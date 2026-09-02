import AppKit
import Observation
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// What the app delegate asks the Settings window to do beyond showing itself.
@MainActor
@Observable
final class SettingsRequests {
    /// The one-time first-launch offer: open on the Claude Code hook section with the offer sheet up.
    var hookOffer = false
    /// `--smoke`: drive the hook-install sheet against this file instead of settings.json, then close it.
    var hookSheetDryRun: URL?
    /// The outcome of the last "Install command line tool…" press.
    var commandLineToolMessage: String?
    var rootsChanged: () -> Void = {}
    var menuBarChanged: () -> Void = {}
    var hotkeysChanged: () -> Void = {}
    var localAPIChanged: () -> Void = {}
    var privacyChanged: () -> Void = {}
    var awakeChanged: () -> Void = {}
    var diagnostics: () -> String = { "" }
    var installCommandLineTool: () -> Void = {}
    var updater: () -> Updater? = { nil }
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
    @State private var showMCPSnippet = false
    @State private var hookMessage: String?
    @State private var statuslineMessage: String?
    @State private var notificationMessage: String?
    @State private var diagnosticsMessage: String?
    @State private var exportMessage: String?
    @State private var hookStatus = HookSettings.status()
    @State private var statuslineStatus = HookSettings.statuslineStatus()
    @State private var currencyText = ""
    @State private var rateText = ""
    @State private var monthlyBudgetText = ""
    @State private var weeklyBudgetText = ""
    @State private var proxyText = ""
    @State private var accessibilityTrusted = MenuBarExtent.isTrusted
    @State private var originText = ""

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
            integrationsSection
            transcriptsSection
            updatesSection
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
        .sheet(isPresented: $showMCPSnippet) {
            HookSnippetView(title: L("MCP server"), explanation: L("Paste this into the MCP configuration of Cursor, Codex or Claude Desktop. The server speaks JSON-RPC over stdio and offers one tool, get_limits, which answers with the same object as --probe --json, from the running app's cache when it has one."),
                            snippet: MCPServer.snippet(executable: HookSettings.executablePath))
        }
        .sheet(isPresented: Binding(get: { requests.hookOffer }, set: { requests.hookOffer = $0 })) {
            HookOfferView(install: { requests.hookOffer = false; installHook() }, later: { requests.hookOffer = false })
        }
        .onAppear {
            prefs.refreshLaunchAtLogin()
            currencyText = prefs.currencyCode
            rateText = prefs.currencyRate == 1 ? "1" : String(prefs.currencyRate)
            monthlyBudgetText = prefs.monthlyBudgetUSD.map { Self.budgetText($0) } ?? ""
            weeklyBudgetText = prefs.weeklyBudgetUSD.map { Self.budgetText($0) } ?? ""
            proxyText = prefs.proxyURL
            accessibilityTrusted = MenuBarExtent.isTrusted
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
                set: { prefs.showSpend = $0; if $0 { store.refreshAll(interactive: true) } }
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
            Picker(L("Language"), selection: Binding(get: { prefs.language ?? "" }, set: { prefs.language = $0.isEmpty ? nil : $0 })) {
                Text(L("System")).tag("")
                ForEach(Localization.languages, id: \.self) { code in
                    Text(Localization.nativeNames[code] ?? code).tag(code)
                }
            }
            HStack {
                Text(L("Takes effect at relaunch.")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Relaunch")) { relaunch() }.controlSize(.small)
            }
            Toggle(L("Show menu bar icon"), isOn: Binding(
                get: { prefs.showMenuBarItem ?? MenuBarPolicy.defaultShown() },
                set: { prefs.showMenuBarItem = $0; requests.menuBarChanged() }
            ))
            Text(L("Off by default so the menu bar keeps its room; the Options menu is then a right-click on the rings. On, it puts Quit and Settings one click (and VoiceOver's VO-M-M) away, which a Mac without a notch needs."))
                .font(.caption).foregroundStyle(.secondary)
            if prefs.showMenuBarItem ?? MenuBarPolicy.defaultShown() {
                Toggle(L("Pin figures beside the icon"), isOn: Binding(get: { prefs.menuBarPin }, set: { prefs.menuBarPin = $0 }))
                if prefs.menuBarPin {
                    Picker(L("Icon style"), selection: Binding(get: { prefs.menuBarStyle }, set: { prefs.menuBarStyle = $0 })) {
                        ForEach(MenuBarStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Text(L("Which assistants are pinned is chosen per assistant below; with none chosen, the first visible one is. Bars draws each pinned window as a mini bar, tinted by its pace."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(L("Install command line tool…")) { requests.installCommandLineTool() }
                if let installed = CommandLineTool.installedLink() {
                    Text(installed.link.path.replacingOccurrences(of: Paths.home.path, with: "~")).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Text(L("Links `notchmeter` in ~/.local/bin (or /usr/local/bin) to this app, so `notchmeter` in a terminal or a Claude Code skill reads the running app's cached report instead of asking every vendor again; `notchmeter --force` reads afresh."))
                .font(.caption).foregroundStyle(.secondary)
            if let message = requests.commandLineToolMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var panelSection: some View {
        Section(L("Panel")) {
            Picker(L("Readouts"), selection: Binding(
                get: { prefs.compactSide },
                set: { actions.chooseCompactSide($0); accessibilityTrusted = MenuBarExtent.isTrusted }
            )) {
                ForEach(CompactSide.allCases, id: \.self) { side in
                    Text(side.title).tag(side)
                }
            }
            Text(L("Both sides reads as centred on the notch. An app with many menus can reach past its left edge; right of the notch always clears them."))
                .font(.caption).foregroundStyle(.secondary)
            if prefs.compactSide == .auto {
                Text(L("Auto measures how far the frontmost app's menu titles reach: both sides while they end clear of the left-hand readouts, right of the notch while they would run into them. It measures when an app comes forward and remembers each app."))
                    .font(.caption).foregroundStyle(.secondary)
                if !accessibilityTrusted {
                    Text(L("Accessibility is off, so Auto stays on the side chosen before it. Notchmeter reads the frontmost app's menu bar geometry and nothing else; no other part of the app asks for Accessibility."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(L("Open Accessibility settings…")) {
                        MenuBarExtent.openSettings()
                        accessibilityTrusted = MenuBarExtent.isTrusted
                    }
                }
            }
            Toggle(L("Show details"), isOn: Binding(
                get: { prefs.showDetails },
                set: { prefs.showDetails = $0 }
            ))
            Text(L("The Cost card past its donut, legend and burn line (the budget, week and model lines), the session block, tokens, top projects and the sparklines. Off keeps the panel short enough not to scroll."))
                .font(.caption).foregroundStyle(.secondary)
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
                let screens = NSScreen.screens
                let keys = DisplayIdentity.keys(for: screens)
                let titles = DisplayIdentity.titles(for: screens.map(\.localizedName))
                ForEach(Array(screens.indices), id: \.self) { index in
                    Text(titles[index]).tag(DisplayChoice.named(keys[index]))
                }
            }
            Text(prefs.display == .pointer
                 ? L("The panel follows the pointer: it moves to the display the pointer has rested on for half a second.")
                 : L("A named display is remembered by its hardware identity, so two monitors of one model are told apart and a rename does not lose it."))
                .font(.caption).foregroundStyle(.secondary)
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
            Text(L("Off, the rings and the panel stay off a full-screen app's Space and the hover machine idles there, so a pointer parked at the top of that Space opens nothing."))
                .font(.caption).foregroundStyle(.secondary)
            Toggle(L("Gestures: swipe down to open, swipe up to close"), isOn: Binding(get: { prefs.gesturesEnabled }, set: { prefs.gesturesEnabled = $0 }))
            Toggle(L("Reduce animations"), isOn: Binding(get: { prefs.reduceAnimations }, set: { prefs.reduceAnimations = $0 }))
        }
    }

    private var shortcutsSection: some View {
        Section(L("Keyboard shortcuts")) {
            HotkeyRow(title: L("Toggle the panel"), hotkey: Binding(get: { prefs.togglePanelHotkey }, set: { prefs.togglePanelHotkey = $0; requests.hotkeysChanged() }))
            HotkeyRow(title: L("Open Settings"), hotkey: Binding(get: { prefs.openSettingsHotkey }, set: { prefs.openSettingsHotkey = $0; requests.hotkeysChanged() }))
            Text(L("Global: they work from any app; with All displays, the panel on the display under the pointer answers. The panel's own keys, when it was opened by a click, a swipe, the shortcut or a notification: Escape closes it, ⌘R refreshes, ⌘, opens Settings, ⌘Q quits. A hover-opened panel never takes the keyboard."))
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
            HStack {
                Text(L("Monthly budget"))
                Spacer()
                TextField(Money.code, text: $monthlyBudgetText).frame(width: 90).onSubmit { applyBudgets() }
                Text(L("Weekly")).foregroundStyle(.secondary)
                TextField(Money.code, text: $weeklyBudgetText).frame(width: 90).onSubmit { applyBudgets() }
                Button(L("Apply")) { applyBudgets() }
            }
            Text(L("In the currency above; leave empty for none. The Cost card's ring fills against the month's budget with the same pace tick the meters use, the Advice strip projects the month against it, and the on-track, behind and run-out notifications apply to it with the month as the period."))
                .font(.caption).foregroundStyle(.secondary)
            Picker(L("Cost card shows"), selection: Binding(get: { prefs.costCardMode }, set: { prefs.costCardMode = $0 })) {
                ForEach(CostCardMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            HStack(spacing: 10) {
                Text(L("In the Cost card"))
                Spacer()
                ForEach(ToolID.allCases.filter(\.reportsCost), id: \.self) { tool in
                    Toggle(isOn: Binding(
                        get: { prefs.costCardTools.contains(tool) },
                        set: { if $0 { prefs.costCardTools.insert(tool) } else { prefs.costCardTools.remove(tool) } }
                    )) {
                        Text(verbatim: tool.displayName)
                    }
                    .toggleStyle(.checkbox).controlSize(.small)
                }
            }
            Text(L("Which assistants the card's donut, legend and total carry, in the order set under Assistants. One that cannot report spend is never offered; one left out still shows its own spend on its own card."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var privacySection: some View {
        Section(L("Privacy")) {
            Toggle(L("Hide usage while the screen is shared or recorded"), isOn: Binding(get: { prefs.hideFromScreenShare }, set: { prefs.hideFromScreenShare = $0; requests.privacyChanged() }))
            Text(L("While Zoom, Meet, QuickTime or Screen Sharing capture the screen, the rings keep their shape but lose their digits and the panel hides the Cost card. Checked every five seconds."))
                .font(.caption).foregroundStyle(.secondary)
            Picker(L("Ask for Keychain access"), selection: Binding(get: { prefs.keychainPrompts }, set: { prefs.keychainPrompts = $0 })) {
                ForEach(KeychainPromptPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Text(L("Claude Code recreates its Keychain item on every token refresh, which forgets the Always Allow you gave. A timed read never raises the dialog: it reads the item through Apple's security tool, which Claude Code wrote it with, then the credentials file, then the status line, and otherwise keeps the last reading marked \"needs your OK\". Only a click on the Claude ring, Refresh or the Assistants toggle may ask, and only under On Refresh only."))
                .font(.caption).foregroundStyle(.secondary)
            Toggle(L("Local API on 127.0.0.1:%ld", Int(LocalAPI.port)), isOn: Binding(get: { prefs.localAPIEnabled }, set: { prefs.localAPIEnabled = $0; requests.localAPIChanged() }))
            Text(L("GET /v1/limits answers with the same JSON as --probe --json, from the cached readings, for status-line scripts, widgets and the command-line tool on this Mac; POST /v1/hook takes a remote machine's Claude Code hook events over an SSH tunnel. Loopback only, no authentication; a request from a web page (one carrying an Origin header) is refused unless its origin is listed below, and the Host header must be the loopback address."))
                .font(.caption).foregroundStyle(.secondary)
            if prefs.localAPIEnabled {
                ForEach(prefs.localAPIOrigins, id: \.self) { origin in
                    HStack {
                        Text(origin).font(.caption)
                        Spacer()
                        Button(L("Remove")) { prefs.localAPIOrigins.removeAll { $0 == origin } }.controlSize(.small)
                    }
                }
                HStack {
                    TextField(L("Allowed origin, e.g. http://localhost:3000"), text: $originText)
                    Button(L("Add")) {
                        let trimmed = originText.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty, !prefs.localAPIOrigins.contains(trimmed) { prefs.localAPIOrigins.append(trimmed) }
                        originText = ""
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var notificationsSection: some View {
        Section(L("Notifications")) {
            Toggle(L("Notify when a window is on pace to run out"), isOn: Binding(
                get: { prefs.notificationsEnabled },
                set: { prefs.notificationsEnabled = $0; if $0 { notifier.requestAuthorization() } }
            ))
            Text(L("Once per window and reset period: when its pace first reaches on track or behind, again when it comes within an hour of running out, and once more when it is out. Each one says what to do about it. macOS asks for permission when this is turned on or the first alert is due, never at launch."))
                .font(.caption)
                .foregroundStyle(.secondary)
            if prefs.notificationsEnabled {
                Toggle(L("Cutting it close (on track)"), isOn: Binding(get: { prefs.notifyOnTrack }, set: { prefs.notifyOnTrack = $0 }))
                Toggle(L("Will run out (behind pace)"), isOn: Binding(get: { prefs.notifyBehind }, set: { prefs.notifyBehind = $0 }))
                Toggle(L("Almost out (under an hour left), and out"), isOn: Binding(get: { prefs.notifyRunningOut }, set: { prefs.notifyRunningOut = $0 }))
                Toggle(L("When a window resets"), isOn: Binding(get: { prefs.notifyOnReset }, set: { prefs.notifyOnReset = $0 }))
                Picker(L("Remind me before a reset"), selection: Binding(get: { prefs.resetReminder }, set: { prefs.resetReminder = $0 })) {
                    ForEach(ResetReminder.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text(L("Reset and reminder notices cover windows that were at least 80% used or behind pace when last read; a window's pace notices are withdrawn from Notification Center when it resets."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(L("When you start paying (extra usage rises)"), isOn: Binding(get: { prefs.notifyExtraUsage }, set: { prefs.notifyExtraUsage = $0 }))
                Text(L("Once a month when Claude's extra-usage credits first rise, and within the hour whenever they rise while the plan windows still have room: the sign that work is being billed instead of drawn from the plan. Every rise is written to the drain log with the plan windows beside it."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(L("When the cache tier or the metering shifts"), isOn: Binding(get: { prefs.notifyCacheShift }, set: { prefs.notifyCacheShift = $0 }))
                Text(L("Once a day when today's cache writes moved to the 5-minute tier against the 30-day norm, or the session meters about twice as heavily as usual."))
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
            Picker(L("When Claude Code waits for you or a turn finishes"), selection: Binding(get: { prefs.sessionAttention }, set: { prefs.sessionAttention = $0 })) {
                ForEach(SessionAttention.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Text(L("Both need the Claude Code hook and stay quiet while a terminal or editor is frontmost and inside the quiet hours. A glance opens the panel for a few seconds with the session line and settles again unless the pointer comes in; under Reduce Motion it opens without animation and stays a little longer. A \"waiting\" notice is withdrawn when you answer. In an unsigned build no notice can break through Focus or Do Not Disturb; the time-sensitive ones (running out, waiting for you) do in the signed release."))
                .font(.caption).foregroundStyle(.secondary)
            Toggle(L("Sound"), isOn: Binding(get: { prefs.notificationSound }, set: { prefs.notificationSound = $0 }))
            if prefs.notificationSound {
                SoundPicker(title: L("Pace crossing"), choice: Binding(get: { prefs.soundPace }, set: { prefs.soundPace = $0 }))
                SoundPicker(title: L("Waiting for you"), choice: Binding(get: { prefs.soundWaiting }, set: { prefs.soundWaiting = $0 }))
                SoundPicker(title: L("Turn finished"), choice: Binding(get: { prefs.soundFinished }, set: { prefs.soundFinished = $0 }))
                Text(L("A chosen file is copied into ~/Library/Sounds, where Notification Center can play it."))
                    .font(.caption).foregroundStyle(.secondary)
            }
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
                    if store.isShown(tool) {
                        HStack(spacing: 8) {
                            Toggle(L("Pin to menu bar"), isOn: Binding(
                                get: { prefs.menuBarPinnedTools.contains(tool) },
                                set: { if $0 { prefs.menuBarPinnedTools.insert(tool) } else { prefs.menuBarPinnedTools.remove(tool) } }
                            ))
                            .toggleStyle(.checkbox).controlSize(.small).font(.caption)
                            Toggle(L("Peak hours"), isOn: Binding(
                                get: { prefs.peakHoursTools.contains(tool) },
                                set: { if $0 { prefs.peakHoursTools.insert(tool) } else { prefs.peakHoursTools.remove(tool) } }
                            ))
                            .toggleStyle(.checkbox).controlSize(.small).font(.caption)
                        }
                        .padding(.leading, 20)
                    }
                    if tool == .claude, store.isShown(tool) {
                        Toggle(L("Keep the Mac awake while Claude Code is working"), isOn: Binding(get: { prefs.keepAwake }, set: { prefs.keepAwake = $0; requests.awakeChanged() }))
                            .font(.caption)
                        if prefs.keepAwake {
                            Toggle(L("Also on battery"), isOn: Binding(get: { prefs.keepAwakeOnBattery }, set: { prefs.keepAwakeOnBattery = $0; requests.awakeChanged() }))
                                .font(.caption)
                        }
                        Text(L("A sleep assertion held only while a session the hook reports is mid-turn, released at its Stop, so a session started from a phone or over SSH keeps running with the lid closed on power. The footer says \"Keeping awake · 2 sessions\" while it is held."))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if tool == .codex, store.isShown(tool) {
                        Toggle(L("Also read Codex reset credits"), isOn: Binding(get: { prefs.codexResetCredits }, set: { prefs.codexResetCredits = $0; store.refreshAll() }))
                            .font(.caption)
                        Text(L("A second read of chatgpt.com on the same login, showing a credit that would reset a window and when it expires. Claiming stays in Codex."))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if tool == .cursor, store.isShown(tool) {
                        Toggle(L("Also read Cursor's usage events"), isOn: Binding(get: { prefs.cursorUsageEvents }, set: { prefs.cursorUsageEvents = $0; store.refreshAll() }))
                            .font(.caption)
                        Text(L("A second read of cursor.com on the same session cookie: the last 30 days of usage events, priced by their exported cost, folded into the daily-totals file as a Cursor series (Today, 30 days and the trend)."))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if tool == .copilot, store.isShown(tool) {
                        Toggle(L("Also read organisation billing"), isOn: Binding(get: { prefs.copilotOrgBilling }, set: { prefs.copilotOrgBilling = $0; store.refreshAll() }))
                            .font(.caption)
                        Text(L("One more endpoint on the same token: each organisation you belong to that answers (owners and billing managers) adds hidden-by-default Org credits and Org spend windows for the month."))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Button(L("Refresh now")) { store.refreshAll(interactive: true) }
        } header: {
            Text(L("Assistants"))
        } footer: {
            Text(L("The first assistant sits left of the notch and the rest to its right; the panel's cards and the edge pills follow the same order. Peak hours applies Anthropic's weekday window (Advanced) to that assistant's advice and projections."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var hookSection: some View {
        Section(L("Claude Code hook")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Let Claude Code tell the notch when it starts, stops or waits for you. The hook passes on the event name, the session id, the folder's name, its git branch, the permission mode, subagent starts and stops, and a stop on a rate limit; the meter refreshes at once, the card counts sessions and agents, and a badge shows while Claude waits for your input."))
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
                Toggle(L("Repair a hook that points at an old copy at launch"), isOn: Binding(get: { prefs.autoRepairHooks }, set: { prefs.autoRepairHooks = $0 }))
                    .font(.caption)
                Text(L("After a move to Applications or an update, an entry that names an old path of this app is rewritten to the running copy at launch, after the usual backup, and the footer says so once. Never from a build folder, never under --smoke."))
                    .font(.caption2).foregroundStyle(.secondary)
                Divider()
                Text(L("Claude Code status line")).font(.subheadline.weight(.semibold))
                Text(L("After every turn Claude Code hands its status line the context window's fill, the official session and weekly limits (Pro and Max), a gateway's spend limit, the model and its effort, the branch and pull request, and the session's cost. With it installed the Claude ring shows a context arc, the card a Context line, and the endpoint is not asked while a session runs. A status line already configured keeps running after it."))
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

    private var integrationsSection: some View {
        Section(L("Other tools")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("MCP server")).font(.subheadline.weight(.semibold))
                Text(L("Cursor, Codex and Claude Desktop can ask for the limits through the Model Context Protocol: `%@ --mcp` speaks JSON-RPC over stdio with one tool, get_limits.", AppInfo.name))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L("Show snippet…")) { showMCPSnippet = true }
                Divider()
                Text(L("Remote Claude Code over SSH")).font(.subheadline.weight(.semibold))
                Text(L("With the local API on, a hook on another machine reaches this notch through `ssh -R %1$ld:127.0.0.1:%1$ld host`: its command is `curl -s -X POST http://127.0.0.1:%1$ld/v1/hook -d @-` with a `host` label; the recipe is in docs/hooks.md.", Int(LocalAPI.port)))
                    .font(.caption).foregroundStyle(.secondary)
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

    @ViewBuilder private var updatesSection: some View {
        if let updater = requests.updater() {
            Section(L("Updates")) {
                Toggle(L("Check for updates automatically"), isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 }))
                Toggle(L("Download updates automatically"), isOn: Binding(get: { updater.automaticallyDownloads }, set: { updater.automaticallyDownloads = $0 }))
                Toggle(L("Beta updates"), isOn: Binding(get: { prefs.betaUpdates }, set: { prefs.betaUpdates = $0 }))
                HStack {
                    Text(updater.lastCheck.map { L("Last checked %@", RelativeTime.ago($0)) } ?? L("Not checked yet")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Check for Updates…")) { updater.checkForUpdates() }
                }
            }
        }
    }

    private var advancedSection: some View {
        Section(L("Advanced")) {
            PeakHoursEditor(prefs: prefs)
            HStack {
                Text(L("Route requests through"))
                Spacer()
                TextField(L("System (default)"), text: $proxyText).frame(width: 220).onSubmit { applyProxy() }
                Button(L("Apply")) { applyProxy() }
            }
            Text(L("Empty follows the proxy in Network settings; `http://host:port` or `socks5://host:port` routes only this app's vendor requests through it, from the next request on."))
                .font(.caption).foregroundStyle(.secondary)
            Toggle(L("Debug logging"), isOn: Binding(get: { prefs.debugLogging }, set: { prefs.debugLogging = $0 }))
            Text(L("Writes each vendor request's outcome (status code and size, never a token or a body) to the unified log at info level, where Copy diagnostics and `log show --info` pick it up."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L("Copy diagnostics")) {
                    let text = requests.diagnostics()
                    Diagnostics.copy(text)
                    diagnosticsMessage = L("Copied %ld lines.", text.split(separator: "\n").count)
                }
                if let diagnosticsMessage {
                    Text(diagnosticsMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(L("The last 10 minutes of this app's unified log, each assistant's status, the hook and status-line state, the layout and the macOS version, scrubbed of your home folder, for a bug report. Never a token."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L("Export history…")) { exportHistory() }
                if let exportMessage {
                    Text(exportMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(L("The daily-totals file as CSV or JSON: one row per day with the cost, the five token buckets, the top model and the per-model and per-project cost."))
                .font(.caption).foregroundStyle(.secondary)
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

    static func budgetText(_ usd: Double) -> String {
        let amount = usd * Money.rate
        return amount == amount.rounded() ? String(Int(amount)) : String(format: "%.2f", amount)
    }

    /// The typed amount is in the user's currency; stored in US dollars.
    static func budgetUSD(_ text: String, rate: Double) -> Double? {
        guard let amount = Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")), amount > 0, rate > 0 else { return nil }
        return amount / rate
    }

    private func applyBudgets() {
        prefs.monthlyBudgetUSD = Self.budgetUSD(monthlyBudgetText, rate: Money.rate)
        prefs.weeklyBudgetUSD = Self.budgetUSD(weeklyBudgetText, rate: Money.rate)
        monthlyBudgetText = prefs.monthlyBudgetUSD.map { Self.budgetText($0) } ?? ""
        weeklyBudgetText = prefs.weeklyBudgetUSD.map { Self.budgetText($0) } ?? ""
    }

    private func applyProxy() {
        let trimmed = proxyText.trimmingCharacters(in: .whitespaces)
        prefs.proxyURL = ProxySettings.dictionary(for: trimmed) != nil ? trimmed : ""
        proxyText = prefs.proxyURL
    }

    private func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
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

    private func exportHistory() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText, .json]
        panel.nameFieldStringValue = "notchmeter-history.csv"
        panel.canSelectHiddenExtension = true
        NSApp.activate()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                let records = CostHistory().load()
                let data = url.pathExtension.lowercased() == "json" ? CostHistory.json(records) : Data(CostHistory.csv(records).utf8)
                do {
                    try data.write(to: url, options: .atomic)
                    exportMessage = L("Wrote %ld days to %@.", records.count, url.lastPathComponent)
                } catch {
                    exportMessage = error.localizedDescription
                }
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
            relaunch()
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
        let ring = prefs.ringWindows(of: reading)
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
                    Toggle(window.label, isOn: Binding(get: { prefs.isHidden(window, of: tool) }, set: { prefs.setHidden($0, window: window, of: tool) }))
                        .toggleStyle(.checkbox).controlSize(.small).font(.caption)
                }
            }
            let _ = chosen
        }
        .padding(.leading, 20)
    }

    private func set(outer: String?, inner: String?) {
        prefs.ringWindows[tool] = [outer, inner].compactMap { $0 }.filter { !$0.isEmpty }
    }
}

/// One event class's sound: the system alert sounds, the user's imported files, none, or a file to import.
private struct SoundPicker: View {
    let title: String
    @Binding var choice: String

    var body: some View {
        HStack {
            Picker(title, selection: $choice) {
                Text(L("Default")).tag(NotificationSound.defaultChoice)
                Text(L("None")).tag(NotificationSound.none)
                Divider()
                ForEach(NotificationSound.systemSounds(), id: \.self) { name in Text(name).tag("system:\(name)") }
                let custom = NotificationSound.customSounds()
                if !custom.isEmpty {
                    Divider()
                    ForEach(custom, id: \.self) { name in Text((name as NSString).deletingPathExtension).tag("custom:\(name)") }
                }
            }
            Button(L("Preview")) { NotificationSound.preview(choice) }.controlSize(.small)
            Button(L("Choose file…")) { chooseFile() }.controlSize(.small)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        NSApp.activate()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                if let imported = try? NotificationSound.importCustom(url) { choice = imported }
            }
        }
    }
}

/// Anthropic's peak window, editable: the hours in Pacific time and the weekday rule.
private struct PeakHoursEditor: View {
    let prefs: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(L("Peak hours (Anthropic's tighter session limits)"), isOn: Binding(get: { prefs.peakHours.enabled }, set: { prefs.peakHours.enabled = $0 }))
            if prefs.peakHours.enabled {
                HStack {
                    QuietHourPicker(title: L("From"), minutes: Binding(get: { prefs.peakHours.startMinute }, set: { prefs.peakHours.startMinute = $0 }))
                    QuietHourPicker(title: L("To"), minutes: Binding(get: { prefs.peakHours.endMinute }, set: { prefs.peakHours.endMinute = $0 }))
                    Text(prefs.peakHours.timeZone.abbreviation() ?? prefs.peakHours.timeZoneID).font(.caption).foregroundStyle(.secondary)
                    Toggle(L("Weekdays only"), isOn: Binding(get: { prefs.peakHours.weekdaysOnly }, set: { prefs.peakHours.weekdaysOnly = $0 }))
                        .toggleStyle(.checkbox).controlSize(.small).font(.caption)
                }
            }
            Text(L("Since March 2026 Anthropic applies tighter 5-hour session limits on weekdays from 5:00 to 11:00 Pacific (reported, not documented; docs/accuracy.md). Inside it the advice names when off-peak starts, the drain log keeps peak and off-peak rates apart, and the footer says \"peak hours\". Applies to the assistants ticked under Assistants."))
                .font(.caption).foregroundStyle(.secondary)
        }
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
    /// Gap between the readouts' lower edge and the window below them.
    nonisolated static let readoutClearance: CGFloat = 12

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
    /// `above` is the panel's window level. The panel sits at screen-saver level so it can draw over the menu
    /// bar, and it collapses out of the way asynchronously; ordering this window above it keeps the settings
    /// visible from the first frame rather than for the tail of that animation.
    func present(on screen: NSScreen, below readouts: CGRect? = nil, above panelLevel: NSWindow.Level? = nil) {
        guard let window else { return }
        if let panelLevel { window.level = Self.level(above: panelLevel) }
        window.setFrame(Self.frame(for: window.frame.size, screen: screen.frame, safeAreaTop: screen.safeAreaInsets.top,
                                   visible: screen.visibleFrame, readouts: readouts), display: false)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    var isNonActivating: Bool {
        window?.styleMask.contains(.nonactivatingPanel) ?? false
    }

    /// One level above the panel, and never below `.floating` so the window still sits over ordinary app
    /// windows when the panel is at a lower level than that. `--smoke` asserts the same relation.
    nonisolated static func level(above panelLevel: NSWindow.Level) -> NSWindow.Level {
        NSWindow.Level(rawValue: max(NSWindow.Level.floating.rawValue, panelLevel.rawValue + 1))
    }

    /// Horizontally centred, and clear of the readouts: they draw above every other window, so a fixed
    /// clearance below the safe area is not enough on a screen whose strip hangs lower than that.
    nonisolated static func frame(for size: NSSize, screen: NSRect, safeAreaTop: CGFloat, visible: NSRect,
                                  readouts: CGRect? = nil) -> NSRect {
        var top = screen.maxY - safeAreaTop - topClearance
        var floor = visible.minY
        let x = (screen.midX - size.width / 2).rounded()
        if let readouts, readouts.width > 0, readouts.maxX > x, readouts.minX < x + size.width {
            // Only the strip that shares this column matters, and which way to dodge depends on where it sits:
            // a strip along the top is passed underneath, one resting on the Dock is passed above.
            if readouts.midY > screen.midY {
                top = min(top, readouts.minY - readoutClearance)
            } else {
                floor = max(floor, readouts.maxY + readoutClearance)
            }
        }
        return NSRect(origin: NSPoint(x: x, y: max(floor, top - size.height)), size: size)
    }
}
