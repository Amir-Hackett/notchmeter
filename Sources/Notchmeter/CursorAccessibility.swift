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
    /// Read from Cursor's own database and not from its window (CursorQuestions): the question is known, and
    /// where its window is does not matter, but there is nothing of it to press. Not part of `id`.
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
    /// Tells Cursor the app no longer reads its windows (Mirror Cursor's cards turned off, or the app quitting).
    func release()
}

extension CursorUIControlling {
    func scanForPlan() -> [CursorCard] { scan() }
    func read() -> (cards: [CursorCard], whole: Bool) { (scan(), true) }
    func pick(_ card: CursorCard, question: Int, choice: Int) -> (result: CursorPressResult, card: CursorCard?) { (.unavailable, nil) }
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

    func scanForPlan() -> [CursorCard] {
        for _ in 0..<3 {
            let cards = scan()
            if cards.contains(where: { $0.kind == .plan }) { return cards }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return scan()
    }

    private func windows(of app: AXUIElement) -> [AXUIElement] {
        (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    func scan() -> [CursorCard] { read().cards }

    func read() -> (cards: [CursorCard], whole: Bool) {
        guard trusted, let app = application() else { return ([], true) }
        var listed: CFTypeRef?
        let health = Health()
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &listed) == .cannotComplete { health.timedOut = true }
        var cards: [CursorCard] = []
        for window in (listed as? [AXUIElement]) ?? [] {
            var budget = Self.nodeBudget
            let title = attribute(window, kAXTitleAttribute) as? String ?? ""
            let tree = snapshot(window, depth: 0, budget: &budget, health: health)
            cards += CursorCards.detect(in: tree, title: title)
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

    /// What is read of each element, in one message to Cursor: every separate attribute is a round trip to
    /// Cursor's main thread, and a window is thousands of elements.
    private static let nodeAttributes = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
                                         kAXEnabledAttribute, kAXChildrenAttribute, kAXSubroleAttribute] as CFArray
    /// The same with the element's classes on Cursor's page, asked only of what sits directly inside a button: a
    /// question's choice is a button whose letter, a button inside it, is where a pick shows (CursorCards.asked).
    /// Buttons hold a handful of elements between them, so it is no more messages and little more to carry.
    static let classesAttribute = "AXDOMClassList"
    private static let nestedAttributes = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
                                           kAXEnabledAttribute, kAXChildrenAttribute, kAXSubroleAttribute, classesAttribute] as CFArray
    static let codeSubrole = "AXCodeStyleGroup"

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
    }
    private static let pressableRoles: Set<String> = ["AXButton", "AXGroup"]

    private func snapshot(_ element: AXUIElement, depth: Int, budget: inout Int, path: [Int]? = nil, pressable: Pressable? = nil,
                          nested: Bool = false, health: Health? = nil) -> CursorAXNode {
        budget -= 1
        let read = read(element, nested: nested, health: health)
        var node = CursorAXNode(role: read.role, label: nil, enabled: read.enabled, code: read.code, classes: read.classes)
        if let path, Self.pressableRoles.contains(read.role) { pressable?.byPath[path] = element }
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
