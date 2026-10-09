// MARK: – BTPermController.swift
// Copyright © 2025 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Handles Bluetooth permission prompts, TCC enforcement, and UI warnings.

import Cocoa
import CoreBluetooth  // For TCC trigger

// @MainActor: CBCentralManager with queue:nil delivers its delegate callbacks on
// the main thread, so @MainActor is the correct isolation domain for this class.
// This eliminates the previous informal "always happens to be main" invariant and
// makes the Preferences writes performed during enforcement provably safe without
// any DispatchQueue.main.async indirection.
@MainActor
final class BTPermController: NSObject, CBCentralManagerDelegate, Loggable {
    nonisolated static let logTag = "[BTPermController]"

    // The CoreBluetooth manager temporarily created to trigger TCC + observe initial state.
    // Hold it only as long as necessary (released after first enforcement when
    // oneShotMonitoring = true).
    private var bluetoothCentral: CBCentralManager?

    // Only trigger/enforce once and then release the CBCentralManager.
    private var oneShotMonitoring: Bool = true

    // MARK: - Lifecycle
    // Trigger the TCC popup and enforce preferences. By default this is a one-shot
    // operation (creates a CBCentralManager, enforces state, releases it). Set
    // 'monitorContinuously: true' to keep observing CoreBluetooth state changes at runtime.
    func triggerBluetoothTCC(monitorContinuously: Bool = false) {
        // Already on the main actor — no dispatch hop needed.
        oneShotMonitoring = !monitorContinuously

        // Initialize manager on the main queue; delegate callbacks will come to this object.
        bluetoothCentral = CBCentralManager(delegate: self, queue: nil,
            options: [CBCentralManagerOptionShowPowerAlertKey: true])
        log("Initialized CBCentralManager to trigger Bluetooth TCC prompt (monitorContinuously=\(monitorContinuously)).")

        // Enforce preference state immediately and synchronously. Although CBCentralManager
        // also triggers centralManagerDidUpdateState(_:) as part of its initialization,
        // that callback is *queued* on the main run loop — it has not yet been delivered
        // by the time the next line executes. Calling enforceBluetoothPermissionsState()
        // here guarantees the preferences reflect the correct TCC state from the moment
        // the app becomes visible, rather than after the run loop's next spin.
        //
        // Except while the authorization is still undetermined. At this moment — before the
        // new manager has checked in — CBManager.authorization can read .notDetermined for
        // an app that is in fact allowed (seen on every launch of a freshly built binary).
        // Enforcing on that reading treated it as a denial: the Bluetooth preferences were
        // saved, forced off and posted, then restored a second later when the delegate
        // callback reported the real state. The callback, which always follows, enforces
        // with the settled value instead.
        guard CBManager.authorization != .notDetermined else {
            log("Bluetooth authorization not yet determined — deferring enforcement to the CoreBluetooth state callback.")
            return }
        enforceBluetoothPermissionsState() }

    // Check to determine if Bluetooth access is permitted via TCC
    func bluetoothAccessGranted() -> Bool { CBManager.authorization == .allowedAlways }

    // MARK: - Enforcement
    // Enforce the preference lockout when TCC permission for Bluetooth has been denied.
    //
    // This no longer touches menu items. The menu is rebuilt from scratch on every open
    // by MenuController, and the two Bluetooth rows read bluetoothAccessGranted() as they
    // are built — so the warning glyph and the checkmark states follow from the state this
    // method leaves behind, rather than being pushed into live NSMenuItem references that
    // would not survive the next rebuild. TogglerMenu calls this from the menu's
    // willOpen hook, so the check is re-run every time the menu is opened.
    func enforceBluetoothPermissionsState() {
        if bluetoothAccessGranted() {
            // If prefs were previously forced off because of denied permission,
            // restore them.
            if Preferences.bluetoothWasForced {
                Preferences.restoreBluetoothPreForcedState()
                log("Bluetooth permission restored — restoring user preferences") }
        } else {
            // Save user prefs once and force-off toggles while TCC permission is denied
            if !Preferences.bluetoothWasForced {
                Preferences.saveBluetoothPreForcedState()
                Preferences.disableBluetoothDuringSleep   = false
                Preferences.toggleBluetoothOnDockEvent    = false
                log("Bluetooth permission denied — saving user preferences and forcing off toggles") } } }

    // Show a modal explaining how to re-enable Bluetooth TCC.
    func showBluetoothPermissionAlert() {
        // Already on the main actor.
        let alert = NSAlert()
        alert.alertStyle    = .warning
        alert.messageText   = "Bluetooth Access Required"
        alert.informativeText = """
        Toggler cannot control Bluetooth because access was denied.

        You must first grant permission in
        System Settings → Privacy & Security.
        """
        alert.addButton(withTitle: "Open Settings") // Index 0
        alert.addButton(withTitle: "Cancel")        // Index 1

        NSApp.activate()
        let response = alert.runModal()

        // Open Settings.app → Privacy & Security → Bluetooth
        if response == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!
            NSWorkspace.shared.open(url) } }

    // MARK: - CBCentralManagerDelegate
    // Called by CoreBluetooth on the main thread (queue:nil was specified at init).
    // Bridge between CoreBluetooth state/authorization changes and enforcement logic.
    // Marked nonisolated to satisfy the nonisolated protocol requirement; the
    // Task { @MainActor } hop provides a static isolation guarantee — the compiler
    // can verify that all accesses to @MainActor-isolated state (enforceBluetoothPermissionsState,
    // bluetoothCentral, oneShotMonitoring) occur within the correct isolation domain.
    // This replaces the previous DispatchQueue.main.async approach, which provided only
    // a runtime guarantee and left the @MainActor-isolated accesses inside the closure
    // in a technically non-isolated context from the compiler's perspective.
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Already on the main actor — enforcement runs directly.
            self.enforceBluetoothPermissionsState()

            if self.oneShotMonitoring {
                // Release the manager and let system resources be freed.
                self.bluetoothCentral = nil
                log("Released CBCentralManager after one-shot enforcement.") } } }
}
