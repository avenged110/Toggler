// MARK: – ConnectivityController.swift
// Copyright © 2025 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Implements for Wi-Fi and Bluetooth:
//   – Enabling and disabling interfaces
//   – Checking power state (on/off)
//   – Refreshing cached power state

import Foundation
import Darwin // For dlopen/dlsym and useconds_t
import CoreWLAN

// MARK: – RadioAction
// Pairs the infinitive and past-tense forms of a radio control action so that
// log messages can always use the grammatically correct form for their context.
// Constructed once at each call site; both forms are immutable after init.
private struct RadioAction {
    /// Infinitive form — used after "to" or "cannot": e.g. "disable Wi-Fi"
    let verb: String
    /// Past-tense form — used after "Successfully": e.g. "disabled Wi-Fi"
    let past: String
}

// MARK: – ConnectivityController

// @unchecked Sendable: All mutable state is protected by either cacheQueue
// (concurrent reader-writer for the cached booleans) or refreshQueue (serialized
// read-refresh-write cycle). These invariants are enforced manually and are safe
// by construction; @unchecked Sendable informs the compiler of this without
// requiring full actor isolation, which would demand @MainActor or a custom executor
// and would force every call-site to be async.
final class ConnectivityController: Loggable, @unchecked Sendable {
    nonisolated static let logTag = "[CC]"

    // Treat the class as a shared controller
    static let shared = ConnectivityController()
    // Single shared private API helper instance
    private let privateBT = PrivateBluetoothAPI()

    // Retry constants for Wi-Fi verification loops.
    // Wi-Fi state transitions are fast (typically < 200ms), so a short interval
    // with a moderate attempt count is sufficient.
    private let interfaceRetryMaxAttempts = 6
    private let interfaceRetrySleepMicros: useconds_t = 100_000 // 100ms

    // Retry constants for the Bluetooth fallback verification loop.
    // Bluetooth radio transitions — especially disable — are substantially slower
    // than Wi-Fi and can take 1–3+ seconds on macOS. A longer per-attempt interval
    // with a larger attempt count gives the radio stack adequate time to settle
    // before the loop exhausts and logs a false failure.
    // Budget: 1 immediate seed read + 8 × 400ms = ~3.2 seconds total.
    private let btRetryMaxAttempts  = 8
    private let btRetryInterval: TimeInterval = 0.4 // 400ms

    // Thread-safe cached Wi-Fi and Bluetooth enabled states.
    // Use a concurrent queue + barrier writes to allow concurrent readers and safe writers.
    private let cacheQueue = DispatchQueue(label: "com.toggler.connectivity.cache", attributes: .concurrent)
    private var _isWiFiEnabledCached: Bool = false
    private var _isBluetoothEnabledCached: Bool = false

    // Reader for the Bluetooth fallback path (fast and thread-safe). Everything else reads
    // both flags together through cachedStateSnapshot().
    private var isBluetoothEnabledCached: Bool { cacheQueue.sync { _isBluetoothEnabledCached } }

    // MARK: – Cached state variables
    // Synchronous barrier writers ensure immediate visibility for subsequent reads.
    // 'sync(flags:.barrier)' is used so callers that need immediate consistency
    // (e.g. refreshCachedState() followed by an immediate read) see the new value.
    private func setWiFiEnabledCached(_ newValue: Bool) { cacheQueue.sync(flags: .barrier) {
        self._isWiFiEnabledCached = newValue } }
    private func setBluetoothEnabledCached(_ newValue: Bool) { cacheQueue.sync(flags: .barrier) {
        self._isBluetoothEnabledCached = newValue } }

    // Write both cached values atomically in a single barrier — callers that update
    // both fields (every refresh path) avoid two separate serialization points.
    private func setCachedState(wifi: Bool, bluetooth: Bool) {
        cacheQueue.sync(flags: .barrier) {
            self._isWiFiEnabledCached      = wifi
            self._isBluetoothEnabledCached = bluetooth } }

    // Atomic snapshot of both cached flags
    func cachedStateSnapshot() -> (wifi: Bool, bluetooth: Bool) { return cacheQueue.sync {
        (_isWiFiEnabledCached, _isBluetoothEnabledCached) } }

    // Serial queue that serializes the full read-refresh-write cycle inside
    // refreshCachedState(). This prevents two concurrent callers (e.g. AppDelegate on
    // main and EventLogic on logicQueue) from redundantly querying the APIs at the same
    // time and from racing on the rate-limiter state. The underlying cache reads and
    // writes still use cacheQueue's reader-writer pattern for all other callers.
    private let refreshQueue = DispatchQueue(label: "com.toggler.connectivity.refresh", qos: .utility)

    // Minimum interval between identical cached-state log lines emitted by both
    // refreshCachedState() and refreshCachedStateSync(). Defined once here so
    // both callers use exactly the same value and cannot drift independently.
    private let cachedStateHeartbeatCooldown: TimeInterval = 5.0

    // MARK: – Private Bluetooth API wrapper
    // Dynamically resolves Apple's private IOBluetooth preference functions:
    //  - IOBluetoothPreferenceSetControllerPowerState(int)
    //  - IOBluetoothPreferenceGetControllerPowerState(void)
    // Resolution is done with dlopen/dlsym at runtime so the application will not hard-link
    // against a private framework. Availability is checked and logged at init().
    // Use of these functions was inspired by blueutil (Copyright (c) 2011-2026 Ivan Kuchin,
    // originally by Frederik Seiffert; MIT; https://github.com/toy/blueutil). No blueutil code
    // is included; this wrapper is an independent Swift implementation.

    // @unchecked Sendable: All mutable state (libHandle, setFn, getFn) is written exactly
    // once during init() and is never mutated thereafter; verifyQueue is a DispatchQueue
    // (itself Sendable). Post-init the instance is effectively immutable and safe to share
    // across queues without any additional synchronization.
    // @safe: the dlopen handle and resolved C function pointers are private; callers see
    // only Bool-based methods, and each raw use is marked 'unsafe' where it happens.
    @safe private final class PrivateBluetoothAPI: @unchecked Sendable {
        typealias SetPowerFn = @convention(c) (Int32) -> Int32
        typealias GetPowerFn = @convention(c) () -> Int32

        private var libHandle: UnsafeMutableRawPointer?
        private var setFn: SetPowerFn?
        private var getFn: GetPowerFn?
        // Reused across all setPowerStateAsync calls — queue creation allocates a
        // kernel object and should not happen per-invocation.
        private let verifyQueue = DispatchQueue(label: "com.toggler.privateBT.verify", qos: .utility)

        init() {
            // Candidate locations historically containing the symbols.
            // If Apple moves these, availability will be false and caller should handle it.
            let candidates = [
                "/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth",
                "/System/Library/Frameworks/IOBluetooth.framework/Versions/Current/IOBluetooth" ]
            for path in candidates { if let h = unsafe dlopen(path, RTLD_NOW) { unsafe libHandle = h; break } }
            if let h = unsafe libHandle {
                if let sym = unsafe dlsym(h, "IOBluetoothPreferenceSetControllerPowerState") {
                    setFn = unsafe unsafeBitCast(sym, to: SetPowerFn.self) }
                if let sym = unsafe dlsym(h, "IOBluetoothPreferenceGetControllerPowerState") {
                    getFn = unsafe unsafeBitCast(sym, to: GetPowerFn.self) } } }
        deinit { if let h = unsafe libHandle { unsafe dlclose(h) } }

        var available: Bool { return setFn != nil && getFn != nil }

        // Attempt to set the power state. Returns 'true' if the call was made and verification
        // (via getPowerState) reports the expected state within a few short retries.
        // Non-blocking async wrapper: Runs the set + verification without blocking
        // any thread with sleeps by scheduling verification attempts using asyncAfter.
        // Completion is invoked on a global utility queue (to match prior async behavior).
        func setPowerStateAsync(_ on: Bool, retryInterval: TimeInterval? = nil,
                               completion: @escaping @Sendable (Bool) -> Void) {
            // Quick failure path if not available
            guard let setter = setFn else { DispatchQueue.global(qos: .utility).async {
                completion(false) }; return }

            // Call setter synchronously (this should be quick), then verify non-blocking.
            _ = setter(on ? 1 : 0)

            // Capture all verification parameters as immutable constants so they can be
            // safely passed through @Sendable asyncAfter closures without mutation.
            let desired = on
            let maxAttempts = 6
            // Allow the caller to supply a wider interval for slow-transitioning interfaces
            // (e.g. Bluetooth radio disable); fall back to the built-in default otherwise.
            let interval = retryInterval ?? (Double(interfaceRetrySleepMicrosForVerify) / 1_000_000.0)

            // First check immediately (don't wait full interval before the first verification).
            // Attempt 0 is consumed here; the named instance method handles all subsequent
            // scheduled retries. Using a named method (rather than a local function) avoids
            // the "capture of local function with non-Sendable type" warning that the compiler
            // emits when a local function is referenced from within a @Sendable closure.
            verifyQueue.async { [weak self] in
                guard let self = self else {
                    DispatchQueue.global(qos: .utility).async { completion(false) }
                    return }
                if let observed = self.getPowerState(), observed == desired {
                    DispatchQueue.global(qos: .utility).async { completion(true) }
                    return }
                // Not yet observed; start scheduled checks beginning at attempt 1
                // (attempt 0 was the immediate check just performed above).
                self.schedulePowerStateCheck(desired: desired, maxAttempts: maxAttempts,
                                             interval: interval, attempt: 1,
                                             completion: completion) } }

        // Reads the controller power state.
        // Returns: (optional bool) 'true' if on, 'false' if off, 'nil' if N/A or error
        func getPowerState() -> Bool? {
            guard let getter = getFn else { return nil }
            let r = getter()
            return r != 0 }

        // Named instance method for the recursive verification loop used by setPowerStateAsync.
        // Promoting this out of a local function eliminates the compiler warning:
        //   "Capture of local function with non-Sendable type '(Int) -> ()' in a @Sendable closure"
        // Each invocation receives the current attempt index as an immutable value parameter
        // and passes attempt + 1 to the next scheduled call; no mutable state is ever captured.
        private func schedulePowerStateCheck(desired: Bool, maxAttempts: Int, interval: TimeInterval,
                                             attempt: Int, completion: @escaping @Sendable (Bool) -> Void) {
            verifyQueue.asyncAfter(deadline: .now() + interval) { [weak self] in
                guard let self = self else {
                    DispatchQueue.global(qos: .utility).async { completion(false) }
                    return }
                if let observed = self.getPowerState(), observed == desired {
                    DispatchQueue.global(qos: .utility).async { completion(true) }
                    return }
                let next = attempt + 1
                if next >= maxAttempts {
                    DispatchQueue.global(qos: .utility).async { completion(false) }
                    return }
                self.schedulePowerStateCheck(desired: desired, maxAttempts: maxAttempts,
                                             interval: interval, attempt: next,
                                             completion: completion) } }

        // Default verification interval used by setPowerStateAsync when the caller does
        // not supply one. 100 ms — matches interfaceRetrySleepMicros on the outer class.
        // 'private' rather than 'fileprivate': it is read only from within this nested
        // type, so the wider access level advertised a dependency that does not exist.
        private let interfaceRetrySleepMicrosForVerify: useconds_t = 100_000 }

    // MARK: – Initialization
    // Log private-API availability on init
    private init() {
        if privateBT.available {
            log("Using private IOBluetooth API for Bluetooth control.")
        } else {
            log("WARNING: Private IOBluetooth API not available on this system. Bluetooth operations will no-op.") } }

    // MARK: – Public Methods
    // Refresh cached states for Wi-Fi and Bluetooth.
    // Call this on-demand or from event notifications to avoid polling.
    // Serialized on refreshQueue to prevent concurrent callers from racing on the
    // read-modify-compare-write cycle and redundantly hammering the underlying APIs.
    func refreshCachedState() {
        refreshQueue.async { [weak self] in self?.performCachedStateRefresh(label: "Refreshed") } }

    // Synchronous variant of refreshCachedState().
    // Blocks the calling thread until the read-modify-write cycle is complete,
    // guaranteeing that any cache read immediately following this call sees the
    // freshly updated values. Used by EventLogic handlers that need a consistent
    // snapshot before acting on an event.
    // MUST NOT be called from the main thread, cacheQueue, or refreshQueue.
    func refreshCachedStateSync() {
        // Enforce the documented queue-safety invariant. Calling refreshQueue.sync from
        // refreshQueue itself would deadlock (serial queue re-entry). The main-thread
        // guard prevents an inadvertent main-thread block, since cacheQueue.sync calls
        // inside performCachedStateRefresh can also queue up on cacheQueue.
        dispatchPrecondition(condition: .notOnQueue(refreshQueue))
        refreshQueue.sync { [weak self] in self?.performCachedStateRefresh(label: "Refreshed (sync)") } }

    // Shared body for both refresh variants. Always runs on refreshQueue.
    // Reads current hardware state, writes both cached values in a single barrier,
    // and conditionally logs based on state change or heartbeat rate-limit.
    private func performCachedStateRefresh(label: String) {
        // Single atomic snapshot of both prior values — one serialization point on
        // cacheQueue instead of two separate synced reads, and a consistent pair that
        // cannot be split by an interleaving barrier write between the two reads.
        let previous = cachedStateSnapshot()
        let previousWiFi = previous.wifi
        let previousBT   = previous.bluetooth

        let currentWiFi = isWiFiEnabled()
        let currentBT   = isBluetoothEnabled()

        // Single barrier write: atomically updates both cached values at once,
        // halving the number of serialization points vs. two separate barrier writes.
        setCachedState(wifi: currentWiFi, bluetooth: currentBT)

        let changed = (previousWiFi != currentWiFi) || (previousBT != currentBT)
        if changed || RateLimiter.shouldPerform(key: "cc.cachedState",
            cooldown: cachedStateHeartbeatCooldown) {
            log("\(label) cached state: wifi=\(currentWiFi), bt=\(currentBT)") } }

    // Use CoreWLAN to check Wi-Fi interface power status.
    // CWWiFiClient.shared() is documented to be safe from any thread as of macOS 10.10;
    // all calls to this method are serialized on either refreshQueue or the global utility
    // queue used by setWiFiPower, so no concurrent access to the interface object occurs.
    // Returns: 'true' if powered on, 'false' otherwise
    func isWiFiEnabled() -> Bool {
        guard let iface = CWWiFiClient.shared().interface() else {
            log("No Wi-Fi interface available via CoreWLAN.")
            return false }
        let on = iface.powerOn()
        log("Wi-Fi power state read via CoreWLAN: \(on ? "ON" : "OFF")")
        return on }

    // Use IOBluetooth to check Bluetooth interface power status
    // Returns: 'true' if powered on, 'false' otherwise
    func isBluetoothEnabled() -> Bool {
        if let on = privateBT.getPowerState() {
            log("Bluetooth power state read via IOBluetooth: \(on ? "ON" : "OFF")")
            return on
        } else {
            log("Private Bluetooth API unavailable — reporting Bluetooth as OFF")
            return false } }

    // Optional completion for callers that must know when an operation has finished and
    // whether its verification observed the requested state (the sleep path, which holds
    // system sleep until the radios are confirmed off). Invoked exactly once, on a global
    // utility queue. Every operation below reaches exactly one terminal branch, each of
    // which calls it.
    typealias RadioCompletion = @Sendable (_ verified: Bool) -> Void

    // MARK: – Wi-Fi control (CoreWLAN)
    func disableWiFi(completion: RadioCompletion? = nil) {
        setWiFiPower(false, action: RadioAction(verb: "disable Wi-Fi", past: "disabled Wi-Fi"), completion: completion) }
    func enableWiFi(completion: RadioCompletion? = nil) {
        setWiFiPower(true, action: RadioAction(verb: "enable Wi-Fi", past: "enabled Wi-Fi"), completion: completion) }

    // MARK: – Bluetooth control (IOBluetooth)
    func disableBluetooth(completion: RadioCompletion? = nil) {
        setBluetoothPower(false, action: RadioAction(verb: "disable Bluetooth", past: "disabled Bluetooth"), completion: completion) }
    func enableBluetooth(completion: RadioCompletion? = nil) {
        setBluetoothPower(true, action: RadioAction(verb: "enable Bluetooth", past: "enabled Bluetooth"), completion: completion) }

    // MARK: – Wi-Fi helper (CoreWLAN)
    // Sets Wi-Fi power and verifies with a few short retries to avoid flakiness.
    private func setWiFiPower(_ on: Bool, action: RadioAction, completion: RadioCompletion?) {
        guard let iface = CWWiFiClient.shared().interface() else {
            log("ERROR: No Wi-Fi interface available; cannot \(action.verb).")
            DispatchQueue.global(qos: .utility).async { completion?(false) }
            return }

        // Attempt to set power (synchronous call). Even if setPower threw, try to
        // verify once (some systems flip state even if an error was thrown)
        do { try iface.setPower(on)
        } catch {
            log("ERROR: CoreWLAN setPower(\(on)) threw while attempting to \(action.verb): \(error.localizedDescription)") }

        // Capture all values needed by the async verification as immutable constants
        // so no mutable state crosses the @Sendable closure boundary.
        let desired = on
        let maxAttempts = interfaceRetryMaxAttempts
        let interval = TimeInterval(interfaceRetrySleepMicros) / 1_000_000.0

        // Schedule verification asynchronously to avoid blocking the caller thread.
        // Route directly to the named instance method from the initial dispatch —
        // using a local function here would produce the same "capture of local function
        // with non-Sendable type" warning that was fixed in PrivateBluetoothAPI.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { completion?(false); return }
            self.scheduleWiFiCheck(desired: desired, action: action,
                                   maxAttempts: maxAttempts, interval: interval, attempt: 0,
                                   completion: completion) } }

    // Extracted named helper so the recursive asyncAfter closure can reference it
    // without capturing a local function across a @Sendable boundary (which the
    // compiler rejects under strict concurrency).
    private func scheduleWiFiCheck(desired: Bool, action: RadioAction,
                                   maxAttempts: Int, interval: TimeInterval, attempt: Int,
                                   completion: RadioCompletion?) {
        let observed = isWiFiEnabled()
        if observed == desired {
            setWiFiEnabledCached(observed)
            log("Successfully executed CoreWLAN to \(action.verb).")
            completion?(true)
            return }
        let next = attempt + 1
        if next >= maxAttempts {
            setWiFiEnabledCached(observed)
            log("ERROR: Failed to \(action.verb) (verification did not observe expected state). Last observed state: \(observed ? "ON" : "OFF")")
            completion?(false)
            return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self = self else { completion?(false); return }
            self.scheduleWiFiCheck(desired: desired, action: action,
                                   maxAttempts: maxAttempts, interval: interval, attempt: next,
                                   completion: completion) } }

    // MARK: – Bluetooth helper (IOBluetooth)
    // Sets Bluetooth power and verifies with a few short retries to avoid flakiness.
    private func setBluetoothPower(_ desired: Bool, action: RadioAction, completion: RadioCompletion?) {
        guard privateBT.available else {
            log("ERROR: IOBluetooth unavailable; cannot \(action.verb).")
            DispatchQueue.global(qos: .utility).async { completion?(false) }
            return }

        // Use the Bluetooth-specific retry budget — Bluetooth radio transitions are
        // substantially slower than Wi-Fi and need a wider verification window.
        let maxAttempts = btRetryMaxAttempts
        let interval    = btRetryInterval

        // Start the set operation using the private API's async wrapper.
        // Pass the wider Bluetooth interval so the internal verification loop inside
        // setPowerStateAsync also respects the longer transition time.
        // The private API already does an internal sync verification; only
        // run a fallback verification if that check fails.
        privateBT.setPowerStateAsync(desired, retryInterval: interval) { [weak self] completionSucceeded in
            guard let self = self else { completion?(false); return }

            if completionSucceeded {
                // Private API verified the state successfully — no extra reads needed.
                self.setBluetoothEnabledCached(desired)
                self.log("Successfully \(action.past) via IOBluetooth.")
                completion?(true)
                return }

            // Fallback: Seed lastObserved with a fresh live read rather than the
            // potentially stale cached value so the exhaustion-path cache write is accurate.
            // Then run a local verification loop via the extracted named helper.
            let seedObserved = self.privateBT.getPowerState() ?? self.isBluetoothEnabledCached
            self.scheduleBluetoothCheck(desired: desired, action: action,
                                        maxAttempts: maxAttempts, interval: interval,
                                        attempt: 0, lastObserved: seedObserved,
                                        completion: completion) } }

    // Extracted named helper for the Bluetooth fallback verification loop.
    // Mirrors scheduleWiFiCheck: each invocation captures immutable values and
    // schedules the next attempt rather than mutating a shared counter, keeping
    // all closures strictly @Sendable-safe.
    private func scheduleBluetoothCheck(desired: Bool, action: RadioAction,
                                        maxAttempts: Int, interval: TimeInterval,
                                        attempt: Int, lastObserved: Bool,
                                        completion: RadioCompletion?) {
        if let observed = privateBT.getPowerState() {
            if observed == desired {
                setBluetoothEnabledCached(observed)
                log("Successfully \(action.past) via IOBluetooth (fallback verification).")
                completion?(true)
                return }
            let next = attempt + 1
            if next >= maxAttempts {
                // Retry budget exhausted. Do one final fresh read so the cache reflects
                // the most current hardware state rather than the stale mid-retry value.
                // This prevents a long-lived stale cache entry in the common case where
                // the radio transition simply outlasted the verification window.
                let finalState = privateBT.getPowerState() ?? observed
                setBluetoothEnabledCached(finalState)
                log("ERROR: Failed to \(action.verb) (verification did not observe expected state). Last observed state: \(finalState ? "ON" : "OFF")")
                completion?(finalState == desired)
                return }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + interval) { [weak self] in
                guard let self = self else { completion?(false); return }
                self.scheduleBluetoothCheck(desired: desired, action: action,
                                            maxAttempts: maxAttempts, interval: interval,
                                            attempt: next, lastObserved: observed,
                                            completion: completion) }
        } else {
            // getPowerState() returned nil — API became unavailable mid-retry.
            let next = attempt + 1
            if next >= maxAttempts {
                setBluetoothEnabledCached(lastObserved)
                log("ERROR: Failed to verify Bluetooth (API unavailable during retry). Last observed state: \(lastObserved ? "ON" : "OFF")")
                completion?(false)
                return }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + interval) { [weak self] in
                guard let self = self else { completion?(false); return }
                self.scheduleBluetoothCheck(desired: desired, action: action,
                                            maxAttempts: maxAttempts, interval: interval,
                                            attempt: next, lastObserved: lastObserved,
                                            completion: completion) } } }
}
