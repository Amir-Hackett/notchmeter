import Foundation
import SwiftUI
import Testing
@testable import Notchmeter

/// Cursor's own cards read from a snapshot of its Accessibility tree: recognised by their buttons, never pressed
/// on a guess, and put on the right session. The trees are transcribed from Cursor 3.23.12's live windows
/// (2026-10-03), an editor window's and the Agents window's: the plan card as each draws it, the mode card waiting
/// and answered, the Run card with and without Always Run, and the Agents window's header.
@Suite struct CursorCardDetection {
    func button(_ title: String, enabled: Bool = true, _ children: [CursorAXNode] = []) -> CursorAXNode {
        CursorAXNode(role: "AXButton", label: title, enabled: enabled, children: children)
    }
    func popUp(_ title: String) -> CursorAXNode { CursorAXNode(role: "AXPopUpButton", label: title) }
    func text(_ value: String) -> CursorAXNode { CursorAXNode(role: "AXStaticText", label: value) }
    /// A command as Cursor draws it: a code-style group, the prompt sign and each word a run of its own.
    func code(_ runs: [String]) -> CursorAXNode { CursorAXNode(role: "AXGroup", label: nil, children: runs.map(text), code: true) }
    func group(_ children: [CursorAXNode]) -> CursorAXNode { CursorAXNode(role: "AXGroup", label: nil, children: children) }

    /// The plan card as Cursor's editor window drew it for a plan named "hello and ls".
    func planCard(build: String = "Build ⌘⏎") -> CursorAXNode {
        group([group([group([text("Created Plan"), text("hello and ls")]),
                      group([text("Create hello.txt with the word hi, then list the directory with ls -la.")]),
                      button("View Plan"),
                      group([button(build, [text("Build"), text("⌘⏎")]), popUp("Open menu")])])])
    }

    @Test func theModeSwitchCardOffersSkipAndSwitchAndNeverThePreferenceMenu() throws {
        // The title is three runs of text; "Always ask" opens a menu that sets a preference and answers nothing.
        let card = group([group([text("Switch to "), text("Plan Mode"), text("?"), text("User requested Plan mode before creating the plan."),
                                 CursorAXNode(role: "AXPopUpButton", label: "Always ask", children: [text("Always ask")]),
                                 button("Skip"), button("Switch ⌘⏎", [text("Switch"), text("⌘⏎")])])])
        let window = group([group([button("New Chat")]), card])
        let found = CursorCards.detect(in: window, title: "plan.md — storefront")
        #expect(found.count == 1)
        let mode = try #require(found.first)
        #expect(mode.kind == .modeSwitch)
        #expect(mode.heading == "Switch to Plan Mode", "the mode is named, not just \"Switch to\"")
        #expect(mode.options.map(\.label) == ["Skip", "Switch"], "Cursor's own words and order, the shortcut dropped")
        #expect(mode.options.last?.path == [1, 0, 6])
        #expect(mode.blocksTurn)

        // Were the preference ever a plain button, pressing it would open a menu and leave the card standing.
        let plain = group([text("Switch to Ask Mode?"), button("Always ask"), button("Skip"), button("Switch")])
        #expect(CursorCards.detect(in: plain, title: "w").first?.options.map(\.label) == ["Skip", "Switch"])
        #expect(CursorCards.detect(in: plain, title: "w").first?.heading == "Switch to Ask Mode?")

        // Answered, the card keeps its words and loses its buttons: nothing to mirror.
        let answered = group([group([text("Switched to "), text("Plan Mode"), text("User asked to switch to Plan mode first.")])])
        #expect(CursorCards.detect(in: answered, title: "w").isEmpty)
    }

    @Test func thePlanCardIsReadAsCursorDrawsIt() throws {
        let found = CursorCards.detect(in: group([text("Plan mode is on."), planCard()]), title: "cursor-e2e")
        let plan = try #require(found.first)
        #expect(found.count == 1)
        #expect(plan.kind == .plan)
        #expect(plan.heading == "hello and ls", "the plan's name, the line after \"Created Plan\"")
        #expect(plan.options.map(\.label) == ["View Plan", "Build"], "the menu beside Build is no button of the card's")
        #expect(plan.blocksTurn == false, "a plan waits for nobody")
        #expect(CursorCards.buildOption(of: plan)?.path == [1, 0, 3, 0])

        // The Agents window draws the same plan as "Review Plan", with Minimize plan where View Plan was, and the
        // plan itself open in a tab beside the chat, which has a Build of its own (live tree, 2026-10-03).
        let review = group([group([text("Review Plan"), text("three echoes"), group([text("Run three standalone echo commands one at a time.")]),
                                   CursorAXNode(role: "AXButton", label: "Minimize plan"),
                                   group([button("Build ⌘⏎", [text("Build"), text("⌘⏎")]), popUp("Open menu")])])])
        let tab = group([text("cursor-e2e"), text("Plans"), text("Three echoes"), popUp("Grok 4.6 Medium"), group([button("Build"), popUp("Open menu")]),
                         text("3 To-dos"), button("New")])
        let header = button("Chat title. Three echoes plan commands", [text("Chat title."), text("Three echoes plan commands")])
        let agents = CursorCards.detect(in: group([header, review, tab]), title: "Cursor Agents")
        #expect(agents.count == 1, "the plan's own tab is no second card")
        let reviewed = try #require(agents.first)
        #expect(reviewed.kind == .plan && reviewed.heading == "three echoes")
        #expect(reviewed.chat == "Three echoes plan commands")
        #expect(CursorCards.buildOption(of: reviewed)?.path == [1, 0, 4, 0], "the card's Build, not the tab's")
        #expect(CursorCards.planCard(named: "three echoes", in: agents) == reviewed)

        // Once built, Cursor takes the Build button away and the card is no longer one to press.
        let built = group([group([group([text("Created Plan"), text("hello and ls")]), button("View Plan")])])
        #expect(CursorCards.detect(in: built, title: "cursor-e2e").isEmpty)

        // Where Cursor shows a separate cloud build, the local one reads "Build Locally"; the cloud one is never it.
        let local = try #require(CursorCards.detect(in: planCard(build: "Build Locally ⌘⏎"), title: "w").first)
        #expect(CursorCards.buildOption(of: local)?.label == "Build Locally")
        let cloud = group([text("Created Plan"), text("p"), button("View Plan"), button("Build in Cloud")])
        #expect(CursorCards.detect(in: cloud, title: "w").isEmpty)
    }

    @Test func theRunCardIsHeadedByTheCommandItWouldRun() throws {
        // As Cursor drew it for `echo three`: the model's line about the command, then the command itself.
        let run = group([group([group([text("Run echo three"), text("echo"),
                                       group([group([popUp("Shell command options")])]),
                                       code(["$", " ", "echo", " ", "three"]),
                                       group([popUp("Autorun mode: Allowlist (with Sandbox)")]),
                                       button("Skip"), button("Run")])])])
        let card = try #require(CursorCards.detect(in: group([planCard(), run]), title: "cursor-e2e").first { $0.kind == .run })
        #expect(card.heading == "echo three", "what Run would run, not the sentence written about it")
        #expect(card.options.map(\.label) == ["Skip", "Run"])
        #expect(card.blocksTurn)

        // Where the command can be allowlisted Cursor adds Always Run between the two, as the Agents window drew it
        // for the same command.
        let gate = group([group([text("Run echo three"), text("echo"), group([group([popUp("Shell command options")])]),
                                 code(["$", " ", "echo", " ", "three"]), group([popUp("Autorun mode: Allowlist (with Sandbox)")]),
                                 button("Skip"), group([button("Always Run")]), button("Run")])])
        let allowlistable = try #require(CursorCards.detect(in: gate, title: "Cursor Agents").first)
        #expect(allowlistable.heading == "echo three")
        #expect(allowlistable.options.map(\.label) == ["Skip", "Always Run", "Run"])
        // With no command drawn, the card's first words head it.
        let wordsOnly = try #require(CursorCards.detect(in: group([group([text("npm run deploy -- --prod")]), button("Skip"), button("Run ⏎")]), title: "w").first)
        #expect(wordsOnly.heading == "npm run deploy -- --prod")
    }

    /// The question card as Cursor 3.23.12's editor window drew it on 2026-10-04, for a question with one answer and
    /// for one with several alike: the choices are buttons, Skip and Continue are plain text. As it was first
    /// recorded, without the classes on the choices' letters that say what is picked (`askedCard` has those).
    func questionCard(_ question: String = "Which fruit?", _ choices: [String] = ["apple", "banana", "cherry"]) -> CursorAXNode {
        let letters = Array("ABCDEFGH").map(String.init)
        let lettered = zip(letters, choices).map { letter, choice in button("\(letter) \(choice)", [button(letter), text(choice)]) }
        let other = button("\(letters[choices.count]) Other...", [button(letters[choices.count]), CursorAXNode(role: "AXTextArea", label: nil)])
        return group([group([group([text(""), text("Questions"), group([text("")]), text("1"), text(" of "), text("1"), group([text("")]), group([text("")])]),
                             group([group([text("1"), text(".")]), group([group([text(question)])])] + lettered + [other]),
                             group([text("Skip"), text("Esc")]),
                             group([text("Continue"), text("⏎")])]),
                      group([group([text(""), group([text("1 background terminal")])])])])
    }

    @Test func theQuestionCardIsReadWithItsChoicesAndNothingToPress() throws {
        let card = try #require(CursorCards.detect(in: group([questionCard()]), title: "proj").first)
        #expect(card.kind == .question)
        #expect(card.heading == "Which fruit?", "the question, not the card's own furniture or its numbering")
        #expect(card.choices == ["A apple", "B banana", "C cherry", "D Other..."], "as Cursor letters them")
        #expect(card.options.isEmpty && !card.answerable, "read without what says a choice is picked, nothing is offered to press")
        #expect(card.questions.map(\.text) == ["Which fruit?"], "and the question is kept, to be shown")
        #expect(card.blocksTurn)
        #expect(CursorCards.detect(in: group([questionCard()]), title: "proj").count == 1)
        let next = try #require(CursorCards.detect(in: group([questionCard("Which colours?", ["red", "green", "blue"])]), title: "proj").first)
        #expect(next.id != card.id, "the next question is another card")
        #expect(try #require(CursorCards.detect(in: group([questionCard("Which fruit?", ["apple", "pear"])]), title: "proj").first).id != card.id)

        // The same words in a reply are no card: a question card is its three texts beside choices lettered from A.
        let reply = group([text("On the "), text("Questions"), text(" card press "), text("Skip"), text(" or "), text("Continue"), button("Copy")])
        #expect(CursorCards.detect(in: reply, title: "proj").isEmpty)
        let unlettered = group([text("Questions"), button("apple"), button("banana"), text("Skip"), text("Continue")])
        #expect(CursorCards.detect(in: unlettered, title: "proj").isEmpty)
        let fromB = group([text("Questions"), button("B banana"), button("C cherry"), text("Skip"), text("Continue")])
        #expect(CursorCards.detect(in: fromB, title: "proj").isEmpty, "the letters run from A")
        let one = group([text("Questions"), button("A apple"), text("Skip"), text("Continue")])
        #expect(CursorCards.detect(in: one, title: "proj").isEmpty)

        // Nor is a stretch of the chat that holds them with another of Cursor's buttons: the card is its choices alone.
        let stretch = group([text("Questions"), button("A quick fix"), button("B tree notes"), button("Copy"), text("Skip"), text("Continue")])
        #expect(CursorCards.detect(in: stretch, title: "proj").isEmpty)

        // Beside a Run card, each is its own.
        let run = group([group([code(["$", " ", "ls"]), button("Skip"), button("Run")])])
        #expect(Set(CursorCards.detect(in: group([questionCard(), run]), title: "proj").map(\.kind)) == [.question, .run])
    }

    /// The question card as Cursor 3.23.12's editor window drew it on 2026-10-05 for two questions asked at once,
    /// with the classes Cursor's page gives each choice's letter: both questions on the one card, each lettered
    /// from A, the header counting the one being looked at, and Skip and Continue each a group of plain text that
    /// takes a press. `picked` names the choices Cursor shows picked.
    func askedCard(picked: Set<String> = [], viewing: Int = 1, classes: Bool = true) -> CursorAXNode {
        func letter(_ name: String, picked: Bool = false) -> CursorAXNode {
            var mark = button(name)
            if classes {
                mark.classes = ["composer-questionnaire-toolbar-option-letter"]
                    + (picked ? ["composer-questionnaire-toolbar-option-letter-selected"] : [])
            }
            return mark
        }
        func asked(_ number: Int, _ question: String, _ words: [String]) -> [CursorAXNode] {
            let letters = Array("ABCDEFGH").map(String.init)
            let lettered = zip(letters, words).map { name, word in button("\(name) \(word)", [letter(name, picked: picked.contains(word)), text(word)]) }
            let other = button("\(letters[words.count]) Other...", [letter(letters[words.count]), CursorAXNode(role: "AXTextArea", label: nil)])
            return [group([text("\(number)"), text(".")]), group([group([text(question)])])] + lettered + [other]
        }
        return group([group([text("\u{f23c}"), text("Questions"), group([text("\u{eab7}")]), text("\(viewing)"), text(" of "), text("2"),
                             group([text("\u{eab4}")]), group([text("\u{eab4}")])]),
                      group([group(asked(1, "Pick a fruit", ["apple", "banana", "cherry"]) + asked(2, "Pick a color", ["red", "green", "blue"]))]),
                      group([text("Skip"), text("Esc")]),
                      group([text("Continue"), text("⏎")])])
    }

    func node(at path: [Int], in root: CursorAXNode) -> CursorAXNode? {
        path.reduce(Optional(root)) { node, index in node.flatMap { $0.children.indices.contains(index) ? $0.children[index] : nil } }
    }

    @Test func aQuestionCardWhoseWindowSaysWhatIsPickedCanBeAnsweredFromTheNotch() throws {
        let window = group([askedCard()])
        let card = try #require(CursorCards.detect(in: window, title: "proj").first)
        #expect(card.kind == .question)
        #expect(card.heading == "Pick a fruit")
        #expect(card.questions.map(\.text) == ["Pick a fruit", "Pick a color"], "each question, without the number Cursor writes before it")
        #expect(card.questions.map { $0.choices.map(\.label) } == [["A apple", "B banana", "C cherry", "D Other..."],
                                                                    ["A red", "B green", "C blue", "D Other..."]])
        #expect(card.choices == card.questions.flatMap { $0.choices.map(\.label) })
        #expect(card.questions.flatMap(\.choices).allSatisfy { !$0.picked })
        #expect(card.questions.map { $0.choices.map(\.typed) } == [[false, false, false, true], [false, false, false, true]],
                "the answer that is typed is told apart, and is Cursor's to take")
        #expect(card.options.map(\.label) == ["Skip", "Continue"], "Cursor's own two ways to end the card, in its order")
        // What a press lands on: each choice's own button, and the groups Skip and Continue are drawn as.
        for choice in card.questions.flatMap(\.choices) {
            #expect(node(at: choice.path, in: window)?.label == choice.label)
        }
        let ends = card.options.map { node(at: $0.path, in: window) }
        #expect(ends.map { $0?.role } == ["AXGroup", "AXGroup"])
        #expect(ends.map { $0?.children.first?.label } == ["Skip", "Continue"])
    }

    @Test func whatIsPickedShowsOnTheCardAndItIsStillTheSameCard() throws {
        let before = try #require(CursorCards.detect(in: group([askedCard()]), title: "proj").first)
        // With a pick Cursor moves its header on to the next question ("2 of 2").
        let after = try #require(CursorCards.detect(in: group([askedCard(picked: ["apple", "green"], viewing: 2)]), title: "proj").first)
        #expect(after.questions.map { $0.choices.map(\.picked) } == [[true, false, false, false], [false, true, false, false]])
        #expect(after.id == before.id, "a card being answered is not another card")
        #expect(after != before, "and what changed on it is seen")
        let other = try #require(CursorCards.detect(in: group([askedCard(picked: ["blue"])]), title: "proj").first)
        #expect(other.questions.map { $0.choices.map(\.picked) } == [[false, false, false, false], [false, false, true, false]])
        // Another card asks something else.
        var next = askedCard()
        next.children[1].children[0].children[1] = group([group([text("Pick a vegetable")])])
        #expect(try #require(CursorCards.detect(in: group([next]), title: "proj").first).id != before.id)
    }

    @Test func aQuestionCardThatDoesNotSayWhatIsPickedIsShownAndAnsweredInCursor() throws {
        // Letters with no classes: a press on a choice could not be checked, so none is offered.
        let silent = try #require(CursorCards.detect(in: group([askedCard(classes: false)]), title: "proj").first)
        #expect(!silent.answerable && silent.options.isEmpty)
        #expect(silent.choices.count == 8 && silent.heading == "Pick a fruit", "it is still shown, every choice of it")
        // Each question with its own choices: shown as one flat list, the second question's read as more of the first's.
        #expect(silent.questions.map(\.text) == ["Pick a fruit", "Pick a color"])
        #expect(silent.questions.map { $0.choices.map(\.label) } == [["A apple", "B banana", "C cherry", "D Other..."], ["A red", "B green", "C blue", "D Other..."]])
        // Kept to be drawn, and for nothing else: no choice of such a card is a thing to press.
        #expect(CursorCards.pickTarget(question: 0, choice: 0, shown: silent, read: silent) == nil)
        #expect(CursorCards.picked(question: 0, choice: 0, in: silent) == nil)
        // Continue as a bare text, with nothing round it to take a press: the answers could not be sent.
        var bare = askedCard()
        bare.children[3] = text("Continue")
        let unsent = try #require(CursorCards.detect(in: group([bare]), title: "proj").first)
        #expect(!unsent.answerable && unsent.options.isEmpty && unsent.choices.count == 8 && unsent.questions.count == 2)
        // Without one of its three words it is not known for a question card at all.
        var skipless = askedCard()
        skipless.children.remove(at: 2)
        #expect(CursorCards.detect(in: group([skipless]), title: "proj").isEmpty)
    }

    @Test func skipAndContinueAreTheGroupsAfterTheChoicesAndNothingThatOpensWithTheWord() throws {
        // A question whose first word is drawn as a run of its own ("Continue", in bold) is a question. Its group
        // takes a press in Cursor too, so read as the card's Continue it would be pressed in place of it.
        var bold = askedCard()
        bold.children[1].children[0].children[1] = group([group([text("Continue"), text(" with the migration?")])])
        let card = try #require(CursorCards.detect(in: group([bold]), title: "proj").first)
        #expect(card.questions.map(\.text) == ["Continue with the migration?", "Pick a color"])
        #expect(card.options.map(\.label) == ["Skip", "Continue"])
        #expect(card.options.map(\.path) == [[0, 2], [0, 3]], "Cursor's own two, after the last choice")
        // A question that is the word itself is still the question.
        var word = askedCard()
        word.children[1].children[0].children[7] = group([group([text("Skip")])])
        let asked = try #require(CursorCards.detect(in: group([word]), title: "proj").first)
        #expect(asked.questions.map(\.text) == ["Pick a fruit", "Skip"])
        #expect(asked.options.map(\.path) == [[0, 2], [0, 3]])

        // What a press is checked against, again, before it is made.
        #expect(CursorCards.questionEnd(of: group([text("Continue"), text("⏎")])) == "Continue")
        #expect(CursorCards.questionEnd(of: group([text("Skip"), text("Esc")])) == "Skip")
        #expect(CursorCards.questionEnd(of: group([text("Continue")])) == "Continue")
        #expect(CursorCards.questionEnd(of: group([text("Continue"), text(" with the migration?")])) == nil)
        #expect(CursorCards.questionEnd(of: group([text("Continue"), text("⏎"), text("or"), text("wait")])) == nil)
        #expect(CursorCards.questionEnd(of: group([text("Continue"), button("Copy")])) == nil, "a stretch with a button in it is no such group")
        #expect(CursorCards.questionEnd(of: text("Continue")) == nil, "a bare text takes no press")
        #expect(CursorCards.questionEnd(of: button("Continue")) == nil, "a button is checked by its own label")
        #expect(CursorCards.questionEnd(of: group([text("Questions")])) == nil)
    }

    @Test func aQuestionsWordsReadAsProseAndWhatIsCutSaysSo() throws {
        // Two paragraphs are two sentences, and a number that opens a question is part of it.
        var long = askedCard()
        long.children[1].children[0].children[1] = group([group([text("Which database?")]), group([text("It cannot be changed later.")])])
        long.children[1].children[0].children[7] = group([group([text("2"), text(" replicas, or 3?")])])
        let card = try #require(CursorCards.detect(in: group([long]), title: "proj").first)
        #expect(card.questions.map(\.text) == ["Which database? It cannot be changed later.", "2 replicas, or 3?"])

        // A choice that runs past what is shown is marked, so it does not read as the whole of it; and two cards
        // that differ only past the cut are two cards.
        let tail = String(repeating: "x", count: CursorCards.headingLimit)
        func cut(ending: String) throws -> CursorCard {
            var tree = askedCard()
            var choice = tree.children[1].children[0].children[2]
            choice.label = "A \(tail) \(ending)"
            tree.children[1].children[0].children[2] = choice
            return try #require(CursorCards.detect(in: group([tree]), title: "proj").first)
        }
        let staging = try cut(ending: "on staging"), production = try cut(ending: "but not on production")
        #expect(staging.questions[0].choices[0].label == String("A \(tail)".prefix(CursorCards.headingLimit)) + "…")
        #expect(staging.questions[0].choices[0].label == production.questions[0].choices[0].label)
        #expect(staging.id != production.id)
        #expect(CursorCards.choiceLabel("B banana") == "B banana")
    }

    @Test func aCardIsAnsweredOnlyWhereItsLettersCarryTheClassThatSaysWhatIsPicked() throws {
        // Letters with classes that are not the ones a pick is read from: the notch could not tell a pick from none.
        var renamed = askedCard()
        func rename(_ node: inout CursorAXNode) {
            node.classes = node.classes.map { $0.replacingOccurrences(of: "option-letter", with: "choice-mark") }
            for index in node.children.indices { rename(&node.children[index]) }
        }
        rename(&renamed)
        let shown = try #require(CursorCards.detect(in: group([renamed]), title: "proj").first)
        #expect(!shown.answerable && shown.options.isEmpty && shown.choices.count == 8)
        // Read with and without what says a choice is picked, it is the same card: a read that came back short of
        // a letter has not seen another one.
        let answered = try #require(CursorCards.detect(in: group([askedCard()]), title: "proj").first)
        #expect(shown.id == answered.id)
        #expect(try #require(CursorCards.detect(in: group([askedCard(classes: false)]), title: "proj").first).id == answered.id)
        #expect(answered.shownOnly.id == answered.id && !answered.shownOnly.answerable && answered.shownOnly.options.isEmpty)
        #expect(answered.shownOnly.choices == answered.choices)
        #expect(answered.shownOnly.questions == answered.questions, "its questions are kept, each with its own choices, to be drawn")
    }

    @Test func aPickIsMadeOnlyAgainstTheCardAsTheNotchShowedIt() throws {
        let shown = try #require(CursorCards.detect(in: group([askedCard()]), title: "proj").first)
        let same = try #require(CursorCards.pickTarget(question: 0, choice: 1, shown: shown, read: shown))
        #expect(same.label == "B banana" && same.path == shown.questions[0].choices[1].path)
        // Picked in Cursor since the notch drew it: a press now would unpick it.
        let moved = try #require(CursorCards.detect(in: group([askedCard(picked: ["banana"])]), title: "proj").first)
        #expect(CursorCards.pickTarget(question: 0, choice: 1, shown: shown, read: moved) == nil)
        #expect(CursorCards.pickTarget(question: 0, choice: 0, shown: shown, read: moved) != nil, "another choice of it is as it was")
        #expect(CursorCards.pickTarget(question: 0, choice: 3, shown: shown, read: shown) == nil, "the typed answer is not picked from here")
        #expect(CursorCards.pickTarget(question: 0, choice: 9, shown: shown, read: shown) == nil)
        #expect(CursorCards.pickTarget(question: 5, choice: 0, shown: shown, read: shown) == nil)
        #expect(CursorCards.pickTarget(question: 0, choice: 0, shown: shown, read: shown.shownOnly) == nil, "a card that no longer says what is picked")
        var other = askedCard()
        other.children[1].children[0].children[1] = group([group([text("Pick a vegetable")])])
        let next = try #require(CursorCards.detect(in: group([other]), title: "proj").first)
        #expect(CursorCards.pickTarget(question: 0, choice: 0, shown: shown, read: next) == nil, "another card")
        #expect(CursorCards.picked(question: 0, choice: 1, in: moved) == true)
        #expect(CursorCards.picked(question: 0, choice: 0, in: moved) == false)
        #expect(CursorCards.picked(question: 0, choice: 0, in: shown.shownOnly) == nil)
    }

    /// The two questions `askedCard` draws, as Cursor's database holds them and the notch's own card shows them.
    func heldCard(picked: Set<String> = [], several: Bool = false, asking first: String = "Pick a **fruit**") -> CursorCard {
        var card = CursorQuestions.card(CursorAsked(questions: [.init(prompt: first, allowsSeveral: several, options: ["apple", "banana", "cherry"]),
                                                                .init(prompt: "Pick a color", allowsSeveral: several, options: ["red", "green", "blue"])]), window: "proj")
        for question in card.questions.indices {
            for choice in card.questions[question].choices.indices where picked.contains(CursorCards.words(ofChoice: card.questions[question].choices[choice].label)) {
                card.questions[question].choices[choice].picked = true
            }
        }
        return card
    }

    @Test func aQuestionTheDatabaseHoldsIsFoundInTheWindowByItsChoices() throws {
        let window = group([askedCard(picked: ["banana"])])
        let placed = try #require(CursorCards.place(of: heldCard(), in: window))
        // Each choice that is not typed, as the button of its words, and what Cursor shows picked.
        #expect(placed.choices.map { $0.map { node(at: $0.path, in: window)?.label } } == [["A apple", "B banana", "C cherry"], ["A red", "B green", "C blue"]])
        #expect(placed.choices.map { $0.map(\.picked) } == [[false, true, false], [false, false, false]])
        // And the two groups Cursor ends its card with.
        #expect(node(at: placed.skip, in: window)?.children.first?.label == "Skip")
        #expect(node(at: placed.send, in: window)?.children.first?.label == "Continue")
        #expect(node(at: placed.send, in: window)?.role == "AXGroup")

        // Cursor draws a question from Markdown, so a real one holds what its words call for: a file's name that
        // is a button, a command, a list. Read whole out of the window such a card is not known for a question at
        // all (0.9.19); found by its choices it is, since what the question holds is not asked of the window.
        var rich = askedCard()
        rich.children[1].children[0].children[1] = group([group([text("Should "), button("theme.css"), text(" keep its "), text("dark palette"), text("?")]),
                                                          group([code(["make", " ", "icons"])]), group([text("•"), text("It is read on every launch.")])])
        #expect(CursorCards.detect(in: group([rich]), title: "proj").isEmpty)
        let asked = heldCard(asking: "Should [`theme.css`](styles/theme.css) keep its **dark palette**?\n\n```\nmake icons\n```\n- It is read on every launch.")
        let found = try #require(CursorCards.place(of: asked, in: group([rich])))
        #expect(found.choices.map(\.count) == [3, 3])
        #expect(found.choices[0].map { node(at: $0.path, in: group([rich]))?.label } == ["A apple", "B banana", "C cherry"])
        // A choice lettered otherwise than the notch's card letters it is on a card that offers something the
        // notch's does not show, and is not this card.
        var shifted = askedCard()
        shifted.children[1].children[0].children[2].label = "B apple"
        #expect(CursorCards.place(of: heldCard(), in: group([shifted])) == nil)
        // The typed choice is known by the field in it, with or without words of its own.
        var wordless = askedCard()
        wordless.children[1].children[0].children[5].label = nil
        #expect(CursorCards.place(of: heldCard(), in: group([wordless])) != nil)
        // Cursor's number for a question, as two runs of text or as one.
        var joined = askedCard()
        joined.children[1].children[0].children[0] = group([text("1.")])
        joined.children[1].children[0].children[6] = group([text("2.")])
        #expect(CursorCards.place(of: heldCard(), in: group([joined])) != nil)

        // Letters that do not say what is picked: found, and nothing known of its picks.
        let silent = try #require(CursorCards.place(of: heldCard(), in: group([askedCard(classes: false)])))
        #expect(silent.choices.allSatisfy { $0.allSatisfy { $0.picked == nil } })
    }

    @Test func nothingIsFoundOnPartOfACardOrOnAnotherQuestion() {
        // Another question's choices.
        let other = CursorQuestions.card(CursorAsked(questions: [.init(prompt: "Pick a fruit", allowsSeveral: false, options: ["apple", "pear"])]), window: "proj")
        #expect(CursorCards.place(of: other, in: group([askedCard()])) == nil)
        // A card with a choice missing, or its choices in another order.
        var short = askedCard()
        short.children[1].children[0].children.remove(at: 3)
        #expect(CursorCards.place(of: heldCard(), in: group([short])) == nil)
        var swapped = askedCard()
        swapped.children[1].children[0].children.swapAt(2, 3)
        #expect(CursorCards.place(of: heldCard(), in: group([swapped])) == nil)
        // Cursor's card minimised: its header is there and its choices are not.
        var minimised = askedCard()
        minimised.children.removeSubrange(1...)
        #expect(CursorCards.place(of: heldCard(), in: group([minimised])) == nil)
        // No Continue after the last choice, or Continue as bare text that takes no press.
        var endless = askedCard()
        endless.children.remove(at: 3)
        #expect(CursorCards.place(of: heldCard(), in: group([endless])) == nil)
        var bare = askedCard()
        bare.children[3] = text("Continue")
        #expect(CursorCards.place(of: heldCard(), in: group([bare])) == nil)
        // The second question's choices after the card has ended are not the card's.
        var split = askedCard()
        let second = Array(split.children[1].children[0].children[6...])
        split.children[1].children[0].children.removeSubrange(6...)
        #expect(CursorCards.place(of: heldCard(), in: group([split, group(second)])) == nil)
        // A card of another kind, and one with only a typed choice, have nothing to be found by.
        #expect(CursorCards.place(of: CursorCard(kind: .run, window: "proj", heading: "ls", options: []), in: group([askedCard()])) == nil)
        let typed = CursorQuestions.card(CursorAsked(questions: [.init(prompt: "Name it", allowsSeveral: false, options: [])]), window: "proj")
        #expect(typed.questions[0].choices.map(\.label) == ["A Other..."])
        #expect(CursorCards.place(of: typed, in: group([askedCard()])) == nil)
    }

    @Test func anotherQuestionWithTheSameChoicesIsNotThisOne() throws {
        // Two chats can offer the same choices for different questions (Yes and No). What is drawn before the
        // choices has to be the question the notch's card holds, or its answer would go to the other chat.
        func yesNo(_ question: String, picked: Bool = false) -> CursorAXNode {
            var yes = button("A Yes", [button("A"), text("Yes")])
            yes.children[0].classes = ["composer-questionnaire-toolbar-option-letter"] + (picked ? ["composer-questionnaire-toolbar-option-letter-selected"] : [])
            var no = button("B No", [button("B"), text("No")])
            no.children[0].classes = ["composer-questionnaire-toolbar-option-letter"]
            return group([group([text("Questions")]), group([text("1"), text(".")]), group([group([text(question)])]), yes, no,
                          button("C Other...", [button("C"), CursorAXNode(role: "AXTextArea", label: nil)]),
                          group([text("Skip"), text("Esc")]), group([text("Continue"), text("⏎")])])
        }
        func held(_ prompt: String) -> CursorCard {
            CursorQuestions.card(CursorAsked(questions: [.init(prompt: prompt, allowsSeveral: false, options: ["Yes", "No"])]), window: "proj")
        }
        let migrate = "Print the report on both sides of the page?", delete = "Sort the list by name as well?"
        #expect(CursorCards.place(of: held(migrate), in: group([yesNo(migrate)])) != nil)
        #expect(CursorCards.place(of: held(migrate), in: group([yesNo(delete)])) == nil, "the same choices under another question")
        // Which is told from a card that is not there at all, for the log.
        #expect(CursorCards.placing(of: held(migrate), in: group([yesNo(delete)])).otherwise == 1)
        #expect(CursorCards.placing(of: held(migrate), in: group([askedCard()])).otherwise == 0)
        #expect(CursorCards.placing(of: held(migrate), in: group([yesNo(migrate)])).otherwise == 0)
        // Both in one window, the other one last: the card is the one that asks this question, not the last.
        let both = group([group([yesNo(migrate, picked: true)]), group([text("and then")]), group([yesNo(delete)])])
        let first = try #require(CursorCards.place(of: held(migrate), in: both))
        #expect(first.choices[0].map(\.path.first) == [0, 0] && first.choices[0].map(\.picked) == [true, false])
        let second = try #require(CursorCards.place(of: held(delete), in: both))
        #expect(second.choices[0].map(\.path.first) == [2, 2] && second.send.first == 2)
        // On a card of several questions each is checked: the second question's choices under other words are not it.
        var swapped = askedCard()
        swapped.children[1].children[0].children[7] = group([group([text("Pick a size")])])
        #expect(CursorCards.place(of: heldCard(), in: group([swapped])) == nil)

        // What is compared is the question with its marks gone, and how much of it is there.
        #expect(CursorCards.essence("Should [`theme.css`](styles/theme.css) keep its **dark palette**?") == Array("shouldthemecsskeepitsdarkpalette"))
        #expect(CursorCards.share(of: "Pick a **fruit**", in: "Questions 1 of 2 1 . Pick a fruit") == 1)
        #expect(CursorCards.share(of: migrate, in: "Questions 1 . " + delete) < 0.2)
        #expect(CursorCards.share(of: migrate + " It takes twice the paper…", in: "1 . " + migrate) >= CursorCards.questionShare, "a question cut short is still most of itself")
        // A question shorter than one run is held to all of itself, and one with no letters to nothing.
        #expect(CursorCards.share(of: "OK?", in: "anything at all") == 0 && CursorCards.share(of: "OK?", in: "is it ok then") == 1)
        #expect(CursorCards.share(of: "OK?", in: "OK, go", fromTheStart: true) == 1 && CursorCards.share(of: "OK?", in: "Not OK", fromTheStart: true) == 0)
        #expect(CursorCards.share(of: "继续吗?", in: "删除所有数据吗?", fromTheStart: true) == 0 && CursorCards.share(of: "继续吗?", in: "继续吗?", fromTheStart: true) == 1)
        #expect(CursorCards.share(of: "?", in: "anything at all") == 1)
        // Two questions a step apart are not told apart by this, which is why they are never left to it alone
        // (CursorQuestions.alike): the chats asking them are answered in Cursor.
        #expect(CursorCards.share(of: "Proceed with step 1?", in: "1 . Proceed with step 2?") >= CursorCards.questionShare)
        #expect(CursorCards.share(of: migrate, in: "") == 0)
    }

    @Test func skipAndContinueAreTheCardsOwnAndAQuestionsWordsAreReadInTheOrderTheyAreDrawn() throws {
        // A card above the one that is waiting, drawn with its choices and without its Skip and Continue: it is
        // not given the pair that ends the card below it, whose answer its picks would then be sent as.
        var above = askedCard(picked: ["apple", "red"])
        above.children.removeSubrange(2...)
        let other = CursorQuestions.card(CursorAsked(questions: [.init(prompt: "Pick a size", allowsSeveral: false, options: ["small", "large"])]), window: "proj")
        let below = group([group([text("Questions")]), group([text("1"), text(".")]), group([group([text("Pick a size")])]),
                           button("A small", [button("A"), text("small")]), button("B large", [button("B"), text("large")]),
                           button("C Other...", [button("C"), CursorAXNode(role: "AXTextArea", label: nil)]),
                           group([text("Skip"), text("Esc")]), group([text("Continue"), text("⏎")])])
        let window = group([group([above]), group([text("and then")]), group([below])])
        #expect(CursorCards.place(of: heldCard(), in: window) == nil, "the card above has no way to be ended, and takes none of the other's")
        #expect(CursorCards.place(of: other, in: window)?.send.first == 2)
        // More than the typed choice between the last choice and Skip is not the card's own ending either.
        var padded = askedCard()
        padded.children.insert(group([button("Copy"), button("Insert")]), at: 2)
        #expect(CursorCards.place(of: heldCard(), in: group([padded])) == nil)

        // A question with two files' names in it, each a button in the middle of the sentence: its words are
        // read in the order Cursor draws them, the buttons' where they stand.
        var files = askedCard()
        files.children[1].children[0].children[1] = group([group([text("Use "), button("a.ts"), text(" or "), button("b.ts"), text("?")])])
        #expect(CursorCards.place(of: heldCard(asking: "Use `a.ts` or `b.ts`?"), in: group([files])) != nil)
        #expect(CursorCards.place(of: heldCard(asking: "Use `b.ts` or `c.ts`?"), in: group([files])) == nil)
        // And one that names many, its first words a long way above its choices.
        let names = (1...12).map { "file\($0).css" }
        var many = askedCard()
        many.children[1].children[0].children[1] = group([group([text("Which of these keeps the old palette: ")] + names.flatMap { [button($0), text(", ")] } + [text("or none?")])])
        let asked = heldCard(asking: "Which of these keeps the old palette: " + names.map { "`\($0)`" }.joined(separator: ", ") + ", or none?")
        #expect(CursorCards.place(of: asked, in: group([many])) != nil)
    }

    @Test func theWindowToPressIsTheOnlyOneOrTheOneTitledForTheChatsWorkspace() {
        // One window holds the card: it is the one, whatever it is called (a worktree's is titled by its folder).
        #expect(CursorAnswering.chosen(among: ["plan.md — atlas-worktree-2"], workspace: "atlas", named: false) == 0)
        #expect(CursorAnswering.chosen(among: [], workspace: "atlas", named: false) == nil)
        // Several hold it: the one whose title names the chat's workspace, as one of its parts and not a part of one.
        #expect(CursorAnswering.chosen(among: ["notes.md — birch", "plan.md — atlas"], workspace: "atlas", named: false) == 1)
        #expect(CursorAnswering.chosen(among: ["atlas.md — birch", "plan.md — atlas-two"], workspace: "atlas", named: false) == nil)
        #expect(CursorAnswering.chosen(among: ["a.md — atlas", "b.md — atlas"], workspace: "atlas", named: false) == nil, "two windows on one workspace")
        #expect(CursorAnswering.chosen(among: ["Cursor Agents", "Cursor Agents"], workspace: "atlas", named: false) == nil)
        #expect(CursorAnswering.chosen(among: ["a.md — birch", "b.md — atlas"], workspace: "", named: false) == nil, "a chat with no workspace known")
        // The only window that holds it, titled for another chat's workspace and not for this chat's: that card
        // is the other workspace's. A title that names neither, as a worktree's does, says nothing against it.
        #expect(CursorAnswering.chosen(among: ["todo.md — birch"], workspace: "atlas", named: false, elsewhere: ["birch", "cedar"]) == nil)
        #expect(CursorAnswering.chosen(among: ["todo.md — atlas-worktree-2"], workspace: "atlas", named: false, elsewhere: ["birch"]) == 0)
        #expect(CursorAnswering.chosen(among: ["birch — atlas"], workspace: "atlas", named: false, elsewhere: ["birch"]) == 0, "it names this chat's own")
        #expect(CursorAnswering.chosen(among: ["Cursor Agents"], workspace: "atlas", named: false, elsewhere: ["birch"]) == 0)
        // Another chat is asking the same thing: only a window titled for this chat's workspace will do, even alone.
        #expect(CursorAnswering.chosen(among: ["plan.md — birch"], workspace: "atlas", named: true) == nil)
        #expect(CursorAnswering.chosen(among: ["plan.md — atlas"], workspace: "atlas", named: true) == 0)
        #expect(CursorAnswering.chosen(among: ["Cursor Agents"], workspace: "atlas", named: true) == nil)
    }

    @Test func theCardFoundIsTheNotchsCardWholeAndNoOthers() throws {
        func question(_ number: Int, _ words: String, _ choices: [String]) -> [CursorAXNode] {
            let letters = Array("ABCDEFGH").map(String.init)
            func letter(_ name: String) -> CursorAXNode {
                var mark = button(name)
                mark.classes = ["composer-questionnaire-toolbar-option-letter"]
                return mark
            }
            return [group([text("\(number)"), text(".")]), group([group([text(words)])])]
                + zip(letters, choices).map { name, choice in button("\(name) \(choice)", [letter(name), text(choice)]) }
                + [button("\(letters[choices.count]) Other...", [letter(letters[choices.count]), CursorAXNode(role: "AXTextArea", label: nil)])]
        }
        func card(_ questions: [[CursorAXNode]], above: [CursorAXNode] = []) -> CursorAXNode {
            group(above + [group([text("Questions")]), group([group(questions.flatMap { $0 })]),
                           group([text("Skip"), text("Esc")]), group([text("Continue"), text("⏎")])])
        }
        func held(_ asked: [(String, [String])]) -> CursorCard {
            CursorQuestions.card(CursorAsked(questions: asked.map { .init(prompt: $0.0, allowsSeveral: false, options: $0.1) }), window: "proj")
        }
        let proceed = "Proceed with the first step?"
        let mine = held([(proceed, ["Yes", "No"])])
        #expect(CursorCards.place(of: mine, in: group([card([question(1, proceed, ["Yes", "No"])])])) != nil)

        // Another chat's card that holds this question as its second: Skip there would skip the other chat's
        // card, and Continue would put this chat's pick on it.
        #expect(CursorCards.place(of: mine, in: group([card([question(1, "Which fruit?", ["apple", "banana"]), question(2, proceed, ["Yes", "No"])])])) == nil)
        // And as its first, with another after it.
        #expect(CursorCards.place(of: mine, in: group([card([question(1, proceed, ["Yes", "No"]), question(2, "Which fruit?", ["apple", "banana"])])])) == nil)
        // One whose choices end with these, or begin with them.
        #expect(CursorCards.place(of: mine, in: group([card([question(1, proceed, ["Yes, with tests", "Yes", "No"])])])) == nil)
        #expect(CursorCards.place(of: mine, in: group([card([question(1, proceed, ["Yes", "No", "Later"])])])) == nil)
        // One that asks something else, under a chat whose words above it are this question's.
        let said = [group([text("Next I will proceed with the first step.")])]
        #expect(CursorCards.place(of: mine, in: group([card([question(1, "Do it now?", ["Yes", "No"])], above: said)])) == nil)
        // And one whose longer question only comes round to these words.
        #expect(CursorCards.place(of: mine, in: group([card([question(1, "Before anything else is touched, and only if the tests pass, proceed with the first step?", ["Yes", "No"])])])) == nil)

        // A card whose last question offers only the typed choice is still the card, with nothing of that
        // question to press: its choices are found, and it can be skipped.
        let named = held([("Which fruit?", ["apple", "banana"]), ("Name the branch", [])])
        let placed = try #require(CursorCards.place(of: named, in: group([card([question(1, "Which fruit?", ["apple", "banana"]), question(2, "Name the branch", [])])])))
        #expect(placed.choices.map(\.count) == [2, 0])
        // A question's own words are held to from their start: a link the card's cut fell in the middle of, or
        // one with a title, is not held against them.
        #expect(CursorCards.essence("See [the notes](https://example.com/a/very/long/pa…") == Array("seethenotes"))
        #expect(CursorCards.essence("See [the notes](https://example.com/a \"Field notes\") first") == Array("seethenotesfirst"))
        #expect(CursorCards.share(of: "Proceed?", in: "Before I proceed? Tell me which", fromTheStart: true) < CursorCards.questionShare)
        #expect(CursorCards.share(of: "Proceed?", in: "Proceed? Tell me which", fromTheStart: true) == 1)
        // A longer question that leads up to the same words is another question, however short its lead.
        #expect(CursorCards.place(of: mine, in: group([card([question(1, "Only if the tests pass, proceed with the first step?", ["Yes", "No"])])])) == nil)

        // What the chat said above a card is no part of the card, even when it numbers this very question: a
        // card begins at the number under its own header.
        let listed = [group([text("1."), text(proceed)])]
        #expect(CursorCards.place(of: mine, in: group([card([question(1, "Do it now?", ["Yes", "No"])], above: listed)])) == nil)
        let spelled = [group([text("1"), text("."), text(proceed)])]
        #expect(CursorCards.place(of: mine, in: group([card([question(1, "Do it now?", ["Yes", "No"])], above: spelled)])) == nil)
        // Nor does a later question whose own words number it begin one.
        var second = question(2, "placeholder", ["Yes", "No"])
        second[1] = group([group([text("1."), text(proceed)])])
        #expect(CursorCards.place(of: mine, in: group([card([question(1, "Which fruit?", ["apple", "banana"]), second])])) == nil)
        // A question the notch holds with no choices but the typed one is not a card that offers some.
        let typedOnly = held([("Name the branch", [])])
        #expect(CursorCards.place(of: typedOnly, in: group([card([question(1, "Name the branch", ["main", "develop"])])])) == nil)
        #expect(CursorCards.place(of: typedOnly, in: group([card([question(1, "Name the branch", [])])])) != nil)
        // A card with no Skip and Continue of its own is not ended by two words of code in the chat below it.
        var endless = card([question(1, proceed, ["Yes", "No"])])
        endless.children.removeLast(2)
        #expect(CursorCards.place(of: mine, in: group([endless, group([code(["skip"])]), group([code(["continue"])])])) == nil)

        // And the card that is this one is found however its question is drawn. A word of code that reads
        // "skip" is a word of the question; so is a question that is the one word.
        let importer = "Should the importer `skip` the row or overwrite it?"
        var coded = question(1, "placeholder", ["Yes", "No"])
        coded[1] = group([group([text("Should the importer "), code(["skip"]), text(" the row or overwrite it?")])])
        #expect(CursorCards.place(of: held([(importer, ["Yes", "No"])]), in: group([card([coded])])) != nil)
        var linked = question(1, "placeholder", ["Yes", "No"])
        linked[1] = group([group([text("Should the importer "), CursorAXNode(role: "AXLink", label: nil, children: [text("skip")]), text(" the row or overwrite it?")])])
        #expect(CursorCards.place(of: held([("Should the importer [skip](docs/skip.md) the row or overwrite it?", ["Yes", "No"])]), in: group([card([linked])])) != nil)
        #expect(CursorCards.place(of: held([("Continue", ["Yes", "No"])]), in: group([card([question(1, "Continue", ["Yes", "No"])])])) != nil)
        // A file's path drawn as the file's name alone is still most of the question.
        var chip = question(1, "placeholder", ["Yes", "No"])
        chip[1] = group([group([text("Should "), button("theme.css"), text(" keep its palette?")])])
        #expect(CursorCards.place(of: held([("Should `styles/shared/theme.css` keep its palette?", ["Yes", "No"])]), in: group([card([chip])])) != nil)
        // A short question in another script is its own, and not any other short one.
        #expect(CursorCards.place(of: held([("继续吗?", ["是", "否"])]), in: group([card([question(1, "继续吗?", ["是", "否"])])])) != nil)
        #expect(CursorCards.place(of: held([("继续吗?", ["是", "否"])]), in: group([card([question(1, "删除所有数据吗?", ["是", "否"])])])) == nil)
    }

    @Test func theCardThatIsWaitingIsTheLastOfItsWordsInTheWindow() throws {
        // A chat keeps what it has asked above what it is asking: the same choices drawn twice are the earlier
        // card, answered, and the one that waits below it.
        let window = group([group([askedCard(picked: ["apple", "red"])]), group([text("Thanks, apple it is.")]), group([askedCard()])])
        let placed = try #require(CursorCards.place(of: heldCard(), in: window))
        #expect(placed.choices.allSatisfy { $0.allSatisfy { $0.path.first == 2 && $0.picked == false } })
        #expect(placed.send.first == 2 && placed.skip.first == 2)
        // A choice that runs to several lines, or past what a card shows, is matched as it is cut.
        let tail = String(repeating: "x", count: CursorCards.headingLimit)
        let long = CursorQuestions.card(CursorAsked(questions: [.init(prompt: "Which?", allowsSeveral: false, options: ["one  two", "\(tail) at the end"])]), window: "proj")
        let drawn = group([text("Questions"), group([text("1"), text(".")]), group([text("Which?")]), button("A one two"), button("B \(tail) at the end"),
                           button("C Other...", [button("C"), CursorAXNode(role: "AXTextArea", label: nil)]),
                           group([text("Skip"), text("Esc")]), group([text("Continue"), text("⏎")])])
        #expect(CursorCards.place(of: long, in: drawn)?.choices.first?.count == 2)
        #expect(CursorCards.words(ofChoice: "A  apple\n pie") == "apple pie" && CursorCards.words(ofChoice: "apple") == "apple")
        #expect(CursorCards.words(ofChoice: "a apple") == "a apple", "a letter is Cursor's capital, not a word that happens to be one long")
    }

    @Test func cursorsCardIsBroughtToTheNotchsOnePressAtATime() throws {
        func placed(_ picked: Set<String>, classes: Bool = true) throws -> CursorCards.Placed {
            try #require(CursorCards.place(of: heldCard(), in: group([askedCard(picked: picked, classes: classes)])))
        }
        // Nothing picked in Cursor: the notch's picks are pressed, in the card's order.
        #expect(CursorCards.step(toward: heldCard(picked: ["banana", "red"]), from: try placed([])) == .press(question: 0, choice: 1))
        #expect(CursorCards.step(toward: heldCard(picked: ["banana", "red"]), from: try placed(["banana"])) == .press(question: 1, choice: 0))
        #expect(CursorCards.step(toward: heldCard(picked: ["banana", "red"]), from: try placed(["banana", "red"])) == .same)
        // A press turns a choice over, so one Cursor already shows picked is not pressed again.
        #expect(CursorCards.step(toward: heldCard(picked: ["apple", "red"]), from: try placed(["apple"])) == .press(question: 1, choice: 0))
        // Another choice picked in Cursor: the notch's is pressed first. On a question with one answer that drops
        // the other, which the next read shows; where it is still picked after, on one with several, it is
        // pressed then. The step is decided by what each card shows, not by which kind the question is.
        #expect(CursorCards.step(toward: heldCard(picked: ["cherry", "red"]), from: try placed(["apple", "red"])) == .press(question: 0, choice: 2))
        #expect(CursorCards.step(toward: heldCard(picked: ["cherry", "red"]), from: try placed(["apple", "cherry", "red"])) == .press(question: 0, choice: 0))
        #expect(CursorCards.step(toward: heldCard(picked: ["apple", "cherry", "blue"]), from: try placed(["apple", "red"])) == .press(question: 0, choice: 2))
        #expect(CursorCards.step(toward: heldCard(picked: ["apple", "blue"]), from: try placed(["apple", "red"])) == .press(question: 1, choice: 2))
        #expect(CursorCards.step(toward: heldCard(picked: ["apple", "blue"]), from: try placed(["apple", "red", "blue"])) == .press(question: 1, choice: 0))
        // A card that does not say what is picked: no press can be told from its opposite.
        #expect(CursorCards.step(toward: heldCard(picked: ["apple", "red"]), from: try placed([], classes: false)) == .unread)
        // A place for another card's shape is no place to press.
        var odd = try placed([])
        odd.choices[1].removeLast()
        #expect(CursorCards.step(toward: heldCard(picked: ["apple", "red"]), from: odd) == .unread)
    }

    @Test func aQuestionIsReadWholeAndEachQuestionsLettersRunFromA() throws {
        // A question drawn as several runs, a word of it in bold, is one question.
        var rich = askedCard()
        rich.children[1].children[0].children[1] = group([group([text("Which "), text("theme"), text(" should it use?")])])
        let card = try #require(CursorCards.detect(in: group([rich]), title: "proj").first)
        #expect(card.questions.map(\.text) == ["Which theme should it use?", "Pick a color"])
        #expect(card.heading == "Which theme should it use?")

        let again = group([text("Questions"), button("A one"), button("B two"), button("A three"), text("Skip"), text("Continue")])
        #expect(CursorCards.detect(in: again, title: "proj").isEmpty, "a second question has two choices or more, as a first has")
        let jumbled = group([text("Questions"), button("A one"), button("B two"), button("C three"), button("B four"), text("Skip"), text("Continue")])
        #expect(CursorCards.detect(in: jumbled, title: "proj").isEmpty)
        // Two questions drawn flat are known for a card, and shown: nothing in them takes a press.
        let flat = group([text("Questions"), text("First?"), button("A one"), button("B two"), text("Second?"), button("A three"), button("B four"),
                          text("Skip"), text("Continue")])
        let shown = try #require(CursorCards.detect(in: flat, title: "proj").first)
        #expect(shown.choices == ["A one", "B two", "A three", "B four"] && shown.heading == "First?")
        #expect(!shown.answerable && shown.options.isEmpty)
        #expect(shown.questions.map(\.text) == ["First?", "Second?"] && shown.questions.map { $0.choices.count } == [2, 2])
    }

    @Test func anApprovalThatIsNotACommandSaysWhatItIsFor() throws {
        // As Cursor 3.23.12 drew its approval for a file written outside the workspace (2026-10-04): the file in a
        // button of its own, then the same Skip and Run a command gets.
        let path = "/Users/x/notes/answers.txt"
        let approval = group([group([group([button("Create \(path)", [text("Create"), text(" "), text(path)]), button("Skip"),
                                            button("Run ⏎", [text("Run"), text("⏎")])])])])
        let card = try #require(CursorCards.detect(in: approval, title: "proj").first)
        #expect(card.kind == .run)
        #expect(!card.command)
        #expect(card.heading == "Create /Users/x/notes/answers.txt", "the button that is not an answer, punctuation and all")
        #expect(card.options.map(\.label) == ["Skip", "Run"])

        // Two files whose paths open alike past what a heading shows are two cards, so a press re-read against one
        // cannot land on the other.
        func long(_ name: String) -> CursorAXNode {
            let long = "/Users/x/" + String(repeating: "deep/", count: 40) + name
            return group([group([button("Create \(long)", [text("Create"), text(" "), text(long)]), button("Skip"), button("Run")])])
        }
        let first = try #require(CursorCards.detect(in: long("one.txt"), title: "proj").first)
        let second = try #require(CursorCards.detect(in: long("two.txt"), title: "proj").first)
        #expect(first.heading == second.heading)
        #expect(first.id != second.id)
        // A button of one word names no subject.
        let bare = try #require(CursorCards.detect(in: group([group([button("Copy"), button("Skip"), button("Run")])]), title: "proj").first)
        #expect(bare.heading == nil)
        #expect(!bare.command)

        let command = try #require(CursorCards.detect(in: group([group([code(["$", " ", "ls"]), button("Skip"), button("Run")])]), title: "proj").first)
        #expect(command.command)
        #expect(command.heading == "ls")
        // Words and no command drawn: an approval headed by its words.
        let words = try #require(CursorCards.detect(in: group([group([text("search_issues")]), button("Skip"), button("Run")]), title: "proj").first)
        #expect(!words.command)
        #expect(words.heading == "search_issues")
    }

    @Test func theAgentsWindowNamesItsChat() throws {
        let header = button("Chat title. Upgrade process inquiry", [text("Chat title."), text("Upgrade process inquiry")])
        let window = group([group([button("New Chat"), button("manga-reader")]), header, group([text("ls"), button("Skip"), button("Run ⏎")])])
        let card = try #require(CursorCards.detect(in: window, title: "Cursor Agents").first)
        #expect(card.chat == "Upgrade process inquiry")
        #expect(card.window == "Cursor Agents")
        let editor = try #require(CursorCards.detect(in: group([text("ls"), button("Skip"), button("Run")]), title: "cursor-e2e").first)
        #expect(editor.chat == nil, "an editor window names its workspace in its title and no chat")
        #expect(card.id != editor.id)
    }

    @Test func aButtonBelongsToOneCardAndAStrayRunMakesNone() {
        // The mode card's Skip must not pair with an unrelated Run elsewhere in the window to invent a run card.
        let mode = group([text("Switch to Ask Mode?"), button("Skip"), button("Switch")])
        let window = group([mode, group([button("Run")])])
        let found = CursorCards.detect(in: window, title: "w")
        #expect(found.map(\.kind) == [.modeSwitch])
        #expect(CursorCards.detect(in: group([button("Run"), text("x")]), title: "w").isEmpty, "Run alone is not a card")
    }

    @Test func aDisabledButtonIsNotOffered() throws {
        let card = group([text("ls"), button("Skip"), button("Run", enabled: false)])
        let found = try #require(CursorCards.detect(in: card, title: "w").first)
        #expect(found.options.map(\.label) == ["Skip"])
    }

    @Test func theSameCardKeepsItsIDAndTheNextOneDoesNot() throws {
        let a = try #require(CursorCards.detect(in: group([text("ls"), button("Skip"), button("Run")]), title: "w").first)
        let again = try #require(CursorCards.detect(in: group([text("ls"), button("Skip"), button("Run")]), title: "w").first)
        let other = try #require(CursorCards.detect(in: group([text("rm x"), button("Skip"), button("Run")]), title: "w").first)
        #expect(a.id == again.id)
        #expect(a.id != other.id, "a press re-reads the card and refuses when it is no longer the same one")
    }

    @Test func headingsAreBounded() throws {
        let long = String(repeating: "a", count: 500) + "\nsecond line"
        let card = try #require(CursorCards.detect(in: group([text(long), button("Skip"), button("Run")]), title: "w").first)
        #expect((card.heading?.count ?? 0) <= CursorCards.headingLimit + 1)
        #expect(card.heading?.contains("second") == false)
    }

    @Test func normalizationDropsShortcutGlyphs() {
        #expect(CursorCards.normalized("Switch ⌘⏎") == "Switch")
        #expect(CursorCards.normalized("  Run   ⌥⌘↩︎ ") == "Run")
        #expect(CursorCards.normalized("⌘") == nil)
        #expect(CursorCards.normalized(nil) == nil)
    }

    @Test func aCardIsMatchedToItsSession() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func session(_ id: String, _ project: String?, _ last: TimeInterval, tool: ToolID = .cursor, host: String? = nil,
                     working: Bool = true, title: String? = nil) -> AgentSession {
            var session = AgentSession(id: id, tool: tool, project: project, state: working ? .working(since: t0) : .idle, started: t0,
                                       lastEvent: t0.addingTimeInterval(last), turnStarted: t0, host: host)
            session.title = title
            return session
        }
        func run(_ window: String, chat: String? = nil) -> CursorCard {
            CursorCard(kind: .run, window: window, chat: chat, heading: "ls", options: [.init(label: "Run", path: [0])])
        }
        let sessions = [session("a", "storefront", 1), session("b", "storefront", 5), session("c", "notchmeter", 9), session("d", "storefront", 20, tool: .claude)]
        #expect(CursorCards.session(for: run("plan.md — storefront"), among: sessions) == "b", "the most recent of the workspace's chats")
        #expect(CursorCards.session(for: run("notchmeter"), among: sessions) == "c")
        #expect(CursorCards.session(for: run("elsewhere"), among: sessions) == nil, "several chats and another workspace's window: no guess")
        #expect(CursorCards.session(for: run("elsewhere"), among: [session("a", nil, 1)]) == "a", "the only Cursor chat there is")
        #expect(CursorCards.session(for: run("x"), among: [session("r", "x", 1, host: "devbox")]) == nil, "a remote chat's window is not on this Mac")

        // A card that holds a turn belongs to a chat that is in one: eight rows and one of them working is no puzzle.
        let idle = (0..<7).map { session("idle\($0)", "storefront", 100 + TimeInterval($0), working: false) }
        #expect(CursorCards.session(for: run("Cursor Agents"), among: idle + [session("busy", "tools", 1)]) == "busy")
        #expect(CursorCards.session(for: run("worktree-folder-name"), among: idle + [session("busy", "tools", 1)]) == "busy",
                "a worktree's window is titled by its folder and its session by its repository")

        // The Agents window names no workspace. Its chat's name settles it where a row carries that name; else the
        // chat heard from last.
        let two = [session("x", "storefront", 1, title: "Find the checkout code"), session("y", "tools", 9, title: "Map Cursor plan ingestion")]
        #expect(CursorCards.session(for: run("Cursor Agents", chat: "Find the checkout code"), among: two) == "x")
        #expect(CursorCards.session(for: run("Cursor Agents", chat: "Some other name"), among: two) == "y")
        // Cursor's own name for a chat is the row's session name; its title is whatever was last typed.
        var named = two
        named[0].title = "ran it and it printed hello"
        named[0].sessionName = "Find the checkout code"
        #expect(CursorCards.session(for: run("Cursor Agents", chat: "Find the checkout code"), among: named) == "x")
        #expect(CursorCards.session(for: run("Cursor Agents"), among: two) == "y")

        // Whose names are worth reading: several chats could own the card, its window names the chat, and no row
        // carries that name yet.
        #expect(CursorCards.unnamedCandidates(for: run("Cursor Agents", chat: "Some other name"), among: two).map(\.id) == ["x", "y"])
        #expect(CursorCards.unnamedCandidates(for: run("Cursor Agents", chat: "Find the checkout code"), among: two).isEmpty, "a row already has it")
        #expect(CursorCards.unnamedCandidates(for: run("Cursor Agents"), among: two).isEmpty, "the window names no chat")
        #expect(CursorCards.unnamedCandidates(for: run("Cursor Agents", chat: "Anything"), among: [two[0]]).isEmpty, "one candidate needs no name")
        #expect(CursorCards.chatName("  Three   echoes\nplan ") == "Three echoes", "cleaned as a name read from Cursor is")

        // A plan card holds no turn, so an idle chat can own one.
        let plan = CursorCard(kind: .plan, window: "storefront", heading: "p", options: [.init(label: "Build", path: [0])])
        #expect(CursorCards.session(for: plan, among: [session("i", "storefront", 1, working: false), session("w", "tools", 5)]) == "i")
    }

    @Test func buildFindsOnlyAnUnambiguousPlanCard() {
        func plan(_ name: String) -> CursorCard { CursorCard(kind: .plan, window: "w", heading: name, options: [.init(label: "Build", path: [0])]) }
        #expect(CursorCards.planCard(named: "A", in: [plan("A"), plan("B")])?.heading == "A")
        #expect(CursorCards.planCard(named: "C", in: [plan("A"), plan("B")]) == nil, "two plans and neither is this one: nothing is pressed")
        #expect(CursorCards.planCard(named: nil, in: [plan("A")])?.heading == "A")
        #expect(CursorCards.planCard(named: "C", in: [plan("A")]) == nil,
                "the only plan card on screen may be another chat's: a row for plan C never presses plan A's Build")
        #expect(CursorCards.planCard(named: "A", in: [plan("A"), plan("A")]) == nil, "two cards of the name are not one")
    }

    @Test func aCardIsItsWholeCommandNotTheLineShown() throws {
        // Two commands that open alike are two cards: the press re-reads the card and must not take one for the other.
        let opening = String(repeating: "x", count: 200)
        func run(_ command: String) throws -> CursorCard {
            try #require(CursorCards.detect(in: group([text("Run it"), code(["$", " ", command]), button("Skip"), button("Run")]), title: "w").first)
        }
        let a = try run(opening + " --dry-run")
        let b = try run(opening + " --force")
        #expect(a.heading == b.heading, "what is shown is the first 160 characters of each")
        #expect(a.heading?.hasSuffix("…") == true, "and says there is more")
        #expect(a.id != b.id, "but the card is the whole command")
        #expect(try run("ls").id == run("ls").id)
        // A command that goes on to a second line says so too.
        let two = try #require(CursorCards.detect(in: group([text("npm test\nrm -rf build"), button("Skip"), button("Run")]), title: "w").first)
        #expect(two.heading == "npm test…")
    }
}

/// Cursor's windows as answering a question needs them (CursorWindowDriving), with question cards that take
/// presses by Cursor's own rules, read from its questionnaire in Cursor 3.23.23: a press turns a choice over, a
/// question with one answer keeping one at most; Continue sends only once every question has a pick; Skip always
/// goes. A window can be put away, when its tree is the one it had until it is asked to bring it up to date.
final class SimulatedCursor: CursorWindowDriving {
    final class Card {
        struct Question {
            var prompt: String
            var options: [String]
            var several = false
            var picked: Set<Int> = []
        }

        var questions: [Question]
        var sent: [[Int]]?
        var skipped = false
        var open: Bool { sent == nil && !skipped }

        init(_ questions: [Question]) {
            self.questions = questions
        }
    }

    final class Window {
        let title: String
        var cards: [Card]
        var putAway = false
        var drawn: Drawn?

        init(_ title: String, _ cards: [Card]) {
            self.title = title
            self.cards = cards
        }
    }

    enum Action {
        case choice(Card, question: Int, choice: Int)
        case skip(Card)
        case send(Card)
    }

    struct Drawn {
        var tree: CursorAXNode
        var actions: [[Int]: Action] = [:]
    }

    var all: [Window]
    /// What was pressed, in order: a choice by its words, "skip", "continue".
    var pressed: [String] = []
    var refreshes = 0
    /// Whether asking brings a put-away window's tree up to date.
    var refreshWorks = true
    /// Whether the choices' letters carry the classes that say what is picked.
    var saysPicks = true
    /// No press is taken.
    var refusesPresses = false
    /// Continue is taken and does nothing.
    var sendSticks = false
    /// How many of the next reads come back short: not whole, and without the letters' classes. And how many
    /// more do after each press.
    var shortReads = 0
    var shortAfterPress = 0
    /// Windows, by title, whose every read comes back short of their cards altogether.
    var shortWindows: Set<String> = []
    /// How many whole reads after a press on Skip or Continue come back without the card although it is still
    /// there: Cursor's chat dropping out of its tree as it redraws.
    var blinksAfterEnd = 0
    private var blinks = 0

    init(_ windows: [Window]) {
        all = windows
    }

    private let build = CursorCardDetection()

    /// A window as Cursor 3.23.12 drew a question card in it: some of the chat, then each card that is waiting.
    func draw(_ window: Window) -> Drawn {
        var drawn = Drawn(tree: build.group([build.group([build.text("the chat so far")])]))
        for card in window.cards where card.open {
            let place = drawn.tree.children.count
            var body: [CursorAXNode] = []
            for (number, question) in card.questions.enumerated() {
                body.append(build.group([build.text("\(number + 1)"), build.text(".")]))
                body.append(build.group([build.group([build.text(question.prompt)])]))
                let letters = Array("ABCDEFGH").map(String.init)
                for (index, option) in question.options.enumerated() {
                    var letter = build.button(letters[index])
                    if saysPicks {
                        letter.classes = ["composer-questionnaire-toolbar-option-letter"]
                            + (question.picked.contains(index) ? ["composer-questionnaire-toolbar-option-letter-selected"] : [])
                    }
                    drawn.actions[[place, 1, 0, body.count]] = .choice(card, question: number, choice: index)
                    body.append(build.button("\(letters[index]) \(option)", [letter, build.text(option)]))
                }
                body.append(build.button("\(letters[question.options.count]) Other...", [build.button(letters[question.options.count]), CursorAXNode(role: "AXTextArea", label: nil)]))
            }
            drawn.actions[[place, 2]] = .skip(card)
            drawn.actions[[place, 3]] = .send(card)
            drawn.tree.children.append(build.group([build.group([build.text("Questions")]), build.group([build.group(body)]),
                                                    build.group([build.text("Skip"), build.text("Esc")]),
                                                    build.group([build.text("Continue"), build.text("⏎")])]))
        }
        return drawn
    }

    func windows() -> [(window: Window, title: String)] {
        all.map { ($0, $0.title) }
    }

    func snapshot(_ window: Window) -> (tree: CursorAXNode, elements: Drawn, whole: Bool) {
        if !window.putAway || window.drawn == nil { window.drawn = draw(window) }
        let drawn = window.drawn ?? draw(window)
        if shortWindows.contains(window.title) { return (build.group([build.group([build.text("the chat so far")])]), drawn, false) }
        if blinks > 0 {
            blinks -= 1
            return (build.group([build.group([build.text("the chat so far")])]), drawn, true)
        }
        guard shortReads > 0 else { return (drawn.tree, drawn, true) }
        shortReads -= 1
        func bare(_ node: CursorAXNode) -> CursorAXNode {
            var node = node
            node.classes = []
            node.children = node.children.map(bare)
            return node
        }
        return (bare(drawn.tree), drawn, false)
    }

    func press(_ path: [Int], in elements: Drawn, reading: CursorAnswering.Reading) -> CursorPressResult? {
        guard let action = elements.actions[path] else { return .gone }
        switch (action, reading) {
        case (.choice(let card, let question, let choice), .choice(let words)):
            guard card.open, card.questions[question].options[choice] == words else { return .gone }
            guard !refusesPresses else { return .refused }
            pressed.append(words)
            let was = card.questions[question].picked.contains(choice)
            if card.questions[question].several {
                card.questions[question].picked.formSymmetricDifference([choice])
            } else {
                card.questions[question].picked = was ? [] : [choice]
            }
        case (.skip(let card), .end("skip")):
            guard card.open else { return .gone }
            guard !refusesPresses else { return .refused }
            pressed.append("skip")
            card.skipped = true
        case (.send(let card), .end("continue")):
            guard card.open else { return .gone }
            guard !refusesPresses else { return .refused }
            pressed.append("continue")
            if !sendSticks, card.questions.allSatisfy({ !$0.picked.isEmpty }) { card.sent = card.questions.map { $0.picked.sorted() } }
        default:
            return .gone
        }
        shortReads += shortAfterPress
        if case .end = reading { blinks = blinksAfterEnd }
        return nil
    }

    func refresh(_ window: Window, elements: Drawn?) {
        refreshes += 1
        if refreshWorks { window.drawn = draw(window) }
    }

    func pause() {}

    func hasPage(_ elements: Drawn) -> Bool { true }
}

/// The pressing itself (CursorAnswering.answer), run press by press against a card that behaves as Cursor's does.
@Suite struct CursorAnsweringOnACard {
    typealias Card = SimulatedCursor.Card
    typealias Window = SimulatedCursor.Window

    func fruit(picked: Set<Int> = [], several: Bool = false) -> Card.Question {
        .init(prompt: "Which fruit?", options: ["apple", "banana", "cherry"], several: several, picked: picked)
    }
    func colour(picked: Set<Int> = []) -> Card.Question {
        .init(prompt: "Which colour?", options: ["red", "green"], picked: picked)
    }

    /// The notch's card for those questions, with `picks` made on it (question, choice).
    func held(_ questions: [Card.Question], picks: [(Int, Int)] = [], workspace: String = "atlas") -> CursorCard {
        let asked = CursorAsked(questions: questions.map { .init(prompt: $0.prompt, allowsSeveral: $0.several, options: $0.options) })
        return picks.reduce(CursorQuestions.card(asked, window: workspace)) { CursorQuestions.picking($0, question: $1.0, choice: $1.1) }
    }

    @Test func thePicksGoOntoCursorsCardAndItIsSent() {
        let card = Card([fruit()])
        let cursor = SimulatedCursor([Window("notes.md — atlas", [card])])
        let answered = CursorAnswering.answer(held([fruit()], picks: [(0, 1)]), skip: false, named: false, in: cursor)
        #expect(answered.result == .pressed && answered.found == "read")
        #expect(cursor.pressed == ["banana", "continue"])
        #expect(card.sent == [[1]])
        #expect(cursor.refreshes > 0, "the window is asked to come up to date before each read that follows a press")
    }

    @Test func cursorsCardIsBroughtToTheNotchsWhateverWasPickedThere() {
        // Several answers: what the notch has picked is pressed, and what Cursor had picked besides is unpicked
        // after. One answer, on the second question: the pick is pressed and takes the other's place by itself.
        let card = Card([fruit(picked: [1], several: true), colour(picked: [0])])
        let cursor = SimulatedCursor([Window("atlas", [card])])
        let wanted = held([fruit(several: true), colour()], picks: [(0, 0), (0, 2), (1, 1)])
        #expect(CursorAnswering.answer(wanted, skip: false, named: false, in: cursor).result == .pressed)
        #expect(cursor.pressed == ["apple", "cherry", "green", "banana", "continue"])
        #expect(card.sent == [[0, 2], [1]])

        // The pick Cursor already shows is not pressed, which would unpick it.
        let same = Card([fruit(picked: [2])])
        let again = SimulatedCursor([Window("atlas", [same])])
        #expect(CursorAnswering.answer(held([fruit()], picks: [(0, 2)]), skip: false, named: false, in: again).result == .pressed)
        #expect(again.pressed == ["continue"] && same.sent == [[2]])

        // One answer, another choice picked in Cursor: one press moves it.
        let moved = Card([fruit(picked: [0])])
        let third = SimulatedCursor([Window("atlas", [moved])])
        #expect(CursorAnswering.answer(held([fruit()], picks: [(0, 1)]), skip: false, named: false, in: third).result == .pressed)
        #expect(third.pressed == ["banana", "continue"] && moved.sent == [[1]])
    }

    @Test func skipPressesSkipAndNothingElse() {
        let card = Card([fruit(picked: [0]), colour()])
        let cursor = SimulatedCursor([Window("atlas", [card])])
        let answered = CursorAnswering.answer(held([fruit(), colour()], picks: [(0, 2)]), skip: true, named: false, in: cursor)
        #expect(answered.result == .pressed && cursor.pressed == ["skip"])
        #expect(card.skipped && card.sent == nil && card.questions[0].picked == [0], "what was picked on either card is left as it was")
    }

    @Test func aCardInAWindowThatIsPutAwayIsReachedWhenAskingBringsItUpToDate() {
        // The question came up after the window was last drawn: its tree has no card until it is asked.
        let card = Card([fruit()])
        let window = Window("atlas", [])
        let cursor = SimulatedCursor([window])
        window.putAway = true
        _ = cursor.snapshot(window)
        window.cards = [card]
        let answered = CursorAnswering.answer(held([fruit()], picks: [(0, 0)]), skip: false, named: false, in: cursor)
        #expect(answered.result == .pressed && answered.found == "refreshed")
        #expect(cursor.pressed == ["apple", "continue"] && card.sent == [[0]])
    }

    @Test func aCardThatCannotBeReachedIsNotPressedAndOneThatDoesNotAnswerIsLeft() {
        // Asking does not bring the window up to date: the card is never there, and nothing is pressed.
        let card = Card([fruit()])
        let window = Window("atlas", [])
        let cursor = SimulatedCursor([window])
        cursor.refreshWorks = false
        window.putAway = true
        _ = cursor.snapshot(window)
        window.cards = [card]
        let unreached = CursorAnswering.answer(held([fruit()], picks: [(0, 0)]), skip: false, named: false, in: cursor)
        #expect(unreached.result == .gone && unreached.found == "none of 1 windows, 1 pages, 0 holding it, 0 under other words")
        #expect(cursor.pressed.isEmpty && card.open && cursor.refreshes == CursorAnswering.reads - 1)

        // The card was drawn before the window was put away, and a press on it does not show: that press is the
        // last, and Continue is not sent on picks nobody could read back.
        let stale = Card([fruit()])
        let behind = Window("atlas", [stale])
        let second = SimulatedCursor([behind])
        second.refreshWorks = false
        _ = second.snapshot(behind)
        behind.putAway = true
        let unread = CursorAnswering.answer(held([fruit()], picks: [(0, 1)]), skip: false, named: false, in: second)
        #expect(unread.result == .refused && second.pressed == ["banana"] && stale.open)

        // A card whose letters do not say what is picked: no press can be told from its opposite, and none is made.
        let silent = Card([fruit()])
        let third = SimulatedCursor([Window("atlas", [silent])])
        third.saysPicks = false
        #expect(CursorAnswering.answer(held([fruit()], picks: [(0, 1)]), skip: false, named: false, in: third).result == .refused)
        #expect(third.pressed.isEmpty)
        // Skip needs to know nothing of the picks.
        #expect(CursorAnswering.answer(held([fruit()]), skip: true, named: false, in: third).result == .pressed && silent.skipped)

        // A press that is not taken, and a Continue that is taken and sends nothing.
        let fourth = SimulatedCursor([Window("atlas", [Card([fruit()])])])
        fourth.refusesPresses = true
        #expect(CursorAnswering.answer(held([fruit()], picks: [(0, 1)]), skip: false, named: false, in: fourth).result == .refused)
        let stuck = Card([fruit()])
        let fifth = SimulatedCursor([Window("atlas", [stuck])])
        fifth.sendSticks = true
        #expect(CursorAnswering.answer(held([fruit()], picks: [(0, 1)]), skip: false, named: false, in: fifth).result == .stillShown)
        #expect(fifth.pressed == ["banana", "continue"] && stuck.open)
    }

    @Test func aReadCursorFellBehindOnIsReadAgainAndNotBelieved() {
        // The first read comes back short, without what says a choice is picked; and so does the read after
        // the press. Neither is taken for a card that does not say, or for a press that showed.
        let card = Card([fruit(), colour()])
        let cursor = SimulatedCursor([Window("atlas", [card])])
        cursor.shortReads = 1
        cursor.shortAfterPress = 1
        let answered = CursorAnswering.answer(held([fruit(), colour()], picks: [(0, 2), (1, 0)]), skip: false, named: false, in: cursor)
        #expect(answered.result == .pressed)
        #expect(cursor.pressed == ["cherry", "red", "continue"] && card.sent == [[2], [0]])
        // Short every time, it is given up on without a press: a read that may be short of this chat's own card
        // is not one to choose a window by.
        let never = SimulatedCursor([Window("atlas", [Card([fruit()])])])
        never.shortReads = 100
        let unread = CursorAnswering.answer(held([fruit()], picks: [(0, 0)]), skip: false, named: false, in: never)
        #expect(unread.result == .gone && unread.found == "none of 1 windows, 1 pages, 1 holding it, 0 under other words, read short")
        #expect(never.pressed.isEmpty)
        // The chat's own window read short, and another chat's card like it in the only window read whole: that
        // one is not answered in its place.
        let mine = Card([fruit()]), theirs = Card([fruit()])
        let two = SimulatedCursor([Window("notes.md — atlas", [mine]), Window("todo.md — birch", [theirs])])
        two.shortWindows = ["notes.md — atlas"]
        #expect(CursorAnswering.answer(held([fruit()], picks: [(0, 0)]), skip: false, named: false, in: two).result == .gone)
        #expect(two.pressed.isEmpty && mine.open && theirs.open)
    }

    @Test func aCardIsGoneWhenTwoReadsRunningDoNotFindIt() {
        // Continue is taken and does nothing, and Cursor's chat drops out of its tree for one read as it redraws:
        // the card is back on the next, and was not answered.
        let stuck = Card([fruit()])
        let cursor = SimulatedCursor([Window("atlas", [stuck])])
        cursor.sendSticks = true
        cursor.blinksAfterEnd = 1
        #expect(CursorAnswering.answer(held([fruit()], picks: [(0, 1)]), skip: false, named: false, in: cursor).result == .stillShown)
        #expect(stuck.open)
        // Taken: it is gone on every read, and believed on the second.
        let sent = Card([fruit()])
        let second = SimulatedCursor([Window("atlas", [sent])])
        second.blinksAfterEnd = 1
        let before = second.refreshes
        #expect(CursorAnswering.answer(held([fruit()], picks: [(0, 1)]), skip: false, named: false, in: second).result == .pressed)
        #expect(sent.sent == [[1]] && second.refreshes - before >= 3)
    }

    @Test func anAnswerGoesToTheChatsOwnCardOrToNone() {
        // The same question waiting in two windows: the one titled for the chat's workspace is the one pressed.
        let mine = Card([fruit()]), theirs = Card([fruit()])
        let cursor = SimulatedCursor([Window("todo.md — birch", [theirs]), Window("notes.md — atlas", [mine])])
        #expect(CursorAnswering.answer(held([fruit()], picks: [(0, 1)]), skip: false, named: false, in: cursor).result == .pressed)
        #expect(mine.sent == [[1]] && theirs.open && theirs.questions[0].picked.isEmpty)
        // Titles that do not settle it (two worktrees' windows, named for neither's repository): nothing is pressed.
        let one = Card([fruit()]), other = Card([fruit()])
        let unsettled = SimulatedCursor([Window("atlas-two", [one]), Window("atlas-three", [other])])
        let refused = CursorAnswering.answer(held([fruit()], picks: [(0, 1)]), skip: false, named: false, in: unsettled)
        #expect(refused.result == .gone && refused.found == "none of 2 windows, 2 pages, 2 holding it, 0 under other words")
        #expect(unsettled.pressed.isEmpty && unsettled.refreshes == 0, "asking again would change nothing, and is not done")
        // Another chat is known to be asking the same: only a window titled for this chat's workspace will do,
        // even when it is the only one that holds the card.
        let alone = Card([fruit()])
        let single = SimulatedCursor([Window("todo.md — birch", [alone])])
        #expect(CursorAnswering.answer(held([fruit()], picks: [(0, 1)]), skip: false, named: true, in: single).result == .gone)
        #expect(single.pressed.isEmpty && alone.open)
        #expect(CursorAnswering.answer(held([fruit()], picks: [(0, 1)], workspace: "birch"), skip: false, named: true, in: single).result == .pressed)

        // The only window that holds the card is titled for another chat's workspace, and this chat's own card
        // is not drawn anywhere: it is the other workspace's, and is left alone.
        let foreign = Card([fruit()])
        let away = SimulatedCursor([Window("todo.md — birch", [foreign])])
        #expect(CursorAnswering.answer(held([fruit()], picks: [(0, 1)]), skip: false, named: false, elsewhere: ["birch"], in: away).result == .gone)
        #expect(away.pressed.isEmpty && foreign.open)
        #expect(CursorAnswering.answer(held([fruit()], picks: [(0, 1)]), skip: false, named: false, elsewhere: ["cedar"], in: away).result == .pressed)

        // Another chat's card over the same choices, asking something else, is not this question's.
        let elsewhere = Card([.init(prompt: "Which one goes in the lunch box?", options: ["apple", "banana", "cherry"])])
        let wrong = SimulatedCursor([Window("atlas", [elsewhere])])
        let missed = CursorAnswering.answer(held([fruit()], picks: [(0, 1)]), skip: false, named: false, in: wrong)
        #expect(missed.result == .gone && missed.found == "none of 1 windows, 1 pages, 0 holding it, 1 under other words")
        #expect(wrong.pressed.isEmpty && elsewhere.open)
        // Both in one window: each is answered on its own card.
        let lunch = Card([.init(prompt: "Which one goes in the lunch box?", options: ["apple", "banana", "cherry"])])
        let asked = Card([fruit()])
        let both = SimulatedCursor([Window("atlas", [asked, lunch])])
        #expect(CursorAnswering.answer(held([fruit()], picks: [(0, 0)]), skip: false, named: false, in: both).result == .pressed)
        #expect(asked.sent == [[0]] && lunch.open && lunch.questions[0].picked.isEmpty)
    }
}

/// The tracker's side: a card proves a wait, a held command is a request, and a plan's state follows its tasks.
@Suite struct CursorControlTracking {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let key = SessionTracker.key(tool: .cursor, session: "c1", host: nil)

    func started() -> SessionTracker {
        var tracker = SessionTracker()
        _ = tracker.apply(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "c1", project: "proj", tool: .cursor), now: t0)
        return tracker
    }

    @Test func aCardLightsTheWaitAndItsGoingOrTheNextSignOfLifeEndsIt() throws {
        var tracker = started()
        let shown = tracker.cursorCardShown(key, now: t0.addingTimeInterval(5))
        #expect(shown != nil)
        #expect(tracker.sessions[key]?.isWaiting == true)
        let repeated = tracker.cursorCardShown(key, now: t0.addingTimeInterval(6))
        #expect(repeated == nil, "the same wait is announced once")
        let gone = tracker.cursorCardGone(key, now: t0.addingTimeInterval(7))
        #expect(gone)
        #expect(tracker.sessions[key]?.isWorking == true)

        _ = tracker.cursorCardShown(key, now: t0.addingTimeInterval(8))
        let alarms = tracker.sessions[key]?.quietFalseAlarms
        _ = tracker.apply(Hook.Message(event: "afterAgentThought", needsInput: false, sessionID: "c1", tool: .cursor), now: t0.addingTimeInterval(9))
        #expect(tracker.sessions[key]?.isWorking == true)
        #expect(tracker.sessions[key]?.quietFalseAlarms == alarms, "a wait the card proved is no false alarm")
        #expect(tracker.sessions[key]?.cardWait == false)
    }

    /// Cursor has no batch boundary. What it sent on 2026-10-04 (3.23.12) for a command that exits with an error is
    /// beforeShellExecution, afterShellExecution and then PostToolUseFailure for `Shell`; for one that works, the
    /// first two alone. Five that failed with nothing working between them is a chat that may be stuck.
    final class Feed {
        var tracker: SessionTracker
        var second = 1.0
        var troubles = 0
        let t0: Date
        init(_ tracker: SessionTracker, t0: Date) {
            self.tracker = tracker
            self.t0 = t0
        }
        var now: Date { t0.addingTimeInterval(second) }
        func send(_ event: String, failed tool: String? = nil, interrupt: Bool = false) {
            var message = Hook.Message(event: event, needsInput: false, sessionID: "c1", tool: .cursor)
            if let tool { message.toolFailure = ToolFailure(tool: tool, interrupt: interrupt) }
            if tracker.apply(message, now: now).trouble != nil { troubles += 1 }
            second += 1
        }
        func command(fails: Bool) {
            send("beforeShellExecution")
            send("afterShellExecution")
            if fails { send("PostToolUseFailure", failed: "Shell") }
        }
    }

    @Test func fiveFailedCommandsInARowMayBeStuckAndOneThatWorkedEndsIt() {
        let feed = Feed(started(), t0: t0)
        func stuck() -> Set<String> { feed.tracker.stuck(now: feed.now) }
        func streak() -> Int? { feed.tracker.sessions[key]?.failureStreak }

        // A file is created: the read before it fails, as it does every time, and is no part of a run.
        feed.send("PostToolUseFailure", failed: "Read")
        feed.send("afterFileEdit")
        for _ in 0..<4 { feed.command(fails: true) }
        #expect(stuck().isEmpty)
        feed.command(fails: true)
        #expect(stuck() == [key])
        #expect(feed.troubles == 1)
        feed.command(fails: true)
        #expect(feed.troubles == 1, "news once, not once a failure")
        #expect(streak() == 6)

        // A command that worked is known to have by what is heard next not being its failure.
        feed.command(fails: false)
        feed.send("afterAgentThought")
        #expect(stuck().isEmpty)
        #expect(streak() == 0)

        // Only a command's failure counts, heard straight after that command ended: not a read's or an edit's, whose
        // successes Cursor does not report, not a second copy of the same failure, not a call denied before it ran.
        for _ in 0..<6 { feed.send("PostToolUseFailure", failed: "Read") }
        for _ in 0..<6 { feed.send("PostToolUseFailure", failed: "StrReplace") }
        #expect(streak() == 0)
        feed.command(fails: true)
        for _ in 0..<5 { feed.send("PostToolUseFailure", failed: "Shell") }
        #expect(streak() == 1, "a failure with no command's end before it is no part of a run")
        feed.send("beforeShellExecution")
        feed.send("PostToolUseFailure", failed: "Shell", interrupt: true)
        #expect(streak() == 1)
        // An edit that landed starts the count again.
        for _ in 0..<3 { feed.command(fails: true) }
        feed.send("afterFileEdit")
        feed.command(fails: true)
        #expect(streak() == 1)
        // A command skipped on Cursor's card ends with no failure after it, and reads as one that worked.
        for _ in 0..<3 { feed.command(fails: true) }
        feed.command(fails: false)
        feed.command(fails: true)
        #expect(streak() == 1)
        #expect(stuck().isEmpty)
        #expect(feed.troubles == 1)
        for _ in 0..<4 { feed.command(fails: true) }
        #expect(stuck() == [key])
        #expect(feed.troubles == 2, "a new run is news again")
        feed.send("UserPromptSubmit")
        #expect(stuck().isEmpty, "a new turn starts over")
    }

    /// A wait in the middle of a run is routine for Cursor: a turn gone quiet is shown as a possible wait, and with
    /// *Mirror Cursor's cards* its own Run card is a wait before every command. The run is the same run after it.
    @Test func aWaitInTheMiddleOfARunDoesNotMakeItNewsAgain() {
        let feed = Feed(started(), t0: t0)
        for _ in 0..<5 { feed.command(fails: true) }
        #expect(feed.troubles == 1)

        // A quiet spell shown as a possible wait (once a turn), and the turn going on by itself.
        feed.second += 300
        let nudged = feed.tracker.quietNudges(now: feed.now)
        #expect(nudged.map(\.id) == [key])
        #expect(feed.tracker.stuck(now: feed.now).isEmpty, "the row says waiting while it waits")
        feed.send("afterAgentThought")
        #expect(feed.tracker.sessions[key]?.isWorking == true)
        #expect(feed.tracker.stuck(now: feed.now) == [key], "and may be stuck again once it goes on")
        #expect(feed.troubles == 1, "the same run, said once")

        // Cursor's own Run card before the next command, answered, and the command fails too.
        _ = feed.tracker.cursorCardShown(key, now: feed.now)
        #expect(feed.tracker.stuck(now: feed.now).isEmpty)
        feed.command(fails: true)
        #expect(feed.tracker.sessions[key]?.isWorking == true)
        #expect(feed.tracker.stuck(now: feed.now) == [key])
        #expect(feed.troubles == 1)

        // A run that had gone stale and picks up again is news again.
        feed.second += SessionTracker.stuckFor + 1
        feed.send("afterAgentThought")
        #expect(feed.tracker.stuck(now: feed.now).isEmpty)
        feed.command(fails: true)
        #expect(feed.troubles == 2)
    }

    @Test func aChatThatReportsNoCommandsEndIsNeverCalledStuck() {
        // A Cursor whose hooks say when a call failed and never when a command ended: nothing to weigh a run against.
        let feed = Feed(started(), t0: t0)
        for _ in 0..<8 { feed.send("PostToolUseFailure", failed: "Shell") }
        #expect(feed.tracker.sessions[key]?.failureStreak == 0)
        #expect(feed.tracker.stuck(now: feed.now).isEmpty)
        #expect(feed.troubles == 0)
    }

    @Test func aWaitTheCardProvedIsSaidAsAWaitNotAMaybe() throws {
        var tracker = started()
        let shown = tracker.cursorCardShown(key, now: t0.addingTimeInterval(5))
        let waiting = try #require(shown)
        #expect(waiting.quietNudge && !waiting.mayBeWaiting, "it ends like a nudge and reads like a wait")
        let copy = Notifier.copy(for: .waiting(blocking: true, kind: .permission), session: waiting)
        #expect(copy.title == L("%@ is waiting", "Cursor"))
        #expect(Notifier.soundCategory(for: .waiting(blocking: true, kind: .permission), quietNudge: waiting.mayBeWaiting) == .permission)

        var quiet = waiting
        quiet.cardWait = false
        #expect(Notifier.copy(for: .waiting(blocking: true, kind: .permission), session: quiet).title == L("%@ may be waiting", "Cursor"),
                "a turn that only went quiet is still a maybe")
    }

    @Test func aHeldCommandIsARequestNotASignOfLife() throws {
        var tracker = started()
        var held = Hook.Message(event: "beforeShellExecution", needsInput: true, sessionID: "c1", tool: .cursor)
        held.request = Hook.Request(id: "r1", kind: .permission(tool: "Shell", summary: "Run ls", detail: nil, suggestions: []))
        let outcome = tracker.apply(held, now: t0.addingTimeInterval(1))
        #expect(outcome.requested?.request.id == "r1")
        #expect(tracker.sessions[key]?.pending?.id == "r1")
        #expect(tracker.sessions[key]?.isWaiting == true)
        let card = tracker.cursorCardShown(key, now: t0.addingTimeInterval(2))
        #expect(card == nil, "a request the notch holds is not also a card wait")
    }

    @Test func aSecondHeldCallDoesNotTakeTheCardFromTheFirst() throws {
        // Two calls held at once for one chat (made side by side, or a subagent's): the card must not change under
        // a click, so the one standing keeps it and the newcomer is not taken, which sends it to Cursor's own prompt.
        var tracker = started()
        func held(_ id: String, _ event: String = "beforeShellExecution") -> Hook.Message {
            var message = Hook.Message(event: event, needsInput: true, sessionID: "c1", tool: .cursor)
            message.request = Hook.Request(id: id, kind: .permission(tool: "Shell", summary: "Run \(id)", detail: nil, suggestions: []))
            return message
        }
        let first = tracker.apply(held("r1"), now: t0.addingTimeInterval(1))
        #expect(first.requested?.request.id == "r1")
        let second = tracker.apply(held("r2", "beforeMCPExecution"), now: t0.addingTimeInterval(2))
        #expect(second.requested == nil, "not taken: its hook is answered nothing and prints ask")
        #expect(second.requestsEnded.isEmpty, "and the first is not ended by it")
        #expect(tracker.sessions[key]?.pending?.id == "r1")
        #expect(tracker.sessions[key]?.isWaiting == true)

        // A sign of life beside a held call is not its answer.
        _ = tracker.apply(Hook.Message(event: "afterAgentThought", needsInput: false, sessionID: "c1", tool: .cursor), now: t0.addingTimeInterval(3))
        #expect(tracker.sessions[key]?.pending?.id == "r1" && tracker.sessions[key]?.isWaiting == true)

        // Once the first is answered the next call is held as usual.
        _ = tracker.resolve(requestID: "r1", resumes: true, now: t0.addingTimeInterval(4))
        let third = tracker.apply(held("r3"), now: t0.addingTimeInterval(5))
        #expect(third.requested?.request.id == "r3")
        // Claude Code's rule is unchanged: its new request replaces the one before it, whose terminal has moved on.
        var claude = SessionTracker()
        var ask = Hook.Message(event: "PermissionRequest", needsInput: true, sessionID: "s1", project: "p")
        ask.request = Hook.Request(id: "a", kind: .permission(tool: "Bash", summary: "ls", detail: nil, suggestions: []))
        _ = claude.apply(ask, now: t0)
        ask.request = Hook.Request(id: "b", kind: .permission(tool: "Bash", summary: "pwd", detail: nil, suggestions: []))
        #expect(claude.apply(ask, now: t0.addingTimeInterval(1)).requested?.request.id == "b")
    }

    @Test func aHeldCallIsInFlightAndACallHandedBackEndsWhenCursorGoesOn() throws {
        var tracker = started()
        var held = Hook.Message(event: "beforeShellExecution", needsInput: true, sessionID: "c1", tool: .cursor)
        held.request = Hook.Request(id: "r1", kind: .permission(tool: "Shell", summary: "Run ls", detail: nil, suggestions: []))
        _ = tracker.apply(held, now: t0.addingTimeInterval(1))
        #expect(tracker.sessions[key]?.commandsInFlight == 1, "so an allowed command running long is not called a possible wait")
        #expect(tracker.sessions[key]?.quietNudge == false)
        // Handed back to Cursor's own prompt: nothing is held, and the chat waits there.
        _ = tracker.resolve(requestID: "r1", resumes: false, now: t0.addingTimeInterval(2))
        #expect(tracker.sessions[key]?.isWaiting == true && tracker.sessions[key]?.pending == nil)
        // Cursor's own card for the call it was handed starts no wait of its own, so the notch is not opened on it
        // again: the call is being answered in Cursor.
        let again = tracker.cursorCardShown(key, now: t0.addingTimeInterval(3))
        #expect(again == nil)
        #expect(tracker.sessions[key]?.isWaiting == true)
        // Answered in Cursor, the command runs and ends: the wait is over without any card being read.
        _ = tracker.apply(Hook.Message(event: "afterShellExecution", needsInput: false, sessionID: "c1", tool: .cursor), now: t0.addingTimeInterval(9))
        #expect(tracker.sessions[key]?.isWorking == true)
        #expect(tracker.sessions[key]?.commandsInFlight == 0)
    }

    @Test func aBuildThatEndedBeforeAnyTaskStartedLeavesThePlanReady() throws {
        func plan(_ statuses: [TodoPlan.Status]) -> TodoPlan {
            TodoPlan(items: statuses.enumerated().map { TodoPlan.Item(id: "\($0.offset)", content: "t", status: $0.element) })
        }
        var tracker = started()
        tracker.cursorPlan(key, todos: plan([.pending, .pending]), planFile: "/p/a.plan.md", replaced: false)
        var build = Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "c1", tool: .cursor)
        build.planBuild = true
        _ = tracker.apply(build, now: t0.addingTimeInterval(1))
        #expect(tracker.sessions[key]?.planState == .building)
        let aborted = Hook.Message(event: "StopFailure", needsInput: false, sessionID: "c1", failure: "aborted", tool: .cursor)
        _ = tracker.apply(aborted, now: t0.addingTimeInterval(2))
        #expect(tracker.sessions[key]?.planState == .ready, "nothing was built: the row offers Build again")

        // A build that got somewhere stays a build when its turn ends.
        _ = tracker.apply(build, now: t0.addingTimeInterval(3))
        tracker.cursorPlan(key, todos: plan([.completed, .pending]), planFile: "/p/a.plan.md", replaced: false)
        _ = tracker.apply(Hook.Message(event: "Stop", needsInput: false, sessionID: "c1", tool: .cursor), now: t0.addingTimeInterval(4))
        #expect(tracker.sessions[key]?.planState == .building)

        // Every task cancelled is a cancelled plan, which the row can only know if the list is kept.
        tracker.cursorPlan(key, todos: plan([.cancelled, .cancelled]), planFile: "/p/a.plan.md", replaced: false)
        #expect(tracker.sessions[key]?.todos != nil)
        #expect(tracker.sessions[key]?.planState == .cancelled, "not ready: Build is not offered for a plan called off")
    }

    @Test func aPlanIsReadyThenBuildingThenDone() {
        func plan(_ statuses: [TodoPlan.Status]) -> TodoPlan {
            TodoPlan(items: statuses.enumerated().map { TodoPlan.Item(id: "\($0.offset)", content: "t", status: $0.element) })
        }
        #expect(CursorPlanState.of(plan([.pending, .pending]), built: false) == .ready)
        #expect(CursorPlanState.of(plan([.pending, .pending]), built: true) == .building)
        #expect(CursorPlanState.of(plan([.inProgress, .pending]), built: false) == .building, "a task started is a build, whoever pressed it")
        #expect(CursorPlanState.of(plan([.completed, .cancelled]), built: true) == .completed, "cancelled is out of the count")
        #expect(CursorPlanState.of(plan([.cancelled, .cancelled]), built: false) == .cancelled)
        #expect(CursorPlanState.of(plan([.completed, .blocked]), built: true) == .building, "blocked is still outstanding")
        #expect(CursorPlanState.of(nil, built: false) == .ready)
    }

    @Test func aBuildPromptMarksThePlanBuiltAndANewPlanStartsOver() {
        var tracker = started()
        var build = Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "c1", tool: .cursor)
        build.planFile = "/p/a.plan.md"
        build.planBuild = true
        _ = tracker.apply(build, now: t0.addingTimeInterval(1))
        #expect(tracker.sessions[key]?.planBuilt == true)
        var listed = Hook.Message(event: "PostToolUse", needsInput: false, sessionID: "c1", tool: .cursor)
        listed.planFile = "/p/b.plan.md"
        _ = tracker.apply(listed, now: t0.addingTimeInterval(2))
        #expect(tracker.sessions[key]?.planFile == "/p/b.plan.md")
        #expect(tracker.sessions[key]?.planBuilt == false, "another plan has not been built")
    }

    @Test func aBuildWhosePayloadNamesNoPlanStillMarksTheChatsPlanBuilt() {
        // The Build prompt's payload need not attach the plan file; the plan file reaches the row from the transcript.
        var tracker = started()
        var build = Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "c1", tool: .cursor)
        build.planBuild = true
        _ = tracker.apply(build, now: t0.addingTimeInterval(1))
        #expect(tracker.sessions[key]?.planBuilt == true)
        var listed = Hook.Message(event: "PostToolUse", needsInput: false, sessionID: "c1", tool: .cursor)
        listed.planFile = "/p/a.plan.md"
        _ = tracker.apply(listed, now: t0.addingTimeInterval(2))
        #expect(tracker.sessions[key]?.planBuilt == true, "the chat's first plan file is the plan that was built")
        #expect(tracker.sessions[key]?.planState == .building)
    }

    @Test func modeAndBackgroundReachTheRow() throws {
        var tracker = SessionTracker()
        var start = Hook.Message(event: "SessionStart", needsInput: false, sessionID: "c1", project: "proj", tool: .cursor)
        start.composerMode = "plan"
        start.background = true
        _ = tracker.apply(start, now: t0)
        let rows = SessionsCard.rows(tracker.all, hideTitles: false, jump: false, now: t0).rows
        let row = try #require(rows.first)
        #expect(row.mode == "plan")
        #expect(row.background)
        start.composerMode = "agent"
        _ = tracker.apply(start, now: t0)
        #expect(SessionsCard.rows(tracker.all, hideTitles: false, jump: false, now: t0).rows.first?.mode == nil, "plain Agent mode needs no chip")

        // A plan is made in Plan and built in Agent: the chip follows each prompt's mode, not the session's first.
        var prompt = Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "c2", project: "proj", tool: .cursor)
        prompt.composerMode = "plan"
        _ = tracker.apply(prompt, now: t0)
        let c2 = SessionTracker.key(tool: .cursor, session: "c2", host: nil)
        #expect(tracker.sessions[c2]?.composerMode == "plan")
        prompt.composerMode = "agent"
        _ = tracker.apply(prompt, now: t0.addingTimeInterval(1))
        #expect(tracker.sessions[c2]?.composerMode == "agent")
        prompt.composerMode = "background"
        _ = tracker.apply(prompt, now: t0.addingTimeInterval(2))
        let cloud = try #require(SessionsCard.rows(tracker.all, hideTitles: false, jump: false, now: t0).rows.first { $0.id == c2 })
        #expect(cloud.mode == nil && cloud.background, "a cloud agent is one chip, not two")
    }
}

/// The store's side with a stand-in for Cursor's windows, so no test reads or presses a real one.
@Suite struct CursorCardStore {
    final class FakeCursorUI: CursorUIControlling, @unchecked Sendable {
        private let lock = NSLock()
        private var _cards: [CursorCard] = []
        private var _pressed: [String] = []
        private var _released = 0
        private var _planReads = 0
        /// Whether there is the Accessibility permission to press Cursor's cards with.
        var trusted = true
        var result: CursorPressResult = .pressed
        var cards: [CursorCard] {
            get { lock.withLock { _cards } }
            set { lock.withLock { _cards = newValue } }
        }
        var pressed: [String] { lock.withLock { _pressed } }
        var released: Int { lock.withLock { _released } }
        var planReads: Int { lock.withLock { _planReads } }
        /// A read of the window that is held until `gate` is signalled, to stand for one that is out while something
        /// else happens; `scans` counts the reads begun.
        var gate: DispatchSemaphore?
        private var _scans = 0
        var scans: Int { lock.withLock { _scans } }
        func scan() -> [CursorCard] {
            let seen = lock.withLock { _scans += 1; return _cards }
            gate?.wait()
            return seen
        }
        /// Whether a read came back whole, to stand for one Cursor fell behind on.
        var whole = true
        func read() -> (cards: [CursorCard], whole: Bool) { (scan(), whole) }
        private var _refreshes: [Bool] = []
        /// For each read, whether Cursor was first asked to bring its windows' trees up to date.
        var refreshes: [Bool] { lock.withLock { _refreshes } }
        func read(refresh: Bool) -> (cards: [CursorCard], whole: Bool) {
            lock.withLock { _refreshes.append(refresh) }
            return read()
        }
        private var _answers: [(card: CursorCard, skip: Bool, named: Bool, elsewhere: Set<String>)] = []
        /// The questions whose answers were sent to Cursor's own card, each as the notch's card stood, whether it
        /// was skipped, whether only a window titled for its workspace would do, and the other chats' workspaces.
        var answers: [(card: CursorCard, skip: Bool, named: Bool, elsewhere: Set<String>)] { lock.withLock { _answers } }
        /// What sending a question's answers comes to.
        var answerResult: CursorPressResult = .pressed
        /// Run as the answers go in, to stand for what Cursor does with them (its database settling the question).
        var onAnswer: (@Sendable () -> Void)?
        /// Holds the answer on its way until signalled, to stand for one that is out while something else happens.
        var answerGate: DispatchSemaphore?
        func answer(_ card: CursorCard, skip: Bool, named: Bool, elsewhere: Set<String>) -> (result: CursorPressResult, found: String) {
            lock.withLock { _answers.append((card, skip, named, elsewhere)) }
            answerGate?.wait()
            onAnswer?()
            return (answerResult, answerResult == .gone ? "none" : "read")
        }
        func scanForPlan() -> [CursorCard] { lock.withLock { _planReads += 1; return _cards } }
        func press(_ card: CursorCard, option: String) -> CursorPressResult {
            lock.withLock { _pressed.append(card.kind.rawValue + ":" + option) }
            return result
        }
        private var _picks: [String] = []
        var picks: [String] { lock.withLock { _picks } }
        /// What a pick comes to. Nil turns the choice over on the fake's own card and hands that card back, as
        /// Cursor's window does; `stillShown` hands the card back as it was; anything else hands back none.
        var pickResult: CursorPressResult?
        func pick(_ card: CursorCard, question: Int, choice: Int) -> (result: CursorPressResult, card: CursorCard?) {
            lock.withLock {
                _picks.append("\(question):\(choice)")
                guard let index = _cards.firstIndex(where: { $0.id == card.id }) else { return (pickResult ?? .gone, nil) }
                if let pickResult { return (pickResult, pickResult == .stillShown ? _cards[index] : nil) }
                _cards[index].questions[question].choices[choice].picked.toggle()
                return (.pressed, _cards[index])
            }
        }
        func release() { lock.withLock { _released += 1 } }
    }

    /// What a stand-in for the chat-name read was asked for.
    final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var _ids: [[String]] = []
        var ids: [[String]] { lock.withLock { _ids } }
        func record(_ ids: Set<String>) { lock.withLock { _ids.append(ids.sorted()) } }
    }

    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor
    func store(_ suite: String, mirror: Bool = true) -> (UsageStore, FakeCursorUI, UserDefaults) {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let prefs = Preferences(defaults: defaults)
        prefs.cursorControl = mirror
        let store = UsageStore(prefs: prefs, providers: [], cache: ReadingCache(defaults: defaults), defaults: defaults, drainLog: nil, reportFile: nil)
        let ui = FakeCursorUI()
        store.cursorUI = ui
        return (store, ui, defaults)
    }

    func key(_ id: String) -> String { SessionTracker.key(tool: .cursor, session: id, host: nil) }

    @MainActor
    func prompt(_ store: UsageStore, _ id: String, project: String, at offset: TimeInterval = 0) {
        store.hookReceived(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: id, project: project, tool: .cursor), now: t0.addingTimeInterval(offset))
    }

    func until(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func run(_ window: String, _ command: String = "ls") -> CursorCard {
        CursorCard(kind: .run, window: window, heading: command, options: [.init(label: "Skip", path: [0]), .init(label: "Run", path: [1])])
    }
    func plan(_ name: String) -> CursorCard {
        CursorCard(kind: .plan, window: "proj", heading: name, options: [.init(label: "View Plan", path: [0]), .init(label: "Build", path: [1])])
    }
    /// A question card that can be answered from the notch: one question, two choices and the typed one.
    func asked(_ window: String, picked: Set<Int> = []) -> CursorCard {
        var card = CursorCard(kind: .question, window: window, heading: "Which fruit?",
                              options: [.init(label: "Skip", path: [8]), .init(label: "Continue", path: [9])])
        let labels = ["A apple", "B banana", "C Other..."]
        card.choices = labels
        card.questions = [.init(text: "Which fruit?", choices: labels.enumerated().map { index, label in
            .init(label: label, path: [index], picked: picked.contains(index), typed: index == 2)
        })]
        return card
    }

    @Test @MainActor func aCardThatHoldsATurnGoesOnItsRowAndAPlanCardDoesNot() {
        let suite = "NotchmeterTests.CursorCardStore.row"
        let (store, _, defaults) = store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        prompt(store, "c1", project: "proj")
        store.cursorCardsSeen([run("proj"), plan("p")], now: t0.addingTimeInterval(2))
        #expect(store.cursorCards[key("c1")]?.map(\.kind) == [.run], "the row's own View Plan and Build are the plan's buttons")
        #expect(store.sessions.sessions[key("c1")]?.isWaiting == true, "Cursor's card is the wait")
        store.cursorCardsSeen([plan("p")], now: t0.addingTimeInterval(4))
        #expect(store.cursorCards.isEmpty)
        #expect(store.sessions.sessions[key("c1")]?.isWorking == true, "answered in Cursor: the turn goes on")
    }

    @Test @MainActor func aPressTakesTheCardOffTheRowWithItsNoteInOneChange() async {
        let suite = "NotchmeterTests.CursorCardStore.pressed"
        let (store, ui, defaults) = store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        prompt(store, "c1", project: "proj")
        let card = run("proj")
        ui.cards = [card]
        await store.readCursorCards()
        #expect(store.cursorCards[key("c1")] == [card])

        // A read of the window is out when Run is pressed: what it saw is from before the press.
        ui.gate = DispatchSemaphore(value: 0)
        let stale = Task { await store.readCursorCards() }
        await until { ui.scans == 2 }
        store.pressCursorCard(card, option: "Run", sessionID: key("c1"))
        #expect(store.cursorPressing == [card.id], "the row holds the card's buttons while the press is out")
        await store.readCursorCards()
        #expect(ui.scans == 2, "and the window is not read beside a press")
        await until { store.cursorActionNotes[key("c1")] != nil }
        #expect(store.cursorCards[key("c1")] == nil, "the card is gone by the time the note says what was pressed")
        #expect(store.cursorPressing.isEmpty)
        #expect(store.sessions.sessions[key("c1")]?.isWorking == true)
        ui.gate?.signal()
        await stale.value
        #expect(store.cursorCards[key("c1")] == nil, "a read begun before the press does not put the card back")

        // A press Cursor did not take leaves the card where it is, with the note saying so.
        ui.gate = nil
        ui.result = .stillShown
        await store.readCursorCards()
        #expect(store.cursorCards[key("c1")] == [card])
        store.pressCursorCard(card, option: "Run", sessionID: key("c1"))
        await until { store.cursorActionNotes[key("c1")] == UsageStore.note(for: .stillShown, option: "Run") }
        #expect(store.cursorCards[key("c1")] == [card])
    }

    /// The app opens the notch on a card that starts a wait and closes it when the chat's cards have gone; the store
    /// says what each read of Cursor's window changed, in one call.
    @Test @MainActor func theStoreSaysWhenACardStartsAWaitAndWhenAChatsCardsHaveGone() async {
        let suite = "NotchmeterTests.CursorCardStore.opens"
        let (store, ui, defaults) = store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        var changes: [(started: [String], ended: [String])] = []
        store.cursorCardsChanged = { started, ended in changes.append((started.map(\.id), ended)) }
        prompt(store, "c1", project: "proj")
        prompt(store, "c2", project: "other", at: 1)
        let card = run("proj"), second = run("other", "make test")
        store.cursorCardsSeen([card], now: t0.addingTimeInterval(2))
        #expect(changes.count == 1 && changes[0].started == [key("c1")] && changes[0].ended.isEmpty)
        store.cursorCardsSeen([card], now: t0.addingTimeInterval(3))
        #expect(changes.count == 1, "once for the wait, not once a read")

        // One chat's card leaves as another's arrives: one change, so the panel moves from one to the other.
        store.cursorCardsSeen([second], now: t0.addingTimeInterval(4))
        #expect(changes.count == 2 && changes[1].started == [key("c2")] && changes[1].ended == [key("c1")])

        // A card out of Cursor's tree for a read and back is the same card: the wait is a wait again, and nothing
        // opens on it a second time.
        store.cursorCardsSeen([], now: t0.addingTimeInterval(5))
        #expect(changes.count == 3 && changes[2].started.isEmpty && changes[2].ended == [key("c2")])
        store.cursorCardsSeen([second], now: t0.addingTimeInterval(6))
        #expect(store.cursorCards[key("c2")] == [second])
        #expect(store.sessions.sessions[key("c2")]?.isWaiting == true)
        #expect(changes.count == 3, "no second opening for a card that only flickered")
        // The same command asked for again later is a new wait.
        store.cursorCardsSeen([], now: t0.addingTimeInterval(7))
        store.cursorCardsSeen([second], now: t0.addingTimeInterval(7 + UsageStore.cursorCardFlicker + 1))
        #expect(changes.last?.started == [key("c2")])

        // Pressed from the notch: the chat's cards end with the press, not with a later read.
        let before = changes.count
        ui.cards = [second]
        store.pressCursorCard(second, option: "Run", sessionID: key("c2"))
        await until { changes.count > before }
        #expect(changes.last?.ended == [key("c2")] && changes.last?.started.isEmpty == true)
        #expect(store.cursorCards[key("c2")] == nil)
    }

    /// A read Cursor fell behind on comes back short of cards that are still on screen. It is waited out, so the card
    /// keeps its row and the notch stays as it is; a window that never reads whole is taken as it is after three.
    @Test @MainActor func aReadCursorDidNotAnswerInTimeDoesNotTakeACardOffItsRow() async {
        let suite = "NotchmeterTests.CursorCardStore.short"
        let (store, ui, defaults) = store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        prompt(store, "c1", project: "proj")
        let card = run("proj")
        ui.cards = [card]
        await store.readCursorCards()
        #expect(store.cursorCards[key("c1")] == [card])
        ui.cards = []
        ui.whole = false
        await store.readCursorCards()
        await store.readCursorCards()
        #expect(store.cursorCards[key("c1")] == [card], "two short reads are waited out")
        ui.whole = true
        ui.cards = [card]
        await store.readCursorCards()
        #expect(store.cursorCards[key("c1")] == [card])
        ui.cards = []
        ui.whole = false
        for _ in 0..<UsageStore.cursorShortReadLimit { await store.readCursorCards() }
        #expect(store.cursorCards[key("c1")] == nil, "a window that never reads whole is believed in the end")
    }

    @Test func theEndToEndStandInReadsItsCardsFromAFileAndAPressTakesTheCardOut() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-cards-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let ui = FileCursorUI(path: file.path)
        #expect(ui.scan().isEmpty, "no file, no cards")
        try Data(#"[{"kind":"run","window":"proj","heading":"ls -la","options":["Skip","Run"]},{"kind":"question","window":"proj","heading":"Which?","choices":["A one","B two"]}]"#.utf8).write(to: file)
        let cards = ui.scan()
        #expect(cards.map(\.kind) == [.run, .question])
        #expect(cards[0].heading == "ls -la" && cards[0].command && cards[0].options.map(\.label) == ["Skip", "Run"])
        #expect(cards[1].choices == ["A one", "B two"] && cards[1].options.isEmpty)
        #expect(ui.press(cards[0], option: "Always Run") == .gone, "a button the card does not have")
        #expect(ui.press(cards[0], option: "Run") == .pressed)
        #expect(ui.scan().map(\.kind) == [.question], "the pressed card is gone, as Cursor's is")
        #expect(ui.press(cards[0], option: "Run") == .gone)
        // Only beside the oracle's own launch argument, and only once the oracle is writing: an ordinary launch is
        // never pointed at a file of cards, nor one with NOTCHMETER_ORACLE left set, nor one whose oracle file would not open.
        let both = ["Notchmeter", "--e2e-oracle", "/tmp/o.jsonl", "--e2e-cursor-cards", "/tmp/c.json"]
        #expect(FileCursorUI.path(arguments: both, oracleActive: true) == "/tmp/c.json")
        #expect(FileCursorUI.path(arguments: both, oracleActive: false) == nil)
        #expect(FileCursorUI.path(arguments: ["Notchmeter", "--e2e-cursor-cards", "/tmp/c.json"], oracleActive: true) == nil)
        #expect(FileCursorUI.path(arguments: ["Notchmeter", "--e2e-oracle", "/tmp/o.jsonl"], oracleActive: true) == nil)
    }

    @Test @MainActor func aQuestionCardIsAWaitOnItsRow() {
        let suite = "NotchmeterTests.CursorCardStore.question"
        let (store, ui, defaults) = store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        prompt(store, "c1", project: "proj")
        var question = CursorCard(kind: .question, window: "proj", heading: "Which fruit?", options: [])
        question.choices = ["A apple", "B banana", "C Other..."]
        store.cursorCardsSeen([question], now: t0.addingTimeInterval(3))
        #expect(store.cursorCards[key("c1")] == [question])
        #expect(store.sessions.sessions[key("c1")]?.isWaiting == true, "Cursor waits on the answer, and no hook says so")
        store.cursorCardsSeen([], now: t0.addingTimeInterval(9))
        #expect(store.sessions.sessions[key("c1")]?.isWorking == true)
        #expect(ui.pressed.isEmpty, "a question is answered in Cursor; nothing of it is pressed from the notch")
    }

    @Test func theStandInsQuestionIsPickedInItsFileAndSentWithContinue() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-cards-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"[{"kind":"question","window":"proj","heading":"Which fruit?","options":["Skip","Continue"],"questions":[{"text":"Which fruit?","choices":[{"label":"A apple"},{"label":"B banana"},{"label":"C Other...","typed":true}]}]}]"#.utf8).write(to: file)
        let ui = FileCursorUI(path: file.path)
        let card = try #require(ui.scan().first)
        #expect(card.questions.map(\.text) == ["Which fruit?"])
        #expect(card.choices == ["A apple", "B banana", "C Other..."] && card.questions[0].choices.map(\.typed) == [false, false, true])
        let picked = ui.pick(card, question: 0, choice: 1)
        #expect(picked.result == .pressed)
        #expect(picked.card?.questions[0].choices.map(\.picked) == [false, true, false])
        #expect(picked.card?.id == card.id)
        #expect(ui.scan().first?.questions[0].choices[1].picked == true, "the card stays in the file, with the pick on it")
        // A press turns a choice over, so one made against the card as it was a read ago is not made: the card as
        // it now reads comes back in its place.
        let stale = ui.pick(card, question: 0, choice: 1)
        #expect(stale.result == .gone && stale.card?.questions[0].choices[1].picked == true)
        #expect(ui.scan().first?.questions[0].choices[1].picked == true, "and nothing was turned over")
        let fresh = try #require(picked.card)
        #expect(ui.pick(fresh, question: 0, choice: 1).card?.questions[0].choices[1].picked == false, "a press on it as it is turns it back")
        #expect(ui.pick(card, question: 0, choice: 2).result == .gone, "the typed answer is not picked from here")
        #expect(ui.pick(card, question: 3, choice: 0).result == .gone)
        #expect(ui.press(card, option: "Continue") == .pressed)
        #expect(ui.scan().isEmpty, "sent, the card is gone")
        #expect(ui.pick(card, question: 0, choice: 0).result == .gone)
    }

    @Test func theStandInsCardGoesWhenItsQuestionIsAnsweredFromTheNotchsOwnCard() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-cards-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"[{"kind":"run","window":"proj","heading":"ls","options":["Skip","Run"]},{"kind":"question","window":"proj","heading":"Which fruit?","options":["Skip","Continue"],"questions":[{"text":"Which fruit?","choices":[{"label":"A apple"},{"label":"B banana"},{"label":"C Other...","typed":true}]}]}]"#.utf8).write(to: file)
        let ui = FileCursorUI(path: file.path)
        let other = CursorQuestions.card(CursorAsked(questions: [.init(prompt: "Which fruit?", allowsSeveral: false, options: ["apple", "pear"])]), window: "proj")
        #expect(ui.answer(other, skip: false, named: false, elsewhere: []).result == .gone, "another question's card is not in the file")
        let held = CursorQuestions.card(CursorAsked(questions: [.init(prompt: "Which fruit?", allowsSeveral: false, options: ["apple", "banana"])]), window: "proj")
        let sent = ui.answer(held, skip: false, named: false, elsewhere: [])
        #expect(sent.result == .pressed && sent.found == "read")
        #expect(ui.scan().map(\.kind) == [.run], "the question's card is gone, and the other card is not")
        #expect(ui.answer(held, skip: true, named: false, elsewhere: []).result == .gone)
    }

    @Test @MainActor func cursorIsAskedToBringItsWindowsUpToDateOnlyForAChatThatHasGoneQuiet() async {
        let suite = "NotchmeterTests.CursorCardStore.refresh"
        let (store, ui, defaults) = store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        // A read is timed by the clock, so the chats' events are too. One heard from this moment is working, and
        // its window is not asked for more than it has.
        store.hookReceived(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "c1", project: "proj", tool: .cursor), now: Date())
        #expect(!store.cursorRefreshWanted())
        await store.readCursorCards()
        #expect(ui.refreshes == [false])
        // One that has said nothing for a moment may be held by a card its window has not said, as a minimised
        // window may not.
        let quiet = Date().addingTimeInterval(UsageStore.cursorRefreshQuiet + 1)
        #expect(store.cursorRefreshWanted(now: quiet))
        store.hookReceived(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "c2", project: "other", tool: .cursor),
                           now: Date().addingTimeInterval(-30))
        await store.readCursorCards()
        #expect(ui.refreshes == [false, true])
        // A chat whose turn has ended holds no card, and neither does another assistant's.
        store.hookReceived(Hook.Message(event: "Stop", needsInput: false, sessionID: "c1", project: "proj", tool: .cursor), now: Date())
        store.hookReceived(Hook.Message(event: "Stop", needsInput: false, sessionID: "c2", project: "other", tool: .cursor), now: Date())
        store.hookReceived(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "k1", project: "proj", tool: .claude), now: Date().addingTimeInterval(-30))
        #expect(!store.cursorRefreshWanted(now: quiet))
    }

    @Test @MainActor func aPickShowsOnTheCardWhichStaysUntilContinue() async throws {
        let suite = "NotchmeterTests.CursorCardStore.pick"
        let (store, ui, defaults) = store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        prompt(store, "c1", project: "proj")
        var opened = 0
        store.cursorCardsChanged = { started, _ in opened += started.count }
        let card = asked("proj")
        ui.cards = [card]
        await store.readCursorCards()
        #expect(store.cursorCards[key("c1")] == [card])
        #expect(opened == 1)

        store.pickCursorChoice(card, question: 0, choice: 1, sessionID: key("c1"))
        #expect(store.cursorPressing == [card.id], "the card's buttons are held while the pick is out")
        store.pickCursorChoice(card, question: 0, choice: 0, sessionID: key("c1"))
        await until { store.cursorPressing.isEmpty }
        #expect(ui.picks == ["0:1"], "and a second press beside it goes nowhere")
        let shown = try #require(store.cursorCards[key("c1")]?.first)
        #expect(shown.questions[0].choices.map(\.picked) == [false, true, false], "what Cursor now shows, with no wait for the next read")
        #expect(shown.id == card.id)
        #expect(store.sessions.sessions[key("c1")]?.isWaiting == true, "picked is not answered: Cursor waits for Continue")
        #expect(opened == 1, "and the notch is not opened on the card a second time")
        #expect(store.cursorActionNotes[key("c1")] == nil, "a pick that took says nothing; the card shows it")

        // Continue sends the answers: the card goes, as any of Cursor's cards does on its button.
        store.pressCursorCard(shown, option: "Continue", sessionID: key("c1"))
        await until { store.cursorActionNotes[key("c1")] != nil }
        #expect(ui.pressed == ["question:Continue"])
        #expect(store.cursorCards[key("c1")] == nil)
        #expect(store.sessions.sessions[key("c1")]?.isWorking == true)
        #expect(store.cursorActionNotes[key("c1")] == UsageStore.note(for: .pressed, option: "Continue"))
    }

    @Test @MainActor func aPickThatCannotBeReadBackIsTheLastOnItsCard() async {
        let suite = "NotchmeterTests.CursorCardStore.pickUnread"
        let (store, ui, defaults) = store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        prompt(store, "c1", project: "proj")
        let card = asked("proj", picked: [1])
        ui.cards = [card]
        await store.readCursorCards()

        // A choice that was picked and stays picked is a question with one answer keeping it: nothing to say.
        ui.pickResult = .stillShown
        store.pickCursorChoice(card, question: 0, choice: 1, sessionID: key("c1"))
        await until { ui.picks.count == 1 && store.cursorPressing.isEmpty }
        #expect(store.cursorActionNotes[key("c1")] == nil)
        #expect(store.cursorCards[key("c1")] == [card], "and the card is still answered here")

        // One that was not picked and still is not: Cursor did not take it, or does not say that it did. The next
        // press would be made without knowing what this one did, so the card is answered in Cursor from here on.
        store.pickCursorChoice(card, question: 0, choice: 0, sessionID: key("c1"))
        await until { ui.picks.count == 2 && store.cursorPressing.isEmpty }
        #expect(store.cursorActionNotes[key("c1")] == L("Pressed %@, but Cursor does not show it picked", "A"))
        #expect(store.cursorCards[key("c1")] == [card.shownOnly])
        #expect(store.cursorCards[key("c1")]?.first?.id == card.id, "the same card, so the notch is not opened on it again")
        #expect(store.sessions.sessions[key("c1")]?.isWaiting == true)
        store.pickCursorChoice(card, question: 0, choice: 0, sessionID: key("c1"))
        store.pressCursorCard(card, option: "Continue", sessionID: key("c1"))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(ui.picks.count == 2 && ui.pressed.isEmpty, "and nothing more of it is pressed, by a button drawn before it changed")
        // Read again as a card that says what is picked, it is still shown only: until it has gone.
        await store.readCursorCards()
        #expect(store.cursorCards[key("c1")] == [card.shownOnly])
        // It is forgotten once a read of the window finds other cards and not this one. A read that finds nothing
        // at all is no proof: one Cursor did not answer in time is empty too.
        ui.cards = []
        await store.readCursorCards()
        ui.cards = [card]
        await store.readCursorCards()
        #expect(store.cursorCards[key("c1")] == [card.shownOnly])
        ui.cards = [run("proj")]
        await store.readCursorCards()
        ui.cards = [card]
        ui.pickResult = nil
        await store.readCursorCards()
        #expect(store.cursorCards[key("c1")] == [card], "asked again later, it is a card like any other")
    }

    @Test @MainActor func aPickOnACardThatChangedPressesNothingAndOneThatTookClearsWhatWasSaid() async {
        let suite = "NotchmeterTests.CursorCardStore.pickGone"
        let (store, ui, defaults) = store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        prompt(store, "c1", project: "proj")
        let card = asked("proj")
        ui.cards = [card]
        await store.readCursorCards()

        ui.pickResult = .gone
        store.pickCursorChoice(card, question: 0, choice: 0, sessionID: key("c1"))
        await until { store.cursorActionNotes[key("c1")] != nil }
        #expect(store.cursorActionNotes[key("c1")] == UsageStore.note(for: .gone, option: "A"))
        #expect(store.cursorCards[key("c1")] == [card], "the card is still answered here: nothing was pressed on it")

        // A pick that takes is the news now, and the card says it: what the last press came to is taken down.
        ui.pickResult = nil
        store.pickCursorChoice(card, question: 0, choice: 0, sessionID: key("c1"))
        await until { store.cursorCards[key("c1")]?.first?.questions.first?.choices.first?.picked == true }
        #expect(store.cursorActionNotes[key("c1")] == nil)

        // A card that went with the pick was answered by it.
        ui.pickResult = .pressed
        let shown = store.cursorCards[key("c1")]?.first ?? card
        store.pickCursorChoice(shown, question: 0, choice: 1, sessionID: key("c1"))
        await until { store.cursorCards[key("c1")] == nil }
        #expect(store.cursorCards[key("c1")] == nil)
        #expect(store.sessions.sessions[key("c1")]?.isWorking == true)
    }

    @Test @MainActor func aCardCursorWillNotTakeAPressOnIsAnsweredInCursor() async {
        let suite = "NotchmeterTests.CursorCardStore.refused"
        let (store, ui, defaults) = store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        prompt(store, "c1", project: "proj")
        prompt(store, "c2", project: "other", at: 1)
        let card = asked("proj"), second = asked("other")
        ui.cards = [card, second]
        await store.readCursorCards()
        #expect(store.cursorCards[key("c1")] == [card] && store.cursorCards[key("c2")] == [second])

        // Continue that would not take a press: said, and the card is no longer answered here.
        ui.result = .refused
        store.pressCursorCard(card, option: "Continue", sessionID: key("c1"))
        await until { store.cursorActionNotes[key("c1")] != nil }
        #expect(store.cursorActionNotes[key("c1")] == L("Cursor would not take the press; answer it in Cursor"))
        #expect(store.cursorCards[key("c1")] == [card.shownOnly])
        #expect(store.cursorCards[key("c2")] == [second], "the other chat's card is its own")
        // A choice that would not: the same.
        ui.pickResult = .refused
        store.pickCursorChoice(second, question: 0, choice: 0, sessionID: key("c2"))
        await until { store.cursorActionNotes[key("c2")] != nil }
        #expect(store.cursorActionNotes[key("c2")] == UsageStore.note(for: .refused, option: "A"))
        #expect(store.cursorCards[key("c2")] == [second.shownOnly])
        // A Run card that would not take its press keeps its buttons: there is nothing else to show of it.
        prompt(store, "c3", project: "third", at: 2)
        let command = run("third")
        ui.cards = [card, second, command]
        await store.readCursorCards()
        store.pressCursorCard(command, option: "Run", sessionID: key("c3"))
        await until { store.cursorActionNotes[key("c3")] != nil }
        #expect(store.cursorCards[key("c3")] == [command])
    }

    @Test @MainActor func nothingIsPickedWithTheMirrorOffOrForAChoiceTheCardDoesNotHave() async {
        let suite = "NotchmeterTests.CursorCardStore.pickGuards"
        let (store, ui, defaults) = store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        prompt(store, "c1", project: "proj")
        let card = asked("proj")
        ui.cards = [card]
        await store.readCursorCards()
        store.pickCursorChoice(card, question: 0, choice: 7, sessionID: key("c1"))
        store.pickCursorChoice(card, question: 2, choice: 0, sessionID: key("c1"))
        store.prefs.cursorControl = false
        store.pickCursorChoice(card, question: 0, choice: 0, sessionID: key("c1"))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(ui.picks.isEmpty && store.cursorPressing.isEmpty)
    }

    @Test @MainActor func aQuestionIsAnsweredHereOnlyWhereItsWordsAreShown() {
        let card = asked("proj")
        #expect(CursorCardView.answersHere(card, hideDetails: false))
        #expect(CursorCardView.offered(card, hideDetails: false).map(\.label) == ["Skip", "Continue"])
        // Titles off, or the screen shared: the choices are not drawn, and Continue is not offered on a question
        // nobody can read. Answer in Cursor is what is left.
        #expect(!CursorCardView.answersHere(card, hideDetails: true))
        #expect(CursorCardView.offered(card, hideDetails: true).isEmpty)
        // A card Cursor's window says too little of is shown and answered there, as before.
        var shown = CursorCard(kind: .question, window: "proj", heading: "Which fruit?", options: [])
        shown.choices = ["A apple", "B banana"]
        #expect(!CursorCardView.answersHere(shown, hideDetails: false) && CursorCardView.offered(shown, hideDetails: false).isEmpty)
        // Every other card keeps its buttons whatever is hidden.
        #expect(CursorCardView.offered(run("proj"), hideDetails: true).map(\.label) == ["Skip", "Run"])
        // A choice is drawn as its letter, set apart, and then its words: "B A second runner" read as one run of words.
        #expect(CursorCardView.lettered("B A second runner") == ("B", "A second runner"))
        #expect(CursorCardView.lettered("A apple") == ("A", "apple"))
        #expect(CursorCardView.lettered("D Other...") == ("D", "Other..."))
        #expect(CursorCardView.lettered("apple") == (nil, "apple"), "a label with no letter of its own is drawn as it is")
        #expect(CursorCardView.lettered("a pple") == (nil, "a pple"))
        #expect(CursorCardView.lettered("A ") == (nil, "A "))
        // Where a choice is only listed, or spoken, it is one line of words.
        #expect(CursorCardView.listed("B A second runner") == "B. A second runner")
        #expect(CursorCardView.listed("apple") == "apple")
        // Drawn, the card with its choices to press is the taller of the two.
        func height(_ card: CursorCard, hidden: Bool) -> CGFloat {
            let host = NSHostingView(rootView: CursorCardView(card: card, hideDetails: hidden, press: { _ in }).frame(width: 360))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        #expect(height(card, hidden: false) > height(card, hidden: true))
    }

    @Test func aPicksNoteNamesTheChoiceByItsLetter() {
        let choice = CursorCard.Choice(label: "B banana, with a good deal more said about it", path: [1], picked: false, typed: false)
        #expect(UsageStore.note(forPick: .pressed, choice: choice) == nil)
        #expect(UsageStore.note(forPick: .stillShown, choice: choice) == L("Pressed %@, but Cursor does not show it picked", "B"))
        #expect(UsageStore.note(forPick: .gone, choice: choice) == UsageStore.note(for: .gone, option: "B"))
        #expect(UsageStore.note(forPick: .refused, choice: choice) == L("Cursor would not take the press; answer it in Cursor"))
        // A choice that was picked and still is has nothing to say for itself.
        let kept = CursorCard.Choice(label: "A apple", path: [0], picked: true, typed: false)
        #expect(UsageStore.note(forPick: .stillShown, choice: kept) == nil)
        #expect(UsageStore.note(forPick: .unavailable, choice: choice) == UsageStore.note(for: .unavailable, option: "B"))
    }

    @Test @MainActor func aCardStaysOnTheRowItWasFirstPutOn() {
        let suite = "NotchmeterTests.CursorCardStore.sticky"
        let (store, _, defaults) = store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        prompt(store, "c1", project: "one", at: 0)
        prompt(store, "c2", project: "two", at: 1)
        let card = run("Cursor Agents")
        store.cursorCardsSeen([card], now: t0.addingTimeInterval(2))
        #expect(store.cursorCards[key("c2")]?.count == 1, "the chat heard from last")
        // The other chat goes on working while this one waits; the card does not jump to it.
        store.hookReceived(Hook.Message(event: "afterAgentThought", needsInput: false, sessionID: "c1", tool: .cursor), now: t0.addingTimeInterval(3))
        store.cursorCardsSeen([card], now: t0.addingTimeInterval(4))
        #expect(store.cursorCards[key("c2")]?.count == 1)
        #expect(store.cursorCards[key("c1")] == nil)
    }

    @Test @MainActor func aCardInTheAgentsWindowGoesToTheChatItsHeaderNames() async {
        // Two chats in a turn at once, and the Agents window, whose title names no workspace. The card is the first
        // chat's; the second spoke last. Cursor's own chat names settle it, read once when the card first shows.
        let suite = "NotchmeterTests.CursorCardStore.names"
        let (store, _, defaults) = store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        prompt(store, "aaaa-1111", project: "one", at: 0)
        prompt(store, "bbbb-2222", project: "two", at: 1)
        let asked = Asked()
        store.cursorChatNameReader = { ids in
            asked.record(ids)
            return ["aaaa-1111": "Release calendar", "bbbb-2222": "Usage export"]
        }
        var card = run("Cursor Agents")
        card.chat = "Release calendar"

        store.cursorCardsSeen([card], now: t0.addingTimeInterval(2))
        #expect(store.cursorCards.isEmpty, "not put on the chat heard from last while the names are being read")
        await until { store.sessions.sessions[key("aaaa-1111")]?.sessionName != nil }
        #expect(asked.ids == [["aaaa-1111", "bbbb-2222"]], "one read, for the chats that could own the card")
        store.cursorCardsSeen([card], now: t0.addingTimeInterval(3))
        #expect(store.cursorCards[key("aaaa-1111")]?.count == 1, "the chat the window names")
        #expect(store.cursorCards[key("bbbb-2222")] == nil)
        #expect(store.sessions.sessions[key("aaaa-1111")]?.isWaiting == true)
        #expect(store.sessions.sessions[key("bbbb-2222")]?.isWorking == true)
        store.cursorCardsSeen([card], now: t0.addingTimeInterval(4))
        #expect(asked.ids.count == 1, "and the names are not read again for the same card")
    }

    @Test @MainActor func aChatCursorHasNotNamedYetFallsBackToTheOneHeardFromLast() async {
        let suite = "NotchmeterTests.CursorCardStore.unnamed"
        let (store, _, defaults) = store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        prompt(store, "aaaa-1111", project: "one", at: 0)
        prompt(store, "bbbb-2222", project: "two", at: 1)
        let asked = Asked()
        store.cursorChatNameReader = { ids in
            asked.record(ids)
            return [:]
        }
        var card = run("Cursor Agents")
        card.chat = "New Agent"
        store.cursorCardsSeen([card], now: t0.addingTimeInterval(2))
        #expect(store.cursorCards.isEmpty)
        // The card is placed by the first read of the window after the look-up has come back, whenever that is.
        await until {
            store.cursorCardsSeen([card], now: t0.addingTimeInterval(3))
            return !store.cursorCards.isEmpty
        }
        #expect(asked.ids.count == 1, "looked up once, however many reads of the window it took")
        #expect(store.cursorCards[key("bbbb-2222")]?.count == 1, "no name to go by: the chat heard from last, as before")
        // A read that came back with nothing (Cursor did not answer in time) does not have the card looked up again.
        store.cursorCardsSeen([], now: t0.addingTimeInterval(4))
        store.cursorCardsSeen([card], now: t0.addingTimeInterval(5))
        #expect(asked.ids.count == 1)

        // With titles off nothing of a chat's name is read, so there is nothing to wait for.
        let quiet = "NotchmeterTests.CursorCardStore.titlesoff"
        let (silent, _, quietDefaults) = self.store(quiet)
        defer { quietDefaults.removePersistentDomain(forName: quiet) }
        silent.prefs.sessionTitles = false
        prompt(silent, "aaaa-1111", project: "one", at: 0)
        prompt(silent, "bbbb-2222", project: "two", at: 1)
        let never = Asked()
        silent.cursorChatNameReader = { ids in
            never.record(ids)
            return [:]
        }
        silent.cursorCardsSeen([card], now: t0.addingTimeInterval(2))
        #expect(silent.cursorCards[key("bbbb-2222")]?.count == 1)
        #expect(never.ids.isEmpty)
    }

    @Test @MainActor func cursorsWindowsAreReadOnlyWhileAChatIsInATurn() {
        let suite = "NotchmeterTests.CursorCardStore.wanted"
        let (store, _, defaults) = store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!store.cursorWatchWanted, "no Cursor chat at all")
        prompt(store, "c1", project: "proj")
        #expect(store.cursorWatchWanted)
        store.hookReceived(Hook.Message(event: "Stop", needsInput: false, sessionID: "c1", project: "proj", tool: .cursor), now: t0.addingTimeInterval(5))
        #expect(!store.cursorWatchWanted, "a finished chat's row costs Cursor nothing however long it stays")
        prompt(store, "c1", project: "proj", at: 6)
        store.prefs.cursorControl = false
        #expect(!store.cursorWatchWanted)
    }

    @Test @MainActor func buildReadsCursorItselfAndPressesThePlansBuild() async {
        let suite = "NotchmeterTests.CursorCardStore.build"
        let (store, ui, defaults) = store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        prompt(store, "c1", project: "proj")
        ui.cards = [plan("hello and ls")]
        // A path outside ~/.cursor/plans names no plan and is never opened; the one plan card on screen is the plan.
        store.cursorPlanAction("/nowhere/x.plan.md", .build, sessionID: key("c1"))
        await until { store.cursorActionNotes[key("c1")] != nil }
        #expect(ui.planReads == 1, "no card had been read for this idle chat: Build takes its own read")
        #expect(ui.pressed == ["plan:Build"])
        #expect(store.cursorActionNotes[key("c1")] == UsageStore.note(for: .pressed, option: "Build"))

        ui.cards = []
        store.cursorPlanAction("/nowhere/x.plan.md", .build, sessionID: key("c1"))
        await until { store.cursorActionNotes[key("c1")] != UsageStore.note(for: .pressed, option: "Build") }
        #expect(ui.pressed == ["plan:Build"], "no card on screen: nothing more is pressed, and the row says so")
        #expect(store.cursorActionNotes[key("c1")]?.isEmpty == false)

        store.releaseCursorTree()
        await until { ui.released == 1 }
        store.releaseCursorTree()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(ui.released == 1, "Cursor is told once per spell of reading")
    }

    @Test @MainActor func aPlanFileChangedWithNoHookIsReadAgain() async throws {
        let suite = "NotchmeterTests.CursorCardStore.planfile"
        let (store, _, defaults) = store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-plan-watch-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: home) }
        let transcript = home.appendingPathComponent(".cursor/projects/p/agent-transcripts/c1/c1.jsonl")
        let plan = home.appendingPathComponent(".cursor/plans/watch_1a2b3c4d.plan.md")
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plan.deletingLastPathComponent(), withIntermediateDirectories: true)
        let created = #"{"role":"assistant","message":{"content":[{"type":"tool_use","name":"CreatePlan","input":{"name":"watch","todos":[{"id":"a","content":"One"},{"id":"b","content":"Two"}]}}]}}"#
        try Data(created.utf8 + [0x0A]).write(to: transcript)
        func write(_ a: String, _ b: String, at date: Date) throws {
            try "---\nname: watch\ntodos:\n  - id: a\n    content: One\n    status: \(a)\n  - id: b\n    content: Two\n    status: \(b)\n---\n"
                .write(to: plan, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: plan.path)
        }
        // The store stamps what it reads with the real clock, so the hook events here are on it too: a turn dated
        // months from the read would age the session out between them.
        let start = Date()
        try write("pending", "pending", at: start)
        store.cursorHome = home

        var prompt = Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "c1", project: "proj", tool: .cursor)
        prompt.transcriptPath = transcript.path
        store.hookReceived(prompt, now: start)
        await until { store.sessions.sessions[key("c1")]?.todos?.total == 2 }
        #expect(store.sessions.sessions[key("c1")]?.todos?.done == 0)
        #expect(store.sessions.sessions[key("c1")]?.planFile == plan.path)
        store.hookReceived(Hook.Message(event: "Stop", needsInput: false, sessionID: "c1", project: "proj", tool: .cursor), now: Date())

        // Nothing changed: the check costs a stat and reads nothing.
        store.refreshChangedCursorPlans()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(store.sessions.sessions[key("c1")]?.todos?.done == 0)

        // The plan is shown on its row (View Plan), as the file reads now.
        var summary = "as first written"
        store.readPlan = { _ in CursorPlanFiles.Preview(name: "p", summary: summary) }
        store.cursorPlanAction(plan.path, .view, sessionID: key("c1"))
        #expect(store.planPreviews[key("c1")]?.preview.summary == "as first written")

        // Both ticked in Cursor's plan editor, between turns, with no hook to say so.
        summary = "as rewritten"
        try write("completed", "completed", at: start.addingTimeInterval(60))
        store.refreshChangedCursorPlans()
        await until { store.sessions.sessions[key("c1")]?.todos?.done == 2 }
        #expect(store.sessions.sessions[key("c1")]?.todos?.done == 2)
        #expect(store.sessions.sessions[key("c1")]?.isWorking == false, "a file read is no turn")
        #expect(store.planPreviews[key("c1")]?.preview.summary == "as rewritten", "the plan on the row is read again with its file, not left as it was beside a Build for the new one")
        // The panel it was shown in closes: the words are let go, and the next View Plan reads the file afresh.
        store.closePlanPreviews()
        #expect(store.planPreviews.isEmpty && store.openSessionLists.isEmpty)
    }

    @Test @MainActor func withTheSettingOffBuildPressesNothing() async {
        let suite = "NotchmeterTests.CursorCardStore.off"
        let (store, ui, defaults) = store(suite, mirror: false)
        defer { defaults.removePersistentDomain(forName: suite) }
        prompt(store, "c1", project: "proj")
        ui.cards = [plan("p")]
        store.cursorPlanAction("/nowhere/x.plan.md", .build, sessionID: key("c1"))
        #expect(store.cursorActionNotes[key("c1")]?.isEmpty == false)
        store.pressCursorCard(run("proj"), option: "Run", sessionID: key("c1"))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(ui.pressed.isEmpty && ui.planReads == 0)
    }
}

/// Where each Cursor feature comes from, feature by feature.
@Suite struct CursorCapabilityReport {
    @Test func eachFeatureFallsBackOnItsOwn() {
        var inputs = CursorCapabilities.Inputs()
        inputs.version = "3.23.12"
        inputs.hookInstalled = true
        inputs.hookCurrent = true
        func source(_ feature: String) -> CursorCapabilities.Source? { CursorCapabilities.entries(inputs).first { $0.feature == feature }?.source }
        #expect(source("sessions") == .hook)
        #expect(source("plans and tasks") == .localData)
        #expect(source("run approval") == .openOnly)
        #expect(source("build") == .openOnly)
        #expect(source("questions") == .openOnly)
        inputs.mirrorCards = true
        #expect(source("build") == .openOnly, "the switch alone is not the permission")
        inputs.trusted = true
        #expect(source("build") == .openOnly, "a closed Cursor has no card to read")
        #expect(CursorCapabilities.entries(inputs).first { $0.feature == "build" }?.reason == "Cursor is not running")
        inputs.running = true
        #expect(source("build") == .accessibility)
        #expect(source("run approval") == .accessibility)
        #expect(source("questions") == .accessibility, "a question is answered through the same reading of Cursor's cards")
        inputs.requireApproval = true
        #expect(source("run approval") == .hook)
        inputs.hookCurrent = false
        #expect(source("run approval") == .accessibility, "an out-of-date hook cannot hold a call")
        inputs.readsSessions = false
        #expect(CursorCapabilities.entries(inputs).map(\.source) == [.unavailable])
        #expect(CursorCapabilities.line(CursorCapabilities.Inputs()).hasPrefix("Cursor not installed: "))
    }
}

/// Cursor's numbers read safely: a malformed value is no value, never a trap, a negative count or a misread sign.
@Suite struct CursorNumberValidation {
    @Test func countsAreWholeFiniteAndNonNegative() {
        #expect(JSON.count(42) == 42)
        #expect(JSON.count(42.0) == 42)
        #expect(JSON.count(42.9) == nil, "a fraction of a token is no count, and is not rounded into one")
        #expect(JSON.count("1.5") == nil)
        #expect(JSON.count("17") == 17)
        #expect(JSON.count(-1) == nil)
        #expect(JSON.count(1e300) == nil, "Int(1e300) would trap the app")
        #expect(JSON.count(Double.nan) == nil)
        #expect(JSON.count(Double.infinity) == nil)
        #expect(JSON.count("12abc") == nil)
        #expect(JSON.count(true) == nil, "a JSON true is no count of one")
        #expect(JSON.count("0x10") == nil, "and a hex string is no sixteen")
        #expect(JSON.count("1e3") == nil)
        #expect(JSON.count("17.0") == 17)
        #expect(JSON.count(nil) == nil)
    }

    @Test func moneyKeepsItsSignAndItsDigits() {
        #expect(JSON.money("$0.05") == 0.05)
        #expect(JSON.money("$1,234.56") == 1234.56)
        #expect(JSON.money("-$0.05") == -0.05, "a refund stays a refund")
        #expect(JSON.money("0.05 (included)") == 0.05)
        #expect(JSON.money("-") == nil)
        #expect(JSON.money("1.2.3") == nil, "two decimal points are no number")
        #expect(JSON.money("") == nil)
        #expect(JSON.money("$1 + $2") == nil, "two amounts are never joined into twelve dollars")
        #expect(JSON.money("$1,2") == nil, "a comma that separates no thousands is not dropped to make twelve")
        #expect(JSON.money("12,345,6") == nil)
        #expect(JSON.money("1,234") == 1234)
        #expect(JSON.money("That is $5.") == 5, "a full stop that ends the sentence is not the number's")
        #expect(JSON.money("on-demand: $0.12") == 0.12, "a hyphen earlier in the words is no minus")
        #expect(JSON.money("\u{2013}$3.10") == -3.1, "a dash written against the amount is one")
        #expect(JSON.money("claude-4 included") == nil, "a number that is part of a name is no amount")
        #expect(JSON.money("5¢") == nil && JSON.money("$1.2k") == nil && JSON.money("12%") == nil, "nor one with a unit or a multiplier on it")
        #expect(JSON.money("USD 5.00") == 5 && JSON.money("5.00 USD") == 5)
        #expect(JSON.money("0.05 (2 requests)") == nil)
        #expect(JSON.money("$12") == 12)
        #expect(JSON.money(".5") == 0.5)
        #expect(JSON.money("\u{2212}$3.10") == -3.1, "a typographic minus is a minus")
        #expect(JSON.money("1,000,000.25") == 1_000_000.25)
    }

    @Test func eventTimesOutsideAnyPossibleCursorEventAreDropped() {
        #expect(CursorProvider.eventDate(1_756_728_000_000) == Date(timeIntervalSince1970: 1_756_728_000), "milliseconds")
        #expect(CursorProvider.eventDate(1_756_728_000) == Date(timeIntervalSince1970: 1_756_728_000), "seconds")
        #expect(CursorProvider.eventDate(0) == nil)
        #expect(CursorProvider.eventDate(-5) == nil)
        #expect(CursorProvider.eventDate(.infinity) == nil)
        #expect(CursorProvider.eventDate(86_400) == nil, "1970 is no Cursor event")
        #expect(CursorProvider.eventDate(9_999_999_999_999) == nil, "2286 is no Cursor event either")
    }

    @Test func aMalformedEventRowNeitherTrapsNorGoesNegative() {
        let json = #"{"usageEventsDisplay":[{"timestamp":"1756728000000","model":"m","tokenUsage":{"inputTokens":1e300,"outputTokens":-4,"cacheReadTokens":"12","totalCents":"x"}},{"timestamp":"1756728000000","model":"m","usageBasedCosts":"-$0.25"}]}"#
        let page = CursorProvider.parseUsageEvents(Data(json.utf8))
        #expect(page.events.count == 2)
        #expect(page.events[0].tokens.input == 0)
        #expect(page.events[0].tokens.output == 0)
        #expect(page.events[0].tokens.cacheRead == 12)
        #expect(page.events[0].costUSD == 0)
        #expect(page.events[1].costUSD == -0.25)
    }
}
