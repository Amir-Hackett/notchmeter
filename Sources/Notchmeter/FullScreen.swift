import AppKit
import os

private let log = Logger(subsystem: "com.amirhackett.notchmeter", category: "fullscreen")

/// Whether another app is running full-screen on a given display, so the readouts can get out of the way.
///
/// A window that joins every space still draws over a full-screen app, whatever its collection behaviour, so
/// the panel has to be ordered out rather than merely reconfigured. Detection reads the on-screen window list:
/// bounds, owner and layer come back without Screen Recording permission (only window titles need it).
enum FullScreen {
    /// Another app's normal-layer window, by its on-screen size; the owner is for the diagnostics line.
    struct Candidate: Equatable {
        var owner: String
        var size: CGSize
    }

    /// The display's shape, read at the moment of the check.
    struct Display: Equatable {
        var size: CGSize
        /// The camera housing's band; zero on a display without one.
        var safeAreaTop: CGFloat
        /// The menu bar's height as visibleFrame reports it right now: its thickness on the desktop, zero in a
        /// full-screen Space and while an auto-hidden bar is away.
        var menuBarHeight: CGFloat

        init(size: CGSize, safeAreaTop: CGFloat, menuBarHeight: CGFloat) {
            self.size = size
            self.safeAreaTop = safeAreaTop
            self.menuBarHeight = menuBarHeight
        }

        @MainActor init(_ screen: NSScreen) {
            self.init(size: screen.frame.size, safeAreaTop: screen.safeAreaInsets.top, menuBarHeight: screen.menuBarHeightNow)
        }
    }

    /// Whether these windows amount to a full-screen app on the display.
    ///
    /// A full-screen window is one of two heights. The whole display: every full-screen window on a display
    /// without a camera housing, and on one with a housing any app that draws into its band (games, and anything
    /// that opts into `NSPrefersDisplaySafeAreaCompatibilityMode`). Or the display minus the band: on a notched
    /// display macOS lays a full-screen window out below the housing by default and blacks out the band beside
    /// it, which is what a full-screen video looks like on a MacBook. That second height is also exactly what a
    /// zoomed window gets under the menu bar, because on a notched display the bar fills the band, so it counts
    /// only while the bar is away, which it is in a full-screen Space and is not on the desktop. The width is
    /// the whole display, or the display shared between windows of one of those heights, which is Split View.
    static func isActive(_ candidates: [Candidate], on display: Display) -> Bool {
        let tall = candidates.filter { candidate in
            let height = candidate.size.height
            if abs(height - display.size.height) < 1 { return true }
            return display.safeAreaTop > 0 && display.menuBarHeight < 1 && abs(height - (display.size.height - display.safeAreaTop)) < 1
        }
        if tall.contains(where: { abs($0.size.width - display.size.width) < 1 }) { return true }
        // Split View: the divider between the two is the Window Server's, a few points wide.
        return tall.count >= 2 && tall.map(\.size.width).reduce(0, +) >= display.size.width - 16
    }

    /// The on-screen windows that could be a full-screen app's: another app's, on the normal layer.
    static func candidates(ownName: String = AppInfo.name) -> [Candidate] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return infos.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let owner = info[kCGWindowOwnerName as String] as? String, owner != ownName,
                  let raw = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: raw)
            else { return nil }
            return Candidate(owner: owner, size: bounds.size)
        }
    }

    @MainActor static func isActive(on screen: NSScreen, ownName: String = AppInfo.name) -> Bool {
        isActive(candidates(ownName: ownName), on: Display(screen))
    }

    /// One line for `--smoke` and the log: the display's shape, the verdict, and the windows that were weighed.
    @MainActor static func describe(on screen: NSScreen, ownName: String = AppInfo.name) -> String {
        let display = Display(screen)
        let found = candidates(ownName: ownName)
        let big = found.filter { $0.size.width >= display.size.width / 2 && $0.size.height >= display.size.height / 2 }
        let windows = big.prefix(6).map { "\($0.owner) \(Int($0.size.width))×\(Int($0.size.height))" }.joined(separator: ", ")
        return "active=\(isActive(found, on: display)) display=\(Int(display.size.width))×\(Int(display.size.height)) "
            + "safeAreaTop=\(Int(display.safeAreaTop)) menuBar=\(Int(display.menuBarHeight)) windows=[\(windows)]"
    }
}

/// Calls back when a display enters or leaves full screen. Entering full screen switches Space, so that
/// notification carries the change; an app activation covers the case of switching between full-screen apps.
@MainActor
final class FullScreenWatch {
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// Space notifications are the signal; this only runs while a full-screen app is up, so a missed one
    /// cannot strand the panel off screen.
    private var poll: Timer?
    private(set) var isActive = false
    private let screen: () -> NSScreen
    private let changed: (Bool) -> Void

    init(screen: @escaping () -> NSScreen, changed: @escaping (Bool) -> Void) {
        self.screen = screen
        self.changed = changed
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh(settling: true) }
            }))
        }
        refresh()
    }

    deinit {
        for (center, token) in observers { center.removeObserver(token) }
    }

    /// `settling` looks again shortly after: a Space change is reported while the window list and the menu bar
    /// are still moving, and a check made mid-transition would otherwise stand until the next app activation.
    func refresh(settling: Bool = false) {
        let active = FullScreen.isActive(on: screen())
        if active != isActive {
            isActive = active
            setPolling(active)
            log.info("full screen \(active ? "entered" : "left", privacy: .public): \(FullScreen.describe(on: self.screen()), privacy: .public)")
            changed(active)
        }
        guard settling else { return }
        for delay in [0.5, 2.0] {
            Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    private func setPolling(_ on: Bool) {
        poll?.invalidate()
        poll = nil
        guard on else { return }
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        setPolling(false)
    }
}
