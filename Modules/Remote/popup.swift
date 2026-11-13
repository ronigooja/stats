import Cocoa
import Kit

internal class Popup: PopupWrapper {
    private let prompt = EmptyView(height: 60, msg: "Waiting for MQTT machines. Configure the broker in Remote settings.")
    private var rows: [String: MQTTMachineView] = [:]

    public init(_ module: ModuleType) {
        super.init(module, frame: NSRect(x: 0, y: 0, width: Constants.Popup.width, height: 0))
        self.orientation = .vertical
        self.distribution = .fill
        self.spacing = 0
        self.addArrangedSubview(self.prompt)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    internal func callback(_ snapshot: RemoteSnapshot) {
        let machines = snapshot.machines.filter { $0.state }.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        let ids = Set(machines.map { $0.id })
        for id in Array(self.rows.keys) where !ids.contains(id) {
            if let row = self.rows.removeValue(forKey: id) {
                self.removeArrangedSubview(row)
                row.removeFromSuperview()
            }
        }
        self.removeArrangedSubview(self.prompt)
        self.prompt.removeFromSuperview()
        for (index, machine) in machines.enumerated() {
            let row = self.rows[machine.id] ?? MQTTMachineView()
            self.rows[machine.id] = row
            row.update(machine)
            self.removeArrangedSubview(row)
            self.insertArrangedSubview(row, at: index)
        }
        if machines.isEmpty { self.addArrangedSubview(self.prompt) }
        let height = self.fittingSize.height
        if height > 0 && self.frame.height != height {
            self.setFrameSize(NSSize(width: self.frame.width, height: height))
            self.sizeCallback?(self.frame.size)
        }
    }
}

private final class MQTTMachineView: NSStackView {
    private let dot = DotView(color: .tertiaryLabelColor)
    private let name = LabelField()
    private let cpu = TextView()
    private let ram = TextView()
    private let details = TextView()
    private let cpuBar = BarChartView(horizontal: true)
    private let ramBar = BarChartView(horizontal: true)

    init() {
        super.init(frame: .zero)
        self.orientation = .vertical
        self.alignment = .width
        self.spacing = 4
        self.edgeInsets = NSEdgeInsets(top: Constants.Popup.margins, left: Constants.Popup.margins, bottom: Constants.Popup.margins, right: Constants.Popup.margins)
        let header = NSStackView(views: [self.dot, self.name, NSView()])
        header.orientation = .horizontal
        header.spacing = 4
        self.addArrangedSubview(header)
        let metrics = NSStackView(views: [self.cpu, self.cpuBar, self.ram, self.ramBar])
        metrics.orientation = .horizontal
        metrics.alignment = .centerY
        metrics.spacing = 6
        self.addArrangedSubview(metrics)
        for field in [self.cpu, self.ram, self.details] {
            field.font = NSFont.systemFont(ofSize: 10)
            field.textColor = .secondaryLabelColor
        }
        for bar in [self.cpuBar, self.ramBar] {
            bar.heightAnchor.constraint(equalToConstant: 4).isActive = true
            bar.widthAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        }
        self.addArrangedSubview(self.details)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ machine: RemoteMachine) {
        self.name.stringValue = machine.displayName
        self.dot.setColor(machine.online ? .systemGreen : .systemRed)
        self.cpu.stringValue = machine.modules?.cpuUsage.map { "CPU \(Int($0 * 100))%" } ?? "CPU —"
        self.ram.stringValue = machine.modules?.ramUsage.map { "RAM \(Int($0 * 100))%" } ?? "RAM —"
        self.cpuBar.setValue(ColorValue(machine.modules?.cpuUsage ?? 0))
        self.ramBar.setValue(ColorValue(machine.modules?.ramUsage ?? 0))
        var details: [String] = []
        if let disk = machine.mqttMetrics?.disk, disk.total_bytes > 0 {
            details.append("Disk \(Int(min(max(disk.used_bytes / disk.total_bytes, 0), 1) * 100))%")
        }
        if let network = machine.mqttMetrics?.network {
            let rx = ByteCountFormatter.string(fromByteCount: Int64(max(0, min(network.rx_bytes_per_second, Double(Int64.max / 2)))), countStyle: .binary)
            let tx = ByteCountFormatter.string(fromByteCount: Int64(max(0, min(network.tx_bytes_per_second, Double(Int64.max / 2)))), countStyle: .binary)
            details.append("↓ \(rx)/s ↑ \(tx)/s")
        }
        self.details.stringValue = details.joined(separator: " · ")
        self.toolTip = machine.lastSeenTS.map { "Updated: " + $0 }
    }
}
