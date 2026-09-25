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
    /// `--render-assets`: what the hook rows and the status-line row report, in place of this Mac's own files.
    ///
    /// The Settings picture is committed to the repository, and the rest of it is fixture from end to end. These
    /// rows were not: they read `~/.claude/settings.json` (and now every other assistant's hooks file) at layout, so the
    /// picture reported whatever state the rendering machine happened to be in — on the machine this was found
    /// on, an orange "Installed but points at an old path", which is neither a fixture nor a thing to show a
    /// reader of the README. It carries the finished `Status` rather than a file to read one out of, so nothing
    /// here can redirect the Add and Repair buttons at a file of the renderer's choosing; those keep reading and
    /// writing each vendor's own file alone.
    var renderedHookStatus: (hook: [HookVendor: HookSettings.Status], statusline: HookSettings.Status)?
    /// The Welcome window's install button: put the status line in after the hook offer above is answered, or
    /// at once when the hook is already there. Cleared by whichever of the two runs it.
    var statuslineOffer = false
    /// A pane the app wants on screen in a window that is already up (the panel's "Add a tool" row lands on
    /// Assistants); the view takes it and clears it.
    var showPane: SettingsPane?
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
    /// Settings › General › "Show the welcome tour again" (AppDelegate.showWelcomeTour).
    var showWelcomeTour: () -> Void = {}
    var updater: () -> Updater? = { nil }
}

/// One row in the Settings sidebar, and the pane it shows on the right.
///
/// Every title is a literal, quoted string handed straight to `L` inside a switch rather than a key built from
/// the raw value: the localisation scanner only sees literals written at the call site, so a key composed from a
/// case name would read to it as shipped-but-never-used.
///
/// Not file-private: `--render-assets` walks `allCases` and asks for each pane by name, because a capture that
/// took whatever `@State` happened to default to would be a picture of one pane of this window.
///
/// Each assistant has a page of its own (`agent`), listed under Assistants in the sidebar: everything about that
/// one assistant — whether it is on, its rings and windows, its hook, its sessions, its notices, where its
/// figures come from — in one place, because a reader thinks "what does Codex do here", not "which of six panes
/// holds Codex's hook". What is the same for every assistant stays on the app's own panes.
enum SettingsPane: Hashable, Identifiable, CaseIterable {
    case general, dashboard, appearance, assistants, notifications, integrations, advanced
    case agent(ToolID)

    /// The app's own panes, in the sidebar's order.
    static let app: [SettingsPane] = [.general, .dashboard, .appearance, .assistants, .notifications, .integrations, .advanced]

    /// Every pane in the default order; the sidebar itself follows the user's (`sidebar(order:)`).
    static var allCases: [SettingsPane] { sidebar(order: ToolID.allCases) }

    /// The sidebar's rows: the app's panes, with a page per assistant right under Assistants, in the user's order
    /// of the assistants — the order the rings, the panel and the Assistants list already use.
    static func sidebar(order: [ToolID]) -> [SettingsPane] {
        app.flatMap { $0 == .assistants ? [$0] + order.map(SettingsPane.agent) : [$0] }
    }

    var id: Self { self }

    /// The assistant a page belongs to; nil for the app's own panes.
    var tool: ToolID? {
        if case .agent(let tool) = self { return tool }
        return nil
    }

    /// The sidebar row's name: an assistant's short one, the name on its rings and in the Assistants list. The
    /// product name ("GitHub Copilot") cut to "GitHub C…" once indented under Assistants, which is a sidebar row
    /// that no longer says which assistant it is; the page's own title carries the full name.
    var sidebarTitle: String {
        tool?.displayName ?? title
    }

    /// An assistant's page is titled with its product's name, which is a name in every language and so not a key.
    var title: String {
        switch self {
        case .general: return L("General")
        case .dashboard: return L("Dashboard")
        case .appearance: return L("Appearance")
        case .assistants: return L("Assistants")
        case .notifications: return L("Notifications")
        case .integrations: return L("Integrations")
        case .advanced: return L("Advanced")
        case .agent(let tool): return tool.productName
        }
    }

    /// One family and one fill weight across the app's panes. An outline glyph beside a solid one reads as two
    /// sets rather than one list, which is what the first pass shipped: gearshape and terminal were outlines
    /// against a solid bell and puzzle piece. Every tile is a fill now, and each glyph has to hold at 11 pt — two
    /// crossed tools (`wrench.and.screwdriver`) turn to mush at that size, so Advanced wears a single wrench.
    /// An assistant's page wears the symbol on its card and beside its rings instead: there the glyph's job is to
    /// be recognised as that assistant, which a new drawing would undo.
    /// `SettingsSidebarTiles` asserts each of these still resolves; a name macOS does not know draws nothing at
    /// all, with no warning and no crash.
    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .dashboard: return "chart.bar.fill"
        case .appearance: return "paintpalette.fill"
        case .assistants: return "terminal.fill"
        case .notifications: return "bell.fill"
        case .integrations: return "powerplug.fill"
        case .advanced: return "wrench.adjustable.fill"
        case .agent(let tool): return tool.symbolName
        }
    }

    /// The glyph's colour on its tile. White on the app's chrome tiles, which were chosen dark enough to carry
    /// it; black on an assistant's own colour, every one of which is a light tint picked to read on the panel's
    /// black, and clears 6.8:1 under a black glyph (Claude's terracotta, the darkest) where white would fail on
    /// Copilot's yellow at 1.3:1. `SettingsSidebarTiles` measures both.
    var glyph: Color {
        tool == nil ? .white : .black
    }

    /// The tile behind the glyph. Palette.warn and Palette.danger are deliberately absent: they mean "needs
    /// attention" and "out" a few rows to the right in this same window, and a sidebar that wore them at rest
    /// would read as alarmed.
    ///
    /// Every tile carries an 11 pt semibold glyph (`glyph`: white on these, black on an assistant's own colour), so
    /// every tile owes it the 3:1 WCAG 1.4.11 asks of a graphical object. Measured against white under `performAsCurrentDrawingAppearance`, light then dark:
    /// purple 4.17/3.63, calm 5.19/5.19, pink 3.65/3.52, indigo 5.09/3.51, brown 3.53/3.07, slate 6.45/6.45.
    /// The system colours do **not** buy adaptivity here: they shift a little between `.aqua` and `.darkAqua`
    /// and `Increase Contrast` returns the identical sRGB values (`accessibilityHighContrastDarkAqua` answers
    /// systemGray with the same rgb(152,152,157) `.darkAqua` does), so a tile that fails does so with every
    /// system remedy switched on. That is why General wears a fixed sRGB grey rather than `.gray`, which is
    /// 2.87:1 in dark — the worst tile in the sidebar on the pane the window opens on. Brown at 3.07 dark is the
    /// thinnest margin left; check a replacement against these numbers rather than against the eye.
    var tint: Color {
        switch self {
        case .general: return Palette.slate
        // Not Palette.calm, which Assistants already wears two rows down; a fixed green rather than the system's,
        // which is under 3:1 against a white glyph in both appearances.
        case .dashboard: return Palette.pine
        case .appearance: return .purple
        case .assistants: return Palette.calm
        case .notifications: return .pink
        case .integrations: return .indigo
        case .advanced: return .brown
        // The colour its rings and card wear, so the page and the ring beside the notch are one thing to the eye.
        case .agent(let tool): return tool.color
        }
    }
}

struct SettingsView: View {
    let store: UsageStore
    let prefs: Preferences
    let actions: NotchActions
    let notifier: Notifier
    let requests: SettingsRequests
    let hostWindow: () -> NSWindow?
    @State private var loginError: String?
    @State private var showHookSnippet: HookVendor?
    @State private var showStatuslineSnippet = false
    @State private var showMCPSnippet = false
    @State private var hookMessage: [HookVendor: String] = [:]
    @State private var statuslineMessage: String?
    @State private var notificationMessage: String?
    @State private var diagnosticsMessage: String?
    @State private var exportMessage: String?
    @State private var hookStatus: [HookVendor: HookSettings.Status] = [:]
    @State private var statuslineStatus = HookSettings.statuslineStatus()
    @State private var currencyText = ""
    @State private var rateText = ""
    @State private var monthlyBudgetText = ""
    @State private var weeklyBudgetText = ""
    @State private var proxyText = ""
    @State private var accessibilityTrusted = MenuBarExtent.isTrusted
    /// Where the Automation grant stands for each terminal a jump drives by AppleScript, read in `onAppear` and
    /// on Check again, never at layout; fixed under `--render-assets` so the pictures do not read this machine.
    @State private var automation: [(name: String, status: TerminalJump.AutomationStatus)] = []
    @State private var colourWell = ColourWell()
    @State private var originText = ""
    @State private var fullScreenExceptionText = ""
    /// The search field's text (SettingsSearch). Not `.searchable`: that renders into a toolbar, and this window
    /// is a toolbar-less panel that cannot show one.
    @State private var query = ""
    /// The Diagnostics disclosure in Advanced; closed until opened, or until a search lands inside it.
    @State private var diagnosticsExpanded = false
    /// The assistants whose *Where each window comes from* a search has opened, for this window only: the
    /// remembered choice is `Preferences.settingsExpandedTools`, which a typed query must not write to.
    @State private var sourcesOpenedBySearch: Set<ToolID> = []
    /// What each sound row wants on one line and what the form gives it, as the rows report it (`soundRowsTwoLine`).
    @State private var soundRowWidths: [SoundCategory: SoundRowWidths] = [:]
    /// The newest crash report (CrashReports), looked up off the main thread each time the Diagnostics disclosure
    /// opens: `.unknown` until the lookup answers, `.found(nil)` when there is none.
    @State private var crashReport: CrashLookup = .unknown
    @State private var crashMessage: String?

    /// Which pane the sidebar is on. Not optional: a nil selection would leave the detail side blank, and this
    /// window has no empty state to show there. Seeded through `init` rather than defaulted here, so a caller
    /// that needs a particular pane on screen — `--render-assets` captures each one in turn — has it laid out
    /// from the first pass, before `onAppear` has run and without a re-layout the measurement could miss.
    @State private var pane: SettingsPane
    /// Pinned to `.all` below. The Settings window is a toolbar-less floating panel, so SwiftUI's sidebar toggle
    /// is dropped and a collapsed sidebar could never be brought back.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    init(store: UsageStore, prefs: Preferences, actions: NotchActions, notifier: Notifier, requests: SettingsRequests,
         hostWindow: @escaping () -> NSWindow?, pane: SettingsPane = .general) {
        self.store = store
        self.prefs = prefs
        self.actions = actions
        self.notifier = notifier
        self.requests = requests
        self.hostWindow = hostWindow
        _pane = State(initialValue: pane)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: SettingsWindowController.minSize.width, minHeight: SettingsWindowController.minSize.height)
        .sheet(item: $showHookSnippet) { vendor in
            if vendor.shape == .pluginModule {
                HookSnippetView(title: L("OpenCode plugin"),
                                explanation: L("Save this as %1$@, or use Add plugin… to have it written for you. OpenCode loads it when it starts, and for each event it runs %2$@ %3$@, which posts the event to the running app and exits.",
                                               vendor.fileURL.path, AppInfo.name, vendor.flag),
                                snippet: HookSettings.snippet(vendor: vendor))
            } else {
                HookSnippetView(title: L("%@ hook", vendor.displayName),
                                explanation: L("Merge this into %1$@, or use Add to %2$@… to have it merged for you. Each entry runs %3$@ %4$@, which posts the event name to the running app and exits.", vendor.fileURL.path, vendor.fileName, AppInfo.name,
                                                 // The per-event flag with a placeholder, so Copilot's explanation names the `--event <name>`
                                                 // every entry below it carries; every other vendor's flag comes back unchanged.
                                                 vendor.flag(for: "<name>")),
                                snippet: HookSettings.snippet(vendor: vendor))
            }
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
            HookOfferView(install: { requests.hookOffer = false; installHook() },
                          later: { requests.hookOffer = false; requests.statuslineOffer = false })
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
            refreshAutomation()
            // The window can be built with the offer already raised; the onChange below catches it being raised
            // while the window is open.
            if requests.hookOffer { pane = .agent(.claude) }
            takeRequestedPane()
            runStatuslineOffer()
        }
        .onChange(of: requests.showPane) { _, _ in takeRequestedPane() }
        .onChange(of: requests.statuslineOffer) { _, _ in runStatuslineOffer() }
        // Typing pulls the window to the first pane with a match — unless the pane on screen has one — and opens
        // the disclosure a match is inside (Diagnostics, or an assistant's sources, and only for a row the
        // disclosure folds away: a match on the rows under it leaves it as it is); the sections without one dim
        // (`searchOpacity`).
        .onChange(of: query) { _, text in
            guard let hit = SettingsSearch.hit(for: text, current: pane, in: SettingsSearch.entries(order: prefs.toolOrder)) else { return }
            if hit.pane != pane { pane = hit.pane }
            if hit.sections.contains(.diagnostics) { diagnosticsExpanded = true }
            if let tool = hit.pane.tool, hit.sections.contains(.agent(tool, .sourcesDetail)) { sourcesOpenedBySearch.insert(tool) }
        }
        .onChange(of: requests.hookSheetDryRun) { _, url in
            guard let url else { return }
            installHook(at: url, dryRun: true)
        }
        // The offer explains the hook rows, so put Claude Code's on screen behind it rather than leaving the sheet
        // talking about a pane the reader cannot see.
        .onChange(of: requests.hookOffer) { _, offered in
            if offered { pane = .agent(.claude) }
        }
        // SwiftUI writes to this binding itself, so a constant initial value is not a pin.
        .onChange(of: columnVisibility) { _, visibility in
            if visibility != .all { columnVisibility = .all }
        }
    }

    // MARK: - The sidebar and the pane it selects

    /// A source list, one row per pane. The rows are ordinary `Label`s in a `List(selection:)`, so Tab reaches
    /// the list and the arrow keys move through it, and the selected row carries both the list's own fill and a
    /// heavier title — the selection never rests on colour alone. (The panel spends most of its life not key, so
    /// that fill is often the inactive grey, which makes the second cue do real work rather than being belt and
    /// braces.) The assistants' pages are indented under Assistants, which reads as "these belong to that" without
    /// a disclosure to open first; the whole row stays the click target.
    private var sidebar: some View {
        List(SettingsPane.sidebar(order: prefs.toolOrder), selection: $pane) { item in
            Label {
                Text(item.sidebarTitle).fontWeight(item == pane ? .semibold : .regular)
            } icon: {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(item.tint)
                    .frame(width: 20, height: 20)
                    .overlay(Image(systemName: item.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(item.glyph))
                    // Decoration: the row already says "General" in words, and VoiceOver would otherwise read
                    // the pane name twice, once as the glyph's own name.
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 2)
            .padding(.leading, item.tool == nil ? 0 : 10)
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(190)
        // The panel has no toolbar of its own and no way to show one, so a toggle that hides the sidebar would
        // hide it for good; the column visibility below is pinned for the same reason.
        .toolbar(removing: .sidebarToggle)
    }

    /// The pane's name as a title, and the pane itself. Switching panes swaps the content outright with no
    /// transition, so there is nothing here for `prefs.reduceAnimations` to have to turn off.
    @ViewBuilder private var detail: some View {
        if pane == .dashboard {
            // The same view as the Usage Dashboard window, not a Form: it scrolls on its own, and its header drops
            // the "Usage" title that would repeat the pane's.
            VStack(alignment: .leading, spacing: 0) {
                Text(pane.title)
                    .font(.largeTitle.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                DashboardView(store: store, embedded: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            formDetail
        }
    }

    private var formDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(pane.title)
                    .font(.largeTitle.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                // In the header rather than the toolbar the window has not got. A plain field: it filters the
                // static index in SettingsSearch, and the rows themselves are never rebuilt.
                VStack(alignment: .trailing, spacing: 2) {
                    TextField(text: $query, prompt: Text(L("Search settings"))) { Text(L("Search settings")) }
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                    if searchMisses {
                        Text(L("No matches")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, -4)
            Form {
                paneContent
            }
            .formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The sections the current query touches; every section while there is no query.
    private var searchedSections: Set<SettingsSection>? {
        guard !SettingsSearch.normalized(query).isEmpty else { return nil }
        return SettingsSearch.sections(matching: query)
    }

    /// A query is typed and nothing answers it: nothing is dimmed, and the header says so.
    private var searchMisses: Bool {
        searchedSections?.isEmpty ?? false
    }

    /// How a block is drawn against the query: dimmed while another block holds the match, whole otherwise.
    /// Dimmed rather than hidden, so the page keeps its shape and a row a reader half-remembers is still there to
    /// be found by eye. Several sections at once for a `Section` that holds more than one block — Advanced holds
    /// the Diagnostics disclosure — so that a match inside the disclosure keeps the section it sits in whole.
    private func searchOpacity(_ sections: SettingsSection...) -> Double {
        guard let searched = searchedSections, !searched.isEmpty, searched.isDisjoint(with: sections) else { return 1 }
        return 0.35
    }

    /// The pane the app asked for after the window was up.
    private func takeRequestedPane() {
        guard let requested = requests.showPane else { return }
        pane = requested
        requests.showPane = nil
    }

    /// The Welcome window's second install, once the hook offer is out of the way (or was never raised because
    /// the hook is already there).
    private func runStatuslineOffer() {
        guard requests.statuslineOffer, !requests.hookOffer else { return }
        requests.statuslineOffer = false
        pane = .agent(.claude)
        installStatusline()
    }

    @ViewBuilder private var paneContent: some View {
        switch pane {
        case .general:
            generalSection.opacity(searchOpacity(.general))
            updatesSection.opacity(searchOpacity(.updates))
            aboutSection.opacity(searchOpacity(.about))
        case .dashboard:
            EmptyView()
        case .appearance:
            themeSection.opacity(searchOpacity(.theme))
            panelSection.opacity(searchOpacity(.panel))
            usageSection.opacity(searchOpacity(.usage))
            shortcutsSection.opacity(searchOpacity(.shortcuts))
        case .assistants:
            assistantsSection.opacity(searchOpacity(.assistants))
            sessionsSection.opacity(searchOpacity(.sessions))
        case .agent(let tool):
            agentOverview(tool).opacity(searchOpacity(.agent(tool, .overview)))
            agentWindows(tool).opacity(searchOpacity(.agent(tool, .windows)))
            agentHook(tool).opacity(searchOpacity(.agent(tool, .hook)))
            agentSessions(tool).opacity(searchOpacity(.agent(tool, .sessions)))
            agentNotifications(tool).opacity(searchOpacity(.agent(tool, .notifications)))
            agentSources(tool).opacity(searchOpacity(.agent(tool, .sources), .agent(tool, .sourcesDetail)))
            if tool == .claude { transcriptsSection.opacity(searchOpacity(.agent(tool, .sources))) }
        case .notifications:
            notificationsSection.opacity(searchOpacity(.notifications))
            soundsSection.opacity(searchOpacity(.sounds))
        case .integrations:
            hookSection.opacity(searchOpacity(.hooks))
            integrationsSection.opacity(searchOpacity(.otherTools))
        case .advanced:
            privacySection.opacity(searchOpacity(.privacy))
            advancedSection.opacity(searchOpacity(.advanced, .diagnostics))
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
                    paragraph(L("Move %@ to the Applications folder first; a login item cannot point here.", AppInfo.name))
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
                paragraph(L("Takes effect at relaunch."))
                Spacer()
                Button(L("Relaunch")) { relaunch() }.controlSize(.small)
            }
            Toggle(L("Show menu bar icon"), isOn: Binding(
                get: { prefs.showMenuBarItem ?? MenuBarPolicy.defaultShown() },
                set: { prefs.showMenuBarItem = $0; requests.menuBarChanged() }
            ))
            .help(L("Off by default so the menu bar keeps its room; the Options menu is then a right-click on the rings. On, it puts Quit and Settings one click (and VoiceOver's VO-M-M) away, which a Mac without a notch needs."))
            if prefs.showMenuBarItem ?? MenuBarPolicy.defaultShown() {
                Toggle(L("Pin figures beside the icon"), isOn: Binding(get: { prefs.menuBarPin }, set: { prefs.menuBarPin = $0 }))
                // Offered as soon as the icon is: hiding how it looks behind a second switch meant nothing said
                // the choice existed. It only takes effect once figures are pinned, which the row says.
                Picker(L("Icon style"), selection: Binding(get: { prefs.menuBarStyle }, set: { prefs.menuBarStyle = $0 })) {
                    ForEach(MenuBarStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(!prefs.menuBarPin)
                .help(L("Which assistants are pinned is chosen on each assistant's page; with none chosen, the first visible one is. Bars draws each pinned window as a mini bar, Rings as the shape beside the notch, Dots as the pace alone."))
                // Only for the drawn styles: Text is drawn by the menu bar itself, in the colour it uses for
                // everything else, and nothing here could change that without fighting it.
                if prefs.menuBarStyle != .text {
                    Picker(L("Icon colour"), selection: Binding(get: { prefs.menuBarTint }, set: { prefs.menuBarTint = $0 })) {
                        ForEach(MenuBarTint.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .disabled(!prefs.menuBarPin)
                    .help(L("By pace uses the app's own amber and vermillion, so the icon says when a window is close to its pace or behind it. Monochrome keeps the menu bar's own colour whatever happens, and stays a template icon macOS paints like every other one. A colour of your own keeps the figures and gives up the warning."))
                    if prefs.menuBarTint == .custom {
                        HStack {
                            Text(L("Colour"))
                            Spacer()
                            Button {
                                colourWell.open(colour: HexColour.colour(prefs.menuBarTintHex),
                                                above: hostWindow()?.level ?? .floating) { prefs.menuBarTintHex = HexColour.hex($0) }
                            } label: {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color(nsColor: HexColour.colour(prefs.menuBarTintHex)))
                                    .frame(width: 44, height: 22)
                                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L("Colour"))
                        }
                        .disabled(!prefs.menuBarPin)
                    }
                }
                if !prefs.menuBarPin {
                    Text(L("Turn on Pin figures beside the icon to use this."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(L("Install command line tool…")) { requests.installCommandLineTool() }
                    .help(L("Links `notchmeter` in ~/.local/bin (or /usr/local/bin) to this app, so `notchmeter` in a terminal or a Claude Code skill reads the running app's cached report instead of asking every vendor again; `notchmeter --force` reads afresh."))
                if let installed = CommandLineTool.installedLink() {
                    Text(installed.link.path.replacingOccurrences(of: Paths.home.path, with: "~")).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            if let message = requests.commandLineToolMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            // Beside the other one-off actions on General rather than under About: the tour is how the app explains
            // itself, and the reader who wants it again is looking for the app's basics, not its version line.
            Button(L("Show the welcome tour again")) { requests.showWelcomeTour() }
                .help(L("The rings, the panel and pace, sessions and the Claude Code hook, over a preview with sample data."))
        }
    }

    /// Placeholders, not labels: `.labelsHidden()` keeps the string inside the field, so the row's own label
    /// carries the wording and nothing has to fit in the field's width.
    private static let currencyPlaceholder = "USD"
    private static let ratePlaceholder = "1.00"
    /// Wide enough for a grouped amount with a decimal ("1,250.00") at the window's minimum width.
    private static let fieldWidth: CGFloat = 96

    /// Help text, the lightest of the form's four levels and never more than two lines of it: what does not fit
    /// is in the tooltip, which carries the whole thing in every language.
    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(2)
            .help(text)
    }

    /// A short entry field: the row's own label names it, so the field's label is hidden and its placeholder
    /// stands in the empty field. Without the bezel an empty field is invisible beside its label.
    private func field(_ text: Binding<String>, prompt: String, label: String, width: CGFloat = fieldWidth) -> some View {
        TextField(text: text, prompt: Text(prompt)) { Text(label) }
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .frame(width: width)
    }

    /// One explanation for both budget rows.
    private static var budgetHelp: String {
        L("In the currency above; leave empty for none. The Cost card's ring fills against the month's budget with the same pace tick the meters use, the Advice strip projects the month against it, and the on-track, behind and run-out notifications apply to it with the month as the period.")
    }

    /// Whether the panel is drawn in an edge layout's card rather than under the notch, which is what decides the
    /// material an install that never chose one gets (`PanelMaterial.unchosen`); the same test `buildPresenters`
    /// makes, against the screen the panel is on.
    private var panelIsEdgeCard: Bool {
        prefs.edge != .top || NSScreen.panelScreen.safeAreaInsets.top == 0
    }

    /// The open panel's look: a live preview over sample data, then the face, the material, the accent, how usage
    /// is drawn and the hour clock. Every choice is applied to the panel at once; the preview is the same views the
    /// panel draws, in the look being chosen (ThemePreview).
    private var themeSection: some View {
        let edgeCard = panelIsEdgeCard
        let look = PanelLook.current(prefs, edgeCard: edgeCard)
        let forcedSolid = AccessibilityDisplay.shared.reduceTransparency || AccessibilityDisplay.shared.contrast
        return Section(L("Theme")) {
            ThemePreview(look: look, width: prefs.panelWidth.points)
            // "Surface", not "Colour": the colour a reader looks for is the accent two rows down, and the menu bar
            // icon's own row is already called Colour.
            Picker(L("Surface"), selection: Binding(get: { prefs.panelTheme }, set: { prefs.panelTheme = $0 })) {
                ForEach(PanelTheme.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .help(L("Paper is the panel inverted: the notch's black stays round it, and the sheet inside is light, with the figures printed on it rather than lit."))
            // The material an install never chose is shown as what the layout draws, and only a click stores one.
            Picker(L("Material"), selection: Binding(
                get: { prefs.panelMaterial ?? PanelMaterial.unchosen(edgeCard: edgeCard, liquidGlass: PanelLook.liquidGlass) },
                set: { prefs.panelMaterial = $0 }
            )) {
                ForEach(PanelMaterial.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(prefs.panelTheme == .paper || forcedSolid)
            .help(L("How much of the desktop shows through the open panel, blurred. Glassy and Smoked keep a black tint strong enough that every line still reads over a white window; the band the notch sits in stays black."))
            if prefs.panelTheme == .paper {
                paragraph(L("Paper is always solid: dark figures on a sheet the desktop shows through would lose their contrast over a dark window."))
            } else if forcedSolid {
                paragraph(L("Solid while Reduce Transparency or Increase Contrast is on, as macOS draws its own panels."))
            }
            // A radio group, as the other choices here are pickers: one control with its options, not three buttons.
            Picker(L("Accent"), selection: Binding(get: { prefs.panelAccent }, set: { prefs.panelAccent = $0 })) {
                ForEach(PanelAccent.allCases, id: \.self) { AccentLabel(accent: $0).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
            .help(L("The app's own colour on the panel: the chosen range on the Cost card, a session waiting for your answer, Clear. Each reads on the panel in every theme and stays apart from the warning colours for colour-blind eyes."))
            Picker(L("Usage style"), selection: Binding(get: { prefs.usageStyle }, set: { prefs.usageStyle = $0 })) {
                ForEach(UsageStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .help(L("Bars draws a meter for each window. Gauges draws an assistant's windows as rings nested in one dial, outermost first, the way the rings beside the notch are; a window past the third keeps its meter, and every line under a window stays."))
            Toggle(L("Draw hour limits on a clock"), isOn: Binding(get: { prefs.hourClock }, set: { prefs.hourClock = $0 }))
                .help(L("A window measured in hours, such as the five-hour session, gets a small clock beside its reset: the filled part is the time left before it resets, and a full clock is a window that has not started. Longer windows keep their words."))
            paragraph(look.theme == .paper || !look.material.translucent
                      ? L("Every line on the panel reads at 4.5:1 or better in the theme you choose, and every mark at 3:1.")
                      : L("Every line on the panel reads at 4.5:1 or better in the theme you choose, and every mark at 3:1, even over a white window."))
        }
    }

    private var panelSection: some View {
        Section(L("Panel")) {
            // Applied to this window at once, not only when it is next opened: the choice is made while looking at it.
            Picker(L("Appearance"), selection: Binding(get: { prefs.appearance }, set: {
                prefs.appearance = $0
                hostWindow()?.appearance = $0.nsAppearance
                actions.applyLayout()
            })) {
                ForEach(AppearanceChoice.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Text(L("The Settings window and the pill an edge layout sits in follow this. The open panel follows Theme above whatever you choose here, and a notch cut into a side edge is always dark: it has to read as part of the screen rather than as something laid on top of it."))
                .font(.caption).foregroundStyle(.secondary)
            Picker(L("Readouts"), selection: Binding(
                get: { prefs.compactSide },
                set: { actions.chooseCompactSide($0); accessibilityTrusted = MenuBarExtent.isTrusted }
            )) {
                ForEach(CompactSide.allCases, id: \.self) { side in
                    Text(side.title).tag(side)
                }
            }
            .help(L("Auto measures how far the frontmost app's menu titles reach: both sides while they end clear of the left-hand readouts, right of the notch while they would run into them. It measures when an app comes forward and remembers each app."))
            paragraph(L("Both sides reads as centred on the notch. An app with many menus can reach past its left edge; right of the notch always clears them."))
            // Only under Auto: a fixed side never gives anything up, so there is nothing for this to order. A direct
            // binding with no action, because AutoSideWatcher observes the preference and re-fits on its own. The
            // copy is worded to hold at every style the picker is shown beside: Numbers has no main-figure rung
            // (CompactFit.steps), and Rings has no figure to give up before the assistants go.
            if prefs.compactSide == .auto {
                Picker(L("When crowded"), selection: Binding(get: { prefs.compactKeep }, set: { prefs.compactKeep = $0 })) {
                    ForEach(CompactKeep.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                paragraph(L("Keep the tools gives up the figures first — every figure past the main one where a ring sits beside them, then the main one too — and leaves out the assistants you put last only once each readout is a bare ring. Keep the numbers leaves those assistants out first, and thins what is left only once a single readout no longer fits."))
            }
            if prefs.compactSide == .auto, !accessibilityTrusted {
                // A stale entry is not the same problem and does not have the same answer: the pane the other
                // button opens may show the switch on (a replaced copy, or an entry that stopped applying) or off
                // (turned off by hand), and the alert the action puts up tells whichever story the code can stand
                // behind. This help sees neither, so it is worded for both.
                if actions.accessibilityIsStale() {
                    Button(L("Repair the Accessibility permission…")) {
                        actions.fixAccessibility()
                        accessibilityTrusted = MenuBarExtent.isTrusted
                    }
                    .help(L("Accessibility is refusing a permission it once granted this app: macOS ties it to the exact copy it was granted to, and a replaced copy or an entry that stopped applying leaves the switch on with the permission gone. If the switch is off, turning it on is enough; otherwise clearing the entry and restarting is the way back."))
                } else {
                    Button(L("Open Accessibility settings…")) {
                        MenuBarExtent.openSettings()
                        accessibilityTrusted = MenuBarExtent.isTrusted
                    }
                    .help(L("Accessibility is off, so Auto stays on the side chosen before it. Notchmeter reads the frontmost app's menu bar geometry and nothing else; no other part of the app asks for Accessibility."))
                }
            }
            Toggle(L("Show details"), isOn: Binding(
                get: { prefs.showDetails },
                set: { prefs.showDetails = $0 }
            ))
            .help(L("The Cost card past its donut, legend and burn line (the budget, week and model lines), the session block, tokens, top projects and the sparklines. Off keeps the panel short enough not to scroll."))
            Picker(L("Position"), selection: Binding(
                get: { prefs.edge },
                set: { prefs.edge = $0; actions.applyLayout() }
            )) {
                ForEach(PanelEdge.allCases, id: \.self) { edge in
                    Text(edge.title).tag(edge)
                }
            }
            paragraph(prefs.edge.detail)
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
            paragraph(prefs.display == .pointer
                      ? L("The panel follows the pointer: it moves to the display the pointer has rested on for half a second.")
                      : L("A named display is remembered by its hardware identity, so two monitors of one model are told apart and a rename does not lose it."))
            Picker(L("Show"), selection: Binding(
                get: { prefs.visibility },
                set: { prefs.visibility = $0; actions.applyLayout() }
            )) {
                ForEach(NotchVisibility.allCases, id: \.self) { visibility in
                    Text(visibility.title).tag(visibility)
                }
            }
            .help(L("The rings shrink to a dot once no assistant has been active for 30 minutes and every window is quiet; a hook event, file activity, a pace change or resting the pointer on them brings them back."))
            if prefs.visibility == .onHover || prefs.visibility == .hideWhenIdle {
                Stepper(value: Binding(get: { prefs.hoverDelay }, set: { prefs.hoverDelay = $0 }), in: 0.1...1.0, step: 0.05) {
                    HStack {
                        Text(L("Hover delay"))
                        Spacer()
                        Text(L("%@ s", String(format: "%.2f", prefs.hoverDelay))).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            Picker(prefs.edge.compactStyleTitle, selection: Binding(get: { prefs.compactStyle }, set: { prefs.compactStyle = $0 })) {
                ForEach(CompactStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if prefs.compactStyle.showsNumbers {
                Toggle(L("Show reset countdown beside the figures"), isOn: Binding(get: { prefs.showResetCountdown }, set: { prefs.showResetCountdown = $0 }))
            } else {
                Toggle(L("Show the main figure beside the rings"), isOn: Binding(get: { prefs.compactPrimary }, set: { prefs.compactPrimary = $0 }))
                    .help(L("The outer ring's window as one figure beside the rings, in the Used or Left sense chosen under Usage display and without the reset countdown. The rings still go quiet under 40 %; the figure stays legible."))
            }
            if prefs.compactStyle.showsRings {
                Toggle(L("Show assistant symbols in the rings"), isOn: Binding(get: { prefs.ringSymbols }, set: { prefs.ringSymbols = $0 }))
                    .help(L("Each assistant's symbol, the one on its card, drawn small in the middle of its rings, or on their corner when three rings leave too little room, for when the assistants' colours are hard to tell apart."))
            }
            Picker(L("Panel layout"), selection: Binding(get: { prefs.panelMode }, set: { prefs.panelMode = $0 })) {
                ForEach(PanelMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .help(L("Simple shows one row per assistant with its most urgent figure; click a row for everything else. Detailed shows every assistant's card open."))
            Picker(L("Density"), selection: Binding(get: { prefs.density }, set: { prefs.density = $0 })) {
                ForEach(Density.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker(L("Panel width"), selection: Binding(get: { prefs.panelWidth }, set: { prefs.panelWidth = $0 })) {
                ForEach(PanelWidth.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle(L("Show over full-screen apps"), isOn: Binding(get: { prefs.showOverFullScreenApps }, set: { prefs.showOverFullScreenApps = $0; actions.applyLayout() }))
                .help(L("Off, the rings and the panel stay off a full-screen app's Space and the hover machine idles there, so a pointer parked at the top of that Space opens nothing."))
            if !prefs.showOverFullScreenApps {
                ForEach(prefs.fullScreenExceptions, id: \.self) { app in
                    HStack {
                        Text(app).font(.caption)
                        Spacer()
                        Button(L("Remove")) {
                            prefs.fullScreenExceptions.removeAll { $0 == app }
                            actions.applyLayout()
                        }
                        .controlSize(.small)
                    }
                }
                HStack {
                    TextField(text: $fullScreenExceptionText, prompt: Text(L("App to stay over, e.g. zoom.us"))) {
                        Text(L("App to stay over, e.g. zoom.us"))
                    }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    Button(L("Add")) {
                        let trimmed = fullScreenExceptionText.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty, !prefs.fullScreenExceptions.contains(trimmed) {
                            prefs.fullScreenExceptions.append(trimmed)
                            actions.applyLayout()
                        }
                        fullScreenExceptionText = ""
                    }
                    .controlSize(.small)
                }
                .help(L("Apps the readouts stay over anyway, by the name the window list gives them: a meeting you want the meters beside, where the setting above is off for a film. It cannot tell two uses of one app apart, a call and a film both in a browser being the case in point; the Show over the full-screen app shortcut answers that one, for the app on screen and until it leaves full screen. The Options menu offers both for whatever is full-screen at the time."))
            }
            Toggle(L("Gestures: swipe down to open, swipe up to close"), isOn: Binding(get: { prefs.gesturesEnabled }, set: { prefs.gesturesEnabled = $0 }))
            Toggle(L("Reduce animations"), isOn: Binding(get: { prefs.reduceAnimations }, set: { prefs.reduceAnimations = $0 }))
        }
    }

    private var shortcutsSection: some View {
        Section {
            HotkeyRow(title: L("Toggle the panel"), hotkey: Binding(get: { prefs.togglePanelHotkey }, set: { prefs.togglePanelHotkey = $0; requests.hotkeysChanged() }))
            HotkeyRow(title: L("Open Settings"), hotkey: Binding(get: { prefs.openSettingsHotkey }, set: { prefs.openSettingsHotkey = $0; requests.hotkeysChanged() }))
            HotkeyRow(title: L("Show over the full-screen app"), hotkey: Binding(get: { prefs.showOverFullScreenHotkey }, set: { prefs.showOverFullScreenHotkey = $0; requests.hotkeysChanged() }))
        } header: {
            Text(L("Keyboard shortcuts"))
                .help(L("Global: they work from any app; with All displays, the panel on the display under the pointer answers. The panel's own keys, when it was opened by a click, a swipe, the shortcut or a notification: Escape closes it, ⌘R refreshes, ⌘, opens Settings, ⌘Q quits. A hover-opened panel never takes the keyboard."))
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
            LabeledContent(L("Show costs in")) {
                field($currencyText, prompt: Self.currencyPlaceholder, label: L("Currency code"))
                    .onSubmit { applyCurrency() }
                Button(L("Apply")) { applyCurrency() }
            }
            // The rate the code converts at is under Advanced › Diagnostics with its own Apply: a number set once
            // and rarely, beside the other rarely-touched fields, where it no longer makes the currency row look
            // like something everyone has to fill in.
            paragraph(L("Costs are computed in US dollars at API list prices; a code (EUR, GBP, JPY) and your own rate convert them. Nothing is fetched: the rate is yours."))
            LabeledContent(L("Monthly budget")) {
                field($monthlyBudgetText, prompt: Money.code, label: L("Monthly budget"))
                    .onSubmit { applyBudgets() }
            }
            .help(Self.budgetHelp)
            LabeledContent(L("Weekly budget")) {
                field($weeklyBudgetText, prompt: Money.code, label: L("Weekly budget"))
                    .onSubmit { applyBudgets() }
                Button(L("Apply")) { applyBudgets() }
            }
            .help(Self.budgetHelp)
            // Which assistants the card carries is on each one's page (*In the Cost card*), beside its other
            // windows; what the card leads with is the card's own, and stays here.
            Picker(L("Cost card shows"), selection: Binding(get: { prefs.costCardMode }, set: { prefs.costCardMode = $0 })) {
                ForEach(CostCardMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        }
    }

    private var privacySection: some View {
        Section(L("Privacy")) {
            Toggle(L("Hide usage while the screen is shared or recorded"), isOn: Binding(get: { prefs.hideFromScreenShare }, set: { prefs.hideFromScreenShare = $0; requests.privacyChanged() }))
                .help(L("While Zoom, Meet, QuickTime or Screen Sharing capture the screen, the rings keep their shape but lose their digits, the panel hides the Cost card, and a banner that fires carries no figure and no project name. Checked every five seconds."))
            Toggle(L("Local API on 127.0.0.1:%ld", Int(LocalAPI.port)), isOn: Binding(get: { prefs.localAPIEnabled }, set: { prefs.localAPIEnabled = $0; requests.localAPIChanged() }))
                .help(L("GET /v1/limits answers with the same JSON as --probe --json, from the cached readings, for status-line scripts, widgets and the command-line tool on this Mac; POST /v1/hook takes a remote machine's hook events, any assistant's, over an SSH tunnel. Loopback only, no authentication; a request from a web page (one carrying an Origin header) is refused unless its origin is listed below, and the Host header must be the loopback address."))
            if prefs.localAPIEnabled {
                ForEach(prefs.localAPIOrigins, id: \.self) { origin in
                    HStack {
                        Text(origin).font(.caption)
                        Spacer()
                        Button(L("Remove")) { prefs.localAPIOrigins.removeAll { $0 == origin } }.controlSize(.small)
                    }
                }
                HStack {
                    TextField(text: $originText, prompt: Text(L("Allowed origin, e.g. http://localhost:3000"))) {
                        Text(L("Allowed origin, e.g. http://localhost:3000"))
                    }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
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
            .help(L("Once per window and reset period: when its pace first reaches on track or behind, again when it comes within an hour of running out, and once more when it is out. Each one says what to do about it. macOS asks for permission when this is turned on or the first alert is due, never at launch."))
            if prefs.notificationsEnabled {
                Toggle(L("Cutting it close (on track)"), isOn: Binding(get: { prefs.notifyOnTrack }, set: { prefs.notifyOnTrack = $0 }))
                Toggle(L("Will run out (behind pace)"), isOn: Binding(get: { prefs.notifyBehind }, set: { prefs.notifyBehind = $0 }))
                Toggle(L("Almost out (under an hour left), and out"), isOn: Binding(get: { prefs.notifyRunningOut }, set: { prefs.notifyRunningOut = $0 }))
                Toggle(L("When a window resets"), isOn: Binding(get: { prefs.notifyOnReset }, set: { prefs.notifyOnReset = $0 }))
                Picker(L("Remind me before a reset"), selection: Binding(get: { prefs.resetReminder }, set: { prefs.resetReminder = $0 })) {
                    ForEach(ResetReminder.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .help(L("Reset and reminder notices cover windows that were at least 80% used or behind pace when last read; a window's pace notices are withdrawn from Notification Center when it resets."))
                Toggle(L("When you start paying (extra usage rises)"), isOn: Binding(get: { prefs.notifyExtraUsage }, set: { prefs.notifyExtraUsage = $0 }))
                    .help(L("Once a month when Claude's extra-usage credits first rise, and within the hour whenever they rise while the plan windows still have room: the sign that work is being billed instead of drawn from the plan. Every rise is written to the drain log with the plan windows beside it."))
                Toggle(L("When the cache tier or the metering shifts"), isOn: Binding(get: { prefs.notifyCacheShift }, set: { prefs.notifyCacheShift = $0 }))
                    .help(L("Once a day when today's cache writes moved to the 5-minute tier against the 30-day norm, or the session meters about twice as heavily as usual."))
                Toggle(L("When the prompt cache keeps missing"), isOn: Binding(get: { prefs.notifyPromptCache }, set: { prefs.notifyPromptCache = $0 }))
                    .help(L("Once a day when Claude Code's status line counts three prompt-cache misses in the current session block, or 200K tokens rewritten, with the cause Claude Code diagnosed."))
            }
            Toggle(L("Notify when an assistant waits for you"), isOn: Binding(get: { prefs.notifyWaiting }, set: { prefs.notifyWaiting = $0; if $0 { notifier.requestAuthorization() } }))
                .help(L("Both need the assistant's hook. A wait the session has stopped for — a permission prompt, an elicitation, an agent asking — always reaches you. Claude Code's idle nudge, which only means you have gone quiet, and a finished turn stay in the background while a terminal or editor is in front, unless you turn that off below."))
            Toggle(L("Notify when a turn finishes"), isOn: Binding(get: { prefs.notifyFinished }, set: { prefs.notifyFinished = $0; if $0 { notifier.requestAuthorization() } }))
                .help(L("Both need the assistant's hook. A wait the session has stopped for — a permission prompt, an elicitation, an agent asking — always reaches you. Claude Code's idle nudge, which only means you have gone quiet, and a finished turn stay in the background while a terminal or editor is in front, unless you turn that off below."))
            if prefs.notifyFinished {
                Stepper(value: Binding(get: { prefs.finishedAfterMinutes }, set: { prefs.finishedAfterMinutes = $0 }), in: 1...60) {
                    HStack {
                        Text(L("Only turns longer than"))
                        Spacer()
                        Text(L("%ld min", prefs.finishedAfterMinutes)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            Toggle(L("Notify when a session compacts, may be stuck or is refused"), isOn: Binding(get: { prefs.notifySessionTrouble }, set: { prefs.notifySessionTrouble = $0; if $0 { notifier.requestAuthorization() } }))
                .help(L("Claude Code's hook only: once when a session starts compacting its context by itself, once when five tool calls in a row have failed with none succeeding between them, and the first time in a turn auto mode refuses a tool. Each arrives without a sound, stays in the background while a terminal or editor is in front, and follows the quiet hours. The session's row and the word beside the notch say all three without it."))
            Toggle(L("Stay quiet while a terminal or editor is in front"), isOn: Binding(get: { prefs.quietWhileTerminalFrontmost }, set: { prefs.quietWhileTerminalFrontmost = $0 }))
                .help(L("On, a notice about a session is held back while a terminal or editor is frontmost, because you are probably looking at the session in it. Off, it arrives anyway — the answer when your sessions sit in tabs you are not looking at, since the app can only see which app is in front and never which window, and never reads a window's title to find out. A wait the session has stopped for, and a session on another Mac, ignore this setting; the quiet hours override it."))
            Toggle(L("Colour the rings when an assistant waits or finishes"), isOn: Binding(get: { prefs.signalRings }, set: { prefs.signalRings = $0 }))
                .help(L("The ring takes the blue that means needs you rather than running out while an assistant waits for your permission or has just finished a turn, and a mark beside it says which. Pace keeps the cap on the arc's end, so a window that is nearly gone still says so. Every hook reports a finished turn; Claude Code's, Codex's, Gemini CLI's and Copilot's report a wait, Cursor's and Kimi Code's do not."))
            Toggle(L("Show news in the notch"), isOn: Binding(get: { prefs.notchNews }, set: { prefs.notchNews = $0 }))
                .help(L("When a session starts waiting for you, finishes a turn, starts compacting by itself, may be stuck or is refused by auto mode, the strip beside the notch names the project and the reason for four seconds, in the room the menu bar leaves. Click it to open the panel on that session. While your screen is shared the project is left out."))
            Toggle(L("Glow under the notch for news"), isOn: Binding(get: { prefs.notchGlow }, set: { prefs.notchGlow = $0 }))
                .help(L("A light under the notch for the same news: blue for a wait, white for a finish, fading after three seconds; a faint blue stays while a session still waits. Under Reduce Motion it is a still tint."))
            Picker(L("When an assistant waits for you, or a turn finishes"), selection: Binding(get: { prefs.sessionAttention }, set: { prefs.sessionAttention = $0 })) {
                ForEach(SessionAttention.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .help(L("Both need the assistant's hook and follow the same rules as the notices above: the frontmost-terminal setting, and the quiet hours. This chooses what the panel does; the toggle above chooses what the rings do, and either can be off without the other. A glance opens a card for that session alone, with a jump back to it, and settles again unless the pointer comes in; under Reduce Motion it opens without animation and stays a little longer. A \"waiting\" notice is withdrawn when you answer. In an unsigned build no notice can break through Focus or Do Not Disturb; the time-sensitive ones (running out, waiting for you) do in the signed release."))
            Toggle(L("Quiet hours"), isOn: Binding(get: { prefs.quietHoursEnabled }, set: { prefs.quietHoursEnabled = $0 }))
            if prefs.quietHoursEnabled {
                HStack {
                    QuietHourPicker(title: L("From"), minutes: Binding(get: { prefs.quietHoursStart }, set: { prefs.quietHoursStart = $0 }), format: prefs.timeFormat)
                    QuietHourPicker(title: L("To"), minutes: Binding(get: { prefs.quietHoursEnd }, set: { prefs.quietHoursEnd = $0 }), format: prefs.timeFormat)
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
            // The switches here choose which kinds of notice go out, for every assistant; which assistants they go
            // out for is on each assistant's own page, and a reader looking for "stop Cursor's banners" is here.
            paragraph(L("These apply to every assistant. Each assistant's page can leave out its own limit notices and its own waiting and finished-turn notices."))
        }
    }

    /// The sound block: one switch for every sound, then a row per SoundCategory with its sound, a Preview and a
    /// Silence box. A block of its own rather than more rows at the foot of Notifications, where the five pickers
    /// of 0.8.0 sat between the quiet hours and the attention picker and read as more notification switches.
    private var soundsSection: some View {
        Section(L("Sounds")) {
            Toggle(L("Play sounds"), isOn: Binding(get: { prefs.notificationSound }, set: { prefs.notificationSound = $0 }))
                .help(L("Each kind of notice has its own sound and its own Silence box below. Notification Center plays them, so Focus silences them as it does any app's, and so do the quiet hours; two notices inside two seconds make one sound between them, except that a request or a limit alert still sounds after a finished turn or a reminder."))
            if prefs.notificationSound {
                ForEach(SoundCategory.allCases, id: \.self) { category in
                    SoundPicker(title: category.title,
                                choice: Binding(get: { prefs.soundChoice(for: category) }, set: { prefs.soundChoices[category] = $0 }),
                                silenced: Binding(get: { prefs.silencedSounds.contains(category) }, set: { prefs.setSilenced($0, category) }),
                                defaultTag: NotificationSound.defaultChoice(for: category),
                                caption: category.caption,
                                twoLine: soundRowsTwoLine,
                                measured: { soundRowWidths[category] = $0 })
                        .help(category.help)
                }
                // In full, as the captions above are, rather than through `paragraph`: its two lines end this
                // sentence in an ellipsis at the window's narrowest in every language, with the rest reachable by
                // hovering alone, and it is the one place the import rules are stated.
                Text(L("A chosen .aiff, .wav or .caf is copied into ~/Library/Sounds as it is; any other format, an mp3 or m4a for instance, is converted to a .caf there, since Notification Center plays nothing else by name."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Whether the six sound rows put their Preview and Silence box under the menu (SoundPicker.twoLine): once
    /// for the block, from what every row reports as it lays out (SoundRowWidths). A row judging for itself, as
    /// each did through a `ViewThatFits`, left the block ragged where a language's words run long — at the
    /// window's narrowest in German, *Plan zur Freigabe bereit* went to two lines while the four rows between it
    /// and *Durchgang beendet* stayed on one, and the six menus sat in three columns — and neighbouring rows in
    /// two layouts read as a fault, not a fit. One line is kept only while every row's fits.
    private var soundRowsTwoLine: Bool {
        soundRowWidths.values.contains { !$0.fits }
    }

    private var assistantsSection: some View {
        Section {
            let order = prefs.toolOrder
            ForEach(Array(order.enumerated()), id: \.element) { index, tool in
                assistantRow(tool, at: index, of: order.count)
            }
            Toggle(L("Hide assistants with nothing to show"), isOn: Binding(get: { prefs.hideEmptyTools }, set: { prefs.hideEmptyTools = $0 }))
                .help(L("An assistant that is on and installed but has no reading, no spend and no session yet stays off the panel and the rings until it has one; the last visible assistant is never hidden. While one is hidden the panel ends with an Add a tool row that opens this pane."))
            Button(L("Refresh now")) { store.refreshAll(interactive: true) }
        } header: {
            Text(L("Assistants"))
                .help(L("The first assistant sits left of the notch and the rest to its right; the panel's cards and the edge pills follow the same order. Everything else about an assistant is on its own page, listed under Assistants in the sidebar."))
        }
    }

    /// One assistant in the list: its name and status, its switch and the two reorder arrows. The whole name opens
    /// the assistant's own page, not only the chevron, and clicking it never flips the switch. Every assistant has a
    /// page, installed or not, so every row opens one: the page is also where an assistant that is not on this Mac
    /// says so and still offers its hook's snippet. Until the pages existed the name unfolded the options in place,
    /// which put a second copy of half a pane inside a list the arrows were reordering.
    private func assistantRow(_ tool: ToolID, at index: Int, of count: Int) -> some View {
        let status = subtitle(for: tool)
        return HStack(spacing: 10) {
            Button {
                pane = .agent(tool)
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.displayName)
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    // Trailing, as a navigation row wears it in System Settings: the row goes somewhere, it does
                    // not unfold.
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Named for what activating it does, a page opening, not for the options that used to unfold here.
            .help(L("Open %@'s page", tool.productName))
            .accessibilityLabel("\(tool.displayName), \(status)")
            .accessibilityHint(L("Open %@'s page", tool.productName))
            Toggle(tool.displayName, isOn: Binding(
                get: { store.isShown(tool) },
                set: { store.setEnabled(tool, $0) }
            ))
            .labelsHidden()
            .disabled(!store.isInstalled(tool))
            ReorderButtons(
                up: index > 0 ? { prefs.move(tool, by: -1) } : nil,
                down: index < count - 1 ? { prefs.move(tool, by: 1) } : nil
            )
        }
    }

    /// The 0.7.0 two-way features, for every assistant at once: the Sessions card, the titles it shows, answering a
    /// request from the notch and the hold before it goes back to the terminal, the jump to a session's terminal
    /// with the Automation grant it may need (docs/hooks.md, docs/permissions.md), and keeping the Mac awake while
    /// a session works, which counts every assistant's sessions and so was never Claude Code's alone; since 0.9.0
    /// the sessions found without a hook (SessionDetection) and Claude Cowork's tasks (CoworkSessions), which need
    /// none. Which assistants' sessions are read and answered is on each one's page.
    private var sessionsSection: some View {
        Section {
            Toggle(L("Show a Sessions card on the panel"), isOn: Binding(get: { prefs.sessionsCard }, set: { prefs.sessionsCard = $0 }))
                .help(L("One row per session, the hooks' and the ones found without them, newest first: what it is working on, which assistant and which terminal it runs in, how long the turn has run, and whether it is waiting for you. Six rows, then a count of the rest."))
            Toggle(L("Find sessions without the hook"), isOn: Binding(get: { prefs.detectSessions }, set: { prefs.detectSessions = $0 }))
                .help(L("Lists the Claude Code, Codex, Cursor, Gemini CLI and Copilot sessions running in a terminal before any hook is installed, from the process, its folder, Claude Code's own session files and the end of its transcript, all read and never written. Such a row is marked detected: whether it is working is a guess that can trail the turn by a few seconds, and it never shows a wait for your answer. A session the hook reports is always the hook's."))
            Toggle(L("Show Claude Cowork tasks"), isOn: Binding(get: { prefs.coworkSessions }, set: { prefs.coworkSessions = $0 }))
                .help(L("Cowork has no hook. While the Claude app is running, Notchmeter reads each task it keeps on this Mac every few seconds, without changing anything: the task's title (only while Show what a session is working on is on), the folder you gave it, and its log. A task is working from its prompt until the log's own end-of-turn line, and shows as idle while its log is quiet for four minutes or it has stopped to ask you something in Claude. It is never shown as waiting for you."))
            Toggle(L("Show what a session is working on"), isOn: Binding(get: { prefs.sessionTitles }, set: { prefs.sessionTitles = $0 }))
                .help(L("The first line of each prompt, at most 96 characters, and the text of Claude Code's task list, which the hook sends and only the running app keeps. Off, the app drops both before they are held anywhere: the row shows the project instead, and the task list only its count. Both are hidden while the screen is shared whatever this says."))
            Toggle(L("Answer from the notch"), isOn: Binding(get: { prefs.answerFromNotch }, set: { prefs.answerFromNotch = $0 }))
                .help(L("A permission request or a question from Claude Code, Codex or Copilot opens the panel with Allow and Deny (⌘Y, ⌘N) or the options (⌘1…⌘9), and the assistant waits on your answer; Escape hands it back to the terminal. So does a Claude Code MCP server's request for input when every field is a choice; one that wants text or a sign-in goes straight to the terminal. Off, the terminal asks as it always has and the panel only shows the wait. Cursor, Gemini CLI and Kimi Code have no event that can be answered."))
            if prefs.answerFromNotch {
                Stepper(value: Binding(get: { prefs.promptHoldSeconds }, set: { prefs.promptHoldSeconds = $0 }), in: Preferences.promptHoldRange, step: 15) {
                    HStack {
                        Text(L("Hand a request back to the terminal after"))
                        Spacer()
                        Text(L("%ld s", prefs.promptHoldSeconds)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .help(L("A request nobody has answered in this long goes back to the terminal, which asks as usual; the hook's own ceiling is ten minutes, and the assistant sees no decision either way."))
            }
            Toggle(L("Jump to the terminal on click"), isOn: Binding(get: { prefs.jumpToTerminal }, set: { prefs.jumpToTerminal = $0 }))
                .help(L("A click on a session row brings its terminal tab or pane forward, from what the hook read in its own environment: Warp by its focus link, iTerm2, Terminal and Ghostty by AppleScript, kitty and WezTerm by their own command, a tmux pane on its socket, anything else by raising the app. It never launches a terminal that is not running, and a session on another Mac has nothing to jump to."))
            Toggle(L("Keep the Mac awake while an assistant is working"), isOn: Binding(get: { prefs.keepAwake }, set: { prefs.keepAwake = $0; requests.awakeChanged() }))
                .help(L("A sleep assertion held only while a session the hook reports is mid-turn, released at its Stop, so a session started from a phone or over SSH keeps running with the lid closed on power. The footer says \"Keeping awake · 2 sessions\" while it is held. A Claude Cowork task at work holds it too, until its log shows the turn ended or goes quiet."))
            if prefs.keepAwake {
                Toggle(L("Also on battery"), isOn: Binding(get: { prefs.keepAwakeOnBattery }, set: { prefs.keepAwakeOnBattery = $0; requests.awakeChanged() }))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Automation")).font(.subheadline.weight(.semibold))
                    .help(L("macOS asks once, the first time a jump drives iTerm2, Terminal or Ghostty by AppleScript, and keeps the answer under Privacy & Security › Automation. Warp, kitty, WezTerm and tmux need no permission. A terminal that is not running cannot be asked about."))
                ForEach(automation, id: \.name) { row in
                    HStack {
                        Text(verbatim: row.name)
                        Spacer()
                        Text(row.status.text).foregroundStyle(row.status == .denied ? Palette.warn : .secondary)
                    }
                    .font(.caption)
                }
                HStack {
                    Button(L("Open Automation settings…")) { actions.open(TerminalJump.automationSettingsURL) }
                    Button(L("Check again")) { refreshAutomation() }
                }
            }
        } header: {
            Text(L("Sessions"))
                .help(L("What the panel shows of each session, and what you can do to it from there, for every assistant. Sessions are found without the hook too, and Claude Cowork's tasks are read from the Claude app's own files; exact turn ends, waits, answers and the task list need the assistant's hook, on its page, and each assistant's page can stop reading its sessions or answering its requests."))
        }
    }

    /// Claude Code's hook carries the deciding entries: `.installed` only; a stale or partial one (a 0.6.0 install)
    /// shows Repair in the hook section of Claude Code's page, which the copy there points at.
    private var claudeHookIsCurrent: Bool {
        if case .installed = hookStatus[.claude] ?? .notInstalled { return true }
        return false
    }

    private func refreshAutomation() {
        automation = TerminalJump.scriptedApps.map { app in
            (app.name, requests.renderedHookStatus == nil ? TerminalJump.automationStatus(bundleID: app.bundleID) : .notAsked)
        }
    }

    /// Which assistants' pages have *Where each window comes from* open (Preferences.settingsExpandedTools),
    /// remembered across launches so a page reopens the way it was left. The same key held which assistants had
    /// their options unfolded in the Assistants list before each had a page; a set opened then opens this now,
    /// which is the nearest thing on the page to what was open. A search whose match is inside the disclosure
    /// opens it for this window alone (`sourcesOpenedBySearch`), as a search opens Diagnostics: a typed word is
    /// not a choice about how the page should reopen next time, and only a click writes one. A click to close
    /// takes both down, so a disclosure a search opened does not spring back open on the next query.
    private func expansion(of tool: ToolID) -> Binding<Bool> {
        Binding(get: { prefs.settingsExpandedTools.contains(tool) || sourcesOpenedBySearch.contains(tool) },
                set: { open in
                    if open { prefs.settingsExpandedTools.insert(tool) } else { prefs.settingsExpandedTools.remove(tool) }
                    sourcesOpenedBySearch.remove(tool)
                })
    }

    /// Every assistant's hook at a glance, with the way to its page, where Add, Repair and the snippet are; and the
    /// launch repair, which applies to every hooks file alike. One line per assistant, in the rings' order, always
    /// shown, so a Mac without one of them still says "Not installed" rather than hiding the option.
    private var hookSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(HookVendor.allCases) { vendor in
                    hookSummary(vendor)
                    Divider()
                }
                // Named for everything the launch repair does, not only the moved path: it also rewrites an entry
                // of ours that lacks an event or carries older flags (HookSettings.Status.partial), and 0.9.0's
                // rewrite of a Gemini CLI entry from --tool antigravity is one of those. A toggle that is on by
                // default is the consent for a config write at launch, so its label has to say what it consents to.
                Toggle(L("Repair an out-of-date hook at launch"), isOn: Binding(get: { prefs.autoRepairHooks }, set: { prefs.autoRepairHooks = $0 }))
                    .font(.caption)
                    .help(L("At launch, after the usual backup, an entry of Notchmeter's own that names an old path of this app (a move to Applications, an update), lacks an event, or carries older flags is rewritten to the running copy and its current form, and the footer says so once; 0.9.0 brings a Gemini CLI entry still on --tool antigravity to --tool gemini this way. Never from a build folder, never under --smoke. Applies to every assistant's hooks file."))
            }
        } header: {
            Text(L("Hooks"))
                .help(L("Let Claude Code, Codex, Cursor, Gemini CLI, GitHub Copilot, Kimi Code and OpenCode tell the notch when a session starts or ends, a prompt is sent, a turn stops and a subagent runs: the meter refreshes at once and the card counts sessions and agents. Claude Code, Codex, Gemini CLI, Copilot and OpenCode also report when they stop to ask you something; Cursor and Kimi Code have no event for that, so their rings show the finished tick and never the waiting hand. Claude Code and Codex report their permission mode; Claude Code and OpenCode report a stop on a rate limit."))
        }
    }

    /// One assistant's line on the Integrations overview: its hook's name, where its file stands in words (colour
    /// only repeats what the words say), and a button to its page. The button reads the same on every line: named
    /// for the page, the Gemini CLI hook's read "Open Antigravity" beside "Gemini CLI hook", two names on one line
    /// for a reader who had to know that hook lights the Antigravity ring. VoiceOver still hears which page.
    private func hookSummary(_ vendor: HookVendor) -> some View {
        let status = hookStatus[vendor] ?? .notInstalled
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(vendor.shape == .pluginModule ? L("OpenCode plugin") : L("%@ hook", vendor.displayName))
                    .font(.subheadline.weight(.semibold))
                Text(status.text).font(.caption).foregroundStyle(hookStatusColor(status))
            }
            Spacer()
            Button(L("Open its page")) { pane = .agent(vendor.tool) }
                .controlSize(.small)
                .accessibilityLabel(L("Open %@'s page", vendor.tool.productName))
        }
        .help(hookRowHelp(vendor))
    }

    /// One vendor's hook on its assistant's page, under the section header that names it: where its file stands,
    /// the snippet, Add or Repair as the status calls for, and what the last press did.
    @ViewBuilder
    private func hookRow(_ vendor: HookVendor) -> some View {
        let status = hookStatus[vendor] ?? .notInstalled
        Text(status.text).font(.caption).foregroundStyle(hookStatusColor(status))
        HStack {
            Button(L("Show snippet…")) { showHookSnippet = vendor }
            switch status {
            case .notInstalled where vendor.shape == .pluginModule: Button(L("Add plugin…")) { installHook(vendor: vendor) }
            case .notInstalled: Button(L("Add to %@…", vendor.fileName)) { installHook(vendor: vendor) }
            case .stale, .partial: Button(L("Repair")) { repairHook(vendor: vendor) }
            case .installed: EmptyView()
            }
        }
        if let message = hookMessage[vendor] {
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - An assistant's page

    /// Whether it is on, what it says about itself, and a read of it now. The switch is the Assistants list's own
    /// (`UsageStore.setEnabled`), so the two can never disagree; its label carries the status, so VoiceOver reads
    /// "Signed in · Max" with the switch rather than as a line of its own.
    private func agentOverview(_ tool: ToolID) -> some View {
        Section {
            Toggle(isOn: Binding(get: { store.isShown(tool) }, set: { store.setEnabled(tool, $0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Show %@ on the panel and the rings", tool.displayName))
                    Text(subtitle(for: tool)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(!store.isInstalled(tool))
            .help(L("Off stops every read of its usage and takes its rings, its card and its menu bar figures away. Its hook and its sessions follow their own switches below."))
            Button(L("Refresh now")) { Task { await store.refresh(tool, force: true, interactive: true) } }
                .disabled(!store.isShown(tool))
        }
    }

    /// Its rings and windows: the ring pickers and the Hide boxes once there is a reading to choose from (until
    /// then, why there is none, in the overview's words), and the three per-assistant switches that need none —
    /// the menu bar pin, peak hours, and whether the Cost card carries it (only where it can report spend at all;
    /// one that is not on keeps its place in the set, so an afternoon signed out does not silently drop it from the
    /// card it comes back to).
    private func agentWindows(_ tool: ToolID) -> some View {
        Section(L("Rings and windows")) {
            // One window is still worth the pickers: requiring two made them vanish without a word when a vendor's
            // reset left only one (Cursor Enterprise, 2026-09-18), which read as a bug rather than a choice.
            if let reading = store.status(tool).reading, !reading.windows.isEmpty {
                WindowChoices(tool: tool, reading: reading, prefs: prefs)
            } else {
                Text(subtitle(for: tool)).font(.caption).foregroundStyle(.secondary)
            }
            Toggle(L("Pin to menu bar"), isOn: Binding(
                get: { prefs.menuBarPinnedTools.contains(tool) },
                set: { if $0 { prefs.menuBarPinnedTools.insert(tool) } else { prefs.menuBarPinnedTools.remove(tool) } }
            ))
            Toggle(L("Peak hours"), isOn: Binding(
                get: { prefs.peakHoursTools.contains(tool) },
                set: { if $0 { prefs.peakHoursTools.insert(tool) } else { prefs.peakHoursTools.remove(tool) } }
            ))
            .help(L("Applies Anthropic's weekday peak window, set under Advanced, to this assistant's advice and projections."))
            if tool.reportsCost {
                Toggle(L("In the Cost card"), isOn: Binding(
                    get: { prefs.costCardTools.contains(tool) },
                    set: { if $0 { prefs.costCardTools.insert(tool) } else { prefs.costCardTools.remove(tool) } }
                ))
                .disabled(!store.isShown(tool))
                .help(L("Whether the Cost card's donut, legend and total carry this assistant, in the order set under Assistants. Left out, it still shows its own spend on its own card."))
            }
        }
    }

    /// Its hook: status, snippet, Add or Repair, with what the vendor's hook reports and cannot, and for Claude Code
    /// the status line beside it, which is the other half of the same connection.
    @ViewBuilder
    private func agentHook(_ tool: ToolID) -> some View {
        if let vendor = HookVendor.vendor(for: tool) {
            Section {
                hookRow(vendor)
                // Whole, not cut to the form's two faint lines: on the assistant's own page what its hook reports and
                // cannot is the answer the reader came for, and the vendor's own step (Codex's trust in /hooks) sits
                // at the end of it.
                pageText(hookRowHelp(vendor))
                if tool == .claude {
                    Text(L("Claude Code status line"))
                        .font(.subheadline.weight(.semibold))
                        .help(L("After every turn Claude Code hands its status line the context window's fill, the official session and weekly limits (Pro and Max), a gateway's spend limit, the model and its effort, the branch and pull request, and the session's cost. With it installed the Claude ring shows a context arc, the card a Context line, and the endpoint is not asked while a session runs. A status line already configured keeps running after it."))
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
            } header: {
                Text(vendor.shape == .pluginModule ? L("OpenCode plugin") : L("%@ hook", vendor.displayName))
            }
        }
    }

    /// Its sessions: whether they are read at all, and whether its requests are answered from the notch where its
    /// hook has an event to answer. Each toggle shows what actually happens, so one the app-wide switch has turned
    /// off reads off, disabled, with the line under it saying where that switch is — never a greyed "on" that
    /// does nothing.
    private func agentSessions(_ tool: ToolID) -> some View {
        Section(L("Sessions")) {
            Toggle(L("Read its sessions"), isOn: Binding(
                get: { prefs.readsSessions(of: tool) },
                set: { prefs.sessionReadingOff = Preferences.switching(prefs.sessionReadingOff, tool, on: $0) }
            ))
            .help(L("Off, its hook still refreshes its meter, and nothing else of an event is kept: no row on the Sessions card, no wait or finish on its ring, no news, no notice, no request on the panel and no keep-awake. The sessions already listed go at once."))
            if tool.hasAnswerableHook {
                Toggle(L("Answer from the notch"), isOn: Binding(
                    get: { prefs.answersFromNotch(tool) },
                    set: { prefs.notchAnswersOff = Preferences.switching(prefs.notchAnswersOff, tool, on: $0) }
                ))
                .disabled(!prefs.answerFromNotch || !prefs.readsSessions(of: tool))
                .help(L("Its permission requests and questions open the panel with their answers, and it waits on yours; off, its terminal asks as it always has and the panel only shows the wait."))
                if !prefs.answerFromNotch {
                    caption(L("Off for every assistant under Assistants › Sessions."))
                } else if !prefs.readsSessions(of: tool) {
                    caption(L("Its sessions are not read."))
                }
                if tool == .claude, !claudeHookIsCurrent {
                    pageText(L("Claude Code answers from the notch only with the 0.7.0 hook entries: the hook section above shows Repair (or Add) until it has them."))
                }
            } else if let note = noAnswerNote(tool) {
                pageText(note)
            }
        }
    }

    /// Its notices, inside what Notifications allows for every assistant: its limits (pace, run-out, limit hit,
    /// reset, reminder, and the advice banners about it — extra usage, the cache tier, the metering) and its
    /// sessions (a wait, a long turn finishing, and the glance or panel either opens).
    private func agentNotifications(_ tool: ToolID) -> some View {
        let sessionKinds = prefs.notifyWaiting || prefs.notifyFinished
        return Section(L("Notifications")) {
            Toggle(L("Notify about its limits"), isOn: Binding(
                get: { prefs.notificationsEnabled && prefs.notifiesLimits(of: tool) },
                set: { prefs.limitNoticesOff = Preferences.switching(prefs.limitNoticesOff, tool, on: $0) }
            ))
            .disabled(!prefs.notificationsEnabled)
            .help(L("Its pace, run-out, limit-hit, reset and reminder notices, and its extra-usage and cache or metering notices, as chosen under Notifications. Off leaves them out for this assistant alone; the budget's notices cover every assistant and stay."))
            if !prefs.notificationsEnabled {
                caption(L("Off for every assistant under Notifications."))
            }
            Toggle(L("Notify when it waits or finishes a turn"), isOn: Binding(
                get: { sessionKinds && prefs.readsSessions(of: tool) && prefs.notifiesSessions(of: tool) },
                set: { prefs.sessionNoticesOff = Preferences.switching(prefs.sessionNoticesOff, tool, on: $0) }
            ))
            .disabled(!sessionKinds || !prefs.readsSessions(of: tool))
            .help(L("Its waiting and finished-turn notices, and the glance or panel they open, as chosen under Notifications. Off leaves them out for this assistant alone; its ring still shows the wait."))
            if !sessionKinds {
                caption(L("Off for every assistant under Notifications."))
            } else if !prefs.readsSessions(of: tool) {
                caption(L("Its sessions are not read."))
            }
        }
    }

    /// Where its figures come from: the login it reads and the requests it makes, as `docs/accuracy.md` lists
    /// them, and each window of its reading with the source that window carries — the reference half folded
    /// away (`expansion(of:)`), the second reads the reader can switch beside it — and for Claude Code the
    /// Keychain policy, which is about Claude Code's login and no one else's.
    private func agentSources(_ tool: ToolID) -> some View {
        Section(L("Sources")) {
            DisclosureGroup(isExpanded: expansion(of: tool)) {
                VStack(alignment: .leading, spacing: 8) {
                    // Each window with its source in words, the answer the disclosure's label asks for; then the
                    // login and the requests behind all of them.
                    VStack(alignment: .leading, spacing: 3) {
                        if let reading = store.status(tool).reading, !reading.windows.isEmpty {
                            ForEach(reading.windows) { window in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(window.label)
                                    Spacer()
                                    Text(window.source.name).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                                }
                                .font(.caption)
                                .accessibilityElement(children: .combine)
                            }
                        } else {
                            Text(subtitle(for: tool)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    note(L("Login"), loginNote(tool))
                    note(L("Readings"), readingsNote(tool))
                }
                // A disclosure's rows are not stretched the way a section's are.
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text(L("Where each window comes from"))
            }
            .accessibilityLabel(L("Where each window comes from"))
            switch tool {
            case .claude:
                Toggle(L("Also poll Claude's usage endpoint"), isOn: Binding(get: { prefs.pollClaudeEndpoint }, set: { prefs.pollClaudeEndpoint = $0; store.refreshAll() }))
                    .help(L("On, the app reads api.anthropic.com's usage endpoint with Claude Code's own login every five minutes while no fresh status line stands in for it. Off relies on the status line alone, the channel Anthropic documents: the Claude ring then fills only after a Claude Code turn, and the endpoint is never asked."))
                Picker(L("Ask for Keychain access"), selection: Binding(get: { prefs.keychainPrompts }, set: { prefs.keychainPrompts = $0 })) {
                    ForEach(KeychainPromptPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .help(L("Claude Code recreates its Keychain item on every token refresh, which forgets the Always Allow you gave. A timed read never raises the dialog: it reads the item through Apple's security tool, which Claude Code wrote it with, then the credentials file, then the status line, and otherwise keeps the last reading marked \"needs your OK\". Only a click on the Claude ring, Refresh or the Assistants toggle may ask, and only under On Refresh only."))
            case .codex:
                Toggle(L("Also read Codex reset credits"), isOn: Binding(get: { prefs.codexResetCredits }, set: { prefs.codexResetCredits = $0; store.refreshAll() }))
                    .help(L("A second read of chatgpt.com on the same login, showing a credit that would reset a window and when it expires. Claiming stays in Codex."))
            case .cursor:
                Toggle(L("Also read Cursor's usage events"), isOn: Binding(get: { prefs.cursorUsageEvents }, set: { prefs.cursorUsageEvents = $0; store.refreshAll() }))
                    .help(L("A second read of cursor.com on the same session cookie: the last 30 days of usage events, priced by their exported cost, folded into the daily-totals file as a Cursor series (Today, 30 days and the trend)."))
            case .copilot:
                Toggle(L("Also read organisation billing"), isOn: Binding(get: { prefs.copilotOrgBilling }, set: { prefs.copilotOrgBilling = $0; store.refreshAll() }))
                    .help(L("One more endpoint on the same token: each organisation you belong to that answers (owners and billing managers) adds hidden-by-default Org credits and Org spend windows for the month."))
            case .opencode:
                Toggle(L("Show sessions read from OpenCode's database"), isOn: Binding(get: { prefs.openCodeStorageSessions }, set: { prefs.openCodeStorageSessions = $0 }))
                    .help(L("With nothing installed, OpenCode's own database on this Mac is read every few seconds while OpenCode writes to it, and never written: a session appears when it starts, works from its prompt until the answer closes, and goes idle a few seconds after. It cannot see OpenCode stop to ask your permission. The OpenCode plugin under Integrations reports that and each turn's end as they happen, and once it has, this reading stands down."))
                pageText(L("OpenCode Go publishes no reading of its limits, so its meters are computed here from this Mac's own turns at the Go page's prices."))
            case .gemini, .antigravity, .kimi:
                EmptyView()
            }
        }
    }

    /// A titled note on a page: the title a step heavier than the text, the text whole rather than cut to two
    /// lines, since on its own assistant's page this is the answer the reader came for, not a hint.
    private func note(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// Why a toggle above it is off: shown, not only hovered, since a switch that cannot be moved has to say why.
    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    /// Explanatory text on an assistant's page, whole and in the secondary colour. The form's `paragraph` is the
    /// tertiary level cut to two lines, a hint beside a control; here the text is the page's own content, and the
    /// tertiary grey sits under 4.5:1 on the dark form.
    private func pageText(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    /// Where each assistant's login comes from (docs/accuracy.md, *How it reads each tool*). Literal keys per
    /// assistant, for the reason `hookRowHelp` gives.
    private func loginNote(_ tool: ToolID) -> String {
        switch tool {
        case .claude:
            L("Claude Code's own login: its Keychain item, else its credentials file, else CLAUDE_CODE_OAUTH_TOKEN. Read only: nothing is signed in, refreshed or written here.")
        case .codex:
            L("Codex's own login, from auth.json in its home folder; the plan name is Codex's own. Read only: the token is never refreshed or written.")
        case .cursor:
            L("The editor's own login, from Cursor's state database, sent the way cursor.com's dashboard sends it. Read only: never refreshed or written.")
        case .gemini:
            L("The Google login Gemini CLI keeps in ~/.gemini/oauth_creds.json. Read only: never refreshed or written.")
        case .antigravity:
            L("The Google login Gemini CLI keeps in ~/.gemini/oauth_creds.json. The Antigravity app keeps its own in the Keychain, out of reach, so one sign-in through Gemini CLI is needed. Read only: never refreshed or written.")
        case .copilot:
            L("The token Copilot's editor plugin or gh keeps: apps.json, then hosts.json, then gh's hosts.yml, each tried in turn. Read only: never refreshed or written.")
        case .kimi:
            L("Kimi Code's own login: the access token in credentials/kimi-code.json under $KIMI_SHARE_DIR or ~/.kimi; the refresh token beside it is never read. Read only: never refreshed or written.")
        case .opencode:
            L("No login: OpenCode's own database on this Mac, opened read-only. Nothing is sent, and no token is read.")
        }
    }

    /// Where each assistant's figures come from, in one line (docs/accuracy.md, *How it reads each tool* and
    /// *Who each request says it is*).
    private func readingsNote(_ tool: ToolID) -> String {
        switch tool {
        case .claude:
            L("The status line after every turn, Anthropic's usage endpoint while it is allowed below, and this Mac's transcripts for the cost.")
        case .codex:
            L("chatgpt.com's usage endpoint, else the newest rate-limit line in Codex's session files, and those files for the cost.")
        case .cursor:
            L("cursor.com's usage summary and the dashboard's own reads, and its usage events for the cost.")
        case .gemini:
            L("Google's Code Assist quota, under Gemini CLI's own identity. No cost: it meters quota, not money.")
        case .antigravity:
            L("Google's Code Assist quota, under Antigravity's own identity where its app is on this Mac. No cost: it meters quota, not money.")
        case .copilot:
            L("api.github.com's Copilot quota, the read its editor plugin makes, and its AI credits, a cent each, for the cost.")
        case .kimi:
            L("api.kimi.com's usage endpoint, the read Kimi Code's own /usage command makes. No cost: it meters a request allowance, not money.")
        case .opencode:
            L("OpenCode's recorded turns and sessions, and on the Go plan a meter computed here from them at the Go page's prices and limits; its cost from the same records.")
        }
    }

    /// Why an assistant whose hook has nothing to answer offers no *Answer from the notch*.
    private func noAnswerNote(_ tool: ToolID) -> String? {
        switch tool {
        case .cursor: L("Cursor has no event that can be answered: its approvals are always answered in Cursor.")
        case .gemini: L("Gemini CLI's hook only reports: its permission prompts are always answered in the terminal.")
        case .kimi: L("Kimi Code has no event that can be answered: its approvals are always answered in the terminal.")
        case .antigravity: L("Antigravity has no hook: its IDE reports no event the notch could read or answer.")
        case .opencode: L("OpenCode's plugin reports its permission requests and their answers but cannot answer them: its approvals are always answered in OpenCode.")
        case .claude, .codex, .copilot: nil
        }
    }

    /// Literal keys per vendor rather than a string on HookVendor: LocalizationTests only sees a quoted literal
    /// passed straight to `L`, so a key that lived on the vendor would be reported as shipped but unused.
    private func hookRowHelp(_ vendor: HookVendor) -> String {
        switch vendor {
        case .claude:
            L("Claude Code reports session starts and ends, prompt sends, waits for your input, stops and stop failures, subagent starts and stops, compactions, model switches, an MCP server asking for input and its answer, teammates going idle, failed and auto-refused tool calls, each finished batch of tool calls and a change of directory. It is never registered for WorktreeCreate, WorktreeRemove or PreModelSwitch, which would put the app in the way of worktrees and model switches.")
        case .codex:
            L("Codex reports session starts and ends, prompt sends, stops, interrupted turns, subagent starts and stops, and the moment it is about to ask your approval. That approval prompt is its one wait: the Codex ring shows the waiting hand for it and lets go at the next prompt, stop or subagent, or after ten minutes. Codex has no event for a question or a rate limit, so a limit hit waits for the next poll. Codex skips a new or changed hook until you open /hooks inside Codex and trust it, and a running session keeps the hooks it started with.")
        case .cursor:
            L("Cursor reports when a conversation starts or ends, when you send a prompt, when a turn stops and when a subagent starts or stops. It has no event for a wait on your approval or for a rate limit, so the Cursor ring shows the finished tick and never the waiting hand, and a turn that was aborted or errored ends without the tick. Cursor reloads hooks.json as soon as it is saved.")
        case .gemini:
            L("Gemini CLI reports session starts and ends, prompt sends, the end of each turn, and the moment it stops to ask your permission for a tool. That notice is its one wait: the Gemini ring shows the waiting hand for it and lets go when the turn ends, the next prompt is sent or the session ends, or after ten minutes. It has no event for a subagent, a rate limit or a cancelled turn, so a cancelled turn shows as working until the next prompt or the session ends. Gemini CLI reads settings.json when it starts; a file with comments in it is left alone, so paste the snippet instead. An entry added before 0.9.0 lit the Antigravity ring and reads as out of date until Repair points it at Gemini CLI's own. The Antigravity IDE's own hooks report none of this, so Antigravity has no hook row.")
        case .kimi:
            L("Kimi Code reports session starts and ends, prompt sends, the end of each turn, a turn that failed, and subagent starts and stops. It has no event for a wait on your approval or a question, so the Kimi ring shows the finished tick and never the waiting hand, and a failed turn ends without the tick. The entries are [[hooks]] tables added to the end of config.toml, and the rest of the file is left exactly as it was; a file that already defines hooks another way is left alone, so paste the snippet instead. Kimi Code reads config.toml when it starts, and /hooks lists the entries.")
        case .copilot:
            L("GitHub Copilot reports session starts and ends, prompt sends, stops, subagent starts and stops, and the notices it raises when it asks your permission or a question. Those two notices are its wait: the Copilot ring shows the waiting hand for them and lets go at the next prompt or stop, or after ten minutes. It has no event for a rate limit or a failed turn, and its built-in general-purpose agent reports no subagents. The file is Notchmeter's own under ~/.copilot/hooks, so removing the hook is deleting it; Copilot reads it when it starts, and /env lists it. Copilot's cloud coding agent never sees it.")
        case .opencode:
            L("OpenCode's plugin reports session starts and ends, prompt sends, each turn's end and a failed one, subagent starts and stops, and the moment it stops to ask your permission and the moment that is answered, so the OpenCode ring shows the waiting hand only while it waits. It is not answered from the notch. The file is Notchmeter's own in ~/.config/opencode/plugins, so removing the plugin is deleting it; OpenCode loads it when it starts. Without it, OpenCode's sessions are read from its own database, a few seconds late and never waiting.")
        }
    }

    /// What Add and Repair say after they have written something: the step the vendor still needs before the new
    /// entry runs, because `.installed` can only see the file. Codex trusts a hook by its hash in `/hooks`, so a
    /// fresh entry — and a repaired one, whose command changed — is skipped until the user has been shown it; Gemini
    /// CLI and Copilot read their files when they start, so a session already open never fires the entry. Claude
    /// Code's note would say the same as Gemini's and the Claude row has always gone without one; Cursor reloads
    /// its file as it is saved (`HookVendor.reloadsLive`), so there is nothing to tell. Literal keys, as above.
    private func hookInstallNote(_ vendor: HookVendor) -> String? {
        switch vendor {
        case .codex:
            L("Codex skips a hook it has not been shown: open /hooks in Codex and trust the new entry. Sessions already running keep the hooks they started with.")
        case .gemini:
            L("Gemini CLI reads settings.json when it starts: the hook works from the next session.")
        case .copilot:
            L("Copilot CLI reads its hooks when it starts: restart it, then /env lists the file.")
        case .kimi:
            L("Kimi Code reads config.toml when it starts: the hook works from the next session.")
        case .opencode:
            L("OpenCode loads its plugins when it starts: the plugin works from the next session.")
        case .claude, .cursor:
            nil
        }
    }

    /// The row's message after Add or Repair: the installer's summary, and the vendor's activation note when the
    /// file was actually written (`Installed.added` is empty when every event was already there and current).
    private func hookOutcome(_ installed: HookSettings.Installed, vendor: HookVendor) -> String {
        guard !installed.added.isEmpty, let note = hookInstallNote(vendor) else { return installed.summary }
        return installed.summary + " " + note
    }

    private var integrationsSection: some View {
        Section(L("Other tools")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("MCP server")).font(.subheadline.weight(.semibold))
                // Documentation with no control of its own to hang a tooltip on: the first two lines stay on the
                // page and the tooltip carries the rest.
                paragraph(L("Cursor, Codex and Claude Desktop can ask for the limits through the Model Context Protocol: `%@ --mcp` speaks JSON-RPC over stdio with one tool, get_limits.", AppInfo.name))
                Button(L("Show snippet…")) { showMCPSnippet = true }
                Divider()
                Text(L("Remote Claude Code over SSH")).font(.subheadline.weight(.semibold))
                paragraph(L("With the local API on, a hook on another machine reaches this notch through `ssh -R %1$ld:127.0.0.1:%1$ld host`: its command is `curl -s -X POST http://127.0.0.1:%1$ld/v1/hook -d @-` with a `host` label; the recipe is in docs/hooks.md.", Int(LocalAPI.port)))
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
                .help(L("Synced Claude Code logs from another Mac, or any folder of transcripts: a projects folder or a flat folder of session folders both work. Claude Desktop's Cowork sessions are read automatically when present. The rate-limit meters are account-wide already; this only widens the cost card."))
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
            Group {
                PeakHoursEditor(prefs: prefs)
                HStack {
                    Button(L("Export history…")) { exportHistory() }
                        .help(L("The daily-totals file as CSV or JSON: one row per day with the cost, the five token buckets, the top model and the per-model and per-project cost."))
                    if let exportMessage {
                        Text(exportMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .opacity(searchOpacity(.advanced))
            // The rows nobody touches twice a year, folded away: the proxy, the log level, the diagnostics copy
            // and the currency rate. A search that lands on one of them opens the group (`onChange(of: query)`).
            DisclosureGroup(isExpanded: $diagnosticsExpanded) {
                Group {
                    LabeledContent(L("Route requests through")) {
                        field($proxyText, prompt: L("System (default)"), label: L("Route requests through"), width: 1.5 * Self.fieldWidth)
                            .onSubmit { applyProxy() }
                        Button(L("Apply")) { applyProxy() }
                    }
                    .help(L("Empty follows the proxy in Network settings; `http://host:port` or `socks5://host:port` routes only this app's vendor requests through it, from the next request on."))
                    Toggle(L("Debug logging"), isOn: Binding(get: { prefs.debugLogging }, set: { prefs.debugLogging = $0 }))
                        .help(L("Writes each vendor request's outcome (status code and size, never a token or a body) to the unified log at info level, where Copy diagnostics and `log show --info` pick it up."))
                    HStack {
                        Button(L("Copy diagnostics")) {
                            let text = requests.diagnostics()
                            Diagnostics.copy(text)
                            diagnosticsMessage = L("Copied %ld lines.", text.split(separator: "\n").count)
                        }
                        .help(L("The last 10 minutes of this app's unified log, each assistant's status, the hook and status-line state, the layout and the macOS version, scrubbed of your home folder, for a bug report. Never a token."))
                        if let diagnosticsMessage {
                            Text(diagnosticsMessage).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    // A disclosure's rows are not stretched the way a section's are, so the button would sit
                    // centred under the labelled rows above it.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    LabeledContent(L("Rate per dollar")) {
                        field($rateText, prompt: Self.ratePlaceholder, label: L("Rate per dollar"))
                            .onSubmit { applyRate() }
                        Button(L("Apply")) { applyRate() }
                    }
                    .help(L("Costs are computed in US dollars at API list prices; a code (EUR, GBP, JPY) and your own rate convert them. Nothing is fetched: the rate is yours."))
                    crashReportRows
                }
                .opacity(searchOpacity(.diagnostics))
            } label: {
                Text(L("Diagnostics")).opacity(searchOpacity(.diagnostics))
            }
            .accessibilityLabel(L("Diagnostics"))
            Button(L("Reset All Settings…")) { resetAll() }
                .help(L("Puts every setting back to its default, forgets the cached readings and which notifications were sent, and relaunches. Transcripts, the cost cache and the drain log are kept."))
                .opacity(searchOpacity(.advanced))
        }
    }

    enum CrashLookup: Equatable {
        case unknown
        case found(CrashReports.Report?)
    }

    /// The newest crash report's date, with Copy and Show in Finder, or a plain line saying there is none. Nothing
    /// here leaves the Mac (docs/permissions.md). The folder is listed only while the disclosure is open, keyed on
    /// it so each opening looks again, and never under `--render-assets`, whose picture must not read this machine.
    @ViewBuilder private var crashReportRows: some View {
        let help = L("The newest report macOS wrote when %@ crashed, from ~/Library/Logs/DiagnosticReports. It stays on this Mac: Copy puts it on the clipboard, scrubbed of your home folder, for you to paste into a bug report.", AppInfo.name)
        LabeledContent(L("Last crash report")) {
            switch crashReport {
            case .unknown: Text(verbatim: "")
            case .found(nil): Text(L("None on this Mac")).foregroundStyle(.secondary)
            case .found(let report?): Text(Self.crashDate(report.modified)).foregroundStyle(.secondary)
            }
        }
        .help(help)
        .task(id: diagnosticsExpanded) {
            guard diagnosticsExpanded, requests.renderedHookStatus == nil else { return }
            let found = await Task.detached(priority: .utility) { CrashReports.newest() }.value
            crashReport = .found(found)
        }
        if case .found(let report?) = crashReport {
            HStack {
                Button(L("Copy crash report")) { copyCrashReport(report) }
                Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([report.url]) }
                if let crashMessage {
                    Text(crashMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            .help(help)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The date in the app's own language rather than the system's, with how long ago beside it.
    static func crashDate(_ date: Date, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Localization.current)
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "\(formatter.string(from: date)) · \(RelativeTime.ago(date, now: now))"
    }

    private func copyCrashReport(_ report: CrashReports.Report) {
        Task {
            let text = await Task.detached(priority: .userInitiated) { CrashReports.text(of: report.url) }.value
            guard let text else {
                crashMessage = L("The crash report could not be read.")
                return
            }
            Diagnostics.copy(text, kind: "crash report")
            crashMessage = L("Copied %ld lines.", text.split(separator: "\n").count)
        }
    }

    private var aboutSection: some View {
        Section {
            Text(L("Version %@", AppInfo.version))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help(L("%@ never signs in. It reads usage from tools already signed in on this Mac and keeps no tokens. macOS asks once per tool for permission to read its saved login; choose Always Allow so it stays quiet.", AppInfo.name))
            // The one ask the app makes, kept to the About footer where a happy user is already looking, in the
            // same quiet type as the version line: the app is free and stays free, and a button any louder than
            // this would make it read as if it were not.
            Button(L("Support %@…", AppInfo.name)) { NSWorkspace.shared.open(AppInfo.supportURL) }
                .buttonStyle(.link)
                .font(.caption2)
                .help(L("An optional pay-what-you-want page. Nothing in the app is held back, and nothing changes after you pay."))
        }
    }

    // MARK: - Helpers

    private func hookStatusColor(_ status: HookSettings.Status) -> Color {
        switch status {
        case .installed: .secondary
        case .stale, .partial: Palette.warn
        case .notInstalled: .secondary
        }
    }

    private func refreshHookStatus() {
        for vendor in HookVendor.allCases {
            hookStatus[vendor] = requests.renderedHookStatus?.hook[vendor] ?? HookSettings.status(vendor: vendor)
        }
        statuslineStatus = requests.renderedHookStatus?.statusline ?? HookSettings.statuslineStatus()
        // What the Sessions card's empty state and its upgrade line read, kept current by the one place the user
        // installs a hook.
        store.hookInstalledTools = Set(hookStatus.filter { $0.value != .notInstalled }.map(\.key.tool))
        store.hooksInstalled = !store.hookInstalledTools.isEmpty
    }

    /// An assistant's standing in a line: under its name in the Assistants list, under its switch on its page, and
    /// on its page wherever its windows would be listed while it has none. The last is the same line on purpose:
    /// an assistant that is off or not on this Mac is not waiting for a reading, and a page whose overview says
    /// "Off" two rows above a "Waiting for the first reading" promised one that was never coming.
    private func subtitle(for tool: ToolID) -> String {
        Self.statusText(installed: store.isInstalled(tool), status: store.status(tool))
    }

    /// `subtitle(for:)` as a function of what the store knows, so a test can hold it to its words without a window:
    /// not installed first, whatever the status says, since a store with no provider for a tool leaves its status
    /// at `.waiting`.
    static func statusText(installed: Bool, status: ToolStatus) -> String {
        guard installed else { return L("Not installed on this Mac") }
        switch status {
        case .off: return L("Off")
        case .waiting: return L("Waiting for the first reading")
        case .idle(let message): return message
        case .ready(let reading): return Self.readySubtitle(reading)
        case .needsAttention(let message, _), .failed(let message, _), .rateLimited(let message, _): return message
        case .offline: return L("Offline, retrying")
        case .notInstalled: return L("Not installed on this Mac")
        }
    }

    /// "Signed in · Max" for a reading taken over a login. A reading computed here from the tool's own local
    /// records (OpenCode Go, every window `computedLocally`) read no login at all, which the Welcome tour and
    /// docs/privacy.md promise, so the row says where its figure came from rather than claiming one.
    static func readySubtitle(_ reading: UsageReading) -> String {
        if !reading.windows.isEmpty, reading.windows.allSatisfy({ $0.source == .computedLocally }) {
            return reading.plan.map { L("%@ · computed from this Mac's turns", $0) } ?? L("Computed from this Mac's turns")
        }
        return reading.plan.map { L("Signed in · %@", $0) } ?? L("Signed in")
    }

    private func applyCurrency() {
        let code = currencyText.trimmingCharacters(in: .whitespaces).uppercased()
        prefs.currencyCode = code.count == 3 ? code : "USD"
        currencyText = prefs.currencyCode
    }

    /// The rate has its own Apply under Diagnostics since 0.7.0; until then it shared the currency row's.
    private func applyRate() {
        prefs.currencyRate = Double(rateText.replacingOccurrences(of: ",", with: ".")) ?? 1
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

    /// Asks first, as a sheet on the Settings window so Return and Escape reach it; the vendor's file is backed up
    /// beside itself before anything is merged in. A dry run (from `--smoke`) writes to the given file and closes
    /// itself.
    private func installHook(vendor: HookVendor = .claude, at url: URL? = nil, dryRun: Bool = false) {
        let url = url ?? vendor.fileURL
        let alert = NSAlert()
        if vendor.shape == .pluginModule {
            // The plugin is a file of Notchmeter's own rather than an entry merged into the user's, so the sheet says
            // what is written, and that a file already at the path is backed up rather than merged.
            alert.messageText = L("Add the Notchmeter plugin to OpenCode?")
            alert.informativeText = L("Notchmeter writes its own plugin at %1$@. A file already there is copied to %2$@.bak-<date> first; nothing else in OpenCode's configuration changes.",
                                      url.path, vendor.fileName)
        } else {
            alert.messageText = L("Add the Notchmeter hook to %@?", vendor.fileName)
            alert.informativeText = L("%1$@ is copied to %2$@.bak-<date> first. Hooks already there are kept; Notchmeter's entry is appended under %3$@.",
                                      url.path, vendor.fileName, vendor.events.joined(separator: ", "))
        }
        alert.addButton(withTitle: L("Add"))
        alert.addButton(withTitle: L("Cancel"))
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            defer { if dryRun { requests.hookSheetDryRun = nil } }
            guard response == .alertFirstButtonReturn else { return }
            do {
                hookMessage[vendor] = try hookOutcome(HookSettings.install(vendor: vendor, at: url), vendor: vendor)
            } catch {
                hookMessage[vendor] = error.localizedDescription
            }
            if !dryRun { refreshHookStatus() }
            // The Welcome window asked for the status line as well: its sheet goes up once this one is down,
            // which the completion is called slightly ahead of.
            if requests.statuslineOffer, !dryRun {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    runStatuslineOffer()
                }
            }
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

    private func repairHook(vendor: HookVendor) {
        do {
            hookMessage[vendor] = try hookOutcome(HookSettings.repairInstall(vendor: vendor), vendor: vendor)
        } catch {
            hookMessage[vendor] = error.localizedDescription
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

/// Which windows the rings show, and which windows the card leaves out, per tool. Up to three rings
/// (RingSelection.maximum); the third is empty until it is chosen, so the default stays at two.
private struct WindowChoices: View {
    let tool: ToolID
    let reading: UsageReading
    let prefs: Preferences

    var body: some View {
        let ring = prefs.ringWindows(of: reading)
        let choices = prefs.ringChoices(of: reading)
        Picker(L("Outer ring"), selection: Binding(get: { ring.first?.id ?? "" }, set: { set(at: 0, $0) })) {
            ForEach(choices) { window in Text(window.label).tag(window.id) }
        }
        .disabled(choices.isEmpty)
        Picker(L("Inner ring"), selection: Binding(get: { id(of: ring, at: 1) }, set: { set(at: 1, $0) })) {
            Text(L("None")).tag("")
            ForEach(choices) { window in Text(window.label).tag(window.id) }
        }
        .disabled(choices.isEmpty)
        Picker(L("Third ring"), selection: Binding(get: { id(of: ring, at: 2) }, set: { set(at: 2, $0) })) {
            Text(L("None")).tag("")
            ForEach(choices) { window in Text(window.label).tag(window.id) }
        }
        .disabled(choices.isEmpty)
        // The checkboxes read from the shown set rather than the raw preference, so a window the floor is showing
        // against a stale preference reads as shown; the one window left is disabled, with the help saying why.
        let shown = prefs.shownWindows(of: reading)
        LabeledContent(L("Hide")) {
            ForEach(reading.windows) { window in
                let last = !WindowFloor.canHide(window, shown: shown)
                Toggle(window.label, isOn: Binding(get: { !shown.contains { $0.id == window.id } }, set: { prefs.setHidden($0, window: window, in: reading) }))
                    .toggleStyle(.checkbox).controlSize(.small)
                    .disabled(last)
                    .help(last ? L("The last window a tool shows stays on the card: the rings and the menu bar would have nothing to draw without it. Show another window before hiding this one.") : "")
            }
        }
    }

    private func id(of ring: [LimitWindow], at index: Int) -> String {
        ring.indices.contains(index) ? ring[index].id : ""
    }

    /// The write is the preference's (Preferences.setRingWindow), where the reveal of a hidden pick goes through
    /// the floor the same way the Hide checkboxes' does, so the two rows cannot disagree about what a reveal keeps.
    private func set(at index: Int, _ id: String) {
        prefs.setRingWindow(at: index, to: id, in: reading)
    }
}

/// What each sound category is called on its row, and what the row says about which notices it covers. Here
/// rather than beside `SoundCategory` because the Settings search index (SettingsSearch) is checked against the
/// literals in this file.
extension SoundCategory {
    var title: String {
        switch self {
        case .completion: L("Turn finished")
        case .waiting: L("Waiting reminder")
        case .permission: L("Permission request")
        case .question: L("Question")
        case .plan: L("Plan ready to approve")
        case .limit: L("Limit alert")
        }
    }

    /// A standing line under the rows whose reach is not what their name suggests, shown rather than hovered:
    /// the reminder is not a request, a plan that plays the permission sound looks like a fault until its hook
    /// entry is known, and the limit sound is also what advice and the Test button play while the gentler pace
    /// notices play nothing.
    var caption: String? {
        switch self {
        case .waiting: L("Claude Code's reminder that you have been idle for a minute, and a Cursor turn gone quiet that may be waiting on an approval: a session that may need you, as against the three below, which have asked.")
        case .plan: L("A plan is told apart only when Claude Code asks for its approval through the hook; a wait that does not say what it wants plays the permission sound.")
        case .limit: L("A window almost out or out, and advice about money already being spent; Test notification plays it too. Cutting it close, Will run out, resets and reminders arrive without a sound.")
        case .completion, .permission, .question: nil
        }
    }

    /// The row's help: the notices it covers, in full.
    var help: String {
        switch self {
        case .completion: L("A turn longer than the minimum above, when Notify when a turn finishes is on.")
        case .waiting, .plan, .limit: caption ?? ""
        case .permission: L("A tool waiting for your approval, and any wait that has stopped a session without saying what it wants.")
        case .question: L("Claude Code's AskUserQuestion, an MCP server asking for input, and an agent asking for input.")
        }
    }
}

/// What one sound row wants and what it has, in points: the width its name, menu, Preview and Silence take on one
/// line, and the width the form gives the row. Every SoundPicker reports its own, so the block can decide once for
/// all six whether the rows go to two lines (SettingsView.soundRowsTwoLine).
private struct SoundRowWidths: Equatable {
    var ideal: CGFloat = 0
    var available: CGFloat = 0
    var fits: Bool { ideal <= available }
}

/// One category's sound: the system alert sounds and the user's imported files, with a file to import at the foot
/// of the menu, a Preview, and the category's Silence box.
///
/// Choose file… is the menu's last entry rather than a button beside it, as Other… is in macOS's own sound menus:
/// the row had room for the picker and two buttons, and the Silence box needed the space of the second. None is no
/// longer an entry: the box is how a category goes quiet, and it keeps the chosen sound for when it comes back.
private struct SoundPicker: View {
    let title: String
    @Binding var choice: String
    @Binding var silenced: Bool
    /// The choice the Default entry stands for: the system alert, or a category's own sound
    /// (`NotificationSound.defaultChoice(for:)`), so choosing Default puts the row back where it started.
    var defaultTag: String = NotificationSound.defaultChoice
    /// A standing explanation under the row, always shown.
    var caption: String?
    /// Whether the Preview and the Silence box go under the name and the menu rather than beside them. The
    /// block's decision rather than the row's (SettingsView.soundRowsTwoLine), so that the six menus keep to one
    /// column whichever layout the block is in.
    var twoLine = false
    /// Where the row reports what its one line wants and what it has (SoundRowWidths), for that decision. Called
    /// from layout, whenever either width changes.
    var measured: (SoundRowWidths) -> Void = { _ in }
    /// What the last import or fallback has to say, shown under the row; nil when there is nothing to report.
    @State private var note: String?
    /// The row's two widths as last measured, kept so that a change to one is reported beside the other.
    @State private var widths = SoundRowWidths()
    /// True from the moment a file is chosen until its import has been applied or refused. The import runs off the
    /// main actor (an mp3 is decoded whole), so the row stays live meanwhile and this keeps a second Choose file…
    /// from starting a parallel import that would race the first for the same name in ~/Library/Sounds.
    @State private var importing = false
    /// Bumped whenever Choose file… is picked, to rebuild the menu. The pick changes no state (the binding refuses
    /// it), so without a change of identity the pop-up button could go on showing "Choose file…" as its title after
    /// a cancelled panel, over a choice that never moved.
    @State private var menuGeneration = 0

    /// The menu entry that opens the file panel instead of being chosen. No stored choice can take this form
    /// (NotificationSound's are "default", "none", "system:…" and "custom:…"), so it can never be mistaken for one.
    private static let chooseFileTag = "choose-file"

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // One line where every row's words fit. Where one row's do not — Russian's "По умолчанию (Glass)"
            // beside "Прослушать" and "Без звука" at the window's narrowest — the name and the menu keep a line
            // of their own and the two controls go under it, on every row alike, rather than the menu cutting off
            // the very sound it names. The name is a Text of its own, not the Picker's label, because the fit is
            // judged on ideal widths and a Form's labelled Picker asks for all the room there is.
            if twoLine {
                VStack(alignment: .trailing, spacing: 6) {
                    HStack {
                        name
                        picker
                    }
                    HStack { controls }
                }
            } else {
                HStack {
                    name
                    picker
                    controls
                }
            }
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        // The one line at the width it wants, laid out under the row and never drawn, so the row can say whether
        // it would fit: the line on screen is cut to the room it has, and tells nothing about what it wanted. A
        // copy of the menu over a constant rather than the menu itself, so picking can open no panel; disabled
        // and out of the accessibility tree, so neither Tab nor VoiceOver can land on a control nobody can see.
        .background(alignment: .leading) {
            HStack {
                name
                menu(selection: .constant(choice))
                controls
            }
            .fixedSize()
            .hidden()
            .disabled(true)
            .accessibilityHidden(true)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { report(\.ideal, $0) }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { report(\.available, $0) }
        .onAppear { settleMissingCustom() }
    }

    /// One width measured: the pair goes up whole, so the block never compares a new ideal with a stale room.
    private func report(_ width: WritableKeyPath<SoundRowWidths, CGFloat>, _ value: CGFloat) {
        widths[keyPath: width] = value
        measured(widths)
    }

    /// The row's name, pushed away from the menu. Hidden from VoiceOver, which hears it as the menu's own label.
    private var name: some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
        }
        .accessibilityHidden(true)
    }

    /// The sound menu. The selection never becomes the Choose file… entry: picking it opens the panel, and the menu
    /// goes on showing the sound that was chosen until an import replaces it.
    private var picker: some View {
        menu(selection: Binding(get: { choice }, set: { picked in
            if picked == Self.chooseFileTag {
                menuGeneration += 1
                chooseFile()
            } else {
                choice = picked
            }
        }))
        .id(menuGeneration)
    }

    /// The menu over `selection`: the row's own choice on screen, a constant in the measuring copy.
    private func menu(selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text(NotificationSound.defaultTitle(for: defaultTag)).tag(defaultTag)
            Divider()
            // The default's own sound is listed once, as Default: two entries with one tag leave the Picker unable
            // to say which is chosen.
            ForEach(NotificationSound.systemSounds().filter { "system:\($0)" != defaultTag }, id: \.self) { name in
                Text(name).tag("system:\(name)")
            }
            let custom = NotificationSound.customSounds()
            if !custom.isEmpty {
                Divider()
                ForEach(custom, id: \.self) { name in Text((name as NSString).deletingPathExtension).tag("custom:\(name)") }
            }
            Divider()
            Text(L("Choose file…")).tag(Self.chooseFileTag).disabled(importing)
        }
        .labelsHidden()
        // At its own width, always: a menu Picker reports an ideal width short of what its title needs, so
        // without this the one-line layout was chosen for German's "Standard (Basso)" and then cut it to "Ba…".
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Six rows each carry a Preview and a Silence box, so VoiceOver hears which row's each one is. The box keeps
    /// its word beside it: a crossed-out speaker alone would put a state on an icon.
    @ViewBuilder private var controls: some View {
        Button(L("Preview")) { NotificationSound.preview(choice) }
            .accessibilityLabel(L("Preview the %@ sound", title))
        Toggle(L("Silence"), isOn: $silenced)
            .toggleStyle(.checkbox)
            .accessibilityLabel(L("Silence the %@ sound", title))
    }

    /// A stored "custom:" choice whose file is gone, or was imported as an .mp3/.m4a that 0.5.0 stopped offering,
    /// matches no tag and left the Picker blank. Default is what the banner plays for it anyway (`unSound`), so the
    /// stored choice is brought in line and the row says which file it was, once, so the change is not a mystery.
    /// The two cases get different words: the mp3 is still sitting in ~/Library/Sounds, so telling its owner it is
    /// gone would send them to the folder to find it there with no hint that choosing it again is what converts it.
    private func settleMissingCustom() {
        guard choice.hasPrefix("custom:") else { return }
        let name = String(choice.dropFirst("custom:".count))
        guard !NotificationSound.customSounds().contains(name) else { return }
        let stored = choice
        choice = defaultTag
        note = NotificationSound.isUnplayableCustom(stored)
            ? L("%@ is in a format Notification Center cannot play, so Default plays until you choose the file again, which converts it.", name)
            : L("%@ is no longer in ~/Library/Sounds, so Default plays until you choose another.", name)
    }

    private func chooseFile() {
        // The menu entry is disabled while an import runs; this is the same rule for a menu that was open when it
        // started.
        guard !importing else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        NSApp.activate()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                // Until 0.5.0 a failed import was swallowed by `try?` and the Picker simply stayed where it was, so
                // the user could not tell a refused file from a copy that had not happened yet.
                // The import may decode a whole mp3 or m4a into PCM, so it runs off the main actor and only its
                // result is applied here; the row says what it is doing meanwhile, since the Picker does not move
                // until the file is in place.
                importing = true
                note = L("Importing %@…", url.lastPathComponent)
                defer { importing = false }
                do {
                    choice = try await NotificationSound.importCustomInBackground(url)
                    note = nil
                } catch {
                    note = error.localizedDescription
                }
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
                .help(L("Since March 2026 Anthropic applies tighter 5-hour session limits on weekdays from 5:00 to 11:00 Pacific (reported, not documented; docs/accuracy.md). Inside it the advice names when off-peak starts, the drain log keeps peak and off-peak rates apart, and the footer says \"peak hours\". Applies to the assistants whose own page has Peak hours on."))
            if prefs.peakHours.enabled {
                // Four controls in one row clipped the times to "5:0…" at the window's minimum width.
                HStack {
                    QuietHourPicker(title: L("From"), minutes: Binding(get: { prefs.peakHours.startMinute }, set: { prefs.peakHours.startMinute = $0 }), format: prefs.timeFormat)
                    QuietHourPicker(title: L("To"), minutes: Binding(get: { prefs.peakHours.endMinute }, set: { prefs.peakHours.endMinute = $0 }), format: prefs.timeFormat)
                    Text(prefs.peakHours.timeZone.abbreviation() ?? prefs.peakHours.timeZoneID).font(.caption).foregroundStyle(.secondary)
                }
                // The hours are Anthropic's, on Anthropic's clock; the row above is already full at the window's
                // minimum width, so what they mean where the reader sits goes on the line below.
                if let hint = prefs.peakHours.localHint(format: prefs.timeFormat) {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                }
                Toggle(L("Weekdays only"), isOn: Binding(get: { prefs.peakHours.weekdaysOnly }, set: { prefs.peakHours.weekdaysOnly = $0 }))
                    .toggleStyle(.checkbox).controlSize(.small)
            }
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
    /// Time format reaches the entries because the peak-hours row prints the same two times again beside them, as
    /// the local-time hint; one row reading "From 5:00 AM … (13:00–19:00 your time)" reads as two windows, not one.
    let format: TimeFormatPreference

    var body: some View {
        Picker(title, selection: $minutes) {
            ForEach(Array(stride(from: 0, to: 24 * 60, by: 30)), id: \.self) { value in
                Text(Self.label(value, format: format)).tag(value)
            }
        }
    }

    static func label(_ minutes: Int, format: TimeFormatPreference) -> String {
        let date = Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
        return ResetText.time(date, format: format)
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
                Button(L("Add to %@…", "settings.json")) { install() }.keyboardShortcut(.defaultAction)
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
            // Arrows, not chevrons: the chevron belongs to the row's expand control beside them.
            Button { up?() } label: { Image(systemName: "arrow.up") }
                .disabled(up == nil)
                .help(L("Move up"))
                .accessibilityLabel(L("Move up"))
            Button { down?() } label: { Image(systemName: "arrow.down") }
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

    /// Close alone, the way a settings panel wears its corner. The style mask has no `.miniaturizable` — a
    /// window that is always raised above the readouts has nowhere useful to be minimised to — so macOS drew the
    /// middle light and then greyed it out, which reads as a broken window rather than as a deliberate one. The
    /// zoom button is worse than useless here: `.resizable` earns it the system's Move & Resize menu, whose
    /// halves, quarters and full screen all move the window out from under the notch that `frame(for:…)` spent
    /// its arithmetic putting it under. Hiding the button leaves the edges draggable, which is the only resizing
    /// this window ever wanted.
    func wearCloseOnly() {
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }
}

/// The system colour panel, opened by hand rather than through SwiftUI's `ColorPicker`. Two reasons, both about
/// this window. It is a non-activating panel, so with the app inactive the first click on SwiftUI's well is spent
/// making the window key and nothing opens at all — the second one works, which from the outside is a feature that
/// does not exist. And the colour panel is an ordinary window, while this one is raised above a panel drawing at
/// screen-saver level, so wherever it was last left it can open under both. So: activate, one level higher again,
/// and the colour flows back into the preference as it is picked.
@MainActor
final class ColourWell: NSObject {
    private var apply: (NSColor) -> Void = { _ in }

    func open(colour: NSColor, above level: NSWindow.Level, apply: @escaping (NSColor) -> Void) {
        self.apply = apply
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = colour
        panel.level = NSWindow.Level(rawValue: level.rawValue + 1)
        panel.hidesOnDeactivate = false
        panel.setTarget(self)
        panel.setAction(#selector(colourChanged))
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Closed with the window that opened it: it sits above everything, and a colour panel left standing over
    /// every other app is not something the user asked for.
    static func closePanel() {
        guard NSColorPanel.sharedColorPanelExists, NSColorPanel.shared.isVisible else { return }
        NSColorPanel.shared.close()
    }

    @objc private func colourChanged(_ sender: NSColorPanel) {
        apply(sender.color)
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    /// A sidebar beside a grouped Form: neither has an intrinsic height, and the sidebar is a fixed 190 pt of
    /// the width, so the window is sized explicitly. The height stays under the 640 the one-column form used, so
    /// the placement below still fits the window on a short screen.
    nonisolated static let contentSize = NSSize(width: 700, height: 620)
    /// The smallest the window is meant to be dragged to, told to both the window and the view. AppKit recomputes
    /// `minSize` from the content once the hosting view lays out, so it is `SettingsView`'s own `.frame` minimum
    /// that actually holds the floor — the two carry the same numbers so a drag can never lay the view out larger
    /// than the window that clips it.
    nonisolated static let minSize = NSSize(width: 640, height: 460)
    /// The window's top sits this far below the screen's top safe area: under the notch and the menu bar, with
    /// the collapsed panel's rings clear above it.
    nonisolated static let topClearance: CGFloat = 60
    /// Gap between the readouts' lower edge and the window below them.
    nonisolated static let readoutClearance: CGFloat = 12

    private let prefs: Preferences
    /// The panel's level as `present` last saw it, so the window can return to sitting above it.
    private var panelLevel: NSWindow.Level?
    private var aside = false

    /// `pane` is which sidebar row the window opens on. The app takes the default; `--render-assets` names one,
    /// because it captures the six in turn.
    init(store: UsageStore, prefs: Preferences, actions: NotchActions, notifier: Notifier, requests: SettingsRequests,
         pane: SettingsPane = .general) {
        self.prefs = prefs
        let panel = SettingsPanel(contentRect: NSRect(origin: .zero, size: Self.contentSize),
                                  styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        // A hosting view that takes first mouse (FirstMouseHostingView), so a click on a control lands on it when
        // the non-activating panel is not key, rather than being spent on making it key. The window keeps sizing
        // the view: a grouped Form has no height of its own to offer, and the panel's frame is set below.
        let host = FirstMouseHostingView(rootView: SettingsView(store: store, prefs: prefs, actions: actions, notifier: notifier, requests: requests,
                                                                hostWindow: { [weak panel] in panel }, pane: pane))
        host.sizingOptions = []
        panel.title = L("%@ Settings", AppInfo.name)
        panel.contentView = host
        panel.setContentSize(Self.contentSize)
        panel.minSize = Self.minSize
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.wearCloseOnly()
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
    /// `aside` is whether an update session or an alert is already up: a window first made during one never heard
    /// its standAside(true), and would otherwise rise over the window it should give way to.
    func present(on screen: NSScreen, below readouts: CGRect? = nil, above panelLevel: NSWindow.Level? = nil, aside: Bool? = nil) {
        guard let window else { return }
        window.appearance = prefs.appearance.nsAppearance
        if let aside { self.aside = aside }
        if let panelLevel {
            self.panelLevel = panelLevel
        }
        window.level = self.aside ? .normal : (self.panelLevel.map(Self.level(above:)) ?? .floating)
        window.setFrame(Self.frame(for: window.frame.size, screen: screen.frame, safeAreaTop: screen.safeAreaInsets.top,
                                   visible: screen.visibleFrame, readouts: readouts), display: false)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    /// Steps back to the ordinary window level while Sparkle has a window up, and returns to its own afterwards.
    /// This window is raised above the panel (see `present`), which puts it over the update alert and the
    /// "you're up to date" alert too — they are ordinary windows, and nothing in them can raise itself past it.
    func standAside(_ aside: Bool) {
        self.aside = aside
        guard let window else { return }
        window.level = aside ? .normal : (panelLevel.map(Self.level(above:)) ?? .floating)
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
