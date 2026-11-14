//
//  settings.swift
//  Remote
//
//  Created by Serhiy Mytrovtsiy on 20/05/2026.
//  Using Swift 6.0.
//  Running on macOS 26.5.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

internal class Settings: NSStackView, Settings_v {
    public var toggleCallback: (() -> Void) = {}
    public var connectionCallback: (() -> Void) = {}
    
    private let host = NSTextField(string: MQTTConfig.host)
    private let port = NSTextField(string: MQTTConfig.port)
    private let username = NSTextField(string: MQTTConfig.username)
    private let password = NSSecureTextField(string: MQTTConfig.password)
    private let deviceID = NSTextField(string: MQTTConfig.deviceID)
    private let status = TextView()
    private let reportStatus = TextView()
    
    private let machinesList: RemoteList = RemoteList()
    
    public init(_ module: ModuleType) {
        super.init(frame: .zero)
        
        self.orientation = .vertical
        self.spacing = Constants.Settings.margin
        
        self.machinesList.toggleCallback = { [weak self] in self?.toggleCallback() }
        
        [self.host, self.port, self.username, self.password, self.deviceID].forEach {
            $0.widthAnchor.constraint(equalToConstant: 180).isActive = true
            $0.alignment = .right
        }
        self.port.widthAnchor.constraint(equalToConstant: 70).isActive = true
        
        for field in [self.status, self.reportStatus] {
            field.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            field.textColor = .secondaryLabelColor
        }
        
        let intervals = MQTTConfig.intervals
        let selected = String(MQTTConfig.interval)
        let intervalSelect = selectView(
            action: #selector(self.changeInterval),
            items: intervals.contains(where: { $0.key == selected }) ? intervals : intervals + [KeyValue_t(key: selected, value: "\(selected) sec")],
            selected: selected
        )
        
        self.addArrangedSubview(PreferencesSection(title: localizedString("Broker"), [
            PreferencesRow(localizedString("Show machines"), component: switchView(
                action: #selector(self.toggleViewing),
                state: MQTTConfig.viewing
            )),
            PreferencesRow(localizedString("Host"), component: self.host),
            PreferencesRow(localizedString("Port"), component: self.port),
            PreferencesRow(localizedString("Username"), component: self.username),
            PreferencesRow(localizedString("Password"), component: self.password),
            PreferencesRow(component: buttonView(#selector(self.apply), text: localizedString("Apply"))),
            PreferencesRow(component: self.status)
        ]))
        
        self.addArrangedSubview(PreferencesSection(title: localizedString("This Mac"), [
            PreferencesRow(localizedString("Report this Mac"), component: switchView(
                action: #selector(self.toggleReporting),
                state: MQTTConfig.reporting
            )),
            PreferencesRow(localizedString("Device ID"), component: self.deviceID),
            PreferencesRow(localizedString("Report interval"), component: intervalSelect),
            PreferencesRow(component: self.reportStatus)
        ]))
        
        self.addArrangedSubview(self.machinesList)
        
        self.status.stringValue = MQTTConfig.viewing ? localizedString("Connecting…") : localizedString("Disconnected")
        self.reportStatus.stringValue = MQTTConfig.reporting ? "" : localizedString("Reporting off")
        
        NotificationCenter.default.addObserver(self, selector: #selector(self.stateChanged), name: MQTTConfig.stateChanged, object: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self, name: MQTTConfig.stateChanged, object: nil)
    }
    
    public func load(widgets: [widget_t]) {}
    
    public func update(_ machines: [RemoteMachine]) {
        self.machinesList.update(machines: machines.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        })
    }
    
    @objc private func stateChanged(_ notification: Notification) {
        guard let text = notification.object as? String else { return }
        DispatchQueue.main.async {
            if text.hasPrefix("report:") { self.reportStatus.stringValue = String(text.dropFirst(7)) }
            else { self.status.stringValue = text }
        }
    }
    
    @objc private func toggleViewing(_ sender: NSControl) {
        Store.shared.set(key: "Remote_mqtt_enabled", value: controlState(sender))
        if !MQTTConfig.viewing { self.status.stringValue = localizedString("Disconnected") }
        self.connectionCallback()
    }
    
    @objc private func toggleReporting(_ sender: NSControl) {
        // Persist the device ID before the reporter reads it.
        self.saveDevice()
        Store.shared.set(key: "Remote_mqtt_report", value: controlState(sender))
        if !MQTTConfig.reporting { self.reportStatus.stringValue = localizedString("Reporting off") }
        NotificationCenter.default.post(name: MQTTConfig.changed, object: nil)
    }
    
    @objc private func changeInterval(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let value = Int(key) else { return }
        Store.shared.set(key: "Remote_mqtt_interval", value: value)
        NotificationCenter.default.post(name: MQTTConfig.changed, object: nil)
    }
    
    private func saveDevice() {
        let id = MQTTConfig.sanitize(self.deviceID.stringValue)
        if !id.isEmpty {
            Store.shared.set(key: "Remote_mqtt_device", value: id)
            self.deviceID.stringValue = id
        }
    }
    
    @objc private func apply() {
        let host = self.host.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, let port = UInt16(self.port.stringValue), port > 0,
              self.username.stringValue.utf8.count <= 65535, self.password.stringValue.utf8.count <= 65535 else {
            self.status.stringValue = localizedString("Enter a host, a port (1–65535) and valid credentials")
            return
        }
        guard MQTTConfig.savePassword(self.password.stringValue) else {
            self.status.stringValue = localizedString("Could not save the password locally")
            return
        }
        Store.shared.set(key: "Remote_mqtt_host", value: host)
        Store.shared.set(key: "Remote_mqtt_port", value: String(port))
        Store.shared.set(key: "Remote_mqtt_username", value: self.username.stringValue)
        self.saveDevice()
        self.status.stringValue = MQTTConfig.viewing ? localizedString("Connecting…") : localizedString("Saved")
        NotificationCenter.default.post(name: MQTTConfig.changed, object: nil)
        self.connectionCallback()
    }
}

internal class RemoteList: NSStackView {
    public var toggleCallback: (() -> Void) = {}
    
    private var sections: [PreferencesSection] = []
    
    public init() {
        super.init(frame: .zero)
        
        self.orientation = .vertical
        self.alignment = .width
        self.spacing = Constants.Settings.margin
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    fileprivate func reset() {
        for s in self.sections {
            self.removeArrangedSubview(s)
            s.removeFromSuperview()
        }
        self.sections.removeAll()
    }
    
    fileprivate func append(_ section: PreferencesSection) {
        self.addArrangedSubview(section)
        self.sections.append(section)
    }
    
    fileprivate func row(storeKey: String, status: Bool, name: String, subtitle: String) -> NSView {
        let toggle = switchView(action: #selector(self.toggle), state: Store.shared.bool(key: storeKey, defaultValue: true))
        toggle.identifier = NSUserInterfaceItemIdentifier(storeKey)
        
        let dot = DotView(color: status ? .systemGreen : .systemRed)
        dot.toolTip = localizedString(status ? "Online" : "Offline")
        
        let titleField = TextView()
        titleField.stringValue = name
        titleField.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        
        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.spacing = 0
        textStack.alignment = .leading
        textStack.addArrangedSubview(titleField)
        
        if !subtitle.isEmpty {
            let subtitleField = TextView()
            subtitleField.font = NSFont.systemFont(ofSize: 12, weight: .regular)
            subtitleField.textColor = .secondaryLabelColor
            subtitleField.stringValue = subtitle
            textStack.addArrangedSubview(subtitleField)
            textStack.addArrangedSubview(NSView())
        }
        
        let row = NSStackView(views: [dot, textStack, NSView(), toggle])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: Constants.Settings.margin / 2, left: 0, bottom: (Constants.Settings.margin / 2) - 1, right: 0)
        
        return row
    }
    
    @objc private func toggle(_ sender: NSControl) {
        guard let key = sender.identifier?.rawValue else { return }
        Store.shared.set(key: key, value: controlState(sender))
        self.toggleCallback()
    }
    
    public func update(machines: [RemoteMachine]) {
        self.reset()
        
        guard !machines.isEmpty else {
            self.append(PreferencesSection(title: localizedString("Machines"), subtitle: localizedString("No machines yet")))
            return
        }
        
        let section = PreferencesSection(title: localizedString("Machines"))
        for machine in machines {
            section.add(self.row(
                storeKey: "\(ModuleType.remote.stringValue)_machine_\(machine.id)",
                status: machine.online,
                name: machine.displayName,
                subtitle: machine.subtitle
            ))
        }
        self.append(section)
    }
}
