import AppKit

/// Why the panel changed state, for the oracle (Oracle.swift): the pointer rested on the rings or left the panel,
/// a click outside, a Spaces switch, the screen lock, the Always open preference, the Settings window holding it
/// closed, the Options menu switching to Open on hover, or the state it launched in.
enum PanelCause: String {
    case dwell, exit, clickOutside, space, lock, always, settings, menu, launch
}

/// Feeds a HoverIntent from the real pointer and hands its decisions to a panel controller. Pointer facts come
/// from global and local mouse monitors (mouse events need no Accessibility permission), one re-sample at the
/// machine's next deadline so a pointer that stops moving still counts as dwelling, and a 250 ms tick that runs
/// only while the panel is open. A Spaces switch or the screen lock collapses through the same machine.
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
    /// Where the pointer is; `--smoke --hover-sim` substitutes a scripted path.
    var pointerLocation: () -> CGPoint = { NSEvent.mouseLocation }
    /// One line per decision, for the transition log.
    var log: ((String) -> Void)?

    static let tickInterval: TimeInterval = 0.25

    private var intent: HoverIntent
    private var monitors: [Any] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var tick: Task<Void, Never>?
    private var deadline: (at: TimeInterval, task: Task<Void, Never>)?
    private weak var trackedView: NSView?

    init(mode: HoverIntent.Mode) {
        intent = HoverIntent(mode: mode)
    }

    var mode: HoverIntent.Mode {
        get { intent.mode }
        set {
            intent.mode = newValue
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
        // Local monitors run on the main thread; the event itself stays outside the isolated closure.
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.handle(type) }
            return event
        } as Any)
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown], handler: { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.handle(type) }
        }) {
            monitors.append(global)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.interrupted(.space) }
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
        guard regions.isOutsidePanel(point) else { return }
        act(intent.clickOutside(at: now), cause: .clickOutside)
    }

    func interrupted(_ cause: PanelCause) {
        act(intent.spaceChangedOrLocked(at: now), cause: cause)
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func handle(_ type: NSEvent.EventType) {
        if type == .leftMouseDown {
            clicked(at: pointerLocation())
        } else {
            sample()
        }
    }

    private func sample() {
        guard !isPaused() else { return }
        let hit = regions.hit(pointerLocation())
        let output = intent.pointer(inCompact: hit.inCompact, inExpanded: hit.inExpanded, at: now)
        act(output, cause: output == .expand ? .dwell : .exit)
    }

    private func act(_ output: HoverIntent.Output, cause: PanelCause) {
        switch output {
        case .expand: log?("expand")
        case .collapse: log?("collapse")
        case .none: break
        }
        if output != .none { perform(output, cause) }
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
        if intent.state == .expanded, intent.mode == .onHover {
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
