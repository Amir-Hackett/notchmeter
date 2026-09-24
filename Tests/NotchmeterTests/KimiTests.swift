import Foundation
import Testing
@testable import Notchmeter

/// Kimi Code's usage answer, in the two shapes it has been seen in (docs/accuracy.md, *Kimi Code*): counts from the
/// CLI's own `/usage` parser, ratio pools beside or instead of them, and the rule for where the two disagree.
@Suite struct KimiUsageParsing {
    init() { Localization.use(language: "en") }

    let now = DateParsing.iso8601("2026-09-24T12:00:00Z")!

    func parse(_ json: String) throws -> UsageReading {
        try KimiProvider.parseUsage(Data(json.utf8), now: now)
    }

    /// The CLI's shape: a summary row and a five-hour window, every number a string and every reset in nanoseconds.
    @Test func theCountsShapeReadsAsTheCLIPrintsIt() throws {
        let reading = try parse(#"""
        {"usage":{"limit":"2048","used":"214","remaining":"1834","resetTime":"2026-09-27T15:23:13.716839300Z"},
         "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
                    "detail":{"limit":"200","used":"139","remaining":"61","resetTime":"2026-09-24T13:33:02.717479433Z"}}]}
        """#)
        #expect(reading.tool == .kimi)
        #expect(reading.plan == nil, "the answer names no plan, and none is guessed")
        let ids = reading.windows.map(\.id)
        #expect(ids == ["session", "weekly"], "the five-hour window leads, as Claude Code's and Codex's do")
        let labels = reading.windows.map(\.label)
        #expect(labels == ["Session", "Weekly"])
        let session = reading.windows[0]
        #expect(abs((session.usedFraction ?? 0) - 0.695) < 1e-9)
        #expect(session.periodDuration == Period.fiveHours)
        #expect(session.note == "61 of 200 left")
        #expect(session.source == .vendorEndpoint)
        #expect(session.resetsAt == DateParsing.iso8601("2026-09-24T13:33:02.717Z"), "nanoseconds are read to the millisecond, not refused")
        let week = reading.windows[1]
        #expect(abs((week.usedFraction ?? 0) - 214.0 / 2048.0) < 1e-9)
        #expect(week.periodDuration == Period.week, "the summary is the week: the CLI calls it Weekly limit and Kimi says it refreshes every 7 days")
        #expect(week.note == "1834 of 2048 left")
    }

    /// Only `remaining` beside `limit`: used is the difference, as the CLI computes it.
    @Test func usedIsTheLimitLessWhatRemains() throws {
        let reading = try parse(#"{"limits":[{"window":{"duration":5,"timeUnit":"TIME_UNIT_HOUR"},"detail":{"limit":"100","remaining":"100","resetTime":"2026-09-24T14:00:00Z"}}]}"#)
        #expect(reading.windows.map(\.id) == ["session"])
        #expect(reading.windows[0].usedFraction == 0)
        #expect(reading.windows[0].note == "100 of 100 left")
    }

    /// The ratio pools alone (steipete/CodexBar #3694): each a fraction and a reset; the two monthly pools are windows
    /// of their own.
    @Test func theRatioPoolsReadAsWindowsOfTheirOwn() throws {
        let reading = try parse(#"""
        {"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
                    "detail":{"limit":"100","used":"25","remaining":"75","resetTime":"2026-09-16T20:15:44.757047Z"}}],
         "usages":{"limit_5h":{"used_ratio":0,"reset_time":"2026-09-16T20:15:44Z"},
                   "limit_month_total":{"used_ratio":0.0056,"reset_time":"2026-10-17T00:00:00Z"},
                   "limit_month_code":{"used_ratio":0,"reset_time":"2026-10-17T00:00:00Z"}}}
        """#)
        let ids = reading.windows.map(\.id)
        #expect(ids == ["session", "monthly_total", "monthly_coding"])
        let labels = reading.windows.map(\.label)
        #expect(labels == ["Session", "Monthly total", "Monthly coding"])
        #expect(reading.windows[0].usedFraction == 0.25, "a ratio of 0 beside counts that say 25 is not believed over them")
        #expect(reading.windows[1].usedFraction == 0.0056)
        #expect(reading.windows[1].periodDuration == Period.month)
        #expect(reading.windows[1].resetsAt == DateParsing.iso8601("2026-10-17T00:00:00Z"))
        #expect(reading.windows[1].note == nil, "a ratio carries no counts to print")
    }

    /// MoonshotAI/kimi-code #3951: the counts say the week is spent, the ratio says untouched, and the API refused
    /// every request. The window is as spent as its furthest-along figure says.
    @Test func whereTheTwoShapesDisagreeTheFurthestAlongWins() throws {
        let reading = try parse(#"""
        {"usage":{"limit":"100","used":"100","resetTime":"2026-09-24T02:09:07.465054Z"},
         "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","remaining":"100","resetTime":"2026-09-21T01:09:07.465054Z"}}],
         "usages":{"limit_5h":{"used_ratio":0.4,"reset_time":"2026-09-21T01:09:06Z"},"limit_7d":{"used_ratio":0,"reset_time":"2026-09-24T02:09:06Z"}}}
        """#)
        #expect(reading.windows.map(\.id) == ["session", "weekly"], "each shape's week and five hours are one window, not two")
        #expect(reading.windows[0].usedFraction == 0.4, "the ratio is further along than counts at 0 used")
        #expect(reading.windows[0].resetsAt == DateParsing.iso8601("2026-09-21T01:09:07.465Z"), "the counts' reset is the one kept")
        #expect(reading.windows[1].usedFraction == 1, "used 100 of 100 is spent, whatever the ratio says")
    }

    /// Two sources of counts for one window: the summary row says the week is a quarter spent, a seven-day
    /// `limits[]` entry says three quarters. The rule is the one above: the window is as spent as its
    /// furthest-along figure says, and that source's counts are the ones kept whole, its reset with them.
    @Test func twoCountSourcesForOneWindowKeepTheFurthestAlong() throws {
        let reading = try parse(#"""
        {"usage":{"limit":"200","used":"50","resetTime":"2026-09-27T00:00:00Z"},
         "limits":[{"window":{"duration":7,"timeUnit":"TIME_UNIT_DAY"},"detail":{"limit":"200","used":"150","resetTime":"2026-09-28T00:00:00Z"}}]}
        """#)
        #expect(reading.windows.map(\.id) == ["weekly"], "the summary and the seven-day entry are one window")
        #expect(reading.windows[0].usedFraction == 0.75, "150 of 200, not the summary's 50")
        #expect(reading.windows[0].note == "50 of 200 left")
        #expect(reading.windows[0].resetsAt == DateParsing.iso8601("2026-09-28T00:00:00Z"), "the reset travels with the counts that won")
        let summaryWins = try parse(#"{"usage":{"limit":"200","used":"150"},"limits":[{"window":{"duration":7,"timeUnit":"TIME_UNIT_DAY"},"detail":{"limit":"200","used":"50","resetTime":"2026-09-28T00:00:00Z"}}]}"#)
        #expect(summaryWins.windows[0].usedFraction == 0.75)
        #expect(summaryWins.windows[0].resetsAt == DateParsing.iso8601("2026-09-28T00:00:00Z"), "a winner without a reset takes the other's")
        let tied = try parse(#"{"usage":{"limit":"200","used":"50"},"limits":[{"window":{"duration":7,"timeUnit":"TIME_UNIT_DAY"},"detail":{"limit":"200","used":"50","resetTime":"2026-09-28T00:00:00Z"}}]}"#)
        #expect(tied.windows[0].usedFraction == 0.25)
        #expect(tied.windows[0].resetsAt == DateParsing.iso8601("2026-09-28T00:00:00Z"), "on a tie the counts carrying a reset win")
        let first = KimiProvider.Counts(limit: 10, used: 2, resetsAt: nil)
        let second = KimiProvider.Counts(limit: 10, used: 2, resetsAt: nil)
        #expect(KimiProvider.furtherAlong(first, second) == first, "a full tie keeps the first, the summary's")
    }

    /// No limit, no figure: Kimi publishes no plan sizes, so a window without one is not drawn as untouched or full.
    @Test func noLimitMeansNoFigure() throws {
        let reading = try parse(#"{"usage":{"used":"12","reset_in":3600},"limits":[{"detail":{"limit":"0","used":"3"}}]}"#)
        #expect(reading.windows.map(\.id) == ["weekly", "limit_1"])
        #expect(reading.windows[0].usedFraction == nil)
        #expect(reading.windows[0].resetsAt == now.addingTimeInterval(3600), "a reset given as seconds to go is read against the read")
        #expect(reading.windows[1].usedFraction == nil)
        #expect(reading.windows[1].label == "Limit 1", "an entry with no length and no name is numbered, as the CLI numbers it")
        #expect(reading.windows[1].periodDuration == nil)
    }

    /// The vendor's own name is kept as its words; the window's id and length stay those of the length it declares.
    @Test func aNameTheVendorGivesIsKeptAsItsWords() throws {
        let reading = try parse(#"{"limits":[{"name":"Rate limit","window":{"duration":1,"timeUnit":"TIME_UNIT_DAY"},"detail":{"limit":"10","used":"5"}},{"window":{"duration":3,"timeUnit":"TIME_UNIT_HOUR"},"detail":{"limit":"4","used":"1"}},{"window":{"duration":2,"timeUnit":"TIME_UNIT_FORTNIGHT"},"detail":{"limit":"4","used":"1"}}]}"#)
        #expect(reading.windows.map(\.id) == ["limit_180m", "daily", "limit_3"])
        #expect(reading.windows[1].label == "Rate limit")
        #expect(reading.windows[1].name == .vendor("Rate limit"))
        #expect(reading.windows[1].periodDuration == Period.day)
        #expect(reading.windows[0].label == "3-hour")
        #expect(reading.windows[2].periodDuration == nil, "a unit this parser does not know gives no length rather than a guess")
    }

    @Test func aWrappedAnswerReadsTheSame() throws {
        let reading = try parse(#"{"data":{"usages":{"limit_7d":{"used_ratio":0.5,"reset_time":"2026-09-30T00:00:00Z"}}}}"#)
        #expect(reading.windows.map(\.id) == ["weekly"])
        #expect(reading.windows[0].usedFraction == 0.5)
    }

    @Test func nothingToReadIsCalmAndGarbageIsAParseError() {
        #expect(throws: ProviderError.nothingYet("Kimi Code reported no usage yet")) { try parse(#"{"usage":{},"limits":[]}"#) }
        #expect(throws: ProviderError.parse("Kimi's usage response unreadable")) { try parse("<html>") }
    }

    @Test func poolKeysAreReadByTheirLength() {
        #expect(KimiProvider.Kind.period(poolKey: "limit_5h") == Period.fiveHours)
        #expect(KimiProvider.Kind.period(poolKey: "limit_7d") == Period.week)
        #expect(KimiProvider.Kind.period(poolKey: "limit_30m") == 1800)
        #expect(KimiProvider.Kind.period(poolKey: "limit_2w") == 2 * Period.week)
        #expect(KimiProvider.Kind.period(poolKey: "limit_month_total") == nil)
        #expect(KimiProvider.Kind.period(poolKey: "limit_h") == nil)
        #expect(KimiProvider.Kind(pool: "limit_other").label == .vendor("limit_other"))
        #expect(KimiProvider.Kind(pool: "limit_other").period == nil)
    }

    @Test func datesWithAnyFractionAreRead() {
        #expect(KimiProvider.date("2026-01-06T13:33:02.717479433Z") == DateParsing.iso8601("2026-01-06T13:33:02.717Z"))
        #expect(KimiProvider.date("2026-01-06T13:33:02.7Z") == DateParsing.iso8601("2026-01-06T13:33:02.700Z"))
        #expect(KimiProvider.date("2026-01-06T13:33:02Z") == DateParsing.iso8601("2026-01-06T13:33:02Z"))
        #expect(KimiProvider.date("2026-01-06T13:33:02.123456+08:00") == DateParsing.iso8601("2026-01-06T13:33:02.123+08:00"))
        #expect(KimiProvider.date("soon") == nil)
        #expect(KimiProvider.date(42) == nil)
    }
}

/// The login the CLI keeps, read and never refreshed, and where it is kept.
@Suite struct KimiLogin {
    init() { Localization.use(language: "en") }

    @Test func theCredentialsFileIsReadAsTheCLIWritesIt() throws {
        let credentials = try KimiProvider.parseCredentials(Data(#"{"access_token":"eyJ.a.b","refresh_token":"r","expires_at":1790000000.5,"scope":"kimi-code","token_type":"Bearer","expires_in":900}"#.utf8))
        #expect(credentials.accessToken == "eyJ.a.b")
        #expect(credentials.expiresAt == Date(timeIntervalSince1970: 1_790_000_000.5), "expires_at is epoch seconds, where Google's is milliseconds")
        let unknown = try KimiProvider.parseCredentials(Data(#"{"access_token":"t","expires_at":0}"#.utf8))
        #expect(unknown.expiresAt == nil, "the CLI writes 0 for an expiry it was never told; that is unknown, not long past")
        #expect(throws: ProviderError.self) { try KimiProvider.parseCredentials(Data(#"{"refresh_token":"only"}"#.utf8)) }
        #expect(throws: ProviderError.self) { try KimiProvider.parseCredentials(Data("not json".utf8)) }
    }

    @Test func theShareFolderAndTheBaseFollowTheCLIsOverrides() {
        let home = URL(fileURLWithPath: "/Users/me")
        #expect(KimiProvider.shareDirectory(environment: [:], home: home).path == "/Users/me/.kimi")
        #expect(KimiProvider.shareDirectory(environment: ["KIMI_SHARE_DIR": "/srv/kimi"], home: home).path == "/srv/kimi")
        #expect(KimiProvider.shareDirectory(environment: ["KIMI_SHARE_DIR": ""], home: home).path == "/Users/me/.kimi", "an empty variable is no override")
        #expect(HookVendor.kimi.fileURL(environment: ["KIMI_SHARE_DIR": "/srv/kimi"], home: home).path == "/srv/kimi/config.toml")
        #expect(HookVendor.kimi.fileURL(environment: [:], home: home).path == "/Users/me/.kimi/config.toml")

        #expect(KimiProvider.baseURL(override: nil) == KimiProvider.defaultBaseURL)
        #expect(KimiProvider.usageURL(base: KimiProvider.defaultBaseURL).absoluteString == "https://api.kimi.com/coding/v1/usages")
        #expect(KimiProvider.baseURL(override: "https://api.kimi.ai/coding/v1/").absoluteString == "https://api.kimi.ai/coding/v1/")
        #expect(KimiProvider.usageURL(base: KimiProvider.baseURL(override: "https://api.kimi.ai/coding/v1/")).absoluteString == "https://api.kimi.ai/coding/v1/usages")
        #expect(KimiProvider.baseURL(override: "https://gateway.moonshot.cn/v1") != KimiProvider.defaultBaseURL, "Moonshot's own hosts are accepted")
        #expect(KimiProvider.baseURL(override: "http://api.kimi.com/coding/v1") == KimiProvider.defaultBaseURL, "never over plain http")
        #expect(KimiProvider.baseURL(override: "https://evil.example/coding/v1") == KimiProvider.defaultBaseURL, "the token goes to Moonshot's hosts only")
        #expect(KimiProvider.baseURL(override: "https://notkimi.com/v1") == KimiProvider.defaultBaseURL, "a lookalike suffix is not a subdomain")
    }
}

/// The one read, answered by a stub so the request and the answer mapping are pinned, and the token never refreshed.
@Suite(.serialized) struct KimiFetching {
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [URLRequest] = []
        var answer: @Sendable (URL) -> (Int, Data) = { _ in (404, Data()) }

        func record(_ request: URLRequest) {
            lock.withLock { seen.append(request) }
        }

        var requests: [URLRequest] { lock.withLock { seen } }
    }

    final class StubProtocol: URLProtocol {
        nonisolated(unsafe) static var recorder = Recorder()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            let recorder = Self.recorder
            recorder.record(request)
            let (status, data) = recorder.answer(request.url!)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    let scratch: URL
    let share: URL
    let recorder = Recorder()
    let provider: KimiProvider

    init() throws {
        Localization.use(language: "en")
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-kimi-\(UUID().uuidString)")
        share = scratch.appendingPathComponent(".kimi")
        try FileManager.default.createDirectory(at: share.appendingPathComponent("credentials"), withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        provider = KimiProvider(session: URLSession(configuration: configuration), environment: ["KIMI_SHARE_DIR": share.path, "TERM": "xterm"], home: scratch)
        StubProtocol.recorder = recorder
    }

    func login(expiresIn seconds: TimeInterval) throws {
        let expiry = Date().addingTimeInterval(seconds).timeIntervalSince1970
        try Data(#"{"access_token":"kimi.live","refresh_token":"r","expires_at":\#(expiry)}"#.utf8)
            .write(to: share.appendingPathComponent("credentials/kimi-code.json"))
    }

    @Test func readsTheUsagesWithTheCLIsTokenAndNothingElse() async throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        #expect(!provider.isInstalled(), "an empty share folder is not an install")
        try login(expiresIn: 600)
        #expect(provider.isInstalled())
        let body = Data(#"{"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"200","used":"50"}}]}"#.utf8)
        recorder.answer = { _ in (200, body) }
        let reading = try await provider.fetch()
        #expect(reading.windows.first?.usedFraction == 0.25)
        let requests = recorder.requests
        #expect(requests.count == 1, "one request, never a refresh")
        let request = try #require(requests.first)
        #expect(request.url?.absoluteString == "https://api.kimi.com/coding/v1/usages")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer kimi.live")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == AppInfo.userAgent, "the app's own name, nothing borrowed")
        let credentials = try String(contentsOf: share.appendingPathComponent("credentials/kimi-code.json"), encoding: .utf8)
        #expect(credentials.contains("kimi.live"), "the CLI's file is read, never written")
    }

    @Test func anExpiredOrMissingLoginAsksForTheCLIAndSendsNothing() async throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        await #expect(throws: ProviderError.notSignedIn("Sign in to Kimi Code (run `kimi`, then /login) to read your plan usage")) { try await provider.fetch() }
        try login(expiresIn: -60)
        await #expect(throws: ProviderError.tokenExpired("Kimi Code's login has expired. Run Kimi Code once so it signs back in")) { try await provider.fetch() }
        #expect(recorder.requests.isEmpty, "an expired token is not sent, and never refreshed from here")
    }

    /// kimi-cli on a Moonshot API-key platform has a config and no Kimi Code login: nothing to meter and nothing
    /// wrong, so the row is calm (idle, and hideable) rather than wearing an attention mark for a membership the
    /// user does not hold. A login file that is there but unreadable is still a login to renew.
    @Test func aConfigWithoutALoginIsCalmNotAFault() async throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        try Data("default_model = \"moonshot-v1-8k\"\n".utf8).write(to: share.appendingPathComponent("config.toml"))
        #expect(provider.isInstalled(), "the config alone is a set-up CLI")
        let message = "No Kimi Code login on this Mac (an API key has no plan to meter). Run `kimi`, then /login, to read a membership's usage"
        await #expect(throws: ProviderError.apiKeyOnly(message)) { try await provider.fetch() }
        #expect(ToolStatus(ProviderError.apiKeyOnly(message), cached: nil) == .idle(message))
        #expect(recorder.requests.isEmpty, "nothing is asked of Kimi without a token")
        try Data(#"{"refresh_token":"only"}"#.utf8).write(to: share.appendingPathComponent("credentials/kimi-code.json"))
        await #expect(throws: ProviderError.notSignedIn("Kimi Code has not signed in. Run `kimi`, then /login")) { try await provider.fetch() }
    }

    @Test func refusalsAreMappedToTheirCauses() async throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        try login(expiresIn: 600)
        recorder.answer = { _ in (401, Data()) }
        await #expect(throws: ProviderError.notSignedIn("Kimi Code's login was refused. Run Kimi Code once so it signs back in")) { try await provider.fetch() }
        recorder.answer = { _ in (403, Data()) }
        await #expect(throws: ProviderError.accessDenied("Kimi refused the usage read for this account")) { try await provider.fetch() }
        recorder.answer = { _ in (404, Data()) }
        await #expect(throws: ProviderError.unavailable("Kimi's usage endpoint answers only a Kimi Code membership")) { try await provider.fetch() }
        recorder.answer = { _ in (429, Data()) }
        await #expect(throws: ProviderError.rateLimited(retryAfter: nil)) { try await provider.fetch() }
        recorder.answer = { _ in (502, Data()) }
        await #expect(throws: ProviderError.http(502, "Kimi's usage endpoint answered")) { try await provider.fetch() }
    }
}

/// Kimi Code's hook payloads read onto the tracker's vocabulary: Claude Code's names, no wait, no rate limit.
@Suite struct KimiHookMessages {
    func parse(_ json: String, tool: ToolID? = .kimi) -> Hook.Message? {
        Hook.message(from: Data(json.utf8), tool: tool, environment: [:], branch: { $0 == "/Users/x/proj" ? "main" : nil })
    }

    func payload(_ event: String, _ extra: String = "") -> String {
        #"{"hook_event_name":"\#(event)","session_id":"k1","cwd":"/Users/x/proj"\#(extra.isEmpty ? "" : "," + extra)}"#
    }

    @Test func everyRegisteredEventIsReadAndNoneWaits() throws {
        let extras = ["SessionStart": #""source":"startup""#, "UserPromptSubmit": #""prompt":"write the tests\nand more""#, "Stop": #""stop_hook_active":false"#,
                      "StopFailure": #""error_type":"RateLimitError","error_message":"429 Too Many Requests""#,
                      "SubagentStart": #""agent_name":"coder","prompt":"secret""#, "SubagentStop": #""agent_name":"coder","response":"done""#,
                      "SessionEnd": #""reason":"exit""#]
        #expect(Set(extras.keys) == Set(HookVendor.kimi.events))
        for event in HookVendor.kimi.events {
            let message = try #require(parse(payload(event, extras[event] ?? "")), "\(event)")
            #expect(message.tool == .kimi, "\(event)")
            #expect(message.event == event, "\(event): Kimi's names are Claude Code's, so nothing is renamed")
            #expect(!message.needsInput, "\(event): Kimi documents no wait on the user")
            #expect(message.request == nil, "\(event): and nothing it asks can be answered")
            #expect(message.sessionID == "k1")
            #expect(message.project == "proj")
            #expect(message.branch == "main")
            #expect(message.failure == nil, "\(event): the exception's class name is not a documented kind")
            #expect(!message.hitRateLimit, "\(event)")
            #expect(message.agentID == nil, "\(event): agent_name is a type, not an id")
            #expect(message.title == (event == "UserPromptSubmit" ? "write the tests" : nil), "\(event): only the user's prompt titles the session")
        }
    }

    @Test func onlyTheFlagOrTheKeyMakesItKimis() throws {
        let asClaude = try #require(parse(payload("Stop"), tool: nil))
        #expect(asClaude.tool == .claude, "the payload is Claude-shaped, so nothing recognises it by shape")
        let remote = try #require(parse(#"{"hook_event_name":"Stop","session_id":"k1","tool":"kimi"}"#, tool: nil))
        #expect(remote.tool == .kimi)
        #expect(Hook.tool(in: ["Notchmeter", "--hook", "--tool", "kimi"]) == .kimi)
    }

    /// A turn runs and ends with the tick; a failed one ends without it; subagents are counted without ids; the
    /// session never shows as waiting on the user.
    @Test func theTrackerRunsAKimiSessionFromItsHook() throws {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        var tracker = SessionTracker()
        tracker.apply(try #require(parse(payload("SessionStart"))), now: t0)
        tracker.apply(try #require(parse(payload("UserPromptSubmit", #""prompt":"go""#))), now: t0.addingTimeInterval(1))
        #expect(tracker.isWorking(.kimi))
        tracker.apply(try #require(parse(payload("SubagentStart", #""agent_name":"coder""#))), now: t0.addingTimeInterval(2))
        tracker.apply(try #require(parse(payload("SubagentStart", #""agent_name":"coder""#))), now: t0.addingTimeInterval(3))
        #expect(tracker.sessions["kimi:k1"]?.agents.count == 2, "two agents of one kind are two agents")
        tracker.apply(try #require(parse(payload("SubagentStop", #""agent_name":"coder""#))), now: t0.addingTimeInterval(4))
        #expect(tracker.sessions["kimi:k1"]?.agents.count == 1)
        let finished = tracker.apply(try #require(parse(payload("Stop"))), now: t0.addingTimeInterval(61))
        #expect(finished.finished?.session.tool == .kimi)
        #expect(tracker.finish(of: .kimi, now: t0.addingTimeInterval(62))?.turn == 60)
        tracker.apply(try #require(parse(payload("UserPromptSubmit"))), now: t0.addingTimeInterval(100))
        let failed = tracker.apply(try #require(parse(payload("StopFailure", #""error_type":"APIStatusError""#))), now: t0.addingTimeInterval(130))
        #expect(failed.finished == nil, "a failed turn is not a finish")
        #expect(failed.limitHit == nil, "and not a rate limit either")
        #expect(!tracker.isWorking(.kimi))
        #expect(tracker.waiting(of: .kimi).isEmpty)
        tracker.apply(try #require(parse(payload("SessionEnd"))), now: t0.addingTimeInterval(140))
        #expect(tracker.sessions["kimi:k1"] == nil)
    }

    @Test func theVendorIsWiredToItsFile() {
        #expect(HookVendor.kimi.tool == .kimi)
        #expect(HookVendor.vendor(for: .kimi) == .kimi)
        #expect(HookVendor.kimi.displayName == "Kimi Code")
        #expect(HookVendor.kimi.fileName == "config.toml")
        #expect(HookVendor.kimi.shape == .tomlTables)
        #expect(HookVendor.kimi.flag == "--hook --tool kimi")
        #expect(HookVendor.kimi.flag(for: "Stop") == "--hook --tool kimi", "Kimi's payload names its event, so no --event is added")
        #expect(HookVendor.kimi.events == ["SessionStart", "UserPromptSubmit", "Stop", "StopFailure", "SubagentStart", "SubagentStop", "SessionEnd"])
        #expect(!HookVendor.kimi.reloadsLive)
        #expect(HookVendor.kimi.matcher(for: "Stop") == nil)
        let handler = HookVendor.kimi.handler(command: "c", event: "Stop")
        #expect(NSDictionary(dictionary: handler) == ["command": "c", "timeout": 5] as NSDictionary)
    }
}

/// Kimi Code's `config.toml`, read and written as text: the `[[hooks]]` tables found, one value rewritten in place,
/// new tables appended, and every byte that is not Notchmeter's left as it was.
@Suite struct KimiHookFileEditing {
    init() { Localization.use(language: "en") }

    let executable = "/Applications/Notchmeter.app/Contents/MacOS/Notchmeter"
    var expected: String { "'\(executable)' --hook --tool kimi" }

    /// A config the CLI and its user wrote: providers, a multi-line string whose lines look like headers, an array
    /// over several lines whose lines start with `[`, and a hook of the user's own.
    static let userConfig = #"""
    # Kimi Code config
    default_model = "kimi-code/kimi-for-coding"

    [providers."managed:kimi-code"]
    type = "kimi"
    base_url = "https://api.kimi.com/coding/v1"

    [loop_control]
    max_steps_per_turn = 100
    notes = """
    [[hooks]]
    event = "Stop"
    """
    matrix = [
      ["a", "b"],
      ["c", "d"],
    ]

    [[hooks]]
    event = "PostToolUse"   # format after edits
    matcher = "WriteFile|StrReplaceFile"
    command = 'jq -r ".tool_input.file_path" | xargs prettier --write'
    timeout = 10
    """#

    func scratchFile(_ text: String?) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-kimi-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("config.toml")
        if let text { try Data(text.utf8).write(to: url) }
        return url
    }

    @Test func theScannerFindsOnlyRealTables() {
        let scan = KimiHookFile.scan(Self.userConfig)
        #expect(!scan.conflict)
        #expect(scan.tables.count == 1, "the header-shaped lines inside a multi-line string and an array are not tables")
        let table = scan.tables[0]
        #expect(table.event == "PostToolUse", "a trailing comment is not part of the value")
        #expect(table.matcher == "WriteFile|StrReplaceFile")
        #expect(table.command == #"jq -r ".tool_input.file_path" | xargs prettier --write"#, "a literal string is read as written")
        #expect(table.timeout == 10)
        let settings = KimiHookFile.settings(from: scan)
        let hooks = settings["hooks"] as? [String: [[String: Any]]]
        #expect(hooks?["PostToolUse"]?.first?["command"] as? String == table.command)
    }

    @Test func basicStringsRoundTripWithEscapes() {
        for value in [#"'/Users/me/My "Apps"/Notchmeter' --hook --tool kimi"#, #"C:\path"#, "tab\there", "line\nbreak", "é ü 日本", "\u{01}"] {
            let written = KimiHookFile.basicString(value)
            let read = KimiHookFile.string(Substring(written))
            #expect(read?.value == value, "\(value)")
            #expect(read?.length == written.utf8.count)
        }
        #expect(KimiHookFile.string(#""\u00e9""#)?.value == "é")
        #expect(KimiHookFile.string(#""unterminated"#) == nil)
        #expect(KimiHookFile.string(#""""multi""""#) == nil, "a multi-line string is not read as a value")
    }

    @Test func aFileThatDefinesHooksAnotherWayIsAConflict() {
        #expect(KimiHookFile.scan("hooks = []\n").conflict)
        #expect(KimiHookFile.scan("hooks.stop = \"x\"\n").conflict)
        #expect(KimiHookFile.scan("[hooks]\nevent = \"Stop\"\n").conflict)
        #expect(KimiHookFile.scan("[hooks.extra]\n").conflict)
        #expect(KimiHookFile.scan("notes = \"\"\"\nnever closed\n").conflict, "a file ending inside a string is not appended to")
        #expect(KimiHookFile.scan("list = [\n1,\n").conflict)
        #expect(!KimiHookFile.scan("[agent]\nhooks = \"inside a table is not the root\"\n").conflict)
        #expect(!KimiHookFile.scan("").conflict)
    }

    @Test func theSnippetIsTheTablesAddWrites() throws {
        let snippet = HookSettings.snippet(vendor: .kimi, executable: executable)
        let scan = KimiHookFile.scan(snippet)
        #expect(!scan.conflict)
        #expect(scan.tables.map(\.event) == HookVendor.kimi.events)
        #expect(scan.tables.allSatisfy { $0.command == expected && $0.timeout == 5 })
        #expect(snippet.hasPrefix("[[hooks]]\nevent = \"SessionStart\"\ncommand = \"'/Applications/Notchmeter.app/Contents/MacOS/Notchmeter' --hook --tool kimi\"\ntimeout = 5\n"))
    }

    @Test func addAppendsTablesAndLeavesEveryOtherByte() throws {
        let url = try scratchFile(Self.userConfig)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(HookSettings.status(vendor: .kimi, at: url, executable: executable) == .notInstalled)
        let installed = try HookSettings.install(vendor: .kimi, at: url, executable: executable, now: now)
        #expect(installed.added == HookVendor.kimi.events)
        let backup = try #require(installed.backup)
        #expect(try String(contentsOf: backup, encoding: .utf8) == Self.userConfig, "the file as it was, beside itself")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix(Self.userConfig), "nothing of the user's is reformatted, reordered or dropped")
        #expect(text.contains(KimiHookFile.marker))
        #expect(HookSettings.status(vendor: .kimi, at: url, executable: executable) == .installed(path: executable))
        let scan = KimiHookFile.scan(text)
        #expect(scan.tables.count == 1 + HookVendor.kimi.events.count)
        #expect(scan.tables.first?.command == #"jq -r ".tool_input.file_path" | xargs prettier --write"#, "the user's own hook is still there")
        let again = try HookSettings.install(vendor: .kimi, at: url, executable: executable, now: now.addingTimeInterval(60))
        #expect(again.backup == nil, "nothing to add, nothing written")
        #expect(again.added.isEmpty)
        #expect(try String(contentsOf: url, encoding: .utf8) == text)
    }

    @Test func addCreatesTheFileWhenThereIsNone() throws {
        let url = try scratchFile(nil)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let installed = try HookSettings.install(vendor: .kimi, at: url, executable: executable, now: Date())
        #expect(installed.backup == nil, "there was nothing to back up")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix(KimiHookFile.marker))
        #expect(HookSettings.status(vendor: .kimi, at: url, executable: executable) == .installed(path: executable))
    }

    /// A moved app and a missing event: Repair rewrites each command of ours in place, keeps its timeout and the
    /// user's own table, and adds the event that lacked one.
    @Test func repairRewritesOurCommandsInPlaceAndAddsWhatIsMissing() throws {
        let old = "/Users/me/Downloads/Notchmeter.app/Contents/MacOS/Notchmeter"
        var text = Self.userConfig + "\n"
        for event in HookVendor.kimi.events where event != "SubagentStop" {
            text += "\n[[hooks]]\nevent = \"\(event)\"\ncommand = \"'\(old)' --hook --tool kimi\" # ours\ntimeout = 7\n"
        }
        let url = try scratchFile(text)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(HookSettings.status(vendor: .kimi, at: url, executable: executable) == .stale(path: old))
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let repaired = try HookSettings.repairInstall(vendor: .kimi, at: url, executable: executable, now: now)
        #expect(repaired.backup != nil)
        #expect(repaired.added.first == "SubagentStop", "the missing event is added")
        #expect(Set(repaired.added) == Set(HookVendor.kimi.events))
        let after = try String(contentsOf: url, encoding: .utf8)
        #expect(after.hasPrefix(Self.userConfig))
        #expect(!after.contains(old))
        #expect(after.contains("command = \"'\(executable)' --hook --tool kimi\" # ours\ntimeout = 7"), "only the value changes: the comment and the timeout stay")
        #expect(HookSettings.status(vendor: .kimi, at: url, executable: executable) == .installed(path: executable))
        let again = try HookSettings.repairInstall(vendor: .kimi, at: url, executable: executable, now: now.addingTimeInterval(60))
        #expect(again.backup == nil, "a current file is not written again")
    }

    @Test func aFileThatDefinesHooksAnotherWayIsLeftAlone() throws {
        let text = "hooks = [{ event = \"Stop\", command = \"say done\" }]\n"
        let url = try scratchFile(text)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(throws: HookSettings.Failure.self) { try HookSettings.install(vendor: .kimi, at: url, executable: executable, now: Date()) }
        #expect(throws: HookSettings.Failure.self) { try HookSettings.repairInstall(vendor: .kimi, at: url, executable: executable, now: Date()) }
        #expect(try String(contentsOf: url, encoding: .utf8) == text)
        #expect(HookSettings.Failure.tomlHooksKey(url).errorDescription?.hasSuffix("paste the snippet instead") == true)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(siblings == ["config.toml"], "no backup either: nothing was written")
    }

    /// A config.toml with Windows line endings. Swift reads CRLF as one Character, so a Character split on "\n"
    /// saw the whole file as one line: no table found, a root `hooks = [...]` no conflict, and Add appended a
    /// second `hooks`, which TOML forbids and Kimi refused. The scanner splits on the LF byte now, drops the CR
    /// before it, and counts both towards the next line's offset, so Repair's in-place rewrite lands on the bytes.
    @Test func windowsLineEndingsAreLines() throws {
        let crlf = Self.userConfig.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n"
        let scan = KimiHookFile.scan(crlf)
        #expect(!scan.conflict)
        #expect(scan.tables.count == 1)
        #expect(scan.tables.first?.event == "PostToolUse")
        #expect(scan.tables.first?.command == #"jq -r ".tool_input.file_path" | xargs prettier --write"#)
        #expect(scan.tables.first?.timeout == 10)
        #expect(KimiHookFile.scan("default_model = \"x\"\r\nhooks = [{ event = \"Stop\", command = \"say done\" }]\r\n").conflict,
                "a root hooks array on the second line is still a conflict")
        #expect(KimiHookFile.scan("[[hooks]]\r\nevent = \"Stop\"\r\nnotes = \"\"\"\r\nnever closed\r\n").conflict)
        #expect(KimiHookFile.lines(of: "").map { $0.offset } == [0], "an empty text is one empty line")
        #expect(KimiHookFile.lines(of: "a\r\nb\nc\r").map { "\($0.offset):\($0.line)" } == ["0:a", "3:b", "5:c"], "a CR is dropped, LF or not")
        #expect(KimiHookFile.lines(of: "x\n").map { "\($0.offset):\($0.line)" } == ["0:x", "2:"])

        let old = "/Users/me/Downloads/Notchmeter.app/Contents/MacOS/Notchmeter"
        var text = crlf
        for event in HookVendor.kimi.events {
            text += "\r\n[[hooks]]\r\nevent = \"\(event)\"\r\ncommand = \"'\(old)' --hook --tool kimi\"\r\ntimeout = 5\r\n"
        }
        let url = try scratchFile(text)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(HookSettings.status(vendor: .kimi, at: url, executable: executable) == .stale(path: old))
        let repaired = try HookSettings.repairInstall(vendor: .kimi, at: url, executable: executable, now: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(repaired.backup != nil)
        let after = try String(contentsOf: url, encoding: .utf8)
        #expect(after == text.replacingOccurrences(of: old, with: executable), "only the seven command values changed; every CR stays")
        #expect(HookSettings.status(vendor: .kimi, at: url, executable: executable) == .installed(path: executable))
    }

    /// The command's range is in UTF-8 bytes, so a value with a multi-byte character before or inside it is still
    /// replaced exactly.
    @Test func replacingWorksOnByteOffsets() throws {
        let text = "# café\n[[hooks]]\ncommand = \"é\"\nb = \"x\"\n"
        let range = try #require(KimiHookFile.scan(text).tables.first?.commandRange)
        let replaced = KimiHookFile.replacing([(range, "\"z\"")], in: text)
        #expect(replaced == "# café\n[[hooks]]\ncommand = \"z\"\nb = \"x\"\n")
        #expect(KimiHookFile.appending([], to: "x") == "x")
        #expect(KimiHookFile.appending(["t\n"], to: "x") == "x\n\n" + KimiHookFile.marker + "\nt\n")
    }
}

/// Kimi's own files set the polling cadence: the newest session's context or wire file, found with a few listings.
@Suite struct KimiActivity {
    @Test func theNewestSessionFilesAreFound() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-kimi-activity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(AgentActivity.newestKimi(root: root) == nil)
        let session = root.appendingPathComponent("sessions/0123abcd/s-1")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let wire = session.appendingPathComponent("wire.jsonl")
        try Data("{}\n".utf8).write(to: wire)
        let written = Date(timeIntervalSince1970: 1_790_000_000)
        try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: wire.path)
        for folder in [session, session.deletingLastPathComponent(), root.appendingPathComponent("sessions")] {
            try FileManager.default.setAttributes([.modificationDate: written.addingTimeInterval(-3600)], ofItemAtPath: folder.path)
        }
        #expect(AgentActivity.newestKimi(root: root) == written)
    }
}
