import Foundation
import Testing
@testable import Notchmeter

/// A reading kept on screen after its tool stopped answering says how old it is, and a reset it has already
/// passed is not announced as imminent.
@Suite struct StaleReadingCopy {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    func date(_ day: Int, _ hour: Int, _ minute: Int, month: Int = 9) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute)))
    }

    @Test func onlyAToolThatStoppedAnsweringKeepsAStaleReading() {
        let reading = UsageReading(tool: .claude, windows: [], plan: nil, fetchedAt: Date(), observedAt: nil)
        #expect(ToolStatus.needsAttention("login expired", cached: reading).staleReading == reading)
        #expect(ToolStatus.failed("timed out", cached: reading).staleReading == reading)
        #expect(ToolStatus.failed("timed out", cached: nil).staleReading == nil)
        #expect(ToolStatus.ready(reading).staleReading == nil)
        #expect(ToolStatus.waiting.staleReading == nil)
        #expect(ToolStatus.idle("nothing yet").staleReading == nil)
    }

    @Test func namesTheTimeInTheUsersFormat() throws {
        let now = try date(1, 23, 10)
        let fetched = try date(1, 22, 52)
        #expect(StaleReading.line(fetchedAt: fetched, timeFormat: .twelveHour, now: now, calendar: calendar) == "Last reading 10:52 PM · may be out of date")
        #expect(StaleReading.line(fetchedAt: fetched, timeFormat: .twentyFourHour, now: now, calendar: calendar) == "Last reading 22:52 · may be out of date")
    }

    @Test func namesTheDayOnceTheReadingIsNotFromToday() throws {
        let now = try date(1, 23, 10)
        #expect(StaleReading.line(fetchedAt: try date(1, 0, 5), timeFormat: .twentyFourHour, now: now, calendar: calendar) == "Last reading 00:05 · may be out of date")
        #expect(StaleReading.line(fetchedAt: try date(31, 22, 52, month: 8), timeFormat: .twelveHour, now: now, calendar: calendar) == "Last reading yesterday at 10:52 PM · may be out of date")
        #expect(StaleReading.line(fetchedAt: try date(29, 9, 0, month: 8), timeFormat: .twentyFourHour, now: now, calendar: calendar) == "Last reading Aug 29 at 09:00 · may be out of date")
    }

    @Test func aPassedResetReadsAsPassedOnlyWhenTheReadingIsStale() throws {
        let now = try date(1, 23, 10)
        let passed = try date(1, 23, 0)
        let ahead = try date(2, 0, 10)
        #expect(ResetText.line(resetsAt: passed, hasLimit: true, display: .countdown, timeFormat: .auto, stale: true, now: now, calendar: calendar) == "Reset passed")
        #expect(ResetText.line(resetsAt: passed, hasLimit: true, display: .exact, timeFormat: .auto, stale: true, now: now, calendar: calendar) == "Reset passed")
        #expect(ResetText.line(resetsAt: passed, hasLimit: true, display: .exact, timeFormat: .auto, now: now, calendar: calendar) == "Resets now")
        #expect(ResetText.line(resetsAt: ahead, hasLimit: true, display: .countdown, timeFormat: .auto, stale: true, now: now, calendar: calendar) == "Resets in 1h")
        #expect(ResetText.line(resetsAt: nil, hasLimit: false, display: .exact, timeFormat: .auto, stale: true, now: now, calendar: calendar) == "No limit published")
    }
}
