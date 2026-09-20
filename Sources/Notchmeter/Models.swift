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

    /// Whether this tool's spend can be derived from something it publishes: Claude Code's transcripts, Codex's
    /// session rollouts, Cursor's priced usage-events export, and since GitHub's June 2026 move to usage-based
    /// billing the AI credit count on a Copilot seat, a cent a credit at GitHub's published rate (a seat GitHub
    /// does not meter in credits still produces no figure and no row). Antigravity meters quota rather than money,
    /// so it cannot produce a dollar figure and never appears on the Cost card (docs/accuracy.md).
    var reportsCost: Bool {
        switch self {
        case .claude, .codex, .cursor, .copilot: true
        case .antigravity: false
        }
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

/// A window's name, kept free of any one language so a reading cached in one run reads correctly in the next: the
/// fixed vocabulary travels as its English key and is looked up when the name is read, and the vendor's own words
/// (a model, an organisation) travel as they came and are never translated.
enum WindowLabel: Codable, Equatable, Sendable, ExpressibleByStringLiteral {
    /// The vendor's own words: a model, a pool.
    case vendor(String)
    /// A name from the fixed vocabulary, as its English key ("Session", "Weekly").
    case key(String)
    /// A key whose placeholders take values that carry no language of their own: the vendor's words, or a count.
    case filled(String, [Argument])
    /// A model-scoped window: the vendor's model name before another name ("Spark Session").
    indirect case scoped(model: String, of: WindowLabel)

    /// The name as the panel shows it, in the language this run is speaking.
    var text: String {
        switch self {
        case .vendor(let text): text
        case .key(let key): L(key)
        case .filled(let key, let values): String(format: Localization.string(key), arguments: values.map(\.value))
        case .scoped(let model, let inner): "\(model) \(inner.text)"
        }
    }

    /// The name inside a sentence ("you hit the Claude weekly cap"). Only the translated part is lowercased, with
    /// the running language's own casing rules; the vendor's words keep the case the vendor gave them.
    var inSentence: String {
        let locale = Locale(identifier: Localization.current)
        switch self {
        case .vendor(let text): return text
        case .key(let key): return L(key).lowercased(with: locale)
        case .filled(let key, let values): return String(format: Localization.string(key).lowercased(with: locale), arguments: values.map(\.value))
        case .scoped(let model, let inner): return "\(model) \(inner.inSentence)"
        }
    }

    /// A bare string is read as a key: a name that is not in the tables reads as itself, so this is safe for
    /// anything, while the vendor's own words are marked as such where they are built.
    init(stringLiteral value: String) { self = .key(value) }

    /// What a key's placeholders take: text `%@` reads, or a count `%ld` reads.
    enum Argument: Codable, Equatable, Sendable {
        case text(String)
        case number(Int)

        var value: CVarArg {
            switch self {
            case .text(let text): text
            case .number(let number): number
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int.self) {
                self = .number(number)
            } else {
                self = .text(try container.decode(String.self))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let text): try container.encode(text)
            case .number(let number): try container.encode(number)
            }
        }
    }

    private enum CodingKeys: String, CodingKey { case key, values, model, of }

    /// The vendor's own words encode as a bare string, which is also what every reading cached before this type
    /// existed holds.
    init(from decoder: Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            self = .vendor(text)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let model = try container.decodeIfPresent(String.self, forKey: .model) {
            self = .scoped(model: model, of: try container.decode(WindowLabel.self, forKey: .of))
            return
        }
        let key = try container.decode(String.self, forKey: .key)
        if let values = try container.decodeIfPresent([Argument].self, forKey: .values) {
            self = .filled(key, values)
        } else {
            self = .key(key)
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .vendor(let text):
            var single = encoder.singleValueContainer()
            try single.encode(text)
        case .key(let key):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(key, forKey: .key)
        case .filled(let key, let values):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(key, forKey: .key)
            try container.encode(values, forKey: .values)
        case .scoped(let model, let inner):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(model, forKey: .model)
            try container.encode(inner, forKey: .of)
        }
    }
}

struct LimitWindow: Identifiable, Codable, Equatable, Sendable {
    let id: String
    /// The window's name, localised when it is read rather than when the reading is parsed.
    let name: WindowLabel
    /// The name in this run's language.
    var label: String { name.text }

    /// A figure measured against a usual amount rather than a limit (Cursor's "Today's spend" against a usual day):
    /// it fills a ring and paces, but nothing runs out, so it never earns a run-out warning, an alert, or the advice
    /// to switch tools. A budget the user set is a limit of their own and is not one of these.
    var isComparison: Bool { id == "spend_today" }
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

    init(id: String, label: WindowLabel, usedFraction: Double?, resetsAt: Date?, note: String? = nil, periodDuration: TimeInterval? = nil, model: String? = nil,
         source: WindowSource = .vendorEndpoint, hiddenByDefault: Bool = false, rawUsedPercent: Double? = nil, amountUSD: Double? = nil) {
        self.id = id
        self.name = label
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

    /// The same window with its reset at `resetsAt`, for a reading whose reset has wandered inside the period it
    /// was first seen in (`ResetPeriod`). Everything that identifies a notification by its window embeds the
    /// reset's instant, so a window that is kept for the life of a period keeps the instant it arrived with.
    func pinningReset(to resetsAt: Date) -> LimitWindow {
        LimitWindow(id: id, label: name, usedFraction: usedFraction, resetsAt: resetsAt, note: note, periodDuration: periodDuration, model: model,
                    source: source, hiddenByDefault: hiddenByDefault, rawUsedPercent: rawUsedPercent, amountUSD: amountUSD)
    }

    private enum CodingKeys: String, CodingKey {
        case id, usedFraction, resetsAt, note, periodDuration, model, source, hiddenByDefault, rawUsedPercent, amountUSD
        case name = "label"
    }

    /// Readings cached by an earlier version carry no source; they were endpoint reads.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(WindowLabel.self, forKey: .name)
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
        LimitWindow(id: id, label: name, usedFraction: usedFraction, resetsAt: resetsAt, note: note ?? self.note,
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

    /// Whether the plan is one the user pays for, which is what makes its room worth routing work to: a free
    /// tier's window is small and has no overage behind it. The only hard signal is the plan's own name — Codex's
    /// "free" slug, Copilot's free SKU, a Claude "free" subscription — so a reading that names no plan at all, or
    /// one this cannot read, counts as paid rather than silencing the advice for every vendor that omits it.
    var isPaid: Bool {
        guard let plan = plan?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !plan.isEmpty else { return true }
        return plan != "free" && !plan.hasPrefix("free ")
    }

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

    /// The shortest a rate-limit backoff is ever allowed to be. A vendor that answers `Retry-After: 0` still gets a
    /// minute, and one that answers `Retry-After: 1800` gets ten (`rateLimitCeiling`), so the wait the message names
    /// is the wait the app takes.
    static let rateLimitFloor: TimeInterval = 60

    /// The longest, matching the other backoffs in UsageStore: a vendor's half-hour Retry-After does not hold the
    /// reading that long. The ceiling lives here beside the floor rather than in the store because `message` is
    /// what the unified log, the `--probe` transcript and the card footer all print: 0.5.0 first capped the wait in
    /// the store alone and built a second string there, so a `Retry-After: 1800` logged "retrying in 1800s" while
    /// the footer said 600s and the app waited 600s.
    static let rateLimitCeiling: TimeInterval = 600

    /// How long the app will really wait after a rate-limit answer: the vendor's own delay, clamped to
    /// [`rateLimitFloor`, `rateLimitCeiling`].
    static func rateLimitWait(retryAfter: TimeInterval?) -> TimeInterval {
        min(rateLimitCeiling, max(rateLimitFloor, retryAfter ?? 0))
    }

    var message: String {
        switch self {
        case .notSignedIn(let m), .tokenExpired(let m), .accessDenied(let m), .parse(let m), .unavailable(let m), .nothingYet(let m), .offline(let m), .apiKeyOnly(let m):
            m
        case .rateLimited(let retry):
            retry.map { L("Rate limited, retrying in %lds", Int(Self.rateLimitWait(retryAfter: $0))) } ?? L("Rate limited, backing off")
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
    /// The vendor answered 429: the cached reading stays on screen without a problem mark, and the footer names the
    /// wait. It is its own case rather than `.ready(cached)`, which is what the store used to set: `.ready` is the
    /// one status with no `staleReading`, so a 429 dropped the "Last reading … may be out of date" caption, stopped
    /// dimming the meter rows and wrote `"stale": false` into the probe JSON, the local API and the MCP server for
    /// figures that were as old as the vendor's Retry-After. A tool already showing `.failed(_, cached:)` even came
    /// out of a 429 looking healthier than it went in. With a reading cached there is no problem mark, because the
    /// footer names the wait under figures that are still worth reading, and the Advisor keeps steering by them
    /// (`UsageStore.readyReadings`); with nothing cached the wait is all there is to show, so `problem` carries it
    /// and the ring wears the mark as it did for `.failed`, rather than dimming to the "no reading yet" look.
    case rateLimited(String, cached: UsageReading?)

    /// The status a provider's error leaves a tool in, for the store and the one-shot probe alike. One mapping so
    /// that a new kind of error cannot be wired into one producer and not the other: 0.5.0 gave the store
    /// `.rateLimited` while `--probe`, and the MCP server and command-line tool falling back to it, still turned the
    /// same 429 into `.failed` with a problem to report.
    init(_ error: ProviderError, cached: UsageReading?) {
        if error.isCalm {
            self = .idle(error.message)
        } else if case .offline = error {
            self = .offline(cached: cached)
        } else if case .rateLimited = error {
            self = .rateLimited(error.message, cached: cached)
        } else if error.needsAttention {
            self = .needsAttention(error.message, cached: cached)
        } else {
            self = .failed(error.message, cached: cached)
        }
    }

    var reading: UsageReading? {
        switch self {
        case .ready(let r): r
        case .needsAttention(_, let c), .failed(_, let c), .offline(let c), .rateLimited(_, let c): c
        case .notInstalled, .off, .waiting, .idle: nil
        }
    }

    var problem: String? {
        switch self {
        case .needsAttention(let m, _), .failed(let m, _): m
        // A 429 with nothing cached has nothing to show but the wait; with a reading on screen the footer names it.
        case .rateLimited(let m, cached: .none): m
        default: nil
        }
    }

    /// Set up with nothing to show yet rather than something wrong: the tool has written nothing on this Mac for
    /// the app to read (ProviderError.isCalm). Not a fault, and the Cost card says so in those words.
    var hasNothingYet: Bool {
        if case .idle = self { return true }
        return false
    }

    /// The reading still on screen after the tool stopped answering; its numbers may be out of date.
    var staleReading: UsageReading? {
        switch self {
        case .needsAttention(_, let c), .failed(_, let c), .offline(let c), .rateLimited(_, let c): c
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
    /// A read with a note of whether the user asked for it (Refresh, the ring, the Assistants toggle) rather than
    /// a timer. Only Claude Code's provider cares, because only it has a Keychain dialog to hold back
    /// (KeychainPromptPolicy); every other provider takes the default below and reads as it always has.
    func fetch(interactive: Bool) async throws -> UsageReading
}

extension UsageProvider {
    func fetch(interactive: Bool) async throws -> UsageReading { try await fetch() }
}

/// Declared empty on purpose: the only way to build the providers is `all(defaults:)` in UsageStore.swift, which
/// wires their opt-in second reads to the preferences. An unwired overload here would win overload resolution for
/// a bare `all()` call and hand back providers whose extra reads are all switched off.
enum ProviderRegistry {}

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
    /// The long-term daily totals (CostHistory). Application Support, not Caches: this file is the only record of
    /// any day older than the transcripts, and ~/Library/Caches is both purgeable by the OS when disk runs short and
    /// left out of Time Machine, so a purge or a restore lost months of history with nothing to rebuild it from.
    static var historyFile: URL { applicationSupport.appendingPathComponent("daily-history-v1.jsonl") }
    /// Where builds before 2026-09-19 kept the daily totals; read as a fallback and moved on launch.
    static var legacyHistoryFile: URL { caches.appendingPathComponent("daily-history-v1.jsonl") }
    /// The Unix-domain socket the running app listens on for the hook and status-line commands (HookSocket.swift),
    /// since 0.6.0 in place of a distributed notification any process could read or forge. Created 0600 in a
    /// folder made 0700 at launch, removed at quit; a leftover from a crash is replaced.
    static var hookSocket: URL { applicationSupport.appendingPathComponent("hook.sock") }
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
    /// The build stamp scripts/build.sh writes into CFBundleVersion (commit, "-dirty", minute built); nil for a
    /// release, whose bundle version is a plain number and says nothing the version does not.
    static var build: String? {
        guard let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String, build.contains("-") else { return nil }
        return build
    }
    /// "0.1.0" on a release, "0.1.0 · 3d95143-dirty-20260904.1830" on a developer build. What the panel footer and
    /// Copy diagnostics show, so that a copy relaunched after an install can be told from the one it replaced —
    /// the user agent stays the bare version, because a vendor's log has no use for a commit hash.
    static var versionWithBuild: String { build.map { "\(version) · \($0)" } ?? version }
    static var userAgent: String { "\(name)/\(version)" }
    /// The optional pay-what-you-want page (Stripe Payment Link): Settings › About, the README and the site all
    /// point at this one URL, so a change here is the whole change.
    static let supportURL = URL(string: "https://buy.stripe.com/8x2bIVbYF8wsgP2cvVao800")!
}

/// Whether two reported resets are the same period.
///
/// A reset is not always a fixed instant on the wire. Claude's windows arrive with a moment that moves a little on
/// every read — three windows of one reading were seen a millisecond apart, and one window's reset wandered inside
/// a two-second band while its figure did not move at all — which is what a moment recomputed from a remaining
/// duration looks like rather than one quoted from a calendar. Compared exactly, the same period then reads as a
/// new one on every single read.
///
/// Nothing downstream wants that. `NotificationScheduler` already drew this line at ten minutes for a Codex
/// snapshot whose reset is measured from when it was written; the same line is drawn here for everyone, because no
/// real reset is ever that close to the one before it: the shortest window the app meters is five hours.
enum ResetPeriod {
    static var tolerance: TimeInterval { NotificationScheduler.samePeriodTolerance }

    static func same(_ one: Date?, _ other: Date?) -> Bool {
        switch (one, other) {
        case (nil, nil): true
        case let (first?, second?): abs(first.timeIntervalSince(second)) < tolerance
        default: false
        }
    }
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
