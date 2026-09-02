import Foundation

/// One Claude Code session the hook has reported: which project it runs in and whether it is mid-turn, idle
/// between turns, or waiting for the user; plus what the hook and status line know about where it runs.
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
    var branch: String?
    var prURL: String?
    var permissionMode: String?
    /// The machine a remote hook posted from; nil for this Mac.
    var host: String?
    /// Subagents running under this session, by agent id, with when each started.
    var agents: [String: Date] = [:]
    /// Claude Code is holding the session for a quota reset it will not resume from on its own.
    var quotaWait = false
    /// The session last stopped because the limit was hit.
    var limitHitAt: Date?

    init(id: String, project: String?, state: State, started: Date, lastEvent: Date, turnStarted: Date?, branch: String? = nil, prURL: String? = nil,
         permissionMode: String? = nil, host: String? = nil) {
        self.id = id
        self.project = project
        self.state = state
        self.started = started
        self.lastEvent = lastEvent
        self.turnStarted = turnStarted
        self.branch = branch
        self.prURL = prURL
        self.permissionMode = permissionMode
        self.host = host
    }

    var isWaiting: Bool {
        if case .waiting = state { return true }
        return false
    }

    var isWorking: Bool {
        if case .working = state { return true }
        return false
    }

    /// "notchmeter", or "notchmeter@devbox" for a remote session.
    var displayName: String? {
        guard let project else { return host.map { "@\($0)" } }
        return host.map { "\(project)@\($0)" } ?? project
    }

    /// "#12" from a pull request URL's last path component.
    var prNumber: String? {
        guard let prURL, let last = URL(string: prURL)?.lastPathComponent, Int(last) != nil else { return nil }
        return "#\(last)"
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
/// (or a StopFailure) ends the turn, SessionEnd removes it; SubagentStart and SubagentStop count the agents under
/// it. A wait expires after ten minutes, as does an agent nothing has been heard from; a session nothing has been
/// heard from for four hours is dropped. Pure, so it is pinned by tests.
struct SessionTracker: Equatable, Sendable {
    struct Outcome: Equatable, Sendable {
        /// A turn ended: the session and how long the turn ran.
        var finished: (session: AgentSession, turn: TimeInterval)?
        /// A session began waiting on the user.
        var startedWaiting: AgentSession?
        /// Sessions that stopped waiting (resumed, stopped or ended), so their notices can be withdrawn.
        var stoppedWaiting: [String] = []
        /// The session stopped because the limit was hit.
        var limitHit: AgentSession?
        /// Claude Code resumed from its own quota wait, so the meter is worth a fresh read.
        var quotaResumed = false

        static func == (lhs: Outcome, rhs: Outcome) -> Bool {
            lhs.finished?.session == rhs.finished?.session && lhs.finished?.turn == rhs.finished?.turn && lhs.startedWaiting == rhs.startedWaiting
                && lhs.stoppedWaiting == rhs.stoppedWaiting && lhs.limitHit == rhs.limitHit && lhs.quotaResumed == rhs.quotaResumed
        }
    }

    static let waitingTimeout: TimeInterval = 600
    static let agentTimeout: TimeInterval = 600
    static let staleAfter: TimeInterval = 4 * 3600
    static let unknownSession = "unknown"

    private(set) var sessions: [String: AgentSession] = [:]
    /// True once any hook event has arrived: the count is then a fact, not an absence of the hook.
    private(set) var hookSeen = false

    var all: [AgentSession] { sessions.values.sorted { $0.lastEvent > $1.lastEvent } }
    var waiting: [AgentSession] { all.filter(\.isWaiting) }
    var working: [AgentSession] { all.filter(\.isWorking) }
    var quotaWaiting: [AgentSession] { all.filter(\.quotaWait) }
    var count: Int { sessions.count }
    /// Subagents running under every session.
    var agentCount: Int { sessions.values.reduce(0) { $0 + $1.agents.count } }
    /// nil until the hook has reported anything.
    var knownCount: Int? { hookSeen ? sessions.count : nil }

    /// A session hit its limit within the last hour, or is held for a quota reset.
    func limitHit(now: Date) -> Bool {
        sessions.values.contains { $0.quotaWait || $0.limitHitAt.map { now.timeIntervalSince($0) < 3600 } ?? false }
    }

    @discardableResult
    mutating func apply(_ message: Hook.Message, now: Date) -> Outcome {
        hookSeen = true
        expire(now: now)
        let id = message.sessionID.map { session in message.host.map { host in "\(session)@\(host)" } ?? session } ?? Self.unknownSession
        var outcome = Outcome()
        if message.event == "SessionEnd" {
            if sessions[id]?.isWaiting == true { outcome.stoppedWaiting.append(id) }
            sessions[id] = nil
            return outcome
        }
        var session = sessions[id] ?? AgentSession(id: id, project: message.project, state: .idle, started: now, lastEvent: now, turnStarted: nil, host: message.host)
        if let project = message.project { session.project = project }
        if let branch = message.branch { session.branch = branch }
        if let mode = message.permissionMode { session.permissionMode = mode }
        session.lastEvent = now
        let wasWaiting = session.isWaiting
        switch message.event {
        case "UserPromptSubmit":
            session.state = .working(since: now)
            session.turnStarted = now
            session.quotaWait = false
            session.limitHitAt = nil
        case "Stop", "StopFailure":
            if let turnStarted = session.turnStarted, message.event == "Stop" {
                outcome.finished = (session, now.timeIntervalSince(turnStarted))
            }
            session.state = .idle
            session.turnStarted = nil
            session.agents = [:]
            if message.hitRateLimit {
                session.limitHitAt = now
                outcome.limitHit = session
            }
        case "SubagentStart":
            session.agents[message.agentID ?? "agent-\(session.agents.count + 1)"] = now
        case "SubagentStop":
            if let agentID = message.agentID, session.agents[agentID] != nil {
                session.agents[agentID] = nil
            } else if let oldest = session.agents.min(by: { $0.value < $1.value }) {
                session.agents[oldest.key] = nil
            }
        default:
            if message.needsInput {
                if !session.isWaiting { outcome.startedWaiting = session }
                session.state = .waiting(since: now)
            } else if message.clearsWaiting, session.isWaiting {
                session.state = .working(since: now)
            }
            if message.waitsOnQuota { session.quotaWait = true }
            if message.resumesFromQuota {
                session.quotaWait = false
                session.limitHitAt = nil
                outcome.quotaResumed = true
            }
        }
        if wasWaiting, !session.isWaiting { outcome.stoppedWaiting.append(id) }
        sessions[id] = session
        return outcome
    }

    /// A status-line update is proof the session is alive; its project, branch and pull request are taken.
    mutating func statusline(sessionID: String?, project: String?, branch: String? = nil, prURL: String? = nil, now: Date) {
        guard let sessionID else { return }
        expire(now: now)
        var session = sessions[sessionID] ?? AgentSession(id: sessionID, project: project, state: .idle, started: now, lastEvent: now, turnStarted: nil)
        if session.project == nil { session.project = project }
        if let branch { session.branch = branch }
        session.prURL = prURL ?? session.prURL
        session.lastEvent = now
        sessions[sessionID] = session
    }

    /// Waits older than ten minutes fall back to idle, agents silent that long are forgotten, and sessions silent
    /// for four hours are dropped.
    mutating func expire(now: Date) {
        for (id, var session) in sessions {
            if now.timeIntervalSince(session.lastEvent) >= Self.staleAfter {
                sessions[id] = nil
                continue
            }
            if case .waiting(let since) = session.state, now.timeIntervalSince(since) >= Self.waitingTimeout {
                session.state = .idle
            }
            session.agents = session.agents.filter { now.timeIntervalSince($0.value) < Self.agentTimeout }
            sessions[id] = session
        }
    }

    /// "notchmeter (and 1 more)": the projects waiting, newest first.
    static func waitingPhrase(_ waiting: [AgentSession]) -> String? {
        guard let first = waiting.first else { return nil }
        let name = first.displayName ?? L("a session")
        return waiting.count > 1 ? L("%1$@ (and %2$ld more)", name, waiting.count - 1) : name
    }
}
