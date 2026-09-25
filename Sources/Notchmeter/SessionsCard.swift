import SwiftUI

/// Every session the hooks know about, and every one found running without them (SessionDetection), one row each
/// (Preferences.sessionsCard): at the top of the panel while any
/// of them is working, waiting or holding a request, and between the Advice strip and the tool cards otherwise
/// (PanelLayout.sessionsLead). How many there are is the panel header's to say (PanelHeader), directly above
/// the card whenever it leads, so the card's own title line no longer repeats it. A row says what its session is
/// working on, which assistant, branch and terminal it runs in, how long the turn has run, and whether it is
/// waiting on the reader. What needs the reader first, then what is working, then what just finished, then idle,
/// newest first within each; `rowCap` rows and then a count of the rest. With more than one project live the rows
/// sit under a small header per project ("notchmeter · 2"), the projects in the order of their most urgent row, so
/// grouping never pushes a wait below something that is only working. Idle
/// rows are drawn quieter and clock their silence, not their age, and *Clear* in the header sets every one of them
/// aside (SessionTracker.dismissIdle); left alone they go by themselves after `SessionTracker.idleAfter`. A click
/// on a row jumps to its terminal (`NotchActions.jump`, TerminalJump.swift) when the hook reported one and the
/// setting allows it; a row with nowhere to go is a row and not a button.
///
/// Under the row's two lines sits what the session is carrying, each only when something reported it: a context
/// gauge from the session's own status line (never estimated), a count of running subagents, and Claude Code's
/// task list as "2/3"; the last two open in place to list what they count. Since 0.11 Claude Code's hook adds
/// more (Hook+Events.swift): a compaction running beside the gauge, or the count of those done; the model the
/// session runs on, opening onto the switches that got it there; the teammates of an agent team that went idle;
/// and the tool calls auto mode refused this turn; the second line says "worktree" when the session runs in one,
/// and the line under it names an MCP server waiting for input, or a run of failures that may mean the session is
/// stuck. The chips wrap onto a second line when the row is too narrow for them (`ChipFlow`). With hooks installed
/// and no session yet the card stays, with one quiet line, so an empty list reads as "nothing running" and not as
/// "not set up".
///
/// The card asserts only what a hook said: a title is the prompt's first line the hook sent and the store kept,
/// a terminal is the one the hook's own environment named, and the clock is the turn's own start. A row found
/// without the hook, by the scan or by Claude Code's status line alone (AgentSession.isDetected), says so: a quiet
/// *detected* mark beside the assistant's chip, whose help, and the row's spoken value and hint, say its working is
/// a guess and a wait is never shown; and while any such row's assistant has no hook, the card
/// ends on one line saying what the hook adds, with a button that opens its install flow (`HookUpgradeLine`). One
/// Claude Cowork's tasks, which have no hook, sit among them with a "Cowork" chip that says where they were
/// read from (CoworkSessions): the Claude app's own name for the task, its folder, and a turn clocked from its
/// prompt that ends at the log's own end line; never a wait, and a click brings the Claude app forward. One
/// `TimelineView` drives every row, at a second while anything is working or waiting and a minute otherwise,
/// because a second timeline per row is a redraw per row per second for as long as the panel is open. Titles and
/// task text go while the screen is shared (`UsageStore.hidesFigures`): they are the user's own words, or the
/// assistant's words about the user's work.
struct SessionsCard: View {
    let store: UsageStore
    let prefs: Preferences
    let actions: NotchActions
    /// Drawn as the Simple panel's Sessions section (SimplePanel.swift): no box, the title as a section label, and
    /// the advice about sessions (AdvicePlacement) under it, which the Detailed panel keeps in its Advice strip.
    var embedded = false
    var advice: [Advice] = []
    @Environment(\.density) private var density

    static let rowCap = 6

    /// One row, computed once per tick from the session it stands for.
    struct Row: Equatable, Sendable {
        enum Status: Equatable, Sendable { case working, waiting, idle, finished }

        /// A subagent running under the session, numbered oldest first: the hook reports an opaque id and nothing
        /// a reader would recognise, so the list says how many and for how long, not which.
        struct Agent: Equatable, Sendable {
            let id: String
            let since: Date
        }

        let id: String
        let tool: ToolID
        let title: String
        /// The assistant's name: the one chip on the title line ("Cowork" for a Cowork task).
        let chips: [String]
        /// The second line: the branch, the terminal or editor's short name, the model when something reported it
        /// (the status line, or a detected session's transcript), and the host for a remote session.
        let branch: String?
        let place: String?
        let host: String?
        /// The project header the row sits under when the card groups ("notchmeter", "notchmeter@devbox").
        let group: String
        /// The turn's start while one runs; the last event heard once idle, so the clock reads as "quiet for".
        let since: Date
        let status: Status
        /// The line under the place: waiting for an answer, or done and worth a jump.
        let note: Note?
        let canJump: Bool
        let agents: [Agent]
        /// The session's own context fill, 0…1, when its status line has reported one.
        let contextUsed: Double?
        /// Claude Code's task list; its text is gone when titles are hidden, and the counts stay.
        let todos: TodoPlan?
        /// Where the session's state comes from (SessionSource), for the oracle's snapshot.
        let source: SessionSource
        /// A compaction running, or the ones done, for the mark beside the gauge.
        var compaction: CompactionMark? = nil
        /// The model the session runs on, and the switches that got it there.
        var model: ModelMark? = nil
        /// Teammates of an agent team that went idle, each with its name while titles are shown.
        var teammates: [Stamped<Teammate>] = []
        /// Tool calls auto mode refused this turn.
        var denials: [Stamped<Denial>] = []
        /// Whether the session runs in a git worktree.
        var worktree = false

        enum Note: Equatable, Sendable {
            case waitingForAnswer, doneJump, justFinished
            /// An MCP server is waiting for input that the notch cannot give it (a text field, a sign-in): the
            /// terminal's dialog is where it is answered. The server's name while titles are shown.
            case mcpInput(server: String?)
            /// `failures` tool calls failed in a row (AgentSession.mayBeStuck).
            case mayBeStuck(failures: Int)
        }

        enum CompactionMark: Equatable, Sendable {
            case compacting(auto: Bool)
            case compacted(count: Int, last: Date, auto: Bool)
        }

        struct ModelMark: Equatable, Sendable {
            let name: String
            /// The newest switch was Claude Code falling back by itself.
            let fellBack: Bool
            let switches: [Stamped<ModelSwitch>]
        }

        /// Found without the hook, by the scan or by the status line alone (AgentSession.isDetected): its working
        /// is a guess and it never waits, so the row wears the mark and the card may offer the hook.
        var detected: Bool { source == .detected || source == .statusline }

        /// Read from OpenCode's own database rather than reported by its plugin (SessionSource.localStorage): the
        /// row wears a chip that says so, and the card may offer the plugin.
        var fromStorage: Bool { source == .localStorage }

        /// The row asks something of the reader: it takes the tinted wash and the accent bar.
        var needsYou: Bool { status == .waiting || note == .waitingForAnswer }
    }

    /// The rows under one project header. `name` is nil when only one project is live, and then no header is drawn.
    struct Group: Equatable, Sendable {
        let name: String?
        /// Every session of the project, not only the ones shown above the "+N more" line.
        let count: Int
        let rows: [Row]
    }

    /// The rows for `sessions` (newest first), live ones ahead of idle ones, and how many were left off. The sort
    /// is stable, so recency still orders each group, and six idle terminals can no longer push a working one off.
    static func rows(_ sessions: [AgentSession], hideTitles: Bool, jump: Bool, now: Date) -> (rows: [Row], more: Int) {
        func status(_ session: AgentSession) -> Row.Status {
            session.isWaiting ? .waiting : session.isWorking ? .working : session.finish(now: now) != nil ? .finished : .idle
        }
        // With more than one project live every row sits under its project's header (`groups`), so a row with no
        // title of its own says something the header does not rather than the project again.
        let grouped = Set(sessions.map(groupName(of:))).count > 1
        let alike = alike(sessions, hideTitles: hideTitles, grouped: grouped)
        // The model chip is drawn where it says something: on a row whose model differs from another row's, or one
        // that has heard a switch and so opens onto how it got there. With the status line installed every Claude
        // row knows its model, and a line of chips all naming the same one tells the rows apart by nothing while
        // wrapping the extras sooner on the narrow panel.
        let modelsDiffer = Set(sessions.compactMap(\.model)).count > 1
        let ordered = sessions.enumerated().sorted { a, b in
            let (ra, rb) = (status(a.element).rank, status(b.element).rank)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
        let rows = ordered.prefix(rowCap).map { session -> Row in
            let status = status(session)
            let finished = status == .finished
            // A row is a button only where the resolver has somewhere to go: a reference that names a program and
            // nothing else (`TERM_PROGRAM=vscode` with no bundle id) is a reference, and not a jump.
            let canJump = jump && session.host == nil && session.terminal.map { TerminalJump.resolve($0) != .none } == true
            let note: Row.Note? = session.pending != nil ? .waitingForAnswer
                : status == .waiting && session.waitsOnMCP ? .mcpInput(server: hideTitles ? nil : session.mcpServer)
                : session.mayBeStuck(now: now) ? .mayBeStuck(failures: session.failureStreak)
                : finished ? (canJump ? .doneJump : .justFinished) : nil
            let place = Self.place(of: session)
            let agents = session.agents.sorted { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key }
                .map { Row.Agent(id: $0.key, since: $0.value) }
            let lines = Self.line(of: session, place: place, hideTitles: hideTitles, grouped: grouped, alike: alike.contains(session.id))
            var row = Row(id: session.id, tool: session.tool, title: lines.title, chips: [session.assistantName],
                          branch: lines.branch, place: lines.place, host: lines.host, group: groupName(of: session),
                          since: status == .idle || status == .finished ? session.lastEvent : session.turnStarted ?? session.started,
                          status: status, note: note, canJump: canJump, agents: agents, contextUsed: session.contextUsed,
                          todos: hideTitles ? session.todos?.withoutContent() : session.todos, source: session.source)
            row.compaction = compactionMark(of: session)
            if let model = session.model, modelsDiffer || !session.modelSwitches.isEmpty {
                row.model = Row.ModelMark(name: model, fellBack: session.fellBack, switches: session.modelSwitches)
            }
            row.teammates = hideTitles
                ? session.idleTeammates.map { Stamped(value: Teammate(key: $0.value.key, name: nil), at: $0.at) }
                : session.idleTeammates
            row.denials = session.denials
            row.worktree = session.worktree
            return row
        }
        return (rows, max(0, sessions.count - rowCap))
    }

    /// The assistant the card's upgrade line offers the hook for: the first drawn row found without the hook whose
    /// assistant has no hook of ours in its file (UsageStore.hookInstalledTools). Nil when there is none, and then
    /// the line is not drawn: a detected row whose assistant already has the hook is a session idle since before the
    /// app started, and its next event makes it the hook's.
    static func upgradeTool(_ rows: [Row], installed: Set<ToolID>) -> ToolID? {
        rows.first { $0.detected && !installed.contains($0.tool) }?.tool
    }

    /// The compaction mark a row carries: one running, else the count of those done, else none.
    static func compactionMark(of session: AgentSession) -> Row.CompactionMark? {
        if let compacting = session.compacting { return .compacting(auto: compacting.value == .auto) }
        guard session.compactions > 0, let last = session.lastCompaction else { return nil }
        return .compacted(count: session.compactions, last: last.at, auto: last.value == .auto)
    }

    /// The rows in project groups. One project, one headerless group. More than one, a group per project in the
    /// order of its most urgent row (the rows arrive worst first, so that is the order of each project's first
    /// row), and the rows keep their order inside it; so a wait still comes before any working row of another
    /// project. The count is taken over every session, including the ones past `rowCap`.
    static func groups(_ rows: [Row], sessions: [AgentSession]) -> [Group] {
        let counts = Dictionary(grouping: sessions, by: groupName(of:)).mapValues(\.count)
        guard counts.count > 1 else { return rows.isEmpty ? [] : [Group(name: nil, count: sessions.count, rows: rows)] }
        var order: [String] = []
        var members: [String: [Row]] = [:]
        for row in rows {
            if members[row.group] == nil { order.append(row.group) }
            members[row.group, default: []].append(row)
        }
        return order.map { Group(name: $0, count: counts[$0] ?? 0, rows: members[$0] ?? []) }
    }

    /// What a project header calls the session: "notchmeter", "notchmeter@devbox", "@devbox"; else the assistant
    /// ("Cowork" for a Cowork task given no folder).
    static func groupName(of session: AgentSession) -> String {
        session.displayName ?? session.assistantName
    }

    /// The prompt's first line when the hook sent one (else the status line's session name) and the screen is not
    /// shared; else the project (or host); else the assistant's name, so a row is never blank. The branch is on
    /// the row's second line, so it is not repeated here.
    static func title(of session: AgentSession, hideTitles: Bool) -> String {
        if !hideTitles, let title = session.displayTitle { return title }
        return session.displayName ?? session.assistantName
    }

    /// The row's title and second line, each saying a thing once. A row with a title of its own shows it over the
    /// branch, the terminal and the host. A row without one, under a project header, would only repeat the
    /// header, so it takes the branch as its title (else the terminal), which then leaves the second line; and
    /// the host is left off the second line wherever the title or the header already carries it ("proj@devbox").
    /// A row that would read word for word like another of its project's (`alike`: two Cursor chats on one
    /// branch, neither of which has a title) is told apart by when the app first heard of it instead, "First seen 2:04 PM", with the
    /// branch kept on the second line.
    static func line(of session: AgentSession, place: String?, hideTitles: Bool, grouped: Bool, alike: Bool = false)
        -> (title: String, branch: String?, place: String?, host: String?) {
        let host = session.host.map { "@\($0)" }
        if !hideTitles, let title = session.displayTitle { return (title, session.branch, place, grouped ? nil : host) }
        if alike { return (firstSeen(session.started), session.branch, place, grouped ? nil : host) }
        if grouped {
            if let branch = session.branch { return (branch, nil, place, nil) }
            if let place { return (place, nil, nil, nil) }
        }
        let fallback = Self.title(of: session, hideTitles: true)
        return (fallback, session.branch, place, grouped || host.map(fallback.contains) == true ? nil : host)
    }

    /// "First seen 2:04 PM", in the reader's own time format.
    static func firstSeen(_ date: Date) -> String {
        L("First seen %@", date.formatted(date: .omitted, time: .shortened))
    }

    /// The terminal or editor's short name for the row's second line. Cursor's own agent runs in Cursor: one name
    /// says it, not two.
    static func place(of session: AgentSession) -> String? {
        TerminalJump.displayName(bundleID: session.terminal?.bundleID).flatMap { $0 == session.tool.displayName ? nil : $0 }
    }

    /// The sessions whose row, with no title of its own, would read word for word like another row of its
    /// project: same fallback title, same second line. Two such rows cannot be told apart, so each says when it
    /// was first seen instead (`line`).
    static func alike(_ sessions: [AgentSession], hideTitles: Bool, grouped: Bool) -> Set<String> {
        struct Key: Hashable { let group, title: String; let branch, place, host: String? }
        let untitled = sessions.filter { hideTitles || $0.displayTitle == nil }
        let byLine = Dictionary(grouping: untitled) { session -> Key in
            let line = line(of: session, place: place(of: session), hideTitles: hideTitles, grouped: grouped)
            return Key(group: groupName(of: session), title: line.title, branch: line.branch, place: line.place, host: line.host)
        }
        return Set(byLine.values.filter { $0.count > 1 }.flatMap { $0.map(\.id) })
    }

    /// The gauge's tint: quiet below 70 %, the warning orange to 90 %, vermillion past it. The percentage beside it
    /// says the same in figures, so the colour is never the only telling.
    static func contextLevel(_ fraction: Double) -> ContextLevel {
        fraction >= 0.9 ? .full : fraction >= 0.7 ? .high : .quiet
    }

    enum ContextLevel: Equatable, Sendable {
        case quiet, high, full

        var tint: Color? {
            switch self {
            case .quiet: nil
            case .high: Palette.warn
            case .full: Palette.danger
            }
        }
    }

    /// What the oracle's snapshot says of the card: the rows as drawn, in order, with their group, status, source
    /// (`hook`, `storage`, `detected`, `statusline` or `coworkLog`) and the counts they carry, never a title, a
    /// task's text, a teammate's name or an MCP server's (docs/testing.md).
    static func oracleRows(_ groups: [Group]) -> [[String: Any]] {
        groups.flatMap { group in
            group.rows.map { row -> [String: Any] in
                ["id": row.id, "group": group.name as Any, "status": row.status.oracleName, "agents": row.agents.count,
                 "source": row.source.rawValue,
                 "context": row.contextUsed.map(Oracle.fraction) as Any,
                 "todos": row.todos.map { ["done": $0.done, "total": $0.total] } as Any,
                 "compaction": row.compaction.map(\.oracleName) as Any, "model": row.model?.name as Any,
                 "fellBack": row.model?.fellBack ?? false, "switches": row.model?.switches.count ?? 0,
                 "teammatesIdle": row.teammates.count, "denials": row.denials.count, "worktree": row.worktree,
                 "note": row.note.map(\.oracleName) as Any]
            }
        }
    }

    var body: some View {
        let sessions = store.sessions
        TimelineView(.periodic(from: .now, by: sessions.working.isEmpty && sessions.waiting.isEmpty ? 60 : 1)) { context in
            // Titles off hides them here too, whatever the tracker still holds (the store clears it, but a value can
            // never be drawn under a setting that says not to).
            let (rows, more) = Self.rows(sessions.all, hideTitles: store.hidesFigures || !prefs.sessionTitles, jump: prefs.jumpToTerminal, now: context.date)
            let groups = Self.groups(rows, sessions: sessions.all)
            let lines = AdvicePlacement.sessionLines(advice, needsYou: rows.filter(\.needsYou).map { ($0.id, $0.tool) },
                                                     waiting: sessions.waiting.map { ($0.id, $0.tool) },
                                                     titlesShown: !(store.hidesFigures || !prefs.sessionTitles))
            VStack(alignment: .leading, spacing: embedded ? density.lineSpacing + 2 : density.rowSpacing) {
                if embedded {
                    SimpleSectionLabel(title: L("Sessions")) { clear(sessions) }
                        .padding(.horizontal, -density.cardPadding)
                    if !lines.drawn.isEmpty {
                        AdviceLines(advice: lines.drawn, open: actions.open)
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        Text(L("Sessions")).font(.headline)
                        Spacer()
                        clear(sessions)
                    }
                }
                if groups.isEmpty {
                    Text(L("No sessions right now")).modifier(Caption())
                }
                ForEach(groups, id: \.name) { group in
                    VStack(alignment: .leading, spacing: density.lineSpacing + 2) {
                        if let name = group.name {
                            GroupHeader(name: name, count: group.count)
                        }
                        ForEach(group.rows, id: \.id) { row in
                            SessionRow(row: row, now: context.date, jump: { actions.jump($0) }, session: sessions.all.first { $0.id == row.id },
                                       remove: { store.dismissSession(row.id) }, removeIdle: { store.dismissIdleSessions() },
                                       open: Set(Disclosure.allCases.filter { store.openSessionLists.contains(Self.listKey(row.id, $0)) }),
                                       toggle: { toggle(row.id, $0) }, embedded: embedded,
                                       advice: lines.onRow[row.id]?.map(\.text) ?? [])
                        }
                    }
                }
                if more > 0 {
                    Text(L("+%ld more", more)).modifier(Caption())
                }
                if let tool = Self.upgradeTool(rows, installed: store.hookInstalledTools) {
                    HookUpgradeLine(tool: tool, offer: actions.offerHook)
                }
                if let offer = Self.pluginOffer(rows: rows, installed: store.openCodePluginInstalled, spoke: store.openCodePluginSpoke) {
                    upgrade(offer)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CardBackground(boxed: !embedded))
        // Bare, the section still keeps the rows' text on the sheet's margin, which the box's padding gave it.
        .padding(.horizontal, embedded ? density.cardPadding : 0)
    }

    /// What the card says under rows read from OpenCode's database: add the plugin, or that it takes over at the
    /// next start.
    enum PluginOffer: Equatable, Sendable { case add, nextStart }

    /// The offer under the rows, if any: only under a row read from the database, and never once the plugin has
    /// spoken, when it has taken over already and the rows still marked *from database* are the ones it will not
    /// report on (UsageStore.standDownOpenCodeReading), so no start is coming that would change them.
    static func pluginOffer(rows: [Row], installed: Bool, spoke: Bool) -> PluginOffer? {
        guard rows.contains(where: \.fromStorage), !spoke else { return nil }
        return installed ? .nextStart : .add
    }

    /// Under rows read from OpenCode's database, the one thing that would make them exact: the plugin, one click
    /// away in Settings › Integrations; or, with the plugin already in place, that OpenCode loads it when it next
    /// starts. A line rather than a banner, since the rows are right as far as they go.
    @ViewBuilder
    private func upgrade(_ offer: PluginOffer) -> some View {
        if offer == .nextStart {
            Text(L("OpenCode switches to its plugin when it next starts")).modifier(Caption())
        } else {
            Button { actions.openSettingsPane(.integrations) } label: {
                Label(L("Add the OpenCode plugin for exact turn ends and waits"), systemImage: "puzzlepiece.extension")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.accent)
                    .frame(minHeight: 22, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Opens Settings › Integrations, where Add plugin… writes Notchmeter's own plugin file for OpenCode after asking"))
        }
    }

    /// Always drawn while there is something to clear, never only on hover: a panel read at a glance has no
    /// pointer on it.
    @ViewBuilder
    private func clear(_ sessions: SessionTracker) -> some View {
        if sessions.all.contains(where: { !$0.isWorking && !$0.isWaiting && $0.pending == nil }) {
            Button(L("Clear")) { store.dismissIdleSessions() }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold)).foregroundStyle(Palette.accent)
                .help(L("Clear the idle sessions; each comes back if it does anything"))
                .accessibilityLabel(L("Remove all idle sessions"))
        }
    }
}

extension SessionsCard {
    /// The lists a row can open in place.
    enum Disclosure: String, CaseIterable, Sendable { case agents, todos, models, teammates, denials }

    /// The key a row's open list is held under (UsageStore.openSessionLists).
    static func listKey(_ session: String, _ list: Disclosure) -> String { "\(session)/\(list.rawValue)" }

    /// Opens or closes one row's list, animated unless motion is reduced, and tells the oracle.
    private func toggle(_ session: String, _ list: Disclosure) {
        let key = Self.listKey(session, list)
        let opening = !store.openSessionLists.contains(key)
        let change = {
            if opening { store.openSessionLists.insert(key) } else { store.openSessionLists.remove(key) }
        }
        if AccessibilityDisplay.shared.motionReduced { change() } else { withAnimation(.easeOut(duration: 0.18), change) }
        Oracle.shared.emit("sessionRow", ["session": session, "list": list.rawValue, "expanded": opening])
    }
}

/// "notchmeter · 2": the project and how many of its sessions the hooks know about, read as one heading.
private struct GroupHeader: View {
    let name: String
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder").font(.caption2.weight(.semibold))
            Text(verbatim: name).font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            Text(verbatim: "· \(count)").font(.caption).monospacedDigit()
        }
        .foregroundStyle(Caption.style)
        .padding(.top, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Spoken.line(name, count == 1 ? L("1 session") : L("%ld sessions", count)))
        .accessibilityAddTraits(.isHeader)
    }
}

private struct SessionRow: View {
    let row: SessionsCard.Row
    let now: Date
    let jump: (AgentSession) -> Void
    let session: AgentSession?
    /// Takes the row off the list until the session sends another event (UsageStore.dismissSession, 0.7.7): a
    /// conversation closed in Cursor never says it ended, so it would otherwise stay for hours.
    var remove: () -> Void = {}
    var removeIdle: () -> Void = {}
    @State private var hovering = false
    /// Bumped on every hover change, so a pending "left" only lands if nothing came after it.
    @State private var hoverGeneration = 0
    /// Which of the row's lists are open, held by the store (UsageStore.openSessionLists), and the switch for one.
    var open: Set<SessionsCard.Disclosure> = []
    var toggle: (SessionsCard.Disclosure) -> Void = { _ in }
    /// On the Simple sheet, where the title takes the sheet's one title size.
    var embedded = false
    /// The advice lines this row carries instead of the sheet drawing them (AdvicePlacement.sessionLines), read
    /// after the row's own value.
    var advice: [String] = []

    /// A row holding a request keeps it: the request is answered from its own card.
    private var removable: Bool { session?.pending == nil }

    var body: some View {
        let contrast = AccessibilityDisplay.shared.contrast
        VStack(alignment: .leading, spacing: 5) {
            // The remove control sits beside the jump button, not inside it: a button in another button's label
            // loses its clicks to the outer one. The disclosures below sit outside it for the same reason.
            HStack(alignment: .top, spacing: 6) {
                if row.canJump, let session {
                    Button { jump(session) } label: { content }
                        .buttonStyle(.plain)
                        .help(TerminalJump.jumpHelp(session.terminal))
                        .accessibilityAction(named: TerminalJump.jumpHelp(session.terminal)) { jump(session) }
                } else {
                    content
                }
                trailing
            }
            if hasExtras {
                extras.padding(.leading, SessionRow.textInset)
            }
            if open.contains(.agents), !row.agents.isEmpty {
                agentList.padding(.leading, SessionRow.textInset)
            }
            if open.contains(.todos), let todos = row.todos, todos.hasContent {
                checklist(todos).padding(.leading, SessionRow.textInset)
            }
            if open.contains(.models), let model = row.model, !model.switches.isEmpty {
                switchList(model.switches).padding(.leading, SessionRow.textInset)
            }
            if open.contains(.teammates), !row.teammates.isEmpty {
                teammateList.padding(.leading, SessionRow.textInset)
            }
            if open.contains(.denials), !row.denials.isEmpty {
                denialList.padding(.leading, SessionRow.textInset)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background {
            // The row that needs the reader: a wash of the "needs you" blue and a bar down its leading edge, so it
            // is found by shape as well as by the hand in its status mark.
            // Under Increase Contrast the card is lighter and the wash with it, and the blue marks drawn on it fall
            // under 3:1 (measured on expanded-contrast.png: the hand 2.3:1, the tick 2.1:1), so the bar and the marks
            // go white there (`SessionRow.needsYouMark`) and the wash alone carries the blue.
            if row.needsYou {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.calm.opacity(contrast ? 0.32 : 0.15))
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Self.needsYouMark).frame(width: 3)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        // The wash reaches into the card's padding, so every row's text stays on the header's edge.
        .padding(.horizontal, -6)
        .onHover { inside in
            // An exit is honoured a moment late. The first click on a panel that is not key makes it key, which
            // resets its tracking areas and reports the pointer gone for an instant; taken at once, that took the
            // remove button away between the mouse going down and coming up, and the first click did nothing.
            hoverGeneration += 1
            let generation = hoverGeneration
            if inside {
                hovering = true
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    if hoverGeneration == generation { hovering = false }
                }
            }
        }
        .contextMenu {
            if removable { Button(L("Remove from the list"), action: remove) }
            Button(L("Remove all idle sessions"), action: removeIdle)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: L("Remove from the list")) { if removable { remove() } }
    }

    /// Where the row's text starts: past the 13 pt status mark and its 7 pt gap, so the extras line up under it.
    static let textInset: CGFloat = 20

    /// The "needs you" blue for a mark drawn on the card (the hand, the bar, a task in progress), or white under
    /// Increase Contrast, where Palette.calm on the lighter card and wash is under 3:1. The shape still tells the
    /// mark apart, and the wash stays blue.
    @MainActor static var needsYouMark: Color { AccessibilityDisplay.shared.contrast ? .white : Palette.calm }

    /// The idle row's quiet is its title in the caption's colour and the hollow ring for its mark. It is not
    /// dimmed further: at 0.8 opacity the secondary title, clock and context figure measured 3.7:1 on the black
    /// panel, under 4.5:1 for text, and Increase Contrast could not raise them.

    private var hasExtras: Bool {
        row.contextUsed != nil || !row.agents.isEmpty || (row.todos?.total ?? 0) > 0 || row.compaction != nil || row.model != nil
            || !row.teammates.isEmpty || !row.denials.isEmpty
    }

    /// The turn's clock, or while the pointer is on the row, the control that removes it (the hover's exit is
    /// debounced above, so a click that makes the panel key cannot take the button away mid-click).
    @ViewBuilder
    private var trailing: some View {
        if hovering, removable {
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").font(.callout).foregroundStyle(.secondary)
                    .frame(minWidth: 22, minHeight: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Remove from the list; it comes back if the session does anything"))
            .accessibilityLabel(L("Remove from the list"))
        } else {
            // Already spoken as part of the row's own value (`content`), so VoiceOver does not read it twice.
            Text(clock)
                .font(.caption).foregroundStyle(Caption.style).monospacedDigit()
                .padding(.top, 1)
                .help(row.status == .idle || row.status == .finished ? L("How long since this session last did anything") : L("How long this turn has run"))
                .accessibilityHidden(true)
        }
    }

    /// A running turn's length, or how long an idle session has been quiet ("idle 12m").
    private var clock: String {
        let duration = ResetText.duration(max(0, now.timeIntervalSince(row.since)))
        return row.status == .idle ? L("idle %@", duration) : duration
    }

    /// "feat/side-notch · worktree · iTerm · @devbox": whichever of them the hook reported.
    private var placeParts: [String] { [row.worktree ? L("worktree") : nil, row.place, row.host].compactMap { $0 } }

    private var content: some View {
        HStack(alignment: .top, spacing: 7) {
            StatusMark(status: row.status, symbol: symbol, colour: colour)
                .frame(width: 13, alignment: .center)
                .padding(.top, 3)
                .help(row.detected ? L("%@, as far as the running process and its files show", statusText) : statusText)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    // On the Simple sheet the title matches its sibling rows' (SimpleRow): one title size a sheet.
                    Text(verbatim: row.title).font((embedded ? Font.body : .callout).weight(.semibold)).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(row.status == .idle ? Caption.style : AnyShapeStyle(.primary))
                    ForEach(row.chips, id: \.self) { Chip(text: $0).help(chipHelp) }
                    if row.detected {
                        DetectedMark()
                    }
                    if row.fromStorage {
                        Chip(text: L("from database"))
                            .help(L("Read from OpenCode's own database without its plugin: a turn's end shows a few seconds late, and a wait for your permission does not show at all"))
                    }
                }
                if row.branch != nil || !placeParts.isEmpty {
                    HStack(spacing: 4) {
                        if let branch = row.branch {
                            Image(systemName: "arrow.triangle.branch").font(.caption2)
                            Text(verbatim: branch).lineLimit(1).truncationMode(.middle)
                        }
                        if !placeParts.isEmpty {
                            Text(verbatim: (row.branch == nil ? "" : "· ") + placeParts.joined(separator: " · ")).lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Caption.style)
                }
                if let note = row.note {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        if let symbol = noteSymbol(note) { Image(systemName: symbol).imageScale(.small) }
                        Text(noteText(note)).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.caption2.weight(.medium)).foregroundStyle(noteColour(note))
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.title)
        .accessibilityValue(Spoken.line(statusText, row.chips.joined(separator: ", "), row.detected ? L("Found without the hook") : row.fromStorage ? L("from database") : nil,
                                        row.branch, placeParts.joined(separator: ", "),
                                        ResetText.duration(max(0, now.timeIntervalSince(row.since))), row.note.map(noteText),
                                        advice.isEmpty ? nil : advice.map(Spoken.phrase).joined(separator: " ")))
        // What the detected mark's tooltip says, for a reader who cannot hover: the spoken waiting state is what
        // such a reader relies on, and this row will never speak one.
        .accessibilityHint(row.detected ? L("Working is a guess, and a wait for your answer is not shown without the hook.") : "")
    }

    // MARK: The extras line

    private var extras: some View {
        ChipFlow(spacing: 6, lineSpacing: 4) {
            if let used = row.contextUsed {
                ContextGauge(fraction: used, quiet: row.status == .idle)
            }
            if let compaction = row.compaction {
                CompactionChip(mark: compaction, now: now)
            }
            if let model = row.model {
                let value = model.fellBack ? L("%@, fell back by itself", model.name) : model.name
                if model.switches.isEmpty {
                    ExtraChip(symbol: "cpu", text: model.name, chevron: nil)
                        .help(L("The model this session runs on"))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(L("Model"))
                        .accessibilityValue(value)
                } else {
                    disclosure(.models, symbol: model.fellBack ? "arrow.uturn.down" : "cpu", text: model.name, label: L("Model"),
                               value: Spoken.line(value, model.switches.count == 1 ? L("1 switch") : L("%ld switches", model.switches.count)),
                               help: L("The model this session runs on; click to list how it got there"))
                }
            }
            if !row.agents.isEmpty {
                disclosure(.agents, symbol: "person.2.fill", text: "\(row.agents.count)",
                           label: L("Subagents"), value: row.agents.count == 1 ? L("1 agent") : L("%ld agents", row.agents.count),
                           help: L("The subagents this session is running; click to list them"))
            }
            if let todos = row.todos, todos.total > 0 {
                let counts = "\(todos.done)/\(todos.total)"
                let value = L("%1$ld of %2$ld done", todos.done, todos.total)
                if todos.hasContent {
                    disclosure(.todos, symbol: "checklist", text: counts, label: L("Task list"), value: value,
                               help: L("Claude Code's task list for this session; click to show it"))
                } else {
                    // The words are hidden (titles off, or the screen shared): the counts stand alone, not as a
                    // control that would open onto nothing.
                    ExtraChip(symbol: "checklist", text: counts, chevron: nil)
                        .help(L("Claude Code's task list for this session"))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(L("Task list"))
                        .accessibilityValue(value)
                }
            }
            if !row.teammates.isEmpty {
                let count = row.teammates.count
                disclosure(.teammates, symbol: "person.3.fill", text: L("%ld idle", count), label: L("Idle teammates"),
                           value: count == 1 ? L("1 teammate idle") : L("%ld teammates idle", count),
                           help: L("Teammates of this session's agent team that finished their turn and went idle; click to list them"))
            }
            if !row.denials.isEmpty {
                let count = row.denials.count
                disclosure(.denials, symbol: "hand.raised.slash.fill", text: "\(count)", label: L("Refused by auto mode"),
                           value: count == 1 ? L("1 tool call") : L("%ld tool calls", count),
                           help: L("Tool calls auto mode refused in this turn; click to list them"))
            }
        }
    }

    /// A chip that opens one of the row's lists in place. The chevron turns with it, and VoiceOver hears the
    /// count and whether the list is open, the way a disclosure triangle is announced.
    private func disclosure(_ section: SessionsCard.Disclosure, symbol: String, text: String, label: String, value: String, help: String) -> some View {
        let isOpen = open.contains(section)
        return Button { toggle(section) } label: {
            ExtraChip(symbol: symbol, text: text, chevron: isOpen)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityValue(Spoken.line(value, isOpen ? L("Expanded") : L("Collapsed")))
    }

    private var agentList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(row.agents.enumerated()), id: \.element.id) { index, agent in
                let elapsed = ResetText.duration(max(0, now.timeIntervalSince(agent.since)))
                HStack(spacing: 5) {
                    Image(systemName: "person.fill").font(.caption2).foregroundStyle(Caption.style)
                    Text(L("Subagent %ld", index + 1)).font(.caption)
                    Spacer(minLength: 8)
                    Text(verbatim: elapsed).font(.caption).foregroundStyle(Caption.style).monospacedDigit()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L("Subagent %ld", index + 1))
                .accessibilityValue(Spoken.line(elapsed))
            }
        }
    }

    /// The model switches, newest first: from what to what, how, and how long ago.
    private func switchList(_ switches: [Stamped<ModelSwitch>]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(switches.reversed().enumerated()), id: \.offset) { _, entry in
                let change = entry.value
                let words = change.from.map { L("%1$@ to %2$@", Hook.modelDisplayName($0), Hook.modelDisplayName(change.to)) } ?? Hook.modelDisplayName(change.to)
                let how = SessionsCard.sourceText(change.source)
                let ago = ResetText.duration(max(0, now.timeIntervalSince(entry.at)))
                HStack(spacing: 5) {
                    Image(systemName: change.isFallback ? "arrow.uturn.down" : "arrow.left.arrow.right").font(.caption2).foregroundStyle(Caption.style)
                    Text(verbatim: words).font(.caption).lineLimit(1).truncationMode(.middle)
                    if let how { Text(verbatim: "· \(how)").font(.caption).foregroundStyle(Caption.style).lineLimit(1) }
                    Spacer(minLength: 8)
                    Text(verbatim: ago).font(.caption).foregroundStyle(Caption.style).monospacedDigit()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(words)
                .accessibilityValue(Spoken.line(how, L("%@ ago", ago)))
            }
        }
    }

    /// The idle teammates, by name while titles are shown, else numbered, with how long each has been idle.
    private var teammateList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(row.teammates.enumerated()), id: \.offset) { index, entry in
                let name = entry.value.name ?? L("Teammate %ld", index + 1)
                let idle = ResetText.duration(max(0, now.timeIntervalSince(entry.at)))
                HStack(spacing: 5) {
                    Image(systemName: "person.fill").font(.caption2).foregroundStyle(Caption.style)
                    Text(verbatim: name).font(.caption).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(L("idle %@", idle)).font(.caption).foregroundStyle(Caption.style).monospacedDigit()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(name)
                .accessibilityValue(L("idle %@", idle))
            }
        }
    }

    /// The tool calls auto mode refused this turn, newest first, with the kind of refusal and how long ago.
    private var denialList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(row.denials.reversed().enumerated()), id: \.offset) { _, entry in
                let kind = SessionsCard.denialText(entry.value.kind)
                let ago = ResetText.duration(max(0, now.timeIntervalSince(entry.at)))
                HStack(spacing: 5) {
                    Image(systemName: "hand.raised.slash").font(.caption2).foregroundStyle(Caption.style)
                    Text(verbatim: entry.value.tool).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    Text(verbatim: "· \(kind)").font(.caption).foregroundStyle(Caption.style).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(verbatim: ago).font(.caption).foregroundStyle(Caption.style).monospacedDigit()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(entry.value.tool)
                .accessibilityValue(Spoken.line(kind, L("%@ ago", ago)))
            }
        }
    }

    /// The plan's items in order. One with no words (the tool sent none, or an update for a task the app never
    /// saw created) is still an item the counts include, so it is drawn and read as "Untitled task", in the
    /// caption's quieter style, rather than as an empty line VoiceOver would read as nothing.
    private func checklist(_ todos: TodoPlan) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(todos.items.enumerated()), id: \.offset) { _, item in
                let text = item.content.flatMap { $0.isEmpty ? nil : $0 }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: item.status.symbol).font(.caption2.weight(.semibold)).foregroundStyle(item.status.colour)
                    Text(text ?? L("Untitled task")).font(.caption).lineLimit(2)
                        .italic(text == nil)
                        .strikethrough(item.status == .completed)
                        .foregroundStyle(item.status == .completed || text == nil ? AnyShapeStyle(Caption.style) : AnyShapeStyle(.primary))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(text ?? L("Untitled task"))
                .accessibilityValue(item.status.spoken)
            }
        }
    }

    /// Colour and shape together: the tool's own colour, breathing, while it works; the blue hand while it waits; a
    /// small grey ring while it idles; a green tick just after it finished.
    private var symbol: String {
        switch row.status {
        case .working: "circle.fill"
        case .waiting: "hand.raised.fill"
        case .idle: "circle.dotted"
        case .finished: "checkmark.circle.fill"
        }
    }

    private var colour: Color {
        switch row.status {
        case .working: row.tool.color
        case .waiting: Self.needsYouMark
        case .idle: .secondary
        case .finished: Palette.pine
        }
    }

    private var statusText: String {
        switch row.status {
        case .working: L("Working")
        case .waiting: L("Waiting")
        case .idle: L("Idle")
        case .finished: L("Just finished")
        }
    }

    /// The chip names the assistant; on a Cowork row it also says where the row came from and what that cannot
    /// tell, since nothing else on the row does.
    private var chipHelp: String {
        switch row.source {
        case .hook, .localStorage, .detected, .statusline: L("The assistant running this session")
        case .coworkLog: L("Claude Cowork, read from the task's own log in the Claude app. It has no hook, so a task is never shown as waiting for you.")
        }
    }

    private func noteText(_ note: SessionsCard.Row.Note) -> String {
        switch note {
        case .waitingForAnswer: L("Waiting for your answer")
        case .doneJump: L("Done — click to jump")
        case .justFinished: L("Just finished")
        case .mcpInput(let server?): L("%@ asks for input: answer in the terminal", server)
        case .mcpInput(nil): L("An MCP server asks for input: answer in the terminal")
        case .mayBeStuck(let failures): L("May be stuck: %ld tool calls failed in a row", failures)
        }
    }

    /// A symbol in front of the two notes that are not the row's own status, so neither is told by colour alone.
    private func noteSymbol(_ note: SessionsCard.Row.Note) -> String? {
        switch note {
        case .mcpInput: NotchNews.Reason.input.symbolName
        case .mayBeStuck: NotchNews.Reason.stuck.symbolName
        case .waitingForAnswer, .doneJump, .justFinished: nil
        }
    }

    /// The waiting line is a link, so it takes the app's accent like the tool card's own "Waiting for your answer"
    /// (Palette.accent); the row's dot and symbol keep Palette.calm, the semantic "needs you" colour on signals.
    private func noteColour(_ note: SessionsCard.Row.Note) -> Color {
        switch note {
        case .waitingForAnswer, .mcpInput: AccessibilityDisplay.shared.contrast ? Palette.accentContrast : Palette.accent
        case .doneJump, .justFinished: Palette.pine
        // The warning orange, 9:1 on the black panel and above 4.5:1 on the lighter card of Increase Contrast.
        case .mayBeStuck: Palette.warn
        }
    }
}

/// A small capsule on the extras line: a symbol, a count, and for a disclosure a chevron that turns when open.
/// Taller than `Chip`, since this one is a click target.
private struct ExtraChip: View {
    let symbol: String
    let text: String
    /// nil for a chip that opens nothing.
    let chevron: Bool?

    var body: some View {
        HStack(spacing: 3) {
            // The type ramp's smallest size, so the chip follows the panel's text size rather than a fixed point size.
            Image(systemName: symbol).font(.caption2.weight(.semibold)).imageScale(.small)
            Text(verbatim: text).font(.caption2.weight(.semibold)).monospacedDigit()
            if let chevron {
                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).imageScale(.small)
                    .rotationEffect(.degrees(chevron ? 90 : 0))
            }
        }
        .padding(.horizontal, 7)
        .frame(minHeight: 20)
        .background(Capsule().fill(.white.opacity(AccessibilityDisplay.shared.contrast ? 0.26 : 0.14)))
        .contentShape(Capsule())
    }
}

/// The session's context fill as a short bar and its percentage, from its own status line. Tinted past 70 % and
/// 90 % (`SessionsCard.contextLevel`), and the figure beside it says the same thing without the colour.
private struct ContextGauge: View {
    let fraction: Double
    /// On an idle row: an untinted bar goes no brighter than the row's own title. The figure stays in the
    /// caption's colour, which is text and so held to 4.5:1.
    var quiet = false

    var body: some View {
        let contrast = AccessibilityDisplay.shared.contrast
        let percent = Int((fraction * 100).rounded())
        let level = SessionsCard.contextLevel(fraction)
        let tint = level.tint ?? .white.opacity(quiet ? 0.55 : contrast ? 0.95 : 0.75)
        HStack(spacing: 4) {
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(contrast ? 0.3 : 0.15))
                Capsule().fill(tint).frame(width: max(2, 34 * CGFloat(min(1, max(0, fraction)))))
            }
            .frame(width: 34, height: 4)
            Text(verbatim: "\(percent)%").font(.caption2.weight(.semibold)).monospacedDigit()
                .foregroundStyle(level != .quiet ? AnyShapeStyle(tint) : AnyShapeStyle(Caption.style))
        }
        .frame(minHeight: 20)
        .contentShape(Rectangle())
        .help(L("How full this session's context window is, from its status line"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Context %ld%%", percent))
    }
}

extension SessionsCard.Row.Status {
    /// The card's order: what needs the reader, what is running, what just ended, what is idle.
    var rank: Int {
        switch self {
        case .waiting: 0
        case .working: 1
        case .finished: 2
        case .idle: 3
        }
    }

    var oracleName: String {
        switch self {
        case .waiting: "waiting"
        case .working: "working"
        case .finished: "finished"
        case .idle: "idle"
        }
    }
}

extension TodoPlan {
    /// Whether any item still has its words: with titles off or the screen shared there is nothing to list.
    var hasContent: Bool { items.contains { $0.content?.isEmpty == false } }
}

private extension TodoPlan.Status {
    /// Shape first: an empty ring, a half-filled one, a tick.
    var symbol: String {
        switch self {
        case .pending: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .completed: "checkmark.circle.fill"
        }
    }

    /// Under Increase Contrast both coloured marks go white: Palette.calm and Palette.pine are under 3:1 on the
    /// lighter card and the row's wash, and the shape (half ring, tick) and the spoken status carry the difference.
    @MainActor var colour: Color {
        let contrast = AccessibilityDisplay.shared.contrast
        return switch self {
        case .pending: .secondary
        case .inProgress: contrast ? .white : Palette.calm
        case .completed: contrast ? .white : Palette.pine
        }
    }

    var spoken: String {
        switch self {
        case .pending: L("Not started")
        case .inProgress: L("In progress")
        case .completed: L("Completed")
        }
    }
}

/// The row's status symbol. A working turn's dot breathes, so "running" reads without the colour legend and a
/// stalled clock is not the only sign of life; under Reduce Motion it holds still (the word is in the row's
/// spoken value either way).
private struct StatusMark: View {
    let status: SessionsCard.Row.Status
    let symbol: String
    let colour: Color

    var body: some View {
        let image = Image(systemName: symbol).font(.caption.weight(.semibold)).foregroundStyle(colour)
        if status == .working, !AccessibilityDisplay.shared.motionReduced {
            image.symbolEffect(.pulse, options: .repeating)
        } else {
            image
        }
    }
}

/// The quiet mark on a row found without the hook (AgentSession.isDetected: the scan's rows, and the status line's):
/// the word in the caption's colour inside a dashed outline, so it reads as a note about the row rather than a
/// second chip, and says what it says in words and not by a colour. Its help is what the scan cannot know;
/// VoiceOver hears the same in the row's value and hint (`SessionRow.content`), so the mark itself is not a second
/// stop.
private struct DetectedMark: View {
    var body: some View {
        Text(L("detected"))
            .font(.system(size: 9, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(Caption.style)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .overlay(Capsule().strokeBorder(Caption.style, style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
            .help(L("Found without the hook, from the running process and its files. Whether it is working is a guess that can trail the turn by a few seconds, and a wait for your answer is not shown. The hook reports both exactly."))
            .accessibilityHidden(true)
    }
}

/// The line a card with a detected row ends on while that row's assistant has no hook of ours
/// (SessionsCard.upgradeTool): what the hook adds, and a button that opens the hook's install flow in Settings
/// (NotchActions.offerHook). The button writes nothing: the assistant's file changes only on Add there, after its
/// backup, which is the consent the app has always asked for. Cursor and Gemini CLI have no event an answer can go
/// back through, so their line leaves answering out rather than promise it. Always drawn, never on hover, and the
/// button is the whole line's height of 24 points.
private struct HookUpgradeLine: View {
    let tool: ToolID
    let offer: (ToolID) -> Void

    /// Whether this assistant's hook carries a decision back (HookVendor.decidingEvents).
    private var answers: Bool { HookVendor.vendor(for: tool).map { !$0.decidingEvents.isEmpty } ?? false }

    var body: some View {
        let contrast = AccessibilityDisplay.shared.contrast
        VStack(alignment: .leading, spacing: 2) {
            Text(answers ? L("Install the hook for exact turn ends and answering from the notch.") : L("Install the hook for exact turn ends."))
                .font(.caption)
                .foregroundStyle(Caption.style)
                .fixedSize(horizontal: false, vertical: true)
            Button { offer(tool) } label: {
                Label(L("Install the hook…"), systemImage: "arrow.down.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(contrast ? Palette.accentContrast : Palette.accent)
                    .frame(minHeight: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Opens the %@ hook in Settings › Integrations. Nothing is written until you choose Add there, and the file is backed up first.",
                    HookVendor.vendor(for: tool)?.displayName ?? tool.productName))
        }
        .padding(.top, 2)
    }
}

extension SessionsCard {
    /// How a model switch came about, in the words a switch list uses; nil for a source the hook did not name.
    static func sourceText(_ source: ModelSwitch.Source?) -> String? {
        switch source {
        case .command: L("by /model")
        case .picker: L("from the picker")
        case .sdk: L("by a client")
        case .auto: L("fell back by itself")
        case .resume: L("restored on resume")
        case nil: nil
        }
    }

    /// The kind of an auto-mode refusal, told from the shape of its reason (Denial.Kind) and never its words.
    static func denialText(_ kind: Denial.Kind) -> String {
        switch kind {
        case .rule: L("matched a rule")
        case .noVerdict: L("could not be judged")
        case .unavailable: L("classifier unavailable")
        case .other: L("refused")
        }
    }
}

extension SessionsCard.Row.Note {
    /// The oracle's word for a note.
    var oracleName: String {
        switch self {
        case .waitingForAnswer: "waitingForAnswer"
        case .doneJump: "doneJump"
        case .justFinished: "justFinished"
        case .mcpInput: "mcpInput"
        case .mayBeStuck: "mayBeStuck"
        }
    }
}

extension SessionsCard.Row.CompactionMark {
    /// The oracle's word for the mark: "compacting", or "compacted" once one is done.
    var oracleName: String {
        switch self {
        case .compacting: "compacting"
        case .compacted: "compacted"
        }
    }
}

/// The compaction beside the context gauge (PreCompact, PostCompact). While one runs: the compress symbol, which
/// breathes unless motion is reduced, and "Compacting" in the warning orange, since the gauge beside it is about to
/// be emptied and its figure with it. Once done, quietly, how many times this session has compacted while the app
/// watched; the gauge is then gone until the status line reports again, because the fill it last showed described
/// the conversation before its summary (AgentSession.contextUsed).
private struct CompactionChip: View {
    let mark: SessionsCard.Row.CompactionMark
    let now: Date

    var body: some View {
        switch mark {
        case .compacting(let auto):
            HStack(spacing: 3) {
                let symbol = Image(systemName: NotchNews.Reason.compacting.symbolName).font(.caption2.weight(.semibold)).imageScale(.small)
                if AccessibilityDisplay.shared.motionReduced { symbol } else { symbol.symbolEffect(.pulse, options: .repeating) }
                Text(L("Compacting")).font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Palette.warn)
            .padding(.horizontal, 7)
            .frame(minHeight: 20)
            .background(Capsule().fill(Palette.warn.opacity(AccessibilityDisplay.shared.contrast ? 0.3 : 0.16)))
            .help(auto ? L("Claude Code is compacting this session's context by itself: the conversation so far is being replaced by a summary")
                       : L("This session's context is being compacted, as /compact asked"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("Compacting"))
            .accessibilityValue(auto ? L("by itself") : L("as /compact asked"))
        case .compacted(let count, let last, let auto):
            let ago = ResetText.duration(max(0, now.timeIntervalSince(last)))
            HStack(spacing: 3) {
                Image(systemName: NotchNews.Reason.compacting.symbolName).font(.caption2.weight(.semibold)).imageScale(.small)
                Text(verbatim: "\(count)").font(.caption2.weight(.semibold)).monospacedDigit()
            }
            .padding(.horizontal, 7)
            .frame(minHeight: 20)
            .background(Capsule().fill(.white.opacity(AccessibilityDisplay.shared.contrast ? 0.26 : 0.14)))
            .help(count == 1 ? L("Compacted once while the app watched, %@ ago", ago) : L("Compacted %1$ld times while the app watched, last %2$@ ago", count, ago))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("Compacted"))
            .accessibilityValue(Spoken.line(count == 1 ? L("once") : L("%ld times", count), L("last %@ ago", ago),
                                            auto ? L("by itself") : L("as /compact asked")))
        }
    }
}

/// The extras line's chips laid left to right, wrapping onto another line when the row is too narrow for them all,
/// each line's chips centred on one another. A row carrying the gauge, a compaction, the model, agents, teammates, a
/// task list and denials at once is wider than the narrowest panel, and a chip pushed past the card's edge is one
/// nobody can click.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 4

    /// Each subview's frame within a width, line by line: pure, so the layout can be pinned without a view.
    static func frames(sizes: [CGSize], width: CGFloat, spacing: CGFloat, lineSpacing: CGFloat) -> [CGRect] {
        var lines: [[Int]] = []
        var current: [Int] = []
        var x: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            if !current.isEmpty, x + spacing + size.width > width {
                lines.append(current)
                current = []
                x = 0
            }
            x += (current.isEmpty ? 0 : spacing) + size.width
            current.append(index)
        }
        if !current.isEmpty { lines.append(current) }
        var frames = Array(repeating: CGRect.zero, count: sizes.count)
        var y: CGFloat = 0
        for line in lines {
            let height = line.map { sizes[$0].height }.max() ?? 0
            var x: CGFloat = 0
            for index in line {
                frames[index] = CGRect(x: x, y: y + (height - sizes[index].height) / 2, width: sizes[index].width, height: sizes[index].height)
                x += sizes[index].width + spacing
            }
            y += height + lineSpacing
        }
        return frames
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let frames = Self.frames(sizes: subviews.map { $0.sizeThatFits(.unspecified) }, width: width, spacing: spacing, lineSpacing: lineSpacing)
        let used = frames.reduce(CGRect.null) { $0.union($1) }
        guard !used.isNull else { return .zero }
        return CGSize(width: proposal.width ?? used.maxX, height: used.maxY)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let frames = Self.frames(sizes: sizes, width: bounds.width, spacing: spacing, lineSpacing: lineSpacing)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }
}
