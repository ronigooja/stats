//
//  main.swift
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

public struct RemoteMachine: Codable {
    public let id: String
    public let name: String?
    public let online: Bool
    public let lastSeenTS: String?
    public let platform: String?
    public let modules: RemoteModules?
    
    public var displayName: String {
        if let n = self.name, !n.isEmpty { return n }
        return self.id
    }
    
    public var state: Bool {
        Store.shared.bool(key: "Remote_machine_\(self.id)", defaultValue: true)
    }
    
    public var subtitle: String {
        self.platform ?? ""
    }
}

public struct RemoteModules: Codable {
    public let cpu: [String: RemoteCPUModule]?
    public let ram: RemoteRAMModule?
    
    public var cpuUsage: Double? {
        guard let cpu = self.cpu else { return nil }
        let values = cpu.values.compactMap { $0.usage }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
    
    public var ramUsage: Double? {
        guard let ram = self.ram, ram.total > 0 else { return nil }
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
        
        super.init(
            moduleType: .remote,
            popup: self.popupView,
            settings: self.settingsView,
        )
        
        self.dataReader = DataReader(.remote) { [weak self] snapshot in
            self?.callback(snapshot)
        }
        
        self.settingsView.toggleCallback = { [weak self] in
            self?.dataReader?.read()
        }
        self.settingsView.connectionCallback = { [weak self] in
            self?.reconnect()
        }
        
        self.setReaders([self.dataReader])
    }
    
    private func reconnect() {
        self.dataReader?.stop()
        self.callback(RemoteSnapshot(machines: []))
        if self.enabled { self.dataReader?.start() }
    }
    
    private func callback(_ snapshot: RemoteSnapshot?) {
        guard let snapshot, self.enabled else { return }
        
        DispatchQueue.main.async(execute: {
            self.popupView.callback(snapshot)
            self.settingsView.update(snapshot.machines)
        })
        
        self.menuBar.widgets.filter{ $0.isActive }.forEach { (w: SWidget) in
            switch w.item {
            case let widget as DotWidget:
                widget.setValue(self.aggregateColor(snapshot))
            default: break
            }
        }
    }
    
    private func aggregateColor(_ snapshot: RemoteSnapshot) -> NSColor {
        var up = 0, down = 0, total = 0
        for m in snapshot.machines.filter({ $0.state }) {
            total += 1
            m.online ? (up += 1) : (down += 1)
        }
        guard total > 0 else { return .systemGray }
        if up == total { return .systemGreen }
        if down == total { return .systemRed }
        return .systemOrange
    }
}
