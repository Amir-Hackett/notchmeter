import Foundation
import SQLite3
import Testing
@testable import Notchmeter

/// One OpenCode turn for a test: tokens in OpenCode's own buckets are already split the way OpenCodeStore splits them.
private func turn(_ id: String = UUID().uuidString, session: String = "ses_1", at date: Date, provider: String = GoPlan.providerID,
                  model: String = "kimi-k3", input: Int = 0, output: Int = 0, read: Int = 0, write: Int = 0, cost: Double? = nil,
                  directory: String? = "/Users/x/proj") -> OpenCodeUsage {
    OpenCodeUsage(id: id, sessionID: session, timestamp: date, providerID: provider, modelID: model, directory: directory,
                  tokens: TokenBreakdown(input: input, cacheWrite5m: write, cacheRead: read, output: output),
                  contextTokens: input + read + write, recordedCost: cost)
}

private func utc(_ text: String) -> Date { DateParsing.iso8601(text)! }

/// The OpenCode Go page's own rows (opencode.ai/docs/go, read 2026-09-24), priced the way the page states them.
@Suite struct GoPlanPricing {
    @Test func aTurnIsPricedAtThePagesRowWithReasoningAtTheOutputRate() {
        // Kimi K3: $3.00 in, $15.00 out, $0.30 cached read per million.
        let kimi = GoPlan.model("kimi-k3")!
        let tokens = TokenBreakdown(input: 100_000, cacheRead: 1_000_000, output: 20_000)
        let expected = 0.3 + 0.3 + 0.3
        #expect(abs(kimi.rates.cost(tokens) - expected) < 1e-9)
        // A dash in the cached-write column is priced at nothing, as a dash is in OpenAI's table.
        #expect(kimi.rates.cacheWrite == nil)
        #expect(kimi.rates.cost(TokenBreakdown(cacheWrite5m: 1_000_000)) == 0)
        // MiniMax M2.7 publishes a write rate of $0.375.
        #expect(GoPlan.model("minimax-m2.7")!.rates.cost(TokenBreakdown(cacheWrite5m: 1_000_000)) == 0.375)
    }

    @Test func theLimitsAreThePagesMonthlyDollarsAndTheirTwoShares() {
        let limits: [String: Double?] = ["kimi-k3": 15, "glm-5.3": 15, "glm-5.2": 60, "qwen3.8-flash": 30, "qwen3.7-max": 30, "hy4-preview": 30,
                                         "deepseek-v4-flash": 30, "gpt-5.6-luna": 15, "space-bunny-free": nil]
        let now = utc("2026-10-01T12:00:00Z")
        for (id, limit) in limits {
            #expect(GoPlan.model(id)?.monthlyLimit(at: now) == limit, "\(id)")
        }
        for model in GoPlan.models.values where model.name != "Space Bunny Free" {
            let limit = model.monthlyLimitUSD
            #expect(limit == 15 || limit == 30 || limit == 60, "\(model.name) carries a limit the page does not print")
        }
        #expect(GoPlan.fiveHourShare == 0.2)
        #expect(GoPlan.weeklyShare == 0.5)
    }

    @Test func thePromotionalLimitHoldsUntilItsDayEndsInUTC() {
        let flash = GoPlan.model("deepseek-v4.1-flash")!
        #expect(flash.monthlyLimit(at: utc("2026-09-27T23:59:59Z")) == 60, "the page shows $15 struck through beside $60, ending Sep 27")
        #expect(flash.monthlyLimit(at: utc("2026-09-28T00:00:00Z")) == 15)
    }

    @Test func peakHoursAreTheWeekdayUTCSpansOnly() {
        // 2026-09-21 is a Monday, 2026-09-26 a Saturday.
        #expect(GoPlan.isPeak(utc("2026-09-21T01:00:00Z")))
        #expect(GoPlan.isPeak(utc("2026-09-21T03:59:00Z")))
        #expect(!GoPlan.isPeak(utc("2026-09-21T04:00:00Z")))
        #expect(!GoPlan.isPeak(utc("2026-09-21T05:30:00Z")))
        #expect(GoPlan.isPeak(utc("2026-09-25T09:59:00Z")))
        #expect(!GoPlan.isPeak(utc("2026-09-25T10:00:00Z")))
        #expect(!GoPlan.isPeak(utc("2026-09-26T02:00:00Z")), "weekends are off-peak all day")
        let pro = GoPlan.model("deepseek-v4-pro")!
        let tokens = TokenBreakdown(input: 1_000_000)
        #expect(pro.rates(contextTokens: 0, at: utc("2026-09-21T02:00:00Z")).cost(tokens) == 1.32)
        #expect(pro.rates(contextTokens: 0, at: utc("2026-09-26T02:00:00Z")).cost(tokens) == 0.66)
    }

    @Test func aLongContextTurnTakesTheUpperRowPastItsThreshold() {
        let qwen = GoPlan.model("qwen3.7-plus")!
        let date = utc("2026-09-26T12:00:00Z")
        #expect(qwen.rates(contextTokens: 256_000, at: date) == qwen.rates, "the page prints ≤ 256K for the lower row")
        #expect(qwen.rates(contextTokens: 256_001, at: date).input == 1.20)
        let grok = GoPlan.model("grok-4.7")!
        #expect(grok.rates(contextTokens: 200_001, at: date).output == 12)
    }

    @Test func anIdIsFoundWithItsProviderOrItsCapitals() {
        #expect(GoPlan.model("opencode-go/kimi-k3")?.name == "Kimi K3")
        #expect(GoPlan.model("GLM-5.2")?.name == "GLM-5.2")
        #expect(GoPlan.model("kimi-k4") == nil, "an id the page does not list is not priced as a neighbour")
        #expect(GoPlan.model(nil) == nil)
    }
}

/// Which figure an OpenCode turn is worth, and on what authority (OpenCodePricing's four rules).
@Suite struct OpenCodePricingRules {
    let date = utc("2026-09-26T12:00:00Z")

    @Test func goTurnsArePricedAtTheGoPageWhateverOpenCodeRecorded() {
        let priced = OpenCodePricing.price(turn(at: date, input: 100_000, output: 20_000, cost: 9.99))
        #expect(priced.basis == .goPlan)
        #expect(abs((priced.cost ?? 0) - 0.6) < 1e-9)
    }

    @Test func aGoModelThePageDoesNotListFallsToOpenCodesOwnFigure() {
        #expect(OpenCodePricing.price(turn(at: date, model: "kimi-k4", input: 10, cost: 0.12)) == .init(cost: 0.12, basis: .recorded))
        #expect(OpenCodePricing.price(turn(at: date, model: "kimi-k4", input: 10, cost: 0)) == .unpriced)
    }

    @Test func openCodesOwnCostWinsAboveZero() {
        let priced = OpenCodePricing.price(turn(at: date, provider: "openrouter", model: "some/model", input: 1000, cost: 0.03))
        #expect(priced == .init(cost: 0.03, basis: .recorded))
    }

    @Test func aZeroOnASubscriptionLoginIsPricedAtThePublishedListRate() throws {
        let anthropic = OpenCodePricing.price(turn(at: date, provider: "anthropic", model: "claude-sonnet-5", input: 1_000_000, cost: 0))
        #expect(anthropic.basis == .anthropicList)
        #expect(anthropic.cost == 2, "Sonnet 5 input is $2 per million in ModelPricing")
        // The table that priced it travels with the figure, so the Cost card's price line can name it for OpenCode's
        // lines as it does for Claude Code's; with no catalog applied that is this build's own table.
        #expect(anthropic.source == .builtIn(ModelPricing.snapshotDate))
        let openai = OpenCodePricing.price(turn(at: date, provider: "openai", model: "gpt-5.3-codex", input: 1_000_000, cost: 0))
        #expect(openai == .init(cost: 1.75, basis: .openAIList, source: .builtIn(OpenAIPricing.snapshotDate)))
    }

    @Test func zenRecordsItsOwnPriceEvenAtZero() {
        #expect(OpenCodePricing.price(turn(at: date, provider: "opencode", model: "free-model", input: 1000, cost: 0)) == .init(cost: 0, basis: .recorded))
    }

    @Test func anythingElseAtZeroIsUnpricedRatherThanFree() {
        #expect(OpenCodePricing.price(turn(at: date, provider: "ollama", model: "llama3", input: 1000, cost: 0)) == .unpriced)
        #expect(OpenCodePricing.price(turn(at: date, provider: "ollama", model: "llama3", input: 1000, cost: nil)) == .unpriced)
    }
}

/// OpenCode's message records read onto this app's buckets, and the turn a session's newest messages describe.
@Suite struct OpenCodeRecords {
    @Test func aV1AssistantMessageReadsItsTokensCostModelAndFolder() throws {
        let object: [String: Any] = [
            "id": "msg_1", "sessionID": "ses_1", "role": "assistant", "providerID": "opencode-go", "modelID": "kimi-k3",
            "time": ["created": 1_790_000_000_000.0, "completed": 1_790_000_060_000.0], "path": ["cwd": "/Users/x/proj", "root": "/Users/x/proj"],
            "cost": 0.5, "tokens": ["input": 1000, "output": 200, "reasoning": 50, "cache": ["read": 3000, "write": 400]],
        ]
        let usage = try #require(OpenCodeStore.usage(v1: object, id: nil, session: nil, directory: nil))
        #expect(usage.id == "msg_1")
        #expect(usage.sessionID == "ses_1")
        #expect(usage.timestamp == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(usage.tokens == TokenBreakdown(input: 1000, cacheWrite5m: 400, cacheRead: 3000, output: 250),
                "reasoning is added back to output, which OpenCode stores net of it")
        #expect(usage.contextTokens == 4400)
        #expect(usage.recordedCost == 0.5)
        #expect(usage.directory == "/Users/x/proj")
    }

    @Test func onlyAnAssistantMessageWithSomethingRecordedCounts() {
        let user: [String: Any] = ["id": "u", "sessionID": "s", "role": "user", "time": ["created": 1_790_000_000_000.0]]
        #expect(OpenCodeStore.usage(v1: user, id: nil, session: nil, directory: nil) == nil)
        let streaming: [String: Any] = ["id": "a", "sessionID": "s", "role": "assistant", "time": ["created": 1_790_000_000_000.0], "cost": 0,
                                        "tokens": ["input": 0, "output": 0, "reasoning": 0, "cache": ["read": 0, "write": 0]]]
        #expect(OpenCodeStore.usage(v1: streaming, id: nil, session: nil, directory: nil) == nil, "a turn still streaming has nothing to price yet")
        let noTime: [String: Any] = ["id": "a", "sessionID": "s", "role": "assistant", "cost": 1]
        #expect(OpenCodeStore.usage(v1: noTime, id: nil, session: nil, directory: nil) == nil)
    }

    @Test func aV2SessionMessageReadsItsModelReference() throws {
        let object: [String: Any] = [
            "id": "sm_1", "type": "assistant", "model": ["id": "glm-5.2", "providerID": "opencode-go"],
            "time": ["created": 1_790_000_000_000.0], "tokens": ["input": 10, "output": 5, "reasoning": 0, "cache": ["read": 0, "write": 0]],
        ]
        let usage = try #require(OpenCodeStore.usage(v2: object, id: nil, session: "ses_2", directory: "/tmp/p"))
        #expect(usage.modelID == "glm-5.2")
        #expect(usage.providerID == "opencode-go")
        #expect(usage.sessionID == "ses_2")
        #expect(usage.recordedCost == nil)
        #expect(OpenCodeStore.usage(v2: ["type": "user", "id": "x"], id: nil, session: "s", directory: nil) == nil)
    }

    @Test func aTimeIsMillisecondsOrAnISOString() {
        #expect(OpenCodeStore.date(1_790_000_000_000.0) == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(OpenCodeStore.date("2026-09-24T12:00:00Z") == utc("2026-09-24T12:00:00Z"))
        #expect(OpenCodeStore.date(nil) == nil)
    }

    @Test func theTurnFollowsTheNewestMessages() {
        let now = Date(timeIntervalSince1970: 1_790_000_600)
        let started = 1_790_000_000_000.0
        let user: [String: Any] = ["role": "user", "time": ["created": started]]
        func assistant(_ fields: [String: Any]) -> [String: Any] {
            var base: [String: Any] = ["role": "assistant", "time": ["created": started + 1000]]
            base.merge(fields) { _, new in new }
            return base
        }
        let since = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(OpenCodeStore.turn(newestFirst: [user], updated: now, now: now) == .working(since: since))
        #expect(OpenCodeStore.turn(newestFirst: [assistant([:]), user], updated: now, now: now) == .working(since: since), "an open answer is working")
        let toolCall = assistant(["time": ["created": started + 1000, "completed": started + 5000], "finish": "tool-calls"])
        #expect(OpenCodeStore.turn(newestFirst: [toolCall, user], updated: now, now: now) == .working(since: since),
                "an answer that closed on a tool call is a step, not the end of the turn")
        let done = assistant(["time": ["created": started + 1000, "completed": started + 9000], "finish": "stop"])
        #expect(OpenCodeStore.turn(newestFirst: [done, user], updated: now, now: now)
                == .idle(finishedAt: Date(timeIntervalSince1970: 1_790_000_009), turnStarted: since, failure: nil))
        let aborted = assistant(["error": ["name": "MessageAbortedError", "data": ["message": "x"]]])
        #expect(OpenCodeStore.turn(newestFirst: [aborted, user], updated: now, now: now)
                == .idle(finishedAt: now, turnStarted: since, failure: "aborted"))
        let limited = assistant(["error": ["name": "APIError", "data": ["statusCode": 429]]])
        if case .idle(_, _, let failure) = OpenCodeStore.turn(newestFirst: [limited], updated: now, now: now) {
            #expect(failure == "rate_limit")
        } else {
            Issue.record("a failed answer is not working")
        }
        let quiet = now.addingTimeInterval(OpenCodeStore.abandonedAfter)
        #expect(OpenCodeStore.turn(newestFirst: [user], updated: now, now: quiet) == .idle(finishedAt: nil, turnStarted: since, failure: nil),
                "a turn nothing has written to for half an hour was abandoned, and has no finish to claim")
        #expect(OpenCodeStore.turn(newestFirst: [], updated: now, now: now) == .idle(finishedAt: nil, turnStarted: nil, failure: nil))
        // Nine steps in, the window holds no user message at all; the prompt's own time, read on its own, still
        // sets the clock, and the finish still names it as the turn's start.
        let step = assistant(["time": ["created": started + 9000]])
        #expect(OpenCodeStore.turn(newestFirst: [step], prompted: since, updated: now, now: now) == .working(since: since))
        let last = assistant(["time": ["created": started + 9000, "completed": started + 9500], "finish": "stop"])
        #expect(OpenCodeStore.turn(newestFirst: [last], prompted: since, updated: now, now: now)
                == .idle(finishedAt: Date(timeIntervalSince1970: 1_790_000_009.5), turnStarted: since, failure: nil))
    }

    @Test func openCodesPlaceholderTitlesAreNotTitles() {
        #expect(OpenCodeStore.isPlaceholderTitle("New session - 2026-09-24T12:00:00.000Z"))
        #expect(OpenCodeStore.isPlaceholderTitle("Child session - 2026-09-24T12:00:00.000Z"))
        #expect(!OpenCodeStore.isPlaceholderTitle("Paginate the audit log"))
    }

    @Test func thePathsFollowXDGAndTheDatabaseOverride() throws {
        let home = URL(fileURLWithPath: "/Users/x")
        #expect(OpenCodePaths.dataDirectory(environment: [:], home: home).path == "/Users/x/.local/share/opencode")
        #expect(OpenCodePaths.dataDirectory(environment: ["XDG_DATA_HOME": "/data"], home: home).path == "/data/opencode")
        #expect(OpenCodePaths.dataDirectory(environment: ["XDG_DATA_HOME": "relative"], home: home).path == "/Users/x/.local/share/opencode",
                "a relative XDG path is not one the specification allows")
        #expect(OpenCodePaths.configDirectory(environment: [:], home: home).path == "/Users/x/.config/opencode")
        #expect(OpenCodePlugin.fileURL(environment: ["XDG_CONFIG_HOME": "/cfg"], home: home).path == "/cfg/opencode/plugins/notchmeter.js")
        #expect(HookVendor.opencode.fileURL(environment: [:], home: home).path == "/Users/x/.config/opencode/plugins/notchmeter.js")
    }
}

/// OpenCode's database read for real: a scratch folder with the tables OpenCode's migrations create, opened the way
/// the app opens it.
@Suite struct OpenCodeDatabase {
    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-opencode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The v1.2 tables (`session`, `message`), the v2 projection (`session_message`), and a credential table holding
    /// a secret that nothing may ever read.
    static func database(at url: URL, _ inserts: String) throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
        CREATE TABLE session (id text PRIMARY KEY, project_id text NOT NULL, parent_id text, slug text NOT NULL, directory text NOT NULL,
            title text NOT NULL, version text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, time_archived integer);
        CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
        CREATE TABLE session_message (id text PRIMARY KEY, session_id text NOT NULL, type text NOT NULL, seq integer NOT NULL,
            time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
        CREATE TABLE credential (id text PRIMARY KEY, label text NOT NULL, value text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL);
        INSERT INTO credential VALUES ('c', 'key', 'sk-secret', 0, 0);
        """
        #expect(sqlite3_exec(db, schema + inserts, nil, nil, nil) == SQLITE_OK)
    }

    static func assistant(_ id: String, session: String, at millis: Int64, model: String = "kimi-k3", cost: Double = 0, input: Int = 1000,
                          completed: Bool = true, finish: String = "stop") -> String {
        let completedField = completed ? #","completed":\#(millis + 1000)"# : ""
        let data = #"{"id":"\#(id)","sessionID":"\#(session)","role":"assistant","providerID":"opencode-go","modelID":"\#(model)","time":{"created":\#(millis)\#(completedField)},"path":{"cwd":"/Users/x/proj","root":"/Users/x/proj"},"cost":\#(cost),"finish":"\#(finish)","tokens":{"input":\#(input),"output":100,"reasoning":0,"cache":{"read":0,"write":0}}}"#
        return "INSERT INTO message VALUES ('\(id)', '\(session)', \(millis), \(millis), '\(data)');\n"
    }

    static func user(_ id: String, session: String, at millis: Int64) -> String {
        let data = #"{"id":"\#(id)","sessionID":"\#(session)","role":"user","time":{"created":\#(millis)}}"#
        return "INSERT INTO message VALUES ('\(id)', '\(session)', \(millis), \(millis), '\(data)');\n"
    }

    static func session(_ id: String, directory: String = "/Users/x/proj", title: String = "t", at millis: Int64) -> String {
        "INSERT INTO session VALUES ('\(id)', 'p', NULL, 's', '\(directory)', '\(title)', 'v', \(millis), \(millis), NULL);\n"
    }

    @Test func turnsAreReadFromEveryDatabaseOnceAndTheFileIsLeftAsItWas() throws {
        let data = try Self.folder()
        defer { try? FileManager.default.removeItem(at: data) }
        let now = Date()
        let millis = Int64(now.timeIntervalSince1970 * 1000) - 60_000
        let old = millis - Int64(40 * Period.day * 1000)
        let main = data.appendingPathComponent("opencode.db")
        try Self.database(at: main, Self.assistant("msg_a", session: "ses_1", at: millis) + Self.assistant("msg_old", session: "ses_1", at: old)
                          + #"INSERT INTO session_message VALUES ('sm_1', 'ses_1', 'assistant', 1, \#(millis), \#(millis), '{"type":"assistant","model":{"id":"glm-5.2","providerID":"opencode-go"},"time":{"created":\#(millis)},"tokens":{"input":5,"output":5,"reasoning":0,"cache":{"read":0,"write":0}}}');"#
                          + #"INSERT INTO session_message VALUES ('sm_2', 'ses_2', 'assistant', 1, \#(millis), \#(millis), '{"type":"assistant","model":{"id":"glm-5.2","providerID":"opencode-go"},"time":{"created":\#(millis)},"tokens":{"input":7,"output":5,"reasoning":0,"cache":{"read":0,"write":0}}}');"#
                          + "INSERT INTO session VALUES ('ses_2', 'p', NULL, 's', '/Users/x/other', 't', 'v', 0, \(millis), NULL);")
        // A channel database a switch left behind, holding the same message again and one of its own.
        try Self.database(at: data.appendingPathComponent("opencode-dev.db"), Self.assistant("msg_a", session: "ses_1", at: millis)
                          + Self.assistant("msg_dev", session: "ses_3", at: millis))
        let before = try Data(contentsOf: main)
        let read = OpenCodeStore.usage(data: data, environment: [:], since: now.addingTimeInterval(-31 * Period.day))
        #expect(read.problem == nil)
        #expect(Set(read.usage.map(\.id)) == ["msg_a", "sm_2", "msg_dev"],
                "msg_a once across both files, the 40-day-old turn left out, and ses_1's v2 row skipped because its v1 rows are read")
        #expect(read.usage.first { $0.id == "sm_2" }?.directory == "/Users/x/other", "a v2 turn takes its folder from its session")
        #expect(try Data(contentsOf: main) == before)
        for suffix in ["-wal", "-shm", "-journal"] {
            #expect(!FileManager.default.fileExists(atPath: main.path + suffix), "a read of a database OpenCode is not running on creates no \(suffix)")
        }
        // OPENCODE_DB names one database, absolute or relative to the data folder.
        #expect(OpenCodePaths.databases(in: data, environment: ["OPENCODE_DB": "opencode-dev.db"]).map(\.lastPathComponent) == ["opencode-dev.db"])
        #expect(OpenCodePaths.databases(in: data, environment: [:]).map(\.lastPathComponent) == ["opencode.db", "opencode-dev.db"])
    }

    /// OpenCode running: its database in WAL mode, a turn committed to the log and not yet checkpointed, and OpenCode's
    /// own connection still open. The read-only connection shares the log like any reader and sees the turn.
    @Test func aLiveDatabaseIsReadThroughItsWriteAheadLog() throws {
        let data = try Self.folder()
        defer { try? FileManager.default.removeItem(at: data) }
        let url = data.appendingPathComponent("opencode.db")
        try Self.database(at: url, "")
        var writer: OpaquePointer?
        #expect(sqlite3_open(url.path, &writer) == SQLITE_OK)
        defer { sqlite3_close(writer) }
        #expect(sqlite3_exec(writer, "PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0;", nil, nil, nil) == SQLITE_OK)
        let millis = Int64(Date().timeIntervalSince1970 * 1000) - 5000
        #expect(sqlite3_exec(writer, Self.assistant("msg_live", session: "ses_live", at: millis), nil, nil, nil) == SQLITE_OK)
        #expect(FileManager.default.fileExists(atPath: url.path + "-wal"), "the turn is in the log, not yet in the file")
        let read = OpenCodeStore.usage(data: data, environment: [:], since: Date().addingTimeInterval(-Period.day))
        #expect(read.problem == nil)
        #expect(read.usage.map(\.id) == ["msg_live"])
    }

    @Test func legacyMessageFilesAreReadWhenNoDatabaseHasThem() throws {
        let data = try Self.folder()
        defer { try? FileManager.default.removeItem(at: data) }
        let session = OpenCodePaths.legacyMessages(in: data).appendingPathComponent("ses_legacy")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let millis = Int64(Date().timeIntervalSince1970 * 1000)
        let json = #"{"id":"msg_l","sessionID":"ses_legacy","role":"assistant","providerID":"anthropic","modelID":"claude-sonnet-5","time":{"created":\#(millis)},"cost":0.02,"tokens":{"input":10,"output":10,"reasoning":0,"cache":{"read":0,"write":0}}}"#
        try Data(json.utf8).write(to: session.appendingPathComponent("msg_l.json"))
        let read = OpenCodeStore.usage(data: data, environment: [:], since: Date().addingTimeInterval(-Period.day))
        #expect(read.usage.map(\.id) == ["msg_l"])
        #expect(read.usage.first?.recordedCost == 0.02)
    }

    @Test func sessionsAreReadWithTheirTurnAndTitlesOnlyWhenAllowed() throws {
        let data = try Self.folder()
        defer { try? FileManager.default.removeItem(at: data) }
        let now = Date()
        let millis = Int64(now.timeIntervalSince1970 * 1000) - 30_000
        let user = #"{"id":"u1","sessionID":"ses_w","role":"user","time":{"created":\#(millis)}}"#
        try Self.database(at: data.appendingPathComponent("opencode.db"), """
        INSERT INTO session VALUES ('ses_w', 'p', NULL, 's', '/Users/x/proj', 'Fix the login', 'v', \(millis), \(millis), NULL);
        INSERT INTO session VALUES ('ses_d', 'p', NULL, 's', '/Users/x/proj', 'New session - 2026-09-24T00:00:00.000Z', 'v', \(millis), \(millis), NULL);
        INSERT INTO session VALUES ('ses_c', 'p', 'ses_w', 's', '/Users/x/proj', 'Child', 'v', \(millis), \(millis), NULL);
        INSERT INTO session VALUES ('ses_x', 'p', NULL, 's', '/Users/x/proj', 'Gone', 'v', \(millis), \(millis), \(millis));
        INSERT INTO message VALUES ('u1', 'ses_w', \(millis), \(millis), '\(user)');
        """ + Self.assistant("a1", session: "ses_d", at: millis))
        let read = OpenCodeStore.sessions(data: data, environment: [:], since: now.addingTimeInterval(-Period.day), titles: true, now: now)
        let byID = Dictionary(uniqueKeysWithValues: read.sessions.map { ($0.id, $0) })
        #expect(byID["ses_w"]?.turn == .working(since: Date(timeIntervalSince1970: Double(millis) / 1000)))
        #expect(byID["ses_w"]?.title == "Fix the login")
        #expect(byID["ses_d"]?.title == nil, "OpenCode's placeholder is not a title")
        if case .idle(let finished?, _, nil) = byID["ses_d"]?.turn {
            #expect(abs(finished.timeIntervalSince1970 - Double(millis + 1000) / 1000) < 0.001)
        } else {
            Issue.record("a finished answer reads as idle with its finish")
        }
        #expect(byID["ses_c"]?.parentID == "ses_w")
        #expect(byID["ses_x"]?.archived == true)
        let untitled = OpenCodeStore.sessions(data: data, environment: [:], since: now.addingTimeInterval(-Period.day), titles: false, now: now)
        #expect(untitled.sessions.allSatisfy { $0.title == nil }, "with titles off the column is never read")
    }

    /// OpenCode bumps a session row's own time only at the prompt, so a turn that has run longer than the read
    /// window is inside it by its messages: the row is 40 minutes old, its newest step a minute, and the session is
    /// still working from its prompt, on this read and the next, with no turn's end invented between them.
    @Test func aTurnLongerThanTheWindowIsFollowedByItsMessages() throws {
        let data = try Self.folder()
        defer { try? FileManager.default.removeItem(at: data) }
        let now = Date()
        let prompted = Int64(now.timeIntervalSince1970 * 1000) - 40 * 60_000
        let step = Int64(now.timeIntervalSince1970 * 1000) - 60_000
        try Self.database(at: data.appendingPathComponent("opencode.db"),
                          Self.session("ses_long", at: prompted) + Self.user("u1", session: "ses_long", at: prompted)
                          + Self.assistant("a1", session: "ses_long", at: prompted + 1000, finish: "tool-calls")
                          + Self.assistant("a2", session: "ses_long", at: step, completed: false))
        let since = now.addingTimeInterval(-OpenCodeSessions.lookBack)
        let first = OpenCodeStore.sessions(data: data, environment: [:], since: since, titles: false, now: now)
        #expect(first.problem == nil)
        #expect(first.sessions.map(\.id) == ["ses_long"])
        #expect(first.sessions.first?.turn == .working(since: Date(timeIntervalSince1970: Double(prompted) / 1000)))
        let seen = OpenCodeSessions.events(previous: nil, current: first.sessions, now: now).seen
        let again = OpenCodeStore.sessions(data: data, environment: [:], since: since, titles: false, now: now.addingTimeInterval(5))
        let events = OpenCodeSessions.events(previous: seen, current: again.sessions, now: now.addingTimeInterval(5)).events
        #expect(events.isEmpty, "a turn still running is not ended because its row is old")
        // The same session in the event-sourced store alone: session_message rows carry the window too.
        let v2 = try Self.folder()
        defer { try? FileManager.default.removeItem(at: v2) }
        try Self.database(at: v2.appendingPathComponent("opencode.db"), Self.session("ses_v2", at: prompted)
                          + #"INSERT INTO session_message VALUES ('m1', 'ses_v2', 'user', 1, \#(prompted), \#(prompted), '{"id":"m1","type":"user","time":{"created":\#(prompted)}}');"#
                          + #"INSERT INTO session_message VALUES ('m2', 'ses_v2', 'assistant', 2, \#(step), \#(step), '{"id":"m2","type":"assistant","time":{"created":\#(step)}}');"#)
        let event = OpenCodeStore.sessions(data: v2, environment: [:], since: since, titles: false, now: now)
        #expect(event.sessions.first?.turn == .working(since: Date(timeIntervalSince1970: Double(prompted) / 1000)))
    }

    /// OpenCode writes one assistant message per step of a turn, so a turn of more than eight steps has no user
    /// message among the newest eight: the prompt is read on its own, and each new step is a step, not a prompt.
    @Test func aLongTurnsStepsAreNotNewPrompts() throws {
        let data = try Self.folder()
        defer { try? FileManager.default.removeItem(at: data) }
        let now = Date()
        let prompted = Int64(now.timeIntervalSince1970 * 1000) - 10 * 60_000
        var inserts = Self.session("ses_steps", at: prompted) + Self.user("u1", session: "ses_steps", at: prompted)
        for step in 1...9 { inserts += Self.assistant("a\(step)", session: "ses_steps", at: prompted + Int64(step) * 30_000, finish: "tool-calls") }
        inserts += Self.assistant("a10", session: "ses_steps", at: prompted + 300_000, completed: false)
        let url = data.appendingPathComponent("opencode.db")
        try Self.database(at: url, inserts)
        let since = now.addingTimeInterval(-OpenCodeSessions.lookBack)
        let start = Date(timeIntervalSince1970: Double(prompted) / 1000)
        let first = OpenCodeStore.sessions(data: data, environment: [:], since: since, titles: false, now: now)
        #expect(first.sessions.first?.turn == .working(since: start), "nine steps in, the clock is still the prompt's")
        let seen = OpenCodeSessions.events(previous: nil, current: first.sessions, now: now).seen
        // The tenth step closes on a tool call and an eleventh opens.
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let more = "UPDATE message SET data = replace(data, '\"created\":\(prompted + 300_000)}', '\"created\":\(prompted + 300_000),\"completed\":\(prompted + 301_000)}') WHERE id = 'a10';\n"
            + Self.assistant("a11", session: "ses_steps", at: prompted + 330_000, completed: false)
        #expect(sqlite3_exec(db, more, nil, nil, nil) == SQLITE_OK)
        let again = OpenCodeStore.sessions(data: data, environment: [:], since: since, titles: false, now: now.addingTimeInterval(5))
        #expect(again.sessions.first?.turn == .working(since: start))
        let events = OpenCodeSessions.events(previous: seen, current: again.sessions, now: now.addingTimeInterval(5)).events
        #expect(events.isEmpty, "a new step of the same turn is no prompt")
        // A second prompt does move the clock, once.
        let second = prompted + 400_000
        #expect(sqlite3_exec(db, Self.user("u2", session: "ses_steps", at: second), nil, nil, nil) == SQLITE_OK)
        let third = OpenCodeStore.sessions(data: data, environment: [:], since: since, titles: false, now: now.addingTimeInterval(10))
        #expect(third.sessions.first?.turn == .working(since: Date(timeIntervalSince1970: Double(second) / 1000)))
        let prompts = OpenCodeSessions.events(previous: OpenCodeSessions.events(previous: seen, current: again.sessions, now: now).seen,
                                              current: third.sessions, now: now.addingTimeInterval(10)).events
        #expect(prompts.map(\.message.event) == ["UserPromptSubmit"])
    }

    @Test func anUnreadableDatabaseIsAProblemNotACrash() throws {
        let data = try Self.folder()
        defer { try? FileManager.default.removeItem(at: data) }
        try Data("not a database".utf8).write(to: data.appendingPathComponent("opencode.db"))
        let read = OpenCodeStore.usage(data: data, environment: [:], since: Date().addingTimeInterval(-Period.day))
        #expect(read.usage.isEmpty)
        #expect(read.problem == "OpenCode's database opencode.db could not be read", "sqlite3_open_v2 reads no header, so the first query is where this is found")
        let sessions = OpenCodeStore.sessions(data: data, environment: [:], since: Date().addingTimeInterval(-Period.day), titles: false)
        #expect(sessions.sessions.isEmpty)
        #expect(sessions.problem != nil)
    }
}

/// OpenCode Go's three limits worked out from this Mac's turns (GoMeter).
@Suite struct GoMeterWindows {
    let now = utc("2026-09-30T12:00:00Z")

    /// Kimi K3 turns of $0.54 each (80K in, 20K out): three in the last five hours, nine more over the week.
    func kimi() -> [OpenCodeUsage] {
        var turns: [OpenCodeUsage] = []
        for hours in [0.5, 1.5, 3.0] { turns.append(turn(at: now.addingTimeInterval(-hours * 3600), input: 80_000, output: 20_000)) }
        for day in 1...3 {
            for slot in 0..<3 { turns.append(turn(at: now.addingTimeInterval(-Double(day) * 86_400 - Double(slot) * 3600), input: 80_000, output: 20_000)) }
        }
        return turns
    }

    @Test func eachWindowIsTheSpendAgainstItsShareOfTheMonthlyLimit() throws {
        let reading = try #require(GoMeter.reading(kimi(), now: now))
        #expect(reading.tool == .opencode)
        #expect(reading.plan == "Go")
        let five = try #require(reading.windows.first { $0.id == "go_5h" })
        let fiveExpected = 1.62 / 3
        #expect(abs((five.usedFraction ?? 0) - fiveExpected) < 1e-9, "$1.62 of Kimi K3's $3 five-hour share (20 % of $15)")
        #expect(five.source == .computedLocally)
        #expect(five.resetsAt == nil, "the page gives no anchor, so no reset is claimed")
        #expect(five.periodDuration == Period.fiveHours)
        #expect(abs((five.amountUSD ?? 0) - 1.62) < 1e-9)
        #expect(five.label == "5-hour")
        let weekly = try #require(reading.windows.first { $0.id == "go_weekly" })
        let weeklyExpected = 6.48 / 7.5
        #expect(abs((weekly.usedFraction ?? 0) - weeklyExpected) < 1e-9, "twelve turns against half of $15")
        #expect(weekly.label == "7-day", "a trailing window is named by its length, not as the calendar unit it is not")
        let monthly = try #require(reading.windows.first { $0.id == "go_monthly" })
        #expect(abs((monthly.usedFraction ?? 0) - 6.48 / 15) < 1e-9)
        #expect(monthly.label == "31-day")
        #expect(!reading.windows.contains { $0.hiddenByDefault }, "one model needs no per-model windows")
    }

    @Test func theTightestModelLeadsAndEveryModelHasAHiddenWindow() throws {
        let glm = (0..<5).map { turn(at: now.addingTimeInterval(-Double($0) * 600), model: "glm-5.2", input: 100_000, output: 10_000) }
        let reading = try #require(GoMeter.reading(kimi() + glm, now: now))
        let five = try #require(reading.windows.first { $0.id == "go_5h" })
        #expect(five.note?.hasPrefix("Kimi K3") == true, "Kimi K3 is at 54 % of its $3; GLM-5.2 at a few per cent of its $12")
        let scoped = reading.windows.filter { $0.hiddenByDefault }
        #expect(Set(scoped.map(\.id)) == ["go_5h:kimi-k3", "go_5h:glm-5.2", "go_weekly:kimi-k3", "go_weekly:glm-5.2", "go_monthly:kimi-k3", "go_monthly:glm-5.2"])
        #expect(scoped.allSatisfy { $0.source == .computedLocally && $0.model != nil })
    }

    @Test func aModelWithNoPublishedLimitShowsItsSpendAndNoBar() throws {
        let unknown = turn(at: now.addingTimeInterval(-600), model: "kimi-k4", input: 1000, cost: 0.4)
        let reading = try #require(GoMeter.reading([unknown], now: now))
        let five = try #require(reading.windows.first { $0.id == "go_5h" })
        #expect(five.usedFraction == nil, "no limit is invented for a model the page does not list")
        #expect(five.amountUSD == 0.4)
        #expect(five.note?.contains("kimi-k4") == true)
    }

    @Test func spendPastTheLimitKeepsItsPercentAndFillsTheBar() throws {
        let heavy = (0..<8).map { turn(at: now.addingTimeInterval(-Double($0) * 60), input: 80_000, output: 20_000) }
        let five = try #require(GoMeter.reading(heavy, now: now)?.windows.first { $0.id == "go_5h" })
        #expect(five.usedFraction == 1)
        let percent = 8 * 0.54 / 3 * 100
        #expect(abs((five.rawUsedPercent ?? 0) - percent) < 1e-6)
    }

    @Test func noGoTurnInTheMonthMeansNoReading() {
        #expect(GoMeter.reading([turn(at: now.addingTimeInterval(-32 * Period.day), input: 1000)], now: now) == nil)
        #expect(GoMeter.reading([turn(at: now, provider: "anthropic", model: "claude-sonnet-5", input: 1000)], now: now) == nil)
        #expect(GoMeter.reading([], now: now) == nil)
    }

    @Test func aWindowWithNothingInItReadsUntouched() throws {
        let yesterday = [turn(at: now.addingTimeInterval(-Period.day), input: 80_000, output: 20_000)]
        let five = try #require(GoMeter.reading(yesterday, now: now)?.windows.first { $0.id == "go_5h" })
        #expect(five.usedFraction == 0)
        #expect(five.note == nil)
    }
}

/// OpenCode on the Cost card: the digest the scanner folds into days, hours and the unpriced list.
@Suite struct OpenCodeCost {
    @Test func turnsFoldIntoDaysModelsProjectsAndTheHour() throws {
        let now = utc("2026-09-30T12:00:00Z")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let turns = [
            turn("a", at: now.addingTimeInterval(-600), input: 80_000, output: 20_000, directory: "/Users/x/api"),
            turn("b", at: now.addingTimeInterval(-2 * 3600), provider: "anthropic", model: "claude-sonnet-5", input: 1000, cost: 0.25, directory: "/Users/x/web"),
            turn("c", at: now.addingTimeInterval(-Period.day), provider: "ollama", model: "llama3", input: 1000, cost: 0),
        ]
        let digest = OpenCodeCostScanner.digest(turns, now: now, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        let record = try #require(digest.days[today])
        #expect(abs(record.cost - 0.79) < 1e-9)
        #expect(abs((record.byModel["kimi-k3"] ?? 0) - 0.54) < 1e-9)
        #expect(record.byProject["web"] == 0.25)
        #expect(abs(digest.lastHour - 0.54) < 1e-9, "only the Kimi turn is inside the last hour")
        #expect(digest.unpriced == ["llama3"], "a free local model at zero is named rather than shown as $0 spent")
        let cost = try #require(ProviderCost.build(tool: .opencode, source: .localMessages, days: digest.days, now: now,
                                                   weekStart: today, calendar: calendar, scannedAt: now))
        #expect(cost.source.isEstimate)
        #expect(cost.source.label == "local messages")
    }

    @Test func openCodeReportsCostAndTheScannerAnswersNothingWithoutItsFolder() async {
        #expect(ToolID.opencode.reportsCost)
        let missing = URL(fileURLWithPath: "/nonexistent/opencode-\(UUID().uuidString)")
        let scanner = OpenCodeCostScanner(reader: OpenCodeUsageReader(data: missing, environment: [:]), history: nil)
        let cost = await scanner.scan(now: Date(), weekStart: Date())
        #expect(cost == nil, "no OpenCode on the Mac is no row, never $0")
    }
}

/// OpenCode's sessions read from its database, turned into the events a hook would have sent (OpenCodeSessions).
@Suite struct OpenCodeSessionEvents {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func state(_ id: String, parent: String? = nil, turn: OpenCodeSessionState.Turn, archived: Bool = false, title: String? = nil) -> OpenCodeSessionState {
        OpenCodeSessionState(id: id, parentID: parent, directory: "/Users/x/proj", title: title, updated: now, archived: archived, turn: turn)
    }

    func names(_ events: [OpenCodeSessions.Event]) -> [String] { events.map(\.message.event) }

    @Test func theFirstReadShowsSessionsAsTheyStandWithoutAnnouncingOldFinishes() {
        let since = now.addingTimeInterval(-90)
        let read = OpenCodeSessions.events(previous: nil, current: [
            state("w", turn: .working(since: since)),
            state("i", turn: .idle(finishedAt: now.addingTimeInterval(-120), turnStarted: now.addingTimeInterval(-300), failure: nil)),
        ], now: now, branch: { _ in "main" })
        #expect(names(read.events) == ["SessionStart", "SessionStart", "UserPromptSubmit"])
        #expect(read.events.allSatisfy { $0.message.source == .localStorage && $0.message.tool == .opencode && $0.message.branch == "main" })
        #expect(read.events.last?.at == since, "the turn's clock is the prompt's, not the read's")
        #expect(!names(read.events).contains("Stop"), "a turn that ended before the app looked is not announced as just finished")
        #expect(read.seen.count == 2)
    }

    @Test func aTurnEndingBetweenReadsIsAStopAtItsOwnTime() {
        let since = now.addingTimeInterval(-300)
        let previous = OpenCodeSessions.events(previous: nil, current: [state("w", turn: .working(since: since))], now: now.addingTimeInterval(-10)).seen
        let finished = now.addingTimeInterval(-4)
        let read = OpenCodeSessions.events(previous: previous, current: [state("w", turn: .idle(finishedAt: finished, turnStarted: since, failure: nil))], now: now)
        #expect(names(read.events) == ["Stop"])
        #expect(read.events.first?.at == finished)
        let failed = OpenCodeSessions.events(previous: previous, current: [state("w", turn: .idle(finishedAt: finished, turnStarted: since, failure: "rate_limit"))], now: now)
        #expect(names(failed.events) == ["StopFailure"])
        #expect(failed.events.first?.message.hitRateLimit == true)
    }

    @Test func aWholeTurnBetweenTwoReadsIsReplayed() {
        let previous = OpenCodeSessions.events(previous: nil, current: [
            state("i", turn: .idle(finishedAt: now.addingTimeInterval(-600), turnStarted: nil, failure: nil)),
        ], now: now.addingTimeInterval(-5)).seen
        let read = OpenCodeSessions.events(previous: previous, current: [
            state("i", turn: .idle(finishedAt: now.addingTimeInterval(-1), turnStarted: now.addingTimeInterval(-4), failure: nil)),
        ], now: now)
        #expect(names(read.events) == ["UserPromptSubmit", "Stop"])
        let fresh = OpenCodeSessions.events(previous: [:], current: [
            state("n", turn: .idle(finishedAt: now.addingTimeInterval(-1), turnStarted: now.addingTimeInterval(-4), failure: nil)),
        ], now: now)
        #expect(names(fresh.events) == ["SessionStart", "UserPromptSubmit", "Stop"], "a session born and finished between reads still tells its finish")
    }

    @Test func aSubagentsSessionIsCountedOnItsParent() {
        let started = OpenCodeSessions.events(previous: [:], current: [
            state("p", turn: .working(since: now.addingTimeInterval(-60))),
            state("c", parent: "p", turn: .working(since: now.addingTimeInterval(-30))),
        ], now: now)
        let subagent = started.events.first { $0.message.event == "SubagentStart" }
        #expect(subagent?.message.sessionID == "p")
        #expect(subagent?.message.agentID == "c")
        let stopped = OpenCodeSessions.events(previous: started.seen, current: [
            state("p", turn: .working(since: now.addingTimeInterval(-60))),
            state("c", parent: "p", turn: .idle(finishedAt: now, turnStarted: nil, failure: nil)),
        ], now: now)
        #expect(names(stopped.events) == ["SubagentStop"])
    }

    @Test func anArchivedOrVanishedSessionEnds() {
        let seen = OpenCodeSessions.events(previous: nil, current: [state("a", turn: .working(since: now.addingTimeInterval(-60))),
                                                                    state("b", turn: .working(since: now.addingTimeInterval(-60)))], now: now).seen
        let read = OpenCodeSessions.events(previous: seen, current: [state("a", turn: .working(since: now.addingTimeInterval(-60)), archived: true)], now: now)
        #expect(Set(names(read.events)) == ["SessionEnd", "StopFailure"], "a archived ends; b gone while working ends its turn unseen")
    }

    @Test func replayedIntoTheTrackerTheyLightTheRingLikeAHook() {
        var tracker = SessionTracker()
        let since = now.addingTimeInterval(-300)
        let first = OpenCodeSessions.events(previous: nil, current: [state("w", turn: .working(since: since))], now: now.addingTimeInterval(-10))
        for event in first.events { tracker.apply(event.message, now: event.at) }
        let key = SessionTracker.key(tool: .opencode, session: "w", host: nil)
        #expect(tracker.sessions[key]?.isWorking == true)
        #expect(tracker.sessions[key]?.source == .localStorage)
        let second = OpenCodeSessions.events(previous: first.seen, current: [state("w", turn: .idle(finishedAt: now, turnStarted: since, failure: nil))], now: now)
        var finish: TimeInterval?
        for event in second.events { finish = tracker.apply(event.message, now: event.at).finished?.turn }
        #expect(finish == 300, "the turn's length is the database's own, prompt to answer")
        #expect(tracker.finish(of: .opencode, now: now) != nil)
        let hooked = Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "w", tool: .opencode)
        tracker.apply(hooked, now: now)
        #expect(tracker.sessions[key]?.source == .hook, "an event from the plugin makes the session a hooked one again")
    }

    @Test func titlesLandAsTheSessionsNameUnderItsKey() {
        let names = OpenCodeSessions.names([state("w", turn: .working(since: now), title: "Fix the login"), state("c", parent: "w", turn: .working(since: now), title: "Child")])
        #expect(names == ["opencode:w": "Fix the login"])
    }
}

/// A tool a later version adds is switched on once for an install that saved its lists before it existed. The
/// record of which tools an install has met is ToolMigration's (`knownTools`); OpenCode is met the same way as
/// the other rows 0.9.0 added, with nobody's settings to inherit.
@Suite struct ToolIntroductionTests {
    @Test func anInstallFromBeforeOpenCodeIsOfferedIt() {
        let suite = "NotchmeterTests.ToolIntroduction.offered"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["claude"], forKey: "enabledTools")
        let first = ToolMigration.migrate(defaults)
        #expect(first.added.contains(.opencode))
        #expect(first.inherited[.opencode] == nil)
        #expect(ToolMigration.migrate(defaults).added.isEmpty, "met once")
    }

    @MainActor @Test func itIsSwitchedOnOnceAndStaysOffWhenSwitchedOff() {
        let suite = "NotchmeterTests.ToolIntroduction"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["claude", "codex"], forKey: "enabledTools")
        defaults.set(["claude"], forKey: "costCardTools")
        let prefs = Preferences(defaults: defaults)
        // Kimi Code, also new to this install, comes on with it; Gemini CLI does not, since the Antigravity row it took
        // over from was off (ToolMigration), and it reports no cost.
        #expect(prefs.enabledTools == [.claude, .codex, .kimi, .opencode])
        #expect(prefs.costCardTools == [.claude, .opencode])
        #expect(defaults.stringArray(forKey: "enabledTools") == ["claude", "codex", "kimi", "opencode"])
        prefs.enabledTools.remove(.opencode)
        #expect(!Preferences(defaults: defaults).enabledTools.contains(.opencode), "once offered, a tool switched off stays off")
    }
}

/// The store's side: the database reading stands down once the plugin speaks, and the oracle names its events.
@Suite struct OpenCodeStoreBehaviour {
    @MainActor @Test func thePluginsFirstEventEndsTheDatabaseReading() {
        let suite = "NotchmeterTests.OpenCodeStore"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(prefs: Preferences(defaults: defaults), providers: [], cache: ReadingCache(defaults: defaults), defaults: defaults,
                               drainLog: nil, reportFile: nil)
        var read = Hook.Message(event: "SessionStart", needsInput: false, sessionID: "s", tool: .opencode)
        read.source = .localStorage
        store.hookReceived(read)
        #expect(!store.openCodePluginSpoke, "the app's own reading is not the plugin")
        store.hookReceived(Hook.Message(event: "SessionStart", needsInput: false, sessionID: "s", tool: .opencode))
        #expect(store.openCodePluginSpoke)
        #expect(!store.readsOpenCodeSessions)
    }

    @Test func theOracleSaysAnEventCameFromTheDatabase() {
        var message = Hook.Message(event: "Stop", needsInput: false, sessionID: "s", tool: .opencode)
        #expect(UsageStore.hookFacts(message)["source"] == nil)
        message.source = .localStorage
        #expect(UsageStore.hookFacts(message)["source"] as? String == "storage")
        #expect(Hook.Message(userInfo: message.userInfo)?.source == .hook, "the socket never carries a claim to be the app's own reading")
    }

    @Test func theComputedSourceSaysWhatItIs() {
        #expect(WindowSource.computedLocally.tag == "computed here")
        #expect(WindowSource.computedLocally.explanation?.contains("Computed on this Mac") == true)
        #expect(WindowSource.computedLocally.explanation?.contains("never lower") == true,
                "the one systematic difference from the vendor's figure is on the tag itself")
        #expect(WindowSource.vendorEndpoint.explanation == nil)
    }

    /// The Assistants pane's subtitle: a login for a reading taken over one, and for the Go meter, which reads
    /// none, where the figure came from.
    @Test func theAssistantsPaneNamesTheComputationRatherThanALogin() throws {
        Localization.use(language: "en")
        let now = Date()
        let go = try #require(GoMeter.reading([turn(at: now, input: 1000)], now: now))
        #expect(SettingsView.readySubtitle(go) == "Go · computed from this Mac's turns")
        let claude = UsageReading(tool: .claude, windows: [LimitWindow(id: "seven_day", label: "Weekly", usedFraction: 0.1, resetsAt: nil)],
                                  plan: "Max", fetchedAt: now, observedAt: nil)
        #expect(SettingsView.readySubtitle(claude) == "Signed in · Max")
        #expect(SettingsView.readySubtitle(UsageReading(tool: .claude, windows: [], plan: nil, fetchedAt: now, observedAt: nil)) == "Signed in")
    }

    /// Under rows read from the database the card offers the plugin, or says it takes over at the next start; once
    /// the plugin has spoken, neither, since the rows still marked *from database* are ones it will never report.
    @Test func thePluginOfferGoesOnceThePluginHasSpoken() {
        var tracker = SessionTracker()
        var read = Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "s", tool: .opencode)
        read.source = .localStorage
        tracker.apply(read, now: now)
        let rows = SessionsCard.rows(tracker.all, hideTitles: false, jump: false, now: now).rows
        #expect(rows.first?.fromStorage == true)
        #expect(SessionsCard.pluginOffer(rows: rows, installed: false, spoke: false) == .add)
        #expect(SessionsCard.pluginOffer(rows: rows, installed: true, spoke: false) == .nextStart)
        #expect(SessionsCard.pluginOffer(rows: rows, installed: true, spoke: true) == nil)
        tracker.apply(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "s", tool: .opencode), now: now)
        let hooked = SessionsCard.rows(tracker.all, hideTitles: false, jump: false, now: now).rows
        #expect(SessionsCard.pluginOffer(rows: hooked, installed: false, spoke: false) == nil, "no row from the database, nothing to offer")
    }

    let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// A store reading a real database: a read that fails changes nothing, and the plugin's first event ends the
    /// turns of the sessions the reading was following, bar the one the event is about.
    @MainActor @Test func aFailedReadChangesNothingAndThePluginsFirstEventEndsTheTurnsItWasFollowing() async throws {
        let suite = "NotchmeterTests.OpenCodeStoreReads"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = try OpenCodeDatabase.folder()
        defer { try? FileManager.default.removeItem(at: data) }
        let url = data.appendingPathComponent("opencode.db")
        let now = Date()
        let millis = Int64(now.timeIntervalSince1970 * 1000)
        try OpenCodeDatabase.database(at: url, OpenCodeDatabase.session("ses_a", at: millis - 120_000) + OpenCodeDatabase.user("ua", session: "ses_a", at: millis - 120_000)
                                      + OpenCodeDatabase.session("ses_b", directory: "/Users/x/other", at: millis - 90_000) + OpenCodeDatabase.user("ub", session: "ses_b", at: millis - 90_000))
        let store = UsageStore(prefs: Preferences(defaults: defaults), providers: [OpenCodeProvider(reader: OpenCodeUsageReader(data: data, environment: [:]))],
                               cache: ReadingCache(defaults: defaults), defaults: defaults, drainLog: nil, reportFile: nil)
        #expect(store.readsOpenCodeSessions)
        await store.readOpenCodeSessions(now: now)
        let a = SessionTracker.key(tool: .opencode, session: "ses_a", host: nil)
        let b = SessionTracker.key(tool: .opencode, session: "ses_b", host: nil)
        #expect(store.sessions.sessions[a]?.isWorking == true)
        #expect(store.sessions.sessions[b]?.isWorking == true)
        #expect(store.sessions.sessions[a]?.source == .localStorage)
        // The file turns into something that is no database (its fingerprint moves, so it is read): nothing changes.
        let good = try Data(contentsOf: url)
        try Data("not a database any more".utf8).write(to: url)
        await store.readOpenCodeSessions(now: now.addingTimeInterval(5))
        #expect(store.sessions.sessions[a]?.isWorking == true, "a read that failed is not a read of no sessions")
        #expect(store.sessions.sessions[b]?.isWorking == true)
        try good.write(to: url)
        // The plugin's first event, about ses_b: ses_a ends its turn unseen, ses_b is the plugin's from here on.
        store.hookReceived(Hook.Message(event: "Stop", needsInput: false, sessionID: "ses_b", tool: .opencode), now: now.addingTimeInterval(10))
        #expect(store.openCodePluginSpoke)
        #expect(!store.readsOpenCodeSessions)
        #expect(store.sessions.sessions[a]?.isWorking == false)
        #expect(store.sessions.sessions[a]?.finished == nil, "no finish is claimed for a turn nobody saw end")
        #expect(store.sessions.sessions[a]?.source == .localStorage)
        #expect(store.sessions.sessions[b]?.source == .hook)
        #expect(store.sessions.sessions[b]?.finished != nil, "the plugin's own Stop is a finish, with the turn's length from the prompt the database gave")
    }
}
