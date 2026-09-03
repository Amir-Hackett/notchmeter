import AppKit
import ApplicationServices

/// Where the menu bar is already spoken for at each end, for `CompactSide.auto`: how far right the frontmost
/// app's menu titles reach, and how far left the status items reach.
///
/// This is the only part of Notchmeter that touches the Accessibility API, and it reads exactly one thing: the
/// geometry (`kAXPositionAttribute`, `kAXSizeAttribute`) of an app's menu bar element (`kAXMenuBarAttribute`) or
/// its menu bar extras (`kAXExtrasMenuBarAttribute`) and of their immediate children. It never reads a title, a
/// value, a description, the contents of a menu, nor any element outside the menu bar, and it never writes an
/// attribute or performs an action anywhere. Nothing else in the app asks for Accessibility, and nothing asks for
/// it at launch: the prompt happens only when the user picks Auto.
enum MenuBarExtent {
    /// Whether Accessibility is granted. Never prompts, so it is safe to call at launch and while drawing.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// The one prompt there is, shown when the user picks Auto and only then.
    @discardableResult
    static func requestTrust() -> Bool {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    static func openSettings() { NSWorkspace.shared.open(settingsURL) }

    /// For `--smoke` and Settings: granted, or not (and so Auto is falling back).
    static var permissionState: String { isTrusted ? "accessibility granted" : "accessibility not granted" }

    /// The right-hand edge, in screen coordinates, of the menu titles the app with this pid draws; nil when
    /// Accessibility is not granted, or the app draws no menu bar of its own.
    static func menuEndX(pid: pid_t) -> CGFloat? {
        guard isTrusted else { return nil }
        let app = AXUIElementCreateApplication(pid)
        guard let bar = element(app, kAXMenuBarAttribute),
              let titles = elements(bar, kAXChildrenAttribute), !titles.isEmpty
        else { return nil }
        let ends = titles.compactMap { frame(of: $0)?.maxX }
        return ends.max()
    }

    /// The left-hand edge, in screen coordinates, of the leftmost menu bar extra — the status items that grow
    /// leftwards from the right — across every app that draws one; nil when Accessibility is not granted, or when
    /// no running app exposed an extras menu bar.
    ///
    /// Treat the answer as a floor rather than an exact edge. Status items belonging to processes that publish no
    /// frames (and the system's own, when it does not vend them) are invisible to this, so the real leftmost item
    /// can sit further left than what comes back; `CompactFit.clearance` is the margin that covers the difference.
    static func statusItemsStartX() -> CGFloat? {
        inventory().compactMap { $0.drawn ? $0.frame.minX : nil }.min()
    }

    /// One entry per menu bar extra any running app vends, with the judgement `statusItemsStartX` makes of it.
    /// `--menu-bar` prints this: Auto's whole behaviour rests on a number nobody can see, and when it is wrong the
    /// only way to find out which item spoiled it is to look at all of them.
    struct StatusItem {
        var app: String
        var frame: CGRect
        var drawn: Bool
    }

    static func inventory() -> [StatusItem] {
        guard isTrusted else { return [] }
        var found: [StatusItem] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy != .prohibited {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            guard let extras = self.element(element, kAXExtrasMenuBarAttribute),
                  let items = elements(extras, kAXChildrenAttribute)
            else { continue }
            let name = app.bundleIdentifier ?? app.localizedName ?? "pid:\(app.processIdentifier)"
            for frame in items.compactMap({ frame(of: $0) }) {
                found.append(StatusItem(app: name, frame: frame, drawn: isDrawn(frame)))
            }
        }
        return found.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Whether an extra is one the menu bar actually draws. An app may vend items it is not showing — a module
    /// switched off, one pushed into the overflow the notch creates — and macOS reports those at the screen's
    /// origin or with no size at all rather than omitting them. Left in, a single such item reads as a status
    /// item at x=0, which makes the whole right-hand gap look negative and pins the readouts to the left.
    private static func isDrawn(_ frame: CGRect) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return false }
        guard let primary = NSScreen.screens.first else { return false }
        return NSScreen.screens.contains { screen in
            // The Accessibility origin is the top-left of the primary screen, so this screen's menu bar begins at
            // its own distance below that top; horizontal coordinates need no conversion, and only they are used.
            let top = primary.frame.maxY - screen.frame.maxY
            let bar = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
            return frame.minY >= top - 1 && frame.minY <= top + bar
                && frame.minX > screen.frame.minX && frame.maxX <= screen.frame.maxX + 1
        }
    }

    /// `--menu-bar`: every extra, in the order they sit across the bar, and which of them Auto counts. Run it
    /// through `open` — a binary started straight from a shell inherits the terminal's Accessibility answer, not
    /// the app's, and reports "not granted" while the app itself is trusted.
    static func printInventory() {
        guard isTrusted else {
            print(permissionState + " — run this through `open -n -a Notchmeter --stdout <file> --args --menu-bar`")
            return
        }
        let items = inventory()
        for item in items {
            let box = String(format: "x %.0f–%.0f, y %.0f, %.0f × %.0f", item.frame.minX, item.frame.maxX,
                             item.frame.minY, item.frame.width, item.frame.height)
            print("\(item.drawn ? "drawn  " : "unplaced") \(box)  \(item.app)")
        }
        let counted = items.filter(\.drawn).count
        print("\(items.count) extra(s), \(counted) drawn; status items start at "
            + (statusItemsStartX().map { String(format: "%.0f", $0) } ?? "not measured"))
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(parent, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func elements(_ parent: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        copy(parent, attribute) as? [AXUIElement]
    }

    /// Position and size only. The y axis is the Accessibility API's flipped one, which does not matter: Auto
    /// asks about horizontal room alone.
    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = copy(element, kAXPositionAttribute), let sizeValue = copy(element, kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue((positionValue as! AXValue), .cgPoint, &origin),
              AXValueGetValue((sizeValue as! AXValue), .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }
}

/// What the strip needs from the screen it is drawn on, asked for at the moment a fit is resolved.
@MainActor
struct CompactMetrics {
    var notch: CGRect
    /// How many tools the strip would draw if nothing were dropped.
    var tools: Int
    /// The room a run of the first *n* tools takes at a style, padding included (CompactStripProbe).
    var width: (CompactStyle, Int) -> CGFloat
}

/// Keeps `Preferences.autoCompactFit` in step with the menu bar while Auto is chosen. It re-fits when an app comes
/// forward, when the style or the tool order changes, and when the screens change; the left edge is cached per
/// bundle id, so returning to an app already seen costs nothing, and the right edge is cached until an app
/// launches, quits or comes forward, since that is when status items appear and disappear. Nothing is measured
/// while a fixed side is chosen.
///
/// An activation is measured twice. `didActivateApplicationNotification` arrives before the incoming app's menu
/// titles have been laid out, so asking straight away can answer with the outgoing app's geometry, or with
/// nothing; measuring once and caching it under the incoming app's name leaves the strip narrowed for an app whose
/// menus are short, and nothing re-measures until some other app happens to activate — which is what "it does not
/// go back until I click something else" is. So the first reading is used but not kept, and a settle pass takes
/// readings until two agree and caches that one.
@MainActor
final class AutoSideWatcher {
    private let prefs: Preferences
    private let metrics: () -> CompactMetrics
    /// How the left edge is read; the tests hand it a script instead of a menu bar. The Accessibility check lives
    /// here rather than in the rules above it: `MenuBarExtent.menuEndX` already answers nil when it is not trusted.
    private let measure: (pid_t) -> CGFloat?
    /// Whose menus to measure; the tests name the app themselves rather than whatever is in front of the runner.
    private let frontmost: () -> NSRunningApplication?
    /// When the settle pass looks again; the tests shorten it.
    private let settleDelays: [Duration]
    /// Settled readings only: a first reading taken while the bar was still catching up is used once and dropped.
    private var menuCache: [String: CGFloat] = [:]
    private var statusItemsCache: CGFloat??
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var settling: Task<Void, Never>?

    /// When the settle pass looks again. Spaced out rather than repeated at one interval, so an app whose bar
    /// draws at once costs two reads and a slow one is still caught without polling.
    /// `nonisolated` so the initialiser below can name it as a default argument: a default argument is evaluated
    /// at the call site, which is not on the main actor, and reaching a main-actor property from there is an error
    /// in the Swift 6 language mode. The value is a constant of Sendable parts, so it needs no isolation.
    nonisolated static let settleDelays: [Duration] = [.milliseconds(120), .milliseconds(300), .milliseconds(700)]

    init(prefs: Preferences, metrics: @escaping () -> CompactMetrics,
         measure: @escaping (pid_t) -> CGFloat? = { MenuBarExtent.menuEndX(pid: $0) },
         frontmost: @escaping () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication },
         settleDelays: [Duration] = AutoSideWatcher.settleDelays) {
        self.prefs = prefs
        self.metrics = metrics
        self.measure = measure
        self.frontmost = frontmost
        self.settleDelays = settleDelays
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.statusItemsCache = nil
                    self?.refresh()
                    self?.settle()
                }
            }))
        }
        observers.append((.default, NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.statusItemsCache = nil
                self?.refresh()
            }
        }))
        observe()
    }

    deinit {
        for (center, observer) in observers { center.removeObserver(observer) }
    }

    /// Re-fits against the app already in front: called when the side preference changes, since no app has activated.
    func refresh() {
        update(for: frontmost())
    }

    /// Looks again while the menu bar finishes drawing, and keeps the answer that stops changing. Runs only for
    /// Auto, gives up the moment another app takes over, and replaces any pass still in flight.
    func settle() {
        settling?.cancel()
        guard prefs.compactSide == .auto, let app = frontmost(), let key = Self.key(for: app) else { return }
        settling = Task { [weak self] in
            guard let delays = self?.settleDelays else { return }
            var previous: CGFloat?
            for delay in delays {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                guard self.frontmost()?.processIdentifier == app.processIdentifier else { return }
                let measured = self.measure(app.processIdentifier)
                // Two readings the same means the bar has stopped moving; an app that never answers keeps no entry,
                // so the next activation measures it again rather than trusting a blank.
                if let measured, measured == previous {
                    if self.menuCache[key] != measured {
                        self.menuCache[key] = measured
                        self.refresh()
                    }
                    return
                }
                previous = measured
            }
            guard let self, let settled = previous, self.menuCache[key] != settled else { return }
            self.menuCache[key] = settled
            self.refresh()
        }
    }

    /// For the tests: the pass in flight, so they can await it instead of sleeping longer than it does.
    var settlePass: Task<Void, Never>? { settling }

    static func key(for app: NSRunningApplication) -> String? {
        app.bundleIdentifier ?? (app.processIdentifier > 0 ? "pid:\(app.processIdentifier)" : nil)
    }

    /// The user picking a side. Picking Auto is the one thing that asks for Accessibility, and it asks once per
    /// pick; picking a fixed side asks for nothing and measures nothing.
    func sideChosen(_ side: CompactSide) {
        prefs.compactSide = side
        guard side == .auto else { return }
        MenuBarExtent.requestTrust()
        refresh()
        settle()
    }

    /// Auto already chosen but not trusted — the grant was never given, or a rebuild replaced the binary it was
    /// given to. Ask again, once, on the launch that finds it that way: the standing choice is the user's own, so
    /// silently falling back to a fixed side forever is the wrong reading of "never prompt uninvited".
    func askAgainIfAutoIsStranded() {
        guard prefs.compactSide == .auto, !MenuBarExtent.isTrusted, !Self.askedThisLaunch else { return }
        Self.askedThisLaunch = true
        MenuBarExtent.requestTrust()
        refresh()
        settle()
    }

    private static var askedThisLaunch = false

    /// What Auto measured and what it made of it, for `--smoke`.
    var description: String {
        let fit = prefs.compactFit
        let drawn = "\(fit.side.rawValue) at \(fit.style.rawValue)" + (fit.dropped > 0 ? ", \(fit.dropped) tool(s) dropped" : ", every tool")
            + (fit.splitLeading.map { ", \($0) left of the notch" } ?? "")
        guard prefs.compactSide == .auto else { return "\(prefs.compactSide.rawValue) (fixed) → \(drawn); \(MenuBarExtent.permissionState)" }
        let geometry = metrics()
        let menus = menuEndX(for: NSWorkspace.shared.frontmostApplication)
        let statusItems = statusItemsStartX()
        let edge = { (value: CGFloat?) in value.map { String(format: "%.0f", $0) } ?? "not measured" }
        let room = { (value: CGFloat?) in value.map { String(format: "%.0f pt", $0) } ?? "unconstrained" }
        let leading = menus.map { geometry.notch.minX - CompactFit.clearance - $0 }
        let trailing = statusItems.map { $0 - CompactFit.clearance - geometry.notch.maxX }
        return "auto → \(drawn); menus end at \(edge(menus)), status items start at \(edge(statusItems)); "
            + "gap leading \(room(leading)), trailing \(room(trailing)); "
            + "measured \(menuCache.count) app(s); \(MenuBarExtent.permissionState)"
    }

    /// Re-fits when what the strip would draw changes under it: the style, which tools there are and in what order,
    /// and the side preference itself. The fit it writes is not tracked here, so answering cannot re-trigger this.
    private func observe() {
        withObservationTracking {
            _ = (prefs.compactStyle, prefs.toolOrder, prefs.enabledTools, prefs.compactSide)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observe()
                self?.refresh()
            }
        }
    }

    private func update(for app: NSRunningApplication?) {
        guard prefs.compactSide == .auto else { return }
        let geometry = metrics()
        let fit = CompactFit.resolve(notch: geometry.notch, menusEndX: menuEndX(for: app),
                                     statusItemsStartX: statusItemsStartX(), tools: geometry.tools,
                                     style: prefs.compactStyle, width: geometry.width)
        // Only on a change: the drawn fit is observed, and observing it is what asks for these measurements.
        if prefs.autoCompactFit != fit { prefs.autoCompactFit = fit }
    }

    /// The cached, settled reading when there is one; otherwise a fresh look, used for this fit but not kept —
    /// the bar may still be catching up, and `settle()` is what decides which reading is worth remembering.
    private func menuEndX(for app: NSRunningApplication?) -> CGFloat? {
        guard let app, let key = Self.key(for: app) else { return nil }
        if let cached = menuCache[key] { return cached }
        return measure(app.processIdentifier)
    }

    private func statusItemsStartX() -> CGFloat? {
        if let cached = statusItemsCache { return cached }
        let measured = MenuBarExtent.statusItemsStartX()
        statusItemsCache = .some(measured)
        return measured
    }
}
