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
    }

    let url: URL
    static let keepFor: TimeInterval = 7 * 86400
    static let compactAbove = 20_000

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

    /// Appends one row per limited window of the reading; a window whose figure has not moved since its last row
    /// is skipped unless five minutes have passed, so an idle account writes little.
    func append(_ reading: UsageReading, previous: [Key: [DrainSample]], now: Date = Date()) {
        var data = Data()
        for window in reading.windows {
            guard let used = window.usedFraction else { continue }
            if let last = previous[Key(tool: reading.tool, window: window.id)]?.last,
               abs(last.used - used) < 0.0005, last.resetsAt == window.resetsAt, now.timeIntervalSince(last.t) < 300 { continue }
            let line = Line(t: now, tool: reading.tool.rawValue, window: window.id, used: used, resetsAt: window.resetsAt)
            guard let encoded = try? Self.encoder.encode(line) else { continue }
            data.append(encoded)
            data.append(0x0A)
        }
        guard !data.isEmpty else { return }
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

    /// Everything within the keep window, oldest first per window; rows older than that are dropped from the file
    /// once it has grown past a few thousand lines.
    func load(now: Date = Date()) -> [Key: [DrainSample]] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let samples = Self.parse(data, now: now)
        let lines = data.split(separator: 0x0A).count
        if lines > Self.compactAbove {
            var whole = Data()
            for (key, rows) in samples {
                for sample in rows {
                    if let encoded = try? Self.encoder.encode(Line(t: sample.t, tool: key.tool.rawValue, window: key.window, used: sample.used, resetsAt: sample.resetsAt)) {
                        whole.append(encoded)
                        whole.append(0x0A)
                    }
                }
            }
            try? whole.write(to: url, options: .atomic)
        }
        return samples
    }

    static func parse(_ data: Data, now: Date) -> [Key: [DrainSample]] {
        let cutoff = now.addingTimeInterval(-keepFor)
        var result: [Key: [DrainSample]] = [:]
        for row in data.split(separator: 0x0A) where !row.isEmpty {
            guard let line = try? decoder.decode(Line.self, from: row), line.t >= cutoff, let tool = ToolID(rawValue: line.tool) else { continue }
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
        for (previous, sample) in zip(window, window.dropFirst()) where sample.used + 0.0005 < previous.used || (sample.resetsAt != previous.resetsAt && sample.used < previous.used) {
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
