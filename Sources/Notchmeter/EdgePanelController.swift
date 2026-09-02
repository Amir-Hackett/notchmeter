import AppKit
import SwiftUI

/// Codenotch-style layouts: a pill on the left, right or bottom edge that opens into the full panel on hover.
@MainActor
final class EdgePanelController: NSObject, PanelPresenting {
    let edge: PanelEdge
    let hover: HoverDriver
    private let store: UsageStore
    private let prefs: Preferences
    private let actions: NotchActions
    private let menu: OptionsMenu
    private let panel: EdgePanel
    private let host: NSHostingView<EdgePanelRoot>
    private let probe: NSHostingView<EdgePanelRoot>
    private let contentProbe: NSHostingView<NotchExpandedView>
    private var expanded = false
    private var held = false
    private var reporter = PanelReporter()
    private var rightClickMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var transitionSerial = 0

    init(edge: PanelEdge, store: UsageStore, prefs: Preferences, actions: NotchActions) {
        self.edge = edge
        self.store = store
        self.prefs = prefs
        self.actions = actions
        self.menu = OptionsMenu(prefs: prefs, actions: actions)
        panel = EdgePanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        host = NSHostingView(rootView: EdgePanelRoot(store: store, prefs: prefs, actions: actions, edge: edge, expanded: false))
        probe = NSHostingView(rootView: EdgePanelRoot(store: store, prefs: prefs, actions: actions, edge: edge, expanded: true))
        contentProbe = NSHostingView(rootView: NotchExpandedView(store: store, prefs: prefs, actions: actions))
        hover = HoverDriver(mode: prefs.visibility.hoverMode)
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.contentView = host

        hover.watch(panel)
        hover.perform = { [weak self] output, cause in self?.act(output, cause: cause) }
        hover.isPaused = { [weak self] in self.map { $0.menu.isOpen || $0.held } ?? false }
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, event.window === self.panel else { return false }
                self.menu.popUp(in: self.panel, event: event)
                return true
            }
            return handled ? nil : event
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.layout(animated: false) }
        }
        observeContent()
    }

    var isVisible: Bool { panel.isVisible }
    var window: NSWindow? { panel }

    var expandedContentSize: CGSize {
        contentProbe.rootView = NotchExpandedView(store: store, prefs: prefs, actions: actions)
        contentProbe.layoutSubtreeIfNeeded()
        return contentProbe.fittingSize
    }

    func show() {
        hover.mode = prefs.visibility.hoverMode
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

    func hide() async {
        hover.stop()
        if let rightClickMonitor { NSEvent.removeMonitor(rightClickMonitor) }
        rightClickMonitor = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
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
            store.refreshAll(force: false)
        case .collapse:
            expanded = false
        case .none:
            return
        }
        reporter.report(expanded ? .expanded : .compact, cause: cause)
        transitionSerial += 1
        let serial = transitionSerial
        let duration = layout(animated: true)
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
        let animate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = animate ? panel.animationResizeTime(frame) : 0
        panel.setFrame(frame, display: true, animate: animate)
        refreshRegions()
        return duration
    }

    /// visibleFrame keeps the panel clear of the Dock.
    private func placement(for size: NSSize) -> NSRect {
        let area = NSScreen.panelScreen.visibleFrame
        let margin: CGFloat = 6
        var origin = NSPoint.zero
        switch edge {
        case .left:
            origin = NSPoint(x: area.minX + margin, y: area.midY - size.height / 2)
        case .right:
            origin = NSPoint(x: area.maxX - size.width - margin, y: area.midY - size.height / 2)
        case .bottom, .top:
            origin = NSPoint(x: area.midX - size.width / 2, y: area.minY + margin)
        }
        origin.y = min(max(origin.y, area.minY), area.maxY - size.height)
        return NSRect(origin: origin, size: size)
    }

    private func root(expanded: Bool) -> EdgePanelRoot {
        EdgePanelRoot(store: store, prefs: prefs, actions: actions, edge: edge, expanded: expanded)
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
            _ = (store.statuses, store.awaitingInput, store.cost, prefs.enabledTools, prefs.showSpend, prefs.toolOrder,
                 prefs.compactStyle, prefs.usageDisplay)
            layout(animated: false)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeContent() }
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
    let expanded: Bool

    var body: some View {
        Group {
            if expanded {
                NotchExpandedView(store: store, prefs: prefs, actions: actions)
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

/// The pill and panel background: Liquid Glass from macOS 26, black before it. The top layout never gets this,
/// because it has to merge with the hardware notch.
struct PanelSurface<S: Shape>: ViewModifier {
    let shape: S

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(shape.fill(.black))
                .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 0.5))
        }
    }
}
