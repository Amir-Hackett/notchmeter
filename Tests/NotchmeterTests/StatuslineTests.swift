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
