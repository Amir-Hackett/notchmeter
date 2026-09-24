import Foundation
import Testing
@testable import Notchmeter

/// What the Sessions card's extras line is made of, from the payload to the tracker: Claude Code's task list off a
/// `PostToolUse` for `TaskCreate`/`TaskUpdate` (current builds) or `TodoWrite` (older ones), reduced before it leaves the hook and held under the titles setting; and the
/// per-session context fill off the status line, stored as reported and never estimated.
@Suite struct SessionTodoParsing {
    func parse(_ json: String, event: String? = nil) -> Hook.Message? {
        Hook.message(from: Data(json.utf8), tool: nil, event: event, environment: [:], branch: { _ in nil }, requestID: "r1")
    }

    @Test func aTodoWriteCarriesEachItemsStatusAndOneLineOfItsText() throws {
        let json = """
        {"hook_event_name":"PostToolUse","session_id":"s","cwd":"/Users/x/notchmeter","tool_name":"TodoWrite",
         "tool_input":{"todos":[
           {"content":"Read the card\\nand its tests","status":"completed","activeForm":"Reading the card"},
           {"content":"Group the rows","status":"in_progress","activeForm":"Grouping"},
           {"content":"Ship it","status":"pending"},
           {"content":"Something new","status":"blocked"},
           {"status":"pending"}
         ]},
         "tool_response":{"oldTodos":[],"newTodos":[]}}
        """
        let message = try #require(parse(json))
        let todos = try #require(message.todos)
        #expect(todos.items.map(\.status) == [.completed, .inProgress, .pending, .pending], "a status nobody documents is dropped, not guessed at")
        #expect(todos.items.map(\.content) == ["Read the card", "Group the rows", "Ship it", nil], "one line of the text, nothing of activeForm")
        #expect(todos.done == 1)
        #expect(todos.total == 4)
        // Across the socket and back, as the app reads it.
        let back = try #require(Hook.Message(userInfo: message.userInfo))
        #expect(back.todos == todos)
    }

    @Test func onlyATodoWriteAfterItRanCarriesAList() {
        let other = #"{"hook_event_name":"PostToolUse","session_id":"s","tool_name":"Bash","tool_input":{"todos":[{"content":"x","status":"pending"}]}}"#
        #expect(parse(other)?.todos == nil, "another tool's input is never read for a task list")
        let before = #"{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"TodoWrite","tool_input":{"todos":[{"content":"x","status":"pending"}]}}"#
        #expect(parse(before)?.todos == nil, "only the list that was written, after the call ran")
        let notAList = #"{"hook_event_name":"PostToolUse","session_id":"s","tool_name":"TodoWrite","tool_input":{"todos":"x"}}"#
        #expect(parse(notAList)?.todos == nil)
        let cleared = #"{"hook_event_name":"PostToolUse","session_id":"s","tool_name":"TodoWrite","tool_input":{"todos":[]}}"#
        #expect(parse(cleared)?.todos == TodoPlan(items: []), "an empty list is the plan being cleared")
    }

    @Test func aLongPlanIsCutAndALongItemIsHeldToATitle() throws {
        let items = (0..<(Hook.todoLimit + 10)).map { _ in ["content": String(repeating: "a", count: 400), "status": "pending"] }
        let todos = try #require(Hook.todos(from: items))
        #expect(todos.total == Hook.todoLimit)
        #expect((todos.items.first?.content?.count ?? 0) <= Hook.titleLimit + 1)
    }

    @Test func withoutContentKeepsTheCounts() {
        let plan = TodoPlan(items: [TodoPlan.Item(content: "a", status: .completed), TodoPlan.Item(content: "b", status: .pending)])
        let bare = plan.withoutContent()
        #expect(bare.items.allSatisfy { $0.content == nil })
        #expect(bare.done == 1)
        #expect(bare.total == 2)
        #expect(!bare.hasContent)
        #expect(plan.hasContent)
    }

    /// The oracle hears a task list as counts: never an item's words.
    @Test func theOracleHearsTheCountsOnly() throws {
        var message = Hook.Message(event: "PostToolUse", needsInput: false, sessionID: "s")
        message.todos = TodoPlan(items: [TodoPlan.Item(content: "Secret", status: .completed), TodoPlan.Item(content: "Plan", status: .pending)])
        let facts = UsageStore.hookFacts(message)
        #expect(facts["todos"] as? [String: Int] == ["done": 1, "total": 2])
        let line = try #require(Oracle.line(event: "hook", fields: facts))
        #expect(!line.contains("Secret"))
        #expect(UsageStore.hookFacts(Hook.Message(event: "Stop", needsInput: false))["todos"] == nil)
    }
}

/// Current Claude Code keeps its plan with the Task tools, one call per change. The payloads here are the shapes
/// 2.1.281 wrote to its own transcripts (`tool_input` as the model sent it, `tool_response` as the tool answered).
@Suite struct SessionTaskToolParsing {
    func parse(_ json: String) -> Hook.Message? {
        Hook.message(from: Data(json.utf8), tool: nil, event: nil, environment: [:], branch: { _ in nil }, requestID: "r1")
    }

    @Test func aTaskCreateCarriesTheNewIdAndOneLineOfTheSubject() throws {
        let json = """
        {"hook_event_name":"PostToolUse","session_id":"s","cwd":"/Users/x/notchmeter","tool_name":"TaskCreate",
         "tool_input":{"subject":"Server: openThreads WS handlers\\nsecond line","description":"A long description","activeForm":"Building handlers"},
         "tool_response":{"task":{"id":"1","subject":"Server: openThreads WS handlers"}}}
        """
        let message = try #require(parse(json))
        let task = try #require(message.task)
        #expect(task == TaskChange(kind: .created, id: "1", subject: "Server: openThreads WS handlers", status: .pending))
        #expect(message.todos == nil)
        let back = try #require(Hook.Message(userInfo: message.userInfo))
        #expect(back.task == task)
        let line = String(decoding: try JSONSerialization.data(withJSONObject: message.userInfo), as: UTF8.self)
        #expect(!line.contains("description") && !line.contains("Building"), "nothing else of the call leaves the command")
    }

    @Test func aTaskUpdateCarriesItsStatusOrADeletion() throws {
        let started = #"{"hook_event_name":"PostToolUse","session_id":"s","tool_name":"TaskUpdate","tool_input":{"taskId":"2","status":"in_progress"},"tool_response":{"success":true,"taskId":"2","updatedFields":["status"],"statusChange":{"from":"pending","to":"in_progress"}}}"#
        #expect(parse(started)?.task == TaskChange(kind: .updated, id: "2", subject: nil, status: .inProgress))
        let renamed = #"{"hook_event_name":"PostToolUse","session_id":"s","tool_name":"TaskUpdate","tool_input":{"taskId":2,"subject":"New name"},"tool_response":{"success":true}}"#
        #expect(parse(renamed)?.task == TaskChange(kind: .updated, id: "2", subject: "New name", status: nil), "a numeric id reads as its digits")
        let deleted = #"{"hook_event_name":"PostToolUse","session_id":"s","tool_name":"TaskUpdate","tool_input":{"taskId":"3","status":"deleted"},"tool_response":{"success":true}}"#
        let removal = try #require(parse(deleted)?.task)
        #expect(removal.deleted)
        #expect(Hook.Message(userInfo: try #require(parse(deleted)).userInfo)?.task == removal)
        let failed = #"{"hook_event_name":"PostToolUse","session_id":"s","tool_name":"TaskUpdate","tool_input":{"taskId":"3","status":"completed"},"tool_response":{"success":false}}"#
        #expect(parse(failed)?.task == nil, "an update that did not happen changes nothing")
        let noID = #"{"hook_event_name":"PostToolUse","session_id":"s","tool_name":"TaskCreate","tool_input":{"subject":"x"},"tool_response":{}}"#
        #expect(parse(noID)?.task == nil)
        let other = #"{"hook_event_name":"PostToolUse","session_id":"s","tool_name":"TaskList","tool_input":{},"tool_response":{"tasks":[]}}"#
        #expect(parse(other)?.task == nil)
        let before = #"{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"TaskUpdate","tool_input":{"taskId":"3","status":"completed"}}"#
        #expect(parse(before)?.task == nil, "only a call that ran")
    }

    /// The oracle hears a task call as its kind and status, never its subject or id.
    @Test func theOracleHearsTheKindAndStatusOnly() throws {
        var message = Hook.Message(event: "PostToolUse", needsInput: false, sessionID: "s")
        message.task = TaskChange(kind: .created, id: "task-77", subject: "Secret", status: .pending)
        let facts = UsageStore.hookFacts(message)
        let line = try #require(Oracle.line(event: "hook", fields: facts))
        #expect(line.contains("created"))
        #expect(!line.contains("Secret"))
        #expect(!line.contains("task-77"))
    }
}

@Suite struct SessionTaskToolTracking {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func change(_ kind: TaskChange.Kind, _ id: String, _ subject: String? = nil, _ status: TodoPlan.Status? = nil, deleted: Bool = false,
                agent: String? = nil) -> Hook.Message {
        var message = Hook.Message(event: "PostToolUse", needsInput: false, sessionID: "a", project: "p", agentID: agent)
        message.task = TaskChange(kind: kind, id: id, subject: subject, status: kind == .created ? status ?? .pending : status, deleted: deleted)
        return message
    }

    @Test func tasksAreKeptById() {
        var tracker = SessionTracker()
        tracker.apply(change(.created, "1", "Read"), now: t0)
        tracker.apply(change(.created, "2", "Write"), now: t0)
        tracker.apply(change(.created, "3", "Ship"), now: t0)
        tracker.apply(change(.updated, "1", nil, .completed), now: t0)
        tracker.apply(change(.updated, "2", nil, .inProgress), now: t0)
        var plan = tracker.all.first?.todos
        #expect(plan?.items.map(\.id) == ["1", "2", "3"])
        #expect(plan?.items.map(\.status) == [.completed, .inProgress, .pending])
        #expect(plan?.items.map(\.content) == ["Read", "Write", "Ship"], "an update without a subject keeps the one held")
        #expect(plan?.done == 1)
        tracker.apply(change(.updated, "3", "Ship it"), now: t0)
        tracker.apply(change(.updated, "2", deleted: true), now: t0)
        plan = tracker.all.first?.todos
        #expect(plan?.items.map(\.id) == ["1", "3"])
        #expect(plan?.items.last?.content == "Ship it")
        tracker.apply(change(.updated, "1", deleted: true), now: t0)
        tracker.apply(change(.updated, "3", deleted: true), now: t0)
        #expect(tracker.all.first?.todos == nil, "deleting the last task clears the plan")
    }

    /// The app started mid-session: an update for a task it never saw created still counts, without words.
    @Test func anUpdateForAnUnseenTaskAddsIt() {
        var tracker = SessionTracker()
        tracker.apply(change(.updated, "4", nil, .inProgress), now: t0)
        #expect(tracker.all.first?.todos?.items == [TodoPlan.Item(id: "4", content: nil, status: .inProgress)])
        tracker.apply(change(.updated, "9", deleted: true), now: t0)
        #expect(tracker.all.first?.todos?.total == 1, "deleting a task the plan never held adds nothing")
    }

    @Test func aNewTaskAfterAFinishedPlanStartsTheNextOne() {
        var tracker = SessionTracker()
        tracker.apply(change(.created, "1", "One"), now: t0)
        tracker.apply(change(.created, "2", "Two"), now: t0)
        tracker.apply(change(.updated, "1", nil, .completed), now: t0)
        tracker.apply(change(.created, "3", "Three"), now: t0)
        #expect(tracker.all.first?.todos?.total == 3, "a plan still under way grows")
        tracker.apply(change(.updated, "2", nil, .completed), now: t0)
        tracker.apply(change(.updated, "3", nil, .completed), now: t0)
        tracker.apply(change(.created, "4", "Within the turn"), now: t0)
        #expect(tracker.all.first?.todos?.total == 4, "inside a turn a task may be finished before the next is created")
        tracker.apply(change(.updated, "4", nil, .completed), now: t0)
        tracker.apply(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "a", project: "p"), now: t0)
        #expect(tracker.all.first?.todos?.done == 4, "the finished plan stays on the row")
        tracker.apply(change(.created, "5", "Next"), now: t0)
        #expect(tracker.all.first?.todos?.items.map(\.id) == ["5"], "a new prompt's first task starts the next plan")
        tracker.apply(change(.created, "6", "More"), now: t0)
        tracker.apply(change(.created, "5", "Ids started over"), now: t0)
        #expect(tracker.all.first?.todos?.items.map(\.content) == ["Ids started over"])
    }

    /// Hooks run inside subagents too, under the parent's session id: a subagent's plan never touches the parent's.
    @Test func aSubagentsTaskCallsLeaveTheParentsPlanAlone() {
        var tracker = SessionTracker()
        tracker.apply(change(.created, "1", "Parent's"), now: t0)
        tracker.apply(change(.created, "1", "Subagent's", agent: "agent-1"), now: t0)
        tracker.apply(change(.updated, "1", nil, .completed, agent: "agent-1"), now: t0)
        var todo = Hook.Message(event: "PostToolUse", needsInput: false, sessionID: "a", project: "p", agentID: "agent-1")
        todo.todos = TodoPlan(items: [])
        tracker.apply(todo, now: t0)
        #expect(tracker.all.first?.todos?.items == [TodoPlan.Item(id: "1", content: "Parent's", status: .pending)])
    }

    @MainActor @Test func theStoreDropsASubjectWhenTitlesAreOff() {
        let suite = "NotchmeterTests.SessionTasks"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        prefs.sessionTitles = false
        let store = UsageStore(prefs: prefs, providers: [], cache: ReadingCache(defaults: defaults), defaults: defaults, drainLog: nil, reportFile: nil)
        store.hookReceived(change(.created, "1", "secret"), now: t0)
        #expect(store.sessions.all.first?.todos?.items == [TodoPlan.Item(id: "1", content: nil, status: .pending)])
    }
}

/// The card's open lists are closed for a session that has left it, so a set-aside session that comes back does
/// not reopen its old list and the set does not grow.
@Suite struct SessionOpenListPruning {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    @MainActor @Test func listsCloseWhenTheirSessionLeaves() {
        let suite = "NotchmeterTests.SessionOpenLists"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(prefs: Preferences(defaults: defaults), providers: [], cache: ReadingCache(defaults: defaults), defaults: defaults,
                               drainLog: nil, reportFile: nil)
        for id in ["a", "b/slash", "c"] {
            store.hookReceived(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: id, project: "p"), now: t0)
        }
        store.openSessionLists = [SessionsCard.listKey("a", .todos), SessionsCard.listKey("a", .agents), SessionsCard.listKey("b/slash", .todos),
                                  SessionsCard.listKey("c", .todos)]
        store.hookReceived(Hook.Message(event: "SessionEnd", needsInput: false, sessionID: "a", project: "p"), now: t0.addingTimeInterval(1))
        #expect(store.openSessionLists == [SessionsCard.listKey("b/slash", .todos), SessionsCard.listKey("c", .todos)], "an ended session's lists go")
        store.hookReceived(Hook.Message(event: "Stop", needsInput: false, sessionID: "c", project: "p"), now: t0.addingTimeInterval(2))
        store.dismissSession("c")
        #expect(store.openSessionLists == [SessionsCard.listKey("b/slash", .todos)], "a removed session's too")
        store.hookReceived(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "c", project: "p"), now: t0.addingTimeInterval(3))
        #expect(!store.openSessionLists.contains(SessionsCard.listKey("c", .todos)), "and it comes back closed")
    }
}

@Suite struct SessionTodoTracking {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func todo(_ items: [TodoPlan.Item], session: String = "a") -> Hook.Message {
        var message = Hook.Message(event: "PostToolUse", needsInput: false, sessionID: session, project: "p")
        message.todos = TodoPlan(items: items)
        return message
    }

    @Test func theListIsReplacedByTheNextAndClearedByAnEmptyOne() {
        var tracker = SessionTracker()
        tracker.apply(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "a", project: "p"), now: t0)
        tracker.apply(todo([TodoPlan.Item(content: "one", status: .inProgress)]), now: t0.addingTimeInterval(1))
        #expect(tracker.all.first?.todos?.total == 1)
        tracker.apply(todo([TodoPlan.Item(content: "one", status: .completed), TodoPlan.Item(content: "two", status: .pending)]), now: t0.addingTimeInterval(2))
        #expect(tracker.all.first?.todos?.done == 1)
        #expect(tracker.all.first?.todos?.total == 2)
        tracker.apply(Hook.Message(event: "Stop", needsInput: false, sessionID: "a", project: "p"), now: t0.addingTimeInterval(3))
        tracker.apply(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "a", project: "p"), now: t0.addingTimeInterval(4))
        #expect(tracker.all.first?.todos?.total == 2, "Claude Code keeps its list across turns, and so does the row")
        tracker.apply(todo([]), now: t0.addingTimeInterval(5))
        #expect(tracker.all.first?.todos == nil)
    }

    /// A TodoWrite can finish while another call in the same batch is held at a prompt, so it ends no wait.
    @Test func aTodoWriteEndsNoWait() {
        var tracker = SessionTracker()
        tracker.apply(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "a", project: "p"), now: t0)
        tracker.apply(Hook.Message(event: "Notification", needsInput: true, sessionID: "a", project: "p", notificationType: "permission_prompt"), now: t0.addingTimeInterval(1))
        #expect(tracker.all.first?.isWaiting == true)
        tracker.apply(todo([TodoPlan.Item(content: "x", status: .pending)]), now: t0.addingTimeInterval(2))
        #expect(tracker.all.first?.isWaiting == true)
        #expect(tracker.all.first?.todos?.total == 1)
    }

    @Test func turningTitlesOffKeepsTheCountsAndDropsTheWords() {
        var tracker = SessionTracker()
        tracker.apply(todo([TodoPlan.Item(content: "secret", status: .completed)]), now: t0)
        tracker.clearTitles()
        #expect(tracker.all.first?.todos?.items.first?.content == nil)
        #expect(tracker.all.first?.todos?.done == 1)
    }

    @MainActor @Test func theStoreDropsTheWordsWhenTitlesAreOff() {
        let suite = "NotchmeterTests.SessionTodos"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        prefs.sessionTitles = false
        let store = UsageStore(prefs: prefs, providers: [], cache: ReadingCache(defaults: defaults), defaults: defaults, drainLog: nil, reportFile: nil)
        store.hookReceived(todo([TodoPlan.Item(content: "secret", status: .inProgress)]), now: t0)
        let held = store.sessions.all.first?.todos
        #expect(held?.total == 1)
        #expect(held?.items.first?.content == nil, "nothing of the plan's words is held with the setting off")
    }
}

@Suite struct SessionContextFill {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func eachSessionHoldsItsOwnFillAndKeepsItThroughAPayloadWithout() {
        var tracker = SessionTracker()
        tracker.statusline(sessionID: "a", project: "p", contextUsed: 0.42, now: t0)
        tracker.statusline(sessionID: "b", project: "p", now: t0)
        #expect(tracker.all.first { $0.id == "a" }?.contextUsed == 0.42)
        #expect(tracker.all.first { $0.id == "b" }?.contextUsed == nil, "never estimated")
        tracker.statusline(sessionID: "a", project: "p", now: t0.addingTimeInterval(1))
        #expect(tracker.all.first { $0.id == "a" }?.contextUsed == 0.42)
        tracker.statusline(sessionID: "a", project: "p", contextUsed: 1.4, now: t0.addingTimeInterval(2))
        #expect(tracker.all.first { $0.id == "a" }?.contextUsed == 1, "held to the gauge's range")
        tracker.statusline(sessionID: "a", project: "p", contextUsed: .nan, now: t0.addingTimeInterval(3))
        #expect(tracker.all.first { $0.id == "a" }?.contextUsed == 1, "a figure that is not a number is no figure")
    }

    @MainActor @Test func theStatusLineReachesTheSessionThroughTheStore() {
        let suite = "NotchmeterTests.SessionContext"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        let store = UsageStore(prefs: prefs, providers: [], cache: ReadingCache(defaults: defaults), defaults: defaults, drainLog: nil, reportFile: nil)
        store.statuslineReceived(Statusline.Message(sessionID: "a", project: "p", contextUsed: 0.63, receivedAt: t0), now: t0)
        #expect(store.sessions.all.first?.contextUsed == 0.63)
    }
}
