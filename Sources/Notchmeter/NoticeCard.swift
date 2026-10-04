import SwiftUI

/// What a glance (`SessionAttention.glance`) puts in the notch when an assistant waits for the user or a turn
/// ends: the one session and what happened to it, and nothing else. The panel opens on this card alone the way a
/// permission request opens on its own (`UsageStore.attentionNotice`, `UsageStore.panelOpenedForPrompt`), and it
/// closes by itself like a glance, so the news arrives without the whole panel crossing the screen.
struct AttentionNotice: Sendable {
    let session: AgentSession
    let event: Notifier.SessionEvent
    /// Opened for one of Cursor's own cards (AppDelegate.cursorCardStarted): opened to stay, as a request's card
    /// is, and closed when the card has been answered, here or in Cursor.
    var forCursorCard = false

    /// A wait that may not be one: Claude Code's idle reminder or a Cursor turn gone quiet (`quietNudge`). Drawn
    /// as one line rather than the full card.
    var isNudge: Bool {
        guard case .waiting(let blocking, _) = event else { return false }
        return !blocking || session.mayBeWaiting
    }
}

/// The card itself: the assistant, whether it is waiting or done, the banner's own sentence
/// (`Notifier.copy`, so the card and the notification read alike), the prompt's first line when titles are shown,
/// and a jump back to the session when there is somewhere to go.
struct NoticeCard: View {
    let notice: AttentionNotice
    /// While the screen is shared the project and the prompt's line go, as they do in the banner.
    var hideFigures = false
    var hideTitle = false
    var canJump = false
    var jump: () -> Void = {}
    /// Cursor's own cards on this session (UsageStore.cursorCards), with their buttons: a card the notch is opened
    /// on is answered on it, not from a row in the whole panel. Drawn in place of the sentence and the jump, which
    /// say less than the card does.
    var cursorCards: [CursorCard] = []
    var cursorPressing: Set<String> = []
    var cursorPress: (CursorCard, String) -> Void = { _, _ in }
    var answerInCursor: () -> Void = {}
    var cursorNote: String? = nil
    @Environment(\.density) private var density

    /// How long the card stays before it settles, unless the pointer comes in. Longer than a bare glance: there
    /// is a sentence to read.
    static let duration: TimeInterval = 6
    /// A nudge's card is one line with no sentence to read, so it settles sooner.
    static let nudgeDuration: TimeInterval = 4

    static func duration(for notice: AttentionNotice) -> TimeInterval { notice.isNudge ? nudgeDuration : duration }

    var body: some View {
        if !cursorCards.isEmpty { cards } else if notice.isNudge { nudge } else { full }
    }

    /// The session's Cursor cards under the notice's own heading: which chat, then what Cursor asks and its buttons.
    private var cards: some View {
        let copy = Notifier.copy(for: notice.event, session: notice.session, hidingFigures: hideFigures)
        let hideDetails = hideFigures || hideTitle
        return VStack(alignment: .leading, spacing: density.rowSpacing) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.caption.weight(.semibold)).foregroundStyle(Themed(colour))
                Text(copy.title).font(.caption.weight(.semibold)).foregroundStyle(Themed(colour, .text))
                if !hideFigures, let project = notice.session.displayName { Chip(text: project) }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            if !hideDetails, let title = notice.session.displayTitle {
                Text(verbatim: title).modifier(Caption()).lineLimit(1).truncationMode(.tail)
            }
            ForEach(cursorCards, id: \.id) { card in
                CursorCardView(card: card, hideDetails: hideDetails, press: { cursorPress(card, $0) },
                               pressing: cursorPressing.contains(card.id), answerInCursor: answerInCursor)
            }
            if let cursorNote {
                Text(cursorNote).font(.caption2.weight(.medium)).foregroundStyle(Caption.style)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CardBackground())
    }

    /// A nudge — a wait the session may not have stopped for — on one line: the symbol, "Cursor may be waiting",
    /// the project, and a small jump. It is a tap on the shoulder, not a request, so it takes no more room than one.
    private var nudge: some View {
        let copy = Notifier.copy(for: notice.event, session: notice.session, hidingFigures: hideFigures)
        let project = hideFigures ? nil : notice.session.displayName
        return HStack(spacing: 6) {
            Image(systemName: symbol).font(.caption.weight(.semibold)).foregroundStyle(Themed(colour))
            Text(copy.title).font(.caption.weight(.semibold)).foregroundStyle(Themed(colour, .text))
                .lineLimit(1).layoutPriority(1)
            if let project {
                Text(verbatim: project).modifier(Caption()).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if canJump {
                let title = TerminalJump.jumpTitle(notice.session.terminal)
                Button(action: jump) {
                    Image(systemName: "arrow.up.forward.app").font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Themed(.white, .text))
                .help(title)
                .accessibilityLabel(title)
            }
        }
        .accessibilityElement(children: .contain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CardBackground())
    }

    private var full: some View {
        let copy = Notifier.copy(for: notice.event, session: notice.session, hidingFigures: hideFigures)
        return VStack(alignment: .leading, spacing: density.rowSpacing) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.caption.weight(.semibold)).foregroundStyle(Themed(colour))
                // The title is words, so it takes the colour's text role: Wong's blue and the pine green are 4.0:1 on
                // black as they stand, and are lifted by the least that reaches 4.5:1 (PanelLook).
                Text(copy.title).font(.caption.weight(.semibold)).foregroundStyle(Themed(colour, .text))
                ForEach(chips, id: \.self) { Chip(text: $0) }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Spoken.line(copy.title, chips.joined(separator: ", ")))
            Text(copy.body)
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if !hideFigures, !hideTitle, let title = notice.session.displayTitle {
                Text(verbatim: title)
                    .modifier(Caption())
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            if canJump {
                // "Open Claude" for a Cowork task, which runs in the Claude app rather than a terminal.
                let title = TerminalJump.jumpTitle(notice.session.terminal)
                Button(action: jump) { Text(title).frame(maxWidth: .infinity) }
                    .buttonStyle(PromptButtonStyle(filled: true))
                    .accessibilityLabel(title)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CardBackground())
    }

    private var symbol: String {
        switch notice.event {
        case .waiting: "hand.raised.fill"
        case .finished: "checkmark.circle.fill"
        case .trouble(let trouble): NotchNews.Reason(trouble).symbolName
        }
    }

    /// A trouble takes the warning orange, which reads 9:1 on the card and is the colour a row's "may be stuck"
    /// line uses; the symbol and the sentence say which trouble it is.
    private var colour: Color {
        switch notice.event {
        case .waiting: Palette.calm
        case .finished: Palette.pine
        case .trouble: Palette.warn
        }
    }

    /// The terminal the session runs in, by the same short name the Sessions card uses.
    private var chips: [String] {
        [TerminalJump.displayName(bundleID: notice.session.terminal?.bundleID)].compactMap { $0 }
    }

    /// Whether a row for this session would be a jump: the same rule the Sessions card applies.
    static func canJump(_ session: AgentSession, enabled: Bool) -> Bool {
        enabled && session.host == nil && session.terminal.map { TerminalJump.resolve($0) != .none } == true
    }
}
