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
        let ids = reading.windows.map(\.id)
        #expect(ids == ["premium"])
        #expect(reading.windows[0].label == "Premium requests")
        #expect(reading.windows[0].usedFraction == 0.87)
        #expect(reading.windows[0].note == "39 of 300 left")
        #expect(reading.windows[0].resetsAt == CopilotProvider.resetDate("2026-10-01"))
        #expect(reading.windows[0].periodDuration == Period.month)
    }

    /// Copilot Free reports its allowance as `monthly_quotas` and what is left as `limited_user_quotas`, with no
    /// snapshots; that threw, so the card showed an error in place of rings.
    @Test func theFreeTierIsReadFromItsMonthlyQuotas() throws {
        let json = """
        {"copilot_plan":"individual","access_type_sku":"free_limited_copilot","limited_user_reset_date":"2026-10-01",
         "monthly_quotas":{"chat":50,"completions":2000},"limited_user_quotas":{"chat":40,"completions":2000}}
        """
        let reading = try CopilotProvider.parseUser(Data(json.utf8))
        #expect(reading.windows.map(\.id) == ["chat", "completions"])
        #expect(abs((reading.windows[0].usedFraction ?? 0) - 0.2) < 1e-9)
        #expect(reading.windows[0].note == "40 of 50 left")
        #expect(reading.windows[1].usedFraction == 0)
        #expect(reading.windows[0].resetsAt == CopilotProvider.resetDate("2026-10-01"))
        let empty = try CopilotProvider.parseUser(Data(#"{"copilot_plan":"individual"}"#.utf8))
        #expect(empty.windows.count == 1)
        #expect(empty.windows[0].usedFraction == nil)
    }

    @Test func overageAndLimitedChatAreNoted() throws {
        let json = """
        {"copilot_plan":"business","quota_reset_date":"2026-10-01",
         "quota_snapshots":{"premium_interactions":{"entitlement":300,"remaining":0,"unlimited":false,"overage_permitted":true,"overage_count":12},
                            "chat":{"entitlement":50,"remaining":10,"unlimited":false},
                            "completions":{"unlimited":true}}}
        """
        let reading = try CopilotProvider.parseUser(Data(json.utf8))
        let ids = reading.windows.map(\.id)
        #expect(ids == ["premium", "chat"])
        #expect(reading.windows[0].usedFraction == 1)
        #expect(reading.windows[0].note == "0 of 300 left · 12 extra this month")
        #expect(reading.windows[1].usedFraction == 0.8)
        #expect(reading.windows[1].label == "Chat")
        let unlimited = try CopilotProvider.parseUser(Data(#"{"copilot_plan":"enterprise","quota_snapshots":{"premium_interactions":{"unlimited":true}}}"#.utf8))
        #expect(unlimited.windows[0].usedFraction == nil)
        #expect(unlimited.windows[0].note == "Unlimited on the Enterprise plan")
        #expect(throws: ProviderError.self) { try CopilotProvider.parseUser(Data("{}".utf8)) }
    }

    /// The paid metered seat after GitHub's June 2026 change (openusage's live fixture): the `-1` sentinel means
    /// no limit, `unlimited` with zero placeholders means the same, and the extra usage counts as before.
    @Test func aMeteredSeatAfterJuneReadsItsSentinelsAsNoLimit() throws {
        let json = """
        {"copilot_plan":"pro","quota_reset_date":"2099-01-15T00:00:00Z",
         "quota_snapshots":{"premium_interactions":{"entitlement":300,"remaining":123,"percent_remaining":41,"quota_id":"premium","overage_permitted":true,"overage_count":36},
                            "chat":{"entitlement":-1,"remaining":-1},
                            "completions":{"unlimited":true,"entitlement":0,"remaining":0}}}
        """
        let reading = try CopilotProvider.parseUser(Data(json.utf8))
        #expect(reading.plan == "Pro")
        #expect(reading.windows.map(\.id) == ["premium"])
        #expect(reading.windows[0].usedFraction == 0.59)
        #expect(reading.windows[0].note == "123 of 300 left · 36 extra this month")
        #expect(reading.windows[0].amountUSD == nil)
        // An ISO instant is a reset too, and the window is the month's.
        #expect(reading.windows[0].resetsAt == DateParsing.iso8601("2099-01-15T00:00:00Z"))
        #expect(reading.windows[0].periodDuration == Period.month)
    }

    /// The org-managed Business seat on AI credits (CodexBar's live-validated fixture): every snapshot a zero
    /// placeholder, which used to draw a 0 % bar, beside a `credits_used` count that is the only figure there is.
    /// A credit is a cent, so the window carries its dollars and the Cost card can show them.
    @Test func aTokenBilledSeatKeepsOnlyItsCreditsAndNeverAZeroBar() throws {
        let json = """
        {"copilot_plan":"business","token_based_billing":true,"quota_reset_date":"2026-09-01",
         "quota_snapshots":{"premium_interactions":{"entitlement":0,"remaining":0,"percent_remaining":100,"quota_id":"premium_interactions","credits_used":"31"},
                            "chat":{"entitlement":0,"remaining":0,"percent_remaining":100,"quota_id":"chat","credits_used":0}}}
        """
        let reading = try CopilotProvider.parseUser(Data(json.utf8))
        #expect(reading.windows.map(\.id) == ["credits"])
        #expect(reading.windows[0].label == "AI credits")
        #expect(reading.windows[0].usedFraction == nil)
        #expect(reading.windows[0].note == "31 credits used")
        let thirtyOneCents = 0.31
        #expect(abs((reading.windows[0].amountUSD ?? 0) - thirtyOneCents) < 1e-9)
        #expect(reading.windows[0].resetsAt == CopilotProvider.resetDate("2026-09-01"))
        #expect(CopilotProvider.creditsUsed(Data(json.utf8)) == 31)
        // The same seat with an entitlement is a credits window with a bar, its dollars the credits spent.
        let entitled = json.replacingOccurrences(of: #""entitlement":0,"remaining":0,"percent_remaining":100,"quota_id":"premium_interactions""#,
                                                 with: #""entitlement":1900,"remaining":1869,"quota_id":"premium_interactions""#)
        let bar = try CopilotProvider.parseUser(Data(entitled.utf8))
        #expect(bar.windows[0].id == "credits")
        #expect(bar.windows[0].note == "1869 of 1900 credits left")
        let usedShare = 31.0 / 1900
        #expect(abs((bar.windows[0].usedFraction ?? 0) - usedShare) < 1e-9)
        #expect(abs((bar.windows[0].amountUSD ?? 0) - thirtyOneCents) < 1e-9)
        // No credit spent yet is a figure of its own, not "no quota".
        let fresh = try CopilotProvider.parseUser(Data(#"{"copilot_plan":"business","token_based_billing":true,"quota_snapshots":{"premium_interactions":{"entitlement":0,"remaining":0,"credits_used":0}}}"#.utf8))
        #expect(fresh.windows.map(\.id) == ["credits"])
        #expect(fresh.windows[0].note == "No credits used this month yet")
        #expect(fresh.windows[0].amountUSD == 0)
        #expect(CopilotProvider.creditsUsed(Data(#"{"copilot_plan":"pro","quota_snapshots":{"chat":{"entitlement":50}}}"#.utf8)) == nil)
    }

    /// The free individual as GitHub answers it today (openusage's live fixture): a premium placeholder under
    /// `percent_remaining: 0`, which is not a full bar, beside the two quotas that are metered. The counts arrive
    /// as strings on some seats, and `quota_reset_date_utc` is a reset too.
    @Test func aFreeIndividualsPlaceholderIsNotAFullBar() throws {
        let json = """
        {"copilot_plan":"individual","access_type_sku":"free_limited_copilot","token_based_billing":true,"quota_reset_date_utc":"2099-07-01",
         "quota_snapshots":{"chat":{"entitlement":"200","remaining":"182","overage_permitted":false},
                            "completions":{"entitlement":2000,"remaining":1989,"percent_remaining":99.4},
                            "premium_interactions":{"entitlement":0,"remaining":0,"percent_remaining":0.0}}}
        """
        let reading = try CopilotProvider.parseUser(Data(json.utf8))
        #expect(reading.windows.map(\.id) == ["chat", "completions"])
        #expect(abs((reading.windows[0].usedFraction ?? 0) - 0.09) < 1e-9)
        #expect(reading.windows[0].note == "182 of 200 left")
        let completionsUsed = 0.006
        #expect(abs((reading.windows[1].usedFraction ?? 0) - completionsUsed) < 1e-9)
        #expect(reading.windows[0].resetsAt == CopilotProvider.resetDate("2099-07-01"))
        #expect(reading.windows[0].amountUSD == nil)
        #expect(CopilotProvider.count("31") == 31)
        #expect(CopilotProvider.count(31.5) == 31.5)
        #expect(CopilotProvider.count("many") == nil)
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
        let ids = reading.windows.map(\.id)
        #expect(ids == ["session", "weekly", "gpt_5.3_codex_spark_session", "gpt_5.3_codex_spark_weekly"])
        #expect(reading.windows[2].label == "GPT 5.3 Codex Spark Session")
        #expect(reading.windows[2].model == "GPT 5.3 Codex Spark")
        #expect(reading.windows[2].usedFraction == 0.91)
        #expect(reading.windows[3].periodDuration == 604_800)
        let context = Advisor.Context(readings: [reading], now: Date(timeIntervalSince1970: 1_759_000_000))
        let routing = Advisor.modelRouting(context).map(\.text)
        #expect(routing == ["GPT 5.3 Codex Spark session is 91%. Overall weekly is 40%. Switch models, not tools."])
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
        let expired = [CodexProvider.ResetCredit(count: 1, expiresAt: now.addingTimeInterval(-1), kind: nil)]
        #expect(CodexProvider.resetCreditWindow(expired, now: now) == nil)
        #expect(CodexProvider.parseResetCredits(Data("[]".utf8)).isEmpty)

        let behind = LimitWindow(id: "weekly", label: "Weekly", usedFraction: 0.9, resetsAt: now.addingTimeInterval(4 * 86400), periodDuration: Period.week)
        let soon = LimitWindow(id: "reset_credits", label: "Reset credits", usedFraction: nil, resetsAt: now.addingTimeInterval(3600 * 5))
        let reading = UsageReading(tool: .codex, windows: [behind, soon], plan: nil, fetchedAt: now, observedAt: nil)
        let advice = Advisor.resetCredits(Advisor.Context(readings: [reading], now: now))
        let claimIt = advice.map(\.text)
        #expect(claimIt == ["A Codex reset credit expires in 5h. Claim it in Codex."])
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
        let tokens = candidates.map(\.token)
        #expect(tokens == ["gho_live", "gho_stale"])
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
        let suite = "NotchmeterTests.CopilotLive"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let answers = Answers()
        let user = try JSONSerialization.data(withJSONObject: ["copilot_plan": "individual", "quota_reset_date": "2026-10-01",
                                                                "quota_snapshots": ["premium_interactions": ["entitlement": 300, "remaining": 100, "unlimited": false]]])
        answers.status = { token, _ in token == "gho_live" ? (200, user) : (401, Data()) }
        StubProtocol.answers = answers
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let provider = CopilotProvider(session: URLSession(configuration: configuration), configRoot: config, ghHosts: gh, defaults: defaults, history: nil)
        let reading = try await provider.fetch()
        // A seat with no credits field is written down as not metered in credits, for the Cost card's line.
        #expect(CopilotCreditsRead.load(from: defaults)?.metered == false)
        // 100 of 300 premium requests left, so two thirds of them are spent.
        let twoThirds = 2.0 / 3
        let drift = abs((reading.windows[0].usedFraction ?? 0) - twoThirds)
        #expect(drift < 1e-9)
        #expect(answers.tokens == ["gho_stale", "gho_live"])
        // The live token is remembered and tried first next time.
        _ = try await provider.fetch()
        #expect(answers.tokens.last == "gho_live")
        #expect(answers.tokens.count == 3)
        let refused = Answers()
        refused.status = { _, _ in (401, Data()) }
        StubProtocol.answers = refused
        do {
            _ = try await CopilotProvider(session: URLSession(configuration: configuration), configRoot: config, ghHosts: gh, defaults: defaults, history: nil).fetch()
            Issue.record("expected a refusal")
        } catch let error as ProviderError {
            #expect(error.needsAttention)
            #expect(error.message.contains("apps.json"))
            #expect(error.message.contains("hosts.yml"))
        }
        #expect(refused.tokens.count == 2)
    }

    /// The quota endpoint is asked with the client identity it answers to, and the credits it reports are folded
    /// into the daily history a cent a credit: the first read sets the baseline, each rise lands on the day it was
    /// seen, and a fall is the month's reset. The org billing read keeps the app's own identity.
    @Test func creditsRiseIntoTheDailyHistoryAndTheHeadersNameTheClient() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("notchmeter-copilot-credits-\(UUID().uuidString)")
        let config = dir.appendingPathComponent("github-copilot")
        try fm.createDirectory(at: config, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try Data(#"{"github.com":{"oauth_token":"gho_live"}}"#.utf8).write(to: config.appendingPathComponent("hosts.json"))
        let suite = "NotchmeterTests.CopilotCredits"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = CostHistory(url: dir.appendingPathComponent("daily.jsonl"), tool: .copilot)
        let answers = Answers()
        final class Seen: @unchecked Sendable {
            var credits = 31
            var headers: [String: String] = [:]
            let lock = NSLock()
        }
        let seen = Seen()
        answers.status = { _, url in
            seen.lock.lock()
            defer { seen.lock.unlock() }
            guard url == CopilotProvider.userURL else { return (404, Data()) }
            let body = #"{"copilot_plan":"business","token_based_billing":true,"quota_snapshots":{"premium_interactions":{"entitlement":0,"remaining":0,"credits_used":\#(seen.credits)},"chat":{"entitlement":0,"remaining":0,"credits_used":0}}}"#
            return (200, Data(body.utf8))
        }
        StubProtocol.answers = answers
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let provider = CopilotProvider(session: URLSession(configuration: configuration), configRoot: config, ghHosts: dir.appendingPathComponent("none.yml"),
                                       defaults: defaults, history: history)
        // First read: the baseline. The 31 credits already spent this month are not charged to today.
        let first = try await provider.fetch()
        #expect(first.windows[0].note == "31 credits used")
        #expect(history.load().isEmpty)
        #expect(CopilotCreditsRead.load(from: defaults)?.credits == 31)
        // A rise of 12 credits is twelve cents on today.
        seen.lock.lock(); seen.credits = 43; seen.lock.unlock()
        _ = try await provider.fetch()
        let today = Calendar.current.startOfDay(for: Date())
        let twelveCents = 0.12
        #expect(abs((history.load()[today]?.cost ?? 0) - twelveCents) < 1e-9)
        // The month resets: the count falls to 5, which is five credits since the reset, on top of the twelve.
        seen.lock.lock(); seen.credits = 5; seen.lock.unlock()
        _ = try await provider.fetch()
        let seventeenCents = 0.17
        #expect(abs((history.load()[today]?.cost ?? 0) - seventeenCents) < 1e-9)
        #expect(CopilotCreditsRead.load(from: defaults)?.credits == 5)
        // The same rise does not count twice.
        _ = try await provider.fetch()
        #expect(abs((history.load()[today]?.cost ?? 0) - seventeenCents) < 1e-9)
        #expect(CopilotProvider.editorVersion == "vscode/1.96.2")
        #expect(CopilotProvider.pluginVersion == "copilot-chat/0.26.7")
        #expect(CopilotProvider.copilotUserAgent == "GitHubCopilotChat/0.26.7")
        #expect(CopilotProvider.copilotAPIVersion == "2025-04-01")
        #expect(CopilotProvider.apiVersion == "2022-11-28")
        #expect(CopilotProvider.creditUSD == 0.01)
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
        let ids = windows.map(\.id)
        #expect(ids == ["org_acme_credits", "org_acme_spend"])
        #expect(windows[0].label == "acme org credits")
        #expect(windows[0].hiddenByDefault)
        #expect(windows[0].usedFraction == nil)
        #expect(abs((windows[0].amountUSD ?? 0) - 4.4) < 1e-9)
        #expect(windows[0].note == "$4.40 covered by the allowance · 150 requests this month")
        #expect(windows[1].note == "$1.60 billed this month")
        #expect(CopilotProvider.parseOrgBilling(Data(#"{"usageItems":[{"product":"actions","netAmount":1}]}"#.utf8), org: "acme").isEmpty)
    }
}
