import Foundation
import os

private let log = Logger(subsystem: "com.amirhackett.notchmeter", category: "kimi")

struct KimiCredentials: Equatable {
    let accessToken: String
    let expiresAt: Date?
}

/// Kimi Code's plan usage, read the way Kimi Code's own CLI reads it for its `/usage` command (MoonshotAI/kimi-cli
/// `src/kimi_cli/ui/shell/usage.py`, read 2026-09-24): `GET {base}/usages` with the CLI's OAuth access token as
/// `Authorization: Bearer`, where the base is `https://api.kimi.com/coding/v1` unless `KIMI_CODE_BASE_URL` says
/// otherwise (`auth/platforms.py`). The token is the one the CLI keeps in `credentials/kimi-code.json` in its share
/// folder (`$KIMI_SHARE_DIR`, else `~/.kimi`; `auth/oauth.py` writes it 0600 with `access_token` and `expires_at` in
/// epoch seconds). It is read, never refreshed or written: the CLI refreshes it while it runs, and a refresh from
/// here would rotate the refresh token out from under it and sign the CLI out. So a token past its expiry is a
/// login to renew by running the CLI, said in those words, and the last reading stays on screen meanwhile.
///
/// The endpoint is undocumented as an API; it is the request Moonshot's own client makes, and two shapes of answer
/// have been seen (docs/accuracy.md, *Kimi Code*):
///
/// - counts: `usage` (the summary row the CLI labels "Weekly limit": `limit`, `used` or `remaining`, a reset) and
///   `limits[]`, each a `window` of `duration` and `timeUnit` (`TIME_UNIT_MINUTE`, `_HOUR`, `_DAY`) with its counts
///   in `detail`. Numbers arrive as strings; resets as RFC 3339 with nanoseconds, or as seconds to go.
/// - ratio pools: `usages`, a dictionary of `limit_5h`, `limit_7d`, `limit_month_total`, `limit_month_code`, each a
///   `used_ratio` from 0 to 1 and a `reset_time`, beside or in place of the counts.
///
/// Where both describe one window they have been seen to disagree — `used: 100` of `limit: 100` beside
/// `used_ratio: 0` for the same week, while the API refused every request (MoonshotAI/kimi-code #3951) — so the
/// window is as spent as its furthest-along figure says, the rule Cursor's two figures already follow. Kimi publishes
/// no absolute plan sizes, so a window with no `limit` and no ratio has no figure; nothing is assumed.
actor KimiProvider: UsageProvider {
    nonisolated let tool: ToolID = .kimi
    nonisolated let refreshInterval: TimeInterval = 300
    nonisolated let shareDirectory: URL
    nonisolated let baseURL: URL
    nonisolated var credentialsFile: URL { shareDirectory.appendingPathComponent("credentials/kimi-code.json") }

    static let defaultBaseURL = URL(string: "https://api.kimi.com/coding/v1")!
    /// The hosts a `KIMI_CODE_BASE_URL` override may name, with their subdomains: Moonshot's own. Anything else is
    /// ignored rather than trusted with the token, as a stray URL in the environment could otherwise redirect it.
    static let trustedHosts = ["kimi.com", "kimi.ai", "moonshot.cn", "moonshot.ai"]

    private let session: URLSession?

    init(session: URLSession? = nil, environment: [String: String] = ProcessInfo.processInfo.environment, home: URL = Paths.home) {
        self.session = session
        var resolved = environment
        for name in ["KIMI_SHARE_DIR", "KIMI_CODE_BASE_URL"] {
            if let value = ProcessEnvironment.value(name, environment: environment) { resolved[name] = value }
        }
        shareDirectory = Self.shareDirectory(environment: resolved, home: home)
        baseURL = Self.baseURL(override: resolved["KIMI_CODE_BASE_URL"])
    }

    /// `$KIMI_SHARE_DIR`, else `~/.kimi`: where the CLI keeps its config, its login and its sessions.
    static func shareDirectory(environment: [String: String], home: URL = Paths.home) -> URL {
        if let custom = environment["KIMI_SHARE_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent(".kimi")
    }

    /// The base the usage path is appended to: an https override on one of Moonshot's hosts, else the CLI's default.
    static func baseURL(override: String?) -> URL {
        guard let raw = override?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL(string: raw), url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              trustedHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") })
        else { return defaultBaseURL }
        return url
    }

    static func usageURL(base: URL) -> URL {
        URL(string: base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/usages") ?? defaultBaseURL.appendingPathComponent("usages")
    }

    nonisolated var configFile: URL { shareDirectory.appendingPathComponent("config.toml") }

    /// The CLI has signed in on this Mac, or has at least been set up here.
    nonisolated func isInstalled() -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: credentialsFile.path) || fm.fileExists(atPath: configFile.path)
    }

    func fetch() async throws -> UsageReading {
        guard let data = try? Data(contentsOf: credentialsFile) else {
            // A config with no Kimi Code login is what kimi-cli looks like on a Moonshot API-key platform
            // (`auth/platforms.py`), which has no membership to meter: a calm state, not a fault, so the row can
            // hide as one with nothing to show rather than wear an attention mark for a login the user never
            // wanted. Neither file is the row not installed; an unreadable or tokenless login file, below, is
            // still a login to renew.
            if FileManager.default.fileExists(atPath: configFile.path) {
                throw ProviderError.apiKeyOnly(L("No Kimi Code login on this Mac (an API key has no plan to meter). Run `kimi`, then /login, to read a membership's usage"))
            }
            throw ProviderError.notSignedIn(L("Sign in to Kimi Code (run `kimi`, then /login) to read your plan usage"))
        }
        let credentials = try Self.parseCredentials(data)
        if let expiresAt = credentials.expiresAt, expiresAt.timeIntervalSinceNow < 30 {
            throw ProviderError.tokenExpired(L("Kimi Code's login has expired. Run Kimi Code once so it signs back in"))
        }
        var request = URLRequest(url: Self.usageURL(base: baseURL))
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        let body: Data
        let response: HTTPURLResponse?
        do {
            let (received, answer) = try await (session ?? NetworkSession.shared).data(for: request)
            body = received
            response = answer as? HTTPURLResponse
            DiagnosticLog.request(log, "usages", status: response?.statusCode ?? 0, bytes: received.count)
        } catch {
            if let offline = ProviderError.offline(from: error) { throw offline }
            throw error
        }
        switch response?.statusCode ?? 0 {
        case 200:
            return try Self.parseUsage(body)
        case 401:
            throw ProviderError.notSignedIn(L("Kimi Code's login was refused. Run Kimi Code once so it signs back in"))
        case 403:
            throw ProviderError.accessDenied(L("Kimi refused the usage read for this account"))
        case 404:
            throw ProviderError.unavailable(L("Kimi's usage endpoint answers only a Kimi Code membership"))
        case 429:
            throw ProviderError.rateLimited(retryAfter: RetryAfter.seconds(from: response))
        case let status:
            throw ProviderError.http(status, L("Kimi's usage endpoint answered"))
        }
    }

    // MARK: - Parsing

    static func parseCredentials(_ data: Data) throws -> KimiCredentials {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = root["access_token"] as? String, !token.isEmpty
        else {
            throw ProviderError.notSignedIn(L("Kimi Code has not signed in. Run `kimi`, then /login"))
        }
        // The CLI writes 0 for an expiry it was never told; that is unknown, not long past.
        let expiry = number(root["expires_at"]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        return KimiCredentials(accessToken: token, expiresAt: expiry)
    }

    /// Both shapes, merged window by window. Windows are ordered shortest first, the five-hour window leading as
    /// Claude Code's and Codex's do, and one with no declared length last.
    static func parseUsage(_ data: Data, now: Date = Date()) throws -> UsageReading {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.parse(L("Kimi's usage response unreadable"))
        }
        // Some answers wrap everything in `data`; the keys are read there first and at the top level after.
        let root = top["data"] as? [String: Any] ?? [:]
        func value(_ key: String) -> Any? { root[key] ?? top[key] }

        var windows: [Slot] = []
        // The summary row is the week: the CLI labels it "Weekly limit", and Kimi's help centre says the Kimi Code
        // allowance refreshes every 7 days from the subscription date.
        if let summary = value("usage") as? [String: Any], let counts = Counts(summary, now: now) {
            let kind = Kind(period: Period.week).named(by: summary)
            merge(Slot(kind: kind, counts: counts), into: &windows)
        }
        for (index, entry) in ((value("limits") as? [Any]) ?? []).enumerated() {
            guard let item = entry as? [String: Any] else { continue }
            let detail = item["detail"] as? [String: Any] ?? item
            let window = item["window"] as? [String: Any] ?? [:]
            guard let counts = Counts(detail, now: now) else { continue }
            let period = Self.period(duration: number(window["duration"] ?? item["duration"] ?? detail["duration"]),
                                     unit: (window["timeUnit"] ?? item["timeUnit"] ?? detail["timeUnit"]) as? String)
            let kind = (period.map(Kind.init(period:)) ?? Kind(id: "limit_\(index + 1)", label: .filled("Limit %ld", [.number(index + 1)]), period: nil))
                .named(by: item).named(by: detail)
            merge(Slot(kind: kind, counts: counts), into: &windows)
        }
        // A dictionary has no order of its own, so the pools are read in a fixed one: the known four, total before
        // coding, then any other by name, so two windows of one length always sit in the same order on the card.
        let pools = (value("usages") as? [String: Any]) ?? [:]
        let rank = ["limit_5h": 0, "limit_7d": 1, "limit_month_total": 2, "limit_month_code": 3]
        for key in pools.keys.sorted(by: { (rank[$0] ?? rank.count, $0) < (rank[$1] ?? rank.count, $1) }) {
            guard let pool = pools[key] as? [String: Any], let ratio = number(pool["used_ratio"] ?? pool["usedRatio"]) else { continue }
            let reset = date(pool["reset_time"] ?? pool["resetTime"] ?? pool["reset_at"] ?? pool["resetAt"])
            merge(Slot(kind: Kind(pool: key), ratio: min(max(ratio, 0), 1), ratioReset: reset), into: &windows)
        }
        guard !windows.isEmpty else { throw ProviderError.nothingYet(L("Kimi Code reported no usage yet")) }
        let ordered = windows.enumerated().sorted { ($0.element.kind.period ?? .infinity, $0.offset) < ($1.element.kind.period ?? .infinity, $1.offset) }
        return UsageReading(tool: .kimi, windows: ordered.map(\.element.window), plan: nil, fetchedAt: now, observedAt: nil)
    }

    /// A window length from `duration` and `timeUnit`; nil for an unknown unit rather than a guess at seconds.
    static func period(duration: Double?, unit: String?) -> TimeInterval? {
        guard let duration, duration > 0, let unit = unit?.uppercased() else { return nil }
        if unit.contains("MINUTE") { return duration * 60 }
        if unit.contains("HOUR") { return duration * 3600 }
        if unit.contains("DAY") { return duration * 86400 }
        if unit.contains("WEEK") { return duration * 7 * 86400 }
        if unit.contains("SECOND") { return duration }
        return nil
    }

    /// A number that may arrive as a string ("214"), as every count in this API does.
    static func number(_ value: Any?) -> Double? {
        if let direct = JSON.number(value) { return direct }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return Double(text)
    }

    /// RFC 3339 with any number of fractional digits, read to the millisecond: Kimi sends nanoseconds, which
    /// ISO8601DateFormatter does not promise to read, so the fraction is cut or padded to three digits first.
    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        guard let dot = text.firstIndex(of: ".") else { return DateParsing.iso8601(text) }
        let digits = text[text.index(after: dot)...].prefix { $0.isNumber }
        let millis = String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
        return DateParsing.iso8601(String(text[..<dot]) + "." + millis + String(text[digits.endIndex...]))
    }

    // MARK: - Windows

    /// Which window an entry is: its id, its name and its length.
    struct Kind: Equatable {
        let id: String
        let label: WindowLabel
        let period: TimeInterval?

        /// A window of a declared length, named the way the app names that length for every other vendor.
        init(period: TimeInterval) {
            self.period = period
            let minutes = Int((period / 60).rounded())
            switch minutes {
            case 300: (id, label) = ("session", .key("Session"))
            case 1440: (id, label) = ("daily", .key("Daily"))
            case 10080: (id, label) = ("weekly", .key("Weekly"))
            case _ where minutes % 1440 == 0: (id, label) = ("limit_\(minutes)m", .filled("%ld-day", [.number(minutes / 1440)]))
            case _ where minutes % 60 == 0: (id, label) = ("limit_\(minutes)m", .filled("%ld-hour", [.number(minutes / 60)]))
            default: (id, label) = ("limit_\(minutes)m", .filled("%ld-minute", [.number(minutes)]))
            }
        }

        init(id: String, label: WindowLabel, period: TimeInterval?) {
            self.id = id
            self.label = label
            self.period = period
        }

        /// A ratio pool by its key: `limit_5h` and `limit_7d` are the windows the counts describe too, the two
        /// monthly pools are their own, and any other `limit_<n><unit>` is read by its length.
        init(pool key: String) {
            switch key {
            case "limit_month_total": self.init(id: "monthly_total", label: .key("Monthly total"), period: Period.month)
            case "limit_month_code": self.init(id: "monthly_coding", label: .key("Monthly coding"), period: Period.month)
            default:
                if let period = Self.period(poolKey: key) {
                    self.init(period: period)
                } else {
                    self.init(id: key, label: .vendor(key), period: nil)
                }
            }
        }

        /// The length a `limit_<count><unit>` key names (`limit_5h`, `limit_7d`, `limit_30m`, `limit_2w`); nil for
        /// any other key.
        static func period(poolKey key: String) -> TimeInterval? {
            guard key.hasPrefix("limit_"), let unit = key.last else { return nil }
            let digits = key.dropFirst("limit_".count).dropLast()
            guard !digits.isEmpty, digits.allSatisfy(\.isASCII), let count = Double(digits), count > 0 else { return nil }
            switch unit {
            case "m": return count * 60
            case "h": return count * 3600
            case "d": return count * 86400
            case "w": return count * 7 * 86400
            default: return nil
            }
        }

        /// The same window under the vendor's own name, when the entry gives one (`name`, else `title`, the two
        /// the CLI prints), kept as its words; the id and the length stay those of the window it is.
        func named(by object: [String: Any]) -> Kind {
            for key in ["name", "title"] {
                if let name = (object[key] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                    return Kind(id: id, label: .vendor(name), period: period)
                }
            }
            return self
        }
    }

    /// The counts on one entry: `limit`, and `used` or `remaining` (used is `limit - remaining` when only the
    /// remainder is sent, as the CLI computes it), and the reset.
    struct Counts: Equatable {
        let limit: Double?
        let used: Double?
        let resetsAt: Date?

        init(limit: Double?, used: Double?, resetsAt: Date?) {
            self.limit = limit
            self.used = used
            self.resetsAt = resetsAt
        }

        init?(_ object: [String: Any], now: Date) {
            let limit = KimiProvider.number(object["limit"])
            var used = KimiProvider.number(object["used"])
            if used == nil, let remaining = KimiProvider.number(object["remaining"]), let limit { used = limit - remaining }
            guard limit != nil || used != nil else { return nil }
            self.limit = limit
            self.used = used
            var reset: Date?
            for key in ["reset_at", "resetAt", "reset_time", "resetTime"] where reset == nil {
                reset = KimiProvider.date(object[key])
            }
            if reset == nil {
                for key in ["reset_in", "resetIn", "ttl"] where reset == nil {
                    if let seconds = KimiProvider.number(object[key]), seconds > 0 { reset = now.addingTimeInterval(seconds) }
                }
            }
            resetsAt = reset
        }

        /// used / limit, with no figure for a missing or zero limit: Kimi publishes no plan sizes to fall back on.
        var fraction: Double? {
            guard let limit, limit > 0, let used else { return nil }
            return max(0, used / limit)
        }
    }

    /// One window as the answer describes it, from the counts, the ratio pool, or both.
    struct Slot {
        var kind: Kind
        var counts: Counts?
        var ratio: Double?
        var ratioReset: Date?

        init(kind: Kind, counts: Counts? = nil, ratio: Double? = nil, ratioReset: Date? = nil) {
            self.kind = kind
            self.counts = counts
            self.ratio = ratio
            self.ratioReset = ratioReset
        }

        /// As spent as the furthest-along figure says; the counts' reset first, since the CLI shows that one.
        var window: LimitWindow {
            let figures = [counts?.fraction, ratio].compactMap { $0 }
            let raw = figures.max()
            var note: String?
            if let limit = counts?.limit, limit > 0, let used = counts?.used {
                note = L("%1$ld of %2$ld left", Int(max(0, limit - used).rounded()), Int(limit.rounded()))
            }
            return LimitWindow(id: kind.id, label: kind.label, usedFraction: raw.map { min($0, 1) }, resetsAt: counts?.resetsAt ?? ratioReset,
                               note: note, periodDuration: kind.period, rawUsedPercent: raw.flatMap { $0 > 1 ? $0 * 100 : nil })
        }
    }

    /// Adds `slot` to `windows`, folding it into the slot already there for the same window. The furthest-along
    /// rule holds between two sources of counts as much as between counts and a ratio: the summary row and a
    /// seven-day `limits[]` entry both map to the week, and if they disagree the one that says more is used is
    /// kept whole (its reset with it), so the card cannot show a week half spent while the API refuses requests.
    private static func merge(_ slot: Slot, into windows: inout [Slot]) {
        guard let index = windows.firstIndex(where: { $0.kind.id == slot.kind.id }) else {
            windows.append(slot)
            return
        }
        if let counts = slot.counts { windows[index].counts = windows[index].counts.map { furtherAlong($0, counts) } ?? counts }
        if let ratio = slot.ratio { windows[index].ratio = max(windows[index].ratio ?? 0, ratio) }
        if let reset = slot.ratioReset, windows[index].ratioReset == nil { windows[index].ratioReset = reset }
    }

    /// Of two counts for one window, the one with the higher fraction; on a tie, or when neither has a fraction,
    /// the one carrying a reset, and the first when both or neither do (the summary's, which the CLI prints). The
    /// winner's counts are kept whole; only a reset it lacks is taken from the other, so the window keeps a reset
    /// whichever source sent it.
    static func furtherAlong(_ first: Counts, _ second: Counts) -> Counts {
        let winner: Counts
        let other: Counts
        switch (first.fraction, second.fraction) {
        case let (a?, b?) where a != b: (winner, other) = a > b ? (first, second) : (second, first)
        case (nil, .some): (winner, other) = (second, first)
        case (.some, nil): (winner, other) = (first, second)
        default: (winner, other) = first.resetsAt == nil && second.resetsAt != nil ? (second, first) : (first, second)
        }
        return Counts(limit: winner.limit, used: winner.used, resetsAt: winner.resetsAt ?? other.resetsAt)
    }
}
