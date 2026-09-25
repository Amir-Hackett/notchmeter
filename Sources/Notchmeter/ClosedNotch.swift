import SwiftUI

/// What the closed notch shows, chosen apart for while the assistants work and for when nothing is running
/// (Preferences.closedWhileWorking, .closedWhenQuiet): the readouts in the style chosen beside the notch, one
/// assistant symbol each carrying what its sessions are doing, or nothing but the notch itself.
///
/// The readouts answer "how much is left"; the symbols answer "who is doing what"; nothing answers neither, for a
/// reader who wants the notch left alone. A reader who works one way and rests another can have both: the rings
/// while quiet and the symbols while a session runs, or nothing while quiet and the rings while one runs.
enum ClosedNotchMode: String, CaseIterable, Codable {
    case readouts, agents, nothing

    var title: String {
        switch self {
        case .readouts: L("Rings or numbers")
        case .agents: L("Assistant symbols")
        case .nothing: L("Nothing")
        }
    }
}

/// The rules the closed notch switches its two modes by. Pure, so they are tested without a notch.
enum ClosedNotch {
    /// Work: a session is working, waiting for the reader, holding a request, or has just finished a turn the
    /// ring still reports (ToolSignal). Quiet: none is. The phase only exists where a hook reports sessions; with
    /// none installed the notch is always quiet, which is what it has no evidence against.
    enum Phase: String, Equatable, Sendable {
        case work, quiet
    }

    /// Whether anything the hooks report is going on. `signalled` is whether any visible assistant's ring carries
    /// a signal, which is how a finished turn is counted: a turn that ended is news only while its tick is lit, and
    /// the tick's own rules (a turn long enough to report, not yet looked at) are ToolSignal's, not repeated here.
    static func active(sessions: [AgentSession], signalled: Bool) -> Bool {
        signalled || sessions.contains { $0.isWorking || $0.isWaiting || $0.pending != nil }
    }

    /// The mode in force. The chosen one for the phase, with one exception: a bare notch gives way to the readouts
    /// while the rings are urgent (PresenceLevel.urgent: a window out or behind pace, or an assistant waiting), so
    /// choosing nothing for quiet never hides a limit that is running out. The symbols are not overridden: they
    /// carry the waiting mark themselves, and a limit is the readouts' news, which the symbols never claimed to
    /// tell.
    static func shows(phase: Phase, whileWorking: ClosedNotchMode, whenQuiet: ClosedNotchMode, urgent: Bool) -> ClosedNotchMode {
        let chosen = phase == .work ? whileWorking : whenQuiet
        return chosen == .nothing && urgent ? .readouts : chosen
    }
}

/// The work phase outlasts the activity by `hold`: a quick turn ends and the next prompt starts a few seconds
/// later, and a notch that swapped its readouts for its symbols and back at each boundary would flicker in the
/// corner of the reader's eye all afternoon. Five seconds covers the gap between answering and the next turn; a
/// finished turn long enough to report holds the phase for ToolSignal's ninety seconds by itself, since its tick
/// counts as activity.
struct ClosedNotchClock: Equatable, Sendable {
    static let hold: TimeInterval = 5

    private(set) var phase: ClosedNotch.Phase = .quiet
    /// When the activity last stopped, while the hold after it runs.
    private var endedAt: Date?

    /// Feeds whether anything is active now; returns when to ask again, while a hold is running and nothing else
    /// would bring the answer back before it ends.
    mutating func update(active: Bool, now: Date) -> Date? {
        if active {
            phase = .work
            endedAt = nil
            return nil
        }
        guard phase == .work else { return nil }
        let ended = endedAt ?? now
        endedAt = ended
        let until = ended.addingTimeInterval(Self.hold)
        guard now < until else {
            phase = .quiet
            endedAt = nil
            return nil
        }
        return until
    }
}

/// One assistant as the closed notch draws it in the symbols mode: what its sessions are doing, worst first.
enum AgentGlyphState: Equatable, Sendable {
    case waiting(count: Int)
    case working
    case finished
    /// Sessions the hook knows about, none of them doing anything.
    case idle
    /// No session known: the hook has reported none, or is not installed.
    case none

    static func of(signal: ToolSignal?, working: Bool, sessions: Int?) -> AgentGlyphState {
        if case .waiting(let count)? = signal { return .waiting(count: count) }
        if working { return .working }
        if case .finished? = signal { return .finished }
        return (sessions ?? 0) > 0 ? .idle : .none
    }

    /// What VoiceOver reads after the assistant's name.
    var spoken: String {
        switch self {
        case .waiting(let count): ToolSignal.waiting(count: count).spokenText
        case .working: L("Working")
        case .finished: ToolSignal.finished(turn: 0).spokenText
        case .idle: L("Idle")
        case .none: L("No sessions right now")
        }
    }

    /// The signal the corner mark draws, the same marks the rings carry.
    var signal: ToolSignal? {
        switch self {
        case .waiting(let count): .waiting(count: count)
        case .finished: .finished(turn: 0)
        case .working, .idle, .none: nil
        }
    }

    /// What is drawn under the symbol: a bar while a session works, a small hollow ring while sessions idle (the
    /// Sessions card's idle mark in miniature), nothing otherwise. The ring is what tells idle from no session
    /// at all for a reader who cannot tell the assistant's colour from the caption's grey; without it the two
    /// differed by colour alone.
    enum UnderMark: Equatable, Sendable {
        case bar, ring
    }

    var underMark: UnderMark? {
        switch self {
        case .working: .bar
        case .idle: .ring
        case .waiting, .finished, .none: nil
        }
    }
}

/// An assistant's symbol for the closed notch (ClosedNotchMode.agents), in the same 18 pt box as its rings so
/// the strip keeps its height and the fit its measure. The state is told by shape as well as colour: a working
/// session puts a bar under the symbol, sessions idling put a hollow ring there (AgentGlyphState.underMark); a
/// wait or a finish puts the rings' own mark on its corner (SignalMark); an assistant with no session is drawn
/// in the caption's grey rather than its own colour, with nothing under it. The mark sits outside the quiet
/// dimming, for the reason CompactRings gives.
///
/// Nothing here moves. The Sessions card's working dot breathes, but that card is on screen only while the panel
/// is open; this strip is on screen all day, and an animation that never ends redraws it every frame for as long
/// as a session works (CompactReadout measured 5–9 % of a core for a ring that pulsed without end). The bar says
/// "working" without it, so Reduce Motion has nothing to take away.
struct AgentGlyph: View {
    let tool: ToolID
    let state: AgentGlyphState
    var presence: PresenceLevel = .legible

    /// The symbol's point size inside the 18 pt box, leaving room below it for the mark under it.
    static let symbolSize: CGFloat = 11
    /// The mark's row under the symbol: the bar is 2 pt tall in it, the hollow ring fills it, since a ring
    /// smaller than 4 pt is a dot on a 1x display and the hole is the whole of what it says.
    static let underMarkHeight: CGFloat = 4

    var body: some View {
        ZStack {
            VStack(spacing: 2) {
                Image(systemName: tool.symbolName)
                    .font(.system(size: Self.symbolSize, weight: .semibold))
                    .foregroundStyle(state == .none ? AnyShapeStyle(Caption.style) : AnyShapeStyle(tool.color))
                    .frame(height: Self.symbolSize + 1)
                underMark
                    .frame(width: 10, height: Self.underMarkHeight)
            }
            .opacity(presence.readoutOpacity)
            if let signal = state.signal {
                SignalMark(signal: signal).offset(SignalMark.cornerOffset(of: signal, in: CompactRings.side))
            }
        }
        .frame(width: CompactRings.side, height: CompactRings.side)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tool.displayName)
        .accessibilityValue(state.spoken)
    }

    /// The row under the symbol always takes its height, so the symbol sits at one place in every state.
    @ViewBuilder private var underMark: some View {
        switch state.underMark {
        case .bar:
            Capsule().fill(tool.color).frame(height: 2)
        case .ring:
            Circle().strokeBorder(tool.color, lineWidth: 1).frame(width: Self.underMarkHeight, height: Self.underMarkHeight)
        case nil:
            Color.clear
        }
    }
}
