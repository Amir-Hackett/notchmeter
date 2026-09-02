import Foundation
import os

private let log = Logger(subsystem: "com.amirhackett.notchmeter", category: "claude")

struct ClaudeCredentials: Equatable {
    let accessToken: String
    let expiresAt: Date?
    let subscriptionType: String?
    let rateLimitTier: String?
}

/// Reads the login Claude Code keeps in the Keychain and asks Anthropic's usage endpoint for the rolling windows.
/// It never refreshes or writes the token; Claude Code does that itself whenever it runs.
///
/// The login is looked for in this order: the Keychain item without raising its dialog; the same item through
/// Apple's `security` tool, which Claude Code wrote it with and which never asks; the Keychain item with the dialog,
/// only for a read the user asked for under the "On Refresh only" policy; `$CLAUDE_CONFIG_DIR/.credentials.json`
/// and `~/.claude/.credentials.json`; and the `CLAUDE_CODE_OAUTH_TOKEN` variable. An account on an API key has no
/// plan windows to meter, and says so calmly rather than as a fault.
actor ClaudeProvider: UsageProvider {
    nonisolated let tool: ToolID = .claude
    nonisolated let refreshInterval: TimeInterval = 300

    static let keychainService = "Claude Code-credentials"
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    enum AuthMode: Equatable {
        case oauth
        case apiKey
        case none
    }

    private let session: URLSession?
    private let configDir: URL
    private var cached: ClaudeCredentials?

    init(session: URLSession? = nil, configDir: URL = ClaudeProvider.defaultConfigDir()) {
        self.session = session
        self.configDir = configDir
    }

    /// `$CLAUDE_CONFIG_DIR` when set, else `~/.claude`, the same rule Claude Code applies.
    static func defaultConfigDir(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let custom = ProcessEnvironment.value("CLAUDE_CONFIG_DIR", environment: environment), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return Paths.home.appendingPathComponent(".claude")
    }

    nonisolated func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: configDir.path) || FileManager.default.fileExists(atPath: Paths.home.appendingPathComponent(".claude").path)
    }

    func fetch() async throws -> UsageReading {
        let credentials = try loadCredentials()
        if let expiresAt = credentials.expiresAt, expiresAt.timeIntervalSinceNow < 30 {
            cached = nil
            throw ProviderError.tokenExpired(L("Claude Code's login has expired. Run claude in a terminal once so it refreshes — Notchmeter never refreshes tokens itself."))
        }

        var request = URLRequest(url: Self.usageURL)
        request.timeoutInterval = 20
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await (session ?? NetworkSession.shared).data(for: request)
        } catch {
            if let offline = ProviderError.offline(from: error) { throw offline }
            throw error
        }
        let http = response as? HTTPURLResponse
        DiagnosticLog.request(log, "usage", status: http?.statusCode ?? 0, bytes: data.count)
        let plan = Naming.plan(subscriptionType: credentials.subscriptionType, rateLimitTier: credentials.rateLimitTier)
        let now = Date()
        let headerWindows = http.map(Self.rateLimitWindows) ?? []
        switch http?.statusCode ?? 0 {
        case 200:
            do {
                return try Self.parseUsage(data, plan: plan, now: now)
            } catch let error as ProviderError {
                guard !headerWindows.isEmpty else { throw error }
                return UsageReading(tool: .claude, windows: headerWindows, plan: plan, fetchedAt: now, observedAt: nil)
            }
        case 401, 403:
            cached = nil
            throw ProviderError.notSignedIn(L("Claude Code's login was refused. Run Claude Code once to refresh it"))
        case 429:
            throw ProviderError.rateLimited(retryAfter: RetryAfter.seconds(from: http, now: now))
        case let code:
            guard !headerWindows.isEmpty else { throw ProviderError.http(code, L("usage endpoint answered")) }
            return UsageReading(tool: .claude, windows: headerWindows, plan: plan, fetchedAt: now, observedAt: nil)
        }
    }

    // MARK: - Rate-limit headers

    /// Anthropic's `anthropic-ratelimit-unified-*` headers: utilization as a 0–1 fraction, reset as epoch seconds.
    /// Today they arrive only on inference responses, which Notchmeter never makes (docs/accuracy.md); should the
    /// usage endpoint ever carry them, they stand in for a body that cannot be read.
    static func rateLimitWindows(from response: HTTPURLResponse) -> [LimitWindow] {
        rateLimitWindows { response.value(forHTTPHeaderField: $0) }
    }

    static func rateLimitWindows(header: (String) -> String?) -> [LimitWindow] {
        let specs: [(prefix: String, id: String, label: WindowLabel, period: TimeInterval)] = [
            ("anthropic-ratelimit-unified-5h", "five_hour", .key("Session"), Period.fiveHours),
            ("anthropic-ratelimit-unified-7d", "seven_day", .key("Weekly"), Period.week),
        ]
        return specs.compactMap { spec in
            guard let utilization = header("\(spec.prefix)-utilization").flatMap(number) else { return nil }
            return LimitWindow(
                id: spec.id,
                label: spec.label,
                usedFraction: min(max(utilization, 0), 1),
                resetsAt: header("\(spec.prefix)-reset").flatMap(number).map { Date(timeIntervalSince1970: $0) },
                note: L("From rate-limit headers"),
                periodDuration: spec.period,
                source: .rateLimitHeaders
            )
        }
    }

    private static func number(_ value: String) -> Double? {
        Double(value.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Credentials

    private func loadCredentials() throws -> ClaudeCredentials {
        if let cached { return cached }
        let parsed = try Self.resolveCredentials(configDir: configDir, mayPrompt: Keychain.mayPromptNow)
        cached = parsed
        return parsed
    }

    /// Every source in order; `mayPrompt` is the one thing that decides whether the Keychain dialog can appear.
    static func resolveCredentials(configDir: URL, mayPrompt: Bool, environment: [String: String] = ProcessInfo.processInfo.environment,
                                   keychain: (_ prompt: Bool) throws -> Data = { try Keychain.genericPassword(service: keychainService, prompt: $0) },
                                   securityTool: () -> Data? = { Keychain.genericPasswordViaSecurityTool(service: keychainService) }) throws -> ClaudeCredentials {
        var denied: OSStatus?
        do {
            return try parseCredentials(try keychain(false))
        } catch KeychainError.denied(let status) {
            denied = status
        } catch KeychainError.notFound {
            denied = nil
        } catch KeychainError.other(let status) {
            throw ProviderError.unavailable(L("Keychain read failed: %@", Keychain.describe(status)))
        }
        if denied != nil, let data = securityTool(), let parsed = try? parseCredentials(data) {
            return parsed
        }
        if denied != nil, mayPrompt {
            do {
                return try parseCredentials(try keychain(true))
            } catch KeychainError.denied(let status) {
                if status == errSecUserCanceled {
                    throw ProviderError.accessDenied(L("The Keychain request was dismissed. Switch Claude off and on in Settings to ask again"))
                }
                denied = status
            } catch KeychainError.notFound {
                denied = nil
            } catch KeychainError.other(let status) {
                throw ProviderError.unavailable(L("Keychain read failed: %@", Keychain.describe(status)))
            }
        }
        for file in credentialFiles(configDir: configDir) {
            if let data = try? Data(contentsOf: file), let parsed = try? parseCredentials(data) { return parsed }
        }
        if let token = ProcessEnvironment.value("CLAUDE_CODE_OAUTH_TOKEN", environment: environment) {
            return ClaudeCredentials(accessToken: token, expiresAt: nil, subscriptionType: nil, rateLimitTier: nil)
        }
        if denied != nil {
            throw ProviderError.accessDenied(mayPrompt
                ? L("macOS needs your permission to read Claude Code's login. Choose Always Allow when it asks")
                : L("Claude Code's login needs your OK: click the Claude ring or Refresh to allow the Keychain read"))
        }
        switch authMode(environment: environment, configDir: configDir) {
        case .apiKey:
            throw ProviderError.apiKeyOnly(L("Claude Code is on an API key: no plan windows to meter; the Cost card is the meter"))
        case .oauth, .none:
            throw ProviderError.notSignedIn(L("Sign in to Claude Code to read your usage"))
        }
    }

    /// `$CLAUDE_CONFIG_DIR/.credentials.json` first, then `~/.claude/.credentials.json`.
    static func credentialFiles(configDir: URL) -> [URL] {
        var files = [configDir.appendingPathComponent(".credentials.json")]
        let home = Paths.home.appendingPathComponent(".claude/.credentials.json")
        if home.standardizedFileURL != files[0].standardizedFileURL { files.append(home) }
        return files
    }

    /// How Claude Code is signed in on this Mac when no OAuth login is on disk: `ANTHROPIC_API_KEY`, an
    /// `apiKeyHelper` in settings.json, or a `~/.claude.json` that carries no `oauthAccount`, all mean an API key.
    static func authMode(environment: [String: String] = ProcessInfo.processInfo.environment, configDir: URL = ClaudeProvider.defaultConfigDir(),
                         claudeJSON: URL = Paths.home.appendingPathComponent(".claude.json")) -> AuthMode {
        if let key = ProcessEnvironment.value("ANTHROPIC_API_KEY", environment: environment), !key.isEmpty { return .apiKey }
        if let data = try? Data(contentsOf: configDir.appendingPathComponent("settings.json")),
           let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let helper = settings["apiKeyHelper"] as? String, !helper.isEmpty {
            return .apiKey
        }
        guard let data = try? Data(contentsOf: claudeJSON), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .none }
        if let account = root["oauthAccount"] as? [String: Any], !account.isEmpty { return .oauth }
        if root["primaryApiKey"] != nil || root["customApiKeyResponses"] != nil { return .apiKey }
        return .apiKey
    }

    static func parseCredentials(_ data: Data) throws -> ClaudeCredentials {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else {
            throw ProviderError.notSignedIn(L("Claude Code has not signed in"))
        }
        let expiresAt = JSON.number(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        return ClaudeCredentials(
            accessToken: token,
            expiresAt: expiresAt,
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String
        )
    }

    // MARK: - Usage

    /// Session and weekly windows, then the per-model weekly limits Anthropic now publishes in `limits`
    /// (each named by its model, e.g. "Fable"), then the legacy per-model keys if they still carry data, then the
    /// extra-usage credits with their monthly cap and, when the payload names it, the billing cycle's end.
    static func parseUsage(_ data: Data, plan: String?, now: Date = Date()) throws -> UsageReading {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.parse(L("usage response unreadable"))
        }
        var windows: [LimitWindow] = []
        if let session = window(root["five_hour"], id: "five_hour", label: .key("Session"), period: Period.fiveHours) {
            windows.append(session)
        }
        if let weekly = window(root["seven_day"], id: "seven_day", label: .key("Weekly"), period: Period.week) {
            windows.append(weekly)
        }
        windows.append(contentsOf: scopedWeeklyLimits(root["limits"]))
        for (key, label) in [("seven_day_opus", "Opus"), ("seven_day_sonnet", "Sonnet")] where !windows.contains(where: { $0.label == label }) {
            if let legacy = window(root[key], id: key, label: .vendor(label), period: Period.week, model: label) {
                windows.append(legacy)
            }
        }
        if let extra = extraUsageWindow(root["extra_usage"]) {
            windows.append(extra)
        }
        guard !windows.isEmpty else { throw ProviderError.parse(L("Claude reported no usage windows")) }
        return UsageReading(tool: .claude, windows: windows, plan: plan, fetchedAt: now, observedAt: nil)
    }

    /// `extra_usage`: `used_credits` and `monthly_limit` in cents; the cycle's end under any of the names the
    /// payload has been seen to use.
    static func extraUsageWindow(_ value: Any?) -> LimitWindow? {
        guard let extra = value as? [String: Any], (extra["is_enabled"] as? Bool) == true else { return nil }
        let usedCents = JSON.number(extra["used_credits"]) ?? 0
        let limitCents = JSON.number(extra["monthly_limit"])
        let fraction = limitCents.flatMap { $0 > 0 ? JSON.fraction(usedCents / $0 * 100) : nil }
        let note = limitCents.map { L("%1$@ of %2$@", Money.dollars(usedCents / 100), Money.dollars($0 / 100, cents: false)) }
            ?? L("%@ spent", Money.dollars(usedCents / 100))
        let cycleEnd = ["resets_at", "reset_at", "billing_cycle_end", "cycle_end", "period_end"].lazy
            .compactMap { extra[$0] as? String }.compactMap(DateParsing.iso8601).first
        return LimitWindow(id: "extra_usage", label: .key("Extra usage"), usedFraction: fraction, resetsAt: cycleEnd, note: note, amountUSD: usedCents / 100)
    }

    private static func window(_ value: Any?, id: String, label: WindowLabel, period: TimeInterval, model: String? = nil) -> LimitWindow? {
        guard let object = value as? [String: Any], let utilization = JSON.number(object["utilization"]) else { return nil }
        return LimitWindow(
            id: id,
            label: label,
            usedFraction: JSON.fraction(utilization),
            resetsAt: (object["resets_at"] as? String).flatMap(DateParsing.iso8601),
            periodDuration: period,
            model: model
        )
    }

    static func scopedWeeklyLimits(_ value: Any?) -> [LimitWindow] {
        guard let array = value as? [Any] else { return [] }
        var result: [LimitWindow] = []
        for case let object as [String: Any] in array {
            guard object["kind"] as? String == "weekly_scoped",
                  let scope = object["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  let name = model["display_name"] as? String, !name.isEmpty,
                  let percent = JSON.number(object["percent"])
            else { continue }
            result.append(LimitWindow(
                id: "scoped_\(name.lowercased().replacingOccurrences(of: " ", with: "_"))",
                label: .vendor(name),
                usedFraction: JSON.fraction(percent),
                resetsAt: (object["resets_at"] as? String).flatMap(DateParsing.iso8601),
                periodDuration: Period.week,
                model: name
            ))
        }
        return result
    }
}

/// Provider logging at the level Settings › Advanced chose: request outcomes are `debug` lines, which the unified
/// log drops unless the Debug logging toggle is on, when they are written as `info` so `log show --info` and
/// Copy diagnostics carry them. Never a token, a header or a body.
enum DiagnosticLog {
    private static let verboseState = OSAllocatedUnfairLock(initialState: false)

    static var verbose: Bool {
        get { verboseState.withLock { $0 } }
        set { verboseState.withLock { $0 = newValue } }
    }

    static func request(_ logger: Logger, _ name: String, status: Int, bytes: Int) {
        if verbose {
            logger.info("\(name, privacy: .public) answered HTTP \(status, privacy: .public), \(bytes, privacy: .public) bytes")
        } else {
            logger.debug("\(name, privacy: .public) answered HTTP \(status, privacy: .public), \(bytes, privacy: .public) bytes")
        }
    }
}
