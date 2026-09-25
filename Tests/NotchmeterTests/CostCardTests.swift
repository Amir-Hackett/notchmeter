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
        let inTheUsersOrder = ordered.providers.map(\.tool)
        #expect(inTheUsersOrder == [.cursor, .claude, .codex])
        let some = CostSelection(all: three, order: ToolID.allCases, carried: [.claude, .cursor])
        let justTheTwoCarried = some.providers.map(\.tool)
        #expect(justTheTwoCarried == [.claude, .cursor])
        // Left out is left out of the total too, so the donut and the figure in the middle describe one set.
        #expect(abs(some.totals(.today).cost - 7) < 1e-9)
        #expect(CostSelection(all: three, order: ToolID.allCases, carried: []).isEmpty)
    }

    /// A tool that cannot report spend has no ProviderCost, so it is absent rather than a zero row.
    @Test func aToolWithNoCostIsNeverASegment() {
        let selection = CostSelection(all: three, order: ToolID.allCases, carried: Set(ToolID.allCases))
        let reporting = selection.providers.map(\.tool)
        #expect(reporting == [.claude, .codex, .cursor])
        #expect(selection.provider(.copilot) == nil)
        #expect(selection.provider(.antigravity) == nil)
        // Nor is a carried tool that spent nothing in the range on show.
        #expect(selection.weights(range: .yesterday, mode: .cost).isEmpty)
        #expect(CostDonut.arcs(selection.weights(range: .yesterday, mode: .cost)).isEmpty)
    }

    @Test func eachModeSharesTheRangeOutInItsOwnUnit() {
        let selection = CostSelection(all: three, order: ToolID.allCases, carried: Set(ToolID.allCases))
        let byCost = selection.weights(range: .today, mode: .cost).map(\.weight)
        #expect(byCost == [6, 3, 1])
        let byTokens = selection.weights(range: .today, mode: .tokens).map(\.weight)
        #expect(byTokens == [3_000_000, 500_000, 250_000])
        // $/MTok is a rate, not a quantity to share out, so it is sized by its dollars.
        let byRate = selection.weights(range: .today, mode: .perMillionTokens).map(\.weight)
        #expect(byRate == [6, 3, 1])
        #expect(abs((selection.share(of: .claude, range: .today, mode: .cost) ?? 0) - 0.6) < 1e-9)
        #expect(abs((selection.share(of: .claude, range: .today, mode: .tokens) ?? 0) - 0.8) < 1e-9)
        #expect(selection.share(of: .copilot, range: .today, mode: .cost) == nil)
        // Per-MTok is each tool's own dollars over its own tokens, never the range's tokens apportioned by cost.
        let codexPerMillion = selection.provider(.codex)?.totals(.today).costPerMillionTokens.map { abs($0 - 6) < 1e-9 }
        #expect(codexPerMillion == true)
        // The card's own rate: the $10 it carries over the 3.75M tokens that earned it.
        let theCardsOwnRate = 10.0 / 3.75
        let blendedPerMillion = selection.totals(.today).costPerMillionTokens.map { abs($0 - theCardsOwnRate) < 1e-9 }
        #expect(blendedPerMillion == true)
    }

    @Test func oneProviderDrawsTheRingTheCardHasAlwaysDrawn() {
        let selection = CostSelection(all: three, order: ToolID.allCases, carried: [.claude])
        let arcs = CostDonut.arcs(selection.weights(range: .today, mode: .cost))
        let wholeRing = [CostArc(tool: .claude, start: 0.012, end: 0.988)]
        #expect(arcs == wholeRing)
        let budgeted = CostDonut.arcs(selection.weights(range: .month, mode: .cost), fill: 0.4)
        let fortyPercentOfTheRing = [CostArc(tool: .claude, start: 0, end: 0.4)]
        #expect(budgeted == fortyPercentOfTheRing)
        // An empty month still shows the sliver the ring has always shown against a budget.
        #expect(CostDonut.arcs(selection.weights(range: .month, mode: .cost), fill: 0).first?.end == CostDonut.gap)
    }

    @Test func everyProviderGetsAnArcOfItsOwnShare() {
        let selection = CostSelection(all: three, order: ToolID.allCases, carried: Set(ToolID.allCases))
        let arcs = CostDonut.arcs(selection.weights(range: .today, mode: .cost))
        let segments = arcs.map(\.tool)
        #expect(segments == [.claude, .codex, .cursor])
        #expect(arcs.first?.start == CostDonut.gap)
        #expect(arcs.last?.end == 1 - CostDonut.gap)
        // Sized by share, with a hairline between neighbours and none after the last.
        let sweep = 1 - 2 * CostDonut.gap
        let claudesEnd = CostDonut.gap + sweep * 0.6 - CostDonut.separation
        #expect(abs(arcs[0].end - claudesEnd) < 1e-9)
        let codexStart = CostDonut.gap + sweep * 0.6
        #expect(abs(arcs[1].start - codexStart) < 1e-9)
        let cursorStart = CostDonut.gap + sweep * 0.9
        #expect(abs(arcs[2].start - cursorStart) < 1e-9)
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
        let shippedOrder: [ToolID] = [.claude, .codex, .cursor, .gemini, .antigravity, .copilot, .kimi, .opencode]
        #expect(prefs.toolOrder == shippedOrder)
        let shippedProviders = asShipped.providers.map(\.tool)
        #expect(shippedProviders == [.claude, .codex, .cursor])
        let shippedSegments = CostDonut.arcs(asShipped.weights(range: .today, mode: .cost)).map(\.tool)
        #expect(shippedSegments == [.claude, .codex, .cursor])

        // The user drags Cursor above Claude, as they would in Settings.
        prefs.move(.cursor, by: -1)
        prefs.move(.cursor, by: -1)
        let draggedOrder: [ToolID] = [.cursor, .claude, .codex, .gemini, .antigravity, .copilot, .kimi, .opencode]
        #expect(prefs.toolOrder == draggedOrder)
        let reordered = CostSelection(all: three, order: prefs.toolOrder, carried: carried)
        let reorderedProviders = reordered.providers.map(\.tool)
        #expect(reorderedProviders == [.cursor, .claude, .codex])
        let reorderedWeights = reordered.weights(range: .today, mode: .cost).map(\.tool)
        #expect(reorderedWeights == [.cursor, .claude, .codex])
        let reorderedSegments = CostDonut.arcs(reordered.weights(range: .today, mode: .cost)).map(\.tool)
        #expect(reorderedSegments == [.cursor, .claude, .codex])
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
        let everyToolThatReportsCost = Set(ToolID.allCases.filter(\.reportsCost))
        #expect(prefs.costCardTools == everyToolThatReportsCost)
        #expect(prefs.costCardTools.contains(.copilot))
        #expect(!prefs.costCardTools.contains(.antigravity))
        prefs.costCardTools = [.claude]
        let stored = defaults.array(forKey: "costCardTools") as? [String]
        #expect(stored == ["claude"])
        #expect(Preferences(defaults: defaults).costCardTools == [.claude])
        // Antigravity publishes nothing a dollar figure could come from, so a stored list naming it loses it.
        defaults.set(["claude", "antigravity"], forKey: "costCardTools")
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

    func detail(_ order: [ToolID], range: CostRange = .today, promptCache: PromptCacheSummary? = nil) throws -> CostDetail {
        let selection = CostSelection(all: [claude, cursor], order: order, carried: [.claude, .cursor])
        return CostDetail(provider: try #require(selection.providers.first), range: range, claude: summary, now: now, calendar: utc,
                          timeFormat: .twelveHour, promptCache: promptCache)
    }

    /// The prompt-cache caption is Claude Code's own count from its status line, so it follows Claude the way the
    /// cache tiers do: under Claude it sits between the tiers and the folders; under Cursor it is absent, and an
    /// empty count draws no line.
    @Test func thePromptCacheCaptionFollowsClaudeAndSitsAmongTheCaptions() throws {
        let cache = PromptCacheSummary(misses: 4, requests: 31, rewrittenTokens: 310_400, rewrittenUSD: 0.93, lastCause: "tools_changed", sessions: 2)
        let claudeLeads = try detail([.claude, .cursor], promptCache: cache)
        #expect(claudeLeads.promptCacheLine == "Prompt cache: 4 misses today · 310K tokens (~$0.93) rewritten · cause: tools changed")
        #expect(claudeLeads.detailCaptions == ["Claude used 10M tokens · 79% cache reads", "cache writes 80% 1-hour · 20% 5-minute",
                                               "Prompt cache: 4 misses today · 310K tokens (~$0.93) rewritten · cause: tools changed",
                                               "Top: notchmeter $30 · scout $10"])
        #expect(try detail([.cursor, .claude], promptCache: cache).promptCacheLine == nil)
        #expect(try detail([.cursor, .claude], promptCache: cache).detailCaptions == ["Cursor used 1.1M tokens · 67% cache reads"])
        let quiet = PromptCacheSummary(misses: 0, requests: 9, rewrittenTokens: 0, rewrittenUSD: nil, lastCause: nil, sessions: 1)
        #expect(try detail([.claude, .cursor], promptCache: quiet).promptCacheLine == nil)
        #expect(try detail([.claude, .cursor]).promptCacheLine == nil)
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

    /// Under $/MTok a range that mixes models across Anthropic's 4.6/4.7 tokenizer line gets one quiet caption
    /// naming the costliest model on the newer side: a million of its tokens is less text than a million of the
    /// others'. Under the other units, or with every model on one side, the caption is absent.
    @Test func theRatePerMillionSaysWhenTheRangeMixesTokenizers() throws {
        func detail(byModel: [String: Double], mode: CostCardMode) throws -> CostDetail {
            let tokens = TokenBreakdown(input: 1_000_000, output: 100_000)
            let record = CostHistory.Record(cost: byModel.values.reduce(0, +), tokens: tokens, byModel: byModel, byProject: [:])
            let provider = try #require(ProviderCost.build(tool: .claude, source: .localTranscripts, days: [today: record], now: now, weekStart: today,
                                                            calendar: utc, scannedAt: now))
            return CostDetail(provider: provider, range: .today, claude: summary, now: now, calendar: utc, timeFormat: .twelveHour, mode: mode)
        }
        let mixed = ["claude-sonnet-4-5": 30.0, "claude-fable-5-1": 10.0]
        #expect(try detail(byModel: mixed, mode: .perMillionTokens).tokenizerNote == "Mixed tokenizers: Claude Fable 5.1 counts about 30% more tokens for the same text.")
        #expect(try detail(byModel: mixed, mode: .cost).tokenizerNote == nil)
        #expect(try detail(byModel: mixed, mode: .tokens).tokenizerNote == nil)
        #expect(try detail(byModel: ["claude-sonnet-4-5": 30, "claude-opus-4-6": 10], mode: .perMillionTokens).tokenizerNote == nil)
        #expect(try detail(byModel: ["claude-fable-5-1": 30, "claude-sonnet-4-7": 10], mode: .perMillionTokens).tokenizerNote == nil)
        // The fixture's single model gives none, and the caption is not one of the Show-details captions.
        let single = try self.detail([.claude, .cursor])
        #expect(single.tokenizerNote == nil)
        #expect(!(try detail(byModel: mixed, mode: .perMillionTokens).detailCaptions.contains { $0.hasPrefix("Mixed tokenizers") }))
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
        let toolsWithAGap = gaps.map(\.tool)
        #expect(toolsWithAGap == [.cursor, .codex])
        #expect(gaps[0].text == "Cursor: “Also read Cursor's usage events” is off in Settings")
        #expect(gaps[1].text == "Codex: no sessions on this Mac yet")
    }

    @Test func aReadThatWentWrongSpeaksInItsOwnWords() {
        let gaps = CostAbsence.gaps(carried: [.cursor], reporting: [], cursorUsageEvents: true,
                                    problems: [.cursor: "Signed out of cursor.com"], nothingLocal: [])
        let lines = gaps.map(\.text)
        #expect(lines == ["Cursor: Signed out of cursor.com"])
        // The switch outranks the error: with the read off there is nothing for an error to be about.
        #expect(CostAbsence.reason(for: .cursor, cursorUsageEvents: false, problem: "Signed out of cursor.com", nothingLocal: false)
            == .settingOff("Also read Cursor's usage events"))
    }

    @Test func nothingIsSaidWhenEveryCarriedToolReports() {
        #expect(CostAbsence.gaps(carried: [.claude, .codex], reporting: [.claude, .codex], cursorUsageEvents: true,
                                 problems: [:], nothingLocal: []).isEmpty)
        // A tool that can never report spend was never a row, so it is not a gap either (docs/accuracy.md).
        #expect(CostAbsence.gaps(carried: [.antigravity], reporting: [], cursorUsageEvents: true,
                                 problems: [:], nothingLocal: []).isEmpty)
        // With nothing else known the line says exactly that rather than guessing at a cause.
        #expect(CostAbsence.reason(for: .claude, cursorUsageEvents: true, problem: nil, nothingLocal: false) == .notReadYet)
    }

    /// Copilot's gap names what GitHub said about the seat's credits: not metered in credits at all, or metered
    /// and not yet risen since the count began; and before any read, only that nothing was read.
    @Test func copilotSaysWhatGitHubSaidAboutItsCredits() {
        let now = Date()
        #expect(CostAbsence.reason(for: .copilot, cursorUsageEvents: true, copilotCredits: nil, problem: nil, nothingLocal: false) == .notReadYet)
        let unmetered = CopilotCreditsRead(readAt: now, credits: nil)
        #expect(CostAbsence.reason(for: .copilot, cursorUsageEvents: true, copilotCredits: unmetered, problem: nil, nothingLocal: false) == .noCredits)
        let metered = CopilotCreditsRead(readAt: now, credits: 31)
        #expect(CostAbsence.reason(for: .copilot, cursorUsageEvents: true, copilotCredits: metered, problem: nil, nothingLocal: false) == .noCreditsCounted)
        let gaps = CostAbsence.gaps(carried: [.copilot], reporting: [], cursorUsageEvents: true, copilotCredits: unmetered, problems: [:], nothingLocal: [])
        #expect(gaps.map(\.text) == ["Copilot: GitHub reports no AI credits for this seat"])
        #expect(CostAbsence.noCreditsCounted.text == "no AI credits used since Notchmeter began counting")
        // A read that failed outranks what an earlier one said.
        #expect(CostAbsence.reason(for: .copilot, cursorUsageEvents: true, copilotCredits: metered, problem: "refused", nothingLocal: false) == .problem("refused"))
    }
}

/// What "Copy as image" draws. `CardImage.copy` renders a detached hierarchy, so a copied card only shows the range
/// the user picked if the card it is given knows it: until 0.5.0 the card's context-menu Button built
/// `SpendCard(store:)` and every pasted card was Today's, whatever the SegmentedBar said, and until 0.6.0 the
/// panel's own "Copy as image" (App.swift, copyPanelImage) rebuilt NotchExpandedView with the same fresh card in
/// it, so the per-card fix never reached the whole-panel copy. The range now lives on the store
/// (`UsageStore.spendRange`), which both a card built with no range and the rebuilt panel read. The card's Button
/// (NotchViews.swift, `.contextMenu` on SpendCard) must keep passing `imageCard` to `CardImage.copy`, which no
/// test exercises.
@Suite struct CostCardCopyImage {
    private static let suite = "NotchmeterTests.CostCardCopyImage"

    @MainActor @Test func theCopiedCardOpensOnTheRangeOnScreen() {
        let defaults = UserDefaults(suiteName: Self.suite)!
        defaults.removePersistentDomain(forName: Self.suite)
        defer { defaults.removePersistentDomain(forName: Self.suite) }
        let prefs = Preferences(defaults: defaults)
        let store = UsageStore(prefs: prefs, providers: [], cache: ReadingCache(defaults: defaults), defaults: defaults, drainLog: nil)

        let onScreen = SpendCard(store: store, range: .ninetyDays)
        let copied = onScreen.imageCard.openingRange
        let expected = SpendCard.Range.ninetyDays
        #expect(copied == expected)

        // A launch starts on today, so a fresh store's card, and a copy of it, are today's.
        let opened = SpendCard(store: store).imageCard.openingRange
        let today = SpendCard.Range.today
        #expect(opened == today)
    }

    /// The card the panel shows is built with no range and follows the store's, which is what the SegmentedBar
    /// sets; a copy of that card is pinned to the same range.
    @MainActor @Test func theLiveCardShowsTheStoresRangeAndItsCopyIsPinnedToIt() {
        let defaults = UserDefaults(suiteName: Self.suite)!
        defaults.removePersistentDomain(forName: Self.suite)
        defer { defaults.removePersistentDomain(forName: Self.suite) }
        let prefs = Preferences(defaults: defaults)
        let store = UsageStore(prefs: prefs, providers: [], cache: ReadingCache(defaults: defaults), defaults: defaults, drainLog: nil)

        store.spendRange = .ninetyDays
        let live = SpendCard(store: store)
        let shown = live.openingRange
        let copied = live.imageCard.openingRange
        let expected = SpendCard.Range.ninetyDays
        #expect(shown == expected)
        #expect(copied == expected)

        // A card pinned to a range of its own does not follow the store: a still of the month stays the month.
        let pinned = SpendCard(store: store, range: .month).openingRange
        let month = SpendCard.Range.month
        #expect(pinned == month)
    }

    /// The whole-panel path: the NotchExpandedView copyPanelImage rebuilds carries a Cost card on the range the
    /// panel on screen is showing, not Today's. The store has to carry a tool that can report a cost for the panel
    /// to build the card at all, so the check that the card exists is part of the test.
    @MainActor @Test func theCopiedPanelsCostCardShowsTheRangeOnScreen() {
        let defaults = UserDefaults(suiteName: Self.suite)!
        defaults.removePersistentDomain(forName: Self.suite)
        defer { defaults.removePersistentDomain(forName: Self.suite) }
        let prefs = Preferences(defaults: defaults)
        let now = Date()
        let readings = DemoFixtures.readings(now: now)
        let store = UsageStore(prefs: prefs, providers: readings.map { FixtureProvider(reading: $0) },
                               cache: ReadingCache(defaults: defaults), defaults: defaults, drainLog: nil)
        store.seed(readings: readings, cost: DemoFixtures.cost(now: now), nextUpdate: now.addingTimeInterval(60), now: now)

        store.spendRange = .thirtyDays
        let rebuilt = NotchExpandedView(store: store, prefs: prefs, actions: NotchActions(), maxHeight: 10_000)
        let card = rebuilt.spendCard
        #expect(card != nil)
        let copied = card?.openingRange
        let expected = SpendCard.Range.thirtyDays
        #expect(copied == expected)

        // The panel on screen is the same view with no cap; changing the range there changes what a rebuild draws.
        store.spendRange = .yesterday
        let redrawn = NotchExpandedView(store: store, prefs: prefs, actions: NotchActions(), maxHeight: 10_000).spendCard?.openingRange
        let yesterday = SpendCard.Range.yesterday
        #expect(redrawn == yesterday)
    }
}
