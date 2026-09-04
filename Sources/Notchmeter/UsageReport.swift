import Foundation

/// The machine-readable picture of everything the app knows, for `--probe --json`, the local API, the command-line
/// tool, the MCP server and the Claude Code skill: one versioned object with sorted keys and no token anywhere.
/// Additive keys since the first version: `source` per window (WindowSource), `runOut` (the interval's two edges),
/// `hiddenByDefault`, `rawUsedPercent`, `amountUSD`; `agents`, `branch`, `pr`, `permissionMode` and `host` per
/// session; the five `tokenBuckets` and `cacheWrite1hShare` per cost range, `metering`, `cursor` in the cost
/// object; `history` (the daily rows) when asked; `pid`, the writing process. Exit codes mirror
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
    let runOuts: [DrainLog.Key: RunOutInterval]
    let sessions: [AgentSession]
    let history: [Date: CostHistory.Record]?
    let now: Date
    /// A report read back from its JSON (the report file, the local API), served verbatim.
    let raw: [String: Any]?

    init(tools: [ToolID: ToolStatus], order: [ToolID] = ToolID.allCases, cost: CostSummary?, advice: [Advice],
         drains: [DrainLog.Key: Drain] = [:], runOuts: [DrainLog.Key: RunOutInterval] = [:], sessions: [AgentSession] = [],
         history: [Date: CostHistory.Record]? = nil, now: Date = Date()) {
        self.tools = tools
        self.order = order
        self.cost = cost
        self.advice = advice
        self.drains = drains
        self.runOuts = runOuts
        self.sessions = sessions
        self.history = history
        self.now = now
        self.raw = nil
    }

    init(raw: [String: Any]) {
        self.tools = [:]
        self.order = []
        self.cost = nil
        self.advice = []
        self.drains = [:]
        self.runOuts = [:]
        self.sessions = []
        self.history = nil
        self.now = (raw["generatedAt"] as? String).flatMap(DateParsing.iso8601) ?? Date()
        self.raw = raw
    }

    /// The same report narrowed to one tool: its sessions come with it (each carries its tool), while the cost and
    /// the history are Claude's alone.
    func limited(to tool: ToolID) -> UsageReport {
        if var raw {
            raw["tools"] = (raw["tools"] as? [[String: Any]])?.filter { $0["tool"] as? String == tool.rawValue } ?? []
            raw["advice"] = (raw["advice"] as? [[String: Any]])?.filter { $0["tool"] as? String == tool.rawValue } ?? []
            raw["sessions"] = (raw["sessions"] as? [[String: Any]])?.filter { $0["tool"] as? String == tool.rawValue } ?? []
            if tool != .claude {
                raw["cost"] = nil
                raw["history"] = nil
            }
            return UsageReport(raw: raw)
        }
        return UsageReport(tools: tools.filter { $0.key == tool }, order: [tool], cost: tool == .claude ? cost : nil,
                           advice: advice.filter { $0.tool == tool }, drains: drains, runOuts: runOuts, sessions: sessions.filter { $0.tool == tool },
                           history: tool == .claude ? history : nil, now: now)
    }

    /// Near: any limited window at 80 % or behind pace; hit: any at 100 %; no session: readings with nothing used.
    var exitCode: ExitCode {
        if let raw { return ExitCode(rawValue: Int32(JSON.number(raw["exitCode"]) ?? 30)) ?? .noData }
        let readings = order.compactMap { tools[$0]?.reading }
        let windows = readings.flatMap(\.windows).filter { $0.usedFraction != nil }
        guard !windows.isEmpty else { return .noData }
        if windows.contains(where: { ($0.usedFraction ?? 0) >= 1 }) { return .limitHit }
        if windows.contains(where: { ($0.usedFraction ?? 0) >= 0.8 || Pace.status(for: $0, now: now) == .behind }) { return .nearLimit }
        if windows.allSatisfy({ ($0.usedFraction ?? 0) == 0 }) { return .noSession }
        return .ok
    }

    var object: [String: Any] {
        if let raw { return raw }
        var root: [String: Any] = [
            "schema": Self.schema,
            "generatedAt": Oracle.timestamp(now),
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "exitCode": Int(exitCode.rawValue),
            "tools": order.compactMap { tool -> [String: Any]? in
                guard let status = tools[tool] else { return nil }
                return toolObject(tool, status)
            },
            "advice": advice.map { ["id": $0.id, "priority": String(describing: $0.priority), "tool": $0.tool?.rawValue as Any, "text": $0.text, "url": $0.url?.absoluteString as Any] },
            "sessions": sessions.map { session -> [String: Any] in
                ["id": session.id, "tool": session.tool.rawValue, "project": session.project as Any, "state": Self.stateName(session.state),
                 "stateSeconds": session.stateDuration(now: now).map { Int($0) } as Any, "agents": session.agents.count,
                 "branch": session.branch as Any, "pr": session.prURL as Any, "permissionMode": session.permissionMode as Any, "host": session.host as Any]
            },
        ]
        if let cost { root["cost"] = costObject(cost) }
        if let history { root["history"] = Self.historyRows(history) }
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
        if case .idle(let message) = status { object["note"] = message }
        if let reading = status.reading {
            object["plan"] = reading.plan as Any
            object["fetchedAt"] = Oracle.timestamp(reading.fetchedAt)
            object["stale"] = status.staleReading != nil
            object["windows"] = reading.windows.map { window -> [String: Any] in
                let key = DrainLog.Key(tool: tool, window: window.id)
                let drain = drains[key]
                let runOut = runOuts[key]
                return [
                    "id": window.id, "label": window.label, "usedFraction": window.usedFraction.map(Oracle.fraction) as Any,
                    "resetsAt": window.resetsAt.map(Oracle.timestamp) as Any, "periodDuration": window.periodDuration.map { Int($0) } as Any,
                    "pace": Pace.status(for: window, now: now).map { String(describing: $0) } as Any,
                    "projectedFraction": projected(window).map(Oracle.fraction) as Any,
                    "model": window.model as Any, "note": window.note as Any, "source": window.source.rawValue,
                    "hiddenByDefault": window.hiddenByDefault, "rawUsedPercent": window.rawUsedPercent as Any, "amountUSD": window.amountUSD.map(Self.money) as Any,
                    "drainLastHour": drain.map { ["from": Oracle.fraction($0.from), "to": Oracle.fraction($0.to), "perHour": $0.perHour.map(Oracle.fraction) as Any] } as Any,
                    "runOut": runOut.map { ["earliestAt": Oracle.timestamp(now.addingTimeInterval($0.earliest)), "latestAt": Oracle.timestamp(now.addingTimeInterval($0.latest)),
                                            "samples": $0.sampleCount] } as Any,
                ]
            }
        }
        return object
    }

    private func projected(_ window: LimitWindow) -> Double? {
        guard let used = window.usedFraction, let resetsAt = window.resetsAt, let period = window.periodDuration else { return nil }
        return Pace.evaluate(usedFraction: used, resetsAt: resetsAt, period: period, now: now)?.projectedFraction
    }

    static func buckets(_ tokens: TokenBreakdown) -> [String: Any] {
        ["input": tokens.input, "output": tokens.output, "cacheWrite5m": tokens.cacheWrite5m, "cacheWrite1h": tokens.cacheWrite1h, "cacheRead": tokens.cacheRead]
    }

    private func costObject(_ cost: CostSummary) -> [String: Any] {
        func shares(_ list: [CostShare]) -> [[String: Any]] {
            list.map { ["name": $0.name, "cost": Self.money($0.cost)] }
        }
        func range(_ totals: RangeTotals) -> [String: Any] {
            ["cost": Self.money(totals.cost), "tokens": totals.tokens.total, "cacheReadShare": totals.tokens.cacheReadShare.map(Oracle.fraction) as Any,
             "tokenBuckets": Self.buckets(totals.tokens), "cacheWrite1hShare": CacheTTL.oneHourShare(totals.tokens).map(Oracle.fraction) as Any,
             "costPerMillionTokens": totals.costPerMillionTokens.map(Self.money) as Any,
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
                               "tokens": block.tokens.total, "tokenBuckets": Self.buckets(block.tokens), "tokensPerMinute": block.tokensPerMinute.map { Int($0.rounded()) } as Any]
        }
        if let metering = cost.sessionMetering {
            object["metering"] = ["tokensPerPercentOfSession": Int(metering.tokensPerPercent.rounded()), "median30Days": metering.median.map { Int($0.rounded()) } as Any,
                                  "heavierBy": metering.multiple.map(Oracle.fraction) as Any]
        }
        if !cost.providers.isEmpty {
            object["providers"] = cost.providers.map { provider -> [String: Any] in
                var entry: [String: Any] = [
                    "tool": provider.tool.rawValue, "source": provider.source.rawValue, "scannedAt": Oracle.timestamp(provider.scannedAt),
                    "today": Self.money(provider.totals(.today).cost), "yesterday": Self.money(provider.totals(.yesterday).cost),
                    "week": Self.money(provider.totals(.week).cost), "month": Self.money(provider.totals(.month).cost),
                    "last30Days": Self.money(provider.totals(.last30Days).cost), "last90Days": Self.money(provider.totals(.last90Days).cost),
                    "byModel": shares(provider.totals(.last30Days).models), "unpricedModels": provider.unpricedModels.sorted(),
                ]
                if let lastHour = provider.lastHour { entry["lastHour"] = Self.money(lastHour) }
                if let typical = provider.typicalHourly { entry["typicalHourly"] = Self.money(typical) }
                if let burn = provider.burnMultiple { entry["burnMultiple"] = Oracle.fraction(burn) }
                if let problem = provider.problem { entry["problem"] = problem }
                return entry
            }
        }
        return object
    }

    /// One row per day, oldest first: day, cost, the five token buckets, the top model, per-model and per-project cost.
    static func historyRows(_ history: [Date: CostHistory.Record], calendar: Calendar = .current) -> [[String: Any]] {
        history.sorted { $0.key < $1.key }.map { day, record in
            ["day": CostHistory.key(day, calendar: calendar), "cost": money(record.cost), "tokenBuckets": buckets(record.tokens), "tokens": record.tokens.total,
             "topModel": record.topModel as Any, "byModel": record.byModel.mapValues(money), "byProject": record.byProject.mapValues(money),
             "sessionTokensPerPercent": record.sessionTokensPerPercent.map { Int($0.rounded()) } as Any]
        }
    }

    static func money(_ value: Double) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.4f", value), locale: Locale(identifier: "en_US_POSIX"))
    }
}
