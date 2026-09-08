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

    @Test func theBoundaryHoldsItsWallClockAcrossADaylightSavingChange() {
        var everyDay = PeakHours.anthropic
        everyDay.weekdaysOnly = false
        // Sunday 2026-03-08, spring forward: 02:00 PST becomes 03:00 PDT, so midnight plus 300 minutes lands at 06:00.
        let springIn = everyDay.nextBoundary(after: date(2026, 3, 8, 1, 0, zone: pacific))!
        #expect(springIn.date == date(2026, 3, 8, 5, 0, zone: pacific))
        #expect(springIn.entersPeak)
        let springOut = everyDay.nextBoundary(after: date(2026, 3, 8, 7, 0, zone: pacific))!
        #expect(springOut.date == date(2026, 3, 8, 11, 0, zone: pacific))
        #expect(!springOut.entersPeak)
        // Sunday 2026-11-01, fall back: 02:00 PDT becomes 01:00 PST. The start used to land at 04:00, off-peak, so
        // it was rejected and the loop took the 10:00 candidate; leaving peak, both candidates agreed and the whole
        // day was skipped.
        let fallIn = everyDay.nextBoundary(after: date(2026, 11, 1, 0, 30, zone: pacific))!
        #expect(fallIn.date == date(2026, 11, 1, 5, 0, zone: pacific))
        #expect(fallIn.entersPeak)
        let fallOut = everyDay.nextBoundary(after: date(2026, 11, 1, 7, 0, zone: pacific))!
        #expect(fallOut.date == date(2026, 11, 1, 11, 0, zone: pacific))
        #expect(!fallOut.entersPeak)
        // A start inside the hour that does not exist is placed at the first real instant after it.
        var early = everyDay
        early.startMinute = 2 * 60 + 30
        early.endMinute = 5 * 60
        #expect(early.nextBoundary(after: date(2026, 3, 8, 1, 0, zone: pacific))!.date == date(2026, 3, 8, 3, 0, zone: pacific))
        // The shipped weekday window is unmoved: both transitions are Sundays.
        #expect(PeakHours.anthropic.nextBoundary(after: date(2026, 3, 6, 20, 0, zone: pacific))!.date == date(2026, 3, 9, 5, 0, zone: pacific))
        #expect(PeakHours.anthropic.nextBoundary(after: date(2026, 10, 30, 20, 0, zone: pacific))!.date == date(2026, 11, 2, 5, 0, zone: pacific))
    }

    /// The hour a fall-back repeats reads every wall clock twice, so a window set inside it has two of each end
    /// and the boundary is often the second. Pinned in UTC: "01:30 Pacific" names two instants on this day.
    @Test func aWindowInsideTheRepeatedHourKeepsBothOfItsReadings() {
        // Sunday 2026-11-01: 02:00 PDT (09:00 UTC) winds back to 01:00 PST, so 01:30 comes round at 08:30 and
        // again at 09:30. Weekdays only off, or the whole day is a weekend and none of this is reachable.
        var window = PeakHours.anthropic
        window.weekdaysOnly = false
        window.startMinute = 90
        window.endMinute = 150
        // From the second 01:00, the peak is half an hour off — not a day and a half, which is what taking only
        // the calendar's first placement of 01:30 leaves.
        let second = window.nextBoundary(after: date(2026, 11, 1, 9, 0, zone: .gmt))!
        #expect(second.date == date(2026, 11, 1, 9, 30, zone: .gmt))
        #expect(second.entersPeak)
        // Inside the first reading, the wound-back clock ends the window at an instant neither end names: 01:00
        // PST is before 01:30, so the change itself is the boundary.
        let unwound = window.nextBoundary(after: date(2026, 11, 1, 8, 45, zone: .gmt))!
        #expect(unwound.date == date(2026, 11, 1, 9, 0, zone: .gmt))
        #expect(!unwound.entersPeak)
        // And the mirror: winding back re-enters a window that had already run out.
        var earlier = window
        earlier.startMinute = 0
        earlier.endMinute = 90
        let reentered = earlier.nextBoundary(after: date(2026, 11, 1, 8, 30, zone: .gmt))!
        #expect(reentered.date == date(2026, 11, 1, 9, 0, zone: .gmt))
        #expect(reentered.entersPeak)
    }

    @Test func theWindowConvertsIntoTheReadersOwnZone() {
        // Tuesday 2026-09-01.
        let noon = date(2026, 9, 1, 12, 0, zone: pacific)
        let eastern = TimeZone(identifier: "America/New_York")!
        let converted = PeakHours.anthropic.localWindow(on: noon, in: eastern)!
        #expect(converted.start == date(2026, 9, 1, 5, 0, zone: pacific))
        #expect(converted.end == date(2026, 9, 1, 11, 0, zone: pacific))
        #expect(converted.dayShift == 0)
        // Crossing the reader's midnight is not a day shift; landing wholly on another date is.
        #expect(PeakHours.anthropic.localWindow(on: noon, in: TimeZone(identifier: "Asia/Tokyo")!)!.dayShift == 0)
        #expect(PeakHours.anthropic.localWindow(on: noon, in: TimeZone(identifier: "Pacific/Auckland")!)!.dayShift == 1)
        // UTC+14 is as far forward as a zone goes, and it is still one day.
        #expect(PeakHours.anthropic.localWindow(on: noon, in: TimeZone(identifier: "Pacific/Kiritimati")!)!.dayShift == 1)
        var earlyHours = PeakHours.anthropic
        earlyHours.startMinute = 30
        earlyHours.endMinute = 4 * 60
        #expect(earlyHours.localWindow(on: noon, in: TimeZone(identifier: "Pacific/Honolulu")!)!.dayShift == -1)
        // A window that ends before it starts wraps past midnight, so its end is the next day and the span is real.
        var overnight = PeakHours.anthropic
        overnight.startMinute = 22 * 60
        overnight.endMinute = 6 * 60
        let wrapped = overnight.localWindow(on: noon, in: eastern)!
        #expect(wrapped.start == date(2026, 9, 1, 22, 0, zone: pacific))
        #expect(wrapped.end == date(2026, 9, 2, 6, 0, zone: pacific))
        let eightHours = 8.0 * 3600
        #expect(wrapped.end.timeIntervalSince(wrapped.start) == eightHours)
        var off = PeakHours.anthropic
        off.enabled = false
        #expect(off.localWindow(on: noon, in: eastern) == nil)
        var empty = PeakHours.anthropic
        empty.endMinute = empty.startMinute
        #expect(empty.localWindow(on: noon, in: eastern) == nil)
    }

    @Test func theSettingsHintReadsTheWindowOnTheReadersClock() {
        // Tuesday 2026-09-01.
        let noon = date(2026, 9, 1, 12, 0, zone: pacific)
        let eastern = TimeZone(identifier: "America/New_York")!
        #expect(PeakHours.anthropic.localHint(format: .twelveHour, in: eastern, now: noon) == "(8:00 AM–2:00 PM your time)")
        #expect(PeakHours.anthropic.localHint(format: .twentyFourHour, in: eastern, now: noon) == "(08:00–14:00 your time)")
        // Tokyo crosses its own midnight; the times say so without a clause. Auckland does not, and needs one.
        #expect(PeakHours.anthropic.localHint(format: .twelveHour, in: TimeZone(identifier: "Asia/Tokyo")!, now: noon)
            == "(9:00 PM–3:00 AM your time)")
        #expect(PeakHours.anthropic.localHint(format: .twelveHour, in: TimeZone(identifier: "Pacific/Auckland")!, now: noon)
            == "(12:00 AM–6:00 AM your time, the next day)")
        var earlyHours = PeakHours.anthropic
        earlyHours.startMinute = 30
        earlyHours.endMinute = 4 * 60
        #expect(earlyHours.localHint(format: .twelveHour, in: TimeZone(identifier: "Pacific/Honolulu")!, now: noon)
            == "(9:30 PM–1:00 AM your time, the day before)")
        // London reads an hour earlier for the fortnight between the US and the EU transitions: Tuesday 2026-03-10.
        let london = TimeZone(identifier: "Europe/London")!
        #expect(PeakHours.anthropic.localHint(format: .twelveHour, in: london, now: noon) == "(1:00 PM–7:00 PM your time)")
        #expect(PeakHours.anthropic.localHint(format: .twelveHour, in: london, now: date(2026, 3, 10, 12, 0, zone: pacific))
            == "(12:00 PM–6:00 PM your time)")
        // Pacific's own transition day, Sunday 2026-11-01, still reads its wall clock.
        #expect(PeakHours.anthropic.localHint(format: .twelveHour, in: eastern, now: date(2026, 11, 1, 12, 0, zone: pacific))
            == "(8:00 AM–2:00 PM your time)")
        // A reader already on the window's clock is told nothing, whatever the zone is called.
        #expect(PeakHours.anthropic.localHint(format: .twelveHour, in: pacific, now: noon) == nil)
        #expect(PeakHours.anthropic.localHint(format: .twelveHour, in: TimeZone(identifier: "US/Pacific")!, now: noon) == nil)
        // Phoenix keeps MST all year: Pacific's clock in summer, an hour ahead of it on Tuesday 2026-01-06.
        let phoenix = TimeZone(identifier: "America/Phoenix")!
        #expect(PeakHours.anthropic.localHint(format: .twelveHour, in: phoenix, now: noon) == nil)
        #expect(PeakHours.anthropic.localHint(format: .twelveHour, in: phoenix, now: date(2026, 1, 6, 12, 0, zone: pacific))
            == "(6:00 AM–12:00 PM your time)")
    }

    /// However the window is set and whenever it is read, the pair keeps the window's own length, give or take the
    /// hour a transition adds or removes inside it — the wrap past midnight included. No zone dimension: the two
    /// instants are placed by the window's own calendar and the reader's zone reaches only `dayShift`, which
    /// `theWindowConvertsIntoTheReadersOwnZone` pins case by case.
    @Test func theSpanKeepsTheWindowsLengthWheneverItIsRead() {
        var everyDay = PeakHours.anthropic
        everyDay.weekdaysOnly = false
        let reader = TimeZone(identifier: "America/New_York")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = pacific
        for start in stride(from: 0, to: 24 * 60, by: 150) {
            for end in stride(from: 0, to: 24 * 60, by: 150) where start != end {
                var window = everyDay
                window.startMinute = start
                window.endMinute = end
                let nominal = TimeInterval(((end - start) + 1440) % 1440 * 60)
                for offset in stride(from: 0, to: 365, by: 11) {
                    let now = calendar.date(byAdding: .day, value: offset, to: date(2026, 1, 1, 12, 0, zone: pacific))!
                    let local = window.localWindow(on: now, in: reader)!
                    #expect(abs(local.end.timeIntervalSince(local.start) - nominal) <= 3600)
                }
            }
        }
    }

    @Test func adviceNamesTheEndOfPeakAndTheStartOfOffPeak() {
        let now = date(2026, 9, 1, 8, 0, zone: pacific)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = pacific
        let session = LimitWindow(id: "five_hour", label: "Session", usedFraction: 0.2, resetsAt: now.addingTimeInterval(4 * 3600), periodDuration: Period.fiveHours)
        let reading = UsageReading(tool: .claude, windows: [session], plan: nil, fetchedAt: now, observedAt: nil)
        var context = Advisor.Context(readings: [reading], timeFormat: .twelveHour, now: now, calendar: calendar)
        context.peakHours = [.claude: .anthropic]
        let insidePeak = Advisor.peak(context).map(\.text)
        #expect(insidePeak == ["Peak hours until 11:00 AM PDT: the session projection assumes the peak rate."])
        context.now = date(2026, 9, 1, 10, 20, zone: pacific)
        let nearingOffPeak = Advisor.peak(context).map(\.text)
        #expect(nearingOffPeak == ["Off-peak in 40m: start the long job then."])
        context.now = date(2026, 9, 1, 14, 0, zone: pacific)
        #expect(Advisor.peak(context).isEmpty)
        context.peakHours = [:]
        context.now = now
        #expect(Advisor.peak(context).isEmpty)
    }
}
