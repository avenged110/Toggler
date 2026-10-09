// MARK: – Utilities.swift
// Copyright © 2025 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Consolidates SendableBox, fixed-point formatting, InputValidation, and RateLimiter
// for Toggler.app.

import Cocoa
import SwiftUI
import Synchronization // Mutex (RateLimiter)

// MARK: – SendableBox
// A lightweight @unchecked Sendable wrapper used to carry C/CF reference types
// (CFRunLoopSource, IONotificationPortRef, io_connect_t) across concurrency boundaries
// into @Sendable closures. Swift cannot automatically verify Sendable conformance for
// opaque C/CF pointer types, so this box asserts the guarantee explicitly.
// Safety: values boxed here are always immutable from Swift's perspective — they are
// ref-counted C objects (or plain integer handles) whose mutation occurs exclusively
// through thread-safe C APIs on the main thread, the same thread to which the closures
// are dispatched.
// Shared by MonitorDock and MonitorSleep; it lives here rather than inside either
// monitor so that neither file owns a type the other depends on.
struct SendableBox<T>: @unchecked Sendable { let value: T }

// MARK: – Fixed-point formatting
// Replaces String(format: "%.Nf", value), whose C varargs are unsafe under strict memory
// safety. The POSIX locale pins the decimal separator to "." — the probe-delay fields
// accept nothing else, and log lines stay identical whatever the user's locale.
extension Double {
    func fixed(_ digits: Int) -> String {
        formatted(.number.precision(.fractionLength(digits)).grouping(.never)
            .locale(Locale(identifier: "en_US_POSIX"))) } }

// MARK: – InputValidation

// MARK: - WholeNumberTextField
/// An NSTextField bridge that silently drops any character that is not a decimal
/// digit and enforces a maximum character count. Suitable for all three Threshold
/// fields in the Advanced settings tab.
struct WholeNumberTextField: NSViewRepresentable {
    @Binding var text: String
    /// Maximum number of characters the field will accept (e.g. 1 for values 1–5,
    /// 2 for values 1–10). Non-digits are stripped before this limit is applied.
    let maxLength: Int
    /// Called when the user commits the field by pressing Return.
    var onSubmit: () -> Void = {}

    // One shared formatter instance per legal maxLength value.
    private static let formatter1 = IntegerOnlyFormatter(maxLength: 1)
    private static let formatter2 = IntegerOnlyFormatter(maxLength: 2)

    private var sharedFormatter: IntegerOnlyFormatter {
        maxLength == 1 ? Self.formatter1 : Self.formatter2
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.formatter         = sharedFormatter
        field.delegate          = context.coordinator
        field.isBordered        = false
        field.isBezeled         = true
        (field.cell as? NSTextFieldCell)?.bezelStyle = .roundedBezel
        field.drawsBackground   = true
        field.focusRingType     = .default
        field.font              = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        field.alignment         = .center
        field.cell?.wraps        = false
        field.cell?.isScrollable = true
        field.stringValue        = text
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        // Update the coordinator's submit action whenever SwiftUI re-renders,
        // so the closure always captures the current view state.
        context.coordinator.parent = self
        // Only push a value change when it originated externally (e.g. revert-on-failure
        // or reset-to-defaults), not while the user is actively editing.
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: WholeNumberTextField

        init(_ parent: WholeNumberTextField) { self.parent = parent }

        // Keep the binding in sync with every keystroke so the commit path always
        // reads the current field content from parent.text.
        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        // Intercept the Return key and call the submit action.
        // .onSubmit does not propagate into NSViewRepresentable, so this is the
        // authoritative hook that triggers commitHeuristics / commitConsecutive / commitUndock.
        func control(_ control: NSControl,
                     textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}

// MARK: - ProbeTextField
/// An NSTextField bridge for the Settling Probe Sequence fields.
/// Silently enforces the structural pattern: one or two digits, optionally followed
/// by a period and exactly one digit — i.e. "#", "##", "#.#", or "##.#".
/// Any character or addition that would violate this structure is silently dropped.
struct ProbeTextField: NSViewRepresentable {
    @Binding var text: String
    /// Called when the user commits the field by pressing Return.
    var onSubmit: () -> Void = {}

    // Shared single instance — probe fields are all identical in their formatting rules.
    private static let formatter = DecimalProbeFormatter()

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.formatter         = Self.formatter
        field.delegate          = context.coordinator
        field.isBordered        = false
        field.isBezeled         = true
        (field.cell as? NSTextFieldCell)?.bezelStyle = .roundedBezel
        field.drawsBackground   = true
        field.focusRingType     = .default
        field.font              = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        field.alignment         = .center
        field.cell?.wraps        = false
        field.cell?.isScrollable = true
        field.stringValue        = text
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ProbeTextField

        init(_ parent: ProbeTextField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl,
                     textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}

// MARK: - IntegerOnlyFormatter
/// NSFormatter subclass that strips non-digit characters and truncates to maxLength
/// at AppKit's pre-storage intercept point (isPartialStringValid). Returning false
/// with a corrected partialStringPtr causes AppKit to apply the cleaned string
/// silently — no alert, no cursor jump, no visible artifact of any kind.
///
/// @unchecked Sendable: NSFormatter is an ObjC class with no Swift concurrency support;
/// all use of this formatter occurs on the main thread (AppKit delegate callbacks and
/// loadView), so the annotation is correct and safe here.
final class IntegerOnlyFormatter: Formatter, @unchecked Sendable {
    let maxLength: Int

    init(maxLength: Int) {
        self.maxLength = maxLength
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    override func string(for obj: Any?) -> String? { obj as? String }

    override func getObjectValue(
        _ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?,
        for string: String,
        errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
        unsafe obj?.pointee = string as AnyObject
        return true
    }

    override func isPartialStringValid(
        _ partialStringPtr: AutoreleasingUnsafeMutablePointer<NSString>,
        proposedSelectedRange proposedSelRangePtr: NSRangePointer?,
        originalString origString: String,
        originalSelectedRange origSelRange: NSRange,
        errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
        let proposed = unsafe partialStringPtr.pointee as String
        let filtered = String(proposed.filter { $0.isASCII && $0.isNumber }.prefix(maxLength))

        if filtered == proposed { return true }

        unsafe partialStringPtr.pointee = filtered as NSString
        if let ptr = unsafe proposedSelRangePtr {
            unsafe ptr.pointee = NSRange(location: min(ptr.pointee.location, filtered.count), length: 0)
        }
        return false
    }
}

// MARK: - DecimalProbeFormatter
/// NSFormatter subclass for the Settling Probe Sequence fields.
///
/// Enforces the structural pattern: "#", "##", "#.#", or "##.#" — that is,
/// one or two digits, optionally followed by a period and exactly one more digit.
///
/// Rules applied at the pre-storage intercept:
///   1. All non-digit, non-period characters are silently dropped.
///   2. At most one period is permitted; further periods are silently dropped.
///   3. At most two digits are permitted before the period; a third is dropped.
///   4. At most one digit is permitted after the period; a second is dropped.
///
/// @unchecked Sendable: same rationale as IntegerOnlyFormatter above.
final class DecimalProbeFormatter: Formatter, @unchecked Sendable {

    required init?(coder: NSCoder) { nil }
    override init() { super.init() }

    override func string(for obj: Any?) -> String? { obj as? String }

    override func getObjectValue(
        _ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?,
        for string: String,
        errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
        unsafe obj?.pointee = string as AnyObject
        return true
    }

    override func isPartialStringValid(
        _ partialStringPtr: AutoreleasingUnsafeMutablePointer<NSString>,
        proposedSelectedRange proposedSelRangePtr: NSRangePointer?,
        originalString origString: String,
        originalSelectedRange origSelRange: NSRange,
        errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
        let proposed = unsafe partialStringPtr.pointee as String

        var seenPeriod         = false
        var digitsBeforePeriod = 0
        var digitsAfterPeriod  = 0
        var filtered           = ""

        for ch in proposed {
            if ch.isASCII && ch.isNumber {
                if !seenPeriod {
                    if digitsBeforePeriod < 2 {
                        filtered.append(ch)
                        digitsBeforePeriod += 1
                    }
                } else {
                    if digitsAfterPeriod < 1 {
                        filtered.append(ch)
                        digitsAfterPeriod += 1
                    }
                }
            } else if ch == "." && !seenPeriod {
                seenPeriod = true
                filtered.append(ch)
            }
        }

        if filtered == proposed { return true }

        unsafe partialStringPtr.pointee = filtered as NSString
        if let ptr = unsafe proposedSelRangePtr {
            unsafe ptr.pointee = NSRange(location: min(ptr.pointee.location, filtered.count), length: 0)
        }
        return false
    }
}

// MARK: – RateLimiter
// Thread-safe gate that returns 'true' at most once per 'cooldown' interval
// for a given key. Used to suppress redundant log output without dropping
// all messages (e.g. the cached-state heartbeat in ConnectivityController).
final class RateLimiter {
    // Mutex-protected rather than a nonisolated(unsafe) var beside an NSLock: the compiler
    // can verify the synchronization, so no escape hatch is needed.
    private static let lastActionTimes = Mutex<[String: Date]>([:])

    // Returns 'true' if the cooldown for 'key' has elapsed since the last
    // successful call; records the current time and returns 'false' otherwise.
    static func shouldPerform(key: String, cooldown: TimeInterval) -> Bool {
        lastActionTimes.withLock { times in
            let now = Date()
            if let last = times[key], now.timeIntervalSince(last) < cooldown { return false }
            times[key] = now
            return true } } }
