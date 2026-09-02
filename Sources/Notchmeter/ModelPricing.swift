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

/// Prices as published on anthropic.com, snapshot 2026-09-01 (`ModelPricing.snapshotDate`; the committed copy is
/// `Sources/Notchmeter/pricing-snapshot.json`, which `.github/workflows/pricing.yml` diffs against the live page).
/// Unknown versions fall back to their family's newest rate so a fresh model still prices roughly right until the
/// table is updated. Overrides (Claude Code's `modelPricing`, or Notchmeter's own file) win over the table.
enum ModelPricing {
    static let snapshotDate = "2026-09-01"
    static let fable51 = ModelRates(input: 10, output: 50, cacheRead: 0.25)
    static let fable5 = ModelRates(input: 10, output: 50, cacheRead: 1.0)
    static let opus5 = ModelRates(input: 5, output: 25)
    static let opusLegacy = ModelRates(input: 15, output: 75)
    static let sonnet5 = ModelRates(input: 2, output: 10)
    static let sonnetLegacy = ModelRates(input: 3, output: 15)
    static let haiku45 = ModelRates(input: 1, output: 5)
    static let haiku35 = ModelRates(input: 0.8, output: 4)
    static let haiku3 = ModelRates(input: 0.25, output: 1.25)
    /// Fast mode bills Opus 5 and Opus 4.8 at twice the standard token rates.
    static let opusFast = ModelRates(input: 10, output: 50)
    /// Web search: $10 per 1,000 requests, never multiplied by residency.
    static let webSearchRequest = 0.01

    /// The longest matching prefix wins, so `claude-opus-4-8` takes its own row rather than `claude-opus-4`'s and
    /// a row may be added anywhere without shadowing one already here. The order below is presentation only.
    static let table: [(prefix: String, rates: ModelRates)] = [
        ("claude-fable-5-1", fable51), ("claude-mythos-5-1", fable51),
        ("claude-fable-5", fable5), ("claude-mythos-5", fable5),
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

    /// Models with a fast-mode rate, matched the same way.
    static let fastTable: [(prefix: String, rates: ModelRates)] = [
        ("claude-opus-5", opusFast), ("claude-opus-4-8", opusFast),
    ]

    private static let overrideState = OSAllocatedUnfairLock<[String: ModelRates]>(initialState: [:])

    /// Rates by normalised model id that replace the table; longest prefix wins, as in the table.
    static var overrides: [String: ModelRates] {
        get { overrideState.withLock { $0 } }
        set { overrideState.withLock { $0 = newValue } }
    }

    /// Changes whenever a rate the scanner would apply changes, so cached digests priced under other rates are not reused.
    static var fingerprint: String {
        let pairs = overrides.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.input)/\($0.value.output)/\($0.value.cacheWrite5m)/\($0.value.cacheWrite1h)/\($0.value.cacheRead)" }
        return snapshotDate + "|" + pairs.joined(separator: ";")
    }

    static func rates(for model: String, speed: String? = nil) -> ModelRates? {
        let name = normalize(model)
        let overrides = self.overrides
        if !overrides.isEmpty, let hit = overrides.keys.filter({ name.hasPrefix($0) }).max(by: { $0.count < $1.count }) {
            return overrides[hit]
        }
        if speed == "fast", let fast = longestMatch(of: name, in: fastTable) { return fast }
        if let hit = longestMatch(of: name, in: table) { return hit }
        if name.contains("fable") || name.contains("mythos") { return fable51 }
        if name.contains("opus") { return speed == "fast" ? opusFast : opus5 }
        if name.contains("sonnet") { return sonnet5 }
        if name.contains("haiku") { return haiku45 }
        return nil
    }

    /// Claude Code prices a response whose `usage.inference_geo` is "us" at 1.1x list on every token bucket;
    /// "global", "not_available" and a missing field all stay at list. Per-request fees are never multiplied.
    static func residencyMultiplier(inferenceGeo: String?) -> Double {
        inferenceGeo == "us" ? 1.1 : 1
    }

    static func cost(of tokens: TokenBreakdown, model: String?, inferenceGeo: String? = nil, speed: String? = nil) -> Double? {
        guard let model, let rates = rates(for: model, speed: speed) else { return nil }
        return rates.cost(tokens) * residencyMultiplier(inferenceGeo: inferenceGeo)
    }

    /// Bedrock/Vertex ids (`anthropic.claude-…`, `claude-…@20250101`) and dated suffixes all collapse to the plain id.
    /// The row whose prefix is the longest one this id starts with; nil when none does. Order-independent, so a
    /// row inserted above its own variants cannot shadow them.
    static func longestMatch(of name: String, in table: [(prefix: String, rates: ModelRates)]) -> ModelRates? {
        table.filter { name.hasPrefix($0.prefix) }.max { $0.prefix.count < $1.prefix.count }?.rates
    }

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
        var merged: [String: ModelRates] = [:]
        if let data = try? Data(contentsOf: claudeSettings),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            merged.merge(parseOverrides(root["modelPricing"])) { _, new in new }
        }
        if let data = try? Data(contentsOf: own), let root = try? JSONSerialization.jsonObject(with: data) {
            merged.merge(parseOverrides((root as? [String: Any])?["modelPricing"] ?? root)) { _, new in new }
        }
        overrides = merged
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
