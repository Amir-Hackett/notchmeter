import AppKit
import Foundation
import Testing
@testable import Notchmeter

/// The 0.7.0 panel and Settings polish: the main figure beside plain rings, assistants with nothing to show kept
/// off the panel, the Settings search index, and the first-launch Welcome window's chrome.

/// Which figures a style draws once the primary-number setting is in (CompactLabel.figures). Plain rings draw the
/// outer figure alone while it is on and nothing while it is off; the digit styles draw whatever the fit says
/// whatever the setting, because their digits were never the setting's to give.
@Suite struct PrimaryFigureRule {
    @Test func plainRingsCarryTheOuterFigureOnlyWhileTheSettingIsOn() {
        #expect(CompactLabel.figures(style: .rings, primary: true) == .outer)
        #expect(CompactLabel.figures(style: .rings, primary: false) == nil)
        // The fit's own rung is not consulted at plain rings: `.rings` means `figures == .all` to CompactFit, and
        // the outer figure is the most the setting ever adds.
        #expect(CompactLabel.figures(style: .rings, primary: true, fit: .outer) == .outer)
    }

    @Test func theDigitStylesAnswerTheFitWhateverTheSetting() {
        for primary in [true, false] {
            #expect(CompactLabel.figures(style: .ringsAndNumbers, primary: primary, fit: .all) == .all)
            #expect(CompactLabel.figures(style: .ringsAndNumbers, primary: primary, fit: .outer) == .outer)
            #expect(CompactLabel.figures(style: .numbers, primary: primary, fit: .all) == .all)
        }
    }

    /// The outer rung never carries a countdown or a second figure (CompactLabel.segments), so the primary figure
    /// beside plain rings is one percentage and nothing else, in the sense the user chose.
    @Test func thePrimaryFigureIsOnePercentageInTheChosenSense() {
        let now = DateParsing.iso8601("2026-09-01T12:00:00Z")!
        let windows = [
            LimitWindow(id: "session", label: .key("session"), usedFraction: 0.14, resetsAt: now.addingTimeInterval(4 * 3600), periodDuration: Period.fiveHours),
            LimitWindow(id: "weekly", label: .key("weekly"), usedFraction: 0.04, resetsAt: now.addingTimeInterval(4 * 86400), periodDuration: 7 * Period.day),
        ]
        let figures = CompactLabel.figures(style: .rings, primary: true)!
        #expect(CompactLabel.text(for: windows, display: .used, figures: figures, countdown: true, now: now) == "14%")
        #expect(CompactLabel.text(for: windows, display: .left, figures: figures, countdown: true, now: now) == "86%")
    }

    @MainActor @Test func theSettingIsOnByDefaultAndPersists() {
        let suite = "NotchmeterTests.PanelPolish.primary"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        #expect(prefs.compactPrimary)
        #expect(prefs.hideEmptyTools)
        #expect(!prefs.welcomed)
        prefs.compactPrimary = false
        prefs.hideEmptyTools = false
        prefs.welcomed = true
        let again = Preferences(defaults: defaults)
        #expect(!again.compactPrimary)
        #expect(!again.hideEmptyTools)
        #expect(again.welcomed)
    }
}

/// `UsageStore.visibleTools` under `hideEmptyTools`: an assistant that is on and installed but has no reading, no
/// spend and no session is left off the list every surface reads, and named by `hiddenEmptyTools` for the panel's
/// "Add a tool" row. The floor is WindowFloor's: the last one is never hidden.
@MainActor @Suite struct HiddenEmptyTools {
    func withStore(_ name: String, _ body: (UsageStore, Preferences, Date) throws -> Void) rethrows {
        let suite = "NotchmeterTests.PanelPolish.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        let now = Date()
        let readings = [ToolID.claude, .codex, .cursor].map { tool in
            UsageReading(tool: tool, windows: [
                LimitWindow(id: "session", label: "Session", usedFraction: 0.1, resetsAt: now.addingTimeInterval(4 * 3600), periodDuration: Period.fiveHours),
            ], plan: nil, fetchedAt: now, observedAt: nil)
        }
        let store = UsageStore(prefs: prefs, providers: readings.map { FixtureProvider(reading: $0) },
                               cache: ReadingCache(defaults: defaults), defaults: defaults, drainLog: nil, reportFile: nil)
        try body(store, prefs, now)
    }

    @Test func anAssistantWithNothingToShowIsHiddenAndNamed() {
        withStore("hidden") { store, prefs, now in
            let claude = [ToolID.claude]
            let hidden: [ToolID] = [.codex, .cursor]
            store.seed(readings: [], cost: .empty, nextUpdate: now.addingTimeInterval(60),
                       nothingYet: [.codex: "Sign in to Codex", .cursor: "Sign in to Cursor"], now: now)
            // Claude is still waiting on its first read: something is coming, so it is not empty.
            #expect(store.visibleTools == claude)
            #expect(store.hiddenEmptyTools == hidden)
            // The setting off puts every shown tool back, in the user's order.
            prefs.hideEmptyTools = false
            let all: [ToolID] = [.claude, .codex, .cursor]
            #expect(store.visibleTools == all)
            #expect(store.hiddenEmptyTools.isEmpty)
        }
    }

    @Test func aReadingASpendOrASessionKeepsATool() {
        withStore("kept") { store, prefs, now in
            let reading = UsageReading(tool: .codex, windows: [
                LimitWindow(id: "session", label: "Session", usedFraction: 0.2, resetsAt: now.addingTimeInterval(3600), periodDuration: Period.fiveHours),
            ], plan: nil, fetchedAt: now, observedAt: nil)
            store.seed(readings: [reading], cost: .empty, nextUpdate: now.addingTimeInterval(60),
                       nothingYet: [.claude: "Sign in to Claude Code", .cursor: "Sign in to Cursor"], now: now)
            let codexOnly = [ToolID.codex]
            #expect(store.visibleTools == codexOnly)
            // A session its hook reported keeps Claude on the panel with nothing else to show.
            store.hookReceived(Hook.Message(event: "SessionStart", needsInput: false, sessionID: "a"), now: now)
            let claudeAndCodex: [ToolID] = [.claude, .codex]
            #expect(store.visibleTools == claudeAndCodex)
            #expect(store.hiddenEmptyTools == [.cursor])
            // A spend the cost scan found keeps Cursor.
            let spend = DemoFixtures.cost(now: now)
            #expect(spend.provider(.cursor) != nil, "the fixture cost carries a Cursor series, or nothing is being tested")
            store.seed(readings: [reading], cost: spend, nextUpdate: now.addingTimeInterval(60),
                       nothingYet: [.claude: "Sign in to Claude Code", .cursor: "Sign in to Cursor"], now: now)
            #expect(store.visibleTools.contains(.cursor))
        }
    }

    @Test func theLastVisibleToolIsNeverHidden() {
        withStore("floor") { store, prefs, now in
            store.seed(readings: [], cost: .empty, nextUpdate: now.addingTimeInterval(60),
                       nothingYet: [.claude: "Sign in", .codex: "Sign in", .cursor: "Sign in"], now: now)
            let first = [ToolID.claude]
            let rest: [ToolID] = [.codex, .cursor]
            #expect(store.visibleTools == first)
            #expect(store.hiddenEmptyTools == rest)
            // The floor follows the user's order: whichever tool is first is the one kept.
            prefs.move(.cursor, by: -2)
            let cursorFirst = [ToolID.cursor]
            #expect(store.visibleTools == cursorFirst)
        }
    }
}

/// The Settings search index (SettingsSearch): every title in it is a literal the rows also hand to `L`, so the
/// two cannot drift apart unnoticed; a query lands on the pane already on screen when it has a match and on the
/// first matching pane otherwise; a hit inside Diagnostics is reported as one, so the disclosure can open.
@Suite struct SettingsSearchIndex {
    static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Notchmeter")

    /// The literal keys the index names, read back off its own source, and the ones SettingsWindow.swift names.
    static func literals(in file: String) throws -> Set<String> {
        let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"\bL\("((?:[^"\\]|\\.)*)""#)
        var keys: Set<String> = []
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            keys.insert(String(text[Range(match.range(at: 1), in: text)!]))
        }
        return keys
    }

    @Test func everyIndexedTitleIsARowsOwnLiteral() throws {
        let indexed = try Self.literals(in: "SettingsSearch.swift")
        let rows = try Self.literals(in: "SettingsWindow.swift")
        let missing = indexed.subtracting(rows)
        #expect(missing.isEmpty, "indexed but on no row in SettingsWindow.swift: \(missing.sorted())")
        let entries = SettingsSearch.entries()
        let count = entries.count
        #expect(count > 80)
        // Every section a row can sit in has at least the pane it belongs to; no section is orphaned.
        for section in SettingsSection.allCases {
            #expect(entries.contains { $0.section == section }, "\(section) has no entry to be found by")
        }
    }

    @Test func aQueryStaysOnAPaneThatHoldsAMatchAndOtherwiseGoesToTheFirst() throws {
        let entries = SettingsSearch.entries()
        // "Peak hours" is both an assistant switch and the Advanced editor: on Assistants it stays put, and from
        // General it goes to Assistants, the first of the two in the window's order.
        let onAssistants = try #require(SettingsSearch.hit(for: "peak hours", current: .assistants, in: entries))
        #expect(onAssistants.pane == .assistants)
        #expect(onAssistants.sections.contains(.assistants) && onAssistants.sections.contains(.advanced))
        let fromGeneral = try #require(SettingsSearch.hit(for: "peak hours", current: .general, in: entries))
        #expect(fromGeneral.pane == .assistants)
        // Case and diacritics do not matter, and the edges are trimmed.
        let loud = try #require(SettingsSearch.hit(for: "  DÉBUG  ", current: .general, in: entries))
        #expect(loud.pane == .advanced)
        #expect(loud.sections == [.diagnostics])
        // The rate moved under Diagnostics with the release; the search says so.
        let rate = try #require(SettingsSearch.hit(for: "rate per dollar", current: .appearance, in: entries))
        #expect(rate.pane == .advanced)
        #expect(rate.sections == [.diagnostics])
    }

    @Test func anEmptyOrUnansweredQueryLandsNowhere() {
        let entries = SettingsSearch.entries()
        #expect(SettingsSearch.hit(for: "", current: .general, in: entries) == nil)
        #expect(SettingsSearch.hit(for: "   ", current: .general, in: entries) == nil)
        #expect(SettingsSearch.hit(for: "xyzzy-no-such-row", current: .general, in: entries) == nil)
        #expect(SettingsSearch.sections(matching: "xyzzy-no-such-row", in: entries).isEmpty)
        // A pane's own title finds the pane.
        for pane in SettingsPane.allCases where pane != .dashboard {
            let hit = SettingsSearch.hit(for: pane.title, current: .dashboard, in: entries)
            #expect(hit?.pane == pane, "\(pane.title) does not find its own pane")
        }
    }
}

/// The Welcome window is built from `SettingsPanel` like Settings and the dashboard, non-activating, and wears
/// the close button alone (PanelChrome pins the same for the other two).
@Suite struct WelcomeChrome {
    @MainActor @Test func theWelcomeWindowIsANonActivatingSettingsPanelWithCloseAlone() throws {
        let controller = WelcomeWindowController(install: {}, finish: {})
        let window = try #require(controller.window)
        #expect(window is SettingsPanel)
        #expect(window.styleMask.contains(.nonactivatingPanel))
        #expect(!window.styleMask.contains(.resizable), "a fixed four-step window has nothing to resize")
        #expect(window.standardWindowButton(.miniaturizeButton)?.isHidden ?? true)
        #expect(window.standardWindowButton(.zoomButton)?.isHidden ?? true)
        #expect(window.contentView is FirstMouseHostingView<WelcomeView>, "a first click has to land on a button")
        #expect(WelcomeView.steps == 4)
    }
}
