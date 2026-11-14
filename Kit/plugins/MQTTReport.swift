//
//  MQTTReport.swift
//  Kit
//
//  Publishes this Mac's metrics to the self-hosted MQTT broker.
//

import Foundation
import Network
import CryptoKit
import Darwin

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

    private static let passwordKey = "Remote_mqtt_password_enc"
    private static let passwordLock = NSLock()
    private static var cachedPassword: String?

    // Local encryption only prevents plaintext reading; this is not protection from the logged-in user.
    // Ignore legacy Keychain items entirely: users must re-enter their password once.
    private static func encryptionKey(create: Bool) throws -> SymmetricKey {
        let manager = FileManager.default
        let support = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("Stats", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let url = directory.appendingPathComponent("mqtt.key")
        if manager.fileExists(atPath: url.path) {
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let data = try Data(contentsOf: url)
            guard data.count == 32 else { throw CocoaError(.fileReadCorruptFile) }
            return SymmetricKey(data: data)
        }
        guard create else { throw CocoaError(.fileNoSuchFile) }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        // Exclusive creation keeps permissions private from the first write and never overwrites a key.
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        return key
    }

    public static var password: String {
        self.passwordLock.lock()
        defer { self.passwordLock.unlock() }
        if let value = self.cachedPassword { return value }
        // Cache failures too: no repeated disk reads/decrypts on reconnect or reporting paths.
        self.cachedPassword = ""
        let stored = Store.shared.string(key: self.passwordKey, defaultValue: "")
        guard !stored.isEmpty, let data = Data(base64Encoded: stored) else { return "" }
        do {
            let key = try self.encryptionKey(create: false)
            let box = try AES.GCM.SealedBox(combined: data)
            let plaintext = try AES.GCM.open(box, using: key)
            let value = String(data: plaintext, encoding: .utf8) ?? ""
            self.cachedPassword = value
            return value
        } catch {
            return ""
        }
    }

    public static func savePassword(_ value: String) -> Bool {
        self.passwordLock.lock()
        defer { self.passwordLock.unlock() }
        self.cachedPassword = nil
        if value.isEmpty {
            Store.shared.remove(self.passwordKey)
            self.cachedPassword = ""
            return true
        }
        do {
            let key = try self.encryptionKey(create: true)
            let box = try AES.GCM.seal(Data(value.utf8), using: key)
            guard let combined = box.combined else { return false }
            Store.shared.set(key: self.passwordKey, value: combined.base64EncodedString())
            self.cachedPassword = value
            return true
        } catch {
            return false
        }
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
    private let runningLock = NSLock()
    private var _running = false
    // Only this flag is shared with reading threads; connection state stays on queue.
    private var running: Bool {
        get {
            self.runningLock.lock()
            defer { self.runningLock.unlock() }
            return self._running
        }
        set {
            self.runningLock.lock()
            defer { self.runningLock.unlock() }
            self._running = newValue
        }
    }
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
        guard !self.running else { return }
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
            self.notify(localizedString("Invalid host, port or device ID"))
            return
        }
        self.running = true
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
                case .failed(let error): self.failed(String(format: localizedString("Connection failed: %@"), error.localizedDescription))
                case .waiting(let error): self.failed(String(format: localizedString("Waiting: %@"), error.localizedDescription))
                default: break
                }
            }
        }
        self.notify(localizedString("Connecting…"))
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
                if complete || error != nil { self.failed(localizedString("Disconnected")) }
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
                self.notify(String(format: localizedString("Reporting as %@"), MQTTConfig.deviceID))
                self.sendInfo()
                self.send(topic: self.base + "/status", payload: Data(#"{"online":true}"#.utf8))
                self.startTimer()
            }
        }
    }

    private func startTimer() {
        self.timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: self.queue)
        timer.schedule(deadline: .now() + 1, repeating: .seconds(MQTTConfig.interval),
                       leeway: .seconds(max(1, MQTTConfig.interval / 10)))
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
                self.failed(localizedString("Send failed"))
            }
        })
    }

    private func failed(_ reason: String) {
        guard self.connection != nil else { return }
        self.teardown(sendOffline: false)
        guard MQTTConfig.reporting else { return }
        self.notify(String(format: localizedString("%@; retrying…"), reason))
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnect = nil
            self.running = false
            self.ensureRunning()
        }
        self.reconnect = item
        self.running = true
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
        self.running = false
        if sendOffline { self.notify(localizedString("Reporting off")) }
    }
}

public protocol RemoteMetrics {
    func apply(to reporter: MQTTReporter)
}
