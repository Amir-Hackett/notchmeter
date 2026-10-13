import Foundation
import Testing
@testable import Notchmeter

/// Codex fetching against OpenAI's backend usage endpoint, tested through an ephemeral URLSession stub.
@Suite(.serialized) struct CodexFetching {
    init() { Localization.use(language: "en") }

    final class CodexStubProtocol: URLProtocol {
        nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Result<(status: Int, headers: [String: String], body: Data), URLError>)?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            switch handler(request) {
            case .success(let result):
                let response = HTTPURLResponse(url: request.url!, statusCode: result.status, httpVersion: nil, headerFields: result.headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: result.body)
                client?.urlProtocolDidFinishLoading(self)
            case .failure(let error):
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    func session(handler: @escaping @Sendable (URLRequest) -> Result<(status: Int, headers: [String: String], body: Data), URLError>) -> URLSession {
        CodexStubProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CodexStubProtocol.self]
        return URLSession(configuration: config)
    }

    func makeDir(token: String = "valid-token", accountID: String? = "acct_test123") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-codex-fetch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var tokensDict: [String: Any] = ["access_token": token]
        if let accountID {
            tokensDict["account_id"] = accountID
        }
        let authObj: [String: Any] = ["tokens": tokensDict]
        let data = try JSONSerialization.data(withJSONObject: authObj)
        try data.write(to: dir.appendingPathComponent("auth.json"))
        return dir
    }

    func makeJWT(expiresAt: Date) -> String {
        let payload = #"{"exp":\#(Int(expiresAt.timeIntervalSince1970))}"#
        let encoded = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJub25lIn0.\(encoded)."
    }

    func writeRollout(in dir: URL, filename: String = "rollout-2026-10-08T00-00-00-abc.jsonl",
                      usedPrimary: Double = 25.0, usedSecondary: Double = 10.0,
                      resetsAt: Double = 1_900_000_000) throws {
        let sessions = dir.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let rollout = sessions.appendingPathComponent(filename)
        let line = """
        {"timestamp":"2026-10-08T00:00:00.000Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":\(usedPrimary),"window_minutes":300,"resets_at":\(resetsAt)},"secondary":{"used_percent":\(usedSecondary),"window_minutes":10080,"resets_at":\(resetsAt)},"plan_type":"plus"}}}
        """
        try line.write(to: rollout, atomically: true, encoding: .utf8)
    }

    @Test func fetchSucceedsOn200WithWindowsAndAuthHeaders() async throws {
        let dir = try makeDir(token: "sk-access-xyz", accountID: "acct_target_456")
        defer { try? FileManager.default.removeItem(at: dir) }

        let json = """
        {"plan_type":"plus",
         "rate_limit":{"primary_window":{"used_percent":15,"reset_at":1759352940,"limit_window_seconds":18000},
                       "secondary_window":{"used_percent":5,"reset_at":1759752940,"limit_window_seconds":604800}}}
        """

        let s = session { req in
            #expect(req.url == CodexProvider.usageURL)
            #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-access-xyz")
            #expect(req.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct_target_456")
            #expect(req.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(req.value(forHTTPHeaderField: "User-Agent") == AppInfo.userAgent)
            return .success((status: 200, headers: ["Content-Type": "application/json"], body: Data(json.utf8)))
        }

        let provider = CodexProvider(session: s, root: dir, readResetCredits: { false })
        let reading = try await provider.fetch()
        #expect(reading.tool == .codex)
        #expect(reading.plan == "Plus")
        #expect(reading.windows.count == 2)
        #expect(reading.windows[0].id == "session")
        #expect(reading.windows[0].usedFraction == 0.15)
        #expect(reading.windows[1].id == "weekly")
        #expect(reading.windows[1].usedFraction == 0.05)
    }

    @Test func fetchIncludesResetCreditsWhenOptedIn() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let usageJson = """
        {"plan_type":"plus",
         "rate_limit":{"primary_window":{"used_percent":20,"reset_at":1759352940,"limit_window_seconds":18000},
                       "secondary_window":{"used_percent":10,"reset_at":1759752940,"limit_window_seconds":604800}}}
        """
        let futureExpiry = Date().addingTimeInterval(86400 * 2).timeIntervalSince1970
        let creditsJson = """
        {"credits":[{"count":1,"type":"full_reset","expires_at":\(futureExpiry)}]}
        """

        let s = session { req in
            if req.url == CodexProvider.usageURL {
                return .success((status: 200, headers: ["Content-Type": "application/json"], body: Data(usageJson.utf8)))
            } else if req.url == CodexProvider.resetCreditsURL {
                #expect(req.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
                return .success((status: 200, headers: ["Content-Type": "application/json"], body: Data(creditsJson.utf8)))
            } else {
                return .failure(URLError(.badURL))
            }
        }

        let provider = CodexProvider(session: s, root: dir, readResetCredits: { true })
        let reading = try await provider.fetch()
        #expect(reading.windows.count == 3)
        let resetWindow = try #require(reading.windows.first { $0.id == "reset_credits" })
        #expect(resetWindow.label == "Reset credits")
        #expect(resetWindow.note?.contains("Full Reset credit expires in") == true)
    }

    @Test func fetchOmitsResetCreditsWhenOptedOut() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let usageJson = """
        {"plan_type":"plus",
         "rate_limit":{"primary_window":{"used_percent":20,"reset_at":1759352940,"limit_window_seconds":18000}}}
        """

        let s = session { req in
            #expect(req.url == CodexProvider.usageURL, "resetCreditsURL must not be queried when opted out")
            return .success((status: 200, headers: ["Content-Type": "application/json"], body: Data(usageJson.utf8)))
        }

        let provider = CodexProvider(session: s, root: dir, readResetCredits: { false })
        let reading = try await provider.fetch()
        #expect(!reading.windows.contains { $0.id == "reset_credits" })
    }

    @Test func fetchSurvivesResetCreditsHttpFailure() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let usageJson = """
        {"plan_type":"plus",
         "rate_limit":{"primary_window":{"used_percent":20,"reset_at":1759352940,"limit_window_seconds":18000}}}
        """

        let s = session { req in
            if req.url == CodexProvider.usageURL {
                return .success((status: 200, headers: ["Content-Type": "application/json"], body: Data(usageJson.utf8)))
            } else {
                return .success((status: 500, headers: [:], body: Data("server error".utf8)))
            }
        }

        let provider = CodexProvider(session: s, root: dir, readResetCredits: { true })
        let reading = try await provider.fetch()
        #expect(!reading.windows.contains { $0.id == "reset_credits" })
        #expect(reading.windows[0].usedFraction == 0.20)
    }

    @Test func fetchFallsBackToLocalRolloutOnUnparseable200() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeRollout(in: dir, usedPrimary: 42.0, usedSecondary: 12.0)

        let s = session { _ in
            .success((status: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"rate_limit":null}"#.utf8)))
        }

        let provider = CodexProvider(session: s, root: dir, readResetCredits: { false })
        let reading = try await provider.fetch()
        #expect(reading.windows.allSatisfy { $0.source == .localSnapshot })
        #expect(reading.windows[0].usedFraction == 0.42)
        #expect(reading.windows[1].usedFraction == 0.12)
    }

    @Test func fetchThrowsParseOnUnparseable200WhenNoRollout() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let s = session { _ in
            .success((status: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"rate_limit":null}"#.utf8)))
        }

        let provider = CodexProvider(session: s, root: dir, readResetCredits: { false })
        do {
            _ = try await provider.fetch()
            Issue.record("Expected parse error when 200 is unreadable and no rollout exists")
        } catch let error as ProviderError {
            #expect(!error.needsAttention)
            switch error {
            case .parse: break
            default: Issue.record("Expected .parse, got \(error)")
            }
        }
    }

    @Test func fetchFallsBackToLocalRolloutOn401Refusal() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeRollout(in: dir, usedPrimary: 33.0, usedSecondary: 8.0)

        let s = session { _ in .success((status: 401, headers: [:], body: Data("Unauthorized".utf8))) }

        let provider = CodexProvider(session: s, root: dir, readResetCredits: { false })
        let reading = try await provider.fetch()
        #expect(reading.windows.allSatisfy { $0.source == .localSnapshot })
        #expect(reading.windows[0].usedFraction == 0.33)
    }

    @Test func fetchThrowsTokenExpiredOn401RefusalWhenNoRollout() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let s = session { _ in .success((status: 401, headers: [:], body: Data("Unauthorized".utf8))) }

        let provider = CodexProvider(session: s, root: dir, readResetCredits: { false })
        do {
            _ = try await provider.fetch()
            Issue.record("Expected tokenExpired on 401 refusal with no rollout")
        } catch let error as ProviderError {
            #expect(error.needsAttention)
            switch error {
            case .tokenExpired: break
            default: Issue.record("Expected .tokenExpired, got \(error)")
            }
        }
    }

    @Test func fetchFallsBackToLocalRolloutOn403Refusal() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeRollout(in: dir, usedPrimary: 55.0, usedSecondary: 22.0)

        let s = session { _ in .success((status: 403, headers: [:], body: Data("Forbidden".utf8))) }

        let provider = CodexProvider(session: s, root: dir, readResetCredits: { false })
        let reading = try await provider.fetch()
        #expect(reading.windows.allSatisfy { $0.source == .localSnapshot })
        #expect(reading.windows[0].usedFraction == 0.55)
    }

    @Test func fetchThrowsTokenExpiredOn403RefusalWhenNoRollout() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let s = session { _ in .success((status: 403, headers: [:], body: Data("Forbidden".utf8))) }

        let provider = CodexProvider(session: s, root: dir, readResetCredits: { false })
        do {
            _ = try await provider.fetch()
            Issue.record("Expected tokenExpired on 403 refusal with no rollout")
        } catch let error as ProviderError {
            #expect(error.needsAttention)
            switch error {
            case .tokenExpired: break
            default: Issue.record("Expected .tokenExpired, got \(error)")
            }
        }
    }

    @Test func fetchThrowsRateLimitedOn429EvenIfRolloutExists() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeRollout(in: dir, usedPrimary: 10.0, usedSecondary: 5.0)

        let s = session { _ in .success((status: 429, headers: ["Retry-After": "90"], body: Data("Rate limited".utf8))) }

        let provider = CodexProvider(session: s, root: dir, readResetCredits: { false })
        do {
            _ = try await provider.fetch()
            Issue.record("Expected rateLimited on 429 even when rollout is available")
        } catch let error as ProviderError {
            #expect(!error.needsAttention)
            #expect(error == .rateLimited(retryAfter: 90))
        }
    }

    @Test func fetchFallsBackToLocalRolloutOn500() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeRollout(in: dir, usedPrimary: 60.0, usedSecondary: 15.0)

        let s = session { _ in .success((status: 500, headers: [:], body: Data("Internal Server Error".utf8))) }

        let provider = CodexProvider(session: s, root: dir, readResetCredits: { false })
        let reading = try await provider.fetch()
        #expect(reading.windows.allSatisfy { $0.source == .localSnapshot })
        #expect(reading.windows[0].usedFraction == 0.6)
    }

    @Test func fetchThrowsHttpOn500WhenNoRollout() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let s = session { _ in .success((status: 500, headers: [:], body: Data("Internal Server Error".utf8))) }

        let provider = CodexProvider(session: s, root: dir, readResetCredits: { false })
        do {
            _ = try await provider.fetch()
            Issue.record("Expected http error on 500 with no rollout")
        } catch let error as ProviderError {
            #expect(!error.needsAttention)
            switch error {
            case .http(let code, _): #expect(code == 500)
            default: Issue.record("Expected .http(500), got \(error)")
            }
        }
    }

    @Test func fetchFallsBackToLocalRolloutOnNetworkFailure() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeRollout(in: dir, usedPrimary: 70.0, usedSecondary: 30.0)

        let s = session { _ in .failure(URLError(.notConnectedToInternet)) }

        let provider = CodexProvider(session: s, root: dir, readResetCredits: { false })
        let reading = try await provider.fetch()
        #expect(reading.windows.allSatisfy { $0.source == .localSnapshot })
        #expect(reading.windows[0].usedFraction == 0.7)
    }

    @Test func fetchThrowsOfflineOnNetworkFailureWhenNoRollout() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let s = session { _ in .failure(URLError(.notConnectedToInternet)) }

        let provider = CodexProvider(session: s, root: dir, readResetCredits: { false })
        do {
            _ = try await provider.fetch()
            Issue.record("Expected offline error on network disconnect with no rollout")
        } catch let error as ProviderError {
            #expect(!error.needsAttention)
            switch error {
            case .offline: break
            default: Issue.record("Expected .offline, got \(error)")
            }
        }
    }

    @Test func fetchThrowsUnavailableOnNonOfflineNetworkFailureWhenNoRollout() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // URLError(.badServerResponse) is not in the offline() family
        let s = session { _ in .failure(URLError(.badServerResponse)) }

        let provider = CodexProvider(session: s, root: dir, readResetCredits: { false })
        do {
            _ = try await provider.fetch()
            Issue.record("Expected unavailable error on badServerResponse with no rollout")
        } catch let error as ProviderError {
            #expect(!error.needsAttention)
            switch error {
            case .unavailable: break
            default: Issue.record("Expected .unavailable, got \(error)")
            }
        }
    }

    @Test func fetchThrowsNotSignedInWhenAuthJsonMissing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-codex-noauth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let s = session { _ in .failure(URLError(.cancelled)) }
        let provider = CodexProvider(session: s, root: dir, readResetCredits: { false })
        do {
            _ = try await provider.fetch()
            Issue.record("Expected notSignedIn when auth.json does not exist")
        } catch let error as ProviderError {
            #expect(error.needsAttention)
            switch error {
            case .notSignedIn: break
            default: Issue.record("Expected .notSignedIn, got \(error)")
            }
        }
    }

    @Test func fetchFallsBackToLocalRolloutWhenTokenIsExpired() async throws {
        let expiredToken = makeJWT(expiresAt: Date().addingTimeInterval(-120))
        let dir = try makeDir(token: expiredToken)
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeRollout(in: dir, usedPrimary: 80.0, usedSecondary: 40.0)

        // Stub would fail if contacted, proving network is never called
        let s = session { _ in .failure(URLError(.badURL)) }

        let provider = CodexProvider(session: s, root: dir, readResetCredits: { false })
        let reading = try await provider.fetch()
        #expect(reading.windows.allSatisfy { $0.source == .localSnapshot })
        #expect(reading.windows[0].usedFraction == 0.8)
    }

    @Test func fetchThrowsTokenExpiredWhenTokenIsExpiredAndNoRollout() async throws {
        let expiredToken = makeJWT(expiresAt: Date().addingTimeInterval(-120))
        let dir = try makeDir(token: expiredToken)
        defer { try? FileManager.default.removeItem(at: dir) }

        let s = session { _ in .failure(URLError(.badURL)) }

        let provider = CodexProvider(session: s, root: dir, readResetCredits: { false })
        do {
            _ = try await provider.fetch()
            Issue.record("Expected tokenExpired when JWT is past expiration and no rollout exists")
        } catch let error as ProviderError {
            #expect(error.needsAttention)
            switch error {
            case .tokenExpired: break
            default: Issue.record("Expected .tokenExpired, got \(error)")
            }
        }
    }

    @Test func isInstalledChecksDirectoryExistence() {
        let existing = FileManager.default.temporaryDirectory
        let providerExisting = CodexProvider(root: existing)
        #expect(providerExisting.isInstalled() == true)

        let nonexistent = FileManager.default.temporaryDirectory.appendingPathComponent("nonexistent-\(UUID().uuidString)")
        let providerNonexistent = CodexProvider(root: nonexistent)
        #expect(providerNonexistent.isInstalled() == false)
    }
}

/// Tests for Codex local rollout parsing and file management.
@Suite struct CodexRolloutDetails {
    init() { Localization.use(language: "en") }

    @Test func readingFromRolloutCalculatesResetsInSeconds() throws {
        let observedAt = Date(timeIntervalSince1970: 1_756_700_000)
        let now = Date(timeIntervalSince1970: 1_756_701_000)
        let limits: [String: Any] = [
            "primary": [
                "used_percent": 25.0,
                "window_minutes": 300,
                "resets_in_seconds": 7200,
            ],
            "plan_type": "plus"
        ]

        let reading = try CodexProvider.reading(from: limits, observedAt: observedAt, now: now)
        let sessionWindow = try #require(reading.windows.first { $0.id == "session" })
        #expect(sessionWindow.usedFraction == 0.25)
        #expect(sessionWindow.resetsAt == observedAt.addingTimeInterval(7200))
        #expect(sessionWindow.source == .localSnapshot)
    }

    @Test func readingFromRolloutMarksPassedResetsAsReset() throws {
        let observedAt = Date(timeIntervalSince1970: 1_756_700_000)
        let now = Date(timeIntervalSince1970: 1_756_750_000) // After resets_at
        let limits: [String: Any] = [
            "primary": [
                "used_percent": 75.0,
                "window_minutes": 300,
                "resets_at": 1_756_710_000,
            ],
            "plan_type": "pro"
        ]

        let reading = try CodexProvider.reading(from: limits, observedAt: observedAt, now: now)
        let sessionWindow = try #require(reading.windows.first { $0.id == "session" })
        #expect(sessionWindow.usedFraction == 0)
        #expect(sessionWindow.note == "Reset since Codex last reported")
    }

    @Test func readingFromRolloutInsertsSessionAndWeeklyPlaceholders() throws {
        let observedAt = Date(timeIntervalSince1970: 1_756_700_000)
        let now = Date(timeIntervalSince1970: 1_756_700_000)
        // Only secondary window present
        let limits: [String: Any] = [
            "secondary": [
                "used_percent": 15.0,
                "window_minutes": 10080,
                "resets_at": 1_757_000_000,
            ]
        ]

        let reading = try CodexProvider.reading(from: limits, observedAt: observedAt, now: now)
        #expect(reading.windows.count == 2)
        #expect(reading.windows[0].id == "session")
        #expect(reading.windows[0].usedFraction == nil)
        #expect(reading.windows[0].note == "No data")
        #expect(reading.windows[1].id == "weekly")
        #expect(reading.windows[1].usedFraction == 0.15)
    }

    @Test func latestRateLimitsPicksNewestLineWithUsedPercent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-codex-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("rollout.jsonl")
        let lines = [
            #"{"timestamp":"2026-10-08T01:00:00.000Z","type":"event_msg","payload":{"rate_limits":{"primary":{"used_percent":10,"window_minutes":300},"secondary":{"used_percent":5,"window_minutes":10080}}}}"#,
            #"{"timestamp":"2026-10-08T02:00:00.000Z","type":"event_msg","payload":{"rate_limits":{"primary":{"used_percent":25,"window_minutes":300},"secondary":{"used_percent":12,"window_minutes":10080}}}}"#,
            // A newer line without used_percent (e.g. only credits or empty windows)
            #"{"timestamp":"2026-10-08T03:00:00.000Z","type":"event_msg","payload":{"rate_limits":{"primary":{"used_percent":null},"secondary":null}}}"#,
        ]
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)

        let found = try #require(CodexProvider.latestRateLimits(in: file))
        #expect(found.observedAt == DateParsing.iso8601("2026-10-08T02:00:00.000Z"))
        let primary = found.limits["primary"] as? [String: Any]
        #expect(primary?["used_percent"] as? Int == 25)
    }

    @Test func recentRolloutsSortsDescendingByModificationDateAndCaps() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-codex-sort-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var createdURLs: [URL] = []
        let now = Date()
        for i in 1...5 {
            let url = dir.appendingPathComponent("rollout-\(i).jsonl")
            try "line".write(to: url, atomically: true, encoding: .utf8)
            // Modify file modification dates with 10s intervals
            let mdate = now.addingTimeInterval(Double(i * 10))
            try FileManager.default.setAttributes([.modificationDate: mdate], ofItemAtPath: url.path)
            createdURLs.append(url)
        }
        // Non-jsonl file should be excluded
        let ignoreURL = dir.appendingPathComponent("ignored.txt")
        try "ignore".write(to: ignoreURL, atomically: true, encoding: .utf8)

        let recent = CodexProvider.recentRollouts(in: dir, limit: 3)
        #expect(recent.count == 3)
        #expect(recent[0].lastPathComponent == "rollout-5.jsonl")
        #expect(recent[1].lastPathComponent == "rollout-4.jsonl")
        #expect(recent[2].lastPathComponent == "rollout-3.jsonl")
    }
}

/// Tests for reset credits JSON parsing and window generation.
@Suite struct CodexResetCreditsParsing {
    init() { Localization.use(language: "en") }

    @Test func parsesVariedFieldNamesAndEpochUnits() {
        let json = """
        {"credits":[
          {"kind":"special_reset","quantity":2,"expiration":"2026-11-01T00:00:00Z"},
          {"type":"full_reset","remaining":3,"expiry":1759352940000},
          {"credit_type":"boost","count":1,"expires_at":1759352940}
        ]}
        """
        let credits = CodexProvider.parseResetCredits(Data(json.utf8))
        #expect(credits.count == 3)
        #expect(credits[0].kind == "special_reset")
        #expect(credits[0].count == 2)
        #expect(credits[0].expiresAt == DateParsing.iso8601("2026-11-01T00:00:00Z"))

        #expect(credits[1].kind == "full_reset")
        #expect(credits[1].count == 3)
        #expect(credits[1].expiresAt == Date(timeIntervalSince1970: 1_759_352_940))

        #expect(credits[2].kind == "boost")
        #expect(credits[2].count == 1)
        #expect(credits[2].expiresAt == Date(timeIntervalSince1970: 1_759_352_940))
    }

    @Test func filtersExpiredCreditsAndFormatsCountdown() throws {
        let now = Date(timeIntervalSince1970: 1_759_000_000)
        let past = now.addingTimeInterval(-3600)
        let future = now.addingTimeInterval(86400 * 3) // 3 days

        let credits = [
            CodexProvider.ResetCredit(count: 1, expiresAt: past, kind: "expired_boost"),
            CodexProvider.ResetCredit(count: 2, expiresAt: future, kind: "full_reset")
        ]

        let window = try #require(CodexProvider.resetCreditWindow(credits, now: now))
        #expect(window.id == "reset_credits")
        #expect(window.resetsAt == future)
        #expect(window.note?.contains("Full Reset credit expires in 3d") == true)

        let allExpired = [CodexProvider.ResetCredit(count: 1, expiresAt: past, kind: "old")]
        #expect(CodexProvider.resetCreditWindow(allExpired, now: now) == nil)
    }

    @Test func handlesCreditsWithoutExpiryDate() throws {
        let now = Date(timeIntervalSince1970: 1_759_000_000)
        let credits = [
            CodexProvider.ResetCredit(count: 3, expiresAt: nil, kind: "extra_turn")
        ]

        let window = try #require(CodexProvider.resetCreditWindow(credits, now: now))
        #expect(window.id == "reset_credits")
        #expect(window.resetsAt == nil)
        #expect(window.note?.contains("3 Extra Turn credit(s)") == true)
    }
}
