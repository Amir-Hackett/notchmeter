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
