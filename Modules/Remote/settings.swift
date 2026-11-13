import Cocoa
import Kit

internal class Settings: NSStackView, Settings_v {
    public var toggleCallback: (() -> Void) = {}
    private let enabled = NSButton(checkboxWithTitle: "Connect to MQTT broker", target: nil, action: nil)
    private let host = NSTextField(string: MQTTSettings.host)
    private let port = NSTextField(string: MQTTSettings.port)
    private let username = NSTextField(string: MQTTSettings.username)
    private let password = NSSecureTextField(string: MQTTSettings.password)
    private let status = NSTextField(wrappingLabelWithString: "TLS/TCP · stats/v1/machines/+/{info,metrics,status}")
    private let machines = NSStackView()

    public init(_ module: ModuleType) {
        super.init(frame: .zero)
        self.orientation = .vertical
        self.spacing = Constants.Settings.margin
        self.alignment = .width
        self.enabled.state = MQTTSettings.enabled ? .on : .off
        self.enabled.target = self
        self.enabled.action = #selector(self.save)
        self.addArrangedSubview(self.enabled)
        self.addArrangedSubview(PreferencesSection(title: "Self-hosted MQTT", [
            PreferencesRow("TLS broker", component: self.host),
            PreferencesRow("Port", component: self.port),
            PreferencesRow("Username", component: self.username),
            PreferencesRow("Password (Keychain)", component: self.password)
        ]))
        let apply = NSButton(title: "Apply MQTT settings", target: self, action: #selector(self.save))
        apply.bezelStyle = .rounded
        self.addArrangedSubview(apply)
        self.status.font = NSFont.systemFont(ofSize: 11)
        self.status.textColor = .secondaryLabelColor
        self.addArrangedSubview(self.status)
        self.machines.orientation = .vertical
        self.machines.alignment = .width
        self.addArrangedSubview(self.machines)
        NotificationCenter.default.addObserver(self, selector: #selector(self.stateChanged), name: MQTTSettings.stateChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    public func load(widgets: [widget_t]) {}

    public func update(_ machines: [RemoteMachine]) {
        self.machines.arrangedSubviews.forEach {
            self.machines.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for machine in machines.sorted(by: { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }) {
            let toggle = NSButton(checkboxWithTitle: machine.displayName, target: self, action: #selector(self.toggleMachine))
            toggle.identifier = NSUserInterfaceItemIdentifier("Remote_machine_\(machine.id)")
            toggle.state = machine.state ? .on : .off
            self.machines.addArrangedSubview(toggle)
        }
    }

    @objc private func toggleMachine(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        Store.shared.set(key: key, value: sender.state == .on)
        self.toggleCallback()
    }

    @objc private func stateChanged(_ notification: Notification) {
        if let text = notification.object as? String { self.status.stringValue = text }
    }

    @objc private func save() {
        // Disabling must work even with invalid edits or an unavailable Keychain.
        guard self.enabled.state == .on else {
            Store.shared.set(key: "Remote_mqtt_enabled", value: false)
            self.status.stringValue = "MQTT disconnected"
            NotificationCenter.default.post(name: MQTTSettings.changed, object: nil)
            return
        }
        let host = self.host.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, let port = UInt16(self.port.stringValue), port > 0,
              self.username.stringValue.utf8.count <= 65535, self.password.stringValue.utf8.count <= 65535 else {
            self.status.stringValue = "Enter a broker hostname, port 1–65535 and valid credentials."
            return
        }
        guard MQTTSettings.savePassword(self.password.stringValue) else {
            self.status.stringValue = "Could not save the MQTT password in Keychain."
            return
        }
        Store.shared.set(key: "Remote_mqtt_host", value: host)
        Store.shared.set(key: "Remote_mqtt_port", value: String(port))
        Store.shared.set(key: "Remote_mqtt_username", value: self.username.stringValue)
        Store.shared.set(key: "Remote_mqtt_enabled", value: true)
        self.status.stringValue = "Connecting to MQTT…"
        NotificationCenter.default.post(name: MQTTSettings.changed, object: nil)
    }
}
