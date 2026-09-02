import Foundation

/// One model id's published row, in dollars per million tokens.
///
/// `cachedInput` is its own rate; a model the page prices without one (the `pro` tiers, which do not serve the
/// prompt cache) carries the input rate there, so a cached count that should never arrive cannot come out cheaper
/// than it was. `cacheWrite` is the price of *writing* the prompt cache, which OpenAI bills for GPT-5.6 and later
/// and for nothing earlier, so every earlier row carries zero. `longContextThreshold` is the input-token count
/// above which the whole request is priced at the long-context tier, and is set only for the ids whose own page
/// publishes that tier.
struct OpenAIRates: Equatable, Sendable {
    let input: Double
    let cachedInput: Double
    let output: Double
    let cacheWrite: Double
    let longContextThreshold: Int?

    /// The long-context tier as the published rows state it: every input bucket at 2x and output at 1.5x. Those
    /// two numbers reproduce all seven published long-context rows exactly, which `longContextTierMatchesThe
    /// PublishedRows` pins.
    static let longInputMultiplier = 2.0
    static let longOutputMultiplier = 1.5

    init(input: Double, cachedInput: Double? = nil, output: Double, cacheWrite: Double = 0, longContext: Int? = nil) {
        self.input = input
        self.cachedInput = cachedInput ?? input
        self.output = output
        self.cacheWrite = cacheWrite
        self.longContextThreshold = longContext
    }

    /// Codex's buckets as this app stores them: `input` is the input OpenAI did not serve from the prompt cache,
    /// `cacheRead` the part it did, `output` everything the model wrote (reasoning tokens are inside it), and the
    /// cache-write buckets hold Codex's `cache_write_input_tokens`.
    func cost(_ tokens: TokenBreakdown) -> Double {
        let isLong = longContextThreshold.map { tokens.input + tokens.cacheRead > $0 } ?? false
        let onInput = isLong ? Self.longInputMultiplier : 1
        var total = (Double(tokens.input) * input + Double(tokens.cacheRead) * cachedInput) * onInput
        total += Double(tokens.cacheWrite5m + tokens.cacheWrite1h) * cacheWrite * onInput
        total += Double(tokens.output) * output * (isLong ? Self.longOutputMultiplier : 1)
        return total / 1_000_000
    }
}

/// Prices as published on developers.openai.com/api/docs/pricing and on the per-model pages under
/// developers.openai.com/api/docs/models, snapshot 2026-09-02 (`OpenAIPricing.snapshotDate`). The rows, the two
/// rules below them and what each leaves unpriced are written out in docs/accuracy.md.
///
/// A lookup is an **exact match on the model id**, never a prefix scan: an id the table does not hold is reported
/// unpriced and named on the card rather than collapsed onto whichever shorter row happens to be a prefix of it.
/// That is the property `unlistedIdsAreNamedRatherThanCollapsed` pins, and it is why a row may be added anywhere
/// in the table without shadowing another. The one id rewritten before lookup is a dated snapshot, which the page
/// prices identically to the undated id it snapshots.
enum OpenAIPricing {
    static let snapshotDate = "2026-09-02"

    /// Keyed by exact model id, holding the standard tier only: Batch, Flex, Priority and Fast mode are separate
    /// published tables, and a rollout does not record which tier a turn ran on.
    ///
    /// `gpt-5.4-cyber` is deliberately absent: its row prints a dash in every column, so there is no rate to
    /// apply and it is named unpriced instead.
    static let table: [String: OpenAIRates] = [
        // Cache writes are billed for GPT-5.6 and later only, at 1.25x the uncached input rate (the prompt-caching
        // guide's rule, and each of these four write rates is that arithmetic). The same pages publish the
        // >272K long-context tier for sol, terra and luna; cyber's own model page states the rule while the
        // pricing table repeats no long-context row for it.
        "gpt-5.6-sol": OpenAIRates(input: 4, cachedInput: 0.4, output: 20, cacheWrite: 5, longContext: 272_000),
        "gpt-5.6-terra": OpenAIRates(input: 2, cachedInput: 0.2, output: 12, cacheWrite: 2.5, longContext: 272_000),
        "gpt-5.6-luna": OpenAIRates(input: 0.2, cachedInput: 0.02, output: 1.2, cacheWrite: 0.25, longContext: 272_000),
        "gpt-5.6-cyber": OpenAIRates(input: 12.5, cachedInput: 1.25, output: 75, cacheWrite: 15.625, longContext: 272_000),
        // GPT-5.5 and earlier carry no cache-write charge, and the cyber rows publish no long-context tier.
        "gpt-5.5-cyber": OpenAIRates(input: 12.5, cachedInput: 1.25, output: 75),
        "gpt-5.5": OpenAIRates(input: 5, cachedInput: 0.5, output: 30, longContext: 272_000),
        "gpt-5.5-pro": OpenAIRates(input: 30, output: 180, longContext: 272_000),
        "gpt-5.4": OpenAIRates(input: 2.5, cachedInput: 0.25, output: 15, longContext: 272_000),
        "gpt-5.4-mini": OpenAIRates(input: 0.75, cachedInput: 0.075, output: 4.5),
        "gpt-5.4-nano": OpenAIRates(input: 0.2, cachedInput: 0.02, output: 1.25),
        "gpt-5.4-pro": OpenAIRates(input: 30, output: 180, longContext: 272_000),
        // Each -codex id carries the row its own model page publishes; the pricing table lists only gpt-5.3-codex.
        "gpt-5.3-codex": OpenAIRates(input: 1.75, cachedInput: 0.175, output: 14),
        "gpt-5.2": OpenAIRates(input: 1.75, cachedInput: 0.175, output: 14),
        "gpt-5.2-codex": OpenAIRates(input: 1.75, cachedInput: 0.175, output: 14),
        "gpt-5.2-pro": OpenAIRates(input: 21, output: 168),
        "gpt-5.1": OpenAIRates(input: 1.25, cachedInput: 0.125, output: 10),
        "gpt-5.1-codex": OpenAIRates(input: 1.25, cachedInput: 0.125, output: 10),
        "gpt-5.1-codex-mini": OpenAIRates(input: 0.25, cachedInput: 0.025, output: 2),
        "gpt-5": OpenAIRates(input: 1.25, cachedInput: 0.125, output: 10),
        "gpt-5-codex": OpenAIRates(input: 1.25, cachedInput: 0.125, output: 10),
        "gpt-5-mini": OpenAIRates(input: 0.25, cachedInput: 0.025, output: 2),
        "gpt-5-nano": OpenAIRates(input: 0.05, cachedInput: 0.005, output: 0.4),
        "gpt-5-pro": OpenAIRates(input: 15, output: 120),
        "gpt-4.1": OpenAIRates(input: 2, cachedInput: 0.5, output: 8),
        "gpt-4.1-mini": OpenAIRates(input: 0.4, cachedInput: 0.1, output: 1.6),
        "gpt-4.1-nano": OpenAIRates(input: 0.1, cachedInput: 0.025, output: 0.4),
        "o3": OpenAIRates(input: 2, cachedInput: 0.5, output: 8),
        "o3-pro": OpenAIRates(input: 20, output: 80),
        "o3-mini": OpenAIRates(input: 1.1, cachedInput: 0.55, output: 4.4),
        "o4-mini": OpenAIRates(input: 1.1, cachedInput: 0.275, output: 4.4),
    ]

    /// The snapshot date and a digest of the rows themselves, so cached day records are dropped when a rate is
    /// edited even if the snapshot date has not moved that day.
    static var fingerprint: String { "\(snapshotDate)-\(digest(of: table))" }

    /// FNV-1a over the rows in id order: same rows, same string, on any run.
    static func digest(of table: [String: OpenAIRates]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for id in table.keys.sorted() {
            guard let rates = table[id] else { continue }
            let row = "\(id):\(rates.input):\(rates.cachedInput):\(rates.output):\(rates.cacheWrite):\(rates.longContextThreshold ?? 0);"
            for byte in row.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        }
        return String(hash, radix: 36)
    }

    static func rates(for model: String) -> OpenAIRates? {
        let name = normalize(model)
        if let hit = table[name] { return hit }
        guard let undated = withoutDateSuffix(name) else { return nil }
        return table[undated]
    }

    static func cost(of tokens: TokenBreakdown, model: String?) -> Double? {
        guard let model, let rates = rates(for: model) else { return nil }
        return rates.cost(tokens)
    }

    /// `openai/gpt-5.3-codex` and a capitalised id both collapse to the plain lowercase id.
    static func normalize(_ model: String) -> String {
        let name = model.lowercased().trimmingCharacters(in: .whitespaces)
        guard let slash = name.lastIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }

    /// `gpt-5-mini-2025-08-07` → `gpt-5-mini`. A dated snapshot carries the same row as the id it snapshots, which
    /// the page shows directly by listing both (`gpt-4.1` and `gpt-4.1-2025-04-14` price identically). Only a
    /// trailing `-YYYY-MM-DD` is stripped, so no other suffix can reach a row that was not written for it.
    static func withoutDateSuffix(_ name: String) -> String? {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count > 3 else { return nil }
        let widths = [4, 2, 2]
        guard zip(parts.suffix(3), widths).allSatisfy({ part, width in
            part.count == width && part.allSatisfy { $0.isASCII && $0.isNumber }
        }) else { return nil }
        return parts.dropLast(3).joined(separator: "-")
    }
}
