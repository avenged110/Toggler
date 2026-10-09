// MARK: – SettingsView.swift
// Copyright © 2025 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Toggler.app settings window content — a single pane, no tab bar.
//
// Launch at login, a divider, the Advanced section, a divider, Recognized Docks, a
// divider, then Debug Logging. The Advanced and Recognized Docks sections are defined
// below the pane.
//
// There is no "About" tab: About is the standard macOS about panel, which picks up the
// GPL-3.0 text from Credits.html in the app bundle's Resources.
//
// The window itself, and the reusable pieces of this content — the launch-at-login
// checkbox, the log-file monitor, the whole Debug Logging block, the temporary main menu —
// now come from the shared SettingsKit.swift. What remains here is Toggler's own:
// which controls the pane carries and in what order.

import Cocoa
import SwiftUI
import Combine

// MARK: – Settings pane
// The window's only content: every setting Toggler has, in one scrolling-free column.
@MainActor
struct SettingsTabView: View {

    var body: some View {
        // SettingsPage supplies the shared grid: leading alignment,
        // SettingsMetrics.sectionSpacing between children, and SettingsMetrics.edgePadding
        // on every side — the same 16 / 18 pt this pane used by hand.
        SettingsPage {

            // MARK: Launch at Login
            // Queries and re-queries SMAppService itself, including on app reactivation
            // after a trip to System Settings › Login Items.
            LaunchAtLoginToggle()

            Divider()

            // MARK: Advanced
            // Not headed by a checkbox, so it takes the 19 pt checkbox-title inset to line
            // its titles up with the checkbox rows above and below. The dividers stay
            // full-width; only the content between them is inset.
            AdvancedSettingsSection()
                .settingsCheckboxTitleAligned()

            Divider()

            // MARK: Recognized Docks
            // Inset for the same reason as Advanced above.
            RecognizedDocksSection()
                .settingsCheckboxTitleAligned()

            Divider()

            // MARK: Debug Logging
            // The toggle, caption and Reveal/Clear buttons, with the buttons gated on the
            // log file's existence by the section's own LogFileMonitor.
            //
            // logForced/shutdownLogging on disable are handled inside the section. No
            // onChange hook: nothing in the app reacts to the logging preference changing
            // (the logger reads it live), so the .togglerPreferencesChanged post that used
            // to sit here was only ever discarded by EventLogic's key filter.
            SettingsLoggingSection(
                loggingEnabledKey: Preferences.loggingEnabledKey,
                title: "Debug logging")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: – Advanced section
// Its own view because of its distinct complexity and validation requirements.
@MainActor
struct AdvancedSettingsSection: View, Loggable {
    nonisolated static let logTag = "[AdvancedSettings]"

    // Local string state for each editable field. Committed to Preferences on submit.
    @State private var heuristicsText: String = ""
    @State private var consecutiveText: String = ""
    @State private var undockText: String = ""
    @State private var probeTexts: [String] = Array(repeating: "", count: 5)

    // Controls the confirmation alert for "Reset to Defaults".
    @State private var showResetAlert: Bool = false

    var body: some View {
        // Spacing values are pulled from SettingsMetrics so this section shares the grid
        // used by the rest of the settings pane (SettingsKit.swift). The whole
        // section is inset by the caller with .settingsCheckboxTitleAligned(), so its
        // titles line up with the checkbox rows above and below.
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {

            // MARK: – Thresholds section
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Thresholds:")
                    .fixedSize()

                VStack(alignment: .leading, spacing: SettingsMetrics.titleControlSpacing) {
                    thresholdRow(
                        label: "Heuristics",
                        description: "Minimum number of heuristics required to consider the MacBook as docked.",
                        text: $heuristicsText,
                        maxLength: 1,
                        onSubmit: { commitHeuristics() }
                    )

                    thresholdRow(
                        label: "Consecutive acceptance",
                        description: "Number of consecutive \"high confidence\" heuristics probes required to accept a state determination before all probes have finished running.",
                        text: $consecutiveText,
                        maxLength: 1,
                        onSubmit: { commitConsecutive() }
                    )

                    thresholdRow(
                        label: "Undock intent debounce window",
                        description: "Seconds to wait after detecting a potential undock event before confirming it. This helps prevent false undock detections as a result of brief connection fluctuations.",
                        text: $undockText,
                        maxLength: 2,
                        onSubmit: { commitUndock() }
                    )
                }
            }

            // MARK: – Settling Probe Sequence section
            VStack(alignment: .leading, spacing: SettingsMetrics.rowContentSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Settling probe sequence:")
                        .fixedSize()
                    HStack(spacing: SettingsMetrics.titleControlSpacing) {
                        ForEach(0..<5, id: \.self) { i in
                            ProbeTextField(text: $probeTexts[i], onSubmit: { commitProbe(at: i) })
                                .frame(width: 48, height: 22)
                        }
                    }
                }
                Text("Configure up to five relative time intervals on which to run heuristics probes and compute a dock-state confidence score after a dock event is detected. Fractional seconds are allowed. Each interval must be greater than that which precedes it.")
                    .font(.system(size: NSFont.smallSystemFontSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // MARK: – Reset button
            Button("Reset to Defaults") {
                showResetAlert = true
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear { loadFieldValues() }
        .alert("Reset Fields?", isPresented: $showResetAlert) {
            Button("Reset", role: .destructive) { performReset() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The heuristics and probe configuration fields will be reset to their default values.")
        }
    }

    // MARK: – Sub-views

    @ViewBuilder
    private func thresholdRow(label: String, description: String, text: Binding<String>,
                              maxLength: Int, onSubmit: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SettingsMetrics.titleControlSpacing) {
            WholeNumberTextField(text: text, maxLength: maxLength, onSubmit: onSubmit)
                .frame(width: 48, height: 22)
            VStack(alignment: .leading, spacing: SettingsMetrics.rowContentSpacing) {
                Text(label)
                Text(description)
                    .font(.system(size: NSFont.smallSystemFontSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: – Persistence helpers

    private func loadFieldValues() {
        heuristicsText  = "\(Preferences.heuristicsThreshold)"
        consecutiveText = "\(Preferences.consecutiveAcceptanceThreshold)"
        undockText      = "\(Int(Preferences.undockIntentDebounceWindow))"
        refreshProbeFields()
    }

    private func commitHeuristics() {
        let minVal = 1; let maxVal = Heuristics.maxScore
        validateAndCommitInt(
            text: &heuristicsText,
            min: minVal, max: maxVal,
            getCurrent: { Preferences.heuristicsThreshold },
            setNew: { Preferences.heuristicsThreshold = $0 },
            errorMessage: "You must enter a whole number between \(minVal) and \(maxVal).")
    }

    private func commitConsecutive() {
        // Lower bound is 1 to match Preferences.consecutiveAcceptanceThreshold's clamping.
        // A value of 0 would allow the high-confidence shortcut to fire on the first
        // probe unconditionally (consecutiveCount >= 0 is always true).
        let minVal = 1; let maxVal = Preferences.settleProbeDelays.count
        validateAndCommitInt(
            text: &consecutiveText,
            min: minVal, max: maxVal,
            getCurrent: { Preferences.consecutiveAcceptanceThreshold },
            setNew: { Preferences.consecutiveAcceptanceThreshold = $0 },
            errorMessage: "You must enter a whole number between \(minVal) and \(maxVal).")
    }

    private func commitUndock() {
        let minVal = 1; let maxVal = 10
        validateAndCommitInt(
            text: &undockText,
            min: minVal, max: maxVal,
            getCurrent: { Int(Preferences.undockIntentDebounceWindow) },
            setNew: { Preferences.undockIntentDebounceWindow = TimeInterval($0) },
            errorMessage: "You must enter a whole number between \(minVal) and \(maxVal).")
    }

    private func commitProbe(at index: Int) {
        let raw = probeTexts[index].trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty field: remove this probe and shift remaining ones left.
        if raw.isEmpty {
            var probes = Preferences.settleProbeDelays
            if index < probes.count { probes.remove(at: index) }
            if probes.isEmpty {
                presentAlert("At least one interval must be set.")
                refreshProbeFields()
                return
            }
            Preferences.settleProbeDelays = probes
            refreshProbeFields()
            return
        }

        // Parse numeric input. The formatter guarantees only digits and at most one
        // period are present, but a lone "." won't parse as a Double — guard covers it.
        guard let entered = Double(raw) else {
            presentAlert("You must enter a number between 0.1 and 10.0.")
            refreshProbeFields()
            return
        }

        // Clamp to the allowed range and round to the nearest tenth.
        let clamped = min(max(entered, 0.1), 10.0)
        var rounded = round(clamped * 10.0) / 10.0

        // Determine the nearest committed value to the left of this index.
        // Use Preferences.settleProbeDelays (committed state) rather than probeTexts
        // (which reflects what the user has typed but not yet submitted). Deriving
        // the ordering constraint from uncommitted text could allow a non-monotonic
        // sequence to be written to Preferences if the user edits field i without
        // committing it before pressing Return in field i+1.
        let committedDelays = Preferences.settleProbeDelays
        var priorValue: Double = 0.0
        if index > 0 {
            // Walk backward through committed delays. If index exceeds the committed
            // count, the last committed entry is the nearest committed predecessor.
            let searchEnd = min(index, committedDelays.count)
            for i in stride(from: searchEnd - 1, through: 0, by: -1) {
                let v = committedDelays[i]
                if v > 0 {
                    priorValue = round(v * 10.0) / 10.0
                    break
                }
            }
        }

        // If rounding brought the value to <= prior but the raw entry was genuinely
        // above it, bump up to the next representable tenth.
        if rounded <= priorValue {
            if clamped > priorValue {
                var bumped = (floor(priorValue * 10.0) + 1.0) / 10.0
                if bumped > 10.0 { bumped = 10.0 }
                rounded = bumped
            } else {
                presentAlert("Each interval must be greater than the previous interval (\(priorValue.fixed(1))).")
                refreshProbeFields()
                return
            }
        }

        // Persist the new value and prune any now-invalid subsequent values.
        var probes = Preferences.settleProbeDelays
        let target = index <= probes.count ? index : probes.count
        if target < probes.count { probes[target] = rounded }
        else { probes.append(rounded) }

        var newProbes: [Double] = []
        for (i, v) in probes.enumerated() {
            if i <= target { newProbes.append(v) }
            else if v > rounded { newProbes.append(v) }
            if newProbes.count >= 5 { break }
        }

        guard !newProbes.isEmpty else {
            presentAlert("At least one interval must be set.")
            refreshProbeFields()
            return
        }

        Preferences.settleProbeDelays = newProbes
        refreshProbeFields()
    }

    // MARK: – Validation helpers

    /// Validates an integer input, persists on success, reverts the text on failure.
    /// Logic is identical to the original project implementation; the only structural
    /// difference is that text is now a SwiftUI @State binding rather than an
    /// NSTextField.stringValue, so setting it drives updateNSView on the bridge.
    private func validateAndCommitInt(text: inout String,
                                      min minVal: Int, max maxVal: Int,
                                      getCurrent: () -> Int,
                                      setNew: (Int) -> Void,
                                      errorMessage: String) {
        let raw    = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let revert = "\(getCurrent())"

        if raw.isEmpty { text = revert; return }

        guard let entered = Double(raw),
              entered >= Double(minVal), entered <= Double(maxVal) else {
            presentAlert(errorMessage)
            text = revert
            return
        }

        let rounded = Int(entered.rounded())
        if rounded != getCurrent() { setNew(rounded) }
        text = "\(rounded)"
    }

    private func refreshProbeFields() {
        let delays = Preferences.settleProbeDelays
        for i in 0..<5 {
            probeTexts[i] = i < delays.count && delays[i] > 0
                ? delays[i].fixed(1) : ""
        }
        // "Consecutive Acceptance"'s valid range is derived from the live probe count,
        // which just changed. Preferences.consecutiveAcceptanceThreshold's getter clamps
        // automatically, but the displayed text otherwise wouldn't reflect that until the
        // tab is reloaded — keep it in sync here rather than leaving it stale.
        consecutiveText = "\(Preferences.consecutiveAcceptanceThreshold)"
    }

    private func presentAlert(_ message: String) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle  = .warning
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in }
    }

    // MARK: – Reset

    private func performReset() {
        Preferences.resetThresholdsToDefaults()
        Preferences.resetSettleProbeDelaysToDefaults()
        loadFieldValues()
        Self.log("Heuristics and probe configuration fields reset to defaults.")
    }
}

// MARK: – Recognized Docks section
// A way to forget the Thunderbolt docks MonitorDock has identified with certainty
// (Preferences.knownDocks). The docks themselves are deliberately not listed. Laid out like
// the Debug Logging section: title, caption, then the control.
@MainActor
struct RecognizedDocksSection: View {

    // Whether any dock is recognized; the button has nothing to forget otherwise.
    @State private var hasRecognizedDocks: Bool = false

    // Controls the confirmation alert for "Forget Recognized Docks".
    @State private var showForgetAlert: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowContentSpacing) {
            Text("Recognized Docks")
            Text("When Toggler identifies with certainty a Thunderbolt device as a dock, the device's UID will be remembered, allowing subsequent dock and undock events with this device to bypass the heuristics and probing pipelines.")
                .font(.system(size: NSFont.smallSystemFontSize))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Forget Recognized Docks") {
                showForgetAlert = true
            }
            .disabled(!hasRecognizedDocks)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear { loadRecognizedDocks() }
        // A dock can be recognized while the settings window is open; the notification is
        // posted from MonitorDock's queue, so hop to main before touching view state.
        .onReceive(NotificationCenter.default.publisher(for: .togglerPreferencesChanged)
            .receive(on: RunLoop.main)) { _ in loadRecognizedDocks() }
        .alert("Forget Recognized Docks?", isPresented: $showForgetAlert) {
            Button("Forget", role: .destructive) { performForget() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The next time each device is connected, they will go through the standard heuristics and probing pipelines again, re-evaluating which are definitively docks.")
        }
    }

    private func loadRecognizedDocks() {
        hasRecognizedDocks = !Preferences.knownDocks.isEmpty
    }

    private func performForget() {
        Preferences.forgetKnownDocks()
        loadRecognizedDocks()
    }
}
