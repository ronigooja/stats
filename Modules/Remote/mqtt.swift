// Remote reads machines from the self-hosted MQTT broker configured in the settings.
import Cocoa
import Network
import Kit

// Byte counts come from the network and are later converted with Int64(); keep them far inside its range.
private let maxBytes: Double = 1e18

private struct MQTTMetrics: Decodable {
    struct Capacity: Decodable {
        let used_bytes: Double
        let total_bytes: Double
    }
    struct Network: Decodable {
        let rx_bytes_per_second: Double
        let tx_bytes_per_second: Double
    }
    struct DiskEntry: Decodable {
        let value: RemoteDiskEntry?

        private enum CodingKeys: String, CodingKey {
            case mount, used_bytes, total_bytes
        }

        init(from decoder: Decoder) throws {
            guard let container = try? decoder.container(keyedBy: CodingKeys.self),
                  let mount = try? container.decode(String.self, forKey: .mount),
                  let used = try? container.decode(Double.self, forKey: .used_bytes),
                  let total = try? container.decode(Double.self, forKey: .total_bytes),
                  used.isFinite, total.isFinite, total > 0, total <= maxBytes else {
                self.value = nil
                return
            }
            let trimmedMount = mount.trimmingCharacters(in: .whitespacesAndNewlines)
            self.value = trimmedMount.isEmpty ? nil : RemoteDiskEntry(mount: trimmedMount, used: min(max(used, 0), total), total: total)
        }
    }
    struct Disks: Decodable {
        let entries: [RemoteDiskEntry]

        init(from decoder: Decoder) throws {
            guard var container = try? decoder.unkeyedContainer() else {
                self.entries = []
                return
            }
            var entries: [RemoteDiskEntry] = []
            while !container.isAtEnd, entries.count < 32 {
                let entry = try container.decode(DiskEntry.self)
                if let value = entry.value { entries.append(value) }
            }
            self.entries = entries
        }
    }
    let cpu_percent: Double?
    let gpu_percent: Double?
    let memory: Capacity?
    let disk: Capacity?
    let disks: Disks?
    let network: Network?
    let load_1m: Double?
    let uptime_seconds: Double?
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
    private var silence: DispatchWorkItem?
    private let snapshotDelay: TimeInterval = 0.5
    private var pendingSnapshot: DispatchWorkItem?

    func start() {
        guard self.stopped else { self.publish(); return }
        self.stopped = false
        self.publish()
        self.open()
    }

    func stop() {
        self.stopped = true
        self.pendingSnapshot?.cancel()
        self.pendingSnapshot = nil
        self.generation += 1
        self.reconnect?.cancel()
        self.reconnect = nil
        self.silence?.cancel()
        self.silence = nil
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
            self.onState?(localizedString("Invalid broker host or port"))
            return
        }
        self.generation += 1
        let generation = self.generation
        self.buffer.removeAll()
        self.connected = false
        self.lastResponse = Date()
        self.onState?(localizedString("Connecting…"))
        let connection = NWConnection(host: NWEndpoint.Host(MQTTConfig.host), port: port, using: .tls)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.generation == generation, !self.stopped else { return }
            switch state {
            case .ready:
                self.send(MQTTWire.connect(clientID: MQTTWire.clientID("statsv"), username: MQTTConfig.username,
                                           password: MQTTConfig.password, will: nil))
                self.receive(connection, generation: generation)
            case .failed(let error): self.failed(String(format: localizedString("Connection failed: %@"), error.localizedDescription))
            case .waiting(let error): self.failed(String(format: localizedString("Unreachable: %@"), error.localizedDescription))
            default: break
            }
        }
        connection.start(queue: .main)
        self.timer = Timer(timeInterval: 45, repeats: true) { [weak self] _ in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastResponse) > (self.connected ? 90 : 30) {
                self.failed(localizedString("Timed out"))
            } else if self.connected {
                self.send(MQTTWire.packet(0xC0, []))
            }
        }
        self.timer?.tolerance = 10
        RunLoop.main.add(self.timer!, forMode: .common)
    }

    private func failed(_ reason: String) {
        guard !self.stopped, self.connection != nil else { return }
        self.generation += 1
        self.connection?.cancel()
        self.connection = nil
        self.connected = false
        self.silence?.cancel()
        self.silence = nil
        self.timer?.invalidate()
        self.timer = nil
        for id in Array(self.machines.keys) { self.machines[id]?.online = false }
        self.publish()
        self.onState?(String(format: localizedString("%@; retrying…"), reason))
        let item = DispatchWorkItem { [weak self] in self?.open() }
        self.reconnect = item
        DispatchQueue.main.asyncAfter(deadline: .now() + min(pow(2, Double(self.attempts)), 60), execute: item)
        self.attempts = min(self.attempts + 1, 6)
    }

    private func send(_ packet: Data) {
        let generation = self.generation
        self.connection?.send(content: packet, completion: .contentProcessed { [weak self] error in
            guard let self, self.generation == generation, error != nil else { return }
            self.failed(localizedString("Send failed"))
        })
    }

    private func receive(_ connection: NWConnection, generation: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, !self.stopped, self.generation == generation else { return }
            if let data { self.buffer.append(data); self.parse() }
            guard self.generation == generation else { return }
            if complete || error != nil { self.failed(localizedString("Disconnected")) }
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
        guard payload.count == 2, payload[0] == 0 else { self.failed(localizedString("Invalid CONNACK")); return }
        guard payload[1] == 0 else {
            let reasons: [UInt8: String] = [
                1: localizedString("Protocol version rejected"), 2: localizedString("Client identifier rejected"), 3: localizedString("Server unavailable"),
                4: localizedString("Username or password rejected"), 5: localizedString("Not authorized")
            ]
            self.failed(reasons[payload[1]] ?? localizedString("Connection refused"))
            return
        }
        var subscription: [UInt8] = [0, 1]
        for topic in ["info", "metrics", "status"] {
            subscription += MQTTWire.string("stats/v1/machines/+/" + topic) + [1]
        }
        self.send(MQTTWire.packet(0x82, subscription))
    }

    private func suback(_ payload: [UInt8]) {
        guard payload.count == 5, payload[0] == 0, payload[1] == 1 else { self.failed("Invalid SUBACK"); return }
        // 0x80 marks a rejected subscription. Some brokers (Mosquitto) grant it anyway and just never deliver.
        guard payload.dropFirst(2).allSatisfy({ $0 <= 2 }) else {
            self.failed(localizedString("Subscription denied: this account cannot read machines"))
            return
        }
        self.connected = true
        self.attempts = 0
        self.onState?(self.machines.isEmpty ? localizedString("Connected · waiting for machines") : String(format: localizedString("Connected · %d machines"), self.machines.count))
        
        // Retained info/status arrive right after subscribing, so silence means no data or no read access.
        self.silence?.cancel()
        let check = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped, self.connected, self.machines.isEmpty else { return }
            self.onState?(localizedString("Connected, but no machines received. Check that this account can read stats/v1/machines/#"))
        }
        self.silence = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: check)
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
        self.onState?(String(format: localizedString("Connected · %d machines"), self.machines.count))
        self.scheduleSnapshot()
    }

    private func scheduleSnapshot() {
        guard !self.stopped, self.pendingSnapshot == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.pendingSnapshot = nil
            self.publish()
        }
        self.pendingSnapshot = item
        DispatchQueue.main.asyncAfter(deadline: .now() + self.snapshotDelay, execute: item)
    }

    private func publish() {
        let machines = self.machines.map { id, value -> RemoteMachine in
            let cpu: [String: RemoteCPUModule]? = value.metrics?.cpu_percent.flatMap {
                $0.isFinite ? ["cpu": RemoteCPUModule(usage: min(max($0 / 100, 0), 1))] : nil
            }
            let ram = value.metrics?.memory.flatMap { memory -> RemoteRAMModule? in
                guard memory.total_bytes.isFinite, memory.used_bytes.isFinite, memory.total_bytes > 0, memory.total_bytes <= maxBytes else { return nil }
                return RemoteRAMModule(total: memory.total_bytes, used: min(max(memory.used_bytes, 0), memory.total_bytes))
            }
            let disk = value.metrics?.disk.flatMap { disk -> RemoteDiskModule? in
                guard disk.total_bytes.isFinite, disk.used_bytes.isFinite, disk.total_bytes > 0, disk.total_bytes <= maxBytes else { return nil }
                return RemoteDiskModule(total: disk.total_bytes, used: min(max(disk.used_bytes, 0), disk.total_bytes))
            }
            let network = value.metrics?.network.flatMap { net -> RemoteNetworkModule? in
                guard net.rx_bytes_per_second.isFinite, net.tx_bytes_per_second.isFinite,
                  net.rx_bytes_per_second <= maxBytes, net.tx_bytes_per_second <= maxBytes else { return nil }
                return RemoteNetworkModule(rx: max(net.rx_bytes_per_second, 0), tx: max(net.tx_bytes_per_second, 0))
            }
            let gpu = value.metrics?.gpu_percent.flatMap { gpu -> Double? in
                guard gpu.isFinite, gpu >= 0, gpu <= 100 else { return nil }
                return min(max(gpu / 100, 0), 1)
            }
            return RemoteMachine(id: id, name: value.hostname, online: value.online, lastSeenTS: value.metrics?.timestamp,
                                 platform: value.platform,
                                 modules: RemoteModules(cpu: cpu, ram: ram, disk: disk, disks: value.metrics?.disks?.entries, network: network,
                                                        load: value.metrics?.load_1m.flatMap { $0.isFinite ? $0 : nil },
                                                        uptime: value.metrics?.uptime_seconds.flatMap { $0.isFinite && $0 >= 0 && $0 <= 1e10 ? $0 : nil }, gpu: gpu))
        }
        self.onSnapshot?(RemoteSnapshot(machines: machines))
    }
}
