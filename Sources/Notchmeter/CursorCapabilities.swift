import AppKit
import Foundation

/// Where each Cursor feature comes from on this Mac, each falling back on its own rather than the whole
/// integration at once: Cursor's hook first, then Cursor's own files (transcripts, plan files), then Accessibility,
/// then only opening Cursor. Shown in Diagnostics, so a report says which path a feature took and why.
enum CursorCapabilities {
    enum Source: String, Sendable {
        case hook, localData = "local data", accessibility, openOnly = "open in Cursor", unavailable
    }

    struct Entry: Equatable, Sendable {
        let feature: String
        let source: Source
        let reason: String
    }

    struct Inputs: Equatable, Sendable {
        var version: String?
        var hookInstalled = false
        var hookCurrent = false
        var readsSessions = true
        var answersFromNotch = true
        var requireApproval = false
        var mirrorCards = false
        var trusted = false
        var running = false
    }

    static func entries(_ inputs: Inputs) -> [Entry] {
        guard inputs.readsSessions else { return [Entry(feature: "everything", source: .unavailable, reason: "Cursor's sessions are not read")] }
        let cards = inputs.mirrorCards && inputs.trusted
        let cardsReason = !inputs.mirrorCards ? "Mirror Cursor's cards is off" : !inputs.trusted ? "Accessibility is not granted" : !inputs.running ? "Cursor is not running" : "reads Cursor's cards"
        var out: [Entry] = []
        out.append(inputs.hookInstalled
            ? Entry(feature: "sessions", source: .hook, reason: inputs.hookCurrent ? "hook current" : "hook out of date: Repair")
            : Entry(feature: "sessions", source: .localData, reason: "no hook: running chats found from Cursor's own files"))
        out.append(Entry(feature: "plans and tasks", source: .localData, reason: "transcript and ~/.cursor/plans; Cursor's hooks never fire for TodoWrite or CreatePlan"))
        if inputs.hookInstalled, inputs.hookCurrent, inputs.answersFromNotch, inputs.requireApproval {
            out.append(Entry(feature: "run approval", source: .hook, reason: "every command held for the notch"))
        } else if cards {
            out.append(Entry(feature: "run approval", source: .accessibility, reason: cardsReason))
        } else {
            let why = !inputs.hookCurrent ? "hook not current" : !inputs.answersFromNotch ? "Answer from the notch is off" : "Require notch approval is off; " + cardsReason
            out.append(Entry(feature: "run approval", source: .openOnly, reason: why))
        }
        out.append(Entry(feature: "mode switch", source: cards ? .accessibility : .openOnly, reason: cardsReason))
        out.append(Entry(feature: "build", source: cards ? .accessibility : .openOnly, reason: cardsReason))
        out.append(Entry(feature: "view plan", source: .openOnly, reason: "opens the plan file in Cursor"))
        out.append(Entry(feature: "questions", source: .openOnly, reason: "Cursor's question card is not recognised yet"))
        return out
    }

    /// One Diagnostics line.
    static func line(_ inputs: Inputs) -> String {
        "Cursor \(inputs.version ?? "not installed"): " + entries(inputs).map { "\($0.feature) \($0.source.rawValue) (\($0.reason))" }.joined(separator: "; ")
    }

    /// The installed Cursor's version, from its bundle.
    @MainActor static func installedVersion() -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: TerminalJump.BundleID.cursor) else { return nil }
        return Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    @MainActor static var running: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: TerminalJump.BundleID.cursor).isEmpty
    }
}
