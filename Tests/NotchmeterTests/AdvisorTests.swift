import Foundation
import Testing
@testable import Notchmeter

/// Windows are built from how far into the period they are, so the projection is `used / elapsed × period`:
/// a weekly window three days in at 60 % projects to 1.4 (behind), at 40 % to 0.93 (on track), at 22 % to 0.51 (ahead).
@Suite struct AdvisorRules {
    init() { Localization.use(language: "en") }

    let now = DateParsing.iso8601("2026-09-01T12:00:00Z")!
    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func window(_ id: String, label: WindowLabel, used: Double?, elapsed: TimeInterval, period: TimeInterval = Period.week, model: String? = nil) -> LimitWindow {
        LimitWindow(id: id, label: label, usedFraction: used, resetsAt: now.addingTimeInterval(period - elapsed), periodDuration: period, model: model)
    }

    func reading(_ tool: ToolID, _ windows: [LimitWindow]) -> UsageReading {
        UsageReading(tool: tool, windows: windows, plan: nil, fetchedAt: now, observedAt: nil)
    }

    func context(_ readings: [UsageReading], awaiting: Set<ToolID> = [], cost: CostSummary? = nil) -> Advisor.Context {
        Advisor.Context(readings: readings, awaitingInput: awaiting, cost: cost, timeFormat: .twentyFourHour, now: now, calendar: utc)
    }

    func provider(_ tool: ToolID, burn: Double?, lastHour: Double = 8.4, month: Double = 0, week: Double = 0) -> ProviderCost {
        ProviderCost(tool: tool, source: tool == .cursor ? .billingExport : .localTranscripts,
                     ranges: [.month: RangeTotals(cost: month), .week: RangeTotals(cost: week)], daily: [],
                     lastHour: lastHour, typicalHourly: 1.4, burnMultiple: burn, scannedAt: now)
    }

    func cost(burn: Double?, lastHour: Double = 8.4) -> CostSummary {
        CostSummary(today: 20, yesterday: 5, last30Days: 100, daily: [], lastHour: lastHour, typicalHourly: 1.4, burnMultiple: burn,
                    unpricedModels: [], scannedAt: now, providers: [provider(.claude, burn: burn, lastHour: lastHour)])
    }

    var claudeAhead: UsageReading {
        reading(.claude, [window("five_hour", label: "Session", used: 0.1, elapsed: 3600, period: Period.fiveHours),
                          window("seven_day", label: "Weekly", used: 0.22, elapsed: 3 * 86400)])
    }
    var codexAhead: UsageReading {
        reading(.codex, [window("session", label: "Session", used: 0.05, elapsed: 3600, period: Period.fiveHours),
                         window("weekly", label: "Weekly", used: 0.22, elapsed: 3 * 86400)])
    }

    // MARK: Run-out

    @Test func runOutNamesTheTimeTheMarginAndTheToolWithRoom() {
        // 60 % with 3 of 7 days gone: out in 2 days (Sep 3, 12:00), 2 days before the reset.
        let claude = reading(.claude, [window("seven_day", label: "Weekly", used: 0.6, elapsed: 3 * 86400)])
        let advice = Advisor.advise(context([claude, codexAhead]))
        #expect(advice.map(\.text) == ["At this rate you hit the Claude weekly cap Sep 3 at 12:00, 2d before reset. Codex weekly is at 22%."])
        #expect(advice.first?.priority == .danger)
        #expect(advice.first?.symbol == "exclamationmark.triangle.fill")
        #expect(advice.first?.tool == .claude)
    }

    @Test func runOutWithoutRoomElsewhereHasNoSuffix() {
        let claude = reading(.claude, [window("seven_day", label: "Weekly", used: 0.6, elapsed: 3 * 86400)])
        let codex = reading(.codex, [window("weekly", label: "Weekly", used: 0.6, elapsed: 5 * 86400)])
        #expect(Advisor.runOut(context([claude])).map(\.text) == ["At this rate you hit the Claude weekly cap Sep 3 at 12:00, 2d before reset."])
        #expect(Advisor.runOut(context([claude, codex])).map(\.text) == ["At this rate you hit the Claude weekly cap Sep 3 at 12:00, 2d before reset."])
    }

    @Test func runOutCoversSessionsAndPerModelWindowsSoonestFirst() {
        // Session: 50 % an hour in, out in 1 h. Fable: 91 % three days in, out in ~7.1 h.
        let claude = reading(.claude, [
            window("five_hour", label: "Session", used: 0.5, elapsed: 3600, period: Period.fiveHours),
            window("seven_day", label: "Weekly", used: 0.2, elapsed: 3 * 86400),
            window("scoped_fable", label: "Fable", used: 0.91, elapsed: 3 * 86400, model: "Fable"),
        ])
        let texts = Advisor.runOut(context([claude])).map(\.text)
        #expect(texts.count == 2)
        #expect(texts[0] == "At this rate you hit the Claude session cap today at 13:00, 3h before reset.")
        #expect(texts[1].hasPrefix("At this rate you hit the Claude Fable weekly cap today at 19:"))
    }

    @Test func aWindowAlreadyOutHasNoRunOutTime() {
        let claude = reading(.claude, [window("seven_day", label: "Weekly", used: 1, elapsed: 3 * 86400)])
        #expect(Advisor.runOut(context([claude])).isEmpty)
    }

    // MARK: Cross-provider routing

    @Test func routesToTheToolWithTheMostLeftWhenTheMainWindowIsOnTrack() {
        let claude = reading(.claude, [window("five_hour", label: "Session", used: 0.1, elapsed: 3600, period: Period.fiveHours),
                                       window("seven_day", label: "Weekly", used: 0.4, elapsed: 3 * 86400)])
        let cursor = reading(.cursor, [window("included", label: "Included usage", used: 0.1, elapsed: 10 * 86400, period: 30 * 86400)])
        let advice = Advisor.advise(context([claude, codexAhead, cursor]))
        #expect(advice.map(\.text) == ["Cursor has 90% of its included usage left."])
        #expect(advice.first?.priority == .info)
        #expect(Advisor.crossProvider(context([claude, codexAhead])).map(\.text) == ["Codex has 78% of its weekly left."])
    }

    @Test func routesWhenTheMainWindowIsOutAndNotWhenItIsAhead() {
        let out = reading(.claude, [window("seven_day", label: "Weekly", used: 1, elapsed: 3 * 86400)])
        #expect(Advisor.advise(context([out, codexAhead])).map(\.text) == ["Codex has 78% of its weekly left."])
        #expect(Advisor.crossProvider(context([claudeAhead, codexAhead])).isEmpty)
    }

    @Test func noRoutingWhenNothingElseHasHalfLeftOrWhenARunOutAlreadyPointsThere() {
        let claude = reading(.claude, [window("seven_day", label: "Weekly", used: 0.4, elapsed: 3 * 86400)])
        let codex = reading(.codex, [window("weekly", label: "Weekly", used: 0.6, elapsed: 5 * 86400)])
        #expect(Advisor.advise(context([claude, codex])).isEmpty)

        let behind = reading(.claude, [window("five_hour", label: "Session", used: 0.5, elapsed: 3600, period: Period.fiveHours),
                                       window("seven_day", label: "Weekly", used: 0.4, elapsed: 3 * 86400)])
        let advice = Advisor.advise(context([behind, codexAhead]))
        #expect(advice.count == 1)
        #expect(advice[0].text.hasSuffix("before reset. Codex weekly is at 22%."))
    }

    @Test func theMainWindowIsTheLongestToolWideOne() {
        let claude = reading(.claude, [
            window("five_hour", label: "Session", used: 0.1, elapsed: 3600, period: Period.fiveHours),
            window("seven_day", label: "Weekly", used: 0.2, elapsed: 86400),
            window("scoped_fable", label: "Fable", used: 0.9, elapsed: 86400, model: "Fable"),
            LimitWindow(id: "extra_usage", label: "Extra usage", usedFraction: 0.5, resetsAt: nil),
        ])
        #expect(Advisor.mainWindow(of: claude)?.id == "seven_day")
        let cursor = reading(.cursor, [window("included", label: "Included usage", used: 0.1, elapsed: 86400, period: 30 * 86400),
                                       window("on_demand", label: "On-demand", used: 0.9, elapsed: 86400, period: 30 * 86400)])
        #expect(Advisor.mainWindow(of: cursor)?.id == "included")
        #expect(Advisor.mainWindow(of: reading(.codex, [LimitWindow(id: "session", label: "Session", usedFraction: nil, resetsAt: nil)])) == nil)
    }

    // MARK: Model routing

    @Test func switchesModelsBeforeTools() {
        // Fable 91 % with half a day left projects to 0.98: on track, so no run-out line competes.
        let claude = reading(.claude, [
            window("seven_day", label: "Weekly", used: 0.34, elapsed: 3 * 86400),
            window("scoped_fable", label: "Fable", used: 0.91, elapsed: 6.5 * 86400, model: "Fable"),
            window("scoped_sonnet", label: "Sonnet", used: 0.34, elapsed: 6.5 * 86400, model: "Sonnet"),
        ])
        let advice = Advisor.advise(context([claude, codexAhead]))
        #expect(advice.map(\.text) == ["Fable weekly is 91%. Sonnet is 34%. Switch models, not tools."])
        #expect(advice.first?.priority == .warn)
    }

    @Test func fallsBackToTheOverallWeeklyAndPrefersTheModelWithTheMostLeft() {
        let overall = reading(.claude, [
            window("seven_day", label: "Weekly", used: 0.34, elapsed: 3 * 86400),
            window("scoped_fable", label: "Fable", used: 0.91, elapsed: 6.5 * 86400, model: "Fable"),
        ])
        #expect(Advisor.modelRouting(context([overall])).map(\.text) == ["Fable weekly is 91%. Overall weekly is 34%. Switch models, not tools."])

        let three = reading(.claude, [
            window("seven_day", label: "Weekly", used: 0.8, elapsed: 3 * 86400),
            window("scoped_fable", label: "Fable", used: 0.88, elapsed: 6.5 * 86400, model: "Fable"),
            window("scoped_opus", label: "Opus", used: 0.95, elapsed: 6.5 * 86400, model: "Opus"),
            window("scoped_sonnet", label: "Sonnet", used: 0.5, elapsed: 6.5 * 86400, model: "Sonnet"),
            window("scoped_haiku", label: "Haiku", used: 0.2, elapsed: 6.5 * 86400, model: "Haiku"),
        ])
        #expect(Advisor.modelRouting(context([three])).map(\.text) == ["Opus weekly is 95%. Haiku is 20%. Switch models, not tools."])
    }

    @Test func noModelAdviceBelowTheThresholdOrWithoutRoom() {
        let cool = reading(.claude, [window("seven_day", label: "Weekly", used: 0.3, elapsed: 3 * 86400),
                                     window("scoped_fable", label: "Fable", used: 0.84, elapsed: 6.5 * 86400, model: "Fable")])
        #expect(Advisor.modelRouting(context([cool])).isEmpty)
        let full = reading(.claude, [window("seven_day", label: "Weekly", used: 0.7, elapsed: 6.5 * 86400),
                                     window("scoped_fable", label: "Fable", used: 0.9, elapsed: 6.5 * 86400, model: "Fable"),
                                     window("scoped_opus", label: "Opus", used: 0.7, elapsed: 6.5 * 86400, model: "Opus")])
        #expect(Advisor.modelRouting(context([full])).isEmpty)
    }

    @Test func perModelWindowsAreNamedByTheirCadence() {
        let daily = window("gemini_pro", label: "Gemini Pro", used: 0.9, elapsed: 12 * 3600, period: Period.day, model: "Gemini Pro")
        let undeclared = LimitWindow(id: "gemini_pro", label: "Gemini Pro", usedFraction: 0.9, resetsAt: now.addingTimeInterval(3600), model: "Gemini Pro")
        #expect(Advisor.name(daily) == "Gemini Pro daily")
        #expect(Advisor.name(undeclared) == "Gemini Pro quota")
        #expect(Advisor.name(window("included", label: "Included usage", used: 0.1, elapsed: 86400, period: 30 * 86400)) == "included usage")
        #expect(Advisor.cadence(Period.week) == "weekly")
        #expect(Advisor.cadence(Period.fiveHours) == "session")
        #expect(Advisor.cadence(30 * 86400) == "30-day window")
        // A label that already names its window is used as the card uses it: "Kimi K3 5-hour", never "Kimi K3 session".
        let scoped = window("go_5h:kimi-k3", label: .scoped(model: "Kimi K3", of: .filled("%ld-hour", [.number(5)])), used: 0.9, elapsed: 3600,
                            period: Period.fiveHours, model: "Kimi K3")
        #expect(Advisor.name(scoped) == "Kimi K3 5-hour")
        #expect(Advisor.name(scoped, of: .opencode) == "Kimi K3 5-hour")
    }

    /// OpenCode Go meters each model over three windows, so the advice sets a model's 5-hour share against another
    /// model's 5-hour share, never its month, and names both the way the card does. Kimi K3: five $0.54 turns in the
    /// last five hours, $2.70 of its $3 share; GLM-5.2: one $0.18 turn of its $12.
    @Test func goModelsAreComparedWindowForWindowAndNamedAsTheCardNamesThem() throws {
        func turn(_ model: String, hoursAgo: Double, input: Int, output: Int) -> OpenCodeUsage {
            OpenCodeUsage(id: UUID().uuidString, sessionID: "s", timestamp: now.addingTimeInterval(-hoursAgo * 3600), providerID: GoPlan.providerID,
                          modelID: model, directory: nil, tokens: TokenBreakdown(input: input, output: output), contextTokens: input, recordedCost: nil)
        }
        let turns = (0..<5).map { turn("kimi-k3", hoursAgo: Double($0) * 0.5 + 0.25, input: 80_000, output: 20_000) }
            + [turn("glm-5.2", hoursAgo: 1, input: 100_000, output: 10_000)]
        let go = try #require(GoMeter.reading(turns, now: now))
        #expect(Advisor.modelRouting(context([go])).map(\.text) == ["Kimi K3 5-hour is 90%. GLM-5.2 is 2%. Switch models, not tools."])
        // With GLM-5.2 as full as Kimi K3 in the five hours, its empty month is no alternative, and the tool-wide
        // 5-hour window is Kimi K3's own figure, so there is nowhere to route to.
        let both = turns + (0..<70).map { turn("glm-5.2", hoursAgo: Double($0) * 0.05 + 0.25, input: 100_000, output: 10_000) }
        #expect(Advisor.modelRouting(context([try #require(GoMeter.reading(both, now: now))])).isEmpty)
    }

    /// Codex Spark's session window is a share of Codex's own session window, not of its week.
    @Test func aPerModelSessionWindowFallsBackToTheOverallSessionNotTheWeek() {
        let codex = reading(.codex, [
            window("session", label: "Session", used: 0.12, elapsed: 3600, period: Period.fiveHours),
            window("weekly", label: "Weekly", used: 0.4, elapsed: 3 * 86400),
            window("spark_session", label: .scoped(model: "Spark", of: "Session"), used: 0.91, elapsed: 3600, period: Period.fiveHours, model: "Spark"),
            window("spark_weekly", label: .scoped(model: "Spark", of: "Weekly"), used: 0.3, elapsed: 3 * 86400, model: "Spark"),
        ])
        #expect(Advisor.modelRouting(context([codex])).map(\.text) == ["Spark session is 91%. Overall session is 12%. Switch models, not tools."])
        #expect(Advisor.overallWindow(of: codex, period: Period.week)?.id == "weekly")
        #expect(Advisor.overallWindow(of: codex, period: nil)?.id == "weekly", "with no length declared, the main window as before")
    }

    /// Cursor labels half its plan "Cursor models", so a sentence that opens with the tool's name used to say it
    /// twice: "At this rate you hit the Cursor Cursor models 31-day window cap".
    @Test func aSentenceThatNamesTheToolDoesNotAlsoNameItInTheWindow() {
        let own = window("cursor_models", label: "Cursor models", used: 0.49, elapsed: 86400, period: 31 * 86400, model: "Cursor models")
        let other = window("other_models", label: "Other models", used: 1, elapsed: 86400, period: 31 * 86400, model: "Other models")
        #expect(Advisor.name(own) == "Cursor models 31-day window")
        #expect(Advisor.name(own, of: .cursor) == "models 31-day window")
        // Only the tool's own name is dropped, and only from the front.
        #expect(Advisor.name(other, of: .cursor) == "Other models 31-day window")
        #expect(Advisor.name(own, of: .claude) == "Cursor models 31-day window")
        // A model labelled with the bare tool name leaves the cadence behind, which is what the sentence wants:
        // "Cursor weekly resets in 3h", not "Cursor Cursor weekly resets in 3h".
        let bare = window("cursor", label: "Cursor", used: 0.5, elapsed: 86400, period: Period.week, model: "Cursor")
        #expect(Advisor.name(bare, of: .cursor) == "weekly")

        // And the whole sentence, which is where the repetition was actually visible.
        let cursor = reading(.cursor, [own, other])
        let texts = Advisor.advise(context([cursor])).map(\.text)
        #expect(texts.contains { $0.hasPrefix("At this rate you hit the Cursor models 31-day window cap") })
        #expect(!texts.contains { $0.contains("Cursor Cursor") })
    }

    @Test func routesBetweenGeminiModelsLikeAnyOtherTool() {
        // Google declares no window length, so the fractions alone drive the model advice.
        let antigravity = reading(.antigravity, [
            LimitWindow(id: "gemini_pro", label: "Gemini Pro", usedFraction: 0.9, resetsAt: now.addingTimeInterval(3600), model: "Gemini Pro"),
            LimitWindow(id: "gemini_flash", label: "Gemini Flash", usedFraction: 0.2, resetsAt: now.addingTimeInterval(3600), model: "Gemini Flash"),
        ])
        let advice = Advisor.advise(context([antigravity, codexAhead]))
        #expect(advice.map(\.text) == ["Gemini Pro quota is 90%. Gemini Flash is 20%. Switch models, not tools."])
        #expect(advice.first?.tool == .antigravity)
        #expect(advice.first?.priority == .warn)

        // Given a length, a per-model daily window runs out and names the tool with room like every other window:
        // 60 % half a day in projects to 1.2, out in 8 h, 4 h before the reset.
        let daily = reading(.antigravity, [window("gemini_pro", label: "Gemini Pro", used: 0.6, elapsed: 12 * 3600, period: Period.day, model: "Gemini Pro")])
        #expect(Advisor.advise(context([daily, codexAhead])).map(\.text) == ["At this rate you hit the Antigravity Gemini Pro daily cap today at 20:00, 4h before reset. Codex weekly is at 22%."])
    }

    // MARK: Session burn

    @Test func burnFromThreeTimesTheUsualIsNamedPerTool() {
        #expect(Advisor.burn(context([], cost: cost(burn: 6))).map(\.text) == ["Claude Code burned $8.40 this hour — 6x its 30-day average."])
        #expect(Advisor.burn(context([], cost: cost(burn: 3))).first?.priority == .warn)
        #expect(Advisor.burn(context([], cost: cost(burn: 2.9))).isEmpty)
        #expect(Advisor.burn(context([], cost: cost(burn: nil))).isEmpty)
        #expect(Advisor.burn(context([])).isEmpty)
        #expect(Advisor.advise(context([claudeAhead], cost: cost(burn: 4.5, lastHour: 3))).map(\.text) == ["Claude Code burned $3.00 this hour — 4.5x its 30-day average."])
    }

    /// Every tool that is burning gets its own line; a tool whose export cannot say (Cursor is day-resolution)
    /// never does, and two tools that are each under the line but together over it are said once as a total.
    @Test func burnIsSaidPerToolAndForTheTotal() {
        let both = CostSummary(today: 30, yesterday: 5, last30Days: 100, daily: [], lastHour: 12, typicalHourly: 2.8, burnMultiple: 4.3,
                               unpricedModels: [], scannedAt: now,
                               providers: [provider(.claude, burn: 5, lastHour: 7), provider(.codex, burn: 3.5, lastHour: 5)])
        #expect(Advisor.burn(context([], cost: both)).map(\.text) == [
            "Claude Code burned $7.00 this hour — 5x its 30-day average.",
            "Codex burned $5.00 this hour — 3.5x its 30-day average.",
        ])
        let together = CostSummary(today: 30, yesterday: 5, last30Days: 100, daily: [], lastHour: 12, typicalHourly: 3, burnMultiple: 4,
                                   unpricedModels: [], scannedAt: now,
                                   providers: [provider(.claude, burn: 2, lastHour: 7), provider(.cursor, burn: nil, lastHour: 5)])
        #expect(Advisor.burn(context([], cost: together)).map(\.text) == ["Every tool together burned $12.00 this hour — 4x your 30-day average."])
        #expect(Advisor.burn(context([], cost: together)).first?.tool == nil)
    }

    // MARK: Tool order

    @Test func tiesForTheMostRoomAndWaitingToolsFollowTheUserOrder() throws {
        // Codex and Cursor both have 78 % of their main window left.
        let codex = reading(.codex, [window("weekly", label: "Weekly", used: 0.22, elapsed: 3 * 86400)])
        let cursor = reading(.cursor, [window("included", label: "Included usage", used: 0.22, elapsed: 10 * 86400, period: 30 * 86400)])
        var context = self.context([claudeAhead, codex, cursor], awaiting: [.claude, .codex])
        #expect(try #require(Advisor.headroom(besides: .claude, in: context)).tool == .codex)
        #expect(Advisor.headroomSuffix(besides: .claude, in: context) == " Codex weekly is at 22%.")
        #expect(Advisor.waiting(context).map(\.tool) == [.claude, .codex])

        context.toolOrder = [.cursor, .codex, .claude, .antigravity]
        #expect(try #require(Advisor.headroom(besides: .claude, in: context)).tool == .cursor)
        #expect(Advisor.headroomSuffix(besides: .claude, in: context) == " Cursor included usage is at 22%.")
        #expect(Advisor.waiting(context).map(\.tool) == [.codex, .claude])

        // More room still wins over order.
        let roomier = reading(.codex, [window("weekly", label: "Weekly", used: 0.1, elapsed: 3 * 86400)])
        context.readings = [claudeAhead, roomier, cursor]
        #expect(try #require(Advisor.headroom(besides: .claude, in: context)).tool == .codex)
    }

    // MARK: Waiting, ordering, cap

    @Test func nothingToSay() {
        #expect(Advisor.advise(context([])).isEmpty)
        #expect(Advisor.advise(context([claudeAhead, codexAhead], cost: cost(burn: 1))).isEmpty)
        let unlimited = reading(.cursor, [LimitWindow(id: "included", label: "Included usage", usedFraction: nil, resetsAt: nil, note: "Unlimited")])
        #expect(Advisor.advise(context([unlimited])).isEmpty)
    }

    @Test func waitingForInputComesFirstAndTheListStopsAtThree() {
        // Codex is out in 13 h 20 m, Claude in 2 d; Cursor has 90 % left, so both run-outs point at it.
        let claude = reading(.claude, [window("seven_day", label: "Weekly", used: 0.6, elapsed: 3 * 86400)])
        let codex = reading(.codex, [window("weekly", label: "Weekly", used: 0.9, elapsed: 5 * 86400)])
        let cursor = reading(.cursor, [window("included", label: "Included usage", used: 0.1, elapsed: 10 * 86400, period: 30 * 86400)])
        let advice = Advisor.advise(context([claude, codex, cursor], awaiting: [.claude], cost: cost(burn: 6)))
        #expect(advice.count == 3)
        #expect(advice.map(\.priority) == [.attention, .danger, .danger])
        #expect(advice[0].text == "Claude Code is waiting for your input.")
        #expect(advice[0].symbol == "hand.raised.fill")
        // Both run-outs point at Cursor; the strip says so once, on the first, and the second keeps its own sentence.
        #expect(advice[1].text == "At this rate you hit the Codex weekly cap tomorrow at 01:20, 1d 10h before reset. Cursor included usage is at 10%.")
        #expect(advice[2].text == "At this rate you hit the Claude weekly cap Sep 3 at 12:00, 2d before reset.")
        #expect(advice[1].headroom == " Cursor included usage is at 10%.")
        #expect(advice[2].headroom.isEmpty)

        let calmer = Advisor.advise(context([claude, cursor], awaiting: [.claude], cost: cost(burn: 6)))
        #expect(calmer.map(\.priority) == [.attention, .danger, .warn])
        #expect(calmer[2].text.hasPrefix("Claude Code burned"))
    }

    /// The headroom clause is one fact, so it is said once per strip; but only a repeat is dropped. Two run-outs
    /// that each point at a different tool both keep theirs, and a notification body, built alone, always does.
    @Test func theHeadroomClauseIsSaidOncePerStripAndKeptWhereItIsNews() {
        // Claude 45 % three days in projects to 1.05 (behind) with 55 % left; Cursor 50 % ten days into thirty
        // projects to 1.5 (behind) with 50 % left: each is the other's room.
        let claude = reading(.claude, [window("seven_day", label: "Weekly", used: 0.45, elapsed: 3 * 86400)])
        let cursor = reading(.cursor, [window("included", label: "Included usage", used: 0.5, elapsed: 10 * 86400, period: 30 * 86400)])
        let each = Advisor.advise(context([claude, cursor]))
        #expect(each.count == 2)
        #expect(each[0].text.hasSuffix(" Cursor included usage is at 50%."))
        #expect(each[1].text.hasSuffix(" Claude weekly is at 45%."))

        // The strip drops the repeat; the same lines out of `runOut` alone, which the notifications read, keep it.
        let codex = reading(.codex, [window("weekly", label: "Weekly", used: 0.9, elapsed: 5 * 86400)])
        let roomy = reading(.cursor, [window("included", label: "Included usage", used: 0.1, elapsed: 10 * 86400, period: 30 * 86400)])
        let strip = Advisor.advise(context([claude, codex, roomy]))
        #expect(strip.map { $0.text.hasSuffix(" Cursor included usage is at 10%.") } == [true, false])
        #expect(Advisor.runOut(context([claude, codex, roomy])).map { $0.text.hasSuffix(" Cursor included usage is at 10%.") } == [true, true])
        let alert = PaceAlert(tool: .claude, window: claude.windows[0], stage: .behind)
        #expect(Advisor.alertBody(alert, context: context([claude, codex, roomy])).hasSuffix(" Cursor included usage is at 10%."))
        // A line whose text does not end with its clause is left alone rather than cut short.
        let odd = Advice(id: "x", tool: nil, priority: .info, symbol: "circle", text: "Plain.", headroom: " Missing.")
        #expect(odd.withoutHeadroom().text == "Plain.")
    }

    /// A free plan's window is not room worth routing a paid tool's work to, so it is named neither in the
    /// headroom clause nor on the room-elsewhere line. A reading that names no plan counts as paid: most of the
    /// fixtures here, and the sample notification, name none.
    @Test func aFreePlanIsNeverTheRoomToRouteTo() {
        let claude = reading(.claude, [window("seven_day", label: "Weekly", used: 0.6, elapsed: 3 * 86400)])
        func codex(plan: String?) -> UsageReading {
            UsageReading(tool: .codex, windows: [window("weekly", label: "Weekly", used: 0.22, elapsed: 3 * 86400)], plan: plan, fetchedAt: now, observedAt: nil)
        }
        #expect(codex(plan: nil).isPaid)
        #expect(codex(plan: "Plus").isPaid)
        #expect(codex(plan: "Max 5x").isPaid)
        #expect(!codex(plan: "Free").isPaid)
        #expect(!codex(plan: "free").isPaid)
        #expect(!codex(plan: "Free Limited").isPaid)
        #expect(!UsageReading(tool: .copilot, windows: [], plan: "Free", fetchedAt: now, observedAt: nil).isPaid)
        #expect(Advisor.advise(context([claude, codex(plan: "Plus")])).map(\.text) == ["At this rate you hit the Claude weekly cap Sep 3 at 12:00, 2d before reset. Codex weekly is at 22%."])
        #expect(Advisor.advise(context([claude, codex(plan: "Free")])).map(\.text) == ["At this rate you hit the Claude weekly cap Sep 3 at 12:00, 2d before reset."])
        #expect(Advisor.crossProvider(context([claudeAhead, codex(plan: "Free")])).isEmpty)
        #expect(Advisor.headroom(besides: .claude, in: context([claudeAhead, codex(plan: "Free")])) == nil)
        // With no paid room elsewhere, the wait line is free to speak.
        let soon = reading(.claude, [window("five_hour", label: "Session", used: 1, elapsed: 4.5 * 3600, period: Period.fiveHours)])
        #expect(Advisor.waitForReset(context([soon, codex(plan: "Free")])).map(\.text) == ["Claude session resets in 30m; wait rather than switch."])
        #expect(Advisor.waitForReset(context([soon, codex(plan: "Plus")])).isEmpty)
    }

    /// `/limit-reset` is community lore, not documentation, so it is an `.info` line that says "may", offered only
    /// where it would do anything: the session was the window hit, and the week still has room to spend after it.
    @Test func limitResetIsOfferedWhenTheSessionIsHitAndTheWeekHasRoom() {
        func claude(session: Double, weekly: Double) -> UsageReading {
            reading(.claude, [window("five_hour", label: "Session", used: session, elapsed: 3 * 3600, period: Period.fiveHours),
                              window("seven_day", label: "Weekly", used: weekly, elapsed: 3 * 86400)])
        }
        func limitLines(_ context: Advisor.Context) -> [Advice] { Advisor.limitHit(context) + Advisor.limitReset(context) }
        var hit = context([claude(session: 1, weekly: 0.3)])
        hit.limitHitTools = [.claude]
        let lines = limitLines(hit)
        #expect(lines.map(\.text) == ["Claude Code hit its limit; session resets in 2h.",
                                      "Claude Code may have a /limit-reset this week: it clears the 5-hour window, not the weekly cap."])
        #expect(lines.map(\.priority) == [.warn, .info])
        #expect(lines[1].id == "limit-reset")
        #expect(lines[1].tool == .claude)
        #expect(Advisor.advise(hit).map(\.id) == ["limit/claude/five_hour", "limit-reset"])

        // The week nearly spent: clearing the session would buy nothing.
        hit.readings = [claude(session: 1, weekly: 0.7)]
        #expect(limitLines(hit).map(\.id) == ["limit/claude/five_hour"])
        // The weekly was the window hit: /limit-reset does not touch it.
        hit.readings = [claude(session: 0.2, weekly: 0.95)]
        #expect(limitLines(hit).map(\.id) == ["limit/claude/seven_day"])
        // The hook recorded a rate limit no window at its limit accounts for (the reading trails the hook): the
        // session is the likeliest, so the offer stands beside the generic line.
        hit.readings = [claude(session: 0.5, weekly: 0.3)]
        #expect(limitLines(hit).map(\.text) == ["Claude Code hit its rate limit; wait for the reset.",
                                                "Claude Code may have a /limit-reset this week: it clears the 5-hour window, not the weekly cap."])
        // Without the hook's word the generic line is gone, and the offer is keyed on the reading alone: a session
        // window at its limit is what the status line or the endpoint see between prompts on a Mac with no hook
        // installed, and it is offered the command; one with room, and no hit recorded, is not.
        hit.limitHitTools = []
        #expect(Advisor.limitHit(hit).isEmpty)
        #expect(Advisor.limitReset(hit).isEmpty, "session at 50 % and nothing recorded: nothing to clear")
        hit.readings = [claude(session: 1, weekly: 0.3)]
        #expect(Advisor.limitReset(hit).map(\.id) == ["limit-reset"])
        #expect(Advisor.advise(hit).map(\.id).contains("limit-reset"))
        hit.readings = [claude(session: 1, weekly: 0.7)]
        #expect(Advisor.limitReset(hit).isEmpty, "the week is what is short")
        // Never for another tool.
        var codexHit = context([reading(.codex, [window("session", label: "Session", used: 1, elapsed: 3 * 3600, period: Period.fiveHours),
                                                 window("weekly", label: "Weekly", used: 0.3, elapsed: 3 * 86400)])])
        codexHit.limitHitTools = [.codex]
        #expect(limitLines(codexHit).map(\.id) == ["limit/codex/session"])
    }

    /// Claude 4.7 and later, and Mythos/Fable, count about 30 % more tokens than 4.6 and earlier for the same
    /// text, so a switch across that line is not the even trade the sentence makes it sound: the clause names
    /// the model on the newer side, whichever way the switch runs, and says nothing when a name cannot be placed.
    @Test func theSwitchModelsLineSaysWhenTheTokenizersDiffer() {
        func claude(hot: String, other: String) -> UsageReading {
            reading(.claude, [window("seven_day", label: "Weekly", used: 0.34, elapsed: 3 * 86400),
                              window("scoped_hot", label: .vendor(hot), used: 0.91, elapsed: 6.5 * 86400, model: hot),
                              window("scoped_other", label: .vendor(other), used: 0.34, elapsed: 6.5 * 86400, model: other)])
        }
        #expect(Advisor.modelRouting(context([claude(hot: "Fable", other: "Sonnet 4.6")])).map(\.text)
                == ["Fable weekly is 91%. Sonnet 4.6 is 34%. Switch models, not tools. Fable counts about 30% more tokens for the same text."])
        #expect(Advisor.modelRouting(context([claude(hot: "Opus 4.6", other: "Sonnet 4.7")])).map(\.text)
                == ["Opus 4.6 weekly is 91%. Sonnet 4.7 is 34%. Switch models, not tools. Sonnet 4.7 counts about 30% more tokens for the same text."])
        // Same side, or a bare label with no version to place: the sentence as it was.
        #expect(Advisor.modelRouting(context([claude(hot: "Opus 4.6", other: "Sonnet 4.5")])).map(\.text) == ["Opus 4.6 weekly is 91%. Sonnet 4.5 is 34%. Switch models, not tools."])
        #expect(Advisor.modelRouting(context([claude(hot: "Fable", other: "Sonnet")])).map(\.text) == ["Fable weekly is 91%. Sonnet is 34%. Switch models, not tools."])
        // The overall window has no model, and another vendor's models are not Claude's.
        let overall = reading(.claude, [window("seven_day", label: "Weekly", used: 0.34, elapsed: 3 * 86400),
                                        window("scoped_fable", label: "Fable", used: 0.91, elapsed: 6.5 * 86400, model: "Fable")])
        #expect(Advisor.modelRouting(context([overall])).map(\.text) == ["Fable weekly is 91%. Overall weekly is 34%. Switch models, not tools."])
        #expect(Advisor.tokenizerCaveat(between: "Gemini Pro", and: "Gemini Flash").isEmpty)
        #expect(Advisor.tokenizerCaveat(between: "Fable", and: nil).isEmpty)
    }

    @Test func spokenCopyReadsTheDashAndTheUnits() {
        #expect(Spoken.phrase("This hour burned $8.40 — 6x your 30-day average.") == "This hour burned $8.40, 6 times your 30-day average.")
        #expect(Spoken.phrase("At this rate you hit the Claude weekly cap Sep 3 at 12:00, 2d before reset.") == "At this rate you hit the Claude weekly cap Sep 3 at 12:00, 2 days before reset.")
        #expect(Spoken.phrase("Fable counts about 30% more tokens for the same text.") == "Fable counts about 30 percent more tokens for the same text.")
    }

    /// Screen-share privacy (UsageStore.hidesFigures): no line carries money or a figure. The same context with
    /// the setting off says plenty of both, so the test is not passing on an empty strip.
    @Test func noLineCarriesAFigureWhileTheScreenIsShared() {
        let claude = reading(.claude, [window("seven_day", label: "Weekly", used: 0.6, elapsed: 3 * 86400)])
        let codex = reading(.codex, [window("weekly", label: "Weekly", used: 0.9, elapsed: 5 * 86400)])
        let cursor = reading(.cursor, [window("included", label: "Included usage", used: 0.1, elapsed: 10 * 86400, period: 30 * 86400)])
        var context = self.context([claude, codex, cursor], awaiting: [.claude], cost: cost(burn: 6))
        context.monthlyBudgetUSD = 10
        context.weeklyBudgetUSD = 5
        context.extraUsageRise = ExtraUsageRise(amountUSD: 12.5, over: 3600, planUsed: 0.4, firstThisMonth: true)
        func figure(_ text: String) -> Bool { text.contains(where: \.isNumber) || text.contains("$") }
        #expect(Advisor.advise(context).contains { figure($0.text) })
        context.hidesFigures = true
        let hidden = Advisor.advise(context)
        #expect(!hidden.isEmpty, "a line with no figure in it still shows")
        for line in hidden {
            #expect(!figure(line.text), "\(line.id): \(line.text)")
        }
    }
}

/// The store's side of screen-share privacy: the advice it builds from its own spend, budgets and sessions.
@MainActor @Suite struct AdvicePrivacy {
    @Test func theStoresAdviceCarriesNoFigureWhileTheScreenIsShared() {
        Localization.use(language: "en")
        let (store, prefs) = DemoFixtures.store(now: Date())
        prefs.hideFromScreenShare = true
        prefs.monthlyBudget = Budget(amount: 1, code: "USD", rate: 1)
        prefs.weeklyBudget = Budget(amount: 1, code: "USD", rate: 1)
        store.setScreenCaptured(true)
        defer { store.setScreenCaptured(false) }
        #expect(store.hidesFigures)
        let context = store.adviceContext()
        #expect(context.cost == nil && context.monthlyBudgetUSD == nil && context.weeklyBudgetUSD == nil)
        #expect(context.extraUsageRise == nil && context.metering == nil && context.waitingSessions.isEmpty)
        for line in store.advice {
            #expect(!(line.text.contains(where: \.isNumber) || line.text.contains("$")), "\(line.id): \(line.text)")
        }
    }
}

@Suite struct PaceAlertCopy {
    init() { Localization.use(language: "en") }

    let now = DateParsing.iso8601("2026-09-01T12:00:00Z")!
    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func context(_ readings: [UsageReading]) -> Advisor.Context {
        Advisor.Context(readings: readings, timeFormat: .twentyFourHour, now: now, calendar: utc)
    }

    @Test func bodiesFollowTheStage() {
        let weekly = LimitWindow(id: "seven_day", label: "Weekly", usedFraction: 0.6, resetsAt: now.addingTimeInterval(4 * 86400), periodDuration: Period.week)
        let codex = UsageReading(tool: .codex, windows: [LimitWindow(id: "weekly", label: "Weekly", usedFraction: 0.22, resetsAt: now.addingTimeInterval(4 * 86400), periodDuration: Period.week)],
                                 plan: nil, fetchedAt: now, observedAt: nil)
        let behind = PaceAlert(tool: .claude, window: weekly, stage: .behind)
        #expect(Advisor.alertTitle(behind) == "Claude Weekly")
        #expect(Advisor.alertBody(behind, context: context([codex])) == "At this rate you hit the Claude weekly cap Sep 3 at 12:00, 2d before reset. Codex weekly is at 22%.")
        #expect(behind.identifier == "claude/seven_day/2/\(Int(weekly.resetsAt!.timeIntervalSince1970))")

        let onTrack = PaceAlert(tool: .claude, window: LimitWindow(id: "seven_day", label: "Weekly", usedFraction: 0.4, resetsAt: now.addingTimeInterval(4 * 86400), periodDuration: Period.week), stage: .onTrack)
        #expect(Advisor.alertBody(onTrack, context: context([])) == "Claude weekly is close to pace: ~7% left at reset.")

        let out = PaceAlert(tool: .claude, window: LimitWindow(id: "five_hour", label: "Session", usedFraction: 1, resetsAt: now.addingTimeInterval(2 * 3600), periodDuration: Period.fiveHours), stage: .behind)
        #expect(Advisor.alertBody(out, context: context([codex])) == "Claude session has run out. Resets today at 14:00. Codex weekly is at 22%.")
    }

    /// The budget rides the scheduler under Claude's key so the key holds all month, but the money in it is every
    /// tool's: the banner names the budget alone, on keys with no tool argument to leave blank, and carries no
    /// headroom nudge, because room on another tool is no answer to money.
    @Test func aBudgetAlertNamesNoVendor() {
        let codex = UsageReading(tool: .codex, windows: [LimitWindow(id: "weekly", label: "Weekly", usedFraction: 0.22, resetsAt: now.addingTimeInterval(4 * 86400), periodDuration: Period.week)],
                                 plan: nil, fetchedAt: now, observedAt: nil)
        let halfway = now.addingTimeInterval(15 * 86400)
        let month: TimeInterval = 30 * 86400
        func budget(used: Double) -> LimitWindow {
            LimitWindow(id: "budget_month", label: .key("Monthly budget"), usedFraction: used, resetsAt: halfway, periodDuration: month, source: .localEstimate)
        }
        let spent = PaceAlert(tool: .claude, window: budget(used: 1), stage: .limitHit)
        #expect(Advisor.isBudget(spent.window))
        #expect(Advisor.alertTitle(spent) == "Monthly budget")
        let spentBody = Advisor.alertBody(spent, context: context([codex]))
        #expect(spentBody.hasPrefix("The monthly budget is spent. Resets "))
        #expect(!spentBody.contains("Claude"))
        #expect(!spentBody.contains("Codex"))
        // 60 % halfway through runs out in 10 days, 5 before the month ends.
        let behind = PaceAlert(tool: .claude, window: budget(used: 0.6), stage: .behind)
        #expect(Advisor.alertBody(behind, context: context([codex])) == "At this rate you pass the monthly budget Sep 11 at 12:00, 5d before it resets.")
        // 40 % halfway through projects to 80 %.
        let onTrack = PaceAlert(tool: .claude, window: budget(used: 0.4), stage: .onTrack)
        #expect(Advisor.alertBody(onTrack, context: context([codex])) == "The monthly budget is close to pace: ~20% left at reset.")
        let weekly = PaceAlert(tool: .claude, window: LimitWindow(id: "seven_day", label: "Weekly", usedFraction: 0.6, resetsAt: now.addingTimeInterval(4 * 86400), periodDuration: Period.week), stage: .behind)
        #expect(!Advisor.isBudget(weekly.window))
        #expect(Advisor.alertTitle(weekly) == "Claude Weekly")
    }

    @Test func theSampleIsARealRunOutLine() {
        let sample = Notifier.sampleBody(timeFormat: .twentyFourHour, now: now)
        #expect(sample.hasPrefix("At this rate you hit the Claude weekly cap "))
        #expect(sample.hasSuffix(" before reset. Codex weekly is at 22%."))
    }
}


/// The wait line's status link, the server-trouble line, and the run-out interval in the run-out line.
@Suite struct AdvisorRoundTwo {
    init() { Localization.use(language: "en") }

    let now = DateParsing.iso8601("2026-09-01T12:00:00Z")!
    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func serverTroublePointsAtTheStatusPage() {
        let out = LimitWindow(id: "five_hour", label: "Session", usedFraction: 1, resetsAt: now.addingTimeInterval(40 * 60), periodDuration: Period.fiveHours)
        var context = Advisor.Context(readings: [UsageReading(tool: .claude, windows: [out], plan: nil, fetchedAt: now, observedAt: nil)], now: now)
        #expect(Advisor.waitForReset(context).first?.url == nil)
        context.serverTrouble = [.claude: 503]
        #expect(Advisor.waitForReset(context).first?.url == ProviderLinks.status(.claude))
        let trouble = Advisor.serverTrouble(context)
        #expect(trouble.map(\.text) == ["Claude's usage endpoint is answering HTTP 503; check its status page."])
        #expect(trouble.first?.url?.host == "status.anthropic.com")
        #expect(trouble.first?.priority == .info)
        let object = UsageReport(tools: [:], cost: nil, advice: trouble, now: now).object
        #expect(((object["advice"] as? [[String: Any]])?.first?["url"] as? String) == "https://status.anthropic.com")
    }

    @Test func aWideRunOutIntervalNamesBothEdges() {
        let session = LimitWindow(id: "five_hour", label: "Session", usedFraction: 0.5, resetsAt: now.addingTimeInterval(4 * 3600), periodDuration: Period.fiveHours)
        var context = Advisor.Context(readings: [UsageReading(tool: .claude, windows: [session], plan: nil, fetchedAt: now, observedAt: nil)], timeFormat: .twentyFourHour, now: now, calendar: utc)
        #expect(Advisor.runOut(context).map(\.text) == ["At this rate you hit the Claude session cap today at 13:00, 3h before reset."])
        context.runOuts = ["claude/five_hour": RunOutInterval(earliest: 70 * 60, latest: 160 * 60, sampleCount: 8)]
        #expect(Advisor.runOut(context).map(\.text) == ["At this rate you hit the Claude session cap today between 13:10 and 14:40."])
        // Narrow: one time at the midpoint (72 minutes from 12:00), with the margin measured from the same time.
        context.runOuts = ["claude/five_hour": RunOutInterval(earliest: 70 * 60, latest: 74 * 60, sampleCount: 8)]
        #expect(Advisor.runOut(context).map(\.text) == ["At this rate you hit the Claude session cap today at 13:12, 2h 48m before reset."])
        context.runOuts = ["claude/five_hour": RunOutInterval(earliest: 5 * 3600, latest: 6 * 3600, sampleCount: 8)]
        #expect(Advisor.runOut(context).map(\.text) == ["At this rate you hit the Claude session cap today at 13:00, 3h before reset."])
        let note = MeterRow.paceNote(window: session, runOut: RunOutInterval(earliest: 70 * 60, latest: 160 * 60, sampleCount: 8), format: .twentyFourHour, now: now)
        #expect(note?.status == .behind)
        #expect(note?.text.hasPrefix("Runs out ") == true)
        let object = UsageReport(tools: [.claude: .ready(context.readings[0])], order: [.claude], cost: nil, advice: [],
                                 runOuts: [DrainLog.Key(tool: .claude, window: "five_hour"): RunOutInterval(earliest: 70 * 60, latest: 160 * 60, sampleCount: 8)], now: now).object
        let window = ((object["tools"] as? [[String: Any]])?.first?["windows"] as? [[String: Any]])?.first
        #expect((window?["runOut"] as? [String: Any])?["earliestAt"] as? String == Oracle.timestamp(now.addingTimeInterval(70 * 60)))
        #expect(window?["source"] as? String == "vendorEndpoint")
    }

    /// Until 0.6.0 the card printed the midpoint of a narrow interval while the advice under it quoted the earliest
    /// edge, so the panel named two times for one event. Both now read `RunOutInterval.presentation`: the same
    /// interval gives the same time out of both paths, a range from both when it is wide.
    @Test func theCardAndTheAdviceNameTheSameRunOutTime() throws {
        let reset = now.addingTimeInterval(4 * 3600)
        let session = LimitWindow(id: "five_hour", label: "Session", usedFraction: 0.5, resetsAt: reset, periodDuration: Period.fiveHours)
        var context = Advisor.Context(readings: [UsageReading(tool: .claude, windows: [session], plan: nil, fetchedAt: now, observedAt: nil)], timeFormat: .twentyFourHour, now: now, calendar: utc)

        // Narrow, 70 to 74 minutes from now: one time, the midpoint, and the earliest edge appears nowhere.
        let narrow = RunOutInterval(earliest: 70 * 60, latest: 74 * 60, sampleCount: 8)
        context.runOuts = ["claude/five_hour": narrow]
        let midpoint: TimeInterval = 72 * 60
        let midpointAt = now.addingTimeInterval(midpoint)
        #expect(narrow.presentation(now: now, resetsAt: reset) == .single(at: midpointAt))
        let card = try #require(MeterRow.paceNote(window: session, runOut: narrow, format: .twentyFourHour, now: now))
        let expectedCard = "Runs out in \(ResetText.duration(midpoint))"
        #expect(card.text == expectedCard)
        #expect(card.status == .behind)
        let advice = try #require(Advisor.runOut(context).first?.text)
        let shown = ResetText.time(midpointAt, format: .twentyFourHour, calendar: utc)
        let earliestShown = ResetText.time(now.addingTimeInterval(narrow.earliest), format: .twentyFourHour, calendar: utc)
        #expect(advice.contains("today at \(shown), "))
        #expect(!advice.contains(earliestShown))
        let expectedMargin = ResetText.duration(reset.timeIntervalSince(midpointAt))
        #expect(advice.hasSuffix(", \(expectedMargin) before reset."))

        // Wide, 70 to 160 minutes: a range with the same two edges out of both paths.
        let wide = RunOutInterval(earliest: 70 * 60, latest: 160 * 60, sampleCount: 8)
        context.runOuts = ["claude/five_hour": wide]
        let fromAt = now.addingTimeInterval(wide.earliest)
        let toAt = now.addingTimeInterval(wide.latest)
        #expect(wide.presentation(now: now, resetsAt: reset) == .range(from: fromAt, to: toAt))
        let from = ResetText.time(fromAt, format: .twentyFourHour, calendar: utc)
        let to = ResetText.time(toAt, format: .twentyFourHour, calendar: utc)
        let wideCard = try #require(wide.text(now: now, resetsAt: reset, format: .twentyFourHour, calendar: utc))
        let expectedWideCard = "Runs out \(from)–\(to)"
        #expect(wideCard == expectedWideCard)
        let wideAdvice = try #require(Advisor.runOut(context).first?.text)
        #expect(wideAdvice.contains("between \(from) and \(to)"))

        // Wide with the slow edge past the reset: both name the fast edge; the card adds that the window may last.
        let open = RunOutInterval(earliest: 70 * 60, latest: 5 * 3600, sampleCount: 8)
        context.runOuts = ["claude/five_hour": open]
        #expect(open.presentation(now: now, resetsAt: reset) == .rangeToReset(from: fromAt))
        let openCard = try #require(open.text(now: now, resetsAt: reset, format: .twentyFourHour, calendar: utc))
        let expectedOpenCard = "Runs out from \(from), or lasts to the reset"
        #expect(openCard == expectedOpenCard)
        let openAdvice = try #require(Advisor.runOut(context).first?.text)
        #expect(openAdvice.contains("today at \(from), "))
    }

    /// Until 0.7.0 the range form printed one day for both edges, so an interval that straddled midnight read
    /// "today between 23:50 and 00:30", a range that runs backwards. Edges on different days now each carry
    /// theirs, on the card and in the advice alike; edges on one day keep the shorter sentence.
    @Test func aRunOutIntervalAcrossMidnightNamesBothDays() throws {
        let lateNow = DateParsing.iso8601("2026-09-01T23:00:00Z")!
        let reset = lateNow.addingTimeInterval(4 * 3600)
        let session = LimitWindow(id: "five_hour", label: "Session", usedFraction: 0.5, resetsAt: reset, periodDuration: Period.fiveHours)
        var context = Advisor.Context(readings: [UsageReading(tool: .claude, windows: [session], plan: nil, fetchedAt: lateNow, observedAt: nil)],
                                      timeFormat: .twentyFourHour, now: lateNow, calendar: utc)
        let straddling = RunOutInterval(earliest: 50 * 60, latest: 90 * 60, sampleCount: 8)
        context.runOuts = ["claude/five_hour": straddling]
        #expect(Advisor.runOut(context).map(\.text) == ["At this rate you hit the Claude session cap between today at 23:50 and tomorrow at 00:30."])
        #expect(straddling.text(now: lateNow, resetsAt: reset, format: .twentyFourHour, calendar: utc) == "Runs out between today at 23:50 and tomorrow at 00:30")
        // The notification body is the same sentence, with the room elsewhere on the end.
        let codex = UsageReading(tool: .codex, windows: [LimitWindow(id: "weekly", label: "Weekly", usedFraction: 0.22, resetsAt: reset, periodDuration: Period.week)],
                                 plan: nil, fetchedAt: lateNow, observedAt: nil)
        context.readings.append(codex)
        #expect(Advisor.alertBody(PaceAlert(tool: .claude, window: session, stage: .behind), context: context)
                == "At this rate you hit the Claude session cap between today at 23:50 and tomorrow at 00:30. Codex weekly is at 22%.")
        context.readings.removeLast()

        // Both edges past midnight: both say tomorrow, because "tomorrow between" would be read from today.
        context.runOuts = ["claude/five_hour": RunOutInterval(earliest: 70 * 60, latest: 110 * 60, sampleCount: 8)]
        #expect(Advisor.runOut(context).map(\.text) == ["At this rate you hit the Claude session cap tomorrow between 00:10 and 00:50."])
        // A single time past midnight, and the near edge of an open range, carry the day as they always did.
        context.runOuts = ["claude/five_hour": RunOutInterval(earliest: 70 * 60, latest: 74 * 60, sampleCount: 8)]
        #expect(Advisor.runOut(context).map(\.text) == ["At this rate you hit the Claude session cap tomorrow at 00:12, 2h 48m before reset."])
        let open = RunOutInterval(earliest: 70 * 60, latest: 5 * 3600, sampleCount: 8)
        context.runOuts = ["claude/five_hour": open]
        #expect(Advisor.runOut(context).map(\.text) == ["At this rate you hit the Claude session cap tomorrow at 00:10, 2h 50m before reset."])
        #expect(open.text(now: lateNow, resetsAt: reset, format: .twentyFourHour, calendar: utc) == "Runs out from tomorrow at 00:10, or lasts to the reset")
        // And the same interval at midday keeps the one-day sentence.
        context.now = now
        context.readings = [UsageReading(tool: .claude, windows: [LimitWindow(id: "five_hour", label: "Session", usedFraction: 0.5, resetsAt: now.addingTimeInterval(4 * 3600), periodDuration: Period.fiveHours)],
                                         plan: nil, fetchedAt: now, observedAt: nil)]
        context.runOuts = ["claude/five_hour": straddling]
        #expect(Advisor.runOut(context).map(\.text) == ["At this rate you hit the Claude session cap today between 12:50 and 13:30."])
    }

    /// The strip drops a repeated headroom clause by cutting it off the end of the line, which holds only while
    /// every language keeps the clause's placeholder last. Each table is checked on each of the three sentences
    /// that carry one.
    @Test func everyLanguagePutsTheHeadroomClauseLast() {
        defer { Localization.use(language: "en") }
        let reset = now.addingTimeInterval(4 * 3600)
        let session = LimitWindow(id: "five_hour", label: "Session", usedFraction: 0.5, resetsAt: reset, periodDuration: Period.fiveHours)
        let codex = LimitWindow(id: "weekly", label: "Weekly", usedFraction: 0.22, resetsAt: now.addingTimeInterval(4 * 86400), periodDuration: Period.week)
        let lateNow = DateParsing.iso8601("2026-09-01T23:00:00Z")!
        let forms: [(start: Date, interval: RunOutInterval?)] = [
            (now, nil),
            (now, RunOutInterval(earliest: 70 * 60, latest: 160 * 60, sampleCount: 8)),
            (lateNow, RunOutInterval(earliest: 50 * 60, latest: 90 * 60, sampleCount: 8)),
        ]
        for language in Localization.languages {
            Localization.use(language: language)
            for form in forms {
                let window = LimitWindow(id: session.id, label: "Session", usedFraction: 0.5, resetsAt: form.start.addingTimeInterval(4 * 3600), periodDuration: Period.fiveHours)
                var context = Advisor.Context(readings: [UsageReading(tool: .claude, windows: [window], plan: nil, fetchedAt: form.start, observedAt: nil),
                                                         UsageReading(tool: .codex, windows: [codex], plan: nil, fetchedAt: form.start, observedAt: nil)],
                                              timeFormat: .twentyFourHour, now: form.start, calendar: utc)
                if let interval = form.interval { context.runOuts = ["claude/five_hour": interval] }
                let clause = Advisor.headroomSuffix(besides: .claude, in: context)
                #expect(!clause.isEmpty, "\(language)")
                let line = Advisor.runOut(context).first
                #expect(line?.headroom == clause, "\(language)")
                #expect(line?.text.hasSuffix(clause) == true, "\(language): \(line?.text ?? "")")
            }
        }
    }
}
