import Foundation
import Testing
@testable import Notchmeter

/// What the Sessions card's extras line is made of, from the payload to the tracker: Claude Code's task list off a
/// `PostToolUse` for `TodoWrite`, reduced before it leaves the hook and held under the titles setting; and the
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
