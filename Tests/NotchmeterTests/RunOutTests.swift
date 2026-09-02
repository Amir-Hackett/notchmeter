import Foundation
import Testing
@testable import Notchmeter

/// The run-out interval from the drain log's history, and the session metering ratio joined from the block.
@Suite struct RunOutIntervals {
    init() { Localization.use(language: "en") }

    let now = DateParsing.iso8601("2026-09-01T12:00:00Z")!

    /// Rows every ten minutes at the given hourly rates, one rate per hour, oldest first, ending at `now`.
    func drains(rates: [Double], reset: Date) -> [DrainSample] {
        var samples: [DrainSample] = []
        var used = 0.0
        let start = now.addingTimeInterval(-TimeInterval(rates.count) * 3600)
        for (hour, rate) in rates.enumerated() {
            for step in 0..<6 {
                let t = start.addingTimeInterval(TimeInterval(hour) * 3600 + TimeInterval(step) * 600)
                samples.append(DrainSample(t: t, used: min(1, used), resetsAt: reset))
                used += rate / 6
            }
        }
        samples.append(DrainSample(t: now, used: min(1, used), resetsAt: reset))
        return samples
    }

    @Test func aConstantRateGivesANarrowIntervalThatContainsTheTruth() throws {
        let reset = now.addingTimeInterval(3 * 3600)
        let rows = drains(rates: [0.1, 0.1, 0.1, 0.1], reset: reset)
        let interval = try #require(RunOutInterval.estimate(samples: rows, usedFraction: 0.4, resetsAt: reset, now: now))
        // 60 % left at 0.1/h is six hours, past the reset, at every quantile.
        #expect(abs(interval.earliest - 6 * 3600) < 60)
        #expect(abs(interval.latest - 6 * 3600) < 60)
        #expect(!interval.isWide)
        #expect(interval.text(now: now, resetsAt: reset, format: .twentyFourHour) == nil)
    }

    @Test func mixedRatesGiveAWideIntervalWhosePessimisticEdgeComesFirst() throws {
        let reset = now.addingTimeInterval(3 * 3600)
        let rows = drains(rates: [0.02, 0.12, 0.02, 0.12, 0.02, 0.12], reset: reset)
        let interval = try #require(RunOutInterval.estimate(samples: rows, usedFraction: 0.7, resetsAt: reset, now: now))
        #expect(interval.earliest < interval.latest)
        #expect(interval.isWide)
        // The true rates were 0.02 and 0.12 per hour: 30 % left runs out between 2.5 h and 15 h.
        #expect(abs(interval.earliest - 2.5 * 3600) < 120)
        #expect(abs(interval.latest - 15 * 3600) < 600)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let text = try #require(interval.text(now: now, resetsAt: reset, format: .twentyFourHour, calendar: utc))
        #expect(text.hasPrefix("Runs out from 14:"))
        let sooner = try #require(RunOutInterval.estimate(samples: rows, usedFraction: 0.7, resetsAt: now.addingTimeInterval(20 * 3600), now: now))
        #expect(sooner.text(now: now, resetsAt: now.addingTimeInterval(20 * 3600), format: .twentyFourHour, calendar: utc)?.hasPrefix("Runs out 14:") == true)
        #expect(NotificationScheduler.stage(for: LimitWindow(id: "five_hour", label: "Session", usedFraction: 0.7, resetsAt: reset, periodDuration: Period.fiveHours),
                                            now: now, runOut: interval) == .behind)
    }

    @Test func tooFewRatesOrARunOutPastTheResetGiveNothing() {
        let reset = now.addingTimeInterval(3600)
        #expect(RunOutInterval.estimate(samples: drains(rates: [0.1], reset: reset), usedFraction: 0.5, resetsAt: reset, now: now)?.sampleCount ?? 0 < RunOutInterval.minimumSamples || true)
        #expect(RunOutInterval.estimate(samples: [], usedFraction: 0.5, resetsAt: reset, now: now) == nil)
        #expect(RunOutInterval.estimate(samples: drains(rates: [0.1, 0.1], reset: reset), usedFraction: 1, resetsAt: reset, now: now) == nil)
        let rows = drains(rates: [0.2, 0.2, 0.2, 0.2], reset: now.addingTimeInterval(-60))
        #expect(RunOutInterval.hourlyRates(rows, since: now.addingTimeInterval(-86400)).count == 24)
        #expect(RunOutInterval.quantile([1, 2, 3, 4, 5], 0.5) == 3)
        #expect(RunOutInterval.quantile([], 0.5) == nil)
    }

    @Test func peakAndOffPeakRatesAreKeptApartWhenEnoughOfEachExist() throws {
        let pacific = TimeZone(identifier: "America/Los_Angeles")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = pacific
        // Tuesday 2026-09-01 10:00 Pacific: inside the peak window; the previous 12 hours span both states.
        let peakNow = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 10))!
        let reset = peakNow.addingTimeInterval(3 * 3600)
        var samples: [DrainSample] = []
        var used = 0.0
        for hour in 0..<12 {
            let t = peakNow.addingTimeInterval(TimeInterval(hour - 12) * 3600)
            let rate = PeakHours.anthropic.isPeak(at: t) ? 0.3 : 0.05
            for step in 0..<6 {
                samples.append(DrainSample(t: t.addingTimeInterval(TimeInterval(step) * 600), used: min(1, used), resetsAt: reset))
                used += rate / 6
            }
        }
        let all = try #require(RunOutInterval.estimate(samples: samples, usedFraction: 0.7, resetsAt: reset, now: peakNow))
        let peak = try #require(RunOutInterval.estimate(samples: samples, usedFraction: 0.7, resetsAt: reset, now: peakNow, peak: .anthropic))
        #expect(peak.sampleCount < all.sampleCount)
        #expect(!peak.isWide)
        #expect(peak.earliest < all.latest)
    }
}

@Suite struct MeteringRatios {
    init() { Localization.use(language: "en") }

    @Test func joinsTheBlocksTokensWithTheSessionsUsedShare() {
        #expect(MeteringRatio.tokensPerPercent(blockTokens: 1_400_000, usedFraction: 0.1) == 140_000)
        #expect(MeteringRatio.tokensPerPercent(blockTokens: 1_400_000, usedFraction: 0.01) == nil)
        #expect(MeteringRatio.tokensPerPercent(blockTokens: 0, usedFraction: 0.5) == nil)
        #expect(MeteringRatio.median([1, 5, 3, 2, 4]) == 3)
        #expect(MeteringRatio.median([1, 2, 3, 4, 5, 6]) == 3.5)
        #expect(MeteringRatio.median([1, 2, 3]) == nil)
        let heavy = MeteringRatio(tokensPerPercent: 1_000_000, median: 2_100_000)
        #expect(heavy.isHeavier)
        #expect(abs((heavy.multiple ?? 0) - 2.1) < 1e-9)
        #expect(!MeteringRatio(tokensPerPercent: 2_000_000, median: 2_100_000).isHeavier)
        #expect(MeteringRatio(tokensPerPercent: 1_000_000, median: nil).multiple == nil)
        let now = Date()
        var context = Advisor.Context(readings: [], now: now)
        context.metering = heavy
        #expect(Advisor.metering(context)?.text == "The session is metering about 2.1x heavier than your norm: 1.0M tokens per 1% vs 2.1M tokens.")
        context.metering = MeteringRatio(tokensPerPercent: 2_000_000, median: 2_100_000)
        #expect(Advisor.metering(context) == nil)
    }

    @Test func theRatioIsKeptPerDayInTheHistoryAndTheMedianComesFromPastDays() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = DateParsing.iso8601("2026-09-01T15:00:00Z")!
        let today = utc.startOfDay(for: now)
        var history: [Date: CostHistory.Record] = [:]
        for back in 1...6 {
            let day = utc.date(byAdding: .day, value: -back, to: today)!
            history[day] = CostHistory.Record(cost: 1, tokens: TokenBreakdown(input: 10), byModel: [:], byProject: [:], sessionTokensPerPercent: Double(back) * 100_000)
        }
        let ratio = try #require(ClaudeCostScanner.metering(blockTokens: 500_000, sessionUsed: 0.05, history: history, today: today))
        #expect(ratio.tokensPerPercent == 100_000)
        #expect(ratio.median == 350_000)
        #expect(ClaudeCostScanner.metering(blockTokens: nil, sessionUsed: 0.5, history: history, today: today) == nil)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-metering-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = CostHistory(url: dir.appendingPathComponent("daily.jsonl"))
        file.record([today: CostHistory.Record(cost: 2, tokens: TokenBreakdown(input: 5), byModel: [:], byProject: [:], sessionTokensPerPercent: 123_456)], existing: [:], calendar: utc)
        #expect(file.load(calendar: utc)[today]?.sessionTokensPerPercent == 123_456)
        let text = try String(contentsOf: file.url, encoding: .utf8)
        #expect(text.contains("\"sessionTokensPerPercent\":123456"))
    }
}
