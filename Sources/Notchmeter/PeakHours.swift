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
            let candidates = [startMinute, endMinute].map { day.addingTimeInterval(TimeInterval($0 * 60)) }
            for candidate in candidates.sorted() where candidate > date {
                if isPeak(at: candidate) != peakNow || isPeak(at: candidate.addingTimeInterval(1)) != peakNow {
                    return (candidate, !peakNow)
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
        }
        return nil
    }

    /// "2:00 PM ET": the boundary in the user's own zone with its abbreviation.
    static func clock(_ date: Date, format: TimeFormatPreference, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        return "\(ResetText.time(date, format: format, calendar: calendar)) \(timeZone.abbreviation(for: date) ?? timeZone.identifier)"
    }
}
