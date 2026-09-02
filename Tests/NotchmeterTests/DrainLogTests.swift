import Foundation
import Testing
@testable import Notchmeter

/// The utilization log: rows in, the last hour's move and the measured rate out, resets never read as negative drain.
@Suite struct DrainLogRules {
    init() { Localization.use(language: "en") }

    let now = DateParsing.iso8601("2026-09-01T12:00:00Z")!

    func sample(_ minutesAgo: Double, _ used: Double, reset: Date? = nil) -> DrainSample {
        DrainSample(t: now.addingTimeInterval(-minutesAgo * 60), used: used, resetsAt: reset)
    }

    @Test func drainOverTheLastHourFromTheRowBeforeItToTheNewest() throws {
        let rows = [sample(150, 0.05), sample(70, 0.12), sample(40, 0.30), sample(2, 0.61)]
        let drain = try #require(DrainLog.drain(rows, now: now))
        #expect(drain.from == 0.12)
        #expect(drain.to == 0.61)
        #expect(abs(drain.over - 68 * 60) < 1)
        #expect(abs(try #require(drain.perHour) - 0.49 / (68 / 60)) < 1e-9)
        #expect(DrainLog.line(drain) == "12% → 61% in the last hour")
        #expect(abs(try #require(DrainLog.rate(rows, now: now)) - drain.perHour!) < 1e-12)
    }

    @Test func aResetInsideTheHourStartsTheComparisonAfterIt() throws {
        let old = now.addingTimeInterval(-600)
        let next = now.addingTimeInterval(4 * 3600)
        let rows = [sample(50, 0.90, reset: old), sample(30, 0.97, reset: old), sample(20, 0.02, reset: next), sample(1, 0.15, reset: next)]
        let drain = try #require(DrainLog.drain(rows, now: now))
        #expect(drain.from == 0.02)
        #expect(drain.to == 0.15)
    }

    @Test func nothingWithoutTwoRowsOrWithStaleRows() {
        #expect(DrainLog.drain([], now: now) == nil)
        #expect(DrainLog.drain([sample(5, 0.5)], now: now) == nil)
        #expect(DrainLog.drain([sample(300, 0.1), sample(200, 0.5)], now: now) == nil)
        #expect(DrainLog.drain([sample(30, 0.5), sample(1, 0.5)], now: now)?.perHour == nil)
    }

    @Test func hourlyPointsKeepTheHighestFigurePerHour() {
        let rows = [sample(23 * 60 + 30, 0.10), sample(60 + 10, 0.40), sample(60 + 5, 0.45), sample(5, 0.61)]
        let points = DrainLog.hourly(rows, now: now)
        #expect(points.count == 24)
        #expect(points[0] == 0.10)
        #expect(points[22] == 0.45)
        #expect(points[23] == 0.61)
        #expect(points[10] == nil)
    }

    @Test func appendsSkipsUnchangedRowsAndReadsBackSevenDays() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-drain-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = DrainLog(url: dir.appendingPathComponent("drain.jsonl"))
        let reset = now.addingTimeInterval(3600)
        let reading = UsageReading(tool: .claude, windows: [
            LimitWindow(id: "five_hour", label: "Session", usedFraction: 0.2, resetsAt: reset, periodDuration: Period.fiveHours),
            LimitWindow(id: "extra", label: "Extra", usedFraction: nil, resetsAt: nil),
        ], plan: nil, fetchedAt: now, observedAt: nil)
        log.append(reading, previous: [:], now: now.addingTimeInterval(-8 * 86400))
        log.append(reading, previous: [:], now: now.addingTimeInterval(-60))
        var loaded = log.load(now: now)
        let key = DrainLog.Key(tool: .claude, window: "five_hour")
        #expect(loaded[key]?.count == 1)
        #expect(loaded.keys.count == 1)
        log.append(reading, previous: loaded, now: now)
        loaded = log.load(now: now)
        #expect(loaded[key]?.count == 1)
        let moved = UsageReading(tool: .claude, windows: [LimitWindow(id: "five_hour", label: "Session", usedFraction: 0.35, resetsAt: reset, periodDuration: Period.fiveHours)],
                                 plan: nil, fetchedAt: now, observedAt: nil)
        log.append(moved, previous: loaded, now: now)
        loaded = log.load(now: now)
        #expect(loaded[key]?.map(\.used) == [0.2, 0.35])
        let text = try String(contentsOf: log.url, encoding: .utf8)
        #expect(!text.contains("token"))
        #expect(text.split(separator: "\n").count == 3)
    }
}
