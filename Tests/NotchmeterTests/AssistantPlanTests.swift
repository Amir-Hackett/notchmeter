import Foundation
import Testing
@testable import Notchmeter

/// Since 0.9.13 every assistant whose hook can see its task list puts it on the session's row, as Claude Code's
/// does: Codex's `update_plan`, Gemini CLI's `write_todos`, Kimi Code's `SetTodoList`, Copilot's `update_todo` and
/// OpenCode's `todo.updated`. Each payload here is the shape the vendor's own source (or, for Copilot, the two
/// shapes a to-do tool takes) gives it; each reads onto the PostToolUse the tracker already turns into a plan.
@Suite struct AssistantPlans {
    func parse(_ json: String, tool: ToolID, event: String? = nil) -> Hook.Message? {
        Hook.message(from: Data(json.utf8), tool: tool, event: event, environment: [:], branch: { _ in nil }, requestID: "r1")
    }

    func lines(_ plan: TodoPlan?) -> [String] {
        (plan?.items ?? []).map { "\($0.status.rawValue) \($0.content ?? "-")" }
    }

    @Test func codexsPlanIsItsUpdatePlanInput() throws {
        let json = #"{"hook_event_name":"PostToolUse","session_id":"x1","cwd":"/tmp/proj","model":"gpt-5.5","tool_name":"update_plan","tool_use_id":"t","tool_input":{"explanation":"why","plan":[{"step":"Read the card","status":"completed"},{"step":"Draw the gauge","status":"in_progress"},{"step":"Ship it","status":"pending"}]},"tool_response":"Plan updated"}"#
        let message = try #require(parse(json, tool: .codex))
        #expect(message.event == "PostToolUse")
        #expect(lines(message.todos) == ["completed Read the card", "in_progress Draw the gauge", "pending Ship it"])
        let other = try #require(parse(#"{"hook_event_name":"PostToolUse","session_id":"x1","tool_name":"shell","tool_input":{"plan":[{"step":"no","status":"pending"}]}}"#, tool: .codex))
        #expect(other.todos == nil, "only the plan tool's input is a plan")
    }

    @Test func geminisPlanKeepsItsBlockedAndCancelledSteps() throws {
        let json = #"{"hook_event_name":"AfterTool","session_id":"g1","cwd":"/tmp/proj","tool_name":"write_todos","tool_input":{"todos":[{"description":"Read the card","status":"completed"},{"description":"Wait on the API","status":"blocked"},{"description":"Old idea","status":"cancelled"},{"description":"Draw it","status":"in_progress"}]},"tool_response":{"llmContent":"ok"}}"#
        let message = try #require(parse(json, tool: .gemini))
        #expect(message.event == "PostToolUse", "AfterTool reads as the PostToolUse that carries a plan")
        #expect(lines(message.todos) == ["completed Read the card", "blocked Wait on the API", "cancelled Old idea", "in_progress Draw it"])
        #expect(message.todos?.total == 3, "the cancelled step is out of the count")
    }

    @Test func kimisPlanIsSetTodoListAndAReadIsNoPlan() throws {
        let json = #"{"hook_event_name":"PostToolUse","session_id":"k1","cwd":"/tmp/proj","tool_name":"SetTodoList","tool_input":{"todos":[{"title":"Read the card","status":"done"},{"title":"Draw it","status":"in_progress"}]},"tool_output":"ok","tool_call_id":"c"}"#
        #expect(lines(try #require(parse(json, tool: .kimi)).todos) == ["completed Read the card", "in_progress Draw it"])
        let read = try #require(parse(#"{"hook_event_name":"PostToolUse","session_id":"k1","tool_name":"SetTodoList","tool_input":{}}"#, tool: .kimi))
        #expect(read.todos == nil, "a call without todos only read the list back, and changes nothing")
    }

    @Test func copilotsUndocumentedPlanIsReadInEitherShapeOrNotAtAll() throws {
        let array = #"{"sessionId":"c1","timestamp":1,"cwd":"/tmp/proj","toolName":"update_todo","toolArgs":{"todos":[{"content":"Read the card","status":"completed"},{"title":"Draw it","status":"in_progress"}]},"toolResult":{"resultType":"success"}}"#
        #expect(lines(try #require(parse(array, tool: .copilot, event: "postToolUse")).todos) == ["completed Read the card", "in_progress Draw it"])
        let checklist = #"{"sessionId":"c1","timestamp":1,"cwd":"/tmp/proj","toolName":"update_todo","toolArgs":"{\"todos\":\"- [x] Read the card\\n- [ ] Draw it\"}"}"#
        let fromString = try #require(parse(checklist, tool: .copilot, event: "postToolUse"))
        #expect(fromString.event == "PostToolUse")
        #expect(lines(fromString.todos) == ["completed Read the card", "pending Draw it"], "arguments sent as a JSON string, holding a Markdown checklist")
        let unknown = try #require(parse(#"{"sessionId":"c1","toolName":"update_todo","toolArgs":{"note":"something else"}}"#, tool: .copilot, event: "postToolUse"))
        #expect(unknown.todos == nil, "a shape nobody recognises shows no list rather than a wrong one")
        let wrongStatuses = Hook.plan(fromUndocumented: ["todos": [["content": "a", "status": "someday"]]])
        #expect(wrongStatuses == nil, "items none of whose statuses are known are not a list")
    }

    @Test func aChecklistReadsOnlyItsCheckboxLines() {
        let plan = Hook.plan(fromChecklist: "Plan:\n- [x] one\n  * [X] two\n- [ ] three\n- [?] four\n- plain")
        #expect(lines(plan) == ["completed one", "completed two", "pending three"])
        #expect(Hook.plan(fromChecklist: "no boxes here") == nil)
    }

    @Test func openCodesPlanComesFromItsPluginAndNotFromASubagent() throws {
        let json = #"{"hook_event_name":"todo.updated","session_id":"o1","cwd":"/tmp/proj","todos":[{"content":"Read the card","status":"completed"},{"content":"Dropped","status":"cancelled"},{"content":"Draw it","status":"pending"}]}"#
        let message = try #require(parse(json, tool: .opencode))
        #expect(message.event == "PostToolUse")
        #expect(lines(message.todos) == ["completed Read the card", "cancelled Dropped", "pending Draw it"])
        let child = try #require(parse(#"{"hook_event_name":"todo.updated","session_id":"o1","agent_id":"o2","todos":[{"content":"x","status":"pending"}]}"#, tool: .opencode))
        #expect(child.todos == nil, "a subagent's own list is not the session's")
        #expect(OpenCodePlugin.events.contains("todo.updated"))
        #expect(OpenCodePlugin.version == 2, "a new event in the plugin is a new version, so the launch repair rewrites an installed copy")
        let source = OpenCodePlugin.source(executable: "/Applications/Notchmeter.app/Contents/MacOS/Notchmeter")
        #expect(source.contains(#"case "todo.updated":"#))
        #expect(source.contains(".slice(0, \(OpenCodePlugin.todoTextLimit))"), "a task's text is cut before it leaves OpenCode")
    }

    @Test func eachAfterToolEventIsMatchedToItsPlanToolAlone() {
        #expect(HookVendor.codex.matcher(for: "PostToolUse") == "update_plan")
        #expect(HookVendor.gemini.matcher(for: "AfterTool") == "write_todos")
        #expect(HookVendor.kimi.matcher(for: "PostToolUse") == "SetTodoList")
        #expect(HookVendor.copilot.matcher(for: "postToolUse") == "update_todo")
        #expect(HookVendor.kimi.handler(command: "x", event: "PostToolUse")["matcher"] as? String == "SetTodoList", "Kimi's tables are flat, so the matcher is on the entry")
        #expect(HookVendor.kimi.handler(command: "x", event: "Stop")["matcher"] == nil)
        #expect(KimiHookFile.table(event: "PostToolUse", handler: HookVendor.kimi.handler(command: "x", event: "PostToolUse")).contains("matcher = \"SetTodoList\""))
        for vendor in [HookVendor.cursor, .opencode] {
            #expect(vendor.events.allSatisfy { vendor.matcher(for: $0) == nil }, "\(vendor): nothing matched")
        }
    }

    @Test func anotherAssistantsPlanLandsOnItsRow() throws {
        var tracker = SessionTracker()
        let now = Date(timeIntervalSince1970: 2_000_000)
        tracker.apply(try #require(parse(#"{"hook_event_name":"UserPromptSubmit","session_id":"x1","cwd":"/tmp/proj","prompt":"Add the gauge"}"#, tool: .codex)), now: now)
        let plan = #"{"hook_event_name":"PostToolUse","session_id":"x1","cwd":"/tmp/proj","tool_name":"update_plan","tool_input":{"plan":[{"step":"Read","status":"completed"},{"step":"Draw","status":"pending"}]}}"#
        tracker.apply(try #require(parse(plan, tool: .codex)), now: now.addingTimeInterval(5))
        let session = try #require(tracker.sessions.values.first)
        #expect(session.todos?.done == 1)
        #expect(session.todos?.total == 2)
    }
}

/// Since 0.9.13 the "Compacting" mark and the model chip are every assistant's whose hook can say so: a compaction
/// start and end from Codex and Kimi Code, a start alone from Gemini CLI, Copilot and Cursor (over at the session's
/// next event), and the model Codex, Cursor and OpenCode name.
@Suite struct AssistantCompactionsAndModels {
    func parse(_ json: String, tool: ToolID, event: String? = nil) -> Hook.Message? {
        Hook.message(from: Data(json.utf8), tool: tool, event: event, environment: [:], branch: { _ in nil }, requestID: "r1")
    }

    func session(_ tracker: SessionTracker, _ tool: ToolID, _ id: String) -> AgentSession? {
        tracker.sessions[SessionTracker.key(tool: tool, session: id, host: nil)]
    }

    @Test func aCompactionWithAnEndRunsUntilItsEnd() throws {
        var tracker = SessionTracker()
        let now = Date(timeIntervalSince1970: 3_000_000)
        let start = try #require(parse(#"{"hook_event_name":"PreCompact","session_id":"x1","cwd":"/tmp/proj","model":"gpt-5.5","trigger":"auto"}"#, tool: .codex))
        #expect(start.compaction == .auto)
        tracker.apply(start, now: now)
        tracker.apply(try #require(parse(#"{"hook_event_name":"PostToolUse","session_id":"x1","tool_name":"shell"}"#, tool: .codex)), now: now.addingTimeInterval(1))
        #expect(session(tracker, .codex, "x1")?.compacting != nil, "an assistant that reports the end is believed until it does")
        tracker.apply(try #require(parse(#"{"hook_event_name":"PostCompact","session_id":"x1","trigger":"auto"}"#, tool: .codex)), now: now.addingTimeInterval(9))
        #expect(session(tracker, .codex, "x1")?.compacting == nil)
        #expect(session(tracker, .codex, "x1")?.compactions == 1)
        let kimi = try #require(parse(#"{"hook_event_name":"PostCompact","session_id":"k1","trigger":"manual-with-prompt"}"#, tool: .kimi))
        #expect(kimi.compaction == .manual, "a /compact with words is still the user's own")
    }

    @Test func aCompactionWithNoEndIsOverAtTheNextEvent() throws {
        var tracker = SessionTracker()
        let now = Date(timeIntervalSince1970: 3_000_000)
        let start = try #require(parse(#"{"hook_event_name":"PreCompress","session_id":"g1","cwd":"/tmp/proj","trigger":"auto"}"#, tool: .gemini))
        #expect(start.event == "PreCompact")
        tracker.apply(start, now: now)
        #expect(session(tracker, .gemini, "g1")?.compacting != nil)
        tracker.apply(try #require(parse(#"{"hook_event_name":"AfterAgent","session_id":"g1"}"#, tool: .gemini)), now: now.addingTimeInterval(20))
        #expect(session(tracker, .gemini, "g1")?.compacting == nil, "Gemini has no end event, so the next one is the end")
        let copilot = try #require(parse(#"{"sessionId":"c1","timestamp":1,"cwd":"/tmp/proj","trigger":"manual"}"#, tool: .copilot, event: "preCompact"))
        #expect(copilot.event == "PreCompact" && copilot.compaction == .manual)
        let cursor = try #require(parse(#"{"hook_event_name":"preCompact","conversation_id":"u1","trigger":"auto","context_usage_percent":91}"#, tool: .cursor))
        #expect(cursor.event == "PreCompact" && cursor.compaction == .auto)
        #expect(!ToolID.gemini.reportsCompactionEnd && ToolID.codex.reportsCompactionEnd && ToolID.claude.reportsCompactionEnd)
    }

    @Test func theModelAnAssistantNamesIsTheRowsModel() throws {
        var tracker = SessionTracker()
        let now = Date(timeIntervalSince1970: 3_000_000)
        tracker.apply(try #require(parse(#"{"hook_event_name":"UserPromptSubmit","session_id":"x1","cwd":"/tmp/proj","model":"gpt-5.5","prompt":"go"}"#, tool: .codex)), now: now)
        #expect(session(tracker, .codex, "x1")?.model == "GPT-5.5", "tidied, the owner's pick")
        let cursor = try #require(parse(#"{"hook_event_name":"beforeShellExecution","conversation_id":"u1","model":"claude-opus-4-7-thinking-max","command":"ls"}"#, tool: .cursor))
        #expect(cursor.reportedModel == "claude-opus-4-7-thinking-max")
        let opencode = try #require(parse(#"{"hook_event_name":"chat.message","session_id":"o1","cwd":"/tmp/proj","prompt":"hi","model":"kimi-k2.5"}"#, tool: .opencode))
        #expect(opencode.reportedModel == "kimi-k2.5")
        #expect(Hook.reportedModel("rm -rf / && echo") == nil, "a field that is not shaped like a model id never reaches the row")
        #expect(Hook.reportedModel(String(repeating: "a", count: 81)) == nil)
        #expect(Hook.reportedModel(["modelID": "x"]) == nil)
        let line = try #require(Hook.Message(userInfo: cursor.userInfo))
        #expect(line.reportedModel == cursor.reportedModel, "the model survives the socket")
        #expect(OpenCodePlugin.source(executable: "/x").contains("model: typeof model === \"string\" ? model : undefined"))
    }
}

/// The owner's picks for 0.9.13: model names tidied as Claude's are, a blocked step with a mark of its own, and a
/// cancelled step kept on the list, crossed out and out of the count.
@Suite struct ParityPicks {
    @Test func modelNamesAreTidied() {
        let cases = ["gpt-5.5": "GPT-5.5", "gpt-5-codex": "GPT-5 Codex", "gpt-5.1-codex-max": "GPT-5.1 Codex Max", "gpt-4o": "GPT-4o",
                     "kimi-k2.5": "Kimi K2.5", "gemini-2.5-pro": "Gemini 2.5 Pro", "o4-mini": "o4-mini", "o3": "o3", "auto-smart": "Auto",
                     "claude-opus-4-7-thinking-max": "Opus 4.7", "openai/gpt-5.5": "GPT-5.5", "composer-1": "Composer 1",
                     "qwen3-coder-20250722": "Qwen3 Coder"]
        for (id, shown) in cases { #expect(Hook.tidyModelName(id) == shown, "\(id)") }
    }

    @Test func aCancelledStepStaysOnTheListOutOfTheCount() {
        let plan = TodoPlan(items: [TodoPlan.Item(content: "a", status: .completed), TodoPlan.Item(content: "b", status: .cancelled),
                                    TodoPlan.Item(content: "c", status: .blocked), TodoPlan.Item(content: "d", status: .pending)])
        #expect(plan.done == 1 && plan.total == 3, "2 of 3 still planned; the cancelled one is not counted")
        let finished = TodoPlan(items: [TodoPlan.Item(content: "a", status: .completed), TodoPlan.Item(content: "b", status: .cancelled)])
        #expect(finished.sealedIfDone().sealed, "done and cancelled is a finished plan")
        let onlyCancelled = TodoPlan(items: [TodoPlan.Item(content: "x", status: .cancelled)])
        #expect(onlyCancelled.total == 0)
    }

    @Test func eachAssistantKeepsItsBlockedAndCancelledSteps() throws {
        let gemini = try #require(Hook.message(from: Data(#"{"hook_event_name":"AfterTool","session_id":"g","tool_name":"write_todos","tool_input":{"todos":[{"description":"Wait on review","status":"blocked"},{"description":"Old idea","status":"cancelled"}]}}"#.utf8),
                                               tool: .gemini, event: nil, environment: [:], branch: { _ in nil }, requestID: "r"))
        #expect(gemini.todos?.items.map(\.status) == [.blocked, .cancelled])
        var cursor = CursorPlanFollower()
        let write = #"{"role":"assistant","message":{"content":[{"type":"tool_use","name":"TodoWrite","input":{"merge":false,"todos":[{"id":"1","content":"One","status":"pending"},{"id":"2","content":"Two","status":"pending"}]}}]}}"# + "\n"
        let cancel = #"{"role":"assistant","message":{"content":[{"type":"tool_use","name":"TodoWrite","input":{"merge":true,"todos":[{"id":"2","status":"cancelled"}]}}]}}"# + "\n"
        _ = cursor.feed(Data((write + cancel).utf8))
        #expect(cursor.plan.items.map(\.status) == [.pending, .cancelled])
        #expect(cursor.plan.total == 1)
    }
}
