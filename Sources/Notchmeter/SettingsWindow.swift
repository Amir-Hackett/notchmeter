import AppKit
import SwiftUI

struct SettingsView: View {
    let store: UsageStore
    let prefs: Preferences
    let actions: NotchActions
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("General") {
                Toggle("Show total spend", isOn: Binding(
                    get: { prefs.showSpend },
                    set: { prefs.showSpend = $0; if $0 { store.refreshAll() } }
                ))
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
            }
            Section("Panel") {
                Picker("Position", selection: Binding(
                    get: { prefs.edge },
                    set: { prefs.edge = $0; actions.applyLayout() }
                )) {
                    ForEach(PanelEdge.allCases, id: \.self) { edge in
                        Text(edge.title).tag(edge)
                    }
                }
                Text(prefs.edge.detail).font(.caption).foregroundStyle(.secondary)
                Picker("Show", selection: Binding(
                    get: { prefs.visibility },
                    set: { prefs.visibility = $0; actions.applyLayout() }
                )) {
                    ForEach(NotchVisibility.allCases, id: \.self) { visibility in
                        Text(visibility.title).tag(visibility)
                    }
                }
            }
            Section("Usage display") {
                Picker("Show usage as", selection: Binding(get: { prefs.usageDisplay }, set: { prefs.usageDisplay = $0 })) {
                    ForEach(UsageDisplay.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Reset times", selection: Binding(get: { prefs.resetDisplay }, set: { prefs.resetDisplay = $0 })) {
                    ForEach(ResetDisplay.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Time format", selection: Binding(get: { prefs.timeFormat }, set: { prefs.timeFormat = $0 })) {
                    ForEach(TimeFormatPreference.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
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
        .frame(minWidth: 460, minHeight: 640)
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
    init(store: UsageStore, prefs: Preferences, actions: NotchActions) {
        let host = NSHostingController(rootView: SettingsView(store: store, prefs: prefs, actions: actions))
        let window = NSWindow(contentViewController: host)
        window.title = "\(AppInfo.name) Settings"
        window.styleMask = [.titled, .closable, .resizable]
        // A grouped Form has no intrinsic height, so the window must be sized explicitly.
        window.setContentSize(NSSize(width: 460, height: 640))
        window.minSize = NSSize(width: 460, height: 420)
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
