import Foundation

/// The weekday window in which Anthropic applies tighter session limits (05:00–11:00 Pacific, reported by The
/// Register on 2026-03-26 from Anthropic's announcement; the support article does not publish it, so this is
/// reporting, not documentation, and the window is editable in Settings). Off for every tool but Claude by
/// default: no other vendor has announced one.
struct PeakHours: Equatable, Codable, Sendable {
    var enabled = true
    /// Minutes after midnight in `timeZoneID`.
    var startMinute = 5 * 60
    var endMinute = 11 * 60
    var timeZoneID = "America/Los_Angeles"
    var weekdaysOnly = true

    static let anthropic = PeakHours()

    var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }

    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// Whether `date` falls inside the window, in the window's own zone.
    func isPeak(at date: Date) -> Bool {
        guard enabled else { return false }
        let calendar = calendar()
        if weekdaysOnly, calendar.isDateInWeekend(date) { return false }
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        return QuietHours.contains(minute: minute, start: startMinute, end: endMinute)
    }

    /// The next moment the state flips, and whether it flips into the peak; nil when the window is off.
    func nextBoundary(after date: Date) -> (date: Date, entersPeak: Bool)? {
        guard enabled, startMinute != endMinute else { return nil }
        let calendar = calendar()
        let peakNow = isPeak(at: date)
        var day = calendar.startOfDay(for: date)
        for _ in 0..<15 {
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            // Adding the minutes to midnight took every day for 24 hours: on 2026-11-01, when Pacific gains an
            // hour, it put the 05:00 boundary at 04:00 PST — outside the window, so the loop rejected it and
            // skipped the day. The calendar places a wall clock on the day it actually falls, and the hour a
            // fall-back repeats holds each clock twice where the calendar offers only the first: a window inside
            // it (01:30 to 02:30 with Weekdays only off) lost its second reading and the day was skipped again.
            var candidates = [startMinute, endMinute].flatMap { wall -> [Date] in
                guard let placed = calendar.date(bySettingHour: wall / 60, minute: wall % 60, second: 0, of: day) else { return [] }
                let again = placed.addingTimeInterval(3600)
                let reads = calendar.component(.hour, from: again) * 60 + calendar.component(.minute, from: again)
                return reads == wall ? [placed, again] : [placed]
            }
            // The change is a boundary in its own right, at no wall clock either end names: winding back from
            // 02:00 to 01:00 re-enters a 00:00–01:30 window that had already ended.
            if let shift = timeZone.nextDaylightSavingTimeTransition(after: day), shift < tomorrow {
                candidates.append(shift)
            }
            for candidate in candidates.sorted() where candidate > date {
                if isPeak(at: candidate) != peakNow || isPeak(at: candidate.addingTimeInterval(1)) != peakNow {
                    return (candidate, !peakNow)
                }
            }
            day = tomorrow
        }
        return nil
    }

    /// The window's two ends as instants on `date`'s own day in the window's zone, and `dayShift`: the start's
    /// calendar day on `zone`'s clock less its day on the window's, in whole days. A window that ends before it
    /// starts has wrapped past midnight, so its end belongs to the following day and the pair is always the real
    /// span. Dated rather than a fixed offset: the US and the EU change clocks on different weekends, so London
    /// reads an hour earlier than usual for the fortnight between them.
    func localWindow(on date: Date = Date(), in zone: TimeZone = .current) -> (start: Date, end: Date, dayShift: Int)? {
        guard enabled, startMinute != endMinute else { return nil }
        let calendar = calendar()
        let day = calendar.startOfDay(for: date)
        guard let start = calendar.date(bySettingHour: startMinute / 60, minute: startMinute % 60, second: 0, of: day) else { return nil }
        let endDay = startMinute < endMinute ? day : calendar.date(byAdding: .day, value: 1, to: day) ?? day
        guard let end = calendar.date(bySettingHour: endMinute / 60, minute: endMinute % 60, second: 0, of: endDay) else { return nil }
        var local = Calendar(identifier: .gregorian)
        local.timeZone = zone
        return (start, end, Self.dayShift(start, from: calendar, to: local))
    }

    /// One instant's calendar date under two zones, differenced in days. Measured against UTC because every UTC day
    /// is 24 hours long and its midnight always exists, where Santiago's does not on its own transition day.
    private static func dayShift(_ instant: Date, from: Calendar, to: Calendar) -> Int {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let fields: Set<Calendar.Component> = [.year, .month, .day]
        guard let theirs = utc.date(from: from.dateComponents(fields, from: instant)),
              let ours = utc.date(from: to.dateComponents(fields, from: instant)) else { return 0 }
        return utc.dateComponents([.day], from: theirs, to: ours).day ?? 0
    }

    /// "(8:00 AM–2:00 PM your time)": the Settings row states the hours on Anthropic's clock, which tells a reader
    /// outside it nothing. nil when their own clock already runs on the window's, so the row does not repeat itself
    /// — an offset test rather than an identifier one, because a zone can keep the window's rules under another name
    /// and part from them later: British Columbia leaves Pacific's rule in November 2026 (tzdata 2026c), and the
    /// hint should start appearing exactly then. `dayShift` is measured against the window's own day, not the
    /// reader's today: the clause answers "which local day does an Anthropic weekday land on", which is a standing
    /// fact about the two zones and the Weekdays only rule below it, rather than a claim about this occurrence.
    func localHint(format: TimeFormatPreference, in zone: TimeZone = .current, now: Date = Date()) -> String? {
        guard let local = localWindow(on: now, in: zone) else { return nil }
        guard zone.secondsFromGMT(for: local.start) != timeZone.secondsFromGMT(for: local.start)
            || zone.secondsFromGMT(for: local.end) != timeZone.secondsFromGMT(for: local.end) else { return nil }
        var calendar = Calendar.current
        calendar.timeZone = zone
        let from = ResetText.time(local.start, format: format, calendar: calendar)
        let to = ResetText.time(local.end, format: format, calendar: calendar)
        if local.dayShift > 0 { return L("(%1$@–%2$@ your time, the next day)", from, to) }
        if local.dayShift < 0 { return L("(%1$@–%2$@ your time, the day before)", from, to) }
        return L("(%1$@–%2$@ your time)", from, to)
    }

    /// "2:00 PM ET": the boundary in the user's own zone with its abbreviation.
    static func clock(_ date: Date, format: TimeFormatPreference, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        return "\(ResetText.time(date, format: format, calendar: calendar)) \(timeZone.abbreviation(for: date) ?? timeZone.identifier)"
    }
}
