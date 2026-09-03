import Foundation

/// A run-out estimate as an interval rather than a point: the 20th and 80th percentile of the hourly drain rates
/// the log has seen for the window over the last seven days, in the same peak or off-peak state as now when
/// enough of those exist, give the latest and the earliest moment the window runs out at those rates. Shown as a
/// range when the two are more than fifteen minutes apart; notifications fire on the earliest edge. The method
/// and its limits are in docs/accuracy.md.
struct RunOutInterval: Equatable, Sendable {
    /// Seconds from now to the run-out at the fastest rate seen (the pessimistic edge).
    let earliest: TimeInterval
    /// Seconds from now at the slowest rate seen; may lie past the reset, in which case the window may last.
    let latest: TimeInterval
    let sampleCount: Int

    static let wideBeyond: TimeInterval = 900
    static let minimumSamples = 4
    static let lowerQuantile = 0.2
    static let upperQuantile = 0.8

    var isWide: Bool { latest - earliest > Self.wideBeyond }

    /// The measured hourly rates a window has moved at, one per pair of consecutive rows at least five minutes
    /// apart that share a reset, newest last.
    static func hourlyRates(_ samples: [DrainSample], since: Date) -> [(t: Date, perHour: Double)] {
        var rates: [(Date, Double)] = []
        for (previous, sample) in zip(samples, samples.dropFirst()) where sample.t >= since {
            guard ResetPeriod.same(sample.resetsAt, previous.resetsAt), sample.used >= previous.used else { continue }
            let hours = sample.t.timeIntervalSince(previous.t) / 3600
            guard hours >= 5.0 / 60 else { continue }
            let rate = (sample.used - previous.used) / hours
            if rate > 0 { rates.append((sample.t, rate)) }
        }
        return rates
    }

    static func quantile(_ sorted: [Double], _ q: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let position = q * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(sorted.count - 1, lower + 1)
        let fraction = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }

    static func estimate(samples: [DrainSample], usedFraction: Double, resetsAt: Date, now: Date, peak: PeakHours? = nil,
                         days: Int = 7) -> RunOutInterval? {
        guard usedFraction < 1, resetsAt > now else { return nil }
        let since = now.addingTimeInterval(-TimeInterval(days) * 86400)
        var rates = hourlyRates(samples, since: since)
        if let peak, peak.enabled {
            let state = peak.isPeak(at: now)
            let matching = rates.filter { peak.isPeak(at: $0.t) == state }
            if matching.count >= minimumSamples { rates = matching }
        }
        guard rates.count >= minimumSamples else { return nil }
        let sorted = rates.map(\.perHour).sorted()
        guard let slow = quantile(sorted, lowerQuantile), let fast = quantile(sorted, upperQuantile), slow > 0, fast > 0 else { return nil }
        let left = 1 - usedFraction
        return RunOutInterval(earliest: left / fast * 3600, latest: left / slow * 3600, sampleCount: rates.count)
    }

    /// "Runs out 2:10–3:40 PM" when wide, "Runs out in 2h" when narrow; nil when even the fastest rate lasts past the reset.
    func text(now: Date, resetsAt: Date, format: TimeFormatPreference, calendar: Calendar = .current) -> String? {
        guard now.addingTimeInterval(earliest) < resetsAt else { return nil }
        guard isWide else { return L("Runs out in %@", ResetText.duration((earliest + latest) / 2)) }
        let from = ResetText.time(now.addingTimeInterval(earliest), format: format, calendar: calendar)
        guard now.addingTimeInterval(latest) < resetsAt else { return L("Runs out from %@, or lasts to the reset", from) }
        let to = ResetText.time(now.addingTimeInterval(latest), format: format, calendar: calendar)
        return L("Runs out %1$@–%2$@", from, to)
    }
}

/// How heavily the session window is metered: tokens spent in the current 5-hour block per one per cent of the
/// window consumed, against the median of the last thirty days' figures, so "is Anthropic metering differently or
/// did my work change" has a number.
struct MeteringRatio: Equatable, Sendable {
    /// Tokens per one per cent of the session window, today.
    let tokensPerPercent: Double
    /// The 30-day median of the daily figure, when at least five days carry one.
    let median: Double?

    static let minimumUsed = 0.02
    static let minimumDays = 5
    /// Today metering at least this much heavier than the norm is worth a line.
    static let heavierBy = 2.0

    /// The block's tokens over the session's used share; nil until the window has moved at all.
    static func tokensPerPercent(blockTokens: Int, usedFraction: Double) -> Double? {
        guard usedFraction >= minimumUsed, blockTokens > 0 else { return nil }
        return Double(blockTokens) / (usedFraction * 100)
    }

    static func median(_ values: [Double]) -> Double? {
        let sorted = values.sorted()
        guard sorted.count >= minimumDays else { return nil }
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// How many times heavier than the norm today meters: 2.0 when today spends half the tokens per per cent.
    var multiple: Double? {
        guard let median, tokensPerPercent > 0 else { return nil }
        return median / tokensPerPercent
    }

    var isHeavier: Bool {
        (multiple ?? 0) >= Self.heavierBy
    }
}
