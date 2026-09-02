import AppKit
import Security

@main
enum NotchmeterMain {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        // --no-prompt: never raise the Keychain dialog; a locked item reports "needs attention" instead.
        if arguments.contains("--no-prompt") || arguments.contains("--smoke") {
            SecKeychainSetUserInteractionAllowed(false)
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
    private(set) var store: UsageStore!
    private var presenter: (any PanelPresenting)?
    private var settings: SettingsWindowController?

    private var smokeRestoreEdge: PanelEdge?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        if arguments.contains("--smoke"), let index = arguments.firstIndex(of: "--edge"), index + 1 < arguments.count,
           let edge = PanelEdge(rawValue: arguments[index + 1]) {
            smokeRestoreEdge = prefs.edge
            prefs.edge = edge
        }
        store = UsageStore(prefs: prefs)
        store.start()
        actions.refresh = { [weak self] in self?.store.refreshAll() }
        actions.openSettings = { [weak self] in self?.showSettings() }
        actions.showOptions = { [weak self] in self?.presenter?.showOptions() }
        actions.applyLayout = { [weak self] in self?.applyLayout() }
        buildPresenter()
        if CommandLine.arguments.contains("--smoke") {
            Task { await self.smokeTest() }
        }
    }

    func showSettings() {
        if settings == nil {
            settings = SettingsWindowController(store: store, prefs: prefs, actions: actions)
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
    private func smokeTest() async {
        let started = Date()
        try? await Task.sleep(for: .seconds(8))
        while store.cost == nil, Date().timeIntervalSince(started) < 90 {
            try? await Task.sleep(for: .seconds(2))
        }
        Probe.emit("smoke ran \(Int(Date().timeIntervalSince(started)))s")
        let frame = presenter?.windowFrame.map { "\($0)" } ?? "none"
        Probe.emit("panel (\(prefs.edge.rawValue)): visible=\(presenter?.isVisible ?? false) frame=\(frame)")
        for tool in ToolID.allCases {
            Probe.emit("\(tool.displayName): \(Probe.describe(store.status(tool)))")
        }
        if let cost = store.cost {
            Probe.emit("cost: today \(Money.dollars(cost.today)) yesterday \(Money.dollars(cost.yesterday)) 30d \(Money.dollars(cost.last30Days)) unpriced=\(cost.unpricedModels.sorted())")
        } else {
            Probe.emit("cost: still scanning")
        }
        let settingsProbe = SettingsWindowController(store: store, prefs: prefs, actions: actions)
        settingsProbe.window?.layoutIfNeeded()
        Probe.emit("settings window: \(settingsProbe.window?.frame.size ?? .zero)")
        if let smokeRestoreEdge { prefs.edge = smokeRestoreEdge }
        exit(presenter?.isVisible == true ? 0 : 1)
    }
}

/// `--probe`: read every provider once from the command line and print the parsed numbers. Tokens are never printed.
enum Probe {
    static func run() {
        emit("\(AppInfo.name) probe: reads usage from tools signed in on this Mac; tokens are never printed.")
        Task.detached {
            for provider in ProviderRegistry.all() {
                let name = provider.tool.displayName
                guard provider.isInstalled() else {
                    emit("\(name): not installed")
                    continue
                }
                emit("\(name): reading…")
                do {
                    emit(describe(try await provider.fetch()))
                } catch let error as ProviderError {
                    emit("\(name): \(error.message)")
                } catch {
                    emit("\(name): \(error.localizedDescription)")
                }
            }
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
