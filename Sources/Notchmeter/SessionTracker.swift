import Foundation

/// One Claude Code session the hook has reported: which project it runs in and whether it is mid-turn, idle
/// between turns, or waiting for the user.
struct AgentSession: Equatable, Sendable, Identifiable {
    enum State: Equatable, Sendable {
        case idle
        case working(since: Date)
        case waiting(since: Date)
    }

    let id: String
    var project: String?
    var state: State
    let started: Date
    var lastEvent: Date
    /// When the current turn began, for the finished-after-N-minutes notification.
    var turnStarted: Date?

    var isWaiting: Bool {
        if case .waiting = state { return true }
        return false
    }

    var isWorking: Bool {
        if case .working = state { return true }
        return false
    }

    /// How long the session has been in its current state.
    func stateDuration(now: Date) -> TimeInterval? {
        switch state {
        case .idle: nil
        case .working(let since), .waiting(let since): now.timeIntervalSince(since)
        }
    }
}

/// The per-session state machine fed by the hook: SessionStart adds a session, UserPromptSubmit starts a turn,
/// a permission prompt or a question makes it wait, agent_completed or an answered elicitation resumes it, Stop
/// ends the turn, SessionEnd removes it. A wait expires after ten minutes; a session nothing has been heard from for
/// four hours is dropped. Pure, so it is pinned by tests.
struct SessionTracker: Equatable, Sendable {
    struct Outcome: Equatable, Sendable {
        /// A turn ended: the session and how long the turn ran.
        var finished: (session: AgentSession, turn: TimeInterval)?
        /// A session began waiting on the user.
        var startedWaiting: AgentSession?

        static func == (lhs: Outcome, rhs: Outcome) -> Bool {
            lhs.finished?.session == rhs.finished?.session && lhs.finished?.turn == rhs.finished?.turn && lhs.startedWaiting == rhs.startedWaiting
        }
    }

    static let waitingTimeout: TimeInterval = 600
    static let staleAfter: TimeInterval = 4 * 3600
    static let unknownSession = "unknown"

    private(set) var sessions: [String: AgentSession] = [:]
    /// True once any hook event has arrived: the count is then a fact, not an absence of the hook.
    private(set) var hookSeen = false

    var all: [AgentSession] { sessions.values.sorted { $0.lastEvent > $1.lastEvent } }
    var waiting: [AgentSession] { all.filter(\.isWaiting) }
    var working: [AgentSession] { all.filter(\.isWorking) }
    var count: Int { sessions.count }
    /// nil until the hook has reported anything.
    var knownCount: Int? { hookSeen ? sessions.count : nil }

    @discardableResult
    mutating func apply(_ message: Hook.Message, now: Date) -> Outcome {
        hookSeen = true
        expire(now: now)
        let id = message.sessionID ?? Self.unknownSession
        var outcome = Outcome()
        if message.event == "SessionEnd" {
            sessions[id] = nil
            return outcome
        }
        var session = sessions[id] ?? AgentSession(id: id, project: message.project, state: .idle, started: now, lastEvent: now, turnStarted: nil)
        if let project = message.project { session.project = project }
        session.lastEvent = now
        switch message.event {
        case "UserPromptSubmit":
            session.state = .working(since: now)
            session.turnStarted = now
        case "Stop":
            if let turnStarted = session.turnStarted {
                outcome.finished = (session, now.timeIntervalSince(turnStarted))
            }
            session.state = .idle
            session.turnStarted = nil
        default:
            if message.needsInput {
                if !session.isWaiting { outcome.startedWaiting = session }
                session.state = .waiting(since: now)
            } else if message.clearsWaiting, session.isWaiting {
                session.state = .working(since: now)
            }
        }
        sessions[id] = session
        return outcome
    }

    /// A status-line update is proof the session is alive; its project is taken when the hook gave none.
    mutating func statusline(sessionID: String?, project: String?, now: Date) {
        guard let sessionID else { return }
        expire(now: now)
        var session = sessions[sessionID] ?? AgentSession(id: sessionID, project: project, state: .idle, started: now, lastEvent: now, turnStarted: nil)
        if session.project == nil { session.project = project }
        session.lastEvent = now
        sessions[sessionID] = session
    }

    /// Waits older than ten minutes fall back to idle; sessions silent for four hours are forgotten.
    mutating func expire(now: Date) {
        for (id, var session) in sessions {
            if now.timeIntervalSince(session.lastEvent) >= Self.staleAfter {
                sessions[id] = nil
                continue
            }
            if case .waiting(let since) = session.state, now.timeIntervalSince(since) >= Self.waitingTimeout {
                session.state = .idle
                sessions[id] = session
            }
        }
    }

    /// "notchmeter (and 1 more)": the projects waiting, newest first.
    static func waitingPhrase(_ waiting: [AgentSession]) -> String? {
        guard let first = waiting.first else { return nil }
        let name = first.project ?? L("a session")
        return waiting.count > 1 ? L("%1$@ (and %2$ld more)", name, waiting.count - 1) : name
    }
}
