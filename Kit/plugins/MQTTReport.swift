//
//  MQTTReport.swift
//  Kit
//
//  Publishes this Mac's metrics to the self-hosted MQTT broker.
//

import Foundation
import Network
import Security

public enum MQTTConfig {
    public static let changed = Notification.Name("RemoteMQTTSettingsChanged")
    public static let stateChanged = Notification.Name("RemoteMQTTState")
    public static let defaultInterval = 60
    public static let intervals: [KeyValue_t] = [
        KeyValue_t(key: "10", value: "10 sec"),
        KeyValue_t(key: "30", value: "30 sec"),
        KeyValue_t(key: "60", value: "1 min"),
        KeyValue_t(key: "300", value: "5 min"),
        KeyValue_t(key: "600", value: "10 min")
    ]

    public static var host: String { Store.shared.string(key: "Remote_mqtt_host", defaultValue: "mqtt.z0e.dev") }
    public static var port: String { Store.shared.string(key: "Remote_mqtt_port", defaultValue: "8883") }
    public static var username: String { Store.shared.string(key: "Remote_mqtt_username", defaultValue: "") }
    public static var viewing: Bool { Store.shared.bool(key: "Remote_mqtt_enabled", defaultValue: false) }
    public static var reporting: Bool { Store.shared.bool(key: "Remote_mqtt_report", defaultValue: false) }
    public static var interval: Int {
        let value = Store.shared.int(key: "Remote_mqtt_interval", defaultValue: defaultInterval)
        return max(5, value)
    }
    public static var deviceID: String {
        let stored = Store.shared.string(key: "Remote_mqtt_device", defaultValue: "")
        let value = sanitize(stored)
        return value.isEmpty ? sanitize(Host.current().localizedName ?? "mac") : value
    }

    // MQTT topic levels cannot contain wildcards or separators.
    public static func sanitize(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = value.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.map {
            allowed.contains($0) ? Character($0) : "-"
        }
        return String(String(scalars).prefix(64))
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "eu.exelban.Stats") + ".mqtt",
         kSecAttrAccount as String: "password"]
    }
    public static var password: String {
        var query = self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    public static func savePassword(_ value: String) -> Bool {
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

public enum MQTTWire {
    public static func string(_ text: String) -> [UInt8] {
        let bytes = Array(text.utf8)
        return [UInt8(bytes.count >> 8), UInt8(bytes.count & 255)] + bytes
    }

    public static func packet(_ header: UInt8, _ body: [UInt8]) -> Data {
        var length = body.count
        var out: [UInt8] = [header]
        repeat {
            var byte = UInt8(length % 128)
            length /= 128
            if length > 0 { byte |= 128 }
            out.append(byte)
        } while length > 0
        return Data(out + body)
    }

    // MQTT 3.1.1 requires servers to accept 1-23 alphanumeric client IDs.
    public static func clientID(_ prefix: String) -> String {
        prefix + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(23 - prefix.count))
    }

    public static func connect(clientID: String, username: String, password: String, will: (topic: String, payload: Data)?) -> Data {
        var flags: UInt8 = 0x02
        var body: [UInt8] = [0, 4, 77, 81, 84, 84, 4]
        if will != nil { flags |= 0x04 | 0x20 | 0x08 } // will, retain, QoS 1
        if !username.isEmpty || !password.isEmpty { flags |= 0x80 | 0x40 }
        body += [flags, 0, 60]
        body += string(clientID)
        if let will { body += string(will.topic) + [UInt8(will.payload.count >> 8), UInt8(will.payload.count & 255)] + [UInt8](will.payload) }
        if !username.isEmpty || !password.isEmpty { body += string(username) + string(password) }
        return packet(0x10, body)
    }

    public static func publish(topic: String, payload: Data, id: UInt16) -> Data {
        // QoS 1 + retain
        packet(0x33, string(topic) + [UInt8(id >> 8), UInt8(id & 255)] + [UInt8](payload))
    }
}

// Collects the latest readings of this Mac and publishes them as one retained JSON message.
public final class MQTTReporter {
    public static let shared = MQTTReporter()

    private let queue = DispatchQueue(label: "eu.exelban.Stats.MQTTReporter")
    private var cpu: Double?
    private var ramUsed: Double?
    private var ramTotal: Double?
    private var diskUsed: Double?
    private var diskTotal: Double?
    private var rx: Double?
    private var tx: Double?
    private var load1: Double?

    private var connection: NWConnection?
    private var buffer = Data()
    private var timer: DispatchSourceTimer?
    private var reconnect: DispatchWorkItem?
    private var generation = 0
    private var ready = false
    private var attempts = 0
    private var packetID: UInt16 = 0
    private var started = Date()
    private var infoSent = false

    private var base: String { "stats/v1/machines/\(MQTTConfig.deviceID)" }

    public init() {
        NotificationCenter.default.addObserver(self, selector: #selector(self.settingsChanged), name: MQTTConfig.changed, object: nil)
    }

    // Called from Reader.callback with every module reading.
    public func update(value: Any) {
        guard MQTTConfig.reporting, let metrics = value as? RemoteMetrics else { return }
        metrics.apply(to: self)
        self.queue.async { [weak self] in self?.ensureRunning() }
    }

    // Safe to call from any thread; each module reports only the fields it knows about.
    public func set(cpu: Double? = nil, ramUsed: Double? = nil, ramTotal: Double? = nil, diskUsed: Double? = nil,
                    diskTotal: Double? = nil, rx: Double? = nil, tx: Double? = nil, load1: Double? = nil) {
        self.queue.async { [weak self] in
            guard let self else { return }
            if let cpu { self.cpu = cpu }
            if let ramUsed, let ramTotal { self.ramUsed = ramUsed; self.ramTotal = ramTotal }
            if let diskUsed, let diskTotal { self.diskUsed = diskUsed; self.diskTotal = diskTotal }
            if let rx { self.rx = rx }
            if let tx { self.tx = tx }
            if let load1 { self.load1 = load1 }
        }
    }

    public func stop() {
        self.queue.async { self.teardown(sendOffline: true) }
    }

    @objc private func settingsChanged() {
        self.queue.async { [weak self] in
            guard let self else { return }
            self.teardown(sendOffline: true)
            if MQTTConfig.reporting { self.ensureRunning() }
        }
    }

    private func ensureRunning() {
        guard MQTTConfig.reporting, self.connection == nil, self.reconnect == nil else { return }
        self.open()
    }

    private func notify(_ text: String) {
        DispatchQueue.main.async { NotificationCenter.default.post(name: MQTTConfig.stateChanged, object: "report:" + text) }
    }

    private func open() {
        guard let number = UInt16(MQTTConfig.port), number > 0, let port = NWEndpoint.Port(rawValue: number),
              !MQTTConfig.host.isEmpty, !MQTTConfig.deviceID.isEmpty else {
            self.notify("Invalid host, port or device ID")
            return
        }
        self.generation += 1
        let generation = self.generation
        self.buffer.removeAll()
        self.ready = false
        let connection = NWConnection(host: NWEndpoint.Host(MQTTConfig.host), port: port, using: .tls)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            self?.queue.async {
                guard let self, self.generation == generation else { return }
                switch state {
                case .ready:
                    let will = (topic: self.base + "/status", payload: Data(#"{"online":false}"#.utf8))
                    connection.send(content: MQTTWire.connect(clientID: MQTTWire.clientID("statsr"), username: MQTTConfig.username,
                        password: MQTTConfig.password, will: will), completion: .contentProcessed { _ in })
                    self.receive(connection, generation: generation)
                case .failed(let error): self.failed("Connection failed: \(error.localizedDescription)")
                case .waiting(let error): self.failed("Waiting: \(error.localizedDescription)")
                default: break
                }
            }
        }
        self.notify("Connecting…")
        connection.start(queue: self.queue)
    }

    private func receive(_ connection: NWConnection, generation: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            self?.queue.async {
                guard let self, self.generation == generation else { return }
                if let data {
                    self.buffer.append(data)
                    self.parse()
                }
                guard self.generation == generation else { return }
                if complete || error != nil { self.failed("Disconnected") }
                else { self.receive(connection, generation: generation) }
            }
        }
    }

    private func parse() {
        while self.buffer.count >= 2 {
            let bytes = [UInt8](self.buffer.prefix(2))
            let length = Int(bytes[1])
            guard length < 128, self.buffer.count >= 2 + length else { return }
            let header = bytes[0]
            let payload = [UInt8](self.buffer.dropFirst(2).prefix(length))
            self.buffer = Data(self.buffer.dropFirst(2 + length))
            if header >> 4 == 2 {
                guard payload.count == 2, payload[1] == 0 else {
                    let code = payload.count == 2 ? payload[1] : 0
                    self.failed([4, 5].contains(code) ? "Credentials rejected" : "Connection refused")
                    return
                }
                self.ready = true
                self.attempts = 0
                self.infoSent = false
                self.notify("Reporting as \(MQTTConfig.deviceID)")
                self.sendInfo()
                self.send(topic: self.base + "/status", payload: Data(#"{"online":true}"#.utf8))
                self.startTimer()
            }
        }
    }

    private func startTimer() {
        self.timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: self.queue)
        timer.schedule(deadline: .now() + 1, repeating: .seconds(MQTTConfig.interval))
        timer.setEventHandler { [weak self] in self?.publishMetrics() }
        timer.resume()
        self.timer = timer
    }

    private func sendInfo() {
        guard self.ready, !self.infoSent else { return }
        let info: [String: String] = ["hostname": Host.current().localizedName ?? MQTTConfig.deviceID, "platform": "macOS"]
        guard let data = try? JSONEncoder().encode(info) else { return }
        self.infoSent = true
        self.send(topic: self.base + "/info", payload: data)
    }

    private func publishMetrics() {
        guard self.ready, MQTTConfig.reporting else { return }
        var metrics: [String: Any] = [
            "version": 1,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "uptime_seconds": Int(ProcessInfo.processInfo.systemUptime)
        ]
        if let cpu { metrics["cpu_percent"] = (cpu * 10000).rounded() / 100 }
        if let ramUsed, let ramTotal { metrics["memory"] = ["used_bytes": Int64(ramUsed), "total_bytes": Int64(ramTotal)] }
        if let diskUsed, let diskTotal { metrics["disk"] = ["used_bytes": Int64(diskUsed), "total_bytes": Int64(diskTotal)] }
        if let rx, let tx { metrics["network"] = ["rx_bytes_per_second": rx, "tx_bytes_per_second": tx] }
        if let load1 { metrics["load_1m"] = load1 }
        guard metrics.count > 3, let data = try? JSONSerialization.data(withJSONObject: metrics) else { return }
        self.send(topic: self.base + "/metrics", payload: data)
    }

    private func send(topic: String, payload: Data) {
        guard let connection = self.connection, self.ready else { return }
        self.packetID = self.packetID &+ 1
        if self.packetID == 0 { self.packetID = 1 }
        let generation = self.generation
        connection.send(content: MQTTWire.publish(topic: topic, payload: payload, id: self.packetID), completion: .contentProcessed { [weak self] error in
            guard error != nil else { return }
            self?.queue.async {
                guard let self, self.generation == generation else { return }
                self.failed("Send failed")
            }
        })
    }

    private func failed(_ reason: String) {
        guard self.connection != nil else { return }
        self.teardown(sendOffline: false)
        guard MQTTConfig.reporting else { return }
        self.notify(reason + "; retrying…")
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnect = nil
            self.ensureRunning()
        }
        self.reconnect = item
        self.queue.asyncAfter(deadline: .now() + min(pow(2, Double(self.attempts)), 60), execute: item)
        self.attempts = min(self.attempts + 1, 6)
    }

    // A graceful DISCONNECT discards the will, so the offline status is published explicitly first.
    private func teardown(sendOffline: Bool) {
        self.generation += 1
        self.timer?.cancel()
        self.timer = nil
        self.reconnect?.cancel()
        self.reconnect = nil
        if sendOffline, self.ready, let connection = self.connection {
            self.packetID = self.packetID &+ 1
            connection.send(content: MQTTWire.publish(topic: self.base + "/status", payload: Data(#"{"online":false}"#.utf8), id: self.packetID),
                completion: .contentProcessed { _ in connection.cancel() })
        } else {
            self.connection?.cancel()
        }
        self.connection = nil
        self.ready = false
        if sendOffline { self.notify("Reporting off") }
    }
}

public protocol RemoteMetrics {
    func apply(to reporter: MQTTReporter)
}
