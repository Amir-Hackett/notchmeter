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
        /// Whether the menu bar is on screen. Its own window, the Window Server's at the main-menu level along
        /// the top of this display, is in the on-screen window list on the desktop and leaves it in a
        /// full-screen Space until the pointer brings the bar back. `visibleFrame` cannot tell: in a full-screen
        /// Space it still reports the desktop's bar.
        var menuBarShowing: Bool
    }

    /// One reading of the window list: the windows weighed, the display they are weighed against, and the
    /// system's own windows along the top of the display, kept for the diagnostics line.
    struct Scan: Equatable {
        var candidates: [Candidate]
        var display: Display
        var chrome: [String]
    }

    /// Whether these windows amount to a full-screen app on the display.
    ///
    /// A full-screen window is one of two heights. The whole display: every full-screen window on a display
    /// without a camera housing, and on one with a housing any app that ignores the safe area and draws into its
    /// band, as games do. (An app that opts into `NSPrefersDisplaySafeAreaCompatibilityMode` gets the opposite:
    /// macOS shrinks the display to the area below the housing, the inset reads zero, and the whole-display test
    /// matches.) Or the display minus the band: on a notched display macOS lays a full-screen window out below
    /// the housing by default and blacks out the band beside it, which is what a full-screen video looks like on
    /// a MacBook. The band is the housing's inset or the menu bar's thickness, which are not quite the same number
    /// (32 and 33 points on a 14-inch), so a few points of slack cover both. That second height is also exactly
    /// what a zoomed window gets under the menu bar, because on a notched display the bar fills the band, so it
    /// counts only while the bar is away. In a full-screen Space the bar is away until the pointer touches the
    /// top edge; on the desktop it is present unless set to hide automatically, in which case a zoomed window
    /// with the Dock out of the way is indistinguishable from a full-screen one and the readouts step aside for
    /// it too, a known limit of reading window sizes. The width is the whole display, or the display shared
    /// between windows of one of those heights, which is Split View.
    static func isActive(_ candidates: [Candidate], on display: Display) -> Bool {
        isActive(candidates, on: display, barAway: !display.menuBarShowing)
    }

    /// Whether these windows would amount to a full-screen app if the menu bar were away: a full-screen app with
    /// its bar revealed by the pointer looks exactly like this, so while it holds the verdict is worth re-reading.
    static func isSuspect(_ candidates: [Candidate], on display: Display) -> Bool {
        isActive(candidates, on: display, barAway: true)
    }

    private static func isActive(_ candidates: [Candidate], on display: Display, barAway: Bool) -> Bool {
        let tall = candidates.filter { candidate in
            let height = candidate.size.height
            if abs(height - display.size.height) < 1 { return true }
            return display.safeAreaTop > 0 && barAway && height >= display.size.height - display.safeAreaTop - 4
        }
        if tall.contains(where: { abs($0.size.width - display.size.width) < 1 }) { return true }
        // Split View: the divider between the two is the Window Server's, a few points wide.
        return tall.count >= 2 && tall.map(\.size.width).reduce(0, +) >= display.size.width - 16
    }

    /// Reads the on-screen window list once for everything the rule needs. Bounds, owner and layer come back
    /// without Screen Recording permission; only window titles need it, and nothing here reads one.
    @MainActor static func scan(on screen: NSScreen, ownName: String = AppInfo.name) -> Scan {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        // Window bounds are in the Window Server's coordinates, the top left of the main display at the origin
        // with y downwards; the screen's frame has y upwards from the main display's bottom left. x agrees.
        let frame = screen.frame
        let mainHeight = NSScreen.screens.first?.frame.height ?? frame.maxY
        let top = mainHeight - frame.maxY
        var candidates: [Candidate] = []
        var chrome: [String] = []
        var menuBarShowing = false
        for info in infos {
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  let owner = info[kCGWindowOwnerName as String] as? String,
                  let raw = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: raw)
            else { continue }
            if layer == 0 {
                if owner != ownName { candidates.append(Candidate(owner: owner, size: bounds.size)) }
                continue
            }
            // The system's windows along this display's top edge: the menu bar's is the Window Server's at the
            // main-menu level, as wide as the display and at most a few dozen points tall.
            let onThisDisplay = bounds.minX >= frame.minX - 1 && bounds.maxX <= frame.maxX + 1 && bounds.minY >= top - 1
            guard onThisDisplay, bounds.minY < top + 60 else { continue }
            chrome.append("\(owner) L\(layer) \(Int(bounds.width))×\(Int(bounds.height)) y=\(Int(bounds.minY - top))")
            if layer == Int(CGWindowLevelForKey(.mainMenuWindow)), owner == "Window Server",
               abs(bounds.width - frame.width) < 1, bounds.height > 0, bounds.height < 60 {
                menuBarShowing = true
            }
        }
        let display = Display(size: frame.size, safeAreaTop: screen.safeAreaInsets.top, menuBarShowing: menuBarShowing)
        return Scan(candidates: candidates, display: display, chrome: chrome)
    }

    /// Whether another app is full-screen on the display right now.
    @MainActor static func isActive(on screen: NSScreen, ownName: String = AppInfo.name) -> Bool {
        let reading = scan(on: screen, ownName: ownName)
        return isActive(reading.candidates, on: reading.display)
    }

    /// One line for `--smoke` and the log: the display's shape, the verdict, and the windows that were weighed.
    @MainActor static func describe(on screen: NSScreen, ownName: String = AppInfo.name) -> String {
        describe(scan(on: screen, ownName: ownName))
    }

    /// The same line over a reading already taken, so a log line and the verdict it explains come from one scan.
    static func describe(_ reading: Scan) -> String {
        let display = reading.display
        let big = reading.candidates.filter { $0.size.width >= display.size.width / 2 && $0.size.height >= display.size.height / 2 }
        let windows = big.prefix(6).map { "\($0.owner) \(Int($0.size.width))×\(Int($0.size.height))" }.joined(separator: ", ")
        return "active=\(isActive(reading.candidates, on: display)) display=\(Int(display.size.width))×\(Int(display.size.height)) "
            + "safeAreaTop=\(Int(display.safeAreaTop)) menuBar=\(display.menuBarShowing ? "showing" : "away") "
            + "windows=[\(windows)] top=[\(reading.chrome.prefix(6).joined(separator: ", "))]"
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
    ///
    /// Polling runs while a full-screen app is up, and also while the windows say one may be up behind a revealed
    /// menu bar: the pointer at the top edge of a full-screen Space brings the bar in, the verdict flips to
    /// "left", and without the poll the readouts would stay over the app once the bar had gone again.
    func refresh(settling: Bool = false) {
        let reading = FullScreen.scan(on: screen())
        let active = FullScreen.isActive(reading.candidates, on: reading.display)
        setPolling(active || FullScreen.isSuspect(reading.candidates, on: reading.display))
        if active != isActive {
            isActive = active
            log.info("full screen \(active ? "entered" : "left", privacy: .public): \(FullScreen.describe(reading), privacy: .public)")
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
        guard on != (poll != nil) else { return }
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
