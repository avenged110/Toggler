// MARK: – Preferences.swift
// Copyright © 2025 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Centralized preferences wrapper used across Toggler.app, providing
// a single place to read/write UserDefaults-backed settings.

import Foundation

struct Preferences: Loggable {
    nonisolated static let logTag = "[PREFS]"
    // UserDefaults.standard is internally thread-safe for standard read/write operations
    // per Apple's documentation. Preferences accessors are called from multiple contexts
    // (main thread, EventLogic's logicQueue, ConnectivityController's refreshQueue), so
    // the thread-safety of UserDefaults.standard is the actual guarantee here, not
    // actor isolation. A computed accessor rather than a stored 'nonisolated(unsafe)'
    // static: there is no shared stored state for the compiler to object to, so no
    // escape hatch is needed under strict concurrency or strict memory safety.
    private static var defaults: UserDefaults { .standard }

    // Built-in defaults (single canonical copy for registration and first-run writes)
    private static let builtInSettleProbeDelays: [TimeInterval] = [1.3, 1.8, 2.5, 2.8, 3.1]
    private static let builtInHeuristicsThreshold = 3
    private static let builtInConsecutiveAcceptanceThreshold = 3
    private static let builtInUndockIntentDebounceWindow = 3.0

    // Live count of currently-stored settle probe delays, falling back to the built-in
    // default count only if none have been stored yet. This must track the *actual*
    // number of probes, not a fixed constant: consecutiveAcceptanceThreshold's upper
    // bound is clamped against this value, and AdvancedSettingsSection.commitConsecutive()
    // separately validates user input against Preferences.settleProbeDelays.count.
    // Hardcoding this to builtInSettleProbeDelays.count (previously always 5) would let
    // the two silently diverge whenever the user customizes the probe sequence to fewer
    // than 5 entries, and would collapse to an invalid 0-upper-bound if the live count
    // were ever 0.
    private static var settleProbeDelaysCount: Int { settleProbeDelays.count }

    // Keys used for UserDefaults.
    private enum Keys {
        static let disableWiFiDuringSleep =
            "preferences.disableWiFiDuringSleep"
        static let disableBluetoothDuringSleep =
            "preferences.disableBluetoothDuringSleep"
        static let toggleWiFiOnDockEvent =
            "preferences.toggleWiFiOnDockEvent"
        static let toggleBluetoothOnDockEvent =
            "preferences.toggleBluetoothOnDockEvent"
        static let loggingEnabled =
            "preferences.loggingEnabled"
        static let heuristicsThreshold =
            "preferences.heuristicsThreshold"
        static let consecutiveAcceptanceThreshold =
            "preferences.consecutiveAcceptanceThreshold"
        static let undockIntentDebounceWindow =
            "preferences.undockIntentDebounceWindow"
        static let settleProbeDelays =
            "preferences.settleProbeDelays"
        static let bluetoothWasForced =
            "preferences.bluetoothWasForced"
        static let bluetoothPreForcedState =
            "preferences.bluetoothPreForcedState"
        static let knownDocks =
            "preferences.knownDocks" }

    // Expose the key strings other modules need: EventLogic routes preference-change
    // notifications by the two dock keys, and SettingsView binds the logging toggle's
    // @AppStorage to loggingEnabled. (Single canonical definition of the key names.)
    static let toggleWiFiOnDockEventKey          = Keys.toggleWiFiOnDockEvent
    static let toggleBluetoothOnDockEventKey     = Keys.toggleBluetoothOnDockEvent
    static let loggingEnabledKey                 = Keys.loggingEnabled

    // Register sane defaults once. Guarantees behavior for the rest
    // of the application without callers needing special 'nil' checks.
    private static let _registeredDefaults: Void = {
        let defaultsToRegister: [String: Any] = [
            Keys.disableWiFiDuringSleep: false,
            Keys.disableBluetoothDuringSleep: false,
            Keys.toggleWiFiOnDockEvent: true,
            Keys.toggleBluetoothOnDockEvent: true,
            Keys.loggingEnabled: false,
            Keys.heuristicsThreshold: builtInHeuristicsThreshold,
            Keys.consecutiveAcceptanceThreshold: builtInConsecutiveAcceptanceThreshold,
            Keys.undockIntentDebounceWindow: builtInUndockIntentDebounceWindow,
            Keys.settleProbeDelays: builtInSettleProbeDelays ]
        defaults.register(defaults: defaultsToRegister) }()

    // Ensure the registration has run (force the static initializer).
    // Made non-private so callers (AppDelegate) can explicitly ensure
    // registration early during app launch, if desired.
    static func ensureDefaultsRegistered() { _ = _registeredDefaults }

    // Helper: Post preferences-changed notification with key
    private static func postPreferenceChangedNotification(key: String) { NotificationCenter.default.post(name: .togglerPreferencesChanged, object: nil, userInfo: ["key": key]) }

    // MARK: - Change guard

    // Normalizes a raw UserDefaults dictionary to [String: Bool], handling both native
    // Bool values and NSNumber-bridged values produced by UserDefaults plist serialization.
    // Used by both setIfChanged and bluetoothPreForcedStateDict to avoid duplicated
    // normalization logic that could otherwise drift out of sync.
    private static func normalizeBoolDict(_ raw: [String: Any]) -> [String: Bool] {
        var out: [String: Bool] = [:]
        for (k, v) in raw {
            if let b = v as? Bool { out[k] = b }
            else if let n = v as? NSNumber { out[k] = n.boolValue } }
        return out }

    // Helper: Sets a value only if it actually differs, logs, and posts a notification.
    private static func setIfChanged<T: Equatable>(_ value: T, forKey key: String, logMessage: String? = nil) {
        // Compare current value using typed accessors where possible so registered defaults
        // (registered via register(defaults:)) are respected.
        var isSame = false

        if let v = value as? Bool { isSame = defaults.bool(forKey: key) == v
        } else if let v = value as? Int { isSame = defaults.integer(forKey: key) == v
        } else if let v = value as? Double { isSame = defaults.double(forKey: key) == v
        } else if let v = value as? String { isSame = defaults.string(forKey: key) == v
        } else if let v = value as? [String] {
            if let current = defaults.array(forKey: key) as? [String] { isSame = current == v
            } else { isSame = false }
        } else if let v = value as? [Double] {
            if let arr = defaults.array(forKey: key) as? [Double] { isSame = arr == v
            } else if let arrn = defaults.array(forKey: key) as? [NSNumber] { isSame = arrn.map { $0.doubleValue } == v
            } else { isSame = false }
        } else if let v = value as? [String: Bool] {
            if let dict = defaults.dictionary(forKey: key) {
                isSame = normalizeBoolDict(dict) == v
            } else { isSame = false }
        } else {
            // Fallback for other Equatable types (may fail for bridged/unexpected types)
            let current: T? = defaults.object(forKey: key) as? T
            isSame = (current == value) }

        if isSame { return }

        defaults.set(value, forKey: key)
        if let message = logMessage { log(message) }
        postPreferenceChangedNotification(key: key) }

    // MARK: – Thresholds
    // Minimum score required to consider the laptop as docked
    static var heuristicsThreshold: Int {
        get {
            let v = defaults.integer(forKey: Keys.heuristicsThreshold)
            let clamped = min(max(1, v), Heuristics.maxScore)
            return clamped }
        set {
            ensureDefaultsRegistered()
            let safe = min(max(1, newValue), Heuristics.maxScore)
            setIfChanged(safe, forKey: Keys.heuristicsThreshold, logMessage: "heuristicsThreshold set to \(safe)") } }

    // Minimum number of consecutive dock state 'settle probes'
    static var consecutiveAcceptanceThreshold: Int {
        get {
            let v = defaults.integer(forKey: Keys.consecutiveAcceptanceThreshold)
            let maxAllowed = self.settleProbeDelaysCount
            // Lower bound is 1: a value of 0 would cause the high-confidence shortcut
            // to accept immediately on the very first probe (consecutiveCount >= 0 is
            // always true), bypassing the settle sequence entirely.
            let clamped = min(max(1, v), maxAllowed)
            return clamped }
        set {
            ensureDefaultsRegistered()
            let maxAllowed = self.settleProbeDelaysCount
            let safe = min(max(1, newValue), maxAllowed)
            setIfChanged(safe, forKey: Keys.consecutiveAcceptanceThreshold, logMessage: "consecutiveAcceptanceThreshold set to \(safe)") } }

    // Seconds to wait after detecting a potential undock before confirming it
    // (helps prevent false undock detections from brief connection fluctuations).
    static var undockIntentDebounceWindow: TimeInterval {
        get {
            let v = defaults.double(forKey: Keys.undockIntentDebounceWindow)
            let clamped = max(1.0, min(10.0, v)) // Minimum 1, maximum 10 seconds
            return clamped }
        set {
            ensureDefaultsRegistered()
            let safe = max(1.0, min(10.0, newValue)) // Minimum 1, maximum 10 seconds
            setIfChanged(safe, forKey: Keys.undockIntentDebounceWindow, logMessage: "undockIntentDebounceWindow set to \(safe)") } }

    // MARK: - Toggles (sleep/wake, dock/undock, logging)
    static var disableWiFiDuringSleep: Bool {
        get { return defaults.bool(forKey: Keys.disableWiFiDuringSleep) }
        set {
            ensureDefaultsRegistered()
            setIfChanged(newValue, forKey: Keys.disableWiFiDuringSleep, logMessage: "disableWiFiDuringSleep set to \(newValue)") } }

    static var disableBluetoothDuringSleep: Bool {
        get { return defaults.bool(forKey: Keys.disableBluetoothDuringSleep) }
        set {
            ensureDefaultsRegistered()
            setIfChanged(newValue, forKey: Keys.disableBluetoothDuringSleep, logMessage: "disableBluetoothDuringSleep set to \(newValue)") } }

    static var toggleWiFiOnDockEvent: Bool {
        get { return defaults.bool(forKey: Keys.toggleWiFiOnDockEvent) }
        set {
            ensureDefaultsRegistered()
            setIfChanged(newValue, forKey: Keys.toggleWiFiOnDockEvent, logMessage: "toggleWiFiOnDockEvent set to \(newValue)") } }

    static var toggleBluetoothOnDockEvent: Bool {
        get { return defaults.bool(forKey: Keys.toggleBluetoothOnDockEvent) }
        set {
            ensureDefaultsRegistered()
            setIfChanged(newValue, forKey: Keys.toggleBluetoothOnDockEvent, logMessage: "toggleBluetoothOnDockEvent set to \(newValue)") } }

    static var loggingEnabled: Bool {
        get { return defaults.bool(forKey: Keys.loggingEnabled) }
        set {
            ensureDefaultsRegistered()
            setIfChanged(newValue, forKey: Keys.loggingEnabled, logMessage: "loggingEnabled set to \(newValue)") } }

    // MARK: – Settle probe intervals
    static var settleProbeDelays: [TimeInterval] {
        get {
            ensureDefaultsRegistered()
            if let arr = defaults.array(forKey: Keys.settleProbeDelays) as? [Double], !arr.isEmpty { return arr }
            // Fallback in case values were stored as NSNumber (bridging)
            if let arrNum = defaults.array(forKey: Keys.settleProbeDelays) as? [NSNumber], !arrNum.isEmpty { return arrNum.map { $0.doubleValue } }
            // Write built-in defaults if missing
            log("settleProbeDelays missing; writing built-in defaults")
            defaults.set(builtInSettleProbeDelays, forKey: Keys.settleProbeDelays)
            postPreferenceChangedNotification(key: Keys.settleProbeDelays)
            return builtInSettleProbeDelays }
        set {
            ensureDefaultsRegistered()
            // Sanitize: Keep strictly positive intervals and cap at 5 entries
            var sanitized = newValue.filter { $0 > 0.0 }
            if sanitized.count > 5 { sanitized = Array(sanitized.prefix(5)) }
            // Defense-in-depth: AdvancedSettingsSection.commitProbe() already refuses to submit an
            // empty result, but never let this setter itself persist an empty array —
            // settleProbeDelaysCount reaching 0 would collapse consecutiveAcceptanceThreshold's
            // clamp to 0, violating its documented minimum of 1.
            if sanitized.isEmpty { sanitized = [builtInSettleProbeDelays[0]] }
            setIfChanged(sanitized, forKey: Keys.settleProbeDelays, logMessage: "settleProbeDelays updated (\(sanitized.count) entries)") } }

    // MARK: – 'Reset to defaults' helpers
    static func resetThresholdsToDefaults() {
        Preferences.heuristicsThreshold = builtInHeuristicsThreshold
        Preferences.consecutiveAcceptanceThreshold = builtInConsecutiveAcceptanceThreshold
        Preferences.undockIntentDebounceWindow = builtInUndockIntentDebounceWindow }
    static func resetSettleProbeDelaysToDefaults() {
        Preferences.settleProbeDelays = Preferences.builtInSettleProbeDelays }
}

// MARK: – Bluetooth Pre-Forced State
// Stores the user's Bluetooth toggle preference(s) before it was forcibly
// overridden due to denied TCC permissions. Can be nil if never forced.
extension Preferences {
    // Dictionary representation of the pre-forced Bluetooth settings.
    private static var bluetoothPreForcedStateDict: [String: Bool]? {
        get {
            guard let raw = defaults.dictionary(forKey: Keys.bluetoothPreForcedState) else { return nil }
            let out = normalizeBoolDict(raw)
            return out.isEmpty ? nil : out }
        set {
            ensureDefaultsRegistered()
            if let dict = newValue {
                // Use explicit bridging-friendly storage
                setIfChanged(dict, forKey: Keys.bluetoothPreForcedState, logMessage: "bluetoothPreForcedState saved")
            } else {
                if defaults.object(forKey: Keys.bluetoothPreForcedState) != nil {
                    defaults.removeObject(forKey: Keys.bluetoothPreForcedState)
                    postPreferenceChangedNotification(key: Keys.bluetoothPreForcedState) } } } }

    // Flag: Are Bluetooth toggles currently forced off due to TCC denial?
    // Written directly — bypasses setIfChanged so no spurious preferencesChanged
    // notification is fired for this internal bookkeeping key.
    static var bluetoothWasForced: Bool {
        get { return defaults.bool(forKey: Keys.bluetoothWasForced) }
        set {
            ensureDefaultsRegistered()
            guard defaults.bool(forKey: Keys.bluetoothWasForced) != newValue else { return }
            defaults.set(newValue, forKey: Keys.bluetoothWasForced)
            log("bluetoothWasForced set to \(newValue)") } }

    // Saves the current user preferences for Bluetooth toggles (before forcing them off).
    static func saveBluetoothPreForcedState() {
        let dict: [String: Bool] = [
            Keys.disableBluetoothDuringSleep: disableBluetoothDuringSleep,
            Keys.toggleBluetoothOnDockEvent: toggleBluetoothOnDockEvent ]
        bluetoothPreForcedStateDict = dict
        bluetoothWasForced = true
        log("Saved Bluetooth pre-forced state: \(dict)") }

    // Restores the saved user preferences for Bluetooth toggles.
    static func restoreBluetoothPreForcedState() {
        guard let dict = bluetoothPreForcedStateDict else { return }
        if let disable = dict[Keys.disableBluetoothDuringSleep] {
            disableBluetoothDuringSleep = disable }
        if let toggle = dict[Keys.toggleBluetoothOnDockEvent] {
            toggleBluetoothOnDockEvent = toggle }
        bluetoothPreForcedStateDict = nil
        bluetoothWasForced = false
        log("Restored Bluetooth pre-forced state: \(dict)") }
}

// MARK: – Recognized docks
// Thunderbolt devices that Heuristics classified as docks beyond reasonable doubt, keyed
// by their Thunderbolt UID. MonitorDock treats a connection from any of them as a dock
// event straight away (the fast path). Stored as [decimal UID string: device name]
// because a UInt64 UID does not always fit a property-list integer.
extension Preferences {
    private static var knownDocksRaw: [String: String] {
        defaults.dictionary(forKey: Keys.knownDocks) as? [String: String] ?? [:] }

    static var knownDocks: [UInt64: String] {
        Dictionary(knownDocksRaw.compactMap { key, name in UInt64(key).map { ($0, name) } },
                   uniquingKeysWith: { first, _ in first }) }

    static var knownDockUIDs: Set<UInt64> { Set(knownDocks.keys) }

    // Remembers a dock. Returns 'false' if it was already known.
    @discardableResult
    static func rememberDock(uid: UInt64, name: String) -> Bool {
        ensureDefaultsRegistered()
        var raw = knownDocksRaw
        guard raw[String(uid)] == nil else { return false }
        raw[String(uid)] = name
        setIfChanged(raw, forKey: Keys.knownDocks, logMessage: "Recognized dock: \(name) (UID \(uid))")
        return true }

    static func forgetKnownDocks() {
        guard defaults.object(forKey: Keys.knownDocks) != nil else { return }
        defaults.removeObject(forKey: Keys.knownDocks)
        log("Forgot all recognized docks")
        postPreferenceChangedNotification(key: Keys.knownDocks) }
}
