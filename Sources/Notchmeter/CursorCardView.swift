import SwiftUI

/// One of Cursor's own cards on its session's row (CursorAccessibility): what Cursor is asking, and the buttons it
/// shows, in its words and order. The primary button (Run, Switch, Build) is filled, as Cursor fills it. A question
/// shows its choices as Cursor letters them and one button that brings Cursor forward, since it is answered there
/// (CursorCard.choices says why).
struct CursorCardView: View {
    let card: CursorCard
    let hideDetails: Bool
    let press: (String) -> Void
    /// A button of this card is being pressed in Cursor: the buttons are held, in place, until the press comes back
    /// and the card leaves the row or says why it has not.
    var pressing = false
    /// Brings Cursor forward for a card answered there.
    var answerInCursor: () -> Void = {}

    static let primary: Set<String> = ["run", "switch", "build"]
    /// The choices of a question a row shows; one with more ends in a mark that there are more.
    static let choiceLimit = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: symbol).imageScale(.small)
                Text(title).fontWeight(.semibold)
            }
            .font(.caption)
            // A Run card keeps its command whatever is hidden, as the request card keeps its summary: Run and Always
            // Run are not offered to someone who cannot read what they would run.
            if !hideDetails || card.kind == .run, let heading = card.heading, heading != title {
                Text(verbatim: heading).font(.caption2).foregroundStyle(Caption.style).lineLimit(2).truncationMode(.tail)
            }
            if !hideDetails, !card.choices.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(card.choices.prefix(Self.choiceLimit).enumerated()), id: \.offset) { _, choice in
                        Text(verbatim: choice).lineLimit(1).truncationMode(.tail)
                    }
                    if card.choices.count > Self.choiceLimit { Text(verbatim: "…") }
                }
                .font(.caption2)
                .foregroundStyle(Caption.style)
            }
            HStack(spacing: 6) {
                ForEach(card.options, id: \.self) { option in
                    Button(option.label) { press(option.label) }
                        .buttonStyle(PromptButtonStyle(filled: Self.primary.contains(option.label.lowercased())))
                        .accessibilityHint(L("Presses this button on Cursor's card"))
                        .disabled(pressing)
                }
                if card.kind == .question {
                    Button(L("Answer in Cursor"), action: answerInCursor)
                        .buttonStyle(PromptButtonStyle(filled: true))
                        .accessibilityHint(L("Brings Cursor forward, where the question is answered"))
                }
            }
            .opacity(pressing ? 0.5 : 1)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Themed.wash(Palette.calm, 0.12)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private var title: String {
        switch card.kind {
        case .run: card.command ? L("Cursor is waiting to run a command") : L("Cursor is waiting for your approval")
        case .modeSwitch: hideDetails ? L("Cursor asks to switch mode") : card.heading ?? L("Cursor asks to switch mode")
        case .plan: L("Cursor's plan is ready to build")
        case .question: L("Cursor is asking a question")
        }
    }

    private var symbol: String {
        switch card.kind {
        case .run: card.command ? "terminal" : "hand.raised"
        case .modeSwitch: "arrow.left.arrow.right"
        case .plan: "list.bullet.clipboard"
        case .question: "questionmark.bubble"
        }
    }
}

/// The plan View Plan puts on its chat's row (UsageStore.planPreviews): the plan's name, Cursor's own summary of it,
/// and the way to the plan itself. Drawn as one of Cursor's cards is, since it is Cursor's plan; the rest of the
/// plan, its steps and its diagrams, is read in Cursor, which Open in Cursor brings forward as the panel closes.
struct PlanPreviewView: View {
    let preview: CursorPlanFiles.Preview
    /// The plan is ready and not yet built, so the row's Build is offered here while the preview is open.
    let canBuild: Bool
    let open: () -> Void
    let build: () -> Void

    /// A summary runs to this many lines on the row and is cut there; Cursor has the whole of it.
    static let summaryLines = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let name = preview.name {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "doc.text").imageScale(.small)
                    Text(verbatim: name).fontWeight(.semibold).lineLimit(2).truncationMode(.tail)
                }
                .font(.caption)
            }
            if let summary = preview.summary {
                Text(verbatim: summary).font(.caption2).foregroundStyle(Caption.style)
                    .lineLimit(Self.summaryLines).truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Button(L("Open in Cursor"), action: open)
                    .buttonStyle(PromptButtonStyle(filled: !canBuild))
                    .accessibilityHint(L("Open this plan in Cursor"))
                if canBuild {
                    Button(L("Build"), action: build)
                        .buttonStyle(PromptButtonStyle(filled: true))
                        .accessibilityHint(L("Press Build on this plan in Cursor"))
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Themed.wash(Palette.calm, 0.12)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(preview.name ?? L("View Plan"))
    }
}
