import AppKit

/// Why the panel changed state, for the oracle (Oracle.swift): the pointer rested on the rings or left the panel,
/// a click outside or on the rings, a swipe, the global shortcut, Escape, a Spaces switch, the screen lock, the
/// Always open preference, the Settings window holding it closed, the Options menu switching to Open on hover,
/// a notification's Open button, or the state it launched in.
enum PanelCause: String {
    case dwell, exit, clickOutside, click, swipe, hotkey, escape, space, lock, always, settings, dashboard, menu, notification, launch, glance, fullScreen
}

/// What a mouse monitor saw, reduced to what the machine needs.
struct PointerEvent: Equatable {
    /// A scroll: the vertical travel the swipe reads, and the whole of it for a readout's retarget (RingScroll).
    struct Scroll: Equatable {
        var deltaY: CGFloat
        var fingersDown: Bool
        var phase: NSEvent.Phase
        var ring: RingScroll.Input
    }

    enum Kind: Equatable { case moved, click, controlClick, scroll(Scroll) }
    let kind: Kind
}

/// Feeds a HoverIntent from the real pointer and hands its decisions to a panel controller. Pointer facts come
/// from global and local mouse monitors (mouse events need no Accessibility permission), one re-sample at the
/// machine's next deadline so a pointer that stops moving still counts as dwelling, and a 250 ms tick that runs
/// only while the panel is open. A Spaces switch or the screen lock collapses through the same machine. Two-finger
/// swipes arrive as scroll events; a control-click is a secondary click and never counts as a click.
@MainActor
final class HoverDriver {
    /// The visible shapes, set by the controller from its own geometry; never a window frame.
    var regions = HoverRegions.none {
        didSet {
            guard regions != oldValue else { return }
            Oracle.shared.emit("regions", ["compact": regions.compact, "expanded": regions.expanded])
        }
    }
    var perform: (HoverIntent.Output, PanelCause) -> Void = { _, _ in }
    /// True while a menu owns the pointer; samples are skipped so an open Options menu cannot close the panel.
    var isPaused: () -> Bool = { false }
    /// True while a request holds the open panel open (PanelHolds.prompt): a click outside is then ignored, so a
    /// click into the terminal, or on anything else, cannot take the card down from under its reader. Escape and
    /// the buttons on the card are the ways out; a lock or a Space change still collapse it.
    var holdsOpen: () -> Bool = { false }
    /// True while the presenter's window is not on the active Space (a full-screen app's, with "Show over
    /// full-screen apps" off): the machine idles, so a pointer parked at the top of that Space opens nothing.
    var isOffScreen: () -> Bool = { false }
    /// Where the pointer is; `--smoke --hover-sim` substitutes a scripted path.
    var pointerLocation: () -> CGPoint = { NSEvent.mouseLocation }
    /// The pointer came to rest on the rings; Hide when idle brings them back for it.
    var pointerEnteredCompact: () -> Void = {}
    /// A click on the collapsed strip that the presenter takes for itself, returning true when it did: while the
    /// strip names a session (the news peek) a click opens the panel on that session in any visibility mode,
    /// where a click on the rings only toggles the panel under Open on click.
    var claimsCompactClick: () -> Bool = { false }
    /// The assistant whose readout is under a point on the collapsed strip (RingTargets), for scroll-to-retarget;
    /// nil where there is none, which is every point for a presenter that registers no readouts.
    var ringAt: (CGPoint) -> ToolID? = { _ in nil }
    /// A scroll over a readout stepped: the presenter moves that tool's ring on (+1) or back (-1) and names it.
    var ringScrolled: (ToolID, Int) -> Void = { _, _ in }
    /// One line per decision, for the transition log.
    var log: ((String) -> Void)?
    /// Swipes open and close (Preferences.gesturesEnabled, off under Reduce Motion).
    var gestures = true
    /// A haptic tick on each transition, with the gestures.
    var haptics = true
    /// Points of two-finger travel that count as a swipe.
    static let swipeThreshold: CGFloat = 24

    static let tickInterval: TimeInterval = 0.25

    private var intent: HoverIntent
    private var monitors: [Any] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var tick: Task<Void, Never>?
    private var deadline: (at: TimeInterval, task: Task<Void, Never>)?
    private weak var trackedView: NSView?
    private var wasInCompact = false
    private var swipeTravel: CGFloat = 0
    private var swipeFired = false
    private var ringScroll = RingScroll()

    init(mode: HoverIntent.Mode, dwell: TimeInterval = HoverIntent.expandDwell) {
        intent = HoverIntent(mode: mode, expandDwell: dwell)
    }

    var mode: HoverIntent.Mode {
        get { intent.mode }
        set {
            intent.mode = newValue
            reschedule()
        }
    }

    var dwell: TimeInterval {
        get { intent.expandDwell }
        set {
            intent.expandDwell = min(1, max(0.1, newValue))
            reschedule()
        }
    }

    var state: HoverIntent.State { intent.state }

    /// Over the app's own windows the global monitor is silent, and a non-key panel gets no mouse-moved events
    /// unless a tracking area asks for them; the local monitor then sees them. Call again after a window is rebuilt.
    func watch(_ window: NSWindow?) {
        guard let window, let view = window.contentView, view !== trackedView else { return }
        window.acceptsMouseMovedEvents = true
        view.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: view, userInfo: nil))
        trackedView = view
    }

    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .scrollWheel]
        // Local monitors run on the main thread; the event itself stays outside the isolated closure.
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            let reduced = Self.reduce(event)
            MainActor.assumeIsolated { self?.handle(reduced) }
            return event
        } as Any)
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let reduced = Self.reduce(event)
            MainActor.assumeIsolated { self?.handle(reduced) }
        }) {
            monitors.append(global)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.interrupted(.space) }
        }))
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.interrupted(.lock) }
        }))
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.interrupted(.lock) }
        }))
        let distributed = DistributedNotificationCenter.default()
        observers.append((distributed, distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.interrupted(.lock) }
        }))
        reschedule()
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        tick?.cancel()
        tick = nil
        deadline?.task.cancel()
        deadline = nil
    }

    /// The controller changed the panel itself (Always open at launch, a layout swap).
    func adopt(_ state: HoverIntent.State) {
        intent.adopt(state, at: now)
        reschedule()
    }

    func transitionSettled() {
        intent.transitionSettled(at: now)
        log?("settled")
        reschedule()
    }

    func pointerMoved() {
        sample()
    }

    func clicked(at point: CGPoint) {
        if regions.isClickOnCompact(point) {
            if intent.state == .compact, claimsCompactClick() { return }
            act(intent.clickInside(at: now), cause: .click)
            return
        }
        guard regions.isOutsidePanel(point), !holdsOpen() else { return }
        act(intent.clickOutside(at: now), cause: .clickOutside)
    }

    /// Closes the panel now, for the app's own reasons (a request answered on a panel that was opened for it).
    func dismiss(cause: PanelCause) {
        act(intent.escape(at: now), cause: cause)
    }

    func swiped(_ swipe: HoverIntent.Swipe, at point: CGPoint) {
        guard gestures else { return }
        let hit = regions.hit(point)
        act(intent.swipe(swipe, inCompact: hit.inCompact, inExpanded: hit.inExpanded, at: now), cause: .swipe)
    }

    func interrupted(_ cause: PanelCause) {
        act(intent.spaceChangedOrLocked(at: now), cause: cause)
    }

    func escape() {
        act(intent.escape(at: now), cause: .escape)
    }

    func toggle(cause: PanelCause = .hotkey) {
        act(intent.toggle(at: now), cause: cause)
    }

    /// Opens a closed panel for a few seconds; the pointer coming in keeps it open, otherwise it settles.
    func glance(for duration: TimeInterval = HoverIntent.glanceDuration) {
        act(intent.glance(for: duration, at: now), cause: .glance)
    }

    var isGlancing: Bool { intent.isGlancing }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    nonisolated static func reduce(_ event: NSEvent) -> PointerEvent {
        switch event.type {
        case .leftMouseDown:
            return PointerEvent(kind: event.modifierFlags.contains(.control) ? .controlClick : .click)
        case .scrollWheel:
            let fingersDown = (event.scrollingDeltaY > 0) == event.isDirectionInvertedFromDevice
            let phase: RingScroll.Phase = event.phase.contains(.began) || event.phase.contains(.mayBegin) ? .began
                : event.phase.contains(.ended) || event.phase.contains(.cancelled) ? .ended
                : event.phase.isEmpty ? .none : .changed
            let ring = RingScroll.Input(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY, phase: phase,
                                        momentum: !event.momentumPhase.isEmpty)
            return PointerEvent(kind: .scroll(PointerEvent.Scroll(deltaY: event.scrollingDeltaY, fingersDown: fingersDown, phase: event.phase, ring: ring)))
        default:
            return PointerEvent(kind: .moved)
        }
    }

    /// One reduced event from either monitor; the tests feed it directly, since no monitor runs without a
    /// window server. A scroll is offered to the readout under the pointer first (`retargetRing`), and only one
    /// it did not claim goes on to the swipe, so a sideways gesture over a ring never also opens the panel.
    func handle(_ event: PointerEvent) {
        switch event.kind {
        case .click:
            clicked(at: pointerLocation())
        case .controlClick:
            break
        case .scroll(let scroll):
            if retargetRing(scroll.ring) { return }
            let (deltaY, fingersDown, phase) = (scroll.deltaY, scroll.fingersDown, scroll.phase)
            guard gestures else { return }
            if phase == .began || phase == .mayBegin {
                swipeTravel = 0
                swipeFired = false
            }
            swipeTravel += abs(deltaY)
            if !swipeFired, swipeTravel >= Self.swipeThreshold {
                swipeFired = true
                swiped(fingersDown ? .down : .up, at: pointerLocation())
            }
            if phase == .ended || phase == .cancelled {
                swipeTravel = 0
                swipeFired = false
            }
        case .moved:
            sample()
        }
    }

    /// A scroll over a readout on the collapsed strip, fed to the ring's quantiser (RingScroll); true when the
    /// scroll was the readout's, so the swipe below does not count it too. Only while collapsed and on screen, and
    /// never while a menu or a window holds the panel: the same conditions the pointer's own samples keep.
    private func retargetRing(_ input: RingScroll.Input) -> Bool {
        guard intent.state == .compact, !isPaused(), !isOffScreen(), let tool = ringAt(pointerLocation()) else {
            ringScroll.reset()
            return false
        }
        let outcome = ringScroll.feed(input, verticalSwipes: gestures, at: now)
        if let step = outcome.step { ringScrolled(tool, step) }
        return outcome.claimed
    }

    private func sample() {
        guard !isPaused(), !isOffScreen() else { return }
        let hit = regions.hit(pointerLocation())
        if hit.inCompact, !wasInCompact { pointerEnteredCompact() }
        wasInCompact = hit.inCompact
        let glancing = intent.isGlancing
        let output = intent.pointer(inCompact: hit.inCompact, inExpanded: hit.inExpanded, at: now)
        act(output, cause: output == .expand ? .dwell : glancing ? .glance : .exit)
    }

    private func act(_ output: HoverIntent.Output, cause: PanelCause) {
        switch output {
        case .expand: log?("expand")
        case .collapse: log?("collapse")
        case .none: break
        }
        if output != .none {
            if haptics, gestures { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            perform(output, cause)
        }
        reschedule()
    }

    /// One re-sample at the pending dwell's deadline; the tick exists only while the panel is open and can close.
    private func reschedule() {
        if let due = intent.nextDeadline {
            if deadline?.at != due {
                deadline?.task.cancel()
                let wait = max(0, due - now) + 0.01
                deadline = (due, Task { [weak self] in
                    try? await Task.sleep(for: .seconds(wait))
                    guard !Task.isCancelled else { return }
                    self?.sample()
                })
            }
        } else {
            deadline?.task.cancel()
            deadline = nil
        }
        if intent.state == .expanded, intent.mode == .onHover || intent.isGlancing {
            if tick == nil {
                tick = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(Self.tickInterval))
                        guard !Task.isCancelled else { return }
                        self?.sample()
                    }
                }
            }
        } else {
            tick?.cancel()
            tick = nil
        }
    }
}
