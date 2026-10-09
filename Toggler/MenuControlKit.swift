// MARK: - MenuControlKit.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// STANDARDIZED MENU-BAR APPLET CONTROLLER — describe the status item and the menu,
// hand it over, done.
//
// The unified successor to the four `StatusMenuController.swift` copies in LAN Stream,
// Toggler, Process Elimination and Ethernet Status, and to the SF Symbol cache those
// applets each reimplemented. All four controllers were the same object — a
// `@MainActor NSObject` owning an `NSStatusItem` with a template SF Symbol, an
// `autoenablesItems = false` menu built from a local `item(title:action:key:)` helper,
// preference-backed checkmark rows reconciled on open, a Settings…/About…/Quit tail, and
// a synchronous termination path that pulls the status item — differing in which rows
// they carried and how dynamic those rows were.
//
// WIRING IT UP
// ────────────
//   private lazy var menu = MenuController(.init(
//       appName: "Toggler",
//       icon: { .symbol(.menuBar("antenna.radiowaves.left.and.right", weight: .bold),
//                       fallbackTitle: "Toggler") },
//       elements: { [weak self] in
//           guard let self else { return [] }
//           return [
//               .header("Upon Sleep While Undocked:"),
//               .toggle(id: "wifiSleep", title: "Disable Wi-Fi", key: "z",
//                       isOn: { Preferences.disableWiFiDuringSleep },
//                       setOn: { Preferences.disableWiFiDuringSleep = $0 }),
//               .separator,
//               .action(id: "settings", title: "Settings…", key: ",") {
//                   self.settings.open()
//               },
//               .separator,
//               .about(title: "About Toggler…") { NSApp.orderFrontStandardAboutPanel(nil) },
//               .separator,
//               .quit(title: "Quit Toggler"),
//           ]
//       }))
//
//   menu.install()                            // at launch
//   menu.prepareForTerminationSynchronously() // in applicationWillTerminate
//
// THE ONE MODEL THAT COVERS ALL FOUR
// ──────────────────────────────────
// `elements` is a closure re-evaluated on every `menuWillOpen`. That is already what
// LAN Stream does (it calls `menu.removeAllItems()` and rebuilds), and it is what the
// other three approximate with a build-once menu plus a reconcile pass on open. Making it
// the single model means a row that appears conditionally, a checkmark that tracks a
// preference, and a row whose title includes live state are all just the closure returning
// something different — no insert/remove bookkeeping, no separator-pair tracking, no
// `updateCheckmarksFromPreferences()`.
//
// Rebuilding does NOT discard custom views: `.custom` caches its `NSView` by id and
// reuses it across rebuilds, calling `update` on each open. That preserves Ethernet
// Status's persistent `StatusSectionView`, which is updated in place rather than rebuilt.
//
// TWO CONSEQUENCES WORTH KNOWING BEFORE MIGRATING
// ───────────────────────────────────────────────
// 1. `NSMenuItem` references do not survive a rebuild. Toggler and Process Elimination
//    both vend live items to a permission controller (`bluetoothItems`, `aqItems`) which
//    reaches in to set `isEnabled` and a warning glyph from outside the menu. Those
//    accessors have to go: express the same thing as `isEnabled:` and `symbolName:` on the
//    element, computed from the permission state inside the `elements` closure, which is
//    re-read on every open. Holding an item and mutating it later would silently affect an
//    object no longer in the menu.
// 2. Handlers outlive the open. The per-element closures are retained until the next
//    rebuild, so one capturing its owner strongly forms a cycle through this controller —
//    harmless while both live for the app's lifetime, and broken by
//    `prepareForTerminationSynchronously()`, but capture `[weak self]` in `elements` and
//    let the per-element closures inherit that unwrapped reference.

import Cocoa

// MARK: - Symbol Cache
//
// Cached, configured SF Symbol glyphs — system or private (CoreGlyphsPrivate).
//
// It lives here rather than in a file of its own because every use of it is a menu-bar
// icon or a glyph inside a menu item. Ethernet Status had it as a real type; Toggler and
// Process Elimination had a cut-down `static func symbolImage(named:pointSize:weight:scale:)`
// duplicated verbatim between them, with no caching at all; LAN Stream built a fresh
// `NSImage(systemSymbolName:)` on every menu open. This is the full version, and
// `MenuController` routes every glyph it draws through it.
//
//   SymbolCache.shared.image(named: "ethernet", pointSize: 13, weight: .semibold,
//                            scale: .medium, isPrivate: true)
//   SymbolCache.shared.image(symbol, alpha: 0.25)
//   SymbolCache.shared.prewarm([.menuBar("network"), .menuBar("network.slash")])

/// One symbol's full parameter set — a cache key, a prewarm request, and the argument to
/// `MenuBarIcon`, all in one value.
public struct SymbolSpec: Hashable, Sendable {
    public var name: String
    public var pointSize: CGFloat?
    public var weight: NSFont.Weight?
    /// `NSImage.SymbolScale` is not `Sendable`/`Hashable`, so the raw value is stored.
    public var scaleRawValue: Int?
    /// Resolve from `CoreGlyphsPrivate.bundle` rather than the system symbol set.
    public var isPrivate: Bool

    public var scale: NSImage.SymbolScale? {
        get { scaleRawValue.flatMap(NSImage.SymbolScale.init(rawValue:)) }
        set { scaleRawValue = newValue?.rawValue }
    }

    public init(name: String,
                pointSize: CGFloat? = nil,
                weight: NSFont.Weight? = nil,
                scale: NSImage.SymbolScale? = nil,
                isPrivate: Bool = false) {
        self.name = name
        self.pointSize = pointSize
        self.weight = weight
        self.scaleRawValue = scale?.rawValue
        self.isPrivate = isPrivate
    }

    /// The size/weight/scale combination the menu-bar button uses in every one of these
    /// applets. `weight` differs per app, so it stays a parameter.
    public static func menuBar(_ name: String, weight: NSFont.Weight = .regular,
                               isPrivate: Bool = false) -> SymbolSpec {
        SymbolSpec(name: name, pointSize: NSFont.systemFontSize, weight: weight,
                   scale: .medium, isPrivate: isPrivate)
    }

    /// The size/weight/scale used for glyphs rendered inside menu item titles.
    public static func menuItem(_ name: String, isPrivate: Bool = false) -> SymbolSpec {
        SymbolSpec(name: name, pointSize: NSFont.systemFontSize, weight: .regular,
                   scale: .medium, isPrivate: isPrivate)
    }

    fileprivate var cacheKey: String {
        var key = name
        if let pointSize { key += "|p:\(pointSize)" }
        if let weight { key += "|w:\(weight.rawValue)" }
        if let scaleRawValue { key += "|s:\(scaleRawValue)" }
        if isPrivate { key += "|private" }
        return key
    }
}

/// `@MainActor` makes the compiler enforce what was previously an undocumented "all
/// callers happen to be on main" invariant. Every existing call site already qualified.
@MainActor
public final class SymbolCache {
    public static let shared = SymbolCache()

    // A plain dictionary rather than NSCache. The set of symbols an applet uses is small
    // and entirely known at launch (all of it prewarmed), so eviction is pure downside:
    // an NSCache can drop a glyph under memory pressure and pay to rebuild it during the
    // very redraw that pressure made expensive. `clearCache()` covers the cases —
    // appearance change, deliberate purge — where eviction is actually wanted.
    private var cache: [String: NSImage] = [:]

    // Separate cache for alpha-composited variants, so `image(_:alpha:)` does not allocate
    // a new NSImage on every call — e.g. on each network-state update, when the menu-bar
    // icon is redrawn in its dimmed disconnected state.
    //
    // The source image is retained alongside the result. The key incorporates the source's
    // ObjectIdentifier, which is unique only among LIVE objects: had the cache held the
    // result alone, a released source image's address could be reused by a different
    // NSImage, and that unrelated image would then hit this cache and be drawn with the
    // previous symbol's pixels. Every caller today passes an image owned by `cache` above
    // and is already safe; retaining the source makes that a property of this type rather
    // than of its callers' habits.
    private var alphaCache: [String: (source: NSImage, result: NSImage)] = [:]

    private init() {}

    /// The private SF Symbols bundle, for glyphs with no public equivalent (Ethernet
    /// Status's `ethernet` menu-bar icon). Resolved once; nil on a system where the path
    /// has moved, in which case `isPrivate` lookups return nil and the caller falls back.
    private static let coreGlyphsBundle: Bundle? = Bundle(
        path: "/System/Library/PrivateFrameworks/SFSymbols.framework/Versions/A/Resources/CoreGlyphsPrivate.bundle")

    /// Obtain, or create and cache, a configured symbol image.
    ///
    /// `SymbolConfiguration(pointSize:weight:)` is only constructed when BOTH are supplied,
    /// since the initializer requires both; `scale` may be supplied alone or composed onto
    /// the point-size configuration.
    public func image(named name: String,
                      pointSize: CGFloat? = nil,
                      weight: NSFont.Weight? = nil,
                      scale: NSImage.SymbolScale? = nil,
                      isPrivate: Bool = false) -> NSImage? {
        image(SymbolSpec(name: name, pointSize: pointSize, weight: weight,
                         scale: scale, isPrivate: isPrivate))
    }

    public func image(_ spec: SymbolSpec) -> NSImage? {
        let key = spec.cacheKey
        if let cached = cache[key] { return cached }

        let base: NSImage?
        if spec.isPrivate {
            guard let bundle = Self.coreGlyphsBundle else { return nil }
            base = NSImage(symbolName: spec.name, bundle: bundle, variableValue: 0.0)
        } else {
            base = NSImage(systemSymbolName: spec.name, accessibilityDescription: nil)
        }
        guard var symbol = base else { return nil }

        var configuration: NSImage.SymbolConfiguration?
        if let pointSize = spec.pointSize, let weight = spec.weight {
            configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        }
        if let scale = spec.scale {
            let scaleConfiguration = NSImage.SymbolConfiguration(scale: scale)
            configuration = configuration?.applying(scaleConfiguration) ?? scaleConfiguration
        }
        if let configuration, let configured = symbol.withSymbolConfiguration(configuration) {
            symbol = configured
        }

        // Template images are tinted by AppKit to match the menu bar's appearance, which is
        // what makes a status icon follow light/dark mode and the menu's highlight state.
        symbol.isTemplate = true
        cache[key] = symbol
        return symbol
    }

    /// Applies alpha to an existing symbol. The composited result is cached by the source's
    /// pointer identity and the alpha value, so a repeatedly-rendered dimmed icon costs one
    /// allocation rather than one per redraw.
    public func image(_ symbol: NSImage?, alpha: CGFloat) -> NSImage? {
        guard let symbol else { return nil }
        guard alpha < 1.0 else { return symbol }

        // `ObjectIdentifier` directly, not its `hashValue`: the identifier wraps a pointer
        // and is unique per live object, whereas a derived hash could collide.
        let key = "\(ObjectIdentifier(symbol))|a:\(alpha)"
        if let cached = alphaCache[key] { return cached.result }

        var size = symbol.size
        if size.width <= 0 || size.height <= 0 { size = NSSize(width: 16, height: 16) }

        // `NSImage(size:flipped:drawingHandler:)` rather than `lockFocus()`/`unlockFocus()`,
        // which are deprecated and capture the drawing at a single backing scale factor.
        let output = NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            // For a template mask, white is the opaque region. Filling with white at the
            // requested alpha and then drawing the symbol with `.destinationIn` uses the
            // symbol's own alpha as a mask, yielding a faded tint rather than a faded fill.
            NSColor.white.withAlphaComponent(alpha).setFill()
            rect.fill()
            symbol.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1.0)
            return true
        }
        output.isTemplate = true
        alphaCache[key] = (source: symbol, result: output)
        return output
    }

    /// Builds and caches a set of symbols ahead of first use, so the first render of the
    /// menu bar and menu does no symbol construction. Call once at launch.
    public func prewarm(_ specs: [SymbolSpec]) {
        for spec in specs { _ = image(spec) }
    }

    /// Convenience for a run of symbols sharing one configuration.
    public func prewarm(names: [String],
                        pointSize: CGFloat? = nil,
                        weight: NSFont.Weight? = nil,
                        scale: NSImage.SymbolScale? = nil,
                        isPrivate: Bool = false) {
        prewarm(names.map {
            SymbolSpec(name: $0, pointSize: pointSize, weight: weight,
                       scale: scale, isPrivate: isPrivate)
        })
    }

    /// Drops every cached image. For an appearance change or a deliberate purge.
    public func clearCache() {
        cache.removeAll(keepingCapacity: true)
        alphaCache.removeAll(keepingCapacity: true)
    }
}

// MARK: - Menu Bar Icon

/// What the status item's button displays.
@MainActor
public struct MenuBarIcon {
    /// Nil renders `fallbackTitle` as text instead — the behavior Toggler and Process
    /// Elimination fall back to when a glyph cannot be resolved.
    public var symbol: SymbolSpec?
    /// A second symbol tried when `symbol` fails to resolve. Ethernet Status needs this:
    /// its primary glyph comes from the private CoreGlyphs bundle, which may not exist.
    public var fallbackSymbol: SymbolSpec?
    /// Text shown when no symbol resolves.
    public var fallbackTitle: String?
    /// Dims the glyph. Applied through `SymbolCache`'s alpha cache, so a repeatedly
    /// redrawn dimmed icon costs one allocation, not one per redraw.
    public var alpha: CGFloat
    /// Reads out to assistive technologies, and sets the button's tooltip when
    /// `toolTip` is nil.
    public var accessibilityDescription: String?
    public var toolTip: String?

    public init(symbol: SymbolSpec?,
                fallbackSymbol: SymbolSpec? = nil,
                fallbackTitle: String? = nil,
                alpha: CGFloat = 1.0,
                accessibilityDescription: String? = nil,
                toolTip: String? = nil) {
        self.symbol = symbol
        self.fallbackSymbol = fallbackSymbol
        self.fallbackTitle = fallbackTitle
        self.alpha = alpha
        self.accessibilityDescription = accessibilityDescription
        self.toolTip = toolTip
    }

    public static func symbol(_ spec: SymbolSpec,
                              fallbackSymbol: SymbolSpec? = nil,
                              fallbackTitle: String? = nil,
                              alpha: CGFloat = 1.0,
                              accessibilityDescription: String? = nil,
                              toolTip: String? = nil) -> MenuBarIcon {
        MenuBarIcon(symbol: spec, fallbackSymbol: fallbackSymbol,
                    fallbackTitle: fallbackTitle, alpha: alpha,
                    accessibilityDescription: accessibilityDescription, toolTip: toolTip)
    }
}

// MARK: - Menu Elements

/// One row of the menu. Every row kind the four applets used is here.
@MainActor
public enum MenuElement {
    /// A plain command row.
    case action(MenuActionSpec)
    /// A checkmark row bound to a preference.
    case toggle(MenuToggleSpec)
    /// A dimmed, non-interactive section label ("Upon Dock/Undock:").
    case header(String)
    /// A dimmed, non-interactive line of live state ("Server name: …").
    case info(MenuInfoSpec)
    /// A submenu whose contents are built lazily, the first time it is expanded.
    case submenu(MenuSubmenuSpec)
    /// A row rendered by a custom `NSView`, created once and reused across rebuilds.
    case custom(MenuCustomSpec)
    case separator
}

/// Where an inline glyph sits relative to the row's text.
public enum MenuGlyphPlacement: Sendable {
    /// Glyph, space, then the text — LAN Stream's "Actively streaming" shape.
    case leading
    /// Text, space, then the glyph — the trailing warning triangle Toggler and Process
    /// Elimination append to a row whose permission has been denied.
    case trailing
}

/// A command row. `symbolName` renders a glyph inline in the title; `leadingSymbolName`
/// sets the item's own image well instead, which is what LAN Stream's warning rows use.
@MainActor
public struct MenuActionSpec {
    public var id: String
    public var title: String
    public var key: String
    public var modifiers: NSEvent.ModifierFlags?
    public var symbolName: String?
    public var glyphPlacement: MenuGlyphPlacement
    public var glyphColor: NSColor?
    public var leadingSymbolName: String?
    public var isEnabled: Bool
    public var handler: () -> Void
}

/// A checkmark row bound to a preference.
///
/// `isOn` is re-read on every menu open, which is what makes an external change to the
/// preference show up without any explicit reconcile pass. `willChange` runs before the
/// write and can veto it by returning false — the shape Toggler and Process Elimination
/// use to demand a Bluetooth or Automation permission before letting a row turn on.
@MainActor
public struct MenuToggleSpec {
    public var id: String
    public var title: String
    public var key: String
    public var modifiers: NSEvent.ModifierFlags?
    public var symbolName: String?
    public var glyphPlacement: MenuGlyphPlacement
    public var isEnabled: Bool
    public var isOn: () -> Bool
    public var willChange: ((Bool) -> Bool)?
    public var setOn: (Bool) -> Void
}

/// A dimmed, non-interactive line. `symbolName` puts a glyph inline ahead of the text;
/// `indent` shifts it right, for a detail line beneath a heading.
///
/// The indent is a paragraph-style head indent rather than leading spaces, so it is exact
/// and survives truncation. This is what replaces the hand-built `NSView` detail rows in
/// Ethernet Status's Interfaces submenu — see `MenuCustomSpec` for why a custom view is
/// the wrong tool for content that varies per build.
@MainActor
public struct MenuInfoSpec {
    public var text: String
    public var symbolName: String?
    public var glyphPlacement: MenuGlyphPlacement
    public var color: NSColor?
    public var indent: CGFloat
    public var font: NSFont?
}

/// A submenu built lazily on expansion, per `NSMenuDelegate.menuNeedsUpdate`.
///
/// Building on expansion rather than on every open matters when the contents are
/// expensive: Ethernet Status's Interfaces submenu runs an `SCDynamicStore` pass and a
/// `getifaddrs` walk, which should not be paid by a user who opens the menu to click Quit.
@MainActor
public struct MenuSubmenuSpec {
    public var id: String
    public var title: String
    public var isEnabled: Bool
    public var elements: () -> [MenuElement]
}

/// A row rendered by a custom `NSView`.
///
/// `make` is called once per id for the controller's lifetime and the view is reused on
/// every rebuild; `update` runs on each menu open. This is what keeps a live status view
/// (Ethernet Status's `StatusSectionView`) a single long-lived object that is updated in
/// place, rather than something rebuilt from scratch whenever the menu opens.
///
/// USE A FIXED SET OF IDS. Because views are cached and never evicted, minting an id per
/// item of varying content — one per network interface, say — grows the cache without
/// bound as that content churns. For rows that vary per build, use `.groupHeading` and
/// `.detail`, which render the same heading-plus-indented-detail shape through attributed
/// titles and hold no state at all.
@MainActor
public struct MenuCustomSpec {
    public var id: String
    public var isEnabled: Bool
    public var make: () -> NSView
    public var update: ((NSView) -> Void)?
}

// MARK: - Element Convenience Constructors

public extension MenuElement {

    static func action(id: String, title: String, key: String = "",
                       modifiers: NSEvent.ModifierFlags? = nil,
                       symbolName: String? = nil,
                       glyphPlacement: MenuGlyphPlacement = .leading,
                       glyphColor: NSColor? = nil,
                       leadingSymbolName: String? = nil,
                       isEnabled: Bool = true,
                       handler: @escaping () -> Void) -> MenuElement {
        .action(MenuActionSpec(id: id, title: title, key: key, modifiers: modifiers,
                               symbolName: symbolName, glyphPlacement: glyphPlacement,
                               glyphColor: glyphColor,
                               leadingSymbolName: leadingSymbolName,
                               isEnabled: isEnabled, handler: handler))
    }

    static func toggle(id: String, title: String, key: String = "",
                       modifiers: NSEvent.ModifierFlags? = nil,
                       symbolName: String? = nil,
                       glyphPlacement: MenuGlyphPlacement = .trailing,
                       isEnabled: Bool = true,
                       isOn: @escaping () -> Bool,
                       willChange: ((Bool) -> Bool)? = nil,
                       setOn: @escaping (Bool) -> Void) -> MenuElement {
        .toggle(MenuToggleSpec(id: id, title: title, key: key, modifiers: modifiers,
                               symbolName: symbolName, glyphPlacement: glyphPlacement,
                               isEnabled: isEnabled,
                               isOn: isOn, willChange: willChange, setOn: setOn))
    }

    static func info(_ text: String, symbolName: String? = nil,
                     glyphPlacement: MenuGlyphPlacement = .leading,
                     color: NSColor? = nil, indent: CGFloat = 0,
                     font: NSFont? = nil) -> MenuElement {
        .info(MenuInfoSpec(text: text, symbolName: symbolName,
                           glyphPlacement: glyphPlacement, color: color,
                           indent: indent, font: font))
    }

    /// A prominent, non-interactive heading — the first line of a group in a submenu, with
    /// detail lines indented beneath it.
    static func groupHeading(_ text: String) -> MenuElement {
        .info(text, color: .labelColor,
              font: .systemFont(ofSize: 13, weight: .regular))
    }

    /// An indented detail line beneath a `groupHeading`.
    static func detail(_ text: String, indent: CGFloat = 24) -> MenuElement {
        .info(text, color: .tertiaryLabelColor, indent: indent,
              font: .systemFont(ofSize: 12))
    }

    static func submenu(id: String, title: String, isEnabled: Bool = true,
                        elements: @escaping () -> [MenuElement]) -> MenuElement {
        .submenu(MenuSubmenuSpec(id: id, title: title, isEnabled: isEnabled,
                                 elements: elements))
    }

    static func custom(id: String, isEnabled: Bool = false,
                       make: @escaping () -> NSView,
                       update: ((NSView) -> Void)? = nil) -> MenuElement {
        .custom(MenuCustomSpec(id: id, isEnabled: isEnabled, make: make, update: update))
    }

    /// The About row every applet ends with, above Quit.
    static func about(title: String, key: String = "?",
                      handler: @escaping () -> Void) -> MenuElement {
        .action(id: "about", title: title, key: key, handler: handler)
    }

    /// The Quit row. Targets `NSApp` directly rather than the controller, so ⌘Q works
    /// through AppKit's own termination path.
    static func quit(title: String, key: String = "q") -> MenuElement {
        .action(id: "quit", title: title, key: key) { NSApp.terminate(nil) }
    }
}

// MARK: - Controller Configuration

@MainActor
public struct MenuControllerConfiguration {
    /// Used in log lines and as the status item's default accessibility label.
    public var appName: String

    /// The current menu-bar icon. Re-evaluated whenever `refreshIcon()` is called and on
    /// every menu open, so it can read live state directly.
    public var icon: () -> MenuBarIcon

    /// The menu's contents. Re-evaluated on every `menuWillOpen`. Capture `self` weakly.
    public var elements: () -> [MenuElement]

    /// Observable properties to track. The controller re-reads them under
    /// `withObservationTracking` and calls `refreshIcon()` whenever any of them changes,
    /// re-arming itself each time. Leave nil for an applet whose icon is static.
    ///
    ///     observing: { [weak self] in
    ///         guard let self else { return }
    ///         _ = self.appState.isConnected
    ///         _ = self.appState.ipv4Address
    ///     }
    public var observing: (() -> Void)?

    /// Runs at the start of every `menuWillOpen`, before the elements closure. For the
    /// side effects the applets perform on open — re-enforcing a permission state,
    /// re-resolving a live value that may be stale.
    public var willOpen: (() -> Void)?

    /// Symbols to build ahead of first use, so the first render does no symbol
    /// construction. The icon's own symbols are prewarmed automatically.
    public var prewarmSymbols: [SymbolSpec]

    /// Raise the app to `.regular` while a window is open and drop back to `.accessory`
    /// when it closes, so a menu-bar-only app's window gets a Dock tile and a menu bar for
    /// as long as it is up. Toggler does this around its Settings window; drive it with
    /// `beginWindowSession()` / `endWindowSession()`.
    public var managesActivationPolicy: Bool

    public init(appName: String,
                icon: @escaping () -> MenuBarIcon,
                elements: @escaping () -> [MenuElement],
                observing: (() -> Void)? = nil,
                willOpen: (() -> Void)? = nil,
                prewarmSymbols: [SymbolSpec] = [],
                managesActivationPolicy: Bool = false) {
        self.appName = appName
        self.icon = icon
        self.elements = elements
        self.observing = observing
        self.willOpen = willOpen
        self.prewarmSymbols = prewarmSymbols
        self.managesActivationPolicy = managesActivationPolicy
    }
}

// MARK: - Menu Controller

@MainActor
public final class MenuController: NSObject, NSMenuDelegate, Loggable {
    public nonisolated static let logTag = "[MenuController]"

    private let configuration: MenuControllerConfiguration

    private var statusItem: NSStatusItem?
    private var menu: NSMenu?

    /// Custom views, kept alive across rebuilds and keyed by element id — see
    /// `MenuCustomSpec`.
    private var customViews: [String: NSView] = [:]

    /// Handlers for the items currently in the menu, keyed by the item's `representedObject`
    /// id. Rebuilt on every open alongside the items themselves.
    private var handlers: [String: () -> Void] = [:]

    /// Submenu builders for the currently-built menu, keyed by submenu id, so
    /// `menuNeedsUpdate` can populate a submenu lazily on expansion.
    private var submenuBuilders: [String: () -> [MenuElement]] = [:]

    /// Cache of attributed titles that carry an inline glyph. Building one allocates an
    /// `NSTextAttachment` and lays out a symbol; the same handful of titles is rebuilt on
    /// every menu open, so caching them makes an open essentially free.
    private let titleCache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 64
        return cache
    }()

    private var isTerminating = false
    private var openWindowCount = 0

    /// `applyIcon` runs on every observed change and every menu open, so a symbol this OS
    /// does not have would otherwise write a line to the log on each one.
    private var didWarnAboutMissingGlyph = false

    private var observationTask: Task<Void, Never>?

    public init(_ configuration: MenuControllerConfiguration) {
        self.configuration = configuration
        super.init()
    }

    // `isolated` runs deinit on the main actor (SE-0371, macOS 15.4+), so it can reach
    // `observationTask` directly — no `nonisolated(unsafe)` mirror is needed.
    isolated deinit {
        observationTask?.cancel()
    }

    // MARK: Installation

    /// Creates the status item and its menu. Call once, at launch.
    public func install() {
        guard statusItem == nil else { return }

        SymbolCache.shared.prewarm(configuration.prewarmSymbols)
        let icon = configuration.icon()
        SymbolCache.shared.prewarm([icon.symbol, icon.fallbackSymbol].compactMap { $0 })

        let menu = NSMenu()
        // AppKit's automatic enabling asks the responder chain to validate every item; with
        // targets wired explicitly here, that only produces spuriously grayed-out rows.
        menu.autoenablesItems = false
        menu.delegate = self
        self.menu = menu

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = menu
        statusItem = item

        applyIcon(icon)
        startObserving()
        log("\(configuration.appName) status item installed.")
    }

    /// The status item's button, for the rare case that needs it directly (positioning a
    /// popover, reading its window).
    public var statusButton: NSStatusBarButton? { statusItem?.button }

    /// Re-reads the icon closure and applies the result. Called automatically on menu open
    /// and whenever an observed property changes.
    public func refreshIcon() {
        applyIcon(configuration.icon())
    }

    /// Rebuilds the menu's contents now, rather than waiting for the next open. Rarely
    /// needed — the menu cannot be visible and stale at the same time — but available for
    /// a change that must be reflected in an already-open menu.
    public func refreshMenu() {
        guard let menu else { return }
        rebuild(menu)
    }

    // MARK: Icon

    private func applyIcon(_ icon: MenuBarIcon) {
        guard let button = statusItem?.button else { return }

        let resolved = icon.symbol.flatMap { SymbolCache.shared.image($0) }
            ?? icon.fallbackSymbol.flatMap { SymbolCache.shared.image($0) }

        if let resolved {
            button.image = SymbolCache.shared.image(resolved, alpha: icon.alpha)
            button.title = ""
        } else if let fallbackTitle = icon.fallbackTitle {
            // No glyph resolved — a private-bundle symbol on a system that moved it, or a
            // system symbol newer than this OS. Text beats an empty status item.
            button.image = nil
            button.title = fallbackTitle
        } else if !didWarnAboutMissingGlyph {
            didWarnAboutMissingGlyph = true
            log("No glyph available for the status item.", level: .warning)
        }

        // The description is set on the BUTTON, not on the image. `SymbolCache` vends one
        // shared NSImage per configuration — and returns that same instance outright when
        // alpha is 1.0 — so writing an accessibility description into the image would
        // stamp this status item's wording onto every other use of that glyph, including
        // glyphs rendered inside menu item titles.
        button.setAccessibilityLabel(icon.accessibilityDescription ?? configuration.appName)
        button.toolTip = icon.toolTip ?? icon.accessibilityDescription
    }

    // MARK: Observation

    /// Watches the properties read by `configuration.observing` and refreshes the icon when
    /// any of them changes.
    ///
    /// `withObservationTracking` fires its `onChange` exactly once, so it has to be
    /// re-armed after every change. It is driven from a task here — rather than by
    /// re-arming inside `onChange`, which is called while the property is mid-write — so
    /// the refresh reads settled values.
    private func startObserving() {
        guard configuration.observing != nil else { return }
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        self.configuration.observing?()
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard !Task.isCancelled else { return }
                self.refreshIcon()
            }
        }
    }

    // MARK: Building

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        handlers.removeAll(keepingCapacity: true)
        submenuBuilders.removeAll(keepingCapacity: true)

        for element in configuration.elements() {
            menu.addItem(makeItem(for: element))
        }
    }

    private func makeItem(for element: MenuElement) -> NSMenuItem {
        switch element {
        case .separator:
            return .separator()

        case .header(let title):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: NSFont.menuFont(ofSize: 0),
                             .foregroundColor: NSColor.secondaryLabelColor])
            return item

        case .info(let spec):
            let item = NSMenuItem(title: spec.text, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.attributedTitle = attributedTitle(
                spec.text, symbolName: spec.symbolName, placement: spec.glyphPlacement,
                color: spec.color ?? .secondaryLabelColor,
                indent: spec.indent, font: spec.font)
            // A menu item carrying only an attributed title is still read out by its
            // `title`, which the indent and glyph do not reach — so it stays the plain text.
            return item

        case .action(let spec):
            let item = NSMenuItem(title: spec.title,
                                  action: #selector(performItemAction(_:)),
                                  keyEquivalent: spec.key)
            item.target = self
            item.isEnabled = spec.isEnabled
            if let modifiers = spec.modifiers { item.keyEquivalentModifierMask = modifiers }
            if spec.symbolName != nil || spec.glyphColor != nil {
                item.attributedTitle = attributedTitle(spec.title,
                                                       symbolName: spec.symbolName,
                                                       placement: spec.glyphPlacement,
                                                       color: spec.glyphColor)
            }
            if let leading = spec.leadingSymbolName {
                item.image = SymbolCache.shared.image(.menuItem(leading))
            }
            bind(item, id: spec.id, handler: spec.handler)
            return item

        case .toggle(let spec):
            let item = NSMenuItem(title: spec.title,
                                  action: #selector(performItemAction(_:)),
                                  keyEquivalent: spec.key)
            item.target = self
            item.isEnabled = spec.isEnabled
            if let modifiers = spec.modifiers { item.keyEquivalentModifierMask = modifiers }
            if spec.symbolName != nil {
                item.attributedTitle = attributedTitle(spec.title,
                                                       symbolName: spec.symbolName,
                                                       placement: spec.glyphPlacement,
                                                       color: nil)
            }
            item.state = spec.isOn() ? .on : .off
            bind(item, id: spec.id) { [weak self, weak item] in
                let newValue = !spec.isOn()
                // `willChange` returning false vetoes the write — the permission-gate shape.
                // The item's state is left untouched, so the row visibly does not move.
                if let willChange = spec.willChange, !willChange(newValue) { return }
                spec.setOn(newValue)
                item?.state = newValue ? .on : .off
                self?.log("\(spec.title) -> \(newValue)")
            }
            return item

        case .submenu(let spec):
            let item = NSMenuItem(title: spec.title, action: nil, keyEquivalent: "")
            item.isEnabled = spec.isEnabled
            let submenu = NSMenu(title: spec.title)
            submenu.autoenablesItems = false
            submenu.delegate = self
            // The id is stamped on the submenu itself, so `menuNeedsUpdate` — which is
            // handed only the `NSMenu` — can find the matching builder.
            submenu.identifier = NSUserInterfaceItemIdentifier(spec.id)
            item.submenu = submenu
            submenuBuilders[spec.id] = spec.elements
            return item

        case .custom(let spec):
            let item = NSMenuItem()
            item.isEnabled = spec.isEnabled
            // Created once per id and reused, so a live view stays a single long-lived
            // object updated in place rather than rebuilt on every open.
            let view = customViews[spec.id] ?? {
                let made = spec.make()
                customViews[spec.id] = made
                return made
            }()
            spec.update?(view)
            item.view = view
            return item
        }
    }

    private func bind(_ item: NSMenuItem, id: String, handler: @escaping () -> Void) {
        item.representedObject = id
        handlers[id] = handler
    }

    @objc private func performItemAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let handler = handlers[id] else { return }
        handler()
    }

    // MARK: Attributed Titles

    /// A title with an optional SF Symbol rendered inline ahead of it, and an optional
    /// color applied to both.
    ///
    /// Cached by title + symbol + color: the attachment construction and symbol layout
    /// would otherwise be repeated on every menu open for a fixed handful of rows.
    private func attributedTitle(_ text: String, symbolName: String?,
                                 placement: MenuGlyphPlacement = .leading,
                                 color: NSColor?, indent: CGFloat = 0,
                                 font explicitFont: NSFont? = nil) -> NSAttributedString {
        let cacheKey = """
            \(text)|\(symbolName ?? "")|\(placement)|\(color?.description ?? "")|\(indent)|\
            \(explicitFont?.fontName ?? "")|\(explicitFont?.pointSize ?? 0)
            """ as NSString
        if let cached = titleCache.object(forKey: cacheKey) { return cached }

        let font = explicitFont ?? NSFont.menuFont(ofSize: 0)
        let line = NSMutableAttributedString()

        /// The glyph run, or nil when there is no symbol or it does not resolve on this OS.
        func glyphRun() -> NSAttributedString? {
            guard let symbolName,
                  let glyph = SymbolCache.shared.image(
                    SymbolSpec(name: symbolName, pointSize: font.pointSize, weight: .regular))
            else { return nil }
            let attachment = NSTextAttachment()
            attachment.image = glyph
            let size = glyph.size
            // Centered on the cap height rather than the baseline, so the glyph sits level
            // with the text instead of hanging below it.
            attachment.bounds = CGRect(x: 0, y: (font.capHeight - size.height) / 2,
                                       width: size.width, height: size.height)
            let run = NSMutableAttributedString(attachment: attachment)
            if let color {
                run.addAttribute(.foregroundColor, value: color,
                                 range: NSRange(location: 0, length: run.length))
            }
            return run
        }

        let glyph = glyphRun()
        if placement == .leading, let glyph {
            line.append(glyph)
            line.append(NSAttributedString(string: " "))
        }

        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if let color { attributes[.foregroundColor] = color }
        if indent > 0 {
            // A head indent rather than leading spaces: exact, and it applies to a wrapped
            // or truncated second line too.
            let paragraph = NSMutableParagraphStyle()
            paragraph.firstLineHeadIndent = indent
            paragraph.headIndent = indent
            paragraph.lineBreakMode = .byTruncatingTail
            attributes[.paragraphStyle] = paragraph
        }
        line.append(NSAttributedString(string: text, attributes: attributes))

        if placement == .trailing, let glyph {
            line.append(NSAttributedString(string: " "))
            line.append(glyph)
        }

        titleCache.setObject(line, forKey: cacheKey)
        return line
    }

    // MARK: NSMenuDelegate

    /// Populates the root menu, and each submenu the first time it is expanded.
    ///
    /// The root menu is built HERE rather than in `menuWillOpen(_:)`. AppKit calls
    /// `menuNeedsUpdate(_:)` as the designated population point and computes the menu's
    /// geometry from what the delegate leaves behind; `menuWillOpen(_:)` runs afterwards,
    /// which is fine for adjusting an already-populated menu — what Ethernet Status did —
    /// but is late to fill an empty one. LAN Stream, the only one of the four that already
    /// rebuilt wholesale, populated from `menuNeedsUpdate`, and that is the shape kept.
    ///
    /// `willOpen` therefore runs here too, immediately before the elements closure, so a
    /// side effect the app performs on open (re-enforcing a permission state, re-resolving
    /// a value that goes stale between opens) is reflected by the rows this build produces.
    ///
    /// For a submenu the `isEmpty` guard means one already built during this menu session
    /// is not rebuilt on re-expansion; the root rebuild discards it, so the next time the
    /// menu opens it starts fresh.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === self.menu {
            configuration.willOpen?()
            refreshIcon()
            rebuild(menu)
            return
        }
        guard menu.items.isEmpty,
              let id = menu.identifier?.rawValue,
              let builder = submenuBuilders[id] else { return }
        for element in builder() {
            menu.addItem(makeItem(for: element))
        }
    }

    // MARK: Activation Policy

    /// Call when opening a window from the menu. With `managesActivationPolicy` on, the
    /// first open raises the app to `.regular` so the window gets a Dock tile and menu bar.
    ///
    /// Returns false when the app is terminating, in which case the caller should not open
    /// the window: changing activation policy during termination leaves the process in a
    /// state AppKit does not expect to unwind from.
    @discardableResult
    public func beginWindowSession() -> Bool {
        guard !isTerminating else {
            log("Skipping window open: the application is terminating.")
            return false
        }
        guard configuration.managesActivationPolicy else { return true }
        openWindowCount += 1
        if openWindowCount == 1 {
            NSApp.setActivationPolicy(.regular)
            // One turn of the run loop, so the policy change takes effect before the window
            // is ordered front. Without it the window can appear behind the frontmost app.
            RunLoop.current.run(mode: .default, before: Date())
        }
        return true
    }

    /// Call when a window opened via `beginWindowSession()` closes. Drops back to
    /// `.accessory` once the last one is gone — but never during termination, where the
    /// policy is set once by the teardown path instead.
    public func endWindowSession() {
        guard configuration.managesActivationPolicy else { return }
        openWindowCount = max(0, openWindowCount - 1)
        if openWindowCount == 0, !isTerminating {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: Teardown

    /// Marks the app as terminating. After this, `beginWindowSession()` refuses, so a menu
    /// item clicked during the teardown window cannot open a window into a dying process.
    public func markTerminating() {
        isTerminating = true
    }

    /// Synchronous teardown for `applicationWillTerminate`. Removes the status item so the
    /// menu bar does not hold a stale slot while the process unwinds.
    public func prepareForTerminationSynchronously() {
        isTerminating = true

        observationTask?.cancel()
        observationTask = nil

        if configuration.managesActivationPolicy {
            NSApp.setActivationPolicy(.accessory)
        }

        menu?.removeAllItems()
        menu?.delegate = nil
        menu = nil
        handlers.removeAll()
        submenuBuilders.removeAll()
        customViews.removeAll()

        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
        log("\(configuration.appName) menu controller torn down.")
    }
}
