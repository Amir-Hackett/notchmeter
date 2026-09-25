import Foundation
import os

private let log = Logger(subsystem: "com.amirhackett.notchmeter", category: "cost")

struct UsageEntry: Codable, Equatable, Sendable {
    let timestamp: Date
    let model: String?
    let tokens: TokenBreakdown
    let costUSD: Double?
    /// `message.id`: streaming writes the same response several times, once per content block.
    let dedupeKey: String?
    /// `usage.inference_geo`; "us" is billed at 1.1x list.
    let inferenceGeo: String?
    /// The project name of the line's `cwd` (ProjectName: the repository a worktree was cut from, else the last path
    /// component), else of the transcript's project folder.
    let project: String?
    let sessionID: String?
    /// `usage.server_tool_use.web_search_requests`, a per-request fee.
    let webSearches: Int
    /// `usage.speed`; "fast" doubles the Opus 5 and Opus 4.8 rates.
    let speed: String?

    init(timestamp: Date, model: String?, tokens: TokenBreakdown, costUSD: Double?, dedupeKey: String?, inferenceGeo: String? = nil,
         project: String? = nil, sessionID: String? = nil, webSearches: Int = 0, speed: String? = nil) {
        self.timestamp = timestamp
        self.model = model
        self.tokens = tokens
        self.costUSD = costUSD
        self.dedupeKey = dedupeKey
        self.inferenceGeo = inferenceGeo
        self.project = project
        self.sessionID = sessionID
        self.webSearches = webSearches
        self.speed = speed
    }
}

struct DailySpend: Equatable, Sendable, Identifiable {
    let day: Date
    let cost: Double
    let tokens: Int
    /// The model that cost the most that day.
    let topModel: String?
    var id: Date { day }

    init(day: Date, cost: Double, tokens: Int, topModel: String? = nil) {
        self.day = day
        self.cost = cost
        self.tokens = tokens
        self.topModel = topModel
    }
}

/// One name's share of a range: a model or a project.
struct CostShare: Equatable, Sendable, Identifiable {
    let name: String
    let cost: Double
    /// Tokens actually attributed to this name, so dollars per million is its own rate rather than the blend.
    var tokens: Int = 0
    var id: String { name }

    static let other = "Other"

    /// The top `limit` by cost, the rest folded into "Other"; zero-cost names are dropped.
    static func top(_ totals: [String: Double], tokens: [String: Int] = [:], limit: Int = 4) -> [CostShare] {
        let sorted = totals.filter { $0.value > 0 }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        var shares = sorted.prefix(limit).map { CostShare(name: $0.key, cost: $0.value, tokens: tokens[$0.key] ?? 0) }
        let rest = sorted.dropFirst(limit).reduce(0) { $0 + $1.value }
        if rest > 0 { shares.append(CostShare(name: other, cost: rest)) }
        return shares
    }
}

enum CostRange: CaseIterable, Sendable {
    case today, yesterday, week, month, last30Days, last90Days
}

struct RangeTotals: Equatable, Sendable {
    var cost = 0.0
    var tokens = TokenBreakdown()
    var byModel: [String: Double] = [:]
    var byProject: [String: Double] = [:]
    var byModelTokens: [String: Int] = [:]
    var byProjectTokens: [String: Int] = [:]
    /// Every list price that priced a line inside this range (PriceSource): the union of what the lines
    /// themselves were priced under, so a source that priced no line here is not named. Empty where the dollars
    /// are the vendor's own, or where every line carried its own `costUSD`.
    var priceSources: Set<PriceSource> = []

    var models: [CostShare] { CostShare.top(byModel, tokens: byModelTokens) }
    var projects: [CostShare] { CostShare.top(byProject, tokens: byProjectTokens) }

    /// Dollars per million tokens across every bucket, cache reads included: the number that explains why a day
    /// cost more (the model mix and the cache share). nil without tokens.
    var costPerMillionTokens: Double? {
        tokens.total > 0 ? cost / Double(tokens.total) * 1_000_000 : nil
    }

    mutating func add(_ other: RangeTotals) {
        cost += other.cost
        tokens += other.tokens
        byModel.merge(other.byModel, uniquingKeysWith: +)
        byProject.merge(other.byProject, uniquingKeysWith: +)
        byModelTokens.merge(other.byModelTokens, uniquingKeysWith: +)
        byProjectTokens.merge(other.byProjectTokens, uniquingKeysWith: +)
        priceSources.formUnion(other.priceSources)
    }
}

/// The current Claude 5-hour block, aligned to the live session window's reset so the Cost card and the Session
/// meter describe the same period.
struct BlockCost: Equatable, Sendable {
    let start: Date
    let end: Date
    let cost: Double
    let tokens: TokenBreakdown
    /// Tokens per minute since the block's first entry; nil before a minute has passed.
    let tokensPerMinute: Double?
}

/// Spend since the live weekly window started, and what one per cent of that window has cost.
struct WeekCost: Equatable, Sendable {
    let start: Date
    let cost: Double
    let perPercent: Double?
}

/// Every tool's spend side by side. The figures at the top are the total across the providers below them: with
/// Claude Code the only tool that can report spend they are Claude Code's, and with three of them reporting they
/// are all three added up. `providers` is where a single tool's own ranges, series, models and source live.
struct CostSummary: Equatable, Sendable {
    let today: Double
    let yesterday: Double
    let last30Days: Double
    /// One entry per calendar day for the last 30 days, oldest first.
    let daily: [DailySpend]
    /// Ninety days, from the durable daily history where the tools' own files are gone.
    let daily90: [DailySpend]
    /// Everything priced in the last 60 minutes, from the sources whose entries carry a time of day.
    let lastHour: Double
    /// Mean cost of an active hour across the window: the window's total over its active hours, an active hour
    /// being a clock hour with at least one entry. A median would sit near zero for bursty agent work and call
    /// every real hour a multiple of it.
    let typicalHourly: Double
    /// lastHour / typicalHourly; nil until five active hours exist and the mean is above zero.
    let burnMultiple: Double?
    let unpricedModels: Set<String>
    let scannedAt: Date
    let ranges: [CostRange: RangeTotals]
    /// The live Claude weekly window's own spend and what one per cent of it cost; Claude's window, not a total.
    let week: WeekCost?
    let block: BlockCost?
    /// The first day Claude Code's history holds spend for, and everything it has cost since.
    let firstUse: Date?
    let sinceFirstUse: Double
    /// Tokens per one per cent of the session window today, against the 30-day median (MeteringRatio).
    let sessionMetering: MeteringRatio?
    /// One entry per tool that can report spend from a source it publishes, in tool order. A tool that cannot is
    /// simply absent: no zero, no invented figure (docs/accuracy.md).
    let providers: [ProviderCost]

    init(today: Double, yesterday: Double, last30Days: Double, daily: [DailySpend], daily90: [DailySpend] = [], lastHour: Double,
         typicalHourly: Double, burnMultiple: Double?, unpricedModels: Set<String>, scannedAt: Date,
         ranges: [CostRange: RangeTotals] = [:], week: WeekCost? = nil, block: BlockCost? = nil, firstUse: Date? = nil, sinceFirstUse: Double = 0,
         sessionMetering: MeteringRatio? = nil, providers: [ProviderCost] = []) {
        self.today = today
        self.yesterday = yesterday
        self.last30Days = last30Days
        self.daily = daily
        self.daily90 = daily90.isEmpty ? daily : daily90
        self.lastHour = lastHour
        self.typicalHourly = typicalHourly
        self.burnMultiple = burnMultiple
        self.unpricedModels = unpricedModels
        self.scannedAt = scannedAt
        self.ranges = ranges
        self.week = week
        self.block = block
        self.firstUse = firstUse
        self.sinceFirstUse = sinceFirstUse
        self.sessionMetering = sessionMetering
        self.providers = providers
    }

    /// The same summary with the figures the store adds after the scan.
    func with(sessionMetering: MeteringRatio?? = nil, providers: [ProviderCost]? = nil, scannedAt: Date? = nil) -> CostSummary {
        CostSummary(today: today, yesterday: yesterday, last30Days: last30Days, daily: daily, daily90: daily90, lastHour: lastHour, typicalHourly: typicalHourly,
                    burnMultiple: burnMultiple, unpricedModels: unpricedModels, scannedAt: scannedAt ?? self.scannedAt, ranges: ranges, week: week, block: block,
                    firstUse: firstUse, sinceFirstUse: sinceFirstUse, sessionMetering: sessionMetering ?? self.sessionMetering,
                    providers: providers ?? self.providers)
    }

    func totals(_ range: CostRange) -> RangeTotals {
        ranges[range] ?? RangeTotals()
    }

    func provider(_ tool: ToolID) -> ProviderCost? {
        providers.first { $0.tool == tool }
    }

    /// The same summary with other tools' spend folded in: every top figure becomes the total across the
    /// providers, and each provider keeps its own ranges, series, source and freshness. The Claude-window
    /// figures (the week, the block, the metering, since first use) stay Claude's, because that is what they are.
    func adding(_ others: [ProviderCost]) -> CostSummary {
        guard !others.isEmpty else { return self }
        let all = (providers + others).sorted { rank($0.tool) < rank($1.tool) }
        var ranges: [CostRange: RangeTotals] = [:]
        for provider in all {
            for (range, totals) in provider.ranges {
                var merged = ranges[range] ?? RangeTotals()
                merged.add(totals)
                ranges[range] = merged
            }
        }
        let daily = Self.sum(all.map(\.daily))
        let lastHour = all.compactMap(\.lastHour).reduce(0, +)
        let typicalHourly = all.compactMap(\.typicalHourly).reduce(0, +)
        let burnable = all.contains { $0.burnMultiple != nil }
        return CostSummary(
            today: ranges[.today]?.cost ?? 0,
            yesterday: ranges[.yesterday]?.cost ?? 0,
            last30Days: daily.reduce(0) { $0 + $1.cost },
            daily: daily,
            daily90: Self.sum(all.map(\.daily90)),
            lastHour: lastHour,
            typicalHourly: typicalHourly,
            burnMultiple: burnable && typicalHourly > 0 ? lastHour / typicalHourly : nil,
            unpricedModels: all.reduce(into: Set<String>()) { $0.formUnion($1.unpricedModels) },
            scannedAt: scannedAt,
            ranges: ranges,
            week: week, block: block, firstUse: firstUse, sinceFirstUse: sinceFirstUse, sessionMetering: sessionMetering,
            providers: all)
    }

    private func rank(_ tool: ToolID) -> Int {
        ToolID.allCases.firstIndex(of: tool) ?? ToolID.allCases.count
    }

    /// Several tools' day series added day by day; the days come from the same grid, so they line up.
    static func sum(_ series: [[DailySpend]]) -> [DailySpend] {
        guard series.count > 1 else { return series.first ?? [] }
        var totals: [Date: (cost: Double, tokens: Int, top: String?)] = [:]
        for list in series {
            for day in list {
                var entry = totals[day.day] ?? (0, 0, nil)
                entry.cost += day.cost
                entry.tokens += day.tokens
                if entry.top == nil { entry.top = day.topModel }
                totals[day.day] = entry
            }
        }
        return totals.keys.sorted().map { DailySpend(day: $0, cost: totals[$0]!.cost, tokens: totals[$0]!.tokens, topModel: totals[$0]!.top) }
    }

    static let empty = CostSummary(today: 0, yesterday: 0, last30Days: 0, daily: [], lastHour: 0, typicalHourly: 0,
                                   burnMultiple: nil, unpricedModels: [], scannedAt: .distantPast)
}

/// A transcript's priced totals in quarter-hour buckets, so a scan folds an unchanged file from a few numbers rather
/// than re-pricing every entry. Quarter hours keep every local day boundary exact (every time zone offset is a
/// multiple of fifteen minutes). Priced under one `ModelPricing.fingerprint`; a change in rates discards it.
struct FileDigest: Codable, Equatable, Sendable {
    struct Bucket: Codable, Equatable, Sendable {
        var cost = 0.0
        var tokens = TokenBreakdown()
        var byModel: [String: Double] = [:]
        var byProject: [String: Double] = [:]
        var byModelTokens: [String: Int] = [:]
        var byProjectTokens: [String: Int] = [:]
        /// The list prices the bucket's lines were priced under; a line with its own `costUSD` adds none.
        var priceSources: Set<PriceSource> = []
    }

    static let bucketSeconds: TimeInterval = 900

    var buckets: [Int: Bucket] = [:]
    var unpriced: Set<String> = []

    static func index(of date: Date) -> Int {
        Int((date.timeIntervalSince1970 / bucketSeconds).rounded(.down))
    }

    static func start(of index: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(index) * bucketSeconds)
    }

    static func build(_ entries: [UsageEntry]) -> FileDigest {
        var digest = FileDigest()
        for entry in entries {
            var bucket = digest.buckets[index(of: entry.timestamp)] ?? Bucket()
            let cost = ClaudeCostScanner.price(entry, unpriced: &digest.unpriced, sources: &bucket.priceSources)
            bucket.cost += cost
            bucket.tokens += entry.tokens
            if let model = entry.model {
                bucket.byModel[model, default: 0] += cost
                bucket.byModelTokens[model, default: 0] += entry.tokens.total
            }
            bucket.byProject[entry.project ?? CostShare.other, default: 0] += cost
            bucket.byProjectTokens[entry.project ?? CostShare.other, default: 0] += entry.tokens.total
            digest.buckets[index(of: entry.timestamp)] = bucket
        }
        return digest
    }
}

/// Prices what Claude Code has already written to disk: assistant lines carrying `usage`, one per message id +
/// request id, a line's own `costUSD` when present, otherwise tokens times list price times the residency
/// multiplier, plus the web-search fee. The rules and their sources are written down in docs/accuracy.md.
actor ClaudeCostScanner {
    private struct CachedFile: Codable {
        let size: Int
        let modified: Date
        let pricing: String
        /// The file's parsed entries, held only while the file is inside the fine horizon; nil once it has aged
        /// out, when the digest answers everything asked of it. Holding a month of transcripts at entry level was
        /// most of the app's resident memory, and none of it was ever read again.
        let entries: [UsageEntry]?
        let digest: FileDigest

        func withoutEntries() -> CachedFile {
            CachedFile(size: size, modified: modified, pricing: pricing, entries: nil, digest: digest)
        }
    }

    nonisolated let roots: [URL]
    nonisolated let cacheURL: URL?
    nonisolated let history: CostHistory?
    private var cache: [String: CachedFile] = [:]
    private var cacheLoaded = false
    private var cacheSavedAt: Date?

    /// The cache is tens of megabytes on a busy Mac; rewriting it on every minute's scan while a session appends
    /// to a transcript cost more CPU than everything else the app does, so writes are spaced out. Entries parsed
    /// since the last write are simply parsed again on the next launch.
    static let cacheSaveSpacing: TimeInterval = 600
    /// Entries (rather than digests) are consulted only for files touched inside this horizon: the last hour and
    /// the current 5-hour block need minute precision, everything longer is day-aligned.
    static let fineHorizon: TimeInterval = Period.fiveHours

    init(roots: [URL] = ClaudeCostScanner.defaultRoots(), cacheURL: URL? = ClaudeCostScanner.defaultCacheURL(),
         history: CostHistory? = CostHistory()) {
        self.roots = roots
        self.cacheURL = cacheURL
        self.history = history
    }

    static let cachePrefix = "claude-usage-cache"

    /// Versioned: entries parsed by an older rule set must not be reused. v4 (0.6.0) folds a worktree's spend onto
    /// its repository, which changes the per-project digest of every file a worktree wrote. v5 (0.8.0) groups a
    /// response's lines by message id alone, which changes every digest built from a Cowork transcript. v6 (0.9.0)
    /// records the price source of every priced line in its bucket, which a v5 digest does not carry and the same
    /// pricing fingerprint would otherwise have kept.
    static func defaultCacheURL() -> URL? {
        Paths.caches.appendingPathComponent("\(cachePrefix)-v6.json")
    }

    private func loadCacheIfNeeded() {
        guard !cacheLoaded else { return }
        cacheLoaded = true
        removeSupersededCaches()
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL),
              let stored = try? JSONDecoder().decode([String: CachedFile].self, from: data)
        else { return }
        cache = stored
    }

    /// The cache files earlier rule sets wrote: tens of megabytes each, never read again once the version in the
    /// name moved on, and nothing else removes them.
    private func removeSupersededCaches() {
        guard let cacheURL else { return }
        let folder = cacheURL.deletingLastPathComponent()
        let current = cacheURL.lastPathComponent
        guard current.hasPrefix(Self.cachePrefix),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        else { return }
        for name in names where name != current && name.hasPrefix(Self.cachePrefix) && name.hasSuffix(".json") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    private func saveCache() {
        guard let cacheURL, let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    /// Claude Code's config directories (their `projects/`), the Cowork session folder when it exists, and the
    /// user's own extra roots, which may be a `projects/` folder or a flat folder of session folders.
    static func defaultRoots(extra: [String] = []) -> [URL] {
        let fm = FileManager.default
        var configDirs: [URL] = []
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            configDirs.append(URL(fileURLWithPath: custom))
        }
        configDirs.append(Paths.home.appendingPathComponent(".config/claude"))
        configDirs.append(Paths.home.appendingPathComponent(".claude"))
        var roots = configDirs.filter { fm.fileExists(atPath: $0.appendingPathComponent("projects").path) }
        var isDirectory: ObjCBool = false
        for candidate in [coworkRoot] + extra.map({ URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }) {
            guard fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            roots.append(candidate)
        }
        var seen: Set<String> = []
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// Claude Desktop's Cowork sessions write the same transcript lines here.
    static var coworkRoot: URL {
        Paths.home.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")
    }

    /// A root's `projects/` when it has one, else the root itself, read as it is.
    static func transcriptFolder(of root: URL) -> URL {
        let projects = root.appendingPathComponent("projects")
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: projects.path, isDirectory: &isDirectory), isDirectory.boolValue { return projects }
        return root
    }

    func scan(now: Date = Date(), daysBack: Int = 30, weeklyResetsAt: Date? = nil, weeklyUsed: Double? = nil, sessionResetsAt: Date? = nil,
              sessionUsed: Double? = nil, meteringSince: Date? = nil, calendar: Calendar = .current) -> CostSummary {
        loadCacheIfNeeded()
        let files = Self.transcriptFiles(under: roots)
        let cutoff = calendar.date(byAdding: .day, value: -(daysBack - 1), to: calendar.startOfDay(for: now)) ?? .distantPast
        let pricing = ModelPricing.fingerprint
        let fineSince = min(now.addingTimeInterval(-3600), sessionResetsAt.map { $0.addingTimeInterval(-Self.fineHorizon) } ?? now)
        var live: Set<String> = []
        var digests: [FileDigest] = []
        var fine: [UsageEntry] = []
        var changed = false
        let projects = ProjectName.Resolver()
        for (url, project) in files {
            let path = url.path
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            let modified = values?.contentModificationDate ?? .distantPast
            guard modified >= cutoff else { continue }
            live.insert(path)
            let needsEntries = modified >= fineSince
            var cached: CachedFile
            if let hit = cache[path], hit.size == size, hit.modified == modified, hit.pricing == pricing, hit.entries != nil || !needsEntries {
                cached = hit
            } else {
                let entries = Self.dedupe((try? Data(contentsOf: url)).map { Self.parseFile($0, project: project, projects: projects) } ?? [])
                cached = CachedFile(size: size, modified: modified, pricing: pricing, entries: entries, digest: FileDigest.build(entries))
                cache[path] = cached
                changed = true
            }
            if !needsEntries, cached.entries != nil {
                cached = cached.withoutEntries()
                cache[path] = cached
                changed = true
            }
            digests.append(cached.digest)
            if needsEntries, let entries = cached.entries { fine.append(contentsOf: entries) }
        }
        cache = cache.filter { live.contains($0.key) }
        if changed, cacheSavedAt.map({ now.timeIntervalSince($0) >= Self.cacheSaveSpacing }) ?? true {
            saveCache()
            cacheSavedAt = now
        }
        let stored = history?.load(calendar: calendar) ?? [:]
        var summary = Self.summarize(digests: digests, fine: fine, now: now, daysBack: daysBack, weeklyResetsAt: weeklyResetsAt,
                                     weeklyUsed: weeklyUsed, sessionResetsAt: sessionResetsAt, history: stored, calendar: calendar)
        var records = Self.dayRecords(digests: digests, now: now, daysBack: daysBack, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        let metering = Self.metering(blockTokens: summary.block?.tokens.total, sessionUsed: sessionUsed, history: stored, today: today, since: meteringSince)
        if let metering, var record = records[today] {
            record.sessionTokensPerPercent = metering.tokensPerPercent
            records[today] = record
        }
        summary = summary.with(sessionMetering: .some(metering))
        history?.record(records, existing: stored, calendar: calendar)
        return summary
    }

    /// Today's tokens per one per cent of the session window, against the median of the days the history holds.
    /// `since` floors the median at a drain-log boundary (DrainLog.Boundary): a day that began before the vendor
    /// changed what the window measures is not a norm for the days after it, and the 30-day median would
    /// otherwise carry the old figures for a month after the change.
    static func metering(blockTokens: Int?, sessionUsed: Double?, history: [Date: CostHistory.Record], today: Date, since: Date? = nil) -> MeteringRatio? {
        guard let blockTokens, let sessionUsed, let ratio = MeteringRatio.tokensPerPercent(blockTokens: blockTokens, usedFraction: sessionUsed) else { return nil }
        let floor = since ?? .distantPast
        let past = history.filter { $0.key < today && $0.key >= floor }.compactMap { $0.value.sessionTokensPerPercent }
        return MeteringRatio(tokensPerPercent: ratio, median: MeteringRatio.median(past))
    }

    /// Every transcript under each root, path-sorted so the scan order is deterministic, with the project name its
    /// folder implies (the line's own `cwd` wins when present).
    static func transcriptFiles(under roots: [URL]) -> [(url: URL, project: String?)] {
        var files: [(URL, String?)] = []
        for root in roots {
            let folder = transcriptFolder(of: root)
            let isProjects = folder.lastPathComponent == "projects"
            let isCowork = root.path.contains("local-agent-mode-sessions")
            guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            let resolved = folder.resolvingSymlinksInPath().path
            let prefix = resolved.hasSuffix("/") ? resolved : resolved + "/"
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let path = url.resolvingSymlinksInPath().path
                let relative = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
                let project: String?
                if isCowork {
                    project = "Cowork"
                } else if isProjects, let first = relative.split(separator: "/").first, relative.contains("/") {
                    project = projectName(fromFolder: String(first))
                } else {
                    project = nil
                }
                files.append((url, project))
            }
        }
        return files.sorted { $0.0.path < $1.0.path }.map { (url: $0.0, project: $0.1) }
    }

    /// "-Users-amir-Developer-notchmeter" is Claude Code's encoding of the working directory: the last segment is
    /// the folder name (a name with a hyphen in it comes out as its last piece, which the line's `cwd` corrects).
    /// A worktree Claude Code cut encodes as "-Users-amir-Developer-notchmeter--claude-worktrees-wf_1", and is
    /// folded onto the segment before "claude-worktrees", as `ProjectName` folds the path itself (0.6.0). The
    /// double hyphen is the mark: it is the dot of ".claude" encoded, so only a real `.claude/worktrees` folder
    /// carries "--claude-worktrees-", while a project that merely has those words in its name
    /// ("my-claude-worktrees-tool") does not, and keeps its own last piece. Splitting alone lost that distinction.
    static func projectName(fromFolder folder: String) -> String? {
        let parts = folder.split(separator: "-", omittingEmptySubsequences: true)
        if folder.contains("--claude-worktrees-"),
           let at = parts.indices.dropLast(2).first(where: { parts[$0] == "claude" && parts[$0 + 1] == "worktrees" }), at >= 1 {
            return String(parts[at - 1])
        }
        guard let last = parts.last, !last.isEmpty else { return nil }
        return String(last)
    }

    static func projectName(fromPath path: String) -> String? {
        ProjectName.ofPath(path)
    }

    /// `projects` is the scan's resolver, so a worktree's `.git` is read once per scan rather than once per line;
    /// a caller parsing one file makes do with a fresh one.
    static func parseFile(_ data: Data, project: String? = nil, projects: ProjectName.Resolver = ProjectName.Resolver()) -> [UsageEntry] {
        let marker = Data("\"usage\":{".utf8)
        var entries: [UsageEntry] = []
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            let line = data[start..<end]
            if line.range(of: marker) != nil, let entry = parseLine(line, project: project, projects: projects) {
                entries.append(entry)
            }
            start = end < data.endIndex ? data.index(after: end) : data.endIndex
        }
        return entries
    }

    static func parseLine(_ line: Data, project: String? = nil, projects: ProjectName.Resolver = ProjectName.Resolver()) -> UsageEntry? {
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
        // The message id alone, which is the API's own and unique per response, and the key Anthropic's cost
        // documentation says to deduplicate by. Until 2026-09-24 the key was the id plus Claude Code's `requestId`,
        // the pair ccusage groups by; Claude Desktop's Cowork transcripts spell it `request_id` on some lines and
        // leave it off others, so each of those lines stood alone and a streamed Cowork response was priced once per
        // content line. No message id on this Mac was ever seen with two request ids, so nothing the pair told apart
        // the id had joined (docs/accuracy.md, "One entry per response").
        var key: String?
        if let id = message["id"] as? String, !id.isEmpty {
            key = id
        }
        let serverTools = usage["server_tool_use"] as? [String: Any]
        return UsageEntry(
            timestamp: timestamp,
            model: model,
            tokens: tokens,
            costUSD: (usage["costUSD"] as? Double) ?? (object["costUSD"] as? Double),
            dedupeKey: key,
            inferenceGeo: usage["inference_geo"] as? String,
            project: (object["cwd"] as? String).flatMap(projects.name(ofPath:)) ?? project,
            sessionID: object["sessionId"] as? String,
            webSearches: (serverTools?["web_search_requests"] as? Int) ?? 0,
            speed: usage["speed"] as? String
        )
    }

    /// One entry per message id. A streamed message is written once per content block with the `message_start`
    /// output count, then once more with the real count, so the line with the most output wins.
    static func dedupe(_ entries: [UsageEntry]) -> [UsageEntry] {
        var kept: [UsageEntry] = []
        var position: [String: Int] = [:]
        for entry in entries {
            guard let key = entry.dedupeKey else {
                kept.append(entry)
                continue
            }
            if let at = position[key] {
                if entry.tokens.output > kept[at].tokens.output { kept[at] = entry }
            } else {
                position[key] = kept.count
                kept.append(entry)
            }
        }
        return kept
    }

    /// A line's own `costUSD` wins; otherwise tokens at list price (fast-mode rates when the line says so) times the
    /// residency multiplier, plus the per-request web-search fee, which is never multiplied. The list price is the
    /// one in force when the line was written, which differs from today's only where the catalog updated a rate.
    static func price(_ entry: UsageEntry, unpriced: inout Set<String>) -> Double {
        var sources: Set<PriceSource> = []
        return price(entry, unpriced: &unpriced, sources: &sources)
    }

    /// The same, recording where the list price came from in `sources`. A line with its own `costUSD` names no
    /// source, since no list price touched it; a line no table prices names none either, and is named unpriced.
    static func price(_ entry: UsageEntry, unpriced: inout Set<String>, sources: inout Set<PriceSource>) -> Double {
        if let explicit = entry.costUSD { return explicit }
        let searches = Double(entry.webSearches) * ModelPricing.webSearchRequest
        if let model = entry.model, let priced = ModelPricing.resolve(model, speed: entry.speed, at: entry.timestamp) {
            sources.insert(priced.source)
            return priced.rates.cost(entry.tokens) * ModelPricing.residencyMultiplier(inferenceGeo: entry.inferenceGeo) + searches
        }
        if let model = entry.model { unpriced.insert(model) }
        return searches
    }

    /// Every entry is fine-grained here: the path the golden tests take, and the app's when a file is fresh.
    static func summarize(_ entries: [UsageEntry], now: Date, daysBack: Int, weeklyResetsAt: Date? = nil, weeklyUsed: Double? = nil,
                          sessionResetsAt: Date? = nil, calendar: Calendar = .current) -> CostSummary {
        summarize(digests: [FileDigest.build(entries)], fine: entries, now: now, daysBack: daysBack, weeklyResetsAt: weeklyResetsAt,
                  weeklyUsed: weeklyUsed, sessionResetsAt: sessionResetsAt, history: [:], calendar: calendar)
    }

    /// Per-day records from the digests, for the durable history and the day-aligned ranges.
    static func dayRecords(digests: [FileDigest], now: Date, daysBack: Int, calendar: Calendar) -> [Date: CostHistory.Record] {
        let today = calendar.startOfDay(for: now)
        guard let windowStart = calendar.date(byAdding: .day, value: -(daysBack - 1), to: today) else { return [:] }
        var days: [Date: CostHistory.Record] = [:]
        for digest in digests {
            for (index, bucket) in digest.buckets {
                let start = FileDigest.start(of: index)
                guard start >= windowStart else { continue }
                let day = calendar.startOfDay(for: start)
                var record = days[day] ?? CostHistory.Record(cost: 0, tokens: TokenBreakdown(), byModel: [:], byProject: [:])
                record.cost += bucket.cost
                record.tokens += bucket.tokens
                record.byModel.merge(bucket.byModel, uniquingKeysWith: +)
                record.byModelTokens.merge(bucket.byModelTokens, uniquingKeysWith: +)
                record.byProjectTokens.merge(bucket.byProjectTokens, uniquingKeysWith: +)
                record.byProject.merge(bucket.byProject, uniquingKeysWith: +)
                record.priceSources.formUnion(bucket.priceSources)
                days[day] = record
            }
        }
        return days
    }

    static func summarize(digests: [FileDigest], fine: [UsageEntry], now: Date, daysBack: Int, weeklyResetsAt: Date?, weeklyUsed: Double?,
                          sessionResetsAt: Date?, history: [Date: CostHistory.Record], calendar: Calendar) -> CostSummary {
        let today = calendar.startOfDay(for: now)
        guard let windowStart = calendar.date(byAdding: .day, value: -(daysBack - 1), to: today),
              let start90 = calendar.date(byAdding: .day, value: -89, to: today)
        else { return .empty }
        let live = dayRecords(digests: digests, now: now, daysBack: daysBack, calendar: calendar)
        // A day the transcripts no longer cover keeps the larger total the history remembers for it, and the
        // sources that priced the lines still here join the ones recorded for it: both priced the day.
        var days = history
        for (day, record) in live {
            if (history[day]?.cost ?? 0) <= record.cost + 1e-9 {
                days[day] = record
            } else {
                days[day]?.priceSources.formUnion(record.priceSources)
            }
        }

        var costByHour: [Int: Double] = [:]
        var unpriced: Set<String> = []
        for digest in digests {
            unpriced.formUnion(digest.unpriced)
            for (index, bucket) in digest.buckets where FileDigest.start(of: index) >= windowStart {
                costByHour[index / 4, default: 0] += bucket.cost
            }
        }

        let daily = RangeTotals.series(days: days, from: windowStart, count: daysBack, calendar: calendar)
        let daily90 = RangeTotals.series(days: days, from: start90, count: 90, calendar: calendar)

        let weekStart = CostEngine.weekStart(weeklyResetsAt: weeklyResetsAt, now: now, calendar: calendar)
        var ranges = RangeTotals.ranges(days: days, daily: daily, daily90: daily90, weekStart: weekStart, now: now, calendar: calendar)
        // The week the transcripts themselves say, to the quarter hour, rather than the day-aligned approximation.
        var weekTotals = RangeTotals()
        for digest in digests {
            for (index, bucket) in digest.buckets where FileDigest.start(of: index) >= weekStart {
                weekTotals.add(RangeTotals(cost: bucket.cost, tokens: bucket.tokens, byModel: bucket.byModel, byProject: bucket.byProject,
                                           byModelTokens: bucket.byModelTokens, byProjectTokens: bucket.byProjectTokens, priceSources: bucket.priceSources))
            }
        }
        ranges[.week] = weekTotals
        let perPercent = weeklyUsed.flatMap { used in used > 0 && weekTotals.cost > 0 ? weekTotals.cost / (used * 100) : nil }
        let week = WeekCost(start: weekStart, cost: weekTotals.cost, perPercent: perPercent)

        var lastHour = 0.0
        var block: BlockCost?
        var blockCost = 0.0
        var blockTokens = TokenBreakdown()
        var blockFirst: Date?
        let blockStart = sessionResetsAt.flatMap { $0 > now ? $0.addingTimeInterval(-Period.fiveHours) : nil }
        var scratch: Set<String> = []
        for entry in fine {
            let age = now.timeIntervalSince(entry.timestamp)
            guard age >= 0 else { continue }
            let cost = price(entry, unpriced: &scratch)
            if age < 3600 { lastHour += cost }
            if let blockStart, entry.timestamp >= blockStart {
                blockCost += cost
                blockTokens += entry.tokens
                blockFirst = min(blockFirst ?? entry.timestamp, entry.timestamp)
            }
        }
        if let blockStart, let sessionResetsAt {
            let minutes = blockFirst.map { max(1, now.timeIntervalSince($0) / 60) }
            block = BlockCost(start: blockStart, end: sessionResetsAt, cost: blockCost, tokens: blockTokens,
                              tokensPerMinute: minutes.flatMap { blockTokens.total > 0 ? Double(blockTokens.total) / $0 : nil })
        }

        let burn = HourlyBurn(lastHour: lastHour, costByHour: costByHour)
        let firstUse = days.filter { $0.value.cost > 0 }.keys.min()
        // Each range carries the price sources of its own days (RangeTotals.priceSources), the live days' from
        // their buckets and the days older than the transcripts from the history as they were recorded.
        let claude = ProviderCost(tool: .claude, source: .localTranscripts, ranges: ranges, daily: daily, daily90: daily90,
                                  lastHour: burn.lastHour, typicalHourly: burn.typicalHourly, burnMultiple: burn.multiple,
                                  unpricedModels: unpriced, scannedAt: now)
        return CostSummary(
            today: ranges[.today]?.cost ?? 0,
            yesterday: ranges[.yesterday]?.cost ?? 0,
            last30Days: daily.reduce(0) { $0 + $1.cost },
            daily: daily,
            daily90: daily90,
            lastHour: burn.lastHour,
            typicalHourly: burn.typicalHourly,
            burnMultiple: burn.multiple,
            unpricedModels: unpriced,
            scannedAt: now,
            ranges: ranges,
            week: week,
            block: block,
            firstUse: firstUse,
            sinceFirstUse: days.values.reduce(0) { $0 + $1.cost },
            providers: claude.hasFigures ? [claude] : []
        )
    }
}

/// Daily totals that outlive the transcripts: Claude Code deletes transcripts after its cleanup period, and
/// `daysBack` is thirty, so without this the 30-day figure shrinks as files go and nothing older is ever known.
/// One JSON line per (day, tool) is appended after a scan whenever a day's total moved; the newest line per day
/// wins on read, and the file is compacted to one line per day once it grows past a few thousand lines.
/// Never a token, a prompt or a path: day, cost, five token counts, per-model and per-project cost, and the
/// names of the price tables the day's lines were priced under.
struct CostHistory: Sendable {
    struct Record: Codable, Equatable, Sendable {
        var cost: Double
        var tokens: TokenBreakdown
        var byModel: [String: Double]
        var byProject: [String: Double]
        var byModelTokens: [String: Int]
        var byProjectTokens: [String: Int]
        /// The day's session metering ratio (MeteringRatio), kept so it survives transcript cleanup.
        var sessionTokensPerPercent: Double?
        /// The list prices the day's lines were priced under (PriceSource), kept so a range can still name them
        /// once the transcripts are gone. Empty on a line an older build wrote, which then names none.
        var priceSources: Set<PriceSource>

        init(cost: Double, tokens: TokenBreakdown, byModel: [String: Double], byProject: [String: Double],
             byModelTokens: [String: Int] = [:], byProjectTokens: [String: Int] = [:], sessionTokensPerPercent: Double? = nil,
             priceSources: Set<PriceSource> = []) {
            self.cost = cost
            self.tokens = tokens
            self.byModel = byModel
            self.byProject = byProject
            self.byModelTokens = byModelTokens
            self.byProjectTokens = byProjectTokens
            self.sessionTokensPerPercent = sessionTokensPerPercent
            self.priceSources = priceSources
        }

        var topModel: String? {
            byModel.filter { $0.value > 0 }.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
        }

        mutating func add(_ other: Record) {
            cost += other.cost
            tokens += other.tokens
            byModel.merge(other.byModel, uniquingKeysWith: +)
            byProject.merge(other.byProject, uniquingKeysWith: +)
            byModelTokens.merge(other.byModelTokens, uniquingKeysWith: +)
            byProjectTokens.merge(other.byProjectTokens, uniquingKeysWith: +)
            sessionTokensPerPercent = sessionTokensPerPercent ?? other.sessionTokensPerPercent
            priceSources.formUnion(other.priceSources)
        }
    }

    /// The token maps and the price sources are written only where they are non-empty, so a line an older build
    /// wrote still reads. The sources are written in key order, so the same day writes the same bytes.
    private struct Line: Codable {
        let day: String
        let tool: String
        let cost: Double
        let tokens: TokenBreakdown
        let byModel: [String: Double]
        let byProject: [String: Double]
        var byModelTokens: [String: Int]?
        var byProjectTokens: [String: Int]?
        var sessionTokensPerPercent: Double?
        var priceSources: [PriceSource]?

        init(day: String, tool: String, record: Record) {
            self.day = day
            self.tool = tool
            self.cost = record.cost
            self.tokens = record.tokens
            self.byModel = record.byModel
            self.byProject = record.byProject
            self.byModelTokens = record.byModelTokens.isEmpty ? nil : record.byModelTokens
            self.byProjectTokens = record.byProjectTokens.isEmpty ? nil : record.byProjectTokens
            self.sessionTokensPerPercent = record.sessionTokensPerPercent
            self.priceSources = record.priceSources.isEmpty ? nil : record.priceSources.sorted { $0.key < $1.key }
        }
    }

    let url: URL
    let tool: ToolID
    /// The file's old home. Every `load` and `record` that finds a file there moves it into `url` first
    /// (`migrateFromCaches`), so the status line, the `notchmeter` command and the MCP server, which build a
    /// CostHistory in a process that never runs the app's launch path, perform the move themselves rather than
    /// waiting for the app. Until 0.5.0's review (2026-09-19) they only read the old file while the new one was
    /// absent: the first scan from one of them then created the new file holding just the days that had changed,
    /// and from that moment every reader saw those few days in place of the months in Caches, and the next scan,
    /// finding a partly cleaned day absent from what it had loaded, wrote the transcripts' smaller figure for it,
    /// which the app's later merge kept as the newer line. Only the production file has a legacy path; a test's
    /// URL never reaches for the real history.
    let legacy: URL?
    static let compactAbove = 4000

    init(url: URL = Paths.historyFile, tool: ToolID = .claude, legacy: URL? = nil) {
        self.url = url
        self.tool = tool
        self.legacy = legacy ?? (url == Paths.historyFile ? Paths.legacyHistoryFile : nil)
    }

    /// Builds before 2026-09-19 kept the file in ~/Library/Caches, which the OS may empty when disk runs short and
    /// Time Machine never backs up. Called at launch, before the providers build their CostHistory values, and by
    /// every `load` and `record` whose history still has a file at its legacy path, so whichever process touches
    /// the history first after the install performs the move: the app, or the `notchmeter` command, the status
    /// line or the MCP server running before it. Idempotent, and safe with a scan from another process having
    /// already written the new file: the legacy lines go in front of the existing ones, and since `parse` takes
    /// the newest line per (tool, day) the readings already in the new file still win. The old file is removed
    /// under the same lock, only after the copy or merge has been written, so a failure part way leaves both files
    /// for the next caller to try again, and a second process that took the lock a moment later finds nothing to
    /// move rather than merging the same lines in twice.
    static func migrateFromCaches(old: URL = Paths.legacyHistoryFile, new: URL = Paths.historyFile) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path) else { return }
        try? fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        let moved = serialised(new, LOCK_EX) {
            guard let legacy = try? Data(contentsOf: old) else { return false }
            let written: Bool
            if let existing = try? Data(contentsOf: new), !existing.isEmpty {
                var whole = legacy
                if whole.last != 0x0A { whole.append(0x0A) }
                whole.append(existing)
                written = (try? whole.write(to: new, options: .atomic)) != nil
            } else {
                written = (try? legacy.write(to: new, options: .atomic)) != nil
            }
            return written && (try? fm.removeItem(at: old)) != nil
        }
        guard moved else { return }
        log.notice("moved the daily history out of Caches")
    }

    /// `body` with `operation` (LOCK_EX or LOCK_SH) held on a sidecar `.lock` beside the file, or nil when the lock
    /// could not be taken. Three actors in this process (Claude's scanner, Codex's scanner, Cursor's provider) each
    /// hold their own CostHistory over the one path, and the `notchmeter` command appends from a second process,
    /// so a Swift lock would serialise only some of the writers; a flock serialises them all. The lock is a
    /// sidecar rather than the history file itself because compaction rewrites the history atomically, a temp
    /// file plus a rename, which gives the path a new inode: a lock taken on the old one would be dropped by the
    /// very write it has to exclude.
    private static func locked<T>(_ url: URL, _ operation: Int32, _ body: () -> T) -> T? {
        // O_RDONLY: flock(2) locks the open file, not its access mode, so a sidecar another uid left behind (a
        // probe run under sudo keeps HOME) or one restored read-only still takes the lock. Only the folder has to
        // be writable, which the history itself already needs.
        let fd = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDONLY | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard flock(fd, operation) == 0 else { return nil }
        defer { flock(fd, LOCK_UN) }
        return body()
    }

    /// `locked`, and when the lock cannot be taken, `body` anyway after a line in the log naming the sidecar.
    /// Until 0.5.0's review (2026-09-19) a nil from `locked` was the end of `record` and of `migrateFromCaches`,
    /// with nothing logged: a sidecar the user could not open (one a probe run under sudo had created root-owned)
    /// made every append and the move out of Caches a silent no-op for the life of the install, while `load` went
    /// on reading, so nothing looked wrong until transcripts were cleaned up and days began to disappear. The lock
    /// guards against a torn line or a lost append when two writers meet; a write without it risks that once,
    /// where a write skipped for it loses the day for good once the transcripts are gone.
    private static func serialised<T>(_ url: URL, _ operation: Int32, _ body: () -> T) -> T {
        if let result = locked(url, operation, body) { return result }
        log.notice("could not take the lock at \(url.appendingPathExtension("lock").path, privacy: .public); going ahead without it")
        return body()
    }

    /// The proleptic Gregorian reading of `calendar`'s wall clock: keys are the file's format, not the user's,
    /// so a non-Gregorian `Calendar.current` must still name the day "2026-09-02".
    private static func gregorian(_ calendar: Calendar) -> Calendar {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian
    }

    /// Both directions derive the day from a `Calendar` made on the spot rather than from a shared `DateFormatter`
    /// whose time zone every call would restamp: these run on the scanners' queues, the report and the store at
    /// once, and one call's time zone landing inside another's read collapsed two adjacent days onto one key.
    static func key(_ day: Date, calendar: Calendar = .current) -> String {
        let parts = gregorian(calendar).dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func day(_ key: String, calendar: Calendar = .current) -> Date? {
        let fields = key.split(separator: "-", omittingEmptySubsequences: false)
        guard fields.count == 3, fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let year = Int(fields[0]), let month = Int(fields[1]), let dayOfMonth = Int(fields[2]) else { return nil }
        let reference = gregorian(calendar)
        guard let date = reference.date(from: DateComponents(year: year, month: month, day: dayOfMonth)) else { return nil }
        let round = reference.dateComponents([.year, .month, .day], from: date)
        guard round.year == year, round.month == month, round.day == dayOfMonth else { return nil }
        return calendar.startOfDay(for: date)
    }

    /// The move out of Caches, when this history's legacy path still has a file: a stat when it does not, which is
    /// every call after the first. `load` and `record` both call it, so the whole history is in one place before
    /// either reads or writes, whichever process gets there first.
    private func moveLegacy() {
        guard let legacy else { return }
        Self.migrateFromCaches(old: legacy, new: url)
    }

    /// Read under a shared lock, so a compaction in another writer is seen whole rather than as the empty file
    /// between its truncate and its rewrite. An absent file is not read at all, so a fresh install, whose folder
    /// is not there yet, neither takes a lock nor logs that it could not. Should the move out of Caches have
    /// failed (the folder unwritable, say), the legacy lines still fill in underneath the new file's, the new
    /// file's line for a day winning as it does in the merge, so no reader ever sees less than the whole history.
    func load(calendar: Calendar = .current) -> [Date: Record] {
        moveLegacy()
        let fm = FileManager.default
        var result: [Date: Record] = [:]
        if fm.fileExists(atPath: url.path), let data = Self.serialised(url, LOCK_SH, { try? Data(contentsOf: url) }) {
            result = Self.parse(data, tool: tool, calendar: calendar)
        }
        if let legacy, let data = try? Data(contentsOf: legacy) {
            result.merge(Self.parse(data, tool: tool, calendar: calendar)) { current, _ in current }
        }
        return result
    }

    static func parse(_ data: Data, tool: ToolID, calendar: Calendar = .current) -> [Date: Record] {
        var result: [Date: Record] = [:]
        let decoder = JSONDecoder()
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            guard let parsed = try? decoder.decode(Line.self, from: line), parsed.tool == tool.rawValue, let day = day(parsed.day, calendar: calendar) else { continue }
            result[day] = Record(cost: parsed.cost, tokens: parsed.tokens, byModel: parsed.byModel, byProject: parsed.byProject,
                                 byModelTokens: parsed.byModelTokens ?? [:], byProjectTokens: parsed.byProjectTokens ?? [:],
                                 sessionTokensPerPercent: parsed.sessionTokensPerPercent ?? result[day]?.sessionTokensPerPercent,
                                 priceSources: Set(parsed.priceSources ?? []))
        }
        return result
    }

    /// Appends the days whose totals moved (a smaller total than remembered is a deleted transcript and is not
    /// written), and the days whose lines were priced under a source the line on file does not name yet: a
    /// catalog update re-prices what is still on disk, and the day then names both the source recorded for the
    /// lines since deleted and the one that priced the rest. A source already on file is not a change, so a day
    /// whose transcripts are half gone is not rewritten on every scan.
    func record(_ days: [Date: Record], existing: [Date: Record], calendar: Calendar = .current) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var appended = Data()
        var merged = existing
        for (day, record) in days where record.cost > 0 {
            if let known = existing[day], known.cost >= record.cost - 0.0005,
               record.sessionTokensPerPercent == nil || known.sessionTokensPerPercent == record.sessionTokensPerPercent,
               record.priceSources.isSubset(of: known.priceSources) { continue }
            var record = record
            if let known = existing[day], known.cost > record.cost {
                // The larger figure is the line on file, priced when every transcript was still there; the lines
                // still here were priced now, so both sets of sources priced the day.
                let priced = record.priceSources
                record = known
                record.priceSources.formUnion(priced)
            }
            if record.sessionTokensPerPercent == nil { record.sessionTokensPerPercent = existing[day]?.sessionTokensPerPercent }
            merged[day] = record
            guard let data = try? encoder.encode(Line(day: Self.key(day, calendar: calendar), tool: tool.rawValue, record: record)) else { continue }
            appended.append(data)
            appended.append(0x0A)
        }
        guard !appended.isEmpty else { return }
        moveLegacy()
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The line count, the compaction's re-read of every other tool's lines and the write are one critical
        // section: counted outside the lock, a compaction rewrote the file from a snapshot that predated another
        // writer's append and dropped it. This tool's own days come from `existing`, which the caller loaded a
        // moment ago; the only writer that could have raised one of them since is the same scanner in another
        // process, and its line is re-appended by whichever scan next finds the file short of it.
        Self.serialised(url, LOCK_EX) {
            let lines = (try? Data(contentsOf: url))?.split(separator: 0x0A).count ?? 0
            if lines + days.count > Self.compactAbove {
                try? compacted(merged, calendar: calendar, encoder: encoder).write(to: url, options: .atomic)
                return
            }
            // O_APPEND: the kernel picks the offset and lands the bytes in one call, so two appends cannot resolve
            // the same end of file even from a writer that takes no lock (an older build of the command, say).
            // O_CREAT is the whole of the first-write path. There is deliberately no fallback when the open fails:
            // until 2026-09-19 a failed open on an existing file fell through to an atomic write of just the new
            // lines, which replaced the entire history with the few days that had changed. Skipping the write
            // costs nothing, because the next scan finds the file short of those days and appends them again.
            let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
            guard fd >= 0 else { return }
            defer { close(fd) }
            appended.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let written = write(fd, base.advanced(by: offset), buffer.count - offset)
                    guard written > 0 else { return }
                    offset += written
                }
            }
        }
    }

    /// The whole file rewritten with one line per tool and day: this tool's days from `merged`, and the newest
    /// line of every other tool's days kept as they stand. The file is shared — Claude's transcripts and Cursor's
    /// export both write to it — so a compaction that emitted only the calling tool's records deleted the other's
    /// history outright.
    private func compacted(_ merged: [Date: Record], calendar: Calendar, encoder: JSONEncoder) -> Data {
        var newest: [String: Line] = [:]
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            for raw in data.split(separator: 0x0A) where !raw.isEmpty {
                guard let parsed = try? decoder.decode(Line.self, from: raw), parsed.tool != tool.rawValue else { continue }
                newest["\(parsed.tool)/\(parsed.day)"] = parsed
            }
        }
        for (day, record) in merged {
            let line = Line(day: Self.key(day, calendar: calendar), tool: tool.rawValue, record: record)
            newest["\(line.tool)/\(line.day)"] = line
        }
        var whole = Data()
        for key in newest.keys.sorted() {
            guard let line = newest[key], let data = try? encoder.encode(line) else { continue }
            whole.append(data)
            whole.append(0x0A)
        }
        return whole
    }

    /// "Export history…": one row per day, oldest first, with the five token buckets, the top model and the
    /// per-model and per-project splits as `name:cost` pairs; values with a comma or a quote are quoted.
    static func csv(_ records: [Date: Record], calendar: Calendar = .current) -> String {
        func cell(_ text: String) -> String {
            text.contains(",") || text.contains("\"") || text.contains("\n") ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
        }
        func split(_ shares: [String: Double]) -> String {
            shares.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map { "\($0.key):\(String(format: "%.4f", $0.value))" }.joined(separator: "; ")
        }
        var lines = ["day,costUSD,input,output,cacheWrite5m,cacheWrite1h,cacheRead,topModel,sessionTokensPerPercent,byModel,byProject"]
        for (day, record) in records.sorted(by: { $0.key < $1.key }) {
            lines.append([
                key(day, calendar: calendar), String(format: "%.4f", record.cost), String(record.tokens.input), String(record.tokens.output),
                String(record.tokens.cacheWrite5m), String(record.tokens.cacheWrite1h), String(record.tokens.cacheRead), record.topModel ?? "",
                record.sessionTokensPerPercent.map { String(Int($0.rounded())) } ?? "", split(record.byModel), split(record.byProject),
            ].map(cell).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The same rows as JSON, the shape `--probe --json --history` prints under `history`.
    static func json(_ records: [Date: Record], calendar: Calendar = .current) -> Data {
        (try? JSONSerialization.data(withJSONObject: UsageReport.historyRows(records, calendar: calendar), options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])) ?? Data("[]".utf8)
    }
}
