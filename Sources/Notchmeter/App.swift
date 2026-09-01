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
    private(set) var store: UsageStore!
    private var notch: NotchController?
    private var settings: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = UsageStore(prefs: prefs)
        store.start()
        let notch = NotchController(store: store, prefs: prefs)
        notch.openSettings = { [weak self] in self?.showSettings() }
        notch.show()
        self.notch = notch
        if CommandLine.arguments.contains("--smoke") {
            Task { await self.smokeTest() }
        }
    }

    func showSettings() {
        if settings == nil {
            settings = SettingsWindowController(store: store, prefs: prefs) { [weak self] in self?.notch?.show() }
        }
        settings?.present()
    }

    /// `--smoke`: run for a few seconds, report what is on screen and what each provider returned, then exit.
    private func smokeTest() async {
        try? await Task.sleep(for: .seconds(8))
        let frame = notch?.windowFrame.map { "\($0)" } ?? "none"
        Probe.emit("notch window: visible=\(notch?.isVisible ?? false) frame=\(frame)")
        for tool in ToolID.allCases {
            Probe.emit("\(tool.displayName): \(Probe.describe(store.status(tool)))")
        }
        exit(notch?.isVisible == true ? 0 : 1)
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
