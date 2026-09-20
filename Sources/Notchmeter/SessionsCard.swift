import SwiftUI

/// Every session the hooks know about, one row each, between the Advice strip and the tool cards
/// (Preferences.sessionsCard): what it is working on, which assistant and which terminal it runs in, how long
/// the turn has run, and whether it is waiting on the reader. Newest first, `rowCap` rows and then a count of
/// the rest. A click on a row jumps to its terminal (`NotchActions.jump`, TerminalJump.swift) when the hook
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
        /// The turn's start, or the session's when no turn has begun.
        let since: Date
        let status: Status
        /// The second line: waiting for an answer, or done and worth a jump.
        let note: Note?
        let canJump: Bool

        enum Note: Equatable, Sendable { case waitingForAnswer, doneJump, justFinished }
    }

    /// The rows for `sessions` (already newest first), and how many were left off.
    static func rows(_ sessions: [AgentSession], hideTitles: Bool, jump: Bool, now: Date) -> (rows: [Row], more: Int) {
        let rows = sessions.prefix(rowCap).map { session -> Row in
            let finished = session.finish(now: now) != nil
            let status: Row.Status = session.isWaiting ? .waiting : session.isWorking ? .working : finished ? .finished : .idle
            let canJump = jump && session.host == nil && session.terminal != nil
            let note: Row.Note? = session.pending != nil ? .waitingForAnswer : finished ? (canJump ? .doneJump : .justFinished) : nil
            var chips = [session.tool.displayName]
            if let terminal = TerminalJump.displayName(bundleID: session.terminal?.bundleID) { chips.append(terminal) }
            if let host = session.host { chips.append("@\(host)") }
            return Row(id: session.id, tool: session.tool, title: title(of: session, hideTitles: hideTitles), chips: chips,
                       since: session.turnStarted ?? session.started, status: status, note: note, canJump: canJump)
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
            let (rows, more) = Self.rows(sessions.all, hideTitles: store.hidesFigures, jump: prefs.jumpToTerminal, now: context.date)
            VStack(alignment: .leading, spacing: density.rowSpacing) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Text(L("Sessions")).font(.headline)
                    Spacer()
                    Text(sessions.count == 1 ? L("1 session") : L("%ld sessions", sessions.count))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                ForEach(rows, id: \.id) { row in
                    SessionRow(row: row, now: context.date, jump: { actions.jump($0) }, session: sessions.all.first { $0.id == row.id })
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

    var body: some View {
        if row.canJump, let session {
            Button { jump(session) } label: { content }
                .buttonStyle(.plain)
                .help(L("Jump to the terminal"))
                .accessibilityAction(named: L("Jump to the terminal")) { jump(session) }
        } else {
            content
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(colour)
                .frame(width: 13, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(verbatim: row.title).font(.caption).lineLimit(1).truncationMode(.middle)
                    ForEach(row.chips, id: \.self) { Chip(text: $0) }
                }
                if let note = row.note {
                    Text(noteText(note)).font(.caption2).foregroundStyle(noteColour(note))
                }
            }
            Spacer(minLength: 6)
            Text(ResetText.duration(max(0, now.timeIntervalSince(row.since))))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.title)
        .accessibilityValue(Spoken.line(statusText, row.chips.joined(separator: ", "), ResetText.duration(max(0, now.timeIntervalSince(row.since))),
                                        row.note.map(noteText)))
    }

    /// Colour and shape together: the tool's own colour while it works, the blue hand while it waits, a grey ring
    /// while it idles, a green tick just after it finished.
    private var symbol: String {
        switch row.status {
        case .working: "circle.fill"
        case .waiting: "hand.raised.fill"
        case .idle: "circle"
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

    private func noteColour(_ note: SessionsCard.Row.Note) -> Color {
        switch note {
        case .waitingForAnswer: Palette.calm
        case .doneJump, .justFinished: Palette.pine
        }
    }
}
