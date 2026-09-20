import Foundation

/// Which vocabulary a Claude model counts text with. Anthropic's pricing page says Claude 4.7 and later, and the
/// Mythos/Fable line, tokenize with a vocabulary that yields approximately 30 % more tokens than Claude 4.6 and
/// earlier for the same text. A token count is still exact for the model that produced it (docs/accuracy.md); what
/// the boundary changes is a comparison across it: a million Fable tokens is less text than a million Sonnet 4.6
/// tokens, and a per-model window on the newer side drains sooner for the same work. The switch-models advice and
/// the Cost card's $/MTok mode say so when their two sides straddle it, and say nothing when a name cannot be
/// placed (the vendor's bare "Opus" label carries no version; a Gemini or GPT model is not Claude at all).
enum Tokenizer: Equatable, Sendable {
    /// Claude 4.6 and earlier.
    case legacy
    /// Claude 4.7 and later, and every Mythos/Fable model.
    case current

    /// The pricing page's figure, "approximately 30%", as a fraction.
    static let moreTokens = 0.3
    /// The first version counting with the newer vocabulary.
    static let boundary = (major: 4, minor: 7)
    private static let families: Set<String> = ["opus", "sonnet", "haiku", "fable", "mythos"]

    /// Reads a model id ("claude-sonnet-4-7", "us.anthropic.claude-opus-4-6@20260101") or a vendor's label
    /// ("Fable", "Opus 4.6") and places it; nil when it is not a Claude model or carries no version to place.
    static func generation(of model: String) -> Tokenizer? {
        let tokens = ModelPricing.normalize(model).split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard tokens.contains(where: { $0 == "claude" || families.contains($0) }) else { return nil }
        if tokens.contains("fable") || tokens.contains("mythos") { return .current }
        // The first one- or two-digit run is the major version; the next, when it is one too, the minor. A date
        // stamp ("20250514") is longer than two digits and never taken for either.
        let isVersion: (String) -> Bool = { $0.count <= 2 && $0.allSatisfy(\.isNumber) }
        guard let majorIndex = tokens.firstIndex(where: isVersion), let major = Int(tokens[majorIndex]) else { return nil }
        let minor = tokens.indices.contains(majorIndex + 1) && isVersion(tokens[majorIndex + 1]) ? Int(tokens[majorIndex + 1]) ?? 0 : 0
        return (major, minor) >= boundary ? .current : .legacy
    }

    /// True when the two models count with different vocabularies; false when either cannot be placed.
    static func straddle(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b, let first = generation(of: a), let second = generation(of: b) else { return false }
        return first != second
    }

    /// The costliest model of a range that counts with the newer vocabulary, when the range also holds one that
    /// counts with the older: the name the $/MTok caption puts first. nil when every placed model is on one side,
    /// or none can be placed.
    static func newerLeader(in byModel: [String: Double]) -> String? {
        let placed = byModel.compactMap { model, cost in generation(of: model).map { (model: model, cost: cost, generation: $0) } }
        guard placed.contains(where: { $0.generation == .legacy }) else { return nil }
        return placed.filter { $0.generation == .current }.max { ($0.cost, $0.model) < ($1.cost, $1.model) }?.model
    }
}
