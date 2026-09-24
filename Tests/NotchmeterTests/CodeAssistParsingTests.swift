import Foundation
import Testing
@testable import Notchmeter

@Suite struct AntigravityParsing {
    init() { Localization.use(language: "en") }

    let resetsAt = "2026-09-02T07:00:00Z"

    @Test func groupsGeminiTiersAndKeepsOtherModelsApart() throws {
        let json = """
        {"buckets":[
          {"modelId":"gemini-2.5-pro","remainingFraction":0.6,"resetTime":"\(resetsAt)"},
          {"modelId":"gemini-3-pro-preview","remainingFraction":0.6,"resetTime":"\(resetsAt)"},
          {"modelId":"gemini-2.5-flash","remainingFraction":0.9,"resetTime":"\(resetsAt)","remainingAmount":"1350"},
          {"modelId":"gemini-2.5-flash-lite","remainingFraction":0.8,"resetTime":"\(resetsAt)"},
          {"modelId":"claude-sonnet-4-5","remainingFraction":0.25,"resetTime":"2026-09-01T17:00:00Z","tokenType":"REQUESTS"},
          {"modelId":"claude-opus-4-1","resetTime":"2026-09-01T17:00:00Z"}
        ]}
        """
        let reading = try CodeAssistProvider.parseQuota(Data(json.utf8), plan: "Standard", now: Date(timeIntervalSince1970: 0))
        #expect(reading.tool == .antigravity)
        #expect(reading.plan == "Standard")
        let labels = reading.windows.map(\.label)
        let ids = reading.windows.map(\.id)
        let models = reading.windows.map(\.model)
        #expect(labels == ["Gemini Pro", "Gemini Flash", "Gemini Flash Lite", "Claude Sonnet 4.5", "Claude Opus 4.1"])
        #expect(ids == ["gemini_pro", "gemini_flash", "gemini_flash_lite", "model_claude-sonnet-4-5", "model_claude-opus-4-1"])
        #expect(models == labels)
        let used = reading.windows.map { $0.usedFraction ?? -1 }
        #expect(abs(used[0] - 0.4) < 1e-9)
        #expect(abs(used[1] - 0.1) < 1e-9)
        #expect(abs(used[2] - 0.2) < 1e-9)
        #expect(used[3] == 0.75)
        // A bucket Google sent no fraction for is a window with no figure and its reset, never one at 100 % left.
        #expect(used[4] == -1)
        #expect(reading.windows[4].resetsAt == DateParsing.iso8601("2026-09-01T17:00:00Z"))
        #expect(reading.windows[0].resetsAt == DateParsing.iso8601(resetsAt))
        #expect(reading.windows[3].resetsAt == DateParsing.iso8601("2026-09-01T17:00:00Z"))
        #expect(reading.windows[0].note == "Gemini 2.5 Pro · Gemini 3 Pro Preview")
        #expect(reading.windows[1].note == "1350 of 1500 left")
        #expect(reading.windows[2].note == nil)
        #expect(reading.windows.allSatisfy { $0.periodDuration == nil })
    }

    /// An explicit 0 is exhausted; an absent fraction is unknown; and a payload whose every figured bucket reads
    /// untouched at one identical reset is the answer of a host that is not metering the account, so it draws no
    /// ring (antigravity-cli #387). One untouched window alone is left as it is.
    @Test func zeroIsExhaustedAbsentIsUnknownAndAllUntouchedIsUnmetered() throws {
        let mixed = """
        {"buckets":[{"modelId":"gemini-2.5-pro","remainingFraction":0,"resetTime":"\(resetsAt)"},
                    {"modelId":"claude-sonnet-4-5","resetTime":"\(resetsAt)"}]}
        """
        let reading = try CodeAssistProvider.parseQuota(Data(mixed.utf8), plan: nil)
        #expect(reading.windows.map(\.usedFraction) == [1, nil])
        #expect(reading.windows[1].resetsAt == DateParsing.iso8601(resetsAt))

        let untouched = """
        {"buckets":[{"modelId":"gemini-2.5-pro","remainingFraction":1,"resetTime":"\(resetsAt)"},
                    {"modelId":"gemini-2.5-flash","remainingFraction":1,"resetTime":"\(resetsAt)"},
                    {"modelId":"claude-sonnet-4-5","remainingFraction":1,"resetTime":"2026-09-02T07:00:30Z"}]}
        """
        let unmetered = try CodeAssistProvider.parseQuota(Data(untouched.utf8), plan: nil)
        #expect(unmetered.windows.map(\.usedFraction) == [nil, nil, nil])
        #expect(unmetered.windows[0].note == "Reads untouched on every model, which this host also answers when it is not the one metering you")
        #expect(unmetered.windows[0].resetsAt == DateParsing.iso8601(resetsAt), "the reset is kept")
        let now = DateParsing.iso8601("2026-09-02T02:00:00Z")!
        #expect(!CodeAssistProvider.looksMetered(unmetered, now: now))

        let alone = try CodeAssistProvider.parseQuota(Data(#"{"buckets":[{"modelId":"gemini-2.5-pro","remainingFraction":1,"resetTime":"\#(resetsAt)"}]}"#.utf8), plan: nil)
        #expect(alone.windows[0].usedFraction == 0)
        let staggered = untouched.replacingOccurrences(of: "2026-09-02T07:00:30Z", with: "2026-09-05T07:00:00Z")
        #expect(try CodeAssistProvider.parseQuota(Data(staggered.utf8), plan: nil).windows[0].usedFraction == 0, "different resets are a real quota")

        // Liveness: something used, or a reset that is not the placeholder five hours from now.
        let placeholder = now.addingTimeInterval(Period.fiveHours)
        let fresh = UsageReading(tool: .antigravity, windows: [LimitWindow(id: "gemini_pro", label: "Gemini Pro", usedFraction: 0, resetsAt: placeholder)],
                                 plan: nil, fetchedAt: now, observedAt: nil)
        #expect(!CodeAssistProvider.looksMetered(fresh, now: now))
        let used = fresh.with(windows: [LimitWindow(id: "gemini_pro", label: "Gemini Pro", usedFraction: 0.02, resetsAt: placeholder)])
        #expect(CodeAssistProvider.looksMetered(used, now: now))
        let realReset = fresh.with(windows: [LimitWindow(id: "gemini_pro", label: "Gemini Pro", usedFraction: 0, resetsAt: placeholder.addingTimeInterval(-1800))])
        #expect(CodeAssistProvider.looksMetered(realReset, now: now))
    }

    /// `:retrieveUserQuotaSummary`: the groups Antigravity's own panel shows, with the window length declared, in
    /// either spelling of the remaining fraction; the group's "models" is dropped from the window's name.
    @Test func theSummaryGroupsBecomeSessionAndWeeklyWindows() throws {
        let json = """
        {"groups":[{"displayName":"Gemini Models","buckets":[
                      {"bucketId":"gemini-5h","displayName":"Session Limit","window":"5h","resetTime":"2026-09-01T17:00:00Z","remainingFraction":0.5},
                      {"bucketId":"gemini-weekly","displayName":"Weekly Limit","window":"weekly","resetTime":"\(resetsAt)","remaining":{"remainingFraction":0.75}}]},
                   {"displayName":"Claude and GPT models","buckets":[
                      {"bucketId":"claude-5h","window":"5h","resetTime":"2026-09-01T17:00:00Z","remaining":{"case":"remainingFraction","value":0.25}},
                      {"bucketId":"claude-daily","window":"daily","resetTime":"2026-09-02T00:00:00Z"}]}]}
        """
        let reading = try CodeAssistProvider.parseQuotaSummary(Data(json.utf8), plan: "Ultra", now: Date(timeIntervalSince1970: 0))
        #expect(reading.plan == "Ultra")
        #expect(reading.windows.map(\.id) == ["gemini_session", "gemini_weekly", "claude_and_gpt_session", "claude_and_gpt_daily"])
        #expect(reading.windows.map(\.label) == ["Gemini Session", "Gemini Weekly", "Claude and GPT Session", "Claude and GPT Daily"])
        #expect(reading.windows.map(\.model) == ["Gemini", "Gemini", "Claude and GPT", "Claude and GPT"])
        #expect(reading.windows.map(\.usedFraction) == [0.5, 0.25, 0.75, nil])
        #expect(reading.windows.map(\.periodDuration) == [Period.fiveHours, Period.week, Period.fiveHours, Period.day])
        #expect(reading.windows[1].resetsAt == DateParsing.iso8601(resetsAt))
        #expect(reading.windows.allSatisfy { $0.source == .vendorEndpoint })
        // Declared lengths are not inferred over.
        let applied = InferredPeriods.apply(reading, resets: [:], now: Date(timeIntervalSince1970: 0))
        #expect(applied.windows[0].note == nil)
        #expect(throws: ProviderError.self) { try CodeAssistProvider.parseQuotaSummary(Data("{}".utf8), plan: nil) }
        #expect(throws: ProviderError.self) { try CodeAssistProvider.parseQuotaSummary(Data(#"{"groups":[{"displayName":"x","buckets":[]}]}"#.utf8), plan: nil) }
        #expect(CodeAssistProvider.groupName(nil) == "Models")
        #expect(CodeAssistProvider.groupName("Models") == "Models")
    }

    /// The host Antigravity's own CLI logged is the one the account is metered on; anything that is not a Code
    /// Assist host is ignored, and the newest mention wins.
    @Test func theLoggedHostIsReadFromTheCLILog() {
        let text = """
        [info] POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist 200
        [info] GET https://example.com/cloudcode-pa.googleapis.com.evil/ 200
        [info] POST https://daily-cloudcode-pa.googleapis.com/v1internal:generateContent 200
        """
        #expect(CodeAssistProvider.loggedHost(inText: text) == CodeAssistProvider.dailyHost)
        #expect(CodeAssistProvider.loggedHost(inText: "nothing here") == nil)
        #expect(CodeAssistProvider.loggedHost(inText: "https://notcloudcode-pa.googleapis.com.example.org/") == nil)
        #expect(CodeAssistProvider.loggedHost(in: URL(fileURLWithPath: "/nonexistent/cli.log")) == nil)
        #expect(CodeAssistProvider.hostsToTry == [CodeAssistProvider.dailyHost, CodeAssistProvider.productionHost])
        #expect(CodeAssistProvider.url(host: CodeAssistProvider.dailyHost, method: "retrieveUserQuota").absoluteString
            == "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")
    }

    @Test func theTightestBucketOfATierSetsItsFigure() throws {
        let json = """
        {"buckets":[{"modelId":"gemini-2.5-pro","remainingFraction":0.6,"resetTime":"\(resetsAt)"},
                    {"modelId":"gemini-3-pro-preview","remainingFraction":0.3,"resetTime":"2026-09-01T20:00:00Z"},
                    {"modelId":"gemini-2.5-flash","remainingFraction":1.4}]}
        """
        let reading = try CodeAssistProvider.parseQuota(Data(json.utf8), plan: nil)
        let labels = reading.windows.map(\.label)
        #expect(labels == ["Gemini Pro", "Gemini Flash"])
        let tightest = reading.windows[0].usedFraction ?? 0
        #expect(abs(tightest - 0.7) < 1e-9)
        #expect(reading.windows[0].resetsAt == DateParsing.iso8601("2026-09-01T20:00:00Z"))
        #expect(reading.windows[1].usedFraction == 0)
        #expect(reading.windows[1].resetsAt == nil)
        #expect(reading.plan == nil)
    }

    @Test func rejectsResponsesWithoutUsableBuckets() {
        #expect(throws: ProviderError.self) { try CodeAssistProvider.parseQuota(Data("{}".utf8), plan: nil) }
        #expect(throws: ProviderError.self) { try CodeAssistProvider.parseQuota(Data(#"{"buckets":[{"modelId":"gemini-2.5-pro"}]}"#.utf8), plan: nil) }
        #expect(throws: ProviderError.self) { try CodeAssistProvider.parseQuota(Data("not json".utf8), plan: nil) }
    }

    @Test func parsesTheCachedGoogleLogin() throws {
        let json = """
        {"access_token":"ya29.test","refresh_token":"1//refresh","scope":"https://www.googleapis.com/auth/cloud-platform",
         "token_type":"Bearer","id_token":"h.p.s","expiry_date":1756771200000}
        """
        let credentials = try CodeAssistProvider.parseCredentials(Data(json.utf8))
        #expect(credentials.accessToken == "ya29.test")
        #expect(credentials.expiresAt == Date(timeIntervalSince1970: 1_756_771_200))
        let withoutAnExpiry = try CodeAssistProvider.parseCredentials(Data(#"{"access_token":"t"}"#.utf8))
        #expect(withoutAnExpiry.expiresAt == nil)
        #expect(throws: ProviderError.self) { try CodeAssistProvider.parseCredentials(Data(#"{"refresh_token":"r","access_token":""}"#.utf8)) }
        #expect(throws: ProviderError.self) { try CodeAssistProvider.parseCredentials(Data("[]".utf8)) }
    }

    @Test func parsesTheAccountFromLoadCodeAssist() throws {
        let free = try CodeAssistProvider.parseAccount(Data(#"{"currentTier":{"id":"free-tier","name":"Gemini Code Assist for individuals"},"cloudaicompanionProject":"managed-project-123","allowedTiers":[]}"#.utf8))
        #expect(free == CodeAssistProvider.Account(project: "managed-project-123", plan: "Free", unsupported: false))

        let paid = try CodeAssistProvider.parseAccount(Data(#"{"currentTier":{"id":"standard-tier"},"paidTier":{"name":"Gemini Code Assist in Google One AI Pro"},"cloudaicompanionProject":{"id":"p-1"}}"#.utf8))
        #expect(paid == CodeAssistProvider.Account(project: "p-1", plan: "Google One AI Pro", unsupported: false))

        let shutdown = try CodeAssistProvider.parseAccount(Data("""
        {"allowedTiers":[{"id":"standard-tier","name":"Gemini Code Assist","userDefinedCloudaicompanionProject":true,"isDefault":true}],
         "ineligibleTiers":[{"reasonCode":"UNSUPPORTED_CLIENT","reasonMessage":"This client is no longer supported for Gemini Code Assist for individuals.","tierId":"free-tier","tierName":"Gemini Code Assist for individuals"}]}
        """.utf8))
        #expect(shutdown == CodeAssistProvider.Account(project: nil, plan: nil, unsupported: true))

        let licensed = try CodeAssistProvider.parseAccount(Data(#"{"currentTier":{"id":"standard-tier"},"ineligibleTiers":[{"reasonCode":"UNSUPPORTED_CLIENT","tierId":"free-tier"}]}"#.utf8))
        #expect(licensed.plan == "Standard")
        #expect(!licensed.unsupported)
        let empty = try CodeAssistProvider.parseAccount(Data("{}".utf8))
        #expect(empty == CodeAssistProvider.Account(project: nil, plan: nil, unsupported: false))
    }

    @Test func namesPlansAndModels() {
        #expect(CodeAssistProvider.planName(tier: ["id": "legacy-tier"], paidTier: nil) == "Legacy")
        #expect(CodeAssistProvider.planName(tier: ["id": "enterprise-tier"], paidTier: nil) == "Enterprise")
        #expect(CodeAssistProvider.planName(tier: ["name": "Something"], paidTier: nil) == "Something")
        #expect(CodeAssistProvider.planName(tier: ["id": "free-tier"], paidTier: ["name": "Plus"]) == "Plus")
        #expect(CodeAssistProvider.planName(tier: nil, paidTier: ["name": " "]) == nil)

        #expect(ModelNames.display("gemini-2.5-pro") == "Gemini 2.5 Pro")
        #expect(ModelNames.display("gemini-3-pro-preview") == "Gemini 3 Pro Preview")
        #expect(ModelNames.display("gemini-2.5-flash-lite") == "Gemini 2.5 Flash Lite")
        #expect(ModelNames.display("claude-sonnet-4-5") == "Claude Sonnet 4.5")
        #expect(ModelNames.display("gpt-oss-120b") == "GPT OSS 120B")
        #expect(ModelNames.display("claude-opus-4-1-20250805") == "Claude Opus 4.1 20250805")
        #expect(CodeAssistProvider.pool(for: "gemini-embedding-001").label == "Gemini Embedding 001")
        #expect(CodeAssistProvider.pool(for: "GEMINI-3.1-PRO").id == "gemini_pro")
    }

    @Test func recognisesTheSubscriptionRequiredRefusal() {
        let refusal = """
        {"error":{"code":403,"message":"You do not have a valid license of this product.","status":"PERMISSION_DENIED",
         "details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"SUBSCRIPTION_REQUIRED","domain":"cloudaicompanion.googleapis.com"}]}}
        """
        #expect(CodeAssistProvider.isSubscriptionRequired(Data(refusal.utf8)))
        #expect(!CodeAssistProvider.isSubscriptionRequired(Data(#"{"error":{"code":403,"status":"PERMISSION_DENIED"}}"#.utf8)))
        #expect(!CodeAssistProvider.isSubscriptionRequired(Data()))
    }

    @Test func installDetectionAndSignInStates() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-antigravity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let gemini = scratch.appendingPathComponent(".gemini")
        let app = scratch.appendingPathComponent("Antigravity.app")
        let home = scratch.appendingPathComponent(".antigravity")
        try FileManager.default.createDirectory(at: gemini, withIntermediateDirectories: true)

        // The two rows since 0.9.0: Gemini CLI's is here wherever its login is; Antigravity's wherever the app, its
        // home folder or its CLI's folder is, and a Gemini CLI login alone never shows it.
        let provider = CodeAssistProvider(tool: .gemini, geminiHome: gemini, applicationBundle: app, antigravityHome: home)
        let antigravity = CodeAssistProvider(tool: .antigravity, geminiHome: gemini, applicationBundle: app, antigravityHome: home)
        #expect(provider.tool == .gemini && antigravity.tool == .antigravity)
        #expect(!provider.isInstalled())
        #expect(!antigravity.isInstalled())
        #expect(await failure(of: provider) == .notSignedIn)
        #expect(await failure(of: antigravity) == .notSignedIn)

        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        #expect(antigravity.isInstalled())
        #expect(!provider.isInstalled(), "Antigravity's own folder says nothing about Gemini CLI")
        try FileManager.default.removeItem(at: home)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        #expect(antigravity.isInstalled())
        try FileManager.default.removeItem(at: app)
        #expect(!antigravity.isInstalled())
        try FileManager.default.createDirectory(at: gemini.appendingPathComponent("antigravity-cli"), withIntermediateDirectories: true)
        #expect(antigravity.isInstalled(), "the Antigravity CLI's folder under ~/.gemini is Antigravity's")
        #expect(!provider.isInstalled())
        try FileManager.default.removeItem(at: gemini.appendingPathComponent("antigravity-cli"))

        let expired = Int(Date().addingTimeInterval(-3600).timeIntervalSince1970 * 1000)
        try Data(#"{"access_token":"ya29.old","expiry_date":\#(expired)}"#.utf8).write(to: gemini.appendingPathComponent("oauth_creds.json"))
        #expect(provider.isInstalled())
        #expect(!antigravity.isInstalled(), "a Gemini CLI login alone shows only the Gemini CLI row")
        #expect(await failure(of: provider) == .tokenExpired)
        #expect(await failure(of: antigravity) == .tokenExpired)
        #expect(!provider.identifiesAsAntigravity)
        #expect(antigravity.identifiesAsAntigravity)

        try Data(#"{"refresh_token":"only"}"#.utf8).write(to: gemini.appendingPathComponent("oauth_creds.json"))
        #expect(await failure(of: provider) == .notSignedIn)
    }
}

/// The two Google calls behind a reading, answered by a stub so the request bodies and the answer mapping are pinned.
@Suite(.serialized) struct AntigravityFetching {
    final class Exchange: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        private var bodies: [Data] = []
        var answer: @Sendable (URL) -> (Int, Data) = { _ in (404, Data()) }

        func record(_ request: URLRequest, body: Data) {
            lock.lock()
            requests.append(request)
            bodies.append(body)
            lock.unlock()
        }

        var seen: [(request: URLRequest, body: [String: Any])] {
            lock.lock()
            defer { lock.unlock() }
            return zip(requests, bodies).map { ($0, (try? JSONSerialization.jsonObject(with: $1) as? [String: Any]) ?? [:]) }
        }
    }

    final class StubProtocol: URLProtocol {
        nonisolated(unsafe) static var exchange = Exchange()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            let exchange = Self.exchange
            exchange.record(request, body: Self.body(of: request))
            let (status, data) = exchange.answer(request.url!)
            // A status below zero is the network failing the request: the host resolving nowhere, or a timeout.
            guard status > 0 else {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
                return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }

        private static func body(of request: URLRequest) -> Data {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            return data
        }
    }

    let scratch: URL
    /// Gemini CLI's row, on a Mac whose one login is Gemini CLI's.
    let provider: CodeAssistProvider
    let exchange = Exchange()
    let session: URLSession
    let gemini: URL

    init() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-antigravity-\(UUID().uuidString)")
        gemini = scratch.appendingPathComponent(".gemini")
        try FileManager.default.createDirectory(at: gemini, withIntermediateDirectories: true)
        let expiry = Int(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        try Data(#"{"access_token":"ya29.live","refresh_token":"1//r","expiry_date":\#(expiry)}"#.utf8).write(to: gemini.appendingPathComponent("oauth_creds.json"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: configuration)
        provider = CodeAssistProvider(tool: .gemini, session: session, geminiHome: gemini,
                                      applicationBundle: scratch.appendingPathComponent("none.app"), antigravityHome: scratch.appendingPathComponent("none"))
        StubProtocol.exchange = exchange
    }

    /// Antigravity's row on the same Mac, reading the same login under its own identity.
    var antigravity: CodeAssistProvider {
        CodeAssistProvider(tool: .antigravity, session: session, geminiHome: gemini,
                           applicationBundle: scratch.appendingPathComponent("none.app"), antigravityHome: scratch.appendingPathComponent("none"))
    }

    func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    @Test func asksForTheProjectThenTheQuotaWithTheLoginAsIs() async throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let quota = json(["buckets": [["modelId": "gemini-2.5-pro", "remainingFraction": 0.75, "resetTime": "2026-09-02T07:00:00Z"]]])
        let account = json(["currentTier": ["id": "standard-tier", "name": "Gemini Code Assist"], "cloudaicompanionProject": "managed-project-123"])
        exchange.answer = { url in
            switch url.path {
            case "/v1internal:loadCodeAssist": (200, account)
            case "/v1internal:retrieveUserQuota": (200, quota)
            default: (404, Data())
            }
        }
        let reading = try await provider.fetch()
        #expect(reading.plan == "Standard")
        let labels = reading.windows.map(\.label)
        #expect(labels == ["Gemini Pro"])
        #expect(reading.windows[0].usedFraction == 0.25)

        // With no log naming a host, the daily deployment is asked first; its live figure is believed and the
        // production host is never asked. The summary is tried before the buckets; a Gemini CLI login keeps Gemini
        // CLI's own identity.
        let seen = exchange.seen
        let calledInTurn = seen.map { $0.request.url }
        let daily = CodeAssistProvider.dailyHost
        #expect(calledInTurn == [CodeAssistProvider.url(host: daily, method: "loadCodeAssist"), CodeAssistProvider.url(host: daily, method: "retrieveUserQuotaSummary"),
                                 CodeAssistProvider.url(host: daily, method: "retrieveUserQuota")])
        let bodies = seen.map { $0.body as NSDictionary }
        let expectedBodies: [NSDictionary] = [
            ["metadata": ["ideType": "GEMINI_CLI", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]] as NSDictionary,
            [:] as NSDictionary,
            ["project": "managed-project-123"] as NSDictionary,
        ]
        #expect(bodies == expectedBodies)
        for (request, _) in seen {
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ya29.live")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == AppInfo.userAgent)
            #expect(request.value(forHTTPHeaderField: "Client-Metadata") == nil)
        }
    }

    /// An Antigravity login (its CLI folder is here, and its log names the production host): only that host is
    /// asked, every call carries Antigravity's identity, and a project-scoped refusal is retried project-less
    /// before it counts as a refusal (termhub #14: the licence is the user's, not a project's).
    @Test func anAntigravityLoginUsesItsLoggedHostItsIdentityAndRetriesProjectless() async throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let cli = scratch.appendingPathComponent(".gemini/antigravity-cli")
        try FileManager.default.createDirectory(at: cli, withIntermediateDirectories: true)
        try Data("[info] POST https://cloudcode-pa.googleapis.com/v1internal:generateContent 200\n".utf8).write(to: cli.appendingPathComponent("cli.log"))
        let account = json(["currentTier": ["id": "standard-tier"], "cloudaicompanionProject": "p-1"])
        let refusal = json(["error": ["code": 403, "message": "You do not have a valid license of this product.", "status": "PERMISSION_DENIED"]])
        let quota = json(["buckets": [["modelId": "gemini-2.5-pro", "remainingFraction": 0.4, "resetTime": "2026-09-02T07:00:00Z"]]])
        let exchange = self.exchange
        exchange.answer = { url in
            guard url.host == CodeAssistProvider.productionHost else { return (500, Data()) }
            switch url.path {
            case "/v1internal:loadCodeAssist": return (200, account)
            case "/v1internal:retrieveUserQuota":
                let projectScoped = exchange.seen.last?.body["project"] != nil
                return projectScoped ? (403, refusal) : (200, quota)
            default: return (404, Data())
            }
        }
        let reading = try await antigravity.fetch()
        #expect(reading.tool == .antigravity)
        #expect(reading.windows[0].usedFraction == 0.6)
        let seen = exchange.seen
        #expect(seen.map { $0.request.url?.host } == Array(repeating: CodeAssistProvider.productionHost, count: 4))
        #expect(seen.map { $0.request.url?.path } == ["/v1internal:loadCodeAssist", "/v1internal:retrieveUserQuotaSummary", "/v1internal:retrieveUserQuota", "/v1internal:retrieveUserQuota"])
        let bodies = seen.map { $0.body as NSDictionary }
        let expectedBodies: [NSDictionary] = [
            ["metadata": ["ideType": "ANTIGRAVITY", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]] as NSDictionary,
            [:] as NSDictionary, ["project": "p-1"] as NSDictionary, [:] as NSDictionary,
        ]
        #expect(bodies == expectedBodies)
        for (request, _) in seen {
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "antigravity")
            #expect(request.value(forHTTPHeaderField: "Client-Metadata") == #"{"ideType":"ANTIGRAVITY","platform":"MACOS","pluginType":"GEMINI"}"#)
        }

        // Gemini CLI's row on the same Mac, since 0.9.0 a row of its own: Antigravity's folder and log are here,
        // but they decide nothing for it. It asks as Gemini CLI, on both hosts in turn (the daily one first, which
        // this account is not metered on), and shows its own figure, tagged as its own.
        let before = exchange.seen.count
        let geminiReading = try await provider.fetch()
        #expect(geminiReading.tool == .gemini)
        #expect(geminiReading.windows[0].usedFraction == 0.6)
        let geminiCalls = exchange.seen.dropFirst(before)
        #expect(geminiCalls.first?.request.url?.host == CodeAssistProvider.dailyHost, "the Antigravity CLI's log names no host for Gemini CLI")
        #expect(geminiCalls.first?.body as NSDictionary? == ["metadata": ["ideType": "GEMINI_CLI", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]] as NSDictionary)
        for (request, _) in geminiCalls {
            #expect(request.value(forHTTPHeaderField: "User-Agent") == AppInfo.userAgent)
            #expect(request.value(forHTTPHeaderField: "Client-Metadata") == nil)
        }
    }

    /// The daily host answers a production-metered account with every bucket untouched and a reset five hours
    /// from now; that answer is declined and the production host's live figure is believed (token-monitor #722).
    /// When both hosts answer that way, the untouched reading is shown with no figure rather than as 100 % left.
    @Test func anUntouchedAnswerYieldsToTheOtherHostsLiveFigure() async throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let account = json(["currentTier": ["id": "standard-tier"]])
        let placeholder = ISO8601DateFormatter().string(from: Date().addingTimeInterval(Period.fiveHours))
        let untouched = json(["buckets": [["modelId": "gemini-2.5-pro", "remainingFraction": 1, "resetTime": placeholder],
                                          ["modelId": "gemini-2.5-flash", "remainingFraction": 1, "resetTime": placeholder]]])
        let live = json(["buckets": [["modelId": "gemini-2.5-pro", "remainingFraction": 0.7, "resetTime": "2026-09-02T07:00:00Z"]]])
        exchange.answer = { url in
            switch url.path {
            case "/v1internal:loadCodeAssist": (200, account)
            case "/v1internal:retrieveUserQuota": url.host == CodeAssistProvider.dailyHost ? (200, untouched) : (200, live)
            default: (404, Data())
            }
        }
        let reading = try await provider.fetch()
        let thirtyPercent = 0.3
        #expect(abs((reading.windows[0].usedFraction ?? 0) - thirtyPercent) < 1e-9)
        let hosts = exchange.seen.map { $0.request.url?.host }
        #expect(hosts.first == CodeAssistProvider.dailyHost)
        #expect(hosts.last == CodeAssistProvider.productionHost)

        exchange.answer = { url in
            switch url.path {
            case "/v1internal:loadCodeAssist": (200, account)
            case "/v1internal:retrieveUserQuota": (200, untouched)
            default: (404, Data())
            }
        }
        let unmetered = try await provider.fetch()
        #expect(unmetered.windows.map(\.usedFraction) == [nil, nil])
        #expect(unmetered.windows[0].note?.hasPrefix("Reads untouched") == true)
    }

    /// The daily alias is the first host tried since 0.7.0, and a Mac that cannot reach it (DNS, a timeout) must
    /// not lose the reading the production host would give: the account load fails inside the same net as the
    /// quota call, so the host is passed over, not the reading.
    @Test func aHostTheNetworkCannotReachIsPassedOverForTheNext() async throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let account = json(["currentTier": ["id": "standard-tier"]])
        let live = json(["buckets": [["modelId": "gemini-2.5-pro", "remainingFraction": 0.7, "resetTime": "2026-09-02T07:00:00Z"]]])
        exchange.answer = { url in
            guard url.host == CodeAssistProvider.productionHost else { return (-1, Data()) }
            switch url.path {
            case "/v1internal:loadCodeAssist": return (200, account)
            case "/v1internal:retrieveUserQuota": return (200, live)
            default: return (404, Data())
            }
        }
        let reading = try await provider.fetch()
        let thirtyPercent = 0.3
        #expect(abs((reading.windows[0].usedFraction ?? 0) - thirtyPercent) < 1e-9)
        let hosts = exchange.seen.map { $0.request.url?.host }
        #expect(hosts.first == CodeAssistProvider.dailyHost, "the daily host was tried, and failed")
        #expect(hosts.last == CodeAssistProvider.productionHost, "and the production host was still given its turn")

        // Neither reachable: the transport error is what is reported, so the footer says offline and the cached
        // reading stays, as for every other tool.
        exchange.answer = { _ in (-1, Data()) }
        await #expect(throws: (any Error).self) { try await provider.fetch() }
    }

    /// The shutdown is a calm state (`ProviderError.notServed`), not a fault: the answer is documented as permanent,
    /// so the row reads idle with the sentence, can hide, and is not polled every five minutes for it.
    @Test func aPersonalAccountIsToldAboutTheShutdownWithoutAQuotaCall() async throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let unsupported = json(["ineligibleTiers": [["reasonCode": "UNSUPPORTED_CLIENT", "tierId": "free-tier"]]])
        exchange.answer = { url in url.path == "/v1internal:loadCodeAssist" ? (200, unsupported) : (500, Data()) }
        #expect(await failure(of: provider) == .notServed)
        let error = ProviderError.notServed(CodeAssistProvider.shutdownMessage)
        #expect(error.isCalm && !error.needsAttention)
        #expect(ToolStatus(error, cached: nil) == .idle(CodeAssistProvider.shutdownMessage))
        #expect(ToolStatus(error, cached: nil).problem == nil, "no problem line on the card or in the footer")
        // Both hosts are asked who the account is, and only then is the shutdown reported; no quota call is made.
        let calledInTurn = exchange.seen.map { $0.request.url }
        #expect(calledInTurn == [CodeAssistProvider.url(host: CodeAssistProvider.dailyHost, method: "loadCodeAssist"), CodeAssistProvider.codeAssistURL])
    }

    @Test func refusalsAreMappedToTheirCauses() async throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let licensed = json(["currentTier": ["id": "standard-tier"]])
        let refusal = json(["error": ["code": 403, "status": "PERMISSION_DENIED", "details": [["reason": "SUBSCRIPTION_REQUIRED"]]]])
        exchange.answer = { url in url.path == "/v1internal:loadCodeAssist" ? (200, licensed) : (403, refusal) }
        #expect(await failure(of: provider) == .notServed, "SUBSCRIPTION_REQUIRED on the quota call is the same calm shutdown")
        #expect(exchange.seen.last?.body.isEmpty == true)

        exchange.answer = { url in url.path == "/v1internal:loadCodeAssist" ? (200, licensed) : (403, Data()) }
        #expect(await failure(of: provider) == .accessDenied)

        exchange.answer = { _ in (401, Data()) }
        #expect(await failure(of: provider) == .notSignedIn)

        exchange.answer = { url in url.path == "/v1internal:loadCodeAssist" ? (503, Data()) : (429, Data()) }
        #expect(await failure(of: provider) == .rateLimited)
    }
}

/// Which ProviderError a fetch ends in, by case; nil when it succeeds or fails some other way.
enum ProviderFailure: Equatable {
    case notSignedIn, tokenExpired, accessDenied, rateLimited, http, parse, unavailable, nothingYet, offline, apiKeyOnly, notServed
}

func failure(of provider: CodeAssistProvider) async -> ProviderFailure? {
    do {
        _ = try await provider.fetch()
        return nil
    } catch let error as ProviderError {
        switch error {
        case .notSignedIn: return .notSignedIn
        case .tokenExpired: return .tokenExpired
        case .accessDenied: return .accessDenied
        case .rateLimited: return .rateLimited
        case .http: return .http
        case .parse: return .parse
        case .unavailable: return .unavailable
        case .nothingYet: return .nothingYet
        case .offline: return .offline
        case .apiKeyOnly: return .apiKeyOnly
        case .notServed: return .notServed
        }
    } catch {
        return nil
    }
}


/// The inferred window length: confirmed by two resets the log has seen, guessed from the first reset otherwise.
@Suite struct AntigravityPeriodInference {
    init() { Localization.use(language: "en") }

    let now = DateParsing.iso8601("2026-09-01T12:00:00Z")!

    @Test func twoConsecutiveResetsFiveHoursApartConfirmASessionWindow() throws {
        let fiveHours = 5.0 * 3600
        let fiveAndAHalfHours = 5.5 * 3600
        let aWeekLessAnHour = 7.0 * 86400 - 3600
        let threeHours = 3.0 * 3600
        #expect(InferredPeriods.period(betweenResets: fiveHours) == Period.fiveHours)
        #expect(InferredPeriods.period(betweenResets: fiveAndAHalfHours) == Period.fiveHours)
        #expect(InferredPeriods.period(betweenResets: aWeekLessAnHour) == Period.week)
        #expect(InferredPeriods.period(betweenResets: threeHours) == nil)
        let first = now.addingTimeInterval(-fiveHours)
        let resetsFiveHoursApart = [first, first, now, now.addingTimeInterval(30)]
        #expect(InferredPeriods.confirmedPeriod(resets: resetsFiveHoursApart) == Period.fiveHours)
        #expect(InferredPeriods.confirmedPeriod(resets: [now]) == nil)
        let resetsTwoDaysApart = [now.addingTimeInterval(-2.0 * 86400), now]
        #expect(InferredPeriods.confirmedPeriod(resets: resetsTwoDaysApart) == nil)
        let inThreeHours = now.addingTimeInterval(threeHours)
        let inTwentyHours = now.addingTimeInterval(20.0 * 3600)
        let inFiveDays = now.addingTimeInterval(5.0 * 86400)
        #expect(InferredPeriods.provisionalPeriod(resetsAt: inThreeHours, now: now) == Period.fiveHours)
        #expect(InferredPeriods.provisionalPeriod(resetsAt: inTwentyHours, now: now) == Period.day)
        #expect(InferredPeriods.provisionalPeriod(resetsAt: inFiveDays, now: now) == Period.week)
        #expect(InferredPeriods.provisionalPeriod(resetsAt: now.addingTimeInterval(-1), now: now) == nil)
    }

    @Test func aConfirmedLengthGivesThePaceTickAndTheInferredTag() throws {
        let reset = now.addingTimeInterval(2 * 3600)
        let reading = UsageReading(tool: .antigravity, windows: [
            LimitWindow(id: "gemini_pro", label: "Gemini Pro", usedFraction: 0.6, resetsAt: reset, model: "Gemini Pro"),
            LimitWindow(id: "gemini_flash", label: "Gemini Flash", usedFraction: 0.1, resetsAt: now.addingTimeInterval(6 * 86400), note: "a · b", model: "Gemini Flash"),
        ], plan: nil, fetchedAt: now, observedAt: nil)
        let provisional = InferredPeriods.apply(reading, resets: [:], now: now)
        #expect(provisional.windows[0].periodDuration == nil)
        #expect(provisional.windows[0].note == "likely a 5-hour window")
        #expect(provisional.windows[0].source == .vendorEndpoint)
        #expect(provisional.windows[1].note == "a · b · likely a 7-day window")
        #expect(Pace.status(for: provisional.windows[0], now: now) == nil)
        let confirmed = InferredPeriods.apply(reading, resets: ["gemini_pro": [reset.addingTimeInterval(-5 * 3600), reset.addingTimeInterval(-5 * 3600)]], now: now)
        #expect(confirmed.windows[0].periodDuration == Period.fiveHours)
        #expect(confirmed.windows[0].source == .localEstimate)
        #expect(confirmed.windows[0].source.tag == "inferred")
        #expect(confirmed.windows[0].note == "5-hour window inferred from its resets")
        #expect(Pace.status(for: confirmed.windows[0], now: now) == .onTrack)
        #expect(confirmed.windows[1].periodDuration == nil)
        let other = InferredPeriods.apply(UsageReading(tool: .codex, windows: reading.windows, plan: nil, fetchedAt: now, observedAt: nil), resets: [:], now: now)
        #expect(other.windows[0].note == nil)
    }

    /// A window pinned at untouched across three polls while a hook reported the tool working is unverified: it
    /// loses its figure and says so. The count is by history, never by value, so a first read cannot fire it, a
    /// quiet Mac cannot fire it, and a meter that moves starts the count again.
    @Test func aMeterPinnedAtUntouchedWhileTheToolWorkedIsUnverified() throws {
        func reading(_ used: Double?, at time: Date) -> UsageReading {
            UsageReading(tool: .antigravity, windows: [LimitWindow(id: "gemini_pro", label: "Gemini Pro", usedFraction: used, resetsAt: time.addingTimeInterval(3600), note: "a")],
                         plan: nil, fetchedAt: time, observedAt: nil)
        }
        let minute = 300.0
        var runs: [String: CodeAssistStaleness.Run] = [:]
        for poll in 0..<3 {
            let at = now.addingTimeInterval(Double(poll) * minute)
            runs = CodeAssistStaleness.runs(after: reading(0, at: at), previous: runs, now: at)
            #expect(runs["gemini_pro"]?.count == poll + 1)
            #expect(runs["gemini_pro"]?.since == now)
        }
        let third = reading(0, at: now.addingTimeInterval(2 * minute))
        // Nothing worked, or the work predates the run: the figure stands.
        #expect(CodeAssistStaleness.unverified(third, runs: runs, activeSince: nil).windows[0].usedFraction == 0)
        #expect(CodeAssistStaleness.unverified(third, runs: runs, activeSince: now.addingTimeInterval(-60)).windows[0].usedFraction == 0)
        // The tool worked after the run began: unverified.
        let flagged = CodeAssistStaleness.unverified(third, runs: runs, activeSince: now.addingTimeInterval(minute))
        #expect(flagged.windows[0].usedFraction == nil)
        #expect(flagged.windows[0].note == "a · Unverified: read untouched across 3 polls while the tool was in use")
        #expect(flagged.windows[0].source == .localEstimate)
        #expect(flagged.windows[0].resetsAt == third.windows[0].resetsAt)
        // Two polls are not enough, and a figure that moves ends the run.
        let twoPolls = ["gemini_pro": CodeAssistStaleness.Run(count: 2, since: now)]
        #expect(CodeAssistStaleness.unverified(third, runs: twoPolls, activeSince: now.addingTimeInterval(minute)).windows[0].usedFraction == 0)
        let moved = CodeAssistStaleness.runs(after: reading(0.1, at: now), previous: runs, now: now)
        #expect(moved["gemini_pro"] == nil)
        #expect(CodeAssistStaleness.runs(after: reading(nil, at: now), previous: runs, now: now).isEmpty)
        let codex = UsageReading(tool: .codex, windows: third.windows, plan: nil, fetchedAt: now, observedAt: nil)
        #expect(CodeAssistStaleness.runs(after: codex, previous: runs, now: now) == runs)
        #expect(CodeAssistStaleness.unverified(codex, runs: runs, activeSince: now.addingTimeInterval(minute)).windows[0].usedFraction == 0)
        #expect(CodeAssistStaleness.readsBeforeUnverified == 3)
    }
}
