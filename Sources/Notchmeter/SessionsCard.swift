import SwiftUI

/// Every session the hooks know about, one row each (Preferences.sessionsCard): at the top of the panel while any
/// of them is working, waiting or holding a request, and between the Advice strip and the tool cards otherwise
/// (PanelLayout.sessionsLead). How many there are is the panel header's to say (PanelHeader), directly above
/// the card whenever it leads, so the card's own title line no longer repeats it. A row says what its session is
/// working on, which assistant and which terminal it runs in, how long the turn has run, and whether it is waiting
/// on the reader. What needs the reader first, then what is working, then what just finished, then idle, newest first within each; `rowCap` rows and then a count of the rest. Idle
/// rows are drawn quieter and clock their silence, not their age, and *Clear* in the header sets every one of them
/// aside (SessionTracker.dismissIdle); left alone they go by themselves after `SessionTracker.idleAfter`. A click on a row jumps to its terminal (`NotchActions.jump`, TerminalJump.swift) when the hook
/// reported one and the setting allows it; a row with nowhere to go is a row and not a button.
///
/// The card asserts only what a hook said: a title is the prompt's first line the hook sent and the store kept,
/// a terminal is the one the hook's own environment named, and the clock is the turn's own start. One
/// `TimelineView` drives every row, at a second while anything is working or waiting and a minute otherwise,
/// because a second timeline per row is a redraw per row per second for as long as the panel is open. Titles go
/// while the screen is shared (`UsageStore.hidesFigures`): a prompt's first line is the one thing here that is
/// the user's own words.
struct SessionsCard: View {
    let store: UsageStore
    let prefs: Preferences
    let actions: NotchActions
    @Environment(\.density) private var density

    static let rowCap = 6

    /// One row, computed once per tick from the session it stands for.
    struct Row: Equatable, Sendable {
        enum Status: Equatable, Sendable { case working, waiting, idle, finished }

        let id: String
        let tool: ToolID
        let title: String
        /// The assistant's name, the terminal app's short name, and the host for a remote session.
        let chips: [String]
        /// The turn's start while one runs; the last event heard once idle, so the clock reads as "quiet for".
        let since: Date
        let status: Status
        /// The second line: waiting for an answer, or done and worth a jump.
        let note: Note?
        let canJump: Bool

        enum Note: Equatable, Sendable { case waitingForAnswer, doneJump, justFinished }
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
            var chips = [session.tool.displayName]
            // Cursor's own agent runs in Cursor: one chip says it, not two.
            if let terminal = TerminalJump.displayName(bundleID: session.terminal?.bundleID), terminal != chips[0] { chips.append(terminal) }
            if let host = session.host { chips.append("@\(host)") }
            return Row(id: session.id, tool: session.tool, title: title(of: session, hideTitles: hideTitles), chips: chips,
                       since: status == .idle || status == .finished ? session.lastEvent : session.turnStarted ?? session.started,
                       status: status, note: note, canJump: canJump)
        }
        return (rows, max(0, sessions.count - rowCap))
    }

    /// The prompt's first line when the hook sent one (else the status line's session name) and the screen is not
    /// shared; else "project · branch", else the project (or host); else the assistant's name, so a row is never blank.
    static func title(of session: AgentSession, hideTitles: Bool) -> String {
        if !hideTitles, let title = session.displayTitle { return title }
        var parts: [String] = []
        if let name = session.displayName { parts.append(name) }
        if let branch = session.branch { parts.append(branch) }
        return parts.isEmpty ? session.tool.displayName : parts.joined(separator: " · ")
    }

    var body: some View {
        let sessions = store.sessions
        TimelineView(.periodic(from: .now, by: sessions.working.isEmpty && sessions.waiting.isEmpty ? 60 : 1)) { context in
            // Titles off hides them here too, whatever the tracker still holds (the store clears it, but a value can
            // never be drawn under a setting that says not to).
            let (rows, more) = Self.rows(sessions.all, hideTitles: store.hidesFigures || !prefs.sessionTitles, jump: prefs.jumpToTerminal, now: context.date)
            VStack(alignment: .leading, spacing: density.rowSpacing) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Text(L("Sessions")).font(.headline)
                    Spacer()
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
                ForEach(rows, id: \.id) { row in
                    SessionRow(row: row, now: context.date, jump: { actions.jump($0) }, session: sessions.all.first { $0.id == row.id },
                               remove: { store.dismissSession(row.id) }, removeIdle: { store.dismissIdleSessions() })
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

    /// A row holding a request keeps it: the request is answered from its own card.
    private var removable: Bool { session?.pending == nil }

    var body: some View {
        // The remove control sits beside the jump button, not inside it: a button in another button's label loses
        // its clicks to the outer one.
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
        .accessibilityAction(named: L("Remove from the list")) { if removable { remove() } }
    }

    /// The turn's clock, or while the pointer is on the row, the control that removes it (the hover's exit is
    /// debounced above, so a click that makes the panel key cannot take the button away mid-click).
    @ViewBuilder
    private var trailing: some View {
        if hovering, removable {
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L("Remove from the list; it comes back if the session does anything"))
            .accessibilityLabel(L("Remove from the list"))
        } else {
            // Already spoken as part of the row's own value (`content`), so VoiceOver does not read it twice.
            Text(clock)
                .font(.caption).foregroundStyle(row.status == .idle ? .tertiary : .secondary).monospacedDigit()
                .accessibilityHidden(true)
        }
    }

    /// A running turn's length, or how long an idle session has been quiet ("idle 12m").
    private var clock: String {
        let duration = ResetText.duration(max(0, now.timeIntervalSince(row.since)))
        return row.status == .idle ? L("idle %@", duration) : duration
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 7) {
            StatusMark(status: row.status, symbol: symbol, colour: colour)
                .frame(width: 13, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(verbatim: row.title).font(.caption).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(row.status == .idle ? .secondary : .primary)
                    ForEach(row.chips, id: \.self) { Chip(text: $0) }
                }
                if let note = row.note {
                    Text(noteText(note)).font(.caption2).foregroundStyle(noteColour(note))
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.title)
        .accessibilityValue(Spoken.line(statusText, row.chips.joined(separator: ", "), ResetText.duration(max(0, now.timeIntervalSince(row.since))),
                                        row.note.map(noteText)))
        .opacity(row.status == .idle ? 0.8 : 1)
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
        case .waitingForAnswer: Palette.accent
        case .doneJump, .justFinished: Palette.pine
        }
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
}

/// The row's status symbol. A working turn's dot breathes, so "running" reads without the colour legend and a
/// stalled clock is not the only sign of life; under Reduce Motion it holds still (the word is in the row's
/// spoken value either way).
private struct StatusMark: View {
    let status: SessionsCard.Row.Status
    let symbol: String
    let colour: Color

    var body: some View {
        let image = Image(systemName: symbol).font(.caption2.weight(.semibold)).foregroundStyle(colour)
        if status == .working, !AccessibilityDisplay.shared.motionReduced {
            image.symbolEffect(.pulse, options: .repeating)
        } else {
            image
        }
    }
}
