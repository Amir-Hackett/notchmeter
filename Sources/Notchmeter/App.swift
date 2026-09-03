import AppKit
import os

private let log = Logger(subsystem: "com.amirhackett.notchmeter", category: "app")

@main
enum NotchmeterMain {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        // --hook: Claude Code's hook command; must return within 50 ms, so nothing else is set up first.
        if arguments.contains("--hook") {
            Hook.runCommand()
        }
        // --statusline: Claude Code's status-line command; forwards the payload and prints one line.
        if arguments.contains("--statusline") {
            Statusline.runCommand(arguments: arguments)
        }
        // --lang zh-Hans: pin the copy to one shipped language, whatever System Settings says; nothing is read before it.
        if let index = arguments.firstIndex(of: "--lang"), index + 1 < arguments.count {
            Localization.use(language: arguments[index + 1])
        }
        // --no-prompt: never raise the Keychain dialog; a locked item reports "needs attention" instead. The
        // command-line tool and the MCP server run headless and never ask either.
        if arguments.contains("--no-prompt") || arguments.contains("--smoke") || arguments.contains("--render-assets") || arguments.contains("--render-gallery")
            || arguments.contains("--mcp") || CommandLineTool.isInvokedAsTool(arguments: arguments) {
            Keychain.setPromptsAllowed(false)
        }
        // --e2e-oracle <path> (or NOTCHMETER_ORACLE): a JSON line per state change for a tester (docs/testing.md).
        // Started before anything that reports, so the launch preferences are the first lines.
        if let path = Oracle.path() {
            Oracle.shared.start(path: path)
        }
        ModelPricing.loadOverrides()
        NetworkSession.configure(proxy: UserDefaults.standard.string(forKey: "proxyURL"))
        if CommandLineTool.isInvokedAsTool(arguments: arguments) {
            CommandLineTool.run(arguments: arguments)
        }
        if arguments.contains("--mcp") {
            Task.detached {
                await MCPServer(report: {
                    if let (data, _) = CommandLineTool.cachedReport(force: false), let cached = UsageReport.decode(data) { return cached }
                    return await Probe.gather()
                }).run()
                exit(0)
            }
            RunLoop.main.run()
        }
        if arguments.contains("--probe") {
            Probe.run(json: arguments.contains("--json"), history: arguments.contains("--history"))
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        AppDelegate.shared = delegate
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?

    let prefs = Preferences()
    let actions = NotchActions()
    let notifier = Notifier()
    let requests = SettingsRequests()
    private(set) var store: UsageStore!
    private var presenters: [any PanelPresenting] = []
    private var settings: SettingsWindowController?
    private var settingsObserver: NSObjectProtocol?
    private var snapshotObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private(set) var updater: Updater?
    let updaterGate = Updater.gate()
    private var menuBarItem: MenuBarItem?
    private let capture = ScreenCaptureMonitor()
    private var localAPI: LocalAPI?
    private var hotkeyIDs: [UInt32] = []
    private var screenKey = ""
    /// Each rebuild takes a number; a build for an older number is dropped, so two screen notifications a few
    /// milliseconds apart cannot leave two sets of presenters (and their monitors) alive.
    private var rebuildGeneration = 0
    private var screenDebounce: Task<Void, Never>?
    private var pointerMonitor: Any?
    private var pointerSettle: Task<Void, Never>?
    private let awake = AwakeKeeper()
    private lazy var autoSideProbe = CompactStripProbe(store: store)
    /// Auto's watcher: idle unless the readouts are set to Auto, and never a timer (MenuBarExtent).
    private lazy var autoSide = AutoSideWatcher(prefs: prefs) { [weak self] in
        guard let self, let screen = self.presenter?.screen ?? NSScreen.main ?? NSScreen.screens.first else {
            return CompactMetrics(notch: .zero, tools: 0) { _, _ in 0 }
        }
        return CompactMetrics(notch: NotchController.notchRect(on: screen), tools: self.autoSideProbe.toolCount) {
            self.autoSideProbe.width(style: $0, tools: $1)
        }
    }

    private var smokeRestoreEdge: PanelEdge?
    private var smokeRestoreStyle: CompactStyle?
    private var smokeRestoreVisibility: NotchVisibility?
    private var smokeRestoreDisplay: DisplayChoice?
    private var smokeRestoreDetails: Bool?

    static let screenDebounceInterval: TimeInterval = 0.15
    static let pointerSettleInterval: TimeInterval = 0.5

    /// The first presenter: the one on the built-in (or chosen) display.
    var presenter: (any PanelPresenting)? { presenters.first }

    /// The presenter whose screen holds the pointer (under "All displays"), else the first.
    var pointerPresenter: (any PanelPresenting)? {
        Self.presenter(for: NSEvent.mouseLocation, among: presenters) ?? presenters.first
    }

    static func presenter(for pointer: CGPoint, among presenters: [any PanelPresenting]) -> (any PanelPresenting)? {
        presenters.first { $0.screen.frame.contains(pointer) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        // --render-assets <dir>: the README's pictures from fixture readings; no store, no provider, no panel.
        if let index = arguments.firstIndex(of: "--render-assets"), index + 1 < arguments.count {
            exit(AssetRenderer.render(into: URL(fileURLWithPath: arguments[index + 1])) ? 0 : 1)
        }
        // --render-gallery <dir>: the Product Hunt composites and thumbnail, from the same fixtures.
        if let index = arguments.firstIndex(of: "--render-gallery"), index + 1 < arguments.count {
            exit(AssetRenderer.gallery(into: URL(fileURLWithPath: arguments[index + 1])) ? 0 : 1)
        }
        if arguments.contains("--smoke"), let index = arguments.firstIndex(of: "--edge"), index + 1 < arguments.count,
           let edge = PanelEdge(rawValue: arguments[index + 1]) {
            smokeRestoreEdge = prefs.edge
            prefs.edge = edge
        }
        if arguments.contains("--smoke"), let index = arguments.firstIndex(of: "--compact-style"), index + 1 < arguments.count,
           let style = CompactStyle(rawValue: arguments[index + 1]) {
            smokeRestoreStyle = prefs.compactStyle
            prefs.compactStyle = style
        }
        if arguments.contains("--smoke"), let index = arguments.firstIndex(of: "--visibility"), index + 1 < arguments.count,
           let visibility = NotchVisibility(rawValue: arguments[index + 1]) {
            smokeRestoreVisibility = prefs.visibility
            prefs.visibility = visibility
        }
        if arguments.contains("--smoke"), let index = arguments.firstIndex(of: "--display"), index + 1 < arguments.count,
           let display = DisplayChoice(rawValue: arguments[index + 1]) {
            smokeRestoreDisplay = prefs.display
            prefs.display = display
        }
        if arguments.contains("--smoke"), let index = arguments.firstIndex(of: "--details"), index + 1 < arguments.count,
           ["on", "off"].contains(arguments[index + 1]) {
            smokeRestoreDetails = prefs.showDetails
            prefs.showDetails = arguments[index + 1] == "on"
        }
        MainMenu.install(actions: actions)
        AccessibilityDisplay.shared.reduceAnimations = prefs.reduceAnimations
        LegacyCaches.clean()
        store = UsageStore(prefs: prefs)
        store.deliverAlerts = { [weak self] alerts in
            guard let self else { return }
            self.notifier.send(alerts, context: self.store.adviceContext())
        }
        store.deliverAdvice = { [weak self] advice in self?.notifier.send(advice: advice) }
        store.deliverSessionEvent = { [weak self] event, session in self?.sessionEvent(event, session: session) }
        store.removeNotifications = { [weak self] identifiers in self?.notifier.remove(identifiers: identifiers) }
        store.awakeChanged = { [weak self] hold in
            self?.awake.apply(hold: hold)
            self?.refreshFooterNote()
        }
        notifier.sound = { [weak self] event in self?.prefs.sound(for: event) ?? NotificationSound.defaultChoice }
        notifier.quiet = { [weak self] in self?.prefs.isQuietHour() ?? false }
        notifier.onOpen = { [weak self] tool in self?.openFromNotification(tool) }
        store.start()
        actions.refresh = { [weak self] in self?.store.refreshAll(interactive: true) }
        actions.openSettings = { [weak self] in self?.showSettings() }
        actions.showOptions = { [weak self] in self?.pointerPresenter?.showOptions() }
        actions.applyLayout = { [weak self] in self?.applyLayout() }
        actions.togglePanel = { [weak self] in self?.pointerPresenter?.toggle(cause: .hotkey) }
        actions.copyPanelImage = { [weak self] in self?.copyPanelImage() }
        actions.installCommandLineTool = { [weak self] in self?.installCommandLineTool() }
        actions.chooseCompactSide = { [weak self] side in self?.autoSide.sideChosen(side) }
        requests.rootsChanged = { [weak self] in self?.store.reloadRoots() }
        requests.menuBarChanged = { [weak self] in self?.applyMenuBarItem() }
        requests.hotkeysChanged = { [weak self] in self?.registerHotkeys() }
        requests.localAPIChanged = { [weak self] in self?.applyLocalAPI() }
        requests.privacyChanged = { [weak self] in self?.applyPrivacy() }
        requests.awakeChanged = { [weak self] in self?.store.applyAwake() }
        requests.diagnostics = { [weak self] in self?.diagnostics() ?? "" }
        requests.installCommandLineTool = { [weak self] in self?.installCommandLineTool() }
        requests.updater = { [weak self] in self?.updater }
        buildPresenters()
        autoSide.refresh()
        if !CommandLine.arguments.contains("--smoke") { autoSide.askAgainIfAutoIsStranded() }
        applyMenuBarItem()
        applyPrivacy()
        applyLocalAPI()
        applyPointerFollowing()
        registerHotkeys()
        observeSettings()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screensChanged() }
        }
        Oracle.shared.emit("launched", ["version": AppInfo.version, "edge": prefs.edge.rawValue, "visibility": prefs.visibility.rawValue,
                                        "compactStyle": prefs.compactStyle.rawValue, "toolOrder": prefs.toolOrder.map(\.rawValue),
                                        "display": prefs.display.rawValue, "bundle": Bundle.main.bundlePath])
        Oracle.shared.emit("screens", ["screens": NSScreen.descriptions])
        if Oracle.shared.isActive {
            snapshotObserver = DistributedNotificationCenter.default().addObserver(forName: Oracle.snapshotNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.emitSnapshot() }
            }
        }
        // A self check reports the gate and never starts Sparkle, so a signed build's --smoke neither reaches the feed
        // nor shows an update; it never touches settings.json either.
        if arguments.contains("--smoke") {
            Task { await self.smokeTest() }
        } else {
            if let updater = Updater.start(gate: updaterGate, beta: { [weak self] in self?.prefs.betaUpdates ?? false }) {
                self.updater = updater
                actions.checkForUpdates = { updater.checkForUpdates() }
            }
            autoRepairHooks()
            if Translocation.shouldOffer(bundlePath: Bundle.main.bundlePath) {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    Translocation.offerMove()
                }
            } else if !prefs.hookOfferShown, store.isShown(.claude), HookSettings.status() == .notInstalled {
                prefs.hookOfferShown = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    self.requests.hookOffer = true
                    self.showSettings()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotkeyCenter.shared.unregisterAll()
        localAPI?.stop()
        awake.apply(hold: false)
    }

    // MARK: - Hooks

    /// A hook or status line that names an old copy of this app is rewritten at launch, after the usual backup,
    /// when the entry is provably Notchmeter's own; never from a build/ copy (the developer's own, which must not
    /// capture the user's installed one) and never under --smoke.
    private func autoRepairHooks() {
        guard prefs.autoRepairHooks, HookRepair.mayRepair(executable: HookSettings.executablePath) else { return }
        var notes: [String] = []
        if case .stale = HookSettings.status() {
            do {
                let repaired = try HookSettings.repairInstall()
                if repaired.backup != nil {
                    notes.append(L("Hook repaired"))
                    log.notice("hook repaired to this executable; backup \(repaired.backup?.lastPathComponent ?? "", privacy: .public)")
                }
            } catch {
                log.error("hook repair failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if case .stale = HookSettings.statuslineStatus() {
            do {
                let installed = try HookSettings.installStatusline()
                if installed.backup != nil {
                    notes.append(L("Status line repaired"))
                    log.notice("status line repaired to this executable")
                }
            } catch {
                log.error("status line repair failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if !notes.isEmpty {
            store.setFooterNote(notes.joined(separator: " · "))
            Oracle.shared.emit("hookRepair", ["repaired": notes])
        }
    }

    // MARK: - Session attention

    /// The notification, then the notch itself: a glance or an open, under the same quiet-hours and
    /// frontmost-terminal rule, on the presenter under the pointer.
    private func sessionEvent(_ event: Notifier.SessionEvent, session: AgentSession) {
        notifier.notify(event, session: session)
        guard prefs.sessionAttention != .nothing, !Notifier.shouldSuppress(frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, quiet: prefs.isQuietHour()),
              !isSettingsVisible, let presenter = pointerPresenter else { return }
        switch prefs.sessionAttention {
        case .glance: presenter.glance()
        case .openPanel: presenter.expandNow(cause: .notification)
        case .nothing: break
        }
    }

    // MARK: - Settings

    /// Collapses the panel first and holds it closed for as long as the window is up: the panel window spans the
    /// screen's height at a level above every other window, so Settings would otherwise open behind it. Opens on
    /// the screen the pointer is on.
    func showSettings() {
        if settings == nil {
            let controller = SettingsWindowController(store: store, prefs: prefs, actions: actions, notifier: notifier, requests: requests)
            settings = controller
            if let window = controller.window {
                settingsObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.settingsDidClose() }
                }
            }
        }
        for presenter in presenters { presenter.holdCompact(true) }
        prefs.refreshLaunchAtLogin()
        settings?.present(on: .pointerScreen, below: presenter?.hover.regions.compact, above: presenter?.window?.level)
        Oracle.shared.emit("settings", settingsFields(action: "shown"))
    }

    private func settingsDidClose() {
        for presenter in presenters { presenter.holdCompact(false) }
        Oracle.shared.emit("settings", settingsFields(action: "hidden"))
    }

    var isSettingsVisible: Bool {
        settings?.window?.isVisible ?? false
    }

    private func settingsFields(action: String) -> [String: Any] {
        var fields: [String: Any] = ["action": action, "panelState": presenter?.hover.state.rawValue as Any,
                                     "frontmostBundleId": NSWorkspace.shared.frontmostApplication?.bundleIdentifier as Any]
        if let settings, let window = settings.window {
            fields["frame"] = window.frame
            fields["level"] = window.level.rawValue
            fields["nonActivating"] = settings.isNonActivating
        }
        return fields
    }

    /// Preferences that the delegate applies: reduce animations mirrors into the display settings.
    private func observeSettings() {
        withObservationTracking {
            AccessibilityDisplay.shared.reduceAnimations = prefs.reduceAnimations
            _ = (prefs.keepAwake, prefs.keepAwakeOnBattery)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.store.applyAwake()
                self?.observeSettings()
            }
        }
    }

    /// "Keeping awake · 2 sessions", or the repair note, whichever is current.
    private func refreshFooterNote() {
        if store.keepingAwake {
            store.setFooterNote(AwakeRule.footer(working: store.sessions.working.count))
        } else if store.footerNote?.hasPrefix(L("Keeping awake")) == true {
            store.setFooterNote(nil)
        }
    }

    // MARK: - Layout

    /// Re-applies the visibility preference, or swaps every presenter when the edge or the display changed.
    func applyLayout() {
        applyPointerFollowing()
        guard presenters.map(\.screen) == chosenScreens(), presenters.allSatisfy({ $0.edge == prefs.edge || ($0.edge == .top && prefs.edge == .top) }),
              presenters.first.map({ ($0 is NotchController) == (prefs.edge == .top && $0.screen.safeAreaInsets.top > 0) }) ?? false
        else {
            rebuildPresenters()
            return
        }
        for presenter in presenters { presenter.show() }
    }

    private func chosenScreens() -> [NSScreen] {
        NSScreen.panelScreens(for: prefs.display)
    }

    /// Hides the old presenters, then builds for the newest generation only; a rebuild asked for meanwhile
    /// supersedes this one, and its own build runs when the hides are done.
    private func rebuildPresenters() {
        rebuildGeneration += 1
        let generation = rebuildGeneration
        let old = presenters
        presenters = []
        Task {
            for presenter in old { await presenter.hide() }
            guard generation == self.rebuildGeneration else { return }
            self.buildPresenters()
        }
    }

    /// One presenter per chosen screen: the notch layout on a screen with a notch, a pill under the menu bar on one
    /// without (the top layout's floating stand-in would draw nothing while closed).
    private func buildPresenters() {
        let screens = chosenScreens()
        screenKey = Self.screenKey(screens)
        presenters = screens.map { screen in
            let built: any PanelPresenting = prefs.edge == .top && screen.safeAreaInsets.top > 0
                ? NotchController(screen: screen, store: store, prefs: prefs, actions: actions)
                : EdgePanelController(edge: prefs.edge, screen: screen, store: store, prefs: prefs, actions: actions)
            return built
        }
        for presenter in presenters {
            if isSettingsVisible {
                presenter.holdCompact(true)
            } else {
                presenter.show()
            }
        }
        Oracle.shared.emit("presenters", ["screens": presenters.map(\.screen.localizedName), "generation": rebuildGeneration])
    }

    static func screenKey(_ screens: [NSScreen]) -> String {
        screens.map { "\($0.identityKey)|\($0.frame)|\($0.safeAreaInsets.top > 0)" }.joined(separator: ";")
    }

    /// A display was plugged in or out, the lid opened or closed, or mirroring changed: macOS posts several
    /// notifications for one event, so they are coalesced over 150 ms, then the screens are re-derived and the
    /// presenters rebuilt when the set, a frame or a notch changed.
    private func screensChanged() {
        Oracle.shared.emit("screens", ["screens": NSScreen.descriptions])
        screenDebounce?.cancel()
        screenDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.screenDebounceInterval))
            guard !Task.isCancelled, let self else { return }
            self.applyScreenChange()
        }
    }

    private func applyScreenChange() {
        let key = Self.screenKey(chosenScreens())
        if key != screenKey {
            rebuildPresenters()
            applyMenuBarItem()
        } else {
            for presenter in presenters { presenter.remeasure() }
        }
    }

    /// "Display with the pointer": a global mouse monitor notices the pointer crossing to another display and,
    /// once it has stayed there half a second, rebuilds onto that display.
    private func applyPointerFollowing() {
        if prefs.display == .pointer, pointerMonitor == nil {
            pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
                MainActor.assumeIsolated { self?.pointerMoved() }
            }
        } else if prefs.display != .pointer, let monitor = pointerMonitor {
            NSEvent.removeMonitor(monitor)
            pointerMonitor = nil
            pointerSettle?.cancel()
            pointerSettle = nil
        }
    }

    private func pointerMoved() {
        guard prefs.display == .pointer, let current = presenter?.screen else { return }
        let target = NSScreen.pointerScreen
        guard target != current else {
            pointerSettle?.cancel()
            pointerSettle = nil
            return
        }
        guard pointerSettle == nil else { return }
        pointerSettle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.pointerSettleInterval))
            guard !Task.isCancelled, let self else { return }
            self.pointerSettle = nil
            if NSScreen.pointerScreen != self.presenter?.screen {
                Oracle.shared.emit("screens", ["pointerMovedTo": NSScreen.pointerScreen.localizedName])
                self.rebuildPresenters()
            }
        }
    }

    private func applyMenuBarItem() {
        let shown = prefs.showMenuBarItem ?? MenuBarPolicy.defaultShown(edge: prefs.edge)
        if shown, menuBarItem == nil {
            menuBarItem = MenuBarItem(store: store, prefs: prefs, actions: actions)
        } else if !shown, let item = menuBarItem {
            item.remove()
            menuBarItem = nil
        }
        menuBarItem?.update(captured: store.hidesFigures)
    }

    private func applyPrivacy() {
        if prefs.hideFromScreenShare {
            capture.start()
            observeCapture()
        } else {
            capture.stop()
            store.setScreenCaptured(false)
        }
    }

    private func observeCapture() {
        withObservationTracking {
            store.setScreenCaptured(capture.captured)
            menuBarItem?.update(captured: store.hidesFigures)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.prefs.hideFromScreenShare else { return }
                self.observeCapture()
            }
        }
    }

    private func applyLocalAPI() {
        if prefs.localAPIEnabled {
            if localAPI == nil {
                localAPI = LocalAPI(allowedOrigins: { [weak self] in self?.prefs.localAPIOrigins ?? [] },
                                    hook: { [weak self] message in self?.store.hookReceived(message) },
                                    report: { [weak self] in self?.store.report() ?? UsageReport(tools: [:], cost: nil, advice: []) })
            }
            localAPI?.start()
        } else {
            localAPI?.stop()
            localAPI = nil
        }
    }

    private func registerHotkeys() {
        for id in hotkeyIDs { HotkeyCenter.shared.unregister(id) }
        hotkeyIDs = []
        if let hotkey = prefs.togglePanelHotkey, let id = HotkeyCenter.shared.register(hotkey, action: { [weak self] in self?.pointerPresenter?.toggle(cause: .hotkey) }) {
            hotkeyIDs.append(id)
        }
        if let hotkey = prefs.openSettingsHotkey, let id = HotkeyCenter.shared.register(hotkey, action: { [weak self] in self?.showSettings() }) {
            hotkeyIDs.append(id)
        }
    }

    private func openFromNotification(_ tool: ToolID?) {
        if tool == nil {
            showSettings()
        } else {
            pointerPresenter?.expandNow(cause: .notification)
        }
    }

    private func copyPanelImage() {
        CardImage.copy(NotchExpandedView(store: store, prefs: prefs, actions: actions, maxHeight: 10_000), width: prefs.panelWidth.points + 24)
    }

    private func installCommandLineTool() {
        do {
            let link = try CommandLineTool.install(executable: HookSettings.executablePath)
            let onPath = CommandLineTool.isOnPath(link.deletingLastPathComponent())
            requests.commandLineToolMessage = onPath
                ? L("Installed at %@.", link.path.replacingOccurrences(of: Paths.home.path, with: "~"))
                : L("Installed at %1$@. Add %2$@ to your PATH to use it as `notchmeter`.", link.path.replacingOccurrences(of: Paths.home.path, with: "~"),
                    link.deletingLastPathComponent().path.replacingOccurrences(of: Paths.home.path, with: "~"))
            log.notice("command line tool linked at \(link.path, privacy: .public)")
        } catch {
            requests.commandLineToolMessage = L("Could not install the command line tool: %@", error.localizedDescription)
        }
    }

    /// "Copy diagnostics": everything Diagnostics gathers, from this delegate's state.
    private func diagnostics() -> String {
        var facts = Diagnostics.Facts()
        facts.edge = prefs.edge.rawValue
        facts.display = prefs.display.rawValue
        facts.visibility = prefs.visibility.rawValue
        facts.screens = NSScreen.descriptions.map { "\($0["name"] ?? "") frame=\($0["frame"] ?? "") notch=\($0["notch"] ?? "") main=\($0["isMain"] ?? "")" }
        facts.tools = ToolID.allCases.map { ($0.displayName, Probe.describe(store.status($0)).replacingOccurrences(of: "\n", with: " ")) }
        facts.hook = HookSettings.status().text
        facts.statusline = HookSettings.statuslineStatus().text
        facts.localAPI = localAPI?.isRunning == true
        facts.debugLogging = prefs.debugLogging
        return Diagnostics.report(facts, log: Diagnostics.recentLog())
    }

    // MARK: - Oracle

    /// Everything a tester could otherwise only see, in one line, on the distributed notification
    /// com.amirhackett.notchmeter.oracle.snapshot.
    private func emitSnapshot() {
        var fields: [String: Any] = [
            "edge": prefs.edge.rawValue, "visibility": prefs.visibility.rawValue, "compactStyle": prefs.compactStyle.rawValue,
            "usageDisplay": prefs.usageDisplay.rawValue, "toolOrder": prefs.toolOrder.map(\.rawValue),
            "enabledTools": prefs.enabledTools.map(\.rawValue).sorted(), "showSpend": prefs.showSpend, "display": prefs.display.rawValue,
            "visibleTools": store.visibleTools.map(\.rawValue), "presence": String(describing: store.presence),
            "costCard": ["carried": store.costSelection.providers.map(\.tool.rawValue),
                         "leads": store.costSelection.providers.first?.tool.rawValue as Any,
                         "gaps": store.costGaps.map { ["tool": $0.tool.rawValue, "reason": $0.text] }],
            "awaitingInput": store.awaitingInput.map(\.rawValue).sorted(), "sessions": store.sessions.count,
            "readings": ToolID.allCases.map { Oracle.fields($0, store.status($0)) },
            "advice": store.advice.map(\.text),
            "settingsVisible": isSettingsVisible,
            "screens": NSScreen.descriptions,
            "captured": store.screenCaptured,
            "presenters": presenters.map(\.screen.localizedName),
            "keepingAwake": store.keepingAwake,
        ]
        if let presenter {
            fields["panelState"] = presenter.hover.state.rawValue
            fields["panelVisible"] = presenter.isVisible
            fields["regions"] = ["compact": presenter.hover.regions.compact, "expanded": presenter.hover.regions.expanded]
            fields["panelScreen"] = presenter.screen.localizedName
            fields["panelScroll"] = presenter.scrollPosition?.fields as Any
        }
        if let window = settings?.window, window.isVisible {
            fields["settingsFrame"] = window.frame
        }
        Oracle.shared.emit("snapshot", fields)
    }

    // MARK: - Smoke

    /// `--smoke`: run for a few seconds, report what is on screen and what each provider returned, then exit.
    /// `--hover-sim` adds a scripted pointer path through the live hover machine and fails the run if it loops;
    /// `--hover-log` prints each decision the real mouse produces meanwhile; `--edge`, `--compact-style`,
    /// `--visibility`, `--display` and `--details on|off` pick the layout for the run and are restored on exit; `--idle-sim` runs the
    /// Hide when idle clock 31 minutes ahead; `--glance-sim` opens a glance and checks it settles. Two simulated
    /// screen changes are fired back to back on every run and the presenter count checked after; the Options menu
    /// is built and walked without a pointer. The copy line names the language the panel is in and shows five of
    /// its strings, so `--lang zh-Hans` can be seen to take.
    private func smokeTest() async {
        let started = Date()
        if CommandLine.arguments.contains("--hover-log") {
            presenter?.hover.log = { line in Probe.emit("hover \(String(format: "%6.3f", Date().timeIntervalSince(started))) \(line)") }
        }
        try? await Task.sleep(for: .seconds(8))
        var hoverPassed = true
        if CommandLine.arguments.contains("--hover-sim"), let presenter {
            hoverPassed = await HoverSimulation(hover: presenter.hover).run()
        }
        while store.cost == nil, Date().timeIntervalSince(started) < 90 {
            try? await Task.sleep(for: .seconds(2))
        }
        Probe.emit("smoke ran \(Int(Date().timeIntervalSince(started)))s")
        Probe.emit(Translocation.describe(bundlePath: Bundle.main.bundlePath))
        for screen in NSScreen.descriptions {
            Probe.emit("screen \(screen["name"] ?? "") [\(screen["key"] ?? "")]: frame=\(screen["frame"] ?? "") visible=\(screen["visibleFrame"] ?? "") notch=\(screen["notch"] ?? "") main=\(screen["isMain"] ?? "") primary=\(screen["isPrimary"] ?? "") keyWindow=\(screen["hasKeyWindow"] ?? "")")
        }
        Probe.emit("chrome: menu bar auto-hides=\(SystemChrome.menuBarAutoHides) dock auto-hides=\(SystemChrome.dockAutoHides) dock side=\(SystemChrome.dockOrientation) stage manager=\(SystemChrome.stageManagerEnabled) strip auto-hides=\(SystemChrome.stageManagerStripAutoHides); low power mode=\(PowerSource.lowPowerMode()); accessibility \(AccessibilityDisplay.shared.description)")
        Probe.emit("display: \(prefs.display.rawValue) → \(presenters.map { "\($0.screen.localizedName) (\(type(of: $0)))" }.joined(separator: ", ")); pointer on \(NSScreen.pointerScreen.localizedName); chosen for the pointer: \(pointerPresenter?.screen.localizedName ?? "none")")
        let frame = presenter?.window.map { "\($0.frame)" } ?? "none"
        Probe.emit("panel (\(prefs.edge.rawValue)): visible=\(presenter?.isVisible ?? false) frame=\(frame)")
        if let window = presenter?.window {
            Probe.emit("window: level=\(window.level.rawValue) fullScreenAuxiliary=\(window.collectionBehavior.contains(.fullScreenAuxiliary)) onActiveSpace=\(window.isOnActiveSpace) (show over full-screen apps=\(prefs.showOverFullScreenApps))")
        }
        if let regions = presenter?.hover.regions {
            Probe.emit("hover regions: compact=\(regions.compact) expanded=\(regions.expanded)")
        }
        Probe.emit("hover: mode=\(String(describing: presenter?.hover.mode)) delay=\(prefs.hoverDelay)s gestures=\(presenter?.hover.gestures ?? false)")
        let sizingPassed = presenter.map(reportSizing) ?? false
        reportCompactStyles()
        reportRings()
        reportIdle()
        let glancePassed = await reportGlance()
        let keyPassed = await reportClickKey()
        let menuPassed = reportMenu()
        let rebuildPassed = await reportRebuild()
        for tool in ToolID.allCases {
            Probe.emit("\(tool.displayName): \(Probe.describe(store.status(tool)))")
        }
        Probe.emit("tool order: \(prefs.toolOrder.map(\.rawValue).joined(separator: ", ")); visible: \(store.visibleTools.map(\.rawValue).joined(separator: ", "))")
        Probe.emit("polling: \(store.scheduleDescription())")
        Probe.emit("presence: \(store.presence); sessions: \(store.sessions.count) (\(store.sessions.agentCount) agents); reduce motion: \(AccessibilityDisplay.shared.motionReduced); keep awake: \(prefs.keepAwake) holding=\(store.keepingAwake)")
        if let cost = store.cost {
            Probe.emit(Probe.describe(cost))
        } else {
            Probe.emit("cost: still scanning")
        }
        let costCardPassed = reportCostCard()
        let scrollPassed = await reportScroll()
        Probe.emit(Probe.describe(store.advice))
        Probe.emit("notifications: \(prefs.notificationsEnabled ? "on" : "off") in settings, \(notifier.isAvailable ? "available" : "no-op in this run"); session attention: \(prefs.sessionAttention.rawValue); keychain prompts: \(prefs.keychainPrompts.rawValue)")
        Probe.emit("updater: \(updaterGate.summary); never started under --smoke")
        Probe.emit("menu bar item: \(menuBarItem == nil ? "off" : "on") style=\(prefs.menuBarStyle.rawValue); local API: \(localAPI?.isRunning == true ? "on" : "off"); privacy probe: \(ScreenCapture.probeName) captured=\(ScreenCapture.isCaptured()); proxy: \(prefs.proxyURL.isEmpty ? "system" : prefs.proxyURL)")
        Probe.emit("hooks: \(HookSettings.status().text); status line: \(HookSettings.statuslineStatus().text); auto-repair: \(prefs.autoRepairHooks) (never under --smoke); command line tool: \(CommandLineTool.installedLink().map { "\($0.link.path) → \($0.destination)" } ?? "not installed")")
        Probe.emit("main menu: \(MainMenu.describe())")
        Probe.emit("readouts: \(autoSide.description)")
        Probe.emit("copy (\(Localization.current)): \(L("Session")) · \(L("Weekly")) · \(L("%@ Settings", AppInfo.name)) · "
                   + "\(L("Resets in %@", ResetText.duration(4 * 3600 + 17 * 60))) · \(L("Open at login"))")
        let settingsPassed = await smokeSettings()
        if Oracle.shared.isActive {
            DistributedNotificationCenter.default().postNotificationName(Oracle.snapshotNotification, object: nil, userInfo: nil, deliverImmediately: true)
            try? await Task.sleep(for: .seconds(1))
            Probe.emit("oracle: \(Oracle.shared.count) lines written")
        }
        if let smokeRestoreEdge { prefs.edge = smokeRestoreEdge }
        if let smokeRestoreStyle { prefs.compactStyle = smokeRestoreStyle }
        if let smokeRestoreVisibility { prefs.visibility = smokeRestoreVisibility }
        if let smokeRestoreDisplay { prefs.display = smokeRestoreDisplay }
        if let smokeRestoreDetails { prefs.showDetails = smokeRestoreDetails }
        let checks: [(String, Bool)] = [("panel visible", presenter?.isVisible == true), ("hover", hoverPassed),
                                        ("sizing", sizingPassed), ("settings", settingsPassed), ("glance", glancePassed),
                                        ("click-to-key", keyPassed), ("menu", menuPassed), ("rebuild", rebuildPassed),
                                        ("cost card", costCardPassed), ("panel scroll", scrollPassed)]
        let failed = checks.filter { !$0.1 }.map(\.0)
        Probe.emit("self check: \(checks.count - failed.count)/\(checks.count) passed"
                   + (failed.isEmpty ? "" : "; failed: \(failed.joined(separator: ", "))"))
        exit(failed.isEmpty ? 0 : 1)
    }

    /// The open panel must fit where it is drawn: inside DynamicNotchKit's fixed window for the top layout, inside
    /// the screen's usable height for the edge pills, which size their window to the content. Content taller than
    /// the cap scrolls instead of being clipped, so the natural height is printed but only the drawn one is a
    /// verdict. The top window is mostly transparent, so a hit test below the panel also confirms that area still
    /// reaches whatever is under it.
    private func reportSizing(_ presenter: any PanelPresenting) -> Bool {
        let screen = presenter.screen
        let content = presenter.expandedContentSize
        let natural = presenter.expandedIntrinsicContentSize
        let cap = NotchExpandedView.maxHeight(on: screen)
        let notchLayout = presenter is NotchController
        let room = notchLayout ? (presenter.window?.frame.height ?? 0) : screen.visibleFrame.height
        let roomName = notchLayout ? "window height" : "usable screen height"
        let fit = NotchExpandedView.Fit.of(drawn: content.height, natural: natural.height, room: room, cap: cap)
        var passed = fit.holds
        Probe.emit("panel sizing: \(roomName)=\(room) drawn content height=\(content.height) natural height=\(natural.height) width=\(content.width) "
                   + "(density=\(prefs.density.rawValue), panel width=\(prefs.panelWidth.rawValue)) max content height=\(cap) → \(fit == .clipped ? "CLIPPED" : fit.rawValue)")
        if notchLayout, let window = presenter.window {
            let below = NSPoint(x: window.frame.midX, y: window.frame.minY + 20)
            let hit = NSWindow.windowNumber(at: below, belowWindowWithWindowNumber: 0)
            let clickThrough = hit != window.windowNumber
            passed = passed && clickThrough
            Probe.emit("panel window: opaque=\(window.isOpaque) click-through below the panel=\(clickThrough)")
        }
        return passed
    }

    /// The compact shape the hover machine uses, measured for each style, and once more with the reset countdown
    /// on; the run's own settings are restored after.
    private func reportCompactStyles() {
        guard let presenter else { return }
        let current = prefs.compactStyle
        let countdown = prefs.showResetCountdown
        for style in CompactStyle.allCases {
            prefs.compactStyle = style
            prefs.showResetCountdown = false
            presenter.remeasure()
            let compact = presenter.hover.regions.compact
            Probe.emit("compact style \(style.rawValue): compact region \(Int(compact.width.rounded())) × \(Int(compact.height.rounded())) pt at (\(Int(compact.minX)), \(Int(compact.minY)))")
            if style.showsNumbers {
                prefs.showResetCountdown = true
                presenter.remeasure()
                let widened = presenter.hover.regions.compact
                Probe.emit("compact style \(style.rawValue) + countdown: compact region \(Int(widened.width.rounded())) × \(Int(widened.height.rounded())) pt")
            }
        }
        prefs.compactStyle = current
        prefs.showResetCountdown = countdown
        presenter.remeasure()
    }

    /// Two rings against three. The hover region follows the compact view's fitting size, so a third window has to
    /// widen the strip rather than being drawn outside the area the pointer finds. Measured in the style that
    /// carries digits, which is where a third window costs width; every preference touched here is put back.
    private func reportRings() {
        guard let presenter else { return }
        let style = prefs.compactStyle
        let chosen = prefs.ringWindows
        let revealed = prefs.revealedWindows
        let hidden = prefs.hiddenWindows
        prefs.compactStyle = .ringsAndNumbers
        presenter.remeasure()
        let two = presenter.hover.regions.compact
        var applied: [String] = []
        for tool in store.visibleTools {
            guard let reading = store.status(tool).reading else { continue }
            for window in reading.windows where prefs.isHidden(window, of: tool) { prefs.setHidden(false, window: window, of: tool) }
            let ids = prefs.panelWindows(of: reading).prefix(RingSelection.maximum).map(\.id)
            guard ids.count == RingSelection.maximum else { continue }
            prefs.ringWindows[tool] = ids
            applied.append("\(tool.rawValue) \(ids.joined(separator: "+"))")
        }
        presenter.remeasure()
        let three = presenter.hover.regions.compact
        Probe.emit("three rings: \(applied.isEmpty ? "no tool published three windows to draw" : applied.joined(separator: ", "))"
                   + "; compact region \(Int(two.width.rounded())) → \(Int(three.width.rounded())) pt wide")
        prefs.compactStyle = style
        prefs.ringWindows = chosen
        prefs.revealedWindows = revealed
        prefs.hiddenWindows = hidden
        presenter.remeasure()
    }

    /// `--idle-sim`: the Hide when idle rule with the clock 31 minutes ahead, then restored.
    private func reportIdle() {
        guard CommandLine.arguments.contains("--idle-sim") else { return }
        let visibility = prefs.visibility
        prefs.visibility = .hideWhenIdle
        store.simulateIdle(minutes: 31)
        Probe.emit("idle-sim: 31 min idle under Hide when idle → presence \(store.presence)")
        store.simulateIdle(minutes: 0)
        Probe.emit("idle-sim: activity just now → presence \(store.presence)")
        store.simulateIdle(minutes: nil)
        prefs.visibility = visibility
        Probe.emit("idle-sim rule: quiet + 31 min idle → hidden=\(Presence.hides(level: .quiet, idleFor: 31 * 60, wokeAgo: nil)); quiet + activity now → hidden=\(Presence.hides(level: .quiet, idleFor: 0, wokeAgo: nil)); pointer rested → hidden=\(Presence.hides(level: .quiet, idleFor: 31 * 60, wokeAgo: 5))")
    }

    /// The glance rule on the pure machine every run, and with `--glance-sim` a real one through the presenter: the
    /// panel must be open half a second in and closed again after the glance has passed.
    private func reportGlance() async -> Bool {
        var intent = HoverIntent(mode: .onHover)
        let opened = intent.glance(at: 0) == .expand
        let stays = intent.pointer(inCompact: false, inExpanded: false, at: 1) == .none
        let settles = intent.pointer(inCompact: false, inExpanded: false, at: HoverIntent.glanceDuration + 0.1) == .collapse
        var kept = HoverIntent(mode: .onHover)
        _ = kept.glance(at: 0)
        _ = kept.pointer(inCompact: false, inExpanded: true, at: 1)
        let keeps = kept.pointer(inCompact: false, inExpanded: true, at: HoverIntent.glanceDuration + 1) == .none && !kept.isGlancing
        Probe.emit("glance rule: opens=\(opened) stays 1s in=\(stays) settles after \(Int(HoverIntent.glanceDuration))s=\(settles) pointer inside keeps it open=\(keeps)")
        var passed = opened && stays && settles && keeps
        guard CommandLine.arguments.contains("--glance-sim"), let presenter, prefs.visibility != .always else { return passed }
        presenter.glance()
        try? await Task.sleep(for: .seconds(0.6))
        let open = presenter.hover.state == .expanded
        try? await Task.sleep(for: .seconds(HoverIntent.glanceDuration + 1.5))
        let closed = presenter.hover.state == .compact
        Probe.emit("glance-sim: open after 0.6s=\(open) closed after \(Int(HoverIntent.glanceDuration) + 2)s=\(closed)")
        passed = passed && open && closed
        return passed
    }

    /// Under `--visibility onClick`, a simulated click on the rings must open the panel and make its window key,
    /// and the collapse must give the keyboard back.
    private func reportClickKey() async -> Bool {
        guard prefs.visibility == .onClick, let presenter else { return true }
        let compact = presenter.hover.regions.compact
        presenter.hover.clicked(at: CGPoint(x: compact.midX, y: compact.midY))
        try? await Task.sleep(for: .seconds(0.8))
        let opened = presenter.hover.state == .expanded
        let key = presenter.window?.isKeyWindow ?? false
        presenter.hover.escape()
        try? await Task.sleep(for: .seconds(0.8))
        let closed = presenter.hover.state == .compact
        let released = !(presenter.window?.isKeyWindow ?? false)
        Probe.emit("click key: opened=\(opened) key window after click=\(key) Escape closes=\(closed) key released=\(released)")
        return opened && key && closed && released
    }

    /// The Cost card's own order, which a tester cannot see: which assistants it carries, which one leads it (the
    /// detail block under the legend is that one's), and which carried assistants had nothing to show and why.
    /// The verdict is that the card follows the same order as the cards below it — reordering an assistant under
    /// Settings has to move it on the Cost card too, or the card and the panel disagree about who is first.
    private func reportCostCard() -> Bool {
        let carried = store.costSelection.providers.map(\.tool)
        let leads = carried.first
        let gaps = store.costGaps
        var remaining = store.visibleTools[...]
        let follows = carried.allSatisfy { tool in
            guard let index = remaining.firstIndex(of: tool) else { return false }
            remaining = remaining[remaining.index(after: index)...]
            return true
        }
        Probe.emit("cost card: leads \(leads?.rawValue ?? "nobody") · carries \(carried.map(\.rawValue).joined(separator: ", "))"
                   + " of \(prefs.costCardTools.map(\.rawValue).sorted().joined(separator: ", "))"
                   + "; panel order \(store.visibleTools.map(\.rawValue).joined(separator: ", ")) → follows=\(follows)"
                   + (gaps.isEmpty ? "" : "; nothing to show: \(gaps.map(\.text).joined(separator: " · "))"))
        return follows
    }

    /// Where a reopened panel is scrolled to, which nothing on the screen spells out. The panel is a readout and
    /// not a document, so every opening starts at the Cost card with its title clear of the notch rather than
    /// where the last look left it (NotchExpandedView's scroll anchor). The panel is opened, scrolled down,
    /// closed and opened again, and its position read from the live scroll view at each step. Where an opening
    /// lands is SwiftUI's to decide, so the verdicts compare readings rather than assume a number: the scroll has
    /// to move the panel off where it opened, the reopen has to put it back there, and the first card's title has
    /// to sit below the notch's bottom edge.
    private func reportScroll() async -> Bool {
        guard let presenter else { return false }
        let wasExpanded = presenter.hover.state == .expanded
        presenter.expandNow(cause: .hotkey)
        try? await Task.sleep(for: .seconds(1.2))
        guard let opened = presenter.scrollPosition else {
            Probe.emit("panel scroll: the open panel's window has no scroll view to read: \(presenter.scroll.hierarchy)")
            return false
        }
        var away: Bool?
        if opened.overflows {
            presenter.scroll.scrollDown(by: 200)
            // Read after a beat rather than at once: a position SwiftUI puts back on its next layout pass is no
            // scroll at all, and then the reopen has nothing to undo and its verdict is worth nothing.
            try? await Task.sleep(for: .seconds(0.4))
            away = presenter.scrollPosition.map { !$0.isAt(opened) }
        }
        presenter.toggle(cause: .hotkey)
        try? await Task.sleep(for: .seconds(1))
        let closed = presenter.scrollPosition
        presenter.expandNow(cause: .hotkey)
        try? await Task.sleep(for: .seconds(1.2))
        let reopened = presenter.scrollPosition
        let back = reopened?.isAt(opened) ?? false
        let clear = reopened?.clearsNotch ?? true
        Probe.emit("panel scroll: opened \(opened.text)"
                   + "; scrolled off it=\(away.map(String.init(describing:)) ?? "nothing to scroll")"
                   + "; while closed=\(closed.map(\.text) ?? "no scroll view in the window")"
                   + "; reopened \(reopened?.text ?? "no scroll view") → back where it opened=\(back)")
        if !wasExpanded { presenter.toggle(cause: .hotkey) }
        return back && clear && (away ?? true)
    }

    /// The Options menu a secondary click puts up, built and walked without a pointer: every command carries a
    /// target that implements its selector, the three settings groups carry one item per case with exactly one
    /// tick on the current one, and Settings… and Quit keep the key equivalents the menu-driven routes rely on.
    /// It cannot show the menu or dismiss it — NSMenu owns that — so it checks everything up to the point where
    /// AppKit takes over.
    private func reportMenu() -> Bool {
        // NSMenuItem.target is weak, as is NSMenu.delegate: the menu is only as alive as whoever holds the
        // OptionsMenu. The controllers hold theirs in a stored property; this one has to be held here.
        let options = OptionsMenu(prefs: prefs, actions: actions)
        defer { withExtendedLifetime(options) {} }
        let items = options.build().items.filter { !$0.isSeparatorItem }
        Probe.emit("menu: \(items.map { $0.submenu == nil ? $0.title : "\($0.title) ▸" }.joined(separator: " · "))")
        let dead = items.filter { $0.submenu == nil }.filter { item in
            guard let action = item.action, let target = item.target as? NSObject else { return true }
            return !target.responds(to: action)
        }
        let untitled = items.filter { $0.title.isEmpty }
        let deadNames = dead.isEmpty ? "" : ": " + dead.map(\.title).joined(separator: ", ")
        Probe.emit("menu wiring: \(items.count) items, \(untitled.count) untitled, "
                   + "\(dead.count) without a target that answers their selector\(deadNames)")

        func submenu(_ expected: [String]) -> [NSMenuItem] {
            items.compactMap(\.submenu).first { $0.items.compactMap { $0.representedObject as? String } == expected }?.items ?? []
        }
        func check(_ label: String, _ group: [NSMenuItem], _ expected: [String], current: String) -> Bool {
            let found = group.compactMap { $0.representedObject as? String }
            let ticked = group.filter { $0.state == .on }.compactMap { $0.representedObject as? String }
            let passed = found == expected && ticked == [current]
            Probe.emit("menu \(label): \(found.joined(separator: ", ")) ticked=\(ticked.joined(separator: ", ")) setting=\(current) → \(passed ? "OK" : "MISMATCH")")
            return passed
        }
        let visibilities = NotchVisibility.allCases.map(\.rawValue)
        let visibility = check("visibility", items.filter { ($0.representedObject as? String).map(visibilities.contains) == true },
                               visibilities, current: prefs.visibility.rawValue)
        let position = check("position", submenu(PanelEdge.allCases.map(\.rawValue)), PanelEdge.allCases.map(\.rawValue), current: prefs.edge.rawValue)
        let style = check("compact style", submenu(CompactStyle.allCases.map(\.rawValue)), CompactStyle.allCases.map(\.rawValue), current: prefs.compactStyle.rawValue)

        func shortcut(_ key: String) -> NSMenuItem? {
            items.first { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == .command }
        }
        let settings = shortcut(",")
        let quit = shortcut("q")
        Probe.emit("menu shortcuts: ⌘, = \(settings?.title ?? "none"); ⌘Q = \(quit?.title ?? "none")")
        return dead.isEmpty && untitled.isEmpty && visibility && position && style && settings != nil && quit != nil
    }

    /// Two screen-change notifications back to back must leave exactly one presenter per chosen screen and no
    /// leaked pointer monitors (a leaked presenter would still answer with its own regions).
    private func reportRebuild() async -> Bool {
        let before = presenters.count
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        screenKey = ""
        applyScreenChange()
        applyScreenChange()
        try? await Task.sleep(for: .seconds(2))
        let expected = chosenScreens().count
        let passed = presenters.count == expected && presenters.allSatisfy { $0.isVisible }
        Probe.emit("rebuild: presenters before=\(before) after two simulated screen changes=\(presenters.count) expected=\(expected) generation=\(rebuildGeneration) → \(passed ? "one per screen" : "MISMATCH")")
        return passed
    }

    /// Opens Settings the way the menu does and checks what the user reported: a non-activating window ordered
    /// above the panel's own level and clear of the collapsed panel, with someone else's app still frontmost;
    /// closing it puts the panel back the way the visibility preference wants it. The hook-install sheet is
    /// driven against a scratch file so the alert is seen to attach to the window without touching settings.json.
    private func smokeSettings() async -> Bool {
        showSettings()
        try? await Task.sleep(for: .seconds(1))
        guard let settings, let window = settings.window, let presenter else {
            Probe.emit("settings window: not created")
            return false
        }
        let ours = Bundle.main.bundleIdentifier ?? "com.amirhackett.notchmeter"
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
        let state = presenter.hover.state
        let shape = state == .expanded ? presenter.hover.regions.expanded : presenter.hover.regions.compact
        let intersects = window.frame.intersects(shape)
        let panelLevel = presenter.window?.level ?? .normal
        let ordered = window.level.rawValue > panelLevel.rawValue && window.level.rawValue >= NSWindow.Level.floating.rawValue
        Probe.emit("settings window: level=\(window.level.rawValue) panel level=\(panelLevel.rawValue) (above=\(ordered)) frame=\(window.frame) "
                   + "nonActivating=\(settings.isNonActivating) visible=\(window.isVisible) key=\(window.isKeyWindow) "
                   + "(key window: \(NSApp.keyWindow.map { $0.title.isEmpty ? "the panel" : $0.title } ?? "none"))")
        Probe.emit("settings: frontmost=\(frontmost) panel=\(state.rawValue) intersects=\(intersects)")
        var passed = ordered && settings.isNonActivating && window.isVisible && frontmost != ours
            && state == .compact && !intersects
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-smoke-\(UUID().uuidString)/settings.json")
        requests.hookSheetDryRun = scratch
        try? await Task.sleep(for: .seconds(2))
        Probe.emit("hook dry run: wrote \(FileManager.default.fileExists(atPath: scratch.path)) at a scratch path; settings.json untouched")
        try? FileManager.default.removeItem(at: scratch.deletingLastPathComponent())
        settings.close()
        try? await Task.sleep(for: .seconds(1))
        let wanted: HoverIntent.State = prefs.visibility == .always ? .expanded : .compact
        let restored = presenter.hover.state == wanted && !(settings.window?.isVisible ?? false)
        Probe.emit("settings closed: panel=\(presenter.hover.state.rawValue) visibility=\(prefs.visibility.rawValue) → \(restored ? "restored" : "NOT restored")")
        passed = passed && restored
        return passed
    }
}

/// Whether the launch-time hook repair may run: only for a copy outside a build folder (the developer's own
/// `build/Notchmeter.app` or `.build/` must never capture the installed hook) and never under `--smoke`.
enum HookRepair {
    static func mayRepair(executable: String, arguments: [String] = CommandLine.arguments) -> Bool {
        guard !arguments.contains("--smoke"), !arguments.contains("--render-assets"), !arguments.contains("--render-gallery") else { return false }
        return !executable.contains("/build/") && !executable.contains("/.build/")
    }
}

/// Builds before the network session became ephemeral (2026-09-02) left a URL cache and cookie jar under the bundle
/// identifier; cleared once at launch, since nothing writes there any more.
enum LegacyCaches {
    static func paths(home: URL = Paths.home, bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.amirhackett.notchmeter") -> [URL] {
        [home.appendingPathComponent("Library/Caches/\(bundleIdentifier)"),
         home.appendingPathComponent("Library/HTTPStorages/\(bundleIdentifier)"),
         home.appendingPathComponent("Library/HTTPStorages/\(bundleIdentifier).binarycookies")]
    }

    static func clean() {
        let fm = FileManager.default
        for url in paths() where fm.fileExists(atPath: url.path) {
            if (try? fm.removeItem(at: url)) != nil { log.notice("removed the legacy cache at \(url.lastPathComponent, privacy: .public)") }
        }
    }
}

/// A minimal main menu built in code: AppKit dispatches key equivalents through it, so ⌘, ⌘Q, ⌘W and the Edit
/// menu's Cut, Copy, Paste and Select All work in Settings and in the panel of an app that has no other menu.
@MainActor
enum MainMenu {
    static func install(actions: NotchActions) {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu(title: AppInfo.name)
        let settings = NSMenuItem(title: L("Settings…"), action: #selector(MenuTarget.openSettings), keyEquivalent: ",")
        settings.target = MenuTarget.shared
        app.addItem(settings)
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: L("Quit %@", AppInfo.name), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = app
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: L("Edit"))
        edit.addItem(NSMenuItem(title: L("Undo"), action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: L("Redo"), action: Selector(("redo:")), keyEquivalent: "Z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: L("Window"))
        window.addItem(NSMenuItem(title: L("Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.mainMenu = main
        MenuTarget.shared.actions = actions
    }

    /// For `--smoke`: which key equivalents the main menu resolves.
    static func describe() -> String {
        guard let main = NSApp.mainMenu else { return "none" }
        let keys = main.items.flatMap { $0.submenu?.items ?? [] }.filter { !$0.keyEquivalent.isEmpty }
            .map { "⌘\($0.keyEquivalent.uppercased())=\($0.title)" }
        return keys.joined(separator: ", ")
    }
}

@MainActor
final class MenuTarget: NSObject {
    static let shared = MenuTarget()
    var actions: NotchActions?

    @objc func openSettings() {
        actions?.openSettings()
    }
}

/// `--probe`: read every provider once from the command line and print the parsed numbers, or with `--json` the
/// versioned object of UsageReport with a Claude-Code-Usage-Monitor-style exit code (`--history` adds the daily
/// rows). Tokens are never printed. `gather()` is the same read for the command-line tool and the MCP server.
enum Probe {
    static func run(json: Bool = false, history: Bool = false) {
        if !json { emit("\(AppInfo.name) probe: reads usage from tools signed in on this Mac; tokens are never printed.") }
        Task.detached {
            let report = await gather(verbose: !json, history: history)
            if json {
                FileHandle.standardOutput.write(report.json)
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else {
                emit(describe(report))
                emit("exit code \(report.exitCode.rawValue) (0 ok, 10 near a limit, 11 limit hit, 20 nothing used, 30 no data)")
            }
            exit(report.exitCode.rawValue)
        }
        RunLoop.main.run()
    }

    /// One read per signed-in tool, the transcript scan, the drain log and the advice, as a report.
    static func gather(verbose: Bool = false, history: Bool = false) async -> UsageReport {
        var readings: [UsageReading] = []
        var statuses: [ToolID: ToolStatus] = [:]
        let defaults = UserDefaults.standard
        for provider in ProviderRegistry.all(defaults: defaults) {
            let name = provider.tool.displayName
            guard provider.isInstalled() else {
                if verbose { emit("\(name): not installed") }
                statuses[provider.tool] = .notInstalled
                continue
            }
            if verbose { emit("\(name): reading…") }
            do {
                let reading = try await provider.fetch()
                readings.append(reading)
                statuses[provider.tool] = .ready(reading)
                if verbose { emit(describe(reading)) }
            } catch let error as ProviderError {
                statuses[provider.tool] = error.needsAttention ? .needsAttention(error.message, cached: nil) : error.isCalm ? .idle(error.message) : .failed(error.message, cached: nil)
                if verbose { emit("\(name): \(error.message)") }
            } catch {
                statuses[provider.tool] = .failed(error.localizedDescription, cached: nil)
                if verbose { emit("\(name): \(error.localizedDescription)") }
            }
        }
        if verbose { emit("Claude Code cost: pricing local transcripts…") }
        let claude = readings.first { $0.tool == .claude }
        let weekly = claude?.windows.first { $0.id == "seven_day" }
        let session = claude?.windows.first { $0.id == "five_hour" }
        let scanner = ClaudeCostScanner()
        let cost = await scanner.scan(weeklyResetsAt: weekly?.resetsAt, weeklyUsed: weekly?.usedFraction, sessionResetsAt: session?.resetsAt, sessionUsed: session?.usedFraction)
        let now = Date()
        let samples = DrainLog().load(now: now)
        var drains: [DrainLog.Key: Drain] = [:]
        var runOuts: [DrainLog.Key: RunOutInterval] = [:]
        for (key, rows) in samples {
            if let drain = DrainLog.drain(rows, now: now) { drains[key] = drain }
            if let window = readings.first(where: { $0.tool == key.tool })?.windows.first(where: { $0.id == key.window }), let used = window.usedFraction, let resetsAt = window.resetsAt,
               let interval = RunOutInterval.estimate(samples: rows, usedFraction: used, resetsAt: resetsAt, now: now) {
                runOuts[key] = interval
            }
        }
        let rates = drains.reduce(into: [String: Double]()) { if let rate = $1.value.perHour { $0["\($1.key.tool.rawValue)/\($1.key.window)"] = rate } }
        var context = Advisor.Context(readings: readings, cost: cost, drainRates: rates, now: now)
        context.runOuts = runOuts.reduce(into: [:]) { $0["\($1.key.tool.rawValue)/\($1.key.window)"] = $1.value }
        context.monthlyBudgetUSD = defaults.object(forKey: "monthlyBudgetUSD") as? Double
        context.weeklyBudgetUSD = defaults.object(forKey: "weeklyBudgetUSD") as? Double
        context.metering = cost.sessionMetering
        let advice = Advisor.advise(context)
        return UsageReport(tools: statuses, cost: cost, advice: advice, drains: drains, runOuts: runOuts, history: history ? scanner.history?.load() : nil, now: now)
    }

    /// Unbuffered so lines survive even if the process is killed mid-way.
    static func emit(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    static func describe(_ report: UsageReport) -> String {
        var lines: [String] = []
        for tool in report.order {
            guard let status = report.tools[tool] else { continue }
            if case .ready = status { continue }
            lines.append("\(tool.displayName): \(describe(status))")
        }
        if let cost = report.cost { lines.append(describe(cost)) }
        for (key, drain) in report.drains.sorted(by: { "\($0.key.tool.rawValue)/\($0.key.window)" < "\($1.key.tool.rawValue)/\($1.key.window)" }) {
            var line = "drain \(key.tool.displayName) \(key.window): \(DrainLog.line(drain))"
            if let interval = report.runOuts[key] { line += " · runs out in \(ResetText.duration(interval.earliest))–\(ResetText.duration(interval.latest)) (\(interval.sampleCount) rates)" }
            lines.append(line)
        }
        lines.append(describe(report.advice))
        return lines.joined(separator: "\n")
    }

    static func describe(_ reading: UsageReading) -> String {
        var lines = ["\(reading.tool.displayName)\(reading.plan.map { " (\($0))" } ?? "")"]
        for window in reading.windows {
            var note = window.note.map { " [\($0)]" } ?? ""
            if let tag = window.source.tag { note += " <\(tag)>" }
            if let fraction = window.usedFraction {
                let resets = RelativeTime.resets(window.resetsAt, hasLimit: true)
                lines.append("  \(window.label): \(Int((fraction * 100).rounded()))%, \(resets)\(note)")
            } else {
                lines.append("  \(window.label): no limit published\(note)")
            }
        }
        if let observed = reading.observedAt {
            lines.append("  observed \(RelativeTime.ago(observed))")
        }
        return lines.joined(separator: "\n")
    }

    static func describe(_ cost: CostSummary) -> String {
        var line = "cost: today \(Money.dollars(cost.today)) yesterday \(Money.dollars(cost.yesterday)) 30d \(Money.dollars(cost.last30Days))"
        line += " 90d \(Money.dollars(cost.totals(.last90Days).cost)) month \(Money.dollars(cost.totals(.month).cost))"
        if let week = cost.week {
            line += " week \(Money.dollars(week.cost))" + (week.perPercent.map { " (\(Money.dollars($0)) per 1% of weekly)" } ?? "")
        }
        line += " last hour \(Money.dollars(cost.lastHour))"
        if let burn = cost.burnMultiple {
            line += " (\(Burn.multiple(burn)) the 30-day average \(Money.dollars(cost.typicalHourly)) per active hour)"
        }
        if let block = cost.block {
            line += " block \(Money.dollars(block.cost))" + (block.tokensPerMinute.map { " \(Int($0.rounded())) tok/min" } ?? "")
        }
        if let metering = cost.sessionMetering {
            line += " metering \(Money.tokens(Int(metering.tokensPerPercent.rounded()))) per 1% of session" + (metering.median.map { " (30-day median \(Money.tokens(Int($0.rounded()))))" } ?? "")
        }
        let today = cost.totals(.today).tokens
        if let share = CacheTTL.oneHourShare(today) { line += " cache writes \(Int((share * 100).rounded()))% 1-hour" }
        let projects = cost.totals(.today).projects.prefix(3).map { "\($0.name) \(Money.dollars($0.cost))" }
        if !projects.isEmpty { line += " projects today [\(projects.joined(separator: ", "))]" }
        let models = cost.totals(.today).models.prefix(3).map { "\($0.name) \(Money.dollars($0.cost))" }
        if !models.isEmpty { line += " models today [\(models.joined(separator: ", "))]" }
        for provider in cost.providers {
            line += " \(provider.tool.rawValue) today \(Money.dollars(provider.totals(.today).cost)) 30d \(Money.dollars(provider.totals(.last30Days).cost))"
            line += " (\(provider.source.rawValue))" + (provider.problem.map { " [\($0)]" } ?? "")
        }
        return line + " unpriced=\(cost.unpricedModels.sorted())"
    }

    static func describe(_ advice: [Advice]) -> String {
        guard !advice.isEmpty else { return "advice: nothing to say" }
        return "advice:\n" + advice.map { "  [\($0.priority)] \($0.text)\($0.url.map { " → \($0.absoluteString)" } ?? "")" }.joined(separator: "\n")
    }

    static func describe(_ status: ToolStatus) -> String {
        switch status {
        case .notInstalled: "not installed"
        case .off: "off"
        case .waiting: "waiting"
        case .idle(let message): "idle: \(message)"
        case .ready(let reading): describe(reading)
        case .needsAttention(let message, _): "needs attention: \(message)"
        case .failed(let message, _): "failed: \(message)"
        case .offline(let cached): "offline" + (cached.map { ", showing \(describe($0))" } ?? "")
        }
    }
}

extension UsageReport {
    /// A report read back from its JSON (the report file or the local API), enough for the MCP server to serve it
    /// as-is: the object is kept verbatim.
    static func decode(_ data: Data) -> UsageReport? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], root["schema"] as? String == schema else { return nil }
        return UsageReport(raw: root)
    }
}
