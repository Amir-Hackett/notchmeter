import Foundation

/// One observation of a window: when, how much was used, and the reset it was counting to.
struct DrainSample: Codable, Equatable, Sendable {
    let t: Date
    let used: Double
    let resetsAt: Date?
}

/// "Session 12% → 61% in the last hour": where a window stood an hour ago against now, and the measured rate.
struct Drain: Equatable, Sendable {
    let from: Double
    let to: Double
    let over: TimeInterval
    /// Fraction of the window consumed per hour over the span; nil when nothing moved.
    var perHour: Double? {
        guard over > 0, to > from else { return nil }
        return (to - from) / (over / 3600)
    }
}

/// An append-only per-window utilization log (one row per successful read, kept for seven days, a few KB a day,
/// never a token), so "my limit drained abnormally fast" has an answer: the last hour's drain under each meter, a
/// 24-hour sparkline in the card, a measured rate for the projection, and a line in `--probe`.
struct DrainLog: Sendable {
    struct Key: Hashable, Sendable {
        let tool: ToolID
        let window: String
    }

    private struct Line: Codable {
        let t: Date
        let tool: String
        let window: String
        let used: Double
        let resetsAt: Date?
        /// "extra" marks an extra-usage transition row (below); absent on a utilization row.
        var kind: String?
        /// The extra-usage credits spent, in dollars, on a transition row.
        var amount: Double?
        /// The plan windows' used fractions at that moment, by window id.
        var plan: [String: Double]?
        /// What a boundary row marks, in a few words.
        var note: String?
    }

    /// One extra-usage transition: the credits rose, from what to what, with the plan windows at that moment.
    struct ExtraUsageRow: Equatable, Sendable {
        let t: Date
        let amountUSD: Double
        let previousUSD: Double?
        let planWindows: [String: Double]
    }

    /// A moment after which a window's figures are not comparable with those before it: the vendor changed what
    /// the window measures (a cap, a denominator) while the used percentage went on reading the same. Rows
    /// either side of a boundary describe different quantities, so the metering median is floored at the newest
    /// one (`ClaudeCostScanner.metering(since:)`) and the boundary is kept whole through every compaction.
    struct Boundary: Equatable, Sendable {
        let t: Date
        let tool: ToolID
        let window: String
        let note: String?
    }

    /// Anthropic's weekly-cap change of 2026-09-14 (00:00 UTC): the weekly window's denominator moved while its
    /// percentage did not. Written once for Claude's `seven_day` on the first launch after the upgrade
    /// (`UsageStore.loadDrains`), and idempotent, so the row is there whether the app ran on the day or not.
    static let weeklyDenominatorChangedAt = Date(timeIntervalSince1970: 1_789_344_000)

    let url: URL
    static let keepFor: TimeInterval = 7 * 86400
    static let compactAbove = 20_000
    /// How long a file may go between compactions while the app stays up. Until 0.6.0 the only compaction ran in
    /// `load`, at launch, so a Mac that stayed up for weeks grew the file past the seven days it keeps until the
    /// next relaunch, and a launch after a long run then paid for the whole backlog at once. The append path now
    /// compacts once a day as well: the compaction rewrites the file, so it must stay rare, and one rewrite a day
    /// bounds the file at eight days of rows, which is the cheapest cadence that never lets it drift. The marker
    /// is the file's own creation date rather than anything held in memory: an atomic write swaps a fresh inode in
    /// under the path, so the birth time is the moment of the last rewrite (or of the first row), an ordinary
    /// append leaves it alone, and it survives a relaunch and needs no state a second process could not see.
    static let compactEvery: TimeInterval = 86400

    /// Every touch of the file goes through this one serial queue. The store appends from the main actor while
    /// `load` runs on a detached task at launch, and `load` rewrites the whole file with an atomic write once it
    /// has grown past `compactAbove`: an atomic write swaps a fresh inode in under the path, so an append that had
    /// already opened a handle and sought to the end of the old file wrote its row into an inode nothing pointed
    /// at any more, and the row was gone. Serialising the read-and-rewrite against the appends is the whole fix.
    /// The appends are enqueued asynchronously, though, because `load` does hold the queue long enough to feel:
    /// compacting a file past `compactAbove` parses it twice, re-encodes every kept row and rewrites it, about
    /// 100 ms at 20 000 lines and more after a long run, and it does so at launch, when the status line adopts its
    /// first reading on the main actor before the file is back. A synchronous append there froze the notch, the
    /// rings and the menu bar item for the whole compaction. The reads stay synchronous, so a `load` queued after
    /// an append still sees the row. Internal rather than private so a test can occupy the queue and check that
    /// an append does not wait behind it.
    static let io = DispatchQueue(label: "com.notchmeter.drainlog")

    init(url: URL = Paths.applicationSupport.appendingPathComponent("drain-log-v1.jsonl")) {
        self.url = url
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    /// True when this figure earns a row: it moved, its reset changed, or five minutes have passed since the last
    /// one, so an idle account writes little. The rule lives here, once, because the store keeps an in-memory
    /// mirror of the file and applies the same test before appending to it. Until 0.5.0 the mirror had no test at
    /// all: it grew by one sample per window on every poll however still the figure was, and after a month of
    /// uptime carried hundreds of thousands of samples that nothing would ever read, since every consumer looks
    /// back at most seven days. Two copies of the rule would drift the first time one of them was edited.
    static func moved(_ last: DrainSample?, used: Double, resetsAt: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return abs(last.used - used) >= 0.0005 || !ResetPeriod.same(last.resetsAt, resetsAt) || now.timeIntervalSince(last.t) >= 300
    }

    /// Appends one row per limited window of the reading; a window whose figure has not moved since its last row
    /// is skipped unless five minutes have passed, so an idle account writes little.
    func append(_ reading: UsageReading, previous: [Key: [DrainSample]], now: Date = Date()) {
        var data = Data()
        for window in reading.windows {
            guard let used = window.usedFraction else { continue }
            guard Self.moved(previous[Key(tool: reading.tool, window: window.id)]?.last, used: used, resetsAt: window.resetsAt, now: now) else { continue }
            let line = Line(t: now, tool: reading.tool.rawValue, window: window.id, used: used, resetsAt: window.resetsAt)
            guard let encoded = try? Self.encoder.encode(line) else { continue }
            data.append(encoded)
            data.append(0x0A)
        }
        guard !data.isEmpty else { return }
        Self.io.async { [url, data] in
            Self.write(data, to: url)
            Self.compactIfDue(at: url, now: now)
        }
    }

    /// Appends the encoded rows to the file, creating the directory and the file when they are not there yet.
    /// Runs on `io` only.
    private static func write(_ data: Data, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Rewrites the file without the rows past the keep window when its last rewrite is `compactEvery` or more
    /// behind `now`; the file's creation date is that marker (see `compactEvery`). Runs on `io` only, after an
    /// append, so it never touches the main actor and the read-and-rewrite is serialised against the appends the
    /// way the launch compaction is. A file whose birth time cannot be read is left alone rather than rewritten
    /// on every append.
    private static func compactIfDue(at url: URL, now: Date) {
        guard let born = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.creationDate] as? Date,
              now.timeIntervalSince(born) >= compactEvery,
              let data = try? Data(contentsOf: url) else { return }
        try? compacted(data, now: now).write(to: url, options: .atomic)
    }

    /// Waits until every append enqueued so far is on disk, or until `bound` passes, and says which. The appends
    /// are asynchronous on `io` (see there), and GCD does not run a queue's pending blocks when the process exits,
    /// so a row enqueued in the last milliseconds before quit -- the reading a poll adopted as the user pressed
    /// ⌘Q -- was lost until 0.6.0. `applicationWillTerminate` calls this once. The bound keeps a quit from hanging
    /// behind a compaction that has only just started; a compaction lost to the bound costs nothing, since the
    /// next one redoes the same work, and a row lost to it is the same row that was lost every time before.
    @discardableResult
    static func flush(within bound: TimeInterval = 2) -> Bool {
        let drained = DispatchSemaphore(value: 0)
        io.async { drained.signal() }
        return drained.wait(timeout: .now() + bound) == .success
    }

    /// Appends the moment extra-usage credits rose, with the plan windows' figures beside it, so the user keeps a
    /// local record of when real money started flowing and what the plan had left.
    func appendExtraUsage(tool: ToolID, amountUSD: Double, previousUSD: Double?, planWindows: [LimitWindow], now: Date = Date()) {
        let plan = planWindows.reduce(into: [String: Double]()) { if let used = $1.usedFraction { $0[$1.id] = used } }
        var line = Line(t: now, tool: tool.rawValue, window: "extra_usage", used: previousUSD ?? 0, resetsAt: nil)
        line.kind = "extra"
        line.amount = amountUSD
        line.plan = plan
        guard let encoded = try? Self.encoder.encode(line) else { return }
        Self.io.async { [url, encoded] in
            Self.write(encoded + Data([0x0A]), to: url)
        }
    }

    /// The extra-usage transitions on file, oldest first.
    func loadExtraUsage() -> [ExtraUsageRow] {
        guard let data = Self.io.sync(execute: { try? Data(contentsOf: url) }) else { return [] }
        return Self.parseExtraUsage(data)
    }

    static func parseExtraUsage(_ data: Data) -> [ExtraUsageRow] {
        data.split(separator: 0x0A).compactMap { row in
            guard let line = try? decoder.decode(Line.self, from: row), line.kind == "extra", let amount = line.amount else { return nil }
            return ExtraUsageRow(t: line.t, amountUSD: amount, previousUSD: line.used > 0 ? line.used : nil, planWindows: line.plan ?? [:])
        }.sorted { $0.t < $1.t }
    }

    /// Appends a boundary row (`kind: "boundary"`) for the window at `at`, unless one for that tool, window and
    /// moment is on file already, so a launch can write the same marker every time and the file holds it once.
    /// Returns whether a row was written.
    @discardableResult
    func appendBoundary(tool: ToolID, window: String, at: Date, note: String? = nil) -> Bool {
        let existing = loadBoundaries()
        guard !existing.contains(where: { $0.tool == tool && $0.window == window && abs($0.t.timeIntervalSince(at)) < 1 }) else { return false }
        var line = Line(t: at, tool: tool.rawValue, window: window, used: 0, resetsAt: nil)
        line.kind = "boundary"
        line.note = note
        guard let encoded = try? Self.encoder.encode(line) else { return false }
        Self.io.async { [url, encoded] in
            Self.write(encoded + Data([0x0A]), to: url)
        }
        return true
    }

    /// The boundaries on file, oldest first.
    func loadBoundaries() -> [Boundary] {
        guard let data = Self.io.sync(execute: { try? Data(contentsOf: url) }) else { return [] }
        return Self.parseBoundaries(data)
    }

    static func parseBoundaries(_ data: Data) -> [Boundary] {
        data.split(separator: 0x0A).compactMap { row in
            guard let line = try? decoder.decode(Line.self, from: row), line.kind == "boundary", let tool = ToolID(rawValue: line.tool) else { return nil }
            return Boundary(t: line.t, tool: tool, window: line.window, note: line.note)
        }.sorted { $0.t < $1.t }
    }

    /// The newest boundary for the tool at or before `now`, any window; nil without one.
    static func latestBoundary(_ boundaries: [Boundary], tool: ToolID, now: Date) -> Date? {
        boundaries.filter { $0.tool == tool && $0.t <= now }.map(\.t).max()
    }

    /// Everything within the keep window, oldest first per window; rows older than that are dropped from the file
    /// once it has grown past a few thousand lines (and once a day while the app stays up: `compactEvery`).
    func load(now: Date = Date()) -> [Key: [DrainSample]] {
        Self.io.sync {
            guard let data = try? Data(contentsOf: url) else { return [:] }
            let samples = Self.parse(data, now: now)
            let lines = data.split(separator: 0x0A).count
            if lines > Self.compactAbove {
                try? Self.compacted(data, now: now).write(to: url, options: .atomic)
            }
            return samples
        }
    }

    /// The file's content with every utilization row older than the keep window dropped: the boundaries and the
    /// extra-usage transitions first, every one of them (the record of when a window changed its meaning, and of
    /// when real money flowed, is kept whole), then each window's surviving rows oldest first. Pure, so the launch
    /// compaction and the daily one share it and a test can pin what survives.
    static func compacted(_ data: Data, now: Date) -> Data {
        var whole = Data()
        for boundary in parseBoundaries(data) {
            var line = Line(t: boundary.t, tool: boundary.tool.rawValue, window: boundary.window, used: 0, resetsAt: nil)
            line.kind = "boundary"
            line.note = boundary.note
            if let encoded = try? encoder.encode(line) {
                whole.append(encoded)
                whole.append(0x0A)
            }
        }
        for extra in parseExtraUsage(data) {
            var line = Line(t: extra.t, tool: ToolID.claude.rawValue, window: "extra_usage", used: extra.previousUSD ?? 0, resetsAt: nil)
            line.kind = "extra"
            line.amount = extra.amountUSD
            line.plan = extra.planWindows
            if let encoded = try? encoder.encode(line) {
                whole.append(encoded)
                whole.append(0x0A)
            }
        }
        for (key, rows) in parse(data, now: now) {
            for sample in rows {
                if let encoded = try? encoder.encode(Line(t: sample.t, tool: key.tool.rawValue, window: key.window, used: sample.used, resetsAt: sample.resetsAt)) {
                    whole.append(encoded)
                    whole.append(0x0A)
                }
            }
        }
        return whole
    }

    /// The file's rows folded into the samples the store recorded while the file was being read. `load` runs on a
    /// detached task at launch, and the first readings adopt before it comes back (the status line answers with no
    /// fetch at all), so by the time the parsed file lands the store already holds rows the read never saw. Those
    /// rows are on disk too, and a row appended just before the read is on both sides. Replacing the dictionary
    /// dropped the newest points from the sparkline and the last-hour drain until the next poll, and left the
    /// skip-if-unmoved rule comparing against a stale predecessor; concatenating and sorting would count a row
    /// present on both sides twice. So: one sample per timestamp, the file's copy winning, oldest first.
    static func merged(_ loaded: [Key: [DrainSample]], with live: [Key: [DrainSample]]) -> [Key: [DrainSample]] {
        loaded.merging(live) { fromFile, recorded in
            let known = Set(fromFile.map(\.t))
            return (fromFile + recorded.filter { !known.contains($0.t) }).sorted { $0.t < $1.t }
        }
    }

    static func parse(_ data: Data, now: Date) -> [Key: [DrainSample]] {
        let cutoff = now.addingTimeInterval(-keepFor)
        var result: [Key: [DrainSample]] = [:]
        for row in data.split(separator: 0x0A) where !row.isEmpty {
            guard let line = try? decoder.decode(Line.self, from: row), line.kind == nil, line.t >= cutoff, let tool = ToolID(rawValue: line.tool) else { continue }
            result[Key(tool: tool, window: line.window), default: []].append(DrainSample(t: line.t, used: line.used, resetsAt: line.resetsAt))
        }
        for key in result.keys { result[key]?.sort { $0.t < $1.t } }
        return result
    }

    /// The window's move over the last `span`: from the last row at or before the span's start (or the first row
    /// inside it) to the newest row. A reset inside the span (the figure fell, or the reset moved) starts the
    /// comparison at the first row after it, so a fresh window never reads as a negative drain.
    static func drain(_ samples: [DrainSample], span: TimeInterval = 3600, now: Date) -> Drain? {
        guard let last = samples.last, now.timeIntervalSince(last.t) < span * 2 else { return nil }
        let start = now.addingTimeInterval(-span)
        var window = samples.filter { $0.t >= start }
        if let before = samples.last(where: { $0.t < start }) { window.insert(before, at: 0) }
        guard window.count >= 2 else { return nil }
        var from = window[0]
        for (previous, sample) in zip(window, window.dropFirst()) where sample.used + 0.0005 < previous.used || (!ResetPeriod.same(sample.resetsAt, previous.resetsAt) && sample.used < previous.used) {
            from = sample
        }
        guard last.t > from.t else { return nil }
        return Drain(from: from.used, to: last.used, over: last.t.timeIntervalSince(from.t))
    }

    /// The per-hour rate measured over the last hour, when a window moved; feeds the projection in place of the
    /// even-burn assumption.
    static func rate(_ samples: [DrainSample], now: Date) -> Double? {
        drain(samples, now: now)?.perHour
    }

    /// Twenty-four hourly points, oldest first: the highest figure seen in each hour, or nil for an hour without a row.
    static func hourly(_ samples: [DrainSample], hours: Int = 24, now: Date) -> [Double?] {
        let start = now.addingTimeInterval(-TimeInterval(hours) * 3600)
        var points = [Double?](repeating: nil, count: hours)
        for sample in samples where sample.t >= start {
            let index = min(hours - 1, max(0, Int(sample.t.timeIntervalSince(start) / 3600)))
            points[index] = max(points[index] ?? 0, sample.used)
        }
        return points
    }

    /// "12% → 61% in the last hour".
    static func line(_ drain: Drain) -> String {
        L("%1$ld%% → %2$ld%% in the last hour", Int((drain.from * 100).rounded()), Int((drain.to * 100).rounded()))
    }
}
