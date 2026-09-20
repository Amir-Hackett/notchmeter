import SwiftUI

/// The card at the top of the panel while an assistant is holding a session for a decision (`PendingRequest`):
/// a permission to grant or refuse, with the tool's name, one line of what it wants and a bounded excerpt of it,
/// or a question with its options. It draws the newest request only; the store keeps the rest and the panel
/// redraws as each one is answered.
///
/// Every answer leaves through `decide` (`UsageStore.decide`), addressed to the request's id: the card never
/// holds a socket or a session, and a request that ends under it (the session moved on, the hold ran out) simply
/// takes the card down. The keys are the panel's own: ⌘Y and ⌘N for a permission, ⌘1 to ⌘9 for an option,
/// ⌘↩ to send a multi-select, and Escape hands the request back to the terminal from the controllers' own key
/// monitor (`NotchActions.passPrompt`). They fire only while the panel is key, which `PanelKeyPolicy` grants a
/// panel with a request on it.
///
/// Everything shown here came over the socket from a process the app can name but not vouch for, so it is text
/// and nothing more: no line is a link, nothing is handed to NSWorkspace, and the excerpt is bounded twice, by
/// the hook (`Hook.detailLimit`) and by `detailLineCap` here.
struct PromptCard: View {
    let session: AgentSession
    let request: PendingRequest
    /// Figures are withheld while the screen is shared (`UsageStore.hidesFigures`); the excerpt goes with them,
    /// since a diff of the user's own code is the one thing on the panel a viewer should not see over their
    /// shoulder. The summary and the buttons stay, because the request still has to be answerable.
    var hideFigures = false
    var decide: (String, Decision) -> Void = { _, _ in }
    @Environment(\.density) private var density
    /// The options chosen per question, by index, while a question is being answered.
    @State private var chosen: [Int: Set<Int>] = [:]
    /// Which question of several is on screen.
    @State private var current = 0

    /// How many lines of the excerpt are shown before it scrolls inside a fixed frame.
    static let detailLinesShown = 8
    static let detailFrameHeight: CGFloat = 120
    /// The most lines the card will lay out at all; the hook's 4 KB cap already bounds this, but a bound the
    /// view can see is one a test can pin.
    static let detailLineCap = 200

    var body: some View {
        VStack(alignment: .leading, spacing: density.rowSpacing) {
            switch request.kind {
            case .permission(let tool, let summary, let detail, let suggestions):
                header(symbol: "hand.raised.fill", title: L("Permission request"), chips: [tool] + placeChips)
                Text(verbatim: summary)
                    .font(.callout.weight(.semibold))
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(L("Permission request"))
                    .accessibilityValue(summary)
                if let detail, !hideFigures {
                    DetailBlock(lines: Self.lines(of: detail))
                }
                if !suggestions.isEmpty {
                    suggestionChips(suggestions)
                }
                HStack(spacing: 8) {
                    Button { decide(request.id, .deny(message: nil)) } label: { buttonLabel(L("Deny"), key: "⌘N") }
                        .buttonStyle(PromptButtonStyle(filled: false))
                        .keyboardShortcut("n", modifiers: .command)
                        .help(L("Deny (⌘N)"))
                        .accessibilityLabel(L("Deny (⌘N)"))
                    Button { decide(request.id, .allow) } label: { buttonLabel(L("Allow"), key: "⌘Y") }
                        .buttonStyle(PromptButtonStyle(filled: true))
                        .keyboardShortcut("y", modifiers: .command)
                        .help(L("Allow (⌘Y)"))
                        .accessibilityLabel(L("Allow (⌘Y)"))
                }
                passLink
            case .question(let questions):
                header(symbol: "bubble.left.fill", title: L("%@ asks", session.tool.displayName), chips: placeChips)
                if let question = questions.indices.contains(current) ? questions[current] : questions.last {
                    questionBody(question, of: questions.count)
                }
                passLink
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CardBackground())
        // The chosen options belong to one request: a new one under the same card starts clean.
        .id(request.id)
    }

    /// The project (and host) the request belongs to, so two sessions asking at once can be told apart.
    private var placeChips: [String] {
        [session.displayName].compactMap { $0 }
    }

    private func header(symbol: String, title: String, chips: [String]) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.caption.weight(.semibold)).foregroundStyle(Palette.calm)
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Palette.calm)
            ForEach(chips, id: \.self) { Chip(text: $0) }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Spoken.line(title, chips.joined(separator: ", ")))
    }

    private func buttonLabel(_ text: String, key: String) -> some View {
        HStack(spacing: 6) {
            Text(text)
            Text(verbatim: key).font(.caption2.monospaced()).opacity(0.6)
        }
    }

    private var passLink: some View {
        Button { decide(request.id, .pass) } label: {
            Text(L("Answer in the terminal")).font(.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(L("Hands the request back to the terminal, which asks as it always has; Escape does the same."))
    }

    private func suggestionChips(_ suggestions: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L("Suggested rules")).modifier(Caption())
            ForEach(suggestions.prefix(3), id: \.self) { rule in
                Text(verbatim: rule).font(.caption2.monospaced()).lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white.opacity(0.1)))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("Suggested rules"))
        .accessibilityValue(suggestions.prefix(3).joined(separator: ", "))
    }

    @ViewBuilder
    private func questionBody(_ question: PendingRequest.Question, of count: Int) -> some View {
        if count > 1 {
            Text(L("Question %1$ld of %2$ld", current + 1, count)).modifier(Caption())
        }
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if !question.header.isEmpty { Chip(text: question.header) }
            Text(verbatim: question.text)
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        let picked = chosen[current] ?? []
        VStack(spacing: 6) {
            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                let key = index < 9 ? "⌘\(index + 1)" : nil
                let button = Button {
                    choose(index, in: question, of: count)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: option.label).font(.callout.weight(.semibold))
                            if let description = option.description {
                                Text(verbatim: description).font(.caption).opacity(0.75)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                        if question.multiSelect {
                            Image(systemName: picked.contains(index) ? "checkmark.circle.fill" : "circle").font(.callout)
                        }
                        if let key {
                            Text(verbatim: key).font(.caption2.monospaced()).opacity(0.6)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(PromptButtonStyle(filled: question.multiSelect && picked.contains(index), leading: true))
                .accessibilityLabel(Spoken.line(option.label, option.description))
                .accessibilityValue(question.multiSelect ? (picked.contains(index) ? L("Selected") : L("Not selected")) : "")
                if index < 9 {
                    button.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                } else {
                    button
                }
            }
        }
        if question.multiSelect {
            Button { advance(from: question, of: count) } label: { buttonLabel(L("Send"), key: "⌘↩") }
                .buttonStyle(PromptButtonStyle(filled: true))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(picked.isEmpty)
                .help(L("Send (⌘↩)"))
                .accessibilityLabel(L("Send (⌘↩)"))
        }
    }

    private func choose(_ index: Int, in question: PendingRequest.Question, of count: Int) {
        if question.multiSelect {
            var picked = chosen[current] ?? []
            if picked.contains(index) { picked.remove(index) } else { picked.insert(index) }
            chosen[current] = picked
        } else {
            chosen[current] = [index]
            advance(from: question, of: count)
        }
    }

    /// The next question, or the answer once the last one is chosen.
    private func advance(from question: PendingRequest.Question, of count: Int) {
        guard !(chosen[current] ?? []).isEmpty else { return }
        if current + 1 < count {
            current += 1
        } else if case .question(let questions) = request.kind {
            decide(request.id, .answers(Self.answers(questions: questions, chosen: chosen)))
        }
    }

    /// Question text → the chosen labels, a multi-select's joined with ", " (`Decision.answers`). A question
    /// nothing was chosen for is left out rather than answered with an empty string.
    static func answers(questions: [PendingRequest.Question], chosen: [Int: Set<Int>]) -> [String: String] {
        var answers: [String: String] = [:]
        for (index, question) in questions.enumerated() {
            let picked = (chosen[index] ?? []).sorted().filter { question.options.indices.contains($0) }
            guard !picked.isEmpty else { continue }
            answers[question.text] = picked.map { question.options[$0].label }.joined(separator: ", ")
        }
        return answers
    }

    /// The excerpt's lines, each with the tint its first two characters ask for: `- ` is what an edit removes
    /// (the vermillion), `+ ` what it adds (the green); everything else is plain. At most `detailLineCap`.
    static func lines(of detail: String) -> [DetailLine] {
        detail.split(separator: "\n", omittingEmptySubsequences: false).prefix(detailLineCap).map { line in
            let text = String(line)
            if text.hasPrefix("- ") { return DetailLine(text: text, tint: .removed) }
            if text.hasPrefix("+ ") { return DetailLine(text: text, tint: .added) }
            return DetailLine(text: text, tint: .plain)
        }
    }

    struct DetailLine: Equatable, Sendable {
        enum Tint: Equatable, Sendable { case plain, removed, added }
        let text: String
        let tint: Tint
    }

    /// The excerpt: monospaced captions, one per line, inside a darker well; past `detailLinesShown` lines it
    /// scrolls inside a frame `detailFrameHeight` tall, so a long command cannot push the buttons off the panel.
    struct DetailBlock: View {
        let lines: [DetailLine]

        var body: some View {
            let block = VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line.text)
                        .font(.caption.monospaced())
                        .foregroundStyle(colour(line.tint))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if lines.count > PromptCard.detailLinesShown {
                    ScrollView(.vertical) { block }
                        .frame(height: PromptCard.detailFrameHeight)
                } else {
                    block
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.black.opacity(0.35)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("Detail"))
            .accessibilityValue(lines.prefix(PromptCard.detailLinesShown).map(\.text).joined(separator: "\n"))
        }

        private func colour(_ tint: DetailLine.Tint) -> Color {
            switch tint {
            case .plain: .white
            case .removed: Palette.danger
            case .added: Palette.pine
            }
        }
    }
}

/// A small capsule of text: the tool, the project, a question's header.
struct Chip: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 9, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(Capsule().fill(.white.opacity(0.14)))
    }
}

/// The card's own button: full width, 8 pt corners; filled white on black for the answer that goes ahead, a
/// quiet translucent well for the rest. Raised under Increase Contrast.
struct PromptButtonStyle: ButtonStyle {
    var filled: Bool
    /// Left-aligned label for an option button, centred for Allow, Deny and Send.
    var leading = false

    func makeBody(configuration: Configuration) -> some View {
        let contrast = AccessibilityDisplay.shared.contrast
        return configuration.label
            .font(.callout.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: leading ? .leading : .center)
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(filled ? Color.white : Color.white.opacity(contrast ? 0.22 : 0.1)))
            .foregroundStyle(filled ? Color.black : Color.white)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
