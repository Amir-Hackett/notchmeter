import SwiftUI

/// The card at the top of the panel while an assistant is holding a session for a decision (`PendingRequest`):
/// a permission to grant or refuse, with the tool's name, one line of what it wants and a bounded excerpt of it,
/// a question with its options, or (since 0.11) an MCP server's form whose every field is a choice or a yes-or-no
/// (Hook+Elicitation.swift), each value a button: a one-field form is answered by the click, a longer one is sent
/// with ⌘↩, a form with no fields is accepted with ⌘Y, and any of them declined with ⌘N. It draws the newest
/// request only; the store keeps the rest and the panel redraws as each one is answered.
///
/// Every answer leaves through `decide` (`UsageStore.decide`), addressed to the request's id: the card never
/// holds a socket or a session, and a request that ends under it (the session moved on, the hold ran out) simply
/// takes the card down. The keys are the panel's own: ⌘Y and ⌘N for a permission, ⌥⌘Y to allow it always by
/// the assistant's first suggestion (⌥⌘↓ unfolds the others, ⌥⌘2 onward), ⌘1 to ⌘9 for an option,
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
    /// Whether *Allow always* has its other suggestions unfolded, and how the chevron changes it. The store holds
    /// it (`UsageStore.unfoldedSuggestions`), not the card, so the edge layout's probe measures the card as drawn
    /// and refits the window when it unfolds, rather than clipping the rows to the folded height.
    var unfolded = false
    var setUnfolded: (Bool) -> Void = { _ in }
    @Environment(\.density) private var density
    @Environment(\.panelLook) private var look
    /// The options chosen per question, by index, while a question is being answered.
    @State private var chosen: [Int: Set<Int>] = [:]
    /// Which question of several is on screen.
    @State private var current = 0
    /// The values chosen per field of an MCP server's form, by field key, while it is being filled.
    @State private var filled: [String: ElicitationValue] = [:]

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
                if let first = Self.offered(suggestions).first {
                    alwaysAllow(first, others: Array(Self.offered(suggestions).dropFirst()))
                }
                passLink
            case .question(let questions):
                header(symbol: "bubble.left.fill", title: L("%@ asks", session.tool.displayName), chips: placeChips)
                if let question = questions.indices.contains(current) ? questions[current] : questions.last {
                    questionBody(question, of: questions.count)
                }
                passLink
            case .elicitation(let form):
                header(symbol: NotchNews.Reason.input.symbolName,
                       title: form.server.map { L("%@ asks for input", $0) } ?? L("An MCP server asks for input"), chips: placeChips)
                if !form.message.isEmpty {
                    Text(verbatim: form.message)
                        .font(.callout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                elicitationBody(form)
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
            Image(systemName: symbol).font(.caption.weight(.semibold)).foregroundStyle(Themed(Palette.calm))
            // Words in the "needs you" blue are held to 4.5:1, which Wong's blue is not on black (4.05:1): the text
            // role lifts it by the least that reads (PanelLook), and the symbol beside it keeps the blue itself.
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Themed(Palette.calm, .text))
            ForEach(chips, id: \.self) { Chip(text: $0) }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Spoken.line(title, chips.joined(separator: ", ")))
    }

    private func buttonLabel(_ text: String, key: String) -> some View {
        HStack(spacing: 6) {
            Text(text)
            Text(verbatim: key).font(.caption2.monospaced()).opacity(Self.hintOpacity(look))
        }
    }

    /// How far a shortcut's key recedes beside its answer: 0.6 on the black panel, where white at 0.6 on a button's
    /// well is 6.4:1, and 0.7 on Paper, where ink at 0.6 on the same well would be 4.0:1.
    static func hintOpacity(_ look: PanelLook) -> Double { look.theme == .paper ? 0.7 : 0.6 }

    private var passLink: some View {
        Button { decide(request.id, .pass) } label: {
            Text(L("Answer in the terminal")).font(.caption).foregroundStyle(Ink.secondary)
        }
        .buttonStyle(.plain)
        .help(L("Hands the request back to the terminal, which asks as it always has; Escape does the same."))
    }

    /// *Allow always*: a split button under Allow and Deny. Its main part answers allow with the assistant's
    /// first suggestion (⌥⌘Y), spelled out in plain words so the rule being saved is read before it is saved, not
    /// found later in a settings file; the chevron beside it, present only when there are more, unfolds the rest
    /// as buttons of their own (⌥⌘2 onward, ⌥⌘↓ to unfold). They unfold in the card rather than in a pop-up menu
    /// because the panel sits at screen-saver level, above any menu an unanchored SwiftUI `Menu` would open, and
    /// because a row in the card keeps its shortcut and its VoiceOver label like every other answer on it. ⌘Y
    /// stays plain Allow: saving a rule is the choice that outlives this call, so it takes the extra key.
    private func alwaysAllow(_ first: PendingRequest.Suggestion, others: [PendingRequest.Suggestion]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                alwaysButton(first, key: "⌥⌘Y", shortcut: "y")
                if !others.isEmpty {
                    Button {
                        // Eased out on the way in and quicker on the way out, as the rest of the panel's motion is;
                        // under Reduce Motion the rows are simply there, or gone.
                        let unfolding = !unfolded
                        if AccessibilityDisplay.shared.motionReduced {
                            setUnfolded(unfolding)
                        } else {
                            withAnimation(unfolding ? .easeOut(duration: 0.2) : .easeIn(duration: 0.12)) { setUnfolded(unfolding) }
                        }
                    } label: {
                        Image(systemName: unfolded ? "chevron.up" : "chevron.down")
                            .font(.callout.weight(.semibold))
                            .frame(width: 18)
                            .frame(maxHeight: .infinity)
                    }
                    .buttonStyle(PromptButtonStyle(filled: false))
                    .fixedSize(horizontal: true, vertical: false)
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                    .help(L("Other rules to always allow (⌥⌘↓)"))
                    .accessibilityLabel(L("Other rules to always allow (⌥⌘↓)"))
                    .accessibilityValue(unfolded ? L("Shown") : L("Hidden"))
                }
            }
            // The chevron takes the height of the phrase beside it, so the two read as one split button.
            .fixedSize(horizontal: false, vertical: true)
            if unfolded {
                ForEach(Array(others.enumerated()), id: \.offset) { offset, suggestion in
                    let number = offset + 2
                    alwaysButton(suggestion, key: "⌥⌘\(number)", shortcut: KeyEquivalent(Character("\(number)")))
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private func alwaysButton(_ suggestion: PendingRequest.Suggestion, key: String, shortcut: KeyEquivalent) -> some View {
        let phrase = Self.phrase(suggestion)
        return Button { decide(request.id, .allowAlways(suggestion: suggestion.index)) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "checkmark.shield")
                Text(verbatim: phrase)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(verbatim: key).font(.caption2.monospaced()).opacity(Self.hintOpacity(look))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(PromptButtonStyle(filled: false, leading: true))
        .keyboardShortcut(shortcut, modifiers: [.command, .option])
        // The key is spoken with the phrase, as Allow's and Deny's are with theirs.
        .help(L("%1$@ (%2$@)", phrase, key))
        .accessibilityLabel(L("%1$@ (%2$@)", phrase, key))
        .accessibilityHint(L("Allows this request and saves the rule, so it is not asked again."))
    }

    /// The suggestions the card shows, at most `suggestionsShown`: past that a rule set is better read in the
    /// terminal, which lists them all.
    static func offered(_ suggestions: [PendingRequest.Suggestion]) -> [PendingRequest.Suggestion] {
        Array(suggestions.prefix(suggestionsShown))
    }

    static let suggestionsShown = 4

    /// A suggestion in plain words: what it would allow from now on, then where Claude Code would write it
    /// (`destination`): the session only, this project for you (`.claude/settings.local.json`), this project for
    /// everyone who shares it (`.claude/settings.json`), or every project (`~/.claude/settings.json`). Rules are
    /// quoted as Claude Code writes them, so the words on the button are the words in the settings file.
    static func phrase(_ suggestion: PendingRequest.Suggestion) -> String {
        let what: String
        switch suggestion.grant {
        case .rules(let rules): what = rules.joined(separator: ", ")
        case .directories(let directories): what = L("files in %@", directories.joined(separator: ", "))
        case .acceptEdits: what = L("every file edit")
        }
        switch suggestion.place {
        case .session: return L("Allow %@ for the rest of this session", what)
        case .localSettings: return L("Always allow %@ in this project", what)
        case .projectSettings: return L("Always allow %@ in this project, for everyone", what)
        case .userSettings: return L("Always allow %@ in every project", what)
        case nil: return L("Always allow %@", what)
        }
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
                            Text(verbatim: key).font(.caption2.monospaced()).opacity(Self.hintOpacity(look))
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

    // MARK: - An MCP server's form

    /// One button of a form: the field it fills, the value it sends, its words and its key (⌘1…⌘9, numbered across
    /// the whole form in the order the fields are drawn; the form is only answerable here when that is enough).
    struct ElicitationChoice: Equatable, Sendable {
        let field: String
        let value: ElicitationValue
        let label: String
        let key: Int?
    }

    /// Every button a form draws, field by field: a choice's options as the server listed them, a yes-or-no as Yes
    /// and No.
    static func elicitationChoices(_ form: PendingRequest.Elicitation) -> [[ElicitationChoice]] {
        var number = 0
        return form.fields.map { field in
            let values: [(ElicitationValue, String)] = switch field.kind {
            case .choice(let options): options.map { (.choice($0.value), $0.label) }
            case .toggle: [(.flag(true), L("Yes")), (.flag(false), L("No"))]
            }
            return values.map { value, label in
                number += 1
                return ElicitationChoice(field: field.key, value: value, label: label, key: number <= 9 ? number : nil)
            }
        }
    }

    /// The accept the form's values make, or nil while a required field has none. Only the form's own fields go.
    static func elicitationAnswer(_ form: PendingRequest.Elicitation, filled: [String: ElicitationValue]) -> ElicitationAnswer? {
        let keys = Set(form.fields.map(\.key))
        guard form.fields.filter(\.required).allSatisfy({ filled[$0.key] != nil }) else { return nil }
        return .accept(filled.filter { keys.contains($0.key) })
    }

    /// A form of one field is answered by the click on its value, the way a single question is; a longer form is
    /// filled in and sent, and a form with no fields is a confirmation, accepted or declined.
    static func answersOnClick(_ form: PendingRequest.Elicitation) -> Bool { form.fields.count == 1 }

    @ViewBuilder
    private func elicitationBody(_ form: PendingRequest.Elicitation) -> some View {
        let choices = Self.elicitationChoices(form)
        ForEach(Array(form.fields.enumerated()), id: \.offset) { index, field in
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: field.title).font(.caption.weight(.semibold))
                    if !field.required { Text(L("optional")).modifier(Caption()) }
                }
                if let detail = field.detail {
                    Text(verbatim: detail).modifier(Caption()).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(choices[index].enumerated()), id: \.offset) { _, choice in
                    elicitationButton(choice, form: form)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(field.title)
        }
        HStack(spacing: 8) {
            Button { decide(request.id, .elicitation(.decline)) } label: { buttonLabel(L("Decline"), key: "⌘N") }
                .buttonStyle(PromptButtonStyle(filled: false))
                .keyboardShortcut("n", modifiers: .command)
                .help(L("Decline (⌘N)"))
                .accessibilityLabel(L("Decline (⌘N)"))
                .accessibilityHint(L("Tells the server no, and the tool call goes on without the input."))
            if form.fields.isEmpty {
                Button { decide(request.id, .elicitation(.accept([:]))) } label: { buttonLabel(L("Accept"), key: "⌘Y") }
                    .buttonStyle(PromptButtonStyle(filled: true))
                    .keyboardShortcut("y", modifiers: .command)
                    .help(L("Accept (⌘Y)"))
                    .accessibilityLabel(L("Accept (⌘Y)"))
            } else if !Self.answersOnClick(form) {
                let answer = Self.elicitationAnswer(form, filled: filled)
                Button { if let answer { decide(request.id, .elicitation(answer)) } } label: { buttonLabel(L("Send"), key: "⌘↩") }
                    .buttonStyle(PromptButtonStyle(filled: true))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(answer == nil)
                    .help(L("Send (⌘↩)"))
                    .accessibilityLabel(L("Send (⌘↩)"))
            }
        }
    }

    private func elicitationButton(_ choice: ElicitationChoice, form: PendingRequest.Elicitation) -> some View {
        let selected = filled[choice.field] == choice.value
        let button = Button {
            if Self.answersOnClick(form) {
                decide(request.id, .elicitation(.accept([choice.field: choice.value])))
            } else {
                filled[choice.field] = choice.value
            }
        } label: {
            HStack(spacing: 8) {
                Text(verbatim: choice.label).font(.callout.weight(.semibold))
                Spacer(minLength: 0)
                if !Self.answersOnClick(form) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.callout)
                }
                if let key = choice.key {
                    Text(verbatim: "⌘\(key)").font(.caption2.monospaced()).opacity(0.6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(PromptButtonStyle(filled: selected, leading: true))
        .accessibilityLabel(choice.label)
        .accessibilityValue(Self.answersOnClick(form) ? "" : (selected ? L("Selected") : L("Not selected")))
        return Group {
            if let key = choice.key {
                button.keyboardShortcut(KeyEquivalent(Character("\(key)")), modifiers: .command)
            } else {
                button
            }
        }
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
            // A well darker than the card on the black panel, lighter than it on Paper: the ground's colour either way.
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Themed.wash(.black, 0.35)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("Detail"))
            .accessibilityValue(lines.prefix(PromptCard.detailLinesShown).map(\.text).joined(separator: "\n"))
        }

        private func colour(_ tint: DetailLine.Tint) -> Themed {
            switch tint {
            case .plain: Themed(.white, .text)
            case .removed: Themed(Palette.danger, .text)
            case .added: Themed(Palette.pine, .text)
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
            .background(Capsule().fill(Themed.wash(.white, 0.14)))
    }
}

/// The card's own button: full width, 8 pt corners; filled white on black for the answer that goes ahead, a
/// quiet translucent well for the rest. Raised under Increase Contrast.
struct PromptButtonStyle: ButtonStyle {
    var filled: Bool
    /// Left-aligned label for an option button, centred for Allow, Deny and Send.
    var leading = false
    /// A Send with nothing chosen yet (a multi-select, an MCP form missing a required field) is drawn faded, so
    /// the filled white that means "the answer that goes ahead" is not shown on a button that cannot go.
    @Environment(\.isEnabled) private var isEnabled

    /// How much of the button is left while it is disabled: enough to read the word, plainly less than a button
    /// that goes (the 0.7 a press dips to is the nearest neighbour, and a disabled one sits well under it).
    static let disabledOpacity = 0.45

    func makeBody(configuration: Configuration) -> some View {
        let contrast = AccessibilityDisplay.shared.contrast
        return configuration.label
            .font(.callout.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: leading ? .leading : .center)
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            // The ink and the ground, so the filled answer is inverted on either face: white on black on the black
            // panel, ink with paper-coloured words on Paper.
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(filled ? Themed(.white) : Themed.wash(.white, contrast ? 0.22 : 0.1)))
            .foregroundStyle(Themed(filled ? .black : .white, .text))
            .opacity(!isEnabled ? Self.disabledOpacity : configuration.isPressed ? 0.7 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
