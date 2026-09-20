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

    /// A line from just before a reset still carries the old figure; once the reset passes it no longer stands in
    /// for the endpoint, so the reset refresh reads the real (emptied) window instead of re-adopting 100 %.
    @Test func aLineDescribingAPassedResetNoLongerStandsIn() {
        let now = DateParsing.iso8601("2026-09-01T12:00:00Z")!
        let reset = now.addingTimeInterval(60)
        let window = LimitWindow(id: "session", label: .key("Session"), usedFraction: 1, resetsAt: reset)
        let line = Statusline.Message(windows: [window], receivedAt: now)
        #expect(line.standsIn(at: now.addingTimeInterval(30)))
        #expect(!line.standsIn(at: reset.addingTimeInterval(5)))
        #expect(!line.standsIn(at: now.addingTimeInterval(PollingPolicy.statuslineFreshFor + 1)))
        #expect(!Statusline.Message(receivedAt: now).standsIn(at: now))
    }

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

    /// The 0.7.0 fields, read as the status line documents them: `prompt_cache` whole (the causes as named, the
    /// per-cause counts, `null` as absent), fast mode, thinking, the agent's and the session's names, the line
    /// counts, the API time, the repository, and the three usage counts kept apart. All of it survives the flat
    /// wire, and the line ends with the session's own miss share.
    @Test func readsThePromptCacheAndTheRoundThreeFieldsAndCarriesThemFlat() throws {
        let payload = """
        {"hook_event_name":"Status","session_id":"pc1","cwd":"/Users/me/Developer/notchmeter","transcript_path":"/Users/me/.claude/x.jsonl",
         "model":{"id":"claude-opus-4-8","display_name":"Opus"},"fast_mode":true,"thinking":{"enabled":true},"agent":{"name":"reviewer"},
         "session_name":"fix the notch","cost":{"total_cost_usd":0.5,"total_lines_added":156,"total_lines_removed":23,"total_api_duration_ms":2300},
         "workspace":{"current_dir":"/Users/me/Developer/notchmeter","repo":{"host":"github.com","owner":"amir","name":"notchmeter"}},
         "context_window":{"context_window_size":200000,"current_usage":{"input_tokens":12000,"cache_creation_input_tokens":500,"cache_read_input_tokens":111500}},
         "prompt_cache":{"warm":true,"caching_observed":true,"ttl":"1h","expires_at":1756732800,"requests":14,"misses":2,"expected_rebuilds":1,
           "hit_ratio":0.91,"cache_write_tokens":352000,"miss_recache_tokens":310200,"last_miss_at":1756728000,
           "last_miss_cause":{"causes":["tools_changed"],"tools_added":2,"tools_removed":0},"miss_causes":{"tools_changed":2},"recache_tokens_if_cold":null}}
        """
        let message = try #require(Statusline.message(from: Data(payload.utf8), now: now))
        #expect(message.inputTokens == 12_000)
        #expect(message.cacheCreationTokens == 500)
        #expect(message.cacheReadTokens == 111_500)
        #expect(message.contextTokens == 124_000)
        #expect(message.fastMode == true)
        #expect(message.thinking == true)
        #expect(message.agentName == "reviewer")
        #expect(message.sessionName == "fix the notch")
        #expect(message.linesAdded == 156)
        #expect(message.linesRemoved == 23)
        #expect(message.apiDurationMs == 2300)
        #expect(message.repoHost == "github.com")
        #expect(message.repoOwner == "amir")
        #expect(message.repoName == "notchmeter")
        let cache = try #require(message.promptCache)
        #expect(cache.warm == true)
        #expect(cache.cachingObserved == true)
        #expect(cache.ttl == "1h")
        #expect(cache.expiresAt == Date(timeIntervalSince1970: 1_756_732_800))
        #expect(cache.requests == 14)
        #expect(cache.misses == 2)
        #expect(cache.expectedRebuilds == 1)
        #expect(cache.hitRatio == 0.91)
        #expect(cache.cacheWriteTokens == 352_000)
        #expect(cache.missRecacheTokens == 310_200)
        #expect(cache.lastMissAt == Date(timeIntervalSince1970: 1_756_728_000))
        #expect(cache.lastMissCauses == ["tools_changed"])
        #expect(cache.toolsAdded == 2)
        #expect(cache.toolsRemoved == 0)
        #expect(cache.systemCharDelta == nil)
        #expect(cache.missCauses == ["tools_changed": 2])
        #expect(cache.recacheTokensIfCold == nil)
        let info = message.userInfo
        #expect(!info.keys.contains("transcript_path"))
        #expect(!info.keys.contains("cwd"))
        #expect(info["cache_miss_causes"] as? String == #"{"tools_changed":2}"#)
        #expect(info["cache_last_miss_causes"] as? String == "tools_changed")
        #expect(info["prompt_cache"] as? Bool == true)
        #expect(JSONSerialization.isValidJSONObject(info))
        #expect(Statusline.Message(userInfo: info) == message)
        // 2 of 14 requests: 14 %, coloured from one in ten.
        #expect(Statusline.line(message) == "Opus · ctx 62% · $0.50 · cache 14% miss")
        #expect(Statusline.line(message, colors: true).hasSuffix("\u{1B}[33mcache 14% miss\u{1B}[0m"))
        #expect(Statusline.tint(cacheMiss: 0.25) == .danger)
        #expect(Statusline.tint(cacheMiss: 0.1) == .warn)
        #expect(Statusline.tint(cacheMiss: 0.09) == .none)
        // Before the first request the part is absent, and an empty object still travels as present.
        let early = try #require(Statusline.message(from: Data(#"{"model":{"display_name":"Opus"},"prompt_cache":{"warm":false,"requests":0,"misses":0}}"#.utf8), now: now))
        #expect(Statusline.line(early) == "Opus")
        #expect(early.promptCache?.warm == false)
        #expect(Statusline.Message(userInfo: early.userInfo)?.promptCache == early.promptCache)
        // With no figure of its own, the line takes today's from the app's report; with neither, nothing.
        let bare = try #require(Statusline.message(from: Data(#"{"model":{"display_name":"Opus"}}"#.utf8), now: now))
        #expect(bare.promptCache == nil)
        #expect(Statusline.line(bare, extras: Statusline.Extras(cacheMissShare: 0.3)) == "Opus · cache 30% miss")
        #expect(Statusline.line(bare) == "Opus")
        #expect(Statusline.Message(userInfo: bare.userInfo)?.promptCache == nil)
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
