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
    /// Which assistant this session belongs to. Only Claude Code's hook reports events today, so in practice every
    /// session is Claude's; the field exists so a second hook lights the same lamps without a change anywhere above
    /// this file, and so no view has to ask "is this Claude?" in order to know what a session means.
    let tool: ToolID
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
    /// The turn that last ended, for the ninety seconds the rings say so. Set on every `Stop` whose start was seen,
    /// cleared when the next turn begins and again by `expire`. It lives on the session rather than in a table on
    /// the store because that is the only place it cannot outlive its evidence: a session dropped for staleness or
    /// ended by `SessionEnd` takes its finish with it, and two sessions of one tool cannot borrow each other's.
    var finished: ToolSignal.Finish?

    init(id: String, tool: ToolID = .claude, project: String?, state: State, started: Date, lastEvent: Date, turnStarted: Date?, branch: String? = nil,
         prURL: String? = nil, permissionMode: String? = nil, host: String? = nil) {
        self.id = id
        self.tool = tool
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

    /// The finish this session is still entitled to claim, or nil. Guarding on `.idle` is what stops a mark left by
    /// an earlier turn being read as the present one; reading it against the clock rather than latching it is what
    /// means a Mac that slept through the hold wakes with the state already over rather than with a colour to
    /// clean up.
    func finish(now: Date) -> ToolSignal.Finish? {
        guard case .idle = state, let finished, now.timeIntervalSince(finished.at) < SessionTracker.finishedHold else { return nil }
        return finished
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
    /// `ToolSignal.heldFor`, named here so `expire` and the tests read one constant rather than reaching across
    /// files for it.
    static let finishedHold = ToolSignal.heldFor
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

    /// One tool's sessions waiting on the user, in no order, for the mark beside its ring. The dictionary stays
    /// keyed by session id, as it always has, because the notification identifiers are built from that id; when a
    /// second hook lands the key wants the tool's name in front of it, and that is one change here and none above.
    /// These three read `sessions.values` rather than `all` because the drawing side asks them once per tool per
    /// pass, and sorting every session five times over to answer a count is work this file's own history says not
    /// to do. So this one does not sort either: its caller asks it for `.count`, and a sort it would throw away is
    /// the same work under another name.
    func waiting(of tool: ToolID) -> [AgentSession] {
        sessions.values.filter { $0.tool == tool && $0.isWaiting }
    }

    /// Whether any of one tool's sessions is mid-turn, which is what releases a finished ring early: something is
    /// still running, so the user is not the bottleneck and the ring has nothing to ask of them.
    func isWorking(_ tool: ToolID) -> Bool { sessions.values.contains { $0.tool == tool && $0.isWorking } }

    /// The most recent turn one tool finished inside the hold, since a tool has one ring and may have several
    /// sessions.
    func finish(of tool: ToolID, now: Date) -> ToolSignal.Finish? {
        sessions.values.filter { $0.tool == tool }.compactMap { $0.finish(now: now) }.max { $0.at < $1.at }
    }

    /// When the earliest state still running stops being true, so one timer can retire it at the moment it expires
    /// rather than leaving it to the thirty-second reset sweep, which would clear it up to thirty seconds late — and
    /// a ring that said "just finished" thirty seconds after it stopped being true is exactly the small lie that
    /// makes a reader stop trusting the whole strip. Waits are included on the same footing even though the sweep
    /// would reach them in time: both are claims with an end, and one release path that retires every claim is
    /// easier to trust than two that between them cover the cases.
    func nextRelease(now: Date) -> Date? {
        var soonest: Date?
        for session in sessions.values {
            var due: Date?
            if case .waiting(let since) = session.state {
                due = since.addingTimeInterval(Self.waitingTimeout)
            } else if let finished = session.finished {
                due = finished.at.addingTimeInterval(Self.finishedHold)
            }
            guard let due, due > now else { continue }
            soonest = soonest.map { Swift.min($0, due) } ?? due
        }
        return soonest
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
        var session = sessions[id] ?? AgentSession(id: id, tool: message.tool, project: message.project, state: .idle, started: now, lastEvent: now,
                                                   turnStarted: nil, host: message.host)
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
            session.finished = nil
        case "Stop", "StopFailure":
            // The mark is set inside the state machine and above the notification's gate, so `notifyFinished` and
            // its minutes cannot silently decide what the rings show. A StopFailure is deliberately not a finish:
            // a turn that fell over on a rate limit has `limitHitAt` and an advice line of its own, and a ring
            // that congratulated it would be the kind of lie this whole state exists to avoid.
            if let turnStarted = session.turnStarted, message.event == "Stop" {
                outcome.finished = (session, now.timeIntervalSince(turnStarted))
                session.finished = ToolSignal.Finish(turn: now.timeIntervalSince(turnStarted), at: now)
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

    /// Waits older than ten minutes fall back to idle, a finished turn's mark is dropped once its ninety seconds
    /// are up, agents silent that long are forgotten, and sessions silent for four hours are dropped. This is the
    /// app's answer to a hook that stops reporting mid-session: every state here has an end that arrives whether or
    /// not another event ever does.
    mutating func expire(now: Date) {
        for (id, var session) in sessions {
            if now.timeIntervalSince(session.lastEvent) >= Self.staleAfter {
                sessions[id] = nil
                continue
            }
            if case .waiting(let since) = session.state, now.timeIntervalSince(since) >= Self.waitingTimeout {
                session.state = .idle
            }
            if let finished = session.finished, now.timeIntervalSince(finished.at) >= Self.finishedHold {
                session.finished = nil
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
