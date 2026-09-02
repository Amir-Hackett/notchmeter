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
        let reading = try AntigravityProvider.parseQuota(Data(json.utf8), plan: "Standard", now: Date(timeIntervalSince1970: 0))
        #expect(reading.tool == .antigravity)
        #expect(reading.plan == "Standard")
        #expect(reading.windows.map(\.label) == ["Gemini Pro", "Gemini Flash", "Gemini Flash Lite", "Claude Sonnet 4.5"])
        #expect(reading.windows.map(\.id) == ["gemini_pro", "gemini_flash", "gemini_flash_lite", "model_claude-sonnet-4-5"])
        #expect(reading.windows.map(\.model) == reading.windows.map(\.label))
        let used = reading.windows.map { $0.usedFraction ?? -1 }
        #expect(abs(used[0] - 0.4) < 1e-9)
        #expect(abs(used[1] - 0.1) < 1e-9)
        #expect(abs(used[2] - 0.2) < 1e-9)
        #expect(used[3] == 0.75)
        #expect(reading.windows[0].resetsAt == DateParsing.iso8601(resetsAt))
        #expect(reading.windows[3].resetsAt == DateParsing.iso8601("2026-09-01T17:00:00Z"))
        #expect(reading.windows[0].note == "Gemini 2.5 Pro · Gemini 3 Pro Preview")
        #expect(reading.windows[1].note == "1350 of 1500 left")
        #expect(reading.windows[2].note == nil)
        #expect(reading.windows.allSatisfy { $0.periodDuration == nil })
    }

    @Test func theTightestBucketOfATierSetsItsFigure() throws {
        let json = """
        {"buckets":[{"modelId":"gemini-2.5-pro","remainingFraction":0.6,"resetTime":"\(resetsAt)"},
                    {"modelId":"gemini-3-pro-preview","remainingFraction":0.3,"resetTime":"2026-09-01T20:00:00Z"},
                    {"modelId":"gemini-2.5-flash","remainingFraction":1.4}]}
        """
        let reading = try AntigravityProvider.parseQuota(Data(json.utf8), plan: nil)
        #expect(reading.windows.map(\.label) == ["Gemini Pro", "Gemini Flash"])
        #expect(abs((reading.windows[0].usedFraction ?? 0) - 0.7) < 1e-9)
        #expect(reading.windows[0].resetsAt == DateParsing.iso8601("2026-09-01T20:00:00Z"))
        #expect(reading.windows[1].usedFraction == 0)
        #expect(reading.windows[1].resetsAt == nil)
        #expect(reading.plan == nil)
    }

    @Test func rejectsResponsesWithoutUsableBuckets() {
        #expect(throws: ProviderError.self) { try AntigravityProvider.parseQuota(Data("{}".utf8), plan: nil) }
        #expect(throws: ProviderError.self) { try AntigravityProvider.parseQuota(Data(#"{"buckets":[{"modelId":"gemini-2.5-pro"}]}"#.utf8), plan: nil) }
        #expect(throws: ProviderError.self) { try AntigravityProvider.parseQuota(Data("not json".utf8), plan: nil) }
    }

    @Test func parsesTheCachedGoogleLogin() throws {
        let json = """
        {"access_token":"ya29.test","refresh_token":"1//refresh","scope":"https://www.googleapis.com/auth/cloud-platform",
         "token_type":"Bearer","id_token":"h.p.s","expiry_date":1756771200000}
        """
        let credentials = try AntigravityProvider.parseCredentials(Data(json.utf8))
        #expect(credentials.accessToken == "ya29.test")
        #expect(credentials.expiresAt == Date(timeIntervalSince1970: 1_756_771_200))
        #expect(try AntigravityProvider.parseCredentials(Data(#"{"access_token":"t"}"#.utf8)).expiresAt == nil)
        #expect(throws: ProviderError.self) { try AntigravityProvider.parseCredentials(Data(#"{"refresh_token":"r","access_token":""}"#.utf8)) }
        #expect(throws: ProviderError.self) { try AntigravityProvider.parseCredentials(Data("[]".utf8)) }
    }

    @Test func parsesTheAccountFromLoadCodeAssist() throws {
        let free = try AntigravityProvider.parseAccount(Data(#"{"currentTier":{"id":"free-tier","name":"Gemini Code Assist for individuals"},"cloudaicompanionProject":"managed-project-123","allowedTiers":[]}"#.utf8))
        #expect(free == AntigravityProvider.Account(project: "managed-project-123", plan: "Free", unsupported: false))

        let paid = try AntigravityProvider.parseAccount(Data(#"{"currentTier":{"id":"standard-tier"},"paidTier":{"name":"Gemini Code Assist in Google One AI Pro"},"cloudaicompanionProject":{"id":"p-1"}}"#.utf8))
        #expect(paid == AntigravityProvider.Account(project: "p-1", plan: "Google One AI Pro", unsupported: false))

        let shutdown = try AntigravityProvider.parseAccount(Data("""
        {"allowedTiers":[{"id":"standard-tier","name":"Gemini Code Assist","userDefinedCloudaicompanionProject":true,"isDefault":true}],
         "ineligibleTiers":[{"reasonCode":"UNSUPPORTED_CLIENT","reasonMessage":"This client is no longer supported for Gemini Code Assist for individuals.","tierId":"free-tier","tierName":"Gemini Code Assist for individuals"}]}
        """.utf8))
        #expect(shutdown == AntigravityProvider.Account(project: nil, plan: nil, unsupported: true))

        let licensed = try AntigravityProvider.parseAccount(Data(#"{"currentTier":{"id":"standard-tier"},"ineligibleTiers":[{"reasonCode":"UNSUPPORTED_CLIENT","tierId":"free-tier"}]}"#.utf8))
        #expect(licensed.plan == "Standard")
        #expect(!licensed.unsupported)
        #expect(try AntigravityProvider.parseAccount(Data("{}".utf8)) == AntigravityProvider.Account(project: nil, plan: nil, unsupported: false))
    }

    @Test func namesPlansAndModels() {
        #expect(AntigravityProvider.planName(tier: ["id": "legacy-tier"], paidTier: nil) == "Legacy")
        #expect(AntigravityProvider.planName(tier: ["id": "enterprise-tier"], paidTier: nil) == "Enterprise")
        #expect(AntigravityProvider.planName(tier: ["name": "Something"], paidTier: nil) == "Something")
        #expect(AntigravityProvider.planName(tier: ["id": "free-tier"], paidTier: ["name": "Plus"]) == "Plus")
        #expect(AntigravityProvider.planName(tier: nil, paidTier: ["name": " "]) == nil)

        #expect(ModelNames.display("gemini-2.5-pro") == "Gemini 2.5 Pro")
        #expect(ModelNames.display("gemini-3-pro-preview") == "Gemini 3 Pro Preview")
        #expect(ModelNames.display("gemini-2.5-flash-lite") == "Gemini 2.5 Flash Lite")
        #expect(ModelNames.display("claude-sonnet-4-5") == "Claude Sonnet 4.5")
        #expect(ModelNames.display("gpt-oss-120b") == "GPT OSS 120B")
        #expect(ModelNames.display("claude-opus-4-1-20250805") == "Claude Opus 4.1 20250805")
        #expect(AntigravityProvider.pool(for: "gemini-embedding-001").label == "Gemini Embedding 001")
        #expect(AntigravityProvider.pool(for: "GEMINI-3.1-PRO").id == "gemini_pro")
    }

    @Test func recognisesTheSubscriptionRequiredRefusal() {
        let refusal = """
        {"error":{"code":403,"message":"You do not have a valid license of this product.","status":"PERMISSION_DENIED",
         "details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"SUBSCRIPTION_REQUIRED","domain":"cloudaicompanion.googleapis.com"}]}}
        """
        #expect(AntigravityProvider.isSubscriptionRequired(Data(refusal.utf8)))
        #expect(!AntigravityProvider.isSubscriptionRequired(Data(#"{"error":{"code":403,"status":"PERMISSION_DENIED"}}"#.utf8)))
        #expect(!AntigravityProvider.isSubscriptionRequired(Data()))
    }

    @Test func installDetectionAndSignInStates() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-antigravity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let gemini = scratch.appendingPathComponent(".gemini")
        let app = scratch.appendingPathComponent("Antigravity.app")
        let home = scratch.appendingPathComponent(".antigravity")
        try FileManager.default.createDirectory(at: gemini, withIntermediateDirectories: true)

        let provider = AntigravityProvider(geminiHome: gemini, applicationBundle: app, antigravityHome: home)
        #expect(!provider.isInstalled())
        #expect(await failure(of: provider) == .notSignedIn)

        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        #expect(provider.isInstalled())
        try FileManager.default.removeItem(at: home)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        #expect(provider.isInstalled())
        try FileManager.default.removeItem(at: app)
        #expect(!provider.isInstalled())

        let expired = Int(Date().addingTimeInterval(-3600).timeIntervalSince1970 * 1000)
        try Data(#"{"access_token":"ya29.old","expiry_date":\#(expired)}"#.utf8).write(to: gemini.appendingPathComponent("oauth_creds.json"))
        #expect(provider.isInstalled())
        #expect(await failure(of: provider) == .tokenExpired)

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
    let provider: AntigravityProvider
    let exchange = Exchange()

    init() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-antigravity-\(UUID().uuidString)")
        let gemini = scratch.appendingPathComponent(".gemini")
        try FileManager.default.createDirectory(at: gemini, withIntermediateDirectories: true)
        let expiry = Int(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        try Data(#"{"access_token":"ya29.live","refresh_token":"1//r","expiry_date":\#(expiry)}"#.utf8).write(to: gemini.appendingPathComponent("oauth_creds.json"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        provider = AntigravityProvider(session: URLSession(configuration: configuration), geminiHome: gemini,
                                       applicationBundle: scratch.appendingPathComponent("none.app"), antigravityHome: scratch.appendingPathComponent("none"))
        StubProtocol.exchange = exchange
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
        #expect(reading.windows.map(\.label) == ["Gemini Pro"])
        #expect(reading.windows[0].usedFraction == 0.25)

        let seen = exchange.seen
        #expect(seen.map { $0.request.url } == [AntigravityProvider.codeAssistURL, AntigravityProvider.quotaURL])
        #expect(seen.map { $0.body as NSDictionary } == [
            ["metadata": ["ideType": "GEMINI_CLI", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]] as NSDictionary,
            ["project": "managed-project-123"] as NSDictionary,
        ])
        for (request, _) in seen {
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ya29.live")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == AppInfo.userAgent)
        }
    }

    @Test func aPersonalAccountIsToldAboutTheShutdownWithoutAQuotaCall() async throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let unsupported = json(["ineligibleTiers": [["reasonCode": "UNSUPPORTED_CLIENT", "tierId": "free-tier"]]])
        exchange.answer = { url in url.path == "/v1internal:loadCodeAssist" ? (200, unsupported) : (500, Data()) }
        #expect(await failure(of: provider) == .unavailable)
        #expect(exchange.seen.map { $0.request.url } == [AntigravityProvider.codeAssistURL])
    }

    @Test func refusalsAreMappedToTheirCauses() async throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let licensed = json(["currentTier": ["id": "standard-tier"]])
        let refusal = json(["error": ["code": 403, "status": "PERMISSION_DENIED", "details": [["reason": "SUBSCRIPTION_REQUIRED"]]]])
        exchange.answer = { url in url.path == "/v1internal:loadCodeAssist" ? (200, licensed) : (403, refusal) }
        #expect(await failure(of: provider) == .unavailable)
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
    case notSignedIn, tokenExpired, accessDenied, rateLimited, http, parse, unavailable, nothingYet, offline
}

func failure(of provider: AntigravityProvider) async -> ProviderFailure? {
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
        }
    } catch {
        return nil
    }
}
