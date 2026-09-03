import AppKit
import SwiftUI

/// Codenotch-style layouts: a pill on the left, right or bottom edge (or under the menu bar of a notchless screen
/// in the top layout) that opens into the full panel on hover. The screen is resolved from its identity key at
/// every layout, never kept as an instance (Apple: screens can be reconfigured at any time).
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
    private let probe: NSHostingView<EdgePanelRoot>
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
        host = NSHostingView(rootView: EdgePanelRoot(store: store, prefs: prefs, actions: actions, edge: edge, screen: screen, expanded: false))
        probe = NSHostingView(rootView: EdgePanelRoot(store: store, prefs: prefs, actions: actions, edge: edge, screen: screen, expanded: true))
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

    /// Ordered out while another app is full-screen, unless the preference says to stay. See NotchController.
    private func fullScreenChanged(_ active: Bool) {
        let hide = active && !prefs.showOverFullScreenApps
        guard hide != suppressedForFullScreen else { return }
        suppressedForFullScreen = hide
        if hide {
            hover.stop()
            panel.orderOut(nil)
        } else {
            show()
        }
    }

    func show() {
        guard !suppressedForFullScreen else { return }
        if fullScreenWatch == nil {
            fullScreenWatch = FullScreenWatch(screen: { [weak self] in self?.screen ?? .panelScreen }) { [weak self] active in
                self?.fullScreenChanged(active)
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
        if prefs.showOverFullScreenApps, suppressedForFullScreen {
            suppressedForFullScreen = false
            show()
        }
        fullScreenWatch?.refresh()
        panel.collectionBehavior = Self.collectionBehavior(showOverFullScreen: prefs.showOverFullScreenApps)
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

    /// Sizes the window to its content and pins it to the chosen edge; returns how long the move animates.
    @discardableResult
    private func layout(animated: Bool) -> TimeInterval {
        host.rootView = root(expanded: expanded)
        host.layoutSubtreeIfNeeded()
        let frame = placement(for: host.fittingSize)
        let animate = animated && !AccessibilityDisplay.shared.motionReduced
        let duration = animate ? panel.animationResizeTime(frame) : 0
        panel.setFrame(frame, display: true, animate: animate)
        refreshRegions()
        return duration
    }

    /// visibleFrame keeps the panel clear of the Dock and the menu bar; the chrome that comes and goes (an
    /// auto-hidden bar or Dock, Stage Manager's strip) is read at each layout.
    private func placement(for size: NSSize) -> NSRect {
        let screen = self.screen
        return Self.placement(for: size, edge: edge, area: screen.visibleFrame,
                              chrome: Chrome(dockHides: screen.dockHidesOnThisScreen && SystemChrome.dockAutoHides, dockOrientation: SystemChrome.dockOrientation,
                                             menuBarHides: SystemChrome.menuBarAutoHides && screen.menuBarHeightNow < 1, menuBarThickness: SystemChrome.menuBarThickness,
                                             stageManager: SystemChrome.stageManagerEnabled, stageManagerStripHides: SystemChrome.stageManagerStripAutoHides))
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
    nonisolated static func placement(for size: NSSize, edge: PanelEdge, area: NSRect, chrome: Chrome) -> NSRect {
        let margin: CGFloat = 6
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

    private func root(expanded: Bool) -> EdgePanelRoot {
        EdgePanelRoot(store: store, prefs: prefs, actions: actions, edge: edge, screen: screen, expanded: expanded)
    }

    /// The pill and the panel are the whole window here, so both regions are window frames: the state on screen
    /// from the live view, the other measured off screen.
    private func refreshRegions() {
        probe.rootView = root(expanded: !expanded)
        probe.layoutSubtreeIfNeeded()
        let other = placement(for: probe.fittingSize)
        let current = placement(for: host.fittingSize)
        hover.regions = expanded ? HoverRegions(compact: other, expanded: current) : HoverRegions(compact: current, expanded: other)
    }

    /// Re-fits the window whenever something that shapes the pill or the panel changes (the window is the visible
    /// shape here, so it must follow its content); the tracking is one-shot, so it re-arms itself.
    private func observeContent() {
        withObservationTracking {
            _ = (store.statuses, store.sessions, store.cost, store.statusline, store.screenCaptured, store.footerNote, prefs.enabledTools, prefs.showSpend, prefs.toolOrder,
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

struct EdgePanelRoot: View {
    let store: UsageStore
    let prefs: Preferences
    let actions: NotchActions
    let edge: PanelEdge
    let screen: NSScreen
    let expanded: Bool

    var body: some View {
        Group {
            if expanded {
                NotchExpandedView(store: store, prefs: prefs, actions: actions, screen: screen)
                    .padding(.vertical, 6)
                    .modifier(PanelSurface(shape: RoundedRectangle(cornerRadius: 22, style: .continuous)))
            } else {
                EdgeCompactView(store: store, edge: edge)
                    .modifier(PanelSurface(shape: Capsule()))
            }
        }
        .padding(4)
        .fixedSize()
        .environment(\.colorScheme, .dark)
    }
}

/// The pill and panel background: Liquid Glass from macOS 26, solid black before it and under Reduce Transparency.
/// The edge layouts only. The notch layout is drawn on an opaque black backdrop, over which glass renders pale
/// grey, so it keeps the black and leaves `expandedGlass` off (`NotchController.applyWindowBehaviour`).
struct PanelSurface<S: Shape>: ViewModifier {
    let shape: S

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !AccessibilityDisplay.shared.reduceTransparency {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(shape.fill(.black))
                .overlay(shape.stroke(.white.opacity(AccessibilityDisplay.shared.contrast ? 0.35 : 0.12), lineWidth: 0.5))
        }
    }
}
