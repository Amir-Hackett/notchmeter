import Foundation
import Testing
@testable import Notchmeter

@Suite struct ClaudeParsing {
    @Test func parsesKnownWindowsInOrder() throws {
        let json = """
        {"seven_day":{"utilization":1,"resets_at":"2026-09-03T22:00:00.313Z"},
         "five_hour":{"utilization":4.0,"resets_at":"2026-09-01T23:00:00.313Z"},
         "seven_day_opus":null,
         "extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null,"utilization":null}}
        """
        let reading = try ClaudeProvider.parseUsage(Data(json.utf8), plan: "max", now: Date(timeIntervalSince1970: 0))
        #expect(reading.windows.map(\.id) == ["five_hour", "seven_day"])
        #expect(reading.windows[0].label == "Current session")
        #expect(reading.windows[0].usedFraction == 0.04)
        #expect(reading.windows[1].label == "All models")
        #expect(reading.windows[1].usedFraction == 0.01)
        #expect(reading.windows[0].resetsAt == DateParsing.iso8601("2026-09-01T23:00:00.313Z"))
        #expect(reading.plan == "Max")
    }

    @Test func keepsUnknownWindowsAndExtraUsage() throws {
        let json = """
        {"five_hour":{"utilization":50,"resets_at":"2026-09-01T23:00:00Z"},
         "seven_day_mystery":{"utilization":10,"resets_at":"2026-09-01T23:00:00Z"},
         "extra_usage":{"is_enabled":true,"monthly_limit":40,"used_credits":10,"utilization":25}}
        """
        let reading = try ClaudeProvider.parseUsage(Data(json.utf8), plan: nil)
        #expect(reading.windows.map(\.id) == ["five_hour", "seven_day_mystery", "extra_usage"])
        #expect(reading.windows[1].label == "Seven Day Mystery")
        #expect(reading.windows[2].usedFraction == 0.25)
        #expect(reading.windows[2].note == "monthly limit $40")
    }

    @Test func rejectsEmptyResponse() {
        #expect(throws: ProviderError.self) {
            try ClaudeProvider.parseUsage(Data("{}".utf8), plan: nil)
        }
    }

    @Test func parsesCredentials() throws {
        let json = """
        {"claudeAiOauth":{"accessToken":"sk-ant-oat01-test","refreshToken":"x","expiresAt":1756771200000,"scopes":["user:inference"],"subscriptionType":"max"}}
        """
        let credentials = try ClaudeProvider.parseCredentials(Data(json.utf8))
        #expect(credentials.accessToken == "sk-ant-oat01-test")
        #expect(credentials.subscriptionType == "max")
        #expect(credentials.expiresAt == Date(timeIntervalSince1970: 1_756_771_200))
    }
}

@Suite struct CodexParsing {
    @Test func readsRolloutTailAndWindows() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-codex-\(UUID().uuidString)")
        let day = dir.appendingPathComponent("sessions/2026/09/01")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let rollout = day.appendingPathComponent("rollout-2026-09-01T10-00-00-abc.jsonl")
        let lines = [
            #"{"timestamp":"2026-09-01T10:00:00.000Z","type":"session_meta","payload":{"id":"abc"}}"#,
            #"{"timestamp":"2026-09-01T10:00:05.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":12.5,"window_minutes":300,"resets_at":1756725000},"secondary":{"used_percent":3,"window_minutes":10080,"resets_at":1757200000},"plan_type":"plus"}}}"#,
            #"{"timestamp":"2026-09-01T10:00:09.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":14,"window_minutes":300,"resets_at":1756725000},"secondary":{"used_percent":3.5,"window_minutes":10080,"resets_at":1757200000},"plan_type":"plus"}}}"#,
        ]
        try lines.joined(separator: "\n").write(to: rollout, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        let found = try #require(CodexProvider.latestRateLimits(in: rollout))
        #expect(found.observedAt == DateParsing.iso8601("2026-09-01T10:00:09.000Z"))
        let reading = try CodexProvider.reading(from: found.limits, observedAt: found.observedAt, now: Date(timeIntervalSince1970: 1_756_720_000))
        #expect(reading.windows.map(\.label) == ["5-hour", "Weekly"])
        #expect(reading.windows[0].usedFraction == 0.14)
        #expect(reading.windows[1].usedFraction == 0.035)
        #expect(reading.windows[0].resetsAt == Date(timeIntervalSince1970: 1_756_725_000))
        #expect(reading.plan == "Plus")
        let listed = CodexProvider.recentRollouts(in: dir.appendingPathComponent("sessions"), limit: 8)
        #expect(listed.map { $0.resolvingSymlinksInPath().path } == [rollout.resolvingSymlinksInPath().path])
    }

    @Test func expiredWindowReadsAsReset() throws {
        let limits: [String: Any] = ["primary": ["used_percent": 80.0, "window_minutes": 300.0, "resets_in_seconds": 100.0]]
        let observed = Date(timeIntervalSince1970: 1_000)
        let reading = try CodexProvider.reading(from: limits, observedAt: observed, now: Date(timeIntervalSince1970: 5_000))
        #expect(reading.windows[0].usedFraction == 0)
        #expect(reading.windows[0].note == "reset since Codex last reported")
        #expect(reading.windows[0].resetsAt == observed.addingTimeInterval(100))
    }

    @Test func labelsWindows() {
        #expect(CodexProvider.label(forMinutes: 300) == "5-hour")
        #expect(CodexProvider.label(forMinutes: 10080) == "Weekly")
        #expect(CodexProvider.label(forMinutes: 1440) == "1-day")
        #expect(CodexProvider.label(forMinutes: 90) == "90-minute")
    }
}

@Suite struct RelativeTimeFormatting {
    @Test func formatsResets() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(RelativeTime.resets(now.addingTimeInterval(8_040), hasLimit: true, now: now) == "resets in 2h 14m")
        #expect(RelativeTime.resets(now.addingTimeInterval(120), hasLimit: true, now: now) == "resets in 2m")
        #expect(RelativeTime.resets(nil, hasLimit: false, now: now) == "no limit published")
        #expect(RelativeTime.resets(now.addingTimeInterval(-5), hasLimit: true, now: now) == "resets now")
    }
}
