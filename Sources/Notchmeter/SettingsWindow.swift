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
            Section(L("General")) {
                Toggle(L("Show total spend"), isOn: Binding(
                    get: { prefs.showSpend },
                    set: { prefs.showSpend = $0; if $0 { store.refreshAll() } }
                ))
                Toggle(L("Open at login"), isOn: Binding(
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
            Section(L("Panel")) {
                Picker(L("Position"), selection: Binding(
                    get: { prefs.edge },
                    set: { prefs.edge = $0; actions.applyLayout() }
                )) {
                    ForEach(PanelEdge.allCases, id: \.self) { edge in
                        Text(edge.title).tag(edge)
                    }
                }
                Text(prefs.edge.detail).font(.caption).foregroundStyle(.secondary)
                Picker(L("Show"), selection: Binding(
                    get: { prefs.visibility },
                    set: { prefs.visibility = $0; actions.applyLayout() }
                )) {
                    ForEach(NotchVisibility.allCases, id: \.self) { visibility in
                        Text(visibility.title).tag(visibility)
                    }
                }
                Picker(prefs.edge.compactStyleTitle, selection: Binding(get: { prefs.compactStyle }, set: { prefs.compactStyle = $0 })) {
                    ForEach(CompactStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Section(L("Usage display")) {
                Picker(L("Show usage as"), selection: Binding(get: { prefs.usageDisplay }, set: { prefs.usageDisplay = $0 })) {
                    ForEach(UsageDisplay.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker(L("Reset times"), selection: Binding(get: { prefs.resetDisplay }, set: { prefs.resetDisplay = $0 })) {
                    ForEach(ResetDisplay.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker(L("Time format"), selection: Binding(get: { prefs.timeFormat }, set: { prefs.timeFormat = $0 })) {
                    ForEach(TimeFormatPreference.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Section(L("Notifications")) {
                Toggle(L("Notify when a window is on pace to run out"), isOn: Binding(
                    get: { prefs.notificationsEnabled },
                    set: { prefs.notificationsEnabled = $0; if $0 { notifier.requestAuthorization() } }
                ))
                Text(L("Once per window and reset period: when its pace first reaches on track or behind, and again when it comes within an hour of running out. Each one says what to do about it."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(L("Test notification")) {
                        Task { notificationMessage = await notifier.sendTest(timeFormat: prefs.timeFormat) }
                    }
                    if let notificationMessage {
                        Text(notificationMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                let order = prefs.toolOrder
                ForEach(Array(order.enumerated()), id: \.element) { index, tool in
                    HStack(spacing: 10) {
                        Toggle(isOn: Binding(
                            get: { store.isShown(tool) },
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
                        ReorderButtons(
                            up: index > 0 ? { prefs.move(tool, by: -1) } : nil,
                            down: index < order.count - 1 ? { prefs.move(tool, by: 1) } : nil
                        )
                    }
                }
                Button(L("Refresh now")) { store.refreshAll() }
            } header: {
                Text(L("Assistants"))
            } footer: {
                Text(L("The first assistant sits left of the notch and the rest to its right; the panel's cards and the edge pills follow the same order."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(L("Claude Code hook")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Let Claude Code tell the notch when it starts, stops or waits for you. The hook passes on only the event name; the meter refreshes at once and a badge shows while Claude waits for your input."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button(L("Show snippet…")) { showHookSnippet = true }
                        Button(L("Add to settings.json…")) { installHook() }
                    }
                    if let hookMessage {
                        Text(hookMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Text(L("%@ never signs in. It reads usage from tools already signed in on this Mac and keeps no tokens. macOS asks once per tool for permission to read its saved login; choose Always Allow so it stays quiet.", AppInfo.name))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L("Version %@", AppInfo.version))
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
        guard store.isInstalled(tool) else { return L("Not installed on this Mac") }
        switch store.status(tool) {
        case .off: return L("Off")
        case .waiting: return L("Waiting for the first reading")
        case .idle(let message): return message
        case .ready(let reading): return reading.plan.map { L("Signed in · %@", $0) } ?? L("Signed in")
        case .needsAttention(let message, _), .failed(let message, _): return message
        case .notInstalled: return L("Not installed on this Mac")
        }
    }

    /// Asks first; the file is backed up beside itself before anything is merged in.
    private func installHook() {
        let url = HookSettings.settingsURL
        let alert = NSAlert()
        alert.messageText = L("Add the Notchmeter hook to settings.json?")
        alert.informativeText = L("%1$@ is copied to settings.json.bak-<date> first. Hooks already there are kept; Notchmeter's entry is appended under %2$@.",
                                  url.path, HookSettings.events.joined(separator: ", "))
        alert.addButton(withTitle: L("Add"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            hookMessage = try HookSettings.install(at: url).summary
        } catch {
            hookMessage = error.localizedDescription
        }
    }
}

/// Up and down arrows for one row of the Assistants list. Buttons rather than drag-to-reorder: a grouped Form on
/// macOS gives a dragged row no handle and no reliable drop, and arrows are what VoiceOver, the keyboard and an
/// automated tester can drive the same way every time. Nil disables the arrow at that end of the list.
struct ReorderButtons: View {
    let up: (() -> Void)?
    let down: (() -> Void)?

    var body: some View {
        HStack(spacing: 2) {
            Button { up?() } label: { Image(systemName: "chevron.up") }
                .disabled(up == nil)
                .help(L("Move up"))
                .accessibilityLabel(L("Move up"))
            Button { down?() } label: { Image(systemName: "chevron.down") }
                .disabled(down == nil)
                .help(L("Move down"))
                .accessibilityLabel(L("Move down"))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

struct HookSnippetView: View {
    let snippet: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Claude Code hook")).font(.headline)
            Text(L("Merge this into %1$@, or use Add to settings.json… to have it merged for you. Each entry runs %2$@ --hook, which posts the event name to the running app and exits.",
                   HookSettings.settingsURL.path, AppInfo.name))
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
                Button(L("Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                }
                Spacer()
                Button(L("Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 560)
    }
}

/// Settings as a floating panel that never activates the app. Notchmeter is a menu-bar-style accessory, so the
/// app the user was working in stays frontmost while they change a setting, and a tester can drive Settings with
/// Finder in front. The panel becomes key on its own, which is what makes its toggles, pickers and buttons work.
final class SettingsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    /// A grouped Form has no intrinsic height, so the window is sized explicitly.
    nonisolated static let contentSize = NSSize(width: 460, height: 640)
    /// The window's top sits this far below the screen's top safe area: under the notch and the menu bar, with
    /// the collapsed panel's rings clear above it.
    nonisolated static let topClearance: CGFloat = 60

    init(store: UsageStore, prefs: Preferences, actions: NotchActions, notifier: Notifier) {
        let host = NSHostingController(rootView: SettingsView(store: store, prefs: prefs, actions: actions, notifier: notifier))
        let panel = SettingsPanel(contentRect: NSRect(origin: .zero, size: Self.contentSize),
                                  styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = L("%@ Settings", AppInfo.name)
        panel.contentViewController = host
        panel.setContentSize(Self.contentSize)
        panel.minSize = NSSize(width: 460, height: 420)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    /// Centred under the notch, ordered front and made key without activating the app. The panel controller has
    /// collapsed the panel before this is called and holds it closed until the window closes (AppDelegate), so the
    /// two never share the screen with the panel open.
    func present(on screen: NSScreen) {
        guard let window else { return }
        window.setFrame(Self.frame(for: window.frame.size, screen: screen.frame, safeAreaTop: screen.safeAreaInsets.top,
                                   visible: screen.visibleFrame), display: false)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    var isNonActivating: Bool {
        window?.styleMask.contains(.nonactivatingPanel) ?? false
    }

    /// Horizontally centred; the top `topClearance` below the safe area, never below the usable area's bottom.
    nonisolated static func frame(for size: NSSize, screen: NSRect, safeAreaTop: CGFloat, visible: NSRect) -> NSRect {
        let top = screen.maxY - safeAreaTop - topClearance
        let origin = NSPoint(x: (screen.midX - size.width / 2).rounded(), y: max(visible.minY, top - size.height))
        return NSRect(origin: origin, size: size)
    }
}
