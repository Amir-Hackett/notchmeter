import Foundation
import Observation
import os

private let log = Logger(subsystem: "com.amirhackett.notchmeter", category: "pricing")

/// One model's dated entry in the catalog, whichever vendor's table it belongs to.
protocol PricingCatalogEntry: Equatable, Sendable {
    /// The first moment the entry's rates apply: midnight UTC on its effective day.
    var start: Date { get }
    /// One stable line for the digest: the model, the day and every rate.
    var fingerprint: String { get }
}

/// Notchmeter's published price catalog: `pricing/catalog.json` in this repository, read from the main branch,
/// so a model that launches between releases is priced at its published rate within a day instead of at the next
/// update (docs/accuracy.md, *The pricing catalog*). It can only add a row the build lacks and date a change to a
/// rate the build has; the tables compiled into the app (ModelPricing, OpenAIPricing) are never removed, and a
/// catalog that fails any check below is refused whole, leaving the last one that passed, or the build's own
/// tables, in force.
///
/// Why the main branch and not a release asset: a price changes between releases, which is the whole reason for
/// the file, so it has to be publishable by a reviewed pull request alone. `raw.githubusercontent.com` answers a
/// conditional GET with 304 and an `ETag`, so the daily check costs a few hundred bytes when nothing changed; a
/// release asset's download URL redirects to a signed, changing object URL that no conditional request can be
/// made against, and would need a release per price change besides.
///
/// Why no signature: the file is fetched over TLS from a pinned host, refused unless every field passes the
/// checks below, and can at worst state a wrong price for a model, which the Cost card then labels as the
/// catalog's. Signing it would need the release key in every pull request that edits a price, which is a larger
/// surface than the one it would close.
enum PricingCatalog {
    /// The one schema this build reads. A catalog written to a later schema is refused rather than half-read.
    static let schema = 1
    static let url = URL(string: "https://raw.githubusercontent.com/Amir-Hackett/notchmeter/main/pricing/catalog.json")!
    /// The catalog is a few kilobytes; a body past this is not the catalog.
    static let largest = 256 * 1024
    /// Dollars per million tokens a rate may state: above zero, and at most this. The dearest published rate
    /// today is $180 (OpenAI's pro tiers' output, docs/accuracy.md), so the cap leaves room for a fivefold rise
    /// and stops a rate typed in cents, and zero is refused because a rate of nothing would price real tokens at
    /// nothing, which is the one error worse than no catalog at all.
    static let mostPerMillion = 1_000.0
    /// A long-context threshold is a token count: OpenAI's is 272,000, and nothing published is under a thousand
    /// or over a hundred million.
    static let longContextRange = 1_000...100_000_000
    /// No Claude model was priced before 2020; an effective day before it is a typo.
    static let earliestDay = "2020-01-01"
    /// The preference under which the catalog is fetched and applied; on unless switched off (Preferences).
    static let preferenceKey = "pricingCatalog"

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: preferenceKey) as? Bool ?? true
    }

    // MARK: - Entries

    /// An Anthropic row: a model id prefix, matched the way ModelPricing.table is, with the standard rates and,
    /// where the page publishes one, the fast-mode row.
    struct AnthropicEntry: PricingCatalogEntry {
        let prefix: String
        let effective: String
        let start: Date
        let rates: ModelRates
        let fast: ModelRates?

        var fingerprint: String {
            let standard = Self.line(rates)
            return "\(prefix)@\(effective)=\(standard)" + (fast.map { "|fast=\(Self.line($0))" } ?? "")
        }

        static func line(_ rates: ModelRates) -> String {
            "\(rates.input)/\(rates.output)/\(rates.cacheWrite5m)/\(rates.cacheWrite1h)/\(rates.cacheRead)"
        }
    }

    /// An OpenAI row: an exact model id, matched the way OpenAIPricing.table is.
    struct OpenAIEntry: PricingCatalogEntry {
        let id: String
        let effective: String
        let start: Date
        let rates: OpenAIRates

        var fingerprint: String {
            "\(id)@\(effective)=\(rates.input)/\(rates.cachedInput)/\(rates.output)/\(rates.cacheWrite)/\(rates.longContextThreshold ?? 0)"
        }
    }

    /// One model's entries, oldest first, and which of them is in force on a date: the newest whose day has
    /// come. Before the first entry's day nothing is, and the build's own row (or its family guess) prices the
    /// line, so an entry dated the day a rate changed leaves every earlier line at the rate it was written under.
    struct Applied<Entry: PricingCatalogEntry>: Equatable, Sendable {
        let entries: [Entry]

        init(_ entries: [Entry]) {
            self.entries = entries.sorted { $0.start < $1.start }
        }

        func entry(at date: Date) -> Entry? {
            entries.last { $0.start <= date }
        }
    }

    /// A catalog that passed every check.
    struct Document: Equatable, Sendable {
        /// The day the catalog was published, as it states it.
        let published: String
        let anthropic: [AnthropicEntry]
        let openai: [OpenAIEntry]

        var count: Int { anthropic.count + openai.count }

        /// The entries by model, for the pricing tables.
        var anthropicByPrefix: [String: Applied<AnthropicEntry>] {
            Dictionary(grouping: anthropic, by: \.prefix).mapValues(Applied.init)
        }

        var openaiByID: [String: Applied<OpenAIEntry>] {
            Dictionary(grouping: openai, by: \.id).mapValues(Applied.init)
        }
    }

    /// Why a catalog was refused. The text names the field, for the log and the oracle; never the body.
    enum Failure: Error, Equatable, CustomStringConvertible {
        case tooLarge
        case notJSON
        case schema(String)
        case entry(String)

        var description: String {
            switch self {
            case .tooLarge: "larger than \(PricingCatalog.largest) bytes"
            case .notJSON: "not a JSON object"
            case .schema(let what): what
            case .entry(let what): what
            }
        }
    }

    // MARK: - Reading

    /// The document, or the first check it fails. Every field is checked before anything is applied: a catalog
    /// with one bad row is a catalog nobody validated, and the build's tables are the safer of the two.
    static func parse(_ data: Data) throws -> Document {
        guard data.count <= largest else { throw Failure.tooLarge }
        guard !data.isEmpty, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.notJSON }
        guard let schema = JSON.number(root["schema"]).flatMap({ Int(exactly: $0) }) else { throw Failure.schema("schema: not a whole number") }
        guard schema == Self.schema else { throw Failure.schema("schema \(schema): this build reads schema \(Self.schema)") }
        guard let published = root["published"] as? String, day(published) != nil else { throw Failure.schema("published: not a YYYY-MM-DD day") }
        guard let anthropicRows = root["anthropic"] as? [[String: Any]] else { throw Failure.schema("anthropic: not a list of entries") }
        guard let openaiRows = root["openai"] as? [[String: Any]] else { throw Failure.schema("openai: not a list of entries") }
        var seen: Set<String> = []
        let anthropic = try anthropicRows.enumerated().map { index, row in
            let entry = try anthropicEntry(row, at: "anthropic[\(index)]")
            guard seen.insert("a:\(entry.prefix)@\(entry.effective)").inserted else {
                throw Failure.entry("anthropic[\(index)]: \(entry.prefix) has two entries effective \(entry.effective)")
            }
            return entry
        }
        let openai = try openaiRows.enumerated().map { index, row in
            let entry = try openaiEntry(row, at: "openai[\(index)]")
            guard seen.insert("o:\(entry.id)@\(entry.effective)").inserted else {
                throw Failure.entry("openai[\(index)]: \(entry.id) has two entries effective \(entry.effective)")
            }
            return entry
        }
        return Document(published: published, anthropic: anthropic, openai: openai)
    }

    static func anthropicEntry(_ row: [String: Any], at place: String) throws -> AnthropicEntry {
        guard let prefix = row["prefix"] as? String, isModelID(prefix), prefix.hasPrefix("claude-") else {
            throw Failure.entry("\(place): prefix must be a lower-case claude- model id")
        }
        let (effective, start) = try effectiveDay(row, at: "\(place) \(prefix)")
        let rates = try rates(row, at: "\(place) \(prefix)", input: "input", output: "output", cacheRead: "cacheRead",
                              cacheWrite5m: "cacheWrite5m", cacheWrite1h: "cacheWrite1h")
        var fast: ModelRates?
        switch (try optionalRate(row, "fastInput", at: place), try optionalRate(row, "fastOutput", at: place)) {
        case (nil, nil):
            // No fast row: the build's own fast row, if it has one, keeps pricing fast lines (ModelPricing.resolve).
            break
        case (.some, .some):
            fast = try self.rates(row, at: "\(place) \(prefix) fast", input: "fastInput", output: "fastOutput", cacheRead: "fastCacheRead",
                                  cacheWrite5m: "fastCacheWrite5m", cacheWrite1h: "fastCacheWrite1h")
        default:
            throw Failure.entry("\(place) \(prefix): fastInput and fastOutput go together")
        }
        return AnthropicEntry(prefix: prefix, effective: effective, start: start, rates: rates, fast: fast)
    }

    static func openaiEntry(_ row: [String: Any], at place: String) throws -> OpenAIEntry {
        guard let id = row["id"] as? String, isModelID(id) else { throw Failure.entry("\(place): id must be a lower-case model id") }
        let (effective, start) = try effectiveDay(row, at: "\(place) \(id)")
        let input = try rate(row, "input", at: "\(place) \(id)")
        let output = try rate(row, "output", at: "\(place) \(id)")
        let cachedInput = try optionalRate(row, "cachedInput", at: "\(place) \(id)")
        if let cachedInput, cachedInput > input { throw Failure.entry("\(place) \(id): cachedInput is above input") }
        var cacheWrite = 0.0
        if let value = row["cacheWrite"] {
            // Zero is a published fact here (OpenAI bills no cache write before GPT-5.6), so the write rate alone may be nothing.
            guard let number = JSON.number(value), number.isFinite, number >= 0, number <= mostPerMillion else {
                throw Failure.entry("\(place) \(id): cacheWrite must be 0 to \(Int(mostPerMillion))")
            }
            cacheWrite = number
        }
        var longContext: Int?
        if let value = row["longContext"] {
            guard let number = JSON.number(value), let threshold = Int(exactly: number), longContextRange.contains(threshold) else {
                throw Failure.entry("\(place) \(id): longContext must be a token count from \(longContextRange.lowerBound) to \(longContextRange.upperBound)")
            }
            longContext = threshold
        }
        return OpenAIEntry(id: id, effective: effective, start: start,
                           rates: OpenAIRates(input: input, cachedInput: cachedInput, output: output, cacheWrite: cacheWrite, longContext: longContext))
    }

    private static func rates(_ row: [String: Any], at place: String, input: String, output: String, cacheRead: String,
                              cacheWrite5m: String, cacheWrite1h: String) throws -> ModelRates {
        let rates = ModelRates(input: try rate(row, input, at: place), output: try rate(row, output, at: place),
                               cacheRead: try optionalRate(row, cacheRead, at: place), cacheWrite5m: try optionalRate(row, cacheWrite5m, at: place),
                               cacheWrite1h: try optionalRate(row, cacheWrite1h, at: place))
        // A cache read never costs more than the input it stands in for; a write above the cap is a typo.
        guard rates.cacheRead <= rates.input else { throw Failure.entry("\(place): \(cacheRead) is above \(input)") }
        guard rates.cacheWrite5m <= mostPerMillion, rates.cacheWrite1h <= mostPerMillion else { throw Failure.entry("\(place): a cache write is above \(Int(mostPerMillion))") }
        return rates
    }

    /// A rate the entry must state: a finite number above zero and at most `mostPerMillion`.
    private static func rate(_ row: [String: Any], _ key: String, at place: String) throws -> Double {
        guard let value = try optionalRate(row, key, at: place) else { throw Failure.entry("\(place): \(key) is missing") }
        return value
    }

    private static func optionalRate(_ row: [String: Any], _ key: String, at place: String) throws -> Double? {
        guard let value = row[key] else { return nil }
        guard let number = JSON.number(value), number.isFinite, number > 0, number <= mostPerMillion else {
            throw Failure.entry("\(place): \(key) must be above 0 and at most \(Int(mostPerMillion)) dollars per million tokens")
        }
        return number
    }

    private static func effectiveDay(_ row: [String: Any], at place: String) throws -> (String, Date) {
        guard let effective = row["effective"] as? String, let start = day(effective) else {
            throw Failure.entry("\(place): effective must be a YYYY-MM-DD day")
        }
        guard effective >= earliestDay else { throw Failure.entry("\(place): effective \(effective) is before \(earliestDay)") }
        return (effective, start)
    }

    /// A model id as the tables spell them: lower case, digits, dots and hyphens, and short.
    static func isModelID(_ text: String) -> Bool {
        guard (2...64).contains(text.count), let first = text.unicodeScalars.first, first != "-", first != "." else { return false }
        return text.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "." }
    }

    /// A `YYYY-MM-DD` day as midnight UTC, so an effective day reads the same on every Mac; nil for anything
    /// that is not one.
    static func day(_ text: String) -> Date? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard text.count == 10, parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let dayOfMonth = Int(parts[2])
        else { return nil }
        let components = DateComponents(year: year, month: month, day: dayOfMonth)
        guard components.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: components)
    }

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// FNV-1a over the lines in order: the same lines, the same string, on any run (OpenAIPricing.digest does the
    /// same over its rows).
    static func digest(_ lines: [String]) -> String {
        guard !lines.isEmpty else { return "" }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for line in lines.sorted() {
            for byte in (line + ";").utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        }
        return String(hash, radix: 36)
    }

    // MARK: - Applying

    /// Puts the document's entries into both pricing tables, or takes them out again with nil. Returns whether
    /// a rate any lookup could answer with changed, which is when cached digests have to be re-priced.
    @discardableResult
    static func apply(_ document: Document?) -> Bool {
        let anthropicBefore = ModelPricing.book.digest
        let openaiBefore = OpenAIPricing.book.digest
        ModelPricing.book = ModelPricing.Book(catalog: document?.anthropicByPrefix ?? [:])
        OpenAIPricing.book = OpenAIPricing.Book(catalog: document?.openaiByID ?? [:])
        return ModelPricing.book.digest != anthropicBefore || OpenAIPricing.book.digest != openaiBefore
    }

    /// The document in force, read back from the tables; nil while none is applied.
    static var applied: Bool { !ModelPricing.book.isBuiltIn || !OpenAIPricing.book.isBuiltIn }

    /// What the app keeps between launches: the last catalog that passed, when the server last confirmed it (a
    /// 200 with a new body, or a 304 for the one held), and the validators for the next conditional request. In
    /// ~/Library/Caches, because it is public data the next fetch replaces and the OS may purge.
    struct Cache: Equatable, Sendable {
        let body: Data
        let fetchedAt: Date
        let etag: String?
        let lastModified: String?

        static var file: URL { Paths.caches.appendingPathComponent("pricing-catalog-v1.json") }

        /// The cached catalog, only if it still passes every check this build makes: a file written by a build
        /// with another schema, or damaged on disk, is dropped rather than half-read.
        static func load(from url: URL = file) -> (cache: Cache, document: Document)? {
            guard let data = try? Data(contentsOf: url), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let stamp = root["fetchedAt"] as? String, let fetchedAt = DateParsing.iso8601(stamp),
                  let catalog = root["catalog"], JSONSerialization.isValidJSONObject(catalog),
                  let body = try? JSONSerialization.data(withJSONObject: catalog, options: [.sortedKeys]),
                  let document = try? parse(body)
            else { return nil }
            return (Cache(body: body, fetchedAt: fetchedAt, etag: root["etag"] as? String, lastModified: root["lastModified"] as? String), document)
        }

        func save(to url: URL = file) throws {
            let catalog = try JSONSerialization.jsonObject(with: body)
            var root: [String: Any] = ["fetchedAt": Oracle.timestamp(fetchedAt), "catalog": catalog]
            root["etag"] = etag
            root["lastModified"] = lastModified
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]).write(to: url, options: .atomic)
        }

        /// The same catalog, confirmed again by a 304.
        func confirmed(at date: Date) -> Cache {
            Cache(body: body, fetchedAt: date, etag: etag, lastModified: lastModified)
        }
    }

    /// Applies the cached catalog, if there is one and the switch is on, before anything prices a line: the app,
    /// `--probe` and the MCP server all start here, so the command-line tool prices the way the app does.
    @discardableResult
    static func applyCached(enabled: Bool = isEnabled(), from url: URL = Cache.file) -> Document? {
        guard enabled, let (_, document) = Cache.load(from: url) else {
            apply(nil)
            return nil
        }
        apply(document)
        return document
    }

    // MARK: - Fetching

    /// What one request came back with.
    enum Fetched: Equatable, Sendable {
        /// 200 with a body that passed every check.
        case updated(Cache, Document)
        /// 304: the catalog held is still the one published.
        case unchanged
        /// 200 with a body that failed a check; the one held stays.
        case refused(String)
        /// No answer, or a status that is neither; the one held stays.
        case failed(String)
    }

    /// One plain GET, conditional on the catalog held: `If-None-Match` with its ETag and `If-Modified-Since` with
    /// its date, so an unchanged file answers 304 and no body. The app's own User-Agent and nothing that says
    /// anything about the user: no cookie is sent or kept, and the language is fixed at English rather than left
    /// to the system, which would otherwise name the Mac's preferred languages in `Accept-Language`. Follows the
    /// proxy the vendor requests follow.
    static func fetch(cache: Cache?, session: URLSession = NetworkSession.shared, now: Date = Date()) async -> Fetched {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.httpShouldHandleCookies = false
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        if let etag = cache?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let since = cache?.lastModified { request.setValue(since, forHTTPHeaderField: "If-Modified-Since") }
        guard let (data, response) = try? await session.data(for: request) else {
            log.info("pricing catalog: no answer")
            return .failed("no answer")
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        DiagnosticLog.request(log, "pricing catalog", status: status, bytes: data.count)
        switch status {
        case 304:
            return cache == nil ? .failed("304 with nothing held") : .unchanged
        case 200:
            do {
                let document = try parse(data)
                let fresh = Cache(body: data, fetchedAt: now, etag: http?.value(forHTTPHeaderField: "ETag"),
                                  lastModified: http?.value(forHTTPHeaderField: "Last-Modified"))
                return .updated(fresh, document)
            } catch {
                log.error("pricing catalog refused: \(String(describing: error), privacy: .public)")
                return .refused(String(describing: error))
            }
        default:
            return .failed("HTTP \(status)")
        }
    }

    /// When the next request is due: a day after the last that answered, and after one that did not, an hour
    /// later, doubling with each failure in a row up to the same day. A catalog confirmed within the day at launch
    /// is not asked for again until the day is up.
    enum Refresh {
        static let interval: TimeInterval = 24 * 3600
        static let firstRetry: TimeInterval = 3600

        static func wait(after failures: Int) -> TimeInterval {
            guard failures > 0 else { return interval }
            return min(interval, firstRetry * pow(2, Double(min(failures, 16) - 1)))
        }

        /// `confirmedAt` is when the server last stood behind the catalog held, `attemptedAt` the last request
        /// made this launch, whether or not it was answered. A stamp after `now` means the clock went back, and
        /// is not waited out.
        static func isDue(enabled: Bool, confirmedAt: Date?, attemptedAt: Date?, failures: Int, now: Date) -> Bool {
            guard enabled else { return false }
            if let attemptedAt, attemptedAt <= now, now.timeIntervalSince(attemptedAt) < wait(after: failures) { return false }
            guard let confirmedAt, confirmedAt <= now else { return true }
            return now.timeIntervalSince(confirmedAt) >= interval
        }
    }
}

/// Fetches the catalog when `PricingCatalog.Refresh` says a request is due, at launch and on a quarter-hour check
/// while the app runs, and applies whatever passes. Never while the switch is off, which also takes the catalog
/// out of the tables; switching it back on applies the cached one at once. One request at a time; a catalog that
/// changes a rate re-runs the cost scan (`rescan`) so the card re-prices now rather than at the next tick.
@MainActor
@Observable
final class PricingCatalogFetcher {
    typealias Load = @MainActor (PricingCatalog.Cache?) async -> PricingCatalog.Fetched

    /// What Settings and the oracle say about the catalog.
    struct Status: Equatable, Sendable {
        enum Outcome: String, Equatable, Sendable { case applied, unchanged, refused, failed }

        /// The published day of the catalog in force, and its entry count; nil while the build's tables alone are.
        var published: String?
        var entries = 0
        /// When the server last confirmed the catalog held (from the cache at launch, then each answer).
        var confirmedAt: Date?
        /// The last request's outcome this launch; nil before one is made.
        var lastOutcome: Outcome?

        /// The line under the switch in Settings: which prices are in use, and when the catalog was last confirmed.
        func settingsLine(enabled: Bool, now: Date = Date()) -> String {
            let build = PriceSource.dayText(ModelPricing.snapshotDate)
            guard enabled else { return L("Off. Prices come from this build (%@) and your own overrides.", build) }
            // A catalog in force always has the moment the server last stood behind it (put sets both).
            if let published, let confirmedAt {
                return L("Catalog of %1$@ in use, last confirmed %2$@.", PriceSource.dayText(published), RelativeTime.ago(confirmedAt, now: now))
            }
            switch lastOutcome {
            case .refused, .failed: return L("The catalog could not be used; this build's prices (%@) stand until it can be.", build)
            default: return L("Not fetched yet; this build's prices (%@) are in use.", build)
            }
        }

        /// For the oracle's `pricing` event and the snapshot.
        var oracleFields: [String: Any] {
            ["published": published as Any, "entries": entries, "confirmedAt": confirmedAt.map(Oracle.timestamp) as Any,
             "outcome": lastOutcome?.rawValue as Any]
        }
    }

    private(set) var status = Status()

    @ObservationIgnored private let prefs: Preferences
    @ObservationIgnored private let load: Load
    @ObservationIgnored private let rescan: () -> Void
    @ObservationIgnored private let cacheFile: URL
    @ObservationIgnored private var cache: PricingCatalog.Cache?
    @ObservationIgnored private var attemptedAt: Date?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var inFlight = false

    /// How often the clock looks. Looking is free (a comparison of dates); only a due check makes a request.
    static let checkEvery: Duration = .seconds(15 * 60)

    init(prefs: Preferences, cacheFile: URL = PricingCatalog.Cache.file, rescan: @escaping () -> Void = {},
         load: @escaping Load = { await PricingCatalog.fetch(cache: $0) }) {
        self.prefs = prefs
        self.cacheFile = cacheFile
        self.rescan = rescan
        self.load = load
    }

    func start() {
        applyCache(from: "cache")
        observe()
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshIfDue()
                try? await Task.sleep(for: Self.checkEvery)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// The switch changed: apply or withdraw the cached catalog now, and look for a fetch now rather than at the
    /// next quarter hour. The tracking is one-shot, and its handler runs before the new value lands, so the look
    /// is made from a task that runs after it.
    private func observe() {
        withObservationTracking {
            _ = prefs.pricingCatalog
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observe()
                self?.applyCache(from: "switch")
                await self?.refreshIfDue()
            }
        }
    }

    /// The cached catalog into the tables while the switch is on, and out of them while it is off.
    private func applyCache(from origin: String) {
        guard prefs.pricingCatalog else {
            let changed = PricingCatalog.apply(nil)
            status.published = nil
            status.entries = 0
            Oracle.shared.emit("pricing", ["action": "off", "from": origin])
            if changed { rescan() }
            return
        }
        guard let (cache, document) = PricingCatalog.Cache.load(from: cacheFile) else {
            self.cache = nil
            PricingCatalog.apply(nil)
            return
        }
        self.cache = cache
        put(document, cache: cache, from: origin)
    }

    private func put(_ document: PricingCatalog.Document, cache: PricingCatalog.Cache, from origin: String) {
        let changed = PricingCatalog.apply(document)
        status.published = document.published
        status.entries = document.count
        status.confirmedAt = cache.fetchedAt
        Oracle.shared.emit("pricing", ["action": "applied", "from": origin, "published": document.published, "entries": document.count, "changed": changed])
        if changed { rescan() }
    }

    /// Makes the request when one is due. Returns whether one was made, for the tests.
    @discardableResult
    func refreshIfDue(now: Date = Date()) async -> Bool {
        guard !inFlight, PricingCatalog.Refresh.isDue(enabled: prefs.pricingCatalog, confirmedAt: cache?.fetchedAt, attemptedAt: attemptedAt,
                                                        failures: failures, now: now) else { return false }
        inFlight = true
        defer { inFlight = false }
        attemptedAt = now
        // Counted up before the request and back to zero after an answer, so a request the app never came back
        // from (a crash, a quit) counts as a failure rather than a success.
        failures += 1
        let fetched = await load(cache)
        guard prefs.pricingCatalog else { return true }
        switch fetched {
        case .updated(let fresh, let document):
            failures = 0
            cache = fresh
            do { try fresh.save(to: cacheFile) } catch { log.error("pricing catalog: cache not written: \(String(describing: error), privacy: .public)") }
            status.lastOutcome = .applied
            put(document, cache: fresh, from: "network")
        case .unchanged:
            failures = 0
            if let held = cache {
                let confirmed = held.confirmed(at: now)
                cache = confirmed
                try? confirmed.save(to: cacheFile)
                status.confirmedAt = now
            }
            status.lastOutcome = .unchanged
            Oracle.shared.emit("pricing", ["action": "unchanged", "from": "network", "published": status.published as Any])
        case .refused(let why):
            status.lastOutcome = .refused
            Oracle.shared.emit("pricing", ["action": "refused", "from": "network", "why": why, "failures": failures])
        case .failed(let why):
            status.lastOutcome = .failed
            Oracle.shared.emit("pricing", ["action": "failed", "from": "network", "why": why, "failures": failures])
        }
        return true
    }

    /// For `--render-assets`: the state the Settings picture shows, without a file or a request.
    func seed(published: String, entries: Int, confirmedAt: Date) {
        status = Status(published: published, entries: entries, confirmedAt: confirmedAt, lastOutcome: .unchanged)
    }
}
