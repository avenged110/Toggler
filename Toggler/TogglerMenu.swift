// MARK: – TogglerMenu.swift
// Copyright © 2025 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Toggler.app's menu-bar applet: the status item, its menu, and the Settings window.
//
// This is the project-specific half of what StatusMenuController.swift used to be. The
// chrome — status item, menu construction, attributed titles, symbol caching, synchronous
// teardown — now lives in the shared MenuControlKit.swift, and the Settings window in the
// shared SettingsKit.swift. What remains here is only what is actually Toggler's:
// which rows the menu carries, which preferences they bind to, the Bluetooth permission
// gate in front of two of them, and what the Settings window contains.
//
// The app runs as `.accessory` for its whole lifetime — set once in AppDelegate and never
// changed, as in LAN Stream, Process Elimination and Ethernet Status.

import Cocoa
import SwiftUI

@MainActor
final class TogglerMenu: Loggable {
    nonisolated static let logTag = "[SMC]"

    // Injected controller.
    private let btpc: BTPermController

    // MARK: – Settings window
    //
    // Built once and held for the app's lifetime; SettingsWindowController itself builds
    // the NSWindow on first open and discards it on close, so holding this costs one
    // small object rather than a live window.
    //
    // One tab, so `tabBar: .hidden`: the content is hosted directly rather than spending
    // a band of window height on a toolbar icon that is already selected.
    // Tracks whether the lazy 'settings' property has actually been created, so the
    // termination path can ask "is a Settings window up?" without *building* the
    // controller in order to find out. Touching a lazy var initializes it, and the
    // teardown path used to read settings.visibleWindow unconditionally — constructing a
    // SettingsWindowController during shutdown for a user who never opened Settings.
    // Set in openSettings(), the only place the property is otherwise touched.
    private var didCreateSettings = false

    private lazy var settings = SettingsWindowController(.init(
        title: "Toggler Settings",
        sizing: .fitToContent(width: Self.contentWidth),
        tabs: [
            .swiftUI(id: "settings", title: "Settings") { SettingsTabView() },
        ],
        edgePadding: Self.edgePadding,
        tabBar: .hidden,
        styleMask: [.titled, .closable, .miniaturizable],
        usesFocusSink: true,
        // LSUIElement app: without a temporary main menu the Settings window would have
        // no Cut/Copy/Paste and no ⌘W.
        installsTemporaryMainMenu: true,
        // Kept pointing at AppDelegate rather than left nil: the kit's nil branch wires
        // the item straight to orderFrontStandardAboutPanel but with no key equivalent,
        // and this preserves ⌘?.
        aboutMenuAction: #selector(AppDelegate.showAboutPanel(_:))))

    /// The window's content width. The height is the pane's own, measured by the kit.
    static let contentWidth: CGFloat = 500

    /// Standard inset for tab content. Single source of truth for both the AppKit and the
    /// SwiftUI layer, as `SettingsWindow.edgePadding` was.
    static let edgePadding: CGFloat = SettingsWindowConfiguration.defaultEdgePadding

    // MARK: – Status menu
    //
    // `elements` is re-evaluated on every menu open, so the checkmarks track the
    // preferences and the Bluetooth warning glyph tracks the TCC grant with no reconcile
    // pass, no retained NSMenuItem references and no updateMenuCheckmarksFromPreferences().
    //
    // [weak self] is captured once, here; the per-element closures inherit the unwrapped
    // reference rather than each capturing self strongly.
    private lazy var menu = MenuController(.init(
        appName: "Toggler",
        icon: { .symbol(.menuBar("antenna.radiowaves.left.and.right", weight: .bold),
                        fallbackTitle: "Toggler") },
        elements: { [weak self] in
            guard let self else { return [] }
            let btGranted = self.btpc.bluetoothAccessGranted()
            // The warning triangle Toggler appends to a Bluetooth row whose permission
            // has been denied. Previously pushed in from BTPermController via
            // setMenuItem(_:title:symbolName:checked:); now computed on every open.
            let btWarning: String? = btGranted ? nil : "exclamationmark.triangle.fill"

            return [
                .header("Upon Sleep While Undocked:"),

                .toggle(id: "wifiSleep", title: "Disable Wi-Fi", key: "z",
                        isOn: { Preferences.disableWiFiDuringSleep },
                        setOn: { Preferences.disableWiFiDuringSleep = $0 }),

                .toggle(id: "btSleep", title: "Disable Bluetooth", key: "x",
                        symbolName: btWarning,
                        isOn: { Preferences.disableBluetoothDuringSleep },
                        willChange: { _ in self.demandBluetoothPermission() },
                        setOn: { Preferences.disableBluetoothDuringSleep = $0 }),

                .separator,

                .header("Upon Dock/Undock:"),

                // Option-only modifier masks, as before — not ⌘⌥.
                .toggle(id: "wifiDock", title: "Toggle Wi-Fi", key: "z",
                        modifiers: [.option],
                        isOn: { Preferences.toggleWiFiOnDockEvent },
                        setOn: { Preferences.toggleWiFiOnDockEvent = $0 }),

                .toggle(id: "btDock", title: "Toggle Bluetooth", key: "x",
                        modifiers: [.option],
                        symbolName: btWarning,
                        isOn: { Preferences.toggleBluetoothOnDockEvent },
                        willChange: { _ in self.demandBluetoothPermission() },
                        setOn: { Preferences.toggleBluetoothOnDockEvent = $0 }),

                .separator,

                .action(id: "settings", title: "Settings…", key: ",") {
                    self.openSettings()
                },

                .separator,

                .about(title: "About Toggler…") {
                    self.showAboutPanel()
                },

                .separator,

                .quit(title: "Quit Toggler"),
            ]
        },
        // Re-checked on every open, so a TCC grant changed in System Settings while the
        // app was running is reflected by the rows this build produces.
        willOpen: { [weak self] in self?.btpc.enforceBluetoothPermissionsState() }))

    // MARK: - Initialization
    init(btpc: BTPermController) {
        self.btpc = btpc
    }

    /// Installs the status item. Call once, at launch.
    func install() { menu.install() }

    // MARK: - Menu Actions

    /// Gate in front of the two Bluetooth rows. Returning false vetoes the preference
    /// write, and the row visibly does not move.
    private func demandBluetoothPermission() -> Bool {
        guard btpc.bluetoothAccessGranted() else {
            btpc.showBluetoothPermissionAlert()
            return false
        }
        return true
    }

    /// Opens the Settings window.
    ///
    /// The app stays `.accessory` throughout, as LAN Stream, Process Elimination and
    /// Ethernet Status do — no policy flip, no run-loop drain, no Dock tile appearing and
    /// disappearing around the window. `SettingsWindowController.open()` calls
    /// `NSApp.activate()`, which is what brings the window to the front from an accessory
    /// app, and the temporary main menu supplies the menu bar it needs while it is up.
    ///
    /// The terminating guard remains: a row clicked during teardown must not open a
    /// window into a dying process.
    private func openSettings() {
        guard !isTerminating else {
            log("Skipping openSettings: the application is terminating.")
            return
        }
        didCreateSettings = true
        settings.open()
        log("Opening Settings window.")
    }

    /// Shows the standard macOS about panel, which renders the app icon, name, version
    /// and the GPL-3.0 text from Credits.html in the bundle's Resources.
    ///
    /// As with the Settings window, the app stays `.accessory`; `NSApp.activate()` is what
    /// brings the panel to the front.
    func showAboutPanel() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
        log("Opening the standard About panel.")
    }

    // MARK: – Termination

    private var isTerminating = false

    /// Called by AppDelegate when termination starts, so no window is opened while the
    /// process is shutting down.
    func markTerminating() {
        isTerminating = true
        menu.markTerminating()
    }

    /// Synchronous teardown: closes the Settings window and pulls the status item before
    /// the process unwinds.
    func prepareForTerminationSynchronously() {
        isTerminating = true
        menu.markTerminating()
        // Short-circuits on didCreateSettings so an app that never opened Settings does
        // not build the controller here just to discover it has no window.
        if didCreateSettings, settings.visibleWindow != nil {
            settings.close()
            // Give AppKit a brief opportunity to process the close notification so the
            // window visually disappears before the process exits.
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        menu.prepareForTerminationSynchronously()
    }
}
