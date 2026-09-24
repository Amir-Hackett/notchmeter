import SwiftUI

/// What a glance (`SessionAttention.glance`) puts in the notch when an assistant waits for the user or a turn
/// ends: the one session and what happened to it, and nothing else. The panel opens on this card alone the way a
/// permission request opens on its own (`UsageStore.attentionNotice`, `UsageStore.panelOpenedForPrompt`), and it
/// closes by itself like a glance, so the news arrives without the whole panel crossing the screen.
struct AttentionNotice: Sendable {
    let session: AgentSession
    let event: Notifier.SessionEvent
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
    @Environment(\.density) private var density

    /// How long the card stays before it settles, unless the pointer comes in. Longer than a bare glance: there
    /// is a sentence to read.
    static let duration: TimeInterval = 6

    var body: some View {
        let copy = Notifier.copy(for: notice.event, session: notice.session, hidingFigures: hideFigures)
        VStack(alignment: .leading, spacing: density.rowSpacing) {
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
                Button(action: jump) { Text(L("Jump to the terminal")).frame(maxWidth: .infinity) }
                    .buttonStyle(PromptButtonStyle(filled: true))
                    .accessibilityLabel(L("Jump to the terminal"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CardBackground())
    }

    private var symbol: String {
        switch notice.event {
        case .waiting: "hand.raised.fill"
        case .finished: "checkmark.circle.fill"
        }
    }

    private var colour: Color {
        switch notice.event {
        case .waiting: Palette.calm
        case .finished: Palette.pine
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
