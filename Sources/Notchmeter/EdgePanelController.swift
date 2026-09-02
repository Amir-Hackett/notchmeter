import AppKit
import SwiftUI

/// Codenotch-style layouts: a pill on the left, right or bottom edge that opens into the full panel on hover.
@MainActor
final class EdgePanelController: NSObject, PanelPresenting {
    let edge: PanelEdge
    private let store: UsageStore
    private let prefs: Preferences
    private let actions: NotchActions
    private let menu: OptionsMenu
    private let panel: EdgePanel
    private let host: NSHostingView<EdgePanelRoot>
    private var expanded = false
    private var collapseTask: Task<Void, Never>?
    private var rightClickMonitor: Any?
    private var screenObserver: NSObjectProtocol?

    init(edge: PanelEdge, store: UsageStore, prefs: Preferences, actions: NotchActions) {
        self.edge = edge
        self.store = store
        self.prefs = prefs
        self.actions = actions
        self.menu = OptionsMenu(prefs: prefs, actions: actions)
        panel = EdgePanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        host = NSHostingView(rootView: EdgePanelRoot(store: store, prefs: prefs, actions: actions, edge: edge, expanded: false))
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        let hover = HoverView(frame: .zero)
        hover.onHover = { [weak self] inside in self?.hoverChanged(inside) }
        hover.addSubview(host)
        host.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: hover.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: hover.trailingAnchor),
            host.topAnchor.constraint(equalTo: hover.topAnchor),
            host.bottomAnchor.constraint(equalTo: hover.bottomAnchor),
        ])
        panel.contentView = hover

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
    }

    var isVisible: Bool { panel.isVisible }
    var windowFrame: NSRect? { panel.frame }

    func show() {
        expanded = prefs.visibility == .always
        layout(animated: false)
        panel.orderFrontRegardless()
    }

    func hide() async {
        if let rightClickMonitor { NSEvent.removeMonitor(rightClickMonitor) }
        rightClickMonitor = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        collapseTask?.cancel()
        panel.orderOut(nil)
    }

    func showOptions() {
        menu.popUp(in: panel)
    }

    private var screen: NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func hoverChanged(_ inside: Bool) {
        collapseTask?.cancel()
        if inside {
            guard !expanded else { return }
            expanded = true
            layout(animated: true)
            store.refreshAll(force: false)
        } else if prefs.visibility != .always {
            collapseTask = Task {
                try? await Task.sleep(for: .seconds(0.45))
                guard !Task.isCancelled else { return }
                self.expanded = false
                self.layout(animated: true)
            }
        }
    }

    /// Sizes the window to its content and pins it to the chosen edge; visibleFrame keeps it clear of the Dock.
    private func layout(animated: Bool) {
        host.rootView = EdgePanelRoot(store: store, prefs: prefs, actions: actions, edge: edge, expanded: expanded)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let area = screen.visibleFrame
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
        let frame = NSRect(origin: origin, size: size)
        panel.setFrame(frame, display: true, animate: animated)
    }
}

final class EdgePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Reports mouse enter/exit over the whole panel, following frame changes automatically.
final class HoverView: NSView {
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
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
                    .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.black))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 0.5))
            } else {
                EdgeCompactView(store: store, edge: edge)
            }
        }
        .padding(4)
        .fixedSize()
    }
}
