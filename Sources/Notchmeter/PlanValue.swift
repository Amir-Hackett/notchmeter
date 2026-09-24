import Foundation

/// One plan's published monthly price, as the vendor's own pricing page states it for monthly billing.
///
/// The table is deliberately short. A plan is here only when three things hold: the vendor publishes a single
/// monthly price for it on a page this project could read, the reading names it unambiguously, and the person on
/// it is the one paying that price. So Claude Team and Enterprise, ChatGPT Business and Enterprise, Cursor Teams
/// and Enterprise, and Copilot Business and Enterprise are out (a seat an organisation pays for, at a price that
/// depends on its billing); a Claude reading that says "Max" with no tier is out, because Max is sold at two
/// prices; a Copilot seat reported as "individual" is out because that one name covers Pro and Pro+; and every
/// paid ChatGPT plan is out because OpenAI's pricing and help pages refused a plain GET when the table was read,
/// and the secondary sources disagreed about Plus ($20 against $24), so no price could be sourced to OpenAI itself.
/// Every price, its page and the day it was read are in docs/accuracy.md (*Plan value*); a plan the table does not
/// know gets no ratio anywhere, never a guess.
struct PlanPrice: Equatable, Sendable {
    let tool: ToolID
    /// The plan as `UsageReading.plan` names it ("Max 5x", "Pro Plus").
    let plan: String
    let monthlyUSD: Double
    /// The vendor page the price was read from.
    let source: String
}

enum PlanCatalog {
    /// When every price below was read from its page.
    static let readOn = "2026-09-24"

    static let prices: [PlanPrice] = [
        // claude.com/pricing: Free "$0"; Pro "$20 if billed monthly" ($17 a month on the annual plan). The page's
        // Max toggle says only "From $100", so both Max tiers come from Anthropic's support article.
        PlanPrice(tool: .claude, plan: "Free", monthlyUSD: 0, source: "https://claude.com/pricing"),
        PlanPrice(tool: .claude, plan: "Pro", monthlyUSD: 20, source: "https://claude.com/pricing"),
        PlanPrice(tool: .claude, plan: "Max 5x", monthlyUSD: 100, source: "https://support.claude.com/en/articles/11049741-what-is-the-max-plan"),
        PlanPrice(tool: .claude, plan: "Max 20x", monthlyUSD: 200, source: "https://support.claude.com/en/articles/11049741-what-is-the-max-plan"),
        // Codex reads the ChatGPT plan. Free costs nothing by definition; no paid plan is priced (see above).
        PlanPrice(tool: .codex, plan: "Free", monthlyUSD: 0, source: "https://chatgpt.com/pricing"),
        // cursor.com/pricing: Hobby is "Free"; cursor.com/docs/account/pricing: Pro "$20/mo", Pro Plus "$60/mo",
        // Ultra "$200/mo".
        PlanPrice(tool: .cursor, plan: "Free", monthlyUSD: 0, source: "https://cursor.com/pricing"),
        PlanPrice(tool: .cursor, plan: "Pro", monthlyUSD: 20, source: "https://cursor.com/docs/account/pricing"),
        PlanPrice(tool: .cursor, plan: "Pro Plus", monthlyUSD: 60, source: "https://cursor.com/docs/account/pricing"),
        PlanPrice(tool: .cursor, plan: "Ultra", monthlyUSD: 200, source: "https://cursor.com/docs/account/pricing"),
        // github.com/features/copilot/plans: Free "$0", Pro "$10 per month", Pro+ "$39 per month", Max "$100 per month".
        PlanPrice(tool: .copilot, plan: "Free", monthlyUSD: 0, source: "https://github.com/features/copilot/plans"),
        PlanPrice(tool: .copilot, plan: "Pro", monthlyUSD: 10, source: "https://github.com/features/copilot/plans"),
        PlanPrice(tool: .copilot, plan: "Pro Plus", monthlyUSD: 39, source: "https://github.com/features/copilot/plans"),
        PlanPrice(tool: .copilot, plan: "Max", monthlyUSD: 100, source: "https://github.com/features/copilot/plans"),
    ]

    /// The price of the plan a reading names, matched whole and without regard to case; nil for a plan the table
    /// does not carry, a reading that names none, and every Antigravity plan (it reports quota, never a cost).
    static func price(tool: ToolID, plan: String?) -> PlanPrice? {
        guard let plan = plan?.trimmingCharacters(in: .whitespacesAndNewlines), !plan.isEmpty else { return nil }
        return prices.first { $0.tool == tool && $0.plan.caseInsensitiveCompare(plan) == .orderedSame }
    }
}

/// What the API-equivalent spend comes to against what the plans behind it cost: "$412 of API-equivalent value
/// on the $200 Claude Max 20x plan · 2.1x".
///
/// Both sides are stated rather than inferred. The value is the Cost card's own figure for the span, the priced
/// estimate for Claude Code and Codex and the vendor's own dollars for Cursor and Copilot (docs/accuracy.md), and
/// the fee is the catalogue's published price times the months the span covers. Nothing is prorated: a span
/// shorter than a month has no fee to set against it, so it has no ratio, and a day's value is never compared
/// with a slice of a month the app would have had to cut itself.
struct PlanValue: Equatable, Sendable {
    /// The API-equivalent dollars of every assistant with spend in the span.
    let value: Double
    /// Each of those assistants' plans with its price, in the order the assistants were given.
    let plans: [PlanPrice]
    /// How many months of fees the span stands against.
    let months: Int

    /// What the plans cost a month, together.
    var monthlyFee: Double { plans.reduce(0) { $0 + $1.monthlyUSD } }
    /// What they cost over the span.
    var fee: Double { monthlyFee * Double(months) }
    /// The value over the fee; `make` never builds a PlanValue whose fee is nothing.
    var ratio: Double { value / fee }

    /// The months of fees a Cost card range stands against: a month for the thirty days and for the calendar
    /// month so far, three for the ninety days; nil for the shorter ranges, which get no ratio.
    static func months(for range: CostRange) -> Int? {
        switch range {
        case .last30Days, .month: 1
        case .last90Days: 3
        case .today, .yesterday, .week: nil
        }
    }

    /// The range a value line describes for a card on `range`: that range when it is a month or longer, and the
    /// thirty days otherwise, which is the one comparison a plan's monthly price supports.
    static func valueRange(for range: CostRange) -> CostRange {
        months(for: range) == nil ? .last30Days : range
    }

    /// The span's name at the head of a value line.
    static func title(of range: CostRange) -> String {
        switch range {
        case .month: L("This month")
        case .last90Days: L("90 days")
        default: L("30 days")
        }
    }

    /// The comparison, or nil where it cannot honestly be made: no spend in the span, a span with no fee to set
    /// against it (`months` nil), an assistant with spend whose plan the catalogue does not price (a ratio over
    /// the others alone would count its value against nobody's fee), a span of several months that the recorded
    /// history does not reach the start of (`covered` false: three months of fees against a month of records
    /// would understate the ratio threefold), or plans that cost nothing together.
    static func make(values: [(tool: ToolID, value: Double)], plans: [ToolID: String], months: Int?, covered: Bool = true) -> PlanValue? {
        guard let months, months > 0, months == 1 || covered else { return nil }
        let spending = values.filter { $0.value > 0 }
        guard !spending.isEmpty else { return nil }
        var priced: [PlanPrice] = []
        for entry in spending {
            guard let price = PlanCatalog.price(tool: entry.tool, plan: plans[entry.tool]) else { return nil }
            priced.append(price)
        }
        let value = spending.reduce(0) { $0 + $1.value }
        let plan = PlanValue(value: value, plans: priced, months: months)
        return plan.fee > 0 ? plan : nil
    }

    /// The same comparison for the assistants a Cost card carries, over one of its ranges. `firstUse` is where
    /// Claude Code's durable history begins (CostSummary.firstUse), which can lie before the ninety days the series
    /// carry.
    static func make(selection: CostSelection, plans: [ToolID: String], range: CostRange, firstUse: Date? = nil, now: Date = Date(),
                     calendar: Calendar = .current) -> PlanValue? {
        let spending = selection.providers.filter { $0.totals(range).cost > 0 }
        let start = calendar.date(byAdding: .day, value: -89, to: calendar.startOfDay(for: now)) ?? now
        let covered = spending.allSatisfy { covers($0, from: start, firstUse: firstUse, calendar: calendar) }
        return make(values: selection.providers.map { (tool: $0.tool, value: $0.totals(range).cost) }, plans: plans, months: months(for: range),
                    covered: covered)
    }

    /// Whether an assistant's records reach back to `start`: its earliest day with spend or tokens in the ninety-day
    /// series is on or before it, or, for Claude Code, its durable history begins there. A quiet first week reads
    /// as uncovered, which costs a ratio and never shows a wrong one.
    static func covers(_ provider: ProviderCost, from start: Date, firstUse: Date?, calendar: Calendar = .current) -> Bool {
        let first = provider.daily90.first { $0.cost > 0 || $0.tokens > 0 }?.day
        let since = [first, provider.tool == .claude ? firstUse : nil].compactMap { $0 }.min()
        guard let since else { return false }
        return calendar.startOfDay(for: since) <= calendar.startOfDay(for: start)
    }

    /// "on the $200 Claude Max 20x plan", "on $220 of plans", or the same over three months. A free plan beside a
    /// paid one adds nothing to the fee, so the one paid plan is named rather than folded into "of plans": Claude
    /// Max beside Cursor Free is the $100 Claude plan, and saying so is the more exact of the two.
    var phrase: String {
        let paid = plans.filter { $0.monthlyUSD > 0 }
        if paid.count == 1, let plan = paid.first {
            let price = Money.dollars(plan.monthlyUSD, cents: false)
            let name = "\(plan.tool.displayName) \(plan.plan)"
            return months == 1 ? L("on the %1$@ %2$@ plan", price, name) : L("on %1$ld months of the %2$@ %3$@ plan", months, price, name)
        }
        let fee = Money.dollars(fee, cents: false)
        return months == 1 ? L("on %@ of plans", fee) : L("on %1$@ of plans over %2$ld months", fee, months)
    }

    /// "2.1x", in the app's own vocabulary for a multiple (Burn.multiple), which each language already writes.
    var multiple: String { Burn.multiple(ratio) }

    /// "$412 of API-equivalent value on the $200 Claude Max 20x plan · 2.1x".
    var sentence: String {
        L("%1$@ of API-equivalent value %2$@ · %3$@", Money.dollars(value, cents: false), phrase, multiple)
    }

    /// The line the Cost card, its Simple row and the dashboard carry, the span named and the kind of number said:
    /// "30 days: $412 of API-equivalent value on the $200 Claude Max 20x plan · 2.1x (estimate)".
    static func line(_ plan: PlanValue, range: CostRange) -> String {
        L("%1$@: %2$@ (estimate)", title(of: range), plan.sentence)
    }
}
