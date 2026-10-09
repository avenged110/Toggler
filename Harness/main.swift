// MARK: – Harness/main.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Scenario runner: drives the real EventLogic + MonitorDock through dock/sleep/wake timelines
// against scripted dock readings and a recording radio controller. Build and run via run.sh.

import Foundation

final class Lines: LogSink, @unchecked Sendable {
    let lock = NSLock(); var all: [String] = []
    func receive(line: String, level: LogLevel, category: String?, occurredAt: Date) { lock.lock(); all.append(line); lock.unlock() }
    func mark() -> Int { lock.lock(); defer { lock.unlock() }; return all.count }
    func since(_ m: Int) -> [String] { lock.lock(); defer { lock.unlock() }; return Array(all[m...]) }
}
let lines = Lines()
let logDir = URL(fileURLWithPath: CommandLine.arguments[1])
Logger.bootstrap(.init(fileName: "harness.log", destination: .custom({ logDir }), isEnabled: { true },
                       timestampFormat: "HH:mm:ss.SSS", echoToConsole: false, sinks: [lines]))
Preferences.ensureDefaultsRegistered()
Preferences.disableWiFiDuringSleep = true
Preferences.disableBluetoothDuringSleep = true
Preferences.toggleWiFiOnDockEvent = true
Preferences.toggleBluetoothOnDockEvent = true
Preferences.resetThresholdsToDefaults()
Preferences.resetSettleProbeDelaysToDefaults()
Preferences.forgetKnownDocks()

let cc = ConnectivityController.shared
func wait(_ s: Double) { Thread.sleep(forTimeInterval: s) }
func H(_ m: String) { Logger.log("[harness] \(m)", cName: "[H]") }

final class Ctx {
    let logic = EventLogic()
    let dock = MonitorDock()
    let fix: Bool
    var sleepStart = Date(), sleepAcked: Date? = nil
    init(fix: Bool) { self.fix = fix
        dock.onDockStatusChanged = { [weak logic] d, t in logic?.receiveDockStatusChanged(isDocked: d, timestamp: t) } }
    func start() { dock.startListeningForThunderboltEvents() }
    func event(_ w: World) { HarnessWorld.set(w); H("THUNDERBOLT EVENT"); dock.stopListening(); dock.startListeningForThunderboltEvents() }
    func willSleep() {
        H("WILL SLEEP (\(fix ? "new" : "old") wiring)")
        sleepStart = Date()
        let done: @Sendable () -> Void = { [self] in
            self.sleepAcked = Date(); cc.setAsleep(true)
            H("SLEEP ACKED after \(Date().timeIntervalSince(self.sleepStart).fixed(2))s — system asleep") }
        if fix { dock.resolvePendingVerdictBeforeSleep { [logic] in logic.receiveSystemWillSleep(done: done) } }
        else { logic.receiveSystemWillSleep(done: done) } }
    func didWake() { cc.setAsleep(false); H("DID WAKE"); logic.receiveSystemDidWake() }
    var holdSeconds: Double { (sleepAcked ?? .distantFuture).timeIntervalSince(sleepStart) }
    func stop() { dock.stopListening() }
}

var failures = 0
func check(_ ok: Bool, _ what: String) { print("   \(ok ? "PASS" : "FAIL")  \(what)"); if !ok { failures += 1 } }
func idx(_ ls: [String], _ needle: String) -> Int? { ls.firstIndex { $0.contains(needle) } }

func scenario(_ title: String, fix: Bool, initial: World, wifi: Bool, bt: Bool,
              _ run: (Ctx) -> Void, _ verify: (Ctx, [String]) -> Void) {
    print("\n== \(title)")
    HarnessWorld.set(initial); cc.reset(wifi: wifi, bt: bt)
    let ctx = Ctx(fix: fix)
    ctx.start(); wait(7.0)           // launch verdict (~2.7 s) + undock debounce (3 s)
    let m = lines.mark()
    run(ctx)
    ctx.stop(); wait(0.3)
    let ls = lines.since(m)
    print("   radio actions: \(cc.actions)   final wifi=\(cc.wifi) bt=\(cc.bt)   sleep hold=\(ctx.holdSeconds.fixed(2))s")
    verify(ctx, ls)
}

func runAll() {
// A — undock, lid closed ~1 s later (the verdict lands before sleep — the 00:27 chain).
func beforeAck(_ ls: [String], _ radio: String) -> Bool {
    guard let r = idx(ls, "RADIO \(radio)"), let a = idx(ls, "SLEEP ACKED") else { return false }
    return r < a }
scenario("A: undock then sleep 1.0 s later", fix: true, initial: .docked, wifi: false, bt: true) { c in
    c.event(.undocked); wait(1.0); c.willSleep(); wait(12); c.didWake(); wait(1.5)
} _: { c, ls in
    check(cc.violations.isEmpty, "no radio changes while asleep")
    if let v = idx(ls, "cachedDockState -> false"), let s = idx(ls, "Handling sleep event") { check(v < s, "undock verdict reached EventLogic before the sleep event") } else { check(false, "verdict and sleep both logged") }
    check(idx(ls, "Undock pending at sleep → applying undock toggles") != nil, "sleep applied the pending undock")
    check(beforeAck(ls, "disableBluetooth"), "Bluetooth off BEFORE the sleep acknowledgment")
    check(idx(ls, "Recorded wasWiFiEnabledBeforeSleep=true") != nil, "Wi-Fi recorded for restore (stays off during sleep)")
    check(idx(ls, "Still undocked at wake") != nil, "wake re-checked the dock before restoring")
    check(cc.actions == ["disableBluetooth@awake", "enableWiFi@awake"], "exactly: BT off before sleep, Wi-Fi on at wake")
    check(cc.wifi && !cc.bt, "ends undocked-correct (Wi-Fi on, BT off)")
}

// A2 — same, with both sleep preferences off: the undock toggles alone run before sleep.
Preferences.disableWiFiDuringSleep = false
Preferences.disableBluetoothDuringSleep = false
scenario("A2: undock then sleep, sleep prefs OFF", fix: true, initial: .docked, wifi: false, bt: true) { c in
    c.event(.undocked); wait(1.0); c.willSleep(); wait(6); c.didWake(); wait(1.5)
} _: { c, ls in
    check(cc.violations.isEmpty, "no radio changes while asleep")
    check(beforeAck(ls, "enableWiFi") && beforeAck(ls, "disableBluetooth"), "Wi-Fi on and BT off BEFORE the sleep acknowledgment")
    check(cc.actions.count == 2, "nothing further at wake (\(cc.actions))")
    check(cc.wifi && !cc.bt, "ends Wi-Fi on, BT off")
}
Preferences.disableWiFiDuringSleep = true
Preferences.disableBluetoothDuringSleep = true

// A3 — undock, sleep, re-docked while asleep with no verdict before wake: the wake
// re-check must apply the docked state instead of restoring Wi-Fi.
scenario("A3: undock, sleep, re-docked while asleep", fix: true, initial: .docked, wifi: false, bt: true) { c in
    c.event(.undocked); wait(1.0); c.willSleep(); wait(6)
    HarnessWorld.set(.docked)          // physically re-docked; no Thunderbolt verdict yet
    c.didWake(); wait(1.5)
} _: { c, ls in
    check(cc.violations.isEmpty, "no radio changes while asleep")
    check(idx(ls, "Re-docked while asleep") != nil, "wake re-check detected the re-dock")
    check(!cc.actions.contains("enableWiFi@awake"), "Wi-Fi NOT restored on a docked machine")
    check(!cc.wifi && cc.bt, "ends docked-correct (Wi-Fi off, BT on)")
}

// B — ambiguous sample at sleep: waits for the settle plan's own verdict.
scenario("B: undock, sample NOT high-confidence at sleep", fix: true, initial: .docked, wifi: false, bt: true) { c in
    c.event(.ambiguousUndocked); wait(1.0); c.willSleep(); wait(12); c.didWake(); wait(1.5)
} _: { c, ls in
    check(idx(ls, "Sleep sample not high-confidence") != nil, "low-confidence sample was not accepted")
    check(idx(ls, "Accepting dock state at end of settle plan (isDocked=false)") != nil, "settle plan delivered its own verdict")
    if let v = idx(ls, "cachedDockState -> false"), let s = idx(ls, "Handling sleep event") { check(v < s, "verdict before sleep event") } else { check(false, "verdict and sleep logged") }
    check(c.holdSeconds > 1.8 && c.holdSeconds < 3.0, "sleep held until plan end (~2.1s): \(c.holdSeconds.fixed(2))s")
    check(cc.violations.isEmpty, "no radio changes while asleep")
    check(beforeAck(ls, "disableBluetooth"), "Bluetooth off BEFORE the sleep acknowledgment")
    check(cc.wifi && !cc.bt, "ends Wi-Fi on, BT off")
}

// C — dock then sleep (mirror image).
do { let fix = true
    scenario("C: dock then sleep 0.5 s later", fix: fix, initial: .undocked, wifi: true, bt: false) { c in
        c.event(.docked); wait(0.5); c.willSleep(); wait(12); c.didWake(); wait(1.5)
    } _: { c, ls in
        if !fix { check(!cc.violations.isEmpty, "old wiring changes radios while asleep: \(cc.violations)"); return }
        check(cc.violations.isEmpty, "no radio changes while asleep")
        check(idx(ls, "Skipping sleep handling (laptop is docked)") != nil, "sleep handled as docked")
        check(!cc.wifi && cc.bt, "ends docked-correct (Wi-Fi off, BT on)")
    }
}

// D — recognized dock: fast path settles before sleep, so no hold at all.
scenario("D: recognized dock, sleep 0.6 s after connect", fix: true, initial: .undocked, wifi: true, bt: false) { c in
    Preferences.rememberDock(uid: HarnessWorld.dock.uid, name: HarnessWorld.dock.name)
    c.event(.knownDocked); wait(0.6); c.willSleep(); wait(4); c.didWake(); wait(1)
} _: { c, ls in
    check(idx(ls, "Fast path: recognized dock present") != nil, "fast path accepted the dock")
    check(idx(ls, "unresolved") == nil, "no sleep hold needed")
    check(c.holdSeconds < 0.2, "sleep proceeded immediately (\(c.holdSeconds.fixed(2))s)")
    check(!cc.wifi && cc.bt && cc.violations.isEmpty, "docked-correct, nothing while asleep")
    Preferences.forgetKnownDocks()
}

// E / F — no dock event near sleep: behavior must be unchanged.
scenario("E: steady undocked sleep/wake", fix: true, initial: .undocked, wifi: true, bt: false) { c in
    c.willSleep(); wait(2); c.didWake(); wait(1)
} _: { c, ls in
    check(c.holdSeconds < 0.2, "no hold (\(c.holdSeconds.fixed(2))s)")
    check(cc.actions == ["disableWiFi@awake", "enableWiFi@awake"], "Wi-Fi off before sleep ack, restored at wake")
}
scenario("F: steady docked sleep/wake", fix: true, initial: .docked, wifi: false, bt: true) { c in
    c.willSleep(); wait(2); c.didWake(); wait(1)
} _: { c, ls in
    check(c.holdSeconds < 0.2 && cc.actions.isEmpty, "no hold, no radio changes")
}

// G — hold limit: a pathological 10 s single-probe plan.
Preferences.settleProbeDelays = [10.0]
scenario("G: hold limit with a 10 s settle plan", fix: true, initial: .docked, wifi: false, bt: true) { c in
    c.event(.ambiguousUndocked); wait(0.5); c.willSleep(); wait(9.5)
} _: { c, ls in
    check(idx(ls, "WARNING: No dock verdict within 8.0s") != nil, "watchdog released the hold")
    check(c.holdSeconds >= 8.0 && c.holdSeconds < 9.0, "held ~8 s (\(c.holdSeconds.fixed(2))s), inside the 15 s ack cap")
}
Preferences.resetSettleProbeDelaysToDefaults()

// H — monitoring stopped while a sleep is held.
scenario("H: stopListening during a hold", fix: true, initial: .docked, wifi: false, bt: true) { c in
    c.event(.ambiguousUndocked); wait(0.5); c.willSleep(); wait(0.3); c.stop(); wait(0.5)
} _: { c, ls in
    check(idx(ls, "Releasing held sleep handling (monitoring stopped)") != nil, "hold released on stop")
    check(c.holdSeconds < 0.6, "released promptly (\(c.holdSeconds.fixed(2))s)")
}

// I / J — a dock verdict lands while the wake-time re-check is in flight.
scenario("I: undock+sleep, UNDOCKED verdict during the wake re-check", fix: true, initial: .docked, wifi: false, bt: true) { c in
    c.event(.undocked); wait(1.0); c.willSleep(); wait(4)
    c.didWake(); c.logic.receiveDockStatusChanged(isDocked: false, timestamp: Date()); wait(4)
} _: { c, ls in
    check(idx(ls, "answers the pending wake-time re-check") != nil, "verdict answered the re-check")
    check(idx(ls, "Still undocked at wake (Thunderbolt verdict)") != nil, "restore ran on the verdict's answer")
    check(idx(ls, "Discarding wake-time dock re-check result") != nil, "late Heuristics result discarded")
    check(cc.wifi && !cc.bt, "Wi-Fi restored, BT off")
    check(cc.actions == ["disableBluetooth@awake", "enableWiFi@awake"], "no duplicate toggles (\(cc.actions))")
}
scenario("J: undock+sleep, DOCKED verdict during the wake re-check", fix: true, initial: .docked, wifi: false, bt: true) { c in
    c.event(.undocked); wait(1.0); c.willSleep(); wait(4)
    HarnessWorld.set(.docked)
    c.didWake(); c.logic.receiveDockStatusChanged(isDocked: true, timestamp: Date()); wait(4)
} _: { c, ls in
    check(idx(ls, "Re-docked while asleep (Thunderbolt verdict)") != nil, "verdict applied the re-dock")
    check(!cc.actions.contains("enableWiFi@awake"), "Wi-Fi NOT restored on a docked machine")
    check(!cc.wifi && cc.bt, "ends docked-correct")
}

// K — slept undocked, re-docked while asleep, with "Toggle Wi-Fi" OFF: the dock toggles
// don't manage Wi-Fi, so the Wi-Fi turned off for sleep must still be restored at wake.
// (The docked verdict lands mid-sleep here by design, so ASLEEP actions are expected.)
Preferences.toggleWiFiOnDockEvent = false
scenario("K: sleep undocked, re-dock while asleep, Toggle Wi-Fi OFF", fix: true, initial: .undocked, wifi: true, bt: false) { c in
    c.willSleep(); wait(1); c.event(.docked); wait(4); c.didWake(); wait(1.5)
} _: { c, ls in
    check(idx(ls, "Skipping wake handling (laptop is docked)") != nil, "woke docked")
    check(idx(ls, "Restoring Wi-Fi on wake") != nil, "Wi-Fi restored (not managed by the dock toggles)")
    check(cc.wifi && cc.bt, "ends Wi-Fi on (user's), BT on (docked)")
}
Preferences.toggleWiFiOnDockEvent = true
scenario("K2: same, Toggle Wi-Fi ON (dock toggles own Wi-Fi)", fix: true, initial: .undocked, wifi: true, bt: false) { c in
    c.willSleep(); wait(1); c.event(.docked); wait(4); c.didWake(); wait(1.5)
} _: { c, ls in
    check(idx(ls, "Restoring Wi-Fi on wake") == nil, "Wi-Fi NOT restored while docked")
    check(!cc.wifi && cc.bt, "ends docked-correct (Wi-Fi off, BT on)")
}

// L — docked, Wi-Fi switched back on by hand, then "Toggle Bluetooth" switched off and on:
// only Bluetooth's own dock toggle may be applied; the user's Wi-Fi must be left alone.
scenario("L: pref change while docked touches only its own radio", fix: true, initial: .docked, wifi: false, bt: true) { c in
    cc.reset(wifi: true, bt: false)    // after the launch sync: user turned Wi-Fi on, BT off
    Preferences.toggleBluetoothOnDockEvent = false; wait(0.5)
    Preferences.toggleBluetoothOnDockEvent = true; wait(0.5)
} _: { c, ls in
    check(cc.actions == ["enableBluetooth@awake"], "only Bluetooth enabled; Wi-Fi left on (\(cc.actions))")
    check(cc.wifi && cc.bt, "ends Wi-Fi on (user's), BT on")
}

print("\n\(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")")
exit(failures == 0 ? 0 : 1)
}
Thread { runAll() }.start()
while true { RunLoop.main.run(mode: .default, before: .distantFuture) }
