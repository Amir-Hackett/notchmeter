import AppKit
import Observation
import ServiceManagement
import SwiftUI

/// What the app delegate asks the Settings window to do beyond showing itself.
@MainActor
@Observable
final class SettingsRequests {
    /// The one-time first-launch offer: open on the Claude Code hook section with the offer sheet up.
    var hookOffer = false
    /// `--smoke`: drive the hook-install sheet against this file instead of settings.json, then close it.
    var hookSheetDryRun: URL?
    var rootsChanged: () -> Void = {}
    var menuBarChanged: () -> Void = {}
    var hotkeysChanged: () -> Void = {}
    var localAPIChanged: () -> Void = {}
    var privacyChanged: () -> Void = {}
}

struct SettingsView: View {
    let store: UsageStore
    let prefs: Preferences
    let actions: NotchActions
    let notifier: Notifier
    let requests: SettingsRequests
    let hostWindow: () -> NSWindow?
    @State private var loginError: String?
    @State private var showHookSnippet = false
    @State private var showStatuslineSnippet = false
    @State private var hookMessage: String?
    @State private var statuslineMessage: String?
    @State private var notificationMessage: String?
    @State private var hookStatus = HookSettings.status()
    @State private var statuslineStatus = HookSettings.statuslineStatus()
    @State private var currencyText = ""
    @State private var rateText = ""

    var body: some View {
        Form {
            generalSection
            panelSection
            shortcutsSection
            usageSection
            privacySection
            notificationsSection
            assistantsSection
            hookSection
            transcriptsSection
            advancedSection
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
            HookSnippetView(title: L("Claude Code hook"), explanation: L("Merge this into %1$@, or use Add to settings.json… to have it merged for you. Each entry runs %2$@ --hook, which posts the event name to the running app and exits.", HookSettings.settingsURL.path, AppInfo.name),
                            snippet: HookSettings.snippet())
        }
        .sheet(isPresented: $showStatuslineSnippet) {
            HookSnippetView(title: L("Claude Code status line"), explanation: L("Set this as statusLine in %1$@, or use Install status line… to have it written for you. Claude Code runs %2$@ --statusline after every turn; it forwards the context fill, the rate limits and the session cost to the app and prints one line for Claude Code's own bar.", HookSettings.settingsURL.path, AppInfo.name),
                            snippet: HookSettings.statuslineSnippet())
        }
        .sheet(isPresented: Binding(get: { requests.hookOffer }, set: { requests.hookOffer = $0 })) {
            HookOfferView(install: { requests.hookOffer = false; installHook() }, later: { requests.hookOffer = false })
        }
        .onAppear {
            prefs.refreshLaunchAtLogin()
            currencyText = prefs.currencyCode
            rateText = prefs.currencyRate == 1 ? "1" : String(prefs.currencyRate)
            refreshHookStatus()
        }
        .onChange(of: requests.hookSheetDryRun) { _, url in
            guard let url else { return }
            installHook(at: url, dryRun: true)
        }
    }

    // MARK: - Sections

    private var generalSection: some View {
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
            .disabled(Translocation.shouldOffer(bundlePath: Bundle.main.bundlePath))
            if Translocation.shouldOffer(bundlePath: Bundle.main.bundlePath) {
                HStack {
                    Text(L("Move %@ to the Applications folder first; a login item cannot point here.", AppInfo.name)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Move to Applications")) { Translocation.offerMove() }
                }
            }
            if prefs.launchAtLoginStatus == .requiresApproval {
                HStack {
                    Text(L("Waiting for your approval in System Settings › General › Login Items.")).font(.caption).foregroundStyle(Palette.warn)
                    Spacer()
                    Button(L("Approve in System Settings")) { SMAppService.openSystemSettingsLoginItems() }
                }
            } else if prefs.launchAtLoginStatus == .notFound, prefs.launchAtLogin {
                Text(L("The login item points at a copy of the app that has moved. Turn it off and on again.")).font(.caption).foregroundStyle(Palette.warn)
            }
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(Palette.danger)
            }
            Toggle(L("Show menu bar icon"), isOn: Binding(
                get: { prefs.showMenuBarItem ?? MenuBarPolicy.defaultShown() },
                set: { prefs.showMenuBarItem = $0; requests.menuBarChanged() }
            ))
            Text(L("Off by default so the menu bar keeps its room; the Options menu is then a right-click on the rings. On, it puts Quit and Settings one click (and VoiceOver's VO-M-M) away, which a Mac without a notch needs."))
                .font(.caption).foregroundStyle(.secondary)
            if prefs.showMenuBarItem ?? MenuBarPolicy.defaultShown() {
                Toggle(L("Pin the first assistant's figures beside the icon"), isOn: Binding(get: { prefs.menuBarPin }, set: { prefs.menuBarPin = $0 }))
            }
        }
    }

    private var panelSection: some View {
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
            Picker(L("Display"), selection: Binding(
                get: { prefs.display },
                set: { prefs.display = $0; actions.applyLayout() }
            )) {
                ForEach(DisplayChoice.fixed, id: \.rawValue) { choice in
                    Text(choice.title).tag(choice)
                }
                ForEach(NSScreen.screens, id: \.localizedName) { screen in
                    Text(screen.localizedName).tag(DisplayChoice.named(screen.localizedName))
                }
            }
            Picker(L("Show"), selection: Binding(
                get: { prefs.visibility },
                set: { prefs.visibility = $0; actions.applyLayout() }
            )) {
                ForEach(NotchVisibility.allCases, id: \.self) { visibility in
                    Text(visibility.title).tag(visibility)
                }
            }
            if prefs.visibility == .onHover || prefs.visibility == .hideWhenIdle {
                Stepper(value: Binding(get: { prefs.hoverDelay }, set: { prefs.hoverDelay = $0 }), in: 0.1...1.0, step: 0.05) {
                    HStack {
                        Text(L("Hover delay"))
                        Spacer()
                        Text(L("%@ s", String(format: "%.2f", prefs.hoverDelay))).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            if prefs.visibility == .hideWhenIdle {
                Text(L("The rings shrink to a dot once no assistant has been active for 30 minutes and every window is quiet; a hook event, file activity, a pace change or resting the pointer on them brings them back."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker(prefs.edge.compactStyleTitle, selection: Binding(get: { prefs.compactStyle }, set: { prefs.compactStyle = $0 })) {
                ForEach(CompactStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if prefs.compactStyle.showsNumbers {
                Toggle(L("Show reset countdown beside the figures"), isOn: Binding(get: { prefs.showResetCountdown }, set: { prefs.showResetCountdown = $0 }))
            }
            Picker(L("Density"), selection: Binding(get: { prefs.density }, set: { prefs.density = $0 })) {
                ForEach(Density.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker(L("Panel width"), selection: Binding(get: { prefs.panelWidth }, set: { prefs.panelWidth = $0 })) {
                ForEach(PanelWidth.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle(L("Show over full-screen apps"), isOn: Binding(get: { prefs.showOverFullScreenApps }, set: { prefs.showOverFullScreenApps = $0; actions.applyLayout() }))
            Toggle(L("Gestures: swipe down to open, swipe up to close"), isOn: Binding(get: { prefs.gesturesEnabled }, set: { prefs.gesturesEnabled = $0 }))
            Toggle(L("Reduce animations"), isOn: Binding(get: { prefs.reduceAnimations }, set: { prefs.reduceAnimations = $0 }))
        }
    }

    private var shortcutsSection: some View {
        Section(L("Keyboard shortcuts")) {
            HotkeyRow(title: L("Toggle the panel"), hotkey: Binding(get: { prefs.togglePanelHotkey }, set: { prefs.togglePanelHotkey = $0; requests.hotkeysChanged() }))
            HotkeyRow(title: L("Open Settings"), hotkey: Binding(get: { prefs.openSettingsHotkey }, set: { prefs.openSettingsHotkey = $0; requests.hotkeysChanged() }))
            Text(L("Global: they work from any app. The panel's own keys: Escape closes it, ⌘R refreshes, ⌘, opens Settings, ⌘Q quits."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var usageSection: some View {
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
            HStack {
                Text(L("Show costs in"))
                Spacer()
                TextField(L("Currency code"), text: $currencyText)
                    .frame(width: 60)
                    .onSubmit { applyCurrency() }
                Text(L("at")).foregroundStyle(.secondary)
                TextField(L("Rate per dollar"), text: $rateText)
                    .frame(width: 80)
                    .onSubmit { applyCurrency() }
                Button(L("Apply")) { applyCurrency() }
            }
            Text(L("Costs are computed in US dollars at API list prices; a code (EUR, GBP, JPY) and your own rate convert them. Nothing is fetched: the rate is yours."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var privacySection: some View {
        Section(L("Privacy")) {
            Toggle(L("Hide usage while the screen is shared or recorded"), isOn: Binding(get: { prefs.hideFromScreenShare }, set: { prefs.hideFromScreenShare = $0; requests.privacyChanged() }))
            Text(L("While Zoom, Meet, QuickTime or Screen Sharing capture the screen, the rings keep their shape but lose their digits and the panel hides the Cost card. Checked every five seconds."))
                .font(.caption).foregroundStyle(.secondary)
            Toggle(L("Local API on 127.0.0.1:%ld", Int(LocalAPI.port)), isOn: Binding(get: { prefs.localAPIEnabled }, set: { prefs.localAPIEnabled = $0; requests.localAPIChanged() }))
            Text(L("GET /v1/limits answers with the same JSON as --probe --json, from the cached readings, for status-line scripts and widgets on this Mac. Loopback only, no authentication; off because it widens the surface of an app whose point is that nothing leaves the Mac."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var notificationsSection: some View {
        Section(L("Notifications")) {
            Toggle(L("Notify when a window is on pace to run out"), isOn: Binding(
                get: { prefs.notificationsEnabled },
                set: { prefs.notificationsEnabled = $0; if $0 { notifier.requestAuthorization() } }
            ))
            Text(L("Once per window and reset period: when its pace first reaches on track or behind, and again when it comes within an hour of running out. Each one says what to do about it. macOS asks for permission when this is turned on or the first alert is due, never at launch."))
                .font(.caption)
                .foregroundStyle(.secondary)
            if prefs.notificationsEnabled {
                Toggle(L("Cutting it close (on track)"), isOn: Binding(get: { prefs.notifyOnTrack }, set: { prefs.notifyOnTrack = $0 }))
                Toggle(L("Will run out (behind pace)"), isOn: Binding(get: { prefs.notifyBehind }, set: { prefs.notifyBehind = $0 }))
                Toggle(L("Almost out (under an hour left)"), isOn: Binding(get: { prefs.notifyRunningOut }, set: { prefs.notifyRunningOut = $0 }))
                Toggle(L("When a window resets"), isOn: Binding(get: { prefs.notifyOnReset }, set: { prefs.notifyOnReset = $0 }))
                Picker(L("Remind me before a reset"), selection: Binding(get: { prefs.resetReminder }, set: { prefs.resetReminder = $0 })) {
                    ForEach(ResetReminder.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text(L("Reset and reminder notices cover windows that were at least 80% used or behind pace when last read."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle(L("Notify when Claude Code waits for you"), isOn: Binding(get: { prefs.notifyWaiting }, set: { prefs.notifyWaiting = $0; if $0 { notifier.requestAuthorization() } }))
            Toggle(L("Notify when a turn finishes"), isOn: Binding(get: { prefs.notifyFinished }, set: { prefs.notifyFinished = $0; if $0 { notifier.requestAuthorization() } }))
            if prefs.notifyFinished {
                Stepper(value: Binding(get: { prefs.finishedAfterMinutes }, set: { prefs.finishedAfterMinutes = $0 }), in: 1...60) {
                    HStack {
                        Text(L("Only turns longer than"))
                        Spacer()
                        Text(L("%ld min", prefs.finishedAfterMinutes)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            Text(L("Both need the Claude Code hook and stay quiet while a terminal or editor is frontmost."))
                .font(.caption).foregroundStyle(.secondary)
            Toggle(L("Sound"), isOn: Binding(get: { prefs.notificationSound }, set: { prefs.notificationSound = $0 }))
            Toggle(L("Quiet hours"), isOn: Binding(get: { prefs.quietHoursEnabled }, set: { prefs.quietHoursEnabled = $0 }))
            if prefs.quietHoursEnabled {
                HStack {
                    QuietHourPicker(title: L("From"), minutes: Binding(get: { prefs.quietHoursStart }, set: { prefs.quietHoursStart = $0 }))
                    QuietHourPicker(title: L("To"), minutes: Binding(get: { prefs.quietHoursEnd }, set: { prefs.quietHoursEnd = $0 }))
                }
            }
            HStack {
                Button(L("Test notification")) {
                    Task { notificationMessage = await notifier.sendTest(timeFormat: prefs.timeFormat) }
                }
                if let notificationMessage {
                    Text(notificationMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var assistantsSection: some View {
        Section {
            let order = prefs.toolOrder
            ForEach(Array(order.enumerated()), id: \.element) { index, tool in
                VStack(alignment: .leading, spacing: 6) {
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
                    if store.isShown(tool), let reading = store.status(tool).reading, reading.windows.count > 1 {
                        WindowChoices(tool: tool, reading: reading, prefs: prefs)
                    }
                    if tool == .codex, store.isShown(tool) {
                        Toggle(L("Also read Codex reset credits"), isOn: Binding(get: { prefs.codexResetCredits }, set: { prefs.codexResetCredits = $0; store.refreshAll() }))
                            .font(.caption)
                        Text(L("A second read of chatgpt.com on the same login, showing a credit that would reset a window and when it expires. Claiming stays in Codex."))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
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
    }

    private var hookSection: some View {
        Section(L("Claude Code hook")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Let Claude Code tell the notch when it starts, stops or waits for you. The hook passes on the event name, the session id and the folder's name; the meter refreshes at once, the card counts sessions, and a badge shows while Claude waits for your input."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(hookStatus.text).font(.caption).foregroundStyle(hookStatusColor(hookStatus))
                HStack {
                    Button(L("Show snippet…")) { showHookSnippet = true }
                    switch hookStatus {
                    case .notInstalled: Button(L("Add to settings.json…")) { installHook() }
                    case .stale: Button(L("Repair")) { repairHook() }
                    case .installed: EmptyView()
                    }
                }
                if let hookMessage {
                    Text(hookMessage).font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Text(L("Claude Code status line")).font(.subheadline.weight(.semibold))
                Text(L("After every turn Claude Code hands its status line the context window's fill, the official session and weekly limits (Pro and Max) and the session's cost. With it installed the Claude ring shows a context arc, the card a Context line, and the endpoint is not asked while a session runs. A status line already configured keeps running after it."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(statuslineStatus.text).font(.caption).foregroundStyle(hookStatusColor(statuslineStatus))
                HStack {
                    Button(L("Show snippet…")) { showStatuslineSnippet = true }
                    Button(statuslineStatus == .notInstalled ? L("Install status line…") : L("Repair")) { installStatusline() }
                        .disabled({ if case .installed = statuslineStatus { return true } else { return false } }())
                }
                if let statuslineMessage {
                    Text(statuslineMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var transcriptsSection: some View {
        Section {
            ForEach(prefs.extraTranscriptRoots, id: \.self) { root in
                HStack {
                    Text(root.replacingOccurrences(of: Paths.home.path, with: "~")).font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(L("Remove")) {
                        prefs.extraTranscriptRoots.removeAll { $0 == root }
                        requests.rootsChanged()
                    }
                    .controlSize(.small)
                }
            }
            Button(L("Add folder…")) { addRoot() }
        } header: {
            Text(L("Also read transcripts from"))
        } footer: {
            Text(L("Synced Claude Code logs from another Mac, or any folder of transcripts: a projects folder or a flat folder of session folders both work. Claude Desktop's Cowork sessions are read automatically when present. The rate-limit meters are account-wide already; this only widens the cost card."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var advancedSection: some View {
        Section(L("Advanced")) {
            Button(L("Reset All Settings…")) { resetAll() }
            Text(L("Puts every setting back to its default, forgets the cached readings and which notifications were sent, and relaunches. Transcripts, the cost cache and the drain log are kept."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private func hookStatusColor(_ status: HookSettings.Status) -> Color {
        switch status {
        case .installed: .secondary
        case .stale: Palette.warn
        case .notInstalled: .secondary
        }
    }

    private func refreshHookStatus() {
        hookStatus = HookSettings.status()
        statuslineStatus = HookSettings.statuslineStatus()
    }

    private func subtitle(for tool: ToolID) -> String {
        guard store.isInstalled(tool) else { return L("Not installed on this Mac") }
        switch store.status(tool) {
        case .off: return L("Off")
        case .waiting: return L("Waiting for the first reading")
        case .idle(let message): return message
        case .ready(let reading): return reading.plan.map { L("Signed in · %@", $0) } ?? L("Signed in")
        case .needsAttention(let message, _), .failed(let message, _): return message
        case .offline: return L("Offline, retrying")
        case .notInstalled: return L("Not installed on this Mac")
        }
    }

    private func applyCurrency() {
        let code = currencyText.trimmingCharacters(in: .whitespaces).uppercased()
        prefs.currencyCode = code.count == 3 ? code : "USD"
        prefs.currencyRate = Double(rateText.replacingOccurrences(of: ",", with: ".")) ?? 1
        currencyText = prefs.currencyCode
        rateText = prefs.currencyRate == 1 ? "1" : String(prefs.currencyRate)
    }

    private func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = L("Add")
        NSApp.activate()
        panel.begin { response in
            guard response == .OK else { return }
            Task { @MainActor in
                for url in panel.urls where !prefs.extraTranscriptRoots.contains(url.path) {
                    prefs.extraTranscriptRoots.append(url.path)
                }
                requests.rootsChanged()
            }
        }
    }

    /// Asks first, as a sheet on the Settings window so Return and Escape reach it; the file is backed up beside
    /// itself before anything is merged in. A dry run (from `--smoke`) writes to the given file and closes itself.
    private func installHook(at url: URL = HookSettings.settingsURL, dryRun: Bool = false) {
        let alert = NSAlert()
        alert.messageText = L("Add the Notchmeter hook to settings.json?")
        alert.informativeText = L("%1$@ is copied to settings.json.bak-<date> first. Hooks already there are kept; Notchmeter's entry is appended under %2$@.",
                                  url.path, HookSettings.events.joined(separator: ", "))
        alert.addButton(withTitle: L("Add"))
        alert.addButton(withTitle: L("Cancel"))
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            defer { if dryRun { requests.hookSheetDryRun = nil } }
            guard response == .alertFirstButtonReturn else { return }
            do {
                hookMessage = try HookSettings.install(at: url).summary
            } catch {
                hookMessage = error.localizedDescription
            }
            if !dryRun { refreshHookStatus() }
        }
        if let window = hostWindow() {
            alert.beginSheetModal(for: window) { response in Task { @MainActor in finish(response) } }
            if dryRun {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    Oracle.shared.emit("settings", ["action": "hookSheet", "attached": window.attachedSheet != nil])
                    Probe.emit("hook sheet: attached to the Settings window=\(window.attachedSheet != nil) dry-run file=\(url.lastPathComponent)")
                    window.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
                }
            }
        } else {
            NSApp.activate()
            finish(alert.runModal())
        }
    }

    private func repairHook() {
        do {
            hookMessage = try HookSettings.repairInstall().summary
        } catch {
            hookMessage = error.localizedDescription
        }
        refreshHookStatus()
    }

    private func installStatusline() {
        let alert = NSAlert()
        alert.messageText = L("Set the Notchmeter status line in settings.json?")
        alert.informativeText = L("%@ is copied to settings.json.bak-<date> first. A status line already there keeps running after Notchmeter's, with the same JSON.", HookSettings.settingsURL.path)
        alert.addButton(withTitle: L("Install"))
        alert.addButton(withTitle: L("Cancel"))
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            do {
                let installed = try HookSettings.installStatusline()
                statuslineMessage = installed.previous.map { L("Installed; your previous status line (%@) runs after it.", $0) } ?? L("Installed.")
            } catch {
                statuslineMessage = error.localizedDescription
            }
            refreshHookStatus()
        }
        if let window = hostWindow() {
            alert.beginSheetModal(for: window) { response in Task { @MainActor in finish(response) } }
        } else {
            NSApp.activate()
            finish(alert.runModal())
        }
    }

    private func resetAll() {
        let alert = NSAlert()
        alert.messageText = L("Reset all settings?")
        alert.informativeText = L("Every setting returns to its default and %@ relaunches. This cannot be undone.", AppInfo.name)
        alert.addButton(withTitle: L("Reset and Relaunch"))
        alert.addButton(withTitle: L("Cancel"))
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            Preferences.resetAll()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", Bundle.main.bundlePath]
            try? process.run()
            NSApp.terminate(nil)
        }
        if let window = hostWindow() {
            alert.beginSheetModal(for: window) { response in Task { @MainActor in finish(response) } }
        } else {
            NSApp.activate()
            finish(alert.runModal())
        }
    }
}

/// Whether the menu bar item shows by default: only when the notch layout has no notch to show the rings beside.
enum MenuBarPolicy {
    @MainActor static func defaultShown(edge: PanelEdge? = nil, screens: [NSScreen] = NSScreen.screens) -> Bool {
        let hasNotch = screens.contains { $0.safeAreaInsets.top > 0 }
        return !hasNotch && (edge ?? .top) == .top
    }
}

/// Which two windows the rings show, and which windows the card leaves out, per tool.
private struct WindowChoices: View {
    let tool: ToolID
    let reading: UsageReading
    let prefs: Preferences

    var body: some View {
        let chosen = prefs.ringWindows[tool] ?? []
        let ring = RingSelection.windows(of: reading, chosen: chosen, hidden: prefs.hiddenWindows[tool] ?? [])
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L("Rings show")).font(.caption)
                Picker(L("Outer ring"), selection: Binding(get: { ring.first?.id ?? "" }, set: { set(outer: $0, inner: ring.dropFirst().first?.id) })) {
                    ForEach(prefs.shownWindows(of: reading)) { window in Text(window.label).tag(window.id) }
                }
                .labelsHidden().controlSize(.small)
                Picker(L("Inner ring"), selection: Binding(get: { ring.dropFirst().first?.id ?? "" }, set: { set(outer: ring.first?.id, inner: $0) })) {
                    ForEach(prefs.shownWindows(of: reading)) { window in Text(window.label).tag(window.id) }
                }
                .labelsHidden().controlSize(.small)
            }
            HStack(spacing: 8) {
                Text(L("Hide")).font(.caption)
                ForEach(reading.windows) { window in
                    Toggle(window.label, isOn: Binding(get: { prefs.isHidden(window, of: tool) }, set: { prefs.setHidden($0, window: window.id, of: tool) }))
                        .toggleStyle(.checkbox).controlSize(.small).font(.caption)
                }
            }
        }
        .padding(.leading, 20)
    }

    private func set(outer: String?, inner: String?) {
        prefs.ringWindows[tool] = [outer, inner].compactMap { $0 }.filter { !$0.isEmpty }
    }
}

/// A shortcut recorder: press Record, then the combination; Clear removes it.
struct HotkeyRow: View {
    let title: String
    @Binding var hotkey: Hotkey?
    @State private var recording = false
    @State private var monitor = MonitorBox()

    final class MonitorBox {
        var token: Any?
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(recording ? L("Press keys…") : hotkey?.description ?? L("None"))
                .foregroundStyle(recording ? Palette.calm : .secondary)
                .monospacedDigit()
                .frame(minWidth: 80, alignment: .trailing)
            Button(recording ? L("Cancel") : L("Record")) { recording ? stop() : start() }
                .controlSize(.small)
            Button(L("Clear")) { hotkey = nil }
                .controlSize(.small)
                .disabled(hotkey == nil)
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor.token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let captured = Hotkey(event: event)
            Task { @MainActor in
                if event.keyCode == 53 { stop(); return }
                if let captured {
                    hotkey = captured
                    stop()
                }
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let token = monitor.token { NSEvent.removeMonitor(token) }
        monitor.token = nil
    }
}

private struct QuietHourPicker: View {
    let title: String
    @Binding var minutes: Int

    var body: some View {
        Picker(title, selection: $minutes) {
            ForEach(Array(stride(from: 0, to: 24 * 60, by: 30)), id: \.self) { value in
                Text(Self.label(value)).tag(value)
            }
        }
    }

    static func label(_ minutes: Int) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        let date = Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
        return formatter.string(from: date)
    }
}

/// The one-time first-launch offer: opt in with a click, never automatic.
struct HookOfferView: View {
    let install: () -> Void
    let later: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Let Claude Code talk to the notch?")).font(.headline)
            Text(L("One entry in ~/.claude/settings.json makes Claude Code run %@ --hook when a session starts, a turn ends or it waits for you: the meter refreshes at once, the card counts sessions, and a dot shows while Claude waits. The file is backed up first, and you can remove it any time from this section.", AppInfo.name))
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L("Not now")) { later() }.keyboardShortcut(.cancelAction)
                Button(L("Add to settings.json…")) { install() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 460)
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
    let title: String
    let explanation: String
    let snippet: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text(explanation)
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
/// Escape and ⌘W close it (the main menu carries ⌘W; Escape is handled here).
final class SettingsPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    /// A grouped Form has no intrinsic height, so the window is sized explicitly.
    nonisolated static let contentSize = NSSize(width: 460, height: 640)
    /// The window's top sits this far below the screen's top safe area: under the notch and the menu bar, with
    /// the collapsed panel's rings clear above it.
    nonisolated static let topClearance: CGFloat = 60

    init(store: UsageStore, prefs: Preferences, actions: NotchActions, notifier: Notifier, requests: SettingsRequests) {
        let panel = SettingsPanel(contentRect: NSRect(origin: .zero, size: Self.contentSize),
                                  styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        let host = NSHostingController(rootView: SettingsView(store: store, prefs: prefs, actions: actions, notifier: notifier, requests: requests,
                                                               hostWindow: { [weak panel] in panel }))
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

    /// Centred under the notch (or the top of the chosen screen), ordered front and made key without activating
    /// the app. The panel controller has collapsed the panel before this is called and holds it closed until the
    /// window closes (AppDelegate), so the two never share the screen with the panel open.
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
