import Foundation
import os

enum ToolID: String, CaseIterable, Codable, Hashable, Sendable {
    case claude, codex, cursor, antigravity, copilot

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .antigravity: "Antigravity"
        case .copilot: "Copilot"
        }
    }

    var symbolName: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .cursor: "cursorarrow"
        case .antigravity: "sparkles.rectangle.stack"
        case .copilot: "airplane"
        }
    }

    /// The name the tool's own product carries where it differs from the short one on the rings.
    var productName: String {
        self == .claude ? "Claude Code" : self == .copilot ? "GitHub Copilot" : displayName
    }
}

/// Where a window's figure came from, so a script or the skill can tell an endpoint read from a rollout snapshot.
enum WindowSource: String, Codable, Equatable, Sendable {
    /// The vendor's own usage endpoint, the figure the vendor's dashboard shows.
    case vendorEndpoint
    /// Claude Code's status line payload: official, local, zero-network.
    case statusline
    /// Anthropic's unified rate-limit headers on a response.
    case rateLimitHeaders
    /// A figure the tool wrote to disk earlier (a Codex rollout), possibly stale.
    case localSnapshot
    /// Built here from local observation (an inferred window length); not something the vendor said.
    case localEstimate

    /// The small tag on the card; nil for the endpoint, which needs no explanation.
    var tag: String? {
        switch self {
        case .vendorEndpoint: nil
        case .statusline: L("status line")
        case .rateLimitHeaders: L("headers")
        case .localSnapshot: L("snapshot")
        case .localEstimate: L("inferred")
        }
    }
}

struct LimitWindow: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let label: String
    /// Share of the window already consumed, 0...1. nil when the tool publishes no limit.
    let usedFraction: Double?
    let resetsAt: Date?
    let note: String?
    /// Length of the rolling window, when known; drives the pace tick and the "left at reset" projection.
    let periodDuration: TimeInterval?
    /// The model a per-model window is scoped to ("Fable", "Opus"); nil for a tool-wide window.
    let model: String?
    let source: WindowSource
    /// Left off the card and the rings until the user reveals it in Settings (a secondary split of a main figure).
    let hiddenByDefault: Bool
    /// The vendor's own percentage before the 0...1 cap, for a window that can run past 100 (a gateway spend limit).
    let rawUsedPercent: Double?
    /// The money behind the fraction, in US dollars, for a window that meters spend (extra usage, on-demand).
    let amountUSD: Double?

    init(id: String, label: String, usedFraction: Double?, resetsAt: Date?, note: String? = nil, periodDuration: TimeInterval? = nil, model: String? = nil,
         source: WindowSource = .vendorEndpoint, hiddenByDefault: Bool = false, rawUsedPercent: Double? = nil, amountUSD: Double? = nil) {
        self.id = id
        self.label = label
        self.usedFraction = usedFraction
        self.resetsAt = resetsAt
        self.note = note
        self.periodDuration = periodDuration
        self.model = model
        self.source = source
        self.hiddenByDefault = hiddenByDefault
        self.rawUsedPercent = rawUsedPercent
        self.amountUSD = amountUSD
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, usedFraction, resetsAt, note, periodDuration, model, source, hiddenByDefault, rawUsedPercent, amountUSD
    }

    /// Readings cached by an earlier version carry no source; they were endpoint reads.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        usedFraction = try container.decodeIfPresent(Double.self, forKey: .usedFraction)
        resetsAt = try container.decodeIfPresent(Date.self, forKey: .resetsAt)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        periodDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .periodDuration)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        source = try container.decodeIfPresent(WindowSource.self, forKey: .source) ?? .vendorEndpoint
        hiddenByDefault = try container.decodeIfPresent(Bool.self, forKey: .hiddenByDefault) ?? false
        rawUsedPercent = try container.decodeIfPresent(Double.self, forKey: .rawUsedPercent)
        amountUSD = try container.decodeIfPresent(Double.self, forKey: .amountUSD)
    }

    /// The same window with another source (a provider re-labelling what a parser built).
    func with(source: WindowSource, note: String? = nil, periodDuration: TimeInterval?? = nil) -> LimitWindow {
        LimitWindow(id: id, label: label, usedFraction: usedFraction, resetsAt: resetsAt, note: note ?? self.note,
                    periodDuration: periodDuration.map { $0 } ?? self.periodDuration, model: model, source: source,
                    hiddenByDefault: hiddenByDefault, rawUsedPercent: rawUsedPercent, amountUSD: amountUSD)
    }
}

enum Period {
    static let fiveHours: TimeInterval = 5 * 3600
    static let day: TimeInterval = 86400
    static let week: TimeInterval = 7 * 86400
    static let month: TimeInterval = 30 * 86400
}

enum JSON {
    static func number(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: d
        case let i as Int: Double(i)
        case let n as NSNumber: n.doubleValue
        default: nil
        }
    }

    static func fraction(_ percent: Double) -> Double {
        min(max(percent / 100, 0), 1)
    }
}

enum JWT {
    static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func expiry(_ token: String) -> Date? {
        (claims(token)?["exp"]).flatMap(JSON.number).map { Date(timeIntervalSince1970: $0) }
    }
}

struct UsageReading: Codable, Equatable, Sendable {
    let tool: ToolID
    let windows: [LimitWindow]
    let plan: String?
    let fetchedAt: Date
    /// When the tool itself produced the numbers. Codex writes snapshots to disk, so this can trail fetchedAt.
    let observedAt: Date?

    /// The same reading with some of its windows swapped for newer ones (the Claude Code status line replaces the
    /// session and weekly figures while a session runs; everything else is kept).
    func replacing(windows replacements: [LimitWindow], fetchedAt: Date) -> UsageReading {
        var merged = windows
        var insertAt = 0
        for window in replacements {
            if let index = merged.firstIndex(where: { $0.id == window.id }) {
                merged[index] = window
                insertAt = index + 1
            } else {
                merged.insert(window, at: insertAt)
                insertAt += 1
            }
        }
        return UsageReading(tool: tool, windows: merged, plan: plan, fetchedAt: fetchedAt, observedAt: observedAt)
    }

    func with(windows: [LimitWindow]) -> UsageReading {
        UsageReading(tool: tool, windows: windows, plan: plan, fetchedAt: fetchedAt, observedAt: observedAt)
    }
}

enum ProviderError: Error, Equatable {
    case notSignedIn(String)
    case tokenExpired(String)
    case accessDenied(String)
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int, String)
    case parse(String)
    case unavailable(String)
    /// Set up and signed in, but the tool has not produced any usage to show yet.
    case nothingYet(String)
    /// The network is down or the host unreachable: the last reading stays, without a problem mark, until it is back.
    case offline(String)
    /// The tool is billed by API key: no plan windows exist to meter, and that is not a fault.
    case apiKeyOnly(String)

    var message: String {
        switch self {
        case .notSignedIn(let m), .tokenExpired(let m), .accessDenied(let m), .parse(let m), .unavailable(let m), .nothingYet(let m), .offline(let m), .apiKeyOnly(let m):
            m
        case .rateLimited(let retry):
            retry.map { L("Rate limited, retrying in %lds", Int($0)) } ?? L("Rate limited, backing off")
        case .http(let code, let m):
            L("%1$@ (HTTP %2$ld)", m, code)
        }
    }

    /// True when the fix lives in the owning tool (sign in, refresh a login, allow Keychain) rather than a retry here.
    var needsAttention: Bool {
        switch self {
        case .notSignedIn, .tokenExpired, .accessDenied: true
        default: false
        }
    }

    /// A calm state rather than a fault: nothing is wrong, there is simply nothing to meter yet.
    var isCalm: Bool {
        switch self {
        case .nothingYet, .apiKeyOnly: true
        default: false
        }
    }

    /// A transport failure that means "no network", never "the vendor said no": URLError's offline family, plus the
    /// wrapper an actor throws around one.
    static func offline(from error: Error) -> ProviderError? {
        guard let urlError = error as? URLError else { return nil }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .timedOut,
             .internationalRoamingOff, .dataNotAllowed:
            return .offline(L("Offline, retrying"))
        default:
            return nil
        }
    }
}

enum ToolStatus: Equatable {
    case notInstalled
    case off
    case waiting
    case idle(String)
    case needsAttention(String, cached: UsageReading?)
    case ready(UsageReading)
    case failed(String, cached: UsageReading?)
    /// No network: the cached reading stays on screen without a problem mark; the footer says "Offline, retrying".
    case offline(cached: UsageReading?)

    var reading: UsageReading? {
        switch self {
        case .ready(let r): r
        case .needsAttention(_, let c), .failed(_, let c), .offline(let c): c
        case .notInstalled, .off, .waiting, .idle: nil
        }
    }

    var problem: String? {
        switch self {
        case .needsAttention(let m, _), .failed(let m, _): m
        default: nil
        }
    }

    /// The reading still on screen after the tool stopped answering; its numbers may be out of date.
    var staleReading: UsageReading? {
        switch self {
        case .needsAttention(_, let c), .failed(_, let c), .offline(let c): c
        default: nil
        }
    }

    var isOffline: Bool {
        if case .offline = self { return true }
        return false
    }
}

protocol UsageProvider: Sendable {
    var tool: ToolID { get }
    var refreshInterval: TimeInterval { get }
    func isInstalled() -> Bool
    func fetch() async throws -> UsageReading
}

enum ProviderRegistry {
    static func all() -> [any UsageProvider] {
        [ClaudeProvider(), CodexProvider(), CursorProvider(), AntigravityProvider(), CopilotProvider()]
    }
}

enum Paths {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    /// Notchmeter's own folder under Application Support: the drain log, pricing overrides, the daily history.
    static var applicationSupport: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? home.appendingPathComponent("Library/Application Support"))
            .appendingPathComponent(AppInfo.name)
    }
    static var caches: URL {
        (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? home.appendingPathComponent("Library/Caches"))
            .appendingPathComponent(AppInfo.name)
    }
    /// The running app's newest machine-readable report, beside the drain log, for the command-line tool and the
    /// status line to read instead of polling every vendor again.
    static var reportFile: URL { applicationSupport.appendingPathComponent("report-v1.json") }
}

/// A value from the process environment, or from launchd's when the app was launched from the Finder and
/// inherited nothing of the shell's (`launchctl getenv`, the same source a login shell's exports reach).
enum ProcessEnvironment {
    static func value(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let direct = environment[name], !direct.isEmpty { return direct }
        guard environment["TERM"] == nil else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["getenv", name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

/// The shared session every provider uses: it waits for connectivity rather than failing at once after a wake, and
/// gives up on a request after a minute so a stalled network cannot hold a loop. "Route requests through" in
/// Settings replaces it with one carrying a proxy; providers read it at each request so the change applies at once.
enum NetworkSession {
    private static let state = OSAllocatedUnfairLock<URLSession>(initialState: make(proxy: nil))

    static var shared: URLSession { state.withLock { $0 } }

    static func configure(proxy: String?) {
        let session = make(proxy: proxy)
        state.withLock { $0 = session }
    }

    private static func make(proxy: String?) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        if let dictionary = ProxySettings.dictionary(for: proxy) {
            configuration.connectionProxyDictionary = dictionary
        }
        return URLSession(configuration: configuration)
    }
}

/// `http://host:port`, `https://host:port` or `socks5://host:port`, as CFNetwork's proxy dictionary; nil (the system
/// proxy from Network settings) for anything else.
enum ProxySettings {
    static func dictionary(for proxy: String?) -> [AnyHashable: Any]? {
        guard let proxy = proxy?.trimmingCharacters(in: .whitespacesAndNewlines), !proxy.isEmpty,
              let url = URL(string: proxy), let host = url.host, let port = url.port, let scheme = url.scheme?.lowercased()
        else { return nil }
        switch scheme {
        case "http", "https":
            return [kCFNetworkProxiesHTTPEnable: 1, kCFNetworkProxiesHTTPProxy: host, kCFNetworkProxiesHTTPPort: port,
                    kCFNetworkProxiesHTTPSEnable: 1, kCFNetworkProxiesHTTPSProxy: host, kCFNetworkProxiesHTTPSPort: port]
        case "socks5", "socks":
            return [kCFNetworkProxiesSOCKSEnable: 1, kCFNetworkProxiesSOCKSProxy: host, kCFNetworkProxiesSOCKSPort: port]
        default:
            return nil
        }
    }
}

/// How long a vendor asked us to wait: `Retry-After` in seconds or as an HTTP date, else GitHub's
/// `x-ratelimit-reset` (epoch seconds); nil when neither is present or parseable.
enum RetryAfter {
    static func seconds(from response: HTTPURLResponse?, now: Date = Date()) -> TimeInterval? {
        guard let response else { return nil }
        return seconds(retryAfter: response.value(forHTTPHeaderField: "Retry-After"),
                       rateLimitReset: response.value(forHTTPHeaderField: "x-ratelimit-reset"), now: now)
    }

    static func seconds(retryAfter: String?, rateLimitReset: String?, now: Date = Date()) -> TimeInterval? {
        if let retryAfter = retryAfter?.trimmingCharacters(in: .whitespaces), !retryAfter.isEmpty {
            if let seconds = TimeInterval(retryAfter) { return max(0, seconds) }
            if let date = httpDate(retryAfter) { return max(0, date.timeIntervalSince(now)) }
        }
        if let reset = rateLimitReset.flatMap({ TimeInterval($0.trimmingCharacters(in: .whitespaces)) }) {
            return max(0, Date(timeIntervalSince1970: reset).timeIntervalSince(now))
        }
        return nil
    }

    private static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

/// Each vendor's own usage page and status page, for the card's context menu and the wait-for-reset advice.
enum ProviderLinks {
    static func usage(_ tool: ToolID) -> URL {
        switch tool {
        case .claude: URL(string: "https://claude.ai/settings/usage")!
        case .codex: URL(string: "https://chatgpt.com/codex/settings/usage")!
        case .cursor: URL(string: "https://cursor.com/dashboard")!
        case .antigravity: URL(string: "https://geminicli.com/docs/resources/quota-and-pricing/")!
        case .copilot: URL(string: "https://github.com/settings/copilot")!
        }
    }

    static func status(_ tool: ToolID) -> URL? {
        switch tool {
        case .claude: URL(string: "https://status.anthropic.com")
        case .codex: URL(string: "https://status.openai.com")
        case .cursor: URL(string: "https://status.cursor.com")
        case .antigravity: nil
        case .copilot: URL(string: "https://www.githubstatus.com")
        }
    }
}

enum AppInfo {
    static let name = "Notchmeter"
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
    static var userAgent: String { "\(name)/\(version)" }
}

enum DateParsing {
    static func iso8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

enum Naming {
    static func plan(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// "Max 5x": the subscription plus the usage multiplier Anthropic encodes in the rate-limit tier.
    static func plan(subscriptionType: String?, rateLimitTier: String?) -> String? {
        guard let raw = subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let base = plan(raw)
        if let tier = rateLimitTier, let match = tier.range(of: #"\d+x"#, options: .regularExpression) {
            return "\(base) \(tier[match])"
        }
        return base
    }

    /// Codex's `plan_type` slugs as ChatGPT names them; an unknown slug is prettified.
    static let codexPlans: [String: String] = [
        "free": "Free", "go": "Go", "plus": "Plus", "pro": "Pro", "team": "Team", "business": "Business", "enterprise": "Enterprise",
        "edu": "Edu", "self_serve_business": "Business", "self_serve_business_prolite": "Business Premium", "business_prolite": "Business Premium",
    ]

    static func codexPlan(_ raw: String) -> String {
        let slug = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return codexPlans[slug] ?? plan(slug)
    }

    static func prettify(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

enum RelativeTime {
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return L("just now") }
        if s < 3600 { return L("%ldm ago", Int(s / 60)) }
        if s < 86400 { return L("%ldh ago", Int(s / 3600)) }
        return L("%ldd ago", Int(s / 86400))
    }

    /// Probe output only, so it stays English.
    static func resets(_ date: Date?, hasLimit: Bool, now: Date = Date()) -> String {
        guard hasLimit else { return "no limit published" }
        guard let date else { return "" }
        let s = date.timeIntervalSince(now)
        if s <= 0 { return "resets now" }
        if s < 3600 { return "resets in \(max(1, Int(s / 60)))m" }
        if s < 86400 {
            let h = Int(s / 3600)
            let m = Int(s.truncatingRemainder(dividingBy: 3600) / 60)
            return "resets in \(h)h \(m)m"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE h a"
        return "resets \(formatter.string(from: date))"
    }
}
