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


/// Every saved token is tried, newest file first; a refused one is passed over; organisation billing parses.
@Suite(.serialized) struct CopilotRoundTwo {
    init() { Localization.use(language: "en") }

    final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var tokens: [String] = []
        var status: @Sendable (String, URL) -> (Int, Data) = { _, _ in (401, Data()) }

        func record(_ token: String) {
            lock.lock()
            tokens.append(token)
            lock.unlock()
        }
    }

    final class StubProtocol: URLProtocol {
        nonisolated(unsafe) static var answers = Answers()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            let token = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "token ", with: "") ?? ""
            Self.answers.record(token)
            let (status, data) = Self.answers.status(token, request.url!)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    @Test func candidatesAreOrderedNewestFileFirstAndDeduplicated() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("notchmeter-copilot-order-\(UUID().uuidString)")
        let config = dir.appendingPathComponent("github-copilot")
        let gh = dir.appendingPathComponent("gh/hosts.yml")
        try fm.createDirectory(at: config, withIntermediateDirectories: true)
        try fm.createDirectory(at: gh.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try Data(#"{"github.com:Iv1.old":{"oauth_token":"gho_stale"}}"#.utf8).write(to: config.appendingPathComponent("apps.json"))
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86400)], ofItemAtPath: config.appendingPathComponent("apps.json").path)
        try Data("github.com:\n    oauth_token: gho_live\n".utf8).write(to: gh)
        try Data(#"{"github.com":{"oauth_token":"gho_live"}}"#.utf8).write(to: config.appendingPathComponent("hosts.json"))
        let candidates = CopilotProvider.tokenCandidates(configRoot: config, ghHosts: gh)
        #expect(candidates.map(\.token) == ["gho_live", "gho_stale"])
        #expect(candidates.first?.file.lastPathComponent != "apps.json")
        #expect(CopilotProvider.token(configRoot: config, ghHosts: gh) == "gho_live")
        #expect(CopilotProvider.shortPath(Paths.home.appendingPathComponent(".config/gh/hosts.yml")) == "~/.config/gh/hosts.yml")
    }

    @Test func aStaleTokenIsPassedOverForTheLiveOneAndNamedWhenAllFail() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("notchmeter-copilot-live-\(UUID().uuidString)")
        let config = dir.appendingPathComponent("github-copilot")
        let gh = dir.appendingPathComponent("gh/hosts.yml")
        try fm.createDirectory(at: config, withIntermediateDirectories: true)
        try fm.createDirectory(at: gh.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try Data(#"{"github.com:Iv1.old":{"oauth_token":"gho_stale"}}"#.utf8).write(to: config.appendingPathComponent("apps.json"))
        try Data("github.com:\n    oauth_token: gho_live\n".utf8).write(to: gh)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86400)], ofItemAtPath: gh.path)
        let answers = Answers()
        let user = try JSONSerialization.data(withJSONObject: ["copilot_plan": "individual", "quota_reset_date": "2026-10-01",
                                                                "quota_snapshots": ["premium_interactions": ["entitlement": 300, "remaining": 100, "unlimited": false]]])
        answers.status = { token, _ in token == "gho_live" ? (200, user) : (401, Data()) }
        StubProtocol.answers = answers
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let provider = CopilotProvider(session: URLSession(configuration: configuration), configRoot: config, ghHosts: gh)
        let reading = try await provider.fetch()
        #expect(abs((reading.windows[0].usedFraction ?? 0) - 2.0 / 3) < 1e-9)
        #expect(answers.tokens == ["gho_stale", "gho_live"])
        // The live token is remembered and tried first next time.
        _ = try await provider.fetch()
        #expect(answers.tokens.last == "gho_live")
        #expect(answers.tokens.count == 3)
        let refused = Answers()
        refused.status = { _, _ in (401, Data()) }
        StubProtocol.answers = refused
        do {
            _ = try await CopilotProvider(session: URLSession(configuration: configuration), configRoot: config, ghHosts: gh).fetch()
            Issue.record("expected a refusal")
        } catch let error as ProviderError {
            #expect(error.needsAttention)
            #expect(error.message.contains("apps.json"))
            #expect(error.message.contains("hosts.yml"))
        }
        #expect(refused.tokens.count == 2)
    }

    @Test func organisationBillingBecomesHiddenWindows() throws {
        let orgs = CopilotProvider.parseOrgs(Data(#"[{"login":"acme","id":1},{"login":"","id":2},{"id":3}]"#.utf8))
        #expect(orgs == ["acme"])
        let url = try #require(CopilotProvider.orgBillingURL(org: "acme", now: DateParsing.iso8601("2026-09-15T12:00:00Z")!))
        #expect(url.absoluteString == "https://api.github.com/orgs/acme/settings/billing/usage/summary?year=2026&month=9")
        let summary = """
        {"usageItems":[{"date":"2026-09-01","product":"copilot","sku":"Copilot Premium Request","quantity":120,"unitType":"Requests","pricePerUnit":0.04,"grossAmount":4.8,"discountAmount":3.2,"netAmount":1.6,"organizationName":"acme"},
                       {"date":"2026-09-02","product":"actions","quantity":9,"netAmount":9},
                       {"date":"2026-09-02","product":"Copilot","quantity":30,"grossAmount":1.2,"discountAmount":1.2,"netAmount":0}]}
        """
        let windows = CopilotProvider.parseOrgBilling(Data(summary.utf8), org: "acme")
        #expect(windows.map(\.id) == ["org_acme_credits", "org_acme_spend"])
        #expect(windows[0].label == "acme org credits")
        #expect(windows[0].hiddenByDefault)
        #expect(windows[0].usedFraction == nil)
        #expect(abs((windows[0].amountUSD ?? 0) - 4.4) < 1e-9)
        #expect(windows[0].note == "$4.40 covered by the allowance · 150 requests this month")
        #expect(windows[1].note == "$1.60 billed this month")
        #expect(CopilotProvider.parseOrgBilling(Data(#"{"usageItems":[{"product":"actions","netAmount":1}]}"#.utf8), org: "acme").isEmpty)
    }
}
