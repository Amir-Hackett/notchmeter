import Foundation
import Testing
@testable import Notchmeter

/// Claude Code fetching against Anthropic's usage endpoint, tested through an ephemeral URLSession stub.
@Suite(.serialized) struct ClaudeFetching {
    init() { Localization.use(language: "en") }

    final class ClaudeStubProtocol: URLProtocol {
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
        ClaudeStubProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ClaudeStubProtocol.self]
        return URLSession(configuration: config)
    }

    func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-claude-fetch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let creds = #"{"claudeAiOauth":{"accessToken":"test-token","expiresAt":1900000000000,"subscriptionType":"max","rateLimitTier":"default_claude_max_5x"}}"#
        try creds.write(to: dir.appendingPathComponent(".credentials.json"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test func fetchSucceedsOn200WithWindows() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let json = """
        {"five_hour":{"utilization":25,"resets_at":"2026-10-07T14:00:00Z"},
         "seven_day":{"utilization":10,"resets_at":"2026-10-14T00:00:00Z"}}
        """
        let s = session { req in
            #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            #expect(req.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
            return .success((status: 200, headers: ["Content-Type": "application/json"], body: Data(json.utf8)))
        }

        let provider = ClaudeProvider(session: s, configDir: dir)
        let reading = try await provider.fetch()
        #expect(reading.tool == .claude)
        #expect(reading.plan == "Max 5x")
        #expect(reading.windows.count == 2)
        #expect(reading.windows[0].id == "five_hour")
        #expect(reading.windows[0].usedFraction == 0.25)
        #expect(reading.windows[1].id == "seven_day")
        #expect(reading.windows[1].usedFraction == 0.10)
    }

    @Test func fetchFallsBackToRateLimitHeadersOnUnreadable200() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let headers = [
            "Content-Type": "application/json",
            "anthropic-ratelimit-unified-5h-utilization": "0.45",
            "anthropic-ratelimit-unified-5h-reset": "1786518600",
        ]
        let s = session { _ in
            .success((status: 200, headers: headers, body: Data("<html>invalid json</html>".utf8)))
        }

        let provider = ClaudeProvider(session: s, configDir: dir)
        let reading = try await provider.fetch()
        #expect(reading.windows.count == 1)
        #expect(reading.windows[0].id == "five_hour")
        #expect(reading.windows[0].usedFraction == 0.45)
        #expect(reading.windows[0].source == .rateLimitHeaders)
    }

    @Test func fetchThrowsParseWhen200IsUnreadableAndNoHeaders() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let s = session { _ in
            .success((status: 200, headers: ["Content-Type": "application/json"], body: Data("<html>empty</html>".utf8)))
        }
        let provider = ClaudeProvider(session: s, configDir: dir)
        do {
            _ = try await provider.fetch()
            Issue.record("expected parse error")
        } catch let error as ProviderError {
            #expect(!error.needsAttention)
            #expect(!error.isCalm)
        }
    }

    @Test func fetchMaps401And403ToNotSignedIn() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        for status in [401, 403] {
            let s = session { _ in .success((status: status, headers: [:], body: Data("refused".utf8))) }
            let provider = ClaudeProvider(session: s, configDir: dir)
            do {
                _ = try await provider.fetch()
                Issue.record("expected refusal")
            } catch let error as ProviderError {
                #expect(error.needsAttention)
                #expect(error == .notSignedIn(L("Claude Code's login was refused. Run Claude Code once to refresh it")))
            }
        }
    }

    @Test func fetchMaps429ToRateLimitedWithRetryAfter() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let s = session { _ in .success((status: 429, headers: ["Retry-After": "120"], body: Data())) }
        let provider = ClaudeProvider(session: s, configDir: dir)
        do {
            _ = try await provider.fetch()
            Issue.record("expected rate limit")
        } catch let error as ProviderError {
            #expect(!error.needsAttention)
            #expect(error == .rateLimited(retryAfter: 120))
        }
    }

    @Test func fetchMaps500WithHeadersToHeaderWindowsAndWithoutToHttpError() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let withHeaders = session { _ in
            .success((status: 500, headers: [
                "anthropic-ratelimit-unified-5h-utilization": "0.33",
                "anthropic-ratelimit-unified-5h-reset": "1786518600",
            ], body: Data()))
        }
        let providerWithHeaders = ClaudeProvider(session: withHeaders, configDir: dir)
        let reading = try await providerWithHeaders.fetch()
        #expect(reading.windows.count == 1)
        #expect(reading.windows[0].usedFraction == 0.33)

        let withoutHeaders = session { _ in .success((status: 502, headers: [:], body: Data())) }
        let providerWithout = ClaudeProvider(session: withoutHeaders, configDir: dir)
        do {
            _ = try await providerWithout.fetch()
            Issue.record("expected http error")
        } catch let error as ProviderError {
            #expect(error == .http(502, L("usage endpoint answered")))
            #expect(!error.needsAttention)
        }
    }

    @Test func fetchThrowsOfflineOnNetworkFailure() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let s = session { _ in .failure(URLError(.notConnectedToInternet)) }
        let provider = ClaudeProvider(session: s, configDir: dir)
        do {
            _ = try await provider.fetch()
            Issue.record("expected offline error")
        } catch let error as ProviderError {
            #expect(!error.needsAttention)
            #expect(!error.isCalm)
            #expect(error == .offline(L("Offline, retrying")))
        }
    }

    @Test func fetchThrowsOfflineOnURLErrorHostOrTimeout() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        for code in [URLError.Code.timedOut, URLError.Code.cannotFindHost, URLError.Code.networkConnectionLost] {
            let s = session { _ in .failure(URLError(code)) }
            let provider = ClaudeProvider(session: s, configDir: dir)
            do {
                _ = try await provider.fetch()
                Issue.record("expected offline error for \(code)")
            } catch let error as ProviderError {
                #expect(!error.needsAttention)
                #expect(error == .offline(L("Offline, retrying")))
            }
        }
    }

    @Test func fetchThrowsTokenExpiredWhenExpiryIsInPast() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-claude-expired-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let pastExpiry = Int((Date().timeIntervalSince1970 - 100) * 1000)
        let creds = #"{"claudeAiOauth":{"accessToken":"token","expiresAt":\#(pastExpiry)}}"#
        try creds.write(to: dir.appendingPathComponent(".credentials.json"), atomically: true, encoding: .utf8)

        let s = session { _ in .success((status: 200, headers: [:], body: Data())) }
        let provider = ClaudeProvider(session: s, configDir: dir)
        do {
            _ = try await provider.fetch()
            Issue.record("expected token expired")
        } catch let error as ProviderError {
            #expect(error.needsAttention)
            #expect(error == .tokenExpired(L("Claude Code's login has expired. Run claude in a terminal once so it refreshes — Notchmeter never refreshes tokens itself.")))
        }
    }
}

/// Credentials resolution order and Keychain / environment fallback mechanisms.
@Suite struct ClaudeCredentialsResolution {
    init() { Localization.use(language: "en") }

    let validCredentialsJSON = Data(#"{"claudeAiOauth":{"accessToken":"sk-kc-token","subscriptionType":"pro"}}"#.utf8)

    @Test func keychainWithoutPromptSucceedsFirst() throws {
        let emptyDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let creds = try ClaudeProvider.resolveCredentials(
            configDir: emptyDir,
            mayPrompt: false,
            keychain: { prompt in
                #expect(!prompt)
                return self.validCredentialsJSON
            }
        )
        #expect(creds.accessToken == "sk-kc-token")
        #expect(creds.subscriptionType == "pro")
    }

    @Test func securityToolSucceedsWhenKeychainIsDenied() throws {
        let emptyDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let creds = try ClaudeProvider.resolveCredentials(
            configDir: emptyDir,
            mayPrompt: false,
            keychain: { _ in throw KeychainError.denied(errSecAuthFailed) },
            securityTool: { self.validCredentialsJSON }
        )
        #expect(creds.accessToken == "sk-kc-token")
    }

    @Test func userDismissingKeychainPromptThrowsAccessDenied() {
        let emptyDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: ProviderError.accessDenied(L("The Keychain request was dismissed. Switch Claude off and on in Settings to ask again"))) {
            try ClaudeProvider.resolveCredentials(
                configDir: emptyDir,
                mayPrompt: true,
                keychain: { prompt in
                    if prompt { throw KeychainError.denied(errSecUserCanceled) }
                    throw KeychainError.denied(errSecAuthFailed)
                },
                securityTool: { nil }
            )
        }
    }

    @Test func fallsBackToConfigDirectoryCredentialsFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-claude-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileJSON = #"{"claudeAiOauth":{"accessToken":"sk-file-token","subscriptionType":"max"}}"#
        try fileJSON.write(to: dir.appendingPathComponent(".credentials.json"), atomically: true, encoding: .utf8)

        let creds = try ClaudeProvider.resolveCredentials(
            configDir: dir,
            mayPrompt: false,
            keychain: { _ in throw KeychainError.notFound },
            securityTool: { nil }
        )
        #expect(creds.accessToken == "sk-file-token")
        #expect(creds.subscriptionType == "max")
    }

    @Test func fallsBackToOAuthTokenEnvironmentVariable() throws {
        let emptyDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let creds = try ClaudeProvider.resolveCredentials(
            configDir: emptyDir,
            mayPrompt: false,
            environment: ["CLAUDE_CODE_OAUTH_TOKEN": "sk-env-token"],
            keychain: { _ in throw KeychainError.notFound },
            securityTool: { nil }
        )
        #expect(creds.accessToken == "sk-env-token")
    }

    @Test func apiKeyModeThrowsApiKeyOnlyCalmError() {
        let emptyDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: ProviderError.apiKeyOnly(L("Claude Code is on an API key: no plan windows to meter; the Cost card is the meter"))) {
            try ClaudeProvider.resolveCredentials(
                configDir: emptyDir,
                mayPrompt: false,
                environment: ["ANTHROPIC_API_KEY": "sk-ant-test-key"],
                keychain: { _ in throw KeychainError.notFound },
                securityTool: { nil }
            )
        }
    }

    @Test func unauthenticatedStateThrowsNotSignedIn() {
        let emptyDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nonExistentClaudeJSON = emptyDir.appendingPathComponent("claude.json")
        #expect(throws: ProviderError.notSignedIn(L("Sign in to Claude Code to read your usage"))) {
            try ClaudeProvider.resolveCredentials(
                configDir: emptyDir,
                mayPrompt: false,
                environment: [:],
                claudeJSON: nonExistentClaudeJSON,
                keychain: { _ in throw KeychainError.notFound },
                securityTool: { nil }
            )
        }
    }

    @Test func authModeDetectsApiKeyInSettingsHelperAndClaudeJSON() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-claude-auth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let nonExistentClaudeJSON = dir.appendingPathComponent("no-claude.json")

        #expect(ClaudeProvider.authMode(environment: ["ANTHROPIC_API_KEY": "sk-x"], configDir: dir, claudeJSON: nonExistentClaudeJSON) == .apiKey)
        #expect(ClaudeProvider.authMode(environment: [:], configDir: dir, claudeJSON: nonExistentClaudeJSON) == .none)

        let settings = dir.appendingPathComponent("settings.json")
        try #"{"apiKeyHelper":"cmd"}"#.write(to: settings, atomically: true, encoding: .utf8)
        #expect(ClaudeProvider.authMode(environment: [:], configDir: dir, claudeJSON: nonExistentClaudeJSON) == .apiKey)

        try FileManager.default.removeItem(at: settings)
        let claudeJSON = dir.appendingPathComponent("claude.json")
        try #"{"primaryApiKey":"sk-ant-123"}"#.write(to: claudeJSON, atomically: true, encoding: .utf8)
        #expect(ClaudeProvider.authMode(environment: [:], configDir: dir, claudeJSON: claudeJSON) == .apiKey)

        try #"{"oauthAccount":{"accountUuid":"acc_1"}}"#.write(to: claudeJSON, atomically: true, encoding: .utf8)
        #expect(ClaudeProvider.authMode(environment: [:], configDir: dir, claudeJSON: claudeJSON) == .oauth)
    }

    @Test func defaultConfigDirRespectsCustomDirAndTildeExpansion() {
        let customURL = ClaudeProvider.defaultConfigDir(environment: ["CLAUDE_CONFIG_DIR": "/custom/path/to/claude"])
        #expect(customURL.path == "/custom/path/to/claude")

        let tildeURL = ClaudeProvider.defaultConfigDir(environment: ["CLAUDE_CONFIG_DIR": "~/custom_claude"])
        #expect(tildeURL.path == Paths.home.appendingPathComponent("custom_claude").path)

        let emptyURL = ClaudeProvider.defaultConfigDir(environment: ["CLAUDE_CONFIG_DIR": ""])
        #expect(emptyURL.path == Paths.home.appendingPathComponent(".claude").path)

        let defaultURL = ClaudeProvider.defaultConfigDir(environment: [:])
        #expect(defaultURL.path == Paths.home.appendingPathComponent(".claude").path)
    }
}

/// Extra usage credits and scoped weekly limits edge cases.
@Suite struct ClaudeExtraUsageAndScopes {
    init() { Localization.use(language: "en") }

    @Test func extraUsageReturnsNilWhenDisabledOrMissing() {
        #expect(ClaudeProvider.extraUsageWindow(nil) == nil)
        #expect(ClaudeProvider.extraUsageWindow(["is_enabled": false, "used_credits": 1000]) == nil)
        #expect(ClaudeProvider.extraUsageWindow("not a dict") == nil)
    }

    @Test func extraUsageParsesAlternativeCycleEndKeys() {
        for key in ["resets_at", "reset_at", "billing_cycle_end", "cycle_end", "period_end"] {
            let dict: [String: Any] = [
                "is_enabled": true,
                "used_credits": 500,
                "monthly_limit": 2000,
                key: "2026-10-31T23:59:59Z",
            ]
            let window = ClaudeProvider.extraUsageWindow(dict)
            #expect(window != nil, "failed to parse cycle end for key \(key)")
            #expect(window?.resetsAt == DateParsing.iso8601("2026-10-31T23:59:59Z"))
            #expect(window?.usedFraction == 0.25)
            #expect(window?.amountUSD == 5.0)
            #expect(window?.note == "$5.00 of $20")
        }
    }

    @Test func extraUsageWithoutMonthlyLimitShowsSpentOnly() {
        let dict: [String: Any] = [
            "is_enabled": true,
            "used_credits": 1750,
            "monthly_limit": NSNull(),
        ]
        let window = ClaudeProvider.extraUsageWindow(dict)
        #expect(window?.usedFraction == nil)
        #expect(window?.amountUSD == 17.50)
        #expect(window?.note == "$17.50 spent")
    }

    @Test func scopedWeeklyLimitsNormalizesNamesWithSpacesAndFiltersOthers() {
        let list: [[String: Any]] = [
            ["kind": "weekly_scoped", "scope": ["model": ["display_name": "Claude 3.5 Sonnet"]], "percent": 30, "resets_at": "2026-10-15T00:00:00Z"],
            ["kind": "daily_scoped", "scope": ["model": ["display_name": "Other"]], "percent": 50],
            ["kind": "weekly_scoped", "scope": ["model": ["display_name": ""]], "percent": 10],
            ["kind": "weekly_scoped", "scope": ["other": 1], "percent": 10],
        ]
        let windows = ClaudeProvider.scopedWeeklyLimits(list)
        #expect(windows.count == 1)
        #expect(windows[0].id == "scoped_claude_3.5_sonnet")
        #expect(windows[0].label == "Claude 3.5 Sonnet")
        #expect(windows[0].model == "Claude 3.5 Sonnet")
        #expect(windows[0].usedFraction == 0.3)
        #expect(windows[0].periodDuration == Period.week)
        #expect(windows[0].resetsAt == DateParsing.iso8601("2026-10-15T00:00:00Z"))
    }

    @Test func rateLimitWindowsClampsUtilizationAndIgnoresMalformed() {
        let windows = ClaudeProvider.rateLimitWindows { header in
            switch header {
            case "anthropic-ratelimit-unified-5h-utilization": return "1.5"
            case "anthropic-ratelimit-unified-5h-reset": return "1786518600"
            case "anthropic-ratelimit-unified-7d-utilization": return "invalid-number"
            default: return nil
            }
        }
        #expect(windows.count == 1)
        #expect(windows[0].id == "five_hour")
        #expect(windows[0].usedFraction == 1.0)
    }
}
