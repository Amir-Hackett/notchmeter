import AppKit
import SwiftUI

struct SettingsView: View {
    let store: UsageStore
    let prefs: Preferences
    let actions: NotchActions
    let notifier: Notifier
    @State private var loginError: String?
    @State private var showHookSnippet = false
    @State private var hookMessage: String?
    @State private var notificationMessage: String?

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
                    Text(loginError).font(.caption).foregroundStyle(Palette.danger)
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
            Section("Notifications") {
                Toggle("Notify when a window is on pace to run out", isOn: Binding(
                    get: { prefs.notificationsEnabled },
                    set: { prefs.notificationsEnabled = $0; if $0 { notifier.requestAuthorization() } }
                ))
                Text("Once per window and reset period: when its pace first reaches on track or behind, and again when it comes within an hour of running out. Each one says what to do about it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Test notification") {
                        Task { notificationMessage = await notifier.sendTest(timeFormat: prefs.timeFormat) }
                    }
                    if let notificationMessage {
                        Text(notificationMessage).font(.caption).foregroundStyle(.secondary)
                    }
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
            Section("Claude Code hook") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Let Claude Code tell the notch when it starts, stops or waits for you. The hook passes on only the event name; the meter refreshes at once and a badge shows while Claude waits for your input.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Show snippet…") { showHookSnippet = true }
                        Button("Add to settings.json…") { installHook() }
                    }
                    if let hookMessage {
                        Text(hookMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
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
        .sheet(isPresented: $showHookSnippet) {
            HookSnippetView(snippet: HookSettings.snippet())
        }
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

    /// Asks first; the file is backed up beside itself before anything is merged in.
    private func installHook() {
        let url = HookSettings.settingsURL
        let alert = NSAlert()
        alert.messageText = "Add the Notchmeter hook to settings.json?"
        alert.informativeText = "\(url.path) is copied to settings.json.bak-<date> first. Hooks already there are kept; Notchmeter's entry is appended under \(HookSettings.events.joined(separator: ", "))."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            hookMessage = try HookSettings.install(at: url).summary
        } catch {
            hookMessage = error.localizedDescription
        }
    }
}

struct HookSnippetView: View {
    let snippet: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Claude Code hook").font(.headline)
            Text("Merge this into \(HookSettings.settingsURL.path), or use Add to settings.json… to have it merged for you. Each entry runs \(AppInfo.name) --hook, which posts the event name to the running app and exits.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(snippet)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 280)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 560)
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    init(store: UsageStore, prefs: Preferences, actions: NotchActions, notifier: Notifier) {
        let host = NSHostingController(rootView: SettingsView(store: store, prefs: prefs, actions: actions, notifier: notifier))
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
