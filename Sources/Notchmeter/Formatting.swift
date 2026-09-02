import Foundation

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

    /// The quiet note beside a meter: "~67% left at reset", or the run-out warning when behind.
    static func note(for window: LimitWindow, now: Date = Date()) -> (text: String, status: Status)? {
        guard let used = window.usedFraction, let resetsAt = window.resetsAt, let period = window.periodDuration,
              let result = evaluate(usedFraction: used, resetsAt: resetsAt, period: period, now: now)
        else { return nil }
        switch result.status {
        case .behind:
            if let eta = secondsToRunOut(usedFraction: used, resetsAt: resetsAt, period: period, now: now) {
                return ("Runs out in \(ResetText.duration(eta))", .behind)
            }
            return ("~\(Int(((result.projectedFraction - 1) * 100).rounded()))% over at reset", .behind)
        case .ahead, .onTrack:
            let left = max(0, 1 - result.projectedFraction)
            return ("~\(Int((left * 100).rounded()))% left at reset", result.status)
        }
    }
}

enum UsageDisplay: String, CaseIterable, Codable {
    case used, left

    var title: String {
        switch self {
        case .used: "Used"
        case .left: "Left"
        }
    }
}

enum ResetDisplay: String, CaseIterable, Codable {
    case countdown, exact

    var title: String {
        switch self {
        case .countdown: "Countdown"
        case .exact: "Exact time"
        }
    }
}

enum TimeFormatPreference: String, CaseIterable, Codable {
    case auto, twelveHour, twentyFourHour

    var title: String {
        switch self {
        case .auto: "Auto"
        case .twelveHour: "12-hour"
        case .twentyFourHour: "24-hour"
        }
    }
}

/// Reset copy in either style: "Resets in 4d 17h" or "Resets today at 10:50 PM".
enum ResetText {
    static func line(resetsAt: Date?, hasLimit: Bool, display: ResetDisplay, timeFormat: TimeFormatPreference,
                     now: Date = Date(), calendar: Calendar = .current) -> String {
        guard hasLimit else { return "No limit published" }
        guard let resetsAt else { return "" }
        let remaining = resetsAt.timeIntervalSince(now)
        if remaining <= 0 { return "Resets now" }
        switch display {
        case .countdown:
            return "Resets in \(duration(remaining))"
        case .exact:
            return "Resets \(dayPhrase(resetsAt, now: now, calendar: calendar)) at \(time(resetsAt, format: timeFormat, calendar: calendar))"
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(total)s"
    }

    static func dayPhrase(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "tomorrow" }
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

enum Money {
    static func dollars(_ value: Double, cents: Bool = true) -> String {
        if !cents || value >= 1000 { return "$\(Int(value.rounded()))" }
        return String(format: "$%.2f", value)
    }
}

enum Burn {
    /// "6x", "1.5x", "0.3x": one decimal below ten, none from ten up.
    static func multiple(_ value: Double) -> String {
        if value >= 10 { return "\(Int(value.rounded()))x" }
        let text = String(format: "%.1f", value)
        return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + "x"
    }
}

/// VoiceOver copy: the on-screen abbreviations read as words, so "~58% left" is spoken "about 58 percent left"
/// and "4d 17h" as "4 days 17 hours".
enum Spoken {
    private static let units: [Character: String] = ["d": "day", "h": "hour", "m": "minute", "s": "second", "x": "time"]

    static func phrase(_ text: String) -> String {
        text.replacingOccurrences(of: "~", with: "about ")
            .replacingOccurrences(of: "%", with: " percent")
            .replacingOccurrences(of: " · ", with: ", ")
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
        if awaitingInput { parts.append("waiting for your input") }
        if let problem = status.problem { parts.append(phrase(problem)) }
        if let reading = status.reading {
            for window in reading.windows {
                guard let used = window.usedFraction else { continue }
                var part = "\(window.label) \(Int((used * 100).rounded())) percent used"
                switch Pace.status(for: window, now: now) {
                case .behind: part += ", behind pace"
                case .onTrack: part += ", close to pace"
                case .ahead, nil: break
                }
                parts.append(part)
            }
        } else {
            switch status {
            case .waiting: parts.append("waiting for the first reading")
            case .idle(let message): parts.append(phrase(message))
            case .off: parts.append("off")
            case .notInstalled: parts.append("not installed")
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
