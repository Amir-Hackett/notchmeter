import AppKit
import SwiftUI

/// The layouts that are not the hardware notch: a notch of the same shape cut into the left or right edge of the
/// screen, with the full panel opening beside it on hover; a Codenotch-style bar on the bottom; and a pill under
/// the menu bar of a notchless screen in the top layout, which opens into the panel in its own place as the
/// sides did before this. The screen is resolved from its identity key at every layout, never kept as an
/// instance (Apple: screens can be reconfigured at any time).
@MainActor
final class EdgePanelController: NSObject, PanelPresenting {
    let edge: PanelEdge
    let screenKey: String
    let hover: HoverDriver
    private let store: UsageStore
    private let prefs: Preferences
    private let actions: NotchActions
    private let menu: OptionsMenu
    private let panel: EdgePanel
    private var fullScreenWatch: FullScreenWatch?
    private var suppressedForFullScreen = false
    private let host: NSHostingView<EdgePanelRoot>
    /// The two shapes are measured apart from each other and from the window, because the window is now their
    /// union rather than either of them: on a side edge the notch stays on screen while the panel opens beside
    /// it, and a measurement of the assembled root cannot say where each of them lands.
    private let notchProbe: NSHostingView<EdgeNotch>
    private let cardProbe: NSHostingView<EdgePanelCard>
    private let contentProbe: NSHostingView<NotchExpandedView>
    private var storedScreen: NSScreen
    private var expanded = false
    private var held = false
    private var reporter = PanelReporter()
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var transitionSerial = 0

    init(edge: PanelEdge, screen: NSScreen, store: UsageStore, prefs: Preferences, actions: NotchActions) {
        self.edge = edge
        self.screenKey = screen.identityKey
        self.storedScreen = screen
        self.store = store
        self.prefs = prefs
        self.actions = actions
        self.menu = OptionsMenu(prefs: prefs, actions: actions)
        panel = EdgePanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        host = NSHostingView(rootView: EdgePanelRoot(store: store, prefs: prefs, actions: actions, edge: edge, screen: screen,
                                                     arrangement: .empty))
        notchProbe = NSHostingView(rootView: EdgeNotch(store: store, edge: edge, flush: false))
        cardProbe = NSHostingView(rootView: EdgePanelCard(store: store, prefs: prefs, actions: actions, screen: screen))
        contentProbe = NSHostingView(rootView: NotchExpandedView(store: store, prefs: prefs, actions: actions, screen: screen))
        hover = HoverDriver(mode: prefs.visibility.hoverMode, dwell: prefs.hoverDelay)
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.contentView = host
        applyWindowBehaviour()

        hover.watch(panel)
        hover.perform = { [weak self] output, cause in self?.act(output, cause: cause) }
        hover.isPaused = { [weak self] in self.map { $0.menu.isOpen || $0.held } ?? false }
        hover.isOffScreen = { [weak self] in self.map { $0.panel.isVisible && !$0.panel.isOnActiveSpace } ?? false }
        hover.pointerEnteredCompact = { [weak self] in self?.store.wakeFromIdle() }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            let secondary = event.type == .rightMouseDown || event.modifierFlags.contains(.control)
            let handled = MainActor.assumeIsolated {
                guard secondary, let self, event.window === self.panel else { return false }
                self.menu.popUp(in: self.panel, event: event)
                return true
            }
            return handled ? nil : event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let escape = event.keyCode == 53
            let handled = MainActor.assumeIsolated {
                guard escape, let self, event.window === self.panel, self.expanded else { return false }
                self.hover.escape()
                return true
            }
            return handled ? nil : event
        }
        observers.append((.default, NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.layout(animated: false) }
        }))
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.layout(animated: false) }
        }))
        observeContent()
    }

    /// The current NSScreen behind the key; the instance it was built with only until the key resolves again.
    var screen: NSScreen {
        if let current = NSScreen.screen(withKey: screenKey) {
            storedScreen = current
            return current
        }
        return storedScreen
    }

    var isVisible: Bool { panel.isVisible }
    var window: NSWindow? { panel }
    var isExpanded: Bool { expanded }

    var scroll: PanelScrollReader {
        PanelScrollReader(window: panel, notch: edge == .top ? NotchController.notchRect(on: screen) : nil,
                          titleInset: NotchExpandedView.titleInset(density: prefs.density))
    }

    var expandedContentSize: CGSize { measuredContentSize(unclamped: false) }
    var expandedIntrinsicContentSize: CGSize { measuredContentSize(unclamped: true) }

    private func measuredContentSize(unclamped: Bool) -> CGSize {
        contentProbe.rootView = NotchExpandedView(store: store, prefs: prefs, actions: actions, screen: screen, unclamped: unclamped)
        contentProbe.layoutSubtreeIfNeeded()
        return contentProbe.fittingSize
    }

    /// The apps the readouts are currently making way for, or would be; empty when none is full-screen.
    var fullScreenApps: [String] { fullScreenWatch?.verdict.apps ?? [] }

    private func fullScreenChanged(_ verdict: FullScreen.Verdict) {
        if prefs.showOverFullScreenNow?.apps != verdict.apps { prefs.showOverFullScreenNow = nil }
        if apply(fullScreen: verdict) { show() }
    }

    /// Ordered out while another app is full-screen, unless the preference, an exception for that app or the
    /// shortcut says to stay. Returns whether the panel may now be shown again. See NotchController.
    @discardableResult private func apply(fullScreen verdict: FullScreen.Verdict) -> Bool {
        let hide = verdict.isActive && !prefs.showsOverFullScreen(verdict.apps)
        guard hide != suppressedForFullScreen else { return false }
        suppressedForFullScreen = hide
        guard hide else { return true }
        hover.stop()
        panel.orderOut(nil)
        return false
    }

    func show() {
        // See NotchController.show(): the answer for an app already full-screen can change without the window
        // list changing at all.
        if let watch = fullScreenWatch { apply(fullScreen: watch.verdict) }
        guard !suppressedForFullScreen else { return }
        if fullScreenWatch == nil {
            fullScreenWatch = FullScreenWatch(screen: { [weak self] in self?.screen ?? .panelScreen }) { [weak self] verdict in
                self?.fullScreenChanged(verdict)
            }
            if suppressedForFullScreen { return }
        }
        hover.mode = prefs.visibility.hoverMode
        hover.dwell = prefs.hoverDelay
        hover.gestures = prefs.gesturesEnabled && !AccessibilityDisplay.shared.motionReduced
        applyWindowBehaviour()
        let wasExpanded = expanded
        expanded = !held && (hover.mode == .always || expanded)
        layout(animated: panel.isVisible && wasExpanded != expanded)
        hover.adopt(expanded ? .expanded : .compact)
        reporter.report(expanded ? .expanded : .compact, cause: expanded ? .always : held ? .settings : .menu)
        hover.start()
        panel.orderFrontRegardless()
    }

    func holdCompact(_ held: Bool) {
        self.held = held
        show()
    }

    func remeasure() {
        layout(animated: false)
    }

    func applyWindowBehaviour() {
        // See NotchController: no window-list scan on a path the readings drive.
        panel.collectionBehavior = Self.collectionBehavior(showOverFullScreen: !suppressedForFullScreen)
    }

    func toggle(cause: PanelCause) {
        hover.toggle(cause: cause)
    }

    func expandNow(cause: PanelCause) {
        guard !expanded else { return }
        hover.toggle(cause: cause)
    }

    func glance() {
        hover.glance(for: AccessibilityDisplay.shared.motionReduced ? HoverIntent.glanceDuration + 2 : HoverIntent.glanceDuration)
    }

    func hide() async {
        hover.stop()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        transitionSerial += 1
        panel.orderOut(nil)
    }

    func showOptions() {
        menu.popUp(in: panel)
    }

    private func act(_ output: HoverIntent.Output, cause: PanelCause) {
        switch output {
        case .expand:
            expanded = true
            if !hover.isOffScreen() { store.refreshAll(force: false) }
        case .collapse:
            expanded = false
        case .none:
            return
        }
        reporter.report(expanded ? .expanded : .compact, cause: cause)
        transitionSerial += 1
        let serial = transitionSerial
        let duration = layout(animated: true)
        if expanded, PanelKeyPolicy.takesKeyboard(cause) {
            panel.makeKey()
        } else if !expanded, panel.isKeyWindow {
            panel.resignKey()
        }
        Task {
            try? await Task.sleep(for: .seconds(duration))
            guard serial == self.transitionSerial else { return }
            self.hover.transitionSettled()
        }
    }

    /// Measures the two shapes, works out where each of them goes, publishes the hover regions and then moves the
    /// one window that carries them; returns how long the move animates.
    ///
    /// The order is the reverse of what it was, and the reversal is the point. The window used to be sized to
    /// whatever the live view fitted into, and the regions read back off the window afterwards. It cannot be now
    /// that the frame is the union of a notch and a panel standing apart: neither shape is the frame, so the
    /// shapes are the arithmetic and the window and the view are both told the answer rather than each working
    /// one out and the two quietly disagreeing by a point.
    ///
    /// The compact region is always the closed arrangement's notch and the expanded region always the open one's
    /// panel, whichever state is on screen. That keeps both rectangles meaning what they always meant —
    /// `--smoke` reads the compact one per compact style and `--hover-sim` enters at its minX, both while the
    /// panel is shut — and it is why a screen with no room beside the notch still reports where the notch would be.
    @discardableResult
    private func layout(animated: Bool) -> TimeInterval {
        let (closed, open) = arrangements()
        let shown = expanded ? open : closed
        hover.regions = HoverRegions(compact: hoverable(closed.notch), expanded: open.panel)
        // The root is sized to the arrangement rather than to itself now, so while AppKit interpolates the
        // window's frame the content is a fixed-size island centred in a box that is both moving and growing: a
        // notch on a side edge would slide across the screen and clip on the way, which is the one thing this
        // layout promises it will not do. A transition into or out of `.beside` is therefore taken in one step,
        // while every transition where the window really is one shape morphing — the top, the bottom, and the
        // fallback on a screen with no room beside the notch — animates exactly as it always has.
        let stillsTheNotch = shown.kind == .beside || host.rootView.arrangement.kind == .beside
        let animate = animated && !AccessibilityDisplay.shared.motionReduced && !stillsTheNotch
        host.rootView = root(shown)
        host.layoutSubtreeIfNeeded()
        let duration = animate ? panel.animationResizeTime(shown.frame) : 0
        panel.setFrame(shown.frame, display: true, animate: animate)
        // The window is no longer opaque from corner to corner: with the panel open beside the notch, the gap
        // between them is clear, and AppKit keeps the shadow it derived from the previous alpha channel until it
        // is told otherwise. Without this the shadow stays a rectangle drawn round both shapes and the gap, and
        // the two read as one smeared object rather than as furniture standing apart.
        panel.invalidateShadow()
        return duration
    }

    /// Both arrangements from one pair of measurements: what the window holds shut, and what it would hold open.
    ///
    /// Whether the notch can be drawn at all is settled before either shape is measured, because the answer does
    /// not depend on a size — the flush face's distance from the glass is the same whatever the shape's extent —
    /// and because the two variants measure differently: the flush one has no padding on the side against the
    /// glass and thirty-two points more run for its fillets.
    ///
    /// Fitting sizes come back in fractional points, and a fractional width on a flush edge puts the straight
    /// face half a pixel off the display's own boundary, where antialiasing draws it as a soft grey seam rather
    /// than a hard edge. Rounded up, it lands on the pixel grid at 1x and 2x alike.
    private func arrangements() -> (closed: EdgeArrangement, open: EdgeArrangement) {
        let screen = self.screen
        let area = screen.visibleFrame
        let chrome = self.chrome(on: screen)
        let flush = Self.reachesTheGlass(edge: edge, area: area, chrome: chrome, bounds: screen.frame)
        notchProbe.rootView = EdgeNotch(store: store, edge: edge, flush: flush)
        notchProbe.layoutSubtreeIfNeeded()
        cardProbe.rootView = EdgePanelCard(store: store, prefs: prefs, actions: actions, screen: screen)
        cardProbe.layoutSubtreeIfNeeded()
        let notch = NSSize(width: notchProbe.fittingSize.width.rounded(.up), height: notchProbe.fittingSize.height.rounded(.up))
        let card = NSSize(width: cardProbe.fittingSize.width.rounded(.up), height: cardProbe.fittingSize.height.rounded(.up))
        return (Self.arrangement(notch: notch, panel: card, expanded: false, edge: edge, area: area, chrome: chrome, bounds: screen.frame),
                Self.arrangement(notch: notch, panel: card, expanded: true, edge: edge, area: area, chrome: chrome, bounds: screen.frame))
    }

    /// A shape flush with the glass, grown one point past it. `CGRect.contains` excludes its own maxX, so a notch
    /// on the right edge whose maxX is the screen's would keep a one-point column against the glass that the
    /// pointer can stand in and never be counted inside — the pointer thrown at the very edge, which is the whole
    /// invitation a flush shape makes, would be the one aim that failed. The pointer cannot leave the screen, so
    /// the extra point outside it costs nothing.
    private func hoverable(_ rect: NSRect) -> NSRect {
        guard !rect.isNull else { return rect }
        switch edge {
        case .left: return NSRect(x: rect.minX - 1, y: rect.minY, width: rect.width + 1, height: rect.height)
        case .right: return NSRect(x: rect.minX, y: rect.minY, width: rect.width + 1, height: rect.height)
        case .top, .bottom: return rect
        }
    }

    /// What the chrome that comes and goes looks like right now (an auto-hidden bar or Dock, Stage Manager's
    /// strip), read at each layout rather than kept — Apple: screens can be reconfigured at any time. Only the
    /// reading is left here; the placing moved into `arrangement`, which both rectangles now come out of together.
    private func chrome(on screen: NSScreen) -> Chrome {
        Chrome(dockHides: screen.dockHidesOnThisScreen && SystemChrome.dockAutoHides, dockOrientation: SystemChrome.dockOrientation,
               menuBarHides: SystemChrome.menuBarAutoHides && screen.menuBarHeightNow < 1, menuBarThickness: SystemChrome.menuBarThickness,
               stageManager: SystemChrome.stageManagerEnabled, stageManagerStripHides: SystemChrome.stageManagerStripAutoHides)
    }

    /// What the placement has to keep clear of beyond visibleFrame.
    struct Chrome: Equatable, Sendable {
        var dockHides = false
        var dockOrientation = "bottom"
        /// The menu bar auto-hides and is away right now, so visibleFrame reaches the screen's top.
        var menuBarHides = false
        var menuBarThickness: CGFloat = 24
        var stageManager = false
        var stageManagerStripHides = false
    }

    nonisolated static func placement(for size: NSSize, edge: PanelEdge, area: NSRect, dockHides: Bool) -> NSRect {
        placement(for: size, edge: edge, area: area, chrome: Chrome(dockHides: dockHides))
    }

    /// A hidden Dock's reveal strip is kept clear on the Dock's own side, a hidden menu bar's full height on the
    /// top, and Stage Manager's strip (shown, or its reveal zone when it hides) on the left.
    ///
    /// The left and right edges take no margin at all. A shape meant to read as a notch cut into the side of the
    /// screen has to touch what holds that side; six points of desktop showing outboard of it turns it back into
    /// a capsule floating near an edge, which is what it used to be. `area` is still visibleFrame and
    /// deliberately so: on the horizontal axis visibleFrame is inset from the screen's own frame by exactly one
    /// thing, a Dock pinned to the left or right (`NSScreen.dockHidesOnThisScreen` asserts that identity), so on
    /// a screen with nothing along that edge flush against `area` is flush against the glass. Where a Dock holds
    /// that side, `area` starts at the Dock's inner face and the shape would be flush with the Dock rather than
    /// with the screen, which is not a notch cut into anything; `reachesTheGlass` says so and the arrangement
    /// gives the six points back, so this function's zero margin is only ever spent on an edge the shape can
    /// actually touch.
    ///
    /// Standing off the glass and standing off a hundred and fifty two points of Stage Manager are different
    /// things, and `reachesTheGlass` is where that difference is decided; this function only places.
    ///
    /// The top and the bottom keep their six points. A bottom bar flush with the glass would sit on the strip
    /// that reveals a hidden Dock, and a top bar flush with it would sit under the menu bar.
    nonisolated static func placement(for size: NSSize, edge: PanelEdge, area: NSRect, chrome: Chrome) -> NSRect {
        let margin: CGFloat = edge == .left || edge == .right ? 0 : Self.margin
        var origin = NSPoint.zero
        switch edge {
        case .left:
            var x = area.minX + margin
            if chrome.dockHides, chrome.dockOrientation == "left" { x += SystemChrome.dockRevealStrip }
            if chrome.stageManager { x += chrome.stageManagerStripHides ? SystemChrome.dockRevealStrip : SystemChrome.stageManagerStripWidth }
            origin = NSPoint(x: x, y: area.midY - size.height / 2)
        case .right:
            var x = area.maxX - size.width - margin
            if chrome.dockHides, chrome.dockOrientation == "right" { x -= SystemChrome.dockRevealStrip }
            origin = NSPoint(x: x, y: area.midY - size.height / 2)
        case .bottom:
            origin = NSPoint(x: area.midX - size.width / 2, y: area.minY + margin + (chrome.dockHides && chrome.dockOrientation == "bottom" ? SystemChrome.dockRevealStrip : 0))
        case .top:
            let bar = chrome.menuBarHides ? chrome.menuBarThickness : 0
            origin = NSPoint(x: area.midX - size.width / 2, y: area.maxY - bar - size.height - margin)
        }
        origin.y = min(max(origin.y, area.minY), area.maxY - size.height)
        return NSRect(origin: origin, size: size)
    }

    private func root(_ arrangement: EdgeArrangement) -> EdgePanelRoot {
        EdgePanelRoot(store: store, prefs: prefs, actions: actions, edge: edge, screen: screen, arrangement: arrangement)
    }

    /// How far a top or bottom bar stands off its edge, and how far a side stands off when it has had to give the
    /// edge up. The sides take none while they are flush; see `placement`.
    nonisolated static let margin: CGFloat = 6

    /// The desktop left showing between the side notch and the panel opened beside it. Exactly
    /// `HoverIntent.expandedMargin`, and that is not a coincidence: the expanded region is widened by that margin
    /// and no more before the pointer is tested against it, so a gap of exactly it is a gap the pointer is never
    /// outside. A wider one would start the four-hundred-millisecond close under a pointer travelling from the
    /// readings to the detail they belong to.
    nonisolated static let besideGap: CGFloat = HoverIntent.expandedMargin

    /// The strip of desktop that has to survive to the panel's inward side for "beside" to mean beside. On a
    /// screen that cannot hold the notch, the gap, the panel and this, the arrangement is the screen and reads as
    /// a takeover rather than as furniture resting on an edge. A hundred and twenty points is a judgement rather
    /// than a measurement, and it is the one number here a designer should expect to move: with the sizes a real
    /// run measures it makes the fallback fire below 598 pt of usable width, which no Mac display reaches but a
    /// scaled resolution or a small external can.
    nonisolated static let besideClearance: CGFloat = 120

    /// How far a side's flush face may stand off the screen's own edge and still be drawn as a notch. A hidden
    /// Dock's reveal strip is exactly it, and four points is a bevel: the shape still reads as cut in. Stage
    /// Manager's hundred and fifty two, and a Dock pinned to that side, are not, and a notch shape flush with
    /// nothing is a rectangle with odd corners standing in the middle of the desktop.
    nonisolated static let flushTolerance: CGFloat = SystemChrome.dockRevealStrip

    /// How far this edge's flush face would stand off the screen's own boundary; infinite on the top and the
    /// bottom, which never draw the notch shape. Deliberately takes no size: for `.left` the flush face is
    /// `area.minX` plus whatever chrome insets it and for `.right` it is `area.maxX` less the same, and neither
    /// depends on how big the shape is — which is what lets the controller settle the question before it measures
    /// anything, and lets it measure the right one of two differently-padded shapes.
    ///
    /// The distance and not just the verdict, because two different decisions read it. Whether to draw the notch
    /// shape at all tolerates the four points of a hidden Dock's reveal strip; whether the shape's outboard rim
    /// falls off the display tolerates nothing at all, and a stroke drawn as though it did when it did not is a
    /// face at twice the weight of the other three (`PanelSurface`).
    nonisolated static func standOff(edge: PanelEdge, area: NSRect, chrome: Chrome, bounds: NSRect) -> CGFloat {
        let probe = placement(for: .zero, edge: edge, area: area, chrome: chrome)
        switch edge {
        case .left: return probe.minX - bounds.minX
        case .right: return bounds.maxX - probe.maxX
        case .top, .bottom: return .infinity
        }
    }

    /// Whether the shape on this edge is close enough to the screen's own boundary to be drawn as a notch cut
    /// into it rather than as the capsule that shipped.
    nonisolated static func reachesTheGlass(edge: PanelEdge, area: NSRect, chrome: Chrome, bounds: NSRect) -> Bool {
        standOff(edge: edge, area: area, chrome: chrome, bounds: bounds) <= flushTolerance
    }

    /// Where the notch and the open panel each go, and the one window frame that has to contain both.
    ///
    /// All three rectangles are in screen coordinates and all three are handed to the view as well as to the
    /// window. That is the point of the type: the shapes the pointer is tested against and the shapes that are
    /// drawn are one set of numbers rather than two workings that agree until a padding changes.
    struct EdgeArrangement: Equatable, Sendable {
        var frame: NSRect
        /// Null while the panel has taken the notch's place for want of room beside it.
        var notch: NSRect
        /// Null while the panel is closed.
        var panel: NSRect
        var kind: Kind
        /// The notch shape is drawn rather than the capsule: a side edge with nothing else on it.
        var flush: Bool
        /// The flush face lies on the display's own boundary with nothing between them, so half of a centred
        /// stroke on it would fall off the screen. False at the four points a hidden Dock's reveal strip leaves,
        /// which `flush` tolerates and this does not; see `PanelSurface`.
        var onTheBoundary = false

        /// What the host is built with before the first measurement; `observeContent`'s first layout replaces it
        /// before the window is ever ordered in.
        static let empty = EdgeArrangement(frame: .zero, notch: .zero, panel: .null, kind: .notchOnly, flush: false)

        /// What the window is holding: the notch alone, the notch with the panel beside it, or the panel standing
        /// where the notch was.
        enum Kind: String, Equatable, Sendable {
            case notchOnly, beside, instead
        }
    }

    /// Both shapes placed together, in one pure function so the rules can be read and tested without a screen.
    ///
    /// The panel opens beside the notch and the notch stays on screen, which is what a side layout is for: the
    /// reading that was glanced at is still there while the detail behind it is read.
    ///
    /// It falls back to opening in the notch's place only when there is genuinely no room for both, and the
    /// fallback is deliberately the layout as it shipped — a rounded card standing six points clear, not a flush
    /// one, because a panel cut into the glass on a screen too narrow to hold both is a shape with nothing left
    /// to be flush against.
    ///
    /// The top and the bottom pass through every branch below untouched: one shape, whichever state it is in,
    /// placed exactly where it has always been placed.
    nonisolated static func arrangement(notch notchSize: NSSize, panel panelSize: NSSize, expanded: Bool,
                                        edge: PanelEdge, area: NSRect, chrome: Chrome, bounds: NSRect) -> EdgeArrangement {
        let standingOff = standOff(edge: edge, area: area, chrome: chrome, bounds: bounds)
        let flush = standingOff <= flushTolerance
        let onTheBoundary = standingOff <= 0
        // A card never touches the glass, so it always takes the margin back that `placement` no longer adds on a
        // side; the notch takes it back only when it has given the edge up.
        let cardInset: CGFloat = edge == .left ? margin : edge == .right ? -margin : 0
        let notch = placement(for: notchSize, edge: edge, area: area, chrome: chrome).offsetBy(dx: flush ? 0 : cardInset, dy: 0)
        guard expanded else {
            return EdgeArrangement(frame: notch, notch: notch, panel: .null, kind: .notchOnly, flush: flush,
                                   onTheBoundary: onTheBoundary)
        }
        let card = placement(for: panelSize, edge: edge, area: area, chrome: chrome).offsetBy(dx: cardInset, dy: 0)
        if flush {
            let room = edge == .left ? area.maxX - notch.minX : notch.maxX - area.minX
            if notchSize.width + besideGap + panelSize.width + besideClearance <= room {
                let x = edge == .left ? notch.maxX + besideGap : notch.minX - besideGap - panelSize.width
                let beside = NSRect(x: x, y: card.minY, width: panelSize.width, height: panelSize.height)
                return EdgeArrangement(frame: notch.union(beside), notch: notch, panel: beside, kind: .beside, flush: true,
                                       onTheBoundary: onTheBoundary)
            }
        }
        return EdgeArrangement(frame: card, notch: .null, panel: card, kind: .instead, flush: flush,
                               onTheBoundary: onTheBoundary)
    }

    /// Re-fits the window whenever something that shapes the pill or the panel changes (the window is the visible
    /// shape here, so it must follow its content); the tracking is one-shot, so it re-arms itself.
    private func observeContent() {
        withObservationTracking {
            _ = (store.statuses, store.sessions, store.attendedAt, store.cost, store.statusline, store.screenCaptured, store.footerNote, prefs.enabledTools,
                 prefs.showSpend, prefs.signalRings, prefs.toolOrder,
                 prefs.compactStyle, prefs.usageDisplay, prefs.density, prefs.panelWidth, prefs.showResetCountdown, prefs.ringWindows, prefs.hiddenWindows,
                 prefs.revealedWindows, prefs.visibility, prefs.hoverDelay, prefs.gesturesEnabled, prefs.showOverFullScreenApps, prefs.costCardMode,
                 prefs.monthlyBudgetUSD)
            layout(animated: false)
            hover.dwell = prefs.hoverDelay
            hover.gestures = prefs.gesturesEnabled && !AccessibilityDisplay.shared.motionReduced
            applyWindowBehaviour()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeContent() }
        }
    }
}

/// Which opens give the panel the keyboard: a deliberate click, swipe, shortcut or notification; never a hover
/// or a glance, which must not take the keyboard from the user's app.
enum PanelKeyPolicy {
    static func takesKeyboard(_ cause: PanelCause) -> Bool {
        switch cause {
        case .click, .swipe, .hotkey, .notification: true
        default: false
        }
    }
}

final class EdgePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// What the one window draws: the notch, the panel, or the notch with the panel beside it.
///
/// Each shape is placed at the offset its own screen rectangle asks for rather than by a stack's alignment,
/// because the hover regions are those same rectangles and the pointer has to be tested against the shape it can
/// see. A stack that centred a 202 pt notch against an 855 pt panel two points differently from `arrangement`
/// would leave the pointer testing a rectangle the shape is not quite in, and the panel would close under a
/// pointer resting on the readings that opened it.
///
/// The offsets are measured from the centre and not from a corner: a `ZStack`'s leading alignment is flipped by
/// the layout direction and `.offset` is not, so a corner-anchored version would put the notch on the wrong side
/// of the window in a right-to-left locale while the window itself stayed where it was.
struct EdgePanelRoot: View {
    let store: UsageStore
    let prefs: Preferences
    let actions: NotchActions
    let edge: PanelEdge
    let screen: NSScreen
    let arrangement: EdgePanelController.EdgeArrangement

    var body: some View {
        ZStack {
            // The window is the union of two shapes standing apart, so most of it is desktop the pointer has to
            // reach. A hit-testable spacer here would take every click landing in the column beside the notch —
            // sixty thousand points of it, at screen-saver level, for as long as the panel is open — and the
            // pointer would find a rectangle of dead screen where the wallpaper is. Declining the hit is the same
            // rule that lets a click pass through the top layout's invisible column.
            Color.clear.allowsHitTesting(false)
            // The notch is drawn before the card so VoiceOver reaches the readings before the detail behind them,
            // which is the order they are read in. The card still holds the only scroll view in the window, so
            // `PanelScrollReader`'s depth-first search finds the same one either way.
            if !arrangement.notch.isNull {
                EdgeNotch(store: store, edge: edge, flush: arrangement.flush, onTheBoundary: arrangement.onTheBoundary)
                    .frame(width: arrangement.notch.width, height: arrangement.notch.height)
                    .offset(x: arrangement.notch.midX - arrangement.frame.midX,
                            y: arrangement.frame.midY - arrangement.notch.midY)
            }
            if !arrangement.panel.isNull {
                EdgePanelCard(store: store, prefs: prefs, actions: actions, screen: screen)
                    .frame(width: arrangement.panel.width, height: arrangement.panel.height)
                    .offset(x: arrangement.panel.midX - arrangement.frame.midX,
                            y: arrangement.frame.midY - arrangement.panel.midY)
            }
        }
        .frame(width: arrangement.frame.width, height: arrangement.frame.height)
        // The pill and the card are their own shapes on the desktop, so they can be light; the notch layout
        // cannot, and neither can the side notch, which forces dark inside its own shape.
        .environment(\.colorScheme, prefs.appearance.colorScheme ?? .dark)
    }
}

/// The open panel on an edge: the same content the notch layout shows, in the same rounded card it has always
/// been, four points of padding and all. It is a card and not a second notch even on a side edge, because it is
/// not against the glass — it floats inboard of the notch, which stays on screen beside it. Its own type only so
/// the controller can measure it apart from the notch, which it cannot do while both are buried in one root.
struct EdgePanelCard: View {
    let store: UsageStore
    let prefs: Preferences
    let actions: NotchActions
    let screen: NSScreen

    var body: some View {
        NotchExpandedView(store: store, prefs: prefs, actions: actions, screen: screen)
            .padding(.vertical, 6)
            .modifier(PanelSurface(shape: RoundedRectangle(cornerRadius: 22, style: .continuous)))
            .padding(4)
            .fixedSize()
    }
}

/// The pill and panel background. The floating shapes — the edge pill and the card the panel opens in — are
/// Liquid Glass from macOS 26 and solid black before it and under Reduce Transparency. The flush side notch is
/// opaque black on every OS, and so is the notch layout's own panel, which is drawn on an opaque black backdrop
/// and leaves `expandedGlass` off (`NotchController.applyWindowBehaviour`) because glass over black renders pale
/// grey and the panel stops reading as one shape with the hardware notch.
///
/// The side notch keeps the black for the sister reason: the shape is claiming to be screen this Mac does not
/// have, and a hole in the screen you can see the wallpaper through is not a hole. Glass there sampled what was
/// behind the window and the desktop read straight through the shape, which left a translucent rounded slab
/// standing on the edge rather than an edge coming inward — the one thing this layout exists to draw. Giving it
/// the glass back is the single condition `!flush` on the line below; that is a judgement `docs/roadmap.md`
/// reserves for a person sitting at a macOS 26 screen, and it stays reserved for the pill and the card.
///
/// A shape whose flush face lies *on* the display's boundary draws its hairline at double width and clipped to
/// itself. The outboard half of a centred stroke on that face falls outside the display, which leaves a quarter
/// of a point of rim where every other face has a half; doubled and clipped, the whole line lands inside the
/// shape and the rim is even all the way round. It is deliberately not keyed to `flush`, which tolerates the four
/// points a hidden Dock's reveal strip leaves: at that stand-off the whole stroke is on screen already, and
/// doubling it there gives that one face twice the weight of the other three.
struct PanelSurface<S: Shape>: ViewModifier {
    let shape: S
    /// True for the notch shape cut into a side edge: never glass, whatever the OS.
    var flush = false
    /// True when the flush face has nothing at all between it and the display's boundary, so half its rim would
    /// fall off the screen. `EdgePanelController.arrangement` decides it and hands it down on
    /// `EdgeArrangement.onTheBoundary`, and that is the only place it is written: a second helper stating the same
    /// rule sat beside `reachesTheGlass` with no caller, so nothing exercised it and nothing would have caught it
    /// drifting from the line the shape is actually drawn by — the two workings `EdgeArrangement`'s own doc warns about.
    var onTheBoundary = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !flush, !AccessibilityDisplay.shared.reduceTransparency {
            content.glassEffect(.regular, in: shape)
        } else {
            let line = shape.stroke(.white.opacity(AccessibilityDisplay.shared.contrast ? 0.35 : 0.12),
                                    lineWidth: onTheBoundary ? 1 : 0.5)
            content
                .background(shape.fill(.black))
                .overlay(onTheBoundary ? AnyView(line.clipShape(shape)) : AnyView(line))
        }
    }
}
