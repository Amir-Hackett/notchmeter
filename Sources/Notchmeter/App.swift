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
        // --no-prompt: never raise the Keychain dialog; a locked item reports "needs attention" instead.
        if arguments.contains("--no-prompt") || arguments.contains("--smoke") || arguments.contains("--render-assets") {
            Keychain.setPromptsAllowed(false)
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
    private var updater: Updater?
    private let updaterGate = Updater.gate()

    private var smokeRestoreEdge: PanelEdge?

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
        // A self check reports the gate and never starts Sparkle, so a signed build's --smoke neither reaches the feed
        // nor shows an update.
        if arguments.contains("--smoke") {
            Task { await self.smokeTest() }
        } else if let updater = Updater.start(gate: updaterGate) {
            self.updater = updater
            actions.checkForUpdates = { updater.checkForUpdates() }
        }
    }

    func showSettings() {
        if settings == nil {
            settings = SettingsWindowController(store: store, prefs: prefs, actions: actions, notifier: notifier)
        }
        settings?.present()
    }

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
        built.show()
    }

    /// `--smoke`: run for a few seconds, report what is on screen and what each provider returned, then exit.
    /// `--hover-sim` adds a scripted pointer path through the live hover machine and fails the run if it loops;
    /// `--hover-log` prints each decision the real mouse produces meanwhile.
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
        for tool in ToolID.allCases {
            Probe.emit("\(tool.displayName): \(Probe.describe(store.status(tool)))")
        }
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
        let settingsProbe = SettingsWindowController(store: store, prefs: prefs, actions: actions, notifier: notifier)
        settingsProbe.window?.layoutIfNeeded()
        Probe.emit("settings window: \(settingsProbe.window?.frame.size ?? .zero)")
        if let smokeRestoreEdge { prefs.edge = smokeRestoreEdge }
        exit(presenter?.isVisible == true && hoverPassed && sizingPassed ? 0 : 1)
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
            line += " (\(Burn.multiple(burn)) the usual \(Money.dollars(cost.typicalHourly)) per active hour)"
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
