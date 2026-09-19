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
        let sixtyEightMinutes = 68.0 * 60
        #expect(abs(drain.over - sixtyEightMinutes) < 1)
        let expectedPerHour = 0.49 / (68.0 / 60.0)
        let perHour = try #require(drain.perHour)
        #expect(abs(perHour - expectedPerHour) < 1e-9)
        #expect(DrainLog.line(drain) == "12% → 61% in the last hour")
        let measured = try #require(DrainLog.rate(rows, now: now))
        #expect(abs(measured - drain.perHour!) < 1e-12)
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
        let afterTheMove = loaded[key]?.map(\.used)
        #expect(afterTheMove == [0.2, 0.35])
        let text = try String(contentsOf: log.url, encoding: .utf8)
        #expect(!text.contains("token"))
        #expect(text.split(separator: "\n").count == 3)
    }

    /// The appends are enqueued, not waited for. `load` holds the queue for the whole compaction at launch, and the
    /// status line adopts its first reading on the main actor before the file is back, so a synchronous append
    /// there froze the notch, the rings and the menu bar item until the rewrite finished (0.5.0). A held block
    /// stands in for the compaction here: the append must come back while the queue is still occupied, and the row
    /// must be on file once it is free, since the reads stay behind the appends.
    @Test func anAppendDoesNotWaitBehindTheQueue() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-drain-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = DrainLog(url: dir.appendingPathComponent("drain.jsonl"))
        let reading = UsageReading(tool: .claude, windows: [
            LimitWindow(id: "five_hour", label: "Session", usedFraction: 0.2, resetsAt: nil, periodDuration: Period.fiveHours),
        ], plan: nil, fetchedAt: now, observedAt: nil)

        let gate = DispatchSemaphore(value: 0)
        DrainLog.io.async { gate.wait() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { gate.signal() }
        let began = Date()
        log.append(reading, previous: [:], now: now)
        let waited = Date().timeIntervalSince(began)
        #expect(waited < 0.5, "the append waited \(waited)s for the queue")

        let loaded = log.load(now: now)
        #expect(loaded[DrainLog.Key(tool: .claude, window: "five_hour")]?.map(\.used) == [0.2])
    }

    /// The file is compacted once a day while the app stays up, not only at launch (0.6.0). The marker is the
    /// file's creation date, which an append leaves alone and an atomic rewrite refreshes, so the test ages the
    /// file by setting it back rather than waiting. The append that finds it a day old drops the rows past the
    /// keep window and keeps every window's rows inside it, oldest first, and every extra-usage transition; the
    /// append after that finds a fresh birth time and leaves the file alone.
    @Test func anAppendCompactsTheFileOnceADay() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-drain-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = DrainLog(url: dir.appendingPathComponent("drain.jsonl"))
        let reset = now.addingTimeInterval(3600)
        func reading(_ used: Double) -> UsageReading {
            UsageReading(tool: .claude, windows: [
                LimitWindow(id: "five_hour", label: "Session", usedFraction: used, resetsAt: reset, periodDuration: Period.fiveHours),
                LimitWindow(id: "seven_day", label: "Weekly", usedFraction: used, resetsAt: reset, periodDuration: Period.week),
            ], plan: nil, fetchedAt: now, observedAt: nil)
        }
        func lines() throws -> Int {
            try String(contentsOf: log.url, encoding: .utf8).split(separator: "\n").count
        }
        // Two rows past the keep window, one extra-usage transition older still, two rows an hour old.
        log.appendExtraUsage(tool: .claude, amountUSD: 4, previousUSD: nil, planWindows: [], now: now.addingTimeInterval(-9 * 86400))
        log.append(reading(0.2), previous: [:], now: now.addingTimeInterval(-8 * 86400))
        log.append(reading(0.3), previous: [:], now: now.addingTimeInterval(-3600))
        DrainLog.flush()
        let beforeAnyCompaction = 5
        #expect(try lines() == beforeAnyCompaction)
        // Age the file: born a little over a day before the append that follows.
        try FileManager.default.setAttributes([.creationDate: now.addingTimeInterval(-DrainLog.compactEvery - 60)], ofItemAtPath: log.url.path)

        log.append(reading(0.5), previous: log.load(now: now), now: now)
        DrainLog.flush()
        // The transition, and two rows per window: the stale pair left, the fresh pair arrived.
        let afterTheDailyCompaction = 5
        #expect(try lines() == afterTheDailyCompaction)
        let loaded = log.load(now: now)
        let keptOldestFirst = [0.3, 0.5]
        #expect(loaded[DrainLog.Key(tool: .claude, window: "five_hour")]?.map(\.used) == keptOldestFirst)
        #expect(loaded[DrainLog.Key(tool: .claude, window: "seven_day")]?.map(\.used) == keptOldestFirst)
        #expect(log.loadExtraUsage().map(\.amountUSD) == [4])

        // The rewrite refreshed the birth time, so the next append is an append and nothing more. A line count
        // cannot tell the two apart: every surviving row is inside the keep window, so a second rewrite would
        // also leave seven lines. What an append leaves is the birth time as the rewrite set it and the
        // compacted text intact at the head of the file, where a rewrite regroups the rows per window and
        // moves the new pair in among them.
        func born() throws -> Date? {
            try FileManager.default.attributesOfItem(atPath: log.url.path)[.creationDate] as? Date
        }
        let bornAtTheRewrite = try #require(try born())
        #expect(now.timeIntervalSince(bornAtTheRewrite) < DrainLog.compactEvery)
        let asCompacted = try String(contentsOf: log.url, encoding: .utf8)
        log.append(reading(0.6), previous: loaded, now: now.addingTimeInterval(60))
        DrainLog.flush()
        let oneMoreRowPerWindow = 7
        #expect(try lines() == oneMoreRowPerWindow)
        #expect(try born() == bornAtTheRewrite)
        let appendedInPlace = try String(contentsOf: log.url, encoding: .utf8)
        #expect(appendedInPlace.hasPrefix(asCompacted))
    }

    /// `flush` is what `applicationWillTerminate` calls: the appends are asynchronous on the serial queue, and GCD
    /// does not run a queue's pending blocks when the process exits, so a row enqueued in the last milliseconds
    /// before quit was lost until 0.6.0. A held block stands in for whatever the queue is busy with: `flush` must
    /// come back only once the row behind it is on disk, read here without the queue's help, and it must give up
    /// at its bound rather than hang a quit behind a compaction.
    @Test func flushReturnsOnceAPendingAppendIsOnDiskAndGivesUpAtItsBound() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-drain-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = DrainLog(url: dir.appendingPathComponent("drain.jsonl"))
        let reading = UsageReading(tool: .claude, windows: [
            LimitWindow(id: "five_hour", label: "Session", usedFraction: 0.2, resetsAt: nil, periodDuration: Period.fiveHours),
        ], plan: nil, fetchedAt: now, observedAt: nil)

        let busy = DispatchSemaphore(value: 0)
        DrainLog.io.async { busy.wait() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { busy.signal() }
        log.append(reading, previous: [:], now: now)
        let began = Date()
        let drained = DrainLog.flush()
        let waited = Date().timeIntervalSince(began)
        #expect(drained)
        let atLeastTheHeldBlock = 0.25
        #expect(waited >= atLeastTheHeldBlock, "flush came back after \(waited)s, before the queue was free")
        let onDisk = try Data(contentsOf: log.url)
        #expect(DrainLog.parse(onDisk, now: now)[DrainLog.Key(tool: .claude, window: "five_hour")]?.map(\.used) == [0.2])

        let stuck = DispatchSemaphore(value: 0)
        DrainLog.io.async { stuck.wait() }
        let gaveUp = DrainLog.flush(within: 0.2)
        stuck.signal()
        #expect(!gaveUp)
        #expect(DrainLog.flush())
    }

    /// The wiring rather than the file format. The log skips a window that has not moved since its last row, so the
    /// store must hand it the samples as they stood *before* the reading being recorded. Handing over the dictionary
    /// it had just written to made every window its own predecessor: every row was skipped as unchanged, the file
    /// was never created, and the seven days of history behind the run-out estimate, the card's sparkline and
    /// `--probe` were empty on every Mac the app ran on.
    @MainActor @Test func theStoreLogsTheFirstReadingAndEveryMoveAfterIt() throws {
        let suite = "NotchmeterTests.Drain.wiring"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-drain-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = DrainLog(url: dir.appendingPathComponent("drain.jsonl"))
        let store = UsageStore(prefs: Preferences(defaults: defaults), providers: [], cache: ReadingCache(defaults: defaults),
                               defaults: defaults, drainLog: log, reportFile: nil)
        let reset = now.addingTimeInterval(3600)
        func reading(_ used: Double) -> UsageReading {
            UsageReading(tool: .cursor, windows: [
                LimitWindow(id: "included", label: "Included usage", usedFraction: used, resetsAt: reset, periodDuration: Period.week),
            ], plan: nil, fetchedAt: now, observedAt: nil)
        }
        let key = DrainLog.Key(tool: .cursor, window: "included")
        store.recordDrain(reading(0.55), now: now)
        let firstReading = log.load(now: now)[key]?.map(\.used)
        #expect(firstReading == [0.55])
        store.recordDrain(reading(1), now: now.addingTimeInterval(60))
        let afterTheMove = log.load(now: now)[key]?.map(\.used)
        #expect(afterTheMove == [0.55, 1])
    }

    /// The in-memory mirror obeys the file's rules. Until 0.5.0 it did not: the file skipped a window whose figure
    /// had not moved, the dictionary beside it appended a sample on every poll regardless, and nothing ever trimmed
    /// it, so a month of uptime left hundreds of thousands of samples that `recomputeDrains` re-filtered several
    /// times a minute and that no consumer, all of which look back at most seven days, would ever read.
    @MainActor @Test func theStoreKeepsItsMirrorAsThinAsTheFile() throws {
        let suite = "NotchmeterTests.Drain.mirror"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(prefs: Preferences(defaults: defaults), providers: [], cache: ReadingCache(defaults: defaults),
                               defaults: defaults, drainLog: nil, reportFile: nil)
        let reset = now.addingTimeInterval(8 * 86400)
        func reading(_ used: Double) -> UsageReading {
            UsageReading(tool: .cursor, windows: [
                LimitWindow(id: "included", label: "Included usage", usedFraction: used, resetsAt: reset, periodDuration: Period.week),
            ], plan: nil, fetchedAt: now, observedAt: nil)
        }
        let key = DrainLog.Key(tool: .cursor, window: "included")
        store.recordDrain(reading(0.55), now: now)
        // The same figure a minute later is not a sample; the same figure five minutes on is.
        store.recordDrain(reading(0.55), now: now.addingTimeInterval(60))
        #expect(store.drainSamples[key]?.count == 1)
        store.recordDrain(reading(0.55), now: now.addingTimeInterval(300))
        #expect(store.drainSamples[key]?.count == 2)
        // Eight days on, both of those rows are past the keep window and leave; only the new one remains.
        let eightDaysOn = now.addingTimeInterval(8 * 86400 - 3600)
        store.recordDrain(reading(0.60), now: eightDaysOn)
        let afterTheTrim = store.drainSamples[key]?.map(\.used)
        #expect(afterTheTrim == [0.60])
    }

    /// The one rule the file and its mirror share.
    @Test func aFigureEarnsARowWhenItMovesItsResetChangesOrFiveMinutesPass() {
        let reset = now.addingTimeInterval(3600)
        let last = DrainSample(t: now, used: 0.40, resetsAt: reset)
        #expect(DrainLog.moved(nil, used: 0.40, resetsAt: reset, now: now))
        #expect(!DrainLog.moved(last, used: 0.40, resetsAt: reset, now: now.addingTimeInterval(60)))
        #expect(!DrainLog.moved(last, used: 0.4004, resetsAt: reset, now: now.addingTimeInterval(60)))
        #expect(DrainLog.moved(last, used: 0.41, resetsAt: reset, now: now.addingTimeInterval(60)))
        #expect(DrainLog.moved(last, used: 0.40, resetsAt: reset.addingTimeInterval(5 * 3600), now: now.addingTimeInterval(60)))
        #expect(DrainLog.moved(last, used: 0.40, resetsAt: reset, now: now.addingTimeInterval(300)))
    }

    /// The launch load lands after the first readings. The file's rows fold into what the store recorded in the
    /// meantime: a row on both sides counts once, a row only the store saw survives, and a window only the store
    /// saw survives whole. Replacing the dictionary lost the newest points; concatenating doubled the shared one.
    @Test func theFileFoldsIntoWhatTheStoreRecordedWhileItWasBeingRead() {
        let key = DrainLog.Key(tool: .claude, window: "five_hour")
        let other = DrainLog.Key(tool: .codex, window: "primary")
        let loaded: [DrainLog.Key: [DrainSample]] = [key: [sample(120, 0.10), sample(60, 0.20)]]
        let live: [DrainLog.Key: [DrainSample]] = [key: [sample(60, 0.20), sample(1, 0.30)], other: [sample(1, 0.05)]]
        let merged = DrainLog.merged(loaded, with: live)
        let oneOfEach = [0.10, 0.20, 0.30]
        #expect(merged[key]?.map(\.used) == oneOfEach)
        #expect(merged[other]?.map(\.used) == [0.05])
        let untouched = DrainLog.merged(loaded, with: [:])
        #expect(untouched == loaded)
    }

    /// A reset that is not a fixed instant. Claude's windows arrive carrying a moment that moves on every read —
    /// three windows of one reading were seen a millisecond apart, and one window's reset wandered inside a
    /// two-second band while its figure did not move at all. Compared exactly, every read looked like a new period:
    /// the log wrote a row each time however still the figure was, and `RunOutInterval` discarded every consecutive
    /// pair as spanning a reset, so no run-out estimate could ever form for that tool.
    @Test func aResetReportedAMomentApartIsStillTheSamePeriod() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-drain-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = DrainLog(url: dir.appendingPathComponent("drain.jsonl"))
        let reset = now.addingTimeInterval(4 * 3600)
        func reading(driftingBy drift: TimeInterval) -> UsageReading {
            UsageReading(tool: .claude, windows: [
                LimitWindow(id: "seven_day", label: "Weekly", usedFraction: 0.68,
                            resetsAt: reset.addingTimeInterval(drift), periodDuration: Period.week),
            ], plan: nil, fetchedAt: now, observedAt: nil)
        }
        let key = DrainLog.Key(tool: .claude, window: "seven_day")
        log.append(reading(driftingBy: 0), previous: [:], now: now)
        var loaded = log.load(now: now)
        #expect(loaded[key]?.count == 1)
        // The same figure a minute later, its reset phrased half a second along: nothing happened, nothing is written.
        log.append(reading(driftingBy: 0.53), previous: loaded, now: now.addingTimeInterval(60))
        loaded = log.load(now: now)
        #expect(loaded[key]?.count == 1)
        // And two rows whose resets drifted apart still measure a rate, rather than reading as a reset between them.
        let drifted = [DrainSample(t: now.addingTimeInterval(-3600), used: 0.60, resetsAt: reset),
                       DrainSample(t: now, used: 0.68, resetsAt: reset.addingTimeInterval(-0.87))]
        #expect(RunOutInterval.hourlyRates(drifted, since: now.addingTimeInterval(-7200)).count == 1)
        // A real reset is never this close to the one before it: the shortest window the app meters is five hours.
        #expect(ResetPeriod.same(reset, reset.addingTimeInterval(599)))
        #expect(!ResetPeriod.same(reset, reset.addingTimeInterval(601)))
        #expect(ResetPeriod.same(nil, nil))
        #expect(!ResetPeriod.same(reset, nil))
    }
}
