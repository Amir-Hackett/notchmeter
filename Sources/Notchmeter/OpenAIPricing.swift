import Foundation

/// OpenAI list prices in dollars per million tokens. Cached input is its own rate; a model the page prices without
/// a cached rate (the `pro` tiers, which do not serve the prompt cache) carries the input rate there, so a cached
/// count that should never arrive cannot come out cheaper than it was.
struct OpenAIRates: Equatable, Sendable {
    let input: Double
    let cachedInput: Double
    let output: Double

    init(input: Double, cachedInput: Double? = nil, output: Double) {
        self.input = input
        self.cachedInput = cachedInput ?? input
        self.output = output
    }

    /// Codex's buckets as this app stores them: `input` is the input OpenAI did not serve from the prompt cache,
    /// `cacheRead` the part it did, `output` everything the model wrote (reasoning tokens are inside it).
    /// `cacheWrite5m` holds Codex's `cache_write_input_tokens`, which OpenAI does not bill for.
    func cost(_ tokens: TokenBreakdown) -> Double {
        (Double(tokens.input) * input + Double(tokens.cacheRead) * cachedInput + Double(tokens.output) * output) / 1_000_000
    }
}

/// Prices as published on developers.openai.com/api/docs/pricing, snapshot 2026-09-02 (`OpenAIPricing.snapshotDate`).
/// Codex's own model is the only `-codex` id the page prices; an older one falls back to the numbered model it is
/// built on (`gpt-5.1-codex` → `gpt-5.1`), which is the rule docs/accuracy.md records. Anything the table cannot
/// reach is left unpriced and named on the card rather than guessed at.
enum OpenAIPricing {
    static let snapshotDate = "2026-09-02"

    /// Longest prefixes first, so `gpt-5-mini` never matches `gpt-5` and `gpt-5.3-codex` never matches `gpt-5.3`.
    static let table: [(prefix: String, rates: OpenAIRates)] = [
        ("gpt-5.6-terra", OpenAIRates(input: 2, cachedInput: 0.2, output: 12)),
        ("gpt-5.6-luna", OpenAIRates(input: 0.2, cachedInput: 0.02, output: 1.2)),
        ("gpt-5.6-sol", OpenAIRates(input: 4, cachedInput: 0.4, output: 20)),
        ("gpt-5.5-pro", OpenAIRates(input: 30, output: 180)),
        ("gpt-5.5", OpenAIRates(input: 5, cachedInput: 0.5, output: 30)),
        ("gpt-5.4-mini", OpenAIRates(input: 0.75, cachedInput: 0.075, output: 4.5)),
        ("gpt-5.4-nano", OpenAIRates(input: 0.2, cachedInput: 0.02, output: 1.25)),
        ("gpt-5.4-pro", OpenAIRates(input: 30, output: 180)),
        ("gpt-5.4", OpenAIRates(input: 2.5, cachedInput: 0.25, output: 15)),
        ("gpt-5.3-codex", OpenAIRates(input: 1.75, cachedInput: 0.175, output: 14)),
        ("gpt-5.2-pro", OpenAIRates(input: 21, output: 168)),
        ("gpt-5.2", OpenAIRates(input: 1.75, cachedInput: 0.175, output: 14)),
        ("gpt-5.1", OpenAIRates(input: 1.25, cachedInput: 0.125, output: 10)),
        ("gpt-5-mini", OpenAIRates(input: 0.25, cachedInput: 0.025, output: 2)),
        ("gpt-5-nano", OpenAIRates(input: 0.05, cachedInput: 0.005, output: 0.4)),
        ("gpt-5-pro", OpenAIRates(input: 15, output: 120)),
        ("gpt-5", OpenAIRates(input: 1.25, cachedInput: 0.125, output: 10)),
        ("gpt-4.1-mini", OpenAIRates(input: 0.4, cachedInput: 0.1, output: 1.6)),
        ("gpt-4.1-nano", OpenAIRates(input: 0.1, cachedInput: 0.025, output: 0.4)),
        ("gpt-4.1", OpenAIRates(input: 2, cachedInput: 0.5, output: 8)),
        ("o4-mini", OpenAIRates(input: 1.1, cachedInput: 0.275, output: 4.4)),
        ("o3-mini", OpenAIRates(input: 1.1, cachedInput: 0.55, output: 4.4)),
        ("o3-pro", OpenAIRates(input: 20, output: 80)),
        ("o3", OpenAIRates(input: 2, cachedInput: 0.5, output: 8)),
    ]

    /// Changes whenever a rate the scanner would apply changes, so cached day records priced under other rates are
    /// not reused.
    static var fingerprint: String { snapshotDate }

    static func rates(for model: String) -> OpenAIRates? {
        let name = normalize(model)
        if let hit = table.first(where: { name.hasPrefix($0.prefix) }) { return hit.rates }
        guard let base = codexBase(of: name) else { return nil }
        return table.first { base.hasPrefix($0.prefix) }?.rates
    }

    static func cost(of tokens: TokenBreakdown, model: String?) -> Double? {
        guard let model, let rates = rates(for: model) else { return nil }
        return rates.cost(tokens)
    }

    /// `openai/gpt-5.3-codex` and a dated id both collapse to the plain id.
    static func normalize(_ model: String) -> String {
        let name = model.lowercased().trimmingCharacters(in: .whitespaces)
        guard let slash = name.lastIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }

    /// `gpt-5.1-codex-mini` → `gpt-5.1`: the numbered model a Codex variant the page no longer prices is built on.
    static func codexBase(of name: String) -> String? {
        guard let range = name.range(of: "-codex") else { return nil }
        return String(name[..<range.lowerBound])
    }
}
