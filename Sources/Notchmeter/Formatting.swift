import Foundation
import os

/// Burn-rate projection for a bounded window (ported from OpenUsage's Pace): given how much is spent and
/// how far through the window we are, project usage at the current rate to the reset.
enum Pace {
    enum Status: Equatable {
        case ahead     // lands with at least 10% to spare
        case onTrack   // lands inside the last 10%
        case behind    // runs out before the reset
    }

    struct Result: Equatable {
        let status: Status
        let projectedFraction: Double
    }

    /// Too early in a window for a stable projection: at least a minute, or 1% of the period.
    static func minimumElapsed(period: TimeInterval) -> TimeInterval {
        max(60, period * 0.01)
    }

    /// Where an even burn would sit right now, 0...1. Drives the tick on the meter.
    static func elapsedFraction(resetsAt: Date, period: TimeInterval, now: Date = Date()) -> Double? {
        guard period > 0, now < resetsAt else { return nil }
        let elapsed = now.timeIntervalSince(resetsAt.addingTimeInterval(-period))
        guard elapsed >= 0 else { return nil }
        return min(1, elapsed / period)
    }

    static func evaluate(usedFraction: Double, resetsAt: Date, period: TimeInterval, now: Date = Date()) -> Result? {
        guard period > 0, now < resetsAt else { return nil }
        let elapsed = now.timeIntervalSince(resetsAt.addingTimeInterval(-period))
        guard elapsed >= minimumElapsed(period: period) else { return nil }
        if usedFraction <= 0 { return Result(status: .ahead, projectedFraction: 0) }
        let projected = usedFraction / elapsed * period
        if usedFraction >= 1 { return Result(status: .behind, projectedFraction: projected) }
        let status: Status = projected <= 0.9 ? .ahead : projected <= 1 ? .onTrack : .behind
        return Result(status: status, projectedFraction: projected)
    }

    /// Seconds until the quota is gone at the current rate, only when that happens before the reset.
    static func secondsToRunOut(usedFraction: Double, resetsAt: Date, period: TimeInterval, now: Date = Date()) -> TimeInterval? {
        guard let result = evaluate(usedFraction: usedFraction, resetsAt: resetsAt, period: period, now: now),
              result.status == .behind
        else { return nil }
        let rate = result.projectedFraction / period
        guard rate > 0 else { return nil }
        let eta = (1 - usedFraction) / rate
        guard eta > 0, eta < resetsAt.timeIntervalSince(now) else { return nil }
        return eta
    }

    static func status(for window: LimitWindow, now: Date = Date()) -> Status? {
        guard let used = window.usedFraction, let resetsAt = window.resetsAt, let period = window.periodDuration else { return nil }
        return evaluate(usedFraction: used, resetsAt: resetsAt, period: period, now: now)?.status
    }

    /// The quiet note beside a meter: "~67% left at reset", or the run-out warning when behind. An untouched window
    /// gets none: "~100% left at reset" says nothing, and the meter's tick already shows where the window stands.
    static func note(for window: LimitWindow, now: Date = Date()) -> (text: String, status: Status)? {
        guard let used = window.usedFraction, used > 0, let resetsAt = window.resetsAt, let period = window.periodDuration,
              let result = evaluate(usedFraction: used, resetsAt: resetsAt, period: period, now: now)
        else { return nil }
        switch result.status {
        case .behind:
            if let eta = secondsToRunOut(usedFraction: used, resetsAt: resetsAt, period: period, now: now) {
                return (L("Runs out in %@", ResetText.duration(eta)), .behind)
            }
            return (L("~%ld%% over at reset", Int(((result.projectedFraction - 1) * 100).rounded())), .behind)
        case .ahead, .onTrack:
            let left = max(0, 1 - result.projectedFraction)
            return (L("~%ld%% left at reset", Int((left * 100).rounded())), result.status)
        }
    }
}

enum UsageDisplay: String, CaseIterable, Codable {
    case used, left

    var title: String {
        switch self {
        case .used: L("Used")
        case .left: L("Left")
        }
    }
}

/// The digits beside a ring (CompactStyle): the main window's percentage and, after a thin dot, the second
/// window's, in the Used or Left sense the user chose; "–" for a window without a limit, or no reading at all.
enum CompactLabel {
    struct Segment: Equatable {
        let text: String
        let pace: Pace.Status?
    }

    static let noLimit = "–"
    static let separator = "·"

    static func segments(for reading: UsageReading?, display: UsageDisplay, countdown: Bool = false, now: Date = Date()) -> [Segment] {
        segments(for: reading.map { Array($0.windows.prefix(2)) } ?? [], display: display, countdown: countdown, now: now)
    }

    /// `windows` are the ones the rings draw (Preferences.ringWindows). With `countdown`, the first window's figure
    /// carries its reset as a compact duration ("90% 32m"), left out when the reset is unknown or has passed.
    static func segments(for windows: [LimitWindow], display: UsageDisplay, countdown: Bool = false, now: Date = Date()) -> [Segment] {
        guard !windows.isEmpty else { return [Segment(text: noLimit, pace: nil)] }
        return windows.enumerated().map { index, window in
            guard let used = window.usedFraction else { return Segment(text: noLimit, pace: nil) }
            let shown = display == .used ? used : 1 - used
            var text = "\(Int((shown * 100).rounded()))%"
            if countdown, index == 0, let resetsAt = window.resetsAt, resetsAt > now {
                text += " " + ResetText.compactDuration(resetsAt.timeIntervalSince(now))
            }
            return Segment(text: text, pace: Pace.status(for: window, now: now))
        }
    }

    static func text(for reading: UsageReading?, display: UsageDisplay, countdown: Bool = false, now: Date = Date()) -> String {
        segments(for: reading, display: display, countdown: countdown, now: now).map(\.text).joined(separator: " \(separator) ")
    }

    static func text(for windows: [LimitWindow], display: UsageDisplay, countdown: Bool = false, now: Date = Date()) -> String {
        segments(for: windows, display: display, countdown: countdown, now: now).map(\.text).joined(separator: " \(separator) ")
    }
}

enum ResetDisplay: String, CaseIterable, Codable {
    case countdown, exact

    var title: String {
        switch self {
        case .countdown: L("Countdown")
        case .exact: L("Exact time")
        }
    }
}

enum TimeFormatPreference: String, CaseIterable, Codable {
    case auto, twelveHour, twentyFourHour

    var title: String {
        switch self {
        case .auto: L("Auto")
        case .twelveHour: L("12-hour")
        case .twentyFourHour: L("24-hour")
        }
    }
}

/// Reset copy in either style: "Resets in 4d 17h" or "Resets today at 10:50 PM". A stale reading whose reset has
/// gone by says "Reset passed": the numbers are from before it, so nothing is about to change. A rolling window
/// that has not begun (nothing used, no reset declared) says "Not started" rather than nothing.
enum ResetText {
    static func line(resetsAt: Date?, hasLimit: Bool, display: ResetDisplay, timeFormat: TimeFormatPreference,
                     stale: Bool = false, unused: Bool = false, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard hasLimit else { return L("No limit published") }
        guard let resetsAt else { return unused ? L("Not started") : "" }
        let remaining = resetsAt.timeIntervalSince(now)
        if remaining <= 0 { return stale ? L("Reset passed") : L("Resets now") }
        switch display {
        case .countdown:
            return L("Resets in %@", duration(remaining))
        case .exact:
            return L("Resets %1$@ at %2$@", dayPhrase(resetsAt, now: now, calendar: calendar), time(resetsAt, format: timeFormat, calendar: calendar))
        }
    }

    /// An unused window has no reset worth showing: Codex reports now + period for one, so the time would slide
    /// with the clock. Name the period instead.
    static func unusedLine(period: TimeInterval) -> String {
        L("Nothing used · %@ window", windowName(period: period))
    }

    /// "5-hour", "7-day", "30-day", "90-minute".
    static func windowName(period: TimeInterval) -> String {
        let minutes = max(1, Int((period / 60).rounded()))
        if minutes % 1440 == 0 { return L("%ld-day", minutes / 1440) }
        if minutes % 60 == 0 { return L("%ld-hour", minutes / 60) }
        return L("%ld-minute", minutes)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return hours > 0 ? L("%1$ldd %2$ldh", days, hours) : L("%ldd", days) }
        if hours > 0 { return minutes > 0 ? L("%1$ldh %2$ldm", hours, minutes) : L("%ldh", hours) }
        if minutes > 0 { return L("%ldm", minutes) }
        return L("%lds", total)
    }

    /// One unit only, for the rings: "6d", "4h", "32m"; anything under a minute is "1m".
    static func compactDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total >= 86400 { return L("%ldd", total / 86400) }
        if total >= 3600 { return L("%ldh", total / 3600) }
        return L("%ldm", max(1, total / 60))
    }

    static func dayPhrase(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return L("today") }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return L("tomorrow") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return L("yesterday") }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMM d" : "MMM d yyyy")
        return formatter.string(from: date)
    }

    static func time(_ date: Date, format: TimeFormatPreference, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        switch format {
        case .auto: formatter.timeStyle = .short
        case .twelveHour: formatter.dateFormat = "h:mm a"
        case .twentyFourHour: formatter.dateFormat = "HH:mm"
        }
        return formatter.string(from: date)
    }
}

/// Under a tool that has stopped answering, when its last reading is still on screen: "Last reading 10:52 PM ·
/// may be out of date". The day is named once the reading is not from today.
enum StaleReading {
    static func line(fetchedAt: Date, timeFormat: TimeFormatPreference, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = ResetText.time(fetchedAt, format: timeFormat, calendar: calendar)
        let when = calendar.isDate(fetchedAt, inSameDayAs: now)
            ? time
            : L("%1$@ at %2$@", ResetText.dayPhrase(fetchedAt, now: now, calendar: calendar), time)
        return L("Last reading %@ · may be out of date", when)
    }
}

/// Every amount on screen goes through here. Amounts are computed in US dollars; "Show costs in" converts them
/// with the user's own rate and the locale's symbol for the code (docs/accuracy.md: the rate is never fetched).
enum Money {
    private struct Currency {
        var code = "USD"
        var rate = 1.0
        var symbol = "$"
    }

    private static let current = OSAllocatedUnfairLock(initialState: Currency())

    static func configure(code: String, rate: Double) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let code = trimmed.count == 3 ? trimmed : "USD"
        let rate = code == "USD" ? 1 : (rate.isFinite && rate > 0 ? rate : 1)
        current.withLock { $0 = Currency(code: code, rate: rate, symbol: symbol(for: code)) }
    }

    static var code: String { current.withLock { $0.code } }
    static var rate: Double { current.withLock { $0.rate } }

    /// The locale's symbol for the code ("€", "£", "¥", "CHF"); the code itself when the locale has none.
    static func symbol(for code: String, locale: Locale = .current) -> String {
        if code == "USD" { return "$" }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        let symbol = formatter.currencySymbol ?? code
        return symbol.isEmpty || symbol == "¤" ? code : symbol
    }

    static func dollars(_ value: Double, cents: Bool = true) -> String {
        let currency = current.withLock { $0 }
        return format(value, cents: cents, rate: currency.rate, symbol: currency.symbol)
    }

    /// The amount in the chosen currency: two decimals under a thousand, whole units from there, and grouped
    /// past a thousand so a four-figure total reads as one number rather than a run of digits. An amount that is
    /// spent but under one unit keeps its cents even where they were asked to be dropped: "$0" over a legend of
    /// non-zero rows reads as nothing spent, which is the one thing the figure must never say by accident.
    static func format(_ value: Double, cents: Bool = true, rate: Double, symbol: String) -> String {
        let amount = value * rate
        let roundsToNothing = amount > 0 && amount < 1
        if (!cents && !roundsToNothing) || amount >= 1000 { return symbol + grouped(Int(amount.rounded())) }
        return symbol + String(format: "%.2f", amount)
    }

    /// Thousands separated in the reader's own locale, so it is "7,845" here and "7 845" or "7.845" elsewhere.
    static func grouped(_ value: Int) -> String {
        groupingFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static let groupingFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    /// "4.2M tokens", "310K tokens", "812 tokens".
    static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            let millions = Double(count) / 1_000_000
            return L("%@M tokens", millions >= 10 ? String(Int(millions.rounded())) : String(format: "%.1f", millions))
        }
        if count >= 1000 { return L("%ldK tokens", Int((Double(count) / 1000).rounded())) }
        return L("%ld tokens", count)
    }
}

enum Burn {
    /// "6x", "1.5x", "0.3x": one decimal below ten, none from ten up.
    static func multiple(_ value: Double) -> String {
        if value >= 10 { return L("%@x", String(Int(value.rounded()))) }
        let text = String(format: "%.1f", value)
        return L("%@x", text.hasSuffix(".0") ? String(text.dropLast(2)) : text)
    }
}

/// VoiceOver copy: the on-screen abbreviations read as words, so "~58% left" is spoken "about 58 percent left"
/// and "4d 17h" as "4 days 17 hours".
enum Spoken {
    /// The suffix letters are the ones the English ResetText.duration and Burn.multiple emit. Another language's
    /// units ("4 天 17 小时") are words already, and pass through untouched.
    private static let units: [Character: String] = ["d": "day", "h": "hour", "m": "minute", "s": "second", "x": "time"]

    static func phrase(_ text: String) -> String {
        text.replacingOccurrences(of: "~", with: L("about "))
            .replacingOccurrences(of: "%", with: L(" percent"))
            .replacingOccurrences(of: " · ", with: ", ")
            .replacingOccurrences(of: " — ", with: ", ")
            .split(separator: " ")
            .map { expand(String($0)) }
            .joined(separator: " ")
    }

    /// Parts joined as one sentence; empty and missing parts are dropped.
    static func line(_ parts: String?...) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.map(phrase).joined(separator: ", ")
    }

    /// One tool for the compact rings: "Session 19 percent used, close to pace; Weekly 5 percent used".
    static func status(_ status: ToolStatus, awaitingInput: Bool, now: Date = Date()) -> String {
        var parts: [String] = []
        if awaitingInput { parts.append(L("waiting for your input")) }
        if let problem = status.problem { parts.append(phrase(problem)) }
        if let reading = status.reading {
            for window in reading.windows {
                guard let used = window.usedFraction else { continue }
                var part = L("%1$@ %2$ld percent used", window.label, Int((used * 100).rounded()))
                switch Pace.status(for: window, now: now) {
                case .behind: part += L(", behind pace")
                case .onTrack: part += L(", close to pace")
                case .ahead, nil: break
                }
                parts.append(part)
            }
        } else {
            switch status {
            case .waiting: parts.append(L("waiting for the first reading"))
            case .idle(let message): parts.append(phrase(message))
            case .off: parts.append(L("off"))
            case .notInstalled: parts.append(L("not installed"))
            case .offline: parts.append(L("Offline, retrying"))
            case .ready, .needsAttention, .failed: break
            }
        }
        return parts.joined(separator: "; ")
    }

    private static func expand(_ token: String) -> String {
        var core = Substring(token)
        var suffix = ""
        if let last = core.last, ",.;".contains(last) {
            suffix = String(last)
            core = core.dropLast()
        }
        guard let unit = core.last, let name = units[unit], let value = Double(core.dropLast()) else { return token }
        return "\(core.dropLast()) \(name)\(value == 1 ? "" : "s")\(suffix)"
    }
}
