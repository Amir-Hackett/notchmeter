import Foundation
import Testing
@testable import Notchmeter

/// The Cost card over several assistants: which ones it carries and in what order, what each is worth in the
/// range and the mode on show, and the arcs the donut draws from that.
@Suite struct CostCardSelection {
    init() { Localization.use(language: "en") }

    let now = DateParsing.iso8601("2026-09-01T15:00:00Z")!

    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// One day's spend for a tool, priced from whatever source it publishes.
    func provider(_ tool: ToolID, source: CostSource, cost: Double, tokens: Int) -> ProviderCost {
        let day = utc.startOfDay(for: now)
        let days = [day: CostHistory.Record(cost: cost, tokens: TokenBreakdown(input: tokens), byModel: [:], byProject: [:])]
        return ProviderCost.build(tool: tool, source: source, days: days, now: now, weekStart: day, calendar: utc, scannedAt: now)!
    }

    var three: [ProviderCost] {
        [provider(.claude, source: .localTranscripts, cost: 6, tokens: 3_000_000),
         provider(.codex, source: .localSessions, cost: 3, tokens: 500_000),
         provider(.cursor, source: .billingExport, cost: 1, tokens: 250_000)]
    }

    @Test func theCardFollowsTheUsersOrderAndCarriesOnlyWhatItIsAskedFor() {
        let ordered = CostSelection(all: three, order: [.cursor, .antigravity, .claude, .codex], carried: [.claude, .codex, .cursor])
        #expect(ordered.providers.map(\.tool) == [.cursor, .claude, .codex])
        let some = CostSelection(all: three, order: ToolID.allCases, carried: [.claude, .cursor])
        #expect(some.providers.map(\.tool) == [.claude, .cursor])
        // Left out is left out of the total too, so the donut and the figure in the middle describe one set.
        #expect(abs(some.totals(.today).cost - 7) < 1e-9)
        #expect(CostSelection(all: three, order: ToolID.allCases, carried: []).isEmpty)
    }

    /// A tool that cannot report spend has no ProviderCost, so it is absent rather than a zero row.
    @Test func aToolWithNoCostIsNeverASegment() {
        let selection = CostSelection(all: three, order: ToolID.allCases, carried: Set(ToolID.allCases))
        #expect(selection.providers.map(\.tool) == [.claude, .codex, .cursor])
        #expect(selection.provider(.copilot) == nil)
        #expect(selection.provider(.antigravity) == nil)
        // Nor is a carried tool that spent nothing in the range on show.
        #expect(selection.weights(range: .yesterday, mode: .cost).isEmpty)
        #expect(CostDonut.arcs(selection.weights(range: .yesterday, mode: .cost)).isEmpty)
    }

    @Test func eachModeSharesTheRangeOutInItsOwnUnit() {
        let selection = CostSelection(all: three, order: ToolID.allCases, carried: Set(ToolID.allCases))
        #expect(selection.weights(range: .today, mode: .cost).map(\.weight) == [6, 3, 1])
        #expect(selection.weights(range: .today, mode: .tokens).map(\.weight) == [3_000_000, 500_000, 250_000])
        // $/MTok is a rate, not a quantity to share out, so it is sized by its dollars.
        #expect(selection.weights(range: .today, mode: .perMillionTokens).map(\.weight) == [6, 3, 1])
        #expect(abs((selection.share(of: .claude, range: .today, mode: .cost) ?? 0) - 0.6) < 1e-9)
        #expect(abs((selection.share(of: .claude, range: .today, mode: .tokens) ?? 0) - 0.8) < 1e-9)
        #expect(selection.share(of: .copilot, range: .today, mode: .cost) == nil)
        // Per-MTok is each tool's own dollars over its own tokens, never the range's tokens apportioned by cost.
        #expect(selection.provider(.codex)?.totals(.today).costPerMillionTokens.map { abs($0 - 6) < 1e-9 } == true)
        #expect(selection.totals(.today).costPerMillionTokens.map { abs($0 - 10 / 3.75) < 1e-9 } == true)
    }

    @Test func oneProviderDrawsTheRingTheCardHasAlwaysDrawn() {
        let selection = CostSelection(all: three, order: ToolID.allCases, carried: [.claude])
        let arcs = CostDonut.arcs(selection.weights(range: .today, mode: .cost))
        #expect(arcs == [CostArc(tool: .claude, start: 0.012, end: 0.988)])
        let budgeted = CostDonut.arcs(selection.weights(range: .month, mode: .cost), fill: 0.4)
        #expect(budgeted == [CostArc(tool: .claude, start: 0, end: 0.4)])
        // An empty month still shows the sliver the ring has always shown against a budget.
        #expect(CostDonut.arcs(selection.weights(range: .month, mode: .cost), fill: 0).first?.end == CostDonut.gap)
    }

    @Test func everyProviderGetsAnArcOfItsOwnShare() {
        let selection = CostSelection(all: three, order: ToolID.allCases, carried: Set(ToolID.allCases))
        let arcs = CostDonut.arcs(selection.weights(range: .today, mode: .cost))
        #expect(arcs.map(\.tool) == [.claude, .codex, .cursor])
        #expect(arcs.first?.start == CostDonut.gap)
        #expect(arcs.last?.end == 1 - CostDonut.gap)
        // Sized by share, with a hairline between neighbours and none after the last.
        let sweep = 1 - 2 * CostDonut.gap
        #expect(abs(arcs[0].end - (CostDonut.gap + sweep * 0.6 - CostDonut.separation)) < 1e-9)
        #expect(abs(arcs[1].start - (CostDonut.gap + sweep * 0.6)) < 1e-9)
        #expect(abs(arcs[2].start - (CostDonut.gap + sweep * 0.9)) < 1e-9)
        for arc in arcs { #expect(arc.end > arc.start) }
    }

    /// A sliver never turns into a backwards arc: the hairline is capped at a third of the slice.
    @Test func aTinyShareKeepsAForwardArc() {
        let weights = [CostWeight(tool: .claude, weight: 1000), CostWeight(tool: .codex, weight: 0.5), CostWeight(tool: .cursor, weight: 1)]
        let arcs = CostDonut.arcs(weights)
        #expect(arcs.count == 3)
        for arc in arcs { #expect(arc.end > arc.start) }
        #expect(arcs.last?.end == 1 - CostDonut.gap)
    }

    /// The hour and the burn multiple are the carried providers' own: a day-resolution export contributes no
    /// hour at all rather than a zero that would halve the average.
    @Test func theBurnMultipleComesFromTheProvidersThatCanMeasureAnHour() {
        let day = utc.startOfDay(for: now)
        let days = [day: CostHistory.Record(cost: 10, tokens: TokenBreakdown(input: 1000), byModel: [:], byProject: [:])]
        let claude = ProviderCost.build(tool: .claude, source: .localTranscripts, days: days, now: now, weekStart: day, calendar: utc,
                                        hourly: HourlyBurn(lastHour: 6, typicalHourly: 2, activeHours: 9), scannedAt: now)!
        let cursor = provider(.cursor, source: .billingExport, cost: 4, tokens: 100)
        let both = CostSelection(providers: [claude, cursor])
        #expect(both.lastHour == 6)
        #expect(both.burnMultiple == 3)
        #expect(CostSelection(providers: [cursor]).burnMultiple == nil)
    }

    /// Dragging an assistant above another in Settings moves it everywhere the card lists assistants: the donut's
    /// segments, the legend rows and the weights they are both built from all read `Preferences.toolOrder`, so
    /// none of them can disagree with the order the user set.
    @MainActor @Test func reorderingTheToolsReordersTheCardsProviders() {
        let suite = "NotchmeterTests.CostCardOrder"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        let carried = prefs.costCardTools

        let asShipped = CostSelection(all: three, order: prefs.toolOrder, carried: carried)
        #expect(prefs.toolOrder == [.claude, .codex, .cursor, .antigravity, .copilot])
        #expect(asShipped.providers.map(\.tool) == [.claude, .codex, .cursor])
        #expect(CostDonut.arcs(asShipped.weights(range: .today, mode: .cost)).map(\.tool) == [.claude, .codex, .cursor])

        // The user drags Cursor above Claude, as they would in Settings.
        prefs.move(.cursor, by: -1)
        prefs.move(.cursor, by: -1)
        #expect(prefs.toolOrder == [.cursor, .claude, .codex, .antigravity, .copilot])
        let reordered = CostSelection(all: three, order: prefs.toolOrder, carried: carried)
        #expect(reordered.providers.map(\.tool) == [.cursor, .claude, .codex])
        #expect(reordered.weights(range: .today, mode: .cost).map(\.tool) == [.cursor, .claude, .codex])
        #expect(CostDonut.arcs(reordered.weights(range: .today, mode: .cost)).map(\.tool) == [.cursor, .claude, .codex])
        // The order says nothing about the arithmetic: the same assistants still add up to the same total.
        #expect(abs(reordered.totals(.today).cost - asShipped.totals(.today).cost) < 1e-9)
    }
}

/// The Cost card's own preference: which assistants it carries, and what a stored value can and cannot say.
@Suite struct CostCardToolsPreference {
    @MainActor @Test func everyToolThatCanReportSpendIsCarriedByDefaultAndNoOtherEverIs() {
        let suite = "NotchmeterTests.CostCardTools"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        #expect(prefs.costCardTools == Set(ToolID.allCases.filter(\.reportsCost)))
        #expect(!prefs.costCardTools.contains(.copilot))
        prefs.costCardTools = [.claude]
        #expect(defaults.array(forKey: "costCardTools") as? [String] == ["claude"])
        #expect(Preferences(defaults: defaults).costCardTools == [.claude])
        // Copilot publishes nothing a dollar figure could come from, so a stored list naming it loses it.
        defaults.set(["claude", "copilot"], forKey: "costCardTools")
        #expect(Preferences(defaults: defaults).costCardTools == [.claude])
    }
}

/// The lines under the Cost card's legend, which describe the assistant at the top of the card's order rather
/// than the blend the donut and the legend show.
@Suite struct CostCardDetailBlock {
    init() { Localization.use(language: "en") }

    let now = DateParsing.iso8601("2026-09-01T15:00:00Z")!

    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    var today: Date { utc.startOfDay(for: now) }

    /// Claude Code's kind of day: five token buckets, a folder per turn, and entries carrying a time of day.
    var claude: ProviderCost {
        let tokens = TokenBreakdown(input: 1_000_000, cacheWrite5m: 200_000, cacheWrite1h: 800_000, cacheRead: 8_000_000, output: 100_000)
        let record = CostHistory.Record(cost: 40, tokens: tokens, byModel: ["claude-sonnet-4-5": 40], byProject: ["notchmeter": 30, "scout": 10])
        return ProviderCost.build(tool: .claude, source: .localTranscripts, days: [today: record], now: now, weekStart: today,
                                  calendar: utc, hourly: HourlyBurn(lastHour: 6, typicalHourly: 3, activeHours: 8), scannedAt: now)!
    }

    /// Cursor's kind of day: the vendor's own dollars, tokens with a cache-read count, no folder and no hour.
    var cursor: ProviderCost {
        let tokens = TokenBreakdown(input: 300_000, cacheRead: 700_000, output: 50_000)
        let record = CostHistory.Record(cost: 12, tokens: tokens, byModel: ["auto": 12], byProject: [:])
        return ProviderCost.build(tool: .cursor, source: .billingExport, days: [today: record], now: now, weekStart: today,
                                  calendar: utc, scannedAt: now)!
    }

    /// The Claude-window figures the summary carries whichever assistant leads.
    var summary: CostSummary {
        CostSummary(today: 52, yesterday: 0, last30Days: 52, daily: [], lastHour: 6, typicalHourly: 3, burnMultiple: 2,
                    unpricedModels: [], scannedAt: now,
                    week: WeekCost(start: today, cost: 1200, perPercent: 12.4),
                    block: BlockCost(start: now, end: now, cost: 18, tokens: TokenBreakdown(input: 500_000), tokensPerMinute: 4200),
                    firstUse: today, sinceFirstUse: 41_300)
    }

    func detail(_ order: [ToolID], range: CostRange = .today) throws -> CostDetail {
        let selection = CostSelection(all: [claude, cursor], order: order, carried: [.claude, .cursor])
        return CostDetail(provider: try #require(selection.providers.first), range: range, claude: summary, now: now, calendar: utc,
                          timeFormat: .twelveHour)
    }

    @Test func withCursorAtTheTopTheBlockIsCursors() throws {
        let detail = try detail([.cursor, .claude])
        #expect(detail.tokens == "Cursor used 1.1M tokens · 67% cache reads")
        #expect(detail.source == "Cursor as the vendor's own usage export priced it")
        // Every line Cursor's export cannot answer is absent rather than filled from Claude, who is on the card.
        #expect(detail.burn == nil)
        #expect(detail.projects == nil)
        #expect(detail.cacheWrites == nil)
        #expect(detail.detailCaptions == ["Cursor used 1.1M tokens · 67% cache reads"])
        #expect(detail.detailLines.isEmpty)
    }

    @Test func withClaudeAtTheTopTheBlockIsClaudes() throws {
        let detail = try detail([.claude, .cursor])
        #expect(detail.burn == "Claude last hour $6.00 · 2x its 30-day average")
        #expect(detail.tokens == "Claude used 10M tokens · 79% cache reads")
        #expect(detail.cacheWrites == "cache writes 80% 1-hour · 20% 5-minute")
        #expect(detail.projects == "Top: notchmeter $30 · scout $10")
        #expect(detail.source == "Claude priced here from local files at published list rates")
    }

    /// The weekly window, the 5-hour block and "since first use" are Claude Code's own metering, so they follow
    /// the leader rather than the fact that Claude happens to be installed.
    @Test func claudesOwnWindowsAppearOnlyWhileClaudeLeads() throws {
        #expect(try detail([.claude, .cursor], range: .week).week?.contains("per 1% of weekly") == true)
        #expect(try detail([.claude, .cursor]).block == "This session block $18.00 since 3:00 PM · 4K/min")
        #expect(try detail([.claude, .cursor], range: .last90Days).since?.hasPrefix("Claude since today") == true)
        #expect(try detail([.cursor, .claude], range: .week).week == nil)
        #expect(try detail([.cursor, .claude]).block == nil)
        #expect(try detail([.cursor, .claude], range: .last90Days).since == nil)
        // Both are range-scoped as they always were: the week's line only under Week, "since" only under 90d.
        #expect(try detail([.claude, .cursor]).week == nil)
        #expect(try detail([.claude, .cursor]).since == nil)
    }

    /// A range the leader spent nothing in has no tokens, no folders and no cache split to report.
    @Test func aRangeTheLeaderHasNothingInDropsEveryLineItCannotFill() throws {
        let detail = try detail([.claude, .cursor], range: .yesterday)
        #expect(detail.tokens == nil)
        #expect(detail.projects == nil)
        #expect(detail.cacheWrites == nil)
        #expect(detail.detailCaptions.isEmpty)
        // The hour and the provenance are the provider's, not the range's, so they stay.
        #expect(detail.burn == "Claude last hour $6.00 · 2x its 30-day average")
        #expect(detail.source == "Claude priced here from local files at published list rates")
    }
}

/// Why a tool the Cost card carries reported nothing. The card used to leave it out in silence, which reads as
/// "it costs nothing" rather than "nothing was read".
@Suite struct CostCardAbsence {
    init() { Localization.use(language: "en") }

    @Test func aCarriedToolWithNoSpendGivesTheReasonTheAppKnows() {
        let gaps = CostAbsence.gaps(carried: [.cursor, .claude, .codex], reporting: [.claude], cursorUsageEvents: false,
                                    problems: [:], nothingLocal: [.codex])
        #expect(gaps.map(\.tool) == [.cursor, .codex])
        #expect(gaps[0].text == "Cursor: “Also read Cursor's usage events” is off in Settings")
        #expect(gaps[1].text == "Codex: no sessions on this Mac yet")
    }

    @Test func aReadThatWentWrongSpeaksInItsOwnWords() {
        let gaps = CostAbsence.gaps(carried: [.cursor], reporting: [], cursorUsageEvents: true,
                                    problems: [.cursor: "Signed out of cursor.com"], nothingLocal: [])
        #expect(gaps.map(\.text) == ["Cursor: Signed out of cursor.com"])
        // The switch outranks the error: with the read off there is nothing for an error to be about.
        #expect(CostAbsence.reason(for: .cursor, cursorUsageEvents: false, problem: "Signed out of cursor.com", nothingLocal: false)
            == .settingOff("Also read Cursor's usage events"))
    }

    @Test func nothingIsSaidWhenEveryCarriedToolReports() {
        #expect(CostAbsence.gaps(carried: [.claude, .codex], reporting: [.claude, .codex], cursorUsageEvents: true,
                                 problems: [:], nothingLocal: []).isEmpty)
        // A tool that can never report spend was never a row, so it is not a gap either (docs/accuracy.md).
        #expect(CostAbsence.gaps(carried: [.copilot, .antigravity], reporting: [], cursorUsageEvents: true,
                                 problems: [:], nothingLocal: []).isEmpty)
        // With nothing else known the line says exactly that rather than guessing at a cause.
        #expect(CostAbsence.reason(for: .claude, cursorUsageEvents: true, problem: nil, nothingLocal: false) == .notReadYet)
    }
}
