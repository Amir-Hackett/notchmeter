import Foundation
import Testing
@testable import Notchmeter

/// The status-line payload: what is read, what is forwarded, what is printed, and how it is installed.
@Suite struct StatuslinePayload {
    init() { Localization.use(language: "en") }

    let now = DateParsing.iso8601("2026-09-01T12:00:00Z")!
    let payload = """
    {"hook_event_name":"Status","session_id":"abc123","transcript_path":"/Users/me/.claude/projects/x/abc.jsonl","cwd":"/Users/me/Developer/notchmeter",
     "model":{"id":"claude-opus-4-8","display_name":"Opus"},"workspace":{"current_dir":"/Users/me/Developer/notchmeter","project_dir":"/Users/me/Developer/notchmeter"},
     "version":"2.1.255","cost":{"total_cost_usd":1.2345,"total_duration_ms":45000},
     "context_window":{"total_input_tokens":15234,"total_output_tokens":4521,"context_window_size":200000,
       "current_usage":{"input_tokens":12000,"output_tokens":3000,"cache_creation_input_tokens":500,"cache_read_input_tokens":111500},"used_percentage":62.0},
     "rate_limits":{"five_hour":{"used_percentage":45.2,"resets_at":1788271200},"seven_day":{"used_percentage":12.8,"resets_at":1788771600}},
     "exceeds_200k_tokens":false}
    """

    @Test func readsContextRateLimitsCostAndTheFolderNameOnly() throws {
        let message = try #require(Statusline.message(from: Data(payload.utf8), now: now))
        #expect(message.sessionID == "abc123")
        #expect(message.project == "notchmeter")
        #expect(message.model == "Opus")
        #expect(message.contextUsed == 0.62)
        #expect(message.contextTokens == 124_000)
        #expect(message.contextSize == 200_000)
        #expect(message.sessionCost == 1.2345)
        #expect(message.windows.map(\.id) == ["five_hour", "seven_day"])
        #expect(message.windows[0].usedFraction == 0.452)
        #expect(message.windows[0].resetsAt == Date(timeIntervalSince1970: 1_788_271_200))
        #expect(message.windows[0].periodDuration == Period.fiveHours)
        #expect(message.windows[1].periodDuration == Period.week)
        #expect(message.windows[0].note == "From Claude Code's status line")
        let info = message.userInfo
        #expect(!info.keys.contains("transcript_path"))
        #expect(!info.keys.contains("cwd"))
        #expect(Statusline.Message(userInfo: info) == message)
        #expect(Statusline.line(message) == "Opus · ctx 62% · 5h 45% ↻2h · 7d 13% ↻5d · $1.23")
    }

    @Test func missingFieldsAreNilAndContextFallsBackToTokens() throws {
        let early = try #require(Statusline.message(from: Data(#"{"hook_event_name":"Status","context_window":{"context_window_size":200000,"current_usage":{"input_tokens":50000,"cache_read_input_tokens":50000}}}"#.utf8), now: now))
        #expect(early.contextUsed == 0.5)
        #expect(early.windows.isEmpty)
        #expect(early.sessionCost == nil)
        #expect(Statusline.line(early) == "ctx 50%")
        #expect(Statusline.message(from: Data("nope".utf8), now: now) == nil)
        let bare = try #require(Statusline.message(from: Data("{}".utf8), now: now))
        #expect(Statusline.line(bare) == "")
        #expect(Statusline.Message(userInfo: bare.userInfo)?.windows.isEmpty == true)
    }

    @Test func aFreshStatuslineReplacesTheEndpointWindowsAndPausesThePoll() {
        let reading = UsageReading(tool: .claude, windows: [
            LimitWindow(id: "five_hour", label: "Session", usedFraction: 0.1, resetsAt: now, periodDuration: Period.fiveHours),
            LimitWindow(id: "seven_day", label: "Weekly", usedFraction: 0.2, resetsAt: now, periodDuration: Period.week),
            LimitWindow(id: "scoped_fable", label: "Fable", usedFraction: 0.3, resetsAt: now, periodDuration: Period.week, model: "Fable"),
        ], plan: "Max 5x", fetchedAt: now, observedAt: nil)
        let fresh = [LimitWindow(id: "seven_day", label: "Weekly", usedFraction: 0.25, resetsAt: now, periodDuration: Period.week),
                     LimitWindow(id: "five_hour", label: "Session", usedFraction: 0.45, resetsAt: now, periodDuration: Period.fiveHours)]
        let merged = reading.replacing(windows: fresh, fetchedAt: now.addingTimeInterval(60))
        #expect(merged.windows.map(\.id) == ["five_hour", "seven_day", "scoped_fable"])
        #expect(merged.windows.map(\.usedFraction) == [0.45, 0.25, 0.3])
        #expect(merged.plan == "Max 5x")
        let empty = UsageReading(tool: .claude, windows: [], plan: nil, fetchedAt: now, observedAt: nil).replacing(windows: fresh, fetchedAt: now)
        #expect(empty.windows.map(\.id) == ["seven_day", "five_hour"])
        var inputs = PollingInputs(baseInterval: 300, minutesSinceLastAgentActivity: 1, secondsSinceStatusline: 30)
        #expect(PollingPolicy.decide(inputs) == .paused(.statusline))
        inputs.secondsSinceStatusline = PollingPolicy.statuslineFreshFor
        #expect(PollingPolicy.decide(inputs) == .after(300))
    }
}

@Suite struct StatuslineInstallation {
    init() { Localization.use(language: "en") }

    let executable = "/Applications/Notchmeter.app/Contents/MacOS/Notchmeter"

    @Test func statusAndRepairFollowThePathInTheCommand() throws {
        let installed = HookSettings.merge(into: [:], executable: executable).settings
        #expect(HookSettings.status(settings: installed, executable: executable) == .installed(path: executable))
        #expect(HookSettings.status(settings: installed, executable: "/Users/me/build/Notchmeter") == .stale(path: executable))
        #expect(HookSettings.status(settings: [:], executable: executable) == .notInstalled)
        #expect(HookSettings.status(settings: ["hooks": ["Stop": [["hooks": [["type": "command", "command": "/usr/local/bin/x"]]]]]], executable: executable) == .notInstalled)
        let repaired = HookSettings.repair(installed, executable: "/Applications/Notchmeter 2.app/Contents/MacOS/Notchmeter")
        #expect(repaired.repaired == HookSettings.events)
        #expect(repaired.added.isEmpty)
        #expect(HookSettings.status(settings: repaired.settings, executable: "/Applications/Notchmeter 2.app/Contents/MacOS/Notchmeter") == .installed(path: "/Applications/Notchmeter 2.app/Contents/MacOS/Notchmeter"))
        #expect(HookSettings.Status.installed(path: executable).text == "Installed · pointing at /Applications/Notchmeter.app")
        #expect(HookSettings.executable(in: "'/it'\\''s/here' --hook") == "/it's/here")
    }

    @Test func statuslineInstallChainsThePreviousCommandAndIsIdempotent() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("notchmeter-statusline-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        try Data(#"{"statusLine":{"type":"command","command":"~/bin/my-status.sh","padding":0},"model":"opus"}"#.utf8).write(to: url)
        let now = Date(timeIntervalSince1970: 1_788_300_000)
        let first = try HookSettings.installStatusline(at: url, executable: executable, now: now)
        #expect(first.previous == "~/bin/my-status.sh")
        #expect(first.backup != nil)
        let written = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let command = try #require((written["statusLine"] as? [String: Any])?["command"] as? String)
        #expect(command == "'\(executable)' --statusline --then '~/bin/my-status.sh'")
        #expect(written["model"] as? String == "opus")
        #expect(HookSettings.statuslineStatus(settings: written, executable: executable) == .installed(path: executable))
        #expect(HookSettings.previousCommand(in: command) == "~/bin/my-status.sh")
        let again = try HookSettings.installStatusline(at: url, executable: executable, now: now.addingTimeInterval(60))
        #expect(again.backup == nil)
        #expect(again.previous == "~/bin/my-status.sh")
        let moved = try HookSettings.installStatusline(at: url, executable: "/Users/me/Notchmeter", now: now.addingTimeInterval(120))
        #expect(moved.previous == "~/bin/my-status.sh")
        let rewritten = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(((rewritten["statusLine"] as? [String: Any])?["command"] as? String)?.hasPrefix("'/Users/me/Notchmeter' --statusline --then") == true)
        let fresh = dir.appendingPathComponent("fresh.json")
        let plain = try HookSettings.installStatusline(at: fresh, executable: executable, now: now)
        #expect(plain.previous == nil)
        #expect(HookSettings.statuslineSnippet(executable: executable).contains("\"statusLine\""))
    }
}


/// The spend-limit window, the effort level, the branch and pull request, the coloured line with the app's figures.
@Suite struct StatuslineRoundTwo {
    init() { Localization.use(language: "en") }

    let now = DateParsing.iso8601("2026-09-01T12:00:00Z")!

    @Test func readsTheSpendLimitAsAThirdWindowThatMayRunPast100() throws {
        let payload = """
        {"hook_event_name":"Status","session_id":"g1","model":{"display_name":"Opus"},"effort":{"level":"high"},
         "rate_limits":{"five_hour":{"used_percentage":45.2,"resets_at":1756728000},"seven_day":{"used_percentage":12.8,"resets_at":1757228400},
                        "spend_limit":{"used_percentage":130,"resets_at":1759276800}},
         "worktree":{"branch":"feat/hooks"},"pr":{"number":12,"url":"https://github.com/a/b/pull/12"}}
        """
        let message = try #require(Statusline.message(from: Data(payload.utf8), now: now))
        #expect(message.windows.map(\.id) == ["five_hour", "seven_day", "spend_limit"])
        let spend = message.windows[2]
        #expect(spend.label == "Spend limit")
        #expect(spend.usedFraction == 1)
        #expect(spend.rawUsedPercent == 130)
        #expect(spend.periodDuration == nil)
        #expect(spend.source == .statusline)
        #expect(spend.note == "From Claude Code's status line · over by 30%")
        #expect(message.windows[0].source == .statusline)
        #expect(message.windows[0].rawUsedPercent == nil)
        #expect(message.effort == "high")
        #expect(message.branch == "feat/hooks")
        #expect(message.prURL == "https://github.com/a/b/pull/12")
        let round = try #require(Statusline.Message(userInfo: message.userInfo))
        #expect(round == message)
        #expect(round.windows[2].rawUsedPercent == 130)
        let worktree = try #require(Statusline.message(from: Data(#"{"hook_event_name":"Status","workspace":{"git_worktree":"/Users/me/wt/feature-x"}}"#.utf8), now: now))
        #expect(worktree.branch == "feature-x")
        #expect(worktree.prURL == nil)
        #expect(!message.userInfo.keys.contains("cwd"))
    }

    @Test func theLineCarriesEffortTodayTheBlockAndTheRingColours() throws {
        let payload = """
        {"model":{"display_name":"Opus"},"effort":{"level":"high"},"context_window":{"used_percentage":62},
         "cost":{"total_cost_usd":1.2345},
         "rate_limits":{"five_hour":{"used_percentage":45,"resets_at":\(Int(now.timeIntervalSince1970) + 7200)},
                        "seven_day":{"used_percentage":85,"resets_at":\(Int(now.timeIntervalSince1970) + 12 * 3600)}}}
        """
        let message = try #require(Statusline.message(from: Data(payload.utf8), now: now))
        let extras = Statusline.Extras(today: 12.4, blockCost: 3.1, blockResetsAt: now.addingTimeInterval(7200))
        #expect(Statusline.line(message, extras: extras) == "Opus high · ctx 62% · 5h 45% ↻2h · 7d 85% ↻12h · $1.23 · today $12 · block $3.10 ↻2h")
        let coloured = Statusline.line(message, extras: extras, colors: true)
        // 85 % with half a day of seven left projects to 92 %: on track, so orange; 45 % with 2 h of 5 left is ahead.
        #expect(coloured.contains("\u{1B}[33m7d 85% ↻12h\u{1B}[0m"))
        #expect(!coloured.contains("\u{1B}[33m5h"))
        #expect(!coloured.contains("\u{1B}[33mctx"))
        #expect(Statusline.tint(context: 0.96) == .danger)
        #expect(Statusline.tint(context: 0.8) == .warn)
        #expect(Statusline.tint(context: 0.5) == .none)
        // 45 % an hour into a five-hour window projects past 100: behind, so red.
        let behind = LimitWindow(id: "five_hour", label: "Session", usedFraction: 0.45, resetsAt: now.addingTimeInterval(4 * 3600), periodDuration: Period.fiveHours)
        #expect(Statusline.tint(for: behind, now: now) == .danger)
        #expect(Statusline.line(Statusline.Message(receivedAt: now), extras: Statusline.Extras(today: 0.5)) == "today $0.50")
    }

    @Test func extrasComeFromTheReportFileThenTheDailyHistory() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("notchmeter-extras-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let report = dir.appendingPathComponent("report-v1.json")
        let history = CostHistory(url: dir.appendingPathComponent("daily.jsonl"))
        history.record([Calendar.current.startOfDay(for: now): CostHistory.Record(cost: 7.5, tokens: TokenBreakdown(), byModel: [:], byProject: [:])], existing: [:])
        let fromHistory = Statusline.Extras.read(reportFile: report, history: history, now: now)
        #expect(fromHistory.today == 7.5)
        #expect(fromHistory.blockCost == nil)
        let object: [String: Any] = ["schema": UsageReport.schema, "generatedAt": Oracle.timestamp(now.addingTimeInterval(-60)),
                                     "cost": ["today": 12.25, "block": ["cost": 3.1, "end": Oracle.timestamp(now.addingTimeInterval(7200))]]]
        try JSONSerialization.data(withJSONObject: object).write(to: report)
        let fromReport = Statusline.Extras.read(reportFile: report, history: history, now: now)
        #expect(fromReport.today == 12.25)
        #expect(fromReport.blockCost == 3.1)
        #expect(fromReport.blockResetsAt == now.addingTimeInterval(7200))
        let stale: [String: Any] = ["schema": UsageReport.schema, "generatedAt": Oracle.timestamp(now.addingTimeInterval(-20 * 60)), "cost": ["today": 99]]
        try JSONSerialization.data(withJSONObject: stale).write(to: report)
        #expect(Statusline.Extras.read(reportFile: report, history: history, now: now).today == 7.5)
    }
}
