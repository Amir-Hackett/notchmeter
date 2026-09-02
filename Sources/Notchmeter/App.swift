import AppKit

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
        // --no-prompt: never raise the Keychain dialog; a locked item reports "needs attention" instead.
        if arguments.contains("--no-prompt") || arguments.contains("--smoke") || arguments.contains("--render-assets") || arguments.contains("--render-gallery") {
            Keychain.setPromptsAllowed(false)
        }
        // --e2e-oracle <path> (or NOTCHMETER_ORACLE): a JSON line per state change for a tester (docs/testing.md).
        // Started before anything that reports, so the launch preferences are the first lines.
        if let path = Oracle.path() {
            Oracle.shared.start(path: path)
        }
        ModelPricing.loadOverrides()
        if arguments.contains("--probe") {
            Probe.run(json: arguments.contains("--json"))
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
    private var updater: Updater?
    private let updaterGate = Updater.gate()
    private var menuBarItem: MenuBarItem?
    private let capture = ScreenCaptureMonitor()
    private var localAPI: LocalAPI?
    private var hotkeyIDs: [UInt32] = []
    private var screenKey = ""

    private var smokeRestoreEdge: PanelEdge?
    private var smokeRestoreStyle: CompactStyle?
    private var smokeRestoreVisibility: NotchVisibility?
    private var smokeRestoreDisplay: DisplayChoice?

    /// The first presenter: the one on the built-in (or chosen) display.
    var presenter: (any PanelPresenting)? { presenters.first }

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
        MainMenu.install(actions: actions)
        AccessibilityDisplay.shared.reduceAnimations = prefs.reduceAnimations
        store = UsageStore(prefs: prefs)
        store.deliverAlerts = { [weak self] alerts in
            guard let self else { return }
            self.notifier.send(alerts, context: self.store.adviceContext())
        }
        store.deliverSessionEvent = { [weak self] event, session in
            self?.notifier.notify(event, session: session)
        }
        notifier.sound = { [weak self] in self?.prefs.notificationSound ?? true }
        notifier.quiet = { [weak self] in self?.prefs.isQuietHour() ?? false }
        notifier.onOpen = { [weak self] tool in self?.openFromNotification(tool) }
        store.start()
        actions.refresh = { [weak self] in self?.store.refreshAll() }
        actions.openSettings = { [weak self] in self?.showSettings() }
        actions.showOptions = { [weak self] in self?.presenter?.showOptions() }
        actions.applyLayout = { [weak self] in self?.applyLayout() }
        actions.togglePanel = { [weak self] in self?.presenter?.toggle(cause: .hotkey) }
        actions.copyPanelImage = { [weak self] in self?.copyPanelImage() }
        requests.rootsChanged = { [weak self] in self?.store.reloadRoots() }
        requests.menuBarChanged = { [weak self] in self?.applyMenuBarItem() }
        requests.hotkeysChanged = { [weak self] in self?.registerHotkeys() }
        requests.localAPIChanged = { [weak self] in self?.applyLocalAPI() }
        requests.privacyChanged = { [weak self] in self?.applyPrivacy() }
        buildPresenters()
        applyMenuBarItem()
        applyPrivacy()
        applyLocalAPI()
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
        // nor shows an update.
        if arguments.contains("--smoke") {
            Task { await self.smokeTest() }
        } else {
            if let updater = Updater.start(gate: updaterGate) {
                self.updater = updater
                actions.checkForUpdates = { updater.checkForUpdates() }
            }
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
        settings?.present(on: .pointerScreen)
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
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeSettings() }
        }
    }

    // MARK: - Layout

    /// Re-applies the visibility preference, or swaps every presenter when the edge or the display changed.
    func applyLayout() {
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

    private func rebuildPresenters() {
        let old = presenters
        presenters = []
        Task {
            for presenter in old { await presenter.hide() }
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
    }

    static func screenKey(_ screens: [NSScreen]) -> String {
        screens.map { "\($0.localizedName)|\($0.frame)|\($0.safeAreaInsets.top > 0)" }.joined(separator: ";")
    }

    /// A display was plugged in or out, the lid opened or closed, or mirroring changed: re-derive the screens and
    /// rebuild the presenters when the set, a frame or a notch changed.
    private func screensChanged() {
        Oracle.shared.emit("screens", ["screens": NSScreen.descriptions])
        let key = Self.screenKey(chosenScreens())
        if key != screenKey {
            rebuildPresenters()
            applyMenuBarItem()
        } else {
            for presenter in presenters { presenter.remeasure() }
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
            if localAPI == nil { localAPI = LocalAPI { [weak self] in self?.store.report() ?? UsageReport(tools: [:], cost: nil, advice: []) } }
            localAPI?.start()
        } else {
            localAPI?.stop()
            localAPI = nil
        }
    }

    private func registerHotkeys() {
        for id in hotkeyIDs { HotkeyCenter.shared.unregister(id) }
        hotkeyIDs = []
        if let hotkey = prefs.togglePanelHotkey, let id = HotkeyCenter.shared.register(hotkey, action: { [weak self] in self?.presenter?.toggle(cause: .hotkey) }) {
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
            presenter?.expandNow(cause: .notification)
        }
    }

    private func copyPanelImage() {
        CardImage.copy(NotchExpandedView(store: store, prefs: prefs, actions: actions, maxHeight: 10_000), width: prefs.panelWidth.points + 24)
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
            "awaitingInput": store.awaitingInput.map(\.rawValue).sorted(), "sessions": store.sessions.count,
            "readings": ToolID.allCases.map { Oracle.fields($0, store.status($0)) },
            "advice": store.advice.map(\.text),
            "settingsVisible": isSettingsVisible,
            "screens": NSScreen.descriptions,
            "captured": store.screenCaptured,
        ]
        if let presenter {
            fields["panelState"] = presenter.hover.state.rawValue
            fields["panelVisible"] = presenter.isVisible
            fields["regions"] = ["compact": presenter.hover.regions.compact, "expanded": presenter.hover.regions.expanded]
            fields["panelScreen"] = presenter.screen.localizedName
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
    /// `--visibility` and `--display` pick the layout for the run and are restored on exit; `--idle-sim` runs the
    /// Hide when idle clock 31 minutes ahead. The copy line names the language the panel is in and shows five of
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
            Probe.emit("screen \(screen["name"] ?? ""): frame=\(screen["frame"] ?? "") visible=\(screen["visibleFrame"] ?? "") notch=\(screen["notch"] ?? "") main=\(screen["isMain"] ?? "") primary=\(screen["isPrimary"] ?? "")")
        }
        Probe.emit("chrome: menu bar auto-hides=\(SystemChrome.menuBarAutoHides) dock auto-hides=\(SystemChrome.dockAutoHides); low power mode=\(PowerSource.lowPowerMode()); accessibility \(AccessibilityDisplay.shared.description)")
        Probe.emit("display: \(prefs.display.rawValue) → \(presenters.map { "\($0.screen.localizedName) (\(type(of: $0)))" }.joined(separator: ", "))")
        let frame = presenter?.window.map { "\($0.frame)" } ?? "none"
        Probe.emit("panel (\(prefs.edge.rawValue)): visible=\(presenter?.isVisible ?? false) frame=\(frame)")
        if let window = presenter?.window {
            Probe.emit("window: level=\(window.level.rawValue) fullScreenAuxiliary=\(window.collectionBehavior.contains(.fullScreenAuxiliary)) (show over full-screen apps=\(prefs.showOverFullScreenApps))")
        }
        if let regions = presenter?.hover.regions {
            Probe.emit("hover regions: compact=\(regions.compact) expanded=\(regions.expanded)")
        }
        Probe.emit("hover: mode=\(String(describing: presenter?.hover.mode)) delay=\(prefs.hoverDelay)s gestures=\(presenter?.hover.gestures ?? false)")
        let sizingPassed = presenter.map(reportSizing) ?? false
        reportCompactStyles()
        reportIdle()
        for tool in ToolID.allCases {
            Probe.emit("\(tool.displayName): \(Probe.describe(store.status(tool)))")
        }
        Probe.emit("tool order: \(prefs.toolOrder.map(\.rawValue).joined(separator: ", ")); visible: \(store.visibleTools.map(\.rawValue).joined(separator: ", "))")
        Probe.emit("polling: \(store.scheduleDescription())")
        Probe.emit("presence: \(store.presence); sessions: \(store.sessions.count); reduce motion: \(AccessibilityDisplay.shared.motionReduced)")
        if let cost = store.cost {
            Probe.emit(Probe.describe(cost))
        } else {
            Probe.emit("cost: still scanning")
        }
        Probe.emit(Probe.describe(store.advice))
        Probe.emit("notifications: \(prefs.notificationsEnabled ? "on" : "off") in settings, \(notifier.isAvailable ? "available" : "no-op in this run")")
        Probe.emit("updater: \(updaterGate.summary); never started under --smoke")
        Probe.emit("menu bar item: \(menuBarItem == nil ? "off" : "on"); local API: \(localAPI?.isRunning == true ? "on" : "off"); privacy probe: \(ScreenCapture.probeName) captured=\(ScreenCapture.isCaptured())")
        Probe.emit("hooks: \(HookSettings.status().text); status line: \(HookSettings.statuslineStatus().text)")
        Probe.emit("main menu: \(MainMenu.describe())")
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
        exit(presenter?.isVisible == true && hoverPassed && sizingPassed && settingsPassed ? 0 : 1)
    }

    /// The open panel must fit where it is drawn: inside DynamicNotchKit's fixed window for the top layout, inside
    /// the screen's usable height for the edge pills, which size their window to the content. The top window is
    /// mostly transparent, so a hit test below the panel also confirms that area still reaches whatever is under it.
    private func reportSizing(_ presenter: any PanelPresenting) -> Bool {
        let screen = presenter.screen
        let content = presenter.expandedContentSize
        let cap = NotchExpandedView.maxHeight(on: screen)
        let notchLayout = presenter is NotchController
        let room = notchLayout ? (presenter.window?.frame.height ?? 0) : screen.visibleFrame.height
        let roomName = notchLayout ? "window height" : "usable screen height"
        var passed = content.height <= room && content.height <= cap
        Probe.emit("panel sizing: \(roomName)=\(room) expanded content height=\(content.height) width=\(content.width) (density=\(prefs.density.rawValue), panel width=\(prefs.panelWidth.rawValue)) max content height=\(cap) → \(passed ? "fits" : "CLIPPED")")
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

    /// Opens Settings the way the menu does and checks what the user reported: a floating, non-activating panel
    /// in front of a collapsed notch panel, clear of it, with someone else's app still frontmost; closing it puts
    /// the panel back the way the visibility preference wants it. The hook-install sheet is driven against a
    /// scratch file so the alert is seen to attach to the window without touching settings.json.
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
        Probe.emit("settings window: level=\(window.level.rawValue) (floating=\(window.level == .floating)) frame=\(window.frame) "
                   + "nonActivating=\(settings.isNonActivating) visible=\(window.isVisible) key=\(window.isKeyWindow) "
                   + "(key window: \(NSApp.keyWindow.map { $0.title.isEmpty ? "the panel" : $0.title } ?? "none"))")
        Probe.emit("settings: frontmost=\(frontmost) panel=\(state.rawValue) intersects=\(intersects)")
        var passed = window.level == .floating && settings.isNonActivating && window.isVisible && frontmost != ours
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
/// versioned object of UsageReport with a Claude-Code-Usage-Monitor-style exit code. Tokens are never printed.
enum Probe {
    static func run(json: Bool = false) {
        if !json { emit("\(AppInfo.name) probe: reads usage from tools signed in on this Mac; tokens are never printed.") }
        Task.detached {
            var readings: [UsageReading] = []
            var statuses: [ToolID: ToolStatus] = [:]
            for provider in ProviderRegistry.all() {
                let name = provider.tool.displayName
                guard provider.isInstalled() else {
                    if !json { emit("\(name): not installed") }
                    statuses[provider.tool] = .notInstalled
                    continue
                }
                if !json { emit("\(name): reading…") }
                do {
                    let reading = try await provider.fetch()
                    readings.append(reading)
                    statuses[provider.tool] = .ready(reading)
                    if !json { emit(describe(reading)) }
                } catch let error as ProviderError {
                    statuses[provider.tool] = error.needsAttention ? .needsAttention(error.message, cached: nil) : .failed(error.message, cached: nil)
                    if !json { emit("\(name): \(error.message)") }
                } catch {
                    statuses[provider.tool] = .failed(error.localizedDescription, cached: nil)
                    if !json { emit("\(name): \(error.localizedDescription)") }
                }
            }
            if !json { emit("Claude Code cost: pricing local transcripts…") }
            let claude = readings.first { $0.tool == .claude }
            let weekly = claude?.windows.first { $0.id == "seven_day" }
            let session = claude?.windows.first { $0.id == "five_hour" }
            let cost = await ClaudeCostScanner().scan(weeklyResetsAt: weekly?.resetsAt, weeklyUsed: weekly?.usedFraction, sessionResetsAt: session?.resetsAt)
            let now = Date()
            let samples = DrainLog().load(now: now)
            var drains: [DrainLog.Key: Drain] = [:]
            for (key, rows) in samples {
                if let drain = DrainLog.drain(rows, now: now) { drains[key] = drain }
            }
            let rates = drains.reduce(into: [String: Double]()) { if let rate = $1.value.perHour { $0["\($1.key.tool.rawValue)/\($1.key.window)"] = rate } }
            let advice = Advisor.advise(Advisor.Context(readings: readings, cost: cost, drainRates: rates, now: now))
            let report = UsageReport(tools: statuses, cost: cost, advice: advice, drains: drains, now: now)
            if json {
                FileHandle.standardOutput.write(report.json)
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else {
                emit(describe(cost))
                for (key, drain) in drains.sorted(by: { "\($0.key.tool.rawValue)/\($0.key.window)" < "\($1.key.tool.rawValue)/\($1.key.window)" }) {
                    emit("drain \(key.tool.displayName) \(key.window): \(DrainLog.line(drain))")
                }
                emit(describe(advice))
                emit("exit code \(report.exitCode.rawValue) (0 ok, 10 near a limit, 11 limit hit, 20 nothing used, 30 no data)")
            }
            exit(report.exitCode.rawValue)
        }
        RunLoop.main.run()
    }

    /// Unbuffered so lines survive even if the process is killed mid-way.
    static func emit(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    static func describe(_ reading: UsageReading) -> String {
        var lines = ["\(reading.tool.displayName)\(reading.plan.map { " (\($0))" } ?? "")"]
        for window in reading.windows {
            let note = window.note.map { " [\($0)]" } ?? ""
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
        let projects = cost.totals(.today).projects.prefix(3).map { "\($0.name) \(Money.dollars($0.cost))" }
        if !projects.isEmpty { line += " projects today [\(projects.joined(separator: ", "))]" }
        let models = cost.totals(.today).models.prefix(3).map { "\($0.name) \(Money.dollars($0.cost))" }
        if !models.isEmpty { line += " models today [\(models.joined(separator: ", "))]" }
        return line + " unpriced=\(cost.unpricedModels.sorted())"
    }

    static func describe(_ advice: [Advice]) -> String {
        guard !advice.isEmpty else { return "advice: nothing to say" }
        return "advice:\n" + advice.map { "  [\($0.priority)] \($0.text)" }.joined(separator: "\n")
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
