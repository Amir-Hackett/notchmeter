import Foundation
import Testing
@testable import Notchmeter

/// A Claude login Anthropic answers with uncapped extra usage alone gets rings from its own spend history, and one
/// with any vendor figure is left exactly as it was (ClaudeProvider.withSpendRings).
@Suite struct ClaudeSpendRings {
    init() { Localization.use(language: "en") }

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 19))! }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
    }

    private func record(_ byModel: [String: Double]) -> CostHistory.Record {
        CostHistory.Record(cost: byModel.values.reduce(0, +), tokens: TokenBreakdown(), byModel: byModel, byProject: [:])
    }

    private var uncapped: LimitWindow {
        LimitWindow(id: "extra_usage", label: .key("Extra usage"), usedFraction: nil, resetsAt: nil, note: "$174.29 spent", amountUSD: 174.29)
    }

    private var history: [Date: CostHistory.Record] {
        [day(-3): record(["claude-opus-5-5": 40, "claude-fable-5-1": 10]),
         day(-2): record(["claude-opus-5-5": 60, "claude-fable-5-1": 20, "claude-sonnet-5-5": 1]),
         day(-1): record(["claude-opus-5-5": 50, "claude-haiku-5-5": 0.5, "<synthetic>": 0]),
         day(0): record(["claude-opus-5-5": 25, "claude-fable-5-1": 5])]
    }

    @Test func uncappedExtraUsageGetsTodaysSpendAndModelRings() {
        let windows = ClaudeProvider.withSpendRings([uncapped], days: history, now: now, calendar: calendar)
        #expect(windows.map(\.id) == ["spend_today", "spend_today_opus", "spend_today_fable", "spend_today_sonnet", "extra_usage"])

        let today = windows[0]
        // Usual day: median of 50, 81, 50.5 = 50.5; today 30.
        #expect(today.isComparison && !today.hiddenByDefault && today.source == .localEstimate)
        #expect(abs((today.usedFraction ?? 0) - 30 / 50.5) < 1e-9)
        #expect(today.amountUSD == 30)

        let opus = windows[1]
        #expect(opus.label == "Opus" && opus.hiddenByDefault && opus.isComparison)
        #expect(abs((opus.usedFraction ?? 0) - 0.5) < 1e-9) // 25 of a usual 50
        #expect(windows[2].label == "Fable" && abs((windows[2].usedFraction ?? 0) - 5.0 / 15) < 1e-9)
        #expect(windows[3].usedFraction == 0) // Sonnet spent nothing today
    }

    @Test func aVendorFigureIsLeftAlone() {
        let session = LimitWindow(id: "five_hour", label: .key("Session"), usedFraction: 0.2, resetsAt: nil)
        let windows = ClaudeProvider.withSpendRings([session, uncapped], days: history, now: now, calendar: calendar)
        #expect(windows.map(\.id) == ["five_hour", "extra_usage"])
        #expect(ClaudeProvider.historyDays(CostHistory(url: URL(fileURLWithPath: "/nonexistent/h.jsonl")), for: [session]).isEmpty)
    }

    @Test func noUsualDayLeavesTheReadingAsItWas() {
        let windows = ClaudeProvider.withSpendRings([uncapped], days: [day(0): record(["claude-opus-5-5": 9])], now: now, calendar: calendar)
        #expect(windows.map(\.id) == ["extra_usage"])
    }

    @Test func modelFamilies() {
        #expect(ClaudeProvider.modelFamily("claude-opus-5-5") == "Opus")
        #expect(ClaudeProvider.modelFamily("claude-fable-5-1") == "Fable")
        #expect(ClaudeProvider.modelFamily("claude-3-5-sonnet") == nil)
        #expect(ClaudeProvider.modelFamily("<synthetic>") == nil)
        #expect(ClaudeProvider.modelFamily("Other") == nil)
    }
}
