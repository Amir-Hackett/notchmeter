import Foundation

struct UsageEntry: Codable, Equatable, Sendable {
    let timestamp: Date
    let model: String?
    let tokens: TokenBreakdown
    let costUSD: Double?
    /// `message.id` + `requestId`; streaming writes the same message several times.
    let dedupeKey: String?
}

struct DailySpend: Equatable, Sendable, Identifiable {
    let day: Date
    let cost: Double
    let tokens: Int
    var id: Date { day }
}

struct CostSummary: Equatable, Sendable {
    let today: Double
    let yesterday: Double
    let last30Days: Double
    /// One entry per calendar day for the last 30 days, oldest first.
    let daily: [DailySpend]
    let unpricedModels: Set<String>
    let scannedAt: Date

    static let empty = CostSummary(today: 0, yesterday: 0, last30Days: 0, daily: [], unpricedModels: [], scannedAt: .distantPast)
}

/// Prices what Claude Code has already written to disk. Ports the ccusage rules OpenUsage also follows:
/// only assistant lines carrying `usage`, deduplicated by message id + request id keeping the first
/// occurrence in path order, a line's own `costUSD` when present, otherwise tokens times list price.
actor ClaudeCostScanner {
    private struct CachedFile: Codable {
        let size: Int
        let modified: Date
        let entries: [UsageEntry]
    }

    nonisolated let roots: [URL]
    nonisolated let cacheURL: URL?
    private var cache: [String: CachedFile] = [:]
    private var cacheLoaded = false

    init(roots: [URL] = ClaudeCostScanner.defaultRoots(), cacheURL: URL? = ClaudeCostScanner.defaultCacheURL()) {
        self.roots = roots
        self.cacheURL = cacheURL
    }

    static func defaultCacheURL() -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return caches.appendingPathComponent("Notchmeter/claude-usage-cache.json")
    }

    private func loadCacheIfNeeded() {
        guard !cacheLoaded else { return }
        cacheLoaded = true
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL),
              let stored = try? JSONDecoder().decode([String: CachedFile].self, from: data)
        else { return }
        cache = stored
    }

    private func saveCache() {
        guard let cacheURL, let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    static func defaultRoots() -> [URL] {
        var roots: [URL] = []
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            roots.append(URL(fileURLWithPath: custom))
        }
        roots.append(Paths.home.appendingPathComponent(".config/claude"))
        roots.append(Paths.home.appendingPathComponent(".claude"))
        return roots.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("projects").path) }
    }

    func scan(now: Date = Date(), daysBack: Int = 30) -> CostSummary {
        loadCacheIfNeeded()
        let files = Self.transcriptFiles(under: roots)
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day, value: -(daysBack - 1), to: calendar.startOfDay(for: now)) ?? .distantPast
        var live: Set<String> = []
        var ordered: [UsageEntry] = []
        var changed = false
        for url in files {
            let path = url.path
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            let modified = values?.contentModificationDate ?? .distantPast
            guard modified >= cutoff else { continue }
            live.insert(path)
            if let cached = cache[path], cached.size == size, cached.modified == modified {
                ordered.append(contentsOf: cached.entries)
                continue
            }
            let entries = (try? Data(contentsOf: url)).map(Self.parseFile) ?? []
            cache[path] = CachedFile(size: size, modified: modified, entries: entries)
            ordered.append(contentsOf: entries)
            changed = true
        }
        let before = cache.count
        cache = cache.filter { live.contains($0.key) }
        if changed || cache.count != before { saveCache() }
        return Self.summarize(Self.dedupe(ordered), now: now, daysBack: daysBack)
    }

    /// Every transcript under each root's projects/, path-sorted so keep-first dedupe is deterministic.
    static func transcriptFiles(under roots: [URL]) -> [URL] {
        var files: [URL] = []
        for root in roots {
            let projects = root.appendingPathComponent("projects")
            guard let enumerator = FileManager.default.enumerator(at: projects, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    static func parseFile(_ data: Data) -> [UsageEntry] {
        let marker = Data("\"usage\":{".utf8)
        var entries: [UsageEntry] = []
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            let line = data[start..<end]
            if line.range(of: marker) != nil, let entry = parseLine(line) {
                entries.append(entry)
            }
            start = end < data.endIndex ? data.index(after: end) : data.endIndex
        }
        return entries
    }

    static func parseLine(_ line: Data) -> UsageEntry? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let stamp = object["timestamp"] as? String,
              let timestamp = DateParsing.iso8601(stamp),
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let inputTokens = usage["input_tokens"] as? Int,
              let outputTokens = usage["output_tokens"] as? Int
        else { return nil }

        var tokens = TokenBreakdown(input: inputTokens, output: outputTokens)
        tokens.cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        if let creation = usage["cache_creation"] as? [String: Any] {
            tokens.cacheWrite5m = creation["ephemeral_5m_input_tokens"] as? Int ?? 0
            tokens.cacheWrite1h = creation["ephemeral_1h_input_tokens"] as? Int ?? 0
        }
        if tokens.cacheWrite5m == 0, tokens.cacheWrite1h == 0 {
            tokens.cacheWrite5m = usage["cache_creation_input_tokens"] as? Int ?? 0
        }

        let rawModel = message["model"] as? String
        let model = rawModel == "<synthetic>" ? nil : rawModel
        var key: String?
        if let id = message["id"] as? String, let request = object["requestId"] as? String, !id.isEmpty, !request.isEmpty {
            key = "\(id):\(request)"
        }
        return UsageEntry(
            timestamp: timestamp,
            model: model,
            tokens: tokens,
            costUSD: (usage["costUSD"] as? Double) ?? (object["costUSD"] as? Double),
            dedupeKey: key
        )
    }

    static func dedupe(_ entries: [UsageEntry]) -> [UsageEntry] {
        var seen: Set<String> = []
        return entries.filter { entry in
            guard let key = entry.dedupeKey else { return true }
            return seen.insert(key).inserted
        }
    }

    static func summarize(_ entries: [UsageEntry], now: Date, daysBack: Int) -> CostSummary {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        guard let windowStart = calendar.date(byAdding: .day, value: -(daysBack - 1), to: today) else { return .empty }
        var costByDay: [Date: Double] = [:]
        var tokensByDay: [Date: Int] = [:]
        var unpriced: Set<String> = []
        for entry in entries where entry.timestamp >= windowStart {
            let day = calendar.startOfDay(for: entry.timestamp)
            let cost: Double
            if let explicit = entry.costUSD {
                cost = explicit
            } else if let priced = ModelPricing.cost(of: entry.tokens, model: entry.model) {
                cost = priced
            } else {
                if let model = entry.model { unpriced.insert(model) }
                cost = 0
            }
            costByDay[day, default: 0] += cost
            tokensByDay[day, default: 0] += entry.tokens.total
        }
        var daily: [DailySpend] = []
        for offset in 0..<daysBack {
            guard let day = calendar.date(byAdding: .day, value: offset, to: windowStart) else { continue }
            daily.append(DailySpend(day: day, cost: costByDay[day] ?? 0, tokens: tokensByDay[day] ?? 0))
        }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today).flatMap { costByDay[$0] } ?? 0
        return CostSummary(
            today: costByDay[today] ?? 0,
            yesterday: yesterday,
            last30Days: daily.reduce(0) { $0 + $1.cost },
            daily: daily,
            unpricedModels: unpriced,
            scannedAt: now
        )
    }
}
