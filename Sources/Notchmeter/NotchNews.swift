import CoreGraphics
import Foundation

/// Something the collapsed notch announces: a session started waiting on the user, or finished a turn worth
/// being told about. The rings already say that *something* happened (ToolSignal); this names the session and
/// the reason, briefly, beside the notch (the peek, `NotchPeek`), and lights the glow under it (`NotchGlow`).
///
/// It is built from what the hook already told the session tracker, never from a file's modification time, for
/// the reason ToolSignal gives: a line in the strip asserting a wait has to be a wait some hook said began. A Claude
/// Cowork task, which has no hook, is news only when it finishes, and its finish is the end line its own log wrote
/// (SessionTracker.observeCowork), not the log going quiet.
struct NotchNews: Equatable, Sendable {
    /// Why the session wants the user. The kinds of wait an assistant can name are kept apart, because "go and
    /// approve something", "go and answer something" and "an MCP server needs something from you" are different
    /// errands; a wait it does not name is just a wait. Since 0.11 three reasons are not waits at all but trouble a
    /// working session ran into (SessionTrouble): they are news, and like a finish they never replace a wait.
    enum Reason: String, Equatable, Sendable {
        case approval, question, input, waiting, finished
        case compacting, stuck, blocked

        var isWait: Bool {
            switch self {
            case .approval, .question, .input, .waiting: true
            case .finished, .compacting, .stuck, .blocked: false
            }
        }

        /// The reason for one trouble.
        init(_ trouble: SessionTrouble) {
            switch trouble {
            case .compacting: self = .compacting
            case .stuck: self = .stuck
            case .blocked: self = .blocked
            }
        }

        /// The trouble this reason stands for on `session`, rebuilt from what the session holds, for the card a
        /// click on the peek opens (NoticeCard); nil for a reason that is no trouble.
        func trouble(of session: AgentSession) -> SessionTrouble? {
            switch self {
            case .compacting: .compacting(context: session.contextUsed)
            case .stuck: .stuck(failures: session.failureStreak)
            case .blocked: session.denials.last.map { .blocked(tool: $0.value.tool) }
            case .approval, .question, .input, .waiting, .finished: nil
            }
        }

        /// The words beside the notch. Short on purpose: they share the menu bar's height with nothing else and
        /// a narrow gap beside the notch with the menus.
        var text: String {
            switch self {
            case .approval: L("Needs approval")
            case .question: L("Question")
            case .input: L("Needs input")
            case .waiting: L("Waiting for you")
            case .finished: L("Finished")
            case .compacting: L("Compacting")
            case .stuck: L("May be stuck")
            case .blocked: L("Blocked")
            }
        }

        /// The symbol in front of the words, so the reason is never carried by the glow's colour alone. The wait
        /// and the finish reuse the card's symbols (ToolSignal.symbolName) so the strip and the panel agree, and
        /// the three troubles the symbols of their marks on the session's row.
        var symbolName: String {
            switch self {
            case .approval, .waiting: "hand.raised.fill"
            case .question: "questionmark.bubble.fill"
            case .input: "rectangle.and.pencil.and.ellipsis"
            case .finished: "checkmark.circle.fill"
            case .compacting: "arrow.down.right.and.arrow.up.left"
            case .stuck: "exclamationmark.arrow.triangle.2.circlepath"
            case .blocked: "hand.raised.slash.fill"
            }
        }
    }

    let reason: Reason
    let sessionID: String
    let tool: ToolID
    /// The folder the session runs in (ProjectName), as the Sessions card shows it; nil when the hook sent none.
    let project: String?
    let at: Date
    /// A hook's session, or a Claude Cowork task (AgentSession.Source), which is announced under its own name.
    var source: SessionSource = .hook

    /// "Claude Code", or "Claude Cowork" for a Cowork task: the name the announcement speaks.
    var productName: String { source == .coworkLog ? CoworkSessions.productName : tool.productName }

    /// How long the peek stays beside the notch: long enough to read two words at a glance, short enough that the
    /// readouts it displaced are back before anyone goes looking for them.
    static let shownFor: TimeInterval = 4

    /// How long the peek stays up: a second longer under Reduce Motion, where it arrives without the slide that
    /// draws the eye to it.
    static func shownFor(motionReduced: Bool) -> TimeInterval { shownFor + (motionReduced ? 1 : 0) }
    /// The same session with the same reason inside this is not news again. A run of permission prompts from one
    /// session arrives a few seconds apart, and a strip that flickered the same words at each would be read as
    /// noise; the rings and the prompt card still carry every one of them.
    static let repeatAfter: TimeInterval = 30

    /// The reason a wait begins, from the message that began it. A request the hook is holding the session for
    /// says what it is; otherwise the vendor's own vocabulary does (Hook.waitingNotificationTypes and its Gemini
    /// and Copilot counterparts). Claude Code's idle nudge is not news: it only says the user has gone quiet, and
    /// it follows a finish the strip has already announced.
    static func reason(event: String, notificationType: String?, request: PendingRequest.Kind?) -> Reason? {
        switch request {
        case .permission: return .approval
        case .question: return .question
        case .elicitation: return .input
        case nil: break
        }
        if notificationType == Hook.idleNotificationType { return nil }
        switch (event, notificationType) {
        case ("PermissionRequest", _), (_, "permission_prompt"), (_, "ToolPermission"): return .approval
        case ("Elicitation", _), (_, "elicitation_dialog"), (_, "elicitation_url_dialog"): return .input
        case (_, "agent_needs_input"): return .question
        default: return .waiting
        }
    }

    /// What one hook message makes news of, if anything: a wait it began, else trouble the session ran into, else a
    /// turn it ended. A finish shorter than `ToolSignal.finishedAfter` ended while the user was watching it, which is
    /// the rule the ring keeps; a session with no id cannot be focused and is not announced.
    static func from(_ message: Hook.Message, outcome: SessionTracker.Outcome, now: Date) -> NotchNews? {
        if let waiting = outcome.startedWaiting,
           let reason = reason(event: message.event, notificationType: message.notificationType,
                               request: outcome.requested?.request.kind ?? message.request?.kind) {
            return NotchNews(reason: reason, sessionID: waiting.id, tool: waiting.tool, project: waiting.project, at: now)
        }
        if let trouble = outcome.trouble {
            return NotchNews(reason: Reason(trouble.trouble), sessionID: trouble.session.id, tool: trouble.session.tool,
                             project: trouble.session.project, at: now)
        }
        if let finished = outcome.finished { return self.finished(finished.session, turn: finished.turn, now: now) }
        return nil
    }

    /// A turn that ended, as news: a hook's `Stop`, or the end line of a Claude Cowork task's log
    /// (SessionTracker.observeCowork). Nil for a turn shorter than `ToolSignal.finishedAfter`, the ring's own rule.
    static func finished(_ session: AgentSession, turn: TimeInterval, now: Date) -> NotchNews? {
        guard turn >= ToolSignal.finishedAfter else { return nil }
        return NotchNews(reason: .finished, sessionID: session.id, tool: session.tool, project: session.project, at: now, source: session.source)
    }

    /// Whether `candidate` earns an announcement. `showing` is the peek on screen now, `last` the most recent
    /// announcement whether or not it is still up. A wait on screen is not replaced by a finish: the wait is
    /// blocking and the finish is only news, which is the order ToolSignal.resolve keeps on the ring. The same
    /// session for the same reason inside `repeatAfter` is dropped as a repeat.
    static func isDue(_ candidate: NotchNews, showing: NotchNews?, last: NotchNews?, now: Date) -> Bool {
        if let showing, showing.reason.isWait, !candidate.reason.isWait { return false }
        if let last, last.sessionID == candidate.sessionID, last.reason == candidate.reason,
           now.timeIntervalSince(last.at) < repeatAfter { return false }
        return true
    }

    /// The ways into the panel that come through the peek itself: the pointer resting on it (the dwell under On
    /// hover), a click on it, or a swipe down on it. A panel opened any of these ways while the peek is up opens on
    /// its session; a hotkey, a banner or a glance was not aimed at the words and opens the way it always has.
    static func opensOnSession(_ cause: PanelCause) -> Bool {
        switch cause {
        case .dwell, .click, .swipe: true
        default: false
        }
    }

    /// What the panel opens on for news about `sessionID`: the session's own request card when it is holding for
    /// one, the session's card alone when it is still known, and the whole panel when it has gone in the meantime.
    enum Opening: Equatable { case request, notice, whole }

    static func opening(for sessionID: String, pendingSessions: [String], known: Bool) -> Opening {
        if pendingSessions.contains(sessionID) { return .request }
        return known ? .notice : .whole
    }

    /// The text the peek draws and VoiceOver announces. The name is the session's own title when the caller may
    /// show one (`title`: the prompt's first line, Claude Code's session name or Cursor's chat name, passed only
    /// while Preferences.sessionTitles is on; UsageStore.peekTitle), else the project, so two chats in one folder
    /// do not announce themselves alike. While the screen is shared the name goes altogether, as it does from the
    /// banner (Notifier.copy): the reason alone says there is something to look at without saying where. The
    /// project is a folder name, not the prompt, so it is not behind the session-titles switch.
    struct Words: Equatable {
        let name: String?
        let reason: String
        let reasonSymbol: String
        let toolSymbol: String
        /// One sentence for the announcement: the assistant, the project when shown, and the reason.
        let spoken: String
    }

    func words(hidesFigures: Bool, title: String? = nil) -> Words {
        let chosen = title.flatMap { $0.isEmpty ? nil : $0 } ?? project.flatMap { $0.isEmpty ? nil : $0 }
        let name = hidesFigures ? nil : chosen
        return Words(name: name, reason: reason.text, reasonSymbol: reason.symbolName, toolSymbol: tool.symbolName,
                     spoken: Spoken.line(productName, name, reason.text))
    }
}

/// Where the peek's words go beside the notch, from the room either side of it. Pure, so the rule is tested
/// without a menu bar; the widths of the words come in from the caller (NotchPeekHalf.width measures them in the
/// strip's own font).
///
/// The words are drawn by the two compact halves DynamicNotchKit lays beside the notch, so they sit left and
/// right of the physical notch and never under it. Each half takes no more than the gap Auto measured on its side
/// (`Room`), less nothing: `Room` is already the gap less `CompactFit.clearance`, and no more than `cap` however
/// wide the gap is. Under a fixed side nothing is measured, and the readouts are drawn without a measurement too;
/// the peek then keeps to `unmeasured`, about the width of three readouts with their figures, so it covers no
/// more of the menu bar than they could.
enum NotchPeek {
    /// The clear room each side of the notch, as AutoSideWatcher measured it.
    struct Room: Equatable {
        var leading: CGFloat
        var trailing: CGFloat

        static let unmeasured = Room(leading: NotchPeek.unmeasuredHalf, trailing: NotchPeek.unmeasuredHalf)
    }

    /// The most either half ever takes, however much room there is: a chat's name and a reason, not a sentence
    /// across the bar.
    static let cap: CGFloat = 320
    /// Each half's room when nothing was measured.
    static let unmeasuredHalf: CGFloat = 150
    /// Less than this and a half cannot hold a symbol and a word; its words move to the other side.
    static let minimumHalf: CGFloat = 44
    /// The tool's symbol alone needs this much (a 10 pt glyph and the strip's 6 pt padding either side).
    static let symbolOnly: CGFloat = 22

    enum Part: Equatable { case tool, name, reason }

    struct Layout: Equatable {
        var leading: [Part]
        var trailing: [Part]
        /// The widest each half may draw; the words inside truncate to it.
        var leadingWidth: CGFloat
        var trailingWidth: CGFloat
    }

    /// Whether the half drawing `parts` is the one VoiceOver meets: the half with the reason, which is the whole of
    /// the peek's meaning. The other half, the tool and the name, is hidden from it, since the spoken line on the
    /// reason's half already says both.
    static func speaks(_ parts: [Part]) -> Bool { parts.contains(.reason) }

    /// The name goes left of the notch and the reason right of it, the way a sentence reads across it, when the
    /// name fits whole on the left. When it does not, the arrangement that shows the most of the name wins: the
    /// whole line on the right ("↖ my-project · ✓ Finished") where the status items leave more room than the menus
    /// do, or on the left the other way round, before a name cut down to three letters beside a reason with room
    /// to spare. A side too narrow for words gives its words to the other; with no room for the reason on either
    /// side there is no peek, and the glow and the rings carry the news alone. With no name to show (the screen
    /// is shared, or the hook sent none) the left keeps the tool's symbol, so the strip still says whose news it
    /// is. `width` is what a half holding those parts needs, and `nameWidth` the name's own share of it.
    static func layout(room: Room, hasName: Bool, nameWidth: CGFloat = 0, width: ([Part]) -> CGFloat = { _ in 0 }) -> Layout? {
        let leading = max(0, min(room.leading, cap))
        let trailing = max(0, min(room.trailing, cap))
        guard hasName else {
            if trailing >= minimumHalf, leading >= symbolOnly {
                return Layout(leading: [.tool], trailing: [.reason], leadingWidth: leading, trailingWidth: trailing)
            }
            if trailing >= minimumHalf, trailing >= leading {
                return Layout(leading: [], trailing: [.tool, .reason], leadingWidth: 0, trailingWidth: trailing)
            }
            if leading >= minimumHalf {
                return Layout(leading: [.tool, .reason], trailing: [], leadingWidth: leading, trailingWidth: 0)
            }
            return nil
        }
        let left: [Part] = [.tool, .name]
        let everything: [Part] = [.tool, .name, .reason]
        // How much of the name each arrangement shows: all of it, less what the half is short by.
        func shown(_ parts: [Part], in room: CGFloat) -> CGFloat { nameWidth - max(0, width(parts) - room) }
        var options: [(layout: Layout, shown: CGFloat)] = []
        if trailing >= minimumHalf, leading >= minimumHalf {
            options.append((Layout(leading: left, trailing: [.reason], leadingWidth: leading, trailingWidth: trailing), shown(left, in: leading)))
        }
        if trailing >= minimumHalf {
            options.append((Layout(leading: [], trailing: everything, leadingWidth: 0, trailingWidth: trailing), shown(everything, in: trailing)))
        }
        if leading >= minimumHalf {
            options.append((Layout(leading: everything, trailing: [], leadingWidth: leading, trailingWidth: 0), shown(everything, in: leading)))
        }
        // `max(by:)` keeps the first of equals, so a tie keeps the split, then the right-hand side.
        return options.max { $0.shown < $1.shown }?.layout
    }
}

/// The light under the notch for the same news. A wait blooms in the "needs you" blue (Palette.calm) and then
/// settles to an ember that stays while anything still waits; a finish blooms white and goes. Colour is never the
/// only channel: the peek beside it names the reason in words and a symbol, and the rings carry their marks.
enum NotchGlow: Equatable {
    enum Tint: String, Equatable { case calm, soft }

    /// Bright, for `bloomFor` after the news.
    case bloom(Tint)
    /// Faint, for as long as a session waits.
    case ember

    static let bloomFor: TimeInterval = 3

    /// The whole rule. `news` is the latest announcement, `waiting` whether any shown assistant still waits.
    static func state(news: NotchNews?, waiting: Bool, enabled: Bool, now: Date) -> NotchGlow? {
        guard enabled else { return nil }
        if let news, now.timeIntervalSince(news.at) < bloomFor, now >= news.at {
            return .bloom(news.reason.isWait ? .calm : .soft)
        }
        return waiting ? .ember : nil
    }

    /// The oracle's word for a state.
    static func name(_ state: NotchGlow?) -> String {
        switch state {
        case .bloom(let tint): "bloom-\(tint.rawValue)"
        case .ember: "ember"
        case nil: "none"
        }
    }
}
