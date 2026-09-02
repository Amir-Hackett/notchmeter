import AppKit
import ApplicationServices

/// How far right the frontmost app's menu titles reach, for `CompactSide.auto`.
///
/// This is the only part of Notchmeter that touches the Accessibility API, and it reads exactly one thing: the
/// geometry (`kAXPositionAttribute`, `kAXSizeAttribute`) of the app's menu bar element and of its immediate
/// children. It never reads a title, a value, a description, the contents of a menu, nor any element outside the
/// menu bar, and it never writes an attribute or performs an action anywhere. Nothing else in the app asks for
/// Accessibility, and nothing asks for it at launch: the prompt happens only when the user picks Auto.
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

/// Keeps `Preferences.autoCompactSide` in step with the frontmost app while Auto is chosen. It measures when an
/// app comes forward and caches the answer per bundle id, so returning to an app already seen costs nothing;
/// there is no timer and nothing is measured while another side is chosen.
@MainActor
final class AutoSideWatcher {
    private let prefs: Preferences
    private let geometry: () -> (notch: CGRect, leadingWidth: CGFloat)
    private var cache: [String: CGFloat] = [:]
    private var observer: NSObjectProtocol?

    init(prefs: Preferences, geometry: @escaping () -> (notch: CGRect, leadingWidth: CGFloat)) {
        self.prefs = prefs
        self.geometry = geometry
        let center = NSWorkspace.shared.notificationCenter
        observer = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in self?.update(for: app) }
        }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    /// Re-reads the app already in front: called when the side preference changes, since no app has activated.
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

    /// What Auto has settled on and why, for `--smoke`.
    var description: String {
        let resolved = prefs.resolvedCompactSide.rawValue
        guard prefs.compactSide == .auto else { return "\(prefs.compactSide.rawValue) (fixed); \(MenuBarExtent.permissionState)" }
        let measured = prefs.autoCompactSide == nil ? "nothing measured yet" : "measured \(cache.count) app(s)"
        return "auto → \(resolved); fallback \(prefs.compactSideFallback.rawValue); \(measured); \(MenuBarExtent.permissionState)"
    }

    private func update(for app: NSRunningApplication?) {
        guard prefs.compactSide == .auto else { return }
        let geometry = geometry()
        let side = CompactSide.resolve(menuEndX: app.flatMap(menuEndX), leadingWidth: geometry.leadingWidth,
                                       notch: geometry.notch, fallback: prefs.compactSideFallback)
        // Only on a change: the drawn side is observed, and observing it is what asks for this measurement.
        if prefs.autoCompactSide != side { prefs.autoCompactSide = side }
    }

    private func menuEndX(for app: NSRunningApplication) -> CGFloat? {
        guard MenuBarExtent.isTrusted else { return nil }
        let key = app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
        if let cached = cache[key] { return cached }
        guard let measured = MenuBarExtent.menuEndX(pid: app.processIdentifier) else { return nil }
        cache[key] = measured
        return measured
    }
}
