// MARK: - Heuristics.swift
// Copyright © 2025 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Pure helper functions that encapsulate the various environmental
// heuristics used by other classes to determine states.

import Foundation
import IOKit          // IOServiceMatching / IORegistry traversal
import IOKit.ps       // IOPSCopyPowerSourcesInfo (wall-power detection)
import CoreGraphics   // CGGetOnlineDisplayList (external-display detection)
import Darwin         // usleep (bounded IORegistry re-scan)
import Network        // NWPathMonitor (Ethernet presence)
import Synchronization // Mutex (Ethernet presence cache)

// @unchecked Sendable: Heuristics has exactly one piece of mutable static state —
// ethernetPresentCache — and every access to it goes through its Mutex.
// All other static state is immutable (let) or purely functional (static methods
// with no captured mutable state). These invariants are enforced manually;
// @unchecked Sendable informs the compiler of this without requiring full actor
// isolation, which would force every call-site to be async.

// File-private holder that (a) allows NWPathMonitor — a non-Sendable type — to be
// captured inside the @Sendable pathUpdateHandler closure required by NWPathMonitor's
// API, and (b) enforces that the surrounding completion handler is invoked exactly once.
//
// The single-invocation guarantee matters because 'isEthernetPresentAsync' has two
// possible finishers: the path update itself and a watchdog timeout. It is also
// possible for NWPathMonitor to deliver a second path update before cancel() takes
// effect. Callers assume single-shot semantics — MonitorDock counts probe completions
// against its settle plan, and EventLogic clears its pending-wake token on the first
// result — so a duplicate delivery would corrupt that bookkeeping.
//
// @unchecked Sendable: 'claimed' and 'monitor' are mutated only while 'lock' is held.
private final class EthernetProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    private var monitor: NWPathMonitor?

    init(_ monitor: NWPathMonitor) { self.monitor = monitor }

    // Returns 'true' for the first caller only; every later caller receives 'false'.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }

    // Cancels and releases the monitor. Safe to call more than once.
    func cancelMonitor() {
        lock.lock()
        let m = monitor
        monitor = nil
        lock.unlock()
        m?.cancel()
    }
}

final class Heuristics: Loggable, @unchecked Sendable {
    nonisolated static let logTag = "[Heuristics]"

    // Maximum possible signal score based on available heuristics.
    // Thunderbolt (a device not classified as a non-dock) contributes 2 points; Ethernet, wall power, and external display
    // each contribute 1 point, for a maximum achievable total of 5.
    static let maxScore = 5

    // Nested types
    // Sendable: all stored properties are Bool (a value type, inherently Sendable).
    struct Signals: Sendable {
        let ethernet: Bool
        let thunderbolt: Bool
        let wallPower: Bool
        let externalDisplay: Bool }

    // MARK: – Caches and queues
    // Cached result of the last Ethernet presence check (default: false).
    // A Mutex rather than a nonisolated(unsafe) var guarded by a serial queue: the
    // compiler can verify it, so it needs no escape hatch under strict concurrency or
    // strict memory safety, and reads stay synchronous for the evaluation path.
    static private let ethernetPresentCache = Mutex(false)

    // Reused delivery queue for NWPathMonitor in isEthernetPresentAsync.
    // Creating a new DispatchQueue per NWPathMonitor call allocates a kernel object
    // unnecessarily — one shared queue is sufficient for the single-shot callback pattern.
    static private let ethernetMonitorQueue = DispatchQueue(label: "com.toggler.heuristics.ethernetMonitor", qos: .utility)

    // Serial queue on which the blocking part of a dock evaluation runs — the IORegistry
    // walk in thunderboltSnapshot (which can usleep 100 ms), the CoreGraphics display
    // query, and the IOKit power-source read.
    //
    // Deliberately NOT ethernetMonitorQueue. That queue is the delivery queue handed to
    // NWPathMonitor, and it is serial: running the scoring work inline on it meant each
    // probe's IOKit walk blocked the *next* probe's path update behind it, so a settle plan
    // whose last two probes are 300 ms apart could not honor that spacing once the walk
    // took longer. Splitting the two keeps path updates prompt and lets the scoring work
    // take as long as it takes. Serial rather than concurrent on purpose: overlapping
    // IORegistry walks would buy nothing, and the settle probes are sequential by design.
    static private let scoringQueue = DispatchQueue(label: "com.toggler.heuristics.scoring", qos: .utility)

    // Watchdog interval for isEthernetPresentAsync. NWPathMonitor normally delivers its
    // first path update within a few tens of milliseconds, so this bound is generous;
    // it exists only so that a monitor which never reports cannot strand its caller.
    static private let ethernetProbeTimeout: TimeInterval = 3.0

    // MARK: – Dock scoring
    // Pure, deterministic scoring function.
    // Returns only the verdict and the score. It previously also echoed the 'signals'
    // argument straight back out, which every caller in the app discarded.
    static func scoreDockState(from signals: Signals, threshold: Int) -> (isDocked: Bool, score: Int) {
        // Thunderbolt device presence is weighted more strongly than other signals.
        let values = [
            signals.ethernet ? 1 : 0,
            signals.thunderbolt ? 2 : 0,
            signals.wallPower ? 1 : 0,
            signals.externalDisplay ? 1 : 0 ]
        let score = values.reduce(0, +)
        let clampedThreshold = max(1, min(self.maxScore, threshold))
        let isDocked = score >= clampedThreshold
        return (isDocked, score) }

    // Synchronous evaluation using the latest cached Ethernet value and
    // freshly-computed values for all other signals.
    //
    // A device classified "certain" (or already learned) is a dock regardless of the
    // score: the classification is the stronger evidence, and letting a low score
    // overrule it would make a confirmation pass contradict MonitorDock's fast path.
    static func evaluateDockUsingCachedSignals(threshold: Int) -> (isDocked: Bool, score: Int, thunderbolt: ThunderboltSnapshot) {
        // Read Ethernet cache in a thread-safe manner.
        let eth = ethernetPresentCache.withLock { $0 }

        let thunderbolt = thunderboltSnapshot(retryIfEmpty: true)
        log("Thunderbolt: \(thunderbolt)")
        let wallPower = isOnACPower()
        let externalDisplay = externalDisplayDetection()

        let signals = Signals(ethernet: eth, thunderbolt: thunderbolt.countsAsDockSignal,
                              wallPower: wallPower, externalDisplay: externalDisplay)
        let scored = scoreDockState(from: signals, threshold: threshold)
        return (scored.isDocked || thunderbolt.dockClass >= .certain, scored.score, thunderbolt) }

    // Async evaluation that first refreshes the Ethernet cache, then computes.
    //
    // The scoring work is hopped onto scoringQueue rather than run inline on
    // isEthernetPresentAsync's delivery queue (ethernetMonitorQueue). That hop is not
    // ceremony: ethernetMonitorQueue is the serial queue NWPathMonitor delivers on, and
    // the scoring work blocks for as long as an IORegistry walk takes — so running it
    // there stalls the path update of whichever probe comes next. See scoringQueue.
    //
    // COMPLETION IS DELIVERED ON scoringQueue, not on the caller's queue. Both call sites
    // (MonitorDock.sampleHeuristics, EventLogic.handleWakeEvent) already re-dispatch onto
    // their own queue, which is what makes this safe to change.
    //
    // The third argument is the Thunderbolt classification, which MonitorDock uses to
    // pick its acceptance rung and to learn docks.
    static func evaluateDockWithRefresh(threshold: Int, completion: @escaping @Sendable (Bool, Int, ThunderboltSnapshot) -> Void) {
        isEthernetPresentAsync { _ in
            scoringQueue.async {
                let result = evaluateDockUsingCachedSignals(threshold: threshold)
                completion(result.isDocked, result.score, result.thunderbolt)
            }
        }
    }

    // MARK: – Ethernet presence detection
    // Asynchronously checks if an Ethernet interface is present on the system
    // and updates the cached value when done. Completion is called on ethernetMonitorQueue
    // (the delivery queue supplied to NWPathMonitor), so it must stay short — the sole
    // caller, evaluateDockWithRefresh, immediately hops the blocking scoring work off it.
    // Callers are responsible for re-dispatching to their own queue if needed.
    // GUARANTEE: 'completion' is invoked exactly once — never zero times, never twice.
    // This is load-bearing rather than merely tidy. isEthernetPresentAsync is the first
    // step of evaluateDockWithRefresh, which is in turn the only path by which a dock
    // determination is ever produced. If the completion never fired, MonitorDock's
    // settle sequence would never reach a verdict (the dock state would silently stop
    // updating until the next Thunderbolt event) and EventLogic's wake-time re-check
    // would leave 'pendingWakeCheck' set forever, permanently stranding a pending
    // undock intent. The watchdog below closes that hole by falling back to the last
    // cached Ethernet value, and EthernetProbe's claim() closes the duplicate-delivery
    // hole in the opposite direction.
    static func isEthernetPresentAsync(completion: @escaping @Sendable (Bool) -> Void) {
        let monitor = NWPathMonitor()

        // NWPathMonitor is not Sendable, so it cannot be captured directly inside a
        // @Sendable pathUpdateHandler closure. EthernetProbe (defined at file scope)
        // wraps it with @unchecked Sendable and adds the single-shot claim.
        let probe = EthernetProbe(monitor)

        // Built before the path handler so the handler can cancel it. Scheduled on the
        // same serial queue that delivers the path update, so the two finishers cannot
        // execute concurrently; claim() then settles which one owns the completion.
        let watchdog = DispatchWorkItem {
            guard probe.claim() else { return }
            let cached = ethernetPresentCache.withLock { $0 }
            log("WARNING: Ethernet path evaluation did not report within \(ethernetProbeTimeout)s; falling back to last cached value (\(cached)).")
            probe.cancelMonitor()
            completion(cached) }

        // DispatchWorkItem is not Sendable, so it cannot be captured directly in the
        // @Sendable pathUpdateHandler — the same constraint that forces NWPathMonitor
        // through EthernetProbe above. SendableBox (Utilities.swift) is the house pattern
        // for this. Sound here: cancel() is documented thread-safe, and the box holds a
        // 'let', so nothing is mutated across the boundary.
        let boxedWatchdog = SendableBox(value: watchdog)

        monitor.pathUpdateHandler = { [probe, boxedWatchdog] path in
            let foundEthernet = path.availableInterfaces.contains(where: { $0.type == .wiredEthernet })
            // First finisher wins; a duplicate path update is dropped here.
            guard probe.claim() else { return }

            // claim() has already settled the race, so the watchdog could not fire the
            // completion a second time in any case. Canceling it releases the captured
            // completion closure now rather than leaving a block parked on this shared
            // serial queue for the remainder of the timeout — with five settle probes in
            // flight per sequence, those otherwise accumulate.
            boxedWatchdog.value.cancel()

            // Synchronous cache write. The subsequent evaluateDockUsingCachedSignals()
            // call reads this value under the same lock, so writing it before the
            // completion makes the happens-before relationship explicit and independent
            // of which queue happens to invoke the completion (path update vs. watchdog).
            ethernetPresentCache.withLock { $0 = foundEthernet }
            probe.cancelMonitor()

            // Deliver the completion on ethernetMonitorQueue (the queue supplied to start).
            completion(foundEthernet) }

        ethernetMonitorQueue.asyncAfter(deadline: .now() + ethernetProbeTimeout, execute: watchdog)

        // Reused static queue — NWPathMonitor only needs a queue to deliver its
        // single-shot callback; allocating a new DispatchQueue per call is wasteful.
        monitor.start(queue: ethernetMonitorQueue) }

    // MARK: – Thunderbolt device classification
    // Scores what the attached Thunderbolt devices actually DO, independently of the dock
    // score above. Thunderbolt has no "dock" device class, but the functions a device
    // exposes are standardized and vendor-neutral, so no whitelist is needed:
    //
    //   • PCIe functions tunneled over Thunderbolt appear as IOPCIDevice nodes flagged
    //     "IOPCITunnelled", each with a PCI "class-code" (0x0C03xx USB host controller,
    //     0x0200xx Ethernet, 0x01xxxx storage). A dock tunnels USB and/or Ethernet
    //     controllers; a drive tunnels only storage.
    //   • Each external IOThunderboltSwitch lists its adapters as IOThunderboltPort
    //     children with a USB4-spec "Adapter Type". An adapter carrying a live tunnel has a
    //     non-empty "Hop Table". A live DisplayPort-out tunnel means the device is driving a
    //     display (a dock or a Thunderbolt display); a live USB3 upstream tunnel is how
    //     USB4/Thunderbolt 4 docks carry USB without a tunneled PCIe controller.
    //
    // Two independent dock functions (score >= certainScore) make the device a dock beyond
    // reasonable doubt; its UID is then remembered and future connections take the fast
    // path in MonitorDock. One function is "likely"; none leaves the device "unknown"
    // (handled exactly as before) unless it tunnels storage, in which case it is
    // "unlikely" and no longer counts as a dock signal at all.

    // Ordered by certainty so tiers compare with < and >=.
    enum DockClass: Int, Sendable, Comparable, CustomStringConvertible {
        case none, unlikely, unknown, likely, certain, known
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
        var description: String {
            switch self {
            case .none: "none"
            case .unlikely: "unlikely"
            case .unknown: "unknown"
            case .likely: "likely"
            case .certain: "certain"
            case .known: "known" } } }

    // One external Thunderbolt device. 'uid' is 0 if the switch did not report one.
    struct ThunderboltDevice: Sendable {
        let uid: UInt64
        let name: String }

    struct ThunderboltSnapshot: Sendable, CustomStringConvertible {
        let devices: [ThunderboltDevice]   // external switches only (depth >= 1)
        let knownDock: ThunderboltDevice?  // first attached device whose UID was learned
        let functionScore: Int
        let evidence: [String]
        let hasStorage: Bool

        var dockClass: DockClass {
            if devices.isEmpty { return .none }
            if knownDock != nil { return .known }
            if functionScore >= Heuristics.certainScore { return .certain }
            if functionScore >= Heuristics.likelyScore { return .likely }
            return hasStorage ? .unlikely : .unknown }

        // Whether the Thunderbolt signal counts toward the dock score. "unknown" still
        // counts, so a device we cannot classify is treated exactly as it was before.
        var countsAsDockSignal: Bool { dockClass >= .unknown }

        // The device to remember, if any. Only with exactly one external device attached:
        // tunneled PCIe functions cannot be attributed to a particular device in a chain,
        // so a drive daisy-chained in front of a dock would otherwise be learned as a dock.
        var learnableDock: ThunderboltDevice? {
            guard dockClass == .certain, devices.count == 1, devices[0].uid != 0 else { return nil }
            return devices[0] }

        var description: String {
            let names = devices.map { "\($0.name) (UID \($0.uid))" }.joined(separator: ", ")
            return "class=\(dockClass) functionScore=\(functionScore) evidence=[\(evidence.joined(separator: ", "))] devices=[\(names)]" } }

    // Function weights. Each dock function alone scores 'likelyScore'; any two reach
    // 'certainScore'. A USB3 tunnel is weighted lower because USB4 storage enclosures
    // can fall back to one.
    static let likelyScore = 3
    static let certainScore = 6
    private static let usbHostWeight = 3
    private static let ethernetWeight = 3
    private static let displayTunnelWeight = 3
    private static let usbTunnelWeight = 2

    // USB4 adapter type codes (IOThunderboltPort "Adapter Type").
    private static let dpOutAdapterType  = 0x0E0102
    private static let usb3UpAdapterType = 0x200102

    // Reads the Thunderbolt topology once, with one short re-scan if no external device
    // is found yet, to reduce false negatives while the IORegistry is still settling just
    // after a connect event.
    //
    // MUST NOT be called on the main thread when 'retryIfEmpty' is set: the retry calls
    // usleep(100 ms). All call sites run on scoringQueue.
    static func thunderboltSnapshot(retryIfEmpty: Bool) -> ThunderboltSnapshot {
        assert(!Thread.isMainThread, "thunderboltSnapshot must not be called on the main thread")
        var snapshot = readThunderboltSnapshot()
        if snapshot.devices.isEmpty && retryIfEmpty {
            usleep(100_000) // 100ms
            snapshot = readThunderboltSnapshot() }
        return snapshot }

    // Single read without the retry, delivered on scoringQueue — MonitorDock's fast path.
    static func thunderboltSnapshotAsync(completion: @escaping @Sendable (ThunderboltSnapshot) -> Void) {
        scoringQueue.async { completion(thunderboltSnapshot(retryIfEmpty: false)) } }

    private static func readThunderboltSnapshot() -> ThunderboltSnapshot {
        let knownUIDs = Preferences.knownDockUIDs
        var devices: [ThunderboltDevice] = []
        var displayTunnel = false, usbTunnel = false

        // Every Thunderbolt device — a dock included — is an IOThunderboltSwitch whose
        // "Depth" is its hop count from the host. The Mac's own controllers sit at depth 0.
        // "Route String" (0 for the host) is the fallback in case a switch omits "Depth".
        forEachService(matching: "IOThunderboltSwitch") { sw in
            let depth = intProperty(sw, "Depth") ?? intProperty(sw, "Route String").map { $0 > 0 ? 1 : 0 } ?? 0
            guard depth > 0 else { return }
            let name = [stringProperty(sw, "Device Vendor Name"), stringProperty(sw, "Device Model Name")]
                .compactMap { $0 }.joined(separator: " ")
            let uid = (property(sw, "UID") as? NSNumber)?.uint64Value ?? 0
            devices.append(ThunderboltDevice(uid: uid, name: name.isEmpty ? "Unknown device" : name))

            forEachChild(of: sw) { port in
                guard let type = intProperty(port, "Adapter Type"),
                      let hops = property(port, "Hop Table") as? [Any], !hops.isEmpty else { return }
                if type == dpOutAdapterType { displayTunnel = true }
                if type == usb3UpAdapterType { usbTunnel = true } } }

        var usbHost = false, ethernet = false, storage = false
        if !devices.isEmpty {
            forEachService(matching: "IOPCIDevice") { dev in
                guard (property(dev, "IOPCITunnelled") as? Bool) == true,
                      let code = (property(dev, "class-code") as? Data).map(classCode) else { return }
                switch (code >> 16, (code >> 8) & 0xFF) {
                case (0x0C, 0x03): usbHost = true
                case (0x02, 0x00): ethernet = true
                case (0x01, _):    storage = true
                default: break } } }

        var score = 0
        var evidence: [String] = []
        func add(_ present: Bool, _ weight: Int, _ label: String) {
            guard present else { return }
            score += weight
            evidence.append(label) }
        add(usbHost, usbHostWeight, "USB host controller")
        add(ethernet, ethernetWeight, "Ethernet controller")
        add(displayTunnel, displayTunnelWeight, "DisplayPort tunnel")
        add(usbTunnel, usbTunnelWeight, "USB3 tunnel")
        if storage { evidence.append("storage") }

        return ThunderboltSnapshot(devices: devices,
                                   knownDock: devices.first { $0.uid != 0 && knownUIDs.contains($0.uid) },
                                   functionScore: score, evidence: evidence, hasStorage: storage) }

    // MARK: – IORegistry helpers
    // IORegistryEntryCreateCFProperty returns +1, which takeRetainedValue balances.
    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        unsafe IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
    private static func intProperty(_ entry: io_registry_entry_t, _ key: String) -> Int? {
        (property(entry, key) as? NSNumber)?.intValue }
    private static func stringProperty(_ entry: io_registry_entry_t, _ key: String) -> String? {
        property(entry, key) as? String }

    // "class-code" is a 4-byte little-endian value: base class, subclass, prog-if.
    private static func classCode(_ data: Data) -> Int {
        data.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) } }

    // Each object is released only AFTER 'body' has read it. An earlier version released
    // it with a 'defer' in a loop body that also advanced to the next object, so the defer
    // released the *next* object before it was read and only the first switch was ever seen.
    private static func forEachService(matching className: String, _ body: (io_object_t) -> Void) {
        guard let matchingDict = unsafe IOServiceMatching(className) else { return }
        var iterator: io_iterator_t = 0
        // Apple can kiss my ass; I'll use the word "master" if I damn well please.
        guard unsafe IOServiceGetMatchingServices(kIOMasterPortDefault, matchingDict, &iterator) == KERN_SUCCESS else { return }
        drain(iterator, body) }

    private static func forEachChild(of entry: io_registry_entry_t, _ body: (io_object_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard unsafe IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { return }
        drain(iterator, body) }

    private static func drain(_ iterator: io_iterator_t, _ body: (io_object_t) -> Void) {
        defer { IOObjectRelease(iterator) }
        var obj = IOIteratorNext(iterator)
        while obj != 0 {
            body(obj)
            IOObjectRelease(obj)   // released only after it has been read
            obj = IOIteratorNext(iterator) } }

    // MARK: - External display detection
    // Returns: 'true' if there is at least one external (non-built-in) display,
    // regardless of whether it is active or asleep, using CoreGraphics.
    static func externalDisplayDetection() -> Bool {
        // Query for the number of online displays first.
        var displayCount: UInt32 = 0
        var err = unsafe CGGetOnlineDisplayList(0, nil, &displayCount)
        guard err == .success, displayCount > 0 else { return false }

        // Allocate array dynamically based on the reported display count.
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        err = unsafe CGGetOnlineDisplayList(displayCount, &displays, &displayCount)
        guard err == .success else { return false }

        for did in displays { if CGDisplayIsBuiltin(did) == 0 { return true } }
        return false }

    // MARK: - Wall power (AC) detection
    // Reads IOKit power source info to determine if the machine is currently on AC/USB power.
    // Returns: 'true' if any power source reports AC power.
    static func isOnACPower() -> Bool {
        guard let snapshotUnmanaged = unsafe IOPSCopyPowerSourcesInfo() else { return false }
        let snapshot = unsafe snapshotUnmanaged.takeRetainedValue()

        guard let sourcesUnmanaged = unsafe IOPSCopyPowerSourcesList(snapshot) else { return false }
        // Bridged to a Swift array rather than walked with CFArrayGetValueAtIndex +
        // unsafeBitCast, which hands back raw pointers.
        let sources = unsafe sourcesUnmanaged.takeRetainedValue() as [CFTypeRef]

        for ps in sources {
            if let desc = unsafe IOPSGetPowerSourceDescription(snapshot, ps)?.takeUnretainedValue() as? [String: Any],
               let powerType = desc[kIOPSPowerSourceStateKey as String] as? String,
               powerType == (kIOPSACPowerValue as String) {
                return true } }
        return false }
}
