import SwiftUI

/// Every session the hooks know about, one row each, between the Advice strip and the tool cards
/// (Preferences.sessionsCard): what it is working on, which assistant, branch and terminal it runs in, how long
/// the turn has run, and whether it is waiting on the reader. What needs the reader first, then what is working,
/// then what just finished, then idle, newest first within each; `rowCap` rows and then a count of the rest. With
/// more than one project live the rows sit under a small header per project ("notchmeter · 2"), the projects in
/// the order of their most urgent row, so grouping never pushes a wait below something that is only working. Idle
/// rows are drawn quieter and clock their silence, not their age, and *Clear* in the header sets every one of them
/// aside (SessionTracker.dismissIdle); left alone they go by themselves after `SessionTracker.idleAfter`. A click
/// on a row jumps to its terminal (`NotchActions.jump`, TerminalJump.swift) when the hook reported one and the
/// setting allows it; a row with nowhere to go is a row and not a button.
///
/// Under the row's two lines sits what the session is carrying, each only when something reported it: a context
/// gauge from the session's own status line (never estimated), a count of running subagents, and Claude Code's
/// task list as "2/3"; the last two open in place to list what they count. With hooks installed and no session
/// yet the card stays, with one quiet line, so an empty list reads as "nothing running" and not as "not set up".
///
/// The card asserts only what a hook said: a title is the prompt's first line the hook sent and the store kept,
/// a terminal is the one the hook's own environment named, and the clock is the turn's own start. One
/// `TimelineView` drives every row, at a second while anything is working or waiting and a minute otherwise,
/// because a second timeline per row is a redraw per row per second for as long as the panel is open. Titles and
/// task text go while the screen is shared (`UsageStore.hidesFigures`): they are the user's own words, or the
/// assistant's words about the user's work.
struct SessionsCard: View {
    let store: UsageStore
    let prefs: Preferences
    let actions: NotchActions
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
        /// The assistant's name: the one chip on the title line.
        let chips: [String]
        /// The second line: the branch, the terminal or editor's short name, and the host for a remote session.
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

        enum Note: Equatable, Sendable { case waitingForAnswer, doneJump, justFinished }

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
            let note: Row.Note? = session.pending != nil ? .waitingForAnswer : finished ? (canJump ? .doneJump : .justFinished) : nil
            // Cursor's own agent runs in Cursor: one name says it, not two.
            let place = TerminalJump.displayName(bundleID: session.terminal?.bundleID).flatMap { $0 == session.tool.displayName ? nil : $0 }
            let agents = session.agents.sorted { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key }
                .map { Row.Agent(id: $0.key, since: $0.value) }
            return Row(id: session.id, tool: session.tool, title: title(of: session, hideTitles: hideTitles), chips: [session.tool.displayName],
                       branch: session.branch, place: place, host: session.host.map { "@\($0)" }, group: groupName(of: session),
                       since: status == .idle || status == .finished ? session.lastEvent : session.turnStarted ?? session.started,
                       status: status, note: note, canJump: canJump, agents: agents, contextUsed: session.contextUsed,
                       todos: hideTitles ? session.todos?.withoutContent() : session.todos)
        }
        return (rows, max(0, sessions.count - rowCap))
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

    /// What a project header calls the session: "notchmeter", "notchmeter@devbox", "@devbox"; else the assistant.
    static func groupName(of session: AgentSession) -> String {
        session.displayName ?? session.tool.displayName
    }

    /// The prompt's first line when the hook sent one (else the status line's session name) and the screen is not
    /// shared; else the project (or host); else the assistant's name, so a row is never blank. The branch is on
    /// the row's second line, so it is not repeated here.
    static func title(of session: AgentSession, hideTitles: Bool) -> String {
        if !hideTitles, let title = session.displayTitle { return title }
        return session.displayName ?? session.tool.displayName
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

    /// What the oracle's snapshot says of the card: the rows as drawn, in order, with their group, status and the
    /// counts they carry, never a title or a task's text (docs/testing.md).
    static func oracleRows(_ groups: [Group]) -> [[String: Any]] {
        groups.flatMap { group in
            group.rows.map { row -> [String: Any] in
                ["id": row.id, "group": group.name as Any, "status": row.status.oracleName, "agents": row.agents.count,
                 "context": row.contextUsed.map(Oracle.fraction) as Any,
                 "todos": row.todos.map { ["done": $0.done, "total": $0.total] } as Any]
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
            VStack(alignment: .leading, spacing: density.rowSpacing) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Text(L("Sessions")).font(.headline)
                    Spacer()
                    if sessions.count > 0 {
                        Text(sessions.count == 1 ? L("1 session") : L("%ld sessions", sessions.count))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    // Always drawn while there is something to clear, never only on hover: a panel read at a glance
                    // has no pointer on it.
                    if sessions.all.contains(where: { !$0.isWorking && !$0.isWaiting && $0.pending == nil }) {
                        Button(L("Clear")) { store.dismissIdleSessions() }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.semibold)).foregroundStyle(Palette.accent)
                            .help(L("Clear the idle sessions; each comes back if it does anything"))
                            .accessibilityLabel(L("Remove all idle sessions"))
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
                                       toggle: { toggle(row.id, $0) })
                        }
                    }
                }
                if more > 0 {
                    Text(L("+%ld more", more)).modifier(Caption())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CardBackground())
    }
}

extension SessionsCard {
    /// The two lists a row can open in place.
    enum Disclosure: String, CaseIterable, Sendable { case agents, todos }

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
                        .help(L("Jump to the terminal"))
                        .accessibilityAction(named: L("Jump to the terminal")) { jump(session) }
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
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background {
            // The row that needs the reader: a wash of the "needs you" blue and a bar down its leading edge, so it
            // is found by shape as well as by the hand in its status mark.
            if row.needsYou {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.calm.opacity(contrast ? 0.32 : 0.15))
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Palette.calm).frame(width: 3)
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

    private var hasExtras: Bool { row.contextUsed != nil || !row.agents.isEmpty || (row.todos?.total ?? 0) > 0 }

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
                .font(.caption).foregroundStyle(row.status == .idle ? .tertiary : .secondary).monospacedDigit()
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

    /// "feat/side-notch · iTerm · @devbox": whichever of the three the hook reported.
    private var placeParts: [String] { [row.place, row.host].compactMap { $0 } }

    private var content: some View {
        HStack(alignment: .top, spacing: 7) {
            StatusMark(status: row.status, symbol: symbol, colour: colour)
                .frame(width: 13, alignment: .center)
                .padding(.top, 3)
                .help(statusText)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(verbatim: row.title).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(row.status == .idle ? .secondary : .primary)
                    ForEach(row.chips, id: \.self) { Chip(text: $0).help(L("The assistant running this session")) }
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
                    Text(noteText(note)).font(.caption2.weight(.medium)).foregroundStyle(noteColour(note))
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.title)
        .accessibilityValue(Spoken.line(statusText, row.chips.joined(separator: ", "), row.branch, placeParts.joined(separator: ", "),
                                        ResetText.duration(max(0, now.timeIntervalSince(row.since))), row.note.map(noteText)))
        .opacity(row.status == .idle ? 0.8 : 1)
    }

    // MARK: The extras line

    private var extras: some View {
        HStack(spacing: 6) {
            if let used = row.contextUsed {
                ContextGauge(fraction: used)
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
            Spacer(minLength: 0)
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

    private func checklist(_ todos: TodoPlan) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(todos.items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: item.status.symbol).font(.caption2.weight(.semibold)).foregroundStyle(item.status.colour)
                    Text(verbatim: item.content ?? "").font(.caption).lineLimit(2)
                        .strikethrough(item.status == .completed)
                        .foregroundStyle(item.status == .completed ? AnyShapeStyle(Caption.style) : AnyShapeStyle(.primary))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.content ?? "")
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
        case .waiting: Palette.calm
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

    private func noteText(_ note: SessionsCard.Row.Note) -> String {
        switch note {
        case .waitingForAnswer: L("Waiting for your answer")
        case .doneJump: L("Done — click to jump")
        case .justFinished: L("Just finished")
        }
    }

    /// The waiting line is a link, so it takes the app's accent like the tool card's own "Waiting for your answer"
    /// (Palette.accent); the row's dot and symbol keep Palette.calm, the semantic "needs you" colour on signals.
    private func noteColour(_ note: SessionsCard.Row.Note) -> Color {
        switch note {
        case .waitingForAnswer: AccessibilityDisplay.shared.contrast ? Palette.accentContrast : Palette.accent
        case .doneJump, .justFinished: Palette.pine
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
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            Text(verbatim: text).font(.system(size: 10, weight: .semibold)).monospacedDigit()
            if let chevron {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
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

    var body: some View {
        let contrast = AccessibilityDisplay.shared.contrast
        let percent = Int((fraction * 100).rounded())
        let level = SessionsCard.contextLevel(fraction)
        let tint = level.tint ?? .white.opacity(contrast ? 0.95 : 0.75)
        HStack(spacing: 4) {
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(contrast ? 0.3 : 0.15))
                Capsule().fill(tint).frame(width: max(2, 34 * CGFloat(min(1, max(0, fraction)))))
            }
            .frame(width: 34, height: 4)
            Text(verbatim: "\(percent)%").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                .foregroundStyle(level == .quiet ? AnyShapeStyle(Caption.style) : AnyShapeStyle(tint))
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

    var colour: Color {
        switch self {
        case .pending: .secondary
        case .inProgress: Palette.calm
        case .completed: Palette.pine
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
