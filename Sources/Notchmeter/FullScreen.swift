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

    /// The display's shape and the system's own furniture on it, read at the moment of the check.
    struct Display: Equatable {
        var size: CGSize
        /// The camera housing's band; zero on a display without one.
        var safeAreaTop: CGFloat
        /// Whether the Dock has a window on screen. It has one on a desktop whether or not the Dock is set to
        /// hide, and none in a full-screen Space, which is what separates a full-screen window from a zoomed
        /// one when the app is the only one open.
        var dockOnScreen: Bool
        /// Whether the menu bar's own window is on screen. It is on screen in a full-screen Space too, which is
        /// why the rule cannot read the bar; the diagnostics line still carries it.
        var menuBarShowing: Bool
    }

    /// One reading of the window list: the windows weighed, the display they are weighed against, and the
    /// system's own windows along the top of the display, kept for the diagnostics line.
    struct Scan: Equatable {
        var candidates: [Candidate]
        var display: Display
        var chrome: [String]
    }

    /// Who is full-screen on the display, if anyone.
    struct Verdict: Equatable {
        /// The apps whose windows cover the display, in name order; empty where no app does. Named rather than
        /// merely counted because the readouts may be told to stay over some of them.
        var apps: [String] = []
        var isActive: Bool { !apps.isEmpty }
    }

    /// Whether these windows amount to a full-screen app on the display, and which app it is.
    ///
    /// Three things have to hold, and they were each read off a 14-inch running a full-screen video.
    ///
    /// A window has to cover the display. Either the whole of it, which is every full-screen window on a display
    /// without a camera housing and any app on one that ignores the safe area and draws into the housing's band,
    /// as games do. Or the display less that band, because macOS lays a full-screen window out below the housing
    /// by default and blacks out the band beside it, which is what a full-screen video looks like on a MacBook.
    /// The band is the housing's inset or the menu bar's thickness, and those are not the same number (32 and 33
    /// points on a 14-inch), so a few points of slack cover both. Two windows sharing the width at one of those
    /// heights are Split View and count together.
    ///
    /// Every app with a window on screen has to be part of that. A Space holds its own windows and nothing else,
    /// so in a full-screen one the only windows are the full-screen app's, or the two apps sharing Split View. A
    /// desktop keeps every unminimised window on screen even when one covers the rest, so a zoomed window has
    /// company: eight apps, on the Mac this was read from.
    ///
    /// And the Dock must have no window on screen. That is what tells a full-screen window from a zoomed one on
    /// a desktop where the covering app happens to be the only one open. The menu bar cannot do this job: its
    /// window stays on screen inside a full-screen Space, which is why an earlier version of this rule left the
    /// readouts over the video it was written to get out of the way of.
    static func verdict(_ candidates: [Candidate], on display: Display) -> Verdict {
        let owners = covering(candidates, on: display)
        guard !display.dockOnScreen, !owners.isEmpty, Set(candidates.map(\.owner)).isSubset(of: owners)
        else { return Verdict() }
        return Verdict(apps: owners.sorted())
    }

    static func isActive(_ candidates: [Candidate], on display: Display) -> Bool {
        verdict(candidates, on: display).isActive
    }

    /// Whether a window covers the display at all, whatever else is on screen: while that holds the verdict is
    /// worth re-reading, because entering or leaving a Space moves the rest of this one window at a time.
    static func isSuspect(_ candidates: [Candidate], on display: Display) -> Bool {
        !covering(candidates, on: display).isEmpty
    }

    /// The apps whose windows cover the display; empty where none does. A covering window always has an owner,
    /// so the empty set says the same thing an optional would.
    private static func covering(_ candidates: [Candidate], on display: Display) -> Set<String> {
        let tall = candidates.filter { candidate in
            let height = candidate.size.height
            if abs(height - display.size.height) < 1 { return true }
            return display.safeAreaTop > 0 && height >= display.size.height - display.safeAreaTop - 4
        }
        if let whole = tall.first(where: { abs($0.size.width - display.size.width) < 1 }) { return [whole.owner] }
        // Split View: the divider between the two is the Window Server's, a few points wide. Sizes alone cannot
        // say the two are side by side rather than stacked, which the Dock and the company tests in `verdict`
        // are what actually rule out.
        guard tall.count >= 2, tall.map(\.size.width).reduce(0, +) >= display.size.width - 16 else { return [] }
        return Set(tall.map(\.owner))
    }

    /// Reads the on-screen window list once for everything the rule needs. Bounds, owner and layer come back
    /// without Screen Recording permission; only window titles need it, and nothing here reads one.
    @MainActor static func scan(on screen: NSScreen, ownName: String = AppInfo.name) -> Scan {
        // Desktop elements are kept rather than excluded, and only so the diagnostics line carries them. They
        // sit below the normal layer, so they can never become a candidate and the rule cannot see them. What
        // they are worth is evidence: the wallpaper's window is on a desktop and not in a full-screen Space,
        // which is the same thing the Dock's window says but per display rather than per Mac. If a reading from
        // a second display ever shows the Dock test getting it wrong, this is the field that says what to use
        // instead, and it costs nothing to carry until then.
        let options: CGWindowListOption = [.optionOnScreenOnly]
        let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        // Window bounds are in the Window Server's coordinates, the top left of the main display at the origin
        // with y downwards; the screen's frame has y upwards from the main display's bottom left. x agrees.
        let frame = screen.frame
        let mainHeight = NSScreen.screens.first?.frame.height ?? frame.maxY
        let top = mainHeight - frame.maxY
        var candidates: [Candidate] = []
        var chrome: [String] = []
        var menuBarShowing = false
        var dockOnScreen = false
        for info in infos {
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  let owner = info[kCGWindowOwnerName as String] as? String,
                  let raw = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: raw)
            else { continue }
            // Both axes: displays stack vertically as readily as side by side, and a window belonging to
            // another display must not count here. The verdict asks whether every app on screen is part of
            // what covers this display, so one window from the next display over would answer no for ever.
            let onThisDisplay = bounds.midX >= frame.minX && bounds.midX <= frame.maxX
                && bounds.midY >= top && bounds.midY <= top + frame.height
            if layer == 0 {
                if owner != ownName, onThisDisplay { candidates.append(Candidate(owner: owner, size: bounds.size)) }
                continue
            }
            if owner == "Dock", layer == Int(CGWindowLevelForKey(.dockWindow)), onThisDisplay { dockOnScreen = true }
            // The system's windows along this display's top edge, the menu bar's among them.
            guard onThisDisplay, bounds.minY >= top - 1, bounds.minY < top + 60 else { continue }
            chrome.append("\(owner) L\(layer) \(Int(bounds.width))×\(Int(bounds.height)) y=\(Int(bounds.minY - top))")
            if layer == Int(CGWindowLevelForKey(.mainMenuWindow)), owner == "Window Server",
               abs(bounds.width - frame.width) < 1, bounds.height > 0, bounds.height < 60 {
                menuBarShowing = true
            }
        }
        let display = Display(size: frame.size, safeAreaTop: screen.safeAreaInsets.top,
                              dockOnScreen: dockOnScreen, menuBarShowing: menuBarShowing)
        return Scan(candidates: candidates, display: display, chrome: chrome)
    }

    /// Whether another app is full-screen on the display right now, and which.
    @MainActor static func verdict(on screen: NSScreen, ownName: String = AppInfo.name) -> Verdict {
        let reading = scan(on: screen, ownName: ownName)
        return verdict(reading.candidates, on: reading.display)
    }

    /// One line for `--smoke` and the log: the display's shape, the verdict, and the windows that were weighed.
    @MainActor static func describe(on screen: NSScreen, ownName: String = AppInfo.name) -> String {
        describe(scan(on: screen, ownName: ownName))
    }

    /// The same line over a reading already taken, so a log line and the verdict it explains come from one scan.
    ///
    /// `apps` is every application with a window on screen, which is what separates a full-screen Space from a
    /// desktop; `dock` is the other half of that, and `menuBar` is there to show it saying nothing useful.
    static func describe(_ reading: Scan) -> String {
        let display = reading.display
        let big = reading.candidates.filter { $0.size.width >= display.size.width / 2 && $0.size.height >= display.size.height / 2 }
        let windows = big.prefix(8).map { "\($0.owner) \(Int($0.size.width))×\(Int($0.size.height))" }.joined(separator: ", ")
        var counts: [(String, Int)] = []
        for candidate in reading.candidates {
            if let at = counts.firstIndex(where: { $0.0 == candidate.owner }) { counts[at].1 += 1 } else { counts.append((candidate.owner, 1)) }
        }
        let apps = counts.prefix(12).map { "\($0.0)×\($0.1)" }.joined(separator: ", ")
        let now = verdict(reading.candidates, on: display)
        return "active=\(now.isActive)\(now.isActive ? " over=\(now.apps.joined(separator: "+"))" : "") display=\(Int(display.size.width))×\(Int(display.size.height)) "
            + "safeAreaTop=\(Int(display.safeAreaTop)) dock=\(display.dockOnScreen ? "on screen" : "away") "
            + "menuBar=\(display.menuBarShowing ? "showing" : "away") "
            + "suspect=\(isSuspect(reading.candidates, on: display)) apps=\(counts.count)[\(apps)] "
            + "windows=[\(windows)] top=[\(reading.chrome.joined(separator: ", "))]"
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
    /// The looks-again after a Space change. Held so a burst of activations replaces them rather than queueing
    /// a scan of the whole window list for each one.
    private var settle: [Timer] = []
    private(set) var verdict = FullScreen.Verdict()
    var isActive: Bool { verdict.isActive }
    private let screen: () -> NSScreen
    private let changed: (FullScreen.Verdict) -> Void

    init(screen: @escaping () -> NSScreen, changed: @escaping (FullScreen.Verdict) -> Void) {
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
        let now = FullScreen.verdict(reading.candidates, on: reading.display)
        setPolling(now.isActive || FullScreen.isSuspect(reading.candidates, on: reading.display))
        // Every reading, not only the ones that change the verdict: `log stream --level debug` beside a
        // full-screen app is how a wrong answer on a particular Mac is read off, and the terminal keeps
        // streaming while the Space it is asking about is the one on screen.
        log.debug("full screen reading: \(FullScreen.describe(reading), privacy: .public)")
        if now != verdict {
            let entered = now.isActive
            verdict = now
            log.info("full screen \(entered ? "entered" : "left", privacy: .public): \(FullScreen.describe(reading), privacy: .public)")
            changed(now)
        }
        guard settling else { return }
        for timer in settle { timer.invalidate() }
        settle = [0.5, 2.0].map { delay in
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
        for timer in settle { timer.invalidate() }
        settle = []
        setPolling(false)
    }
}
