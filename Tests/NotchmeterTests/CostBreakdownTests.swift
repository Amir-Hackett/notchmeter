import Foundation
import Testing
@testable import Notchmeter

/// Golden fixtures for the rules added after the first suite: the web-search fee, fast mode, projects, the
/// week/month/90-day ranges, the durable history, the incremental digests and pricing overrides.
@Suite(.serialized) struct CostBreakdown {
    let now = DateParsing.iso8601("2026-09-01T15:00:00Z")!
    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func summary(_ jsonl: String, weeklyResetsAt: Date? = nil, weeklyUsed: Double? = nil, sessionResetsAt: Date? = nil) -> CostSummary {
        ClaudeCostScanner.summarize(ClaudeCostScanner.dedupe(ClaudeCostScanner.parseFile(Data(jsonl.utf8))), now: now, daysBack: 30,
                                    weeklyResetsAt: weeklyResetsAt, weeklyUsed: weeklyUsed, sessionResetsAt: sessionResetsAt, calendar: utc)
    }

    @Test func webSearchesArePricedPerRequestAndNeverMultiplied() {
        // Sonnet 5: 1000 × $2 + 100 × $10 = $0.003, × 1.1 = $0.0033; plus 3 searches × $0.01 = $0.0333.
        let jsonl = """
        {"type":"assistant","timestamp":"2026-09-01T14:40:00.000Z","requestId":"req_w","cwd":"/Users/me/Developer/notchmeter","message":{"id":"msg_w","model":"claude-sonnet-5","usage":{"input_tokens":1000,"output_tokens":100,"inference_geo":"us","server_tool_use":{"web_search_requests":3,"web_fetch_requests":1}}}}
        """
        #expect(abs(summary(jsonl).last30Days - 0.0333) < 1e-9)
    }

    @Test func fastModeDoublesOpusRates() {
        // Opus 4.8 fast: 1000 × $10 + 100 × $50 = $0.015; standard would be $0.0075. Sonnet ignores the marker.
        let fast = """
        {"type":"assistant","timestamp":"2026-09-01T14:40:00.000Z","requestId":"req_f","message":{"id":"msg_f","model":"claude-opus-4-8","usage":{"input_tokens":1000,"output_tokens":100,"speed":"fast"}}}
        """
        #expect(abs(summary(fast).last30Days - 0.015) < 1e-9)
        let standard = fast.replacingOccurrences(of: "\"speed\":\"fast\"", with: "\"speed\":\"standard\"")
        #expect(abs(summary(standard).last30Days - 0.0075) < 1e-9)
        let sonnet = fast.replacingOccurrences(of: "claude-opus-4-8", with: "claude-sonnet-5")
        #expect(abs(summary(sonnet).last30Days - 0.003) < 1e-9)
        #expect(ModelPricing.rates(for: "claude-opus-5", speed: "fast") == ModelPricing.opusFast)
        #expect(ModelPricing.rates(for: "claude-opus-4-6", speed: "fast") == ModelPricing.opus5)
    }

    @Test func projectsComeFromCwdThenTheFolderNameAndRankByCost() throws {
        let jsonl = """
        {"type":"assistant","timestamp":"2026-09-01T14:40:00.000Z","requestId":"r1","cwd":"/Users/me/Developer/notchmeter","message":{"id":"m1","model":"claude-sonnet-5","usage":{"input_tokens":1000000,"output_tokens":0}}}
        {"type":"assistant","timestamp":"2026-09-01T14:41:00.000Z","requestId":"r2","cwd":"/Users/me/Developer/scout","message":{"id":"m2","model":"claude-opus-5","usage":{"input_tokens":1000000,"output_tokens":0}}}
        {"type":"assistant","timestamp":"2026-09-01T14:42:00.000Z","requestId":"r3","message":{"id":"m3","model":"claude-haiku-4-5","usage":{"input_tokens":1000000,"output_tokens":0}}}
        """
        let entries = ClaudeCostScanner.parseFile(Data(jsonl.utf8), project: "fallback")
        #expect(entries.map(\.project) == ["notchmeter", "scout", "fallback"])
        let totals = ClaudeCostScanner.summarize(entries, now: now, daysBack: 30, calendar: utc).totals(.today)
        #expect(totals.projects.map(\.name) == ["scout", "notchmeter", "fallback"])
        #expect(totals.projects.map(\.cost) == [5, 2, 1])
        #expect(totals.models.map(\.name) == ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"])
        #expect(totals.tokens.total == 3_000_000)
        #expect(ClaudeCostScanner.projectName(fromFolder: "-Users-amirhackett-Developer-notchmeter") == "notchmeter")
        #expect(ClaudeCostScanner.projectName(fromFolder: "---") == nil)
        #expect(ClaudeCostScanner.projectName(fromPath: "/") == nil)
        let five = CostShare.top(["a": 5, "b": 4, "c": 3, "d": 2, "e": 1, "f": 0.5, "zero": 0])
        #expect(five.map(\.name) == ["a", "b", "c", "d", CostShare.other])
        #expect(five.last?.cost == 1.5)
    }

    @Test func weekMonthAndBlockAlignToTheLiveWindows() throws {
        // Weekly reset Thursday 2026-09-03 21:00 UTC → the week began Thursday 08-27 21:00. Session resets 17:00 → block began 12:00.
        let jsonl = """
        {"type":"assistant","timestamp":"2026-08-27T20:00:00.000Z","requestId":"a","message":{"id":"a","model":"claude-sonnet-5","usage":{"input_tokens":1000000,"output_tokens":0}}}
        {"type":"assistant","timestamp":"2026-08-27T22:00:00.000Z","requestId":"b","message":{"id":"b","model":"claude-sonnet-5","usage":{"input_tokens":1000000,"output_tokens":0}}}
        {"type":"assistant","timestamp":"2026-08-31T10:00:00.000Z","requestId":"c","message":{"id":"c","model":"claude-sonnet-5","usage":{"input_tokens":1000000,"output_tokens":0}}}
        {"type":"assistant","timestamp":"2026-09-01T11:30:00.000Z","requestId":"d","message":{"id":"d","model":"claude-sonnet-5","usage":{"input_tokens":1000000,"output_tokens":0}}}
        {"type":"assistant","timestamp":"2026-09-01T13:00:00.000Z","requestId":"e","message":{"id":"e","model":"claude-sonnet-5","usage":{"input_tokens":500000,"output_tokens":0}}}
        {"type":"assistant","timestamp":"2026-09-01T14:50:00.000Z","requestId":"f","message":{"id":"f","model":"claude-sonnet-5","usage":{"input_tokens":500000,"output_tokens":0}}}
        """
        let weekly = DateParsing.iso8601("2026-09-03T21:00:00Z")!
        let session = DateParsing.iso8601("2026-09-01T17:00:00Z")!
        let cost = summary(jsonl, weeklyResetsAt: weekly, weeklyUsed: 0.5, sessionResetsAt: session)
        let week = try #require(cost.week)
        #expect(week.start == weekly.addingTimeInterval(-Period.week))
        #expect(abs(week.cost - 8) < 1e-9)
        #expect(abs(try #require(week.perPercent) - 0.16) < 1e-9)
        #expect(abs(cost.totals(.week).cost - 8) < 1e-9)
        #expect(abs(cost.totals(.month).cost - 4) < 1e-9)
        #expect(abs(cost.today - 4) < 1e-9)
        #expect(abs(cost.totals(.last90Days).cost - 10) < 1e-9)
        #expect(abs(cost.sinceFirstUse - 10) < 1e-9)
        #expect(cost.firstUse == utc.startOfDay(for: DateParsing.iso8601("2026-08-27T20:00:00Z")!))
        let block = try #require(cost.block)
        #expect(block.start == session.addingTimeInterval(-Period.fiveHours))
        #expect(abs(block.cost - 2) < 1e-9)
        #expect(block.tokens.total == 1_000_000)
        // 1,000,000 tokens since the block's first entry at 13:00, two hours before now.
        #expect(abs(try #require(block.tokensPerMinute) - 1_000_000 / 120) < 1e-6)
        #expect(abs(cost.lastHour - 1) < 1e-9)
        let noWindows = summary(jsonl)
        #expect(noWindows.block == nil)
        #expect(noWindows.week?.perPercent == nil)
    }

    @Test func digestsFoldTheSameTotalsAsEntriesAndCarryTheTopModel() {
        let jsonl = """
        {"type":"assistant","timestamp":"2026-09-01T14:40:00.000Z","requestId":"a","cwd":"/x/notchmeter","message":{"id":"a","model":"claude-sonnet-5","usage":{"input_tokens":1000000,"output_tokens":0}}}
        {"type":"assistant","timestamp":"2026-08-20T14:41:00.000Z","requestId":"b","cwd":"/x/scout","message":{"id":"b","model":"claude-opus-5","usage":{"input_tokens":1000000,"output_tokens":0}}}
        {"type":"assistant","timestamp":"2026-08-20T09:41:00.000Z","requestId":"c","message":{"id":"c","model":"claude-nimbus-1","usage":{"input_tokens":1000000,"output_tokens":0}}}
        """
        let entries = ClaudeCostScanner.dedupe(ClaudeCostScanner.parseFile(Data(jsonl.utf8)))
        let digest = FileDigest.build(entries)
        #expect(digest.buckets.count == 3)
        #expect(digest.unpriced == ["claude-nimbus-1"])
        let fine = ClaudeCostScanner.summarize(entries, now: now, daysBack: 30, calendar: utc)
        let coarse = ClaudeCostScanner.summarize(digests: [digest], fine: [], now: now, daysBack: 30, weeklyResetsAt: nil, weeklyUsed: nil,
                                                 sessionResetsAt: nil, history: [:], calendar: utc)
        #expect(coarse.last30Days == fine.last30Days)
        #expect(coarse.daily == fine.daily)
        #expect(coarse.totals(.last30Days).byProject == fine.totals(.last30Days).byProject)
        #expect(coarse.unpricedModels == fine.unpricedModels)
        #expect(coarse.lastHour == 0)
        #expect(fine.lastHour == 2)
        #expect(fine.daily.last?.topModel == "claude-sonnet-5")
        #expect(fine.daily.first { utc.component(.day, from: $0.day) == 20 }?.topModel == "claude-opus-5")
        #expect(ModelPricing.fingerprint.hasPrefix(ModelPricing.snapshotDate))
    }

    @Test func historyOutlivesTheTranscriptsAndKeepsTheLargerDay() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("notchmeter-history-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let history = CostHistory(url: dir.appendingPathComponent("daily.jsonl"))
        let gone = utc.date(byAdding: .day, value: -40, to: utc.startOfDay(for: now))!
        let yesterday = utc.date(byAdding: .day, value: -1, to: utc.startOfDay(for: now))!
        let records: [Date: CostHistory.Record] = [
            gone: CostHistory.Record(cost: 12, tokens: TokenBreakdown(input: 10), byModel: ["claude-opus-5": 12], byProject: ["scout": 12]),
            yesterday: CostHistory.Record(cost: 3, tokens: TokenBreakdown(input: 3), byModel: ["claude-sonnet-5": 3], byProject: ["notchmeter": 3]),
        ]
        history.record(records, existing: [:], calendar: utc)
        let loaded = history.load(calendar: utc)
        #expect(loaded[gone]?.cost == 12)
        #expect(loaded[yesterday]?.topModel == "claude-sonnet-5")
        // The transcript for yesterday now prices lower (a file was deleted): the remembered day wins; today is live.
        let jsonl = """
        {"type":"assistant","timestamp":"2026-08-31T10:00:00.000Z","requestId":"y","message":{"id":"y","model":"claude-sonnet-5","usage":{"input_tokens":500000,"output_tokens":0}}}
        {"type":"assistant","timestamp":"2026-09-01T14:00:00.000Z","requestId":"t","message":{"id":"t","model":"claude-sonnet-5","usage":{"input_tokens":1000000,"output_tokens":0}}}
        """
        let entries = ClaudeCostScanner.parseFile(Data(jsonl.utf8))
        let cost = ClaudeCostScanner.summarize(digests: [FileDigest.build(entries)], fine: entries, now: now, daysBack: 30, weeklyResetsAt: nil,
                                               weeklyUsed: nil, sessionResetsAt: nil, history: loaded, calendar: utc)
        #expect(cost.yesterday == 3)
        #expect(cost.today == 2)
        #expect(cost.last30Days == 5)
        #expect(cost.totals(.last90Days).cost == 17)
        #expect(cost.sinceFirstUse == 17)
        #expect(cost.daily90.count == 90)
        // A smaller day is never written over a larger one; a larger one is appended.
        history.record([yesterday: CostHistory.Record(cost: 1, tokens: TokenBreakdown(), byModel: [:], byProject: [:])], existing: loaded, calendar: utc)
        #expect(history.load(calendar: utc)[yesterday]?.cost == 3)
        history.record([yesterday: CostHistory.Record(cost: 4, tokens: TokenBreakdown(), byModel: [:], byProject: [:])], existing: loaded, calendar: utc)
        #expect(history.load(calendar: utc)[yesterday]?.cost == 4)
        let text = try String(contentsOf: history.url, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 3)
        #expect(!text.contains("/Users"))
    }

    @Test func pricingOverridesWinOverTheTableAndChangeTheFingerprint() {
        defer { ModelPricing.overrides = [:] }
        let before = ModelPricing.fingerprint
        let parsed = ModelPricing.parseOverrides(["claude-opus-5": ["input": 4, "output": 20, "cache_read": 0.4], "claude-x": ["output": 1]])
        #expect(parsed.keys.sorted() == ["claude-opus-5"])
        ModelPricing.overrides = parsed
        #expect(ModelPricing.rates(for: "claude-opus-5-20261001")?.input == 4)
        #expect(ModelPricing.rates(for: "claude-opus-5")?.cacheRead == 0.4)
        #expect(ModelPricing.rates(for: "claude-opus-5")?.cacheWrite5m == 5)
        #expect(ModelPricing.rates(for: "claude-sonnet-5") == ModelPricing.sonnet5)
        #expect(ModelPricing.fingerprint != before)
        let cost = ModelPricing.cost(of: TokenBreakdown(input: 1_000_000), model: "claude-opus-5", speed: "fast")
        #expect(cost == 4)
    }

    @Test func overridesLoadFromClaudeSettingsThenNotchmetersOwnFile() throws {
        defer { ModelPricing.overrides = [:] }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("notchmeter-pricing-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let claude = dir.appendingPathComponent("settings.json")
        let own = dir.appendingPathComponent("pricing-overrides.json")
        try Data(#"{"modelPricing":{"claude-sonnet-5":{"inputTokens":1,"outputTokens":5}},"model":"opus"}"#.utf8).write(to: claude)
        ModelPricing.loadOverrides(claudeSettings: claude, own: own)
        #expect(ModelPricing.rates(for: "claude-sonnet-5")?.input == 1)
        try Data(#"{"claude-sonnet-5":{"input":1.5,"output":7}}"#.utf8).write(to: own)
        ModelPricing.loadOverrides(claudeSettings: claude, own: own)
        #expect(ModelPricing.rates(for: "claude-sonnet-5")?.input == 1.5)
        ModelPricing.loadOverrides(claudeSettings: dir.appendingPathComponent("none.json"), own: dir.appendingPathComponent("none2.json"))
        #expect(ModelPricing.overrides.isEmpty)
    }

    @Test func snapshotFileMatchesTheTableAndItsDate() throws {
        let url = try #require(Localization.resources.url(forResource: "pricing-snapshot", withExtension: "json"))
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(root["snapshotDate"] as? String == ModelPricing.snapshotDate)
        let models = try #require(root["models"] as? [String: [String: Any]])
        for (prefix, rates) in ModelPricing.table {
            let row = try #require(models[prefix], "snapshot lacks \(prefix)")
            #expect(JSON.number(row["input"]) == rates.input, Comment(rawValue: prefix))
            #expect(JSON.number(row["output"]) == rates.output, Comment(rawValue: prefix))
        }
        #expect(Set(models.keys) == Set(ModelPricing.table.map(\.prefix)))
        #expect(JSON.number(root["webSearchPerRequest"]) == ModelPricing.webSearchRequest)
    }

    @Test func coworkAndFlatFoldersAreReadAsTranscriptRoots() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("notchmeter-roots-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let cowork = dir.appendingPathComponent("local-agent-mode-sessions/org/user/local_abc")
        let synced = dir.appendingPathComponent("synced/projects/-Users-other-Developer-scout")
        try fm.createDirectory(at: cowork, withIntermediateDirectories: true)
        try fm.createDirectory(at: synced, withIntermediateDirectories: true)
        let line = #"{"type":"assistant","timestamp":"2026-09-01T14:00:00.000Z","requestId":"r","message":{"id":"m","model":"claude-sonnet-5","usage":{"input_tokens":1000000,"output_tokens":0}}}"#
        try Data((line + "\n").utf8).write(to: cowork.appendingPathComponent("audit.jsonl"))
        try Data((line.replacingOccurrences(of: "\"requestId\":\"r\"", with: "\"requestId\":\"s\"") + "\n").utf8).write(to: synced.appendingPathComponent("s.jsonl"))
        let roots = [dir.appendingPathComponent("local-agent-mode-sessions"), dir.appendingPathComponent("synced")]
        let files = ClaudeCostScanner.transcriptFiles(under: roots)
        #expect(files.map(\.project) == ["Cowork", "scout"])
        let scanner = ClaudeCostScanner(roots: roots, cacheURL: dir.appendingPathComponent("cache.json"), history: nil)
        let cost = await scanner.scan(now: now)
        #expect(abs(cost.today - 4) < 1e-9)
        #expect(cost.totals(.today).projects.map(\.name) == ["Cowork", "scout"])
        let again = await scanner.scan(now: now)
        #expect(again.today == cost.today)
        #expect(ClaudeCostScanner.transcriptFolder(of: dir.appendingPathComponent("synced")).lastPathComponent == "projects")
        #expect(ClaudeCostScanner.transcriptFolder(of: roots[0]) == roots[0])
    }

    /// Entry-level detail is only ever asked for inside the fine horizon (the last hour and the current block), so
    /// the cache holds entries for that recent a file alone and folds every older one from its digest. Loading the
    /// cache also clears the files earlier versions left behind, which nothing else removes.
    @Test func theCacheHoldsEntriesOnlyForRecentFilesAndClearsOlderVersions() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("notchmeter-cache-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let projects = dir.appendingPathComponent("projects/-Users-a-Developer-notchmeter")
        try fm.createDirectory(at: projects, withIntermediateDirectories: true)
        func line(_ request: String) -> String {
            #"{"type":"assistant","timestamp":"2026-09-01T14:00:00.000Z","requestId":"@","message":{"id":"m@","model":"claude-sonnet-5","usage":{"input_tokens":1000000,"output_tokens":0}}}"#
                .replacingOccurrences(of: "@", with: request) + "\n"
        }
        let recent = projects.appendingPathComponent("recent.jsonl")
        let old = projects.appendingPathComponent("old.jsonl")
        try Data(line("r").utf8).write(to: recent)
        try Data(line("o").utf8).write(to: old)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-4 * 3600)], ofItemAtPath: old.path)
        let superseded = dir.appendingPathComponent("claude-usage-cache-v2.json")
        try Data("{}".utf8).write(to: superseded)
        let cacheURL = dir.appendingPathComponent("claude-usage-cache-v3.json")
        let scanner = ClaudeCostScanner(roots: [dir], cacheURL: cacheURL, history: nil)
        let first = await scanner.scan(now: now)
        #expect(!fm.fileExists(atPath: superseded.path))
        let stored = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: [String: Any]])
        let aged = try #require(stored.first { $0.key.hasSuffix("old.jsonl") }?.value)
        let fresh = try #require(stored.first { $0.key.hasSuffix("recent.jsonl") }?.value)
        #expect(aged["entries"] == nil)
        #expect(aged["digest"] != nil)
        #expect((fresh["entries"] as? [Any])?.count == 1)
        // The aged file's money survives it: the digest carries the day, and a second scan reads the same totals.
        #expect(abs(first.today - 4) < 1e-9)
        let again = await scanner.scan(now: now)
        #expect(again.today == first.today)
    }
}


/// Dollars per million tokens, the cache-tier shift, and the history export.
@Suite struct CostRoundTwo {
    init() { Localization.use(language: "en") }

    @Test func costPerMillionTokensCountsEveryBucket() {
        // $2 across 1.5M input, 0.5M cache reads: $1.00 per MTok.
        let totals = RangeTotals(cost: 2, tokens: TokenBreakdown(input: 1_500_000, cacheRead: 500_000))
        #expect(totals.costPerMillionTokens == 1)
        #expect(RangeTotals().costPerMillionTokens == nil)
        #expect(SpendCard.headline(mode: .perMillionTokens, amount: 2, totals: totals) == "$1.00")
        #expect(SpendCard.headline(mode: .tokens, amount: 2, totals: totals) == "2.0M")
        #expect(SpendCard.headline(mode: .cost, amount: 2.4, totals: totals) == "$2")
        #expect(SpendCard.headline(mode: .cost, amount: nil, totals: nil) == "—")
        #expect(CostCardMode.cost.next == .tokens)
        #expect(CostCardMode.perMillionTokens.next == .cost)
        #expect(SpendCard.unit(mode: .perMillionTokens) == "per MTok")
    }

    @Test func aCacheTierShiftIsNoticedAgainstTheNorm() {
        let norm = TokenBreakdown(cacheWrite5m: 180_000, cacheWrite1h: 820_000)
        let today = TokenBreakdown(cacheWrite5m: 164_000, cacheWrite1h: 36_000)
        #expect(CacheTTL.oneHourShare(norm) == 0.82)
        #expect(CacheTTL.oneHourShare(TokenBreakdown()) == nil)
        let shift = CacheTTL.shift(today: today, norm: norm)
        #expect(shift?.today == 0.18)
        #expect(shift?.norm == 0.82)
        #expect(CacheTTL.shift(today: TokenBreakdown(cacheWrite5m: 1000, cacheWrite1h: 0), norm: norm) == nil)
        #expect(CacheTTL.shift(today: TokenBreakdown(cacheWrite5m: 60_000, cacheWrite1h: 140_000), norm: norm) == nil)
        let cost = CostSummary(today: 0, yesterday: 0, last30Days: 0, daily: [], lastHour: 0, typicalHourly: 0, burnMultiple: nil, unpricedModels: [], scannedAt: Date(),
                               ranges: [.today: RangeTotals(cost: 1, tokens: today), .last30Days: RangeTotals(cost: 30, tokens: norm)])
        #expect(Advisor.cacheShift(cost)?.text == "Cache writes today are 18% 1-hour against a 30-day norm of 82%: the 5-minute tier re-caches more often and costs more quota per turn.")
        #expect(Advisor.cacheShift(nil) == nil)
        // The fixture flips the mix: three 1-hour lines yesterday, three 5-minute lines today.
        let now = DateParsing.iso8601("2026-09-01T15:00:00Z")!
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var lines: [String] = []
        for i in 0..<3 {
            lines.append(#"{"type":"assistant","timestamp":"2026-08-31T10:0\#(i):00.000Z","requestId":"y\#(i)","message":{"id":"y\#(i)","model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":1,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":200000}}}}"#)
            lines.append(#"{"type":"assistant","timestamp":"2026-09-01T14:0\#(i):00.000Z","requestId":"t\#(i)","message":{"id":"t\#(i)","model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":1,"cache_creation":{"ephemeral_5m_input_tokens":200000,"ephemeral_1h_input_tokens":0}}}}"#)
        }
        let entries = ClaudeCostScanner.dedupe(ClaudeCostScanner.parseFile(Data(lines.joined(separator: "\n").utf8)))
        let summary = ClaudeCostScanner.summarize(entries, now: now, daysBack: 30, calendar: utc)
        #expect(CacheTTL.oneHourShare(summary.totals(.today).tokens) == 0)
        #expect(CacheTTL.oneHourShare(summary.totals(.last30Days).tokens) == 0.5)
        #expect(Advisor.cacheShift(summary)?.text.hasPrefix("Cache writes today are 0% 1-hour against a 30-day norm of 50%") == true)
        let object = UsageReport(tools: [:], cost: summary, advice: [], now: now).object
        let ranges = (object["cost"] as? [String: Any])?["ranges"] as? [String: Any]
        let buckets = (ranges?["today"] as? [String: Any])?["tokenBuckets"] as? [String: Any]
        #expect(buckets?["cacheWrite5m"] as? Int == 600_000)
        #expect(buckets?["cacheWrite1h"] as? Int == 0)
    }

    @Test func historyExportsAsCSVAndJSONRows() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let day = utc.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        let records = [day: CostHistory.Record(cost: 12.5, tokens: TokenBreakdown(input: 1, cacheWrite5m: 2, cacheWrite1h: 3, cacheRead: 4, output: 5),
                                               byModel: ["claude-opus-5": 10, "claude-sonnet-5": 2.5], byProject: ["notchmeter": 12.5], sessionTokensPerPercent: 140_000)]
        let csv = CostHistory.csv(records, calendar: utc)
        let lines = csv.split(separator: "\n")
        #expect(lines[0] == "day,costUSD,input,output,cacheWrite5m,cacheWrite1h,cacheRead,topModel,sessionTokensPerPercent,byModel,byProject")
        #expect(lines[1] == "2026-09-01,12.5000,1,5,2,3,4,claude-opus-5,140000,claude-opus-5:10.0000; claude-sonnet-5:2.5000,notchmeter:12.5000")
        let rows = try #require(try JSONSerialization.jsonObject(with: CostHistory.json(records, calendar: utc)) as? [[String: Any]])
        #expect(rows.count == 1)
        #expect(rows[0]["day"] as? String == "2026-09-01")
        #expect((rows[0]["tokenBuckets"] as? [String: Any])?["cacheRead"] as? Int == 4)
        #expect(rows[0]["topModel"] as? String == "claude-opus-5")
        #expect(rows[0]["sessionTokensPerPercent"] as? Int == 140_000)
        let quoted = CostHistory.csv([day: CostHistory.Record(cost: 1, tokens: TokenBreakdown(), byModel: [:], byProject: ["a,b": 1])], calendar: utc)
        #expect(quoted.contains("\"a,b:1.0000\""))
        let report = UsageReport(tools: [:], cost: nil, advice: [], history: records, now: day)
        #expect(((report.object["history"] as? [[String: Any]])?.first?["cost"] as? NSNumber)?.doubleValue == 12.5)
    }
}
