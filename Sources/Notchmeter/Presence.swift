import Foundation

/// How loud the compact rings are. The calm rule: silent at 40 % used, legible at 80 %, impossible to miss once
/// the pace crosses. In numbers: quiet while every limited window is under `Presence.quietBelow` and none is on
/// track or behind; urgent once any window is behind pace or has run out, or Claude Code is waiting for the user;
/// legible in between.
enum PresenceLevel: Equatable {
    /// Rings shrink and dim.
    case quiet
    /// Full size, no motion.
    case legible
    /// Full size and a slow opacity pulse (none under Reduce Motion).
    case urgent
}

enum Presence {
    static let quietBelow = 0.4

    static func level(windows: [LimitWindow], awaitingInput: Bool, now: Date = Date()) -> PresenceLevel {
        if awaitingInput { return .urgent }
        var quiet = true
        for window in windows {
            guard let used = window.usedFraction else { continue }
            let pace = Pace.status(for: window, now: now)
            if used >= 1 || pace == .behind { return .urgent }
            if used >= quietBelow || pace == .onTrack { quiet = false }
        }
        return quiet ? .quiet : .legible
    }
}
