import Foundation

struct ClaudeCredentials: Equatable {
    let accessToken: String
    let expiresAt: Date?
    let subscriptionType: String?
}

/// Reads the login Claude Code keeps in the Keychain and asks Anthropic's usage endpoint for the rolling windows.
/// It never refreshes or writes the token; Claude Code does that itself whenever it runs.
actor ClaudeProvider: UsageProvider {
    nonisolated let tool: ToolID = .claude
    nonisolated let refreshInterval: TimeInterval = 90

    static let keychainService = "Claude Code-credentials"
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static let windowOrder = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "seven_day_oauth_apps", "seven_day_cowork"]
    static let labels: [String: String] = [
        "five_hour": "Current session",
        "seven_day": "All models",
        "seven_day_opus": "Opus",
        "seven_day_sonnet": "Sonnet",
        "seven_day_oauth_apps": "OAuth apps",
        "seven_day_cowork": "Cowork",
    ]

    private let session: URLSession
    private var cached: ClaudeCredentials?

    init(session: URLSession = .shared) {
        self.session = session
    }

    nonisolated func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: Paths.home.appendingPathComponent(".claude").path)
    }

    func fetch() async throws -> UsageReading {
        let credentials = try loadCredentials()
        if let expiresAt = credentials.expiresAt, expiresAt.timeIntervalSinceNow < 30 {
            cached = nil
            throw ProviderError.tokenExpired("Claude Code's login has expired. Run Claude Code once so it refreshes")
        }

        var request = URLRequest(url: Self.usageURL)
        request.timeoutInterval = 20
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        switch http?.statusCode ?? 0 {
        case 200:
            break
        case 401, 403:
            cached = nil
            throw ProviderError.notSignedIn("Claude Code's login was refused. Run Claude Code once to refresh it")
        case 429:
            let retry = http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw ProviderError.rateLimited(retryAfter: retry)
        case let code:
            throw ProviderError.http(code, "usage endpoint answered")
        }
        return try Self.parseUsage(data, plan: credentials.subscriptionType)
    }

    private func loadCredentials() throws -> ClaudeCredentials {
        if let cached { return cached }
        let data: Data
        do {
            data = try Keychain.genericPassword(service: Self.keychainService)
        } catch KeychainError.notFound {
            let fallback = Paths.home.appendingPathComponent(".claude/.credentials.json")
            guard let fileData = try? Data(contentsOf: fallback) else {
                throw ProviderError.notSignedIn("Sign in to Claude Code to read your usage")
            }
            data = fileData
        } catch KeychainError.denied(let status) {
            if status == errSecUserCanceled {
                throw ProviderError.accessDenied("The Keychain request was dismissed. Switch Claude off and on in Settings to ask again")
            }
            throw ProviderError.accessDenied("macOS needs your permission to read Claude Code's login. Choose Always Allow when it asks")
        } catch KeychainError.other(let status) {
            throw ProviderError.unavailable("Keychain read failed: \(Keychain.describe(status))")
        }
        let parsed = try Self.parseCredentials(data)
        cached = parsed
        return parsed
    }

    static func parseCredentials(_ data: Data) throws -> ClaudeCredentials {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else {
            throw ProviderError.notSignedIn("Claude Code has not signed in")
        }
        let expiresAt = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return ClaudeCredentials(accessToken: token, expiresAt: expiresAt, subscriptionType: oauth["subscriptionType"] as? String)
    }

    static func parseUsage(_ data: Data, plan: String?, now: Date = Date()) throws -> UsageReading {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.parse("usage response unreadable")
        }
        var windows: [LimitWindow] = []
        for key in windowOrder {
            guard let object = root[key] as? [String: Any] else { continue }
            windows.append(window(id: key, object: object))
        }
        // Windows Anthropic adds later still show up, after the known ones.
        for key in root.keys.sorted() where !windowOrder.contains(key) && key != "extra_usage" {
            guard let object = root[key] as? [String: Any], object["utilization"] != nil, object["resets_at"] != nil else { continue }
            windows.append(window(id: key, object: object))
        }
        if let extra = root["extra_usage"] as? [String: Any], (extra["is_enabled"] as? Bool) == true {
            let utilization = extra["utilization"] as? Double
            windows.append(LimitWindow(
                id: "extra_usage",
                label: "Extra usage",
                usedFraction: utilization.map { min(max($0 / 100, 0), 1) },
                resetsAt: nil,
                note: extra["monthly_limit"].flatMap { limit in (limit as? Double).map { "monthly limit $\(Int($0))" } }
            ))
        }
        guard !windows.isEmpty else { throw ProviderError.parse("Claude reported no usage windows") }
        return UsageReading(tool: .claude, windows: windows, plan: plan.map(Naming.plan), fetchedAt: now, observedAt: nil)
    }

    private static func window(id: String, object: [String: Any]) -> LimitWindow {
        let utilization = object["utilization"] as? Double
        let resetsAt = (object["resets_at"] as? String).flatMap(DateParsing.iso8601)
        return LimitWindow(
            id: id,
            label: labels[id] ?? Naming.prettify(id),
            usedFraction: utilization.map { min(max($0 / 100, 0), 1) },
            resetsAt: resetsAt
        )
    }
}
