import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Notchmeter

/// 0.9.0 split the one Antigravity row into Gemini CLI's and Antigravity's and added Kimi Code and OpenCode. A
/// preference an earlier build wrote is brought forward once (ToolMigration): the Gemini CLI row inherits the
/// combined row's settings, a new tool starts switched on, and nothing is migrated twice.
@Suite struct ToolMigrationRules {
    func withSuite(_ name: String, _ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "NotchmeterTests.ToolMigration.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    /// Everything a user of 0.8 could have set about the Antigravity row, which was Gemini CLI's too.
    func legacy(_ defaults: UserDefaults, antigravityOn: Bool = true) {
        defaults.set(antigravityOn ? ["antigravity", "claude"] : ["claude"], forKey: "enabledTools")
        defaults.set(["claude", "antigravity", "codex", "cursor", "copilot"], forKey: "toolOrder")
        defaults.set(["antigravity"], forKey: "menuBarPinnedTools")
        defaults.set(["claude", "antigravity"], forKey: "peakHoursTools")
        defaults.set(["antigravity"], forKey: "settingsExpandedTools")
        defaults.set(["antigravity": ["gemini_flash", "gemini_pro"], "claude": ["five_hour"]], forKey: "ringWindows")
        defaults.set(["antigravity": ["model_claude-opus-4-1"]], forKey: "hiddenWindows")
        defaults.set(["antigravity": ["gemini_flash_lite"]], forKey: "revealedWindows")
    }

    @Test func theGeminiRowInheritsTheCombinedRowAndKimiStartsOn() {
        withSuite("inherit") { defaults in
            legacy(defaults)
            let outcome = ToolMigration.migrate(defaults)
            #expect(outcome.added == [.gemini, .kimi, .opencode])
            #expect(outcome.inherited == [.gemini: .antigravity])
            let enabled = Set(defaults.stringArray(forKey: "enabledTools") ?? [])
            #expect(enabled == ["antigravity", "claude", "gemini", "kimi", "opencode"], "on because the combined row was, and a new tool starts on")
            #expect(defaults.stringArray(forKey: "toolOrder") == ["claude", "gemini", "antigravity", "codex", "cursor", "copilot"],
                    "just before Antigravity, where a new install has it")
            #expect(defaults.stringArray(forKey: "menuBarPinnedTools") == ["antigravity", "gemini"])
            #expect(defaults.stringArray(forKey: "peakHoursTools") == ["claude", "antigravity", "gemini"])
            #expect(defaults.stringArray(forKey: "settingsExpandedTools") == ["antigravity", "gemini"])
            let rings = defaults.dictionary(forKey: "ringWindows") as? [String: [String]]
            #expect(rings?["gemini"] == ["gemini_flash", "gemini_pro"])
            #expect(rings?["antigravity"] == ["gemini_flash", "gemini_pro"], "Antigravity keeps its own")
            #expect((defaults.dictionary(forKey: "hiddenWindows") as? [String: [String]])?["gemini"] == ["model_claude-opus-4-1"])
            #expect((defaults.dictionary(forKey: "revealedWindows") as? [String: [String]])?["gemini"] == ["gemini_flash_lite"])
            #expect(defaults.stringArray(forKey: ToolMigration.knownToolsKey) == ToolID.allCases.map(\.rawValue))
        }
    }

    /// The same setup read through Preferences, which is what the app does at launch.
    @Test @MainActor func preferencesReadTheMigratedSetup() {
        withSuite("prefs") { defaults in
            legacy(defaults)
            let prefs = Preferences(defaults: defaults)
            #expect(prefs.enabledTools == [.claude, .gemini, .antigravity, .kimi, .opencode])
            let order: [ToolID] = [.claude, .gemini, .antigravity, .codex, .cursor, .copilot, .kimi, .opencode]
            #expect(prefs.toolOrder == order)
            #expect(prefs.menuBarPinnedTools == [.gemini, .antigravity])
            #expect(prefs.peakHoursTools == [.claude, .gemini, .antigravity])
            #expect(prefs.ringWindows[.gemini] == ["gemini_flash", "gemini_pro"])
            #expect(prefs.hiddenWindows[.gemini] == ["model_claude-opus-4-1"])
            #expect(prefs.revealedWindows[.gemini] == ["gemini_flash_lite"])
        }
    }

    @Test func aRowThatWasOffStaysOffAndANewToolStillStartsOn() {
        withSuite("off") { defaults in
            legacy(defaults, antigravityOn: false)
            ToolMigration.migrate(defaults)
            #expect(Set(defaults.stringArray(forKey: "enabledTools") ?? []) == ["claude", "kimi", "opencode"])
        }
    }

    /// Once is once: a user who switches the new row off after the migration finds it off at the next launch.
    @Test @MainActor func aLaterChoiceIsNeverUndone() {
        withSuite("once") { defaults in
            legacy(defaults)
            let prefs = Preferences(defaults: defaults)
            prefs.enabledTools.remove(.gemini)
            prefs.enabledTools.remove(.kimi)
            prefs.menuBarPinnedTools.remove(.gemini)
            let second = ToolMigration.migrate(defaults)
            #expect(second.added.isEmpty)
            let reloaded = Preferences(defaults: defaults)
            #expect(!reloaded.enabledTools.contains(.gemini))
            #expect(!reloaded.enabledTools.contains(.kimi))
            #expect(!reloaded.menuBarPinnedTools.contains(.gemini))
        }
    }

    /// A first launch has nothing to bring forward: it records the tools and changes nothing, and the defaults
    /// already cover every tool.
    @Test func aFirstLaunchOnlyRecords() {
        withSuite("fresh") { defaults in
            let outcome = ToolMigration.migrate(defaults)
            #expect(outcome == ToolMigration.Outcome())
            #expect(defaults.stringArray(forKey: ToolMigration.knownToolsKey) == ToolID.allCases.map(\.rawValue))
            #expect(defaults.object(forKey: "enabledTools") == nil)
            #expect(defaults.object(forKey: "toolOrder") == nil)
        }
    }

    /// A tool added after this one, in a later version, is met the same way without an entry of its own here: it
    /// starts on for a user with a stored set, and takes nobody's settings.
    @Test func aToolFromALaterVersionStartsOnWithoutInheriting() {
        withSuite("later") { defaults in
            defaults.set(["claude", "codex", "cursor", "gemini", "antigravity", "copilot"], forKey: ToolMigration.knownToolsKey)
            defaults.set(["claude"], forKey: "enabledTools")
            defaults.set(["kimi-was-not-known"], forKey: "menuBarPinnedTools")
            let outcome = ToolMigration.migrate(defaults)
            #expect(outcome.added == [.kimi, .opencode])
            #expect(outcome.inherited.isEmpty)
            #expect(defaults.stringArray(forKey: "enabledTools") == ["claude", "kimi", "opencode"])
            #expect(defaults.stringArray(forKey: "menuBarPinnedTools") == ["kimi-was-not-known"], "nothing else is touched")
        }
    }

    @Test func insertingPlacesTheToolOnce() {
        #expect(ToolMigration.inserting("gemini", before: "antigravity", in: ["claude", "antigravity"]) == ["claude", "gemini", "antigravity"])
        #expect(ToolMigration.inserting("gemini", before: "antigravity", in: ["claude"]) == ["claude", "gemini"])
        #expect(ToolMigration.inserting("gemini", before: "antigravity", in: ["gemini", "antigravity"]) == ["gemini", "antigravity"])
    }

    /// Antigravity's user base is personal Google AI Pro accounts, the plan `DemoFixtures.assistantReadings` uses,
    /// and Google stopped serving Gemini CLI quota to those in June 2026. A Mac with both, updated from 0.8: the
    /// Gemini CLI row inherits "on" from the combined row, Google says no under Gemini CLI's identity, and the row
    /// is calm rather than broken: idle with the sentence as its note, no problem line, hidden by *Hide assistants
    /// with nothing to show* and named by *Add a tool*, its next poll an hour off rather than five minutes, while
    /// the Antigravity row reads as it did.
    @Test @MainActor func aPersonalAccountsGeminiRowIsCalmAfterTheSplit() async {
        let suite = "NotchmeterTests.ToolMigration.personal"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        legacy(defaults)
        let prefs = Preferences(defaults: defaults)
        #expect(prefs.enabledTools.contains(.gemini), "inherited from the combined row, which was on")
        #expect(prefs.hideEmptyTools, "on by default")
        let now = Date()
        guard let antigravity = DemoFixtures.assistantReadings(now: now).first(where: { $0.tool == .antigravity }) else {
            Issue.record("the review fixture has no Antigravity reading")
            return
        }
        let store = UsageStore(prefs: prefs, providers: [NotServedProvider(), FixtureProvider(reading: antigravity)],
                               cache: ReadingCache(defaults: defaults), defaults: defaults, drainLog: nil, reportFile: nil)
        await store.refresh(.gemini, force: true)
        await store.refresh(.antigravity, force: true)
        let status = store.status(.gemini)
        #expect(status == .idle(CodeAssistProvider.shutdownMessage))
        #expect(status.problem == nil, "nothing on the card's problem line or in the footer")
        #expect(status.hasNothingYet)
        #expect(Oracle.kind(status) == "idle")
        #expect(store.isEmpty(.gemini))
        #expect(store.visibleTools == [.antigravity], "the Antigravity row alone is on the panel")
        #expect(store.hiddenEmptyTools == [.gemini], "and Add a tool names the Gemini row")
        #expect(store.backoffAfterLastRead(.gemini) == UsageStore.notServedBackoff, "asked again in an hour, not five minutes")
        #expect(store.status(.antigravity).reading?.tool == .antigravity)
        #expect(store.status(.antigravity).problem == nil)
        #expect(store.backoffAfterLastRead(.antigravity) == 0)
    }
}

/// Gemini CLI's row on a personal account: Google answers, under Gemini CLI's identity, that it does not serve it.
private struct NotServedProvider: UsageProvider {
    var tool: ToolID { .gemini }
    var refreshInterval: TimeInterval { 300 }
    func isInstalled() -> Bool { true }
    func fetch() async throws -> UsageReading { throw ProviderError.notServed(CodeAssistProvider.shutdownMessage) }
}

/// The two Google rows read and guard their own figures.
@Suite struct GoogleRowsApart {
    init() { Localization.use(language: "en") }

    let now = DateParsing.iso8601("2026-09-24T12:00:00Z")!

    @Test func eachRowTagsItsOwnReading() throws {
        let buckets = Data(#"{"buckets":[{"modelId":"gemini-2.5-pro","remainingFraction":0.5,"resetTime":"2026-09-25T00:00:00Z"}]}"#.utf8)
        #expect(try CodeAssistProvider.parseQuota(buckets, plan: nil, tool: .gemini, now: now).tool == .gemini)
        #expect(try CodeAssistProvider.parseQuota(buckets, plan: nil, tool: .antigravity, now: now).tool == .antigravity)
        let summary = Data(#"{"groups":[{"displayName":"Gemini Models","buckets":[{"window":"5h","remainingFraction":0.8,"resetTime":"2026-09-24T15:00:00Z"}]}]}"#.utf8)
        #expect(try CodeAssistProvider.parseQuotaSummary(summary, plan: nil, tool: .gemini, now: now).tool == .gemini)
        #expect(throws: ProviderError.parse("Google's quota response unreadable")) { try CodeAssistProvider.parseQuota(Data("x".utf8), plan: nil, tool: .gemini, now: now) }
        #expect(throws: ProviderError.parse("Google reported no quota buckets")) { try CodeAssistProvider.parseQuota(Data(#"{"buckets":[]}"#.utf8), plan: nil, tool: .gemini, now: now) }
    }

    /// The staleness guard and the period inference reach the rows that need them and no other: both Google rows
    /// for the guard (the two-host fault is theirs), those and Kimi's for the inference (windows that may arrive
    /// without a length).
    @Test func theGuardsReachTheirRowsAndNoOthers() {
        #expect(CodeAssistStaleness.tools == [.gemini, .antigravity])
        #expect(InferredPeriods.tools == [.gemini, .antigravity, .kimi])
        func reading(_ tool: ToolID) -> UsageReading {
            UsageReading(tool: tool, windows: [LimitWindow(id: "w", label: "W", usedFraction: 0, resetsAt: now.addingTimeInterval(3 * 3600))],
                         plan: nil, fetchedAt: now, observedAt: nil)
        }
        for tool in ToolID.allCases {
            let runs = CodeAssistStaleness.runs(after: reading(tool), previous: [:], now: now)
            #expect(runs.isEmpty == !CodeAssistStaleness.tools.contains(tool), "\(tool)")
            let inferred = InferredPeriods.apply(reading(tool), resets: [:], now: now)
            #expect((inferred.windows[0].note != nil) == InferredPeriods.tools.contains(tool), "\(tool)")
        }
        let run = ["w": CodeAssistStaleness.Run(count: 3, since: now)]
        let gemini = CodeAssistStaleness.unverified(reading(.gemini), runs: run, activeSince: now.addingTimeInterval(60))
        #expect(gemini.windows[0].usedFraction == nil, "Gemini CLI's own turn after the run began makes its pinned figure unverified")
        #expect(gemini.windows[0].source == .localEstimate)
    }

    /// Gemini CLI's files set Gemini CLI's cadence and Antigravity's set Antigravity's; the login file is Gemini
    /// CLI's alone.
    @Test func activityIsReadPerRow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-gemini-activity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tmp/abc"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("antigravity-cli/conversations/c1"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("oauth_creds.json"))
        let geminiAt = Date(timeIntervalSince1970: 1_790_000_000)
        let antigravityAt = Date(timeIntervalSince1970: 1_790_003_600)
        try FileManager.default.setAttributes([.modificationDate: geminiAt], ofItemAtPath: root.appendingPathComponent("tmp/abc").path)
        try FileManager.default.setAttributes([.modificationDate: geminiAt.addingTimeInterval(-60)], ofItemAtPath: root.appendingPathComponent("oauth_creds.json").path)
        try FileManager.default.setAttributes([.modificationDate: antigravityAt], ofItemAtPath: root.appendingPathComponent("antigravity-cli/conversations/c1").path)
        #expect(AgentActivity.newestGemini(root: root) == geminiAt)
        #expect(AgentActivity.newestAntigravity(root: root) == antigravityAt)
    }
}

/// What the rest of the app knows about the new rows: names, marks, colours, links, search.
@MainActor
@Suite struct NewRowsPresentation {
    init() { Localization.use(language: "en") }

    @Test func namesAndMarks() {
        #expect(ToolID.gemini.displayName == "Gemini")
        #expect(ToolID.gemini.productName == "Gemini CLI")
        #expect(ToolID.kimi.displayName == "Kimi")
        #expect(ToolID.kimi.productName == "Kimi Code")
        #expect(ToolID.antigravity.productName == "Antigravity")
        for tool in ToolID.allCases {
            #expect(NSImage(systemSymbolName: tool.symbolName, accessibilityDescription: nil) != nil, "\(tool) asks for \(tool.symbolName)")
        }
        #expect(Set(ToolID.allCases.map(\.symbolName)).count == ToolID.allCases.count, "no two assistants share a mark")
        #expect(ProviderLinks.usage(.gemini).host == "geminicli.com")
        #expect(ProviderLinks.usage(.kimi).absoluteString == "https://www.kimi.com/code/console")
        #expect(ProviderLinks.status(.kimi) == nil)
    }

    /// The identity colours stay apart and legible on both surfaces they are drawn on. Under the dark scheme,
    /// which the notch, the panel and the edge card force, the dark value: 4.5:1 at least against black, so a
    /// figure drawn in one reads as text (every one clears 6.5:1, and the two added in 0.9.0 clear 7:1). Under
    /// the light scheme, which only a floating edge pill takes, the light value: 4.5:1 at least against white,
    /// where the dark leaf green sat at 1.6:1 and the orchid at 2.6:1 before the pair. And the chart pair 3:1
    /// against the light and dark windows the Dashboard draws on.
    @Test func coloursAreDistinctAndLegible() throws {
        let black = NSColor.black
        let white = NSColor.white
        let darkWindow = NSColor(srgbRed: 0x1E / 255, green: 0x1E / 255, blue: 0x1E / 255, alpha: 1)
        let aqua = try #require(NSAppearance(named: .aqua))
        let darkAqua = try #require(NSAppearance(named: .darkAqua))
        func resolved(_ colour: Color, under appearance: NSAppearance) throws -> NSColor {
            var out: NSColor?
            appearance.performAsCurrentDrawingAppearance { out = NSColor(colour).usingColorSpace(.sRGB) }
            return try #require(out)
        }
        func hex(_ colour: NSColor) -> String {
            String(format: "%02X%02X%02X", Int((colour.redComponent * 255).rounded()), Int((colour.greenComponent * 255).rounded()), Int((colour.blueComponent * 255).rounded()))
        }
        var onDark: [String] = []
        var onLight: [String] = []
        for tool in ToolID.allCases {
            let dark = try resolved(tool.color, under: darkAqua)
            let light = try resolved(tool.color, under: aqua)
            onDark.append(hex(dark))
            onLight.append(hex(light))
            #expect(hex(dark) == String(format: "%06X", tool.identity.dark), "\(tool) under Dark is its dark value")
            #expect(hex(light) == String(format: "%06X", tool.identity.light), "\(tool) under Light is its light value")
            #expect(SettingsSidebarTiles.contrast(dark, black) >= 4.5, "\(tool) on the notch")
            if tool == .gemini || tool == .kimi { #expect(SettingsSidebarTiles.contrast(dark, black) >= 7, "\(tool) on the notch") }
            #expect(SettingsSidebarTiles.contrast(light, white) >= 4.5, "\(tool) readout on a light pill")
            let chartLight = try resolved(tool.chartColor, under: aqua)
            let chartDark = try resolved(tool.chartColor, under: darkAqua)
            #expect(hex(chartLight) == hex(light), "\(tool): the chart's light value is the identity's")
            #expect(SettingsSidebarTiles.contrast(chartLight, white) >= 3, "\(tool) chart on the light window")
            #expect(SettingsSidebarTiles.contrast(chartDark, darkWindow) >= 3, "\(tool) chart on the dark window")
        }
        #expect(Set(onDark).count == ToolID.allCases.count, "no two assistants share a colour on the notch")
        #expect(Set(onLight).count == ToolID.allCases.count, "nor on a light pill")
    }

    /// Since the per-assistant pages, a product's name finds its own page (its overview block first) and its hook
    /// row on that page; Antigravity's page has a switch and no hook block.
    @Test func searchFindsTheNewRowsByName() throws {
        let entries = SettingsSearch.entries()
        let kimi = SettingsSearch.sections(matching: "Kimi", in: entries)
        #expect(kimi.contains(.agent(.kimi, .overview)))
        #expect(kimi.contains(.agent(.kimi, .hook)))
        let gemini = SettingsSearch.sections(matching: "Gemini", in: entries)
        #expect(gemini.contains(.agent(.gemini, .overview)) && gemini.contains(.agent(.gemini, .hook)))
        let antigravity = SettingsSearch.sections(matching: "Antigravity", in: entries)
        #expect(antigravity.contains(.agent(.antigravity, .overview)))
        #expect(!antigravity.contains(.agent(.antigravity, .hook)), "Antigravity has a switch and no hook row")
        #expect(try #require(SettingsSearch.hit(for: "Kimi Code", current: .general, in: entries)).pane == .agent(.kimi))
        #expect(try #require(SettingsSearch.hit(for: "Gemini CLI hook", current: .general, in: entries)).pane == .agent(.gemini))
    }

    /// The review render of the new rows: the three rows alone, Gemini CLI's session held on its permission and
    /// Kimi's working, each from its own hook's messages.
    @Test func theReviewFixtureShowsTheNewRows() {
        let now = Date()
        let (store, _) = DemoFixtures.assistantsStore(now: now)
        defer { UserDefaults.standard.removePersistentDomain(forName: DemoFixtures.assistantsSuiteName) }
        let shown: [ToolID] = [.gemini, .antigravity, .kimi]
        #expect(store.visibleTools == shown)
        #expect(store.awaitingInput == [.gemini])
        #expect(store.sessions.isWorking(.kimi))
        #expect(store.status(.gemini).reading?.windows.first?.note?.contains("likely a 1-day window") == true, "the first read can only say what the reset suggests")
        #expect(store.status(.kimi).reading?.windows.map(\.id) == ["session", "weekly", "monthly_total"])
    }
}
