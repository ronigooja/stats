// Remote receives machines only from the configured self-hosted MQTT broker.
import Cocoa
import Kit

public struct RemoteMachine: Codable {
    public let id: String
    public let name: String?
    public let online: Bool
    public let lastSeenTS: String?
    public let modules: RemoteModules?
    public let mqttMetrics: MQTTMetrics?

    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return String(self.id.dropFirst("mqtt:".count))
    }

    public var state: Bool {
        Store.shared.bool(key: "Remote_machine_\(self.id)", defaultValue: true)
    }
}

public struct RemoteModules: Codable {
    public let cpu: [String: RemoteCPUModule]?
    public let ram: RemoteRAMModule?

    public var cpuUsage: Double? {
        guard let cpu else { return nil }
        let values = cpu.values.compactMap { $0.usage }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    public var ramUsage: Double? {
        guard let ram, ram.total > 0 else { return nil }
        return ram.used / ram.total
    }
}

public struct RemoteCPUModule: Codable {
    public let usage: Double?
}

public struct RemoteRAMModule: Codable {
    public let total: Double
    public let used: Double
}

public struct RemoteSnapshot: Codable {
    public let machines: [RemoteMachine]
}

public class Remote: Module {
    private let settingsView: Settings
    private let popupView: Popup
    private var dataReader: DataReader?

    public init() {
        self.settingsView = Settings(.remote)
        self.popupView = Popup(.remote)
        super.init(moduleType: .remote, popup: self.popupView, settings: self.settingsView)
        self.dataReader = DataReader(.remote) { [weak self] snapshot in
            self?.callback(snapshot)
        }
        self.settingsView.toggleCallback = { [weak self] in self?.dataReader?.read() }
        NotificationCenter.default.addObserver(self, selector: #selector(self.handleMQTTSettings), name: MQTTSettings.changed, object: nil)
        self.setReaders([self.dataReader])
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: MQTTSettings.changed, object: nil)
    }

    @objc private func handleMQTTSettings() {
        self.dataReader?.stop()
        self.callback(RemoteSnapshot(machines: []))
        if self.enabled { self.dataReader?.start() }
    }

    private func callback(_ snapshot: RemoteSnapshot?) {
        guard let snapshot, self.enabled, self.dataReader != nil else { return }
        // Reader can restore an old database snapshot before setup runs.
        guard snapshot.machines.allSatisfy({ $0.id.hasPrefix("mqtt:") }) else { return }
        let render = { [weak self] in
            guard let self, self.enabled else { return }
            self.settingsView.update(snapshot.machines)
            self.popupView.callback(snapshot)
            let machines = snapshot.machines.filter { $0.state }
            let online = machines.filter { $0.online }.count
            let color: NSColor = machines.isEmpty ? .systemGray :
                (online == machines.count ? .systemGreen : (online == 0 ? .systemRed : .systemOrange))
            self.menuBar.widgets.filter { $0.isActive }.forEach { widget in
                (widget.item as? DotWidget)?.setValue(color)
            }
        }
        if Thread.isMainThread { render() }
        else { DispatchQueue.main.async(execute: render) }
    }
}
