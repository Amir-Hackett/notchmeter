import Foundation
import os

private let log = Logger(subsystem: "com.amirhackett.notchmeter", category: "codex")

/// Asks the same backend endpoint Codex itself uses for its rate-limit windows, with the login Codex keeps in
/// its home (`$CODEX_HOME`, else `~/.config/codex`, else `~/.codex`, the order Codex resolves it). Falls back to the
/// snapshots Codex writes into session rollouts when the network is out. The token is never refreshed or written;
/// Codex does that whenever it runs. The reset-credits endpoint is a second request on the same login and runs
/// only when the user opts in.
actor CodexProvider: UsageProvider {
    nonisolated let tool: ToolID = .codex
    nonisolated let refreshInterval: TimeInterval = 300
    nonisolated let root: URL

    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let resetCreditsURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!

    struct Auth: Equatable {
        let accessToken: String
        let accountID: String?
        let expiresAt: Date?
    }

    /// A credit that resets a window when claimed in Codex; Notchmeter shows it and never claims it.
    struct ResetCredit: Equatable, Sendable {
        let count: Int
        let expiresAt: Date?
        let kind: String?
    }

    private let session: URLSession?
    private let readResetCredits: @Sendable () -> Bool

    init(session: URLSession? = nil, root: URL = CodexProvider.defaultHome(),
         readResetCredits: @escaping @Sendable () -> Bool = { false }) {
        self.session = session
        self.root = root
        self.readResetCredits = readResetCredits
    }

    /// `$CODEX_HOME` when set; else `~/.config/codex` when it exists; else `~/.codex`.
    static func defaultHome(environment: [String: String] = ProcessInfo.processInfo.environment, home: URL = Paths.home,
                            exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        if let custom = ProcessEnvironment.value("CODEX_HOME", environment: environment), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        let config = home.appendingPathComponent(".config/codex")
        return exists(config) ? config : home.appendingPathComponent(".codex")
    }

    nonisolated func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: root.path)
    }

    func fetch() async throws -> UsageReading {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("auth.json")) else {
            throw ProviderError.notSignedIn(L("Sign in to Codex (run `codex login`) to read your usage"))
        }
        let auth = try Self.parseAuth(data)
        if let expiresAt = auth.expiresAt, expiresAt.timeIntervalSinceNow < 30 {
            if let local = try? localReading() { return local }
            throw ProviderError.tokenExpired(L("Codex's login has expired. Run Codex once so it signs back in"))
        }

        let body: Data
        let response: HTTPURLResponse?
        do {
            (body, response) = try await get(Self.usageURL, auth: auth)
        } catch {
            if let local = try? localReading() { return local }
            if let offline = ProviderError.offline(from: error) { throw offline }
            throw ProviderError.unavailable(L("Codex usage is unreachable: %@", error.localizedDescription))
        }

        switch response?.statusCode ?? 0 {
        case 200:
            var reading = try Self.parseBackend(body)
            if readResetCredits(), let (credits, creditResponse) = try? await get(Self.resetCreditsURL, auth: auth), creditResponse?.statusCode == 200,
               let window = Self.resetCreditWindow(Self.parseResetCredits(credits)) {
                reading = reading.with(windows: reading.windows + [window])
            }
            return reading
        case 401, 403:
            if let local = try? localReading() { return local }
            throw ProviderError.tokenExpired(L("Codex's login was refused. Run Codex once so it signs back in"))
        case 429:
            throw ProviderError.rateLimited(retryAfter: RetryAfter.seconds(from: response))
        case let status:
            if let local = try? localReading() { return local }
            throw ProviderError.http(status, L("Codex usage endpoint answered"))
        }
    }

    private func get(_ url: URL, auth: Auth) async throws -> (Data, HTTPURLResponse?) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        if let accountID = auth.accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        let (received, response) = try await (session ?? NetworkSession.shared).data(for: request)
        let http = response as? HTTPURLResponse
        DiagnosticLog.request(log, url.lastPathComponent, status: http?.statusCode ?? 0, bytes: received.count)
        return (received, http)
    }

    // MARK: - Backend

    static func parseAuth(_ data: Data) throws -> Auth {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.notSignedIn(L("Codex's auth.json could not be read. Run `codex login` to sign in again"))
        }
        let tokens = root["tokens"] as? [String: Any]
        guard let token = tokens?["access_token"] as? String, !token.isEmpty else {
            throw ProviderError.notSignedIn(L("Codex is set up with an API key only; its usage limits need a ChatGPT login (`codex login`)"))
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
    /// `additional_rate_limits` carries a paired pair per extra model (GPT-5.3-Codex-Spark), which become
    /// per-model windows so the switch-models advice applies to Codex too.
    static func parseBackend(_ data: Data, now: Date = Date()) throws -> UsageReading {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.parse(L("Codex usage response unreadable"))
        }
        var windows = parseRateLimit(root["rate_limit"] as? [String: Any], model: nil)
        if !windows.contains(where: { $0.id == "session" }) {
            windows.insert(LimitWindow(id: "session", label: .key("Session"), usedFraction: nil, resetsAt: nil, note: L("No data")), at: 0)
        }
        if windows.count == 1 {
            windows.append(LimitWindow(id: "weekly", label: .key("Weekly"), usedFraction: nil, resetsAt: nil, note: L("No data")))
        }
        for case let extra as [String: Any] in (root["additional_rate_limits"] as? [Any]) ?? [] {
            let name = additionalModelName(extra)
            let limit = (extra["rate_limit"] as? [String: Any]) ?? extra
            windows.append(contentsOf: parseRateLimit(limit, model: name))
        }
        if let credits = root["credits"] as? [String: Any], (credits["has_credits"] as? Bool) == true, (credits["unlimited"] as? Bool) != true,
           let balance = JSON.number(credits["balance"]) {
            windows.append(LimitWindow(id: "credits", label: .key("Credits"), usedFraction: nil, resetsAt: nil, note: L("%@ remaining", Money.dollars(balance)), amountUSD: balance))
        }
        let plan = (root["plan_type"] as? String).map(Naming.codexPlan)
        return UsageReading(tool: .codex, windows: windows, plan: plan, fetchedAt: now, observedAt: nil)
    }

    /// Both slots of one rate_limit object; a model name scopes the ids and labels ("Spark Session").
    static func parseRateLimit(_ rateLimit: [String: Any]?, model: String?) -> [LimitWindow] {
        var session: LimitWindow?
        var longer: [LimitWindow] = []
        for (slot, fallbackIsWeekly) in [("primary_window", false), ("secondary_window", true)] {
            guard let window = rateLimit?[slot] as? [String: Any], let used = JSON.number(window["used_percent"]) else { continue }
            let seconds = JSON.number(window["limit_window_seconds"])
            let kind = windowKind(seconds: seconds, fallbackIsWeekly: fallbackIsWeekly)
            let slug = model.map { $0.lowercased().replacingOccurrences(of: " ", with: "_") + "_" } ?? ""
            let parsed = LimitWindow(
                id: slug + kind.id,
                label: model.map { WindowLabel.scoped(model: $0, of: kind.label) } ?? kind.label,
                usedFraction: JSON.fraction(used),
                resetsAt: JSON.number(window["reset_at"]).map { Date(timeIntervalSince1970: $0) },
                periodDuration: seconds ?? (kind.id == "session" ? Period.fiveHours : Period.week),
                model: model
            )
            if kind.id == "session" {
                session = session ?? parsed
            } else if !longer.contains(where: { $0.id == parsed.id }) {
                longer.append(parsed)
            }
        }
        return [session].compactMap { $0 } + longer
    }

    /// The model an additional limit is for: a display name when given, else its slug made readable.
    static func additionalModelName(_ entry: [String: Any]) -> String {
        for key in ["display_name", "model_display_name", "name", "limit_name", "model_slug", "model"] {
            if let value = entry[key] as? String, !value.isEmpty {
                return value.contains(" ") ? value : ModelNames.display(value)
            }
        }
        return L("Extra")
    }

    /// Labels a window by its declared length: 5-hour sessions, weekly and monthly limits, or "N-day". The name
    /// travels unlocalised, so a per-model window reads in whatever language shows it.
    static func windowKind(seconds: Double?, fallbackIsWeekly: Bool) -> (id: String, label: WindowLabel) {
        guard let seconds else { return fallbackIsWeekly ? ("weekly", .key("Weekly")) : ("session", .key("Session")) }
        if seconds <= 6 * 3600 { return ("session", .key("Session")) }
        let days = seconds / 86400
        if (5...9).contains(days) { return ("weekly", .key("Weekly")) }
        if (25...35).contains(days) { return ("monthly", .key("Monthly")) }
        let rounded = Int(days.rounded())
        return ("window_\(rounded)d", .filled("%ld-day", [.number(rounded)]))
    }

    // MARK: - Reset credits

    /// `{"credits":[{"count":1,"expires_at":…,"type":"full_reset"}]}` in the shape OpenUsage's research recorded;
    /// `reset_credits`, `quantity`/`remaining`, `expiration`/`expiry` and ISO or epoch dates are accepted as well.
    static func parseResetCredits(_ data: Data) -> [ResetCredit] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let list = (root["credits"] ?? root["reset_credits"] ?? root["items"]) as? [Any] ?? []
        return list.compactMap { item in
            guard let object = item as? [String: Any] else { return nil }
            let count = Int(JSON.number(object["count"] ?? object["quantity"] ?? object["remaining"]) ?? 1)
            let expiry = object["expires_at"] ?? object["expiration"] ?? object["expiry"]
            let expiresAt = (expiry as? String).flatMap(DateParsing.iso8601) ?? JSON.number(expiry).map { Date(timeIntervalSince1970: $0 > 1e12 ? $0 / 1000 : $0) }
            let kind = (object["type"] ?? object["credit_type"] ?? object["kind"]) as? String
            return count > 0 ? ResetCredit(count: count, expiresAt: expiresAt, kind: kind) : nil
        }
    }

    /// One informational window for the soonest-expiring credit: "Full reset credit expires in 3d — claim it in Codex".
    static func resetCreditWindow(_ credits: [ResetCredit], now: Date = Date()) -> LimitWindow? {
        let live = credits.filter { $0.expiresAt.map { $0 > now } ?? true }
        guard !live.isEmpty else { return nil }
        let soonest = live.min { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }!
        let total = live.reduce(0) { $0 + $1.count }
        let name = soonest.kind.map { Naming.prettify($0) } ?? L("Reset")
        let note: String
        if let expiresAt = soonest.expiresAt {
            note = L("%1$@ credit expires in %2$@ — claim it in Codex", name, ResetText.duration(expiresAt.timeIntervalSince(now)))
        } else {
            note = L("%1$ld %2$@ credit(s) — claim them in Codex", total, name)
        }
        return LimitWindow(id: "reset_credits", label: .key("Reset credits"), usedFraction: nil, resetsAt: soonest.expiresAt, note: note)
    }

    // MARK: - Local rollouts (fallback)

    private func localReading() throws -> UsageReading {
        let rollouts = Self.recentRollouts(in: root.appendingPathComponent("sessions"), limit: 8)
        guard !rollouts.isEmpty else {
            throw ProviderError.nothingYet(L("No Codex sessions on this Mac yet. Run Codex once and its limits appear here"))
        }
        var newest: (observedAt: Date, limits: [String: Any])?
        for url in rollouts {
            guard let found = Self.latestRateLimits(in: url) else { continue }
            if newest == nil || found.observedAt > newest!.observedAt { newest = found }
        }
        guard let newest else { throw ProviderError.nothingYet(L("Codex has not recorded a usage snapshot yet")) }
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

    /// A snapshot Codex wrote into a rollout: tagged as such, and a reset that has already passed reads as a fresh
    /// window rather than a stale figure.
    static func reading(from limits: [String: Any], observedAt: Date, now: Date) throws -> UsageReading {
        var windows: [LimitWindow] = []
        for (key, fallbackLabel) in [("primary", WindowLabel.key("Session")), ("secondary", WindowLabel.key("Weekly"))] {
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
                note = L("Reset since Codex last reported")
            }
            windows.append(LimitWindow(
                id: key == "primary" ? "session" : "weekly",
                label: minutes.map(label(forMinutes:)) ?? fallbackLabel,
                usedFraction: fraction,
                resetsAt: resetsAt,
                note: note,
                periodDuration: minutes.map { TimeInterval($0 * 60) },
                source: .localSnapshot
            ))
        }
        guard !windows.isEmpty else { throw ProviderError.unavailable(L("Codex reported no usage windows")) }
        let plan = (limits["plan_type"] as? String).map(Naming.codexPlan)
        return UsageReading(tool: .codex, windows: windows, plan: plan, fetchedAt: now, observedAt: observedAt)
    }

    static func label(forMinutes minutes: Int) -> WindowLabel {
        switch minutes {
        case 300: .key("Session")
        case 10080: .key("Weekly")
        case ..<60: .filled("%ld-minute", [.number(minutes)])
        case 60..<1440: minutes % 60 == 0 ? .filled("%ld-hour", [.number(minutes / 60)]) : .filled("%ld-minute", [.number(minutes)])
        default: .filled("%ld-day", [.number(minutes / 1440)])
        }
    }
}
