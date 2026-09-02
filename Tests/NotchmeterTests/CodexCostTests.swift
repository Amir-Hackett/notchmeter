import Foundation
import Testing
@testable import Notchmeter

/// Codex's session rollouts priced at OpenAI's published rates. This Mac has no Codex sessions, so every fixture
/// here is a synthetic rollout written in the shape codex-rs records: a `turn_context` line naming the model and
/// the folder, then `token_usage_record` lines (or, on older builds, `token_count` events).
@Suite struct CodexCostScanning {
    init() { Localization.use(language: "en") }

    let now = DateParsing.iso8601("2026-09-01T15:00:00Z")!

    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func turnContext(model: String, cwd: String = "/Users/someone/Developer/notchmeter", at: String = "2026-09-01T14:00:00.000Z") -> String {
        #"{"timestamp":"\#(at)","type":"turn_context","payload":{"cwd":"\#(cwd)","approval_policy":"on-request","model":"\#(model)","summary":"auto"}}"#
    }

    func record(_ id: String, input: Int, cached: Int, output: Int, reasoning: Int = 0, write: Int = 0,
                at: String = "2026-09-01T14:30:00.000Z") -> String {
        #"""
        {"timestamp":"\#(at)","type":"token_usage_record","payload":{"thread_id":"t1","turn_id":"u1","session_id":"s1","root_turn_id":"u1","response_id":"\#(id)","usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"cache_write_input_tokens":\#(write),"output_tokens":\#(output),"reasoning_output_tokens":\#(reasoning),"total_tokens":\#(input + output)},"turn_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"cache_write_input_tokens":0,"output_tokens":\#(output),"reasoning_output_tokens":\#(reasoning),"total_tokens":\#(input + output)},"thread_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"cache_write_input_tokens":0,"output_tokens":\#(output),"reasoning_output_tokens":\#(reasoning),"total_tokens":\#(input + output)}}}
        """#
    }

    func tokenCount(input: Int, cached: Int, output: Int, at: String) -> String {
        #"""
        {"timestamp":"\#(at)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":0,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":0},"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"cache_write_input_tokens":0,"output_tokens":\#(output),"reasoning_output_tokens":0,"total_tokens":\#(input + output)},"model_context_window":272000},"rate_limits":{"primary":{"used_percent":12.5,"window_minutes":300}}}}
        """#
    }

    func priced(_ jsonl: String) -> (cost: Double, unpriced: Set<String>, entries: [CodexUsage]) {
        let entries = CodexCostScanner.dedupe(CodexCostScanner.parseFile(Data(jsonl.utf8)))
        var unpriced: Set<String> = []
        let cost = entries.reduce(0.0) { $0 + CodexCostScanner.price($1, unpriced: &unpriced) }
        return (cost, unpriced, entries)
    }

    /// gpt-5.3-codex is $1.75 / $0.175 / $14.00 per million. `input_tokens` counts the cached tokens, so the
    /// billed input is 10,000 − 8,000; `reasoning_output_tokens` is inside `output_tokens` and is not added again.
    @Test func aTurnIsPricedOnFreshInputCachedInputAndWholeOutput() {
        let jsonl = [turnContext(model: "gpt-5.3-codex"), record("resp_a", input: 10_000, cached: 8000, output: 2000, reasoning: 1500)].joined(separator: "\n")
        let result = priced(jsonl)
        // 2,000 × $1.75 + 8,000 × $0.175 + 2,000 × $14.00, per million = $0.0329.
        #expect(abs(result.cost - 0.0329) < 1e-9)
        #expect(result.unpriced.isEmpty)
        #expect(result.entries.first?.model == "gpt-5.3-codex")
        #expect(result.entries.first?.project == "notchmeter")
        #expect(result.entries.first?.tokens == TokenBreakdown(input: 2000, cacheRead: 8000, output: 2000))
    }

    @Test func severalTurnsInOneRolloutAddUp() {
        let jsonl = [turnContext(model: "gpt-5.3-codex"),
                     record("resp_a", input: 10_000, cached: 8000, output: 2000, reasoning: 1500),
                     record("resp_b", input: 4000, cached: 0, output: 500)].joined(separator: "\n")
        // $0.0329 + (4,000 × $1.75 + 500 × $14.00) / 1e6 = $0.0329 + $0.014.
        #expect(abs(priced(jsonl).cost - 0.0469) < 1e-9)
    }

    /// A cache write is carried through the parse and costs nothing on a row that publishes no write rate, which
    /// is every row before GPT-5.6.
    @Test func aCacheWriteIsCarriedAndCostsNothingBeforeGPT56() {
        let jsonl = [turnContext(model: "gpt-5.3-codex"), record("resp_a", input: 1000, cached: 0, output: 0, write: 50_000)].joined(separator: "\n")
        let result = priced(jsonl)
        #expect(result.entries.first?.tokens.cacheWrite5m == 50_000)
        #expect(abs(result.cost - 0.00175) < 1e-9)
    }

    /// From GPT-5.6 the same write is billed, at the rate that row publishes.
    @Test func aCacheWriteIsBilledFromGPT56() {
        let jsonl = [turnContext(model: "gpt-5.6-luna"), record("resp_a", input: 1000, cached: 0, output: 0, write: 50_000)].joined(separator: "\n")
        // 1,000 x $0.20 + 50,000 x $0.25, per million.
        #expect(abs(priced(jsonl).cost - 0.0127) < 1e-9)
    }

    /// Every published cache-write rate is 1.25x that row's uncached input rate, and no earlier row charges for a
    /// write at all. A new row that breaks either half is a rate this build would apply without a source.
    @Test func cacheWritesAreBilledOnlyFromGPT56AndAt125xInput() {
        for (id, rates) in OpenAIPricing.table {
            if id.hasPrefix("gpt-5.6") {
                #expect(abs(rates.cacheWrite - rates.input * 1.25) < 1e-9, "\(id)")
            } else {
                #expect(rates.cacheWrite == 0, "\(id)")
            }
        }
    }

    /// The long-context tier is 2x on every input bucket and 1.5x on output. These are the published long-context
    /// rows; the multipliers the code applies have to reproduce each of them exactly.
    @Test func theLongContextTierMatchesThePublishedRows() {
        let published: [(id: String, input: Double, cached: Double, write: Double, output: Double)] = [
            ("gpt-5.6-sol", 8, 0.8, 10, 30),
            ("gpt-5.6-terra", 4, 0.4, 5, 18),
            ("gpt-5.6-luna", 0.4, 0.04, 0.5, 1.8),
            ("gpt-5.5", 10, 1, 0, 45),
            ("gpt-5.5-pro", 60, 60, 0, 270),
            ("gpt-5.4", 5, 0.5, 0, 22.5),
            ("gpt-5.4-pro", 60, 60, 0, 270),
        ]
        for row in published {
            let rates = try! #require(OpenAIPricing.rates(for: row.id))
            #expect(rates.longContextThreshold == 272_000, "\(row.id)")
            #expect(abs(rates.input * OpenAIRates.longInputMultiplier - row.input) < 1e-9, "\(row.id)")
            #expect(abs(rates.cachedInput * OpenAIRates.longInputMultiplier - row.cached) < 1e-9, "\(row.id)")
            #expect(abs(rates.cacheWrite * OpenAIRates.longInputMultiplier - row.write) < 1e-9, "\(row.id)")
            #expect(abs(rates.output * OpenAIRates.longOutputMultiplier - row.output) < 1e-9, "\(row.id)")
        }
        // gpt-5.6-cyber is the one id whose tier comes from its model page's rule rather than a long-context row
        // of its own, and no other row carries the tier at all, so none can pick up a surcharge nothing published
        // for it — gpt-5.5-cyber, whose page is gone and whose row leaves the long columns empty, least of all.
        let tiered = OpenAIPricing.table.filter { $0.value.longContextThreshold != nil }.keys.sorted()
        #expect(tiered == (published.map(\.id) + ["gpt-5.6-cyber"]).sorted())
        #expect(OpenAIPricing.rates(for: "gpt-5.5-cyber")?.longContextThreshold == nil)
    }

    /// A turn over the threshold is priced at the published long-context rates, and one at the threshold is not.
    @Test func aTurnOverTheThresholdIsPricedAtTheLongContextRates() {
        let long = [turnContext(model: "gpt-5.5"), record("resp_a", input: 300_000, cached: 100_000, output: 10_000)].joined(separator: "\n")
        // 200,000 x $10.00 + 100,000 x $1.00 + 10,000 x $45.00, per million.
        #expect(abs(priced(long).cost - 2.55) < 1e-9)
        let short = [turnContext(model: "gpt-5.5"), record("resp_a", input: 272_000, cached: 72_000, output: 10_000)].joined(separator: "\n")
        // 200,000 x $5.00 + 72,000 x $0.50 + 10,000 x $30.00, per million.
        #expect(abs(priced(short).cost - 1.336) < 1e-9)
    }

    /// Each Codex variant carries its own published row; a provider prefix and case are the only things normalised.
    @Test func codexVariantsCarryTheirOwnRow() {
        let jsonl = [turnContext(model: "gpt-5.1-codex"), record("resp_a", input: 2000, cached: 1000, output: 1000)].joined(separator: "\n")
        #expect(abs(priced(jsonl).cost - 0.011375) < 1e-9)
        #expect(OpenAIPricing.rates(for: "gpt-5-codex")?.output == 10)
        #expect(OpenAIPricing.rates(for: "openai/GPT-5.3-Codex")?.output == 14)
        #expect(OpenAIPricing.rates(for: "gpt-5.1-codex-mini")?.output == 2)
    }

    /// Ids resolve by exact row, with only a trailing date snapshot stripped. Nothing is matched by prefix: a
    /// family member absent from the table must price as unknown rather than collapse onto a sibling's row.
    @Test func unlistedIdsAreNamedRatherThanCollapsed() {
        #expect(OpenAIPricing.rates(for: "gpt-5-mini-2025-08-07")?.input == 0.25)
        #expect(OpenAIPricing.rates(for: "gpt-5-2025-08-07")?.input == 1.25)
        #expect(OpenAIPricing.rates(for: "gpt-5.2-pro")?.output == 168)
        #expect(OpenAIPricing.rates(for: "o3-mini")?.cachedInput == 0.55)
        #expect(OpenAIPricing.rates(for: "o3")?.cachedInput == 0.5)
        // A model with no published cached rate never prices a cached token below its input rate.
        #expect(OpenAIPricing.rates(for: "gpt-5-pro")?.cachedInput == 15)
        // The bug this replaced: an unlisted sibling used to collapse onto the first row sharing its prefix. The
        // ids that mattered were the ones inside a family the table does hold, which is what these are.
        #expect(OpenAIPricing.rates(for: "gpt-5-turbo") == nil)
        #expect(OpenAIPricing.rates(for: "gpt-5.9") == nil)
        #expect(OpenAIPricing.rates(for: "gpt-5.6-nova") == nil)
        #expect(OpenAIPricing.rates(for: "gpt-5.5-cyber-preview") == nil)
        #expect(OpenAIPricing.rates(for: "gpt-5.4-mini-high") == nil)
        // Published with a dash in every column, so there is no rate to apply to it.
        #expect(OpenAIPricing.rates(for: "gpt-5.4-cyber") == nil)
        // Order cannot shadow: every id in the table resolves to its own row, whatever order the rows were written.
        for (id, rates) in OpenAIPricing.table { #expect(OpenAIPricing.rates(for: id) == rates, "\(id)") }
    }

    /// The fingerprint keys the day-record cache, so an edited rate has to change it even on a day the snapshot
    /// date does not move.
    @Test func theFingerprintFollowsTheRowsAndNotOnlyTheDate() {
        #expect(OpenAIPricing.fingerprint.hasPrefix(OpenAIPricing.snapshotDate))
        let one = ["a": OpenAIRates(input: 1, output: 2)]
        #expect(OpenAIPricing.digest(of: one) == OpenAIPricing.digest(of: ["a": OpenAIRates(input: 1, output: 2)]))
        #expect(OpenAIPricing.digest(of: one) != OpenAIPricing.digest(of: ["a": OpenAIRates(input: 1.1, output: 2)]))
        #expect(OpenAIPricing.digest(of: one) != OpenAIPricing.digest(of: ["a": OpenAIRates(input: 1, output: 2, cacheWrite: 1)]))
        #expect(OpenAIPricing.digest(of: one) != OpenAIPricing.digest(of: ["a": OpenAIRates(input: 1, output: 2, longContext: 10)]))
        #expect(OpenAIPricing.digest(of: one) != OpenAIPricing.digest(of: ["b": OpenAIRates(input: 1, output: 2)]))
    }

    /// The id here is a real model inside a family the table holds, published with no price at all: the case that
    /// matters, because an id outside every family would take the one path that returned nil even under the old
    /// prefix lookup.
    @Test func anUnpricedModelCostsNothingAndIsNamed() {
        let jsonl = [turnContext(model: "gpt-5.4-cyber"), record("resp_a", input: 1_000_000, cached: 0, output: 100_000)].joined(separator: "\n")
        let result = priced(jsonl)
        #expect(result.cost == 0)
        #expect(result.unpriced == ["gpt-5.4-cyber"])
    }

    /// A rollout an older Codex wrote carries `token_count` events instead; `last_token_usage` is the turn that
    /// just finished, so the events add up to the session rather than double-counting the running total.
    @Test func legacyTokenCountEventsArePricedFromTheLastTurn() {
        let jsonl = [turnContext(model: "gpt-5.3-codex"),
                     tokenCount(input: 1000, cached: 0, output: 100, at: "2026-09-01T14:10:00.000Z"),
                     tokenCount(input: 3000, cached: 2000, output: 400, at: "2026-09-01T14:20:00.000Z")].joined(separator: "\n")
        let result = priced(jsonl)
        #expect(result.entries.count == 2)
        // $0.00315 + $0.0077.
        #expect(abs(result.cost - 0.01085) < 1e-9)
    }

    /// A build that writes both keeps the per-response records and ignores the events, which describe the same turns.
    @Test func recordsWinOverEventsInTheSameRollout() {
        let jsonl = [turnContext(model: "gpt-5.3-codex"),
                     tokenCount(input: 10_000, cached: 8000, output: 2000, at: "2026-09-01T14:29:00.000Z"),
                     record("resp_a", input: 10_000, cached: 8000, output: 2000)].joined(separator: "\n")
        let result = priced(jsonl)
        #expect(result.entries.count == 1)
        #expect(abs(result.cost - 0.0329) < 1e-9)
    }

    /// Resuming a thread replays the turns it inherited under the same response id, so the first of each wins.
    @Test func aReplayedResponseIdIsCountedOnce() {
        let jsonl = [turnContext(model: "gpt-5.3-codex"),
                     record("resp_a", input: 10_000, cached: 8000, output: 2000),
                     record("resp_a", input: 10_000, cached: 8000, output: 2000),
                     record("resp_b", input: 4000, cached: 0, output: 500)].joined(separator: "\n")
        let result = priced(jsonl)
        #expect(result.entries.count == 2)
        #expect(abs(result.cost - 0.0469) < 1e-9)
    }

    @Test func aTurnWithNoModelIsNotPricedAndIsNotGuessedAt() {
        let result = priced(record("resp_a", input: 10_000, cached: 0, output: 2000))
        #expect(result.entries.count == 1)
        #expect(result.entries.first?.model == nil)
        #expect(result.cost == 0)
        #expect(result.unpriced.isEmpty)
    }

    // MARK: - The scan

    func write(_ jsonl: String, into folder: URL) throws -> URL {
        let sessions = folder.appendingPathComponent("sessions/2026/09/01")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let file = sessions.appendingPathComponent("rollout-2026-09-01T14-00-00-s1.jsonl")
        try Data(jsonl.utf8).write(to: file)
        return file
    }

    @Test func theScanBuildsCodexItsOwnProviderCost() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-codex-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try write([turnContext(model: "gpt-5.3-codex"),
                       record("resp_a", input: 10_000, cached: 8000, output: 2000, reasoning: 1500),
                       record("resp_b", input: 4000, cached: 0, output: 500)].joined(separator: "\n"), into: home)
        let history = CostHistory(url: home.appendingPathComponent("daily.jsonl"), tool: .codex)
        let scanner = CodexCostScanner(root: home, history: history)
        let cost = try #require(await scanner.scan(now: now, weekStart: utc.startOfDay(for: now), calendar: utc))
        #expect(cost.tool == .codex)
        #expect(cost.source == .localSessions)
        #expect(cost.source.label == "local sessions")
        #expect(abs(cost.totals(.today).cost - 0.0469) < 1e-9)
        #expect(abs(cost.totals(.last30Days).cost - 0.0469) < 1e-9)
        #expect(cost.daily.count == 30)
        #expect(abs((cost.daily.last?.cost ?? 0) - 0.0469) < 1e-9)
        #expect(cost.totals(.today).models.map(\.name) == ["gpt-5.3-codex"])
        #expect(cost.totals(.today).projects.map(\.name) == ["notchmeter"])
        // The entries carry a time of day, so Codex reports an hour of its own.
        #expect(abs((cost.lastHour ?? 0) - 0.0469) < 1e-9)
        #expect(cost.problem == nil)
        // The day totals outlive the rollout, so the history keeps them.
        #expect(abs((history.load(calendar: utc)[utc.startOfDay(for: now)]?.cost ?? 0) - 0.0469) < 1e-9)
    }

    /// A session resumed for weeks keeps one rollout whose file is recent while most of its turns are older than
    /// the window. Those turns are outside every range, and their hours are outside the average active hour too,
    /// so a month-old burst cannot flatten the multiple a hot hour is measured against.
    @Test func turnsOlderThanTheWindowAreLeftOutOfTheAverageActiveHour() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-codex-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        // A $0.014 turn inside the window, and a $1.40 one 60 days back that a resumed rollout still carries.
        _ = try write([turnContext(model: "gpt-5.3-codex"),
                       record("resp_old", input: 400_000, cached: 0, output: 50_000, at: "2026-07-03T09:30:00.000Z"),
                       record("resp_new", input: 4000, cached: 0, output: 500, at: "2026-09-01T14:30:00.000Z")].joined(separator: "\n"), into: home)
        let scanner = CodexCostScanner(root: home, history: nil)
        let cost = try #require(await scanner.scan(now: now, weekStart: utc.startOfDay(for: now), calendar: utc))
        #expect(abs(cost.totals(.last30Days).cost - 0.014) < 1e-9)
        // One active hour in the window, so the average is that hour's own $0.014 — not $0.707, the mean of it
        // and a July hour the ranges above already exclude.
        #expect(abs((cost.typicalHourly ?? 0) - 0.014) < 1e-9)
    }

    /// No sessions on the Mac means no cost at all — not $0, which would read as "Codex cost you nothing".
    @Test func aMacWithNoCodexSessionsShowsNoCostAtAll() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-codex-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let scanner = CodexCostScanner(root: home, history: CostHistory(url: home.appendingPathComponent("daily.jsonl"), tool: .codex))
        #expect(await scanner.scan(now: now, weekStart: utc.startOfDay(for: now), calendar: utc) == nil)
    }

    /// A rollout whose turns never name a model cannot be priced at all. The tokens are real, so Codex is not
    /// hidden, but the figure stays at nothing and the card carries the reason instead of a confident $0.
    @Test func turnsWithNoModelAreReportedRatherThanPriced() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-codex-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try write(record("resp_a", input: 10_000, cached: 0, output: 2000), into: home)
        let scanner = CodexCostScanner(root: home, history: CostHistory(url: home.appendingPathComponent("daily.jsonl"), tool: .codex))
        let cost = try #require(await scanner.scan(now: now, weekStart: utc.startOfDay(for: now), calendar: utc))
        #expect(cost.totals(.today).cost == 0)
        #expect(cost.totals(.today).tokens.total == 12_000)
        #expect(cost.problem == "1 Codex turn(s) name no model and are not priced")
    }
}
