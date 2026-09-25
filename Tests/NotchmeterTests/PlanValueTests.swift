import Foundation
import Testing
@testable import Notchmeter

/// The plan value (docs/accuracy.md, *Plan value*): a published price per plan, and the API-equivalent dollars set
/// against it only where both sides are known. Every rule here is one the line on the Cost card and the usage
/// card's ratio rest on, so each is pinned rather than trusted.
@Suite struct PlanValueRules {
    init() { Localization.use(language: "en") }

    let now = DateParsing.iso8601("2026-09-24T15:00:00Z")!

    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func theCatalogueNamesAPriceOnlyForAPlanItHolds() {
        #expect(PlanCatalog.price(tool: .claude, plan: "Max 20x")?.monthlyUSD == 200)
        #expect(PlanCatalog.price(tool: .claude, plan: "max 5x")?.monthlyUSD == 100, "matched without regard to case")
        #expect(PlanCatalog.price(tool: .claude, plan: "Pro")?.monthlyUSD == 20)
        #expect(PlanCatalog.price(tool: .claude, plan: "Max") == nil, "Max is sold at two prices, so a bare Max names neither")
        #expect(PlanCatalog.price(tool: .claude, plan: "Team") == nil, "a seat an organisation pays for")
        #expect(PlanCatalog.price(tool: .codex, plan: "Plus") == nil, "no ChatGPT price could be sourced to OpenAI itself")
        #expect(PlanCatalog.price(tool: .codex, plan: "Free")?.monthlyUSD == 0)
        #expect(PlanCatalog.price(tool: .cursor, plan: "Pro Plus")?.monthlyUSD == 60)
        #expect(PlanCatalog.price(tool: .cursor, plan: "Ultra")?.monthlyUSD == 200)
        #expect(PlanCatalog.price(tool: .copilot, plan: "Pro Plus")?.monthlyUSD == 39)
        #expect(PlanCatalog.price(tool: .copilot, plan: "individual") == nil, "one name for two prices")
        #expect(PlanCatalog.price(tool: .antigravity, plan: "Pro") == nil, "Antigravity reports quota, never a cost")
        #expect(PlanCatalog.price(tool: .claude, plan: nil) == nil)
        #expect(PlanCatalog.price(tool: .claude, plan: "  ") == nil)
        // The vendor's own punctuation names the same plan: GitHub writes "Pro+", a slug may hyphenate or
        // underscore, and none of it makes a bare "Max" into a tier.
        #expect(PlanCatalog.price(tool: .copilot, plan: "Pro+")?.monthlyUSD == 39)
        #expect(PlanCatalog.price(tool: .cursor, plan: "Pro-Plus")?.monthlyUSD == 60)
        #expect(PlanCatalog.price(tool: .cursor, plan: "pro_plus")?.monthlyUSD == 60)
        #expect(PlanCatalog.spelled(" Pro+ ") == "Pro Plus")
        #expect(PlanCatalog.spelled("Max--5x") == "Max 5x")
        #expect(PlanCatalog.price(tool: .claude, plan: "Max-") == nil)
        // Every price names the vendor page it was read from, and the day the table was read is stated.
        for price in PlanCatalog.prices { #expect(price.source.hasPrefix("https://"), "\(price.tool) \(price.plan) has no source") }
        #expect(PlanCatalog.readOn == "2026-09-24")
    }

    @Test func theRatioIsValueOverTheFeeSaidInTheAppsOwnWords() throws {
        let plan = try #require(PlanValue.make(values: [(tool: .claude, value: 412)], plans: [.claude: "Max 20x"], months: 1))
        #expect(plan.fee == 200)
        #expect(abs(plan.ratio - 2.06) < 1e-9)
        #expect(plan.multiple == "2.1x")
        #expect(plan.phrase == "on the $200 Claude Max 20x plan")
        #expect(plan.sentence == "$412 of API-equivalent value on the $200 Claude Max 20x plan · 2.1x")
        let line = PlanValue.line(plan, range: .last30Days)
        #expect(line == "30 days: $412 of API-equivalent value on the $200 Claude Max 20x plan · 2.1x (estimate)")
        #expect(PlanValue.title(of: .month) == "This month")
        #expect(PlanValue.title(of: .last90Days) == "90 days")
    }

    /// The comparison is withheld rather than guessed at: a span with no fee of its own, a plan the table does
    /// not price, no plan at all, nothing spent, or plans that cost nothing together.
    @Test func aSpanUnderAMonthAndAnUnpricedPlanGetNoRatio() {
        #expect(PlanValue.months(for: .today) == nil)
        #expect(PlanValue.months(for: .yesterday) == nil)
        #expect(PlanValue.months(for: .week) == nil)
        #expect(PlanValue.months(for: .month) == 1)
        #expect(PlanValue.months(for: .last30Days) == 1)
        #expect(PlanValue.months(for: .last90Days) == 3)
        #expect(PlanValue.valueRange(for: .today) == .last30Days)
        #expect(PlanValue.valueRange(for: .week) == .last30Days)
        #expect(PlanValue.valueRange(for: .month) == .month)
        #expect(PlanValue.valueRange(for: .last90Days) == .last90Days)
        #expect(PlanValue.make(values: [(tool: .claude, value: 412)], plans: [.claude: "Max 20x"], months: nil) == nil)
        // A spending assistant whose plan is unpriced takes the ratio away rather than being left out of the fee:
        // its value counted against nobody's price would flatter the others.
        #expect(PlanValue.make(values: [(tool: .claude, value: 412), (tool: .codex, value: 30)],
                               plans: [.claude: "Max 20x", .codex: "Plus"], months: 1) == nil)
        // An assistant with nothing spent in the span needs no price at all.
        #expect(PlanValue.make(values: [(tool: .claude, value: 412), (tool: .codex, value: 0)],
                               plans: [.claude: "Max 20x", .codex: "Plus"], months: 1)?.fee == 200)
        #expect(PlanValue.make(values: [(tool: .claude, value: 412)], plans: [:], months: 1) == nil)
        #expect(PlanValue.make(values: [(tool: .claude, value: 0)], plans: [.claude: "Max 20x"], months: 1) == nil)
        #expect(PlanValue.make(values: [(tool: .cursor, value: 4)], plans: [.cursor: "Free"], months: 1) == nil)
    }

    @Test func aFreePlanBesideAPaidOneNamesThePaidOneAndSeveralPaidPlansAreSummed() throws {
        let one = try #require(PlanValue.make(values: [(tool: .claude, value: 900), (tool: .cursor, value: 100)],
                                              plans: [.claude: "Max 5x", .cursor: "Free"], months: 1))
        #expect(one.fee == 100)
        #expect(one.phrase == "on the $100 Claude Max 5x plan")
        #expect(one.multiple == "10x")
        let two = try #require(PlanValue.make(values: [(tool: .claude, value: 300), (tool: .cursor, value: 100)],
                                              plans: [.claude: "Pro", .cursor: "Pro"], months: 1))
        #expect(two.fee == 40)
        #expect(two.phrase == "on $40 of plans")
        #expect(two.sentence == "$400 of API-equivalent value on $40 of plans · 10x")
    }

    @Test func ninetyDaysSetsThreeMonthsOfFeesAgainstThreeMonthsOfRecords() throws {
        let three = try #require(PlanValue.make(values: [(tool: .claude, value: 900)], plans: [.claude: "Max 5x"], months: 3, covered: true))
        #expect(three.fee == 300)
        #expect(three.multiple == "3x")
        #expect(three.phrase == "on 3 months of the $100 Claude Max 5x plan")
        let twoPlans = try #require(PlanValue.make(values: [(tool: .claude, value: 900), (tool: .cursor, value: 90)],
                                                   plans: [.claude: "Pro", .cursor: "Pro"], months: 3, covered: true))
        #expect(twoPlans.phrase == "on $120 of plans over 3 months")
        #expect(PlanValue.make(values: [(tool: .claude, value: 900)], plans: [.claude: "Max 5x"], months: 3, covered: false) == nil)
        // A single month never asks for coverage: the thirty days are the thirty days.
        #expect(PlanValue.make(values: [(tool: .claude, value: 900)], plans: [.claude: "Max 5x"], months: 1, covered: false) != nil)
    }

    /// Coverage on real providers: a series whose first spend lies inside the ninety days does not cover them,
    /// Claude Code's durable history can, and it says nothing about Cursor's export.
    @Test func coverageComesFromTheSeriesOrClaudesHistory() throws {
        let today = utc.startOfDay(for: now)
        let start = try #require(utc.date(byAdding: .day, value: -89, to: today))
        let longAgo = utc.date(byAdding: .day, value: -200, to: today)
        func provider(_ tool: ToolID, daysAgo: Int) throws -> ProviderCost {
            let day = try #require(utc.date(byAdding: .day, value: -daysAgo, to: today))
            let record = CostHistory.Record(cost: 10, tokens: TokenBreakdown(input: 1000), byModel: [:], byProject: [:])
            return try #require(ProviderCost.build(tool: tool, source: tool == .cursor ? .billingExport : .localTranscripts,
                                                   days: [day: record, today: record], now: now, weekStart: today, calendar: utc, scannedAt: now))
        }
        #expect(PlanValue.covers(try provider(.claude, daysAgo: 89), from: start, firstUse: nil, calendar: utc))
        #expect(!PlanValue.covers(try provider(.claude, daysAgo: 40), from: start, firstUse: nil, calendar: utc))
        #expect(PlanValue.covers(try provider(.claude, daysAgo: 40), from: start, firstUse: longAgo, calendar: utc))
        #expect(!PlanValue.covers(try provider(.cursor, daysAgo: 40), from: start, firstUse: longAgo, calendar: utc),
                "Claude's history says nothing about Cursor")
        let selection = CostSelection(providers: [try provider(.claude, daysAgo: 40)])
        #expect(PlanValue.make(selection: selection, plans: [.claude: "Max 5x"], range: .last90Days, now: now, calendar: utc) == nil)
        #expect(PlanValue.make(selection: selection, plans: [.claude: "Max 5x"], range: .last90Days, firstUse: longAgo, now: now, calendar: utc)?.fee == 300)
        #expect(PlanValue.make(selection: selection, plans: [.claude: "Max 5x"], range: .last30Days, now: now, calendar: utc)?.fee == 100)
    }
}
