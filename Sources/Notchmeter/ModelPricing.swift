import Foundation
import os

/// Token buckets as Claude Code records them per assistant message.
struct TokenBreakdown: Codable, Equatable, Sendable {
    var input = 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0
    var cacheRead = 0
    var output = 0

    var total: Int { input + cacheWrite5m + cacheWrite1h + cacheRead + output }

    /// Share of every token that was a cache read, 0...1; nil with no tokens at all.
    var cacheReadShare: Double? {
        total > 0 ? Double(cacheRead) / Double(total) : nil
    }

    static func + (lhs: TokenBreakdown, rhs: TokenBreakdown) -> TokenBreakdown {
        TokenBreakdown(input: lhs.input + rhs.input, cacheWrite5m: lhs.cacheWrite5m + rhs.cacheWrite5m,
                       cacheWrite1h: lhs.cacheWrite1h + rhs.cacheWrite1h, cacheRead: lhs.cacheRead + rhs.cacheRead, output: lhs.output + rhs.output)
    }

    static func += (lhs: inout TokenBreakdown, rhs: TokenBreakdown) {
        lhs = lhs + rhs
    }
}

/// Anthropic list prices in dollars per million tokens.
struct ModelRates: Equatable, Sendable, Codable {
    let input: Double
    let output: Double
    let cacheWrite5m: Double
    let cacheWrite1h: Double
    let cacheRead: Double

    /// Standard multipliers: 5-minute cache writes 1.25x input, 1-hour writes 2x, cache reads 0.1x.
    init(input: Double, output: Double, cacheRead: Double? = nil, cacheWrite5m: Double? = nil, cacheWrite1h: Double? = nil) {
        self.input = input
        self.output = output
        self.cacheWrite5m = cacheWrite5m ?? input * 1.25
        self.cacheWrite1h = cacheWrite1h ?? input * 2
        self.cacheRead = cacheRead ?? input * 0.1
    }

    func cost(_ tokens: TokenBreakdown) -> Double {
        (Double(tokens.input) * input
            + Double(tokens.output) * output
            + Double(tokens.cacheWrite5m) * cacheWrite5m
            + Double(tokens.cacheWrite1h) * cacheWrite1h
            + Double(tokens.cacheRead) * cacheRead) / 1_000_000
    }
}

/// Where the rate a line was priced at came from. The cases are in the order a lookup tries them, which is the
/// precedence docs/accuracy.md writes out: the user's own file, Claude Code's table, then the build's rows and
/// Notchmeter's catalog as one table, then the family guess.
///
/// Recorded per priced line into the digest buckets and the day records (FileDigest.Bucket, CostHistory.Record),
/// so a range names the sources of the lines inside it and nothing else; stored as its `key`, never a case number.
enum PriceSource: Hashable, Sendable, Codable {
    /// Notchmeter's `pricing-overrides.json`.
    case overrides
    /// Claude Code's `modelPricing` in its settings.json.
    case claudeCode
    /// Notchmeter's published catalog (PricingCatalog), with the effective date of the entry that applied.
    case catalog(String)
    /// The table compiled into this build, with its snapshot date.
    case builtIn(String)
    /// No row at all: the family's newest rate, a guess made so a fresh model is not priced at nothing.
    case family

    /// The stable word for the probe, the report and the oracle: `builtIn:2026-09-24`, `catalog:2026-09-24`.
    var key: String {
        switch self {
        case .overrides: "overrides"
        case .claudeCode: "claudeCode"
        case .catalog(let date): "catalog:\(date)"
        case .builtIn(let date): "builtIn:\(date)"
        case .family: "family"
        }
    }

    /// The source a key names; nil for a word no build has written, which a reader treats as a record it
    /// cannot use rather than a source of some kind.
    init?(key: String) {
        switch key {
        case "overrides": self = .overrides
        case "claudeCode": self = .claudeCode
        case "family": self = .family
        default:
            if key.hasPrefix("catalog:") { self = .catalog(String(key.dropFirst("catalog:".count))) }
            else if key.hasPrefix("builtIn:") { self = .builtIn(String(key.dropFirst("builtIn:".count))) }
            else { return nil }
        }
    }

    init(from decoder: Decoder) throws {
        let key = try decoder.singleValueContainer().decode(String.self)
        guard let source = PriceSource(key: key) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "not a price source: \(key)"))
        }
        self = source
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(key)
    }

    /// The order the Cost card names them in: precedence first, so the source that outranks the rest leads.
    var rank: Int {
        switch self {
        case .overrides: 0
        case .claudeCode: 1
        case .catalog: 2
        case .builtIn: 3
        case .family: 4
        }
    }

    /// The words the Cost card and Settings use for a source, the dated ones with their day.
    var label: String {
        switch self {
        case .overrides: L("your pricing-overrides.json")
        case .claudeCode: L("Claude Code's modelPricing")
        case .catalog(let date): L("Notchmeter's catalog of %@", Self.dayText(date))
        case .builtIn(let date): L("this build's table of %@", Self.dayText(date))
        case .family: L("a family guess")
        }
    }

    /// The card's line naming every source that priced the range, precedence first and, within a source, the
    /// newer day first; nil when nothing was priced here (a card of vendor figures alone has no list price).
    /// Joined by the middle dot the card's other captions use, because a dated label has a comma of its own in
    /// English ("Sep 24, 2026") and a comma between two of them left the reader parsing dates to find the seam.
    static func line(_ sources: Set<PriceSource>) -> String? {
        guard !sources.isEmpty else { return nil }
        let ordered = sources.sorted { ($0.rank, $1.key) < ($1.rank, $0.key) }
        return L("Prices: %@", ordered.map(\.label).joined(separator: " · "))
    }

    /// "Sep 24, 2026" in the app's own language for a `YYYY-MM-DD` snapshot day; the day as written when it is
    /// not one. The year stays: a table's age is the point of naming its day.
    static func dayText(_ day: String) -> String {
        guard let date = PricingCatalog.day(day) else { return day }
        let formatter = DateFormatter()
        formatter.calendar = PricingCatalog.calendar
        formatter.timeZone = PricingCatalog.calendar.timeZone
        formatter.locale = Locale(identifier: Localization.current)
        formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        return formatter.string(from: date)
    }
}

/// Prices as published on platform.claude.com, snapshot 2026-09-24 (`ModelPricing.snapshotDate`; the committed copy
/// is `Sources/Notchmeter/Resources/pricing-snapshot.json`, which `.github/workflows/pricing.yml` diffs against the
/// live page, as it does `pricing/catalog.json`).
/// Unknown versions fall back to their family's newest rate so a fresh model still prices roughly right until the
/// table is updated. Overrides (Claude Code's `modelPricing`, or Notchmeter's own file) win over the table, and
/// Notchmeter's catalog (PricingCatalog) adds rows to it and updates them from their effective dates.
enum ModelPricing {
    static let snapshotDate = "2026-09-24"
    static let fable51 = ModelRates(input: 10, output: 50, cacheRead: 0.25)
    static let fable5 = ModelRates(input: 10, output: 50, cacheRead: 1.0)
    /// Opus 5.5 reads its cache at 0.05x input ($0.20), the page's own exception to the 0.1x rule.
    static let opus55 = ModelRates(input: 4, output: 20, cacheRead: 0.2)
    static let opus5 = ModelRates(input: 5, output: 25)
    static let opusLegacy = ModelRates(input: 15, output: 75)
    static let sonnet5 = ModelRates(input: 2, output: 10)
    static let sonnetLegacy = ModelRates(input: 3, output: 15)
    static let haiku45 = ModelRates(input: 1, output: 5)
    static let haiku35 = ModelRates(input: 0.8, output: 4)
    static let haiku3 = ModelRates(input: 0.25, output: 1.25)
    /// Fast mode bills Opus 5 and Opus 4.8 at twice the standard token rates.
    static let opusFast = ModelRates(input: 10, output: 50)
    /// Fast mode on Opus 5.5 is its own row ($8/$40), and the page stacks the caching multipliers on it, the
    /// model's 0.05x cache read included.
    static let opus55Fast = ModelRates(input: 8, output: 40, cacheRead: 0.4)
    /// Web search: $10 per 1,000 requests, never multiplied by residency.
    static let webSearchRequest = 0.01

    /// The longest matching prefix wins, so `claude-opus-4-8` takes its own row rather than `claude-opus-4`'s and
    /// a row may be added anywhere without shadowing one already here. The order below is presentation only.
    ///
    /// `claude-opus-5-5` needs its own row for the same reason: without it the id is a prefix match for
    /// `claude-opus-5`, and Opus 5.5 was priced as Opus 5, a quarter too high, under a "built-in" label.
    static let table: [(prefix: String, rates: ModelRates)] = [
        ("claude-fable-5-1", fable51), ("claude-mythos-5-1", fable51),
        ("claude-fable-5", fable5), ("claude-mythos-5", fable5),
        ("claude-opus-5-5", opus55),
        ("claude-opus-5", opus5), ("claude-opus-4-8", opus5), ("claude-opus-4-7", opus5),
        ("claude-opus-4-6", opus5), ("claude-opus-4-5", opus5),
        ("claude-opus-4-1", opusLegacy), ("claude-opus-4", opusLegacy),
        ("claude-sonnet-5", sonnet5),
        ("claude-sonnet-4-6", sonnetLegacy), ("claude-sonnet-4-5", sonnetLegacy), ("claude-sonnet-4", sonnetLegacy),
        ("claude-3-7-sonnet", sonnetLegacy), ("claude-3-5-sonnet", sonnetLegacy),
        ("claude-haiku-4-5", haiku45),
        ("claude-3-5-haiku", haiku35),
        ("claude-3-haiku", haiku3),
    ]

    /// The fast-mode rate of a row in `table`, under the same prefix. A row with none ignores the marker, which is
    /// what the page says of Opus 4.6 ("billed at standard rates").
    static let fastTable: [(prefix: String, rates: ModelRates)] = [
        ("claude-opus-5-5", opus55Fast), ("claude-opus-5", opusFast), ("claude-opus-4-8", opusFast),
    ]

    /// Rates by normalised model id that replace the table, and which of them came from Claude Code's settings
    /// rather than Notchmeter's own file (for the Cost card's price line).
    private struct Overrides {
        var rates: [String: ModelRates] = [:]
        var fromClaudeCode: Set<String> = []
    }

    private static let overrideState = OSAllocatedUnfairLock<Overrides>(initialState: Overrides())

    /// Rates by normalised model id that replace the table; longest prefix wins, as in the table. Set directly,
    /// every row counts as Notchmeter's own file.
    static var overrides: [String: ModelRates] {
        get { overrideState.withLock { $0.rates } }
        set { overrideState.withLock { $0 = Overrides(rates: newValue) } }
    }

    /// One row of the table a lookup walks: the build's rates for a prefix, the catalog's entries for it, or both.
    struct Row: Equatable, Sendable {
        let prefix: String
        let builtIn: ModelRates?
        let builtInFast: ModelRates?
        let catalog: PricingCatalog.Applied<PricingCatalog.AnthropicEntry>?

        /// Whether an entry only repeats what the build's row already says. Such an entry is not an update: the
        /// number is the build's and is labelled so, and a catalog that restates the whole table changes nothing.
        func repeatsBuild(_ entry: PricingCatalog.AnthropicEntry) -> Bool {
            entry.rates == builtIn && (entry.fast == nil || entry.fast == builtInFast)
        }

        /// Whether any lookup on this row can answer differently from the build alone. Every entry then counts
        /// towards the digest, a repeating one included: after an update, an entry that returns to the build's
        /// rate is what ends the update, and a lookup after its day depends on it.
        var alters: Bool {
            catalog?.entries.contains { !repeatsBuild($0) } ?? false
        }
    }

    /// The build's rows and the catalog's merged, longest prefix first, so the first row that matches is the one
    /// the longest-prefix rule picks. Rebuilt when a catalog is applied; the build's alone until then.
    struct Book: Equatable, Sendable {
        let rows: [Row]
        /// The catalog entries that can change an answer, as a digest for the fingerprint; empty with none.
        let digest: String

        static let builtIn = Book(catalog: [:])

        init(catalog: [String: PricingCatalog.Applied<PricingCatalog.AnthropicEntry>]) {
            var rows: [String: Row] = [:]
            for (prefix, rates) in ModelPricing.table {
                rows[prefix] = Row(prefix: prefix, builtIn: rates, builtInFast: ModelPricing.fastTable.first { $0.prefix == prefix }?.rates,
                                   catalog: catalog[prefix])
            }
            for (prefix, applied) in catalog where rows[prefix] == nil {
                rows[prefix] = Row(prefix: prefix, builtIn: nil, builtInFast: nil, catalog: applied)
            }
            // Longest first; equal lengths cannot both prefix one id, so their order only has to be stable.
            self.rows = rows.values.sorted { ($0.prefix.count, $0.prefix) > ($1.prefix.count, $1.prefix) }
            digest = PricingCatalog.digest(self.rows.filter(\.alters).flatMap { $0.catalog?.entries.map(\.fingerprint) ?? [] })
        }

        /// True while no catalog entry can change an answer: the build's tables alone, whatever was applied.
        var isBuiltIn: Bool { digest.isEmpty }
    }

    private static let bookState = OSAllocatedUnfairLock<Book>(initialState: .builtIn)

    /// The table lookups walk. Only PricingCatalog sets it.
    static var book: Book {
        get { bookState.withLock { $0 } }
        set { bookState.withLock { $0 = newValue } }
    }

    /// Changes whenever a rate the scanner would apply changes, so cached digests priced under other rates are not
    /// reused. Without a catalog entry in force it is the string it always was, so switching the catalog on changes
    /// nothing cached until the catalog actually changes a price.
    static var fingerprint: String {
        let pairs = overrides.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.input)/\($0.value.output)/\($0.value.cacheWrite5m)/\($0.value.cacheWrite1h)/\($0.value.cacheRead)" }
        let catalog = book.digest
        return snapshotDate + "|" + pairs.joined(separator: ";") + (catalog.isEmpty ? "" : "|catalog=\(catalog)")
    }

    /// A rate and where it came from.
    struct Priced: Equatable, Sendable {
        let rates: ModelRates
        let source: PriceSource
    }

    /// The rate a line of `model` written at `date` is priced at, and its source. `date` matters only where the
    /// catalog updates one of the build's rows: a line before the update's effective date keeps the build's rate.
    static func resolve(_ model: String, speed: String? = nil, at date: Date = Date()) -> Priced? {
        let name = normalize(model)
        let overrides = overrideState.withLock { $0 }
        if !overrides.rates.isEmpty, let hit = overrides.rates.keys.filter({ name.hasPrefix($0) }).max(by: { $0.count < $1.count }),
           let rates = overrides.rates[hit] {
            return Priced(rates: rates, source: overrides.fromClaudeCode.contains(hit) ? .claudeCode : .overrides)
        }
        let fast = speed == "fast"
        for row in book.rows where name.hasPrefix(row.prefix) {
            if let entry = row.catalog?.entry(at: date) {
                let built = PriceSource.builtIn(snapshotDate)
                let updated = PriceSource.catalog(entry.effective)
                if fast, let entryFast = entry.fast {
                    return Priced(rates: entryFast, source: entryFast == row.builtInFast ? built : updated)
                }
                // An entry that states no fast rate updates the standard one only; the build's fast row stands.
                if fast, let builtInFast = row.builtInFast { return Priced(rates: builtInFast, source: built) }
                return Priced(rates: entry.rates, source: entry.rates == row.builtIn ? built : updated)
            }
            if let builtIn = row.builtIn {
                return Priced(rates: fast ? (row.builtInFast ?? builtIn) : builtIn, source: .builtIn(snapshotDate))
            }
        }
        let family: ModelRates? =
            if name.contains("fable") || name.contains("mythos") { fable51 }
            else if name.contains("opus") { fast ? opus55Fast : opus55 }
            else if name.contains("sonnet") { sonnet5 }
            else if name.contains("haiku") { haiku45 }
            else { nil }
        return family.map { Priced(rates: $0, source: .family) }
    }

    static func rates(for model: String, speed: String? = nil, at date: Date = Date()) -> ModelRates? {
        resolve(model, speed: speed, at: date)?.rates
    }

    /// Claude Code prices a response whose `usage.inference_geo` is "us" at 1.1x list on every token bucket;
    /// "global", "not_available" and a missing field all stay at list. Per-request fees are never multiplied.
    static func residencyMultiplier(inferenceGeo: String?) -> Double {
        inferenceGeo == "us" ? 1.1 : 1
    }

    static func cost(of tokens: TokenBreakdown, model: String?, inferenceGeo: String? = nil, speed: String? = nil, at date: Date = Date()) -> Double? {
        guard let model, let rates = rates(for: model, speed: speed, at: date) else { return nil }
        return rates.cost(tokens) * residencyMultiplier(inferenceGeo: inferenceGeo)
    }

    /// Bedrock/Vertex ids (`anthropic.claude-…`, `claude-…@20250101`) and dated suffixes all collapse to the plain id.
    static func normalize(_ model: String) -> String {
        var name = model.lowercased()
        if let at = name.firstIndex(of: "@") { name = String(name[..<at]) }
        if let dot = name.lastIndex(of: "."), name.hasPrefix("anthropic.") || name.hasPrefix("us.") || name.hasPrefix("eu.") {
            name = String(name[name.index(after: dot)...])
        }
        return name
    }

    // MARK: - Overrides

    /// Loads Claude Code's own `modelPricing` from its settings.json (so the estimate matches what Claude Code shows)
    /// and then Notchmeter's `pricing-overrides.json` in Application Support, which wins on a clash.
    static func loadOverrides(claudeSettings: URL = HookSettings.settingsURL,
                              own: URL = Paths.applicationSupport.appendingPathComponent("pricing-overrides.json")) {
        var claudeCode: [String: ModelRates] = [:]
        if let data = try? Data(contentsOf: claudeSettings),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            claudeCode = parseOverrides(root["modelPricing"])
        }
        var mine: [String: ModelRates] = [:]
        if let data = try? Data(contentsOf: own), let root = try? JSONSerialization.jsonObject(with: data) {
            mine = parseOverrides((root as? [String: Any])?["modelPricing"] ?? root)
        }
        let merged = claudeCode.merging(mine) { _, new in new }
        let fromClaudeCode = Set(claudeCode.keys).subtracting(mine.keys)
        overrideState.withLock { $0 = Overrides(rates: merged, fromClaudeCode: fromClaudeCode) }
    }

    /// `{"claude-opus-5": {"input": 5, "output": 25, "cacheRead": 0.5, "cacheWrite": 6.25, "cacheWrite1h": 10}}`, dollars
    /// per million tokens; snake_case and `_tokens` spellings are accepted, missing cache rates derive from input.
    static func parseOverrides(_ value: Any?) -> [String: ModelRates] {
        guard let table = value as? [String: Any] else { return [:] }
        var result: [String: ModelRates] = [:]
        for (model, entry) in table {
            guard let fields = entry as? [String: Any], let input = number(fields, "input"), let output = number(fields, "output") else { continue }
            result[normalize(model)] = ModelRates(input: input, output: output, cacheRead: number(fields, "cacheRead"),
                                                  cacheWrite5m: number(fields, "cacheWrite") ?? number(fields, "cacheWrite5m"),
                                                  cacheWrite1h: number(fields, "cacheWrite1h"))
        }
        return result
    }

    private static func number(_ fields: [String: Any], _ key: String) -> Double? {
        let snake = key.replacingOccurrences(of: "([A-Z0-9]+)", with: "_$1", options: .regularExpression).lowercased()
        for candidate in [key, snake, key + "Tokens", snake + "_tokens", key + "_per_million", snake + "_per_million"] {
            if let value = JSON.number(fields[candidate]) { return value }
        }
        return nil
    }
}
