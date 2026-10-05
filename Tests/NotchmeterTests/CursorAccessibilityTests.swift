import Foundation
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
        let found = CursorCards.detect(in: window, title: "plan.md — enrollhere")
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
    /// for one with several alike: the choices are buttons, Skip and Continue are plain text.
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
        #expect(card.options.isEmpty, "Continue is no button in Cursor's tree, so nothing is offered to press")
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
        let sessions = [session("a", "enrollhere", 1), session("b", "enrollhere", 5), session("c", "notchmeter", 9), session("d", "enrollhere", 20, tool: .claude)]
        #expect(CursorCards.session(for: run("plan.md — enrollhere"), among: sessions) == "b", "the most recent of the workspace's chats")
        #expect(CursorCards.session(for: run("notchmeter"), among: sessions) == "c")
        #expect(CursorCards.session(for: run("elsewhere"), among: sessions) == nil, "several chats and another workspace's window: no guess")
        #expect(CursorCards.session(for: run("elsewhere"), among: [session("a", nil, 1)]) == "a", "the only Cursor chat there is")
        #expect(CursorCards.session(for: run("x"), among: [session("r", "x", 1, host: "devbox")]) == nil, "a remote chat's window is not on this Mac")

        // A card that holds a turn belongs to a chat that is in one: eight rows and one of them working is no puzzle.
        let idle = (0..<7).map { session("idle\($0)", "enrollhere", 100 + TimeInterval($0), working: false) }
        #expect(CursorCards.session(for: run("Cursor Agents"), among: idle + [session("busy", "tools", 1)]) == "busy")
        #expect(CursorCards.session(for: run("worktree-folder-name"), among: idle + [session("busy", "tools", 1)]) == "busy",
                "a worktree's window is titled by its folder and its session by its repository")

        // The Agents window names no workspace. Its chat's name settles it where a row carries that name; else the
        // chat heard from last.
        let two = [session("x", "enrollhere", 1, title: "Find NB screener code"), session("y", "tools", 9, title: "Map Cursor plan ingestion")]
        #expect(CursorCards.session(for: run("Cursor Agents", chat: "Find NB screener code"), among: two) == "x")
        #expect(CursorCards.session(for: run("Cursor Agents", chat: "Some other name"), among: two) == "y")
        // Cursor's own name for a chat is the row's session name; its title is whatever was last typed.
        var named = two
        named[0].title = "called and i heard hello"
        named[0].sessionName = "Find NB screener code"
        #expect(CursorCards.session(for: run("Cursor Agents", chat: "Find NB screener code"), among: named) == "x")
        #expect(CursorCards.session(for: run("Cursor Agents"), among: two) == "y")

        // Whose names are worth reading: several chats could own the card, its window names the chat, and no row
        // carries that name yet.
        #expect(CursorCards.unnamedCandidates(for: run("Cursor Agents", chat: "Some other name"), among: two).map(\.id) == ["x", "y"])
        #expect(CursorCards.unnamedCandidates(for: run("Cursor Agents", chat: "Find NB screener code"), among: two).isEmpty, "a row already has it")
        #expect(CursorCards.unnamedCandidates(for: run("Cursor Agents"), among: two).isEmpty, "the window names no chat")
        #expect(CursorCards.unnamedCandidates(for: run("Cursor Agents", chat: "Anything"), among: [two[0]]).isEmpty, "one candidate needs no name")
        #expect(CursorCards.chatName("  Three   echoes\nplan ") == "Three echoes", "cleaned as a name read from Cursor is")

        // A plan card holds no turn, so an idle chat can own one.
        let plan = CursorCard(kind: .plan, window: "enrollhere", heading: "p", options: [.init(label: "Build", path: [0])])
        #expect(CursorCards.session(for: plan, among: [session("i", "enrollhere", 1, working: false), session("w", "tools", 5)]) == "i")
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
        var trusted: Bool { true }
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
        func scanForPlan() -> [CursorCard] { lock.withLock { _planReads += 1; return _cards } }
        func press(_ card: CursorCard, option: String) -> CursorPressResult {
            lock.withLock { _pressed.append(card.kind.rawValue + ":" + option) }
            return result
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
            return ["aaaa-1111": "Holiday greeting line", "bbbb-2222": "Usage export"]
        }
        var card = run("Cursor Agents")
        card.chat = "Holiday greeting line"

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
        inputs.mirrorCards = true
        #expect(source("build") == .openOnly, "the switch alone is not the permission")
        inputs.trusted = true
        #expect(source("build") == .openOnly, "a closed Cursor has no card to read")
        #expect(CursorCapabilities.entries(inputs).first { $0.feature == "build" }?.reason == "Cursor is not running")
        inputs.running = true
        #expect(source("build") == .accessibility)
        #expect(source("run approval") == .accessibility)
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
