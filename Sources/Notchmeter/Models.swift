import Foundation

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

    init(id: String, label: String, usedFraction: Double?, resetsAt: Date?, note: String? = nil, periodDuration: TimeInterval? = nil, model: String? = nil) {
        self.id = id
        self.label = label
        self.usedFraction = usedFraction
        self.resetsAt = resetsAt
        self.note = note
        self.periodDuration = periodDuration
        self.model = model
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

    var message: String {
        switch self {
        case .notSignedIn(let m), .tokenExpired(let m), .accessDenied(let m), .parse(let m), .unavailable(let m), .nothingYet(let m), .offline(let m):
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
}

/// The shared session every provider uses: it waits for connectivity rather than failing at once after a wake, and
/// gives up on a request after a minute so a stalled network cannot hold a loop.
enum NetworkSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()
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
