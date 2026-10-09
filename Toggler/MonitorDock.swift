// MARK: – MonitorDock.swift
// Copyright © 2025 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Listens for Thunderbolt device connection events using IOKit.
// When detected, run a short settling probe sequence to compute a dock event
// confidence determination, then deliver a single "final" status to the
// registered onDockStatusChanged callback.

import Foundation
import IOKit
import IOKit.usb
import Darwin
import CoreGraphics

// SendableBox<T> is defined in Utilities.swift and shared by this file and
// MonitorSleep.swift. It wraps CF/C reference types for safe capture across
// @Sendable closure boundaries.

// @unchecked Sendable: All mutable state (isRunning, currentSequenceToken,
// sequenceAccepted, sequenceConsecutiveCount, lastSequenceStart, and all
// thunderbolt* IOKit handles) is accessed exclusively on the serial dockMonQueue,
// with the sole exception of the thunderbolt* IOKit handles and isRunning during
// the startup/teardown paths, which are guarded by explicit main-thread dispatch
// and the isRunning flag. Post-init the dockMonQueue is effectively immutable.
// onDockStatusChanged is written once from AppDelegate before the monitor starts
// and is thereafter treated as read-only on dockMonQueue.
// These invariants are enforced manually; @unchecked Sendable informs the
// compiler of this without requiring full actor isolation.
// @safe: the IOKit port/refcon storage is private and every use of it is marked 'unsafe'
// at the point of use; nothing unsafe crosses this type's interface.
@safe final class MonitorDock: Loggable, @unchecked Sendable {
    nonisolated static let logTag = "[DockMon]"

    // MARK: - Configuration
    // Tiny debounce to avoid reacting to microbursts of identical IOKit callbacks.
    // Keep small so legitimate dock/undock transitions still start new sequences.
    // 'static let' — this is a fixed constant; it never varies per instance and
    // does not read from Preferences, so an instance property is unnecessary.
    private static let microburstDebounceSeconds: TimeInterval = 0.12
    // Delay, after a settle sequence delivers its verdict, before one confirmation
    // sequence re-measures the dock state. The settle plan ends ~3 s after the event,
    // which is before a dock's Ethernet link and external display have come up; the
    // verdict then rests on Thunderbolt and wall power alone. Re-measuring once the
    // slower signals are present means a single missing signal at the moment of the
    // event can no longer leave the wrong state standing until the next Thunderbolt
    // event. EventLogic acts only on a verdict that differs from its current state, so
    // a confirmation that agrees is a no-op.
    private static let confirmationDelaySeconds: TimeInterval = 10.0
    // Fast-path reads, relative to the Thunderbolt event, that run ahead of the settle
    // plan. A learned dock (Preferences.knownDocks) that is present on any read is
    // accepted at once. The learned dock being gone is accepted only when both reads
    // agree, so a momentary drop during re-enumeration cannot undock on its own. Either
    // way the regular settle plan is the fallback, and the confirmation pass still runs.
    private static let fastPathDelays: [TimeInterval] = [0.3, 0.8]
    // Upper bound on how long sleep handling is held for an unresolved settle sequence
    // (see resolvePendingVerdictBeforeSleep). It must leave EventLogic's own pre-sleep
    // radio work room inside MonitorSleep.sleepAckTimeout (15 s), which stays the hard cap.
    private static let sleepHoldLimitSeconds: TimeInterval = 8.0
    // Retrieve probe delay values from Preferences.
    // Preferences is a struct backed exclusively by UserDefaults, which is
    // thread-safe; reading from any queue is safe by construction.
    private var settleProbeDelays: [TimeInterval] { Preferences.settleProbeDelays }

    // Variables from Preferences (UserDefaults-backed, bounded safely there)
    private var heuristicsThreshold: Int { Preferences.heuristicsThreshold }
    private var consecutiveAcceptanceThreshold: Int { Preferences.consecutiveAcceptanceThreshold }

    // MARK: - Callback
    // Invoked on dockMonQueue when a final dock-state determination is made.
    // Set once by AppDelegate immediately after init, before the monitor starts.
    // Captured as @Sendable because dockMonQueue closures are @Sendable contexts.
    // 'var' rather than 'let' to allow AppDelegate to inject it after construction.
    var onDockStatusChanged: (@Sendable (_ isDocked: Bool, _ timestamp: Date) -> Void)?

    // MARK: - State/threading
    // Internal serial queue for monitor logic.
    // Owns all mutable state except thunderbolt* handles and isRunning during the
    // narrow startup/teardown windows documented below.
    private let dockMonQueue = DispatchQueue(label: "com.toggler.MonitorDock", qos: .userInitiated)
    // Timestamp (on dockMonQueue) of the last sequence start to filter microbursts.
    private var lastSequenceStart: Date?

    // IOKit notification objects to retain.
    // These are set once on the main thread during startup (before isRunning
    // becomes true and before dockMonQueue closures can race on them), then
    // read/nil'd on dockMonQueue during teardown. The narrow window where
    // main-thread setup code writes them is guarded by the isRunning flag and
    // the sequential nature of the dispatch chain; see startListeningForThunderboltEvents.
    private var thunderboltNotifyPort: IONotificationPortRef?
    private var thunderboltRunLoopSource: CFRunLoopSource?
    // The refCon handed to IOKit: a +1 reference to a context that holds this monitor
    // weakly. Same ownership as thunderboltNotifyPort; released on main only AFTER the
    // port is destroyed, so no callback can ever run against a freed context — and a
    // callback that lands after this monitor is gone finds nil rather than a dangling self.
    private var thunderboltCallbackContext: Unmanaged<ThunderboltCallbackContext>?
    private var thunderboltMatchIterator: io_iterator_t = 0
    private var thunderboltTermIterator: io_iterator_t = 0

    // Monitor status. Written on dockMonQueue and on the main-thread startup path
    // (guarded by the check-then-set pattern inside startListeningForThunderboltEvents).
    // Fully private: no external caller reads this flag; exposing it as private(set)
    // would allow unsynchronized reads from outside dockMonQueue.
    private var isRunning: Bool = false

    // Active settle sequence token.
    // New sequences replace the old token, canceling it.
    // Accessed exclusively on dockMonQueue.
    private var currentSequenceToken: UUID?

    // Per-sequence acceptance state. Both are reset at the top of each
    // startSettleSequence call and accessed exclusively on dockMonQueue,
    // making the ownership and queue discipline explicit rather than relying
    // on local-var capture-by-reference across asyncAfter closures.
    private var sequenceAccepted: Bool = false
    private var sequenceConsecutiveCount: Int = 0
    // Fast-path reads in the current sequence that found no external Thunderbolt device.
    private var fastPathAbsentReads: Int = 0
    // Whether the current sequence is a confirmation, and when its last probe is due.
    // Both are read only by resolvePendingVerdictBeforeSleep.
    private var sequenceIsConfirmation: Bool = false
    private var sequencePlanEnd: Date = .distantPast

    // Sleep handling held until the next verdict is delivered (or its hold limit
    // expires), keyed so the watchdog can release exactly its own entry.
    // Accessed exclusively on dockMonQueue.
    private var sleepHolds: [UUID: @Sendable () -> Void] = [:]

    // Whether the last delivered verdict was "docked" on the strength of a learned (or
    // "certain") dock. Only then may the fast path conclude an undock from the absence
    // of every external Thunderbolt device.
    // Accessed exclusively on dockMonQueue.
    private var lastVerdictViaKnownDock: Bool = false

    init() { log("Initialized") }
    deinit { stopListening() }

    // MARK: – Thunderbolt event listener
    // Creates an IONotificationPort and registers notifications on the main runloop.
    // All public state flags are still owned on dockMonQueue; actual IOKit runloop
    // operations are performed on the main thread (required by CFRunLoop/IOKit).
    func startListeningForThunderboltEvents() {
        dockMonQueue.async { [weak self] in
            guard let self = self, !self.isRunning else { return }
            // Mark running on the queue that owns the state.
            self.isRunning = true

            // Creation and runloop attachment must be done on the main thread.
            DispatchQueue.main.async { [weak self] in
                // If self was deallocated between the dockMonQueue hop and this main
                // dispatch, we must reset isRunning back to false on dockMonQueue before
                // bailing. Without this reset the monitor is permanently stuck in a
                // "running" state: startListeningForThunderboltEvents() will always
                // short-circuit at the 'guard !self.isRunning' check, and stopListening()
                // will attempt to tear down IOKit resources that were never created.
                guard let self = self else {
                    // 'self' is gone — there is no instance to reset, so no action is
                    // needed. The object is being torn down; isRunning is irrelevant.
                    // (We cannot call dockMonQueue.async here because we have no
                    // reference to dockMonQueue without self.)
                    return
                }

                // Create notify port (main thread)
                // Apple can kiss my ass; I'll use the word "master" if I damn well please.
                guard let notifyPort = unsafe IONotificationPortCreate(kIOMasterPortDefault) else {
                    log("ERROR: IONotificationPortCreate failed")
                    // Reset isRunning on dockMonQueue
                    self.dockMonQueue.async { [weak self] in self?.isRunning = false }
                    return }
                unsafe self.thunderboltNotifyPort = notifyPort
                unsafe self.thunderboltCallbackContext = unsafe Unmanaged.passRetained(ThunderboltCallbackContext(self))

                // Add run loop source to the main runloop (must be done on main)
                let rlSource = unsafe IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue()
                self.thunderboltRunLoopSource = rlSource
                CFRunLoopAddSource(CFRunLoopGetMain(), rlSource, .defaultMode)

                // Register notifications for connect/disconnect on main thread as required
                let connectOk = self.registerThunderboltNotification(connect: true)
                let termOk    = self.registerThunderboltNotification(connect: false)

                // If registration failed for either, clean up and mark stopped.
                guard connectOk && termOk else {
                    log("Failed to register all Thunderbolt notifications; cleaning up.")
                    self.cleanupIOKitResources()
                    // Ensure isRunning is cleared on dockMonQueue
                    self.dockMonQueue.async { [weak self] in self?.isRunning = false }
                    return }

                log("Started listening for Thunderbolt events (IOThunderboltPort)") } } }

    // Helper to register IOKit notifications.
    // Must be called on the main thread (this function does not dispatch).
    // Returns: 'true' on success, 'false' on failure.
    //
    // NOTE: This method reads and writes thunderbolt* ivars which are otherwise
    // owned by dockMonQueue. It is safe here because:
    //   (a) it is only ever called from the main-thread block inside
    //       startListeningForThunderboltEvents, before isRunning is confirmed true
    //       and before any dockMonQueue closure can observe these handles; and
    //   (b) the thunderboltNotifyPort written just above this call on the same
    //       main-thread execution path is the only other writer.
    // This is a deliberate, documented exception to the general dockMonQueue rule.
    private func registerThunderboltNotification(connect: Bool) -> Bool {
        // Ensure caller is on main thread (required).
        if !Thread.isMainThread {
            log("registerThunderboltNotification should be called on the main thread.")
            // Fail fast — the caller should ensure main-thread invocation.
            return false }

        guard let notifyPort = unsafe thunderboltNotifyPort else {
            log("ERROR: No notification port available for registering Thunderbolt notifications.")
            return false }

        let matchingDictName = "IOThunderboltPort"
        guard let matchingDict = unsafe IOServiceMatching(matchingDictName) else {
            log("ERROR: IOServiceMatching(\(matchingDictName)) returned nil" + (connect ? "" : "; disconnect events may not be observed"))
            return false }

        // Pass the retained callback context rather than self: the context outlives every
        // possible callback (see thunderboltCallbackContext), and reaches the monitor
        // through a weak reference. The IOKit callback always dispatches its logic work
        // to dockMonQueue before touching any mutable state, maintaining the
        // queue-ownership invariant.
        guard let context = unsafe thunderboltCallbackContext else {
            log("ERROR: No callback context available for registering Thunderbolt notifications.")
            return false }
        let contextPtr = unsafe UnsafeMutableRawPointer(context.toOpaque())

        // Define the callback used by IOServiceAddMatchingNotification.
        // The closure is a plain C function pointer; it must be @convention(c).
        // MonitorDock is @unchecked Sendable, satisfying the Sendable requirement
        // for values captured in @Sendable contexts.
        let callback: IOServiceMatchingCallback = { (refCon, iterator) in
            guard let refCon = unsafe refCon else { return }
            let context = unsafe Unmanaged<ThunderboltCallbackContext>.fromOpaque(refCon).takeUnretainedValue()
            if let monitor = context.monitor {
                monitor.handleThunderboltIterator(iterator)
            } else {
                // Monitor already gone; drain anyway so IOKit's iterator stays consistent.
                var device = IOIteratorNext(iterator)
                while device != 0 { IOObjectRelease(device); device = IOIteratorNext(iterator) } } }

        var iterator: io_iterator_t = 0
        let notificationType = connect ? kIOFirstMatchNotification : kIOTerminatedNotification

        let kr = unsafe IOServiceAddMatchingNotification(notifyPort, notificationType, matchingDict, callback, contextPtr, &iterator)
        if kr != KERN_SUCCESS {
            log("ERROR: IOServiceAddMatchingNotification (\(connect ? "first match" : "terminated")) failed with code \(kr)")
            return false }

        // Store the iterator for later cleanup.
        if connect { self.thunderboltMatchIterator = iterator } else { self.thunderboltTermIterator = iterator }
        // Drain initial iterator to arm the notification
        // (drain on whatever thread invoked this; safe).
        handleThunderboltIterator(iterator)

        return true }

    // Callback to drain the iterator and schedule an evaluation; called by IOKit.
    // nonisolated: IOKit delivers this callback on an arbitrary thread (the main
    // runloop thread in practice, since the notification port is attached there).
    // Marking nonisolated makes the isolation crossing explicit to the compiler.
    // All mutable-state access is immediately re-dispatched onto dockMonQueue.
    private nonisolated func handleThunderboltIterator(_ iterator: io_iterator_t) {
        // Drain iterator (release objects) — required pattern to arm the notification.
        // IOObjectRelease is thread-safe and does not require queue confinement.
        var device: io_object_t = IOIteratorNext(iterator)
        while device != 0 { IOObjectRelease(device); device = IOIteratorNext(iterator) }

        // Schedule evaluation on dockMonQueue, but first enforce suppression.
        dockMonQueue.async { [weak self] in
            guard let self = self else { return }
            // Microburst filtering: If a sequence was started very recently (< debounce),
            // skip starting another sequence to avoid tight repeated restarts.
            let now = Date()
            if let last = self.lastSequenceStart, now.timeIntervalSince(last) < Self.microburstDebounceSeconds {
                // Use a small local formatted string to avoid nested-paren
                // confusion in the literal.
                let elapsedStr = now.timeIntervalSince(last).fixed(3) + "s"
                Self.log("Thunderbolt event ignored due to microburst debounce (\(elapsedStr))")
                return }

            // Start (and therefore cancel any prior) settle sequence.
            self.lastSequenceStart = now
            self.startSettleSequence(trigger: "thunderboltEvent") } }

    // MARK: – Settling sequence
    // 'isConfirmation' marks the single follow-up sequence scheduled after a verdict (see
    // confirmationDelaySeconds); a confirmation does not schedule another one.
    private func startSettleSequence(trigger: String, isConfirmation: Bool = false) {
        // Cancel previous sequence by replacing the token.
        let token = UUID()
        currentSequenceToken = token

        // Reset per-sequence state for the new sequence.
        sequenceAccepted = false
        sequenceConsecutiveCount = 0
        fastPathAbsentReads = 0
        sequenceIsConfirmation = isConfirmation

        // Capture the probe plan once at sequence start so that any mid-sequence
        // preference change cannot alter the count or values being iterated, which
        // would otherwise risk the final-probe check never firing (count shrinks)
        // or firing prematurely (count grows).
        let probeDelays = settleProbeDelays
        let probeCount = probeDelays.count
        // Captured for the same reason as the probe plan above, and it must be captured
        // TOGETHER with it: Preferences clamps consecutiveAcceptanceThreshold against the
        // *live* probe count, so re-reading it per probe would let a mid-sequence edit to
        // the probe list shift the acceptance bar underneath a sequence already in flight —
        // accepting early or late against a threshold that did not exist when the sequence
        // started. One read, at the same instant as the plan it is measured against.
        let acceptanceThreshold = consecutiveAcceptanceThreshold
        sequencePlanEnd = Date() + (probeDelays.last ?? 0)

        log("Starting settle sequence (\(token.uuidString.prefix(8))) triggered by \(trigger); plan=\(probeDelays), acceptanceThreshold=\(acceptanceThreshold)")

        // A confirmation exists to re-measure with every signal, so it skips the fast path.
        if !isConfirmation { scheduleFastPath(token: token) }

        for (index, delay) in probeDelays.enumerated() {
            dockMonQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, token == self.currentSequenceToken, !self.sequenceAccepted else { return }
                let delayStr = delay.fixed(2) + "s"
                self.log("Settle probe #\(index + 1)/\(probeCount) (+\(delayStr))")

                self.sampleHeuristics(trigger: index == 0 ? "\(trigger):immediate" : "\(trigger):settle#\(index)") { [weak self] isDocked, score, thunderbolt in
                    // sampleHeuristics delivers its completion on dockMonQueue (see below).
                    guard let self = self else { return }
                    // Ensure sequence still current and not already accepted.
                    guard token == self.currentSequenceToken, !self.sequenceAccepted else { return }

                    // A device classified as a dock beyond reasonable doubt is remembered,
                    // so its next connection takes the fast path.
                    if let dock = thunderbolt.learnableDock {
                        Preferences.rememberDock(uid: dock.uid, name: dock.name) }
                    let viaKnownDock = isDocked && thunderbolt.dockClass >= .certain

                    // High-confidence shortcut. A dock classified "certain" or better is
                    // high-confidence by itself: its classification does not depend on the
                    // slower signals (Ethernet link, display) having come up yet.
                    if Self.isHighConfidence(isDocked: isDocked, score: score, viaKnownDock: viaKnownDock) {
                        self.sequenceConsecutiveCount += 1
                        let required = Self.requiredStreak(isDocked: isDocked, dockClass: thunderbolt.dockClass,
                                                           configured: acceptanceThreshold)
                        self.log("High-confidence probe accepted (isDocked=\(isDocked), score=\(score), class=\(thunderbolt.dockClass)); streak=\(self.sequenceConsecutiveCount)/\(required)")
                        if self.sequenceConsecutiveCount >= required {
                            self.log("Accepting dock state early after \(self.sequenceConsecutiveCount) consecutive high-confidence probes (isDocked=\(isDocked))")
                            self.sequenceAccepted = true
                            self.deliverDockStatus(isDocked: isDocked, timestamp: Date(), sequenceToken: token,
                                                   isConfirmation: isConfirmation, viaKnownDock: viaKnownDock)
                            return }
                    } else { self.sequenceConsecutiveCount = 0 }

                    // Failing the shortcut, accept the value of the final probe.
                    // Use the captured probeCount so the check is stable even if
                    // Preferences.settleProbeDelays changes mid-sequence.
                    if index == probeCount - 1 {
                        let finalDecision = isDocked
                        self.log("Accepting dock state at end of settle plan (isDocked=\(finalDecision))")
                        self.sequenceAccepted = true
                        self.deliverDockStatus(isDocked: finalDecision, timestamp: Date(), sequenceToken: token,
                                               isConfirmation: isConfirmation, viaKnownDock: viaKnownDock) } } } } }

    private static func isHighConfidence(isDocked: Bool, score: Int, viaKnownDock: Bool) -> Bool {
        isDocked ? (score >= 4 || viaKnownDock) : score <= 1 }

    // The acceptance ladder: the more certain the device classification, the fewer
    // agreeing probes a docked verdict needs. It never asks for more than the configured
    // threshold, which remains the floor for unclassified devices and for undocking.
    private static func requiredStreak(isDocked: Bool, dockClass: Heuristics.DockClass, configured: Int) -> Int {
        guard isDocked else { return configured }
        switch dockClass {
        case .known, .certain: return 1
        case .likely:          return min(2, configured)
        default:               return configured } }

    // MARK: – Fast path
    // Reads only the Thunderbolt topology (no Ethernet, power or display signals) and
    // settles the sequence if a learned dock decides it. See fastPathDelays.
    private func scheduleFastPath(token: UUID) {
        for delay in Self.fastPathDelays {
            dockMonQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, token == self.currentSequenceToken, !self.sequenceAccepted else { return }
                Heuristics.thunderboltSnapshotAsync { [weak self] snapshot in
                    self?.dockMonQueue.async { [weak self] in
                        guard let self, token == self.currentSequenceToken, !self.sequenceAccepted else { return }
                        self.evaluateFastPath(snapshot, token: token) } } } } }

    private func evaluateFastPath(_ snapshot: Heuristics.ThunderboltSnapshot, token: UUID) {
        if let dock = snapshot.knownDock {
            log("Fast path: recognized dock present (\(dock.name), UID \(dock.uid)) — accepting isDocked=true")
            sequenceAccepted = true
            deliverDockStatus(isDocked: true, timestamp: Date(), sequenceToken: token,
                              isConfirmation: false, viaKnownDock: true)
            return }

        guard lastVerdictViaKnownDock, snapshot.devices.isEmpty else { return }
        fastPathAbsentReads += 1
        guard fastPathAbsentReads >= Self.fastPathDelays.count else {
            log("Fast path: recognized dock absent (\(fastPathAbsentReads)/\(Self.fastPathDelays.count) reads)")
            return }
        log("Fast path: recognized dock gone on every read — accepting isDocked=false")
        sequenceAccepted = true
        deliverDockStatus(isDocked: false, timestamp: Date(), sequenceToken: token,
                          isConfirmation: false, viaKnownDock: false) }

    // sampleHeuristics dispatches to a background utility queue for the potentially
    // blocking Heuristics work, then re-delivers the completion on dockMonQueue so
    // that the caller's continuation (inside startSettleSequence) remains
    // queue-confined without an extra async hop.
    //
    // The completion is @Sendable because it crosses from Heuristics.evaluateDockWithRefresh's
    // own delivery queue (its internal scoringQueue) back onto dockMonQueue. MonitorDock is @unchecked Sendable,
    // satisfying the Sendable constraint for the [weak self] capture inside.
    private func sampleHeuristics(trigger: String,
                                  completion: @escaping @Sendable (_ isDocked: Bool, _ score: Int,
                                                                   _ thunderbolt: Heuristics.ThunderboltSnapshot) -> Void) {
        log("Heuristics sample start (trigger=\(trigger))")

        Heuristics.evaluateDockWithRefresh(threshold: heuristicsThreshold) { [weak self] isDocked, score, thunderbolt in
            guard let self = self else { return }
            // Re-dispatch onto dockMonQueue so the completion body runs under
            // the same queue isolation as the rest of the settle-sequence logic,
            // avoiding any data race on the sequence-state variables.
            self.dockMonQueue.async {
                self.log("Heuristics sample (trigger=\(trigger)) -> isDocked=\(isDocked) score=\(score)")
                completion(isDocked, score, thunderbolt) } } }

    // MARK: – Sleep
    // Called (via AppDelegate) on every willSleep, BEFORE EventLogic handles the sleep.
    // 'proceed' hands the sleep on to EventLogic and is called exactly once.
    //
    // If a settle sequence is still unresolved when sleep begins — the dock was pulled a
    // moment before the lid closed — EventLogic's dock state is stale: it would handle the
    // sleep as docked (skipping the sleep toggles), and the undock verdict would then land
    // mid-sleep and run the undock toggles while the machine was going to sleep. So the
    // sequence is resolved first:
    //
    //   1. One immediate sample. A high-confidence result (the same bar the settle plan
    //      uses) is delivered at once as the sequence's verdict.
    //   2. Otherwise the sleep is held until the sequence delivers its own verdict, for no
    //      longer than the rest of its plan plus a second, capped at sleepHoldLimitSeconds.
    //      The system is kept awake meanwhile by MonitorSleep's withheld acknowledgment.
    //
    // Either way the verdict is queued on EventLogic's serial queue before the sleep event
    // (see deliverDockStatus), so an undock lands as a pending undock intent, which the
    // sleep handler applies together with the sleep toggles before the machine sleeps
    // (EventLogic.handleSleepEvent), re-checking the dock at wake before restoring.
    func resolvePendingVerdictBeforeSleep(then proceed: @escaping @Sendable () -> Void) {
        dockMonQueue.async { [weak self] in
            guard let self else { proceed(); return }
            guard self.isRunning, let token = self.currentSequenceToken, !self.sequenceAccepted else {
                proceed()
                return }

            let holdID = UUID()
            let remaining = self.sequencePlanEnd.timeIntervalSinceNow + 1.0
            let limit = min(max(remaining, 1.0), Self.sleepHoldLimitSeconds)
            self.sleepHolds[holdID] = proceed
            self.log("System will sleep with settle sequence (\(token.uuidString.prefix(8))) unresolved — sampling now; holding sleep handling for its verdict (up to \(limit.fixed(1))s).")

            self.dockMonQueue.asyncAfter(deadline: .now() + limit) { [weak self] in
                guard let self, let held = self.sleepHolds.removeValue(forKey: holdID) else { return }
                self.log("WARNING: No dock verdict within \(limit.fixed(1))s of sleep — proceeding with the last known dock state.")
                held() }

            self.sampleHeuristics(trigger: "sleep") { [weak self] isDocked, score, thunderbolt in
                guard let self else { return }
                // Already settled (the plan finished first) or superseded by a newer event,
                // whose own verdict will release the hold.
                guard token == self.currentSequenceToken, !self.sequenceAccepted else { return }

                if let dock = thunderbolt.learnableDock {
                    Preferences.rememberDock(uid: dock.uid, name: dock.name) }
                let viaKnownDock = isDocked && thunderbolt.dockClass >= .certain
                guard Self.isHighConfidence(isDocked: isDocked, score: score, viaKnownDock: viaKnownDock) else {
                    self.log("Sleep sample not high-confidence (isDocked=\(isDocked), score=\(score), class=\(thunderbolt.dockClass)) — waiting for the settle sequence's verdict.")
                    return }

                self.log("Accepting sleep sample as the verdict (isDocked=\(isDocked), score=\(score), class=\(thunderbolt.dockClass))")
                self.sequenceAccepted = true
                self.deliverDockStatus(isDocked: isDocked, timestamp: Date(), sequenceToken: token,
                                       isConfirmation: self.sequenceIsConfirmation, viaKnownDock: viaKnownDock) } } }

    // Hands every held sleep on to EventLogic. dockMonQueue only.
    private func releaseSleepHolds(reason: String) {
        guard !sleepHolds.isEmpty else { return }
        let held = sleepHolds.values
        sleepHolds.removeAll()
        log("Releasing held sleep handling (\(reason)).")
        held.forEach { $0() } }

    // MARK: – Callback delivery
    // deliverDockStatus is called exclusively on dockMonQueue.
    // Delivers the final dock determination directly to the registered callback
    // rather than broadcasting through NotificationCenter. The callback is invoked
    // on dockMonQueue; EventLogic's receive method immediately re-serializes
    // onto its own logicQueue, preserving the same queue-discipline as before.
    // 'object: nil' / observer identity is not needed because there is exactly
    // one consumer (EventLogic) and it is wired by AppDelegate at startup.
    private func deliverDockStatus(isDocked: Bool, timestamp: Date, sequenceToken: UUID, isConfirmation: Bool,
                                   viaKnownDock: Bool) {
        guard sequenceToken == currentSequenceToken else {
            log("Skipping delivery (sequence superseded)")
            return }

        lastVerdictViaKnownDock = viaKnownDock

        log("Delivering dock status (isDocked=\(isDocked))\(isConfirmation ? " [confirmation]" : "")")
        onDockStatusChanged?(isDocked, timestamp)
        // After the callback, never before: the callback queues the verdict on EventLogic's
        // serial queue, and a released hold queues the sleep event on that same queue, so
        // EventLogic is guaranteed to see the verdict first.
        releaseSleepHolds(reason: "verdict delivered")

        // Schedule the one confirmation re-measurement. It is tied to this sequence's
        // token: any newer Thunderbolt event replaces the token (and schedules its own
        // confirmation in turn), so a superseded confirmation simply does not start.
        //
        // Dispatch timers do not advance while the Mac sleeps, so a confirmation pending at
        // sleep would otherwise fire seconds after wake, possibly mid dock re-enumeration.
        // Wall-clock time does advance, so an overdue confirmation is skipped: any real
        // change across the sleep produces Thunderbolt events, and the wake-time re-check
        // in EventLogic covers a pending undock.
        guard !isConfirmation else { return }
        let scheduledAt = Date()
        dockMonQueue.asyncAfter(deadline: .now() + Self.confirmationDelaySeconds) { [weak self] in
            guard let self, self.isRunning, sequenceToken == self.currentSequenceToken else { return }
            guard Date().timeIntervalSince(scheduledAt) < Self.confirmationDelaySeconds + 5 else {
                self.log("Skipping confirmation (a sleep intervened since the verdict)")
                return }
            self.startSettleSequence(trigger: "confirmation", isConfirmation: true) } }

    // MARK: - Cleanup
    // Graceful stop: Synchronized on dockMonQueue and ensures cleanup is performed.
    //
    // IMPORTANT – deadlock avoidance:
    // cleanupIOKitResources() must run cleanup work on the main thread. If
    // stopListening() is called FROM the main thread (as AppDelegate does during
    // applicationShouldTerminate), performing dockMonQueue.sync first and then
    // DispatchQueue.main.sync inside that closure would produce a classic
    // main ↔ dockMonQueue deadlock. To break this cycle we:
    //   1. Collect the IOKit objects that need releasing inside the dockMonQueue.sync
    //      closure (safe, since dockMonQueue owns them).
    //   2. Nil them out immediately on dockMonQueue so no other code can race on them.
    //   3. Dispatch the actual CFRunLoop/IONotificationPort teardown to main
    //      asynchronously AFTER the sync block has returned, so the calling thread
    //      is never blocked by main-thread work.
    func stopListening() {
        // Invariant: stopListening() must never be called from dockMonQueue itself.
        // If deinit fires on dockMonQueue (e.g. because the last strong reference
        // is released from inside a dockMonQueue closure), the dockMonQueue.sync call
        // below would deadlock — a serial queue cannot re-enter itself synchronously.
        // In the current call graph the last strong reference (AppDelegate.monitorDock)
        // is always released on the main thread, so this invariant holds in practice.
        // The precondition surfaces any future regression as a clear assertion failure
        // rather than a silent hang.
        dispatchPrecondition(condition: .notOnQueue(dockMonQueue))

        // Collect the IOKit objects to tear down.
        var portToDestroy: IONotificationPortRef?
        var contextToRelease: Unmanaged<ThunderboltCallbackContext>?
        var sourceToRemove: CFRunLoopSource?
        var matchIteratorToRelease: io_iterator_t = 0
        var termIteratorToRelease: io_iterator_t = 0

        // 'self' is captured STRONGLY and directly — deliberately, not with [weak self].
        // stopListening() is also reached from deinit, and a weak capture formed while the
        // object is deinitializing loads as nil: the guard would return immediately, the
        // IOKit port would never be destroyed, the run-loop source would never be removed
        // from the main run loop, and both iterators would leak. A strong capture is safe
        // here because this is a SYNCHRONOUS dispatch — the closure provably finishes
        // before stopListening() (and therefore before deinit) returns, so it cannot
        // resurrect or outlive the object.
        dockMonQueue.sync {
            // If not running, ensure any sequence tokens are cleared and return.
            guard self.isRunning else { self.currentSequenceToken = nil; return }
            self.isRunning = false
            self.currentSequenceToken = nil

            // Collect the objects that need teardown and nil them out on dockMonQueue
            // so they are no longer accessible to any in-flight closures.
            unsafe portToDestroy             = self.thunderboltNotifyPort
            unsafe contextToRelease          = self.thunderboltCallbackContext
            sourceToRemove            = self.thunderboltRunLoopSource
            matchIteratorToRelease    = self.thunderboltMatchIterator
            termIteratorToRelease     = self.thunderboltTermIterator

            unsafe self.thunderboltNotifyPort      = nil
            unsafe self.thunderboltCallbackContext = nil
            self.thunderboltRunLoopSource   = nil
            self.thunderboltMatchIterator   = 0
            self.thunderboltTermIterator    = 0

            // A sleep held for a verdict that will now never come must not wait out its limit.
            self.releaseSleepHolds(reason: "monitoring stopped")
            Self.log("Stopped Thunderbolt monitoring") }

        // Release iterators — safe from any thread.
        if matchIteratorToRelease != 0 { IOObjectRelease(matchIteratorToRelease) }
        if termIteratorToRelease  != 0 { IOObjectRelease(termIteratorToRelease) }

        // Perform CFRunLoop/port teardown on main. Use async to avoid a deadlock when
        // stopListening() is itself called from the main thread (e.g. during termination).
        // Box the C/CF values in SendableBox so the @Sendable closure can capture them
        // without a compiler warning. The box asserts what the compiler cannot verify:
        // these values are ref-counted C objects mutated only via thread-safe C APIs
        // on the main thread, the same thread to which the closure is dispatched.
        let boxedSource = SendableBox(value: sourceToRemove)
        let boxedPort   = unsafe SendableBox(value: portToDestroy)
        let boxedContext = unsafe SendableBox(value: contextToRelease)
        let doMainCleanup: @Sendable () -> Void = {
            if let src = boxedSource.value {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode) }
            if let port = unsafe boxedPort.value {
                unsafe IONotificationPortDestroy(port) }
            // Only now, with the port gone and no callback able to fire, drop the context.
            unsafe boxedContext.value?.release() }

        if Thread.isMainThread {
            doMainCleanup()
        } else {
            // Use async rather than sync to avoid any hidden re-entrancy or
            // priority-inversion issues on non-termination paths.
            DispatchQueue.main.async { doMainCleanup() } } }

    // cleanupIOKitResources() has been folded into stopListening() above.
    // It is kept as a private helper only for the failure paths in
    // startListeningForThunderboltEvents() where cleanup is needed before the
    // monitor has fully started (and before any queue-ownership concerns exist).
    //
    // NOTE: This method reads and writes thunderbolt* ivars which are otherwise
    // owned by dockMonQueue. It is safe here because it is called exclusively
    // from the main-thread setup closure inside startListeningForThunderboltEvents,
    // before isRunning is confirmed true and before any dockMonQueue closure has
    // had an opportunity to observe or mutate these handles.
    private func cleanupIOKitResources() {
        let portToDestroy    = unsafe self.thunderboltNotifyPort
        let contextToRelease = unsafe self.thunderboltCallbackContext
        let sourceToRemove   = self.thunderboltRunLoopSource
        let matchIter        = self.thunderboltMatchIterator
        let termIter         = self.thunderboltTermIterator

        unsafe self.thunderboltNotifyPort      = nil
        unsafe self.thunderboltCallbackContext = nil
        self.thunderboltRunLoopSource   = nil
        self.thunderboltMatchIterator   = 0
        self.thunderboltTermIterator    = 0

        if matchIter != 0 { IOObjectRelease(matchIter) }
        if termIter  != 0 { IOObjectRelease(termIter) }

        // Same SendableBox pattern as stopListening() — see comment there.
        let boxedSource = SendableBox(value: sourceToRemove)
        let boxedPort   = unsafe SendableBox(value: portToDestroy)
        let boxedContext = unsafe SendableBox(value: contextToRelease)
        let doMainCleanup: @Sendable () -> Void = {
            if let src = boxedSource.value {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode) }
            if let port = unsafe boxedPort.value {
                unsafe IONotificationPortDestroy(port) }
            // Only now, with the port gone and no callback able to fire, drop the context.
            unsafe boxedContext.value?.release() }

        if Thread.isMainThread { doMainCleanup()
        } else { DispatchQueue.main.async { doMainCleanup() } } }
}

// MARK: – ThunderboltCallbackContext
// The object IOKit's refCon points at. Holding the monitor weakly means a callback that
// arrives after MonitorDock has been freed (its teardown is finished asynchronously on
// main) sees nil instead of dereferencing a dangling pointer. 'monitor' is set once in
// init and never written again.
// @unchecked Sendable: the only stored property is a weak reference written in init;
// weak loads are atomic.
private final class ThunderboltCallbackContext: @unchecked Sendable {
    weak var monitor: MonitorDock?
    init(_ monitor: MonitorDock) { self.monitor = monitor }
}
