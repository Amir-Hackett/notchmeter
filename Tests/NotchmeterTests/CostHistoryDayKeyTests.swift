import Foundation
import Testing
@testable import Notchmeter

/// The day keys the shared history file is written and read with.
///
/// `key` and `day` used to share one `DateFormatter` and restamp its `timeZone` on every call. The scanners, the
/// report and the store all reach them at once with different calendars, so one call's time zone could land
/// inside another's read: two adjacent days collapsed onto one key, and a compaction that dedupes by
/// "tool/day" then dropped a day outright. These pin the keys themselves and the behaviour under concurrency.
@Suite struct CostHistoryDayKeys {
    private static let utc = calendar("UTC")
    private static let tokyo = calendar("Asia/Tokyo")

    private static func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    /// A fresh formatter per call: the oracle must not be the thing under test.
    private static func formatted(_ date: Date, _ calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = calendar.timeZone
        return formatter.string(from: date)
    }

    @Test func keysReadTheCalendarsOwnTimeZone() {
        // 2026-09-02 22:30 UTC, which is already the 3rd in Tokyo.
        let moment = Self.utc.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 22, minute: 30))!
        #expect(CostHistory.key(moment, calendar: Self.utc) == "2026-09-02")
        #expect(CostHistory.key(moment, calendar: Self.tokyo) == "2026-09-03")
        #expect(CostHistory.day("2026-09-02", calendar: Self.utc) == Self.utc.startOfDay(for: moment))
        #expect(CostHistory.day("2026-09-03", calendar: Self.tokyo) == Self.tokyo.startOfDay(for: moment))
    }

    @Test func singleDigitMonthsAndDaysArePadded() {
        let moment = Self.utc.date(from: DateComponents(year: 2026, month: 1, day: 5))!
        #expect(CostHistory.key(moment, calendar: Self.utc) == "2026-01-05")
        #expect(CostHistory.day("2026-01-05", calendar: Self.utc) == moment)
    }

    @Test func aKeyThatIsNotADayIsNotADate() {
        for key in ["", "2026-09", "2026-09-02-01", "2026-13-01", "2026-02-30", "2026-9-2x", "notaday", "٢٠٢٦-٠٩-٠٢"] {
            #expect(CostHistory.day(key, calendar: Self.utc) == nil, "\(key) parsed as a day")
        }
    }

    /// Two calendars asking at once. Against the shared mutable formatter this failed within a few iterations.
    @Test func twoTimeZonesAtOnceStillGetTheirOwnDays() {
        let start = Self.utc.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 22, minute: 30))!
        let lock = NSLock()
        var wrong: [String] = []
        DispatchQueue.concurrentPerform(iterations: 2000) { iteration in
            let calendar = iteration.isMultiple(of: 2) ? Self.utc : Self.tokyo
            let moment = start.addingTimeInterval(Double(iteration) * 3600)
            let expected = Self.formatted(moment, calendar)
            let key = CostHistory.key(moment, calendar: calendar)
            let round = CostHistory.day(key, calendar: calendar)
            guard key != expected || round != calendar.startOfDay(for: moment) else { return }
            lock.lock()
            wrong.append("\(calendar.timeZone.identifier): \(key) for \(expected)")
            lock.unlock()
        }
        #expect(wrong.isEmpty, "\(wrong.count) wrong keys, first \(wrong.first ?? "")")
    }

    /// The symptom the race produced: a day lost from the file because two of them compacted onto one key.
    @Test func compactionKeepsEveryDayWhileAnotherCalendarReads() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("notchmeter-day-keys-\(UUID().uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let history = CostHistory(url: directory.appendingPathComponent("daily-history-v1.jsonl"), tool: .cursor)
        let today = Self.utc.startOfDay(for: Date())
        var days: [Date: CostHistory.Record] = [:]
        for offset in 0..<(CostHistory.compactAbove + 1) {
            days[today.addingTimeInterval(Double(-offset) * 86400)] = CostHistory.Record(cost: 0.5, tokens: TokenBreakdown(input: 10), byModel: [:], byProject: [:])
        }
        let reading = Thread { while !Thread.current.isCancelled { _ = CostHistory.key(Date(), calendar: Self.tokyo) } }
        reading.start()
        defer { reading.cancel() }
        history.record(days, existing: [:], calendar: Self.utc)
        #expect(history.load(calendar: Self.utc).count == CostHistory.compactAbove + 1)
    }
}
