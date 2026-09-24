import Foundation

/// One OpenCode Go price row, in dollars per million tokens. `cacheWrite` is nil where the page prints a dash,
/// which is priced at nothing, as a dash is in OpenAI's table (docs/accuracy.md, *OpenCode*).
struct GoRates: Equatable, Sendable {
    let input: Double
    let output: Double
    let cacheRead: Double
    let cacheWrite: Double?

    /// OpenCode's own buckets (OpenCodeUsage): `input` excludes the cache, `cacheRead` and the write bucket are the
    /// cache, and `output` already carries the reasoning tokens, which OpenCode itself charges at the output rate.
    func cost(_ tokens: TokenBreakdown) -> Double {
        (Double(tokens.input) * input + Double(tokens.output) * output + Double(tokens.cacheRead) * cacheRead
            + Double(tokens.cacheWrite5m + tokens.cacheWrite1h) * (cacheWrite ?? 0)) / 1_000_000
    }
}

/// One model on the OpenCode Go page: its standard row, a long-context row and the context size it starts past
/// where the page prints one, a peak-hours row where the page prints one (the standard row is then the off-peak
/// one), and the monthly dollar limit the plan meters it against; nil for a model the page calls Unlimited.
struct GoModel: Equatable, Sendable {
    let name: String
    let rates: GoRates
    var longContext: (threshold: Int, rates: GoRates)?
    var peak: GoRates?
    let monthlyLimitUSD: Double?
    /// A limit the page shows struck through for a promotional one, and the instant the promotion ends.
    var promotion: (limitUSD: Double, endsAt: Date)?

    init(_ name: String, _ rates: GoRates, limit: Double?, longContext: (Int, GoRates)? = nil, peak: GoRates? = nil,
         promotion: (Double, Date)? = nil) {
        self.name = name
        self.rates = rates
        self.longContext = longContext.map { (threshold: $0.0, rates: $0.1) }
        self.peak = peak
        self.monthlyLimitUSD = limit
        self.promotion = promotion.map { (limitUSD: $0.0, endsAt: $0.1) }
    }

    static func == (lhs: GoModel, rhs: GoModel) -> Bool {
        lhs.name == rhs.name && lhs.rates == rhs.rates && lhs.longContext?.threshold == rhs.longContext?.threshold
            && lhs.longContext?.rates == rhs.longContext?.rates && lhs.peak == rhs.peak && lhs.monthlyLimitUSD == rhs.monthlyLimitUSD
            && lhs.promotion?.limitUSD == rhs.promotion?.limitUSD && lhs.promotion?.endsAt == rhs.promotion?.endsAt
    }

    /// The monthly limit in force at `date`: the promotional one until its end, the page's standing one after.
    func monthlyLimit(at date: Date) -> Double? {
        if let promotion, date < promotion.endsAt { return promotion.limitUSD }
        return monthlyLimitUSD
    }

    /// The row one turn is priced at: the peak row inside the page's peak hours, the long-context row past its
    /// threshold, the standard row otherwise.
    func rates(contextTokens: Int, at date: Date) -> GoRates {
        if let peak, GoPlan.isPeak(date) { return peak }
        if let longContext, contextTokens > longContext.threshold { return longContext.rates }
        return rates
    }
}

/// OpenCode Go as its page publishes it (opencode.ai/docs/go, read 2026-09-24, "Last updated: Sep 24, 2026"): $10 a
/// month, limits "defined as monthly dollar amounts", set per model, with a 5-hour limit of 20 % of the monthly one
/// and a weekly limit of 50 %. The page also says "Usage limits may change as we learn from early usage and
/// feedback", which is why `snapshotDate` travels with every figure built from this table (docs/accuracy.md).
enum GoPlan {
    static let snapshotDate = "2026-09-24"
    /// OpenCode's provider id for the plan, the `opencode-go` in `opencode-go/<model-id>`.
    static let providerID = "opencode-go"
    static let fiveHourShare = 0.2
    static let weeklyShare = 0.5

    private static func r(_ input: Double, _ output: Double, _ cacheRead: Double, _ cacheWrite: Double? = nil) -> GoRates {
        GoRates(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
    }

    /// "Ends Sep 27" beside DeepSeek V4.1 Flash's struck-through $15 and its $60: the page names no time or zone, so
    /// the promotion is held to the end of that day in UTC, the latest reading of it, and the $15 applies from then.
    static let deepSeekV41FlashPromotionEnds = Date(timeIntervalSince1970: 1_790_553_600)  // 2026-09-28T00:00:00Z

    /// Keyed by the model id the page's endpoint table gives, which is the `modelID` OpenCode records.
    static let models: [String: GoModel] = [
        "glm-5.3-flash": GoModel("GLM-5.3-Flash", r(0.15, 0.50, 0.03), limit: 60),
        "glm-5.3": GoModel("GLM-5.3", r(1.40, 4.40, 0.26), limit: 15),
        "glm-5.2": GoModel("GLM-5.2", r(1.40, 4.40, 0.26), limit: 60),
        "glm-5.1": GoModel("GLM-5.1", r(1.40, 4.40, 0.26), limit: 60),
        "kimi-k3": GoModel("Kimi K3", r(3.00, 15.00, 0.30), limit: 15),
        "kimi-k2.7-code": GoModel("Kimi K2.7 Code", r(0.95, 4.00, 0.19), limit: 60),
        "kimi-k2.6": GoModel("Kimi K2.6", r(0.95, 4.00, 0.16), limit: 60),
        "longcat-2.0": GoModel("LongCat-2.0", r(0.30, 1.20, 0.006), limit: 60),
        "mimo-v2.6-flash": GoModel("MiMo-V2.6-Flash", r(0.14, 0.28, 0.0028), limit: 60),
        "mimo-v2.6-pro": GoModel("MiMo-V2.6-Pro", r(0.435, 0.87, 0.003625), limit: 15),
        "mimo-v2.5": GoModel("MiMo-V2.5", r(0.14, 0.28, 0.0028), limit: 60),
        "mimo-v2.5-pro": GoModel("MiMo-V2.5-Pro", r(0.435, 0.87, 0.003625), limit: 15),
        "minimax-m3": GoModel("MiniMax M3", r(0.30, 1.20, 0.06), limit: 60),
        "minimax-m2.7": GoModel("MiniMax M2.7", r(0.30, 1.20, 0.06, 0.375), limit: 60),
        "minimax-m2.5": GoModel("MiniMax M2.5", r(0.30, 1.20, 0.06, 0.375), limit: 60),
        "muse-spark-1.3-contributor": GoModel("Muse Spark 1.3 Contributor", r(0.10, 0.20, 0.002), limit: 60),
        "muse-spark-1.2-contributor": GoModel("Muse Spark 1.2 Contributor", r(0.10, 0.20, 0.002), limit: 60),
        "qwen3.8-max": GoModel("Qwen3.8 Max", r(2.00, 6.00, 0.25, 2.50), limit: 15),
        "qwen3.8-flash": GoModel("Qwen3.8 Flash", r(0.15, 0.47, 0.016, 0.20), limit: 30),
        "qwen3.7-max": GoModel("Qwen3.7 Max", r(2.50, 7.50, 0.50, 3.125), limit: 30),
        "qwen3.7-plus": GoModel("Qwen3.7 Plus", r(0.40, 1.60, 0.04, 0.50), limit: 60, longContext: (256_000, r(1.20, 4.80, 0.12, 1.50))),
        "qwen3.6-plus": GoModel("Qwen3.6 Plus", r(0.50, 3.00, 0.05, 0.625), limit: 60, longContext: (256_000, r(2.00, 6.00, 0.20, 2.50))),
        "deepseek-v4.1-flash": GoModel("DeepSeek V4.1 Flash", r(0.15, 0.60, 0.003), limit: 15, peak: r(0.30, 1.20, 0.006),
                                       promotion: (60, deepSeekV41FlashPromotionEnds)),
        "deepseek-v4-pro": GoModel("DeepSeek V4 Pro", r(0.66, 1.98, 0.022), limit: 15, peak: r(1.32, 3.96, 0.044)),
        "deepseek-v4-flash": GoModel("DeepSeek V4 Flash", r(0.15, 0.60, 0.003), limit: 30, peak: r(0.30, 1.20, 0.006)),
        "deepseek-v4-flash-vision-exp": GoModel("DeepSeek V4 Flash Vision Exp", r(0.15, 0.60, 0.003), limit: 15, peak: r(0.30, 1.20, 0.006)),
        "hy4-preview": GoModel("Hy4 preview", r(0.834, 2.501, 0.042), limit: 30),
        "hy3": GoModel("Hy3", r(0.14, 0.58, 0.035), limit: 60),
        "space-bunny-free": GoModel("Space Bunny Free", r(0, 0, 0), limit: nil),
        "grok-4.7": GoModel("Grok 4.7", r(2.00, 6.00, 0.50), limit: 15, longContext: (200_000, r(4.00, 12.00, 1.00))),
        "grok-4.6": GoModel("Grok 4.6", r(2.00, 6.00, 0.50), limit: 15, longContext: (200_000, r(4.00, 12.00, 1.00))),
        "gpt-6-luna": GoModel("GPT 6 Luna", r(0.10, 0.50, 0.01, 0.125), limit: 15, longContext: (272_000, r(0.20, 0.75, 0.02, 0.25))),
        "gpt-5.6-luna": GoModel("GPT 5.6 Luna", r(0.20, 1.20, 0.02, 0.25), limit: 15, longContext: (272_000, r(0.40, 1.80, 0.04, 0.50))),
    ]

    /// The page's peak hours for its DeepSeek rows: "01:00-04:00 and 06:00-10:00 UTC, Monday through Friday; all
    /// other hours, including weekends, are Off-Peak". Each span is read as including its first minute and not its
    /// last, so 04:00 and 10:00 are off-peak.
    static func isPeak(_ date: Date) -> Bool {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = utc.dateComponents([.weekday, .hour], from: date)
        guard let weekday = parts.weekday, (2...6).contains(weekday), let hour = parts.hour else { return false }
        return (1..<4).contains(hour) || (6..<10).contains(hour)
    }

    /// A model id as OpenCode records it, lower-cased; an id written `opencode-go/<id>` loses its provider.
    static func model(_ id: String?) -> GoModel? {
        guard var name = id?.lowercased().trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        return models[name]
    }

    /// The snapshot date and a digest of every row and limit, so a cost cached under other rates is never reused.
    static var fingerprint: String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for id in models.keys.sorted() {
            guard let model = models[id] else { continue }
            let rows = [model.rates, model.longContext?.rates, model.peak].map { rates in
                rates.map { "\($0.input)/\($0.output)/\($0.cacheRead)/\($0.cacheWrite ?? -1)" } ?? "-"
            }
            let row = "\(id):\(rows.joined(separator: ",")):\(model.longContext?.threshold ?? 0):\(model.monthlyLimitUSD ?? -1):\(model.promotion?.limitUSD ?? -1);"
            for byte in row.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        }
        return "\(snapshotDate)-\(String(hash, radix: 36))"
    }
}

/// What one OpenCode turn is worth in dollars, and on what authority (docs/accuracy.md, *OpenCode*). Four rules, in
/// order:
///
/// 1. **OpenCode Go** (`providerID` `opencode-go`) is priced here at the Go page's own rates, because those are the
///    rates the plan's dollar limits are measured in; a Go model the page does not list falls to rule 2.
/// 2. **OpenCode's own figure.** Every assistant message records the `cost` OpenCode put on it from its model
///    catalogue (models.dev), the way a Claude Code line may carry its own `costUSD`; above zero, it wins. On
///    OpenCode Zen (`opencode`), OpenCode's own pay-as-you-go gateway, the recorded figure is the price even at
///    zero, since Zen's free models are free.
/// 3. **A published list rate** where the recorded cost is zero and this app holds the vendor's table: Anthropic's
///    (ModelPricing) for `anthropic`, OpenAI's (OpenAIPricing) for `openai`. OpenCode records zero for a turn run on
///    a subscription login, and the card, as it does for Claude Code, shows the API-equivalent value of the work.
/// 4. Otherwise **unpriced**: the turn's tokens count, its dollars do not, and its model is named on the card.
enum OpenCodePricing {
    enum Basis: String, Equatable, Sendable {
        case goPlan, recorded, anthropicList, openAIList
    }

    struct Priced: Equatable, Sendable {
        let cost: Double?
        let basis: Basis?

        static let unpriced = Priced(cost: nil, basis: nil)
    }

    static let zenProviderID = "opencode"

    static func price(_ usage: OpenCodeUsage) -> Priced {
        let provider = usage.providerID?.lowercased()
        if provider == GoPlan.providerID, let model = GoPlan.model(usage.modelID) {
            return Priced(cost: model.rates(contextTokens: usage.contextTokens, at: usage.timestamp).cost(usage.tokens), basis: .goPlan)
        }
        if let recorded = usage.recordedCost, recorded.isFinite, recorded > 0 || (provider == zenProviderID && recorded == 0) {
            return Priced(cost: recorded, basis: .recorded)
        }
        switch provider {
        case "anthropic":
            if let cost = ModelPricing.cost(of: usage.tokens, model: usage.modelID) { return Priced(cost: cost, basis: .anthropicList) }
        case "openai":
            if let cost = OpenAIPricing.cost(of: usage.tokens, model: usage.modelID) { return Priced(cost: cost, basis: .openAIList) }
        default:
            break
        }
        return .unpriced
    }

    /// Every table a figure here can depend on, so the scanner's cache is dropped when any of them changes.
    static var fingerprint: String { "\(GoPlan.fingerprint)|\(ModelPricing.fingerprint)|\(OpenAIPricing.fingerprint)" }
}
