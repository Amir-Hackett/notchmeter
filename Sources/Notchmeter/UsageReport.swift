import Foundation

/// The machine-readable picture of everything the app knows, for `--probe --json`, the local API and the Claude
/// Code skill: one versioned object with sorted keys and no token anywhere. Exit codes mirror
/// Claude-Code-Usage-Monitor's: 0 fine, 10 near a limit, 11 a limit hit, 20 no session (nothing used), 30 no data.
struct UsageReport {
    static let schema = "notchmeter.limits.v1"

    enum ExitCode: Int32 {
        case ok = 0
        case nearLimit = 10
        case limitHit = 11
        case noSession = 20
        case noData = 30
    }

    let tools: [ToolID: ToolStatus]
    let order: [ToolID]
    let cost: CostSummary?
    let advice: [Advice]
    let drains: [DrainLog.Key: Drain]
    let sessions: [AgentSession]
    let now: Date

    init(tools: [ToolID: ToolStatus], order: [ToolID] = ToolID.allCases, cost: CostSummary?, advice: [Advice],
         drains: [DrainLog.Key: Drain] = [:], sessions: [AgentSession] = [], now: Date = Date()) {
        self.tools = tools
        self.order = order
        self.cost = cost
        self.advice = advice
        self.drains = drains
        self.sessions = sessions
        self.now = now
    }

    /// Near: any limited window at 80 % or behind pace; hit: any at 100 %; no session: readings with nothing used.
    var exitCode: ExitCode {
        let readings = order.compactMap { tools[$0]?.reading }
        let windows = readings.flatMap(\.windows).filter { $0.usedFraction != nil }
        guard !windows.isEmpty else { return .noData }
        if windows.contains(where: { ($0.usedFraction ?? 0) >= 1 }) { return .limitHit }
        if windows.contains(where: { ($0.usedFraction ?? 0) >= 0.8 || Pace.status(for: $0, now: now) == .behind }) { return .nearLimit }
        if windows.allSatisfy({ ($0.usedFraction ?? 0) == 0 }) { return .noSession }
        return .ok
    }

    var object: [String: Any] {
        var root: [String: Any] = [
            "schema": Self.schema,
            "generatedAt": Oracle.timestamp(now),
            "exitCode": Int(exitCode.rawValue),
            "tools": order.compactMap { tool -> [String: Any]? in
                guard let status = tools[tool] else { return nil }
                return toolObject(tool, status)
            },
            "advice": advice.map { ["id": $0.id, "priority": String(describing: $0.priority), "tool": $0.tool?.rawValue as Any, "text": $0.text] },
            "sessions": sessions.map { session -> [String: Any] in
                ["id": session.id, "project": session.project as Any, "state": Self.stateName(session.state),
                 "stateSeconds": session.stateDuration(now: now).map { Int($0) } as Any]
            },
        ]
        if let cost { root["cost"] = costObject(cost) }
        return root
    }

    var json: Data {
        (try? JSONSerialization.data(withJSONObject: Oracle.scrub(object, home: Paths.home.path), options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    static func stateName(_ state: AgentSession.State) -> String {
        switch state {
        case .idle: "idle"
        case .working: "working"
        case .waiting: "waiting"
        }
    }

    private func toolObject(_ tool: ToolID, _ status: ToolStatus) -> [String: Any] {
        var object: [String: Any] = ["tool": tool.rawValue, "name": tool.displayName, "status": Oracle.kind(status), "problem": status.problem as Any]
        if let reading = status.reading {
            object["plan"] = reading.plan as Any
            object["fetchedAt"] = Oracle.timestamp(reading.fetchedAt)
            object["stale"] = status.staleReading != nil
            object["windows"] = reading.windows.map { window -> [String: Any] in
                let drain = drains[DrainLog.Key(tool: tool, window: window.id)]
                return [
                    "id": window.id, "label": window.label, "usedFraction": window.usedFraction.map(Oracle.fraction) as Any,
                    "resetsAt": window.resetsAt.map(Oracle.timestamp) as Any, "periodDuration": window.periodDuration.map { Int($0) } as Any,
                    "pace": Pace.status(for: window, now: now).map { String(describing: $0) } as Any,
                    "projectedFraction": projected(window).map(Oracle.fraction) as Any,
                    "model": window.model as Any, "note": window.note as Any,
                    "drainLastHour": drain.map { ["from": Oracle.fraction($0.from), "to": Oracle.fraction($0.to), "perHour": $0.perHour.map(Oracle.fraction) as Any] } as Any,
                ]
            }
        }
        return object
    }

    private func projected(_ window: LimitWindow) -> Double? {
        guard let used = window.usedFraction, let resetsAt = window.resetsAt, let period = window.periodDuration else { return nil }
        return Pace.evaluate(usedFraction: used, resetsAt: resetsAt, period: period, now: now)?.projectedFraction
    }

    private func costObject(_ cost: CostSummary) -> [String: Any] {
        func shares(_ list: [CostShare]) -> [[String: Any]] {
            list.map { ["name": $0.name, "cost": Self.money($0.cost)] }
        }
        func range(_ totals: RangeTotals) -> [String: Any] {
            ["cost": Self.money(totals.cost), "tokens": totals.tokens.total, "cacheReadShare": totals.tokens.cacheReadShare.map(Oracle.fraction) as Any,
             "byModel": shares(totals.models), "byProject": shares(totals.projects)]
        }
        var object: [String: Any] = [
            "currency": "USD",
            "today": Self.money(cost.today), "yesterday": Self.money(cost.yesterday), "last30Days": Self.money(cost.last30Days),
            "last90Days": Self.money(cost.totals(.last90Days).cost), "month": Self.money(cost.totals(.month).cost),
            "lastHour": Self.money(cost.lastHour), "typicalHourly": Self.money(cost.typicalHourly),
            "burnMultiple": cost.burnMultiple.map { Oracle.fraction($0) } as Any,
            "unpricedModels": cost.unpricedModels.sorted(),
            "sinceFirstUse": Self.money(cost.sinceFirstUse), "firstUse": cost.firstUse.map(Oracle.timestamp) as Any,
            "ranges": ["today": range(cost.totals(.today)), "yesterday": range(cost.totals(.yesterday)), "week": range(cost.totals(.week)),
                       "month": range(cost.totals(.month)), "last30Days": range(cost.totals(.last30Days)), "last90Days": range(cost.totals(.last90Days))],
        ]
        if let week = cost.week {
            object["week"] = ["start": Oracle.timestamp(week.start), "cost": Self.money(week.cost), "perPercentOfWeekly": week.perPercent.map(Self.money) as Any]
        }
        if let block = cost.block {
            object["block"] = ["start": Oracle.timestamp(block.start), "end": Oracle.timestamp(block.end), "cost": Self.money(block.cost),
                               "tokens": block.tokens.total, "tokensPerMinute": block.tokensPerMinute.map { Int($0.rounded()) } as Any]
        }
        return object
    }

    static func money(_ value: Double) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.4f", value), locale: Locale(identifier: "en_US_POSIX"))
    }
}
