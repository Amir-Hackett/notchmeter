import Foundation

enum ToolID: String, CaseIterable, Codable, Hashable, Sendable {
    case claude, codex, cursor

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }

    var symbolName: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .cursor: "cursorarrow"
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

    init(id: String, label: String, usedFraction: Double?, resetsAt: Date?, note: String? = nil) {
        self.id = id
        self.label = label
        self.usedFraction = usedFraction
        self.resetsAt = resetsAt
        self.note = note
    }
}

struct UsageReading: Codable, Equatable, Sendable {
    let tool: ToolID
    let windows: [LimitWindow]
    let plan: String?
    let fetchedAt: Date
    /// When the tool itself produced the numbers. Codex writes snapshots to disk, so this can trail fetchedAt.
    let observedAt: Date?
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

    var message: String {
        switch self {
        case .notSignedIn(let m), .tokenExpired(let m), .accessDenied(let m), .parse(let m), .unavailable(let m), .nothingYet(let m):
            m
        case .rateLimited(let retry):
            retry.map { "Rate limited, retrying in \(Int($0))s" } ?? "Rate limited, backing off"
        case .http(let code, let m):
            "\(m) (HTTP \(code))"
        }
    }

    /// True when the fix lives in the owning tool (sign in, refresh a login, allow Keychain) rather than a retry here.
    var needsAttention: Bool {
        switch self {
        case .notSignedIn, .tokenExpired, .accessDenied: true
        default: false
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

    var reading: UsageReading? {
        switch self {
        case .ready(let r): r
        case .needsAttention(_, let c), .failed(_, let c): c
        case .notInstalled, .off, .waiting, .idle: nil
        }
    }

    var problem: String? {
        switch self {
        case .needsAttention(let m, _), .failed(let m, _): m
        default: nil
        }
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
        [ClaudeProvider(), CodexProvider(), CursorProvider()]
    }
}

enum Paths {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
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

    static func prettify(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

enum RelativeTime {
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        if s < 86400 { return "\(Int(s / 3600))h ago" }
        return "\(Int(s / 86400))d ago"
    }

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
