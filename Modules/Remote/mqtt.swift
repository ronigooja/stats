// Remote reads machines from the self-hosted MQTT broker configured in the settings.
import Cocoa
import Network
import Kit

private struct MQTTMetrics: Decodable {
    struct Capacity: Decodable {
        let used_bytes: Double
        let total_bytes: Double
    }
    let cpu_percent: Double?
    let memory: Capacity?
    let timestamp: String?
}

// All state and callbacks are confined to the main queue. TLS uses system trust validation.
internal final class MQTTSubscriber {
    private struct Machine {
        var hostname: String?
        var platform: String?
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
        guard let number = UInt16(MQTTConfig.port), number > 0,
              let port = NWEndpoint.Port(rawValue: number), !MQTTConfig.host.isEmpty else {
            self.onState?("Invalid broker host or port")
            return
        }
        self.generation += 1
        let generation = self.generation
        self.buffer.removeAll()
        self.connected = false
        self.lastResponse = Date()
        self.onState?("Connecting…")
        let connection = NWConnection(host: NWEndpoint.Host(MQTTConfig.host), port: port, using: .tls)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.generation == generation, !self.stopped else { return }
            switch state {
            case .ready:
                self.send(MQTTWire.connect(clientID: MQTTWire.clientID("statsv"), username: MQTTConfig.username,
                                           password: MQTTConfig.password, will: nil))
                self.receive(connection, generation: generation)
            case .failed(let error): self.failed("Connection failed: \(error.localizedDescription)")
            case .waiting(let error): self.failed("Unreachable: \(error.localizedDescription)")
            default: break
            }
        }
        connection.start(queue: .main)
        self.timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastResponse) > (self.connected ? 90 : 30) {
                self.failed("Timed out")
            } else if self.connected {
                self.send(MQTTWire.packet(0xC0, []))
            }
        }
        RunLoop.main.add(self.timer!, forMode: .common)
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

    private func send(_ packet: Data) {
        let generation = self.generation
        self.connection?.send(content: packet, completion: .contentProcessed { [weak self] error in
            guard let self, self.generation == generation, error != nil else { return }
            self.failed("Send failed")
        })
    }

    private func receive(_ connection: NWConnection, generation: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, !self.stopped, self.generation == generation else { return }
            if let data { self.buffer.append(data); self.parse() }
            guard self.generation == generation else { return }
            if complete || error != nil { self.failed("Disconnected") }
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
                if offset == 5 { self.failed("Invalid frame"); return }
                multiplier *= 128
            }
            guard bytes[offset - 1] & 128 == 0 else { return }
            guard length <= 1_048_576 else { self.failed("Frame exceeds 1 MiB"); return }
            guard self.buffer.count >= offset + length else { return }
            let header = bytes[0]
            let payload = [UInt8](self.buffer.dropFirst(offset).prefix(length))
            self.buffer = Data(self.buffer.dropFirst(offset + length))
            self.lastResponse = Date()
            switch header >> 4 {
            case 2: self.connack(payload)
            case 9: self.suback(payload)
            case 3: self.incoming(header, payload)
            default: break
            }
        }
    }

    private func connack(_ payload: [UInt8]) {
        guard payload.count == 2, payload[0] == 0 else { self.failed("Invalid CONNACK"); return }
        guard payload[1] == 0 else {
            let reasons: [UInt8: String] = [
                1: "Protocol version rejected", 2: "Client identifier rejected", 3: "Server unavailable",
                4: "Username or password rejected", 5: "Not authorized"
            ]
            self.failed(reasons[payload[1]] ?? "Connection refused")
            return
        }
        var subscription: [UInt8] = [0, 1]
        for topic in ["info", "metrics", "status"] {
            subscription += MQTTWire.string("stats/v1/machines/+/" + topic) + [1]
        }
        self.send(MQTTWire.packet(0x82, subscription))
    }

    private func suback(_ payload: [UInt8]) {
        // 0x80 marks a rejected subscription, e.g. an account without read access.
        guard payload.count == 5, payload[0] == 0, payload[1] == 1 else { self.failed("Invalid SUBACK"); return }
        guard payload.dropFirst(2).allSatisfy({ $0 <= 2 }) else {
            self.failed("Subscription denied: this account cannot read machines")
            return
        }
        self.connected = true
        self.attempts = 0
        self.onState?(self.machines.isEmpty ? "Connected · waiting for machines" : "Connected · \(self.machines.count) machines")
    }

    private func incoming(_ header: UInt8, _ payload: [UInt8]) {
        guard payload.count >= 2 else { return }
        let topicLength = Int(payload[0]) * 256 + Int(payload[1])
        let qos = (header >> 1) & 3
        let start = 2 + topicLength + (qos > 0 ? 2 : 0)
        guard qos <= 1, payload.count >= start,
              let topic = String(bytes: payload[2..<(2 + topicLength)], encoding: .utf8) else { return }
        if qos == 1 { self.send(MQTTWire.packet(0x40, Array(payload[(start - 2)..<start]))) }
        self.message(topic, data: Data(payload.dropFirst(start)))
    }

    private func message(_ topic: String, data: Data) {
        let parts = topic.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == "stats", parts[1] == "v1", parts[2] == "machines", !parts[3].isEmpty else { return }
        let id = String(parts[3])
        var machine = self.machines[id] ?? Machine()
        if data.isEmpty {
            // A retained deletion applies to one topic, not the entire machine.
            guard self.machines[id] != nil else { return }
            switch parts[4] {
            case "info": machine.hostname = nil; machine.platform = nil
            case "metrics": machine.metrics = nil
            case "status": machine.online = false
            default: return
            }
        } else {
            switch parts[4] {
            case "info":
                struct Info: Decodable { let hostname: String?; let platform: String? }
                guard let info = try? JSONDecoder().decode(Info.self, from: data) else { return }
                machine.hostname = info.hostname
                machine.platform = info.platform
            case "status":
                struct Status: Decodable { let online: Bool }
                guard let status = try? JSONDecoder().decode(Status.self, from: data) else { return }
                machine.online = status.online
            case "metrics":
                guard let metrics = try? JSONDecoder().decode(MQTTMetrics.self, from: data) else { return }
                machine.metrics = metrics
            default: return
            }
        }
        self.machines[id] = machine
        self.onState?("Connected · \(self.machines.count) machines")
        self.publish()
    }

    private func publish() {
        let machines = self.machines.map { id, value -> RemoteMachine in
            let cpu: [String: RemoteCPUModule]? = value.metrics?.cpu_percent.flatMap {
                $0.isFinite ? ["cpu": RemoteCPUModule(usage: min(max($0 / 100, 0), 1))] : nil
            }
            let ram = value.metrics?.memory.flatMap { memory -> RemoteRAMModule? in
                guard memory.total_bytes.isFinite, memory.used_bytes.isFinite, memory.total_bytes > 0 else { return nil }
                return RemoteRAMModule(total: memory.total_bytes, used: min(max(memory.used_bytes, 0), memory.total_bytes))
            }
            return RemoteMachine(id: id, name: value.hostname, online: value.online, lastSeenTS: value.metrics?.timestamp,
                                 platform: value.platform, modules: RemoteModules(cpu: cpu, ram: ram))
        }
        self.onSnapshot?(RemoteSnapshot(machines: machines))
    }
}
