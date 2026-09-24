import Foundation
import Testing
@testable import Notchmeter

/// What a usage card is built from and what it comes to: the rows, the series, the ratio and the caption, all
/// from figures the app already holds and nothing else.
@Suite struct ShareCardAssembly {
    init() { Localization.use(language: "en") }

    /// A Thursday.
    let now = DateParsing.iso8601("2026-09-24T15:00:00Z")!

    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    var today: Date { utc.startOfDay(for: now) }

    /// A provider's day series: `spend` is cost by days back from today, on a project every record names, so the
    /// tests can check that the name reaches neither the card nor the caption.
    func provider(_ tool: ToolID, spend: [Int: Double], topModel: [Int: String] = [:]) throws -> ProviderCost {
        var days: [Date: CostHistory.Record] = [:]
        for (ago, cost) in spend {
            let day = try #require(utc.date(byAdding: .day, value: -ago, to: today))
            let model = topModel[ago] ?? "claude-opus-5"
            days[day] = CostHistory.Record(cost: cost, tokens: TokenBreakdown(input: Int(cost * 1000)), byModel: [model: cost],
                                           byProject: ["secret-project": cost])
        }
        return try #require(ProviderCost.build(tool: tool, source: .localTranscripts, days: days, now: now, weekStart: today, calendar: utc, scannedAt: now))
    }

    func input(_ providers: [ProviderCost], range: ShareCardRange = .sevenDays, metric: ShareCardMetric = .value,
               plans: [ToolID: String] = [:]) -> ShareCard.Input {
        ShareCard.Input(providers: providers, order: ToolID.allCases, plans: plans, metric: metric, range: range, now: now, calendar: utc)
    }

    @Test func rowsSeriesAndTotalsComeFromTheProvidersInTheReadersOrder() throws {
        let claude = try provider(.claude, spend: [0: 10, 1: 20, 3: 30])
        let cursor = try provider(.cursor, spend: [0: 5, 6: 5])
        var made = input([cursor, claude], plans: [.claude: "Max 5x", .cursor: "Free"])
        made.order = [.cursor, .claude, .codex, .antigravity, .copilot]
        let content = ShareCard.content(made)
        #expect(content.days.count == 7)
        #expect(content.days.last == today)
        let rows = content.rows.map(\.tool)
        #expect(rows == [.cursor, .claude])
        let amounts = content.rows.map(\.amount)
        #expect(amounts == [10, 60])
        #expect(content.total == 70)
        let claudesShare = content.rows[1].share.map { abs($0 - 60.0 / 70) < 1e-9 }
        #expect(claudesShare == true)
        // Running totals per row, oldest day first: Cursor spent 5 six days ago and 5 today.
        let cursorRunning: [Double] = [5, 5, 5, 5, 5, 5, 10]
        let claudeRunning: [Double] = [0, 0, 0, 30, 30, 50, 60]
        #expect(content.cumulative[0] == cursorRunning)
        #expect(content.cumulative[1] == claudeRunning)
        #expect(content.headline == "$70")
        // Seven days stand against no fee, so there is no ratio however well the plans are known.
        #expect(content.plan == nil)
        #expect(content.headlineCaption == "of API-equivalent value")
        #expect(content.ratioCaption == nil)
        #expect(content.footnote == "API-equivalent estimate, not a bill")
        // The interval formatter's own spacing around the dash is not asserted, only the two ends.
        let span = content.span(calendar: utc)
        #expect(span.hasPrefix("Sep 18") && span.hasSuffix("24"), "the span reads \(span)")
    }

    @Test func aMonthCarriesTheRatioAndTokensCarryNone() throws {
        let claude = try provider(.claude, spend: [0: 100, 10: 100, 20: 100])
        let value = ShareCard.content(input([claude], range: .thirtyDays, plans: [.claude: "Max 5x"]))
        let plan = try #require(value.plan)
        #expect(plan.fee == 100)
        #expect(plan.multiple == "3x")
        #expect(value.headlineCaption == "of API-equivalent value on the $100 Claude Max 5x plan")
        #expect(value.ratioCaption == "the plan's price")
        #expect(value.rows.first?.share == nil, "a lone row has no share to print")
        let tokens = ShareCard.content(input([claude], range: .thirtyDays, metric: .tokens, plans: [.claude: "Max 5x"]))
        #expect(tokens.plan == nil)
        #expect(tokens.headline == "300K tokens")
        #expect(tokens.headlineCaption == nil)
        #expect(tokens.footnote == "Token counts from this Mac's own records")
        // An unknown plan: the value stays, the ratio goes.
        let unknown = ShareCard.content(input([claude], range: .thirtyDays, plans: [.claude: "Team"]))
        #expect(unknown.plan == nil)
        #expect(unknown.headline == "$300")
        // This month on the 24th: a month's fee against the month so far.
        let month = ShareCard.content(input([claude], range: .month, plans: [.claude: "Max 5x"]))
        #expect(month.days.count == 24)
        #expect(month.plan?.months == 1)
    }

    /// Ninety days of fees are set against ninety days of records or not at all (PlanValue.covers).
    @Test func ninetyDaysAsksForNinetyDaysOfRecords() throws {
        let recent = try provider(.claude, spend: [0: 100, 40: 100])
        var made = input([recent], range: .ninetyDays, plans: [.claude: "Max 5x"])
        #expect(ShareCard.content(made).plan == nil)
        made.firstUse = utc.date(byAdding: .day, value: -300, to: today)
        #expect(ShareCard.content(made).plan?.fee == 300)
        let old = try provider(.claude, spend: [0: 100, 89: 100])
        #expect(ShareCard.content(input([old], range: .ninetyDays, plans: [.claude: "Max 5x"])).plan?.months == 3)
    }

    @Test func theReadersChoiceOfAssistantsAndAnEmptyRange() throws {
        let claude = try provider(.claude, spend: [0: 10])
        let cursor = try provider(.cursor, spend: [0: 5])
        var chosen = input([claude, cursor])
        chosen.tools = [.cursor]
        #expect(ShareCard.content(chosen).rows.map(\.tool) == [.cursor])
        let available = ShareCard.available(providers: [claude, cursor], order: [.cursor, .claude, .codex, .antigravity, .copilot])
        #expect(available == [.cursor, .claude])
        chosen.tools = []
        let empty = ShareCard.content(chosen)
        #expect(empty.isEmpty)
        #expect(empty.rows.isEmpty)
        #expect(empty.advice == nil, "an empty card has nothing true to say")
        // Yesterday's spend alone: today's card is empty too.
        #expect(ShareCard.content(input([try provider(.claude, spend: [1: 10])], range: .today)).isEmpty)
    }

    @Test func theSignatureIsOneTrimmedLineOrNothing() {
        #expect(ShareCard.signature("  ") == nil)
        #expect(ShareCard.signature("@amir\nbuilds things ") == "@amir builds things")
        #expect(ShareCard.signature(String(repeating: "x", count: 60))?.count == ShareCard.signatureLimit)
        #expect(ShareCard.fileName(range: .thirtyDays, format: .feed) == "notchmeter-usage-30-days-feed.png")
        #expect(ShareCard.fileName(range: .month, format: .story) == "notchmeter-usage-this-month-story.png")
    }

    /// The caption is the picture in words: the same figures, the footnote and the site, and nothing the picture
    /// does not carry. The project every record names must reach neither, nor a model id.
    @Test func theCaptionRepeatsTheCardAndNeverAProject() throws {
        let claude = try provider(.claude, spend: [0: 100, 10: 100, 20: 100])
        let cursor = try provider(.cursor, spend: [0: 50])
        let content = ShareCard.content(input([claude, cursor], range: .thirtyDays, plans: [.claude: "Max 5x", .cursor: "Free"]))
        let caption = content.caption(calendar: utc)
        #expect(caption.hasPrefix("30 days (Aug 26"))
        #expect(caption.contains("Sep 24): $350 of API-equivalent value on the $100 Claude Max 5x plan · 3.5x"))
        #expect(caption.contains("Claude $300 · Cursor $50"))
        // Never "today": a card is read days after it is posted, so the day is named.
        #expect(caption.contains("Busiest day: Thursday, $150."))
        #expect(caption.contains("API-equivalent estimate, not a bill"))
        #expect(caption.hasSuffix("Measured with Notchmeter · https://notchmeter.com"))
        #expect(!caption.contains("secret-project"))
        #expect(!caption.contains("opus"))
    }
}

/// The one line under the figures: something that really happened in the span, or a plain fact about it, and
/// never a sentence the data does not support.
@Suite struct ShareCardAdviceLine {
    init() { Localization.use(language: "en") }

    /// A Thursday, so two days ago is Tuesday and three Monday.
    let now = DateParsing.iso8601("2026-09-24T15:00:00Z")!

    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    var today: Date { utc.startOfDay(for: now) }

    func provider(_ tool: ToolID, spend: [Int: Double], topModel: [Int: String] = [:]) throws -> ProviderCost {
        var days: [Date: CostHistory.Record] = [:]
        for (ago, cost) in spend {
            let day = try #require(utc.date(byAdding: .day, value: -ago, to: today))
            let model = topModel[ago] ?? "claude-opus-5"
            days[day] = CostHistory.Record(cost: cost, tokens: TokenBreakdown(input: Int(cost * 1000)), byModel: [model: cost], byProject: [:])
        }
        return try #require(ProviderCost.build(tool: tool, source: .localTranscripts, days: days, now: now, weekStart: today, calendar: utc, scannedAt: now))
    }

    /// Claude's Fable window and its weekly, as a reading carries them.
    var windows: [ToolID: [LimitWindow]] {
        [.claude: [
            LimitWindow(id: "scoped_fable", label: "Fable", usedFraction: 0.3, resetsAt: now.addingTimeInterval(86_400), periodDuration: Period.week, model: "Fable"),
            LimitWindow(id: "seven_day", label: .key("Weekly"), usedFraction: 0.5, resetsAt: now.addingTimeInterval(86_400), periodDuration: Period.week),
        ]]
    }

    /// The drain log's week for one window: quiet, then `peak` some days ago, then quiet again.
    func samples(_ window: String, peak: Double, daysAgo: Double) -> [DrainLog.Key: [DrainSample]] {
        [DrainLog.Key(tool: .claude, window: window): [
            DrainSample(t: now.addingTimeInterval(-6 * 86_400), used: 0.2, resetsAt: nil),
            DrainSample(t: now.addingTimeInterval(-daysAgo * 86_400), used: peak, resetsAt: nil),
            DrainSample(t: now, used: 0.3, resetsAt: nil),
        ]]
    }

    func input(_ providers: [ProviderCost], range: ShareCardRange = .sevenDays, samples: [DrainLog.Key: [DrainSample]] = [:],
               windows: [ToolID: [LimitWindow]]? = nil) -> ShareCard.Input {
        ShareCard.Input(providers: providers, order: ToolID.allCases, windows: windows ?? self.windows, samples: samples, range: range, now: now, calendar: utc)
    }

    @Test func aWindowThatReachedTheMarkInsideTheSpanIsTheLine() throws {
        let claude = try provider(.claude, spend: [0: 10, 1: 10, 2: 10])
        let made = input([claude], samples: samples("scoped_fable", peak: 0.91, daysAgo: 2))
        #expect(ShareCard.content(made).advice == "Claude Fable weekly peaked at 91% on Tuesday.")
        // The tool-wide weekly has no model, so its line names the window alone, lowercased inside the sentence
        // the way the Advisor's own lines name it.
        let weekly = input([claude], samples: samples("seven_day", peak: 0.88, daysAgo: 3))
        #expect(ShareCard.content(weekly).advice == "Claude weekly peaked at 88% on Monday.")
        // Older than a week, the day is dated rather than named.
        let old = input([try provider(.claude, spend: [0: 10, 20: 10])], range: .thirtyDays, samples: samples("scoped_fable", peak: 0.9, daysAgo: 20))
        #expect(ShareCard.content(old).advice == "Claude Fable weekly peaked at 90% on Sep 4.")
    }

    @Test func belowTheMarkTheLineIsTheBusiestDay() throws {
        let claude = try provider(.claude, spend: [0: 10, 1: 10, 2: 30])
        let made = input([claude], samples: samples("scoped_fable", peak: 0.6, daysAgo: 2))
        #expect(ShareCard.content(made).advice == "Busiest day: Tuesday, $30.")
        #expect(ShareCardAdvice.peakThreshold == Advisor.modelNearlyOut)
    }

    /// A peak from before the span, or on a window the reading no longer carries, is not this span's story.
    @Test func aPeakOutsideTheSpanOrOnAnUnknownWindowIsNotTold() throws {
        let claude = try provider(.claude, spend: [0: 10, 1: 10, 2: 10])
        let outside = input([claude], range: .today, samples: samples("scoped_fable", peak: 0.91, daysAgo: 2))
        #expect(ShareCard.content(outside).advice == nil, "one day, one assistant, no peak inside it: nothing to say")
        let unknown = input([claude], samples: samples("scoped_opus", peak: 0.95, daysAgo: 2))
        #expect(ShareCard.content(unknown).advice == "Busiest day: Tuesday, $10.", "a window with no name to give falls through")
        let noReading = input([claude], samples: samples("scoped_fable", peak: 0.95, daysAgo: 2), windows: [:])
        #expect(ShareCard.content(noReading).advice == "Busiest day: Tuesday, $10.")
    }

    @Test func aSingleDayWithTwoAssistantsSaysWhoLed() throws {
        let claude = try provider(.claude, spend: [0: 30])
        let cursor = try provider(.cursor, spend: [0: 10])
        #expect(ShareCard.content(input([claude, cursor], range: .today)).advice == "Claude was 75% of it.")
    }

    /// "Switched to …" is said only when the days say it plainly: the peak's model led up to the peak's day and
    /// never again after it.
    @Test func theSwitchIsSaidOnlyWhenTheDaysSayItPlainly() throws {
        let fable = "claude-fable-5-1", sonnet = "claude-sonnet-5"
        let switched = try provider(.claude, spend: [0: 10, 1: 10, 2: 10, 3: 10, 4: 10],
                                    topModel: [4: fable, 3: fable, 2: sonnet, 1: sonnet, 0: sonnet])
        let made = input([switched], samples: samples("scoped_fable", peak: 0.91, daysAgo: 3))
        #expect(ShareCard.content(made).advice == "Claude Fable weekly hit 91% on Monday; switched to Sonnet 5 after.")
        // Fable led again a day later: no switch happened, and none is claimed.
        let returned = try provider(.claude, spend: [0: 10, 1: 10, 2: 10, 3: 10, 4: 10],
                                    topModel: [4: fable, 3: fable, 2: sonnet, 1: fable, 0: sonnet])
        #expect(ShareCard.content(input([returned], samples: samples("scoped_fable", peak: 0.91, daysAgo: 3))).advice
            == "Claude Fable weekly peaked at 91% on Monday.")
        // The peak's model was not the one leading up to it: the days do not say it was Fable that ran out.
        let other = try provider(.claude, spend: [0: 10, 1: 10, 2: 10, 3: 10, 4: 10],
                                 topModel: [4: sonnet, 3: sonnet, 2: sonnet, 1: sonnet, 0: sonnet])
        #expect(ShareCard.content(input([other], samples: samples("scoped_fable", peak: 0.91, daysAgo: 3))).advice
            == "Claude Fable weekly peaked at 91% on Monday.")
        #expect(ShareCardAdvice.matches("claude-fable-5-1", "Fable"))
        #expect(!ShareCardAdvice.matches("claude-sonnet-5", "Fable"))
    }

    /// The fixtures' own week of the drain log (DemoFixtures.drainSamples) carries the Fable peak the rendered
    /// cards show, so the pictures are of a line the log really produces.
    @MainActor @Test func theFixturesWeekCarriesTheFablePeak() {
        let now = Date()
        let (store, _) = DemoFixtures.store(now: now)
        var made = store.shareCardInput(now: now)
        made.samples = DemoFixtures.drainSamples(now: now)
        let content = ShareCard.content(made)
        #expect(content.advice?.hasPrefix("Claude Fable weekly peaked at 91% on") == true, "\(content.advice ?? "nil")")
        #expect(content.rows.map(\.tool) == [.claude, .cursor])
        #expect(content.plan?.phrase == "on the $100 Claude Max 5x plan")
        // The Cost card's own line over the same store: a Today card stands its thirty days against the month's
        // fee, and hides the line with the rest of the figures while the screen is shared.
        let line = store.planValueLine(for: .today)
        #expect(line == "30 days: $7,326 of API-equivalent value on the $100 Claude Max 5x plan · 73x (estimate)")
        #expect(store.planValueLine(for: .month)?.hasPrefix("This month: ") == true)
        store.prefs.hideFromScreenShare = true
        store.setScreenCaptured(true)
        #expect(store.planValueLine(for: .today) == nil)
    }
}

/// The three grounds hold the same bar the rest of the app is held to: text at 4.5:1, every mark at 3:1.
@Suite struct ShareCardThemes {
    @Test func everyThemeHoldsTextAt45AndMarksAt3() {
        for theme in ShareCardTheme.allCases {
            #expect(ShareCardTheme.contrast(theme.primary, theme.background) >= 4.5, "\(theme) primary")
            #expect(ShareCardTheme.contrast(theme.secondary, theme.background) >= 4.5, "\(theme) secondary")
            #expect(ShareCardTheme.contrast(theme.badge, theme.background) >= 3, "\(theme) badge")
            #expect(ShareCardTheme.contrast(theme.onBadge, theme.badge) >= 4.5, "\(theme) text on the badge")
            for tool in ToolID.allCases {
                #expect(ShareCardTheme.contrast(theme.tool(tool), theme.background) >= 3, "\(theme) \(tool)")
            }
        }
        #expect(abs(ShareCardTheme.contrast(0xFFFFFF, 0x000000) - 21) < 0.01)
        #expect(ShareCardMetric.value.defaultTheme == .black)
        #expect(ShareCardMetric.tokens.defaultTheme == .blue)
        #expect(ShareCardFormat.feed.pixels.width == 1200 && ShareCardFormat.feed.pixels.height == 1500)
        #expect(ShareCardFormat.square.pixels.width == 1080 && ShareCardFormat.square.pixels.height == 1080)
        #expect(ShareCardFormat.story.pixels.width == 1080 && ShareCardFormat.story.pixels.height == 1920)
    }
}

/// When the app offers the card by itself: once per version, after an update, and only when it is safe and
/// worth it (ShareCardOffer).
@Suite struct ShareCardOfferRule {
    @Test func anUpdateIsAFirstLaunchOfANewVersionOnAnExistingInstall() {
        #expect(ShareCardOffer.updated(previous: "0.8.0", current: "0.9.0", existingInstall: true))
        #expect(!ShareCardOffer.updated(previous: "0.9.0", current: "0.9.0", existingInstall: true), "a relaunch")
        #expect(ShareCardOffer.updated(previous: nil, current: "0.9.0", existingInstall: true), "a copy from before the version was recorded")
        #expect(!ShareCardOffer.updated(previous: nil, current: "0.9.0", existingInstall: false), "a first install is not an update")
    }

    @Test func theOfferShowsOncePerVersionAndOnlyWhenItIsSafeAndWorthIt() {
        func decide(pending: String? = "0.9.0", enabled: Bool = true, showSpend: Bool = true, costReady: Bool = true, activeDays: Int = 7,
                    hidesFigures: Bool = false, fullScreen: Bool = false, busy: Bool = false) -> ShareCardOffer.Decision {
            ShareCardOffer.decide(pending: pending, current: "0.9.0", enabled: enabled, showSpend: showSpend, costReady: costReady,
                                  activeDays: activeDays, hidesFigures: hidesFigures, fullScreen: fullScreen, busy: busy)
        }
        #expect(decide() == .show)
        #expect(decide(pending: nil) == .drop, "already shown, or never an update")
        #expect(decide(pending: "0.8.0") == .drop, "an offer left over from another version")
        #expect(decide(enabled: false) == .drop)
        #expect(decide(showSpend: false) == .drop)
        #expect(decide(activeDays: 6) == .drop, "a quiet month is not a card anyone wants to post")
        // Not now, but not never: the same launch asks again shortly.
        #expect(decide(costReady: false) == .wait)
        #expect(decide(hidesFigures: true) == .wait)
        #expect(decide(fullScreen: true) == .wait)
        #expect(decide(busy: true) == .wait)
        #expect(ShareCardOffer.minimumActiveDays == 7)
        let daily = (0..<30).map { DailySpend(day: Date(timeIntervalSince1970: Double($0) * 86_400), cost: $0 % 4 == 0 ? 1 : 0, tokens: 0) }
        #expect(ShareCardOffer.activeDays(daily) == 8)
        #expect(ShareCardOffer.activeDays([DailySpend(day: Date(), cost: 0, tokens: 12)]) == 1, "tokens without a price still count as use")
    }
}
