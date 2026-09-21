import Foundation

/// Where a session's terminal is, as the hook process saw it from its own environment and process ancestry
/// (TerminalIdentity.swift): the terminal app, its tab or pane, the controlling tty, and the multiplexer in
/// between, each only when the hook could read it. Nothing here is inspected from the app's side; it is what the
/// session volunteered, and it is what a jump back to the terminal is resolved from. Never reported, logged or
/// exported: it is the app's alone.
struct TerminalRef: Equatable, Sendable, Codable {
    /// `TERM_PROGRAM`: iTerm.app, Apple_Terminal, WarpTerminal, ghostty, WezTerm, vscode…
    var program: String?
    /// `__CFBundleIdentifier`, else the bundle id of the nearest ancestor process the system knows as an app.
    var bundleID: String?
    /// `/dev/ttys003`: the controlling tty of the nearest ancestor that has one (the hook itself has none).
    var tty: String?
    /// The terminal's own id for the tab or pane: `ITERM_SESSION_ID`, else `TERM_SESSION_ID`, else `WEZTERM_PANE`,
    /// else `KITTY_WINDOW_ID`, else `ZELLIJ_PANE_ID`.
    var sessionID: String?
    /// Warp's `WARP_FOCUS_URL`, kept only when it is shaped like one.
    var focusURL: String?
    /// `TMUX` (the socket path, the server's pid and the session index) and `TMUX_PANE`.
    var tmux: String?
    var tmuxPane: String?
    /// `KITTY_LISTEN_ON`, the socket `kitten @` reaches the running kitty over.
    var kittySocket: String?
    /// Whether `GHOSTTY_RESOURCES_DIR` was set.
    var ghostty = false
    /// The folder the session runs in, kept only when the terminal is an editor that brings forward the window
    /// already showing a folder it is asked to open (`TerminalJump.opensFolders`): the one way to tell two of its
    /// windows apart without reading a title.
    var workspace: String?

    init(program: String? = nil, bundleID: String? = nil, tty: String? = nil, sessionID: String? = nil, focusURL: String? = nil,
         tmux: String? = nil, tmuxPane: String? = nil, kittySocket: String? = nil, ghostty: Bool = false, workspace: String? = nil) {
        self.program = program
        self.bundleID = bundleID
        self.tty = tty
        self.sessionID = sessionID
        self.focusURL = focusURL
        self.tmux = tmux
        self.tmuxPane = tmuxPane
        self.kittySocket = kittySocket
        self.ghostty = ghostty
        self.workspace = workspace
    }

    /// True when nothing at all was read.
    var isEmpty: Bool {
        program == nil && bundleID == nil && tty == nil && sessionID == nil && focusURL == nil && tmux == nil && tmuxPane == nil
            && kittySocket == nil && !ghostty && workspace == nil
    }

    /// This reference with every field the newer one carries taken from it; a field the newer one lacks is kept,
    /// so a later event that could read less does not erase what an earlier one knew.
    func merging(_ newer: TerminalRef) -> TerminalRef {
        TerminalRef(program: newer.program ?? program, bundleID: newer.bundleID ?? bundleID, tty: newer.tty ?? tty,
                    sessionID: newer.sessionID ?? sessionID, focusURL: newer.focusURL ?? focusURL, tmux: newer.tmux ?? tmux,
                    tmuxPane: newer.tmuxPane ?? tmuxPane, kittySocket: newer.kittySocket ?? kittySocket, ghostty: newer.ghostty || ghostty,
                    workspace: newer.workspace ?? workspace)
    }
}

/// A decision the assistant is holding a session for, as the hook described it: a permission to grant or refuse,
/// or a question to answer. Carries a display summary only, never the tool's raw input (Hook+Decision.swift);
/// `id` is the nonce the hook generated for this one request, and the only thing a decision can be addressed to.
struct PendingRequest: Equatable, Sendable, Identifiable {
    struct Option: Equatable, Sendable {
        var label: String
        var description: String?

        init(label: String, description: String? = nil) {
            self.label = label
            self.description = description
        }
    }

    struct Question: Equatable, Sendable {
        var text: String
        var header: String
        var options: [Option]
        var multiSelect: Bool

        init(text: String, header: String = "", options: [Option], multiSelect: Bool = false) {
            self.text = text
            self.header = header
            self.options = options
            self.multiSelect = multiSelect
        }
    }

    enum Kind: Equatable, Sendable {
        /// `tool` is the tool's name (Bash, Edit, an MCP tool's), `summary` one line of what it wants to do,
        /// `detail` a bounded excerpt of it, `suggestions` the permission rules the assistant proposed.
        case permission(tool: String, summary: String, detail: String?, suggestions: [String])
        case question([Question])

        /// "permission" or "question": the word the oracle and the log use, never the content.
        var name: String {
            switch self {
            case .permission: "permission"
            case .question: "question"
            }
        }
    }

    let id: String
    let kind: Kind
    let since: Date

    init(id: String, kind: Kind, since: Date) {
        self.id = id
        self.kind = kind
        self.since = since
    }

    var kindName: String { kind.name }
}

/// What the user chose for a pending request. `pass` hands the request back to the terminal, which then asks as
/// it always has; it is also what a request that timed out, or that the app could not answer, amounts to.
enum Decision: Equatable, Sendable {
    case allow
    case deny(message: String?)
    /// Question text → the chosen option's label (labels of a multi-select joined with ", ").
    case answers([String: String])
    case pass

    /// The word the oracle records: allow, deny, answers or pass.
    var behavior: String {
        switch self {
        case .allow: "allow"
        case .deny: "deny"
        case .answers: "answers"
        case .pass: "pass"
        }
    }
}

/// One assistant session a hook has reported: which project it runs in and whether it is mid-turn, idle between
/// turns, or waiting for the user; plus what the hook and status line know about where it runs.
struct AgentSession: Equatable, Sendable, Identifiable {
    enum State: Equatable, Sendable {
        case idle
        case working(since: Date)
        case waiting(since: Date)
    }

    let id: String
    /// Which assistant this session belongs to. Claude Code's and Cursor's hooks both report, and each one's
    /// sessions light its own ring; the field is the typed home of that fact, so no view has to ask "is this
    /// Claude?" in order to know what a session means, and a third hook lights the same lamps without a change
    /// anywhere above this file.
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
    /// The first line of the prompt that started the current turn, when the hook was allowed to send it
    /// (Preferences.sessionTitles); nil otherwise, and nil again for every session at launch.
    var title: String?
    /// Where the session's terminal is, merged from every event that carried one.
    var terminal: TerminalRef?
    /// The decision the assistant is holding this session for, while its hook waits on the socket for it.
    var pending: PendingRequest?
    // From Claude Code's status line (0.7.0), so every one is nil for a session only the hook reports.
    /// The model's display name as the status line carries it ("Opus").
    var model: String?
    /// `session_name`: the name set with `--name` or `/rename`, else Claude Code's own title for the session;
    /// never the default `my-app-3f` display name. Shown only under the same setting as the prompt title
    /// (UsageStore.statuslineReceived drops it when Preferences.sessionTitles is off, as hookReceived drops `title`).
    var sessionName: String?
    var linesAdded: Int?
    var linesRemoved: Int?
    /// Claude Code's account of this session's prompt cache, priced (PromptCache.swift).
    var promptCache: PromptCacheStats?
    // The quiet-turn nudge (0.7.6), for an assistant that never says it is waiting: Cursor asks for a command's
    // approval in its own window and sends no hook for it (`SessionTracker.quietNudges`).
    /// Shell and MCP calls begun and not yet ended: a turn with one running is busy, not waiting.
    var commandsInFlight = 0
    /// Whether this session has sent any in-turn activity (`SessionTracker.heartbeatEvents`). Without it a long
    /// silence says nothing: an install from before 0.7.6 sends only the prompt and the stop.
    var heartbeats = false
    /// This turn went quiet with nothing running and is shown as a possible wait. Set once per turn, cleared by the
    /// next prompt; the wait itself ends with the next activity.
    var quietNudge = false

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

    /// What a row calls the session: the prompt's first line when the hook sent one, else the name Claude Code's
    /// status line carries (`--name`, `/rename` or its own title). Both are held only while Preferences.sessionTitles
    /// is on, so a nil here is either "nothing said yet" or "the user asked not to show it".
    var displayTitle: String? {
        if let title, !title.isEmpty { return title }
        if let sessionName, !sessionName.isEmpty { return sessionName }
        return nil
    }

    /// "notchmeter", or "notchmeter@devbox" for a remote session.
    var displayName: String? {
        guard let project else { return host.map { "@\($0)" } }
        return host.map { "\(project)@\($0)" } ?? project
    }

    /// The pull request's page, accepted only as an ordinary web link. `prURL` is `pr.url` from Claude Code's
    /// status-line JSON, forwarded by `--statusline` over the hook socket (HookSocket.swift; a distributed
    /// notification any local process could post until 0.6.0). The socket vouches for the sender being a copy of
    /// this app's binary, not for the string: Claude Code, a rewritten hook or settings file, or any same-user
    /// process that runs `Notchmeter --statusline` itself still chooses what the payload says, and the panel hands
    /// it straight to NSWorkspace when the arrow button is clicked; without this gate a `file:///Volumes/X/Setup.app`
    /// or a third-party app's custom scheme drew the familiar PR button and launched whatever it named. Every
    /// reader of the link, the panel button, `prNumber` and the report's `pr` field, goes through here so the check
    /// lives in one place rather than at each button; the report used to export the raw string, so an address the
    /// panel refused still reached the local API, the command-line tool and the MCP server (0.5.0).
    var prLink: URL? {
        guard let prURL, let url = URL(string: prURL),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// "#12" from a pull request URL's last path component.
    var prNumber: String? {
        guard let last = prLink?.lastPathComponent, Int(last) != nil else { return nil }
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

/// The per-session state machine fed by the hooks: SessionStart adds a session, UserPromptSubmit starts a turn,
/// a permission prompt or a question makes it wait, agent_completed or an answered elicitation resumes it, Stop
/// (or a StopFailure) ends the turn, SessionEnd removes it; SubagentStart and SubagentStop count the agents under
/// it. The names are Claude Code's; Cursor's parser puts its events onto them before they arrive here, so there is
/// one grammar. A wait expires after ten minutes, as does an agent nothing has been heard from; a session nothing
/// has been heard from for four hours is dropped. Pure, so it is pinned by tests.
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
        /// A session began holding for a decision its hook is waiting on: the store keeps the reply and the
        /// panel shows the request.
        var requested: (session: AgentSession, request: PendingRequest)?
        /// Requests that ended without a decision from the app (the session moved on or ended), by session and
        /// request id, so their parked replies can be released and the panel told.
        var requestsEnded: [EndedRequest] = []

        static func == (lhs: Outcome, rhs: Outcome) -> Bool {
            lhs.finished?.session == rhs.finished?.session && lhs.finished?.turn == rhs.finished?.turn && lhs.startedWaiting == rhs.startedWaiting
                && lhs.stoppedWaiting == rhs.stoppedWaiting && lhs.limitHit == rhs.limitHit && lhs.quotaResumed == rhs.quotaResumed
                && lhs.requested?.session == rhs.requested?.session && lhs.requested?.request == rhs.requested?.request
                && lhs.requestsEnded == rhs.requestsEnded
        }
    }

    struct EndedRequest: Equatable, Sendable {
        let sessionID: String
        let requestID: String
    }

    static let waitingTimeout: TimeInterval = 600
    /// How long a pending request may stand before `expire` drops it: the socket's own hold cap
    /// (`HookSocket.Listener.holdCap`), since a request the app has stopped holding a reply for is one the
    /// terminal has already taken back. The app's own, shorter hold (Preferences.promptHoldSeconds) is what ends
    /// a request in practice; this is the backstop for one the store never got to answer.
    static let pendingTimeout: TimeInterval = 600
    /// `ToolSignal.heldFor`, named here so `expire` and the tests read one constant rather than reaching across
    /// files for it.
    static let finishedHold = ToolSignal.heldFor
    static let agentTimeout: TimeInterval = 600
    static let staleAfter: TimeInterval = 4 * 3600
    static let unknownSession = "unknown"

    private(set) var sessions: [String: AgentSession] = [:]
    /// The tools whose hook has ever reported. Kept per tool because a hook is proof about its own tool only: a
    /// Cursor event says nothing about how many Claude Code sessions there are, and a Claude ring told "zero
    /// sessions" on Cursor's word would go quiet on a window that is being spent.
    private(set) var hooksSeen: Set<ToolID> = []
    /// True once any hook event has arrived: the count is then a fact, not an absence of the hook.
    var hookSeen: Bool { !hooksSeen.isEmpty }

    var all: [AgentSession] { sessions.values.sorted { $0.lastEvent > $1.lastEvent } }
    var waiting: [AgentSession] { all.filter(\.isWaiting) }
    var working: [AgentSession] { all.filter(\.isWorking) }
    var quotaWaiting: [AgentSession] { all.filter(\.quotaWait) }
    var count: Int { sessions.count }
    /// Subagents running under every session.
    var agentCount: Int { sessions.values.reduce(0) { $0 + $1.agents.count } }
    /// nil until any hook has reported anything.
    var knownCount: Int? { hookSeen ? sessions.count : nil }

    /// One tool's session count, and nil until that tool's own hook has reported: the input to the calm rule
    /// (Presence.level), which must not read another tool's silence as this tool's idleness.
    func knownCount(of tool: ToolID) -> Int? {
        hooksSeen.contains(tool) ? sessions.values.filter { $0.tool == tool }.count : nil
    }

    /// A session hit its limit within the last hour, or is held for a quota reset.
    func limitHit(now: Date) -> Bool {
        sessions.values.contains { $0.quotaWait || $0.limitHitAt.map { now.timeIntervalSince($0) < 3600 } ?? false }
    }

    /// A session hit its limit within the last hour, or is held for a quota reset, per tool: the same rule as
    /// `limitHit(now:)`, answered as the set of tools it is true of, so the advice line names the assistant whose
    /// session actually stopped rather than the one that happens to come first.
    func limitHitTools(now: Date) -> Set<ToolID> {
        Set(sessions.values.filter { $0.quotaWait || $0.limitHitAt.map { now.timeIntervalSince($0) < 3600 } ?? false }.map(\.tool))
    }

    /// One tool's sessions waiting on the user, in no order, for the mark beside its ring. The dictionary is keyed
    /// by `key(tool:session:host:)`: the bare session id for Claude Code, as it always was, because the
    /// notification identifiers are built from that id; the tool's name in front of it for every other hook.
    /// These three read `sessions.values` rather than `all` because the drawing side asks them once per tool per
    /// pass, and sorting every session five times over to answer a count is work this file's own history says not
    /// to do. So this one does not sort either: its caller asks it for `.count`, and a sort it would throw away is
    /// the same work under another name.
    func waiting(of tool: ToolID) -> [AgentSession] {
        sessions.values.filter { $0.tool == tool && $0.isWaiting }
    }

    /// A copy holding only one tool's sessions, for the sessions line on that tool's card, which must not count a
    /// Cursor conversation on the Claude Code card or the other way round. `hooksSeen` is kept as it is: whether a
    /// hook has ever reported is a fact about the app, not about the tool asked for; `knownCount(of:)` is the
    /// per-tool question.
    func only(_ tool: ToolID) -> SessionTracker {
        var copy = self
        copy.sessions = sessions.filter { $0.value.tool == tool }
        return copy
    }

    /// The dictionary key. Claude Code's sessions keep the bare id (and `id@host`) they have always had, so nothing
    /// that logs, notifies or reports them changes; any other tool's id carries the tool's name in front
    /// ("cursor:conv-1", "codex:<uuid>", "antigravity:<uuid>", "copilot:<id>", "cursor:conv-1@devbox", "cursor:unknown"),
    /// so another assistant's session and a Claude session can never share an entry. The tool's typed home is still AgentSession.tool; the prefix is only a collision guard.
    /// The separator is a colon rather than a slash because `Notifier.identifier` is `session/<id>/<kind>`, and a
    /// slash inside the id would muddy it.
    static func key(tool: ToolID, session: String?, host: String?) -> String {
        let id = session.map { session in host.map { host in "\(session)@\(host)" } ?? session } ?? unknownSession
        return tool == .claude ? id : "\(tool.rawValue):\(id)"
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
            if let quiet = Self.quietDue(session) {
                due = quiet
            } else if case .waiting(let since) = session.state {
                due = since.addingTimeInterval(Self.waitingTimeout)
            } else if let finished = session.finished {
                due = finished.at.addingTimeInterval(Self.finishedHold)
            }
            guard let due, due > now else { continue }
            soonest = soonest.map { Swift.min($0, due) } ?? due
        }
        return soonest
    }

    /// Cursor's in-turn events Notchmeter registers since 0.7.6 (HookVendor), read only as signs of life. Cursor
    /// runs `beforeShellExecution` as it executes a command, after any approval, so a command between its before
    /// and after is running rather than waiting.
    static let heartbeatEvents: Set<String> = ["beforeShellExecution", "afterShellExecution", "beforeMCPExecution", "afterMCPExecution",
                                               "afterFileEdit", "afterAgentThought", "afterAgentResponse"]

    /// How long a turn may go without a sign of life, with nothing running, before it is shown as a possible wait.
    /// Long enough for a slow model step, short enough to be worth it for a command waiting on a click.
    static let quietAfter: TimeInterval = 45

    /// When `session` becomes a possible wait, if it can: a working turn of an assistant that sends heartbeats and
    /// no waits of its own, with nothing running and not already nudged this turn.
    static func quietDue(_ session: AgentSession) -> Date? {
        guard session.tool == .cursor, session.heartbeats, session.commandsInFlight == 0, !session.quietNudge,
              session.turnStarted != nil, case .working = session.state else { return nil }
        return session.lastEvent.addingTimeInterval(quietAfter)
    }

    /// The turns that have gone quiet (`quietDue`) by `now`, each moved to a wait marked as a nudge, so the
    /// ring, the card and the notification can say it may be waiting. Returns the sessions just nudged.
    mutating func quietNudges(now: Date) -> [AgentSession] {
        var nudged: [AgentSession] = []
        for (id, var session) in sessions {
            guard let due = Self.quietDue(session), due <= now else { continue }
            session.quietNudge = true
            session.state = .waiting(since: now)
            sessions[id] = session
            nudged.append(session)
        }
        return nudged
    }

    @discardableResult
    mutating func apply(_ message: Hook.Message, now: Date) -> Outcome {
        hooksSeen.insert(message.tool)
        var outcome = Outcome()
        outcome.stoppedWaiting = expire(now: now)
        let id = Self.key(tool: message.tool, session: message.sessionID, host: message.host)
        if message.event == "SessionEnd" {
            if sessions[id]?.isWaiting == true { outcome.stoppedWaiting.append(id) }
            if let pending = sessions[id]?.pending { outcome.requestsEnded.append(EndedRequest(sessionID: id, requestID: pending.id)) }
            sessions[id] = nil
            return outcome
        }
        var session = sessions[id] ?? AgentSession(id: id, tool: message.tool, project: message.project, state: .idle, started: now, lastEvent: now,
                                                   turnStarted: nil, host: message.host)
        if let project = message.project { session.project = project }
        if let branch = message.branch { session.branch = branch }
        if let mode = message.permissionMode { session.permissionMode = mode }
        if let terminal = message.terminal, !terminal.isEmpty { session.terminal = session.terminal?.merging(terminal) ?? terminal }
        session.lastEvent = now
        let wasWaiting = session.isWaiting
        let hadPending = session.pending
        switch message.event {
        case "SessionStart":
            session.pending = nil
        case "UserPromptSubmit":
            session.state = .working(since: now)
            session.turnStarted = now
            session.commandsInFlight = 0
            session.quietNudge = false
            session.quotaWait = false
            session.limitHitAt = nil
            session.finished = nil
            session.pending = nil
            session.title = message.title
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
            session.commandsInFlight = 0
            session.pending = nil
            if message.hitRateLimit {
                session.limitHitAt = now
                outcome.limitHit = session
            }
        case "SubagentStart":
            session.agents[message.agentID ?? "agent-\(session.agents.count + 1)"] = now
            // A session that has just started an agent is running its own loop, so it is not waiting on the user.
            // This is the only proof of an answered permission prompt the hook ever sends: Claude Code reports
            // the prompt and never the answer, so without it an approved prompt — or one auto mode settled by
            // itself — kept the hand up for the ten-minute timeout, through a turn that was plainly working.
            // A SubagentStop is deliberately not the same proof: a background agent can finish while the main
            // loop is genuinely held at a prompt.
            if session.isWaiting { session.state = .working(since: now) }
            session.pending = nil
        case "SubagentStop":
            if let agentID = message.agentID, session.agents[agentID] != nil {
                session.agents[agentID] = nil
            } else if let oldest = session.agents.min(by: { $0.value < $1.value }) {
                session.agents[oldest.key] = nil
            }
        case _ where Self.heartbeatEvents.contains(message.event):
            // In-turn activity: a turn shown as a possible wait was not waiting after all, or has been answered.
            session.heartbeats = true
            if message.event == "beforeShellExecution" || message.event == "beforeMCPExecution" {
                session.commandsInFlight += 1
            } else if message.event == "afterShellExecution" || message.event == "afterMCPExecution" {
                session.commandsInFlight = Swift.max(0, session.commandsInFlight - 1)
            }
            if session.quietNudge, session.isWaiting { session.state = .working(since: now) }
        default:
            if message.needsInput {
                if !session.isWaiting { outcome.startedWaiting = session }
                session.state = .waiting(since: now)
            } else if message.clearsWaiting, session.isWaiting {
                session.state = .working(since: now)
            }
            if message.clearsWaiting { session.pending = nil }
            if message.waitsOnQuota { session.quotaWait = true }
            if message.resumesFromQuota {
                session.quotaWait = false
                session.limitHitAt = nil
                outcome.quotaResumed = true
            }
            // A request the hook is holding the session for. It replaces whatever request stood before it (the
            // hook process behind that one is gone, or is about to be answered nothing), and it is a wait
            // whatever the vendor's `needsInput` said, because the assistant cannot go on until it is answered.
            // A request whose id is already standing, on this session or another, is a replayed line (ids are
            // UUIDs the hook generated): the first keeps its place and its `since`, and this one is reported as
            // nothing, so the store releases its connection at once and it lands as the display-only wait.
            if let request = message.request {
                if !session.isWaiting { outcome.startedWaiting = session }
                session.state = .waiting(since: now)
                let standing = session.pending?.id == request.id || sessions.values.contains { $0.pending?.id == request.id }
                if !standing {
                    let pending = PendingRequest(id: request.id, kind: request.kind, since: now)
                    session.pending = pending
                    outcome.requested = (session, pending)
                }
            }
        }
        if let hadPending, session.pending?.id != hadPending.id {
            outcome.requestsEnded.append(EndedRequest(sessionID: id, requestID: hadPending.id))
        }
        if wasWaiting, !session.isWaiting { outcome.stoppedWaiting.append(id) }
        sessions[id] = session
        return outcome
    }

    /// Every request still standing, with the session it stands on, newest first.
    func pending(now: Date) -> [(session: AgentSession, request: PendingRequest)] {
        sessions.values.compactMap { session in session.pending.map { (session, $0) } }
            .filter { now.timeIntervalSince($0.request.since) < Self.pendingTimeout }
            .sorted { $0.request.since > $1.request.since }
    }

    /// Ends the request `requestID`, because the app answered it or handed it back to the terminal. A decision
    /// the assistant acts on puts the session back to work, since nothing else will say so until its next event;
    /// a pass leaves it waiting, because the terminal is now asking. Returns the session the request stood on, or
    /// nil when no session holds that id: a decision can only land on a request the tracker is showing.
    @discardableResult
    mutating func resolve(requestID: String, resumes: Bool, now: Date) -> AgentSession? {
        guard let entry = sessions.first(where: { $0.value.pending?.id == requestID }) else { return nil }
        var session = entry.value
        session.pending = nil
        if resumes, session.isWaiting { session.state = .working(since: now) }
        session.lastEvent = now
        sessions[entry.key] = session
        return session
    }

    /// Drops every title and session name held: *Show what a session is working on* was turned off, and with it
    /// off nothing of a prompt is held anywhere in the app (docs/hooks.md), not only nothing new.
    mutating func clearTitles() {
        for (id, var session) in sessions where session.title != nil || session.sessionName != nil {
            session.title = nil
            session.sessionName = nil
            sessions[id] = session
        }
    }

    /// A status-line update is proof the session is alive; its project, branch and pull request are taken. Only
    /// Claude Code has a status line, and its key is the bare id, so no `key(tool:session:host:)` is needed here.
    /// The status line's per-session figures. The model, the name and the line counts are Claude Code's running
    /// values and replace what was held; the prompt-cache object is priced here at the session model's
    /// cache-write rate (`PromptCacheStats`), so the tracker holds a figure the card can show without pricing.
    mutating func statusline(sessionID: String?, project: String?, branch: String? = nil, prURL: String? = nil, model: String? = nil,
                             sessionName: String? = nil, linesAdded: Int? = nil, linesRemoved: Int? = nil,
                             promptCache: Statusline.PromptCache? = nil, now: Date) {
        guard let sessionID else { return }
        expire(now: now)
        var session = sessions[sessionID] ?? AgentSession(id: sessionID, project: project, state: .idle, started: now, lastEvent: now, turnStarted: nil)
        if session.project == nil { session.project = project }
        if let branch { session.branch = branch }
        session.prURL = prURL ?? session.prURL
        if let model { session.model = model }
        if let sessionName { session.sessionName = sessionName }
        if let linesAdded { session.linesAdded = linesAdded }
        if let linesRemoved { session.linesRemoved = linesRemoved }
        if let promptCache { session.promptCache = PromptCacheStats(promptCache, model: model ?? session.model) }
        session.lastEvent = now
        sessions[sessionID] = session
    }

    /// Waits older than ten minutes fall back to idle, a finished turn's mark is dropped once its ninety seconds
    /// are up, agents silent that long are forgotten, and sessions silent for four hours are dropped. This is the
    /// app's answer to a hook that stops reporting mid-session: every state here has an end that arrives whether or
    /// not another event ever does.
    /// Returns the sessions that stopped waiting by timing out or going stale, so their delivered "is waiting"
    /// notices can be withdrawn like every other end of a wait. Without this a wait nobody ever answered left its
    /// banner in Notification Center for good, and the hand stayed up there long after the ring had put it down.
    @discardableResult
    mutating func expire(now: Date) -> [String] {
        var stoppedWaiting: [String] = []
        for (id, var session) in sessions {
            if now.timeIntervalSince(session.lastEvent) >= Self.staleAfter {
                if session.isWaiting { stoppedWaiting.append(id) }
                sessions[id] = nil
                continue
            }
            if case .waiting(let since) = session.state, now.timeIntervalSince(since) >= Self.waitingTimeout {
                session.state = .idle
                stoppedWaiting.append(id)
            }
            if let pending = session.pending, now.timeIntervalSince(pending.since) >= Self.pendingTimeout {
                session.pending = nil
            }
            if let finished = session.finished, now.timeIntervalSince(finished.at) >= Self.finishedHold {
                session.finished = nil
            }
            session.agents = session.agents.filter { now.timeIntervalSince($0.value) < Self.agentTimeout }
            sessions[id] = session
        }
        return stoppedWaiting
    }

    /// "notchmeter (and 1 more)": the projects waiting, newest first.
    static func waitingPhrase(_ waiting: [AgentSession]) -> String? {
        guard let first = waiting.first else { return nil }
        let name = first.displayName ?? L("a session")
        return waiting.count > 1 ? L("%1$@ (and %2$ld more)", name, waiting.count - 1) : name
    }
}
