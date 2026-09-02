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
        // --lang zh-Hans: pin the copy to one shipped language, whatever System Settings says; nothing is read before it.
        if let index = arguments.firstIndex(of: "--lang"), index + 1 < arguments.count {
            Localization.use(language: arguments[index + 1])
        }
        // --no-prompt: never raise the Keychain dialog; a locked item reports "needs attention" instead.
        if arguments.contains("--no-prompt") || arguments.contains("--smoke") || arguments.contains("--render-assets") {
            Keychain.setPromptsAllowed(false)
        }
        // --e2e-oracle <path> (or NOTCHMETER_ORACLE): a JSON line per state change for a tester (docs/testing.md).
        // Started before anything that reports, so the launch preferences are the first lines.
        if let path = Oracle.path() {
            Oracle.shared.start(path: path)
        }
        if arguments.contains("--probe") {
            Probe.run()
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
    private(set) var store: UsageStore!
    private var presenter: (any PanelPresenting)?
    private var settings: SettingsWindowController?
    private var settingsObserver: NSObjectProtocol?
    private var snapshotObserver: NSObjectProtocol?
    private var updater: Updater?
    private let updaterGate = Updater.gate()

    private var smokeRestoreEdge: PanelEdge?
    private var smokeRestoreStyle: CompactStyle?
    private var smokeRestoreVisibility: NotchVisibility?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        // --render-assets <dir>: the README's pictures from fixture readings; no store, no provider, no panel.
        if let index = arguments.firstIndex(of: "--render-assets"), index + 1 < arguments.count {
            exit(AssetRenderer.render(into: URL(fileURLWithPath: arguments[index + 1])) ? 0 : 1)
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
        store = UsageStore(prefs: prefs)
        store.deliverAlerts = { [weak self] alerts in
            guard let self else { return }
            self.notifier.send(alerts, context: self.store.adviceContext())
        }
        if prefs.notificationsEnabled { notifier.requestAuthorization() }
        store.start()
        actions.refresh = { [weak self] in self?.store.refreshAll() }
        actions.openSettings = { [weak self] in self?.showSettings() }
        actions.showOptions = { [weak self] in self?.presenter?.showOptions() }
        actions.applyLayout = { [weak self] in self?.applyLayout() }
        buildPresenter()
        Oracle.shared.emit("launched", ["version": AppInfo.version, "edge": prefs.edge.rawValue, "visibility": prefs.visibility.rawValue,
                                        "compactStyle": prefs.compactStyle.rawValue, "toolOrder": prefs.toolOrder.map(\.rawValue)])
        if Oracle.shared.isActive {
            snapshotObserver = DistributedNotificationCenter.default().addObserver(forName: Oracle.snapshotNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.emitSnapshot() }
            }
        }
        // A self check reports the gate and never starts Sparkle, so a signed build's --smoke neither reaches the feed
        // nor shows an update.
        if arguments.contains("--smoke") {
            Task { await self.smokeTest() }
        } else if let updater = Updater.start(gate: updaterGate) {
            self.updater = updater
            actions.checkForUpdates = { updater.checkForUpdates() }
        }
    }

    // MARK: - Settings

    /// Collapses the panel first and holds it closed for as long as the window is up: the panel window spans the
    /// screen's height at a level above every other window, so Settings would otherwise open behind it.
    func showSettings() {
        if settings == nil {
            let controller = SettingsWindowController(store: store, prefs: prefs, actions: actions, notifier: notifier)
            settings = controller
            if let window = controller.window {
                settingsObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.settingsDidClose() }
                }
            }
        }
        presenter?.holdCompact(true)
        settings?.present(on: .panelScreen)
        Oracle.shared.emit("settings", settingsFields(action: "shown"))
    }

    private func settingsDidClose() {
        presenter?.holdCompact(false)
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

    // MARK: - Layout

    /// Re-applies the visibility preference, or swaps the whole presenter when the edge changed.
    func applyLayout() {
        guard let presenter, presenter.edge == prefs.edge else {
            let old = presenter
            presenter = nil
            Task {
                await old?.hide()
                self.buildPresenter()
            }
            return
        }
        presenter.show()
    }

    private func buildPresenter() {
        let built: any PanelPresenting = prefs.edge == .top
            ? NotchController(store: store, prefs: prefs, actions: actions)
            : EdgePanelController(edge: prefs.edge, store: store, prefs: prefs, actions: actions)
        presenter = built
        if isSettingsVisible {
            built.holdCompact(true)
        } else {
            built.show()
        }
    }

    // MARK: - Oracle

    /// Everything a tester could otherwise only see, in one line, on the distributed notification
    /// com.amirhackett.notchmeter.oracle.snapshot.
    private func emitSnapshot() {
        var fields: [String: Any] = [
            "edge": prefs.edge.rawValue, "visibility": prefs.visibility.rawValue, "compactStyle": prefs.compactStyle.rawValue,
            "usageDisplay": prefs.usageDisplay.rawValue, "toolOrder": prefs.toolOrder.map(\.rawValue),
            "enabledTools": prefs.enabledTools.map(\.rawValue).sorted(), "showSpend": prefs.showSpend,
            "visibleTools": store.visibleTools.map(\.rawValue), "presence": String(describing: store.presence),
            "awaitingInput": store.awaitingInput.map(\.rawValue).sorted(),
            "readings": ToolID.allCases.map { Oracle.fields($0, store.status($0)) },
            "advice": store.advice.map(\.text),
            "settingsVisible": isSettingsVisible,
        ]
        if let presenter {
            fields["panelState"] = presenter.hover.state.rawValue
            fields["panelVisible"] = presenter.isVisible
            fields["regions"] = ["compact": presenter.hover.regions.compact, "expanded": presenter.hover.regions.expanded]
        }
        if let window = settings?.window, window.isVisible {
            fields["settingsFrame"] = window.frame
        }
        Oracle.shared.emit("snapshot", fields)
    }

    // MARK: - Smoke

    /// `--smoke`: run for a few seconds, report what is on screen and what each provider returned, then exit.
    /// `--hover-sim` adds a scripted pointer path through the live hover machine and fails the run if it loops;
    /// `--hover-log` prints each decision the real mouse produces meanwhile; `--edge`, `--compact-style` and
    /// `--visibility` pick the layout for the run and are restored on exit. The copy line names the language the
    /// panel is in and shows five of its strings, so `--lang zh-Hans` can be seen to take.
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
        let frame = presenter?.window.map { "\($0.frame)" } ?? "none"
        Probe.emit("panel (\(prefs.edge.rawValue)): visible=\(presenter?.isVisible ?? false) frame=\(frame)")
        if let regions = presenter?.hover.regions {
            Probe.emit("hover regions: compact=\(regions.compact) expanded=\(regions.expanded)")
        }
        let sizingPassed = presenter.map(reportSizing) ?? false
        reportCompactStyles()
        for tool in ToolID.allCases {
            Probe.emit("\(tool.displayName): \(Probe.describe(store.status(tool)))")
        }
        Probe.emit("tool order: \(prefs.toolOrder.map(\.rawValue).joined(separator: ", ")); visible: \(store.visibleTools.map(\.rawValue).joined(separator: ", "))")
        Probe.emit("polling: \(store.scheduleDescription())")
        Probe.emit("presence: \(store.presence); reduce motion: \(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)")
        if let cost = store.cost {
            Probe.emit(Probe.describe(cost))
        } else {
            Probe.emit("cost: still scanning")
        }
        Probe.emit(Probe.describe(store.advice))
        Probe.emit("notifications: \(prefs.notificationsEnabled ? "on" : "off") in settings, \(notifier.isAvailable ? "available" : "no-op in this run")")
        Probe.emit("updater: \(updaterGate.summary); never started under --smoke")
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
        exit(presenter?.isVisible == true && hoverPassed && sizingPassed && settingsPassed ? 0 : 1)
    }

    /// The open panel must fit where it is drawn: inside DynamicNotchKit's fixed window for the top layout, inside
    /// the screen's usable height for the edge pills, which size their window to the content. The top window is
    /// mostly transparent, so a hit test below the panel also confirms that area still reaches whatever is under it.
    private func reportSizing(_ presenter: any PanelPresenting) -> Bool {
        let screen = NSScreen.panelScreen
        let content = presenter.expandedContentSize
        let cap = NotchExpandedView.maxHeight(on: screen)
        let room = presenter.edge == .top ? (presenter.window?.frame.height ?? 0) : screen.visibleFrame.height
        let roomName = presenter.edge == .top ? "window height" : "usable screen height"
        var passed = content.height <= room && content.height <= cap
        Probe.emit("panel sizing: \(roomName)=\(room) expanded content height=\(content.height) max content height=\(cap) → \(passed ? "fits" : "CLIPPED")")
        if presenter.edge == .top, let window = presenter.window {
            let below = NSPoint(x: window.frame.midX, y: window.frame.minY + 20)
            let hit = NSWindow.windowNumber(at: below, belowWindowWithWindowNumber: 0)
            let clickThrough = hit != window.windowNumber
            passed = passed && clickThrough
            Probe.emit("panel window: opaque=\(window.isOpaque) click-through below the panel=\(clickThrough)")
        }
        return passed
    }

    /// The compact shape the hover machine uses, measured for each style; the run's own style is restored after.
    private func reportCompactStyles() {
        guard let presenter else { return }
        let current = prefs.compactStyle
        for style in CompactStyle.allCases {
            prefs.compactStyle = style
            presenter.remeasure()
            let compact = presenter.hover.regions.compact
            Probe.emit("compact style \(style.rawValue): compact region \(Int(compact.width.rounded())) × \(Int(compact.height.rounded())) pt at (\(Int(compact.minX)), \(Int(compact.minY)))")
        }
        prefs.compactStyle = current
        presenter.remeasure()
    }

    /// Opens Settings the way the menu does and checks what the user reported: a floating, non-activating panel
    /// in front of a collapsed notch panel, clear of it, with someone else's app still frontmost; closing it puts
    /// the panel back the way the visibility preference wants it.
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
        settings.close()
        try? await Task.sleep(for: .seconds(1))
        let wanted: HoverIntent.State = prefs.visibility == .always ? .expanded : .compact
        let restored = presenter.hover.state == wanted && !(settings.window?.isVisible ?? false)
        Probe.emit("settings closed: panel=\(presenter.hover.state.rawValue) visibility=\(prefs.visibility.rawValue) → \(restored ? "restored" : "NOT restored")")
        passed = passed && restored
        return passed
    }
}

/// `--probe`: read every provider once from the command line and print the parsed numbers. Tokens are never printed.
enum Probe {
    static func run() {
        emit("\(AppInfo.name) probe: reads usage from tools signed in on this Mac; tokens are never printed.")
        Task.detached {
            var readings: [UsageReading] = []
            for provider in ProviderRegistry.all() {
                let name = provider.tool.displayName
                guard provider.isInstalled() else {
                    emit("\(name): not installed")
                    continue
                }
                emit("\(name): reading…")
                do {
                    let reading = try await provider.fetch()
                    readings.append(reading)
                    emit(describe(reading))
                } catch let error as ProviderError {
                    emit("\(name): \(error.message)")
                } catch {
                    emit("\(name): \(error.localizedDescription)")
                }
            }
            emit("Claude Code cost: pricing local transcripts…")
            let cost = await ClaudeCostScanner().scan()
            emit(describe(cost))
            emit(describe(Advisor.advise(Advisor.Context(readings: readings, cost: cost))))
            exit(0)
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
        line += " last hour \(Money.dollars(cost.lastHour))"
        if let burn = cost.burnMultiple {
            line += " (\(Burn.multiple(burn)) the 30-day average \(Money.dollars(cost.typicalHourly)) per active hour)"
        }
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
        }
    }
}
