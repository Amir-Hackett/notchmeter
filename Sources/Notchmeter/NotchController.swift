import AppKit
import DynamicNotchKit
import SwiftUI

/// Closures the panel content can invoke; wired by the app delegate.
@MainActor
final class NotchActions {
    var refresh: () -> Void = {}
    var openSettings: () -> Void = {}
    var showOptions: () -> Void = {}
    var applyLayout: () -> Void = {}
    /// Nil while the updater is inactive (see Updater); the Options menu offers "Check for Updates…" only when set.
    var checkForUpdates: (() -> Void)?
}

/// One on-screen presentation of the readings: the notch itself or a Codenotch-style edge pill.
@MainActor
protocol PanelPresenting: AnyObject {
    var edge: PanelEdge { get }
    var isVisible: Bool { get }
    var window: NSWindow? { get }
    /// What the open panel's content measures right now, before any window or chrome around it.
    var expandedContentSize: CGSize { get }
    var hover: HoverDriver { get }
    func show()
    func hide() async
    func showOptions()
}

extension NSScreen {
    /// Where the panel lives: the display with the notch when there is one, else the main screen.
    static var panelScreen: NSScreen {
        screens.first { $0.safeAreaInsets.top > 0 } ?? main ?? screens[0]
    }
}

/// The right-click / Options menu shared by every panel style.
@MainActor
final class OptionsMenu: NSObject, NSMenuDelegate {
    private let prefs: Preferences
    private let actions: NotchActions
    private(set) var isOpen = false

    init(prefs: Preferences, actions: NotchActions) {
        self.prefs = prefs
        self.actions = actions
    }

    func popUp(in window: NSWindow?, event: NSEvent? = nil) {
        let menu = build()
        if let event, let view = window?.contentView {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    func menuWillOpen(_ menu: NSMenu) { isOpen = true }
    func menuDidClose(_ menu: NSMenu) { isOpen = false }

    private func build() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(item("Refresh now", #selector(refreshNow)))
        menu.addItem(.separator())
        for visibility in NotchVisibility.allCases {
            let entry = item(visibility.title, #selector(setVisibility(_:)))
            entry.representedObject = visibility.rawValue
            entry.state = prefs.visibility == visibility ? .on : .off
            menu.addItem(entry)
        }
        let position = NSMenuItem(title: "Position", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for edge in PanelEdge.allCases {
            let entry = item(edge.title, #selector(setEdge(_:)))
            entry.representedObject = edge.rawValue
            entry.state = prefs.edge == edge ? .on : .off
            submenu.addItem(entry)
        }
        position.submenu = submenu
        menu.addItem(position)
        menu.addItem(.separator())
        let login = item("Open at login", #selector(toggleLaunchAtLogin))
        login.state = prefs.launchAtLogin ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Settings…", #selector(showSettings)))
        if actions.checkForUpdates != nil {
            menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        }
        menu.addItem(.separator())
        menu.addItem(item("Quit \(AppInfo.name)", #selector(quit)))
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        return entry
    }

    @objc private func refreshNow() { actions.refresh() }

    @objc private func setVisibility(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let visibility = NotchVisibility(rawValue: raw) else { return }
        prefs.visibility = visibility
        actions.applyLayout()
    }

    @objc private func setEdge(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let edge = PanelEdge(rawValue: raw) else { return }
        prefs.edge = edge
        actions.applyLayout()
    }

    @objc private func toggleLaunchAtLogin() { try? prefs.setLaunchAtLogin(!prefs.launchAtLogin) }
    @objc private func showSettings() { actions.openSettings() }
    @objc private func checkForUpdates() { actions.checkForUpdates?() }
    @objc private func quit() { NSApp.terminate(nil) }
}

extension NotchVisibility {
    var hoverMode: HoverIntent.Mode {
        self == .always ? .always : .onHover
    }
}

/// Top layout: compact rings beside the physical notch, the full panel below it on hover.
@MainActor
final class NotchController: NSObject, PanelPresenting {
    let edge: PanelEdge = .top
    let hover: HoverDriver
    private let store: UsageStore
    private let prefs: Preferences
    private let actions: NotchActions
    private let menu: OptionsMenu
    private let notch: DynamicNotch<NotchExpandedView, NotchCompactView, NotchCompactView>
    private let floating: Bool
    private let leadingProbe: NSHostingView<NotchCompactView>
    private let trailingProbe: NSHostingView<NotchCompactView>
    private let expandedProbe: NSHostingView<NotchExpandedView>
    private var rightClickMonitor: Any?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var transitionSerial = 0

    /// DynamicNotchKit's insets around the expanded content: 15 pt at the sides and bottom, the notch on top.
    static let panelInset: CGFloat = 15
    /// Its floating style (notchless screens) hangs the panel 20 pt below a 300 pt stand-in for the notch.
    static let floatingGap: CGFloat = 20
    static let floatingNotchWidth: CGFloat = 300
    /// How far past the rings the compact shape counts as hoverable.
    static let compactMargin: CGFloat = 8

    init(store: UsageStore, prefs: Preferences, actions: NotchActions) {
        self.store = store
        self.prefs = prefs
        self.actions = actions
        self.menu = OptionsMenu(prefs: prefs, actions: actions)
        let hasNotch = NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
        floating = !hasNotch
        notch = DynamicNotch(hoverBehavior: [.increaseShadow], style: hasNotch ? .notch : .floating) {
            NotchExpandedView(store: store, prefs: prefs, actions: actions)
        } compactLeading: {
            NotchCompactView(store: store, side: .leading)
        } compactTrailing: {
            NotchCompactView(store: store, side: .trailing)
        }
        leadingProbe = NSHostingView(rootView: NotchCompactView(store: store, side: .leading))
        trailingProbe = NSHostingView(rootView: NotchCompactView(store: store, side: .trailing))
        expandedProbe = NSHostingView(rootView: NotchExpandedView(store: store, prefs: prefs, actions: actions))
        hover = HoverDriver(mode: prefs.visibility.hoverMode)
        super.init()
        configureTransition(closing: false)
        hover.perform = { [weak self] output in self?.act(output) }
        hover.isPaused = { [weak self] in self?.menu.isOpen ?? false }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.configureTransition(closing: false) }
        }))
        observers.append((.default, NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshRegions() }
        }))
        // Local monitors run on the main thread. assumeIsolated must return something Sendable, which NSEvent is not,
        // so the closure reports whether it handled the event and the event is passed on outside it.
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, let window = self.notch.windowController?.window, event.window === window else { return false }
                self.menu.popUp(in: window, event: event)
                return true
            }
            return handled ? nil : event
        }
        observeContent()
    }

    var window: NSWindow? { notch.windowController?.window }
    var isVisible: Bool { window?.isVisible ?? false }
    var expandedContentSize: CGSize { fittingSize(expandedProbe, NotchExpandedView(store: store, prefs: prefs, actions: actions)) }

    func show() {
        hover.mode = prefs.visibility.hoverMode
        hover.start()
        Task {
            if self.hover.mode == .always || self.hover.state == .expanded {
                await self.expand()
            } else {
                await self.compact()
            }
        }
    }

    func hide() async {
        hover.stop()
        if let rightClickMonitor { NSEvent.removeMonitor(rightClickMonitor) }
        rightClickMonitor = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        transitionSerial += 1
        await notch.hide()
    }

    func showOptions() {
        menu.popUp(in: notch.windowController?.window)
    }

    // MARK: - Transitions

    private func act(_ output: HoverIntent.Output) {
        switch output {
        case .expand:
            store.refreshAll(force: false)
            Task { await self.expand() }
        case .collapse:
            Task { await self.compact() }
        case .none:
            break
        }
    }

    private func expand() async {
        refreshRegions()
        configureTransition(closing: false)
        hover.adopt(.expanded)
        let serial = beginTransition()
        await notch.expand(on: .panelScreen)
        endTransition(serial)
    }

    private func compact() async {
        configureTransition(closing: true)
        hover.adopt(.compact)
        let serial = beginTransition()
        await notch.compact(on: .panelScreen)
        endTransition(serial)
    }

    private func beginTransition() -> Int {
        transitionSerial += 1
        return transitionSerial
    }

    /// DynamicNotchKit returns once its animation has run, possibly in a rebuilt window; only the latest
    /// transition may settle the machine.
    private func endTransition(_ serial: Int) {
        hover.watch(notch.windowController?.window)
        guard serial == transitionSerial else { return }
        hover.transitionSettled()
    }

    /// The open keeps DynamicNotchKit's spring; the close is a 0.25 s smooth shrink so the panel never sits as a
    /// black slab with its content already faded. Reduce Motion makes every transition instant.
    private func configureTransition(closing: Bool) {
        let instant = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let shrink: Animation = .smooth(duration: 0.25)
        notch.transitionConfiguration = DynamicNotchTransitionConfiguration(
            openingAnimation: instant ? .linear(duration: 0) : nil,
            closingAnimation: instant ? .linear(duration: 0) : shrink,
            conversionAnimation: instant ? .linear(duration: 0) : closing ? shrink : nil,
            skipIntermediateHides: true
        )
    }

    // MARK: - Geometry

    /// The physical notch in screen coordinates; on a notchless screen, DynamicNotchKit's stand-in at the top centre.
    static func notchRect(on screen: NSScreen) -> CGRect {
        let frame = screen.frame
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let height = screen.safeAreaInsets.top
            return CGRect(x: left.maxX, y: frame.maxY - height, width: right.minX - left.maxX, height: height)
        }
        let height = frame.maxY - screen.visibleFrame.maxY
        return CGRect(x: frame.midX - floatingNotchWidth / 2, y: frame.maxY - height, width: floatingNotchWidth, height: height)
    }

    /// Both visible shapes from the notch and the content's fitting sizes; never DynamicNotchKit's window, an
    /// invisible column half the screen wide and the full screen tall that would flip a stationary pointer inside
    /// and outside as it morphs.
    static func regions(notch: CGRect, leadingWidth: CGFloat, trailingWidth: CGFloat, expanded: CGSize, floating: Bool) -> HoverRegions {
        let compact = CGRect(
            x: notch.minX - leadingWidth - compactMargin,
            y: notch.minY,
            width: notch.width + leadingWidth + trailingWidth + 2 * compactMargin,
            height: notch.height
        )
        let width = expanded.width + 2 * panelInset
        let panel: CGRect
        if floating {
            let height = expanded.height + 2 * panelInset
            panel = CGRect(x: notch.midX - width / 2, y: notch.minY - floatingGap - height, width: width, height: height)
        } else {
            let height = expanded.height + panelInset + notch.height
            panel = CGRect(x: notch.midX - width / 2, y: notch.maxY - height, width: width, height: height)
        }
        return HoverRegions(compact: compact, expanded: panel)
    }

    private func refreshRegions() {
        hover.regions = Self.regions(
            notch: Self.notchRect(on: .panelScreen),
            leadingWidth: fittingSize(leadingProbe, NotchCompactView(store: store, side: .leading)).width,
            trailingWidth: fittingSize(trailingProbe, NotchCompactView(store: store, side: .trailing)).width,
            expanded: expandedContentSize,
            floating: floating
        )
    }

    private func fittingSize<Content: View>(_ probe: NSHostingView<Content>, _ content: Content) -> CGSize {
        probe.rootView = content
        probe.layoutSubtreeIfNeeded()
        return probe.fittingSize
    }

    /// Re-measures whenever something that shapes the panel changes; the tracking is one-shot, so it re-arms itself.
    private func observeContent() {
        withObservationTracking {
            _ = (store.statuses, store.awaitingInput, store.cost, prefs.enabledTools, prefs.showSpend)
            refreshRegions()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeContent() }
        }
    }
}
