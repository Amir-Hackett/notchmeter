import Foundation

/// One block of an assistant's own page (SettingsPane.agent), in the order the page draws them: what it is and
/// whether it is on, its rings and windows, its hook, its sessions, its notices, and where its figures come from.
/// The last is two blocks of one `Section`: the rows *Where each window comes from* folds away (`sourcesDetail`)
/// apart from the switches under it (`sources`), because a search that lands inside the disclosure has to open
/// it and one that lands on the Keychain picker under it must not.
enum AgentBlock: CaseIterable, Hashable {
    case overview, windows, hook, sessions, notifications, sources, sourcesDetail
}

/// The block a Settings row sits in: one of the `Section`s `SettingsView.paneContent` composes, the Diagnostics
/// disclosure inside Advanced, and each block of each assistant's page. The search field dims every section a
/// query does not touch, and a hit inside a disclosure opens it.
enum SettingsSection: Hashable, CaseIterable {
    case general, updates, about, theme, panel, usage, shortcuts, assistants, sessions, notifications, sounds, hooks, otherTools,
         privacy, advanced, diagnostics
    case agent(ToolID, AgentBlock)

    /// The app's own blocks, in the window's order.
    static let app: [SettingsSection] = [.general, .updates, .about, .theme, .panel, .usage, .shortcuts, .assistants, .sessions, .notifications,
                                         .sounds, .hooks, .otherTools, .privacy, .advanced, .diagnostics]

    /// Every block, every assistant's page included; written out because a case with a payload gets no
    /// synthesised list.
    static var allCases: [SettingsSection] {
        app + ToolID.allCases.flatMap { tool in AgentBlock.allCases.map { SettingsSection.agent(tool, $0) } }
    }

    var pane: SettingsPane {
        switch self {
        case .general, .updates, .about: .general
        case .theme, .panel, .usage, .shortcuts: .appearance
        case .assistants, .sessions: .assistants
        case .notifications, .sounds: .notifications
        case .hooks, .otherTools: .integrations
        case .privacy, .advanced, .diagnostics: .advanced
        case .agent(let tool, _): .agent(tool)
        }
    }
}

/// What the search field in the Settings header looks through: a static index of the rows, each with the section
/// and pane it lives on and its own title.
///
/// The titles are the same literals the rows hand to `L`, written out a second time here rather than read off the
/// rows: the sections are opaque views with no per-row identity to search, and a quoted literal at the call site
/// is the only thing the localisation scanner sees (LocalizationTests), so the index can neither name a key the
/// tables lack nor keep one alive that no row uses. Help text is not indexed: it is a paragraph per row, and a
/// query that matched a paragraph would light half the window.
///
/// The cost of the second copy is that it can drift from the rows. `SettingsSearchIndex` (the test) walks the
/// index against the rows' own literals in SettingsWindow.swift, so a title renamed on one side and not the other
/// fails a test rather than a search.
enum SettingsSearch {
    struct Entry: Equatable {
        let section: SettingsSection
        let title: String
    }

    /// Where a query lands: the pane to show and the sections that hold a match.
    struct Hit: Equatable {
        let pane: SettingsPane
        let sections: Set<SettingsSection>
    }

    /// Every searchable row, in the window's own order: the assistants' pages sit under Assistants in the order
    /// the sidebar lists them (`order`, the user's), so a row every page has — *Pin to menu bar* — lands on the
    /// first assistant the reader sees there. Each pane's title is an entry of its first section, so typing
    /// "Notifications" finds the pane and not only the toggle that repeats its name; an assistant's product name
    /// is the first entry of its page, and nothing on a page repeats a pane's title, so typing a pane's name never
    /// lands on an assistant instead.
    static func entries(order: [ToolID] = ToolID.allCases) -> [Entry] {
        var rows: [Entry] = []
        func add(_ section: SettingsSection, _ titles: String...) {
            rows += titles.map { Entry(section: section, title: $0) }
        }
        add(.general, L("General"), L("Show total spend"), L("Open at login"), L("Language"), L("Relaunch"),
            L("Show menu bar icon"), L("Pin figures beside the icon"), L("Icon style"), L("Icon colour"), L("Install command line tool…"),
            L("Show the welcome tour again"), L("Offer the usage card after an update"))
        add(.updates, L("Updates"), L("Check for updates automatically"), L("Download updates automatically"), L("Beta updates"),
            L("Check for Updates…"))
        add(.about, L("Version %@", AppInfo.version), L("Send Feedback…"), L("Support %@…", AppInfo.name))
        add(.theme, L("Theme"), L("Surface"), L("Material"), L("Accent"), L("Usage style"), L("Draw hour limits on a clock"))
        add(.panel, L("Appearance"), L("Panel"), L("Readouts"), L("When crowded"), L("Show details"), L("Position"), L("Display"),
            L("Show"), L("Hover delay"), L("Show reset countdown beside the figures"), L("Show the main figure beside the rings"),
            L("Show assistant symbols in the rings"), L("While an assistant works"), L("When nothing is running"), L("Show on these displays"),
            L("Panel layout"), L("Density"), L("Panel width"), L("Show over full-screen apps"), L("Gestures: swipe down to open, swipe up to close"),
            L("Reduce animations"))
        add(.usage, L("Usage display"), L("Show usage as"), L("Reset times"), L("Time format"), L("Show costs in"), L("Monthly budget"),
            L("Weekly budget"), L("Cost card shows"), L("Update model prices from notchmeter's catalog"))
        add(.shortcuts, L("Keyboard shortcuts"), L("Toggle the panel"), L("Open Settings"), L("Show over the full-screen app"))
        add(.assistants, L("Assistants"), L("Hide assistants with nothing to show"), L("Refresh now"))
        add(.sessions, L("Sessions"), L("Show a Sessions card on the panel"), L("Sessions shown at once"), L("A row leads with"), L("Find sessions without the hook"), L("Show Claude Cowork tasks"), L("Show what a session is working on"),
            L("Answer from the notch"), L("Hand a request back to the terminal after"), L("Jump to the terminal on click"),
            L("Automation"), L("Open Automation settings…"), L("Check again"), L("Keep the Mac awake while an assistant is working"),
            L("Also on battery"))
        for tool in order { rows += agentEntries(tool) }
        add(.notifications, L("Notifications"), L("Notify when a window is on pace to run out"), L("Cutting it close (on track)"),
            L("Will run out (behind pace)"), L("Almost out (under an hour left), and out"), L("When a window resets"),
            L("Remind me before a reset"), L("When you start paying (extra usage rises)"), L("When the cache tier or the metering shifts"),
            L("Notify when an assistant waits for you"), L("Notify when a turn finishes"), L("Only turns longer than"),
            L("Notify when a session compacts, may be stuck or is refused"),
            L("Stay quiet while a terminal or editor is in front"), L("Colour the rings when an assistant waits or finishes"),
            L("Show news in the notch"), L("Glow under the notch for news"), L("When an assistant waits for you, or a turn finishes"),
            L("Quiet hours"), L("Test notification"))
        add(.sounds, L("Sounds"), L("Play sounds"), L("Turn finished"), L("Waiting reminder"), L("Permission request"), L("Question"),
            L("Plan ready to approve"), L("Limit alert"), L("Silence"))
        add(.hooks, L("Integrations"), L("Hooks"), L("Repair an out-of-date hook at launch"))
        add(.otherTools, L("Other tools"), L("MCP server"), L("Remote Claude Code over SSH"))
        add(.privacy, L("Advanced"), L("Privacy"), L("Hide usage while the screen is shared or recorded"),
            L("Local API on 127.0.0.1:%ld", Int(LocalAPI.port)))
        add(.advanced, L("Peak hours (Anthropic's tighter session limits)"), L("Export history…"), L("Reset All Settings…"))
        add(.diagnostics, L("Diagnostics"), L("Route requests through"), L("Debug logging"), L("Copy diagnostics"), L("Send Feedback…"), L("Rate per dollar"),
            L("Last crash report"), L("Copy crash report"))
        return rows
    }

    /// One assistant's page, block by block, holding only the rows that page draws: the answer switch where the
    /// assistant's hook has an event to answer, the Cost card switch where it can report spend, and each second
    /// read on the one assistant it belongs to. The product name is not a key: it is a name in every language.
    static func agentEntries(_ tool: ToolID) -> [Entry] {
        var rows: [Entry] = []
        func add(_ block: AgentBlock, _ titles: String...) {
            rows += titles.map { Entry(section: .agent(tool, block), title: $0) }
        }
        add(.overview, tool.productName, L("Show %@ on the panel and the rings", tool.displayName))
        add(.windows, L("Rings and windows"), L("Outer ring"), L("Inner ring"), L("Third ring"), L("Hide"), L("Pin to menu bar"), L("Peak hours"))
        if tool.reportsCost { add(.windows, L("In the Cost card")) }
        if let vendor = HookVendor.vendor(for: tool) {
            add(.hook, vendor.shape == .pluginModule ? L("OpenCode plugin") : L("%@ hook", vendor.displayName))
        }
        if tool == .claude { add(.hook, L("Claude Code status line"), L("Install status line…")) }
        add(.sessions, L("Read its sessions"))
        if tool.hasAnswerableHook { add(.sessions, L("Answer from the notch")) }
        add(.notifications, L("Notify about its limits"), L("Notify when it waits or finishes a turn"))
        add(.sources, L("Sources"))
        add(.sourcesDetail, L("Where each window comes from"), L("Login"), L("Readings"))
        switch tool {
        case .claude:
            add(.sources, L("Also poll Claude's usage endpoint"), L("Ask for Keychain access"), L("Also read transcripts from"), L("Add folder…"))
        case .codex: add(.sources, L("Also read Codex reset credits"))
        case .cursor: add(.sources, L("Also read Cursor's usage events"))
        case .copilot: add(.sources, L("Also read organisation billing"))
        case .opencode: add(.sources, L("Show sessions read from OpenCode's database"))
        case .gemini, .antigravity, .kimi: break
        }
        return rows
    }

    /// The query with its edges trimmed; empty means no search is on.
    static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a title answers a query: a substring match that ignores case and diacritics, so "resume" finds a
    /// title with "résumé" in it and "cost" finds "Cost card shows".
    static func matches(_ title: String, _ query: String) -> Bool {
        let needle = normalized(query)
        guard !needle.isEmpty else { return false }
        return title.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Every section with a row that answers the query; empty for an empty query or no match.
    static func sections(matching query: String, in entries: [Entry]? = nil) -> Set<SettingsSection> {
        Set((entries ?? self.entries()).filter { matches($0.title, query) }.map(\.section))
    }

    /// Where the query lands. The pane already on screen wins while it holds a match, so typing does not pull
    /// the window away from a row the reader can already see; otherwise the first matching section's pane, in
    /// the window's order. Nil for an empty query or no match at all.
    static func hit(for query: String, current: SettingsPane, in entries: [Entry]? = nil) -> Hit? {
        let rows = entries ?? self.entries()
        let matched = sections(matching: query, in: rows)
        guard !matched.isEmpty else { return nil }
        if matched.contains(where: { $0.pane == current }) {
            return Hit(pane: current, sections: matched)
        }
        let first = rows.first { matched.contains($0.section) }!
        return Hit(pane: first.section.pane, sections: matched)
    }
}
