import Foundation

/// One turn's token usage from a Codex session rollout, with the model and folder the turn ran under.
struct CodexUsage: Equatable, Sendable {
    let timestamp: Date
    let model: String?
    let project: String?
    let tokens: TokenBreakdown
    /// The rollout's `response_id`; one turn is recorded once per response, and a resumed session replays it.
    let dedupeKey: String?

    init(timestamp: Date, model: String?, project: String? = nil, tokens: TokenBreakdown, dedupeKey: String? = nil) {
        self.timestamp = timestamp
        self.model = model
        self.project = project
        self.tokens = tokens
        self.dedupeKey = dedupeKey
    }
}

/// Prices what Codex has already written to disk. Codex records each turn's token usage in its session rollouts
/// under `$CODEX_HOME/sessions`: a `token_usage_record` line per response (codex-rs `TokenUsageRecord`), and on
/// older builds a `token_count` event carrying `TokenUsageInfo`, whose `last_token_usage` is the turn just
/// finished. The model comes from the `turn_context` line that opened the turn and the folder from its `cwd`.
/// The rules and their sources are written down in docs/accuracy.md.
///
/// With no sessions on the Mac the scan answers nil: Codex shows no cost at all rather than $0.
actor CodexCostScanner {
    private struct CachedFile {
        let size: Int
        let modified: Date
        let pricing: String
        let days: [Date: CostHistory.Record]
        /// Clock hours (UTC-aligned) with at least one entry, and what each cost.
        let costByHour: [Int: Double]
        /// Kept only while the file is inside the fine horizon, for the last-hour figure.
        let entries: [CodexUsage]?
        let unpriced: Set<String>
        /// Turns whose rollout never named a model, which cannot be priced at all.
        let unmodelled: Int

        func withoutEntries() -> CachedFile {
            CachedFile(size: size, modified: modified, pricing: pricing, days: days, costByHour: costByHour,
                       entries: nil, unpriced: unpriced, unmodelled: unmodelled)
        }
    }

    nonisolated let root: URL
    nonisolated let history: CostHistory?
    private var cache: [String: CachedFile] = [:]
    /// The last hour needs entry times; everything longer is answered from the day records and the hour buckets.
    static let fineHorizon: TimeInterval = 2 * 3600

    init(root: URL = CodexProvider.defaultHome(), history: CostHistory? = CostHistory(tool: .codex)) {
        self.root = root
        self.history = history
    }

    nonisolated var sessionsFolder: URL { root.appendingPathComponent("sessions") }

    /// Prices every rollout touched inside the window, folds the day totals into the durable history and answers
    /// with Codex's own ProviderCost. nil when there is nothing to price.
    func scan(now: Date = Date(), daysBack: Int = 30, weekStart: Date, calendar: Calendar = .current) -> ProviderCost? {
        let cutoff = calendar.date(byAdding: .day, value: -(daysBack - 1), to: calendar.startOfDay(for: now)) ?? .distantPast
        let firstHour = Int(cutoff.timeIntervalSince1970 / 3600)
        let pricing = OpenAIPricing.fingerprint
        let fineSince = now.addingTimeInterval(-Self.fineHorizon)
        var live: Set<String> = []
        var days: [Date: CostHistory.Record] = [:]
        var costByHour: [Int: Double] = [:]
        var unpriced: Set<String> = []
        var unmodelled = 0
        var fine: [CodexUsage] = []
        for url in Self.rolloutFiles(under: sessionsFolder, modifiedSince: cutoff) {
            let path = url.path
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            let modified = values?.contentModificationDate ?? .distantPast
            live.insert(path)
            let needsEntries = modified >= fineSince
            var cached: CachedFile
            if let hit = cache[path], hit.size == size, hit.modified == modified, hit.pricing == pricing, hit.entries != nil || !needsEntries {
                cached = hit
            } else {
                let entries = Self.dedupe((try? Data(contentsOf: url)).map { Self.parseFile($0) } ?? [])
                cached = Self.digest(entries, size: size, modified: modified, pricing: pricing, calendar: calendar)
                cache[path] = cached
            }
            if !needsEntries, cached.entries != nil {
                cached = cached.withoutEntries()
                cache[path] = cached
            }
            for (day, record) in cached.days where day >= cutoff {
                var merged = days[day] ?? CostHistory.Record(cost: 0, tokens: TokenBreakdown(), byModel: [:], byProject: [:])
                merged.add(record)
                days[day] = merged
            }
            // A resumed rollout can be older than the window while its file is recent, so its hours are filtered
            // here as the day records are above: the average active hour is the window's, not the file's.
            for (hour, cost) in cached.costByHour where hour >= firstHour {
                costByHour[hour, default: 0] += cost
            }
            unpriced.formUnion(cached.unpriced)
            unmodelled += cached.unmodelled
            if needsEntries, let entries = cached.entries { fine.append(contentsOf: entries) }
        }
        cache = cache.filter { live.contains($0.key) }

        let stored = history?.load(calendar: calendar) ?? [:]
        // A day whose rollouts Codex has since removed keeps the larger total the history remembers for it.
        var merged = stored
        for (day, record) in days where (stored[day]?.cost ?? 0) <= record.cost + 1e-9 {
            merged[day] = record
        }
        history?.record(days, existing: stored, calendar: calendar)

        var lastHour = 0.0
        var scratch: Set<String> = []
        for entry in fine {
            let age = now.timeIntervalSince(entry.timestamp)
            guard age >= 0, age < 3600 else { continue }
            lastHour += Self.price(entry, unpriced: &scratch)
        }
        let problem = unmodelled > 0 ? L("%ld Codex turn(s) name no model and are not priced", unmodelled) : nil
        return ProviderCost.build(tool: .codex, source: .localSessions, days: merged, now: now, daysBack: daysBack, weekStart: weekStart,
                                  calendar: calendar, hourly: HourlyBurn(lastHour: lastHour, costByHour: costByHour),
                                  unpricedModels: unpriced, scannedAt: now, problem: problem)
    }

    /// A file's priced day records, hour buckets and unpriced models, held against its size and modification date.
    private static func digest(_ entries: [CodexUsage], size: Int, modified: Date, pricing: String, calendar: Calendar) -> CachedFile {
        var days: [Date: CostHistory.Record] = [:]
        var costByHour: [Int: Double] = [:]
        var unpriced: Set<String> = []
        var unmodelled = 0
        for entry in entries {
            let cost = price(entry, unpriced: &unpriced)
            if entry.model == nil { unmodelled += 1 }
            let day = calendar.startOfDay(for: entry.timestamp)
            var record = days[day] ?? CostHistory.Record(cost: 0, tokens: TokenBreakdown(), byModel: [:], byProject: [:])
            record.cost += cost
            record.tokens += entry.tokens
            if let model = entry.model {
                record.byModel[model, default: 0] += cost
                record.byModelTokens[model, default: 0] += entry.tokens.total
            }
            record.byProject[entry.project ?? CostShare.other, default: 0] += cost
            record.byProjectTokens[entry.project ?? CostShare.other, default: 0] += entry.tokens.total
            days[day] = record
            costByHour[Int(entry.timestamp.timeIntervalSince1970 / 3600), default: 0] += cost
        }
        return CachedFile(size: size, modified: modified, pricing: pricing, days: days, costByHour: costByHour,
                          entries: entries, unpriced: unpriced, unmodelled: unmodelled)
    }

    /// Tokens at OpenAI list price. A model with no published rate contributes nothing and is named on the card.
    static func price(_ entry: CodexUsage, unpriced: inout Set<String>) -> Double {
        if let priced = OpenAIPricing.cost(of: entry.tokens, model: entry.model) { return priced }
        if let model = entry.model, !model.isEmpty { unpriced.insert(model) }
        return 0
    }

    /// Every rollout under `sessions/` touched since `modifiedSince`, path-sorted so the scan order is deterministic.
    static func rolloutFiles(under sessions: URL, modifiedSince: Date) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, (values?.contentModificationDate ?? .distantPast) >= modifiedSince else { continue }
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    /// One rollout. `token_usage_record` lines are the record of a turn; where a file has any, the `token_count`
    /// events in the same file are running totals of those same turns and are left alone.
    static func parseFile(_ data: Data) -> [CodexUsage] {
        // The four line types worth parsing, as the byte markers their `"type"` field carries. Everything else in
        // a rollout is the conversation itself, which is never read here.
        let markers = ["token_usage_record", "token_count", "turn_context", "session_meta"].map { Data($0.utf8) }
        var records: [CodexUsage] = []
        var events: [CodexUsage] = []
        var model: String?
        var project: String?
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            let line = data[start..<end]
            start = end < data.endIndex ? data.index(after: end) : data.endIndex
            guard markers.contains(where: { line.range(of: $0) != nil }),
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = object["type"] as? String
            else { continue }
            let payload = object["payload"] as? [String: Any]
            switch type {
            case "turn_context", "session_meta":
                if let name = payload?["model"] as? String, !name.isEmpty { model = name }
                if let cwd = payload?["cwd"] as? String, let name = ProjectName.ofPath(cwd) { project = name }
            case "token_usage_record":
                guard let stamp = timestamp(object), let tokens = tokens(payload?["usage"]) else { continue }
                records.append(CodexUsage(timestamp: stamp, model: model, project: project, tokens: tokens,
                                          dedupeKey: payload?["response_id"] as? String))
            case "event_msg":
                guard (payload?["type"] as? String) == "token_count", let stamp = timestamp(object),
                      let info = payload?["info"] as? [String: Any], let tokens = tokens(info["last_token_usage"])
                else { continue }
                events.append(CodexUsage(timestamp: stamp, model: model, project: project, tokens: tokens))
            default:
                continue
            }
        }
        return records.isEmpty ? events : records
    }

    private static func timestamp(_ object: [String: Any]) -> Date? {
        (object["timestamp"] as? String).flatMap(DateParsing.iso8601)
    }

    /// codex-rs `TokenUsage`: `input_tokens` counts the cached tokens too, and `reasoning_output_tokens` is part of
    /// `output_tokens`, so the billed input is input minus cached and the output is taken whole.
    /// `cache_write_input_tokens` is carried but not billed: OpenAI charges nothing to write the prompt cache.
    static func tokens(_ value: Any?) -> TokenBreakdown? {
        guard let usage = value as? [String: Any] else { return nil }
        let input = Int(JSON.number(usage["input_tokens"]) ?? 0)
        let cached = Int(JSON.number(usage["cached_input_tokens"]) ?? 0)
        let output = Int(JSON.number(usage["output_tokens"]) ?? 0)
        let write = Int(JSON.number(usage["cache_write_input_tokens"]) ?? 0)
        guard input > 0 || output > 0 || cached > 0 else { return nil }
        return TokenBreakdown(input: max(0, input - cached), cacheWrite5m: max(0, write), cacheRead: min(max(0, cached), max(0, input)), output: max(0, output))
    }

    /// One entry per response id. A resumed session replays the turns it inherited, and the replay carries the
    /// same response id, so the first of each wins.
    static func dedupe(_ entries: [CodexUsage]) -> [CodexUsage] {
        var kept: [CodexUsage] = []
        var seen: Set<String> = []
        for entry in entries {
            guard let key = entry.dedupeKey, !key.isEmpty else {
                kept.append(entry)
                continue
            }
            if seen.insert(key).inserted { kept.append(entry) }
        }
        return kept
    }
}
