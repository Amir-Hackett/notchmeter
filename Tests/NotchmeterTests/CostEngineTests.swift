import Foundation
import Testing
@testable import Notchmeter

/// The engine that runs every tool's cost scanner. Each scanner reads its own source and answers with its own
/// ProviderCost, so one that is empty, stale or missing entirely cannot empty or delay another; the figures at
/// the top of the summary are the providers added up.
@Suite struct CostEngineScans {
    init() { Localization.use(language: "en") }

    let now = DateParsing.iso8601("2026-09-01T15:00:00Z")!

    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// One Sonnet 5 line: 1000 × $2 + 200 × $10 + 3000 × $2.50 + 2000 × $4 + 40000 × $0.20 per million = $0.0275.
    static let claudeLine = #"""
    {"type":"assistant","timestamp":"2026-09-01T13:30:00.000Z","requestId":"req_b","message":{"id":"msg_b","model":"claude-sonnet-5","usage":{"input_tokens":1000,"output_tokens":200,"cache_read_input_tokens":40000,"cache_creation":{"ephemeral_5m_input_tokens":3000,"ephemeral_1h_input_tokens":2000},"inference_geo":"global"}}}
    """#

    /// A scratch home with a Claude transcript, no Codex sessions, and a Cursor history file that may be empty.
    func makeEngine(cursorDays: [Date: CostHistory.Record] = [:]) throws -> (engine: CostEngine, home: URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-engine-\(UUID().uuidString)")
        let project = home.appendingPathComponent("claude/projects/-Users-someone-notchmeter")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data(Self.claudeLine.utf8).write(to: project.appendingPathComponent("session.jsonl"))
        let cursorHistory = CostHistory(url: home.appendingPathComponent("cursor.jsonl"), tool: .cursor)
        if !cursorDays.isEmpty { cursorHistory.record(cursorDays, existing: [:], calendar: utc) }
        let engine = CostEngine(
            claude: ClaudeCostScanner(roots: [home.appendingPathComponent("claude")], cacheURL: nil, history: nil),
            codex: CodexCostScanner(root: home.appendingPathComponent("no-codex-here"), history: nil),
            cursor: CursorCostReader(history: cursorHistory))
        return (engine, home)
    }

    @Test func aToolWithNothingToSayLeavesTheOthersAlone() async throws {
        let (engine, home) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: home) }
        let summary = await engine.scan(now: now, calendar: utc)
        // Codex has no sessions and Cursor no export: neither is a zero row, both are simply absent.
        #expect(summary.providers.map(\.tool) == [.claude])
        #expect(summary.provider(.codex) == nil)
        #expect(summary.provider(.cursor) == nil)
        #expect(abs(summary.today - 0.0275) < 1e-9)
        #expect(abs(summary.totals(.last30Days).cost - 0.0275) < 1e-9)
        #expect(summary.providers.first?.source == .localTranscripts)
    }

    @Test func theTopFiguresAreEveryProviderAddedUp() async throws {
        let day = utc.startOfDay(for: now)
        let yesterday = utc.date(byAdding: .day, value: -1, to: day)!
        let cursorDays = [day: CostHistory.Record(cost: 1.25, tokens: TokenBreakdown(input: 4000, output: 400), byModel: ["gpt-5.3-codex": 1.25], byProject: [:]),
                          yesterday: CostHistory.Record(cost: 0.5, tokens: TokenBreakdown(input: 1000), byModel: [:], byProject: [:])]
        let (engine, home) = try makeEngine(cursorDays: cursorDays)
        defer { try? FileManager.default.removeItem(at: home) }
        let summary = await engine.scan(reads: [.cursor: ProviderReadState(readAt: now.addingTimeInterval(-120))], now: now, calendar: utc)
        #expect(summary.providers.map(\.tool) == [.claude, .cursor])
        #expect(summary.providers.map(\.source) == [.localTranscripts, .billingExport])
        #expect(abs(summary.today - (0.0275 + 1.25)) < 1e-9)
        #expect(abs(summary.yesterday - 0.5) < 1e-9)
        #expect(abs(summary.last30Days - (0.0275 + 1.75)) < 1e-9)
        #expect(summary.daily.count == 30)
        #expect(abs((summary.daily.last?.cost ?? 0) - (0.0275 + 1.25)) < 1e-9)
        // Each tool keeps its own figures beside the total.
        #expect(abs((summary.provider(.claude)?.totals(.today).cost ?? 0) - 0.0275) < 1e-9)
        #expect(abs((summary.provider(.cursor)?.totals(.today).cost ?? 0) - 1.25) < 1e-9)
        #expect(summary.provider(.cursor)?.scannedAt == now.addingTimeInterval(-120))
        // The models of both tools rank together in the total.
        #expect(summary.totals(.last30Days).models.map(\.name) == ["gpt-5.3-codex", "claude-sonnet-5"])
    }

    /// A tool the user has turned off, or one that cannot report spend at all, is never scanned.
    @Test func onlyTheToolsAskedForAreScanned() async throws {
        let day = utc.startOfDay(for: now)
        let (engine, home) = try makeEngine(cursorDays: [day: CostHistory.Record(cost: 1.25, tokens: TokenBreakdown(), byModel: [:], byProject: [:])])
        defer { try? FileManager.default.removeItem(at: home) }
        let cursorOnly = await engine.scan(tools: [.cursor], now: now, calendar: utc)
        #expect(cursorOnly.providers.map(\.tool) == [.cursor])
        #expect(abs(cursorOnly.today - 1.25) < 1e-9)
        let none = await engine.scan(tools: [], now: now, calendar: utc)
        #expect(none.providers.isEmpty)
        #expect(none.today == 0)
        #expect(none.scannedAt == now)
    }

    /// The tools that publish no per-request price never reach the engine at all.
    @Test func onlyThreeToolsCanReportSpend() {
        #expect(ToolID.allCases.filter(\.reportsCost) == [.claude, .codex, .cursor])
        #expect(ToolID.copilot.reportsCost == false)
        #expect(ToolID.antigravity.reportsCost == false)
    }

    /// A tool whose vendor read failed keeps its last figures and carries the failure, rather than reading as fresh.
    @Test func aProviderCarriesItsOwnFreshnessAndProblem() async throws {
        let day = utc.startOfDay(for: now)
        let (engine, home) = try makeEngine(cursorDays: [day: CostHistory.Record(cost: 2, tokens: TokenBreakdown(), byModel: [:], byProject: [:])])
        defer { try? FileManager.default.removeItem(at: home) }
        let stale = ProviderReadState(readAt: now.addingTimeInterval(-3 * 86400), problem: "Cursor's login has expired")
        let summary = await engine.scan(reads: [.cursor: stale], now: now, calendar: utc)
        let cursor = try #require(summary.provider(.cursor))
        #expect(cursor.problem == "Cursor's login has expired")
        #expect(cursor.scannedAt == now.addingTimeInterval(-3 * 86400))
        #expect(abs(cursor.totals(.today).cost - 2) < 1e-9)
        // The Claude scan is untouched by it.
        #expect(summary.provider(.claude)?.problem == nil)
        #expect(abs((summary.provider(.claude)?.totals(.today).cost ?? 0) - 0.0275) < 1e-9)
    }
}
