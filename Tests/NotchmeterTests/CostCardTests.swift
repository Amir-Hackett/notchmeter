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
