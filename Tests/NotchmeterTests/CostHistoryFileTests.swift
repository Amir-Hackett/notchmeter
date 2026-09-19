import Foundation
import Testing
@testable import Notchmeter

/// How the daily-history file is written: what a failed append may and may not do to the days already in it, and
/// three writers on one file at once.
///
/// Until 2026-09-19 a failed `FileHandle(forWritingTo:)` on an existing file fell through to
/// `appended.write(to: url, options: .atomic)`, which replaced the whole history with the handful of lines that
/// had just changed: every day older than the transcripts, gone, with nothing to rebuild it from. The append is
/// now an `open(2)` with O_CREAT, so the only file that branch was meant for (none yet) needs no fallback, and a
/// failure leaves the file alone until the next scan tries again.
@Suite struct DailyHistoryWrites {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func days(_ range: Range<Int>, from: Date, cost: Double) -> [Date: CostHistory.Record] {
        range.reduce(into: [:]) { days, offset in
            guard let day = utc.date(byAdding: .day, value: -offset, to: from) else { return }
            days[day] = CostHistory.Record(cost: cost + Double(offset) / 100, tokens: TokenBreakdown(input: 10), byModel: [:], byProject: [:])
        }
    }

    static func directory(_ name: String) throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("notchmeter-\(name)-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The file exists but cannot be opened for writing. The days already in it must survive; the new ones may wait.
    @Test func anAppendThatCannotOpenTheFileLeavesTheHistoryAlone() throws {
        let fm = FileManager.default
        let dir = try Self.directory("history-readonly")
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("daily-history-v1.jsonl")
        let today = Self.utc.startOfDay(for: Date())
        let history = CostHistory(url: url, tool: .claude)
        history.record(Self.days(0..<10, from: today, cost: 1), existing: [:], calendar: Self.utc)
        let before = try Data(contentsOf: url)
        let storedDays = 10
        #expect(history.load(calendar: Self.utc).count == storedDays)

        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        history.record(Self.days(10..<15, from: today, cost: 2), existing: history.load(calendar: Self.utc), calendar: Self.utc)

        let after = try Data(contentsOf: url)
        #expect(after == before, "a failed open rewrote the file: \(after.count) bytes for \(before.count)")
        #expect(history.load(calendar: Self.utc).count == storedDays)
    }

    /// Three tools' scanners, each on its own actor, appending to the one file at once. Before the lock, two
    /// writers could resolve the same end offset and one line landed on top of the other.
    @Test func threeWritersAtOnceLoseNoDayAndTearNoLine() throws {
        let fm = FileManager.default
        let dir = try Self.directory("history-writers")
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("daily-history-v1.jsonl")
        let today = Self.utc.startOfDay(for: Date())
        let tools: [ToolID] = [.claude, .cursor, .codex]
        let perTool = 300
        let plans = tools.enumerated().map { index, tool in
            (CostHistory(url: url, tool: tool), Self.days(0..<perTool, from: today, cost: Double(index + 1)))
        }

        DispatchQueue.concurrentPerform(iterations: plans.count) { index in
            let (history, days) = plans[index]
            for (day, record) in days {
                history.record([day: record], existing: [:], calendar: Self.utc)
            }
        }

        for (history, days) in plans {
            let loaded = history.load(calendar: Self.utc)
            #expect(loaded.count == perTool, "\(history.tool.rawValue) kept \(loaded.count) of \(perTool) days")
            for (day, record) in days {
                #expect(loaded[day]?.cost == record.cost)
            }
        }
        let lines = try Data(contentsOf: url).split(separator: 0x0A)
        let expectedLines = perTool * tools.count
        #expect(lines.count == expectedLines)
        let torn = lines.filter { (try? JSONSerialization.jsonObject(with: $0)) == nil }.count
        #expect(torn == 0, "\(torn) lines do not parse")
    }
}

/// The move from ~/Library/Caches to Application Support (2026-09-19): the file is merged, not copied over or
/// skipped, because the `notchmeter` command may have written the new file before the app first launched the build
/// that moved it; and a process that never runs the launch path reads the old file until the move has happened.
@Suite struct DailyHistoryMigration {
    static let utc = DailyHistoryWrites.utc

    static func record(_ cost: Double) -> CostHistory.Record {
        CostHistory.Record(cost: cost, tokens: TokenBreakdown(input: 10), byModel: [:], byProject: [:])
    }

    @Test func legacyAndNewFilesMergeAndTheNewerReadingWins() throws {
        let fm = FileManager.default
        let dir = try DailyHistoryWrites.directory("history-migration")
        defer { try? fm.removeItem(at: dir) }
        let old = dir.appendingPathComponent("Caches/daily-history-v1.jsonl")
        let new = dir.appendingPathComponent("Application Support/daily-history-v1.jsonl")
        let today = Self.utc.startOfDay(for: Date())
        let yesterday = Self.utc.date(byAdding: .day, value: -1, to: today)!
        let earlier = Self.utc.date(byAdding: .day, value: -40, to: today)!

        // An older build left Claude's and Cursor's days in Caches; the new build has already scanned Claude once.
        CostHistory(url: old, tool: .claude).record([earlier: Self.record(3), yesterday: Self.record(1)], existing: [:], calendar: Self.utc)
        CostHistory(url: old, tool: .cursor).record([earlier: Self.record(0.5)], existing: [:], calendar: Self.utc)
        CostHistory(url: new, tool: .claude).record([yesterday: Self.record(2), today: Self.record(4)], existing: [:], calendar: Self.utc)

        CostHistory.migrateFromCaches(old: old, new: new)

        #expect(!fm.fileExists(atPath: old.path))
        let claude = CostHistory(url: new, tool: .claude).load(calendar: Self.utc)
        let cursor = CostHistory(url: new, tool: .cursor).load(calendar: Self.utc)
        let claudeDays = 3
        #expect(claude.count == claudeDays)
        #expect(claude[earlier]?.cost == 3)
        #expect(claude[yesterday]?.cost == 2, "the reading the new build wrote lost to the legacy one")
        #expect(claude[today]?.cost == 4)
        #expect(cursor.count == 1)
        #expect(cursor[earlier]?.cost == 0.5)
    }

    @Test func aSecondCallAndANewFileAloneChangeNothing() throws {
        let fm = FileManager.default
        let dir = try DailyHistoryWrites.directory("history-migration-twice")
        defer { try? fm.removeItem(at: dir) }
        let old = dir.appendingPathComponent("Caches/daily-history-v1.jsonl")
        let new = dir.appendingPathComponent("Application Support/daily-history-v1.jsonl")
        let today = Self.utc.startOfDay(for: Date())
        CostHistory(url: old, tool: .claude).record([today: Self.record(1)], existing: [:], calendar: Self.utc)
        let legacy = try Data(contentsOf: old)

        // No new file yet: the legacy file is carried over as it stands.
        CostHistory.migrateFromCaches(old: old, new: new)
        #expect(try Data(contentsOf: new) == legacy)
        #expect(!fm.fileExists(atPath: old.path))

        // Nothing left to move: the new file is untouched, byte for byte.
        CostHistory.migrateFromCaches(old: old, new: new)
        #expect(try Data(contentsOf: new) == legacy)

        // And a fresh install with no legacy file at all ends with no new file either.
        let empty = dir.appendingPathComponent("Empty/daily-history-v1.jsonl")
        CostHistory.migrateFromCaches(old: dir.appendingPathComponent("Nowhere/daily-history-v1.jsonl"), new: empty)
        #expect(!fm.fileExists(atPath: empty.path))
    }

    /// The status line or the command reading before the app has launched the build that moved the file.
    @Test func loadFallsBackToTheLegacyFileUntilTheMove() throws {
        let fm = FileManager.default
        let dir = try DailyHistoryWrites.directory("history-fallback")
        defer { try? fm.removeItem(at: dir) }
        let old = dir.appendingPathComponent("Caches/daily-history-v1.jsonl")
        let new = dir.appendingPathComponent("Application Support/daily-history-v1.jsonl")
        let today = Self.utc.startOfDay(for: Date())
        CostHistory(url: old, tool: .claude).record([today: Self.record(1.5)], existing: [:], calendar: Self.utc)

        let reader = CostHistory(url: new, tool: .claude, legacy: old)
        #expect(reader.load(calendar: Self.utc)[today]?.cost == 1.5)
        // Once the new file exists it is the only one read, even when it holds less.
        CostHistory(url: new, tool: .claude).record([today: Self.record(0.25)], existing: [:], calendar: Self.utc)
        #expect(reader.load(calendar: Self.utc)[today]?.cost == 0.25)
        // A test's own URL never reaches for the real legacy file.
        #expect(CostHistory(url: new, tool: .claude).legacy == nil)
    }
}
