import Foundation

/// How loud the compact rings are. The calm rule: quiet while every limited window is under `Presence.quietBelow`
/// and none is on track or behind; urgent once any window is behind pace or has run out, or Claude Code is waiting
/// for the user; legible in between (from 80 % the ring's own tint turns orange as well). With the hook installed
/// and no Claude Code session running, a window on pace stays quiet however full it is: nothing is being spent.
/// `hidden` is the Hide when idle visibility's fourth level (UsageStore decides it): a 4 pt dot in place of the rings.
enum PresenceLevel: Equatable {
    /// A dot in place of the rings.
    case hidden
    /// Rings shrink and dim.
    case quiet
    /// Full size, no motion.
    case legible
    /// Full size and three slow opacity pulses on entry, then steady (none under Reduce Motion).
    case urgent
}

enum Presence {
    static let quietBelow = 0.4

    /// `sessions` is how many Claude Code sessions the hook reports; nil while no hook has ever reported one.
    ///
    /// A finished turn is deliberately not an input here. It lifted quiet rings to full size for a while, to make
    /// the tick beside them easier to read, and the cost was that this rule stopped being about how much is left
    /// and how fast: a level that answers a ninety-second clock as well as a set of limits says two things down one
    /// channel, and the nest churns between its 14 pt and 18 pt diameters after every long turn on a readout whose
    /// whole job is to be read at a glance.
    ///
    /// It also put that clock into `presence`, which is read by the view `CompactStripProbe` renders to measure the
    /// strip, so the compact fit's inputs became a function of the time of day. Measured, it did not move the
    /// answer: `CompactRings` pins itself to a hard 18 pt box, so the quiet nest shrinks inside a fixed frame, and
    /// quiet against legible against urgent measures to the same point at one, two and three rings, in all three
    /// compact styles, on both axes and on the API-key readout. That is a fit resting on a frame rather than on
    /// this rule, which is a thing to know rather than a thing to build on.
    ///
    /// The mark answers the need on its own terms instead (CompactRings): it keeps its full size and its full
    /// opacity while the rings around it go quiet, which is what makes a tick on a 14 pt ring readable without
    /// anything else moving.
    static func level(windows: [LimitWindow], awaitingInput: Bool, sessions: Int? = nil, now: Date = Date()) -> PresenceLevel {
        if awaitingInput { return .urgent }
        var quiet = true
        for window in windows {
            guard let used = window.usedFraction else { continue }
            let pace = Pace.status(for: window, now: now)
            if used >= 1 || pace == .behind { return .urgent }
            if pace == .onTrack { quiet = false }
            if used >= quietBelow, sessions.map({ $0 > 0 }) ?? true { quiet = false }
        }
        return quiet ? .quiet : .legible
    }

    /// Hide when idle collapses the rings once no agent has been active for `PollingPolicy.idleAfter`, every window
    /// is quiet and nothing waits on the user; a hook event, file activity, a pace change or the pointer resting on
    /// the rings brings them back at once.
    static func hides(level: PresenceLevel, idleFor: TimeInterval?, wokeAgo: TimeInterval?) -> Bool {
        guard level == .quiet else { return false }
        if let wokeAgo, wokeAgo < 300 { return false }
        guard let idleFor else { return true }
        return idleFor >= PollingPolicy.idleAfter
    }
}
