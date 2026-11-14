//
//  popup.swift
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

internal class Popup: PopupWrapper {
    private let prompt = EmptyView(height: 60, msg: localizedString("No machines yet"))
    
    private var groups: NSStackView = {
        let view = NSStackView()
        view.spacing = Constants.Popup.spacing*2
        view.orientation = .vertical
        return view
    }()
    
    public init(_ module: ModuleType) {
        super.init(module, frame: NSRect(x: 0, y: 0, width: Constants.Popup.width, height: 0))
        
        self.orientation = .vertical
        self.distribution = .fill
        self.spacing = 0
        self.setClippingResistancePriority(.defaultLow, for: .vertical)
        
        self.addArrangedSubview(self.prompt)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func recalculateHeight() {
        let h = self.fittingSize.height
        if h > 0 && self.frame.size.height != h {
            self.setFrameSize(NSSize(width: self.frame.width, height: h))
            self.sizeCallback?(self.frame.size)
        }
    }
    
    internal func callback(_ snapshot: RemoteSnapshot) {
        let machines = snapshot.machines.filter { $0.state }.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        
        if machines.isEmpty {
            self.groups.removeFromSuperview()
            if self.prompt.superview == nil { self.addArrangedSubview(self.prompt) }
        } else {
            self.prompt.removeFromSuperview()
            if self.groups.superview == nil { self.addArrangedSubview(self.groups) }
        }
        
        if let view = self.groups.subviews.compactMap({ $0 as? GroupView }).first {
            view.update(machines: machines)
        } else if !machines.isEmpty {
            let view = GroupView()
            view.update(machines: machines)
            self.groups.addArrangedSubview(view)
        }
        
        self.recalculateHeight()
    }
}

private class GroupView: NSStackView {
    private let body: NSStackView = {
        let v = NSStackView()
        v.orientation = .vertical
        v.distribution = .fill
        v.spacing = 0
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()
    
    public init() {
        super.init(frame: .zero)
        
        self.orientation = .vertical
        self.distribution = .fill
        self.spacing = 0
        self.translatesAutoresizingMaskIntoConstraints = false
        
        self.wantsLayer = true
        self.layer?.cornerRadius = Constants.Popup.radius
        
        self.addArrangedSubview(self.body)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func updateLayer() {
        self.layer?.backgroundColor = (isDarkMode ? NSColor(red: 17/255, green: 17/255, blue: 17/255, alpha: 0.25) : NSColor(red: 245/255, green: 245/255, blue: 245/255, alpha: 1)).cgColor
    }
    
    public func update(machines: [RemoteMachine]) {
        let ids = Set(machines.map { $0.id })
        
        self.body.subviews.compactMap { $0 as? RemoteItemView }.filter { !ids.contains($0.id) }.forEach {
            self.body.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        
        machines.enumerated().forEach { (index, machine) in
            let view: RemoteItemView
            if let existing = self.body.subviews.compactMap({ $0 as? RemoteItemView }).first(where: { $0.id == machine.id }) {
                existing.update(machine)
                view = existing
                self.body.removeArrangedSubview(view)
            } else {
                view = RemoteItemView(machine)
            }
            self.body.insertArrangedSubview(view, at: index)
            view.setLast(index == machines.count - 1)
        }
    }
}

private class RemoteItemView: NSStackView {
    public let id: String
    
    private let dot = DotView(color: .tertiaryLabelColor)
    private var labelField: LabelField = LabelField()
    private let platformField: LabelField = {
        let field = LabelField()
        field.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        field.textColor = .tertiaryLabelColor
        return field
    }()
    
    private let cpuLabel = TextView()
    private let cpuBar = BarChartView(horizontal: true)
    private let ramLabel = TextView()
    private let ramBar = BarChartView(horizontal: true)
    private let diskLabel = TextView()
    private let diskBar = BarChartView(horizontal: true)
    
    private let separator = RemoteSeparator()
    private var heightConstraint: NSLayoutConstraint?
    
    public init(_ machine: RemoteMachine) {
        self.id = machine.id
        
        super.init(frame: NSRect(x: 0, y: 0, width: Constants.Popup.width, height: 53))
        let height = self.heightAnchor.constraint(equalToConstant: 53)
        height.priority = .required
        height.isActive = true
        self.heightConstraint = height
        self.setContentHuggingPriority(.required, for: .vertical)
        self.setContentCompressionResistancePriority(.required, for: .vertical)
        
        self.orientation = .vertical
        self.distribution = .fill
        self.spacing = 0
        self.edgeInsets = NSEdgeInsets(top: Constants.Popup.margins, left: Constants.Popup.margins, bottom: 0, right: Constants.Popup.margins)
        
        let header: NSStackView = {
            let view: NSStackView = NSStackView()
            view.orientation = .horizontal
            view.spacing = 4
            
            view.addArrangedSubview(self.dot)
            view.addArrangedSubview(self.labelField)
            view.addArrangedSubview(NSView())
            view.addArrangedSubview(self.platformField)
            
            return view
        }()
        
        self.addArrangedSubview(header)
        self.addArrangedSubview(self.machineStats())
        self.addArrangedSubview(self.separator)
        
        self.update(machine)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func machineStats() -> NSView {
        let view: NSStackView = NSStackView()
        view.spacing = Constants.Popup.margins
        view.orientation = .horizontal
        view.alignment = .centerY
        view.distribution = .fillEqually
        view.translatesAutoresizingMaskIntoConstraints = false
        view.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        
        let cpuIcon = NSImageView()
        cpuIcon.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: localizedString("CPU"))
        cpuIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        cpuIcon.contentTintColor = .secondaryLabelColor
        cpuIcon.toolTip = localizedString("CPU")
        
        self.cpuLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        self.cpuLabel.textColor = .secondaryLabelColor
        self.cpuLabel.setContentHuggingPriority(.required, for: .horizontal)
        
        let ramIcon = NSImageView()
        ramIcon.image = NSImage(systemSymbolName: "memorychip", accessibilityDescription: localizedString("RAM"))
        ramIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        ramIcon.contentTintColor = .secondaryLabelColor
        ramIcon.toolTip = localizedString("RAM")
        
        self.ramLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        self.ramLabel.textColor = .secondaryLabelColor
        self.ramLabel.setContentHuggingPriority(.required, for: .horizontal)
        
        let diskIcon = NSImageView()
        diskIcon.image = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: localizedString("Disk"))
        diskIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        diskIcon.contentTintColor = .secondaryLabelColor
        diskIcon.toolTip = localizedString("Disk")
        
        self.diskLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        self.diskLabel.textColor = .secondaryLabelColor
        self.diskLabel.setContentHuggingPriority(.required, for: .horizontal)
        
        [self.cpuBar, self.ramBar, self.diskBar].forEach {
            let height = $0.heightAnchor.constraint(equalToConstant: 4)
            height.priority = .defaultHigh
            height.isActive = true
            $0.widthAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        }
        
        let cpuGroup = NSStackView(views: [cpuIcon, self.cpuLabel, self.cpuBar])
        cpuGroup.orientation = .horizontal
        cpuGroup.alignment = .centerY
        cpuGroup.spacing = 0
        
        let ramGroup = NSStackView(views: [ramIcon, self.ramLabel, self.ramBar])
        ramGroup.orientation = .horizontal
        ramGroup.alignment = .centerY
        ramGroup.spacing = 0
        
        let diskGroup = NSStackView(views: [diskIcon, self.diskLabel, self.diskBar])
        diskGroup.orientation = .horizontal
        diskGroup.alignment = .centerY
        diskGroup.spacing = 0
        
        view.addArrangedSubview(cpuGroup)
        view.addArrangedSubview(ramGroup)
        view.addArrangedSubview(diskGroup)
        
        return view
    }
    
    public func update(_ machine: RemoteMachine) {
        self.labelField.stringValue = machine.displayName
        self.platformField.stringValue = machine.subtitle
        self.dot.setColor(machine.online ? .systemGreen : .systemRed)
        self.dot.toolTip = localizedString(machine.online ? "Online" : "Offline")
        
        if let cpu = machine.modules?.cpuUsage {
            self.cpuLabel.stringValue = "\(Int(cpu.rounded(toPlaces: 2) * 100))%"
            self.cpuBar.setValue(ColorValue(cpu))
        } else {
            self.cpuLabel.stringValue = "—"
            self.cpuBar.setValue(ColorValue(0))
        }
        if let ram = machine.modules?.ramUsage {
            self.ramLabel.stringValue = "\(Int(ram.rounded(toPlaces: 2) * 100))%"
            self.ramBar.setValue(ColorValue(ram))
        } else {
            self.ramLabel.stringValue = "—"
            self.ramBar.setValue(ColorValue(0))
        }
        if let disk = machine.modules?.diskUsage {
            self.diskLabel.stringValue = "\(Int(disk.rounded(toPlaces: 2) * 100))%"
            self.diskBar.setValue(ColorValue(disk))
        } else {
            self.diskLabel.stringValue = "—"
            self.diskBar.setValue(ColorValue(0))
        }
        self.toolTip = machine.details
    }
    
    public func setLast(_ isLast: Bool) {
        self.separator.isHidden = isLast
        self.heightConstraint?.constant = 53 + (isLast ? 0 : 1)
    }
}

private class RemoteSeparator: NSView {
    public init() {
        super.init(frame: .zero)
        
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.05).cgColor
        
        let height = self.heightAnchor.constraint(equalToConstant: 1)
        height.priority = .defaultHigh
        height.isActive = true
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func updateLayer() {
        self.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.05).cgColor
    }
}
