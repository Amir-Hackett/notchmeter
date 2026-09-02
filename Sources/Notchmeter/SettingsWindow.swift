import AppKit
import SwiftUI

struct SettingsView: View {
    let store: UsageStore
    let prefs: Preferences
    let applyVisibility: () -> Void
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Assistants") {
                ForEach(ToolID.allCases, id: \.self) { tool in
                    Toggle(isOn: Binding(
                        get: { prefs.enabledTools.contains(tool) },
                        set: { store.setEnabled(tool, $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.displayName)
                            Text(subtitle(for: tool))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!store.isInstalled(tool))
                }
            }
            Section("Notch") {
                Picker("Show", selection: Binding(
                    get: { prefs.visibility },
                    set: { prefs.visibility = $0; applyVisibility() }
                )) {
                    ForEach(NotchVisibility.allCases, id: \.self) { visibility in
                        Text(visibility.title).tag(visibility)
                    }
                }
                Toggle("Open at login", isOn: Binding(
                    get: { prefs.launchAtLogin },
                    set: { enabled in
                        do {
                            try prefs.setLaunchAtLogin(enabled)
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                        }
                    }
                ))
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Button("Refresh now") { store.refreshAll() }
            }
            Section {
                Text("\(AppInfo.name) never signs in. It reads usage from tools already signed in on this Mac and keeps no tokens. macOS asks once per tool for permission to read its saved login; choose Always Allow so it stays quiet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Version \(AppInfo.version)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, minHeight: 480)
    }

    private func subtitle(for tool: ToolID) -> String {
        guard store.isInstalled(tool) else { return "Not installed on this Mac" }
        switch store.status(tool) {
        case .off: return "Off"
        case .waiting: return "Waiting for the first reading"
        case .idle(let message): return message
        case .ready(let reading): return "Signed in" + (reading.plan.map { " · \($0)" } ?? "")
        case .needsAttention(let message, _), .failed(let message, _): return message
        case .notInstalled: return "Not installed on this Mac"
        }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    init(store: UsageStore, prefs: Preferences, applyVisibility: @escaping () -> Void) {
        let host = NSHostingController(rootView: SettingsView(store: store, prefs: prefs, applyVisibility: applyVisibility))
        let window = NSWindow(contentViewController: host)
        window.title = "\(AppInfo.name) Settings"
        window.styleMask = [.titled, .closable, .resizable]
        // A grouped Form has no intrinsic height, so the window must be sized explicitly.
        window.setContentSize(NSSize(width: 440, height: 480))
        window.minSize = NSSize(width: 440, height: 360)
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
