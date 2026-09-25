import Foundation
import Testing
@testable import Notchmeter

/// The usage dashboard's figures: the day grid under the bars, the tiles above them, and the per-day allowance
/// under each limit. Every number is a rearrangement of what the providers already hold, so the tests pin that
/// the dashboard neither loses a day nor invents one.
@Suite struct DashboardFigures {
    init() { Localization.use(language: "en") }

    let now = DateParsing.iso8601("2026-09-14T15:00:00Z")!

    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func day(_ offset: Int) -> Date {
        utc.date(byAdding: .day, value: offset, to: utc.startOfDay(for: now))!
    }

    func record(_ cost: Double, model: String = "claude-opus-5", project: String = "notchmeter") -> CostHistory.Record {
        CostHistory.Record(cost: cost, tokens: TokenBreakdown(input: Int(cost * 1000)), byModel: [model: cost], byProject: [project: cost])
    }

    func provider(_ tool: ToolID, source: CostSource, days: [Date: CostHistory.Record], weekStart: Date) -> ProviderCost {
        ProviderCost.build(tool: tool, source: source, days: days, now: now, weekStart: weekStart, calendar: utc, scannedAt: now)!
    }

    @Test func theWeekRunsFromTheWindowsStartDayToToday() {
        let weekStart = day(-3).addingTimeInterval(18 * 3600)
        let claude = provider(.claude, source: .localTranscripts, days: [day(-5): record(100), day(-3): record(40), day(-1): record(640), day(0): record(4)],
                              weekStart: weekStart)
        let model = DashboardModel(providers: [claude], range: .week, weekStart: weekStart, now: now, calendar: utc)
        let expectedDays = [day(-3), day(-2), day(-1), day(0)]
        #expect(model.days.map(\.day) == expectedDays)
        let expectedTotals: [Double] = [40, 0, 640, 4]
        #expect(model.days.map(\.total) == expectedTotals)
        #expect(model.peak?.day == day(-1))
        #expect(model.today == 4)
    }

    @Test func thirtyDaysIsThirtyBarsWithEmptyDaysKept() {
        let claude = provider(.claude, source: .localTranscripts, days: [day(-29): record(10), day(0): record(20)], weekStart: day(0))
        let model = DashboardModel(providers: [claude], range: .thirtyDays, weekStart: day(0), now: now, calendar: utc)
        #expect(model.days.count == 30)
        #expect(model.days.first?.day == day(-29))
        #expect(model.days.last?.day == day(0))
        #expect(model.total == 30)
        #expect(model.bars.count == 2)
    }

    @Test func barsStackEachAssistantInTheCarriedOrder() {
        let claude = provider(.claude, source: .localTranscripts, days: [day(0): record(6)], weekStart: day(0))
        let cursor = provider(.cursor, source: .billingExport, days: [day(0): record(3, model: "gpt-5.6"), day(-1): record(2, model: "gpt-5.6")],
                              weekStart: day(0))
        let model = DashboardModel(providers: [cursor, claude], range: .thirtyDays, weekStart: day(0), now: now, calendar: utc)
        let todayTools = model.days.last?.byTool.map(\.tool)
        #expect(todayTools == [.cursor, .claude])
        #expect(model.days.last?.total == 9)
        #expect(model.tools == [.cursor, .claude])
        let sources = model.sources.map(\.source)
        #expect(sources == [.billingExport, .localTranscripts])
    }

    @Test func theAverageStartsAtTheFirstDayWithSpend() {
        // Ninety days of range, but the history begins ten days ago: ten days averaged, not ninety.
        let claude = provider(.claude, source: .localTranscripts, days: [day(-9): record(50), day(-4): record(50)], weekStart: day(0))
        let model = DashboardModel(providers: [claude], range: .ninetyDays, weekStart: day(0), now: now, calendar: utc)
        #expect(model.days.count == 90)
        #expect(model.dailyAverage == 10)
    }

    @Test func totalsAndSharesAreTheProvidersOwnRangeFigures() {
        let claude = provider(.claude, source: .localTranscripts, days: [day(0): record(30, project: "a"), day(-1): record(10, model: "claude-fable-5-1", project: "b")],
                              weekStart: day(-1))
        let model = DashboardModel(providers: [claude], range: .week, weekStart: day(-1), now: now, calendar: utc)
        #expect(model.total == claude.totals(.week).cost)
        #expect(model.models.map(\.name) == ["claude-opus-5", "claude-fable-5-1"])
        #expect(model.projects.map(\.name) == ["a", "b"])
    }

    @Test func aQuietStretchInsideTheHistoryStillCountsTowardTheAverage() {
        // Spend sixty days ago, nothing from -29 to -10, then $100 a day: thirty calendar days, $1,000, $33.33 a day.
        var days: [Date: CostHistory.Record] = [day(-60): record(5)]
        for offset in -9...0 { days[day(offset)] = record(100) }
        let claude = provider(.claude, source: .localTranscripts, days: days, weekStart: day(0))
        let model = DashboardModel(providers: [claude], range: .thirtyDays, weekStart: day(0), now: now, calendar: utc)
        let average = model.dailyAverage ?? 0
        #expect(abs(average - 1000.0 / 30) < 0.001)
    }

    @Test func theWeeksFirstBarHoldsOnlyWhatWasSpentAfterTheWindowOpened() {
        // The window opened at 18:00 three days ago: $300 that day before 18:00 and $5 after, $20 the next day.
        let weekStart = day(-3).addingTimeInterval(18 * 3600)
        let daily = [DailySpend(day: day(-3), cost: 305, tokens: 0), DailySpend(day: day(-2), cost: 20, tokens: 0)]
        let claude = ProviderCost(tool: .claude, source: .localTranscripts, ranges: [.week: RangeTotals(cost: 25)], daily: daily, daily90: daily,
                                  scannedAt: now)
        let model = DashboardModel(providers: [claude], range: .week, weekStart: weekStart, now: now, calendar: utc)
        let firstBar = model.days.first?.total
        #expect(firstBar == 5)
        let barsTotal = model.days.reduce(0) { $0 + $1.total }
        #expect(barsTotal == model.total)
        #expect(model.peak?.total == 20)
    }

    @Test func daysMatchTheSeriesAcrossAMidnightDaylightSavingJump() throws {
        // America/Santiago moved its clocks from 00:00 to 01:00 on 2026-09-06, so that day starts at 01:00.
        var santiago = Calendar(identifier: .gregorian)
        santiago.timeZone = try #require(TimeZone(identifier: "America/Santiago"))
        let today = santiago.startOfDay(for: now)
        let start = try #require(santiago.date(byAdding: .day, value: -29, to: today))
        var days: [Date: CostHistory.Record] = [:]
        for offset in 0..<30 { days[try #require(santiago.date(byAdding: .day, value: offset, to: start))] = record(1) }
        let claude = try #require(ProviderCost.build(tool: .claude, source: .localTranscripts, days: days, now: now, weekStart: today,
                                                     calendar: santiago, scannedAt: now))
        let model = DashboardModel(providers: [claude], range: .thirtyDays, weekStart: today, now: now, calendar: santiago)
        let spentDays = model.days.filter { $0.total > 0 }.count
        #expect(spentDays == 30)
        #expect(model.days.last?.total == 1)
    }

    @Test func nothingSpentIsEmptyWithNoPeakOrAverage() {
        let model = DashboardModel(providers: [], range: .week, weekStart: day(-2), now: now, calendar: utc)
        #expect(model.isEmpty)
        #expect(model.peak == nil)
        #expect(model.dailyAverage == nil)
        #expect(model.days.count == 3)
    }

    // MARK: Limits

    func weekly(used: Double, resetsIn: TimeInterval) -> LimitWindow {
        LimitWindow(id: "seven_day", label: "Weekly", usedFraction: used, resetsAt: now.addingTimeInterval(resetsIn), periodDuration: Period.week)
    }

    @Test func theAllowanceSharesWhatIsLeftOverTheDaysToTheReset() throws {
        // 85% gone with three and a half days left: 15% over 3.5 days is about 4.3% a day.
        let limit = try #require(DashboardLimit(tool: .claude, window: weekly(used: 0.85, resetsIn: 3.5 * 86400), runOut: nil, format: .twelveHour, now: now))
        let allowance = try #require(limit.allowance)
        let expected = 0.15 / 3.5
        #expect(abs(allowance - expected) < 0.0001)
        #expect(limit.unit == .day)
        #expect(limit.allowanceLine == "About 4.3% a day lasts to the reset")
        #expect(limit.status == .behind)
        let elapsed = try #require(limit.elapsed)
        #expect(abs(elapsed - 0.5) < 0.0001)
    }

    @Test func aShortWindowIsBudgetedPerHour() throws {
        let session = LimitWindow(id: "five_hour", label: "Session", usedFraction: 0.4, resetsAt: now.addingTimeInterval(3 * 3600), periodDuration: Period.fiveHours)
        let limit = try #require(DashboardLimit(tool: .claude, window: session, runOut: nil, format: .twelveHour, now: now))
        #expect(limit.unit == .hour)
        #expect(limit.allowanceLine == "About 20% an hour lasts to the reset")
    }

    @Test func aSpentWindowSaysSoAndOffersNoAllowance() throws {
        let limit = try #require(DashboardLimit(tool: .claude, window: weekly(used: 1, resetsIn: 86400), runOut: nil, format: .twelveHour, now: now))
        #expect(limit.allowance == nil)
        #expect(limit.allowanceLine == "Used up until the reset")
    }

    @Test func aSpentWindowCarriesNoOverTheLimitWarning() throws {
        let limit = try #require(DashboardLimit(tool: .claude, window: weekly(used: 1, resetsIn: 3 * 86400), runOut: nil, format: .twelveHour, now: now))
        #expect(limit.status == .behind)
        #expect(limit.note == nil)
    }

    @Test func nearlyRunningOutIsSaidInWordsNotOnlyOrange() throws {
        // 60% used with 65% of the week gone projects to about 92%: on track, inside the last tenth.
        let limit = try #require(DashboardLimit(tool: .claude, window: weekly(used: 0.6, resetsIn: 0.35 * Period.week), runOut: nil,
                                                format: .twelveHour, now: now))
        #expect(limit.status == .onTrack)
        #expect(limit.note != nil)
    }

    @Test func aReadingWhoseResetHasPassedIsNotShownAsALimit() {
        let expired = weekly(used: 1, resetsIn: -6 * 3600)
        #expect(DashboardLimit(tool: .claude, window: expired, runOut: nil, format: .twelveHour, now: now) == nil)
    }

    @Test func aCachedReadingSaysItMayBeOutOfDate() throws {
        let fetched = now.addingTimeInterval(-2 * 3600)
        let limit = try #require(DashboardLimit(tool: .claude, window: weekly(used: 0.4, resetsIn: 86400), runOut: nil, format: .twelveHour,
                                                staleSince: fetched, now: now))
        let line = try #require(limit.staleLine)
        #expect(line.contains("may be out of date"))
    }

    @Test func aWeekStartFromAPassedResetIsCarriedForward() {
        // The cached reset was four days ago; the live window is the one that opened then, not the one before it.
        let passed = now.addingTimeInterval(-4 * 86400)
        let start = CostEngine.weekStart(weeklyResetsAt: passed, now: now, calendar: utc)
        #expect(start == passed)
        let live = now.addingTimeInterval(3 * 86400)
        let liveStart = CostEngine.weekStart(weeklyResetsAt: live, now: now, calendar: utc)
        #expect(liveStart == live.addingTimeInterval(-Period.week))
        let longAgo = now.addingTimeInterval(-15 * 86400)
        let longAgoStart = CostEngine.weekStart(weeklyResetsAt: longAgo, now: now, calendar: utc)
        #expect(longAgoStart == longAgo.addingTimeInterval(2 * Period.week))
    }

    @Test func aWindowWithNoFractionIsNotALimit() {
        let unmetered = LimitWindow(id: "included", label: "Included usage", usedFraction: nil, resetsAt: nil)
        #expect(DashboardLimit(tool: .cursor, window: unmetered, runOut: nil, format: .twelveHour, now: now) == nil)
    }

    @Test func theLastHourBeforeTheResetIsNotDividedByLessThanOne() throws {
        let limit = try #require(DashboardLimit(tool: .claude, window: weekly(used: 0.5, resetsIn: 600), runOut: nil, format: .twelveHour, now: now))
        #expect(limit.allowance == 0.5)
        #expect(limit.allowanceLine == "50% left to the reset", "Less than an hour left is not a rate per hour")
    }

    @Test func theAverageNamesItsFirstDayWhenTheHistoryStartsInsideTheRange() {
        let claude = provider(.claude, source: .localTranscripts, days: [day(-9): record(50), day(-4): record(50)], weekStart: day(0))
        let ninety = DashboardModel(providers: [claude], range: .ninetyDays, weekStart: day(0), now: now, calendar: utc)
        #expect(ninety.averageSince == day(-9))
        let old = provider(.claude, source: .localTranscripts, days: [day(-60): record(5), day(0): record(5)], weekStart: day(0))
        let thirty = DashboardModel(providers: [old], range: .thirtyDays, weekStart: day(0), now: now, calendar: utc)
        #expect(thirty.averageSince == nil, "History older than the range: the average covers every day of it")
    }

    @Test func theDashboardHoldsThePanelLikeSettings() {
        var holds = PanelHolds()
        var changed = holds.set(.dashboard, true)
        #expect(changed)
        changed = holds.set(.settings, true)
        #expect(changed == false)
        changed = holds.set(.dashboard, false)
        #expect(changed == false)
        #expect(holds.isHeld)
    }
}

/// The second review's fixes outside the dashboard itself: the panel's pace note on a spent window, the weekly used
/// fraction from a reading whose reset has passed, and the average across a break longer than the series.
@Suite struct DashboardFollowUps {
    init() { Localization.use(language: "en") }

    let now = DateParsing.iso8601("2026-09-14T15:00:00Z")!

    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func aSpentWindowHasNoPaceNoteOnThePanelEither() {
        let spent = LimitWindow(id: "scoped_fable", label: "Fable", usedFraction: 1, resetsAt: now.addingTimeInterval(3 * 86400), periodDuration: Period.week)
        #expect(Pace.note(for: spent, now: now) == nil)
        let nearly = LimitWindow(id: "seven_day", label: "Weekly", usedFraction: 0.9, resetsAt: now.addingTimeInterval(3 * 86400), periodDuration: Period.week)
        #expect(Pace.note(for: nearly, now: now) != nil)
    }

    @Test func aFirstRecordedDayBeforeTheSeriesKeepsQuietDaysInTheAverage() {
        // A year of history, a four-month break, ten days of $100: thirty calendar days, not ten.
        let today = utc.startOfDay(for: now)
        var days: [Date: CostHistory.Record] = [:]
        for offset in -9...0 {
            days[utc.date(byAdding: .day, value: offset, to: today)!] = CostHistory.Record(cost: 100, tokens: TokenBreakdown(), byModel: [:], byProject: [:])
        }
        let claude = ProviderCost.build(tool: .claude, source: .localTranscripts, days: days, now: now, weekStart: today, calendar: utc, scannedAt: now)!
        let firstRecorded = utc.date(byAdding: .day, value: -365, to: today)!
        let model = DashboardModel(providers: [claude], range: .thirtyDays, weekStart: today, firstRecorded: firstRecorded, now: now, calendar: utc)
        let average = model.dailyAverage ?? 0
        #expect(abs(average - 1000.0 / 30) < 0.001)
    }

    @Test func theWeeksClippedFirstDayIsMarkedPartial() {
        let today = utc.startOfDay(for: now)
        let daily = [DailySpend(day: today, cost: 300, tokens: 0)]
        let claude = ProviderCost(tool: .claude, source: .localTranscripts, ranges: [.week: RangeTotals(cost: 4), .today: RangeTotals(cost: 300)],
                                  daily: daily, daily90: daily, scannedAt: now)
        let model = DashboardModel(providers: [claude], range: .week, weekStart: today.addingTimeInterval(14 * 3600), now: now, calendar: utc)
        #expect(model.days.first?.partial == true)
        #expect(model.days.first?.total == 4)
        #expect(model.today == 300)
    }
}

/// How the dashboard presents its figures: the hero's wording, which assistant a model row is coloured for, the
/// accent the project rows take (the theme's, never the system's), and the pin under the chart.
@Suite struct DashboardPresentation {
    init() { Localization.use(language: "en") }

    let now = DateParsing.iso8601("2026-09-14T15:00:00Z")!

    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func day(_ offset: Int) -> Date {
        utc.date(byAdding: .day, value: offset, to: utc.startOfDay(for: now))!
    }

    func record(_ cost: Double, model: String = "claude-opus-5", project: String = "notchmeter") -> CostHistory.Record {
        CostHistory.Record(cost: cost, tokens: TokenBreakdown(input: Int(cost * 1000)), byModel: [model: cost], byProject: [project: cost])
    }

    func provider(_ tool: ToolID, source: CostSource, days: [Date: CostHistory.Record]) -> ProviderCost {
        ProviderCost.build(tool: tool, source: source, days: days, now: now, weekStart: day(-3), calendar: utc, scannedAt: now)!
    }

    // MARK: Colour

    @Test func aModelRowIsColouredForTheAssistantThatSpentMostOnIt() {
        // Cursor's export names gpt-5.6 and, for $2, the same Sonnet Claude Code spent $60 on.
        let claude = provider(.claude, source: .localTranscripts, days: [day(0): record(60, model: "claude-sonnet-5"), day(-1): record(40)])
        let cursor = provider(.cursor, source: .billingExport, days: [day(0): record(30, model: "gpt-5.6"), day(-1): record(2, model: "claude-sonnet-5")])
        let model = DashboardModel(providers: [claude, cursor], range: .thirtyDays, weekStart: day(-3), now: now, calendar: utc)
        #expect(model.tool(ofModel: "claude-opus-5") == .claude)
        #expect(model.tool(ofModel: "gpt-5.6") == .cursor)
        #expect(model.tool(ofModel: "claude-sonnet-5") == .claude, "the bigger spender owns a name both used")
        #expect(model.tool(ofModel: CostShare.other) == nil, "Other is nobody's and draws neutral")
        #expect(model.tool(ofModel: "never-used") == nil)
    }

    /// The accent on the dashboard is the one chosen under Settings › Appearance › Theme, resolved as the panel
    /// resolves it: its black-panel value under Dark, its Paper value under Light, the lifted or darkened one under
    /// Increase Contrast. Each reads at 3:1 as a mark against the window it is drawn on, and at 4.5:1 as the pin's
    /// symbol, which is drawn in the text role.
    @Test func theAccentIsTheThemesAndReadsOnEitherWindow() {
        for accent in PanelAccent.allCases {
            for contrast in [false, true] {
                let dark = DashboardLook.accent(dark: true, accent: accent, contrast: contrast)
                let light = DashboardLook.accent(dark: false, accent: accent, contrast: contrast)
                #expect(dark == (contrast ? accent.onBlackContrast : accent.onBlack), "\(accent) under Dark")
                #expect(light == (contrast ? accent.onPaperContrast : accent.onPaper), "\(accent) under Light")
                let minimumMark = 3.0
                let olderLightWindow = RGB(hex: 0xECECEC)
                #expect(dark.contrast(DashboardLook.darkWindow) >= minimumMark, "\(accent) on the dark window")
                #expect(light.contrast(DashboardLook.lightWindow) >= minimumMark, "\(accent) on the light window")
                #expect(light.contrast(olderLightWindow) >= minimumMark, "\(accent) on an older release's grey window")
                let minimumText = 4.5
                let darkText = DashboardLook.pin(dark: true, accent: accent, contrast: contrast)
                let lightText = DashboardLook.pin(dark: false, accent: accent, contrast: contrast)
                #expect(darkText.contrast(DashboardLook.darkWindow) >= minimumText, "\(accent) as the pin on the dark window")
                #expect(lightText.contrast(DashboardLook.lightWindow) >= minimumText, "\(accent) as the pin on the light window")
            }
        }
        #expect(DashboardLook.look(dark: true, accent: .teal, contrast: false).theme == .black)
        #expect(DashboardLook.look(dark: false, accent: .teal, contrast: false).theme == .paper)
        #expect(DashboardLook.look(dark: false, accent: .lilac, contrast: true).contrast)
    }

    /// The bars are drawn at full strength whatever day is chosen (a pin once dimmed the other days to 0.45, which
    /// put Claude at 2.0:1 and Cursor at 1.9:1 on either window), so the contrast a bar is read at is its colour's
    /// own against the window it is on, and every assistant's clears the 3:1 a mark owes there.
    @Test func everyAssistantsBarsReadOnEitherWindow() {
        let minimumMark = 3.0
        for tool in ToolID.allCases {
            #expect(tool.chartInk(dark: true).contrast(DashboardLook.darkWindow) >= minimumMark, "\(tool) on the dark window")
            #expect(tool.chartInk(dark: false).contrast(DashboardLook.lightWindow) >= minimumMark, "\(tool) on the light window")
        }
    }

    /// The status colours on the limits card are held to the window's own grounds, not the panel's: the black
    /// look's vermillion passes as text on black (5.4:1) and so the panel leaves it, but the dark window is #1E1E1E
    /// (4.3:1) and a card's box on it #2E2E2E (3.5:1), both under the 4.5:1 words owe. Measured in both roles on
    /// both windows and both card boxes, with and without Increase Contrast.
    @Test func theStatusColoursReadOnEitherWindowAndItsCards() {
        #expect(DashboardLook.box(dark: true, contrast: false).description == "#2E2E2E", "the card box the dark render measured")
        for dark in [true, false] {
            for contrast in [false, true] {
                let window = DashboardLook.window(dark: dark)
                let box = DashboardLook.box(dark: dark, contrast: contrast)
                for name in [PanelInk.danger, .warn] {
                    let text = DashboardLook.status(name, role: .text, dark: dark, contrast: contrast)
                    let mark = DashboardLook.status(name, role: .mark, dark: dark, contrast: contrast)
                    let pairing = "\(name) \(dark ? "dark" : "light")\(contrast ? " contrast" : "")"
                    #expect(text.contrast(window) >= 4.5, "\(pairing) as text on the window")
                    #expect(text.contrast(box) >= 4.5, "\(pairing) as text on the card box")
                    #expect(mark.contrast(window) >= 3, "\(pairing) as a mark on the window")
                    #expect(mark.contrast(box) >= 3, "\(pairing) as a mark on the card box")
                }
            }
        }
        let panels = PanelInk.danger.onBlack
        let lifted = DashboardLook.status(.danger, role: .text, dark: true, contrast: false)
        #expect(lifted != panels, "the dark window's vermillion is lifted from the panel's, which reads 4.3:1 there")
        #expect(lifted.contrast(panels) < 2, "and lifted in lightness alone, so it is still the vermillion")
    }

    /// The system accent is the one colour on the Mac that says nothing about this app, and the audit of the 0.9.0
    /// render found it on the breakdown's bars: the only blue on the page, and a blue the panel never draws.
    @Test func nothingOnTheDashboardIsDrawnInTheSystemAccent() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Notchmeter/Dashboard.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(!text.contains("accentColor"), "Dashboard.swift draws Color.accentColor")
        #expect(!text.contains("controlAccentColor"), "Dashboard.swift draws NSColor.controlAccentColor")
    }

    // MARK: The pin

    @Test func aClickPinsADayAndASecondClickLetsItGo() {
        var selection = DashboardSelection(calendar: utc)
        #expect(selection.shown == nil)
        selection.hover(day(-1), inside: true)
        #expect(selection.shown == day(-1), "a hover previews")
        #expect(selection.isPinned == false)
        let pinned = selection.click(day(-2))
        #expect(pinned)
        #expect(selection.shown == day(-2), "the pin outranks the pointer")
        selection.hover(day(0), inside: true)
        #expect(selection.shown == day(-2), "a hover never moves a pin")
        selection.hover(day(0), inside: false)
        let again = selection.click(day(-2).addingTimeInterval(3600))
        #expect(again == false, "a click on the pinned day, at any hour of it, unpins")
        #expect(selection.isPinned == false)
        #expect(selection.shown == nil)
    }

    @Test func aLeaveClearsOnlyItsOwnDaysPreview() {
        // The pointer crossing from Monday's slot into Tuesday's: Tuesday's enter can land before Monday's leave.
        var selection = DashboardSelection(calendar: utc)
        selection.hover(day(-1), inside: true)
        selection.hover(day(0), inside: true)
        selection.hover(day(-1), inside: false)
        #expect(selection.shown == day(0))
        selection.hover(day(0), inside: false)
        #expect(selection.shown == nil)
    }

    @Test func escapeUnpinsAndTheHoverShowsAgain() {
        var selection = DashboardSelection(calendar: utc)
        selection.click(day(-1))
        selection.hover(day(0), inside: true)
        selection.unpin()
        #expect(selection.isPinned == false)
        #expect(selection.shown == day(0), "with the pin gone, the day under the pointer is back")
    }

    /// A change of range rebuilds the chart, and the old range's slots go without reporting the pointer's leave:
    /// the preview is let go with the pin, or the line under the chart would name a day the pointer has left.
    @Test func aChangeOfRangeLetsThePreviewGoWithThePin() {
        var selection = DashboardSelection(calendar: utc)
        selection.hover(day(-1), inside: true)
        selection.click(day(-2))
        selection.unpin()
        selection.clearHover()
        #expect(selection.isPinned == false)
        #expect(selection.shown == nil, "neither the pin nor the day the pointer was over")
    }

    /// A day's slot is one VoiceOver element whose label is the day and whose value is the figures, so the day is
    /// spoken once; the line under the chart is the one that carries both.
    @Test func aSlotSpeaksItsDayOnceAndItsFiguresAsTheValue() throws {
        let claude = provider(.claude, source: .localTranscripts, days: [day(0): record(60)])
        let cursor = provider(.cursor, source: .billingExport, days: [day(0): record(30, model: "gpt-5.6")])
        let model = DashboardModel(providers: [claude, cursor], range: .week, weekStart: day(-3), now: now, calendar: utc)
        let today = try #require(model.days.last)
        let phrase = ResetText.dayPhrase(today.day, now: now, calendar: utc)
        let figures = DashboardView.dayFigures(today)
        #expect(figures == "$90.00 · \(ToolID.claude.displayName) $60.00 · \(ToolID.cursor.displayName) $30.00")
        #expect(!figures.hasPrefix(phrase), "the value does not start with the label")
        #expect(DashboardView.dayLine(today, now: now, calendar: utc) == "\(phrase) · \(figures)")
        let spoken = Spoken.line("Pinned", figures)
        #expect(spoken.hasPrefix("Pinned, $90.00"), "pinned, then the figures, and no day: \(spoken)")
    }

    @Test func thePinnedDayIsMatchedByCalendarDayInTheModel() {
        let claude = provider(.claude, source: .localTranscripts, days: [day(-1): record(40), day(0): record(4)])
        let model = DashboardModel(providers: [claude], range: .week, weekStart: day(-3), now: now, calendar: utc)
        #expect(model.day(day(-1).addingTimeInterval(5 * 3600), calendar: utc)?.total == 40)
        #expect(model.day(nil, calendar: utc) == nil)
        #expect(model.day(day(-40), calendar: utc) == nil, "a day outside the range shows nothing")
    }

    @Test func aPinWhoseDayHasLeftTheRangeIsNoPinAndTheHoverShows() {
        let claude = provider(.claude, source: .localTranscripts, days: [day(-1): record(40), day(0): record(4)])
        let model = DashboardModel(providers: [claude], range: .week, weekStart: day(-3), now: now, calendar: utc)
        var selection = DashboardSelection(calendar: utc)
        selection.click(day(-1))
        #expect(selection.resolved(in: model).isPinned, "a pinned day in the range is a pin")
        #expect(selection.resolved(in: model).day?.total == 40)
        // The range moved on while the window was open: the pinned date is no longer one of its days.
        selection.click(day(-40))
        selection.hover(day(0), inside: true)
        let resolved = selection.resolved(in: model)
        #expect(selection.isPinned, "the stale date is still held")
        #expect(!resolved.isPinned, "but it is not shown as a pin")
        #expect(resolved.day?.total == 4, "and the hovered day shows instead of nothing")
    }

    // MARK: The hero

    @Test func theHeroPrintsTheTotalTheRangeAndTheValueLine() {
        // Spend on the week's first day, so the average covers every calendar day of the range and needs no date.
        let claude = provider(.claude, source: .localTranscripts, days: [day(-3): record(300), day(-1): record(400.4), day(0): record(40)])
        let model = DashboardModel(providers: [claude], range: .week, weekStart: day(-3), now: now, calendar: utc)
        let value = "30 days: $412 of API-equivalent value on the $200 Claude Max 20x plan · 2.1x (estimate)"
        let figures = DashboardHero(model: model, valueLine: value, now: now, calendar: utc)
        #expect(figures.total == "$740")
        #expect(figures.range == "This week")
        #expect(figures.value?.hasSuffix("(estimate)") == true, "the estimate stays marked")
        #expect(figures.value?.contains("API\u{2011}equivalent") == true, "the hyphen is kept whole so the line wraps between words")
        #expect(figures.average.title == "Daily average")
        #expect(figures.average.value == "$185")
        #expect(figures.average.caption == "per calendar day")
        #expect(figures.peak.title == "Peak day")
        #expect(figures.peak.value == "$400")
        #expect(figures.peak.caption == "yesterday")
        #expect(figures.today.title == "Today")
        #expect(figures.today.value == "$40")
        #expect(figures.today.caption.isEmpty)
    }

    @Test func theHeroSaysNothingWhereThereIsNoValueLineOrPeak() {
        let model = DashboardModel(providers: [], range: .ninetyDays, weekStart: day(-3), now: now, calendar: utc)
        let figures = DashboardHero(model: model, valueLine: nil, now: now, calendar: utc)
        #expect(figures.total == "$0")
        #expect(figures.range == "90 days")
        #expect(figures.value == nil)
        #expect(figures.average.value == "—")
        #expect(figures.peak.value == "—")
        #expect(figures.peak.caption.isEmpty)
    }
}
