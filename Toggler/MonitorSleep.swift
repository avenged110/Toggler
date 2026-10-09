// MARK: – MonitorSleep.swift
// Copyright © 2025 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Monitors system sleep and wake events and notifies the EventLogic coordinator.
//
// Division of labor:
//   • NSWorkspace's willSleep/didWake notifications DRIVE the work. They are posted only
//     for full, user-visible sleep and wake — never for the dark-wake/maintenance cycles a
//     closed laptop goes through overnight — which is exactly when the radios should be
//     touched. This is the path Toggler has relied on since the start.
//   • IOKit's kIOMessageSystemWillSleep is used only to HOLD the system's sleep until that
//     work has finished (by withholding IOAllowPowerChange, with a hard cap). It never
//     starts work itself: IOKit also sends it for every maintenance sleep, and acting on
//     those would toggle radios in the middle of the night.

import Foundation
import IOKit.pwr_mgt
import AppKit

// SendableBox<T> is defined in Utilities.swift (internal scope) and shared here.
// It wraps CF/C reference types for safe capture across @Sendable closure boundaries.

// @unchecked Sendable: mutable state is protected as follows:
//   – sleepWork / pendingAcks: main thread only (NSWorkspace observers, the IOKit
//     callback and every completion hop there).
//   – notifyPort / notifyRunLoopSource: written once on the main thread during
//     registerIOKitSleepWakeNotifications (called from init), nil'd under
//     sleepMonQueue.sync in unregisterIOKitNotifications, and never written again.
//   – rootPort / notifierObject: same as notifyPort/notifyRunLoopSource. rootPort
//     is also read in handleIOKitPowerMessage, which is called on the main thread
//     by the IOKit callback; the main thread is the same thread that wrote rootPort
//     during init, so no concurrent mutation is possible during the live callback window.
//   – onWillSleep / onDidWake: written once by AppDelegate before any events fire;
//     thereafter read-only on sleepMonQueue.
// The compiler cannot verify queue-based or thread-based isolation, so we assert it.
// @safe: the IOKit port/refcon storage is private and every use of it is marked 'unsafe'
// at the point of use; nothing unsafe crosses this type's interface.
@safe final class MonitorSleep: Loggable, @unchecked Sendable {
    nonisolated static let logTag = "[SleepMon]"

    // Internal serial queue for monitor logic
    private let sleepMonQueue = DispatchQueue(label: "com.toggler.MonitorSleep", qos: .userInitiated)

    // IOKit notification support
    private var notifyPort: IONotificationPortRef? = nil
    private var notifyRunLoopSource: CFRunLoopSource? = nil   // retained from registration
    private var notifierObject: io_object_t = 0
    private var rootPort: io_connect_t = 0

    // Pre-sleep work state for the current sleep cycle (main thread only).
    //   idle     — awake; no work started since the last wake.
    //   running  — NSWorkspace's willSleep started the work; it has not reported done.
    //   finished — the work for this cycle is done. Stays set across dark wakes (for which
    //              NSWorkspace posts nothing) until the next full wake resets it.
    private enum SleepWork { case idle, running, finished }
    private var sleepWork: SleepWork = .idle
    // Incremented at each willSleep; a completion from an earlier cycle (work that outlived
    // a wake and a new sleep) is ignored rather than releasing the new cycle's hold.
    private var sleepCycle = 0
    // IOKit sleep acknowledgments waiting on the running work (main thread only).
    private var pendingAcks: [SleepAck] = []

    // Internal flag: Choose whether or not to log benign/unrelated IOKit messages
    private let logBenignMessages = false
    // Dictionary of known benign/unrelated IOKit power messages.
    // Values are human-readable descriptions for log clarity.
    // Note: kIOMessageCanSystemSleep (0x00000004) is handled explicitly in
    // handleIOKitPowerMessage and is intentionally absent from this table.
    private let benignIOKitMessages: [UInt32: String] = [
        0x00000005: "kIOMessageSystemWillNotSleep",
        0x00000006: "kIOMessageSystemWillPowerOn",
        0x00000010: "kIOMessageDeviceWillPowerOff",
        0x00000011: "kIOMessageDeviceWillPowerOn",
        0x00000012: "kIOMessageDeviceHasPoweredOn",
        0xE0000270: "kIOReturnNotPrivileged",
        0xE0000280: "kIOReturnInvalid",
        0xE0000300: "kIOReturnUnsupported",
        0xE0000320: "kIOReturnAborted" ]

    // MARK: – Callbacks
    // Invoked on sleepMonQueue when the system is about to sleep or has awakened.
    // Set once by AppDelegate immediately after init, before any events fire.
    // Captured as @Sendable because sleepMonQueue closures are @Sendable contexts.
    //
    // onWillSleep receives a 'done' closure that the handler MUST call once its pre-sleep
    // work has finished (from any queue). Until it is called — or sleepAckTimeout elapses,
    // whichever comes first — the kIOMessageSystemWillSleep acknowledgment is withheld, so
    // the system does not sleep underneath the work.
    var onWillSleep: (@Sendable (_ done: @escaping @Sendable () -> Void) -> Void)?
    var onDidWake:   (@Sendable () -> Void)?

    // MARK: – Initialization
    init() { registerForSleepWakeNotifications(); log("Initialized") }

    // All real teardown is performed synchronously and on the main thread by
    // prepareForTermination(), which AppDelegate calls before releasing this object.
    // deinit is nonisolated and may fire on any thread; making it a true no-op
    // eliminates the thread-safety concern with CF/IOKit resources entirely.
    // The sleepMonQueue.sync call inside unregisterIOKitNotifications would deadlock
    // if deinit fired on sleepMonQueue itself — the same hazard that
    // MonitorDock.stopListening() guards against with dispatchPrecondition.
    // prepareForTermination() is the authoritative teardown path.
    deinit {}

    // MARK: – Explicit teardown
    // Must be called from the main thread before the object is released.
    // Removes both the NSWorkspace observer and the IOKit notification port/source
    // explicitly here, rather than in deinit, because:
    //   (a) NSWorkspace.shared requires main-thread access and deinit is nonisolated.
    //   (b) Moving IOKit teardown here too makes deinit a true no-op, eliminating the
    //       thread-context dependency that the deinit → unregisterIOKitNotifications()
    //       path carries (it works today because AppDelegate nils monitorSleep on the
    //       main thread, but that is an implicit invariant rather than an enforced one).
    func prepareForTermination() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        unregisterIOKitNotifications() }

    // Register for system sleep/wake notifications.
    private func registerForSleepWakeNotifications() {
        log("Registering for NSWorkspace sleep/wake notifications")

        // NSWorkspace notifications — standard and simple to use
        let workspaceNC = NSWorkspace.shared.notificationCenter
        workspaceNC.addObserver(self, selector: #selector(systemWillSleepNotification(_:)),
            name: NSWorkspace.willSleepNotification, object: nil)
        workspaceNC.addObserver(self, selector: #selector(systemDidWakeNotification(_:)),
            name: NSWorkspace.didWakeNotification, object: nil)

        // IOKit power notifications, used only to hold sleep until the work above is done.
        registerIOKitSleepWakeNotifications() }

    // MARK: - NSWorkspace notification handlers
    // The sole drivers of sleep and wake work (see the file header). Both are delivered on
    // the main thread, which owns sleepWork and pendingAcks.
    //
    // History: for a time the IOKit message drove sleep and this notification was ignored
    // whenever IOKit registration succeeded. The IOKit callback has never been observed
    // to run in this app — the power log shows "Toggler timed out(30000 ms)" on every sleep
    // — so with that arrangement the pre-sleep work silently stopped running altogether.
    @objc private func systemWillSleepNotification(_ notification: Notification) {
        log("Received NSWorkspace.willSleepNotification")
        guard sleepWork != .running else {
            log("Pre-sleep work already running — ignoring duplicate notification")
            return }
        sleepWork = .running
        sleepCycle += 1
        let cycle = sleepCycle
        handleSleep(done: { DispatchQueue.main.async { [weak self] in self?.sleepWorkFinished(cycle: cycle) } }) }

    @objc private func systemDidWakeNotification(_ notification: Notification) {
        log("Received NSWorkspace.didWakeNotification")
        // A new awake period: the next sleep starts from scratch. Any acknowledgment still
        // pending (not possible in a normal cycle) is released rather than stranded.
        sleepWork = .idle
        releasePendingAcks(reason: "system woke")
        handleWake() }

    // Main thread. Marks this cycle's work done and releases any IOKit acknowledgment
    // that was waiting for it.
    private func sleepWorkFinished(cycle: Int) {
        guard cycle == sleepCycle else { return }
        if sleepWork == .running { sleepWork = .finished }
        releasePendingAcks(reason: "pre-sleep work complete") }

    private func releasePendingAcks(reason: String) {
        let acks = pendingAcks
        pendingAcks.removeAll()
        for ack in acks { ack.fire(reason) } }

    // MARK: - IOKit power notifications
    private let kIOMessageCanSystemSleep:   UInt32 = 0x00000004
    private let kIOMessageSystemWillSleep:  UInt32 = 0x00000001
    private let kIOMessageSystemHasPoweredOn: UInt32 = 0x00000003

    // Upper bound on how long sleep is held for pre-sleep work. The kernel itself waits up
    // to 30 s for an acknowledgment before sleeping anyway, so this cap keeps Toggler well
    // clear of ever being the reason a sleep stalls. It covers the slowest verified path
    // including EventLogic's single retry: Bluetooth is ~5.6 s per attempt (~2.4 s
    // private-API check + ~3.2 s fallback check), so ~11.2 s worst case for two attempts.
    // In the normal case the radios confirm within a fraction of a second and the
    // acknowledgment goes out immediately; this only bounds the failure case.
    private static let sleepAckTimeout: TimeInterval = 15.0

    // How long an IOKit sleep message that arrives while no work is running waits for
    // NSWorkspace's notification to start it. Both come from the same kernel message and
    // are normally delivered back to back; if nothing starts within this window, the
    // sleep is a maintenance (dark-wake) sleep with no work to do and is acknowledged.
    private static let sleepWorkStartGrace: TimeInterval = 2.0

    private func registerIOKitSleepWakeNotifications() {
        log("Registering for IOKit sleep/wake notifications")

        // Prepare a local notify port pointer we will save into the instance property.
        var localNotifyPort: IONotificationPortRef? = nil

        // Pre-build the callback — forward both messageType and messageArgument
        let selfPtr = unsafe UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let callback: IOServiceInterestCallback = { (refCon, service, messageType, messageArgument) in
            guard let refCon = unsafe refCon else { return }
            // Convert refCon back to MonitorSleep
            let monitor = unsafe Unmanaged<MonitorSleep>.fromOpaque(refCon).takeUnretainedValue()
            // The argument is the notification ID IOAllowPowerChange needs: a kernel-supplied
            // integer disguised as a pointer. Converting it here, via Int(bitPattern:), keeps
            // the raw pointer out of handleIOKitPowerMessage entirely.
            let notificationID = unsafe messageArgument.map { Int(bitPattern: $0) } ?? 0
            monitor.handleIOKitPowerMessage(messageType: messageType, notificationID: notificationID) }

        // Register for system power notifications — returns a root port.
        // NOTE: IORegisterForSystemPower requires a pointer to an
        // IONotificationPortRef variable.
        rootPort = unsafe IORegisterForSystemPower(selfPtr, &localNotifyPort, callback, &notifierObject)
        if rootPort == 0 { log("IORegisterForSystemPower failed"); return }

        // Save the notify port
        unsafe notifyPort = localNotifyPort

        guard let notifyPort = unsafe notifyPort else {
            log("IONotificationPortCreate / IORegister returned nil notify port"); return }

        // Get the runloop source for the notification port and store it as an ivar
        // so teardown can remove it without calling IONotificationPortGetRunLoopSource
        // again on a port that may be mid-teardown.
        let runLoopSource = unsafe IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue()
        notifyRunLoopSource = runLoopSource

        // This function is always invoked from init(), which AppKit guarantees runs on
        // the main thread (applicationDidFinishLaunching is a main-thread callback).
        // CFRunLoopAddSource requires the main run loop, and we are already on it, so
        // no dispatch hop is needed. An assertion confirms the invariant so any future
        // off-main caller surfaces a clear failure rather than a silent misbehavior.
        assert(Thread.isMainThread,
            "registerIOKitSleepWakeNotifications must be called on the main thread")
        // Common modes rather than only the default mode, so the power message is serviced
        // whatever mode the main run loop happens to be in when sleep begins.
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, CFRunLoopMode.commonModes)

        log("Registered for IOKit sleep/wake notifications (notifierObject=\(self.notifierObject))") }

    // nonisolated: this method is called from prepareForTermination (called on the
    // main thread by AppDelegate). Marking it explicitly nonisolated makes the call
    // site unambiguous under Swift 6 strict concurrency and avoids any implicit
    // isolation mismatch.
    //
    // IMPORTANT – deadlock avoidance:
    // This method calls sleepMonQueue.sync to collect and nil IOKit ivars. If called
    // from sleepMonQueue itself, that sync would deadlock. The same hazard exists for
    // MonitorDock.stopListening() and is guarded there with dispatchPrecondition.
    // The precondition below enforces the same invariant here: prepareForTermination()
    // is always called on the main thread (from AppDelegate), which is never sleepMonQueue,
    // so this precondition should never fire in practice — but will surface any future
    // regression as a clear assertion failure rather than a silent hang.
    nonisolated private func unregisterIOKitNotifications() {
        dispatchPrecondition(condition: .notOnQueue(sleepMonQueue))

        // Collect and nil all IOKit/CF ivars under sleepMonQueue.sync to provide a
        // formal memory barrier. IOObjectRelease is safe from any thread and is
        // called after collecting the value but outside the queue to minimize
        // time spent under the lock.
        var portToDestroy:    IONotificationPortRef? = nil
        var sourceToRemove:   CFRunLoopSource?       = nil
        var rootPortToClose:  io_connect_t           = 0
        var notifierToRelease: io_object_t           = 0

        sleepMonQueue.sync {
            unsafe portToDestroy      = self.notifyPort
            sourceToRemove     = self.notifyRunLoopSource
            rootPortToClose    = self.rootPort
            notifierToRelease  = self.notifierObject

            unsafe self.notifyPort          = nil
            self.notifyRunLoopSource = nil
            self.rootPort            = 0
            self.notifierObject      = 0
        }

        // NOTE: the notifier is NOT released here. A notifier obtained from
        // IORegisterForSystemPower must be torn down with IODeregisterForSystemPower,
        // which both deregisters the interest notification and releases the object.
        // IOObjectRelease alone (what this used to call) drops the reference while
        // leaving the notification registered against a port that the block below then
        // destroys. The deregistration is therefore performed in doMainCleanup, in the
        // order Apple documents: remove the run-loop source, deregister, close the root
        // port, destroy the notification port.

        // Tear down the notification port and remove its run-loop source.
        // CFRunLoopRemoveSource must execute on the main thread. Using main.sync here
        // would deadlock if deinit fires on the main thread (e.g. during teardown in
        // applicationShouldTerminate). Use the same async-after-nil pattern as
        // MonitorDock.stopListening(): the ivars have already been nil'd above so no
        // other code can race on them; dispatch the actual CF teardown asynchronously.
        // If we're already on the main thread, run inline.
        //
        // Note: rootPort is read on the main thread inside handleIOKitPowerMessage.
        // The call chain through prepareForTermination() / applicationShouldTerminate()
        // ensures this method runs after all IOKit callbacks have been delivered and the
        // run-loop source has been removed, so no concurrent main-thread read of rootPort
        // is possible at this point.
        let boxedPort     = unsafe SendableBox(value: portToDestroy)
        let boxedSource   = SendableBox(value: sourceToRemove)
        // Box rootPortToClose as a value type wrapped in SendableBox so the @Sendable
        // closure can capture it safely. Swift 6 forbids capturing a 'var' local
        // directly in a @Sendable closure; boxing it via SendableBox (which holds a
        // 'let') gives the compiler the immutability guarantee it requires.
        let boxedRootPort = SendableBox(value: rootPortToClose)
        let boxedNotifier = SendableBox(value: notifierToRelease)
        let doMainCleanup: @Sendable () -> Void = {
            // Use the stored source ivar — avoids calling IONotificationPortGetRunLoopSource
            // again on a port that is about to be destroyed.
            if let src = boxedSource.value {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src, CFRunLoopMode.commonModes) }
            // Apple's documented teardown order for IORegisterForSystemPower:
            // IODeregisterForSystemPower, then IOServiceClose, then
            // IONotificationPortDestroy. Deregistering first guarantees no further
            // callback can be delivered through a port that is about to go away.
            // IODeregisterForSystemPower takes the notifier inout and releases it, so no
            // separate IOObjectRelease is needed (or wanted — that would over-release).
            var notifier = boxedNotifier.value
            if notifier != 0 { unsafe IODeregisterForSystemPower(&notifier) }
            if boxedRootPort.value != 0 { IOServiceClose(boxedRootPort.value) }
            if let port = unsafe boxedPort.value {
                unsafe IONotificationPortDestroy(port) } }

        if Thread.isMainThread { doMainCleanup()
        } else { DispatchQueue.main.async { doMainCleanup() } } }

    // 'notificationID' is the value IOAllowPowerChange / IOCancelPowerChange require by the
    // IOKit power management contract (0 when the message carries none).
    //
    // THREADING: Called exclusively on the main thread by the IOKit power-notification
    // callback. This is guaranteed because the notification port's run-loop source is
    // attached to the main run loop in registerIOKitSleepWakeNotifications. The
    // precondition below makes this invariant explicit so that any future refactor that
    // moves the run-loop attachment will surface a clear failure rather than a silent race.
    // rootPort is safe to read here because it is also written on the main thread during
    // init (registerIOKitSleepWakeNotifications) and nil'd under sleepMonQueue.sync in
    // unregisterIOKitNotifications — the sleepMonQueue.sync barrier ensures the nil write
    // is fully visible before any subsequent main-thread access, and the prepareForTermination()
    // / applicationShouldTerminate() call chain guarantees IOKit is unregistered before
    // the MonitorSleep object is released.
    private func handleIOKitPowerMessage(messageType: UInt32, notificationID: Int) {
        assert(Thread.isMainThread,
            "handleIOKitPowerMessage must be called on the main thread (rootPort is main-thread-owned)")
        switch messageType {

        // kIOMessageCanSystemSleep: The system is requesting permission to sleep.
        // We must respond with IOAllowPowerChange; failing to do so will block the
        // system from sleeping until the kernel's timeout expires (~30 s).
        case kIOMessageCanSystemSleep:
            log("IOKit reports kIOMessageCanSystemSleep — acknowledging")
            IOAllowPowerChange(rootPort, notificationID)

        case kIOMessageSystemWillSleep:
            // Exactly one IOAllowPowerChange is sent per message — by whichever of the work's
            // completion, the start-grace check or the cap gets there first. All of them run
            // on the main thread, so SleepAck needs no lock. rootPort is captured now so a
            // teardown racing the ack cannot swap it underneath.
            let port = rootPort
            let ack = SleepAck { [weak self] reason in
                IOAllowPowerChange(port, notificationID)
                self?.log("Acknowledged system sleep (\(reason))") }
            switch sleepWork {
            case .finished:
                log("IOKit reports system will sleep — pre-sleep work already complete")
                ack.fire("pre-sleep work already complete")
                return
            case .running:
                log("IOKit reports system will sleep — holding acknowledgment until pre-sleep work completes")
                pendingAcks.append(ack)
            case .idle:
                log("IOKit reports system will sleep — waiting up to \(Self.sleepWorkStartGrace)s for pre-sleep work to start")
                pendingAcks.append(ack)
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.sleepWorkStartGrace) { [weak self] in
                    guard self?.sleepWork != .running else { return }
                    ack.fire("no pre-sleep work for this sleep") } }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.sleepAckTimeout) {
                ack.fire("WARNING: pre-sleep work did not finish within \(Self.sleepAckTimeout)s") }

        case kIOMessageSystemHasPoweredOn:
            // Logged only. Wake work is driven by NSWorkspace.didWakeNotification, which —
            // unlike this message — is not sent for dark wakes.
            log("IOKit reports system did wake")

        default:
            if let description = benignIOKitMessages[messageType] {
                if logBenignMessages { log("Received benign IOKit power message: \(description) (\(Self.hex(messageType)))") }
            } else { log("Received unhandled IOKit power message: \(Self.hex(messageType))") } } }

    // "0xE0000280"-style rendering for log lines, without String(format:), whose C varargs
    // are unsafe under strict memory safety.
    private static func hex(_ value: UInt32) -> String { "0x" + String(value, radix: 16, uppercase: true) }

    // MARK: - Sleep/wake callback delivery

    // Hands the pre-sleep work to EventLogic. 'done' is always called: immediately when
    // there is no callback wired, otherwise by the callback itself.
    private func handleSleep(done: @escaping @Sendable () -> Void) {
        sleepMonQueue.async { [weak self] in
            guard let onWillSleep = self?.onWillSleep else { done(); return }
            Self.log("System will sleep - invoking callback")
            onWillSleep(done) } }

    // Called when the system has awakened.
    private func handleWake() {
        sleepMonQueue.async { [weak self] in
            guard let onDidWake = self?.onDidWake else { return }
            Self.log("System did wake - invoking callback")
            onDidWake() } }
}

// MARK: – SleepAck
// One-shot wrapper around the deferred IOAllowPowerChange for a single sleep message.
// @unchecked Sendable: 'fired' is only ever read and written on the main thread — the
// completion, grace and cap paths all dispatch there before calling fire() — which the
// assertion enforces.
private final class SleepAck: @unchecked Sendable {
    private var fired = false
    private let action: (String) -> Void

    init(_ action: @escaping (String) -> Void) { self.action = action }

    func fire(_ reason: String) {
        assert(Thread.isMainThread, "SleepAck must fire on the main thread")
        guard !fired else { return }
        fired = true
        action(reason) }
}
