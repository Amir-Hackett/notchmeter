import Foundation
import Testing
@testable import Notchmeter

@Suite struct CopilotParsing {
    init() { Localization.use(language: "en") }

    @Test func premiumRequestsBecomeTheMeteredWindow() throws {
        let json = """
        {"copilot_plan":"individual","quota_reset_date":"2026-10-01",
         "quota_snapshots":{"premium_interactions":{"entitlement":300,"remaining":39,"percent_remaining":13.0,"unlimited":false,"overage_permitted":true,"overage_count":0},
                            "chat":{"unlimited":true,"entitlement":0,"remaining":0},
                            "completions":{"unlimited":true}}}
        """
        let reading = try CopilotProvider.parseUser(Data(json.utf8), now: Date(timeIntervalSince1970: 1_758_000_000))
        #expect(reading.plan == "Individual")
        #expect(reading.windows.map(\.id) == ["premium"])
        #expect(reading.windows[0].label == "Premium requests")
        #expect(reading.windows[0].usedFraction == 0.87)
        #expect(reading.windows[0].note == "39 of 300 left")
        #expect(reading.windows[0].resetsAt == CopilotProvider.resetDate("2026-10-01"))
        #expect(reading.windows[0].periodDuration == Period.month)
    }

    @Test func overageAndLimitedChatAreNoted() throws {
        let json = """
        {"copilot_plan":"business","quota_reset_date":"2026-10-01",
         "quota_snapshots":{"premium_interactions":{"entitlement":300,"remaining":0,"unlimited":false,"overage_permitted":true,"overage_count":12},
                            "chat":{"entitlement":50,"remaining":10,"unlimited":false},
                            "completions":{"unlimited":true}}}
        """
        let reading = try CopilotProvider.parseUser(Data(json.utf8))
        #expect(reading.windows.map(\.id) == ["premium", "chat"])
        #expect(reading.windows[0].usedFraction == 1)
        #expect(reading.windows[0].note == "0 of 300 left · 12 extra this month")
        #expect(reading.windows[1].usedFraction == 0.8)
        #expect(reading.windows[1].label == "Chat")
        let unlimited = try CopilotProvider.parseUser(Data(#"{"copilot_plan":"enterprise","quota_snapshots":{"premium_interactions":{"unlimited":true}}}"#.utf8))
        #expect(unlimited.windows[0].usedFraction == nil)
        #expect(unlimited.windows[0].note == "Unlimited on the Enterprise plan")
        #expect(throws: ProviderError.self) { try CopilotProvider.parseUser(Data("{}".utf8)) }
    }

    @Test func tokenComesFromAppsJSONThenHostsThenGh() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("notchmeter-copilot-\(UUID().uuidString)")
        let config = dir.appendingPathComponent("github-copilot")
        let gh = dir.appendingPathComponent("gh/hosts.yml")
        try fm.createDirectory(at: config, withIntermediateDirectories: true)
        try fm.createDirectory(at: gh.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        #expect(CopilotProvider.token(configRoot: config, ghHosts: gh) == nil)
        try Data("github.com:\n    user: me\n    oauth_token: gho_from_gh\n    git_protocol: https\n".utf8).write(to: gh)
        #expect(CopilotProvider.token(configRoot: config, ghHosts: gh) == "gho_from_gh")
        try Data(#"{"github.com":{"user":"me","oauth_token":"gho_from_hosts"}}"#.utf8).write(to: config.appendingPathComponent("hosts.json"))
        #expect(CopilotProvider.token(configRoot: config, ghHosts: gh) == "gho_from_hosts")
        try Data(#"{"github.com:Iv1.b507a08c87ecfe98":{"user":"me","oauth_token":"gho_from_apps"}}"#.utf8).write(to: config.appendingPathComponent("apps.json"))
        #expect(CopilotProvider.token(configRoot: config, ghHosts: gh) == "gho_from_apps")
        #expect(CopilotProvider.token(inHostsYAML: "gitlab.com:\n    oauth_token: x\n") == nil)
    }
}

@Suite struct CodexExtras {
    init() { Localization.use(language: "en") }

    @Test func additionalRateLimitsBecomePerModelWindows() throws {
        let json = """
        {"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":12,"reset_at":1759352940,"limit_window_seconds":18000},
                                         "secondary_window":{"used_percent":40,"reset_at":1759752940,"limit_window_seconds":604800}},
         "additional_rate_limits":[{"limit_name":"gpt-5.3-codex-spark","rate_limit":{"primary_window":{"used_percent":91,"reset_at":1759352940,"limit_window_seconds":18000},
                                                                                     "secondary_window":{"used_percent":30,"reset_at":1759752940,"limit_window_seconds":604800}}}],
         "credits":{"has_credits":false}}
        """
        let reading = try CodexProvider.parseBackend(Data(json.utf8), now: Date(timeIntervalSince1970: 1_759_000_000))
        #expect(reading.windows.map(\.id) == ["session", "weekly", "gpt_5.3_codex_spark_session", "gpt_5.3_codex_spark_weekly"])
        #expect(reading.windows[2].label == "GPT 5.3 Codex Spark Session")
        #expect(reading.windows[2].model == "GPT 5.3 Codex Spark")
        #expect(reading.windows[2].usedFraction == 0.91)
        #expect(reading.windows[3].periodDuration == 604_800)
        let context = Advisor.Context(readings: [reading], now: Date(timeIntervalSince1970: 1_759_000_000))
        #expect(Advisor.modelRouting(context).map(\.text) == ["GPT 5.3 Codex Spark session is 91%. Overall weekly is 40%. Switch models, not tools."])
    }

    @Test func resetCreditsAreShownNeverClaimed() throws {
        let now = Date(timeIntervalSince1970: 1_759_000_000)
        let credits = CodexProvider.parseResetCredits(Data(#"{"credits":[{"type":"full_reset","count":1,"expires_at":1759259200},{"credit_type":"partial","quantity":2,"expiration":"2026-10-20T00:00:00Z"},{"count":0}]}"#.utf8))
        #expect(credits.count == 2)
        #expect(credits[0].expiresAt == Date(timeIntervalSince1970: 1_759_259_200))
        #expect(credits[1].count == 2)
        let window = try #require(CodexProvider.resetCreditWindow(credits, now: now))
        #expect(window.id == "reset_credits")
        #expect(window.usedFraction == nil)
        #expect(window.resetsAt == credits[0].expiresAt)
        #expect(window.note == "Full Reset credit expires in 3d — claim it in Codex")
        #expect(CodexProvider.resetCreditWindow([], now: now) == nil)
        #expect(CodexProvider.resetCreditWindow([CodexProvider.ResetCredit(count: 1, expiresAt: now.addingTimeInterval(-1), kind: nil)], now: now) == nil)
        #expect(CodexProvider.parseResetCredits(Data("[]".utf8)).isEmpty)

        let behind = LimitWindow(id: "weekly", label: "Weekly", usedFraction: 0.9, resetsAt: now.addingTimeInterval(4 * 86400), periodDuration: Period.week)
        let soon = LimitWindow(id: "reset_credits", label: "Reset credits", usedFraction: nil, resetsAt: now.addingTimeInterval(3600 * 5))
        let reading = UsageReading(tool: .codex, windows: [behind, soon], plan: nil, fetchedAt: now, observedAt: nil)
        let advice = Advisor.resetCredits(Advisor.Context(readings: [reading], now: now))
        #expect(advice.map(\.text) == ["A Codex reset credit expires in 5h. Claim it in Codex."])
        let calm = UsageReading(tool: .codex, windows: [LimitWindow(id: "weekly", label: "Weekly", usedFraction: 0.1, resetsAt: now.addingTimeInterval(4 * 86400), periodDuration: Period.week), soon],
                                plan: nil, fetchedAt: now, observedAt: nil)
        #expect(Advisor.resetCredits(Advisor.Context(readings: [calm], now: now)).isEmpty)
    }
}
