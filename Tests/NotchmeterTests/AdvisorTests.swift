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
        #expect(advice[1].text == "At this rate you hit the Codex weekly cap tomorrow at 01:20, 1d 10h before reset. Cursor included usage is at 10%.")
        #expect(advice[2].text == "At this rate you hit the Claude weekly cap Sep 3 at 12:00, 2d before reset. Cursor included usage is at 10%.")

        let calmer = Advisor.advise(context([claude, cursor], awaiting: [.claude], cost: cost(burn: 6)))
        #expect(calmer.map(\.priority) == [.attention, .danger, .warn])
        #expect(calmer[2].text.hasPrefix("Claude Code burned"))
    }

    @Test func spokenCopyReadsTheDashAndTheUnits() {
        #expect(Spoken.phrase("This hour burned $8.40 — 6x your 30-day average.") == "This hour burned $8.40, 6 times your 30-day average.")
        #expect(Spoken.phrase("At this rate you hit the Claude weekly cap Sep 3 at 12:00, 2d before reset.") == "At this rate you hit the Claude weekly cap Sep 3 at 12:00, 2 days before reset.")
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
        context.runOuts = ["claude/five_hour": RunOutInterval(earliest: 70 * 60, latest: 75 * 60, sampleCount: 8)]
        #expect(Advisor.runOut(context).map(\.text) == ["At this rate you hit the Claude session cap today at 13:10, 2h 50m before reset."])
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
}
