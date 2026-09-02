import Foundation

/// Token buckets as Claude Code records them per assistant message.
struct TokenBreakdown: Codable, Equatable, Sendable {
    var input = 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0
    var cacheRead = 0
    var output = 0

    var total: Int { input + cacheWrite5m + cacheWrite1h + cacheRead + output }
}

/// Anthropic list prices in dollars per million tokens.
struct ModelRates: Equatable, Sendable {
    let input: Double
    let output: Double
    let cacheWrite5m: Double
    let cacheWrite1h: Double
    let cacheRead: Double

    /// Standard multipliers: 5-minute cache writes 1.25x input, 1-hour writes 2x, cache reads 0.1x.
    init(input: Double, output: Double, cacheRead: Double? = nil) {
        self.input = input
        self.output = output
        self.cacheWrite5m = input * 1.25
        self.cacheWrite1h = input * 2
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

/// Prices as published on anthropic.com (September 2026). Unknown versions fall back to their family's
/// newest rate so a fresh model still prices roughly right until the table is updated.
enum ModelPricing {
    static let fable51 = ModelRates(input: 10, output: 50, cacheRead: 0.25)
    static let fable5 = ModelRates(input: 10, output: 50, cacheRead: 1.0)
    static let opus5 = ModelRates(input: 5, output: 25)
    static let opusLegacy = ModelRates(input: 15, output: 75)
    static let sonnet5 = ModelRates(input: 2, output: 10)
    static let sonnetLegacy = ModelRates(input: 3, output: 15)
    static let haiku45 = ModelRates(input: 1, output: 5)
    static let haiku35 = ModelRates(input: 0.8, output: 4)
    static let haiku3 = ModelRates(input: 0.25, output: 1.25)

    /// Longest prefixes first so `claude-opus-4-1` never matches `claude-opus-4`.
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

    static func rates(for model: String) -> ModelRates? {
        let name = normalize(model)
        if let hit = table.first(where: { name.hasPrefix($0.prefix) }) { return hit.rates }
        if name.contains("fable") || name.contains("mythos") { return fable51 }
        if name.contains("opus") { return opus5 }
        if name.contains("sonnet") { return sonnet5 }
        if name.contains("haiku") { return haiku45 }
        return nil
    }

    static func cost(of tokens: TokenBreakdown, model: String?) -> Double? {
        guard let model, let rates = rates(for: model) else { return nil }
        return rates.cost(tokens)
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
}
