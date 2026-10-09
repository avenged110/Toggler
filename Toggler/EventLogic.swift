// MARK: – EventLogic.swift
// Copyright © 2025 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Receives system events from monitors and toggles hardware interfaces in
// accordance with user preferences.
//
// Dock and sleep/wake events arrive via direct callbacks (wired in AppDelegate),
// eliminating the NotificationCenter broadcast path for those channels and
// making the data flow explicit and type-safe. Preference-change events
// continue to use NotificationCenter because Preferences is a static struct
// with no instance identity from which to call a direct method.

import Foundation

// @unchecked Sendable: All mutable state (wasWiFiEnabledBeforeSleep,
// wasBTEnabledBeforeSleep, cachedDockState, undockIntent, undockIntentTimer)
// is accessed exclusively on the serial logicQueue. Post-init the two
// DispatchQueues and ConnectivityController are effectively immutable.
// These invariants are enforced manually; @unchecked Sendable informs the
// compiler of this without requiring full actor isolation.
final class EventLogic: Loggable, @unchecked Sendable {
    nonisolated static let logTag = "[EventLogic]"

    // Internal serial queue — owns event logic, state updates, and timers.
    // Use .utility as this work is system/IO-related and not interactive.
    private let logicQueue = DispatchQueue(label: "com.toggler.eventLogic", qos: .utility)

    // Action queue — dedicated serial queue to perform hardware toggles.
    // Keeps potentially blocking operations (verification loops, usleep) off the logicQueue.
    private let actionQueue = DispatchQueue(label: "com.toggler.eventLogic.actions", qos: .utility)

    // Controller
    private let cc = ConnectivityController.shared

    // Class-wide cached state variables (internal bookkeeping; accessed on logicQueue)
    private var wasWiFiEnabledBeforeSleep: Bool = false
    private var wasBTEnabledBeforeSleep: Bool = false
    private var cachedDockState: Bool = false
    // False until MonitorDock's first verdict (the launch-time settle sequence) arrives.
    // That first verdict is always applied, so launch syncs the radios to the dock state;
    // every later verdict is applied only if it differs from cachedDockState.
    private var hasReceivedDockState: Bool = false

    // Track undock intent
    private enum DockIntent { case undock }
    private var undockIntent: DockIntent? = nil
    private var undockIntentTimer: DispatchWorkItem? = nil
    private var undockIntentDebounceWindow: TimeInterval { Preferences.undockIntentDebounceWindow }

    // The async wake-time dock re-check in flight, if any (see recheckDockAtWake).
    // Heuristics.evaluateDockWithRefresh is asynchronous, so a genuine new event can run
    // on logicQueue before its completion is delivered:
    //   • a dock verdict ANSWERS the re-check — it is the fresher measurement, so it is
    //     handed to 'resolve' in place of the re-check's own result (see
    //     receiveDockStatusChanged);
    //   • a new sleep cycle drops it (invalidatePendingWakeCheck()).
    // The token then makes the late completion a no-op, mirroring the sequence-token
    // pattern MonitorDock uses. Accessed exclusively on logicQueue.
    private struct PendingWakeCheck {
        let token: UUID
        let resolve: @Sendable (_ isDocked: Bool, _ basis: String) -> Void }
    private var pendingWakeCheck: PendingWakeCheck? = nil

    // Set when the sleep handler applied a pending undock's toggles itself (see
    // handleSleepEvent). The next wake re-checks the dock before restoring anything, in
    // case the machine was re-docked while asleep. Accessed exclusively on logicQueue.
    private var undockAppliedAtSleep: Bool = false

    // Invalidates any in-flight wake-time dock re-check. Must be called on logicQueue
    // whenever a genuine, newer event (a real dock/undock callback or a new sleep
    // cycle) makes a previously-scheduled wake-time re-check's eventual answer stale.
    private func invalidatePendingWakeCheck() {
        guard pendingWakeCheck != nil else { return }
        log("Invalidating pending wake-time dock re-check (superseded by a newer event).")
        pendingWakeCheck = nil }

    // Local keys for preference-change routing
    // Use canonical preference key strings exported by Preferences to avoid mismatch.
    private enum PrefKey {
        static let toggleWiFiOnDockEvent = Preferences.toggleWiFiOnDockEventKey
        static let toggleBluetoothOnDockEvent = Preferences.toggleBluetoothOnDockEventKey }

    // MARK: – Initialization
    init() {
        // Only the preferences-changed channel uses NotificationCenter; dock and
        // sleep/wake events arrive via direct callbacks (see receiveDockStatusChanged,
        // receiveSystemWillSleep, receiveSystemDidWake).
        NotificationCenter.default.addObserver(self,
            selector: #selector(handleExternalNotification(_:)),
            name: .togglerPreferencesChanged, object: nil) }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: – Shared toggle helper
    // Executes the undock toggles (enable Wi-Fi / disable Bluetooth) using a
    // freshly-obtained cached snapshot and the current preference values.
    // Must be called on logicQueue. Dispatches hardware work onto actionQueue.
    private func executeUndockToggles() {
        let snap     = cc.cachedStateSnapshot()
        let wifiPref = Preferences.toggleWiFiOnDockEvent
        let btPref   = Preferences.toggleBluetoothOnDockEvent

        if wifiPref {
            if !snap.wifi {
                log("Undocked: enabling Wi-Fi (per preference).")
                actionQueue.async { [weak self] in self?.cc.enableWiFi() }
            } else { log("Undocked: Wi-Fi already enabled — skipping.") } }

        if btPref {
            if snap.bluetooth {
                log("Undocked: disabling Bluetooth (per preference).")
                actionQueue.async { [weak self] in self?.cc.disableBluetooth() }
            } else { log("Undocked: Bluetooth already disabled — skipping.") } } }

    // MARK: – Dock events
    // Handles dock and undock events, applying user preferences to appropriately
    // toggle hardware interfaces. Expected to run on logicQueue.
    //
    // 'onlyKey' restricts the pass to the radio of that one dock preference (the
    // preference-change reconcile): the other radio is left as the user has it, rather than
    // having its dock toggle re-applied because an unrelated preference changed.
    private func handleDockEvent(onlyKey: String? = nil) {
        // Read preferences and cached dock state.
        let wifiPref  = Preferences.toggleWiFiOnDockEvent && (onlyKey ?? PrefKey.toggleWiFiOnDockEvent) == PrefKey.toggleWiFiOnDockEvent
        let btPref    = Preferences.toggleBluetoothOnDockEvent && (onlyKey ?? PrefKey.toggleBluetoothOnDockEvent) == PrefKey.toggleBluetoothOnDockEvent
        let dockState = self.cachedDockState

        log("handleDockEvent(isDocked: \(dockState)) • prefs { Wi-Fi: \(wifiPref), BT: \(btPref) }")

        // If neither toggle is enabled, nothing to do.
        guard wifiPref || btPref else {
            log("No dock-affecting preferences enabled; nothing to do.")
            return }

        // Use cached snapshot
        let snapshot = cc.cachedStateSnapshot()

        if dockState {
            // Docked path → immediate toggles; Cancel any pending undock intent.
            undockIntent = nil
            undockIntentTimer?.cancel()
            undockIntentTimer = nil

            // Wi-Fi: Disable if preference is enabled and Wi-Fi is currently on.
            if wifiPref {
                if snapshot.wifi {
                    log("Docked: Disabling Wi-Fi (by preference).")
                    actionQueue.async { [weak self] in self?.cc.disableWiFi() }
                } else { log("Docked: Wi-Fi already disabled — skipping call.") } }

            // Bluetooth: Enable if preference is enabled and Bluetooth is currently off.
            if btPref {
                if !snapshot.bluetooth {
                    log("Docked: Enabling Bluetooth (by preference).")
                    actionQueue.async { [weak self] in self?.cc.enableBluetooth() }
                } else { log("Docked: Bluetooth already enabled — skipping call.") } }
        } else {
            // Undocked path → defer toggles briefly (debounce).
            undockIntent = .undock
            undockIntentTimer?.cancel()

            // Create work item that will perform the toggles after debounce window.
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                // Confirm the intent is still valid (that it wasn't re-docked).
                guard self.undockIntent == .undock else { return }
                log("Undock intent timer fired → executing undock toggles now.")
                // The cache was last refreshed when the verdict arrived, a debounce window
                // ago; a radio switched by hand since then would otherwise be skipped as
                // "already" in its undocked state (or toggled needlessly).
                self.cc.refreshCachedStateSync()
                self.executeUndockToggles()

                // Clear intent and timer references.
                self.undockIntent = nil
                self.undockIntentTimer = nil }

            undockIntentTimer = work
            // Schedule the work on the logicQueue (keeping intent/timer
            // access serialized there).
            self.logicQueue.asyncAfter(deadline: .now() + self.undockIntentDebounceWindow, execute: work) } }

    // MARK: – Sleep events
    // Handles system sleep events (when undocked) by applying user preferences.
    //
    // 'done' is called exactly once, when every radio operation started here has finished
    // its verification (or immediately, if none was started). MonitorSleep withholds the
    // system's sleep acknowledgment until then, so the radios are confirmed off before
    // the machine actually sleeps rather than racing it.
    private func handleSleepEvent(done: @escaping @Sendable () -> Void) {
        let group = DispatchGroup()
        defer { group.notify(queue: logicQueue) { done() } }

        let disableWiFiDuringSleep = Preferences.disableWiFiDuringSleep
        let disableBluetoothDuringSleep = Preferences.disableBluetoothDuringSleep

        // If docked, do nothing (no toggling)
        guard !self.cachedDockState else {
            log("Skipping sleep handling (laptop is docked)")
            // A dock verdict delivered just before sleep (MonitorDock resolves a pending one
            // before handing the sleep on) may have queued its toggles on actionQueue. Hold
            // the acknowledgment until they have run, so they take effect before the machine
            // sleeps rather than after it. actionQueue is serial, so this empty block finishes
            // only after anything queued ahead of it; with nothing queued, immediately.
            group.enter()
            actionQueue.async { group.leave() }
            return }

        // Use cached snapshot for interface states.
        let snap = cc.cachedStateSnapshot()

        // The state each radio should be in while the machine is awake. Normally that is
        // simply its current state.
        var wifiAwake = snap.wifi
        var btAwake   = snap.bluetooth

        // Special handling: an undock whose toggles are still waiting out the debounce
        // window. A closed-clamshell Mac sleeps the moment it is undocked, so this is the
        // common case, not a corner. The toggles are applied here, together with the
        // sleep toggles and inside the held sleep acknowledgment, so the machine sleeps —
        // and wakes — in its undocked state: Bluetooth already off, Wi-Fi off for sleep and
        // recorded for restore.
        //
        // This used to skip every toggle and carry the intent across the sleep for the wake
        // handler to execute. That left Bluetooth on through the sleep and delayed the undock
        // toggles until after the user had opened the lid. It only appeared to work while
        // dock verdicts were slow enough to land after willSleep, when the debounce timer
        // happened to fire in the moments before the machine actually slept.
        //
        // The debounce timer is canceled rather than left to fire across the sleep window
        // (where cachedDockState is stale by definition). The re-dock safety net it provided
        // moves to the wake handler: 'undockAppliedAtSleep' makes it re-check the dock
        // before restoring anything.
        if undockIntent == .undock {
            undockIntentTimer?.cancel()
            undockIntentTimer = nil
            undockIntent = nil
            undockAppliedAtSleep = true
            if Preferences.toggleWiFiOnDockEvent { wifiAwake = true }
            if Preferences.toggleBluetoothOnDockEvent { btAwake = false }
            log("Undock pending at sleep → applying undock toggles with the sleep toggles (awake state: Wi-Fi \(wifiAwake), BT \(btAwake)).") }

        // Record the awake state so the wake handler can restore it — but only for
        // interfaces whose sleep-disable preference is currently on. If a pref is off, zero
        // the snapshot explicitly so that any stale 'true' value left by a prior sleep cycle
        // (when the pref was on) cannot trigger a spurious restore at the next wake if the
        // pref was re-enabled in between.
        self.wasWiFiEnabledBeforeSleep = disableWiFiDuringSleep ? wifiAwake : false
        self.wasBTEnabledBeforeSleep   = disableBluetoothDuringSleep ? btAwake : false
        if disableWiFiDuringSleep { log("Recorded wasWiFiEnabledBeforeSleep=\(self.wasWiFiEnabledBeforeSleep)") }
        if disableBluetoothDuringSleep { log("Recorded wasBTEnabledBeforeSleep=\(self.wasBTEnabledBeforeSleep)") }

        // Wi-Fi: off for sleep if the preference allows; otherwise brought to its awake state
        // (which differs from the current one only when an undock was just applied).
        if disableWiFiDuringSleep {
            if snap.wifi {
                log("Disabling Wi-Fi on sleep (pref=on)")
                group.enter()
                disableForSleep(name: "Wi-Fi", operation: { [cc] in cc.disableWiFi(completion: $0) }) {
                    group.leave() }
            } else { log("Wi-Fi already disabled at sleep, recorded state for wake.") }
        } else if wifiAwake != snap.wifi {
            log("Undocked: enabling Wi-Fi before sleep (per preference; sleep pref=off).")
            group.enter()
            actionQueue.async { [cc] in cc.enableWiFi { _ in group.leave() } }
        } else { log("Leaving Wi-Fi state unchanged on sleep (pref=off)") }

        // Bluetooth: the same, with the undocked state being off.
        if disableBluetoothDuringSleep || btAwake != snap.bluetooth {
            if snap.bluetooth {
                log(disableBluetoothDuringSleep ? "Disabling Bluetooth on sleep (pref=on)"
                                                : "Undocked: disabling Bluetooth before sleep (per preference; sleep pref=off).")
                group.enter()
                disableForSleep(name: "Bluetooth", operation: { [cc] in cc.disableBluetooth(completion: $0) }) {
                    group.leave() }
            } else { log("Bluetooth already disabled at sleep, recorded state for wake.") }
        } else { log("Leaving Bluetooth state unchanged on sleep (pref=off)") } }

    // Runs a pre-sleep disable on actionQueue, retrying exactly once if verification does
    // not confirm the radio off. 'finished' is called once, after the first success or the
    // retry's result. Both attempts together stay inside MonitorSleep.sleepAckTimeout, which
    // remains the hard cap: if the work overruns it, sleep proceeds anyway.
    private func disableForSleep(name: String,
                                 operation: @escaping @Sendable (@escaping ConnectivityController.RadioCompletion) -> Void,
                                 finished: @escaping @Sendable () -> Void) {
        actionQueue.async { [actionQueue] in
            operation { verified in
                if verified { finished(); return }
                Self.log("\(name) not confirmed off before sleep — retrying once.")
                actionQueue.async {
                    operation { retryVerified in
                        Self.log(retryVerified
                            ? "\(name) confirmed off on retry."
                            : "WARNING: \(name) could not be confirmed off before sleep (after retry).")
                        finished() } } } } }

    // MARK: – Wake events
    // Handle system wake events (when undocked) by applying user preference
    // and pre-sleep states.
    private func handleWakeEvent() {
        // Consumed by this wake whichever branch runs.
        let recheckBeforeRestore = self.undockAppliedAtSleep
        self.undockAppliedAtSleep = false

        // If docked, the dock toggles own the radios; restore only what they do not manage.
        guard !self.cachedDockState else {
            log("Skipping wake handling (laptop is docked)")
            restoreRadiosNotManagedByDock()
            return }

        // If an undock intent is still pending, re-verify the physical dock state
        // before executing undock-specific toggles. (The sleep handler now applies an
        // intent pending at sleep itself, so this is reached only when an undock verdict
        // arrived after willSleep and its debounce had not yet fired by wake.)
        //
        // cachedDockState passed the guard above (it is false), but it is the
        // EventLogic-local copy maintained exclusively by dock-event callbacks, so it
        // can be stale across a sleep: if the user physically re-docked the laptop while
        // it slept and the Thunderbolt events have not produced a verdict yet, it still
        // reads false. Executing undock toggles on a docked laptop would incorrectly
        // enable Wi-Fi and disable Bluetooth.
        //
        // Heuristics.evaluateDockWithRefresh (rather than the synchronous/cached
        // evaluator) is used deliberately: Thunderbolt, wall power, and external
        // display are all queried live either way, but Ethernet presence is backed
        // by a cache (ethernetPresentCache) that is only ever refreshed as a
        // side effect of a Thunderbolt-triggered settle sequence in MonitorDock.
        // evaluateDockWithRefresh explicitly refreshes the Ethernet cache first,
        // so this call is the authoritative, fully-fresh dock determination.
        if undockIntent == .undock {
            // Cancel the pending debounce timer — it must not fire after wake.
            undockIntentTimer?.cancel()
            undockIntentTimer = nil
            undockIntent = nil
            log("Undock intent pending at wake — scheduling fresh (Ethernet-refreshed) dock re-check.")
            recheckDockAtWake { [weak self] isDocked, basis in
                self?.finishHandlingUndockIntentAtWake(isDocked: isDocked, basis: basis) }
            return }

        // The sleep handler applied an undock moments before sleep. Its restore (Wi-Fi back
        // on) assumes the machine is still undocked, so confirm that first — the same
        // re-dock safety net the pending-intent path above provides.
        if recheckBeforeRestore {
            log("Undock was applied at sleep — re-checking the dock before restoring.")
            recheckDockAtWake { [weak self] isDocked, basis in
                guard let self else { return }
                if isDocked { self.applyRedockAtWake(basis: basis) }
                else {
                    log("Still undocked at wake (\(basis)) → restoring.")
                    self.restoreRadiosAfterSleep() } }
            return }

        restoreRadiosAfterSleep() }

    // Restores whatever the sleep handler turned off, per the records it left. Must be
    // called on logicQueue.
    private func restoreRadiosAfterSleep() {
        let disableWiFiDuringSleep = Preferences.disableWiFiDuringSleep
        let disableBluetoothDuringSleep = Preferences.disableBluetoothDuringSleep

        // Restore Wi-Fi if Preference allows and it was enabled before sleep.
        if disableWiFiDuringSleep && self.wasWiFiEnabledBeforeSleep {
            log("Restoring Wi-Fi on wake (pref=on, wasWiFiBeforeSleep=true)")
            actionQueue.async { [weak self] in self?.cc.enableWiFi() }
        } else { log("Not restoring Wi-Fi on wake (pref=\(disableWiFiDuringSleep), wasWiFiBeforeSleep=\(self.wasWiFiEnabledBeforeSleep))") }

        // Restore Bluetooth if Preference allows and it was enabled before sleep.
        if disableBluetoothDuringSleep && self.wasBTEnabledBeforeSleep {
            log("Restoring Bluetooth on wake (pref=on, wasBTBeforeSleep=true)")
            actionQueue.async { [weak self] in self?.cc.enableBluetooth() }
        } else {
            log("Not restoring Bluetooth on wake (pref=\(disableBluetoothDuringSleep), wasBTEnabledBeforeSleep=\(self.wasBTEnabledBeforeSleep))") }

        // Unconditionally clear pre-sleep snapshots once wake handling is complete.
        // This must happen regardless of which restore branches were taken, ensuring
        // a subsequent spurious wake event cannot trigger a second restoration attempt.
        self.wasWiFiEnabledBeforeSleep = false
        self.wasBTEnabledBeforeSleep = false }

    // Runs a fresh (Ethernet-refreshed) dock evaluation at wake and hands its result to
    // 'resolve' on logicQueue — or, if a dock verdict arrives first, that verdict instead.
    // 'basis' names which of the two answered, for the log.
    //
    // evaluateDockWithRefresh delivers its completion on Heuristics' internal scoringQueue,
    // not logicQueue, so the completion body must not touch any EventLogic mutable state
    // directly. It is re-serialized onto logicQueue immediately and guarded with a token
    // (see pendingWakeCheck).
    private func recheckDockAtWake(resolve: @escaping @Sendable (_ isDocked: Bool, _ basis: String) -> Void) {
        let token = UUID()
        self.pendingWakeCheck = PendingWakeCheck(token: token, resolve: resolve)
        Heuristics.evaluateDockWithRefresh(threshold: Preferences.heuristicsThreshold) { [weak self] isDocked, score, _ in
            guard let self = self else { return }
            self.logicQueue.async { [weak self] in
                guard let self = self else { return }
                guard let pending = self.pendingWakeCheck, pending.token == token else {
                    self.log("Discarding wake-time dock re-check result (superseded before completion).")
                    return }
                self.pendingWakeCheck = nil
                pending.resolve(isDocked, "Heuristics score=\(score)") } } }

    // The machine was re-docked while asleep. Bring cachedDockState in sync, clear stale
    // snapshots, and apply the docked toggles here rather than waiting for MonitorDock:
    // dock verdicts are applied only when they CHANGE cachedDockState, so the docked
    // verdict MonitorDock delivers after re-enumeration would be skipped as a no-op once
    // this has set cachedDockState = true. handleDockEvent skips any toggle the snapshot
    // shows already applied, so it is safe to run twice. Must be called on logicQueue.
    private func applyRedockAtWake(basis: String) {
        log("Re-docked while asleep (\(basis)); applying docked state.")
        self.cachedDockState = true
        restoreRadiosNotManagedByDock()
        self.handleDockEvent() }

    // Woke docked after sleeping undocked. A radio whose dock toggle is on is set by the
    // docked toggles, so its pre-sleep record is simply dropped. A radio whose dock toggle
    // is OFF is not Toggler's to manage while docked — but the sleep handler still turned it
    // off, so it is restored as on any other wake. Previously both records were dropped, and
    // with "Toggle Wi-Fi" off a Wi-Fi turned off for sleep stayed off after re-docking.
    // Must be called on logicQueue; clears both records.
    private func restoreRadiosNotManagedByDock() {
        if Preferences.toggleWiFiOnDockEvent { self.wasWiFiEnabledBeforeSleep = false }
        if Preferences.toggleBluetoothOnDockEvent { self.wasBTEnabledBeforeSleep = false }
        restoreRadiosAfterSleep() }

    // Completes the wake-time undock-intent re-check started in handleWakeEvent()
    // once Heuristics.evaluateDockWithRefresh's completion has been delivered.
    // Must be called on logicQueue, via recheckDockAtWake's 'resolve'.
    private func finishHandlingUndockIntentAtWake(isDocked: Bool, basis: String) {
        if isDocked {
            log("Undock intent canceled at wake.")
            applyRedockAtWake(basis: basis)
            return }

        // Machine is still undocked — execute toggles directly (not via
        // handleDockEvent, which would re-read cachedDockState and could apply
        // the wrong branch if state changed between the check and the call).
        log("Handling undock intent at wake → executing undock toggles directly (\(basis)).")
        executeUndockToggles()

        // The undock toggles take precedence over the restore, but only for the radios they
        // manage; a radio whose dock toggle is off is restored as on any other wake (the same
        // rule as restoreRadiosNotManagedByDock). Previously both records were dropped, so
        // with "Toggle Wi-Fi" off a Wi-Fi turned off for sleep stayed off. Clears both.
        restoreRadiosNotManagedByDock() }

    // MARK: – Direct callback entry points
    // These methods are called by MonitorDock and MonitorSleep via the closures
    // wired in AppDelegate. They are the typed, direct replacements for the
    // NotificationCenter broadcast paths that previously handled dock/sleep/wake events.
    //
    // Each method is nonisolated and immediately re-serializes onto logicQueue,
    // preserving the same queue-discipline as the old notification handler.
    // The callbacks arrive on dockMonQueue / sleepMonQueue respectively, so
    // logicQueue.async is the correct hop — not a sync, which would risk deadlock
    // if logicQueue were blocked.

    // Called by MonitorDock on dockMonQueue when a final dock determination is made.
    nonisolated func receiveDockStatusChanged(isDocked: Bool, timestamp: Date) {
        logicQueue.async { [weak self] in
            guard let self = self else { return }
            // Act only on a genuine state change. MonitorDock runs a settle sequence for
            // EVERY Thunderbolt connect/disconnect — a drive plugged into the dock, a
            // cable reseated — and each one ends in a verdict. Re-applying the toggles on an
            // unchanged verdict would undo manual changes (e.g. Wi-Fi switched back on while
            // docked would be switched off again by an unrelated Thunderbolt event).
            //
            // A wake-time dock re-check in flight is answered by this verdict, whether or not
            // it changes the state: handleWakeEvent has already consumed the undock intent (or
            // deferred the restore) pending that answer, and this is the fresher one. It used
            // to be treated as a plain dock event instead, which canceled the re-check and
            // with it the deferred restore — a radio turned off for sleep stayed off.
            if let pending = self.pendingWakeCheck {
                self.pendingWakeCheck = nil
                self.hasReceivedDockState = true
                self.cc.refreshCachedStateSync()
                self.cachedDockState = isDocked
                log("cachedDockState -> \(isDocked) @ \(timestamp) (answers the pending wake-time re-check)")
                pending.resolve(isDocked, "Thunderbolt verdict")
                return }

            // Always acted on: the first verdict (launch-time sync, deliberately preserved).
            let changed = !self.hasReceivedDockState || isDocked != self.cachedDockState
            guard changed else {
                log("Dock verdict unchanged (isDocked=\(isDocked)) @ \(timestamp) — no action.")
                return }
            self.hasReceivedDockState = true

            // Synchronous refresh: blocks logicQueue until the cache reflects the
            // current hardware state, so the snapshot read inside handleDockEvent
            // is guaranteed to be fresh rather than pre-event stale values.
            self.cc.refreshCachedStateSync()
            self.cachedDockState = isDocked

            log("cachedDockState -> \(isDocked) @ \(timestamp)")

            // Use fresh system snapshot inside handleDockEvent.
            self.handleDockEvent() } }

    // Called by MonitorSleep on sleepMonQueue when the system is about to sleep.
    // 'done' releases the held sleep acknowledgment; see handleSleepEvent.
    nonisolated func receiveSystemWillSleep(done: @escaping @Sendable () -> Void) {
        logicQueue.async { [weak self] in
            guard let self = self else { done(); return }
            // Synchronous refresh: guarantees the pre-sleep snapshot operates
            // on current hardware state, not stale values.
            self.cc.refreshCachedStateSync()
            self.invalidatePendingWakeCheck()
            log("Handling sleep event")
            self.handleSleepEvent(done: done) } }

    // Called by MonitorSleep on sleepMonQueue when the system has awakened.
    nonisolated func receiveSystemDidWake() {
        logicQueue.async { [weak self] in
            guard let self = self else { return }
            // Synchronous refresh: guarantees wake restore logic operates on
            // current hardware state, not stale values.
            self.cc.refreshCachedStateSync()
            log("Handling wake event")
            self.handleWakeEvent() } }

    // MARK: – Notification branch handler (preferences only)
    // nonisolated: NotificationCenter delivers selector-based callbacks on the posting
    // thread (main or a background thread). Marking the method nonisolated makes the
    // isolation boundary explicit — all mutable state access is immediately serialized
    // onto logicQueue, satisfying strict concurrency without requiring @MainActor.
    @objc nonisolated func handleExternalNotification(_ note: Notification) {
        // This handler now exclusively serves the .togglerPreferencesChanged channel.
        // Dock and sleep/wake events are delivered via direct callbacks instead.
        guard note.name == .togglerPreferencesChanged else {
            log("Ignoring unhandled notification: \(note.name.rawValue)")
            return }

        let changedKey = (note.userInfo?["key"] as? String) ?? ""
        guard changedKey == PrefKey.toggleWiFiOnDockEvent ||
              changedKey == PrefKey.toggleBluetoothOnDockEvent else {
            log("Ignoring preference change for key '\(changedKey)' (not dock-affecting)")
            return }

        // Serialize onto EventLogic's queue.
        logicQueue.async { [weak self] in
            guard let self = self else { return }
            // Synchronous refresh, for the same reason as the three event entry points
            // above. This branch can call handleDockEvent(), which reads
            // cc.cachedStateSnapshot() and skips any toggle it believes is already
            // applied — so a stale cache silently turns the reconcile into a no-op.
            // Concretely: docked, user re-enables Wi-Fi by hand, then switches this
            // preference on. The cache still holds wifi=false from the dock event, so
            // handleDockEvent logs "Wi-Fi already disabled — skipping call" and the
            // preference the user just enabled does nothing until the next dock or sleep
            // event. (An earlier comment here asserted this branch never touches the
            // hardware cache; it does, by way of handleDockEvent.)
            self.cc.refreshCachedStateSync()

            let wifiPref  = Preferences.toggleWiFiOnDockEvent
            let btPref    = Preferences.toggleBluetoothOnDockEvent
            let dockState = self.cachedDockState

            log("Reconciling preference change: \(changedKey) (Wi-Fi: \(wifiPref), BT: \(btPref), docked: \(dockState))")

            // Only a preference that was just ENABLED while docked is applied, and only to its
            // own radio. Previously any change to either key re-ran the full docked toggles:
            // switching "Toggle Bluetooth" off (or BTPermController forcing it off) turned off
            // a Wi-Fi the user had switched back on by hand while docked.
            let enabled = changedKey == PrefKey.toggleWiFiOnDockEvent ? wifiPref : btPref
            if dockState && enabled {
                log("Preference change enables dock behavior while already docked → applying it to that radio")
                self.handleDockEvent(onlyKey: changedKey) } } }
}
