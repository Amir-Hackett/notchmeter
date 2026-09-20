import Foundation

/// The block a Settings row sits in: one of the fourteen `Section`s `SettingsView.paneContent` composes, plus the
/// Diagnostics disclosure inside Advanced. The search field dims every section a query does not touch, and a hit
/// inside the disclosure opens it.
enum SettingsSection: CaseIterable {
    case general, updates, about, panel, usage, shortcuts, assistants, sessions, transcripts, notifications, hooks, otherTools,
         privacy, advanced, diagnostics

    var pane: SettingsPane {
        switch self {
        case .general, .updates, .about: .general
        case .panel, .usage, .shortcuts: .appearance
        case .assistants, .sessions, .transcripts: .assistants
        case .notifications: .notifications
        case .hooks, .otherTools: .integrations
        case .privacy, .advanced, .diagnostics: .advanced
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

    /// Every searchable row, in the window's own order. Each pane's title is an entry of its first section, so
    /// typing "Notifications" finds the pane and not only the toggle that repeats its name.
    static func entries() -> [Entry] {
        var rows: [Entry] = []
        func add(_ section: SettingsSection, _ titles: String...) {
            rows += titles.map { Entry(section: section, title: $0) }
        }
        add(.general, L("General"), L("Show total spend"), L("Open at login"), L("Language"), L("Relaunch"),
            L("Show menu bar icon"), L("Pin figures beside the icon"), L("Icon style"), L("Icon colour"), L("Install command line tool…"))
        add(.updates, L("Updates"), L("Check for updates automatically"), L("Download updates automatically"), L("Beta updates"),
            L("Check for Updates…"))
        add(.about, L("Version %@", AppInfo.version), L("Support %@…", AppInfo.name))
        add(.panel, L("Appearance"), L("Panel"), L("Readouts"), L("When crowded"), L("Show details"), L("Position"), L("Display"),
            L("Show"), L("Hover delay"), L("Show reset countdown beside the figures"), L("Show the main figure beside the rings"),
            L("Density"), L("Panel width"), L("Show over full-screen apps"), L("Gestures: swipe down to open, swipe up to close"),
            L("Reduce animations"))
        add(.usage, L("Usage display"), L("Show usage as"), L("Reset times"), L("Time format"), L("Show costs in"), L("Monthly budget"),
            L("Weekly budget"), L("Cost card shows"), L("In the Cost card"))
        add(.shortcuts, L("Keyboard shortcuts"), L("Toggle the panel"), L("Open Settings"), L("Show over the full-screen app"))
        add(.assistants, L("Assistants"), L("Pin to menu bar"), L("Peak hours"), L("Keep the Mac awake while an assistant is working"),
            L("Also on battery"), L("Also read Codex reset credits"), L("Also read Cursor's usage events"), L("Also read organisation billing"),
            L("Hide assistants with nothing to show"), L("Refresh now"))
        add(.sessions, L("Sessions"), L("Show a Sessions card on the panel"), L("Show what a session is working on"),
            L("Answer from the notch"), L("Hand a request back to the terminal after"), L("Jump to the terminal on click"),
            L("Automation"), L("Open Automation settings…"), L("Check again"))
        add(.transcripts, L("Also read transcripts from"), L("Add folder…"))
        add(.notifications, L("Notifications"), L("Notify when a window is on pace to run out"), L("Cutting it close (on track)"),
            L("Will run out (behind pace)"), L("Almost out (under an hour left), and out"), L("When a window resets"),
            L("Remind me before a reset"), L("When you start paying (extra usage rises)"), L("When the cache tier or the metering shifts"),
            L("Notify when an assistant waits for you"), L("Notify when a turn finishes"), L("Only turns longer than"),
            L("Stay quiet while a terminal or editor is in front"), L("Colour the rings when an assistant waits or finishes"),
            L("When an assistant waits for you, or a turn finishes"), L("Sound"), L("Pace crossing"), L("Waiting for you"),
            L("Turn finished"), L("Quiet hours"), L("Test notification"))
        add(.hooks, L("Integrations"), L("Hooks"), L("Repair a hook that points at an old copy at launch"), L("Claude Code status line"),
            L("Install status line…"))
        add(.otherTools, L("Other tools"), L("MCP server"), L("Remote Claude Code over SSH"))
        add(.privacy, L("Advanced"), L("Privacy"), L("Hide usage while the screen is shared or recorded"), L("Ask for Keychain access"),
            L("Local API on 127.0.0.1:%ld", Int(LocalAPI.port)))
        add(.advanced, L("Peak hours (Anthropic's tighter session limits)"), L("Export history…"), L("Reset All Settings…"))
        add(.diagnostics, L("Diagnostics"), L("Route requests through"), L("Debug logging"), L("Copy diagnostics"), L("Rate per dollar"))
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
