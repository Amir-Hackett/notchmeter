import Foundation

/// Where a tool's spend figure came from. It is printed beside the figure because a number priced here from local
/// files at published rates and a number the vendor itself billed are not the same kind of number.
enum CostSource: String, Codable, Equatable, Sendable {
    /// Priced here from the tool's own transcripts at published list rates (Claude Code).
    case localTranscripts
    /// Priced here from the tool's own session rollouts at published list rates (Codex).
    case localSessions
    /// The vendor's own per-request costs, read from its usage export (Cursor).
    case billingExport

    var label: String {
        switch self {
        case .localTranscripts: L("local transcripts")
        case .localSessions: L("local sessions")
        case .billingExport: L("billing export")
        }
    }

    /// True where the dollars are this Mac's arithmetic over published rates rather than a figure the vendor sent.
    var isEstimate: Bool { self != .billingExport }
}

/// One tool's spend: the ranges the Cost card offers, a daily series, the per-model shares of each range, the
/// source the figures came from, when they were read and what went wrong if anything did.
///
/// A tool whose spend cannot be derived from a source it publishes has no `ProviderCost` at all. GitHub Copilot
/// (a flat seat with no per-request price) and Antigravity (quota, no dollars) never build one, so the card shows
/// nothing for them rather than a zero that would read as "you spent nothing". docs/accuracy.md says why.
struct ProviderCost: Equatable, Sendable, Identifiable {
    let tool: ToolID
    let source: CostSource
    let ranges: [CostRange: RangeTotals]
    /// One entry per calendar day for the last 30 days, oldest first.
    let daily: [DailySpend]
    /// Ninety days, where the durable history reaches back that far.
    let daily90: [DailySpend]
    /// Everything priced in the last 60 minutes; nil where the source is day-resolution and cannot say.
    let lastHour: Double?
    /// Mean cost of an active hour over the window; nil with the same limit.
    let typicalHourly: Double?
    /// lastHour / typicalHourly, on the same five-active-hours guard the Claude figure uses; nil until then.
    let burnMultiple: Double?
    /// Model ids the source named that this build has no published rate for; their tokens contribute nothing.
    let unpricedModels: Set<String>
    /// When these figures were read from their source, which is not when the app last drew them.
    let scannedAt: Date
    /// Why the figures are missing or older than they should be; nil when the read was clean.
    let problem: String?

    var id: ToolID { tool }

    init(tool: ToolID, source: CostSource, ranges: [CostRange: RangeTotals], daily: [DailySpend], daily90: [DailySpend] = [],
         lastHour: Double? = nil, typicalHourly: Double? = nil, burnMultiple: Double? = nil, unpricedModels: Set<String> = [],
         scannedAt: Date, problem: String? = nil) {
        self.tool = tool
        self.source = source
        self.ranges = ranges
        self.daily = daily
        self.daily90 = daily90.isEmpty ? daily : daily90
        self.lastHour = lastHour
        self.typicalHourly = typicalHourly
        self.burnMultiple = burnMultiple
        self.unpricedModels = unpricedModels
        self.scannedAt = scannedAt
        self.problem = problem
    }

    func totals(_ range: CostRange) -> RangeTotals { ranges[range] ?? RangeTotals() }

    /// True once any range holds something worth showing; a tool with nothing to say is left off the card.
    var hasFigures: Bool {
        ranges.values.contains { $0.cost > 0 || $0.tokens.total > 0 }
    }

    /// Ranges and series from per-day records: the shape every tool's spend reduces to once it is on the day grid.
    /// nil when the records hold nothing, so an installed tool that has spent nothing shows no cost rather than $0.
    static func build(tool: ToolID, source: CostSource, days: [Date: CostHistory.Record], now: Date, daysBack: Int = 30,
                      weekStart: Date, calendar: Calendar = .current, hourly: HourlyBurn? = nil, unpricedModels: Set<String> = [],
                      scannedAt: Date, problem: String? = nil) -> ProviderCost? {
        let today = calendar.startOfDay(for: now)
        guard let windowStart = calendar.date(byAdding: .day, value: -(daysBack - 1), to: today),
              let start90 = calendar.date(byAdding: .day, value: -89, to: today)
        else { return nil }
        let daily = RangeTotals.series(days: days, from: windowStart, count: daysBack, calendar: calendar)
        let daily90 = RangeTotals.series(days: days, from: start90, count: 90, calendar: calendar)
        let ranges = RangeTotals.ranges(days: days, daily: daily, daily90: daily90, weekStart: weekStart, now: now, calendar: calendar)
        let cost = ProviderCost(tool: tool, source: source, ranges: ranges, daily: daily, daily90: daily90, lastHour: hourly?.lastHour,
                                typicalHourly: hourly?.typicalHourly, burnMultiple: hourly?.multiple, unpricedModels: unpricedModels,
                                scannedAt: scannedAt, problem: problem)
        return cost.hasFigures ? cost : nil
    }
}

/// The name the Cost card groups spend under: the folder a turn ran in, whichever tool ran it.
enum ProjectName {
    static func ofPath(_ path: String) -> String? {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }
}

/// The last hour against a normal active hour, for a source whose entries carry a time of day.
struct HourlyBurn: Equatable, Sendable {
    let lastHour: Double
    let typicalHourly: Double
    /// Clock hours in the window with at least one entry; the multiple is withheld under five of them.
    let activeHours: Int

    static let minimumActiveHours = 5

    var multiple: Double? {
        activeHours >= Self.minimumActiveHours && typicalHourly > 0 ? lastHour / typicalHourly : nil
    }

    /// The mean priced cost of an active hour, an active hour being one with at least one entry.
    init(lastHour: Double, costByHour: [Int: Double]) {
        self.lastHour = lastHour
        self.activeHours = costByHour.count
        self.typicalHourly = costByHour.isEmpty ? 0 : costByHour.values.reduce(0, +) / Double(costByHour.count)
    }

    init(lastHour: Double, typicalHourly: Double, activeHours: Int) {
        self.lastHour = lastHour
        self.typicalHourly = typicalHourly
        self.activeHours = activeHours
    }
}

extension RangeTotals {
    init(_ record: CostHistory.Record) {
        self.init(cost: record.cost, tokens: record.tokens, byModel: record.byModel, byProject: record.byProject,
                  byModelTokens: record.byModelTokens, byProjectTokens: record.byProjectTokens)
    }

    /// A per-day series over `count` days from `first`, oldest first, with a zero day where nothing was recorded.
    static func series(days: [Date: CostHistory.Record], from first: Date, count: Int, calendar: Calendar) -> [DailySpend] {
        (0..<count).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: first) else { return nil }
            let record = days[day]
            return DailySpend(day: day, cost: record?.cost ?? 0, tokens: record?.tokens.total ?? 0, topModel: record?.topModel)
        }
    }

    /// Every range the Cost card offers, from day records. `week` is day-aligned from `weekStart`; a source that
    /// knows its own boundary to the minute (Claude's weekly window) replaces it with its own total afterwards.
    static func ranges(days: [Date: CostHistory.Record], daily: [DailySpend], daily90: [DailySpend], weekStart: Date,
                       now: Date, calendar: Calendar) -> [CostRange: RangeTotals] {
        let today = calendar.startOfDay(for: now)
        func total(_ chosen: [Date]) -> RangeTotals {
            var totals = RangeTotals()
            for day in chosen {
                guard let record = days[day] else { continue }
                totals.add(RangeTotals(record))
            }
            return totals
        }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? today
        let weekDay = calendar.startOfDay(for: weekStart)
        return [
            .today: total([today]),
            .yesterday: total([yesterday]),
            .last30Days: total(daily.map(\.day)),
            .last90Days: total(daily90.map(\.day)),
            .month: total(days.keys.filter { $0 >= monthStart && $0 <= today }),
            .week: total(days.keys.filter { $0 >= weekDay && $0 <= today }),
        ]
    }
}
