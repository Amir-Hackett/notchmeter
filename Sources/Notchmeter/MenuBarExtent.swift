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
        guard isTrusted else { return nil }
        var leftmost: CGFloat?
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy != .prohibited {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            guard let extras = self.element(element, kAXExtrasMenuBarAttribute),
                  let items = elements(extras, kAXChildrenAttribute)
            else { continue }
            for minX in items.compactMap({ frame(of: $0)?.minX }) {
                leftmost = min(leftmost ?? minX, minX)
            }
        }
        return leftmost
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
/// launches, quits or comes forward, since that is when status items appear and disappear. There is no timer and
/// nothing is measured while a fixed side is chosen.
@MainActor
final class AutoSideWatcher {
    private let prefs: Preferences
    private let metrics: () -> CompactMetrics
    private var menuCache: [String: CGFloat] = [:]
    private var statusItemsCache: CGFloat??
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(prefs: Preferences, metrics: @escaping () -> CompactMetrics) {
        self.prefs = prefs
        self.metrics = metrics
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.statusItemsCache = nil
                    self?.refresh()
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
        update(for: NSWorkspace.shared.frontmostApplication)
    }

    /// The user picking a side. Picking Auto is the one thing that asks for Accessibility, and it asks once per
    /// pick; picking a fixed side asks for nothing and measures nothing.
    func sideChosen(_ side: CompactSide) {
        prefs.compactSide = side
        guard side == .auto else { return }
        MenuBarExtent.requestTrust()
        refresh()
    }

    /// Auto already chosen but not trusted — the grant was never given, or a rebuild replaced the binary it was
    /// given to. Ask again, once, on the launch that finds it that way: the standing choice is the user's own, so
    /// silently falling back to a fixed side forever is the wrong reading of "never prompt uninvited".
    func askAgainIfAutoIsStranded() {
        guard prefs.compactSide == .auto, !MenuBarExtent.isTrusted, !Self.askedThisLaunch else { return }
        Self.askedThisLaunch = true
        MenuBarExtent.requestTrust()
        refresh()
    }

    private static var askedThisLaunch = false

    /// What Auto measured and what it made of it, for `--smoke`.
    var description: String {
        let fit = prefs.compactFit
        let drawn = "\(fit.side.rawValue) at \(fit.style.rawValue)" + (fit.dropped > 0 ? ", \(fit.dropped) tool(s) dropped" : ", every tool")
        guard prefs.compactSide == .auto else { return "\(prefs.compactSide.rawValue) (fixed) → \(drawn); \(MenuBarExtent.permissionState)" }
        let geometry = metrics()
        let menus = menuEndX(for: NSWorkspace.shared.frontmostApplication)
        let statusItems = statusItemsStartX()
        let edge = { (value: CGFloat?) in value.map { String(format: "%.0f", $0) } ?? "not measured" }
        let room = { (value: CGFloat?) in value.map { String(format: "%.0f pt", $0) } ?? "unconstrained" }
        let leading = menus.map { geometry.notch.minX - CompactFit.clearance - $0 }
        let trailing = statusItems.map { $0 - CompactFit.clearance - geometry.notch.maxX }
        return "auto → \(drawn); menus end at \(edge(menus)), status items start at \(edge(statusItems)); "
            + "gap leading \(room(leading)), trailing \(room(trailing)); fallback \(prefs.compactSideFallback.rawValue); "
            + "measured \(menuCache.count) app(s); \(MenuBarExtent.permissionState)"
    }

    /// Re-fits when what the strip would draw changes under it: the style, which tools there are and in what order,
    /// and the side preference itself. The fit it writes is not tracked here, so answering cannot re-trigger this.
    private func observe() {
        withObservationTracking {
            _ = (prefs.compactStyle, prefs.toolOrder, prefs.enabledTools, prefs.compactSide, prefs.compactSideFallback)
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
                                     style: prefs.compactStyle, fallback: prefs.compactSideFallback,
                                     width: geometry.width)
        // Only on a change: the drawn fit is observed, and observing it is what asks for these measurements.
        if prefs.autoCompactFit != fit { prefs.autoCompactFit = fit }
    }

    private func menuEndX(for app: NSRunningApplication?) -> CGFloat? {
        guard MenuBarExtent.isTrusted, let app else { return nil }
        let key = app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
        if let cached = menuCache[key] { return cached }
        guard let measured = MenuBarExtent.menuEndX(pid: app.processIdentifier) else { return nil }
        menuCache[key] = measured
        return measured
    }

    private func statusItemsStartX() -> CGFloat? {
        if let cached = statusItemsCache { return cached }
        let measured = MenuBarExtent.statusItemsStartX()
        statusItemsCache = .some(measured)
        return measured
    }
}
