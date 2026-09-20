import Foundation

/// A run-out estimate as an interval rather than a point: the 20th and 80th percentile of the hourly drain rates
/// the log has seen for the window over the last seven days, in the same peak or off-peak state as now when
/// enough of those exist, give the latest and the earliest moment the window runs out at those rates. How the two
/// are shown is one rule, `presentation`, for the card and the advice alike: a range when they are more than
/// fifteen minutes apart, one time at their midpoint when they are not. Notifications fire on the earliest edge,
/// which is a threshold rather than a display. The method and its limits are in docs/accuracy.md.
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

    /// How the interval is shown. One rule, because until 0.6.0 the card and the advice each had their own and the
    /// panel named two times for one event: the card printed the midpoint of a narrow interval ("Runs out in
    /// 1h 10m", 4:20 PM) while the advice under it quoted the earliest edge ("hit the cap at 3:54 PM"), and a
    /// reader could not tell which to plan around.
    enum Presentation: Equatable {
        /// The edges lie within `wideBeyond` of each other: one time, their midpoint. Inside a quarter of an hour
        /// neither edge is the better guess, and quoting the earliest as if it were reads as false precision.
        case single(at: Date)
        /// Both edges fall before the reset and further apart than `wideBeyond`: the window runs out somewhere between.
        case range(from: Date, to: Date)
        /// The fastest rate seen runs the window out at `from` and the slowest carries it past the reset, so the far
        /// edge of the range is the reset itself and the window may last.
        case rangeToReset(from: Date)

        /// The time a sentence names first: the single time, or the near edge of a range. The advice sorts on it and
        /// measures its "before reset" margin from it, so the margin agrees with the time it stands beside.
        var at: Date {
            switch self {
            case .single(let at), .range(let at, _), .rangeToReset(let at): at
            }
        }
    }

    /// Nil when the interval has nothing to show: the fastest rate lasts past the reset, or the edges are close and
    /// their midpoint does, in which case the window lasts as far as the interval can tell and the callers fall back
    /// to their other projections.
    func presentation(now: Date, resetsAt: Date) -> Presentation? {
        let from = now.addingTimeInterval(earliest)
        guard from < resetsAt else { return nil }
        guard isWide else {
            let midpoint = now.addingTimeInterval((earliest + latest) / 2)
            return midpoint < resetsAt ? .single(at: midpoint) : nil
        }
        let to = now.addingTimeInterval(latest)
        return to < resetsAt ? .range(from: from, to: to) : .rangeToReset(from: from)
    }

    /// The card's line: "Runs out 2:10–3:40 PM" when wide, "Runs out in 2h" when narrow, "Runs out from 2:10 PM, or
    /// lasts to the reset" when only the fast edge falls before it; nil when `presentation` is. A time on another
    /// day than today carries its day ("Runs out tomorrow at 12:10–12:50 AM"), and a range whose edges fall on
    /// different days names both ("Runs out between today at 11:50 PM and tomorrow at 12:30 AM"): two bare clock
    /// times across midnight read backwards.
    func text(now: Date, resetsAt: Date, format: TimeFormatPreference, calendar: Calendar = .current) -> String? {
        func clock(_ date: Date) -> String { ResetText.time(date, format: format, calendar: calendar) }
        func dated(_ date: Date) -> String { L("%1$@ at %2$@", ResetText.dayPhrase(date, now: now, calendar: calendar), clock(date)) }
        switch presentation(now: now, resetsAt: resetsAt) {
        case nil:
            return nil
        case .single(let at):
            return L("Runs out in %@", ResetText.duration(at.timeIntervalSince(now)))
        case .rangeToReset(let from):
            return L("Runs out from %@, or lasts to the reset", calendar.isDate(from, inSameDayAs: now) ? clock(from) : dated(from))
        case .range(let from, let to):
            guard calendar.isDate(from, inSameDayAs: to) else { return L("Runs out between %1$@ and %2$@", dated(from), dated(to)) }
            return L("Runs out %1$@–%2$@", calendar.isDate(from, inSameDayAs: now) ? clock(from) : dated(from), clock(to))
        }
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
    /// Below this the block is too small for its share of the window to mean anything: the numerator is this
    /// Mac's transcripts and the denominator is the whole account's window, so a few thousand tokens against a
    /// window mostly spent elsewhere read as an absurd ratio, and recorded as the day's figure they pulled the
    /// 30-day median with them.
    static let minimumBlockTokens = 50_000
    /// Past this multiple, usage the app cannot see (another Mac, another macOS account, claude.ai on the same
    /// Anthropic account) explains the gap far better than a change in metering: an hour's work elsewhere and a
    /// small task here read as "165x heavier", and the advice line blamed Anthropic for it.
    static let implausibleAbove = 6.0

    /// The block's tokens over the session's used share; nil until the window has moved at all and the block
    /// holds enough to compare.
    static func tokensPerPercent(blockTokens: Int, usedFraction: Double) -> Double? {
        guard usedFraction >= minimumUsed, blockTokens >= minimumBlockTokens else { return nil }
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
        guard let multiple else { return false }
        return multiple >= Self.heavierBy && multiple < Self.implausibleAbove
    }
}
