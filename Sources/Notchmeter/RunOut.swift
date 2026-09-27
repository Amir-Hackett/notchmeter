import Foundation

/// The pace a window of a day or longer is projected at: how far it rose over the last day, idle hours included,
/// as a rate per hour (`LimitWindow.recentRate`, which `Pace` projects at in place of the even burn).
///
/// A week is not spent the way a five-hour session is. Until 0.9.4 a weekly window was forecast at the rates it
/// had risen at while in use, which answers "if you work without stopping from now", and on 2026-09-27 it told a
/// reader at 9 AM that the week would run out that afternoon: the window had risen 51 points on the night it reset
/// and 5 in the two days since, and the forecast took the first night's hours as the pace. A day's rise counts the
/// nights and the breaks, so it answers "if the next days go like the last one". The rise is the growth of the
/// window's high-water mark, so the 1-point flicker between two reads of the same figure (50, 51, 50, 51) counts
/// once, and a reset inside the day starts the new period from nothing. Until the log reaches back a day there is
/// no rate, and `Pace` keeps the even burn.
enum RecentPace {
    static let span: TimeInterval = 86400

    /// A fall this large inside one period is a vendor's correction, not the flicker, and the mark follows it down.
    static let correction = 0.2

    /// Windows of a day or longer, the ones projected at this pace; a shorter one (the five-hour session) is
    /// projected at the pace of the hours it was used in (`RunOutInterval`), which is how such a window is spent.
    static func applies(to window: LimitWindow) -> Bool {
        !window.isComparison && (window.periodDuration ?? 0) >= Period.day
    }

    /// Fraction per hour over the span from the newest sample at least a day old to `now`; nil when the log does not
    /// reach back that far. A gap in the log (the Mac asleep) widens the span rather than inventing a day.
    static func rate(_ samples: [DrainSample], now: Date) -> Double? {
        guard let start = samples.lastIndex(where: { $0.t <= now.addingTimeInterval(-span) }) else { return nil }
        let base = samples[start]
        var mark = base.used
        var resetsAt = base.resetsAt
        var rise = 0.0
        for sample in samples[samples.index(after: start)...] where sample.t <= now {
            if !ResetPeriod.same(sample.resetsAt, resetsAt) {
                resetsAt = sample.resetsAt
                mark = 0
            } else if sample.used < mark - correction {
                mark = sample.used
            }
            if sample.used > mark {
                rise += sample.used - mark
                mark = sample.used
            }
        }
        let hours = now.timeIntervalSince(base.t) / 3600
        return hours > 0 ? rise / hours : nil
    }

    /// The reading with each window of a day or longer carrying its rate from `samples`, which must already hold
    /// this reading's own figures (UsageStore.recordDrain); the other windows as they came.
    static func apply(_ reading: UsageReading, samples: [DrainLog.Key: [DrainSample]], now: Date) -> UsageReading {
        let windows = reading.windows.map { window -> LimitWindow in
            guard applies(to: window), let rows = samples[DrainLog.Key(tool: reading.tool, window: window.id)] else { return window }
            return window.pacing(at: rate(rows, now: now))
        }
        return reading.replacing(windows: windows, fetchedAt: reading.fetchedAt)
    }
}

/// A run-out estimate as an interval rather than a point, for a window shorter than a day (the five-hour session;
/// a longer one is projected at `RecentPace`): the 20th and 80th percentile of the rates the window has risen at
/// in use over the last seven days, in the same peak or off-peak state as now when enough of those exist, give the
/// latest and the earliest moment the window runs out at those rates. How the two are shown is one rule,
/// `presentation`, for the card and the advice alike: a range when they are more than fifteen minutes apart, one
/// time at their midpoint when they are not. Notifications fire on the earliest edge, which is a threshold rather
/// than a display. The method and its limits are in docs/accuracy.md.
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
    /// A rise measured over less than this is timed by when the reads fell rather than by the work, so it waits
    /// for the next one and the two are measured together.
    static let shortestRise: TimeInterval = 300
    /// A rise more than this after the last one spans a break, and says nothing about the pace of the work.
    static let longestRise: TimeInterval = 3600

    var isWide: Bool { latest - earliest > Self.wideBeyond }

    /// The rates a window has risen at while in use, newest last: each rise of its high-water mark over the time
    /// since the mark last rose, when that was between five minutes and an hour before. Until 0.9.4 a rate was
    /// taken between each pair of consecutive rows, which measured the log rather than the work: the figure moves
    /// in whole points and a row is written at least every five minutes, so any 1-point step read as about 12% an
    /// hour however slowly the window was really moving, and the 1-point flicker between two reads of the same
    /// figure (50, 51, 50, 51) was counted as a fresh rise each time it came back up.
    static func hourlyRates(_ samples: [DrainSample], since: Date) -> [(t: Date, perHour: Double)] {
        var rates: [(Date, Double)] = []
        var mark: DrainSample?
        var peak: DrainSample?
        for sample in samples {
            guard let from = mark, ResetPeriod.same(sample.resetsAt, from.resetsAt), sample.used >= from.used - RecentPace.correction else {
                mark = sample
                peak = nil
                continue
            }
            if sample.used > (peak ?? from).used { peak = sample }
            guard let to = peak else { continue }
            let span = to.t.timeIntervalSince(from.t)
            guard span >= shortestRise else { continue }
            if span <= longestRise, to.t >= since { rates.append((to.t, (to.used - from.used) / (span / 3600))) }
            mark = to
            peak = nil
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

    /// Nil for a window of a day or longer (`period`), which is projected at `RecentPace` instead.
    static func estimate(samples: [DrainSample], usedFraction: Double, resetsAt: Date, now: Date, period: TimeInterval? = nil,
                         peak: PeakHours? = nil, days: Int = 7) -> RunOutInterval? {
        guard usedFraction < 1, resetsAt > now, (period ?? 0) < Period.day else { return nil }
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
