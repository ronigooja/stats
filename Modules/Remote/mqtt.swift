// Remote uses only the self-hosted broker configured here.
import Cocoa
import Network
import Security
import Kit

internal enum MQTTSettings {
    static let changed = Notification.Name("RemoteMQTTSettingsChanged")
    static let stateChanged = Notification.Name("RemoteMQTTState")
    static var enabled: Bool { Store.shared.bool(key: "Remote_mqtt_enabled", defaultValue: false) }
    static var host: String { Store.shared.string(key: "Remote_mqtt_host", defaultValue: "mqtt.z0e.dev") }
    static var port: String { Store.shared.string(key: "Remote_mqtt_port", defaultValue: "8883") }
    static var username: String { Store.shared.string(key: "Remote_mqtt_username", defaultValue: "") }
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "eu.exelban.Stats") + ".mqtt-viewer",
         kSecAttrAccount as String: "password"]
    }
    static var password: String {
        get {
            var query = self.query
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }
    static func savePassword(_ value: String) -> Bool {
        if value.isEmpty {
            let result = SecItemDelete(self.query as CFDictionary)
            return result == errSecSuccess || result == errSecItemNotFound
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let result = SecItemUpdate(self.query as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            return SecItemAdd(self.query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess
        }
        return result == errSecSuccess
    }
}

public struct MQTTMetrics: Codable {
    public struct Capacity: Codable {
        public let used_bytes: Double
        public let total_bytes: Double
    }
    public struct Network: Codable {
        public let rx_bytes_per_second: Double
        public let tx_bytes_per_second: Double
    }
    public let cpu_percent: Double?
    public let memory: Capacity?
    public let disk: Capacity?
    public let network: Network?
    public let timestamp: MQTTTimestamp?
}

public enum MQTTTimestamp: Codable {
    case text(String)
    case seconds(Double)
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let number = try? value.decode(Double.self) { self = .seconds(number) }
        else { self = .text(try value.decode(String.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .text(let text): try value.encode(text)
        case .seconds(let number): try value.encode(number)
        }
    }
    var displayValue: String {
        switch self {
        case .text(let text): return text
        case .seconds(let value): return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: value > 1e12 ? value / 1000 : value))
        }
    }
}

// All state and callbacks are confined to the main queue. TLS uses system trust validation.
internal final class MQTTSubscriber {
    private struct Machine {
        var hostname: String?
        var online = false
        var metrics: MQTTMetrics?
    }
    var onSnapshot: ((RemoteSnapshot) -> Void)?
    var onState: ((String) -> Void)?
    private var machines: [String: Machine] = [:]
    private var connection: NWConnection?
    private var buffer = Data()
    private var timer: Timer?
    private var reconnect: DispatchWorkItem?
    private var stopped = true
    private var generation = 0
    private var lastResponse = Date()
    private var connected = false
    private var attempts = 0

    func start() {
        guard self.stopped else { self.publish(); return }
        self.stopped = false
        self.publish()
        self.open()
    }
    func stop() {
        self.stopped = true
        self.generation += 1
        self.reconnect?.cancel()
        self.reconnect = nil
        self.timer?.invalidate()
        self.timer = nil
        self.connection?.cancel()
        self.connection = nil
        self.connected = false
    }
    private func open() {
        guard !self.stopped else { return }
        guard let number = UInt16(MQTTSettings.port), number > 0,
              let port = NWEndpoint.Port(rawValue: number), !MQTTSettings.host.isEmpty,
              [MQTTSettings.username, MQTTSettings.password].allSatisfy({ $0.utf8.count <= 65535 }) else {
            self.onState?("Invalid MQTT host, port or credentials")
            return
        }
        self.generation += 1
        let generation = self.generation
        self.buffer.removeAll()
        self.connected = false
        self.lastResponse = Date()
        self.onState?("Connecting to MQTT…")
        let connection = NWConnection(host: NWEndpoint.Host(MQTTSettings.host), port: port, using: .tls)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.generation == generation, !self.stopped else { return }
            switch state {
            case .ready:
                var body: [UInt8] = [0, 4, 77, 81, 84, 84, 4]
                let user = MQTTSettings.username
                let password = MQTTSettings.password
                body += [user.isEmpty && password.isEmpty ? 2 : 194, 0, 60]
                // MQTT 3.1.1 servers must support 1–23 alphanumeric client ID bytes.
                body += Self.string("stats" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(18)))
                if !user.isEmpty || !password.isEmpty { body += Self.string(user) + Self.string(password) }
                self.send(0x10, body)
                self.receive(connection, generation: generation)
            case .failed, .waiting: self.failed("MQTT connection unavailable")
            default: break
            }
        }
        connection.start(queue: .main)
        self.timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastResponse) > (self.connected ? 90 : 30) {
                self.failed("MQTT connection timed out")
            } else if self.connected { self.send(0xC0, []) }
        }
    }
    private func failed(_ reason: String) {
        guard !self.stopped, self.connection != nil else { return }
        self.generation += 1
        self.connection?.cancel()
        self.connection = nil
        self.connected = false
        self.timer?.invalidate()
        self.timer = nil
        for id in Array(self.machines.keys) { self.machines[id]?.online = false }
        self.publish()
        self.onState?(reason + "; retrying…")
        let item = DispatchWorkItem { [weak self] in self?.open() }
        self.reconnect = item
        DispatchQueue.main.asyncAfter(deadline: .now() + min(pow(2, Double(self.attempts)), 60), execute: item)
        self.attempts = min(self.attempts + 1, 6)
    }
    private static func string(_ text: String) -> [UInt8] {
        let bytes = Array(text.utf8)
        return [UInt8(bytes.count >> 8), UInt8(bytes.count & 255)] + bytes
    }
    private func send(_ header: UInt8, _ body: [UInt8]) {
        var length = body.count
        var packet = [header]
        repeat {
            var byte = UInt8(length % 128)
            length /= 128
            if length > 0 { byte |= 128 }
            packet.append(byte)
        } while length > 0
        packet += body
        let generation = self.generation
        self.connection?.send(content: Data(packet), completion: .contentProcessed { [weak self] error in
            guard let self, self.generation == generation, error != nil else { return }
            self.failed("MQTT send failed")
        })
    }
    private func receive(_ connection: NWConnection, generation: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, !self.stopped, self.generation == generation else { return }
            if let data { self.buffer.append(data); self.parse() }
            guard self.generation == generation else { return }
            if complete || error != nil { self.failed("MQTT disconnected") }
            else { self.receive(connection, generation: generation) }
        }
    }
    private func parse() {
        while self.buffer.count >= 2 {
            let bytes = [UInt8](self.buffer.prefix(5))
            var length = 0, multiplier = 1, offset = 1
            while offset < bytes.count {
                let byte = bytes[offset]
                length += Int(byte & 127) * multiplier
                offset += 1
                if byte & 128 == 0 { break }
                if offset == 5 { self.failed("Invalid MQTT frame"); return }
                multiplier *= 128
            }
            guard bytes[offset - 1] & 128 == 0 else { return }
            guard length <= 1_048_576 else { self.failed("MQTT frame exceeds 1 MiB"); return }
            guard self.buffer.count >= offset + length else { return }
            let header = bytes[0]
            let payload = [UInt8](self.buffer.dropFirst(offset).prefix(length))
            self.buffer = Data(self.buffer.dropFirst(offset + length))
            self.lastResponse = Date()
            switch header >> 4 {
            case 2:
                guard payload.count == 2, payload[0] == 0 else { self.failed("Invalid MQTT CONNACK"); return }
                if payload[1] != 0 {
                    let reasons: [UInt8: String] = [
                        1: "MQTT protocol version rejected", 2: "MQTT client identifier rejected",
                        3: "MQTT server unavailable", 4: "MQTT username or password rejected",
                        5: "MQTT authorization rejected"
                    ]
                    self.failed(reasons[payload[1]] ?? "Invalid MQTT CONNACK return code")
                    return
                }
                var subscription: [UInt8] = [0, 1]
                for topic in ["info", "metrics", "status"] {
                    subscription += Self.string("stats/v1/machines/+/" + topic) + [0]
                }
                self.send(0x82, subscription)
            case 9:
                guard payload.count == 5, payload[0] == 0, payload[1] == 1,
                      payload.dropFirst(2).allSatisfy({ $0 <= 2 }) else { self.failed("MQTT subscription rejected"); return }
                self.connected = true
                self.attempts = 0
                self.onState?("MQTT connected · waiting for machines")
            case 3:
                guard payload.count >= 2 else { continue }
                let topicLength = Int(payload[0]) * 256 + Int(payload[1])
                let qos = (header >> 1) & 3
                let start = 2 + topicLength + (qos > 0 ? 2 : 0)
                guard qos <= 1, payload.count >= start,
                      let topic = String(bytes: payload[2..<(2 + topicLength)], encoding: .utf8) else { continue }
                if qos == 1 { self.send(0x40, Array(payload[(start - 2)..<start])) }
                self.message(topic, data: Data(payload.dropFirst(start)))
            default: break
            }
        }
    }
    private func message(_ topic: String, data: Data) {
        let parts = topic.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == "stats", parts[1] == "v1", parts[2] == "machines", !parts[3].isEmpty else { return }
        let id = String(parts[3])
        if data.isEmpty {
            guard var machine = self.machines[id] else { return }
            // A retained deletion applies to one topic, not the entire machine.
            switch parts[4] {
            case "info": machine.hostname = nil
            case "metrics": machine.metrics = nil
            case "status": machine.online = false
            default: return
            }
            self.machines[id] = machine
            self.publish()
            return
        }
        var machine = self.machines[id] ?? Machine()
        switch parts[4] {
        case "info":
            struct Info: Decodable { let hostname: String }
            guard let info = try? JSONDecoder().decode(Info.self, from: data) else { return }
            machine.hostname = info.hostname
        case "status":
            struct Status: Decodable { let online: Bool }
            guard let status = try? JSONDecoder().decode(Status.self, from: data) else { return }
            machine.online = status.online
        case "metrics":
            guard let metrics = try? JSONDecoder().decode(MQTTMetrics.self, from: data) else { return }
            machine.metrics = metrics
        default: return
        }
        self.machines[id] = machine
        self.onState?("MQTT connected · \(self.machines.count) machines")
        self.publish()
    }
    private func publish() {
        let machines = self.machines.map { id, value in
            let cpu: [String: RemoteCPUModule]? = value.metrics?.cpu_percent.flatMap {
                $0.isFinite ? ["cpu": RemoteCPUModule(usage: min(max($0 / 100, 0), 1))] : nil
            }
            let ram = value.metrics?.memory.flatMap { memory -> RemoteRAMModule? in
                guard memory.total_bytes.isFinite, memory.used_bytes.isFinite, memory.total_bytes > 0 else { return nil }
                return RemoteRAMModule(total: memory.total_bytes, used: min(max(memory.used_bytes, 0), memory.total_bytes))
            }
            return RemoteMachine(id: "mqtt:" + id, name: value.hostname, online: value.online,
                lastSeenTS: value.metrics?.timestamp?.displayValue,
                modules: RemoteModules(cpu: cpu, ram: ram), mqttMetrics: value.metrics)
        }
        self.onSnapshot?(RemoteSnapshot(machines: machines))
    }
}
