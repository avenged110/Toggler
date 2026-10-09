// MARK: – Harness/Stubs.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Test doubles: scripted dock world, recording ConnectivityController, and the two small
// Utilities.swift pieces the compiled sources need (Utilities.swift itself pulls in AppKit UI).

import Foundation
struct SendableBox<T>: @unchecked Sendable { let value: T }
extension Double { func fixed(_ d: Int) -> String { String(format: "%.\(d)f", self) } }

enum World: String { case docked, knownDocked, undocked, ambiguousUndocked }

final class HarnessWorld: @unchecked Sendable {
    nonisolated(unsafe) static var world: World = .docked
    static let lock = NSLock()
    static func set(_ w: World) { lock.lock(); world = w; lock.unlock()
        Logger.log("[harness] WORLD -> \(w.rawValue)", cName: "[H]") }
    static let dock = Heuristics.ThunderboltDevice(uid: 17443902305921792, name: "CalDigit, Inc. TS3 Plus")
    static func reading() -> (Bool, Int, Heuristics.ThunderboltSnapshot) {
        lock.lock(); let w = world; lock.unlock()
        switch w {
        case .docked:
            return (true, 5, .init(devices: [dock], knownDock: nil, functionScore: 3, evidence: ["USB host controller"], hasStorage: false))
        case .knownDocked:
            return (true, 5, .init(devices: [dock], knownDock: dock, functionScore: 9, evidence: [], hasStorage: false))
        case .undocked:
            return (false, 1, .init(devices: [], knownDock: nil, functionScore: 0, evidence: [], hasStorage: false))
        case .ambiguousUndocked:
            return (false, 2, .init(devices: [], knownDock: nil, functionScore: 0, evidence: [], hasStorage: false))
        } }
}

// Records every radio action with the phase it happened in.
final class ConnectivityController: @unchecked Sendable {
    typealias RadioCompletion = @Sendable (_ verified: Bool) -> Void
    static let shared = ConnectivityController()
    private let lock = NSLock()
    var wifi = true, bt = false
    var asleep = false
    var actions: [String] = []
    var violations: [String] = []
    func reset(wifi: Bool, bt: Bool) { lock.lock(); self.wifi = wifi; self.bt = bt; asleep = false; actions = []; violations = []; lock.unlock() }
    func cachedStateSnapshot() -> (wifi: Bool, bluetooth: Bool) { lock.lock(); defer { lock.unlock() }; return (wifi, bt) }
    func refreshCachedStateSync() {}
    private func act(_ name: String, _ apply: () -> Void, _ c: RadioCompletion?) {
        lock.lock(); apply()
        let tag = asleep ? "ASLEEP" : "awake"
        actions.append("\(name)@\(tag)")
        if asleep { violations.append(name) }
        lock.unlock()
        Logger.log("[harness] RADIO \(name) (\(tag))", cName: "[H]")
        c?(true) }
    func disableWiFi(completion: RadioCompletion? = nil) { act("disableWiFi", { wifi = false }, completion) }
    func enableWiFi(completion: RadioCompletion? = nil) { act("enableWiFi", { wifi = true }, completion) }
    func disableBluetooth(completion: RadioCompletion? = nil) { act("disableBluetooth", { bt = false }, completion) }
    func enableBluetooth(completion: RadioCompletion? = nil) { act("enableBluetooth", { bt = true }, completion) }
    func setAsleep(_ v: Bool) { lock.lock(); asleep = v; lock.unlock() }
}
