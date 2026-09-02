import Foundation

/// Asks the same backend endpoint Codex itself uses for its rate-limit windows, with the login Codex keeps in
/// `~/.codex/auth.json`. Falls back to the snapshots Codex writes into session rollouts when the network is out.
/// The token is never refreshed or written; Codex does that whenever it runs.
actor CodexProvider: UsageProvider {
    nonisolated let tool: ToolID = .codex
    nonisolated let refreshInterval: TimeInterval = 120
    nonisolated let root: URL

    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    struct Auth: Equatable {
        let accessToken: String
        let accountID: String?
        let expiresAt: Date?
    }

    private let session: URLSession

    init(session: URLSession = .shared, root: URL = Paths.home.appendingPathComponent(".codex")) {
        self.session = session
        self.root = root
    }

    nonisolated func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: root.path)
    }

    func fetch() async throws -> UsageReading {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("auth.json")) else {
            throw ProviderError.notSignedIn("Sign in to Codex (run `codex login`) to read your usage")
        }
        let auth = try Self.parseAuth(data)
        if let expiresAt = auth.expiresAt, expiresAt.timeIntervalSinceNow < 30 {
            if let local = try? localReading() { return local }
            throw ProviderError.tokenExpired("Codex's login has expired. Run Codex once so it signs back in")
        }

        var request = URLRequest(url: Self.usageURL)
        request.timeoutInterval = 20
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        if let accountID = auth.accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let body: Data
        let status: Int
        do {
            let (received, response) = try await session.data(for: request)
            body = received
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            if let local = try? localReading() { return local }
            throw ProviderError.unavailable("Codex usage is unreachable: \(error.localizedDescription)")
        }

        switch status {
        case 200:
            return try Self.parseBackend(body)
        case 401, 403:
            if let local = try? localReading() { return local }
            throw ProviderError.tokenExpired("Codex's login was refused. Run Codex once so it signs back in")
        case 429:
            throw ProviderError.rateLimited(retryAfter: nil)
        default:
            if let local = try? localReading() { return local }
            throw ProviderError.http(status, "Codex usage endpoint answered")
        }
    }

    // MARK: - Backend

    static func parseAuth(_ data: Data) throws -> Auth {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.notSignedIn("Codex's auth.json could not be read. Run `codex login` to sign in again")
        }
        let tokens = root["tokens"] as? [String: Any]
        guard let token = tokens?["access_token"] as? String, !token.isEmpty else {
            throw ProviderError.notSignedIn("Codex is set up with an API key only; its usage limits need a ChatGPT login (`codex login`)")
        }
        var accountID = tokens?["account_id"] as? String
        if accountID == nil, let idToken = tokens?["id_token"] as? String, let claims = JWT.claims(idToken) {
            if let direct = claims["chatgpt_account_id"] as? String {
                accountID = direct
            } else if let auth = claims["https://api.openai.com/auth"] as? [String: Any] {
                accountID = auth["chatgpt_account_id"] as? String
            }
        }
        return Auth(accessToken: token, accountID: accountID, expiresAt: JWT.expiry(token))
    }

    /// `rate_limit.primary_window` is normally the 5-hour window and `secondary_window` the weekly one, but
    /// they are classified by their declared length so a sole weekly limit in the primary slot still reads right.
    static func parseBackend(_ data: Data, now: Date = Date()) throws -> UsageReading {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.parse("Codex usage response unreadable")
        }
        let rateLimit = root["rate_limit"] as? [String: Any]
        var session: LimitWindow?
        var longer: [LimitWindow] = []
        for (slot, fallbackIsWeekly) in [("primary_window", false), ("secondary_window", true)] {
            guard let window = rateLimit?[slot] as? [String: Any], let used = JSON.number(window["used_percent"]) else { continue }
            let seconds = JSON.number(window["limit_window_seconds"])
            let kind = windowKind(seconds: seconds, fallbackIsWeekly: fallbackIsWeekly)
            let parsed = LimitWindow(
                id: kind.id,
                label: kind.label,
                usedFraction: JSON.fraction(used),
                resetsAt: JSON.number(window["reset_at"]).map { Date(timeIntervalSince1970: $0) },
                periodDuration: seconds ?? (kind.id == "session" ? Period.fiveHours : Period.week)
            )
            if kind.id == "session" {
                session = session ?? parsed
            } else if !longer.contains(where: { $0.id == kind.id }) {
                longer.append(parsed)
            }
        }
        var windows: [LimitWindow] = []
        windows.append(session ?? LimitWindow(id: "session", label: "Session", usedFraction: nil, resetsAt: nil, note: "No data"))
        if longer.isEmpty {
            windows.append(LimitWindow(id: "weekly", label: "Weekly", usedFraction: nil, resetsAt: nil, note: "No data"))
        } else {
            windows.append(contentsOf: longer)
        }
        if let credits = root["credits"] as? [String: Any], (credits["has_credits"] as? Bool) == true, (credits["unlimited"] as? Bool) != true,
           let balance = JSON.number(credits["balance"]) {
            windows.append(LimitWindow(id: "credits", label: "Credits", usedFraction: nil, resetsAt: nil, note: "\(Money.dollars(balance)) remaining"))
        }
        let plan = (root["plan_type"] as? String).map(Naming.plan)
        return UsageReading(tool: .codex, windows: windows, plan: plan, fetchedAt: now, observedAt: nil)
    }

    /// Labels a window by its declared length: 5-hour sessions, weekly and monthly limits, or "N-day".
    static func windowKind(seconds: Double?, fallbackIsWeekly: Bool) -> (id: String, label: String) {
        guard let seconds else { return fallbackIsWeekly ? ("weekly", "Weekly") : ("session", "Session") }
        if seconds <= 6 * 3600 { return ("session", "Session") }
        let days = seconds / 86400
        if (5...9).contains(days) { return ("weekly", "Weekly") }
        if (25...35).contains(days) { return ("monthly", "Monthly") }
        let rounded = Int(days.rounded())
        return ("window_\(rounded)d", "\(rounded)-day")
    }

    // MARK: - Local rollouts (fallback)

    private func localReading() throws -> UsageReading {
        let rollouts = Self.recentRollouts(in: root.appendingPathComponent("sessions"), limit: 8)
        guard !rollouts.isEmpty else {
            throw ProviderError.nothingYet("No Codex sessions on this Mac yet. Run Codex once and its limits appear here")
        }
        var newest: (observedAt: Date, limits: [String: Any])?
        for url in rollouts {
            guard let found = Self.latestRateLimits(in: url) else { continue }
            if newest == nil || found.observedAt > newest!.observedAt { newest = found }
        }
        guard let newest else { throw ProviderError.nothingYet("Codex has not recorded a usage snapshot yet") }
        return try Self.reading(from: newest.limits, observedAt: newest.observedAt, now: Date())
    }

    /// Newest rollout files by modification date, wherever Codex nests them under sessions/.
    static func recentRollouts(in sessions: URL, limit: Int) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }
        var files: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            files.append((url, values?.contentModificationDate ?? .distantPast))
        }
        return files.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// The last rate_limits payload in a rollout, read from the tail first because rollouts grow large.
    static func latestRateLimits(in url: URL) -> (observedAt: Date, limits: [String: Any])? {
        let tailBytes = 2_000_000
        guard let tail = read(url, lastBytes: tailBytes) else { return nil }
        if let found = scan(tail, fileURL: url) { return found }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > tailBytes, let whole = try? Data(contentsOf: url) else { return nil }
        return scan(whole, fileURL: url)
    }

    private static func scan(_ data: Data, fileURL: URL) -> (observedAt: Date, limits: [String: Any])? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() where line.contains("\"rate_limits\"") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let payload = object["payload"] as? [String: Any]
            guard let limits = (payload?["rate_limits"] ?? object["rate_limits"]) as? [String: Any] else { continue }
            let stamp = (object["timestamp"] as? String).flatMap(DateParsing.iso8601)
                ?? (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                ?? Date()
            return (stamp, limits)
        }
        return nil
    }

    private static func read(_ url: URL, lastBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(lastBytes) ? size - UInt64(lastBytes) : 0
        try? handle.seek(toOffset: start)
        return try? handle.readToEnd()
    }

    static func reading(from limits: [String: Any], observedAt: Date, now: Date) throws -> UsageReading {
        var windows: [LimitWindow] = []
        for (key, fallbackLabel) in [("primary", "Session"), ("secondary", "Weekly")] {
            guard let window = limits[key] as? [String: Any], let usedPercent = JSON.number(window["used_percent"]) else { continue }
            var resetsAt: Date?
            if let epoch = JSON.number(window["resets_at"]) {
                resetsAt = Date(timeIntervalSince1970: epoch)
            } else if let seconds = JSON.number(window["resets_in_seconds"]) {
                resetsAt = observedAt.addingTimeInterval(seconds)
            }
            let minutes = JSON.number(window["window_minutes"]).map(Int.init)
            var fraction = JSON.fraction(usedPercent)
            var note: String?
            if let resetsAt, resetsAt < now {
                fraction = 0
                note = "Reset since Codex last reported"
            }
            windows.append(LimitWindow(
                id: key == "primary" ? "session" : "weekly",
                label: minutes.map(label(forMinutes:)) ?? fallbackLabel,
                usedFraction: fraction,
                resetsAt: resetsAt,
                note: note,
                periodDuration: minutes.map { TimeInterval($0 * 60) }
            ))
        }
        guard !windows.isEmpty else { throw ProviderError.unavailable("Codex reported no usage windows") }
        let plan = (limits["plan_type"] as? String).map(Naming.plan)
        return UsageReading(tool: .codex, windows: windows, plan: plan, fetchedAt: now, observedAt: observedAt)
    }

    static func label(forMinutes minutes: Int) -> String {
        switch minutes {
        case 300: "Session"
        case 10080: "Weekly"
        case ..<60: "\(minutes)-minute"
        case 60..<1440: minutes % 60 == 0 ? "\(minutes / 60)-hour" : "\(minutes)-minute"
        default: "\(minutes / 1440)-day"
        }
    }
}
