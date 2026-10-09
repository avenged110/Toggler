// MARK: - SettingsKit.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// STANDARDIZED SETTINGS WINDOW UTILITY — drop in, describe the window, done.
//
// A hand-built NSWindow hosting an NSTabViewController with `tabStyle = .toolbar`, a
// locked content size, a title set once, and teardown on close — described by a
// `SettingsWindowConfiguration` rather than rebuilt per project.
//
// It also carries the reusable pieces of settings CONTENT: the focus sink, the temporary
// main menu, the main-window lifetime rule, the log-file monitor, the launch-at-login
// control, the Debug Logging block,
// and a row factory (`SettingsPage` / `SettingsRow` / `SettingsControlStrip`, sharing the
// 19 pt `SettingsMetrics.checkboxTitleInset` so control-less rows line up with checkbox
// rows). None of them depends on the window, so a project can take just the one it wants
// and put it inside a window it builds itself.
//
// WHY NOT A SwiftUI `Settings` SCENE
// ──────────────────────────────────
// It reassigns the window title from the selected tab's `tabItem` label on every tab
// change, with no public API to opt out. It also introduces an independent scene scope,
// which duplicates menu commands (a second "Settings…" entry, an extra View/Help menu)
// and does not inherit the app's environment.
//
// WIRING IT UP
// ────────────
//   private let settings = SettingsWindowController(
//       .init(title: "Toggler Settings",
//             contentSize: NSSize(width: 500, height: 398),
//             tabs: [
//                 .swiftUI(id: "general",  title: "General",  symbol: "gearshape") {
//                     GeneralTabView()
//                 },
//                 .swiftUI(id: "advanced", title: "Advanced", symbol: "gearshape.2") {
//                     AdvancedTabView()
//                 },
//             ]))
//
//   settings.open()                 // default tab
//   settings.open(tab: "about")     // a specific tab
//
// A single-tab window needs no change of shape — pass one tab and set `tabBar: .hidden`;
// the content is hosted directly, spending no toolbar band on an icon that is already
// selected. An AppKit project passes `.viewController` tabs instead of `.swiftUI` ones;
// everything else is identical.
//
// SIZING TO CONTENT
// ─────────────────
// `contentSize:` states the content area outright. The alternative is to fix only the
// width and let the height come from the tabs themselves:
//
//   .init(title: "nvNotes Settings",
//         sizing: .fitToContent(width: 500),
//         tabs: [...])
//
// Each tab's view is measured once, when the window is built, and the window takes the
// height of the tallest — so a caption that gains a line moves the bottom edge instead of
// leaving a hand-tuned constant one line short, and the tabs still share one size (the
// window never resizes between them). It asks that a tab's content be top-aligned and
// free to grow: `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)`
// with its own `edgePadding`, which is how every tab in these projects is already built.
// A tab that pins its own height (`.frame(height:)`) simply measures as that height.

import AppKit
import SwiftUI
import ServiceManagement
import System // FileDescriptor, for the log directory monitor


// MARK: - Tab Specification

/// One tab: a stable id, its toolbar label and symbol, and how to build its content.
@MainActor
public struct SettingsTabSpec {
    /// Stable identity used by `open(tab:)` and `selectTab(_:)`. A String rather than an
    /// index, so reordering tabs cannot silently repoint a call site.
    public let id: String
    /// The toolbar label.
    public let title: String
    /// An SF Symbol name for the toolbar item. `nil` gives a label-only item.
    public let symbolName: String?
    /// Builds the tab's view controller. Called once, when the window is built. The flag
    /// is the window's `usesFocusSink` setting, so a SwiftUI tab can insert the sink only
    /// when the window wants it.
    public let makeViewController: (_ usesFocusSink: Bool) -> NSViewController

    public init(id: String, title: String, symbolName: String?,
                makeViewController: @escaping (_ usesFocusSink: Bool) -> NSViewController) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.makeViewController = makeViewController
    }

    /// A tab hosting a SwiftUI view, wrapped in `SettingsFocusSinkWrapper` when the
    /// window's `usesFocusSink` is on.
    public static func swiftUI<Content: View>(id: String, title: String,
                                              symbol: String? = nil,
                                              @ViewBuilder content: @escaping () -> Content)
    -> SettingsTabSpec {
        SettingsTabSpec(id: id, title: title, symbolName: symbol) { usesFocusSink in
            NSHostingController(
                rootView: SettingsFocusSinkWrapper(isActive: usesFocusSink, content: content))
        }
    }

    /// A tab hosting an AppKit view controller the project builds itself.
    public static func viewController(id: String, title: String, symbol: String? = nil,
                                      make: @escaping () -> NSViewController)
    -> SettingsTabSpec {
        SettingsTabSpec(id: id, title: title, symbolName: symbol) { _ in make() }
    }
}

// MARK: - Window Configuration

/// Everything a project can vary about the window, in one value.
@MainActor
public struct SettingsWindowConfiguration {

    /// Whether a toolbar tab bar is shown.
    public enum TabBar {
        /// `NSTabViewController` with `tabStyle = .toolbar` — the standard look.
        case toolbar
        /// No tab bar: the single tab's content is hosted directly in the window. Use
        /// this for a one-tab window rather than spending a band of window height on an
        /// icon that is already selected.
        case hidden
    }

    /// Where the window sits when first built.
    public enum Placement {
        /// `NSWindow.center()` — AppKit's own placement.
        case centered
        /// Horizontally centered, vertically raised above center — a settings window
        /// sitting dead-center reads as low, because the eye expects a dialog slightly
        /// above the midline.
        case raised
        /// Leave the window where AppKit puts it, or position it yourself in
        /// `onWindowDidBuild`.
        case none
    }

    /// The window title. Set once, at build time, and never reassigned — see the header.
    public var title: String

    /// How the content area — BELOW the titlebar — gets its size. Whichever way, the
    /// result is fixed: `contentMinSize` and `contentMaxSize` are both pinned to it.
    public enum ContentSizing {
        /// The stated size, as is.
        case fixed(NSSize)
        /// The stated width; the height of the tallest tab's content at that width,
        /// measured when the window is built, and never less than `minimumHeight`. See
        /// "SIZING TO CONTENT" in the header.
        case fitToContent(width: CGFloat, minimumHeight: CGFloat = 0)
    }

    public var sizing: ContentSizing

    /// Standard inset for tab content, exposed so tab views can use the same value
    /// without redefining it.
    public var edgePadding: CGFloat

    /// The tabs, in toolbar order.
    public var tabs: [SettingsTabSpec]

    /// Which tab `open()` selects when no tab is named. Defaults to the first.
    public var defaultTabID: String?

    public var tabBar: TabBar

    public var styleMask: NSWindow.StyleMask

    public var placement: Placement

    /// Insert an invisible focus trap ahead of each tab's controls, so AppKit's automatic
    /// first-responder assignment does not draw a focus ring nobody asked for on open.
    /// See `SettingsFocusSink` — focus is real, one Tab press behind the first control, so
    /// keyboard users still get a ring on the first Tab.
    public var usesFocusSink: Bool

    /// Install a minimal main menu (App/File/Edit/Window) while the window is open, and
    /// restore the original on close. Menu-bar-only (`LSUIElement`) apps need this: they
    /// have no menu bar of their own, and without it Cut/Copy/Paste and ⌘W do not work in
    /// the Settings window. Regular windowed apps should leave this off.
    public var installsTemporaryMainMenu: Bool

    /// Selector on `NSApp.delegate` that the temporary menu's "About <app>" item targets.
    /// Nil leaves the item pointing at AppKit's standard About panel.
    public var aboutMenuAction: Selector?

    /// Called after the window is built and before it is shown. The escape hatch for
    /// anything this configuration does not cover.
    public var onWindowDidBuild: ((NSWindow) -> Void)?

    /// Called when the selected tab changes, with the new tab's id — for per-tab setup
    /// such as starting a log-file monitor or re-querying the login-item state.
    public var onTabSelected: ((String) -> Void)?

    /// Called when the window becomes key. Used to re-check state that can change while
    /// the app is in the background (a login item toggled in System Settings).
    public var onWindowDidBecomeKey: (() -> Void)?

    /// Called when the window stops being key. The counterpart to `onWindowDidBecomeKey`,
    /// for work that should not continue while the window is not in front — stopping a
    /// file-system monitor rather than leaving it armed against a window nobody is
    /// looking at.
    public var onWindowDidResignKey: (() -> Void)?

    /// Called as the window closes, before the controller tears down its own state.
    public var onWindowWillClose: (() -> Void)?

    public static let defaultEdgePadding: CGFloat = 18

    public init(title: String,
                sizing: ContentSizing,
                tabs: [SettingsTabSpec],
                defaultTabID: String? = nil,
                edgePadding: CGFloat = SettingsWindowConfiguration.defaultEdgePadding,
                tabBar: TabBar = .toolbar,
                styleMask: NSWindow.StyleMask = [.titled, .closable],
                placement: Placement = .raised,
                usesFocusSink: Bool = true,
                installsTemporaryMainMenu: Bool = false,
                aboutMenuAction: Selector? = nil,
                onWindowDidBuild: ((NSWindow) -> Void)? = nil,
                onTabSelected: ((String) -> Void)? = nil,
                onWindowDidBecomeKey: (() -> Void)? = nil,
                onWindowDidResignKey: (() -> Void)? = nil,
                onWindowWillClose: (() -> Void)? = nil) {
        self.title = title
        self.sizing = sizing
        self.tabs = tabs
        self.defaultTabID = defaultTabID
        self.edgePadding = edgePadding
        self.tabBar = tabBar
        self.styleMask = styleMask
        self.placement = placement
        self.usesFocusSink = usesFocusSink
        self.installsTemporaryMainMenu = installsTemporaryMainMenu
        self.aboutMenuAction = aboutMenuAction
        self.onWindowDidBuild = onWindowDidBuild
        self.onTabSelected = onTabSelected
        self.onWindowDidBecomeKey = onWindowDidBecomeKey
        self.onWindowDidResignKey = onWindowDidResignKey
        self.onWindowWillClose = onWindowWillClose
    }

    /// The original shape: a stated content size. Equivalent to `sizing: .fixed(_:)`.
    public init(title: String,
                contentSize: NSSize,
                tabs: [SettingsTabSpec],
                defaultTabID: String? = nil,
                edgePadding: CGFloat = SettingsWindowConfiguration.defaultEdgePadding,
                tabBar: TabBar = .toolbar,
                styleMask: NSWindow.StyleMask = [.titled, .closable],
                placement: Placement = .raised,
                usesFocusSink: Bool = true,
                installsTemporaryMainMenu: Bool = false,
                aboutMenuAction: Selector? = nil,
                onWindowDidBuild: ((NSWindow) -> Void)? = nil,
                onTabSelected: ((String) -> Void)? = nil,
                onWindowDidBecomeKey: (() -> Void)? = nil,
                onWindowDidResignKey: (() -> Void)? = nil,
                onWindowWillClose: (() -> Void)? = nil) {
        self.init(title: title,
                  sizing: .fixed(contentSize),
                  tabs: tabs,
                  defaultTabID: defaultTabID,
                  edgePadding: edgePadding,
                  tabBar: tabBar,
                  styleMask: styleMask,
                  placement: placement,
                  usesFocusSink: usesFocusSink,
                  installsTemporaryMainMenu: installsTemporaryMainMenu,
                  aboutMenuAction: aboutMenuAction,
                  onWindowDidBuild: onWindowDidBuild,
                  onTabSelected: onTabSelected,
                  onWindowDidBecomeKey: onWindowDidBecomeKey,
                  onWindowDidResignKey: onWindowDidResignKey,
                  onWindowWillClose: onWindowWillClose)
    }
}

// MARK: - Tab View Controller

/// An `NSTabViewController` that re-seats keyboard focus on the focus sink whenever the
/// selected tab changes, and reports selection changes upward.
///
/// The delegate method is OVERRIDDEN rather than a second delegate installed:
/// `NSTabViewController` is its own tabView's delegate and traps if that is reassigned.
/// The async hop is required — at `didSelect` the newly selected tab's view is not yet in
/// the window, so `makeFirstResponder` would be sent to nil.
@MainActor
private final class SettingsTabViewController: NSTabViewController {
    var usesFocusSink = true
    var onSelect: ((Int) -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        onSelect?(selectedTabViewItemIndex)

        guard usesFocusSink, let contentView = tabViewItem?.view else { return }
        Task { @MainActor [weak self] in
            guard self != nil,
                  let button = Self.findSinkButton(in: contentView),
                  let window = unsafe button.window else { return }
            window.makeFirstResponder(button)
        }
    }

    private static func findSinkButton(in view: NSView) -> SettingsFocusSink.SinkButton? {
        if let button = view as? SettingsFocusSink.SinkButton { return button }
        for subview in view.subviews {
            if let found = findSinkButton(in: subview) { return found }
        }
        return nil
    }
}

// MARK: - Settings Window Controller

/// Owns the one Settings window: builds it on first open, reuses it while it is up, and
/// discards it in `windowWillClose`. Nothing from a previous opening survives, which is
/// deliberate — transient per-tab state resets rather than persisting invisibly.
@MainActor
public final class SettingsWindowController: NSObject, NSWindowDelegate, Loggable {
    public nonisolated static let logTag = "[SettingsWindow]"

    private let configuration: SettingsWindowConfiguration

    private var window: NSWindow?
    private var tabViewController: SettingsTabViewController?
    private var tabIDs: [String] = []

    /// The content size the current window was built with — `configuration.sizing`
    /// resolved against the tabs' measured content. Meaningful only while `window` is.
    private var contentSize: NSSize = .zero

    /// The last tab id handed to `onTabSelected`, so the explicit report after building
    /// cannot double-fire with AppKit's own `didSelect` callback.
    private var lastReportedTabID: String?

    /// Saved main menu, restored on close when `installsTemporaryMainMenu` is on.
    private var savedMainMenu: NSMenu?
    private var temporaryMainMenuInstalled = false

    public init(_ configuration: SettingsWindowConfiguration) {
        self.configuration = configuration
        super.init()
    }

    // MARK: Public API

    /// The window, if one is currently up and visible — for a caller that must know
    /// whether Settings is open before, say, changing activation policy.
    public var visibleWindow: NSWindow? {
        guard let window, window.isVisible else { return nil }
        return window
    }

    /// The id of the currently selected tab, or nil when the window is not built.
    public var selectedTabID: String? {
        guard let index = tabViewController?.selectedTabViewItemIndex,
              tabIDs.indices.contains(index) else { return nil }
        return tabIDs[index]
    }

    /// Opens the window, raising an already-open one rather than building a second, and
    /// selecting `tab` if one is named.
    public func open(tab id: String? = nil) {
        let target = id ?? configuration.defaultTabID ?? configuration.tabs.first?.id

        if let existing = window, existing.isVisible {
            if let target { selectTab(target) }
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            log("Settings window already open; switched to tab '\(target ?? "—")'.")
            return
        }

        buildWindow()
        if let target { selectTab(target) }

        guard let window else { return }
        if let target { reportTabSelected(target) }
        installTemporaryMainMenuIfNeeded()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        log("Settings window opened on tab '\(target ?? "—")'.")
    }

    /// Selects a tab by id. A no-op when the window is not built or the id is unknown —
    /// what a stale menu item should do rather than crash.
    public func selectTab(_ id: String) {
        guard let tabViewController, let index = tabIDs.firstIndex(of: id) else { return }
        tabViewController.selectedTabViewItemIndex = index
    }

    /// Delivers `onTabSelected` at most once per actual change.
    ///
    /// AppKit does not reliably call `tabView(_:didSelect:)` for a tab view's initial
    /// selection, and assigning `selectedTabViewItemIndex` the index it already holds
    /// produces no callback at all — so without the explicit report after building, per-tab
    /// setup would not run until the user left the opening tab and came back.
    private func reportTabSelected(_ id: String) {
        guard lastReportedTabID != id else { return }
        lastReportedTabID = id
        configuration.onTabSelected?(id)
    }

    /// Closes the window if it is open. Teardown runs through `windowWillClose`.
    public func close() {
        window?.performClose(nil)
    }

    // MARK: Building

    private func buildWindow() {
        guard window == nil else { return }
        guard !configuration.tabs.isEmpty else {
            log("ERROR: Settings window has no tabs; refusing to build.")
            return
        }

        // The tabs' controllers are built BEFORE the window, because under `.fitToContent`
        // the window's size is theirs to decide.
        tabIDs = configuration.tabs.map(\.id)
        let controllers = configuration.tabs.map {
            $0.makeViewController(configuration.usesFocusSink)
        }
        let contentSize = resolveContentSize(measuring: controllers)
        self.contentSize = contentSize

        // `NSWindow(contentRect:)` takes a CONTENT rect and derives the frame itself.
        // Passing `NSWindow.frameRect(forContentRect:styleMask:)` here would add the
        // titlebar height a second time.
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: contentSize),
                              styleMask: configuration.styleMask,
                              backing: .buffered,
                              defer: false)
        window.title = configuration.title
        window.contentMinSize = contentSize
        window.contentMaxSize = contentSize
        // AppKit's default of `true` performs an extra release on close, over-releasing a
        // window this controller holds strongly.
        window.isReleasedWhenClosed = false
        window.delegate = self

        switch configuration.tabBar {
        case .toolbar:
            window.contentViewController = buildTabViewController(hosting: controllers)
        case .hidden:
            window.contentViewController = buildSingleTabController(hosting: controllers)
        }

        window.setContentSize(contentSize)
        place(window)
        self.window = window

        configuration.onWindowDidBuild?(window)
    }

    /// `configuration.sizing` as a concrete size. `.fixed` is returned as is; the
    /// measuring `.fitToContent` does happens here, once, against the built controllers.
    private func resolveContentSize(measuring controllers: [NSViewController]) -> NSSize {
        switch configuration.sizing {
        case .fixed(let size):
            return size
        case .fitToContent(let width, let minimumHeight):
            let tallest = controllers
                .map { Self.fittingHeight(of: $0, width: width) }
                .max() ?? 0
            return NSSize(width: width, height: max(tallest, minimumHeight))
        }
    }

    /// The height `controller`'s view wants at `width`, captions wrapped at that width.
    ///
    /// A hosting controller is asked through SwiftUI's own layout (`sizeThatFits`), which
    /// needs no window: proposing a token height to a top-aligned, free-to-grow tab yields
    /// the content's ideal height. An AppKit controller is asked through Auto Layout, its
    /// width pinned for the duration of the question. Rounded up: a fractional content
    /// height would put the window on a half-point boundary and blur every hairline in it.
    private static func fittingHeight(of controller: NSViewController, width: CGFloat) -> CGFloat {
        if let hosting = controller as? (any SettingsHostingControllerSizing) {
            return ceil(hosting.fittingHeight(forWidth: width))
        }
        let view = controller.view
        let widthConstraint = view.widthAnchor.constraint(equalToConstant: width)
        widthConstraint.isActive = true
        defer { widthConstraint.isActive = false }
        return ceil(view.fittingSize.height)
    }

    private func buildTabViewController(hosting controllers: [NSViewController])
    -> NSTabViewController {
        let tabViewController = SettingsTabViewController()
        tabViewController.tabStyle = .toolbar
        tabViewController.usesFocusSink = configuration.usesFocusSink
        tabViewController.onSelect = { [weak self] index in
            guard let self, self.tabIDs.indices.contains(index) else { return }
            self.reportTabSelected(self.tabIDs[index])
        }

        for (spec, controller) in zip(configuration.tabs, controllers) {
            pinToContentSize(controller.view)

            let item = NSTabViewItem(viewController: controller)
            item.label = spec.title
            if let symbolName = spec.symbolName {
                item.image = NSImage(systemSymbolName: symbolName,
                                     accessibilityDescription: spec.title)
            }
            tabViewController.addTabViewItem(item)
        }

        tabViewController.view.layoutSubtreeIfNeeded()
        self.tabViewController = tabViewController
        return tabViewController
    }

    private func buildSingleTabController(hosting controllers: [NSViewController])
    -> NSViewController {
        guard let controller = controllers.first else { return NSViewController() }

        // With no tab view controller to measure it, the hosted view must NOT size the
        // window: `NSHostingView` answers a size change by resizing the window, which
        // resizes it again, until AppKit throws `NSGenericException`. `sizingOptions = []`
        // switches that propagation off and the window's fixed min/max size decides.
        if let hosting = controller as? (any SettingsHostingControllerSizing) {
            hosting.disableAutomaticSizing()
        }
        // `NSHostingView` opts out of the autoresizing mask, so with sizing off it
        // collapses to zero. Handing the mask back makes the view one the window TELLS its
        // size, which cannot answer back — hence no constraint loop.
        controller.view.translatesAutoresizingMaskIntoConstraints = true
        controller.view.frame = NSRect(origin: .zero, size: contentSize)
        controller.view.autoresizingMask = [.width, .height]
        return controller
    }

    /// Pins a tab's view to the content size, so `NSTabViewController` measures every tab
    /// the same and the window does not resize between them.
    private func pinToContentSize(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: contentSize.width),
            view.heightAnchor.constraint(equalToConstant: contentSize.height),
        ])
    }

    private func place(_ window: NSWindow) {
        switch configuration.placement {
        case .centered:
            window.center()
        case .raised:
            guard let visibleFrame = NSScreen.main?.visibleFrame else {
                window.center()
                return
            }
            let frame = window.frame
            let origin = NSPoint(x: visibleFrame.midX - frame.width / 2.0,
                                 y: visibleFrame.midY - frame.height / 12.0)
            window.setFrameOrigin(origin)
        case .none:
            break
        }
    }

    // MARK: Temporary Main Menu

    private func installTemporaryMainMenuIfNeeded() {
        guard configuration.installsTemporaryMainMenu, !temporaryMainMenuInstalled else {
            return
        }
        savedMainMenu = NSApp.mainMenu
        NSApp.mainMenu = SettingsMainMenu.make(aboutAction: configuration.aboutMenuAction)
        temporaryMainMenuInstalled = true
    }

    private func restoreMainMenuIfNeeded() {
        guard temporaryMainMenuInstalled else { return }
        NSApp.mainMenu = savedMainMenu
        savedMainMenu = nil
        temporaryMainMenuInstalled = false
    }

    // MARK: NSWindowDelegate

    public func windowDidBecomeKey(_ notification: Notification) {
        configuration.onWindowDidBecomeKey?()
    }

    public func windowDidResignKey(_ notification: Notification) {
        configuration.onWindowDidResignKey?()
    }

    public func windowWillClose(_ notification: Notification) {
        configuration.onWindowWillClose?()

        // Dropped before the view tree goes away, so AppKit is not left holding a
        // responder inside a controller about to be deallocated.
        window?.makeFirstResponder(nil)
        restoreMainMenuIfNeeded()

        window?.contentViewController = nil
        tabViewController = nil
        tabIDs = []
        lastReportedTabID = nil
        window = nil
        log("Settings window closed.")
    }
}

// MARK: - Hosting Controller Sizing

/// Lets the controller talk to a hosting controller about size without knowing its
/// generic parameter: switching off automatic size propagation
/// (`buildSingleTabController`) and measuring its content (`.fitToContent`).
@MainActor
public protocol SettingsHostingControllerSizing: AnyObject {
    func disableAutomaticSizing()
    /// The height the hosted view wants at `width`.
    func fittingHeight(forWidth width: CGFloat) -> CGFloat
}

extension NSHostingController: SettingsHostingControllerSizing {
    public func disableAutomaticSizing() { sizingOptions = [] }

    /// Height 1, not 0: a zero proposal is the one some SwiftUI containers treat as
    /// "collapse", while any positive token is simply too small and answered with the
    /// content's ideal height.
    public func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        sizeThatFits(in: NSSize(width: width, height: 1)).height
    }
}



// ─────────────────────────────────────────────────────────────────────────────────────
// REUSABLE SETTINGS CONTENT
//
// Each of these is independent of `SettingsWindowController` and of the others, and can be
// dropped into a window a project builds itself.
// ─────────────────────────────────────────────────────────────────────────────────────

// MARK: - Focus Sink

/// An invisible, zero-size focus trap that sits ahead of every real control in a Settings
/// tab.
///
/// AppKit assigns keyboard focus to the first focusable control when a window opens,
/// drawing a focus ring nobody asked for. The sink is first instead and absorbs that
/// assignment, drawing nothing — no focus ring, no size.
///
/// A SINK, not a suppression: focus is real, one Tab press behind the first control, so
/// keyboard users get the ring on their first Tab and mouse users never see one.
///
/// Return and Space are swallowed so the sink cannot be "pressed"; every other key, Tab
/// included, drives the key-view loop normally.
@MainActor
public struct SettingsFocusSink: NSViewRepresentable {

    public init() {}

    public func makeNSView(context: Context) -> SinkButton {
        let button = SinkButton()
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.title = ""
        button.focusRingType = .none
        button.translatesAutoresizingMaskIntoConstraints = false
        // Zero-size at required priority, so the button contributes no intrinsic size to
        // the hosting view that wraps it.
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 0),
            button.heightAnchor.constraint(equalToConstant: 0),
        ])
        // The async hop is needed: at `makeNSView` return the hosting view is not yet in a
        // window, so `window?.makeFirstResponder` would be sent to nil.
        //
        // The visibility check matters in a tabbed window: every tab's view is built up
        // front to be measured, so every tab's sink runs this and the last one would claim
        // focus — possibly inside a tab the user cannot see. A sink that declines here gets
        // its turn when `SettingsTabViewController` re-seats focus on its tab.
        Task { @MainActor [weak button] in
            guard let button, let window = unsafe button.window,
                  !button.isHiddenOrHasHiddenAncestor else { return }
            window.makeFirstResponder(button)
        }
        return button
    }

    public func updateNSView(_ nsView: SinkButton, context: Context) {}

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: SinkButton,
                             context: Context) -> CGSize? {
        .zero
    }

    public final class SinkButton: NSButton {
        public override var acceptsFirstResponder: Bool { true }

        public override func keyDown(with event: NSEvent) {
            // 36 = Return, 49 = Space. Discarded outright: no action, no beep.
            if event.keyCode == 36 || event.keyCode == 49 { return }
            super.keyDown(with: event)
        }

        /// The sink is invisible and zero-sized, so it cannot be clicked — but nothing
        /// should happen if it somehow is.
        public override func performClick(_ sender: Any?) {}
    }
}

/// Places `SettingsFocusSink` ahead of the wrapped content, collapsed to nothing.
/// `isActive: false` passes the content straight through.
@MainActor
public struct SettingsFocusSinkWrapper<Content: View>: View {
    private let isActive: Bool
    private let content: () -> Content

    public init(isActive: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.isActive = isActive
        self.content = content
    }

    public var body: some View {
        if isActive {
            VStack(spacing: 0) {
                // Zero height at the SwiftUI level as well as at the Auto Layout level;
                // the wrapped content's own layout is untouched.
                SettingsFocusSink()
                    .frame(height: 0)
                    .clipped()
                    .accessibilityHidden(true)

                content()
            }
        } else {
            content()
        }
    }
}

// MARK: - Temporary Main Menu

/// Builds the minimal main menu a menu-bar-only (`LSUIElement`) app installs while its
/// Settings window is open.
///
/// Such an app has no menu bar of its own, so without this the Settings window gets no
/// Cut/Copy/Paste, no ⌘W and no ⌘Q. `SettingsWindowController` installs this when
/// `installsTemporaryMainMenu` is on and restores the original menu on close.
@MainActor
public enum SettingsMainMenu {

    /// `aboutAction` targets `NSApp.delegate`, for an app that routes About somewhere of
    /// its own; nil leaves AppKit's standard About panel.
    public static func make(aboutAction: Selector? = nil) -> NSMenu {
        let mainMenu = NSMenu()
        let appName = ProcessInfo.processInfo.processName

        // ----- Application menu (first) -----
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appSubmenu = NSMenu()

        if let aboutAction {
            let aboutItem = NSMenuItem(title: "About \(appName)",
                                       action: aboutAction, keyEquivalent: "?")
            aboutItem.target = NSApp.delegate
            appSubmenu.addItem(aboutItem)
        } else {
            appSubmenu.addItem(withTitle: "About \(appName)",
                               action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                               keyEquivalent: "")
        }

        appSubmenu.addItem(.separator())
        appSubmenu.addItem(withTitle: "Hide \(appName)",
                           action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appSubmenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appSubmenu.addItem(withTitle: "Show All",
                           action: #selector(NSApplication.unhideAllApplications(_:)),
                           keyEquivalent: "")

        appSubmenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit \(appName)",
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
        quitItem.target = NSApp
        appSubmenu.addItem(quitItem)
        appMenuItem.submenu = appSubmenu

        // ----- File -----
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        let closeItem = NSMenuItem(title: "Close",
                                   action: #selector(NSWindow.performClose(_:)),
                                   keyEquivalent: "w")
        closeItem.target = nil // Let the responder chain handle close.
        fileMenu.addItem(closeItem)
        fileMenuItem.submenu = fileMenu

        // ----- Edit -----
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        editMenuItem.submenu = CleanEditMenu(title: "Edit")

        // ----- Window -----
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize",
                                      action: #selector(NSWindow.performMiniaturize(_:)),
                                      keyEquivalent: "m"))
        windowMenuItem.submenu = windowMenu

        return mainMenu
    }

    /// Populates an Edit-style menu with only the intended actions, wired to the responder
    /// chain.
    ///
    /// `nonisolated` so `CleanEditMenu`'s nonisolated inits can call it without sending
    /// `self` across an isolation boundary. Safe because it touches only the menu passed
    /// in; the `dispatchPrecondition` asserts the main-thread invariant AppKit already
    /// guarantees for menu inits and `menuNeedsUpdate`.
    public nonisolated static func populateEditMenu(_ menu: NSMenu) {
        dispatchPrecondition(condition: .onQueue(.main))
        menu.removeAllItems()
        menu.addItem(NSMenuItem(title: "Undo",
                                action: Selector(("undo:")), keyEquivalent: "z"))
        menu.addItem(NSMenuItem(title: "Redo",
                                action: Selector(("redo:")), keyEquivalent: "Z"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Cut",
                                action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        menu.addItem(NSMenuItem(title: "Copy",
                                action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: "Paste",
                                action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        menu.addItem(NSMenuItem(title: "Select All",
                                action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
    }
}

/// An `NSMenu` that repopulates itself on every update, so AppKit cannot persistently
/// inject items (Start Dictation, Emoji & Symbols) into the Edit menu.
///
/// The inits are unannotated because an override cannot be more isolated than what it
/// overrides and NSMenu's bridged inits are nonisolated — which is why `populateEditMenu`
/// is nonisolated too.
public final class CleanEditMenu: NSMenu, NSMenuDelegate {
    public override init(title: String) {
        super.init(title: title)
        self.delegate = self
        SettingsMainMenu.populateEditMenu(self)
    }

    public required init(coder: NSCoder) {
        super.init(coder: coder)
        self.delegate = self
        SettingsMainMenu.populateEditMenu(self)
    }

    @MainActor
    public func menuNeedsUpdate(_ menu: NSMenu) {
        SettingsMainMenu.populateEditMenu(menu)
    }
}

// MARK: - Main Window Lifetime

/// Quits a single-main-window app when that window closes, even while the settings window
/// is still open.
///
/// `applicationShouldTerminateAfterLastWindowClosed` returning `true` is not enough once a
/// `SettingsWindowController` window exists: it is an AppKit window outside SwiftUI's scene
/// graph, so closing the main window with Settings open leaves the app running on the
/// settings window alone — and clicking the Dock icon does NOT bring a SwiftUI
/// `WindowGroup` window back in that state, stranding the user with no way to reopen it.
/// Tying the app's lifetime to the main window removes that state: closing it quits, and
/// the settings window goes with it.
///
/// Call once the main window exists — from a window-accessor view, or wherever the app
/// first gets hold of its `NSWindow`:
///
///     MainWindowLifetime.terminateWhenClosed(window)
///
/// Repeat calls for the same window are ignored, so it is safe from an `onChange` that
/// fires more than once. Not for apps that keep running without a window (menu-bar
/// applets, LANStream) or that manage several document windows.
@MainActor
public enum MainWindowLifetime: Loggable {
    public nonisolated static let logTag = "[MainWindowLifetime]"

    private static var observers: [ObjectIdentifier: CloseObserver] = [:]

    /// Terminate the app when `window` closes.
    public static func terminateWhenClosed(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard observers[id] == nil else { return }
        observers[id] = CloseObserver(window: window)
        log("Watching \"\(window.title)\" — closing it quits the app.")
    }

    /// Undo `terminateWhenClosed(_:)` for `window` (for example before replacing it).
    public static func stopTerminatingWhenClosed(_ window: NSWindow) {
        observers[ObjectIdentifier(window)] = nil
    }

    /// Selector-based on purpose: the block-based observer API needs an `@Sendable`
    /// closure and a token that a nonisolated `deinit` cannot safely remove. AppKit posts
    /// `willCloseNotification` on the main thread.
    @MainActor
    private final class CloseObserver: NSObject {
        init(window: NSWindow) {
            super.init()
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowWillClose(_:)),
                name: NSWindow.willCloseNotification, object: window)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func windowWillClose(_ notification: Notification) {
            MainWindowLifetime.log("Main window closing — terminating.")
            NSApp.terminate(nil)
        }
    }
}

// MARK: - Login Item Manager

/// Thin wrapper around `SMAppService` for launch-at-login control.
@MainActor
public enum LoginItemManager: Loggable {
    public nonisolated static let logTag = "[LoginItemManager]"

    /// The live system state. Query this rather than caching, since the user can change it
    /// in System Settings while the app is running.
    public static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    public static func setEnabled(_ enabled: Bool) {
        let status = SMAppService.mainApp.status
        if (enabled && status == .enabled) || (!enabled && status == .notRegistered) {
            log("Launch at login already \(enabled ? "enabled" : "disabled") — no changes required.")
            return
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
                log("Launch at login enabled successfully.")
            } else {
                try SMAppService.mainApp.unregister()
                log("Launch at login disabled successfully.")
            }
        } catch {
            log("ERROR: Failed to update launch at login to \(enabled ? "enabled" : "disabled") — \(error.localizedDescription)",
                level: .error)
        }
    }
}

// MARK: - Log File Monitor

/// Watches the log file's parent directory and publishes whether the log file currently
/// exists, so Reveal/Clear buttons enable and disable reactively.
///
/// It watches the DIRECTORY, not the file: the file may not exist yet, and a monitor on a
/// non-existent path never fires.
@MainActor
@Observable
public final class LogFileMonitor: Loggable {
    public nonisolated static let logTag = "[LogFileMonitor]"

    public private(set) var logFileExists: Bool = false

    private var source: (any DispatchSourceFileSystemObject)?

    public init() {}

    // Isolated, so it can read `source` directly. A release on the main actor (the usual
    // case: SwiftUI dropping the owning view's state) runs it inline; a release elsewhere
    // runs it on the main actor shortly after.
    isolated deinit {
        source?.cancel()
    }

    public func start() { start(retriesRemaining: 3, delay: 0.5) }

    public func stop() {
        source?.cancel()
        source = nil
    }

    /// Re-reads the file's existence without restarting the monitor — call after clearing
    /// or deleting the log from a button action.
    public func refresh() {
        logFileExists = FileManager.default.fileExists(atPath: Logger.safeLogFileURL.path)
    }

    // `retriesRemaining` is threaded through so a failing open cannot re-arm a fresh
    // budget each attempt — retrying via the public `start()` would turn a persistently
    // unopenable directory into an unbounded retry chain.
    private func start(retriesRemaining: Int, delay: TimeInterval) {
        stop()

        // Resolved once: `safeLogFileURL` can do FileManager work on a cold cache.
        let logFileURL = Logger.safeLogFileURL
        logFileExists = FileManager.default.fileExists(atPath: logFileURL.path)

        let path = logFileURL.deletingLastPathComponent().path
        guard let descriptor = try? FileDescriptor.open(FilePath(path), .readOnly,
                                                        options: .eventOnly) else {
            log("Failed to open log directory for monitoring: \(path)", level: .warning)
            scheduleRestart(retriesRemaining: retriesRemaining, delay: delay)
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor.rawValue,
            eventMask: [.attrib, .delete, .rename, .write],
            queue: .main)

        // The handler runs on `DispatchQueue.main`, so `MainActor.assumeIsolated` bridges
        // that guarantee into the actor system without an async hop. Flags are read through
        // `self.source` rather than by capturing `source`, which would retain-cycle
        // (source → handler → source).
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let flags = self.source?.data ?? []
                self.logFileExists = FileManager.default.fileExists(
                    atPath: Logger.safeLogFileURL.path)
                if flags.contains(.rename) || flags.contains(.delete) {
                    // The watched directory went away. A fresh situation rather than a
                    // continuation of a failing attempt, so the budget starts over.
                    self.stop()
                    self.scheduleRestart(retriesRemaining: 3, delay: 0.5)
                }
            }
        }

        // Runs on the source's own queue, and closes the descriptor it captured — which is
        // why no descriptor is stored on self.
        source.setCancelHandler { try? descriptor.close() }

        source.resume()
        self.source = source
    }

    // Retries after the source could not be established.
    //
    // Gated on nothing but a re-attempt: a retry only happens when the DIRECTORY could not
    // be opened, in which case the file cannot exist either, so testing for the file would
    // never recover. Resolving the log URL creates the directory as a side effect, which is
    // what makes a bare retry likely to succeed.
    private func scheduleRestart(retriesRemaining: Int, delay: TimeInterval) {
        guard retriesRemaining > 0 else {
            log("Giving up on re-establishing the log directory monitor.", level: .warning)
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            // A `start()` that already succeeded in the meantime makes this retry moot.
            guard let self, self.source == nil else { return }
            self.start(retriesRemaining: retriesRemaining - 1, delay: delay * 2.0)
        }
    }
}

// MARK: - Debug Logging Section

/// The Debug Logging block: a toggle, an explanatory caption, and Reveal/Clear buttons
/// gated on the log file's existence by its own `LogFileMonitor`. Clear asks for
/// confirmation first — the log is the one record of what the app did, and there is no
/// undo — so the button arms an alert rather than clearing outright.
///
/// Drop it into a tab body:
///
///     SettingsLoggingSection(loggingEnabledKey: Preferences.loggingEnabledKey) { enabled in
///         Preferences.loggingEnabled = enabled
///     }
@MainActor
public struct SettingsLoggingSection: View, Loggable {
    public nonisolated static let logTag = "[SettingsLogging]"

    private let title: String
    private let caption: String
    private let onChange: ((Bool) -> Void)?

    @AppStorage private var loggingEnabled: Bool
    @State private var monitor = LogFileMonitor()
    @State private var showClearLogAlert = false

    /// `loggingEnabledKey` must be the same UserDefaults key the project's `Preferences`
    /// uses, so the toggle and the logger's own predicate read one value.
    ///
    /// `onChange` receives the new value and runs BEFORE the logger is torn down, for the
    /// project's own side effects (posting a preferences-changed notification, reconciling
    /// a menu). The shutdown/forced-log handling below is done for you.
    public init(loggingEnabledKey: String,
                title: String = "Debug Logging",
                caption: String = "Messages are buffered before being written to disk every ten seconds.",
                onChange: ((Bool) -> Void)? = nil) {
        self._loggingEnabled = AppStorage(wrappedValue: false, loggingEnabledKey)
        self.title = title
        self.caption = caption
        self.onChange = onChange
    }

    public var body: some View {
        Toggle(isOn: $loggingEnabled) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(caption)
                    .font(.system(size: NSFont.smallSystemFontSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Button("Reveal Log in Finder") {
                        let url = Logger.safeLogFileURL
                        if FileManager.default.fileExists(atPath: url.path) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                            Self.log("Reveal log triggered.")
                        }
                    }
                    .disabled(!monitor.logFileExists)

                    Button("Clear Log") { showClearLogAlert = true }
                    .disabled(!monitor.logFileExists)

                    Spacer()
                }
                .padding(.top, 8)
            }
        }
        .onChange(of: loggingEnabled) { oldValue, newValue in
            // Compared against `oldValue`, NOT the preference: `@AppStorage` commits the
            // new value before this closure runs, so the preference always equals
            // `newValue` and a guard against it would suppress the body every time.
            guard newValue != oldValue else { return }
            onChange?(newValue)

            if newValue {
                Self.log("Logging toggled -> true")
            } else {
                // `@AppStorage` has already committed `false`, so an ordinary log would be
                // dropped and nothing would record why the log goes silent. `logForced` is
                // the bypass for that one line; `shutdownLogging()` flushes it to disk.
                Logger.logForced("Logging toggled -> false", cName: Self.logTag)
                Logger.shutdownLogging()
            }
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
        .alert("Clear Log File?", isPresented: $showClearLogAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) { clearLog() }
        } message: {
            Text("This will permanently erase the current contents of the debug log file. This action cannot be undone.")
        }
    }

    private func clearLog() {
        // `Logger.clearLog()` rather than writing empty Data at the file: it drains the
        // pipe and the write chain first, so the clear cannot land in the middle of an
        // in-flight append.
        Task {
            let cleared = await Logger.clearLog()
            monitor.refresh()
            Self.log(cleared ? "Log file cleared by user."
                             : "ERROR: Failed to clear log file.",
                     level: cleared ? .info : .error)
        }
    }
}

// MARK: - Launch At Login Toggle

/// The launch-at-login checkbox, kept in sync with the live system state.
///
/// Re-queried on appear and whenever the app regains focus, because the user can change
/// Login Items in System Settings while this window is open. The delay after toggling is
/// because `SMAppService.status` does not reflect a register/unregister immediately.
@MainActor
public struct LaunchAtLoginToggle: View, Loggable {
    public nonisolated static let logTag = "[LaunchAtLogin]"

    private let title: String
    @State private var isOn: Bool = LoginItemManager.isEnabled

    public init(title: String = "Launch at login") {
        self.title = title
    }

    public var body: some View {
        Toggle(title, isOn: $isOn)
            .onChange(of: isOn) { _, newValue in
                LoginItemManager.setEnabled(newValue)
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    isOn = LoginItemManager.isEnabled
                }
                Self.log("Launch at Login toggled -> \(newValue)")
            }
            .onAppear { isOn = LoginItemManager.isEnabled }
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)
            ) { _ in
                isOn = LoginItemManager.isEnabled
            }
    }
}

// MARK: - Settings Row Factory
//
// Nearly every Settings row across these apps is the same shape: a title, an optional
// secondary caption, and sometimes a trailing control on the title line or a strip of
// buttons beneath it. Some rows are headed by their own checkbox; the rest have to be
// pushed right by the width of a checkbox-plus-gap so every title lands on one vertical
// line and the tab reads as a single column.
//
// `SettingsMetrics.checkboxTitleInset` is that offset (19 pt). `SettingsRow` builds the
// shared shape and applies the inset for the control-less rows; `SettingsPage` is the
// outer stack that holds the rows. The genuine outliers stay hand-built — reach for
// `.settingsCheckboxTitleAligned()` on those so they still line up.

/// Shared layout values for a Settings tab, so every project's rows agree on one grid.
public enum SettingsMetrics {

    /// The leading inset that lines a control-less row's title up with the titles of rows
    /// headed by a checkbox. macOS draws a checkbox roughly 13 pt wide followed by a ~6 pt
    /// gap before its label; 19 pt is that combined width. A row that has its own checkbox
    /// must NOT take this inset — the checkbox already occupies the column.
    public static let checkboxTitleInset: CGFloat = 19

    /// The leading inset for a row that is a genuine child of the row above it — most
    /// often a checkbox whose meaning depends on a parent checkbox being on. Unlike
    /// `checkboxTitleInset`, this is a visible step in from the grid, not a correction
    /// that keeps titles on one line; a child row that has its own checkbox takes this
    /// inset in full.
    public static let childRowInset: CGFloat = 40

    /// Vertical gap between rows in a tab's outer stack.
    public static let sectionSpacing: CGFloat = 16

    /// Vertical gap between a row's title, its caption, and its accessory strip.
    public static let rowContentSpacing: CGFloat = 4

    /// Horizontal gap between the title and a trailing control on the title line.
    public static let titleControlSpacing: CGFloat = 6

    /// Horizontal gap between buttons in a row's accessory strip.
    public static let controlSpacing: CGFloat = 12

    /// Padding from the row's caption down to its accessory strip.
    public static let accessoryTopPadding: CGFloat = 8

    /// A tab's edge padding. Kept in step with `SettingsWindowConfiguration.defaultEdgePadding`
    /// by hand — a stored reference to it cannot be nonisolated, and these values are read
    /// from nonisolated default-argument positions.
    public static let edgePadding: CGFloat = 18
}

public extension View {
    /// Insets the view so its leading edge lines up with the titles of checkbox-headed
    /// `SettingsRow`s. For the custom rows the factory does not cover.
    func settingsCheckboxTitleAligned(_ inset: CGFloat = SettingsMetrics.checkboxTitleInset)
    -> some View {
        padding(.leading, inset)
    }

    /// Insets the view by `SettingsMetrics.childRowInset` so it reads as a child of the
    /// row above it. For dependent checkbox rows and other hand-built sub-rows.
    func settingsChildRowInset(_ inset: CGFloat = SettingsMetrics.childRowInset)
    -> some View {
        padding(.leading, inset)
    }
}

/// One Settings row: a title, an optional caption, an optional trailing control on the
/// title line, and an optional accessory strip (usually buttons) beneath.
///
///     // A plain row — inset so its title aligns with the checkbox rows below.
///     SettingsRow("nvNotes reads and writes .txt files directly in this folder.")
///
///     // A checkbox row — no inset; the checkbox fills the alignment column.
///     SettingsRow("Always use a light background for notes",
///                 leading: .checkbox($preferLightBody))
///
///     // A plain row with a trailing picker and a caption.
///     SettingsRow("Frequency axis scale:",
///                 description: "Force a consistent scale, or let Spectrum decide.") {
///         Picker("", selection: $clamp) { /* … */ }.labelsHidden().frame(width: 120)
///     }
///
/// The `inset` is a parameter, defaulted to `SettingsMetrics.checkboxTitleInset`, so a
/// project that needs a different grid can pass its own without abandoning the factory.
@MainActor
public struct SettingsRow<Trailing: View, Accessory: View>: View {

    /// What sits at the row's leading edge.
    public enum Leading {
        /// The row is headed by its own checkbox, bound to `isOn`. Takes no inset.
        case checkbox(Binding<Bool>)
        /// No control: the title is inset by `inset` so it aligns with the checkbox rows.
        case aligned
        /// No control and no inset — flush to the leading edge, for a row that means to
        /// break the grid.
        case flush
    }

    private let title: String
    private let description: String?
    private let leading: Leading
    private let isEnabled: Bool
    private let inset: CGFloat
    private let trailing: () -> Trailing
    private let accessory: () -> Accessory

    public init(_ title: String,
                description: String? = nil,
                leading: Leading = .aligned,
                isEnabled: Bool = true,
                inset: CGFloat = SettingsMetrics.checkboxTitleInset,
                @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
                @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.title = title
        self.description = description
        self.leading = leading
        self.isEnabled = isEnabled
        self.inset = inset
        self.trailing = trailing
        self.accessory = accessory
    }

    public var body: some View {
        switch leading {
        case .checkbox(let isOn):
            Toggle(isOn: isOn) { label }
                .disabled(!isEnabled)
        case .aligned:
            label
                .padding(.leading, inset)
                .disabled(!isEnabled)
        case .flush:
            label
                .disabled(!isEnabled)
        }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowContentSpacing) {
            // An `EmptyView` trailing contributes no size and no spacing, so the common
            // no-trailing-control row still reads as a bare title.
            HStack(alignment: .firstTextBaseline,
                   spacing: SettingsMetrics.titleControlSpacing) {
                Text(title)
                trailing()
            }

            if let description {
                Text(description)
                    .font(.system(size: NSFont.smallSystemFontSize))
                    .foregroundStyle(isEnabled ? AnyShapeStyle(.secondary)
                                               : AnyShapeStyle(.quaternary))
                    .fixedSize(horizontal: false, vertical: true)
            }

            accessory()
        }
    }
}

/// A horizontal strip of buttons for a `SettingsRow`'s `accessory`, spaced by
/// `SettingsMetrics.controlSpacing`, trailing `Spacer`, and offset down from the caption.
///
///     SettingsRow("Debug logging", description: "…", leading: .checkbox($enabled)) {
///     } accessory: {
///         SettingsControlStrip {
///             Button("Reveal Log in Finder") { … }
///             Button("Clear Log") { … }
///         }
///     }
@MainActor
public struct SettingsControlStrip<Content: View>: View {
    private let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        HStack(spacing: SettingsMetrics.controlSpacing) {
            content()
            Spacer()
        }
        .padding(.top, SettingsMetrics.accessoryTopPadding)
    }
}

/// The outer stack of a Settings tab: leading-aligned, `sectionSpacing` between children,
/// `edgePadding` on every side. Put `SettingsRow`s and `Divider()`s inside.
@MainActor
public struct SettingsPage<Content: View>: View {
    private let spacing: CGFloat
    private let padding: CGFloat
    private let content: () -> Content

    public init(spacing: CGFloat = SettingsMetrics.sectionSpacing,
                padding: CGFloat = SettingsMetrics.edgePadding,
                @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.padding = padding
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content()
        }
        .padding(padding)
    }
}

// MARK: - Described Toggle

/// A checkbox with a secondary description beneath it. Passing `isEnabled: false` dims the
/// caption along with the control, for a row that depends on another setting.
///
/// A thin preset over `SettingsRow(_:description:leading:isEnabled:)` — kept as its own
/// name because call sites already read well.
@MainActor
public struct SettingsDescribedToggle: View {
    private let title: String
    private let description: String
    private let isEnabled: Bool
    @Binding private var isOn: Bool

    public init(_ title: String, description: String,
                isOn: Binding<Bool>, isEnabled: Bool = true) {
        self.title = title
        self.description = description
        self._isOn = isOn
        self.isEnabled = isEnabled
    }

    public var body: some View {
        SettingsRow(title,
                    description: description,
                    leading: .checkbox($isOn),
                    isEnabled: isEnabled)
    }
}