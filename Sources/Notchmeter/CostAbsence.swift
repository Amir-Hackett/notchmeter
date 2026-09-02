import Foundation

/// Why an assistant the Cost card carries has no spend of its own to show. Left out in silence it reads as "this
/// costs nothing", which is a different claim from "nothing was read"; every case below is something the app
/// already knows, and none of them guesses (docs/accuracy.md).
enum CostAbsence: Equatable, Sendable {
    /// The read that would price it is switched off, named as the setting that switches it on.
    case settingOff(String)
    /// Its own read failed or went stale, in the words that read gave.
    case problem(String)
    /// Set up, with nothing written on this Mac to price yet.
    case nothingLocalYet
    /// The usage export answered, and this is what it said: an account can genuinely be billed nothing.
    case nothingBilled(events: Int)
    /// Nothing has been read for it yet, and nothing else is known.
    case notReadYet

    var text: String {
        switch self {
        case .settingOff(let setting): L("“%@” is off in Settings", setting)
        case .problem(let problem): problem
        case .nothingLocalYet: L("no sessions on this Mac yet")
        case .nothingBilled(let events):
            events == 0 ? L("nothing used in the last 30 days")
                        : L("%ld usage events in the last 30 days, none of them billed", events)
        case .notReadYet: L("no spend read yet")
        }
    }

    /// Every carried assistant that reported nothing, in the card's own order, each with its reason. Empty once
    /// they all report, which is when the card says nothing about absence at all.
    static func gaps(carried: [ToolID], reporting: Set<ToolID>, cursorUsageEvents: Bool, cursorExport: CursorExportRead? = nil,
                     problems: [ToolID: String], nothingLocal: Set<ToolID>) -> [CostGap] {
        carried.filter { $0.reportsCost && !reporting.contains($0) }.map { tool in
            CostGap(tool: tool, reason: reason(for: tool, cursorUsageEvents: cursorUsageEvents, cursorExport: cursorExport,
                                               problem: problems[tool], nothingLocal: nothingLocal.contains(tool)))
        }
    }

    /// Most explanatory first: a read that is switched off, then a read that went wrong, then what Cursor's own
    /// export answered, then a tool with nothing of its own on this Mac, and only then the bare fact that nothing
    /// has been read. An export that was read and held no billable spend is the one case the card used to get
    /// wrong: it said nothing had been read, which the app knew to be false.
    static func reason(for tool: ToolID, cursorUsageEvents: Bool, cursorExport: CursorExportRead? = nil,
                       problem: String?, nothingLocal: Bool) -> CostAbsence {
        if tool == .cursor, !cursorUsageEvents { return .settingOff(L("Also read Cursor's usage events")) }
        if let problem, !problem.isEmpty { return .problem(problem) }
        if tool == .cursor, let export = cursorExport {
            if let refused = export.problem, !refused.isEmpty { return .problem(refused) }
            if export.costUSD <= 0 { return .nothingBilled(events: export.events) }
        }
        if nothingLocal { return .nothingLocalYet }
        return .notReadYet
    }
}

/// One assistant the Cost card carries with nothing to show, and why, as the card prints it under the legend.
struct CostGap: Equatable, Sendable, Identifiable {
    let tool: ToolID
    let reason: CostAbsence
    var id: ToolID { tool }

    var text: String { "\(tool.displayName): \(reason.text)" }
}
