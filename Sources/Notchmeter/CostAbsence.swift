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
    /// Nothing has been read for it yet, and nothing else is known.
    case notReadYet

    var text: String {
        switch self {
        case .settingOff(let setting): L("“%@” is off in Settings", setting)
        case .problem(let problem): problem
        case .nothingLocalYet: L("no sessions on this Mac yet")
        case .notReadYet: L("no spend read yet")
        }
    }

    /// Every carried assistant that reported nothing, in the card's own order, each with its reason. Empty once
    /// they all report, which is when the card says nothing about absence at all.
    static func gaps(carried: [ToolID], reporting: Set<ToolID>, cursorUsageEvents: Bool,
                     problems: [ToolID: String], nothingLocal: Set<ToolID>) -> [CostGap] {
        carried.filter { $0.reportsCost && !reporting.contains($0) }.map { tool in
            CostGap(tool: tool, reason: reason(for: tool, cursorUsageEvents: cursorUsageEvents,
                                               problem: problems[tool], nothingLocal: nothingLocal.contains(tool)))
        }
    }

    /// Most explanatory first: a read that is switched off, then a read that went wrong, then a tool with nothing
    /// of its own on this Mac, and only then the bare fact that nothing has been read.
    static func reason(for tool: ToolID, cursorUsageEvents: Bool, problem: String?, nothingLocal: Bool) -> CostAbsence {
        if tool == .cursor, !cursorUsageEvents { return .settingOff(L("Also read Cursor's usage events")) }
        if let problem, !problem.isEmpty { return .problem(problem) }
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
