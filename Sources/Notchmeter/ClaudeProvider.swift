import Foundation

struct ClaudeCredentials: Equatable {
    let accessToken: String
    let expiresAt: Date?
    let subscriptionType: String?
    let rateLimitTier: String?
}

/// Reads the login Claude Code keeps in the Keychain and asks Anthropic's usage endpoint for the rolling windows.
/// It never refreshes or writes the token; Claude Code does that itself whenever it runs.
actor ClaudeProvider: UsageProvider {
    nonisolated let tool: ToolID = .claude
    nonisolated let refreshInterval: TimeInterval = 180

    static let keychainService = "Claude Code-credentials"
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

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
            throw ProviderError.notSignedIn("Claude Code's login was refused. Run Claude Code once to refresh it")
        case 429:
            let retry = http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw ProviderError.rateLimited(retryAfter: retry)
        case let code:
            guard !headerWindows.isEmpty else { throw ProviderError.http(code, "usage endpoint answered") }
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
        let specs: [(prefix: String, id: String, label: String, period: TimeInterval)] = [
            ("anthropic-ratelimit-unified-5h", "five_hour", "Session", Period.fiveHours),
            ("anthropic-ratelimit-unified-7d", "seven_day", "Weekly", Period.week),
        ]
        return specs.compactMap { spec in
            guard let utilization = header("\(spec.prefix)-utilization").flatMap(number) else { return nil }
            return LimitWindow(
                id: spec.id,
                label: spec.label,
                usedFraction: min(max(utilization, 0), 1),
                resetsAt: header("\(spec.prefix)-reset").flatMap(number).map { Date(timeIntervalSince1970: $0) },
                note: "From rate-limit headers",
                periodDuration: spec.period
            )
        }
    }

    private static func number(_ value: String) -> Double? {
        Double(value.trimmingCharacters(in: .whitespaces))
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
        let expiresAt = JSON.number(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        return ClaudeCredentials(
            accessToken: token,
            expiresAt: expiresAt,
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String
        )
    }

    /// Session and weekly windows, then the per-model weekly limits Anthropic now publishes in `limits`
    /// (each named by its model, e.g. "Fable"), then the legacy per-model keys if they still carry data.
    static func parseUsage(_ data: Data, plan: String?, now: Date = Date()) throws -> UsageReading {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.parse("usage response unreadable")
        }
        var windows: [LimitWindow] = []
        if let session = window(root["five_hour"], id: "five_hour", label: "Session", period: Period.fiveHours) {
            windows.append(session)
        }
        if let weekly = window(root["seven_day"], id: "seven_day", label: "Weekly", period: Period.week) {
            windows.append(weekly)
        }
        windows.append(contentsOf: scopedWeeklyLimits(root["limits"]))
        for (key, label) in [("seven_day_opus", "Opus"), ("seven_day_sonnet", "Sonnet")] where !windows.contains(where: { $0.label == label }) {
            if let legacy = window(root[key], id: key, label: label, period: Period.week, model: label) {
                windows.append(legacy)
            }
        }
        if let extra = root["extra_usage"] as? [String: Any], (extra["is_enabled"] as? Bool) == true {
            let usedCents = JSON.number(extra["used_credits"]) ?? 0
            let limitCents = JSON.number(extra["monthly_limit"])
            let fraction = limitCents.flatMap { $0 > 0 ? JSON.fraction(usedCents / $0 * 100) : nil }
            let note = limitCents.map { "\(Money.dollars(usedCents / 100)) of \(Money.dollars($0 / 100, cents: false))" }
                ?? "\(Money.dollars(usedCents / 100)) spent"
            windows.append(LimitWindow(id: "extra_usage", label: "Extra usage", usedFraction: fraction, resetsAt: nil, note: note))
        }
        guard !windows.isEmpty else { throw ProviderError.parse("Claude reported no usage windows") }
        return UsageReading(tool: .claude, windows: windows, plan: plan, fetchedAt: now, observedAt: nil)
    }

    private static func window(_ value: Any?, id: String, label: String, period: TimeInterval, model: String? = nil) -> LimitWindow? {
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
                label: name,
                usedFraction: JSON.fraction(percent),
                resetsAt: (object["resets_at"] as? String).flatMap(DateParsing.iso8601),
                periodDuration: Period.week,
                model: name
            ))
        }
        return result
    }
}
