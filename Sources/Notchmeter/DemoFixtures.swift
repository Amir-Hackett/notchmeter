import Foundation

/// What `--render-assets` shows: one afternoon on a Mac with Claude Code, Codex and Cursor signed in and the
/// Claude Code hook installed, fixed so the README's pictures come out the same on every render. Nothing here
/// reaches a provider, the Keychain or the network: the store is seeded and its loops never start.
enum DemoFixtures {
    static let suiteName = "com.amirhackett.notchmeter.render-assets"
    /// The Welcome tour's previews, which run inside the app rather than in a render: a suite of their own so a
    /// tour open while `--render-assets` runs from the same account cannot have its preferences emptied under it.
    static let previewSuiteName = "com.amirhackett.notchmeter.welcome-preview"

    /// What the hook is reporting while a picture is drawn. A tool has one ring and `ToolSignal.resolve` gives a
    /// wait the better claim on it, so the two states cannot both be true of Claude Code at one instant and no
    /// single frame can honestly show both. They are two moments of the same afternoon instead, and the renderer
    /// draws the pair side by side (`AssetRenderer.signalRings`).
    ///
    /// Both states are Claude Code's, and that is a choice. Cursor's hook lights the same finished tick, but it has
    /// no event for a wait (`ToolSignal`), so the pair is shown on the one ring that can honestly carry both; a
    /// fixture that lit Codex's ring would be a picture of something no user can currently see — which is the
    /// exact failure the stale `edge-left.png` already cost this repository once.
    enum Moment {
        /// A permission prompt is open: the ring takes the colour and the white dot.
        case waiting
        /// A turn has just ended inside the ninety-second hold: the ring takes the colour and the tick.
        case justFinished
        /// A permission request the hook is holding the session for (0.7.0): the panel opens on the PromptCard
        /// with Allow and Deny. The ring reads as `.waiting` does.
        case permissionRequest
        /// A question with options, the same way.
        case question
        /// A turn still running: the notchmeter session has its prompt and nothing has stopped it or asked
        /// anything. The one moment with no mark on any ring, which is what the Welcome tour's first step wants —
        /// it explains the rings before it explains the marks, and a dot it has not yet named would be a question
        /// the page cannot answer.
        case working
        /// What Claude Code's 0.11 events put on the Sessions card (Hook+Events.swift), across three sessions: the
        /// notchmeter session in a worktree, compacting by itself at 94 %, fallen back from Opus to Sonnet and
        /// twice refused by auto mode; scout, whose last five tool calls failed in a row, with two teammates idle;
        /// and atlas, waiting on an MCP server's sign-in that only the terminal can answer. For review
        /// (`hook-events.png`); nothing in the README uses it.
        case hookEvents
        /// An MCP server's form a click can answer, held for the notch like a permission request
        /// (`elicitation.png`, for review).
        case elicitation
    }

    @MainActor
    static func store(now: Date = Date(), moment: Moment = .waiting, suite: String = suiteName) -> (store: UsageStore, prefs: Preferences) {
        // A suite nothing writes to. The registration domain lives in memory only, so the countdown style the
        // pictures rely on is neither read from nor written to the user's own preferences. Peak hours are off: the
        // window is read against the wall clock, so a render during it grew an advice line and a footer word that
        // one an hour later did not. The suite is emptied first, since a registered default is only a fallback and
        // a value an earlier render left behind would outrank it.
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.register(defaults: ["resetDisplay": ResetDisplay.countdown.rawValue, "peakHoursTools": [String]()])
        let prefs = Preferences(defaults: defaults)
        let readings = readings(now: now)
        let store = UsageStore(prefs: prefs, providers: readings.map { FixtureProvider(reading: $0) },
                               cache: ReadingCache(defaults: defaults), defaults: defaults, drainLog: nil)
        store.seed(readings: readings, cost: cost(now: now), nextUpdate: now.addingTimeInterval(2 * 60 + 40),
                   sessions: sessions(now: now, moment: moment), now: now)
        // The afternoon has the Claude Code hook installed, which is what keeps the Sessions card on the panel.
        store.hooksInstalled = true
        // The task list open on the notchmeter row, so the pictures show the checklist and not only its count.
        store.openSessionLists = [SessionsCard.listKey("notchmeter", .todos)]
        return (store, prefs)
    }

    /// Two Claude Code sessions the hook has reported, built by feeding `SessionTracker.apply` the events a real
    /// hook sends rather than by setting the fields — so a change to the state machine changes the pictures, and a
    /// state the machine cannot reach cannot be drawn.
    ///
    /// Every timestamp is an offset from the render's own `now`, because both signal states are read against the
    /// clock: a wait times out at ten minutes and a finish is held for ninety seconds, so absolute dates would
    /// give a blank strip on every render but the first. The offsets are deliberately well inside those windows —
    /// the wait is thirty-five seconds old and the finish twelve — since a render lays out every view and writes
    /// every file between seeding the store and drawing the last of them.
    ///
    /// The second session is idle and stays idle. It is there so the card's session line reads "2 sessions ·
    /// waiting in notchmeter" rather than "1 session", which is the count the README claims the hook keeps; its
    /// own turn ended six minutes ago, far outside the hold, so it adds nothing to the ring in either moment.
    static func sessions(now: Date, moment: Moment) -> SessionTracker {
        var tracker = SessionTracker()
        // The hook-events moment is three sessions of its own, replayed whole (`hookEvents`).
        if moment == .hookEvents {
            hookEvents(&tracker, now: now)
            return tracker
        }
        func send(_ event: String, _ ago: TimeInterval, session: String, project: String, branch: String, type: String? = nil, title: String? = nil) {
            var message = Hook.Message(event: event, needsInput: Hook.needsInput(event: event, notificationType: type),
                                       sessionID: session, project: project, notificationType: type, branch: branch)
            message.title = title
            // The terminal every fixture session runs in, so the Sessions card's chip and the jump have a target;
            // it is what iTerm2 puts in the environment of a shell it opens (docs/hooks.md).
            if event == "SessionStart" {
                message.terminal = TerminalRef(program: "iTerm.app", bundleID: "com.googlecode.iterm2", tty: session == "scout" ? "/dev/ttys002" : "/dev/ttys004",
                                               sessionID: session == "scout" ? "w0t1p0:2F1A0C44-5D2B-4E6A-9C3D-1B2A3C4D5E6F" : "w0t0p0:ABA06F98-9094-4382-953B-E41AFAC97761")
            }
            tracker.apply(message, now: now.addingTimeInterval(-ago))
        }
        func request(_ ago: TimeInterval, session: String, project: String, branch: String, kind: PendingRequest.Kind) {
            var message = Hook.Message(event: "PermissionRequest", needsInput: true, sessionID: session, project: project, branch: branch, permissionMode: "default")
            message.request = Hook.Request(id: requestID, kind: kind)
            tracker.apply(message, now: now.addingTimeInterval(-ago))
        }
        // What the notchmeter session carries while its turn runs, for the Sessions card's extras line: two
        // subagents, a task list two-thirds done, and the status line's context fill for each session. Replayed as
        // the hook and the status line send them, between scout's stop and the event each moment turns on, and
        // every one of them older than that event so the order stays ascending.
        func busy() {
            for (agent, ago) in [("agent-explore", 4.0 * 60), ("agent-review", 2.0 * 60 + 30)] {
                let message = Hook.Message(event: "SubagentStart", needsInput: false, sessionID: "notchmeter", project: "notchmeter",
                                           branch: "feat/side-notch", agentID: agent)
                tracker.apply(message, now: now.addingTimeInterval(-ago))
            }
            // The way current Claude Code builds it: a TaskCreate per task, then a TaskUpdate per change of status.
            for (index, item) in todoItems.enumerated() {
                for change in [TaskChange(kind: .created, id: "\(index + 1)", subject: item.content, status: .pending),
                               TaskChange(kind: .updated, id: "\(index + 1)", subject: nil, status: item.status)] {
                    var task = Hook.Message(event: "PostToolUse", needsInput: false, sessionID: "notchmeter", project: "notchmeter", branch: "feat/side-notch")
                    task.task = change
                    tracker.apply(task, now: now.addingTimeInterval(-100))
                }
            }
            tracker.statusline(sessionID: "scout", project: "scout", contextUsed: 0.31, now: now.addingTimeInterval(-90))
            tracker.statusline(sessionID: "notchmeter", project: "notchmeter", contextUsed: 0.78, now: now.addingTimeInterval(-60))
        }
        // Ascending in time: `apply` expires against the clock it is handed, so an event out of order would age
        // the state the one before it had just set. That is why scout's turn ends inside each branch below rather
        // than above them: it stopped six minutes ago, which in either moment falls after the notchmeter session
        // opened and took its prompt and before the event that moment turns on.
        send("SessionStart", 22 * 60, session: "scout", project: "scout", branch: "main")
        send("UserPromptSubmit", 19 * 60, session: "scout", project: "scout", branch: "main", title: scoutTitle)
        send("SessionStart", 14 * 60, session: "notchmeter", project: "notchmeter", branch: "feat/side-notch")
        switch moment {
        case .waiting:
            send("UserPromptSubmit", 9 * 60, session: "notchmeter", project: "notchmeter", branch: "feat/side-notch", title: notchmeterTitle)
            send("Stop", 6 * 60, session: "scout", project: "scout", branch: "main")
            busy()
            send("Notification", 35, session: "notchmeter", project: "notchmeter", branch: "feat/side-notch", type: "permission_prompt")
        case .justFinished:
            // Eight minutes and forty seconds, twenty-six times `ToolSignal.finishedAfter` and so a turn the ring
            // is meant to report rather than one the user watched end.
            send("UserPromptSubmit", 8 * 60 + 52, session: "notchmeter", project: "notchmeter", branch: "feat/side-notch", title: notchmeterTitle)
            send("Stop", 6 * 60, session: "scout", project: "scout", branch: "main")
            busy()
            send("Stop", 12, session: "notchmeter", project: "notchmeter", branch: "feat/side-notch")
        case .permissionRequest:
            send("UserPromptSubmit", 9 * 60, session: "notchmeter", project: "notchmeter", branch: "feat/side-notch", title: notchmeterTitle)
            send("Stop", 6 * 60, session: "scout", project: "scout", branch: "main")
            busy()
            request(35, session: "notchmeter", project: "notchmeter", branch: "feat/side-notch",
                    kind: .permission(tool: "Bash", summary: "swift build -c release", detail: "swift build -c release 2>&1 | grep -E 'warning:'",
                                      suggestions: [
                                          PendingRequest.Suggestion(index: 0, grant: .rules(["Bash(swift build:*)"]), place: .localSettings),
                                          PendingRequest.Suggestion(index: 1, grant: .rules(["Bash(swift build:*)"]), place: .session),
                                      ]))
        case .question:
            send("UserPromptSubmit", 9 * 60, session: "notchmeter", project: "notchmeter", branch: "feat/side-notch", title: notchmeterTitle)
            send("Stop", 6 * 60, session: "scout", project: "scout", branch: "main")
            busy()
            request(35, session: "notchmeter", project: "notchmeter", branch: "feat/side-notch",
                    kind: .question([PendingRequest.Question(text: "Where should the Sessions card sit?", header: "Layout", options: [
                        PendingRequest.Option(label: "Under the advice", description: "Between the Advice strip and the tool cards"),
                        PendingRequest.Option(label: "Above the cost", description: "First card on the panel"),
                        PendingRequest.Option(label: "Inside each tool card", description: "One block per assistant"),
                    ])]))
        case .working:
            send("UserPromptSubmit", 9 * 60, session: "notchmeter", project: "notchmeter", branch: "feat/side-notch", title: notchmeterTitle)
            send("Stop", 6 * 60, session: "scout", project: "scout", branch: "main")
        case .hookEvents:
            break
        case .elicitation:
            send("UserPromptSubmit", 9 * 60, session: "notchmeter", project: "notchmeter", branch: "feat/side-notch", title: notchmeterTitle)
            send("Stop", 6 * 60, session: "scout", project: "scout", branch: "main")
            busy()
            var message = Hook.Message(event: "Elicitation", needsInput: true, sessionID: "notchmeter", project: "notchmeter", branch: "feat/side-notch")
            message.mcpServer = "deploybot"
            message.request = Hook.Request(id: requestID, kind: .elicitation(elicitationForm))
            tracker.apply(message, now: now.addingTimeInterval(-35))
        }
        return tracker
    }

    /// The form the elicitation moment holds: a choice and a yes-or-no, the kind a click can answer.
    static let elicitationForm = PendingRequest.Elicitation(
        server: "deploybot", message: "Where should the preview build go?",
        fields: [
            .init(key: "environment", title: "Environment", detail: nil, kind: .choice([
                .init(value: "staging", label: "Staging"), .init(value: "preview", label: "Preview"), .init(value: "production", label: "Production"),
            ]), required: true),
            .init(key: "notify", title: "Tell the channel", detail: "Posts the link in #releases", kind: .toggle, required: false),
        ])

    /// The hook-events moment's three sessions, replayed as Claude Code's hook and status line send them. Each event
    /// is laid down with its age and the whole list played oldest first, across the three sessions, because `apply`
    /// expires against the clock it is handed (the note above `sessions`).
    private static func hookEvents(_ tracker: inout SessionTracker, now: Date) {
        var events: [(ago: TimeInterval, play: (inout SessionTracker, Date) -> Void)] = []
        func send(_ ago: TimeInterval, _ event: String, _ session: String, branch: String = "main", worktree: Bool = false,
                  _ configure: (inout Hook.Message) -> Void = { _ in }) {
            var message = Hook.Message(event: event, needsInput: Hook.needsInput(event: event, notificationType: nil), sessionID: session,
                                       project: session, branch: branch)
            message.worktree = worktree
            configure(&message)
            let built = message
            events.append((ago, { tracker, date in tracker.apply(built, now: date) }))
        }
        let notchmeter = (branch: "feat/hook-events", worktree: true)
        send(20 * 60, "SessionStart", "notchmeter", branch: notchmeter.branch, worktree: notchmeter.worktree) {
            $0.terminal = TerminalRef(program: "iTerm.app", bundleID: "com.googlecode.iterm2", tty: "/dev/ttys004")
        }
        send(12 * 60, "UserPromptSubmit", "notchmeter", branch: notchmeter.branch, worktree: notchmeter.worktree) {
            $0.title = "Subscribe to the hook events nobody is using"
        }
        send(9 * 60, "PostModelSwitch", "notchmeter", branch: notchmeter.branch, worktree: notchmeter.worktree) {
            $0.modelSwitch = ModelSwitch(from: "claude-opus-5", to: "claude-sonnet-5", source: .auto)
        }
        for (tool, ago) in [("Bash", 7.0 * 60), ("WebFetch", 4.0 * 60)] {
            send(ago, "PermissionDenied", "notchmeter", branch: notchmeter.branch, worktree: notchmeter.worktree) { $0.denial = Denial(tool: tool, kind: .rule) }
        }
        events.append((80, { tracker, date in tracker.statusline(sessionID: "notchmeter", project: "notchmeter", contextUsed: 0.94, now: date) }))
        send(20, "PreCompact", "notchmeter", branch: notchmeter.branch, worktree: notchmeter.worktree) { $0.compaction = .auto }

        send(18 * 60, "SessionStart", "scout") {
            $0.terminal = TerminalRef(program: "iTerm.app", bundleID: "com.googlecode.iterm2", tty: "/dev/ttys002")
        }
        send(10 * 60, "UserPromptSubmit", "scout") { $0.title = scoutTitle }
        send(6 * 60, "TeammateIdle", "scout") { $0.teammate = Teammate(key: "researcher", name: "researcher") }
        send(3 * 60, "TeammateIdle", "scout") { $0.teammate = Teammate(key: "fact-checker", name: "fact-checker") }
        // Five failed calls across three batches, none of which succeeded: the run that makes a session look stuck.
        var ago = 150.0
        for calls in [2, 2, 1] {
            for _ in 0..<calls {
                send(ago, "PostToolUseFailure", "scout") { $0.toolFailure = ToolFailure(tool: "Bash", interrupt: false) }
                ago -= 10
            }
            send(ago, Hook.batchEvent, "scout") { $0.batchSize = calls }
            ago -= 10
        }

        send(9 * 60, "SessionStart", "atlas") {
            $0.terminal = TerminalRef(program: "Apple_Terminal", bundleID: "com.apple.Terminal", tty: "/dev/ttys006")
        }
        send(5 * 60, "UserPromptSubmit", "atlas") { $0.title = "File the release checklist in Linear" }
        send(15, "Elicitation", "atlas") { $0.mcpServer = "linear" }

        for event in events.sorted(by: { $0.ago > $1.ago }) {
            event.play(&tracker, now.addingTimeInterval(-event.ago))
        }
    }

    /// The news the moment's last hook event raises (NotchNews.from), for the notch's peek and glow: the
    /// notchmeter session's permission prompt or question, or its long turn ending. Read off the tracker, so the
    /// project and the assistant are the session's own; nil if the moment's session is somehow not there, and for
    /// the working moment, where nothing has started waiting and no turn has ended.
    @MainActor
    static func news(in store: UsageStore, moment: Moment, now: Date) -> NotchNews? {
        guard let session = store.sessions.sessions["notchmeter"] else { return nil }
        let reason: NotchNews.Reason
        switch moment {
        case .waiting, .permissionRequest: reason = .approval
        case .question: reason = .question
        case .justFinished: reason = .finished
        case .working: return nil
        case .hookEvents: reason = .compacting
        case .elicitation: reason = .input
        }
        return NotchNews(reason: reason, sessionID: session.id, tool: session.tool, project: session.project, at: now)
    }

    /// The request id the two request moments carry, so a test or a renderer can address it.
    static let requestID = "demo-request"
    static let notchmeterTitle = "Add a Sessions card between the advice and the tool cards"
    static let scoutTitle = "Draft the Friday sports recap"
    /// The notchmeter session's task list, as Claude Code's Task tools would leave it partway through the turn.
    static let todoItems = [
        TodoPlan.Item(content: "Read the Sessions card and its tests", status: .completed),
        TodoPlan.Item(content: "Group the rows by project", status: .completed),
        TodoPlan.Item(content: "Draw the context gauge on each row", status: .inProgress),
    ]


    /// Claude on Max 5x a third of the way into a quiet session, Codex on a free plan with an untouched monthly
    /// window, Cursor on a free plan with nothing to meter: every ring under 40 % and on pace.
    ///
    /// Every reset is placed in the middle of the unit its countdown prints rather than on the boundary of it,
    /// which is what the odd half-minute and half-hour below are. `ResetText.duration` rounds the remaining
    /// seconds and then divides, so a reset laid exactly 3h 19m out prints "3h 19m" only while the draw happens
    /// inside the first half-second of the render and "3h 18m" after that. That is how `expanded.png` and
    /// `expanded-contrast.png` came to disagree with one another inside a single run — the two captures are
    /// seconds apart, and the pair is offered in docs/testing.md as evidence about contrast, which it cannot be
    /// while the two frames read different clocks. Half a unit is the furthest a printed value can be from
    /// changing: thirty seconds for a countdown printed in minutes, thirty minutes for one printed in hours,
    /// against a render that takes about two seconds end to end.
    static func readings(now: Date) -> [UsageReading] {
        let sessionSeconds: Int = 3 * 3600 + 19 * 60 + 30
        let weekSeconds: Int = 4 * 86_400 + 17 * 3600 + 30 * 60
        let monthSeconds: Int = 18 * 86_400 + 6 * 3600 + 30 * 60
        let cycleSeconds: Int = 12 * 86_400 + 12 * 3600 + 30 * 60
        let sessionReset = now.addingTimeInterval(TimeInterval(sessionSeconds))
        let weekReset = now.addingTimeInterval(TimeInterval(weekSeconds))
        return [
            UsageReading(tool: .claude, windows: [
                LimitWindow(id: "five_hour", label: .key("Session"), usedFraction: 0.14, resetsAt: sessionReset, periodDuration: Period.fiveHours),
                LimitWindow(id: "seven_day", label: .key("Weekly"), usedFraction: 0.04, resetsAt: weekReset, periodDuration: Period.week),
                LimitWindow(id: "scoped_fable", label: "Fable", usedFraction: 0.06, resetsAt: weekReset, periodDuration: Period.week, model: "Fable"),
            ], plan: "Max 5x", fetchedAt: now, observedAt: nil),
            UsageReading(tool: .codex, windows: [
                LimitWindow(id: "session", label: .key("Session"), usedFraction: nil, resetsAt: nil, note: L("No data")),
                LimitWindow(id: "monthly", label: .key("Monthly"), usedFraction: 0, resetsAt: now.addingTimeInterval(TimeInterval(monthSeconds)), periodDuration: 30 * Period.day),
            ], plan: "Free", fetchedAt: now, observedAt: nil),
            UsageReading(tool: .cursor, windows: [
                LimitWindow(id: "included", label: .key("Included usage"), usedFraction: nil, resetsAt: now.addingTimeInterval(TimeInterval(cycleSeconds)),
                            note: L("%@ plan has nothing for Cursor to meter yet", "Free")),
            ], plan: "Free", fetchedAt: now, observedAt: nil),
        ]
    }

    /// $6,600 over 30 days of Claude Code with quiet weekends, a heavy $548.76 yesterday and $118.31 so far
    /// today, beside a Cursor export at a ninth of it. The last hour ran at 3.2x the 30-day average active hour,
    /// which is what puts a line in the Advice strip.
    static func cost(now: Date) -> CostSummary {
        let today = 118.31
        let yesterday = 548.76
        let last30Days = 6600.0
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let weights: [Double] = [
            210, 265, 190, 305, 240, 35, 12,
            280, 330, 255, 410, 295, 48, 20,
            225, 360, 300, 445, 250, 60, 15,
            310, 380, 290, 520, 315, 70, 25,
        ]
        let perWeight = (last30Days - yesterday - today) / weights.reduce(0, +)
        let models = ["claude-opus-5": 0.6, "claude-sonnet-5": 0.33, "claude-haiku-4-5": 0.07]
        let projects = ["notchmeter": 0.63, "scout": 0.27, "Other": 0.1]
        var days: [Date: CostHistory.Record] = [:]
        for offset in 0..<30 {
            guard let day = calendar.date(byAdding: .day, value: offset - 29, to: start) else { continue }
            let cost = offset == 29 ? today : offset == 28 ? yesterday : weights[offset] * perWeight
            let tokens = Int(cost * 62_000)
            days[day] = CostHistory.Record(
                cost: cost,
                tokens: TokenBreakdown(input: tokens / 60, cacheWrite5m: tokens / 40, cacheWrite1h: tokens / 20,
                                       cacheRead: tokens - tokens / 60 - tokens / 40 - tokens / 20 - tokens / 100, output: tokens / 100),
                byModel: models.mapValues { $0 * cost }, byProject: projects.mapValues { $0 * cost },
                byModelTokens: models.mapValues { Int($0 * Double(tokens)) }, byProjectTokens: projects.mapValues { Int($0 * Double(tokens)) })
        }
        // Cursor's own export, day-resolution, so it reports no hour of its own.
        let cursorDays = days.mapValues { record in
            CostHistory.Record(cost: record.cost * 0.11, tokens: TokenBreakdown(input: record.tokens.total / 6, output: record.tokens.total / 60),
                               byModel: ["claude-4.5-sonnet": record.cost * 0.08, "gpt-5.3-codex": record.cost * 0.03], byProject: [:])
        }
        let weekStart = CostEngine.weekStart(weeklyResetsAt: nil, now: now, calendar: calendar)
        let claude = ProviderCost.build(tool: .claude, source: .localTranscripts, days: days, now: now, weekStart: weekStart,
                                        calendar: calendar, hourly: HourlyBurn(lastHour: 31.20, typicalHourly: 9.75, activeHours: 380),
                                        scannedAt: now)
        let cursor = ProviderCost.build(tool: .cursor, source: .billingExport, days: cursorDays, now: now, weekStart: weekStart,
                                        calendar: calendar, scannedAt: now.addingTimeInterval(-240))
        let base = CostSummary(today: 0, yesterday: 0, last30Days: 0, daily: [], lastHour: 0, typicalHourly: 0, burnMultiple: nil,
                               unpricedModels: [], scannedAt: now,
                               week: WeekCost(start: weekStart, cost: 903, perPercent: 12.4),
                               firstUse: calendar.date(byAdding: .day, value: -212, to: start), sinceFirstUse: 41_300)
        return base.adding([claude, cursor].compactMap { $0 })
    }
}

/// Installed, and never read: the demo store is seeded with the reading instead.
struct FixtureProvider: UsageProvider {
    let reading: UsageReading

    var tool: ToolID { reading.tool }
    var refreshInterval: TimeInterval { 300 }
    func isInstalled() -> Bool { true }
    func fetch() async throws -> UsageReading { reading }
}
