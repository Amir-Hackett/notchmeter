import Foundation

/// What the store knows about a tool's own read of a vendor endpoint, so a cost figure that came from one carries
/// that read's freshness and its error rather than the moment the local scan happened to run.
struct ProviderReadState: Equatable, Sendable {
    var readAt: Date?
    var problem: String?

    init(readAt: Date? = nil, problem: String? = nil) {
        self.readAt = readAt
        self.problem = problem
    }
}

/// Cursor's spend as Cursor itself priced it. `CursorProvider` fetches the account's usage-events export on its
/// own loop and folds each event's own dollar cost into the daily-totals file; this reads that file back. Nothing
/// is priced here, which is why the source is the vendor's own export rather than an estimate.
struct CursorCostReader: Sendable {
    let history: CostHistory

    init(history: CostHistory = CostHistory(tool: .cursor)) {
        self.history = history
    }

    func read(now: Date, daysBack: Int, weekStart: Date, calendar: Calendar, state: ProviderReadState) -> ProviderCost? {
        let days = history.load(calendar: calendar)
        guard !days.isEmpty else { return nil }
        return ProviderCost.build(tool: .cursor, source: .billingExport, days: days, now: now, daysBack: daysBack,
                                  weekStart: weekStart, calendar: calendar, scannedAt: state.readAt ?? now, problem: state.problem)
    }
}

/// Runs every tool's cost scanner and assembles one summary.
///
/// The scanners are independent by construction: each reads its own source in its own child task and answers with
/// its own `ProviderCost`, carrying its own freshness stamp and problem. A Cursor export that is stale, refused or
/// never fetched cannot delay or empty the Claude scan, and a Mac with no Codex sessions simply has no Codex cost.
struct CostEngine: Sendable {
    let claude: ClaudeCostScanner
    let codex: CodexCostScanner
    let cursor: CursorCostReader

    init(claude: ClaudeCostScanner = ClaudeCostScanner(), codex: CodexCostScanner = CodexCostScanner(),
         cursor: CursorCostReader = CursorCostReader()) {
        self.claude = claude
        self.codex = codex
        self.cursor = cursor
    }

    /// The week every tool's spend is measured against: where the live Claude weekly window started, else the
    /// calendar week. One boundary for the whole card, so the ranges add up.
    static func weekStart(weeklyResetsAt: Date?, now: Date, calendar: Calendar) -> Date {
        weeklyResetsAt.map { $0.addingTimeInterval(-Period.week) }
            ?? calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
    }

    func scan(tools: Set<ToolID> = Set(ToolID.allCases), reads: [ToolID: ProviderReadState] = [:], now: Date = Date(), daysBack: Int = 30,
              weeklyResetsAt: Date? = nil, weeklyUsed: Double? = nil, sessionResetsAt: Date? = nil, sessionUsed: Double? = nil,
              calendar: Calendar = .current) async -> CostSummary {
        let week = Self.weekStart(weeklyResetsAt: weeklyResetsAt, now: now, calendar: calendar)
        async let claudeSummary = claudeCost(tools: tools, now: now, daysBack: daysBack, weeklyResetsAt: weeklyResetsAt,
                                             weeklyUsed: weeklyUsed, sessionResetsAt: sessionResetsAt, sessionUsed: sessionUsed, calendar: calendar)
        async let codexCost = codexCost(tools: tools, now: now, daysBack: daysBack, weekStart: week, calendar: calendar)
        let cursorCost = tools.contains(.cursor)
            ? cursor.read(now: now, daysBack: daysBack, weekStart: week, calendar: calendar, state: reads[.cursor] ?? ProviderReadState())
            : nil
        let summary = await claudeSummary ?? CostSummary.empty.with(scannedAt: now)
        return summary.adding([await codexCost, cursorCost].compactMap { $0 })
    }

    private func claudeCost(tools: Set<ToolID>, now: Date, daysBack: Int, weeklyResetsAt: Date?, weeklyUsed: Double?,
                            sessionResetsAt: Date?, sessionUsed: Double?, calendar: Calendar) async -> CostSummary? {
        guard tools.contains(.claude) else { return nil }
        return await claude.scan(now: now, daysBack: daysBack, weeklyResetsAt: weeklyResetsAt, weeklyUsed: weeklyUsed,
                                 sessionResetsAt: sessionResetsAt, sessionUsed: sessionUsed, calendar: calendar)
    }

    private func codexCost(tools: Set<ToolID>, now: Date, daysBack: Int, weekStart: Date, calendar: Calendar) async -> ProviderCost? {
        guard tools.contains(.codex) else { return nil }
        return await codex.scan(now: now, daysBack: daysBack, weekStart: weekStart, calendar: calendar)
    }
}
