import SwiftUI

/// One of Cursor's own cards on its session's row (CursorAccessibility): what Cursor is asking, and the buttons it
/// shows, in its words and order. The primary button (Run, Switch, Build) is filled, as Cursor fills it. A question
/// is answered as it is in Cursor: each choice is a button that picks it, and Continue sends the answers
/// (CursorCard.questions). A question read from Cursor's database is picked on this card and put on Cursor's own
/// when it is sent; one read from Cursor's window is picked there, and shows what Cursor shows picked. One that
/// cannot be answered from here, because its words are hidden, there is no permission to press Cursor's card
/// with, or an answer could not be put on it, shows its choices and one button that brings Cursor forward.
struct CursorCardView: View {
    let card: CursorCard
    let hideDetails: Bool
    let press: (String) -> Void
    /// Picks a choice of a question card, by the question's place and the choice's.
    var pick: (Int, Int) -> Void = { _, _ in }
    /// A button of this card is being pressed in Cursor: the buttons are held, in place, until the press comes back
    /// and the card leaves the row or says why it has not.
    var pressing = false
    /// Brings Cursor forward for a card answered there.
    var answerInCursor: () -> Void = {}

    static let primary: Set<String> = ["run", "switch", "build"]
    /// The choices of a question a row shows where they are only shown; one with more ends in a mark that there
    /// are more.
    static let choiceLimit = 6
    /// The lines a question or one of its choices runs to where it is answered; Cursor has the rest.
    static let answerLines = 4

    /// Whether a question is answered here: its words may be shown, and it has its choices and Cursor's Continue
    /// to answer with (`CursorCard.answerable`: a question read from Cursor's database where there is the
    /// permission to press Cursor's card, or one read from a window that says what is picked).
    static func answersHere(_ card: CursorCard, hideDetails: Bool) -> Bool {
        card.answerable && !hideDetails
    }

    /// A choice's letter and its words apart, as a row draws them (the letter in a chip, then the words): Cursor's
    /// label is the two run together ("A apple"), which reads badly when the words open with a capital of their
    /// own ("B A second runner"). A label that is not a letter, a space and words is drawn as it is, with no letter.
    static func lettered(_ label: String) -> (letter: String?, words: String) {
        guard label.count > 2, let first = label.first, first.isLetter, first.isUppercase, label.dropFirst().first == " " else { return (nil, label) }
        return (String(first), String(label.dropFirst(2)))
    }

    /// A choice as one line of words, where it is only listed or spoken: "A. apple".
    static func listed(_ label: String) -> String {
        let parts = lettered(label)
        return [parts.letter.map { $0 + "." }, parts.words].compactMap { $0 }.joined(separator: " ")
    }

    /// Whether a question card's answers can be sent: every question on it has a choice picked. Cursor's own
    /// Continue does nothing until then (its handler asks that of every question, Cursor 3.23.12), so the notch's
    /// is held too, and is not pressed to no effect.
    static func canSend(_ card: CursorCard) -> Bool {
        card.answerable && card.complete
    }

    /// Whether one of the card's buttons is held: Continue on a question that still has a question unanswered.
    static func held(_ option: CursorCard.Option, on card: CursorCard) -> Bool {
        card.kind == .question && option.label.lowercased() == CursorCards.questionSend && !canSend(card)
    }

    /// The card's own buttons that are offered. A question's Skip and Continue only where its choices are: nobody
    /// is offered Continue on a question they cannot read. Every other card keeps its buttons whatever is hidden.
    static func offered(_ card: CursorCard, hideDetails: Bool) -> [CursorCard.Option] {
        card.kind == .question && !answersHere(card, hideDetails: hideDetails) ? [] : card.options
    }

    private var answered: Bool { Self.answersHere(card, hideDetails: hideDetails) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: symbol).imageScale(.small)
                Text(title).fontWeight(.semibold)
            }
            .font(.caption)
            // A Run card keeps its command whatever is hidden, as the request card keeps its summary: Run and Always
            // Run are not offered to someone who cannot read what they would run.
            if answered {
                questions
            } else if !hideDetails || card.kind == .run, let heading = card.heading, heading != title {
                Text(verbatim: heading).font(.caption2).foregroundStyle(Caption.style).lineLimit(2).truncationMode(.tail)
            }
            if !answered, !hideDetails, card.questions.count > 1 {
                // Several questions that are only shown (read from Cursor's database with its window out of reach,
                // or from a window that does not say what is picked): each after the first with its own words,
                // and every one's choices under it, so one question's choices do not read as another's.
                ForEach(Array(card.questions.enumerated()), id: \.offset) { number, question in
                    VStack(alignment: .leading, spacing: 1) {
                        if number > 0, let text = question.text {
                            Text(verbatim: text).lineLimit(2).truncationMode(.tail).padding(.top, 2)
                        }
                        ForEach(Array(question.choices.prefix(Self.choiceLimit).enumerated()), id: \.offset) { _, choice in
                            Text(verbatim: Self.listed(choice.label)).lineLimit(1).truncationMode(.tail)
                        }
                        if question.choices.count > Self.choiceLimit { Text(verbatim: "…") }
                    }
                    .font(.caption2)
                    .foregroundStyle(Caption.style)
                }
            } else if !answered, !hideDetails, !card.choices.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(card.choices.prefix(Self.choiceLimit).enumerated()), id: \.offset) { _, choice in
                        Text(verbatim: Self.listed(choice)).lineLimit(1).truncationMode(.tail)
                    }
                    if card.choices.count > Self.choiceLimit { Text(verbatim: "…") }
                }
                .font(.caption2)
                .foregroundStyle(Caption.style)
            }
            HStack(spacing: 6) {
                ForEach(Self.offered(card, hideDetails: hideDetails), id: \.self) { option in
                    Button(option.label) { press(option.label) }
                        .buttonStyle(PromptButtonStyle(filled: filled(option)))
                        .accessibilityHint(L("Presses this button on Cursor's card"))
                        .disabled(pressing || Self.held(option, on: card))
                }
                if card.kind == .question, !answered {
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

    /// Continue is filled once every question has a choice picked, when it can send; the others as Cursor fills them.
    private func filled(_ option: CursorCard.Option) -> Bool {
        let label = option.label.lowercased()
        if card.kind == .question { return label == CursorCards.questionSend && Self.canSend(card) }
        return Self.primary.contains(label)
    }

    /// Each question with its choices under it, in Cursor's order and words. A press on a choice picks it: on the
    /// notch's own card for a question read from Cursor's database, on Cursor's card for one read from its
    /// window, where the mark beside it is what Cursor then shows. Either way a question with one answer moves
    /// its mark and one with several keeps them. The choice that is typed is answered in Cursor.
    @ViewBuilder
    private var questions: some View {
        ForEach(Array(card.questions.enumerated()), id: \.offset) { number, question in
            VStack(alignment: .leading, spacing: 4) {
                if let text = question.text {
                    Text(verbatim: text).font(.caption.weight(.medium))
                        .lineLimit(Self.answerLines).truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(question.choices.enumerated()), id: \.offset) { index, choice in
                    let parts = Self.lettered(choice.label)
                    Button {
                        if choice.typed { answerInCursor() } else { pick(number, index) }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            // The letter stands apart as the choice's mark, and the words line up beside it
                            // however many lines they run to.
                            if let letter = parts.letter {
                                // The letter in a small badge, as Cursor's own card draws it (the owner's pick
                                // of four ways to mark a choice, 2026-10-05). The badge takes the row's ink, so
                                // it reads on a picked row and an unpicked one alike.
                                Text(verbatim: letter).font(.caption.weight(.bold))
                                    .frame(minWidth: 18, minHeight: 18)
                                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(.foreground.opacity(AccessibilityDisplay.shared.contrast ? 0.28 : 0.16)))
                            }
                            Text(verbatim: parts.words)
                                .lineLimit(Self.answerLines).truncationMode(.tail)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Image(systemName: choice.typed ? "arrow.up.forward" : choice.picked ? "checkmark.circle.fill" : "circle")
                                .imageScale(.small)
                        }
                    }
                    .buttonStyle(PromptButtonStyle(filled: choice.picked, leading: true))
                    .accessibilityLabel(Self.listed(choice.label))
                    .accessibilityValue(choice.typed ? "" : choice.picked ? L("Selected") : L("Not selected"))
                    .accessibilityHint(choice.typed ? L("Brings Cursor forward, where the question is answered")
                                       : card.fromDatabase ? L("Picks this choice; Continue sends it") : L("Picks this choice on Cursor's card"))
                    .disabled(pressing)
                }
            }
        }
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
