import AppKit
import ApplicationServices
import Foundation
import os

/// What a row's plan buttons ask for (SessionsCard, UsageStore.cursorPlanAction): View Plan shows the plan on the
/// row, Open in Cursor on that preview goes to the plan itself, and Build presses Cursor's own Build.
enum CursorPlanAction: String, Sendable {
    case view, open, build
}

/// Cursor's own cards — a command waiting for Run, a mode-switch confirmation, a created plan's Build, a question
/// the agent asks — have no hook event; they exist only in Cursor's window. With *Mirror Cursor's cards* on (Preferences.cursorControl) and
/// the Accessibility permission granted, the app reads Cursor's windows through the Accessibility API, never a
/// screenshot, recognises those cards by their buttons, shows them on the session's row with the options Cursor
/// shows, and presses the one chosen. Nothing is ever pressed without re-reading the same card first, and a
/// press counts only once the card has gone, or, for a question's choice, once Cursor shows it picked.
struct CursorAXNode: Equatable, Sendable {
    var role: String
    /// A button's title (or its description, or its text children's), a static text's value.
    var label: String?
    var enabled = true
    var children: [CursorAXNode] = []
    /// Set on the group Cursor draws a command in (`AXCodeStyleGroup`), whose words are one text run each.
    var code = false
    /// The names Cursor's own page gives the element (its CSS classes, `AXDOMClassList`), read only for what sits
    /// directly inside a button: a question's choice says it is picked there and nowhere else.
    var classes: [String] = []
}

struct CursorCard: Equatable, Sendable, Identifiable {
    enum Kind: String, Sendable, CaseIterable {
        /// A shell command or MCP call waiting for Run.
        case run
        /// "Switch to Plan Mode?": Always ask, Skip, Switch.
        case modeSwitch
        /// A created plan: View Plan, Build.
        case plan
        /// A question the agent asks (its AskQuestion tool): the choices, Skip and Continue.
        case question
    }

    struct Option: Equatable, Sendable, Hashable {
        /// The button's words as Cursor shows them, its shortcut glyphs dropped.
        let label: String
        /// Child indexes from the window down to the button.
        let path: [Int]
    }

    let kind: Kind
    /// The window's title. An editor window's names the workspace; the Agents window's is always "Cursor Agents".
    let window: String
    /// The chat's name where the window states it (the Agents window's header), nil in an editor window.
    var chat: String? = nil
    /// The card's own words: the destination mode, the plan's name, the command; at most `CursorCards.headingLimit`.
    let heading: String?
    let options: [Option]
    /// One question of a question card. Cursor asks one or several on a card, each with its own choices.
    struct Question: Equatable, Sendable {
        /// The question's words, cut as a heading is; nil when it has none.
        let text: String?
        var choices: [Choice]
        /// Whether Cursor takes more than one of the choices. Its window does not say and its database does, so
        /// this is set only on a card read from there (CursorQuestions.card).
        var several = false
    }

    struct Choice: Equatable, Sendable {
        /// The choice as Cursor letters it ("A apple"), cut as a heading is.
        let label: String
        /// Child indexes from the window down to the choice's button.
        let path: [Int]
        /// Whether Cursor shows it picked.
        var picked: Bool
        /// The choice whose answer is typed ("Other..."), which is done in Cursor.
        let typed: Bool
    }

    /// Every choice of a question card as Cursor letters it ("A apple"), in its order, one question's after
    /// another's. All there is of a card that can only be shown (`questions` is then empty).
    var choices: [String] = []
    /// A question card's questions, each with its own choices. Where the card can be answered from the notch
    /// (`answerable`: Cursor's window says which choices are picked and takes a press on Continue, Cursor 3.23.12,
    /// 2026-10-05), a choice is picked with a press and the card is then sent with Continue, as in Cursor: the
    /// window does not say whether a question takes one answer or several, so the notch never sends on a pick.
    /// Where it can only be shown they are kept to be drawn, each question with its own choices, and nothing of
    /// them is pressed: with no `options` the card is not `answerable`. Empty only for a card read without them
    /// (the stand-in's older form). What is picked is not part of `id`: a card is the same card while it is
    /// being answered.
    var questions: [Question] = []
    /// Read from Cursor's own database and not from its window (CursorQuestions): the question is known wherever
    /// its window is. Its choices are picked on the notch's own card, and its Skip and Continue find Cursor's card
    /// by the question's words when they are pressed (CursorCards.place), so its choices and buttons carry no
    /// place in a window. Not part of `id`.
    var fromDatabase = false
    /// Whether a Run card is for a command, which heads it. Cursor shows the same Skip and Run for other things it
    /// wants approved, a file written outside the workspace for one, and the card then says what instead.
    var command = true
    /// A hash of everything the card says, command included and uncut, so two commands that open with the same 160
    /// characters are two cards. Of a question card, its questions and choices uncut, and not the header that counts
    /// the question being looked at. Stable for the life of the process, which is all a card's `id` is compared within.
    var fingerprint = 0

    /// Stable while the same card is on screen, and different for the next one. A question's Skip and Continue are
    /// left out: they are offered or not as its window can be read (`questions`), and a read that came back short
    /// of what says a choice is picked has still seen the same card.
    var id: String {
        [kind.rawValue, window, chat ?? "", heading ?? "", kind == .question ? "" : options.map(\.label).joined(separator: "|"),
         choices.joined(separator: "|"), String(fingerprint)].joined(separator: "\u{1F}")
    }
    /// Whether the card holds the turn until it is answered (a plan card waits for nobody).
    var blocksTurn: Bool { kind != .plan }
    /// The same card with nothing to press: its questions and their choices as words, to be answered in Cursor.
    var shownOnly: CursorCard {
        var card = CursorCard(kind: kind, window: window, chat: chat, heading: heading, options: [], fingerprint: fingerprint)
        card.choices = choices
        // For display alone: with no options the card is not `answerable`, and nothing of it is pressed.
        card.questions = questions
        card.command = command
        card.fromDatabase = fromDatabase
        return card
    }
    /// Whether a question card can be answered from the notch: it has its questions with their choices to press,
    /// and Cursor's own Continue to send them with.
    var answerable: Bool { kind == .question && !questions.isEmpty && !options.isEmpty }
    /// Whether every question on the card has a choice picked, which is when Cursor's own Continue sends them: its
    /// handler asks that of every question and does nothing before then (Cursor 3.23.12 and 3.23.23).
    var complete: Bool { questions.allSatisfy { $0.choices.contains(where: \.picked) } }
}

enum CursorCards {
    static let headingLimit = 160

    /// The buttons that make each kind of card, in Cursor's words, lowercased; and the buttons it may also carry.
    /// Checked against Cursor 3.23.12's own components and its live tree (2026-10-03): the mode card is Skip and
    /// Switch, and its "Always ask" is a menu that sets a preference (Always ask, Always run), a pop-up button and
    /// no answer, so it is never offered; the Run card is Skip, Run and, when the command can be allowlisted,
    /// Always Run; a plan's Build reads "Build Locally" where Cursor shows a separate cloud build. A plan's card is
    /// drawn two ways: in an editor window "Created Plan", the name, View Plan and Build; in the Agents window
    /// "Review Plan", the name, Minimize plan and Build, the plan itself open in a tab beside the chat.
    static let signatures: [CursorCard.Kind: (required: [Set<String>], optional: Set<String>)] = [
        .modeSwitch: ([["switch"], ["skip"]], []),
        .plan: ([buildLabels, ["view plan", "minimize plan"]], []),
        .run: ([["run"], ["skip", "reject", "deny", "cancel"]], ["always run", "allow", "always allow", "allowlist", "add to allowlist", "run always", "run everything"]),
    ]
    /// A question's card has no button but its choices (Cursor 3.23.12's live tree, 2026-10-04, the same for a
    /// question with one answer and one with several): a header that reads "Questions", the question, one button
    /// a choice titled by its letter and its words ("A apple", the last "D Other..." for an answer typed in), and
    /// "Skip" and "Continue", each plain text in a group. So it is known by those three texts beside choices
    /// lettered from A, and by no signature of buttons. A card that asks several questions holds them all, one
    /// after another, each with its choices lettered from A again (2026-10-05).
    static let questionMarks: Set<String> = ["questions", "skip", "continue"]
    /// The two things a question card is ended with, in Cursor's words, lowercased. Each is a group that takes a
    /// press, its word and its key ("Continue", "⏎") plain text inside it (2026-10-05).
    static let questionEnds: Set<String> = ["skip", "continue"]
    /// The one that sends the answers, without which a card is not answered from the notch.
    static let questionSend = "continue"
    /// How the class Cursor's page gives every choice's letter ends (`composer-questionnaire-toolbar-option-letter`),
    /// and how the one more it gives a picked choice's does (`…-option-letter-selected`, 2026-10-05). The choice
    /// says it is picked nowhere else, so a card whose letters do not carry the first is one whose picks cannot be
    /// read, and is not answered from the notch.
    static let letterClassSuffix = "-option-letter"
    static let pickedClassSuffix = "-option-letter-selected"
    /// A question card's own words, which are not the question.
    static let questionChrome: Set<String> = ["questions", "of", "skip", "esc", "continue"]
    /// The words that head a plan's card, the plan's name on the line after them.
    static let planCardLabels = ["Created Plan", "Review Plan"]
    /// A plan card's Build on this Mac. "Build in Cloud" is another thing and is never pressed.
    static let buildLabels: Set<String> = ["build", "build locally"]
    /// What the Agents window's header button reads before the chat's name.
    static let chatTitlePrefix = "Chat title."

    /// A button's words without its keyboard hint ("Switch ⌘⏎" → "Switch").
    static func normalized(_ label: String?) -> String? {
        guard let label else { return nil }
        // Letters and digits by category: CharacterSet.letters also holds marks, among them the variation
        // selector that follows a glyph such as ↩︎.
        let wordy: Set<Unicode.GeneralCategory> = [.uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .otherLetter, .modifierLetter, .decimalNumber]
        let kept = label.unicodeScalars.map { wordy.contains($0.properties.generalCategory) || $0 == " " || $0 == "-" ? Character($0) : " " }
        let words = String(kept).split(separator: " ").joined(separator: " ")
        return words.isEmpty ? nil : words
    }

    /// Every card in one window's tree: for each kind, the smallest container whose buttons carry the kind's
    /// signature. The options are the signature's buttons in the order Cursor lays them out.
    static func detect(in window: CursorAXNode, title: String) -> [CursorCard] {
        var found: [CursorCard] = []
        _ = visit(window, path: [], title: title, found: &found)
        guard !found.isEmpty, let chat = chat(in: window) else { return found }
        return found.map { card in
            var card = card
            card.chat = chat
            return card
        }
    }

    /// The chat a window is showing, where it says: the Agents window heads the chat with a button that reads
    /// "Chat title. <name>". An editor window has no such button, and its title names the workspace instead.
    static func chat(in node: CursorAXNode) -> String? {
        if node.role == "AXButton", let label = node.label, label.hasPrefix(chatTitlePrefix) {
            let name = label.dropFirst(chatTitlePrefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        }
        for child in node.children {
            if let name = chat(in: child) { return name }
        }
        return nil
    }

    private struct Gathered {
        /// `raw` is the button's words as Cursor has them, punctuation and all.
        var buttons: [(label: String, raw: String, path: [Int], enabled: Bool)] = []
        var texts: [String] = []
        /// Each command drawn in the subtree, its runs joined as Cursor lays them out.
        var commands: [String] = []
        var kinds: Set<CursorCard.Kind> = []
    }

    /// The text under a node, run by run, with nothing put between the runs.
    private static func runs(_ node: CursorAXNode) -> String {
        (node.role == "AXStaticText" ? node.label ?? "" : "") + node.children.map(runs).joined()
    }

    private static func visit(_ node: CursorAXNode, path: [Int], title: String, found: inout [CursorCard]) -> Gathered {
        var gathered = Gathered()
        if node.role == "AXButton", let label = normalized(node.label) {
            gathered.buttons.append((label, (node.label ?? label).trimmingCharacters(in: .whitespacesAndNewlines), path, node.enabled))
        } else if node.role == "AXStaticText" || node.role == "AXHeading", let text = node.label?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            gathered.texts.append(text)
        }
        if node.code {
            // "$ echo three", one run a word: the command is the line, less the prompt sign Cursor draws.
            var command = runs(node).trimmingCharacters(in: .whitespacesAndNewlines)
            if command.hasPrefix("$") { command = String(command.dropFirst()).trimmingCharacters(in: .whitespaces) }
            if !command.isEmpty { gathered.commands.append(command) }
        } else if node.role != "AXButton" {
            // A button's own text children name the button, not the card.
            for (index, child) in node.children.enumerated() {
                let sub = visit(child, path: path + [index], title: title, found: &found)
                gathered.buttons += sub.buttons
                gathered.texts += sub.texts
                gathered.commands += sub.commands
                gathered.kinds.formUnion(sub.kinds)
            }
        }
        var emitted = false
        for kind in CursorCard.Kind.allCases where !gathered.kinds.contains(kind) {
            guard let signature = signatures[kind] else { continue }
            let labels = Set(gathered.buttons.map { $0.label.lowercased() })
            guard signature.required.allSatisfy({ !$0.isDisjoint(with: labels) }) else { continue }
            let wanted = signature.required.reduce(signature.optional) { $0.union($1) }
            var seen = Set<String>()
            let options = gathered.buttons.filter { wanted.contains($0.label.lowercased()) && $0.enabled && seen.insert($0.label.lowercased()).inserted }
                .map { CursorCard.Option(label: $0.label, path: $0.path) }
            var hasher = Hasher()
            hasher.combine(gathered.commands)
            hasher.combine(gathered.texts)
            var subject = heading(kind, texts: gathered.texts, commands: gathered.commands)
            // A Run card with no command and no words of its own is an approval of something else, and the button
            // that is not one of its answers says what: "Create /path/to/file" (Cursor 3.23.12, 2026-10-04). A
            // button of one word ("Copy") names no subject. What such a card says is in its buttons, so they are
            // part of what makes it this card and not the next: two files whose paths open alike are two cards,
            // and a press re-read against one must not land on the other.
            if kind == .run, gathered.commands.isEmpty {
                hasher.combine(gathered.buttons.map(\.raw))
                if subject == nil {
                    subject = gathered.buttons.first { !wanted.contains($0.label.lowercased()) && $0.raw.contains(" ") }.flatMap { line($0.raw) }
                }
            }
            var card = CursorCard(kind: kind, window: title, heading: subject, options: options, fingerprint: hasher.finalize())
            card.command = kind != .run || !gathered.commands.isEmpty
            found.append(card)
            gathered.kinds.insert(kind)
            emitted = true
        }
        if !gathered.kinds.contains(.question), let asked = asked(in: node, path: path, gathered: gathered) {
            // What the card asks and offers and nothing that changes while it is answered: its header counts the
            // question being looked at ("1 of 2") and moves on with a pick, and the card is still the same card.
            var hasher = Hasher()
            hasher.combine(asked.whole)
            var card = CursorCard(kind: .question, window: title,
                                  heading: asked.questions.first.flatMap(\.text) ?? heading(.question, texts: gathered.texts, commands: []),
                                  options: asked.answerable ? asked.options : [], fingerprint: hasher.finalize())
            card.choices = asked.labels
            // Kept whether or not the card can be answered: one that is only shown still shows each question
            // with its own choices. What makes it answerable is its Skip and Continue, which it then has not got.
            card.questions = asked.questions
            found.append(card)
            gathered.kinds.insert(.question)
            emitted = true
        }
        // A card's buttons and words are its own: an ancestor cannot pair them with another card's.
        if emitted {
            gathered.buttons = []
            gathered.texts = []
            gathered.commands = []
        }
        return gathered
    }

    private static func heading(_ kind: CursorCard.Kind, texts: [String], commands: [String]) -> String? {
        let text: String?
        switch kind {
        case .modeSwitch:
            // Cursor writes the title as three runs: "Switch to ", the mode ("Plan Mode"), then "?".
            if let index = texts.firstIndex(where: { $0.hasPrefix("Switch to") }) {
                text = texts[index] == "Switch to" && texts.indices.contains(index + 1) ? "Switch to " + texts[index + 1] : texts[index]
            } else {
                text = texts.first
            }
        case .plan:
            if let index = texts.firstIndex(where: { text in planCardLabels.contains { text.caseInsensitiveCompare($0) == .orderedSame } }),
               texts.indices.contains(index + 1) {
                text = texts[index + 1]
            } else {
                text = texts.first
            }
        // What Run would run, not the line the model wrote to describe it ("Run echo three").
        case .run: text = commands.first ?? texts.first
        // The question, which is the first of the card's words that is not its own furniture or a number.
        case .question: text = texts.first { !questionChrome.contains($0.lowercased()) && $0.contains(where: \.isLetter) }
        }
        return text.flatMap(line)
    }

    /// One line, and a mark where there was more: a command that goes on past what is shown must not read as whole.
    static func line(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let cut = line.count > headingLimit
        return (cut ? String(line.prefix(headingLimit)) : line) + (cut || text.contains(where: \.isNewline) ? "…" : "")
    }

    /// What a question card asks, as it was read.
    private struct Asked {
        var questions: [CursorCard.Question] = []
        /// Every choice's label, in order.
        var labels: [String] = []
        /// Skip and Continue, where each is a group that could take a press.
        var options: [CursorCard.Option] = []
        /// Whether the card can be answered from the notch: Continue was found, and every choice says whether it
        /// is picked. Otherwise it is shown, as it was before 0.9.19, and answered in Cursor.
        var answerable = false
        /// Each question and each choice uncut, in order, for the card's fingerprint: two cards that differ only
        /// past what is shown of them are two cards.
        var whole: [String] = []
    }

    /// A stretch of a card between its buttons, or one of its buttons, in the order Cursor lays them out.
    private enum Block {
        /// `text` is the stretch as prose. `end` is Skip or Continue when the stretch is drawn as the group that
        /// ends a card. `question` is false for what cannot be one: the card's header and its numbering.
        case words(text: String, end: String?, question: Bool, path: [Int])
        case button(CursorAXNode, path: [Int])
    }

    private static func holdsButton(_ node: CursorAXNode) -> Bool {
        node.children.contains { $0.role == "AXButton" || holdsButton($0) }
    }

    private static func textRuns(_ node: CursorAXNode) -> [String] {
        (node.role == "AXStaticText" ? [node.label ?? ""] : []) + node.children.flatMap(textRuns)
    }

    /// A stretch's words as they read: the runs of one paragraph as Cursor lays them out, with nothing put between
    /// them (a word in bold is a run of its own), and a space between one paragraph or part and the next.
    private static func prose(_ node: CursorAXNode) -> String {
        if node.role == "AXStaticText" { return node.label ?? "" }
        let parts = node.children.map(prose)
        if node.children.allSatisfy({ $0.role == "AXStaticText" }) { return parts.joined() }
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Skip or Continue, when `node` is drawn as the group Cursor ends a question card with: a container with no
    /// button in it and nothing but that word and its key ("Continue", "⏎"; "Skip", "Esc"). A question that opens
    /// with the word is not it, and a press is checked against this again before it is made (LiveCursorUI.press).
    static func questionEnd(of node: CursorAXNode) -> String? {
        guard node.role != "AXStaticText", node.role != "AXButton", !holdsButton(node) else { return nil }
        let words = textRuns(node).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard (1...3).contains(words.count), let first = words.first, questionEnds.contains(first.lowercased()),
              words.dropFirst().allSatisfy({ !$0.contains(where: \.isLetter) || $0.lowercased() == "esc" }) else { return nil }
        return normalized(first)
    }

    /// A choice as the card shows it: one line, cut as a heading is, with a mark where there was more, so a choice
    /// that goes on past what is shown does not read as whole.
    static func choiceLabel(_ raw: String) -> String {
        line(raw) ?? raw
    }

    private static func blocks(_ node: CursorAXNode, path: [Int], into found: inout [Block]) {
        if node.role == "AXButton" {
            found.append(.button(node, path: path))
        } else if node.code || !holdsButton(node) {
            let words = textRuns(node).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !words.isEmpty else { return }
            // The header reads "Questions" and counts them; the numbering before a question holds no letter.
            let header = words.contains { $0.lowercased() == "questions" }
            found.append(.words(text: prose(node), end: questionEnd(of: node), question: !header && words.contains { $0.contains(where: \.isLetter) },
                                path: path))
        } else {
            for (index, child) in node.children.enumerated() { blocks(child, path: path + [index], into: &found) }
        }
    }

    /// The questions of a question card, when what was gathered is one: its three texts, and buttons that are its
    /// choices and nothing else, each question's lettered A, B and on in order and two or more. Every button, so
    /// that the card is the card alone: a stretch of the chat that happens to hold those three words and a lettered
    /// button or two also holds Cursor's other buttons, and is no question. A card drawn some other way is not
    /// recognised, which leaves it where it was before, in Cursor. Cursor's own letters are kept, since they are
    /// how its card names a choice.
    ///
    /// The card is then read in the order Cursor lays it out. A question is the last words before its first
    /// choice that are not the card's header or its numbering; a choice is picked when its letter, the button
    /// inside it, carries the class Cursor gives a picked one, and typed when it holds a text field; Skip and
    /// Continue are the groups of those words that come after the last choice, so the same word in a question is
    /// the question's.
    private static func asked(in node: CursorAXNode, path: [Int], gathered: Gathered) -> Asked? {
        guard questionMarks.isSubset(of: Set(gathered.texts.map { $0.lowercased() })) else { return nil }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var sizes: [Int] = []
        for button in gathered.buttons {
            guard button.raw.count > 2, button.raw.dropFirst().first == " ", let letter = button.raw.first else { return nil }
            if letter == alphabet[0] {
                sizes.append(1)
            } else {
                guard let size = sizes.last, size < alphabet.count, letter == alphabet[size] else { return nil }
                sizes[sizes.count - 1] += 1
            }
        }
        guard !sizes.isEmpty, sizes.allSatisfy({ $0 >= 2 }) else { return nil }

        var found: [Block] = []
        blocks(node, path: path, into: &found)
        guard let lastChoice = found.lastIndex(where: { if case .button = $0 { true } else { false } }) else { return nil }
        var asked = Asked()
        var question: String?
        var readable = true
        for (index, block) in found.enumerated() {
            switch block {
            case .words(let text, let end, let isQuestion, let at):
                if index > lastChoice {
                    if let end, !asked.options.contains(where: { $0.label == end }) { asked.options.append(.init(label: end, path: at)) }
                } else if isQuestion {
                    question = text
                }
            case .button(let button, let at):
                guard normalized(button.label) != nil,
                      let raw = button.label?.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
                if raw.first == alphabet[0] || asked.questions.isEmpty {
                    asked.questions.append(.init(text: question.flatMap(line), choices: []))
                    asked.whole.append(question ?? "")
                    question = nil
                }
                let letter = button.children.first { $0.role == "AXButton" }
                if !(letter?.classes.contains { $0.hasSuffix(letterClassSuffix) } ?? false) { readable = false }
                let label = choiceLabel(raw)
                asked.questions[asked.questions.count - 1].choices.append(
                    .init(label: label, path: at, picked: letter?.classes.contains { $0.hasSuffix(pickedClassSuffix) } ?? false,
                          typed: button.children.contains { $0.role == "AXTextArea" }))
                asked.labels.append(label)
                asked.whole.append(raw)
            }
        }
        guard asked.labels.count == gathered.buttons.count else { return nil }
        asked.answerable = readable && asked.options.contains { $0.label.lowercased() == questionSend }
        return asked
    }

    /// The Cursor session a card belongs to. A card that holds a turn (Run, a mode switch) belongs to a chat that is
    /// in one, so the chats on this Mac that are working or waiting are the candidates, and a single candidate is
    /// the answer whatever the window is called (a worktree's window is titled by its folder, the session by its
    /// repository). Several are narrowed by the chat's name where the window states it (the Agents window, whose
    /// title names no workspace), then by the workspace an editor window's title names (" — " separates Cursor's
    /// title parts), the latest event deciding among a workspace's chats since a card follows its chat's last sign
    /// of life by a moment. An editor window naming a workspace none of several candidates is in belongs to none
    /// of them; the Agents window is every workspace's, and there the latest event decides.
    static func session(for card: CursorCard, among sessions: [AgentSession]) -> String? {
        let candidates = candidates(for: card, among: sessions)
        if candidates.count <= 1 { return candidates.first?.id }
        if let chat = card.chat.flatMap(chatName) {
            // Cursor's own name for the chat is the row's `sessionName` (CursorChatNames); its title is a prompt's.
            let named = candidates.filter { $0.sessionName == chat || $0.title == chat }
            if named.count == 1 { return named[0].id }
        }
        let parts = Set(card.window.components(separatedBy: " — ").map { $0.trimmingCharacters(in: .whitespaces) })
        let inWorkspace = candidates.filter { $0.project.map(parts.contains) ?? false }
        if let best = inWorkspace.max(by: { $0.lastEvent < $1.lastEvent }) { return best.id }
        guard card.chat != nil || card.window == agentsWindowTitle else { return nil }
        return candidates.max(by: { $0.lastEvent < $1.lastEvent })?.id
    }

    /// The chats on this Mac a card could belong to: Cursor's, and for a card that holds a turn, the ones in a turn.
    static func candidates(for card: CursorCard, among sessions: [AgentSession]) -> [AgentSession] {
        let local = sessions.filter { $0.tool == .cursor && $0.host == nil }
        guard card.blocksTurn else { return local }
        let inTurn = local.filter { $0.isWorking || $0.isWaiting }
        return inTurn.isEmpty ? local : inTurn
    }

    /// A chat's name as a row would hold it: the header's words cleaned the way Cursor's own name for the chat is
    /// when it is read from Cursor's database (CursorChatNames.name), so the two compare equal.
    static func chatName(_ header: String) -> String? {
        Hook.title(fromPrompt: header)
    }

    /// The chats whose names are worth reading for a card: several could own it, its window names the chat, and no
    /// row carries that name yet. Empty when one candidate settles it, the window names no chat, or a row is
    /// already known by the name. With Cursor's names read for these, the card goes to the chat it is in, not to
    /// whichever was heard from last (UsageStore.cursorCardsSeen).
    static func unnamedCandidates(for card: CursorCard, among sessions: [AgentSession]) -> [AgentSession] {
        let candidates = candidates(for: card, among: sessions)
        guard candidates.count > 1, let chat = card.chat.flatMap(chatName) else { return [] }
        return candidates.contains { $0.sessionName == chat || $0.title == chat } ? [] : candidates
    }

    static let agentsWindowTitle = "Cursor Agents"

    /// A plan card's Build button, under whichever of its names Cursor shows.
    static func buildOption(of card: CursorCard) -> CursorCard.Option? {
        card.options.first { buildLabels.contains($0.label.lowercased()) }
    }

    /// The plan card for a plan named `name`, when exactly one of that name is on screen. A name that matches no
    /// card finds none, whatever else is showing: the only plan card on screen may be another chat's, and its Build
    /// is not the row's. With no name to go by (the plan file could not be read), the one plan card there is.
    static func planCard(named name: String?, in cards: [CursorCard]) -> CursorCard? {
        let plans = cards.filter { $0.kind == .plan }
        guard let name else { return plans.count == 1 ? plans[0] : nil }
        let matching = plans.filter { $0.heading == name }
        return matching.count == 1 ? matching[0] : nil
    }
}

extension CursorCards {
    /// The choice a pick may press: the one at that place on the card as it was just read, when it is the choice
    /// the notch showed there, by its words and by whether it is picked, and is not the one that is typed. Nil
    /// when the card has moved on since the notch drew it, and nothing is pressed.
    static func pickTarget(question: Int, choice: Int, shown: CursorCard, read: CursorCard) -> CursorCard.Choice? {
        guard shown.answerable, read.answerable, shown.id == read.id,
              shown.questions.indices.contains(question), read.questions.indices.contains(question),
              shown.questions[question].choices.indices.contains(choice), read.questions[question].choices.indices.contains(choice) else { return nil }
        let wanted = shown.questions[question].choices[choice], target = read.questions[question].choices[choice]
        guard target.label == wanted.label, target.picked == wanted.picked, !target.typed else { return nil }
        return target
    }

    /// Whether the choice at that place reads as picked; nil when the card no longer has it, or says nothing of picks.
    static func picked(question: Int, choice: Int, in card: CursorCard) -> Bool? {
        guard card.answerable, card.questions.indices.contains(question), card.questions[question].choices.indices.contains(choice) else { return nil }
        return card.questions[question].choices[choice].picked
    }
}

/// Finding Cursor's own card for a question the notch holds from Cursor's database (CursorQuestions).
///
/// Reading a question card whole out of a window (`asked`) asks a great deal of how Cursor draws it: its three
/// words, and no button in it but its choices. Cursor draws the question itself from Markdown, so a real one holds
/// whatever its words call for, a link or a file's name that is a button among them, and such a card was not
/// recognised at all (0.9.19, reported 2026-10-06: a question that had reached the notch from the database kept
/// *Answer in Cursor* with Cursor's window in view). The database says what is asked, so the window is not asked
/// to say it again in a shape it may not keep. It is asked where the choices are: a choice's button is found by
/// the choice's own words, which Cursor draws as plain text; the card is ended by the two groups that follow its
/// last choice; and the words drawn before each question's choices have only to hold the question's, however
/// they are laid out, which is what tells this card from another chat's with the same choices.
extension CursorCards {
    struct Placed: Equatable, Sendable {
        struct Choice: Equatable, Sendable {
            /// Child indexes from the window down to the choice's button.
            let path: [Int]
            /// Whether Cursor shows the choice picked; nil where its letter does not say (`letterClassSuffix`).
            let picked: Bool?
        }

        /// A list for each question of the card, of its choices that are not typed, in the card's order.
        var choices: [[Choice]]
        /// The groups Cursor ends its card with.
        var skip: [Int]
        var send: [Int]
    }

    /// What a window holds that a question's card is found by, in the order Cursor lays it out: its buttons, each
    /// by its words, and the groups drawn as Skip or Continue.
    private enum Mark {
        case button(label: String, node: CursorAXNode, path: [Int])
        case end(word: String, path: [Int])
    }

    /// `drawn` is the window's text outside its buttons, each run with how many marks came before it, so the
    /// words between two marks can be put together again (`place` checks a question's words against them).
    private static func marks(_ node: CursorAXNode, path: [Int], into found: inout [Mark], drawn: inout [(before: Int, words: String)]) {
        if node.role == "AXButton" {
            // A choice's letter is a button inside the choice's own, and is not a choice. The choice that is typed
            // is known by the field in it, whether or not Cursor gives it words.
            if node.label != nil || node.children.contains(where: { $0.role == "AXTextArea" }) {
                found.append(.button(label: drawnLabel(node.label ?? ""), node: node, path: path))
            }
            return
        }
        if node.role == "AXStaticText" || node.role == "AXHeading", let label = node.label, !label.isEmpty { drawn.append((found.count, label)) }
        // A group of a word and its key and nothing more is looked at closely; a window is thousands of groups.
        // A word of code that reads "skip" is a word of the question it is in, and is not drawn to take a press.
        if node.role != "AXStaticText", !node.code, (1...3).contains(node.children.count), node.children.allSatisfy({ $0.children.count <= 2 }),
           let word = questionEnd(of: node) {
            // The innermost group that reads so is the one Cursor drew to take the press.
            if let inner = node.children.firstIndex(where: { questionEnd(of: $0) != nil }) {
                marks(node.children[inner], path: path + [inner], into: &found, drawn: &drawn)
            } else {
                found.append(.end(word: word.lowercased(), path: path))
            }
            return
        }
        for (index, child) in node.children.enumerated() { marks(child, path: path + [index], into: &found, drawn: &drawn) }
    }

    /// A question's words boiled down, to compare what the database holds with what Cursor's window draws of
    /// them. Cursor draws a question from Markdown: a word in bold or a command reads the same with its marks
    /// gone, and a link shows its words and not where it goes. So a link's target is dropped, and what is left
    /// is its letters and digits alone, lowercased.
    static func essence(_ text: String) -> [Character] {
        // A link whole, its title with it, and one a card's cut fell in the middle of, which never closes.
        let bare = text.replacingOccurrences(of: #"\]\([^)]*(\)|$)"#, with: "]", options: .regularExpression)
        return Array(bare.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// How much of a question, as the notch's card has it, is in a stretch of what a window draws: the share of
    /// the question's runs of `questionRun` letters that the stretch holds. A run that long is the question's
    /// own, where a pair of letters is anybody's; the question whole and in order is too much to ask of
    /// Markdown drawn. A question shorter than one run is held to all of itself.
    static let questionRun = 4
    /// `fromTheStart` holds the stretch to where the question would end if it began the stretch, and one run
    /// more: the words a card draws for a question begin with that question, so one whose words only turn up
    /// further on, in a longer question, is another.
    static func share(of question: String, in stretch: String, fromTheStart: Bool = false) -> Double {
        let wanted = essence(question)
        var there = essence(stretch)
        if fromTheStart { there = Array(there.prefix(wanted.count + questionRun)) }
        guard !wanted.isEmpty else { return 1 }
        guard wanted.count >= questionRun else {
            if fromTheStart { return there.starts(with: wanted) ? 1 : 0 }
            return there.count >= wanted.count && (0...(there.count - wanted.count)).contains { Array(there[$0..<($0 + wanted.count)]) == wanted } ? 1 : 0
        }
        guard there.count >= questionRun else { return 0 }
        let runs = Set((0...(there.count - questionRun)).map { String(there[$0..<($0 + questionRun)]) })
        let found = (0...(wanted.count - questionRun)).filter { runs.contains(String(wanted[$0..<($0 + questionRun)])) }.count
        return Double(found) / Double(wanted.count - questionRun + 1)
    }
    /// The share of a question's words that the words under its number must hold for the card to be its. Half:
    /// a file's path in the question may be drawn as the file's name alone, and what tells one question from
    /// another over the same choices is whole sentences, which share next to nothing.
    static let questionShare = 0.5
    /// The word that heads Cursor's question card, in its header before the first question's number.
    static let questionHeader = "questions"
    /// How many buttons a question's own words may hold before its first choice, a file's name each.
    static let questionReach = 24

    /// A button's words as the notch's card and Cursor's are compared: runs of white space as one space, since
    /// Cursor draws a choice as running text, and cut as a card cuts a choice.
    static func drawnLabel(_ label: String) -> String {
        choiceLabel(label.split(whereSeparator: \.isWhitespace).joined(separator: " "))
    }

    /// A choice's words without the letter Cursor puts before them ("A apple"): what the choice says, by which a
    /// window's card and the database's are told for the same question (CursorQuestions.same).
    static func words(ofChoice label: String) -> String {
        let line = drawnLabel(label)
        guard line.count > 2, let first = line.first, first.isLetter, first.isUppercase, line.dropFirst().first == " " else { return line }
        return String(line.dropFirst(2))
    }

    /// Where `card`, a question read from Cursor's database, is drawn in a window. The card found has to be that
    /// card whole and no other, since what is pressed on it is an answer: each of its questions in order, as
    /// Cursor numbers them ("1" and "." before the first, as its own two runs of text, then "2"); under each
    /// number the question's words, which have to begin with the question as the card has it (`share`), a button
    /// among them where the words name a file; then its choices and no others, each a button of the same letter
    /// and words, one directly after another; then the choice that is typed, which ends every question of
    /// Cursor's; and after the last question's, directly, Skip and then Continue. A card that offers the same
    /// choices for another question, one that holds this question among others, and one whose choices merely end
    /// with these, are each another chat's and none of them is found. Nil when the window does not hold all of
    /// that. A chat keeps what it has asked above what it is asking, so the last place the card is found is the
    /// one that is waiting.
    static func place(of card: CursorCard, in window: CursorAXNode) -> Placed? {
        placing(of: card, in: window).placed
    }

    /// `place`, with how many cards in the window were this one in everything but the words of a question: a
    /// count for the log, which tells a question that was not there from one that was not taken for itself.
    static func placing(of card: CursorCard, in window: CursorAXNode) -> (placed: Placed?, otherwise: Int) {
        guard card.kind == .question, !card.questions.isEmpty else { return (nil, 0) }
        var found: [Mark] = []
        var drawn: [(before: Int, words: String)] = []
        marks(window, path: [], into: &found, drawn: &drawn)
        func typed(_ node: CursorAXNode) -> Bool { node.children.contains { $0.role == "AXTextArea" } }
        /// How many runs of text, from `index`, are a question's number: "2" and ".", or "2." as one. None when
        /// they are not that number drawn directly before mark `at`.
        func numbered(_ number: Int, from index: Int, before at: Int) -> Int {
            guard index < drawn.count, drawn[index].before == at else { return 0 }
            let first = drawn[index].words.trimmingCharacters(in: .whitespaces)
            if first == "\(number)." { return 1 }
            guard first == "\(number)", index + 1 < drawn.count, drawn[index + 1].before == at,
                  drawn[index + 1].words.trimmingCharacters(in: .whitespaces) == "." else { return 0 }
            return 2
        }
        var placed: Placed?
        var otherwise = 0
        /// Whether a button is a choice of some question: it holds the button that is its letter, or the field
        /// of the one that is typed. A file's name in a question's words holds neither.
        func choice(_ node: CursorAXNode) -> Bool { typed(node) || node.children.contains { $0.role == "AXButton" } }
        starts: for start in drawn.indices where numbered(1, from: start, before: drawn[start].before) > 0 {
            var text = start
            var at = drawn[start].before
            // The first question's number follows the card's header, with nothing a press could land on between:
            // a "1." in what the chat said above a card, or in a later question's own words, begins no card.
            guard drawn[..<start].reversed().prefix(while: { $0.before == at }).contains(where: {
                $0.words.trimmingCharacters(in: .whitespaces).lowercased() == questionHeader
            }) else { continue }
            var asks = true
            var lists: [[Placed.Choice]] = []
            for (number, question) in card.questions.enumerated() {
                // The question's number, drawn directly after the typed choice of the question before.
                while text < drawn.count, drawn[text].before < at { text += 1 }
                let runs = numbered(number + 1, from: text, before: at)
                guard runs > 0 else { continue starts }
                text += runs
                // Its words: what is drawn from there to its first choice, a button among them where it stands.
                let labels = question.choices.filter { !$0.typed }.map { drawnLabel($0.label) }
                var words: [String] = []
                var buttons = 0
                gather: while true {
                    while text < drawn.count, drawn[text].before <= at {
                        words.append(drawn[text].words)
                        text += 1
                    }
                    guard at < found.count, buttons < questionReach else { continue starts }
                    switch found[at] {
                    case .end(let word, _):
                        // A word that reads as Skip or Continue here is a word of the question, a link or the
                        // question itself ("Continue"); the card's own two come after its last choice.
                        words.append(word)
                    case .button(let label, let node, _):
                        if let first = labels.first {
                            if label == first, !typed(node) { break gather }
                        } else if typed(node) {
                            break gather
                        }
                        // Another choice here is one the notch's card does not have, and the card is not this one.
                        guard !choice(node) else { continue starts }
                        words.append(label)
                    }
                    buttons += 1
                    at += 1
                }
                if let asked = question.text, share(of: asked, in: words.joined(separator: " "), fromTheStart: true) < questionShare { asks = false }
                var list: [Placed.Choice] = []
                for label in labels {
                    guard at < found.count, case .button(label, let node, let path) = found[at], !typed(node) else { continue starts }
                    let letter = node.children.first { $0.role == "AXButton" }
                    let says = letter?.classes.contains { $0.hasSuffix(letterClassSuffix) } ?? false
                    list.append(.init(path: path, picked: says ? letter?.classes.contains { $0.hasSuffix(pickedClassSuffix) } : nil))
                    at += 1
                }
                // The choice that is typed ends the question: a choice more than the card's is another question's.
                guard at < found.count, case .button(_, let node, _) = found[at], typed(node) else { continue starts }
                at += 1
                lists.append(list)
            }
            // Skip and then Continue, directly: a card above the one that is waiting, drawn without its own two,
            // is not given the pair of the card below it.
            guard at + 1 < found.count, case .end("skip", let skip) = found[at], case .end(questionSend, let send) = found[at + 1] else { continue }
            guard asks else {
                otherwise += 1
                continue
            }
            placed = Placed(choices: lists, skip: skip, send: send)
        }
        return (placed, otherwise)
    }

    /// What is pressed next on Cursor's card to make it show what the notch's card does.
    enum Step: Equatable, Sendable {
        /// A choice to press, by its place on the card (question, then choice among those not typed).
        case press(question: Int, choice: Int)
        /// Cursor's card does not say what is picked on it, so no press can be told from its opposite.
        case unread
        /// Cursor's card shows what the notch's does.
        case same
    }

    /// The next press that brings Cursor's card to the notch's. A press turns a choice over, in Cursor as on the
    /// notch, and on a question with one answer picking a choice drops the one that was picked: so a choice the
    /// notch has picked and Cursor has not is pressed first, and one Cursor still has picked that the notch has
    /// not is pressed after, each press read back before the next is decided.
    static func step(toward card: CursorCard, from placed: Placed) -> Step {
        let wanted = card.questions.map { question in question.choices.filter { !$0.typed }.map(\.picked) }
        guard wanted.count == placed.choices.count, zip(wanted, placed.choices).allSatisfy({ $0.count == $1.count }) else { return .unread }
        guard placed.choices.allSatisfy({ $0.allSatisfy { $0.picked != nil } }) else { return .unread }
        for picking in [true, false] {
            for (question, picks) in wanted.enumerated() {
                for (choice, pick) in picks.enumerated() where pick == picking && placed.choices[question][choice].picked != pick {
                    return .press(question: question, choice: choice)
                }
            }
        }
        return .same
    }
}

/// What answering a question needs of Cursor's windows: reading them, pressing in them, and asking them to come up
/// to date. The live one is Cursor's own windows through the Accessibility API (LiveCursorUI.Windows). The tests'
/// is a card that takes presses as Cursor's own does, so the pressing in `CursorAnswering` is run, press by
/// press, without a Cursor to press.
protocol CursorWindowDriving {
    associatedtype Window
    associatedtype Elements
    /// Every window of Cursor's, with its title.
    func windows() -> [(window: Window, title: String)]
    /// One read of a window: its tree, what in it a press can land on, and whether Cursor answered for all of it.
    func snapshot(_ window: Window) -> (tree: CursorAXNode, elements: Elements, whole: Bool)
    /// Presses what a read met at `path`, if it still reads as it should. Nil when the press was made; `gone`
    /// when what is there is no longer that; `refused` when it would not take a press.
    func press(_ path: [Int], in elements: Elements, reading: CursorAnswering.Reading) -> CursorPressResult?
    /// Asks Cursor to bring the window's tree up to date (LiveCursorUI.refresh), with what the last read met.
    func refresh(_ window: Window, elements: Elements?)
    /// Waits for Cursor to act on what it was asked.
    func pause()
    /// Whether a read met the window's page at all, for the log.
    func hasPage(_ elements: Elements) -> Bool
}

/// Answering a question the notch holds from Cursor's database, on Cursor's own card: find the card, bring it to
/// what the notch's shows, send it, and see it gone (CursorUIControlling.answer says what each outcome means).
enum CursorAnswering {
    /// What is about to be pressed has to read as: a choice of these words, or the card's Skip or Continue.
    enum Reading: Equatable, Sendable {
        case choice(words: String)
        case end(word: String)
    }

    /// How many times Cursor's windows are read for the card before it is given up as out of reach, Cursor
    /// asked to bring them up to date between the reads.
    static let reads = 6
    /// How many times the card is read again for a press on a choice to show, and for the card to have gone.
    static let readBacks = 6
    static let goneReads = 10
    /// How many times a card that does not say what is picked is read again before that is believed: a read
    /// Cursor fell behind on comes back short of the classes that say it.
    static let unreadReads = 2

    /// Which of the windows that hold a question's card is the one to press. Among several, the only one whose
    /// title names the card's workspace (" — " separates Cursor's title parts); with `named`, a window so titled
    /// and no other. A window that is the only one holding the card is the one, whatever it is called (a
    /// worktree's is titled by its folder, the chat by its repository), unless its title names a workspace of
    /// another chat the app is showing (`elsewhere`) and not this chat's own: that card is the other workspace's.
    /// Nil where that leaves none or more than one, and nothing is pressed.
    static func chosen(among titles: [String], workspace: String, named: Bool, elsewhere: Set<String> = []) -> Int? {
        func parts(_ title: String) -> Set<String> { Set(title.components(separatedBy: " — ").map { $0.trimmingCharacters(in: .whitespaces) }) }
        let titled = titles.indices.filter { !workspace.isEmpty && parts(titles[$0]).contains(workspace) }
        if named || titles.count > 1 { return titled.count == 1 ? titled[0] : nil }
        guard let only = titles.first else { return nil }
        return titled.isEmpty && !parts(only).isDisjoint(with: elsewhere) ? nil : 0
    }

    static func answer<Cursor: CursorWindowDriving>(_ card: CursorCard, skip: Bool, named: Bool, elsewhere: Set<String> = [],
                                                    in cursor: Cursor) -> (result: CursorPressResult, found: String) {
        typealias Held = (window: Cursor.Window, placed: CursorCards.Placed, elements: Cursor.Elements)
        func read(_ window: Cursor.Window) -> (held: Held?, elements: Cursor.Elements, whole: Bool, otherwise: Int) {
            let snapshot = cursor.snapshot(window)
            let placing = CursorCards.placing(of: card, in: snapshot.tree)
            return (placing.placed.map { (window, $0, snapshot.elements) }, snapshot.elements, snapshot.whole, placing.otherwise)
        }

        // The card may be in any window, and in one that is put away: every one is read, and asked to bring its
        // tree up to date, until one holds it. Every one each time, so that the same choices in two windows are
        // seen for what they are and not answered in whichever was read first.
        var found = "read"
        var held: Held?
        var seen = (windows: 0, pages: 0, holding: 0, otherwise: 0, whole: true)
        for attempt in 0..<reads {
            let windows = cursor.windows()
            var met: [(window: Cursor.Window, elements: Cursor.Elements)] = []
            var holding: [(held: Held, title: String)] = []
            var otherwise = 0
            var whole = true
            for (window, title) in windows {
                let one = read(window)
                if let held = one.held { holding.append((held, title)) }
                met.append((window, one.elements))
                otherwise += one.otherwise
                whole = whole && one.whole
            }
            seen = (windows.count, met.filter { cursor.hasPage($0.elements) }.count, holding.count, otherwise, whole)
            // Only on whole reads of every window: one Cursor fell behind on may be short of this chat's own
            // card, and the only window left holding one like it would be another chat's.
            if whole, let index = chosen(among: holding.map(\.title), workspace: card.window, named: named, elsewhere: elsewhere) {
                held = holding[index].held
                break
            }
            // Several windows hold it and their titles do not say which is this chat's: asking again changes nothing.
            guard holding.count < 2 || !whole, attempt + 1 < reads else { break }
            for (window, elements) in met { cursor.refresh(window, elements: elements) }
            found = "refreshed"
            cursor.pause()
        }
        // How many windows were read, how many of them had a page to ask, how many held the card, how many
        // cards had its choices under another question, and whether Cursor fell behind on the last read: what
        // tells a Cursor with no window to read from one whose window would not say, from two that both did,
        // and from a question not taken for itself.
        guard var at = held else {
            return (.gone, "none of \(seen.windows) windows, \(seen.pages) pages, \(seen.holding) holding it, \(seen.otherwise) under other words"
                + (seen.whole ? "" : ", read short"))
        }

        /// The card's window read once more, Cursor first asked to bring it up to date.
        func again() -> (held: Held?, whole: Bool) {
            cursor.refresh(at.window, elements: at.elements)
            cursor.pause()
            let one = read(at.window)
            return (one.held, one.whole)
        }
        func picks(_ placed: CursorCards.Placed) -> [[Bool?]] { placed.choices.map { $0.map(\.picked) } }

        // From here the card has been reached, and what goes wrong is a press that was not taken or did not
        // show: `refused`, and never `gone`, which says the card was not found.
        if !skip {
            // Cursor's card is brought to what the notch's shows one press at a time, each read back before the
            // next is decided: a press turns a choice over, so one made against a card that was not read is a guess.
            var presses = 0, unread = 0
            let limit = card.questions.reduce(2) { $0 + $1.choices.count }
            loop: while true {
                switch CursorCards.step(toward: card, from: at.placed) {
                case .same:
                    break loop
                case .unread:
                    unread += 1
                    guard unread <= unreadReads, let now = again().held else { return (.refused, found) }
                    at = now
                case .press(let question, let choice):
                    let wanted = card.questions[question].choices.filter { !$0.typed }[choice]
                    guard presses < limit,
                          cursor.press(at.placed.choices[question][choice].path, in: at.elements, reading: .choice(words: CursorCards.words(ofChoice: wanted.label))) == nil
                    else { return (.refused, found) }
                    presses += 1
                    var shown: Held?
                    for _ in 0..<readBacks {
                        // A read Cursor fell behind on, short of what says a choice is picked, is no sign of the press.
                        let now = again()
                        guard now.whole, let next = now.held, !picks(next.placed).joined().contains(nil) else { continue }
                        if picks(next.placed) != picks(at.placed) {
                            shown = next
                            break
                        }
                    }
                    // A press that shows nothing is the last: the next would be made without knowing what it did.
                    guard let shown else { return (.refused, found) }
                    at = shown
                }
            }
        }

        guard cursor.press(skip ? at.placed.skip : at.placed.send, in: at.elements, reading: .end(word: skip ? "skip" : CursorCards.questionSend)) == nil
        else { return (.refused, found) }
        // Gone on the second whole read running that does not find it: Cursor's chat drops out of its tree for
        // a moment as it redraws, and a card that is back on the next read was not answered.
        var missing = 0
        for _ in 0..<goneReads {
            let now = again()
            guard now.whole else { continue }
            missing = now.held == nil ? missing + 1 : 0
            if missing == 2 { return (.pressed, found) }
        }
        return (.stillShown, found)
    }
}

enum CursorPressResult: String, Sendable {
    /// Pressed, and the card went.
    case pressed
    /// Pressed, and the card is still there.
    case stillShown
    /// The card or the button was gone, or no longer the same, when re-read: nothing pressed.
    case gone
    /// The card was there and what was to be pressed would not take a press: nothing pressed.
    case refused
    /// No Accessibility permission, or Cursor is not running.
    case unavailable
}

/// Reading and pressing Cursor's cards; the live one uses the Accessibility API, tests use a fake.
protocol CursorUIControlling: Sendable {
    var trusted: Bool { get }
    func scan() -> [CursorCard]
    /// The same read with whether it was whole. Cursor's main thread answers each element within half a second or
    /// not at all, and a read it fell behind on is short of cards that are still on screen, which is not the same
    /// as a window with none (UsageStore.readCursorCards).
    func read() -> (cards: [CursorCard], whole: Bool)
    /// A read for Build, which may be the first in a while: Chromium builds its tree only once asked, so a read
    /// that finds no plan card is taken again a few times before it is believed.
    func scanForPlan() -> [CursorCard]
    func press(_ card: CursorCard, option: String) -> CursorPressResult
    /// Presses one choice of a question card, after re-reading the same card. `pressed` when Cursor then shows the
    /// choice the other way (picked, or no longer picked) or the card has gone, with the card as it now reads (nil
    /// once it has gone); `stillShown` when the press changed nothing that can be read.
    func pick(_ card: CursorCard, question: Int, choice: Int) -> (result: CursorPressResult, card: CursorCard?)
    /// The same read, with Cursor asked to bring its windows' trees up to date (LiveCursorUI.refresh): for a
    /// window that is put away, minimised or with Cursor hidden, whose tree may be the one it had when it was
    /// last on screen.
    func read(refresh: Bool) -> (cards: [CursorCard], whole: Bool)
    /// Answers a question the notch holds from Cursor's database, on Cursor's own card and where its window is:
    /// the card is found by the question's choices (CursorCards.place), its choices are pressed until it shows
    /// what `card` has picked, and Continue is pressed, or Skip alone. Cursor is never brought forward for it.
    /// `pressed` once the card has gone; `stillShown` when Continue or Skip went in and the card is still there;
    /// `gone` when the card could not be found in any window, and nothing was pressed; `refused` when it was
    /// found and does not say what is picked, or a press on it was not taken or did not show, which may leave
    /// some of the picks on Cursor's card for whoever answers it there. `found` says how the card was come by, for
    /// the oracle and the log, and holds none of its words: "read" as the window stood, "refreshed" after
    /// Cursor was asked to bring its trees up to date, and "none" with how many windows were read. With `named`
    /// the card is taken only from a window whose title names the card's workspace (`card.window`): for a
    /// question another chat is asking too, where a card found in any other window may be the other chat's.
    /// Without it a title decides between several windows that hold the card, and rules out the only one that
    /// does when it names one of `elsewhere`, the workspaces of the other chats the app is showing, and not
    /// this chat's own.
    func answer(_ card: CursorCard, skip: Bool, named: Bool, elsewhere: Set<String>) -> (result: CursorPressResult, found: String)
    /// Tells Cursor the app no longer reads its windows (Mirror Cursor's cards turned off, or the app quitting).
    func release()
}

extension CursorUIControlling {
    func scanForPlan() -> [CursorCard] { scan() }
    func read() -> (cards: [CursorCard], whole: Bool) { (scan(), true) }
    func read(refresh: Bool) -> (cards: [CursorCard], whole: Bool) { read() }
    func pick(_ card: CursorCard, question: Int, choice: Int) -> (result: CursorPressResult, card: CursorCard?) { (.unavailable, nil) }
    func answer(_ card: CursorCard, skip: Bool, named: Bool, elsewhere: Set<String>) -> (result: CursorPressResult, found: String) { (.unavailable, "none") }
    func release() {}
}

final class LiveCursorUI: CursorUIControlling, @unchecked Sendable {
    /// Cursor's tree is a whole editor; the chat's cards sit in the first few thousand nodes of a window, and an
    /// editor's text or a file tree is skipped whole.
    static let nodeBudget = 20_000
    static let depthLimit = 90
    static let skippedRoles: Set<String> = ["AXTextArea", "AXOutline", "AXScrollBar", "AXMenuBar"]

    var trusted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's own prompt for the permission; called only when the user turns the setting on.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Chromium builds its web content's tree only for a client that asks for it this way. Asking has a cost the
    /// user can see: Cursor takes it for a screen reader, and its editor shows "Screen Reader Optimized" unless
    /// `editor.accessibilitySupport` is "off" in Cursor's settings (seen on Cursor 3.23.12, 2026-10-03). So it is
    /// asked for only while Mirror Cursor's cards is on, and handed back when that goes off (`release`).
    static let treeAttribute = "AXManualAccessibility"
    private let asked = OSAllocatedUnfairLock(initialState: false)

    private func application() -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: TerminalJump.BundleID.cursor).first else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)
        if AXUIElementSetAttributeValue(element, Self.treeAttribute as CFString, kCFBooleanTrue) == .success {
            asked.withLock { $0 = true }
        }
        return element
    }

    func release() {
        guard asked.withLock({ let was = $0; $0 = false; return was }),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: TerminalJump.BundleID.cursor).first else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)
        AXUIElementSetAttributeValue(element, Self.treeAttribute as CFString, kCFBooleanFalse)
    }

    /// Each read asks Cursor to bring its windows up to date (`refresh`), so that a plan card in a window that is
    /// put away may be there by the next.
    func scanForPlan() -> [CursorCard] {
        for _ in 0..<3 {
            let cards = read(refresh: true).cards
            if cards.contains(where: { $0.kind == .plan }) { return cards }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return read(refresh: true).cards
    }

    private func windows(of app: AXUIElement) -> [AXUIElement] {
        (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    func scan() -> [CursorCard] { read().cards }

    func read() -> (cards: [CursorCard], whole: Bool) { read(refresh: false) }

    func read(refresh: Bool) -> (cards: [CursorCard], whole: Bool) {
        guard trusted, let app = application() else { return ([], true) }
        var listed: CFTypeRef?
        let health = Health()
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &listed) == .cannotComplete { health.timedOut = true }
        var cards: [CursorCard] = []
        for window in (listed as? [AXUIElement]) ?? [] {
            var budget = Self.nodeBudget
            let title = attribute(window, kAXTitleAttribute) as? String ?? ""
            let met = Pressable()
            let tree = snapshot(window, depth: 0, budget: &budget, pressable: met, health: health)
            cards += CursorCards.detect(in: tree, title: title)
            // Cursor answers the asking after this read has been taken, so it is the next read that is the fresher.
            if refresh { self.refresh(window, in: app, area: met.area) }
        }
        return (cards, !health.timedOut)
    }

    /// Whether a read met an element Cursor did not answer for in time (`kAXErrorCannotComplete`).
    private final class Health {
        var timedOut = false
    }

    /// The same card, read again: same window, same words, same buttons. Two windows on one workspace share a
    /// title, so each of that title is read until one holds the card. What is pressed is the element this very
    /// read saw the card's button in, not one found again by walking the tree a second time: Cursor's chat
    /// re-renders as it streams, and a second walk could land on the same place in another card. An element that
    /// has gone since refuses the press.
    private func locate(_ card: CursorCard, in app: AXUIElement) -> (window: AXUIElement, card: CursorCard, pressable: Pressable)? {
        for window in windows(of: app) where (attribute(window, kAXTitleAttribute) as? String ?? "") == card.window {
            var budget = Self.nodeBudget
            let pressable = Pressable()
            if let same = CursorCards.detect(in: snapshot(window, depth: 0, budget: &budget, path: [], pressable: pressable), title: card.window)
                .first(where: { $0.id == card.id }) {
                return (window, same, pressable)
            }
        }
        return nil
    }

    /// One more read of a window, with whether Cursor answered for all of it. A read it fell behind on is short of
    /// cards that are still there, so it is no proof that one has gone.
    private func cards(in window: AXUIElement, title: String) -> (cards: [CursorCard], whole: Bool) {
        var budget = Self.nodeBudget
        let health = Health()
        let cards = CursorCards.detect(in: snapshot(window, depth: 0, budget: &budget, health: health), title: title)
        return (cards, !health.timedOut)
    }

    /// The action a window's page is asked to take to bring its tree up to date (`refresh`): scrolling the page
    /// into view, which moves nothing, since the page is the whole of its window. Every element of Cursor's page
    /// takes it (the recording of 2026-10-05 lists it on each).
    static let refreshAction = "AXScrollToVisible"

    /// Asks Cursor to bring a window's tree up to date, for a window that is put away. What is known of when a
    /// tree is kept up to date, on Cursor 3.23.23 (2026-10-06): an editor window wholly covered by another app's
    /// keeps its tree up to date by itself and takes a press where it is, a line printed in its terminal and the
    /// effect of a press both showing in the very next read, so a window behind another needs nothing of this.
    /// A minimised window, or a hidden Cursor's, is the other case: nothing reached the notch from one until it
    /// came back (reported 2026-10-05), and a minimised window that Cursor is first asked about while it is
    /// minimised has no page in its tree at all, however often it is asked. Chromium works a page's tree out as it
    /// draws the page, and also when it is asked something of the page that needs it: what is at a point, and
    /// before any action on an element. So Cursor is asked what is at the middle of the window (of the
    /// application, so that a window of its own answers whatever lies over it), and the window's page (`area`,
    /// where a read has met it) is asked to scroll into view, which reaches that window's page whatever is in
    /// front of it. Both were taken by a covered window with no change to it; whether either brings a minimised
    /// window's tree up to date has not been seen. Neither brings Cursor forward, moves its pointer or its
    /// keyboard focus, or changes what its page shows. Cursor answers after this returns, so it is a later read
    /// that sees the difference.
    private func refresh(_ window: AXUIElement, in app: AXUIElement, area: AXUIElement? = nil) {
        var position: CFTypeRef?, size: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
           AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
           let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() {
            var origin = CGPoint.zero, extent = CGSize.zero
            if AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent),
               extent.width > 0, extent.height > 0 {
                var hit: AXUIElement?
                _ = AXUIElementCopyElementAtPosition(app, Float(origin.x + extent.width / 2), Float(origin.y + extent.height / 2), &hit)
            }
        }
        if let area { _ = AXUIElementPerformAction(area, Self.refreshAction as CFString) }
    }

    /// Presses `element`, and says what kept it from being pressed: an element that has gone since it was read is
    /// the card having changed, and one that is there and takes no press is a refusal.
    private func perform(_ element: AXUIElement) -> CursorPressResult? {
        switch AXUIElementPerformAction(element, kAXPressAction as CFString) {
        case .success: nil
        case .actionUnsupported, .attributeUnsupported, .notImplemented: .refused
        default: .gone
        }
    }

    func press(_ card: CursorCard, option: String) -> CursorPressResult {
        guard trusted, let app = application() else { return .unavailable }
        guard let (window, same, pressable) = locate(card, in: app), let target = same.options.first(where: { $0.label == option }),
              let element = pressable.byPath[target.path],
              CursorCards.normalized(label(of: element)) == option else { return .gone }
        if let failed = perform(element) { return failed }
        for _ in 0..<10 {
            // A window that is put away may not show the card gone until it is asked to.
            refresh(window, in: app, area: pressable.area)
            Thread.sleep(forTimeInterval: 0.25)
            let read = cards(in: window, title: card.window)
            if read.whole, !read.cards.contains(where: { $0.id == card.id }) { return .pressed }
        }
        return .stillShown
    }

    /// How many times a pick's card is read again for the choice to show the other way. Fewer than a button's
    /// ten: Cursor marks a pick within a frame, and a press that changes nothing (a question with one answer,
    /// its picked choice pressed again) holds the card's buttons for as long as this takes.
    static let pickReads = 6

    func pick(_ card: CursorCard, question: Int, choice: Int) -> (result: CursorPressResult, card: CursorCard?) {
        guard trusted, let app = application() else { return (.unavailable, nil) }
        guard let (window, same, pressable) = locate(card, in: app) else { return (.gone, nil) }
        // The card is the same card whatever is picked on it, so the choice is checked by its own words, and by
        // whether it is picked: a press turns a choice over, and one made against a card the notch showed a read
        // ago would unpick what the click meant to pick. The card as it now reads goes back in place of a press.
        guard let target = CursorCards.pickTarget(question: question, choice: choice, shown: card, read: same) else { return (.gone, same) }
        guard let element = pressable.byPath[target.path],
              label(of: element).map({ CursorCards.choiceLabel($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) == target.label
        else { return (.gone, same) }
        if let failed = perform(element) { return (failed, same) }
        var last = same
        var missing = 0
        for _ in 0..<Self.pickReads {
            refresh(window, in: app, area: pressable.area)
            Thread.sleep(forTimeInterval: 0.25)
            let read = cards(in: window, title: card.window)
            guard read.whole else { continue }
            // A card that went with the press was answered by it. Believed on the second whole read that does not
            // find it: a pick leaves the card where it is, and Cursor's chat drops out of its tree as it redraws.
            guard let now = read.cards.first(where: { $0.id == card.id }) else {
                missing += 1
                if missing == 2 { return (.pressed, nil) }
                continue
            }
            missing = 0
            last = now
            if CursorCards.picked(question: question, choice: choice, in: now) == !target.picked { return (.pressed, now) }
        }
        return (.stillShown, last)
    }

    /// Cursor's own windows, as answering a question needs them (CursorAnswering).
    private struct Windows: CursorWindowDriving {
        let ui: LiveCursorUI
        let app: AXUIElement

        func windows() -> [(window: AXUIElement, title: String)] {
            ui.windows(of: app).map { ($0, ui.attribute($0, kAXTitleAttribute) as? String ?? "") }
        }

        func snapshot(_ window: AXUIElement) -> (tree: CursorAXNode, elements: Pressable, whole: Bool) {
            var budget = LiveCursorUI.nodeBudget
            let pressable = Pressable()
            let health = Health()
            let tree = ui.snapshot(window, depth: 0, budget: &budget, path: [], pressable: pressable, health: health)
            return (tree, pressable, !health.timedOut)
        }

        /// The element this very read met there, checked once more for what it reads before it is pressed.
        func press(_ path: [Int], in elements: Pressable, reading: CursorAnswering.Reading) -> CursorPressResult? {
            guard let element = elements.byPath[path] else { return .gone }
            let label = ui.label(of: element)
            switch reading {
            case .choice(let words): guard label.map(CursorCards.words(ofChoice:)) == words else { return .gone }
            case .end(let word): guard label?.lowercased() == word else { return .gone }
            }
            return ui.perform(element)
        }

        func refresh(_ window: AXUIElement, elements: Pressable?) {
            ui.refresh(window, in: app, area: elements?.area)
        }

        func pause() {
            Thread.sleep(forTimeInterval: 0.25)
        }

        func hasPage(_ elements: Pressable) -> Bool {
            elements.area != nil
        }
    }

    func answer(_ card: CursorCard, skip: Bool, named: Bool, elsewhere: Set<String>) -> (result: CursorPressResult, found: String) {
        guard trusted, let app = application() else { return (.unavailable, "none") }
        return CursorAnswering.answer(card, skip: skip, named: named, elsewhere: elsewhere, in: Windows(ui: self, app: app))
    }

    /// What is read of each element, in one message to Cursor: every separate attribute is a round trip to
    /// Cursor's main thread, and a window is thousands of elements.
    private static let nodeAttributes = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
                                         kAXEnabledAttribute, kAXChildrenAttribute, kAXSubroleAttribute] as CFArray
    /// The same with the element's classes on Cursor's page, asked only of what sits directly inside a button: a
    /// question's choice is a button whose letter, a button inside it, is where a pick shows (CursorCards.place).
    /// Buttons hold a handful of elements between them, so it is no more messages and little more to carry.
    /// Asked for among the others it arrives as it does asked for alone (checked on Cursor 3.23.23, 2026-10-06:
    /// of a window's 1,160 elements, 640 carried classes either way).
    static let classesAttribute = "AXDOMClassList"
    private static let nestedAttributes = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
                                           kAXEnabledAttribute, kAXChildrenAttribute, kAXSubroleAttribute, classesAttribute] as CFArray
    static let codeSubrole = "AXCodeStyleGroup"
    static let pageRole = "AXWebArea"

    private struct Read {
        var role = ""
        var label: String?
        var enabled = true
        var children: [AXUIElement] = []
        var code = false
        var classes: [String] = []
    }

    /// An attribute the element lacks comes back as an error value, which is no String, Bool or array.
    private func read(_ element: AXUIElement, nested: Bool = false, health: Health? = nil) -> Read {
        var values: CFArray?
        let answered = AXUIElementCopyMultipleAttributeValues(element, nested ? Self.nestedAttributes : Self.nodeAttributes, [], &values)
        if answered == .cannotComplete { health?.timedOut = true }
        guard answered == .success, let values = values as? [Any], values.count == (nested ? 8 : 7) else { return Read() }
        var read = Read()
        if nested { read.classes = values[7] as? [String] ?? [] }
        read.role = values[0] as? String ?? ""
        read.enabled = values[4] as? Bool ?? true
        read.children = values[5] as? [AXUIElement] ?? []
        read.code = values[6] as? String == Self.codeSubrole
        let title = values[1] as? String, description = values[2] as? String, value = values[3] as? String
        if read.role == "AXStaticText" || read.role == "AXHeading" {
            read.label = value ?? title
        } else {
            read.label = [title, description].compactMap { $0 }.first { !$0.isEmpty }
        }
        return read
    }

    /// What a read met that a press could land on, by its place in the tree, kept only for a press (`press`,
    /// `pick`): the buttons, and the groups, since a question card's Skip and Continue are groups that take one.
    private final class Pressable {
        var byPath: [[Int]: AXUIElement] = [:]
        /// The window's page, the first met, which is the one the chat is drawn in (`refresh`).
        var area: AXUIElement?
    }
    private static let pressableRoles: Set<String> = ["AXButton", "AXGroup"]

    private func snapshot(_ element: AXUIElement, depth: Int, budget: inout Int, path: [Int]? = nil, pressable: Pressable? = nil,
                          nested: Bool = false, health: Health? = nil) -> CursorAXNode {
        budget -= 1
        let read = read(element, nested: nested, health: health)
        var node = CursorAXNode(role: read.role, label: nil, enabled: read.enabled, code: read.code, classes: read.classes)
        if let path, Self.pressableRoles.contains(read.role) { pressable?.byPath[path] = element }
        if read.role == Self.pageRole, let pressable, pressable.area == nil { pressable.area = element }
        guard depth < Self.depthLimit, budget > 0, !Self.skippedRoles.contains(read.role) else { return node }
        for (index, child) in read.children.enumerated() {
            guard budget > 0 else { break }
            node.children.append(snapshot(child, depth: depth + 1, budget: &budget, path: path.map { $0 + [index] }, pressable: pressable,
                                          nested: read.role == "AXButton", health: health))
        }
        node.label = read.label ?? (read.role == "AXButton" ? Self.text(in: node) : nil)
        return node
    }

    /// What a press is checked against, as `snapshot` reads it: a button's title or description, else its text
    /// children's; and for a group, Skip or Continue when it is drawn as the group that ends a question card and
    /// as nothing else (CursorCards.questionEnd), so a group that merely opens with the word is not pressed.
    private func label(of element: AXUIElement) -> String? {
        var budget = 64
        let node = snapshot(element, depth: 0, budget: &budget)
        return node.role == "AXButton" ? node.label : CursorCards.questionEnd(of: node)
    }

    private static func text(in node: CursorAXNode) -> String? {
        let words = node.children.compactMap { child in child.role == "AXStaticText" ? child.label : text(in: child) }.joined(separator: " ")
        return words.isEmpty ? nil : words
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}

/// A stand-in for Cursor's window, for the end-to-end scripts (docs/testing.md): the cards are whatever a JSON file
/// says, and a press takes its card out of the file, as Cursor's own card goes when its button is pressed. It lets
/// a run see what the app does with a card (the row, the wait, the notch opening on it and closing after it)
/// without a Cursor to draw one. `--e2e-cursor-cards <path>`, honoured only beside the `--e2e-oracle` argument and
/// only once the oracle is writing (the app delegate checks), so no ordinary launch reads cards from a file.
final class FileCursorUI: CursorUIControlling, @unchecked Sendable {
    struct Entry: Codable, Equatable {
        var kind: String
        var window: String
        var chat: String?
        var heading: String?
        var options: [String]?
        var choices: [String]?
        var command: Bool?
        /// A question card that can be answered: its questions, each with its choices. `choices` is then theirs.
        var questions: [Asked]?

        struct Asked: Codable, Equatable {
            var text: String?
            var choices: [Choice]
        }

        struct Choice: Codable, Equatable {
            var label: String
            var picked: Bool?
            var typed: Bool?
        }
    }

    private let url: URL
    private let lock = NSLock()

    init(path: String) {
        url = URL(fileURLWithPath: path)
    }

    /// The launch argument's file, when the oracle's own launch argument is there too and the oracle is writing.
    /// The environment's NOTCHMETER_ORACLE alone does not count: a variable left set must not point a launch at a file.
    static func path(arguments: [String] = CommandLine.arguments, oracleActive: Bool = Oracle.shared.isActive) -> String? {
        guard oracleActive, arguments.contains("--e2e-oracle"),
              let index = arguments.firstIndex(of: "--e2e-cursor-cards"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    var trusted: Bool { true }

    private func entries() -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    static func card(_ entry: Entry) -> CursorCard? {
        guard let kind = CursorCard.Kind(rawValue: entry.kind) else { return nil }
        let options = (entry.options ?? []).enumerated().map { CursorCard.Option(label: $1, path: [$0]) }
        var card = CursorCard(kind: kind, window: entry.window, chat: entry.chat, heading: entry.heading, options: options)
        card.choices = entry.choices ?? []
        if let questions = entry.questions {
            card.questions = questions.enumerated().map { number, question in
                CursorCard.Question(text: question.text, choices: question.choices.enumerated().map { index, choice in
                    .init(label: choice.label, path: [number, index], picked: choice.picked ?? false, typed: choice.typed ?? false)
                })
            }
            card.choices = questions.flatMap { $0.choices.map(\.label) }
        }
        card.command = entry.command ?? (kind != .run || entry.heading != nil)
        return card
    }

    func scan() -> [CursorCard] {
        lock.withLock { entries().compactMap(Self.card) }
    }

    func press(_ card: CursorCard, option: String) -> CursorPressResult {
        lock.withLock {
            var all = entries()
            guard card.options.contains(where: { $0.label == option }),
                  let index = all.firstIndex(where: { Self.card($0)?.id == card.id }) else { return .gone }
            all.remove(at: index)
            guard let data = try? JSONEncoder().encode(all), (try? data.write(to: url, options: .atomic)) != nil else { return .unavailable }
            return .pressed
        }
    }

    /// A pick turns the choice over in the file and leaves the card there, as Cursor's does until Continue.
    func pick(_ card: CursorCard, question: Int, choice: Int) -> (result: CursorPressResult, card: CursorCard?) {
        lock.withLock {
            var all = entries()
            guard let index = all.firstIndex(where: { Self.card($0)?.id == card.id }), let same = Self.card(all[index]),
                  var questions = all[index].questions else { return (.gone, nil) }
            guard CursorCards.pickTarget(question: question, choice: choice, shown: card, read: same) != nil else { return (.gone, same) }
            questions[question].choices[choice].picked = !(questions[question].choices[choice].picked ?? false)
            all[index].questions = questions
            guard let data = try? JSONEncoder().encode(all), (try? data.write(to: url, options: .atomic)) != nil else { return (.unavailable, nil) }
            return (.pressed, Self.card(all[index]))
        }
    }

    /// An answer sent from the notch's own card takes the file's card for the same question out of it, as
    /// Cursor's goes with Continue or Skip.
    func answer(_ card: CursorCard, skip: Bool, named: Bool, elsewhere: Set<String>) -> (result: CursorPressResult, found: String) {
        lock.withLock {
            var all = entries()
            guard let index = all.firstIndex(where: { entry in Self.card(entry).map { CursorQuestions.same(window: $0, database: card) } ?? false })
            else { return (.gone, "none") }
            all.remove(at: index)
            guard let data = try? JSONEncoder().encode(all), (try? data.write(to: url, options: .atomic)) != nil else { return (.unavailable, "none") }
            return (.pressed, "read")
        }
    }
}

/// View Plan: the plan file, opened in Cursor itself (its editor shows the plan with its own Build button).
enum CursorPlanOpener {
    @MainActor static func open(_ path: String) -> Bool {
        guard let url = CursorPlanFiles.allowed(path), FileManager.default.fileExists(atPath: url.path) else { return false }
        let workspace = NSWorkspace.shared
        guard let app = workspace.urlForApplication(withBundleIdentifier: TerminalJump.BundleID.cursor) else {
            return workspace.open(url)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.open([url], withApplicationAt: app, configuration: configuration)
        return true
    }

    /// Brings Cursor forward, and says whether there was a Cursor to bring.
    @MainActor @discardableResult static func activateCursor() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: TerminalJump.BundleID.cursor).first?.activate() ?? false
    }
}
