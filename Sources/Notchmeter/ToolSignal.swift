import Foundation

/// What an assistant is asking of the user, as against how full its meters are. Two things stop an agent and put
/// the ball back in the user's court — a permission prompt or a question it will not proceed past, and a turn that
/// has just ended — and the instruction is the same either way: go and look. So both take one colour on the rings,
/// and the mark beside them says which, which is also what keeps the distinction off colour alone.
///
/// Nothing here is Claude-specific. Claude Code's hook is the only one that reports these events today; the others
/// are on the roadmap (docs/roadmap.md), and the day one lands its sessions carry its own `ToolID` and light these
/// same lamps with no change above `SessionTracker`. Nothing here is inferred from a file's modification time
/// either: `AgentActivity` knows when a transcript last changed, which is not the same fact as an agent holding a
/// permission prompt open, and a ring that claimed it was would be asserting a guess in the one moment a reader
/// most needs it to be right.
enum ToolSignal: Equatable, Sendable {
    /// Sessions are blocked on the user, and how many.
    case waiting(count: Int)
    /// A turn ended inside the hold, and how long it ran.
    case finished(turn: TimeInterval)

    /// The turn that ended and when, kept on the session that earned it so it can outlive neither that session nor
    /// its own hold.
    struct Finish: Equatable, Sendable {
        let turn: TimeInterval
        let at: Date
    }

    /// A turn ends the instant the hook's Stop arrives, so the ring has to let go of it on its own. Ninety seconds
    /// sits between the urgency pulse (7.5 s, over before anyone walks back) and the five minutes a hook event's
    /// wake keeps the rings up for — which matters, because a finish does not raise the presence level, and a hold
    /// longer than that wake could land on a strip collapsed to a 4 pt dot, where hue would be the only thing left
    /// carrying it. What actually keeps the state honest is not the length but the three releases in `resolve`: in
    /// a live back-and-forth the next prompt clears it in seconds, so a lit ring means the user really has stopped
    /// being asked for anything.
    static let heldFor: TimeInterval = 90

    /// A turn shorter than this ended while the user was still watching it and needs no telling. The
    /// notification's own floor is `Preferences.finishedAfterMinutes` — minutes, not seconds — because a banner
    /// interrupts and so has to be earned; a ring interrupts nothing and only has to be true.
    static let finishedAfter: TimeInterval = 20

    /// The whole rule, pure so the tests can pin it. A wait outranks a finish because a wait is blocking and a
    /// finish is only news. A finish is dropped when that tool is working again (something is still running, so the
    /// user is not the bottleneck), when the user has already attended to the rings since it landed, or when the
    /// hold has run out — whichever comes first. Nothing here may retire a wait: a wait ends when the hook says it
    /// ended, or when `SessionTracker.expire` times it out at ten minutes.
    static func resolve(waiting: Int, finish: Finish?, working: Bool, attended: Date?, now: Date) -> ToolSignal? {
        if waiting > 0 { return .waiting(count: waiting) }
        guard let finish, !working, finish.turn >= finishedAfter,
              now.timeIntervalSince(finish.at) < heldFor,
              attended.map({ $0 < finish.at }) ?? true
        else { return nil }
        return .finished(turn: finish.turn)
    }

    /// The symbol on the card and on the menu bar's glyph: the hand the Advice strip already raises for a wait
    /// (Advisor.waiting), and a tick for a turn that is done.
    var symbolName: String {
        switch self {
        case .waiting: "hand.raised.fill"
        case .finished: "checkmark.circle.fill"
        }
    }

    /// The short label the expanded card carries beside the tool's name, where there is room for words. Its own
    /// keys rather than the sound picker's "Waiting for you": a row that names a sound and a line that reports a
    /// state want different registers in the languages that inflect them, and one key cannot be proofread for both.
    var cardText: String {
        switch self {
        case .waiting: L("Waiting for your answer")
        case .finished: L("Just finished")
        }
    }

    /// What VoiceOver reads before the windows, since it is the only part of the readout the listener can act on.
    ///
    /// The count comes with it past one. `WaitingDot` puts the number in the disc, so a sighted reader could see
    /// that four sessions were blocked and a listener heard "waiting for your input" for four exactly as for one —
    /// the state's own figure carried by shape alone, which is the mirror of the rule that colour never carries one
    /// alone. The count is joined on rather than folded into its own sentence so it can reuse the tables' existing
    /// session keys; `MenuBarItem` builds its accessibility value by joining in the same way.
    var spokenText: String {
        switch self {
        case .waiting(let count):
            count > 1 ? [L("waiting for your input"), L("%ld sessions", count)].joined(separator: ", ") : L("waiting for your input")
        case .finished: L("just finished a turn")
        }
    }

    var isWaiting: Bool {
        if case .waiting = self { return true }
        return false
    }
}
