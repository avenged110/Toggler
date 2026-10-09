// MARK: – AppDelegate.swift
// Copyright © 2025 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Entry point (@main) and application delegate for Toggler.app.
// Runs as a MenuBar-only (accessory) applet; no main window or Dock icon.

import Cocoa

// @unchecked Sendable: AppDelegate is an NSObject subclass whose lifecycle and
// all mutable state are managed entirely on the main thread by AppKit. The compiler
// cannot verify this invariant automatically, so we assert it here.
@main
final class AppDelegate: NSObject, NSApplicationDelegate, Loggable, @unchecked Sendable {
    nonisolated static let logTag = "[AD]"

    // MARK: - Entry point
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run() }

    // Controllers
    private var menuController: TogglerMenu!
    private let cc = ConnectivityController.shared
    private var btpc: BTPermController!
    private var eventLogic: EventLogic?
    private var monitorSleep: MonitorSleep?
    private var monitorDock: MonitorDock?

    // Cache application version and build numbers once for reuse in logs.
    private let appVersionBuild: String = {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))" }()

    // MARK: - Application lifecycle
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Order matters: prepareLogDirectory() reads Preferences.loggingEnabled, so the
        // registered defaults must be in place first. (Both paths currently yield the
        // same answer because 'loggingEnabled' registers as false and UserDefaults.bool
        // also returns false for an unregistered key — but relying on that coincidence
        // would break silently the moment the registered default changed.)
        Preferences.ensureDefaultsRegistered()
        // Bootstrap the shared logger before the first log line. prepareLogDirectory()
        // reads the enabled predicate, so it must follow both this and the defaults
        // registration above.
        Logger.bootstrap(.init(fileName: "Toggler.log",
                               destination: .containerLibraryLogs,
                               isEnabled: { Preferences.loggingEnabled }))
        Logger.prepareLogDirectory()
        log("Toggler application \(appVersionBuild) launched.")

        // Run application headless — no Dock icon; MenuBar only.
        NSApp.setActivationPolicy(.accessory)

        // Initialize external controllers and install the status item.
        // BTPermController no longer needs a host: the menu is rebuilt on every open and
        // reads the TCC state as it builds, so there are no live NSMenuItem references to
        // push warning glyphs or checkmarks into.
        btpc = BTPermController()
        menuController = TogglerMenu(btpc: btpc)
        menuController.install()

        // Refresh cached state immediately. ConnectivityController owns the one
        // canonical cache, so we call it directly rather than duplicating queues here.
        // NOTE: refreshCachedState() dispatches the read-write work asynchronously onto
        // its own refreshQueue, so any log emitted here would read stale cached values
        // that predate the refresh. The authoritative post-refresh log is emitted by
        // ConnectivityController itself once the async write has completed.
        cc.refreshCachedState()

        // Trigger Bluetooth TCC prompt.
        btpc.triggerBluetoothTCC()

        // Setup event system and monitors; deferred until after main menu is set up.
        let logic = EventLogic()
        eventLogic = logic

        // Wire MonitorSleep callbacks directly into EventLogic, replacing the
        // NotificationCenter broadcast path for sleep/wake events. The closures
        // are @Sendable and capture 'logic' (not self) to avoid a retain cycle
        // through AppDelegate. EventLogic is @unchecked Sendable.
        //
        // MonitorDock is created first because the sleep callback goes through it: a dock
        // verdict still being settled when sleep begins is resolved and handed to
        // EventLogic BEFORE the sleep itself (see resolvePendingVerdictBeforeSleep).
        let dock = MonitorDock()
        let sleep = MonitorSleep()
        sleep.onWillSleep = { [weak logic, weak dock] done in
            guard let logic else { done(); return }
            guard let dock else { logic.receiveSystemWillSleep(done: done); return }
            dock.resolvePendingVerdictBeforeSleep { logic.receiveSystemWillSleep(done: done) } }
        sleep.onDidWake   = { [weak logic] in logic?.receiveSystemDidWake() }
        monitorSleep = sleep

        // Wire MonitorDock callback directly into EventLogic, replacing the
        // NotificationCenter broadcast path for dock/undock events.
        dock.onDockStatusChanged = { [weak logic] isDocked, timestamp in
            logic?.receiveDockStatusChanged(isDocked: isDocked, timestamp: timestamp) }
        monitorDock = dock
        monitorDock?.startListeningForThunderboltEvents() }

    // Called by AppKit when termination is requested (Quit from Dock, Cmd-Q, etc.)
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        log("applicationShouldTerminate: Beginning controlled shutdown")
        // Tell status controller immediately that termination is starting.
        menuController?.markTerminating()
        // Ask TogglerMenu to perform an immediate, synchronous teardown.
        // This removes the status item and closes any windows Toggler owns
        // so AppKit isn't left with UI still attached when it wants to terminate.
        menuController?.prepareForTerminationSynchronously()
        // Stop monitors synchronously as a final step.
        monitorDock?.stopListening()
        // Explicitly remove the NSWorkspace observer on the main thread before releasing
        // MonitorSleep. NSWorkspace.shared requires main-thread access; deinit is
        // nonisolated and may fire on any thread, so this must happen here rather than
        // relying on deinit to do it safely.
        monitorSleep?.prepareForTermination()
        monitorSleep = nil
        // Defensive: remove any observers registered on self.
        NotificationCenter.default.removeObserver(self)
        log("applicationShouldTerminate: Finished shutdown cleanup — allowing termination")
        // Flush buffered log messages to disk. This must be the LAST statement that
        // touches the logger: shutdownLogging() drains whatever is buffered at the
        // moment it runs, so anything logged after it would sit in the buffer with no
        // further flush scheduled before the process exits. (Previously this call sat
        // above the two lines that follow it, and those messages were silently lost.)
        // The blocking variant is the one to use here: the plain shutdownLogging() is
        // fire-and-forget, and the process may exit before its detached task runs.
        Logger.shutdownLoggingBlocking()
        // Allow termination now that everything's been cleaned up synchronously.
        return .terminateNow }

    func applicationWillTerminate(_ notification: Notification) {
        // Still invoked by AppKit. Kept minimal because
        // applicationShouldTerminate() already did most of the synchronous work.
        log("applicationWillTerminate: Called")
        log("Toggler application \(appVersionBuild) terminating.")
        // applicationShouldTerminate() already flushed, which reset the buffer and left
        // no pending flush scheduled. Flush again so the two lines above are not stranded
        // in the buffer when the process exits. The call is idempotent — a flush of an
        // empty buffer returns immediately — so the repeat costs nothing.
        Logger.shutdownLoggingBlocking()
        // Release the strong reference to menuController last, after all logging, to
        // avoid any in-flight async work referencing a partially-torn-down object.
        menuController = nil }

    // MARK: – External helper
    // Target of the "About Toggler" item in the temporary main menu that
    // SettingsKit installs while the Settings window is open (see
    // SettingsWindowConfiguration.aboutMenuAction in TogglerMenu). Routes through this
    // delegate so the live TogglerMenu instance handles the request safely.
    @MainActor
    @objc func showAboutPanel(_ sender: Any?) {
        menuController?.showAboutPanel() }

    // NOTE: the .togglerPreferencesChanged observer that used to live here is gone.
    // It existed only to call updateMenuCheckmarksFromPreferences(); the menu is now
    // rebuilt from the live preferences on every open, so an external change is picked
    // up with no reconcile pass. EventLogic keeps its own observer for its own reasons.
}
