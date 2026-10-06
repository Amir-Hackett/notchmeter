import Foundation
import os
import SQLite3
import Testing
@testable import Notchmeter

/// A Cursor subagent's own chat on the row of the chat it works for (CursorSubagents): what crosses onto that row
/// and what does not, what Cursor's database is read for, and the store keeping a subagent from ever having a
/// row of its own. Every name here is made up.
@Suite struct CursorSubagentChats {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func key(_ id: String) -> String { SessionTracker.key(tool: .cursor, session: id, host: nil) }

    func event(_ name: String, _ id: String, agent: String? = nil, project: String = "atlas") -> Hook.Message {
        Hook.Message(event: name, needsInput: false, sessionID: id, project: project, agentID: agent, tool: .cursor)
    }

    // MARK: - What crosses onto the parent's row

    @Test func aSubagentsSignOfLifeIsItsParentsAndNothingOfItsOwnChatCrosses() {
        var thought = event("afterAgentThought", "child-1")
        thought.reportedModel = "small-fast"
        thought.composerMode = "agent"
        thought.title = "List the fonts"
        thought.transcriptPath = "/Users/x/.cursor/projects/atlas/agent-transcripts/child-1/child-1.jsonl"
        thought.planFile = "/Users/x/.cursor/plans/fonts.plan.md"
        thought.planBuild = true
        thought.background = true
        thought.context = 0.4
        thought.compaction = .auto
        thought.toolFailure = ToolFailure(tool: "Shell", interrupt: false)
        thought.request = Hook.Request(id: "r1", kind: .permission(tool: "Shell", summary: "ls", detail: nil, suggestions: []))
        let folded = CursorSubagents.folded(thought, from: "child-1", into: "parent-1")
        #expect(folded.sessionID == "parent-1" && folded.agentID == "child-1" && folded.event == "afterAgentThought")
        #expect(folded.project == "atlas" && folded.tool == .cursor)
        #expect(folded.reportedModel == nil && folded.composerMode == nil && folded.title == nil && folded.transcriptPath == nil)
        #expect(folded.planFile == nil && !folded.planBuild && !folded.background && folded.context == nil && folded.compaction == nil)
        #expect(folded.toolFailure == thought.toolFailure, "a failed tool is what the conversation is doing")
        #expect(folded.request == thought.request, "a call held for the notch is answered on the parent's row")
    }

    @Test func aSubagentsOwnTurnNeitherStartsNorEndsItsParents() {
        for name in ["Stop", "StopFailure", "SessionStart", "SessionEnd", "PreCompact"] {
            var message = Hook.Message(event: name, needsInput: false, sessionID: "child-1", failure: "aborted", tool: .cursor)
            message.compaction = .auto
            let folded = CursorSubagents.folded(message, from: "child-1", into: "parent-1")
            #expect(folded.event == CursorSubagents.chatEvent && folded.failure == nil && folded.agentID == "child-1", "\(name)")
        }
        let prompt = CursorSubagents.folded(event("UserPromptSubmit", "child-1"), from: "child-1", into: "parent-1")
        #expect(prompt.event == Hook.Codex.subagentPromptEvent)
        // A subagent the subagent started is counted on the same row, under its own id.
        let nested = CursorSubagents.folded(event("SubagentStart", "child-1", agent: "grandchild-task"), from: "child-1", into: "parent-1")
        #expect(nested.event == "SubagentStart" && nested.agentID == "grandchild-task" && nested.sessionID == "parent-1")
    }

    @Test func theTrackerKeepsTheParentsTurnThroughItsSubagentsEvents() {
        var tracker = SessionTracker()
        var prompt = event("UserPromptSubmit", "parent-1")
        prompt.title = "Tidy the palette"
        prompt.reportedModel = "big-model"
        tracker.apply(prompt, now: t0)
        tracker.apply(event("SubagentStart", "parent-1", agent: "task-1"), now: t0.addingTimeInterval(5))
        var childPrompt = event("UserPromptSubmit", "child-1")
        childPrompt.title = "List the fonts"
        childPrompt.reportedModel = "small-fast"
        var childStop = event("Stop", "child-1")
        childStop.reportedModel = "small-fast"
        var outcomes: [SessionTracker.Outcome] = []
        for (offset, message) in [(10.0, childPrompt), (20, event("beforeShellExecution", "child-1")), (25, event("afterShellExecution", "child-1")), (60, childStop)] {
            outcomes.append(tracker.apply(CursorSubagents.folded(message, from: "child-1", into: "parent-1"), now: t0.addingTimeInterval(offset)))
        }
        #expect(tracker.count == 1, "the subagent's chat is no session")
        let parent = tracker.sessions[key("parent-1")]
        #expect(parent?.isWorking == true && parent?.turnStarted == t0, "its turn is the one its own prompt began")
        #expect(parent?.title == "Tidy the palette" && parent?.model == Hook.tidyModelName("big-model"))
        #expect(parent?.agents.keys.sorted() == ["task-1"] && parent?.finished == nil)
        #expect(parent?.lastEvent == t0.addingTimeInterval(60), "and it is heard from while its subagent works")
        #expect(outcomes.allSatisfy { $0.finished == nil && $0.startedWaiting == nil })
    }

    @Test func aSubagentsSignOfLifeEndsAGuessedWaitAndNotOneACardProves() {
        var tracker = SessionTracker()
        tracker.apply(event("UserPromptSubmit", "parent-1"), now: t0)
        tracker.apply(event("afterAgentThought", "parent-1"), now: t0.addingTimeInterval(1))
        // Quiet for longer than the spell: shown as a possible wait.
        let later = t0.addingTimeInterval(1 + tracker.quietAfter + 1)
        #expect(tracker.quietNudges(now: later).map(\.id) == [key("parent-1")])
        tracker.apply(event("afterAgentThought", "parent-1", agent: "child-1"), now: later.addingTimeInterval(1))
        #expect(tracker.sessions[key("parent-1")]?.isWorking == true, "the conversation was at work all along")
        // A card of Cursor's on the chat: a subagent working on behind it does not answer it.
        #expect(tracker.cursorCardShown(key("parent-1"), now: later.addingTimeInterval(2)) != nil)
        tracker.apply(event("afterAgentThought", "parent-1", agent: "child-1"), now: later.addingTimeInterval(3))
        #expect(tracker.sessions[key("parent-1")]?.isWaiting == true)
        tracker.apply(event("afterAgentThought", "parent-1"), now: later.addingTimeInterval(4))
        #expect(tracker.sessions[key("parent-1")]?.isWorking == true, "the chat's own sign of life still does")
    }

    @Test func aDroppedSessionLeavesNothingToComeBack() {
        var tracker = SessionTracker()
        tracker.apply(event("UserPromptSubmit", "child-1"), now: t0)
        var held = event("beforeShellExecution", "child-1")
        held.request = Hook.Request(id: "r1", kind: .permission(tool: "Shell", summary: "ls", detail: nil, suggestions: []))
        tracker.apply(held, now: t0.addingTimeInterval(1))
        let dropped = tracker.drop(key("child-1"))
        #expect(dropped.sessions == [key("child-1")] && dropped.waiting == [key("child-1")])
        #expect(dropped.requests == [SessionTracker.EndedRequest(sessionID: key("child-1"), requestID: "r1")])
        #expect(tracker.count == 0 && tracker.dismissed.isEmpty)
        // One the user had removed goes too, where a removed session's next event would bring it back.
        tracker.apply(event("SessionStart", "child-2"), now: t0)
        tracker.dismiss(key("child-2"))
        #expect(tracker.drop(key("child-2")).sessions.isEmpty && tracker.dismissed.isEmpty)
        #expect(tracker.drop("cursor:nobody") == SessionTracker.Forgotten())
    }

    // MARK: - The places kept

    @Test func aSubagentsSubagentWorksForTheChatAtTheTop() {
        let places: [String: CursorSubagents.Place] = ["a": .own, "b": .child(of: "a"), "c": .child(of: "b"), "x": .child(of: "y"), "y": .child(of: "x")]
        #expect(CursorSubagents.top(of: "c", in: places) == "a")
        #expect(CursorSubagents.top(of: "a", in: places) == "a")
        #expect(CursorSubagents.top(of: "unheard", in: places) == "unheard")
        // Two chats each said to work for the other: followed once round, not for ever.
        #expect(["x", "y"].contains(CursorSubagents.top(of: "x", in: places)))
    }

    @Test func onlyThePlacesARowNeedsAreKept() {
        let places: [String: CursorSubagents.Place] = ["a": .own, "b": .child(of: "a"), "gone": .own, "orphan": .child(of: "gone")]
        #expect(CursorSubagents.pruned(places, live: ["a"]) == ["a": .own, "b": .child(of: "a")])
    }

    // MARK: - Cursor's database

    /// A scratch database with Cursor's two tables.
    func database(in directory: URL, _ rows: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appendingPathComponent("state.vscdb")
        var db: OpaquePointer?
        #expect(sqlite3_open(database.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
        CREATE TABLE composerHeaders (composerId TEXT PRIMARY KEY, workspaceId TEXT, createdAt INTEGER, lastUpdatedAt INTEGER, isArchived INTEGER, isSubagent INTEGER, recency INTEGER, checkpointAt INTEGER, value TEXT, subagentTypeName TEXT);
        CREATE TABLE cursorDiskKV (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
        """
        #expect(sqlite3_exec(db, schema + rows, nil, nil, nil) == SQLITE_OK)
        return database
    }

    @Test func theDatabaseSaysWhoseChatAConversationIs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-subagents-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try database(in: directory, """
        INSERT INTO composerHeaders (composerId, isSubagent, value) VALUES ('parent-1', 0, '{"type":"head","composerId":"parent-1","name":"Tidy the palette"}');
        INSERT INTO composerHeaders (composerId, isSubagent, value) VALUES ('child-1', 1, '{"type":"head","composerId":"child-1","subagentInfo":{"parentComposerId":"parent-1","subagentTypeName":"explore"}}');
        INSERT INTO cursorDiskKV (key, value) VALUES ('composerData:fresh-1', '{"composerId":"fresh-1","subagentInfo":{"parentComposerId":"parent-1"}}');
        INSERT INTO cursorDiskKV (key, value) VALUES ('composerData:plain-1', '{"composerId":"plain-1"}');
        INSERT INTO composerHeaders (composerId, isSubagent, value) VALUES ('grand-1', 1, '{"composerId":"grand-1","subagentInfo":{"parentComposerId":"child-1"}}');
        INSERT INTO composerHeaders (composerId, isSubagent, value) VALUES ('answer-1', 0, '{"composerId":"answer-1","isBestOfNSubcomposer":true,"subagentInfo":{"parentComposerId":"parent-1"}}');
        INSERT INTO composerHeaders (composerId, isSubagent, value) VALUES ('odd-1', 1, '{"composerId":"odd-1","subagentInfo":{"parentComposerId":"not an id;"}}');
        INSERT INTO composerHeaders (composerId, isSubagent, value) VALUES ('self-1', 1, '{"composerId":"self-1","subagentInfo":{"parentComposerId":"self-1"}}');
        INSERT INTO composerHeaders (composerId, isSubagent, value) VALUES ('torn-1', 0, '{"composerId":"torn-1","subagentInfo":');
        INSERT INTO composerHeaders (composerId, isSubagent, value) VALUES ('loop-1', 1, '{"subagentInfo":{"parentComposerId":"loop-2"}}');
        INSERT INTO composerHeaders (composerId, isSubagent, value) VALUES ('loop-2', 1, '{"subagentInfo":{"parentComposerId":"loop-1"}}');
        """)
        let ids: Set<String> = ["parent-1", "child-1", "fresh-1", "plain-1", "grand-1", "answer-1", "odd-1", "self-1", "torn-1", "unheard-1", "bad id;"]
        let places = try #require(CursorSubagents.read(ids: ids, database: database))
        #expect(places["parent-1"] == .own)
        #expect(places["child-1"] == .child(of: "parent-1"))
        #expect(places["fresh-1"] == .child(of: "parent-1"), "a chat with no header yet is read from its own record")
        #expect(places["plain-1"] == .own)
        #expect(places["grand-1"] == .child(of: "parent-1"), "a subagent's subagent works for the chat at the top")
        #expect(places["answer-1"] == .own, "one of several answers to a prompt is a chat Cursor lists")
        #expect(places["odd-1"] == .own && places["self-1"] == .own && places["torn-1"] == .own)
        #expect(places["unheard-1"] == nil && places["bad id;"] == nil, "a chat the database holds nothing of is absent")
        #expect(places.count == 9)
        // Two chats each said to work for the other are read without going round for ever.
        #expect(CursorSubagents.read(ids: ["loop-1"], database: database) == ["loop-1": .child(of: "loop-2")])
        #expect(CursorSubagents.read(ids: ["child-1"], database: directory.appendingPathComponent("missing.vscdb")) == nil, "no database says nothing of any chat")
        #expect(CursorSubagents.read(ids: [], database: database) == [:])
    }

    @Test func aDatabaseWithoutCursorsTablesHoldsNothingOfAnyChat() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-subagents-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appendingPathComponent("state.vscdb")
        var db: OpaquePointer?
        #expect(sqlite3_open(database.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT, value BLOB);", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        #expect(CursorSubagents.read(ids: ["child-1"], database: database) == [:])
    }

    // MARK: - What the hook reads

    func parse(_ json: String) -> Hook.Message? {
        Hook.message(from: Data(json.utf8), tool: .cursor, environment: [:], branch: { _ in nil }, requestID: "r1", cursorApproval: false)
    }

    @Test func aSubagentsEndNamesItsChatAndItsModelIsNotTheChats() throws {
        let stop = try #require(parse(#"{"hook_event_name":"subagentStop","conversation_id":"parent-1","parent_conversation_id":"parent-1","subagent_id":"task-1","child_conversation_id":"child-1","status":"completed","model":"small-fast"}"#))
        #expect(stop.event == "SubagentStop" && stop.sessionID == "parent-1" && stop.agentID == "task-1")
        #expect(stop.childSessionID == "child-1")
        #expect(stop.reportedModel == nil, "the model on a subagent's event is the subagent's")
        let start = try #require(parse(#"{"hook_event_name":"subagentStart","conversation_id":"parent-1","parent_conversation_id":"parent-1","subagent_id":"task-1","child_conversation_id":"child-1","model":"small-fast","subagent_model":"small-fast"}"#))
        #expect(start.reportedModel == nil && start.childSessionID == nil, "only the end is read for the chat")
        let shell = try #require(parse(#"{"hook_event_name":"afterShellExecution","conversation_id":"parent-1","child_conversation_id":"child-1","model":"big-model"}"#))
        #expect(shell.reportedModel == "big-model" && shell.childSessionID == nil)
        let odd = try #require(parse(#"{"hook_event_name":"subagentStop","conversation_id":"parent-1","child_conversation_id":"not an id;"}"#))
        #expect(odd.childSessionID == nil)
        // Over the socket and back, and nothing on the line of an event that names none.
        #expect(Hook.Message(userInfo: stop.userInfo) == stop)
        #expect(start.userInfo[Hook.childSessionKey] == nil)
        var forged = stop.userInfo
        forged[Hook.childSessionKey] = "not an id;"
        #expect(Hook.Message(userInfo: forged)?.childSessionID == nil)
    }
}

/// The store keeping a subagent's chat off the Sessions card: asked of Cursor's database before the chat is given
/// a row, with its events waiting in the order they came.
@MainActor
@Suite struct CursorSubagentRows {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// What a stand-in for the database was asked, and what it answers, from any thread.
    final class Database: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: (asked: [String](), answers: [[String: CursorSubagents.Place]?]()))
        /// The answers in turn; the last one is every answer after it.
        init(_ answers: [String: CursorSubagents.Place]?...) { state.withLock { $0.answers = answers } }
        var asked: [String] { state.withLock { $0.asked } }
        func read(_ ids: Set<String>) -> [String: CursorSubagents.Place]? {
            state.withLock { state in
                state.asked.append(contentsOf: ids.sorted())
                return state.answers.count > 1 ? state.answers.removeFirst() : state.answers.first ?? [:]
            }
        }
    }

    func store(_ suite: String, database: Database?, configure: (Preferences) -> Void = { _ in }) -> (UsageStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let prefs = Preferences(defaults: defaults)
        configure(prefs)
        let store = UsageStore(prefs: prefs, providers: [], cache: ReadingCache(defaults: defaults), defaults: defaults, drainLog: nil, reportFile: nil)
        if let database { store.cursorParentReader = { database.read($0) } }
        return (store, defaults)
    }

    func key(_ id: String) -> String { SessionTracker.key(tool: .cursor, session: id, host: nil) }

    func event(_ name: String, _ id: String, agent: String? = nil) -> Hook.Message {
        Hook.Message(event: name, needsInput: false, sessionID: id, project: "atlas", agentID: agent, tool: .cursor)
    }

    func until(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// A chat in a turn with one subagent started, placed and on the card.
    func working(_ store: UsageStore, _ database: Database) async {
        var prompt = event("UserPromptSubmit", "parent-1")
        prompt.title = "Tidy the palette"
        prompt.reportedModel = "big-model"
        store.hookReceived(prompt, now: t0)
        await until { store.sessions.sessions[key("parent-1")] != nil }
        store.hookReceived(event("SubagentStart", "parent-1", agent: "task-1"), now: t0.addingTimeInterval(5))
    }

    @Test func aSubagentsChatIsNeverGivenARow() async {
        let database = Database(["parent-1": .own, "child-1": .child(of: "parent-1")])
        let suite = "NotchmeterTests.subagentNoRow"
        let (store, defaults) = store(suite, database: database)
        defer { defaults.removePersistentDomain(forName: suite) }
        await working(store, database)
        #expect(store.sessions.sessions[key("parent-1")]?.agents.count == 1)
        var thought = event("afterAgentThought", "child-1")
        thought.reportedModel = "small-fast"
        store.hookReceived(thought, now: t0.addingTimeInterval(10))
        store.hookReceived(event("beforeShellExecution", "child-1"), now: t0.addingTimeInterval(11))
        #expect(store.sessions.count == 1, "nothing of the chat is shown before the database has said whose it is")
        store.hookReceived(event("afterShellExecution", "child-1"), now: t0.addingTimeInterval(12))
        store.hookReceived(event("Stop", "child-1"), now: t0.addingTimeInterval(30))
        await until { store.sessions.sessions[key("parent-1")]?.lastEvent == t0.addingTimeInterval(30) }
        #expect(store.sessions.count == 1 && store.sessions.sessions[key("child-1")] == nil)
        let parent = store.sessions.sessions[key("parent-1")]
        #expect(parent?.isWorking == true && parent?.turnStarted == t0 && parent?.finished == nil, "the subagent's end is not the turn's")
        #expect(parent?.title == "Tidy the palette" && parent?.model == Hook.tidyModelName("big-model"))
        #expect(parent?.agents.keys.sorted() == ["task-1"])
        #expect(parent?.commandsInFlight == 0 && parent?.heartbeats == true, "its command began and ended on the parent's row, in order")
        #expect(database.asked == ["parent-1", "child-1"], "each conversation is asked about once")
        // And again without a word to the database, now the chat is placed.
        store.hookReceived(event("afterAgentThought", "child-1"), now: t0.addingTimeInterval(40))
        #expect(store.sessions.count == 1 && store.sessions.sessions[key("parent-1")]?.lastEvent == t0.addingTimeInterval(40))
        #expect(database.asked.count == 2)
    }

    @Test func aChatOfItsOwnIsShownAsSoonAsTheDatabaseHasSaidSo() async {
        let database = Database(["other-1": .own])
        let suite = "NotchmeterTests.subagentOwn"
        let (store, defaults) = store(suite, database: database)
        defer { defaults.removePersistentDomain(forName: suite) }
        store.hookReceived(event("UserPromptSubmit", "other-1"), now: t0)
        store.hookReceived(event("afterAgentThought", "other-1"), now: t0.addingTimeInterval(1))
        store.hookReceived(event("Stop", "other-1"), now: t0.addingTimeInterval(40))
        await until { store.sessions.sessions[key("other-1")]?.finished != nil }
        let chat = store.sessions.sessions[key("other-1")]
        #expect(chat?.state == .idle && chat?.finished?.turn == 40, "its events arrive in order, each at the time it came")
        #expect(database.asked == ["other-1"])
    }

    @Test func aChatTheDatabaseHasNotSavedYetIsAskedAboutAgainWhileASubagentRuns() async {
        // Nothing of the chat at first, then its record: Cursor was between creating it and saving it.
        let database = Database(["parent-1": .own], [:], ["child-1": .child(of: "parent-1")])
        let suite = "NotchmeterTests.subagentRetry"
        let (store, defaults) = store(suite, database: database)
        defer { defaults.removePersistentDomain(forName: suite) }
        await working(store, database)
        store.hookReceived(event("afterAgentThought", "child-1"), now: t0.addingTimeInterval(10))
        await until { store.sessions.sessions[key("parent-1")]?.lastEvent == t0.addingTimeInterval(10) }
        #expect(store.sessions.count == 1)
        #expect(database.asked == ["parent-1", "child-1", "child-1"])
    }

    @Test func withNoSubagentRunningAChatTheDatabaseHoldsNothingOfIsItsOwnAtOnce() async {
        let database = Database([:])
        let suite = "NotchmeterTests.subagentUnknown"
        let (store, defaults) = store(suite, database: database)
        defer { defaults.removePersistentDomain(forName: suite) }
        store.hookReceived(event("UserPromptSubmit", "new-1"), now: t0)
        await until { store.sessions.sessions[key("new-1")] != nil }
        #expect(store.sessions.sessions[key("new-1")]?.isWorking == true)
        #expect(database.asked == ["new-1"])
    }

    @Test func aDatabaseThatCannotBeReadLeavesEveryChatItsOwn() async {
        let database = Database(nil)
        let suite = "NotchmeterTests.subagentUnread"
        let (store, defaults) = store(suite, database: database)
        defer { defaults.removePersistentDomain(forName: suite) }
        store.hookReceived(event("UserPromptSubmit", "parent-1"), now: t0)
        await until { store.sessions.sessions[key("parent-1")] != nil }
        store.hookReceived(event("SubagentStart", "parent-1", agent: "task-1"), now: t0.addingTimeInterval(5))
        store.hookReceived(event("afterAgentThought", "child-1"), now: t0.addingTimeInterval(10))
        await until { store.sessions.sessions[key("child-1")] != nil }
        #expect(store.sessions.count == 2, "as before 0.9.21, until the subagent's end names its chat")
        #expect(database.asked == ["parent-1", "child-1"], "a read that failed is not tried again")
        // The end of the subagent names the chat it ran as: its row goes, and what it sends after is the parent's.
        var stop = event("SubagentStop", "parent-1", agent: "task-1")
        stop.childSessionID = "child-1"
        store.hookReceived(stop, now: t0.addingTimeInterval(20))
        #expect(store.sessions.count == 1 && store.sessions.sessions[key("child-1")] == nil)
        #expect(store.sessions.sessions[key("parent-1")]?.agents.isEmpty == true)
        store.hookReceived(event("afterAgentThought", "child-1"), now: t0.addingTimeInterval(21))
        #expect(store.sessions.count == 1 && store.sessions.sessions[key("parent-1")]?.lastEvent == t0.addingTimeInterval(21))
    }

    @Test func aSubagentsSubagentIsCountedOnTheRowAtTheTop() async {
        let database = Database(["parent-1": .own, "child-1": .child(of: "parent-1")])
        let suite = "NotchmeterTests.subagentNested"
        let (store, defaults) = store(suite, database: database)
        defer { defaults.removePersistentDomain(forName: suite) }
        await working(store, database)
        store.hookReceived(event("SubagentStart", "child-1", agent: "task-2"), now: t0.addingTimeInterval(10))
        await until { store.sessions.sessions[key("parent-1")]?.agents.count == 2 }
        #expect(store.sessions.count == 1 && store.sessions.sessions[key("parent-1")]?.agents.keys.sorted() == ["task-1", "task-2"])
        // Its end names the chat it ran as, which is the top chat's subagent from there on, unasked.
        var stop = event("SubagentStop", "child-1", agent: "task-2")
        stop.childSessionID = "grand-1"
        store.hookReceived(stop, now: t0.addingTimeInterval(20))
        #expect(store.sessions.sessions[key("parent-1")]?.agents.keys.sorted() == ["task-1"])
        store.hookReceived(event("afterAgentThought", "grand-1"), now: t0.addingTimeInterval(21))
        #expect(store.sessions.count == 1 && store.sessions.sessions[key("parent-1")]?.lastEvent == t0.addingTimeInterval(21))
        #expect(database.asked == ["parent-1", "child-1"])
    }

    @Test func aCommandASubagentIsHeldForIsAnsweredOnItsParentsRow() async {
        let database = Database(["parent-1": .own, "child-1": .child(of: "parent-1")])
        let suite = "NotchmeterTests.subagentHeld"
        let (store, defaults) = store(suite, database: database) { $0.cursorRequireApproval = true }
        defer { defaults.removePersistentDomain(forName: suite) }
        var prompted: [String] = []
        store.promptRequested = { session, request in prompted.append("\(session.id) \(request.id)") }
        await working(store, database)
        var held = Hook.Message(event: "beforeShellExecution", needsInput: true, sessionID: "child-1", project: "atlas", tool: .cursor)
        held.request = Hook.Request(id: "r1", kind: .permission(tool: Hook.Cursor.shellTool, summary: "ls", detail: nil, suggestions: []))
        store.hookReceived(held, now: t0.addingTimeInterval(10))
        await until { !prompted.isEmpty }
        #expect(prompted == ["\(key("parent-1")) r1"])
        let parent = store.sessions.sessions[key("parent-1")]
        #expect(store.sessions.count == 1 && parent?.pending?.id == "r1" && parent?.isWaiting == true)
    }

    @Test func withNoDatabaseToAskEveryChatIsItsOwnAsItAlwaysWas() {
        let suite = "NotchmeterTests.subagentNoDatabase"
        let (store, defaults) = store(suite, database: nil)
        defer { defaults.removePersistentDomain(forName: suite) }
        store.hookReceived(event("UserPromptSubmit", "parent-1"), now: t0)
        store.hookReceived(event("afterAgentThought", "child-1"), now: t0.addingTimeInterval(1))
        #expect(store.sessions.count == 2, "at once, with nothing waited for")
    }

    @Test func aRemoteCursorsChatsAreNotAskedOfThisMacsDatabase() {
        let database = Database(["child-1": .child(of: "parent-1")])
        let suite = "NotchmeterTests.subagentRemote"
        let (store, defaults) = store(suite, database: database)
        defer { defaults.removePersistentDomain(forName: suite) }
        store.hookReceived(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "child-1", project: "atlas", host: "devbox", tool: .cursor), now: t0)
        #expect(store.sessions.sessions[SessionTracker.key(tool: .cursor, session: "child-1", host: "devbox")] != nil)
        #expect(database.asked.isEmpty)
    }

    @Test func sessionsNoLongerReadTakeWhatWasKnownOfCursorsChatsWithThem() async {
        let database = Database(["parent-1": .own, "child-1": .child(of: "parent-1")])
        let suite = "NotchmeterTests.subagentForget"
        let (store, defaults) = store(suite, database: database)
        defer { defaults.removePersistentDomain(forName: suite) }
        await working(store, database)
        store.hookReceived(event("afterAgentThought", "child-1"), now: t0.addingTimeInterval(10))
        await until { store.sessions.sessions[key("parent-1")]?.lastEvent == t0.addingTimeInterval(10) }
        store.forgetSessions(of: .cursor)
        #expect(store.sessions.count == 0)
        // Read again: the chat is asked about afresh, and placed as before.
        store.hookReceived(event("afterAgentThought", "child-1"), now: t0.addingTimeInterval(20))
        await until { store.sessions.sessions[key("parent-1")] != nil }
        #expect(store.sessions.sessions[key("child-1")] == nil && database.asked == ["parent-1", "child-1", "child-1"])
    }
}
