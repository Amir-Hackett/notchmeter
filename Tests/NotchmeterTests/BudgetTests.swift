import Foundation
import Testing
@testable import Notchmeter

/// The spend budget as a window: the month's elapsed share, the Advisor's projection, the scheduler's stages over
/// it, and the extra-usage rule.
@Suite struct BudgetRules {
    init() { Localization.use(language: "en") }

    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 2026-09-16 12:00 UTC: halfway through September.
    let now = DateParsing.iso8601("2026-09-16T00:00:00Z")!

    func cost(month: Double, week: Double? = nil) -> CostSummary {
        CostSummary(today: 0, yesterday: 0, last30Days: 0, daily: [], lastHour: 0, typicalHourly: 0, burnMultiple: nil, unpricedModels: [], scannedAt: now,
                    ranges: [.month: RangeTotals(cost: month)], week: week.map { WeekCost(start: now.addingTimeInterval(-3 * 86400), cost: $0, perPercent: nil) })
    }

    @Test func theMonthIsAPeriodWithAnElapsedShare() {
        let period = BudgetPeriod.month(now: now, calendar: utc)
        #expect(period.start == DateParsing.iso8601("2026-09-01T00:00:00Z"))
        #expect(period.end == DateParsing.iso8601("2026-10-01T00:00:00Z"))
        #expect(period.elapsedFraction(now: now) == 0.5)
        #expect(period.elapsedFraction(now: period.start) == 0)
        #expect(period.elapsedFraction(now: period.end.addingTimeInterval(60)) == 1)
    }

    @Test func advisorProjectsTheMonthAgainstTheBudget() {
        var context = Advisor.Context(readings: [], cost: cost(month: 155), now: now, calendar: utc)
        context.monthlyBudgetUSD = 200
        #expect(Advisor.budget(context).map(\.text) == ["At this rate the month costs $310 against a $200 budget."])
        #expect(Advisor.budget(context).first?.priority == .warn)
        context.cost = cost(month: 90)
        #expect(Advisor.budget(context).isEmpty)
        context.cost = cost(month: 210)
        #expect(Advisor.budget(context).map(\.text) == ["The month's $210 is past the $200 budget."])
        #expect(Advisor.budget(context).first?.priority == .danger)
        context.monthlyBudgetUSD = nil
        context.weeklyBudgetUSD = 50
        context.cost = cost(month: 0, week: 30)
        // Three of seven days in at $30 projects to $70.
        #expect(Advisor.budget(context).map(\.text) == ["At this rate the week costs $70 against a $50 budget."])
        #expect(Advisor.budget(Advisor.Context(readings: [], cost: nil, now: now)).isEmpty)
    }

    @Test func theSchedulerTreatsTheBudgetAsAWindowWithTheMonthAsItsPeriod() throws {
        let reading = try #require(NotificationScheduler.budgetReading(cost: cost(month: 155), monthlyUSD: 200, weeklyUSD: nil, now: now, calendar: utc))
        let window = try #require(reading.windows.first)
        #expect(window.id == "budget_month")
        #expect(window.usedFraction == 0.775)
        #expect(window.resetsAt == DateParsing.iso8601("2026-10-01T00:00:00Z"))
        #expect(abs((window.periodDuration ?? 0) - 30 * 86400) < 1)
        #expect(window.source == .localEstimate)
        #expect(window.note == "$155 of $200")
        // 77.5 % halfway through projects to 155 %: behind, and the stage says so once per month.
        #expect(Pace.status(for: window, now: now) == .behind)
        let first = NotificationScheduler.plan(memory: .empty, readings: [reading], now: now)
        #expect(first.alerts.map(\.stage) == [.behind])
        #expect(first.alerts.first?.tool == .claude)
        #expect(NotificationScheduler.plan(memory: first.memory, readings: [reading], now: now.addingTimeInterval(3600)).alerts.isEmpty)
        let calm = try #require(NotificationScheduler.budgetReading(cost: cost(month: 60), monthlyUSD: 200, weeklyUSD: nil, now: now, calendar: utc))
        #expect(NotificationScheduler.plan(memory: .empty, readings: [calm], now: now).alerts.isEmpty)
        #expect(NotificationScheduler.budgetReading(cost: cost(month: 60), monthlyUSD: nil, weeklyUSD: nil, now: now, calendar: utc) == nil)
        #expect(Advisor.mainWindow(of: reading) == nil)
        let body = Advisor.alertBody(first.alerts[0], context: Advisor.Context(readings: [], timeFormat: .twentyFourHour, now: now, calendar: utc))
        #expect(body.hasPrefix("At this rate you hit the Claude monthly budget cap"))
        #expect(SettingsView.budgetUSD("150", rate: 1) == 150)
        #expect(SettingsView.budgetUSD("300", rate: 1.5) == 200)
        #expect(SettingsView.budgetUSD("", rate: 1) == nil)
        #expect(SettingsView.budgetUSD("-4", rate: 1) == nil)
    }

    @Test func extraUsageRisesAreSaidOnceAMonthAndLouderWhileThePlanHasRoom() {
        var context = Advisor.Context(readings: [], now: now)
        context.extraUsageRise = ExtraUsageRise(amountUSD: 4.2, over: 3600, planUsed: 0.13, firstThisMonth: true)
        let loud = Advisor.extraUsage(context)
        #expect(loud.map(\.text) == ["Extra usage rose $4.20 in 1h while your plan has 87% left; check /usage."])
        #expect(loud.first?.priority == .danger)
        #expect(loud.first?.url == ProviderLinks.usage(.claude))
        context.extraUsageRise = ExtraUsageRise(amountUSD: 4.2, over: 3600, planUsed: 0.95, firstThisMonth: true)
        let first = Advisor.extraUsage(context)
        #expect(first.map(\.text) == ["You are now paying: extra usage rose $4.20 this month."])
        #expect(first.first?.priority == .warn)
        context.extraUsageRise = ExtraUsageRise(amountUSD: 4.2, over: 3600, planUsed: 0.95, firstThisMonth: false)
        #expect(Advisor.extraUsage(context).isEmpty)
        context.extraUsageRise = nil
        #expect(Advisor.extraUsage(context).isEmpty)
        // The advice notifications fire once per repeat period, remembered by id.
        let planned = NotificationScheduler.planAdvice(memory: .empty, advice: loud, now: now) { _ in 3600 }
        #expect(planned.advice.map(\.id) == ["extra/room"])
        #expect(NotificationScheduler.planAdvice(memory: planned.memory, advice: loud, now: now.addingTimeInterval(600)) { _ in 3600 }.advice.isEmpty)
        #expect(NotificationScheduler.planAdvice(memory: planned.memory, advice: loud, now: now.addingTimeInterval(3601)) { _ in 3600 }.advice.count == 1)
        #expect(NotificationScheduler.planAdvice(memory: .empty, advice: loud, now: now) { _ in nil }.advice.isEmpty)
    }

    @Test func everyExtraUsageTransitionIsAppendedToTheDrainLogWithThePlanWindows() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-extra-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = DrainLog(url: dir.appendingPathComponent("drain.jsonl"))
        let plan = [LimitWindow(id: "five_hour", label: "Session", usedFraction: 0.12, resetsAt: now.addingTimeInterval(3600), periodDuration: Period.fiveHours),
                    LimitWindow(id: "seven_day", label: "Weekly", usedFraction: 0.13, resetsAt: now.addingTimeInterval(86400), periodDuration: Period.week)]
        log.appendExtraUsage(tool: .claude, amountUSD: 14.2, previousUSD: 10, planWindows: plan, now: now)
        let usage = UsageReading(tool: .claude, windows: plan, plan: nil, fetchedAt: now, observedAt: nil)
        log.append(usage, previous: [:], now: now.addingTimeInterval(60))
        let rows = log.loadExtraUsage()
        #expect(rows.count == 1)
        #expect(rows[0].amountUSD == 14.2)
        #expect(rows[0].previousUSD == 10)
        #expect(rows[0].planWindows == ["five_hour": 0.12, "seven_day": 0.13])
        let samples = log.load(now: now.addingTimeInterval(120))
        #expect(samples[DrainLog.Key(tool: .claude, window: "five_hour")]?.count == 1)
        #expect(samples[DrainLog.Key(tool: .claude, window: "extra_usage")] == nil)
        let text = try String(contentsOf: log.url, encoding: .utf8)
        #expect(text.contains("\"kind\":\"extra\""))
        #expect(!text.contains("token"))
    }
}
