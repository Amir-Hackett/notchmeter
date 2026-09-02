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
    var togglePanel: () -> Void = {}
    var copyPanelImage: () -> Void = {}
    var installCommandLineTool: () -> Void = {}
    /// Opens a URL in the browser (a vendor's usage or status page).
    var open: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Nil while the updater is inactive (see Updater); the Options menu offers "Check for Updates…" only when set.
    var checkForUpdates: (() -> Void)?
}

/// One on-screen presentation of the readings: the notch itself or a Codenotch-style edge pill.
@MainActor
protocol PanelPresenting: AnyObject {
    var edge: PanelEdge { get }
    var screen: NSScreen { get }
    var isVisible: Bool { get }
    var window: NSWindow? { get }
    /// What the open panel's content measures right now, before any window or chrome around it.
    var expandedContentSize: CGSize { get }
    var hover: HoverDriver { get }
    func show()
    func hide() async
    func showOptions()
    /// Keeps the panel closed while the app's own Settings window is up, whatever the visibility preference, so
    /// the full-height panel can never sit over it; releasing re-applies the preference.
    func holdCompact(_ held: Bool)
    /// Measures the visible shapes again now (`--smoke` reads the compact width per style).
    func remeasure()
    /// The Show over full-screen apps setting, applied to the window.
    func applyWindowBehaviour()
    /// Opens the panel for a notification's Open button or the shortcut; the machine adopts the state.
    func toggle(cause: PanelCause)
    func expandNow(cause: PanelCause)
    /// Opens a closed panel for a few seconds (SessionAttention.glance); the pointer coming in keeps it open.
    func glance()
}

extension PanelPresenting {
    /// The window collection behaviour for the setting: joined to every Space, and to a full-screen app's when asked.
    static func collectionBehavior(showOverFullScreen: Bool) -> NSWindow.CollectionBehavior {
        showOverFullScreen ? [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary] : [.canJoinAllSpaces, .stationary]
    }
}

/// Reports each change of the panel's state to the oracle (Oracle.swift); the first report is the launch state.
struct PanelReporter {
    private var reported: HoverIntent.State?

    mutating func report(_ state: HoverIntent.State, cause: PanelCause) {
        guard reported != state else { return }
        Oracle.shared.emit("panel", ["state": state.rawValue, "cause": (reported == nil ? PanelCause.launch : cause).rawValue])
        reported = state
    }
}

/// The right-click / Options menu shared by every panel style and the menu bar item.
@MainActor
final class OptionsMenu: NSObject, NSMenuDelegate {
    private let prefs: Preferences
    private let actions: NotchActions
    private let includesOpenPanel: Bool
    private(set) var isOpen = false

    init(prefs: Preferences, actions: NotchActions, includesOpenPanel: Bool = false) {
        self.prefs = prefs
        self.actions = actions
        self.includesOpenPanel = includesOpenPanel
    }

    func popUp(in window: NSWindow?, event: NSEvent? = nil) {
        let menu = build()
        if let event, let view = window?.contentView {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        isOpen = true
        Oracle.shared.emit("menu", ["action": "shown", "items": menu.items.map(\.title).filter { !$0.isEmpty }])
    }

    func menuDidClose(_ menu: NSMenu) {
        isOpen = false
        Oracle.shared.emit("menu", ["action": "dismissed"])
    }

    func build() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        if includesOpenPanel {
            menu.addItem(item(L("Open panel"), #selector(togglePanel)))
        }
        menu.addItem(item(L("Refresh now"), #selector(refreshNow)))
        menu.addItem(.separator())
        for visibility in NotchVisibility.allCases {
            let entry = item(visibility.title, #selector(setVisibility(_:)))
            entry.representedObject = visibility.rawValue
            entry.state = prefs.visibility == visibility ? .on : .off
            menu.addItem(entry)
        }
        let position = NSMenuItem(title: L("Position"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for edge in PanelEdge.allCases {
            let entry = item(edge.title, #selector(setEdge(_:)))
            entry.representedObject = edge.rawValue
            entry.state = prefs.edge == edge ? .on : .off
            submenu.addItem(entry)
        }
        position.submenu = submenu
        menu.addItem(position)
        let compact = NSMenuItem(title: prefs.edge.compactStyleTitle, action: nil, keyEquivalent: "")
        let styles = NSMenu()
        for style in CompactStyle.allCases {
            let entry = item(style.title, #selector(setCompactStyle(_:)))
            entry.representedObject = style.rawValue
            entry.state = prefs.compactStyle == style ? .on : .off
            styles.addItem(entry)
        }
        compact.submenu = styles
        menu.addItem(compact)
        menu.addItem(item(L("Copy panel as image"), #selector(copyImage)))
        menu.addItem(item(L("Install command line tool…"), #selector(installCLI)))
        menu.addItem(.separator())
        let login = item(L("Open at login"), #selector(toggleLaunchAtLogin))
        login.state = prefs.launchAtLogin ? .on : .off
        menu.addItem(login)
        let settings = item(L("Settings…"), #selector(showSettings))
        settings.keyEquivalent = ","
        settings.keyEquivalentModifierMask = .command
        menu.addItem(settings)
        if actions.checkForUpdates != nil {
            menu.addItem(item(L("Check for Updates…"), #selector(checkForUpdates)))
        }
        menu.addItem(.separator())
        let quit = item(L("Quit %@", AppInfo.name), #selector(quit))
        quit.keyEquivalent = "q"
        quit.keyEquivalentModifierMask = .command
        menu.addItem(quit)
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        return entry
    }

    @objc private func refreshNow() { actions.refresh() }
    @objc private func togglePanel() { actions.togglePanel() }
    @objc private func copyImage() { actions.copyPanelImage() }
    @objc private func installCLI() { actions.installCommandLineTool() }

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

    @objc private func setCompactStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = CompactStyle(rawValue: raw) else { return }
        prefs.compactStyle = style
    }

    @objc private func toggleLaunchAtLogin() { try? prefs.setLaunchAtLogin(!prefs.launchAtLogin) }
    @objc private func showSettings() { actions.openSettings() }
    @objc private func checkForUpdates() { actions.checkForUpdates?() }
    @objc private func quit() { NSApp.terminate(nil) }
}

extension NotchVisibility {
    var hoverMode: HoverIntent.Mode {
        switch self {
        case .always: .always
        case .onClick: .onClick
        case .onHover, .hideWhenIdle: .onHover
        }
    }
}

/// Top layout on a screen with a notch: compact rings beside it, the full panel below it on hover. A notchless
/// screen gets an EdgePanelController pill under the menu bar instead (AppDelegate.buildPresenters).
@MainActor
final class NotchController: NSObject, PanelPresenting {
    let edge: PanelEdge = .top
    let screenKey: String
    private var storedScreen: NSScreen
    let hover: HoverDriver
    private let store: UsageStore
    private let prefs: Preferences
    private let actions: NotchActions
    private let menu: OptionsMenu
    private let notch: DynamicNotch<NotchExpandedView, NotchCompactView, NotchCompactView>
    private let leadingProbe: NSHostingView<NotchCompactView>
    private let trailingProbe: NSHostingView<NotchCompactView>
    private let expandedProbe: NSHostingView<NotchExpandedView>
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var transitionSerial = 0
    private var held = false
    private var reporter = PanelReporter()

    /// DynamicNotchKit's insets around the expanded content: 15 pt at the sides and bottom, the notch on top.
    static let panelInset: CGFloat = 15
    /// Its floating style (notchless screens) hangs the panel 20 pt below a 300 pt stand-in for the notch.
    static let floatingGap: CGFloat = 20
    static let floatingNotchWidth: CGFloat = 300
    /// How far past the rings the compact shape counts as hoverable.
    static let compactMargin: CGFloat = 8

    init(screen: NSScreen, store: UsageStore, prefs: Preferences, actions: NotchActions) {
        self.screenKey = screen.identityKey
        self.storedScreen = screen
        self.store = store
        self.prefs = prefs
        self.actions = actions
        self.menu = OptionsMenu(prefs: prefs, actions: actions)
        notch = DynamicNotch(hoverBehavior: [.increaseShadow], style: .notch) {
            NotchExpandedView(store: store, prefs: prefs, actions: actions, screen: screen)
        } compactLeading: {
            NotchCompactView(store: store, side: .leading)
        } compactTrailing: {
            NotchCompactView(store: store, side: .trailing)
        }
        leadingProbe = NSHostingView(rootView: NotchCompactView(store: store, side: .leading))
        trailingProbe = NSHostingView(rootView: NotchCompactView(store: store, side: .trailing))
        expandedProbe = NSHostingView(rootView: NotchExpandedView(store: store, prefs: prefs, actions: actions, screen: screen))
        hover = HoverDriver(mode: prefs.visibility.hoverMode, dwell: prefs.hoverDelay)
        super.init()
        applyWindowBehaviour()
        configureTransition(closing: false)
        hover.perform = { [weak self] output, cause in self?.act(output, cause: cause) }
        hover.isPaused = { [weak self] in self.map { $0.menu.isOpen || $0.held } ?? false }
        hover.isOffScreen = { [weak self] in
            guard let self, let window = self.notch.windowController?.window, window.isVisible else { return false }
            return !window.isOnActiveSpace
        }
        hover.pointerEnteredCompact = { [weak self] in self?.store.wakeFromIdle() }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.configureTransition(closing: false)
                self?.applyWindowBehaviour()
            }
        }))
        observers.append((.default, NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshRegions() }
        }))
        // Local monitors run on the main thread. assumeIsolated must return something Sendable, which NSEvent is not,
        // so the closure reports whether it handled the event and the event is passed on outside it. A control-click
        // is the secondary click for one-button mice and many accessibility setups, so it opens the menu too.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            let secondary = event.type == .rightMouseDown || event.modifierFlags.contains(.control)
            let handled = MainActor.assumeIsolated {
                guard secondary, let self, let window = self.notch.windowController?.window, event.window === window else { return false }
                self.menu.popUp(in: window, event: event)
                return true
            }
            return handled ? nil : event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let escape = event.keyCode == 53
            let handled = MainActor.assumeIsolated {
                guard escape, let self, let window = self.notch.windowController?.window, event.window === window, self.hover.state == .expanded else { return false }
                self.hover.escape()
                return true
            }
            return handled ? nil : event
        }
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

    var window: NSWindow? { notch.windowController?.window }
    var isVisible: Bool { window?.isVisible ?? false }
    var expandedContentSize: CGSize { fittingSize(expandedProbe, NotchExpandedView(store: store, prefs: prefs, actions: actions, screen: screen)) }

    func show() {
        hover.mode = prefs.visibility.hoverMode
        hover.dwell = prefs.hoverDelay
        hover.gestures = prefs.gesturesEnabled && !AccessibilityDisplay.shared.motionReduced
        hover.start()
        applyWindowBehaviour()
        let open = !held && (hover.mode == .always || hover.state == .expanded)
        Task {
            if open {
                await self.expand(cause: .always)
            } else {
                await self.compact(cause: self.held ? .settings : .menu)
            }
        }
    }

    /// The machine adopts the closed state at once, so whoever presents a window over the panel sees it closed
    /// before the morph has run.
    func holdCompact(_ held: Bool) {
        self.held = held
        if held {
            hover.adopt(.compact)
            reporter.report(.compact, cause: .settings)
        }
        show()
    }

    func remeasure() {
        refreshRegions()
    }

    func applyWindowBehaviour() {
        notch.collectionBehavior = Self.collectionBehavior(showOverFullScreen: prefs.showOverFullScreenApps)
        notch.expandedGlass = !AccessibilityDisplay.shared.reduceTransparency
    }

    func toggle(cause: PanelCause) {
        hover.toggle(cause: cause)
    }

    func expandNow(cause: PanelCause) {
        guard hover.state != .expanded else { return }
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
        await notch.hide()
    }

    func showOptions() {
        menu.popUp(in: notch.windowController?.window)
    }

    // MARK: - Transitions

    private func act(_ output: HoverIntent.Output, cause: PanelCause) {
        switch output {
        case .expand:
            if !hover.isOffScreen() { store.refreshAll(force: false) }
            Task { await self.expand(cause: cause) }
        case .collapse:
            Task { await self.compact(cause: cause) }
        case .none:
            break
        }
    }

    private func expand(cause: PanelCause) async {
        refreshRegions()
        configureTransition(closing: false)
        hover.adopt(.expanded)
        reporter.report(.expanded, cause: cause)
        let serial = beginTransition()
        await notch.expand(on: screen)
        if PanelKeyPolicy.takesKeyboard(cause) { window?.makeKey() }
        endTransition(serial)
    }

    private func compact(cause: PanelCause) async {
        configureTransition(closing: true)
        hover.adopt(.compact)
        reporter.report(.compact, cause: cause)
        if let window, window.isKeyWindow { window.resignKey() }
        let serial = beginTransition()
        await notch.compact(on: screen)
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
    /// black slab with its content already faded. Reduce Motion (or the app's own toggle) makes every transition instant.
    private func configureTransition(closing: Bool) {
        let instant = AccessibilityDisplay.shared.motionReduced
        let shrink: Animation = .smooth(duration: 0.25)
        notch.transitionConfiguration = DynamicNotchTransitionConfiguration(
            openingAnimation: instant ? .linear(duration: 0) : nil,
            closingAnimation: instant ? .linear(duration: 0) : shrink,
            conversionAnimation: instant ? .linear(duration: 0) : closing ? shrink : nil,
            skipIntermediateHides: true
        )
    }

    // MARK: - Geometry

    /// The physical notch in screen coordinates; on a notchless screen, a stand-in at the top centre as tall as the
    /// menu bar is right now (never cached: with the bar set to hide, its height comes and goes).
    static func notchRect(on screen: NSScreen) -> CGRect {
        let frame = screen.frame
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let height = screen.safeAreaInsets.top
            return CGRect(x: left.maxX, y: frame.maxY - height, width: right.minX - left.maxX, height: height)
        }
        let height = max(screen.menuBarHeightNow, 24)
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
            notch: Self.notchRect(on: screen),
            leadingWidth: fittingSize(leadingProbe, NotchCompactView(store: store, side: .leading)).width,
            trailingWidth: fittingSize(trailingProbe, NotchCompactView(store: store, side: .trailing)).width,
            expanded: expandedContentSize,
            floating: false
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
            _ = (store.statuses, store.sessions, store.cost, store.statusline, store.screenCaptured, store.footerNote, prefs.enabledTools, prefs.showSpend, prefs.toolOrder,
                 prefs.compactStyle, prefs.usageDisplay, prefs.density, prefs.panelWidth, prefs.showResetCountdown, prefs.ringWindows, prefs.hiddenWindows,
                 prefs.revealedWindows, prefs.visibility, prefs.hoverDelay, prefs.gesturesEnabled, prefs.showOverFullScreenApps, prefs.costCardMode,
                 prefs.monthlyBudgetUSD)
            refreshRegions()
            hover.dwell = prefs.hoverDelay
            hover.gestures = prefs.gesturesEnabled && !AccessibilityDisplay.shared.motionReduced
            applyWindowBehaviour()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeContent() }
        }
    }
}
