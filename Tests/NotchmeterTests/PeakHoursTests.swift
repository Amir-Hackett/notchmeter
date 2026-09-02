import Foundation
import Testing
@testable import Notchmeter

/// Anthropic's weekday window, 05:00–11:00 Pacific: membership, the next boundary, and the conversion into the
/// user's own zone for the advice line.
@Suite struct PeakHourRules {
    init() { Localization.use(language: "en") }

    let pacific = TimeZone(identifier: "America/Los_Angeles")!

    func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    @Test func weekdayMorningsInPacificArePeak() {
        let peak = PeakHours.anthropic
        // Tuesday 2026-09-01.
        #expect(peak.isPeak(at: date(2026, 9, 1, 8, 0, zone: pacific)))
        #expect(peak.isPeak(at: date(2026, 9, 1, 5, 0, zone: pacific)))
        #expect(!peak.isPeak(at: date(2026, 9, 1, 11, 0, zone: pacific)))
        #expect(!peak.isPeak(at: date(2026, 9, 1, 4, 59, zone: pacific)))
        // Saturday 2026-09-05.
        #expect(!peak.isPeak(at: date(2026, 9, 5, 8, 0, zone: pacific)))
        var everyDay = peak
        everyDay.weekdaysOnly = false
        #expect(everyDay.isPeak(at: date(2026, 9, 5, 8, 0, zone: pacific)))
        var off = peak
        off.enabled = false
        #expect(!off.isPeak(at: date(2026, 9, 1, 8, 0, zone: pacific)))
    }

    @Test func theSameInstantIsPeakWhateverTheUsersZone() {
        let eastern = TimeZone(identifier: "America/New_York")!
        // 08:00 Pacific is 11:00 Eastern on the same Tuesday.
        #expect(PeakHours.anthropic.isPeak(at: date(2026, 9, 1, 11, 0, zone: eastern)))
        #expect(!PeakHours.anthropic.isPeak(at: date(2026, 9, 1, 14, 0, zone: eastern)))
        let boundary = PeakHours.anthropic.nextBoundary(after: date(2026, 9, 1, 8, 0, zone: pacific))!
        #expect(boundary.date == date(2026, 9, 1, 11, 0, zone: pacific))
        #expect(!boundary.entersPeak)
        #expect(PeakHours.clock(boundary.date, format: .twelveHour, timeZone: eastern) == "2:00 PM EDT")
        let evening = PeakHours.anthropic.nextBoundary(after: date(2026, 9, 1, 20, 0, zone: pacific))!
        #expect(evening.date == date(2026, 9, 2, 5, 0, zone: pacific))
        #expect(evening.entersPeak)
        // Friday evening skips the weekend.
        let friday = PeakHours.anthropic.nextBoundary(after: date(2026, 9, 4, 20, 0, zone: pacific))!
        #expect(friday.date == date(2026, 9, 7, 5, 0, zone: pacific))
    }

    @Test func adviceNamesTheEndOfPeakAndTheStartOfOffPeak() {
        let now = date(2026, 9, 1, 8, 0, zone: pacific)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = pacific
        let session = LimitWindow(id: "five_hour", label: "Session", usedFraction: 0.2, resetsAt: now.addingTimeInterval(4 * 3600), periodDuration: Period.fiveHours)
        let reading = UsageReading(tool: .claude, windows: [session], plan: nil, fetchedAt: now, observedAt: nil)
        var context = Advisor.Context(readings: [reading], timeFormat: .twelveHour, now: now, calendar: calendar)
        context.peakHours = [.claude: .anthropic]
        #expect(Advisor.peak(context).map(\.text) == ["Peak hours until 11:00 AM PDT: the session projection assumes the peak rate."])
        context.now = date(2026, 9, 1, 10, 20, zone: pacific)
        #expect(Advisor.peak(context).map(\.text) == ["Off-peak in 40m: start the long job then."])
        context.now = date(2026, 9, 1, 14, 0, zone: pacific)
        #expect(Advisor.peak(context).isEmpty)
        context.peakHours = [:]
        context.now = now
        #expect(Advisor.peak(context).isEmpty)
    }
}
