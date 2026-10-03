import Foundation
import Testing
@testable import Notchmeter

/// Cursor's own cards read from a snapshot of its Accessibility tree: recognised by their buttons, never pressed
/// on a guess, and put on the right session. The trees are transcribed from Cursor 3.23.12's live windows
/// (2026-10-03): the plan card, the mode card waiting and answered, the Run card and the Agents window's header.
/// The Run card with Always Run follows that version's ToolApprovalGate component, which the live run did not show.
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

        // Where the command can be allowlisted Cursor adds Always Run between the two; with no command drawn the
        // card's first words head it.
        let gate = group([group([text("npm run deploy -- --prod")]), button("Skip"), group([button("Always Run"), button("Run ⏎")])])
        let allowlistable = try #require(CursorCards.detect(in: gate, title: "w").first)
        #expect(allowlistable.heading == "npm run deploy -- --prod")
        #expect(allowlistable.options.map(\.label) == ["Skip", "Always Run", "Run"])
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
        #expect(CursorCards.session(for: run("Cursor Agents"), among: two) == "y")

        // A plan card holds no turn, so an idle chat can own one.
        let plan = CursorCard(kind: .plan, window: "enrollhere", heading: "p", options: [.init(label: "Build", path: [0])])
        #expect(CursorCards.session(for: plan, among: [session("i", "enrollhere", 1, working: false), session("w", "tools", 5)]) == "i")
    }

    @Test func buildFindsOnlyAnUnambiguousPlanCard() {
        func plan(_ name: String) -> CursorCard { CursorCard(kind: .plan, window: "w", heading: name, options: [.init(label: "Build", path: [0])]) }
        #expect(CursorCards.planCard(named: "A", in: [plan("A"), plan("B")])?.heading == "A")
        #expect(CursorCards.planCard(named: "C", in: [plan("A"), plan("B")]) == nil, "two plans and neither is this one: nothing is pressed")
        #expect(CursorCards.planCard(named: nil, in: [plan("A")])?.heading == "A")
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
        func scan() -> [CursorCard] { cards }
        func scanForPlan() -> [CursorCard] { lock.withLock { _planReads += 1; return _cards } }
        func press(_ card: CursorCard, option: String) -> CursorPressResult {
            lock.withLock { _pressed.append(card.kind.rawValue + ":" + option) }
            return result
        }
        func release() { lock.withLock { _released += 1 } }
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
        await until { ui.released > 1 }
        #expect(ui.released == 1, "Cursor is told once per spell of reading")
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
        #expect(JSON.count(42.9) == 42)
        #expect(JSON.count("17") == 17)
        #expect(JSON.count(-1) == nil)
        #expect(JSON.count(1e300) == nil, "Int(1e300) would trap the app")
        #expect(JSON.count(Double.nan) == nil)
        #expect(JSON.count(Double.infinity) == nil)
        #expect(JSON.count("12abc") == nil)
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
