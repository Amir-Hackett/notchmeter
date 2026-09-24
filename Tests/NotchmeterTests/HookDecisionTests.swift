import Darwin
import Foundation
import Testing
@testable import Notchmeter

/// The two-way hook: what a deciding event carries (and, more to the point, what it does not), the title a
/// prompt leaves, the wire shape, and what the command prints back for each answer.
@Suite struct HookDecisions {
    func parse(_ json: String, tool: ToolID? = nil, event: String? = nil) -> Hook.Message? {
        Hook.message(from: Data(json.utf8), tool: tool, event: event, environment: [:], branch: { _ in nil }, requestID: "r1")
    }

    @Test func aPromptLeavesItsFirstLineAsTheTitle() throws {
        #expect(Hook.title(fromPrompt: "  fix   the\ttests\nand then some") == "fix the tests")
        #expect(Hook.title(fromPrompt: "\n\nsecond line first?") == "second line first?", "leading blank lines are skipped: the first line with words on it is the title")
        #expect(Hook.title(fromPrompt: "   ") == nil)
        #expect(Hook.title(fromPrompt: 42) == nil)
        let long = String(repeating: "word ", count: 40)
        let title = try #require(Hook.title(fromPrompt: long))
        #expect(title.hasSuffix("…"))
        #expect(title.count == Hook.titleLimit + 1)
        let message = try #require(parse(#"{"hook_event_name":"UserPromptSubmit","session_id":"s","prompt":"Refactor the parser\n\nDetails follow"}"#))
        #expect(message.title == "Refactor the parser")
        #expect(message.userInfo["title"] as? String == "Refactor the parser")
        #expect(message.userInfo["prompt"] == nil, "the prompt itself never leaves the process")
        #expect(Hook.Message(userInfo: message.userInfo) == message)
        let stop = try #require(parse(#"{"hook_event_name":"Stop","session_id":"s","prompt":"not read here"}"#))
        #expect(stop.title == nil, "only a prompt submission carries a title")
        let start = try #require(parse(#"{"hook_event_name":"SessionStart","session_id":"s","prompt":"x"}"#))
        #expect(start.title == nil)
    }

    @Test func everyVendorsPromptLeavesATitle() throws {
        let codex = try #require(parse(#"{"hook_event_name":"UserPromptSubmit","session_id":"s","prompt":"codex task"}"#, tool: .codex))
        #expect(codex.title == "codex task")
        let subagent = try #require(parse(#"{"hook_event_name":"UserPromptSubmit","session_id":"s","agent_id":"a","prompt":"sub task"}"#, tool: .codex))
        #expect(subagent.title == nil, "a subagent's submission is not the session's title")
        let cursor = try #require(parse(#"{"hook_event_name":"beforeSubmitPrompt","conversation_id":"c","prompt":"cursor task","attachments":[{"type":"file"}]}"#))
        #expect(cursor.title == "cursor task")
        #expect(cursor.userInfo["attachments"] == nil)
        let gemini = try #require(parse(#"{"hook_event_name":"BeforeAgent","session_id":"g","prompt":"gemini task"}"#))
        #expect(gemini.title == "gemini task")
        let copilot = try #require(parse(#"{"sessionId":"p","prompt":"copilot task"}"#, tool: .copilot, event: "userPromptSubmitted"))
        #expect(copilot.title == "copilot task")
    }

    @Test func aPermissionRequestCarriesASummaryAndNeverTheInput() throws {
        let json = #"""
        {"hook_event_name":"PermissionRequest","session_id":"s","cwd":"/Users/me/proj","permission_mode":"default",
         "tool_name":"Bash","tool_input":{"command":"rm -rf node_modules\nnpm install","description":"Reinstall"},
         "permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm -rf node_modules"},{"toolName":"Bash","ruleContent":"npm install:*"}],"behavior":"allow","destination":"localSettings"},
                                   {"type":"setMode","mode":"acceptEdits","destination":"session"},
                                   {"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm -rf node_modules"}]}]}
        """#
        let message = try #require(parse(json))
        #expect(message.needsInput)
        #expect(message.awaitsDecision)
        let request = try #require(message.request)
        #expect(request.id == "r1")
        #expect(request.kind == .permission(tool: "Bash", summary: "rm -rf node_modules", detail: "rm -rf node_modules\nnpm install",
                                            suggestions: [
                                                PendingRequest.Suggestion(index: 0, grant: .rules(["Bash(rm -rf node_modules)", "Bash(npm install:*)"]), place: .localSettings),
                                                PendingRequest.Suggestion(index: 1, grant: .acceptEdits, place: .session),
                                            ]))
        let info = message.userInfo
        #expect(Set(info.keys) == ["hook_event_name", "needsInput", "session_id", "project", "permission_mode",
                                   "awaitsDecision", "requestID", "toolName", "toolSummary", "toolDetail", "suggestions"])
        #expect(info["tool_input"] == nil)
        #expect(info["tool_name"] == nil)
        #expect(info["permission_suggestions"] == nil)
        #expect(info["cwd"] == nil)
        #expect(Hook.Message(userInfo: info) == message, "the request survives the wire")
        let line = try #require(HookSocket.encode(.hook, info))
        #expect(HookSocket.decode(line) == .hook(message))
        // A line that claims a decision but names no tool and no question is the display-only wait it always was.
        #expect(Hook.Message(userInfo: ["hook_event_name": "PermissionRequest", "needsInput": true, "awaitsDecision": true, "requestID": "x"])?.request == nil)
        #expect(Hook.Message(userInfo: ["hook_event_name": "PermissionRequest", "needsInput": true, "toolName": "Bash", "toolSummary": "ls"])?.request == nil,
                "without awaitsDecision and an id nothing is a request")
    }

    /// The summary names a file the way the card reads best: relative to the session's working directory when it is
    /// under it (the project is a chip on the card already), with the home folder as `~` otherwise, and as it came
    /// when it is neither. The tool still gets the full path; only the card's line is shortened.
    @Test func aFilePathIsNamedRelativeToTheProject() throws {
        let short = { (path: String) in Hook.ToolSummary.shortened(path, cwd: "/Users/me/proj", home: "/Users/me") }
        #expect(short("/Users/me/proj/src/a.swift") == "src/a.swift")
        #expect(short("/Users/me/proj") == ".")
        #expect(short("/Users/me/other/b.swift") == "~/other/b.swift")
        #expect(short("/tmp/x.txt") == "/tmp/x.txt")
        #expect(Hook.ToolSummary.shortened("/Users/me/proj/a", cwd: nil, home: "/Users/me") == "~/proj/a")
        #expect(Hook.ToolSummary.shortened("/Users/me/proj/a", cwd: "", home: "") == "/Users/me/proj/a")
        let message = try #require(parse(#"{"hook_event_name":"PermissionRequest","cwd":"/Users/me/proj","tool_name":"Write","tool_input":{"file_path":"/Users/me/proj/hello.txt","content":"hi"}}"#))
        #expect(message.request?.kind == .permission(tool: "Write", summary: "hello.txt", detail: "hi", suggestions: []))
    }

    @Test func eachToolIsSummarisedByWhatItWantsToDo() throws {
        func kind(_ tool: String, _ input: String) throws -> PendingRequest.Kind {
            let message = try #require(parse(#"{"hook_event_name":"PermissionRequest","tool_name":"\#(tool)","tool_input":\#(input)}"#))
            return try #require(message.request?.kind)
        }
        #expect(try kind("Edit", #"{"file_path":"/Users/me/proj/a.swift","old_string":"let a = 1\nlet b = 2","new_string":"let a = 2"}"#)
                == .permission(tool: "Edit", summary: "/Users/me/proj/a.swift", detail: "- let a = 1\n- let b = 2\n+ let a = 2", suggestions: []))
        let content = (1...45).map { "line \($0)" }.joined(separator: "\n")
        let write = try kind("Write", #"{"file_path":"/tmp/x.txt","content":"\#(content.replacingOccurrences(of: "\n", with: "\\n"))"}"#)
        guard case .permission(_, let summary, let detail?, _) = write else {
            Issue.record("a Write is a permission with a detail")
            return
        }
        #expect(summary == "/tmp/x.txt")
        #expect(detail.hasPrefix("line 1\nline 2\n"))
        #expect(detail.hasSuffix("line 40\n… (5 more lines)"))
        #expect(!detail.contains("line 41"))
        #expect(try kind("Read", #"{"file_path":"/etc/hosts"}"#) == .permission(tool: "Read", summary: "/etc/hosts", detail: nil, suggestions: []))
        #expect(try kind("NotebookEdit", #"{"notebook_path":"/n.ipynb","new_source":"x"}"#) == .permission(tool: "NotebookEdit", summary: "/n.ipynb", detail: nil, suggestions: []))
        #expect(try kind("mcp__github__create_issue", #"{"title":"Bug","body":"secret body"}"#)
                == .permission(tool: "mcp__github__create_issue", summary: "mcp__github__create_issue", detail: nil, suggestions: []),
                "an MCP tool's arguments are not summarised: the name is all that is shown")
        #expect(try kind("WebFetch", #"{"url":"https://example.com/x","prompt":"summarise"}"#) == .permission(tool: "WebFetch", summary: "https://example.com/x", detail: nil, suggestions: []))
        #expect(try kind("Grep", #"{"pattern":"TODO","path":"/src"}"#) == .permission(tool: "Grep", summary: "/src", detail: nil, suggestions: []))
        #expect(try kind("SomethingNew", #"{"x":1}"#) == .permission(tool: "SomethingNew", summary: "SomethingNew", detail: nil, suggestions: []))
        #expect(try kind("Bash", #"{}"#) == .permission(tool: "Bash", summary: "Bash", detail: nil, suggestions: []))
        // Codex: the same shape under its own flag, with the description Codex documents left to the detail's owner.
        let codex = try #require(parse(#"{"hook_event_name":"PermissionRequest","session_id":"s","tool_name":"Bash","tool_input":{"command":"git push --force","description":"Push"}}"#, tool: .codex))
        #expect(codex.request?.kind == .permission(tool: "Bash", summary: "git push --force", detail: "git push --force", suggestions: []))
        #expect(codex.userInfo["tool_input"] == nil)
    }

    @Test func theDetailIsBoundedAndCutOnACharacterBoundary() throws {
        let long = String(repeating: "é", count: 3000) // 6000 bytes
        let bounded = Hook.ToolSummary.bounded(long)
        #expect(bounded.hasSuffix("…"))
        #expect(bounded.utf8.count <= Hook.detailLimit + "…".utf8.count)
        #expect(bounded.dropLast().allSatisfy { $0 == "é" }, "no character is cut in half")
        let message = try #require(parse(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"\#(String(repeating: "x", count: 5000))"}}"#))
        guard case .permission(_, _, let detail?, _) = try #require(message.request?.kind) else {
            Issue.record("a command has a detail")
            return
        }
        #expect(detail.utf8.count <= Hook.detailLimit + 3)
        #expect(Hook.ToolSummary.bounded("short") == "short")
    }

    @Test func aQuestionCarriesItsOptionsAndAnyOtherPreToolUseIsNotARequest() throws {
        let json = #"""
        {"hook_event_name":"PreToolUse","session_id":"s","tool_name":"AskUserQuestion","tool_use_id":"t1",
         "tool_input":{"questions":[{"question":"Which framework?","header":"Framework","options":[{"label":"React","description":"The usual"},{"label":"Vue"}],"multiSelect":false},
                                    {"question":"Which extras?","header":"Extras","options":[{"label":"Lint"},{"label":"Tests"}],"multiSelect":true},
                                    {"question":"No options","header":"x","options":[]}]}}
        """#
        let message = try #require(parse(json))
        #expect(message.needsInput, "a question holds the session as surely as a permission does")
        let request = try #require(message.request)
        #expect(request.kind == .question([
            PendingRequest.Question(text: "Which framework?", header: "Framework", options: [PendingRequest.Option(label: "React", description: "The usual"), PendingRequest.Option(label: "Vue")]),
            PendingRequest.Question(text: "Which extras?", header: "Extras", options: [PendingRequest.Option(label: "Lint"), PendingRequest.Option(label: "Tests")], multiSelect: true),
        ]))
        let info = message.userInfo
        #expect(Set(info.keys) == ["hook_event_name", "needsInput", "session_id", "awaitsDecision", "requestID", "questions"])
        #expect(info["tool_input"] == nil)
        #expect(Hook.Message(userInfo: info) == message)
        let line = try #require(HookSocket.encode(.hook, info))
        #expect(HookSocket.decode(line) == .hook(message), "a nested array is fine on the wire")

        let bash = try #require(parse(#"{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"Bash","tool_input":{"command":"ls"}}"#))
        #expect(bash.request == nil)
        #expect(!bash.needsInput, "a tool call about to run is not a wait")
        #expect(bash.event == "PreToolUse")
        #expect(Set(bash.userInfo.keys) == ["hook_event_name", "needsInput", "session_id"])
        let empty = try #require(parse(#"{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"AskUserQuestion","tool_input":{"questions":[]}}"#))
        #expect(empty.request == nil)
    }

    @Test func theCommandPrintsTheVendorsDecisionForTheAppsReply() throws {
        let allow = try #require(Hook.Answer.line(for: .allow))
        #expect(String(decoding: allow, as: UTF8.self) == "{\"decision\":{\"behavior\":\"allow\"}}\n")
        #expect(Hook.Answer.decision(from: allow) == .allow)
        let deny = try #require(Hook.Answer.line(for: .deny(message: nil)))
        #expect(Hook.Answer.decision(from: deny) == .deny(message: "Denied from Notchmeter"))
        let answers = try #require(Hook.Answer.line(for: .answers(["Which framework?": "React", "Which extras?": "Lint, Tests"])))
        #expect(Hook.Answer.decision(from: answers) == .answers(["Which framework?": "React", "Which extras?": "Lint, Tests"]))
        #expect(Hook.Answer.line(for: .pass) == nil, "a pass is answered with nothing but the hang-up")
        #expect(Hook.Answer.decision(from: Data()) == nil)
        #expect(Hook.Answer.decision(from: Data("{\"decision\":{\"behavior\":\"maybe\"}}".utf8)) == nil)
        #expect(Hook.Answer.decision(from: Data("not json".utf8)) == nil)

        let permission = Data(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}"#.utf8)
        #expect(Hook.Answer.output(event: "PermissionRequest", reply: allow, payload: permission)
                == #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#)
        #expect(Hook.Answer.output(event: "PermissionRequest", reply: deny, payload: permission)
                == #"{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"Denied from Notchmeter"},"hookEventName":"PermissionRequest"}}"#)
        #expect(Hook.Answer.output(event: "PermissionRequest", reply: Data(), payload: permission) == nil, "no reply prints nothing")
        #expect(Hook.Answer.output(event: "PermissionRequest", reply: answers, payload: permission) == nil, "an answer to a permission is no decision")

        let question = Data(#"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which framework?","header":"Framework","options":[{"label":"React"},{"label":"Vue"}],"multiSelect":false}]}}"#.utf8)
        let printed = try #require(Hook.Answer.output(event: "PreToolUse", reply: answers, payload: question))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(printed.utf8)) as? [String: Any])
        let specific = try #require(object["hookSpecificOutput"] as? [String: Any])
        #expect(specific["hookEventName"] as? String == "PreToolUse")
        #expect(specific["permissionDecision"] as? String == "allow")
        let updated = try #require(specific["updatedInput"] as? [String: Any])
        #expect(updated["answers"] as? [String: String] == ["Which framework?": "React", "Which extras?": "Lint, Tests"])
        let questions = try #require(updated["questions"] as? [[String: Any]])
        #expect(questions.count == 1)
        #expect(questions.first?["question"] as? String == "Which framework?", "the tool's input is echoed back unchanged beside the answers")
        #expect(!printed.contains("\n"), "one line")
        #expect(Hook.Answer.output(event: "PreToolUse", reply: allow, payload: question) == nil, "allow alone is not enough for a question, so it is not printed")
        #expect(Hook.Answer.output(event: "PreToolUse", reply: answers, payload: Data("broken".utf8)) == nil)
    }

    @Test func allowAlwaysEchoesTheChosenSuggestionAsUpdatedPermissions() throws {
        let always = try #require(Hook.Answer.line(for: .allowAlways(suggestion: 2)))
        #expect(String(decoding: always, as: UTF8.self) == "{\"decision\":{\"behavior\":\"allow\",\"suggestion\":2}}\n",
                "the app sends the entry's position, never a rule of its own")
        #expect(Hook.Answer.decision(from: always) == .allowAlways(suggestion: 2))
        #expect(Hook.Answer.decision(from: Data(#"{"decision":{"behavior":"allow","suggestion":-1}}"#.utf8)) == .allow)
        #expect(Hook.Answer.decision(from: Data(#"{"decision":{"behavior":"allow","suggestion":"0"}}"#.utf8)) == .allow)
        #expect(Hook.Answer.decision(from: Data(#"{"decision":{"behavior":"deny","suggestion":0}}"#.utf8)) == .deny(message: nil),
                "a suggestion only rides on an allow")

        let payload = Data(#"""
        {"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"npm test"},
         "permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm -rf /"}],"behavior":"deny","destination":"localSettings"},
                                   {"type":"setMode","mode":"bypassPermissions","destination":"session"},
                                   {"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"npm test:*"}],"behavior":"allow","destination":"localSettings"},
                                   {"type":"addDirectories","directories":["/Users/me/lib"],"destination":"session"}]}
        """#.utf8)
        #expect(Hook.Answer.output(event: "PermissionRequest", reply: always, payload: payload) == #"""
        {"hookSpecificOutput":{"decision":{"behavior":"allow","updatedPermissions":[{"behavior":"allow","destination":"localSettings","rules":[{"ruleContent":"npm test:*","toolName":"Bash"}],"type":"addRules"}]},"hookEventName":"PermissionRequest"}}
        """#, "Claude Code's own entry, echoed whole as the one update")
        let directory = try #require(Hook.Answer.line(for: .allowAlways(suggestion: 3)))
        #expect(Hook.Answer.output(event: "PermissionRequest", reply: directory, payload: payload)
                == #"{"hookSpecificOutput":{"decision":{"behavior":"allow","updatedPermissions":[{"destination":"session","directories":["/Users/me/lib"],"type":"addDirectories"}]},"hookEventName":"PermissionRequest"}}"#,
                "the directory goes back as Claude Code sent it, not shortened as the card shows it")

        let plain = #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#
        for index in [0, 1] {
            let reply = try #require(Hook.Answer.line(for: .allowAlways(suggestion: index)))
            #expect(Hook.Answer.output(event: "PermissionRequest", reply: reply, payload: payload) == plain,
                    "entry \(index) is one the card never offers (a deny rule, bypassPermissions), so it is not applied; the call is still allowed")
        }
        let beyond = try #require(Hook.Answer.line(for: .allowAlways(suggestion: 9)))
        #expect(Hook.Answer.output(event: "PermissionRequest", reply: beyond, payload: payload) == plain)
        #expect(Hook.Answer.output(event: "PermissionRequest", reply: always, payload: Data("broken".utf8)) == plain,
                "a payload the command cannot read still gets the allow the user gave")
        #expect(Hook.Answer.output(event: "PreToolUse", reply: always, payload: payload) == nil, "a question is answered, not allowed")
    }

    @Test func theOracleSaysARuleWasAskedForAndNeverWhichRule() {
        let always = UsageStore.decisionFields(request: "r", kind: "permission", behavior: Decision.allowAlways(suggestion: 0).behavior,
                                               session: "s", asksRule: Decision.allowAlways(suggestion: 0).addsRule)
        #expect(always["behavior"] as? String == "allow")
        #expect(always["ruleRequested"] as? Bool == true)
        #expect(Set(always.keys) == ["request", "kind", "behavior", "session", "ruleRequested"])
        let plain = UsageStore.decisionFields(request: "r", kind: "permission", behavior: "allow", session: nil, asksRule: Decision.allow.addsRule)
        #expect(plain["ruleRequested"] as? Bool == false)
        let deny = UsageStore.decisionFields(request: "r", kind: "permission", behavior: "deny", session: nil, asksRule: false)
        #expect(deny["ruleRequested"] == nil, "only an allow says whether it asked for a rule")
        let lost = UsageStore.decisionFields(request: "r", kind: "permission", behavior: "lost", session: nil, asksRule: false)
        #expect(lost["ruleRequested"] == nil)
    }

    @Test @MainActor func theHeadOfALargePayloadSaysWhetherToReadOn() {
        #expect(Hook.looksDeciding(Data(#"{"hook_event_name":"PermissionRequest","tool_name":"Write","tool_input":{"content":""#.utf8)))
        #expect(Hook.looksDeciding(Data(#"{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion""#.utf8)))
        #expect(!Hook.looksDeciding(Data(#"{"hook_event_name":"Stop","session_id":"s"}"#.utf8)))
        #expect(Hook.quickPayloadLimit == 64 * 1024)
        #expect(Hook.decidingPayloadLimit == HookSocket.maximumLine, "a deciding payload may be as large as one line on the wire")
        #expect(Hook.decisionWait == 600)
        #expect(Hook.decisionWait == HookSocket.Listener.holdCap, "the command's wait and the app's cap are one figure")
        #expect(HookVendor.decisionTimeout == Int(HookSocket.Listener.holdCap), "and the entries' timeout is that figure too")
        // The app's own hold is what ends a request, so it stops short of every other clock: the vendor's starts
        // before the command has connected, and a card must never outlive the command under it.
        #expect(Preferences.promptHoldRange.upperBound < Int(HookSocket.Listener.holdCap))
        #expect(Preferences.promptHoldRange.upperBound < Int(SessionTracker.pendingTimeout))
        #expect(SessionTracker.pendingTimeout == HookSocket.Listener.holdCap)
    }

    @Test func aRemotePostKeepsTheTitleAndDropsWhatItCannotUse() throws {
        let body = Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"s","cwd":"/x/proj","branch":"main","host":"vps","prompt":"remote task","terminal_program":"iTerm.app"}"#.utf8)
        let message = try #require(LocalAPI.hookMessage(from: body))
        #expect(message.title == "remote task")
        #expect(message.terminal == nil, "a remote terminal's ids name windows on another machine")
        let permission = Data(#"{"hook_event_name":"PermissionRequest","session_id":"s","host":"vps","tool_name":"Bash","tool_input":{"command":"ls"}}"#.utf8)
        let posted = try #require(LocalAPI.hookMessage(from: permission))
        #expect(posted.needsInput, "the wait shows")
        #expect(posted.request == nil, "but nothing can be decided over a route that answers 202")
    }
}

/// The hooks files: the deciding entries are synchronous with the decision timeout, Claude Code's PreToolUse is
/// matched to AskUserQuestion, a 0.6.0 install reads as out of date and the launch repair upgrades it.
@Suite struct HookDecisionSettings {
    let executable = "/Applications/Notchmeter.app/Contents/MacOS/Notchmeter"

    @Test func theSnippetMakesTheDecidingEntriesSynchronous() throws {
        let snippet = HookSettings.snippet(executable: executable)
        let root = try #require(try JSONSerialization.jsonObject(with: Data(snippet.utf8)) as? [String: Any])
        let hooks = try #require(root["hooks"] as? [String: Any])
        #expect(HookSettings.events.contains("PreToolUse"))
        for event in HookSettings.events {
            let group = try #require((hooks[event] as? [[String: Any]])?.first, "\(event)")
            let handler = try #require((group["hooks"] as? [[String: Any]])?.first, "\(event)")
            if HookVendor.claude.decidingEvents.contains(event) {
                #expect(Set(handler.keys) == ["type", "command", "timeout"], "\(event): no async, or the answer could decide nothing")
                #expect(handler["timeout"] as? Int == 600, "\(event)")
            } else {
                #expect(handler["async"] as? Bool == true, "\(event)")
                #expect(handler["timeout"] as? Int == 5, "\(event)")
            }
            #expect(group["matcher"] as? String == HookVendor.claude.matcher(for: event), "\(event)")
        }
        #expect(snippet.contains("\"PreToolUse\": [\n      { \"matcher\": \"AskUserQuestion\", \"hooks\": [ { \"type\": \"command\", \"command\": \"'\(executable)' --hook\", \"timeout\": 600 } ] }"))
        #expect(snippet.contains("\"PostToolUse\": [\n      { \"matcher\": \"TodoWrite|TaskCreate|TaskUpdate\", \"hooks\": [ { \"type\": \"command\", \"command\": \"'\(executable)' --hook\", \"async\": true, \"timeout\": 5 } ] }"))
        #expect(snippet.contains("\"PermissionRequest\": [\n      { \"hooks\": [ { \"type\": \"command\", \"command\": \"'\(executable)' --hook\", \"timeout\": 600 } ] }"))
    }

    @Test func aSixPointZeroInstallIsPartialAndRepairUpgradesItOnce() throws {
        // What 0.6.0 wrote: every event async with a five-second timeout, and no PreToolUse or PostToolUse, nor any
        // of the events 0.11 added.
        var hooks: [String: Any] = [:]
        for event in HookSettings.events where event != "PreToolUse" && event != "PostToolUse" && !HookEventInstallation.added.contains(event) {
            hooks[event] = [["hooks": [["type": "command", "command": "'\(executable)' --hook", "async": true, "timeout": 5]]]]
        }
        let older: [String: Any] = ["hooks": hooks, "model": "opus"]
        let status = HookSettings.status(settings: older, executable: executable)
        #expect(status == .partial(path: executable), "the path is right; the PermissionRequest entry cannot carry an answer back")
        #expect(status.needsRepair)

        let repaired = HookSettings.repair(older, executable: executable)
        #expect(repaired.added == ["PreToolUse", "PostToolUse"] + HookEventInstallation.added)
        #expect(repaired.repaired == ["PermissionRequest"], "only the deciding entry changes shape; the others are byte for byte what they were")
        #expect(HookSettings.status(settings: repaired.settings, executable: executable) == .installed(path: executable))
        let written = try #require(repaired.settings["hooks"] as? [String: Any])
        let permission = try #require(((written["PermissionRequest"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first)
        #expect(NSDictionary(dictionary: permission) == NSDictionary(dictionary: ["type": "command", "command": "'\(executable)' --hook", "timeout": 600]))
        let stop = try #require(((written["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first)
        #expect(stop["async"] as? Bool == true)
        #expect(stop["timeout"] as? Int == 5)
        let question = try #require((written["PreToolUse"] as? [[String: Any]])?.first)
        #expect(question["matcher"] as? String == "AskUserQuestion")
        #expect(repaired.settings["model"] as? String == "opus")

        let again = HookSettings.repair(repaired.settings, executable: executable)
        #expect(again.added.isEmpty)
        #expect(again.repaired.isEmpty)
        #expect(NSDictionary(dictionary: again.settings) == NSDictionary(dictionary: repaired.settings))
    }

    /// An unmatched `PostToolUse` of ours would launch the command after every tool call, so it is out of date
    /// even though the event is not a deciding one, and Repair gives the group its task-tool matcher and nothing else.
    @Test func anUnmatchedPostToolUseIsPartialAndRepairMatchesItToTheTaskTools() throws {
        let snippet = HookSettings.snippet(executable: executable)
        var root = try #require(try JSONSerialization.jsonObject(with: Data(snippet.utf8)) as? [String: Any])
        var hooks = try #require(root["hooks"] as? [String: Any])
        hooks["PostToolUse"] = [["hooks": [["type": "command", "command": "'\(executable)' --hook", "async": true, "timeout": 5]]]]
        root["hooks"] = hooks
        #expect(HookSettings.status(settings: root, executable: executable) == .partial(path: executable))
        let repaired = HookSettings.repair(root, executable: executable)
        #expect(repaired.repaired == ["PostToolUse"])
        let group = try #require(((repaired.settings["hooks"] as? [String: Any])?["PostToolUse"] as? [[String: Any]])?.first)
        #expect(group["matcher"] as? String == "TodoWrite|TaskCreate|TaskUpdate")
        let handler = try #require((group["hooks"] as? [[String: Any]])?.first)
        #expect(handler["async"] as? Bool == true, "not a deciding event: the handler stays asynchronous")
        #expect(HookSettings.status(settings: repaired.settings, executable: executable) == .installed(path: executable))
    }

    /// A group matched to `TodoWrite` alone (what the first build of the task list wrote) misses the Task tools
    /// current Claude Code uses: it is out of date, and Repair adds the two names and keeps any the user added.
    @Test func aPostToolUseMatchedToTodoWriteAloneGainsTheTaskTools() throws {
        let snippet = HookSettings.snippet(executable: executable)
        var root = try #require(try JSONSerialization.jsonObject(with: Data(snippet.utf8)) as? [String: Any])
        var hooks = try #require(root["hooks"] as? [String: Any])
        hooks["PostToolUse"] = [["matcher": "TodoWrite|Bash", "hooks": [["type": "command", "command": "'\(executable)' --hook", "async": true, "timeout": 5]]]]
        root["hooks"] = hooks
        #expect(HookSettings.status(settings: root, executable: executable) == .partial(path: executable))
        let repaired = HookSettings.repair(root, executable: executable)
        #expect(repaired.repaired == ["PostToolUse"])
        let group = try #require(((repaired.settings["hooks"] as? [String: Any])?["PostToolUse"] as? [[String: Any]])?.first)
        #expect(group["matcher"] as? String == "TodoWrite|Bash|TaskCreate|TaskUpdate")
        #expect(HookSettings.status(settings: repaired.settings, executable: executable) == .installed(path: executable))
    }

    @Test func aMatcherCoversARequiredListNameByName() {
        #expect(HookVendor.matcher("AskUserQuestion|Bash", covers: "AskUserQuestion"))
        #expect(!HookVendor.matcher("TodoWrite", covers: "TodoWrite|TaskCreate|TaskUpdate"))
        #expect(HookVendor.matcher("TaskUpdate|TodoWrite|TaskCreate", covers: "TodoWrite|TaskCreate|TaskUpdate"), "order does not matter")
        #expect(!HookVendor.matcher(nil, covers: "AskUserQuestion"))
        #expect(!HookVendor.matcher("AskUserQuestions", covers: "AskUserQuestion"), "a name, not a substring")
        #expect(HookVendor.matcher(nil, adding: "A|B") == "A|B")
        #expect(HookVendor.matcher("B|C", adding: "A|B") == "B|C|A")
    }

    @Test func aPreToolUseGroupWithoutItsMatcherIsPartialAndATimeoutTheUserRaisedIsKept() throws {
        var current = HookSettings.merge(into: [:], executable: executable).settings
        var hooks = try #require(current["hooks"] as? [String: Any])
        hooks["PreToolUse"] = [["hooks": [["type": "command", "command": "'\(executable)' --hook", "timeout": 600]]]]
        hooks["PermissionRequest"] = [["hooks": [["type": "command", "command": "'\(executable)' --hook", "timeout": 900]]]]
        current["hooks"] = hooks
        #expect(HookSettings.status(settings: current, executable: executable) == .partial(path: executable),
                "a PreToolUse group of ours with no matcher would launch the command on every tool call")
        let repaired = HookSettings.repair(current, executable: executable)
        #expect(repaired.repaired == ["PreToolUse"])
        let written = try #require(repaired.settings["hooks"] as? [String: Any])
        #expect((written["PreToolUse"] as? [[String: Any]])?.first?["matcher"] as? String == "AskUserQuestion")
        let permission = try #require(((written["PermissionRequest"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first)
        #expect(permission["timeout"] as? Int == 900, "a longer timeout is the user's")
        #expect(HookSettings.status(settings: repaired.settings, executable: executable) == .installed(path: executable))

        var wider = repaired.settings
        var widened = try #require(wider["hooks"] as? [String: Any])
        widened["PreToolUse"] = [["matcher": "AskUserQuestion|ExitPlanMode", "hooks": [["type": "command", "command": "'\(executable)' --hook", "timeout": 600]]]]
        wider["hooks"] = widened
        #expect(HookSettings.status(settings: wider, executable: executable) == .installed(path: executable), "a matcher that still covers the question is the user's")
    }

    @Test func codexAndCopilotDecidingEntriesFollowTheSameRule() throws {
        var codex = HookSettings.merge(into: [:], vendor: .codex, executable: executable).settings
        #expect(HookSettings.status(settings: codex, vendor: .codex, executable: executable) == .installed(path: executable))
        var hooks = try #require(codex["hooks"] as? [String: Any])
        hooks["PermissionRequest"] = [["hooks": [["type": "command", "command": "'\(executable)' --hook --tool codex", "timeout": 5]]]]
        codex["hooks"] = hooks
        #expect(HookSettings.status(settings: codex, vendor: .codex, executable: executable) == .partial(path: executable), "0.6.0's five-second entry")
        let repaired = HookSettings.repair(codex, vendor: .codex, executable: executable)
        #expect(repaired.repaired == ["PermissionRequest"])
        let handler = try #require((((repaired.settings["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first)
        #expect(NSDictionary(dictionary: handler) == NSDictionary(dictionary: ["type": "command", "command": "'\(executable)' --hook --tool codex", "timeout": 600]))

        let copilot = HookVendor.copilot.handler(command: "'\(executable)' --hook --tool copilot --event PermissionRequest", event: "PermissionRequest")
        #expect(NSDictionary(dictionary: copilot) == NSDictionary(dictionary: ["type": "command", "command": "'\(executable)' --hook --tool copilot --event PermissionRequest", "timeoutSec": 600]))
        var older = HookSettings.merge(into: [:], vendor: .copilot, executable: executable).settings
        var entries = try #require(older["hooks"] as? [String: Any])
        entries["PermissionRequest"] = nil
        older["hooks"] = entries
        #expect(HookSettings.status(settings: older, vendor: .copilot, executable: executable) == .partial(path: executable), "a 0.6.0 file has no PermissionRequest entry")
        #expect(HookSettings.repair(older, vendor: .copilot, executable: executable).added == ["PermissionRequest"])
        let untimed: [String: Any] = ["type": "command", "command": "'\(executable)' --hook --tool copilot --event PermissionRequest"]
        #expect(!HookVendor.copilot.isCurrent(handler: untimed, element: untimed, event: "PermissionRequest"), "Copilot's default is 30 s, which would cancel the command before the user answers")
        #expect(HookVendor.cursor.decidingEvents.isEmpty)
        #expect(HookVendor.antigravity.decidingEvents.isEmpty)
    }
}

/// The socket carrying an answer back: the command holds the connection, the app writes one line and hangs up,
/// and every way that can fail leaves the command with nothing, promptly.
@Suite struct HookSocketDecisions {
    static func request(_ id: String = "r1") -> Hook.Message {
        var message = Hook.Message(event: "PermissionRequest", needsInput: true, sessionID: "s")
        message.request = Hook.Request(id: id, kind: .permission(tool: "Bash", summary: "ls", detail: nil, suggestions: []))
        return message
    }

    @Test func aDecisionRoundTripsOnTheSameConnection() throws {
        let url = HookSocketTransport.scratch("decide")
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let listener = HookSocket.Listener(path: url, peerCheck: { _ in .accepted }, holdCap: 5) { message, reply in
            guard case .hook(let hook) = message, hook.awaitsDecision else {
                reply.answer(nil)
                return
            }
            // The app, answering from its UI two hundred milliseconds later.
            Thread.detachNewThread {
                Thread.sleep(forTimeInterval: 0.2)
                reply.answer(Hook.Answer.line(for: .deny(message: nil)))
                reply.answer(Hook.Answer.line(for: .allow))
            }
        }
        #expect(listener.start())
        defer { listener.stop() }

        let started = Date()
        let result = HookSocket.send(.hook, Self.request().userInfo, to: url.path, timeout: 5)
        let elapsed = Date().timeIntervalSince(started)
        guard case .sent(let reply?) = result else {
            Issue.record("the command must get the app's line back: \(result)")
            return
        }
        #expect(Hook.Answer.decision(from: reply) == .deny(message: "Denied from Notchmeter"), "the first answer wins; the second is a no-op")
        #expect(elapsed >= 0.15, "the command waited for the answer: \(elapsed) s")
        #expect(elapsed < 2.5, "and returned as soon as it came, well inside the cap: \(elapsed) s")
        // The worker notices the answer at its next look at the peer (Listener.peerPoll), so the slot is given
        // back within a poll of the command returning, not in the same instant.
        #expect(Self.settles { listener.parkedCount == 0 })
    }

    /// Dials `url` the way the command does for a deciding line: connect and keep the write side open. The
    /// caller writes the line and, later, closes the descriptor, which is the hook process going away.
    static func dial(_ url: URL) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let path = url.path
        withUnsafeMutablePointer(to: &address.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { buffer in
                _ = path.withCString { strlcpy(buffer, $0, capacity) }
            }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            close(fd)
            return -1
        }
        return fd
    }

    /// Polls `condition` every 20 ms for up to `deadline` seconds.
    static func settles(within deadline: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        let until = Date().addingTimeInterval(deadline)
        while Date() < until {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    /// The command behind a deciding line keeps its write side open, and that is what lets the parked worker tell
    /// the hook process going away (its vendor cancelled it, the turn was interrupted, a 0.6.0 entry's five
    /// seconds ran out) from one still waiting: the connection turns readable with nothing on it, the request is
    /// ended through `whenPeerCloses` well inside the cap, and the slot is given back.
    @Test func aPeerThatGoesAwayReleasesItsRequestAtOnce() throws {
        let url = HookSocketTransport.scratch("gone")
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let gone = DispatchSemaphore(value: 0)
        let replies = OSAllocatedUnfairLockBox<[HookSocket.Reply]>([])
        let listener = HookSocket.Listener(path: url, peerCheck: { _ in .accepted }, holdCap: 5) { _, reply in
            replies.set(replies.get() + [reply])
            // The store hangs the end of the request on this, as UsageStore.hookReceived does.
            reply.whenPeerCloses { gone.signal() }
        }
        #expect(listener.start())
        defer { listener.stop() }

        let line = try #require(HookSocket.encode(.hook, Self.request("r1").userInfo))
        let fd = Self.dial(url)
        try #require(fd >= 0)
        #expect(line.withUnsafeBytes { write(fd, $0.baseAddress!, line.count) } == line.count)
        #expect(Self.settles { listener.parkedCount == 1 }, "the line was taken and the connection parked")
        Thread.sleep(forTimeInterval: 0.4)
        #expect(replies.get().first?.isAnswered == false, "a peer that is merely quiet is not a peer that is gone")
        #expect(replies.get().first?.isPeerClosed == false)

        let closed = Date()
        close(fd)
        #expect(gone.wait(timeout: .now() + 2) == .success, "the peer going ends the request")
        let noticed = Date().timeIntervalSince(closed)
        #expect(noticed < 1, "and is noticed within a poll or two, not at the cap: \(noticed) s")
        #expect(replies.get().first?.isPeerClosed == true)
        #expect(replies.get().first?.isAnswered == true)
        #expect(Self.settles { listener.parkedCount == 0 }, "the slot is given back")
    }

    @Test func noAnswerInsideTheHoldCapIsNothing() throws {
        let url = HookSocketTransport.scratch("hold")
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let listener = HookSocket.Listener(path: url, peerCheck: { _ in .accepted }, holdCap: 0.5) { _, _ in }
        #expect(listener.start())
        defer { listener.stop() }

        let started = Date()
        let result = HookSocket.send(.hook, Self.request().userInfo, to: url.path, timeout: 5)
        let elapsed = Date().timeIntervalSince(started)
        #expect(result == .sent(reply: nil), "a hold that ran out prints nothing, so the terminal asks")
        #expect(elapsed >= 0.4, "the connection was held for the cap: \(elapsed) s")
        #expect(elapsed < 2, "and no longer: \(elapsed) s")
    }

    @Test func anOrdinaryEventIsStillAnsweredAtOnce() throws {
        let url = HookSocketTransport.scratch("ordinary")
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let seen = HookSocketTransport.Seen()
        let replies = OSAllocatedUnfairLockBox<[HookSocket.Reply]>([])
        let listener = HookSocket.Listener(path: url, peerCheck: { _ in .accepted }, holdCap: 5) { message, reply in
            replies.set(replies.get() + [reply])
            seen.deliver(message)
        }
        #expect(listener.start())
        defer { listener.stop() }

        let started = Date()
        #expect(HookSocket.send(.hook, Hook.Message(event: "Stop", needsInput: false, sessionID: "s").userInfo, to: url.path) == .sent(reply: nil))
        let promptly = 0.5
        #expect(Date().timeIntervalSince(started) < promptly, "nothing about the ordinary hop changed")
        #expect(seen.delivered.wait(timeout: .now() + 2) == .success)
        #expect(replies.get().first?.isAnswered == true, "the listener closed it the moment delivery returned")
        #expect(listener.parkedCount == 0)
    }

    @Test func pastTheParkedCapARequestIsDeliveredWithoutItsRequestAndAnsweredAtOnce() throws {
        let url = HookSocketTransport.scratch("parked")
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let seen = HookSocketTransport.Seen()
        let listener = HookSocket.Listener(path: url, peerCheck: { _ in .accepted }, holdCap: 1.5) { message, _ in seen.deliver(message) }
        #expect(listener.start())
        defer { listener.stop() }

        // Fill the cap with commands nobody answers, then one more.
        let cap = HookSocket.Listener.parkedCap
        let finished = DispatchGroup()
        for index in 0..<cap {
            finished.enter()
            Thread.detachNewThread {
                defer { finished.leave() }
                _ = HookSocket.send(.hook, Self.request("r\(index)").userInfo, to: url.path, timeout: 5)
            }
        }
        #expect(HookSocketTransport.count(seen.delivered, upTo: cap) == cap)
        #expect(listener.parkedCount == cap)
        let started = Date()
        let result = HookSocket.send(.hook, Self.request("overflow").userInfo, to: url.path, timeout: 5)
        let elapsed = Date().timeIntervalSince(started)
        #expect(result == .sent(reply: nil))
        #expect(elapsed < 0.75, "the one past the cap is answered at once: \(elapsed) s")
        #expect(seen.delivered.wait(timeout: .now() + 2) == .success)
        let overflow = seen.messages.last
        guard case .hook(let hook)? = overflow else {
            Issue.record("the request past the cap is still delivered")
            return
        }
        #expect(hook.request == nil, "as the display-only wait it would have been in 0.6.0")
        #expect(hook.needsInput)
        #expect(finished.wait(timeout: .now() + 5) == .success, "the parked ones are released at the cap")
        #expect(Self.settles { listener.parkedCount == 0 })
    }
}

/// The store's end: the reply is kept under the request's id, `decide` alone writes to it, the settings that
/// turn titles and answers off hold, and nothing of the request reaches the oracle.
@Suite struct StoreDecisions {
    let t0 = DateParsing.iso8601("2026-09-01T12:00:00Z")!

    /// A connected pair: the store answers on one end, the test reads the other.
    static func pair() throws -> (reply: HookSocket.Reply, peer: Int32) {
        var fds: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        // As the listener sets on every accepted connection: a write to a peer that has gone is EPIPE, not a signal.
        var on: Int32 = 1
        setsockopt(fds[0], SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return (HookSocket.Reply(fd: fds[0]), fds[1])
    }

    static func read(_ fd: Int32) -> Data {
        var data = Data()
        var scratch = [UInt8](repeating: 0, count: 256)
        while true {
            let count = Darwin.read(fd, &scratch, scratch.count)
            guard count > 0 else { return data }
            data.append(scratch, count: count)
        }
    }

    @MainActor
    func store(_ suite: String, configure: (Preferences) -> Void = { _ in }) -> (UsageStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let prefs = Preferences(defaults: defaults)
        prefs.notifyWaiting = true
        configure(prefs)
        let store = UsageStore(prefs: prefs, providers: [], cache: ReadingCache(defaults: defaults), defaults: defaults, drainLog: nil, reportFile: nil)
        return (store, defaults)
    }

    @MainActor @Test func aDecisionIsWrittenToTheParkedReplyAndClearsTheRequest() throws {
        let suite = "NotchmeterTests.decide"
        let (store, defaults) = store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        var acted: [String] = []
        store.deliverSessionEvent = { _, session in acted.append("raise \(session.id)") }
        store.removeNotifications = { acted.append("withdraw \($0.joined(separator: ","))") }
        store.promptRequested = { session, request in acted.append("prompt \(session.id) \(request.id)") }
        store.promptEnded = { acted.append("ended \($0)") }

        let (reply, peer) = try Self.pair()
        defer { close(peer) }
        store.hookReceived(HookSocketDecisions.request("r1"), now: t0, reply: reply)
        #expect(acted == ["prompt s r1", "raise s"])
        #expect(store.sessions.pending(now: t0).map(\.request.id) == ["r1"])
        #expect(store.sessions.all.first?.isWaiting == true)
        #expect(!reply.isAnswered, "the reply is parked until the app decides")

        store.decide("nobody", .allow, now: t0.addingTimeInterval(1))
        #expect(!reply.isAnswered, "an id the app is not showing decides nothing")
        #expect(acted.count == 2)

        store.decide("r1", .allow, now: t0.addingTimeInterval(2))
        #expect(reply.isAnswered)
        #expect(String(decoding: Self.read(peer), as: UTF8.self) == "{\"decision\":{\"behavior\":\"allow\"}}\n")
        #expect(store.sessions.pending(now: t0.addingTimeInterval(2)).isEmpty)
        #expect(store.sessions.all.first?.isWorking == true, "an allowed session is running again until its next event says otherwise")
        #expect(acted == ["prompt s r1", "raise s", "withdraw session/s/waiting", "ended r1"])
        store.decide("r1", .deny(message: nil), now: t0.addingTimeInterval(3))
        #expect(acted.count == 4, "a second decision on the same id is nothing")
    }

    /// *Allow always*'s unfold lives on the store, so the edge layout's probe measures it; it is kept for a
    /// pending request only and leaves with the request.
    @MainActor @Test func anUnfoldIsKeptForAPendingRequestAndLeavesWithIt() throws {
        let suite = "NotchmeterTests.unfold"
        let (store, defaults) = store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let (reply, peer) = try Self.pair()
        defer { close(peer) }
        store.hookReceived(HookSocketDecisions.request("r1"), now: t0, reply: reply)
        store.unfoldSuggestions("nobody", true, now: t0)
        #expect(store.unfoldedSuggestions.isEmpty, "an id the app is not showing is not unfolded")
        store.unfoldSuggestions("r1", true, now: t0)
        #expect(store.unfoldedSuggestions == ["r1"])
        store.unfoldSuggestions("r1", false, now: t0)
        #expect(store.unfoldedSuggestions.isEmpty)
        store.unfoldSuggestions("r1", true, now: t0)
        store.decide("r1", .allow, now: t0.addingTimeInterval(1))
        #expect(store.unfoldedSuggestions.isEmpty, "an answered request takes its unfold with it")
    }

    @MainActor @Test func aPassLeavesTheSessionWaitingAndANewRequestReleasesTheOld() throws {
        let suite = "NotchmeterTests.pass"
        let (store, defaults) = store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        var ended: [String] = []
        store.promptEnded = { ended.append($0) }

        let first = try Self.pair()
        defer { close(first.peer) }
        store.hookReceived(HookSocketDecisions.request("r1"), now: t0, reply: first.reply)
        store.decide("r1", .pass, now: t0.addingTimeInterval(1))
        #expect(first.reply.isAnswered)
        #expect(Self.read(first.peer).isEmpty, "a pass is the hang-up alone")
        #expect(store.sessions.all.first?.isWaiting == true, "the terminal is asking now")
        #expect(store.sessions.pending(now: t0.addingTimeInterval(1)).isEmpty)
        #expect(ended == ["r1"])

        let second = try Self.pair()
        defer { close(second.peer) }
        let third = try Self.pair()
        defer { close(third.peer) }
        store.hookReceived(HookSocketDecisions.request("r2"), now: t0.addingTimeInterval(2), reply: second.reply)
        store.hookReceived(HookSocketDecisions.request("r3"), now: t0.addingTimeInterval(3), reply: third.reply)
        #expect(second.reply.isAnswered, "a request overtaken on the same session is released with nothing")
        #expect(!third.reply.isAnswered)
        #expect(ended == ["r1", "r2"])
        store.hookReceived(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "s"), now: t0.addingTimeInterval(4))
        #expect(third.reply.isAnswered, "the session moving on releases its request")
        #expect(ended == ["r1", "r2", "r3"])
        store.decide("r3", .answers(["q": "a"]), now: t0.addingTimeInterval(5))
        #expect(Self.read(third.peer).isEmpty)
    }

    @MainActor @Test func answeringFromTheNotchOffAnswersNothingAtOnceAndTitlesOffDropsTheTitle() throws {
        let suite = "NotchmeterTests.answerOff"
        let (store, defaults) = store(suite) { prefs in
            prefs.answerFromNotch = false
            prefs.sessionTitles = false
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        var prompted = 0
        store.promptRequested = { _, _ in prompted += 1 }
        let (reply, peer) = try Self.pair()
        defer { close(peer) }
        store.hookReceived(HookSocketDecisions.request("r1"), now: t0, reply: reply)
        #expect(reply.isAnswered, "the terminal asks")
        #expect(Self.read(peer).isEmpty)
        #expect(prompted == 0)
        #expect(store.sessions.all.first?.isWaiting == true, "the wait still shows")
        #expect(store.sessions.pending(now: t0).isEmpty)

        var prompt = Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "s")
        prompt.title = "the secret plan"
        store.hookReceived(prompt, now: t0.addingTimeInterval(1))
        #expect(store.sessions.all.first?.title == nil, "nothing of the prompt is held anywhere")

        let on = "NotchmeterTests.titlesOn"
        let (open, openDefaults) = self.store(on)
        defer { openDefaults.removePersistentDomain(forName: on) }
        open.hookReceived(prompt, now: t0)
        #expect(open.sessions.all.first?.title == "the secret plan")
    }

    @MainActor @Test func theHoldPassesTheRequestBackAfterThePreferenceSeconds() async throws {
        let suite = "NotchmeterTests.hold"
        let (store, defaults) = store(suite) { $0.promptHoldSeconds = 15 }
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(store.prefs.promptHoldSeconds == 15, "the floor of the range")
        store.prefs.promptHoldSeconds = 1
        #expect(store.prefs.promptHoldSeconds == 15, "clamped, not taken")
        store.prefs.promptHoldSeconds = 9000
        #expect(store.prefs.promptHoldSeconds == 540, "the ceiling stops a minute short of the socket's cap and the entries' timeouts")
        #expect(Preferences.promptHoldDefault == 120)
        // The hold itself is a Task on the preference's seconds; fifteen is the shortest it can be, so the timer
        // is not waited for here: what is pinned is that the request stands until something ends it.
        let (reply, peer) = try Self.pair()
        defer { close(peer) }
        store.hookReceived(HookSocketDecisions.request("r1"), now: t0, reply: reply)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!reply.isAnswered)
        store.decide("r1", .pass)
        #expect(reply.isAnswered)
    }

    /// The socket's worker saw the hook process go (the vendor cancelled the command, the turn was interrupted):
    /// the card comes down at once and the hold with it, the session is left waiting as after a pass, and a
    /// decision on the gone request is nothing.
    @MainActor @Test func aRequestWhoseHookWentAwayComesDownAtOnce() async throws {
        let suite = "NotchmeterTests.peerGone"
        let (store, defaults) = store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        var ended: [String] = []
        store.promptEnded = { ended.append($0) }
        let (reply, peer) = try Self.pair()
        defer { close(peer) }
        store.hookReceived(HookSocketDecisions.request("r1"), now: t0, reply: reply)
        #expect(!reply.isAnswered)
        reply.peerClosed()
        #expect(reply.isAnswered)
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.sessions.pending(now: t0.addingTimeInterval(1)).isEmpty, "the card is down")
        #expect(ended == ["r1"])
        #expect(store.sessions.all.first?.isWaiting == true, "the terminal is asking, or has gone on; nothing here says which")
        store.decide("r1", .allow, now: t0.addingTimeInterval(2))
        #expect(ended == ["r1"], "a decision on the gone request is nothing")
        #expect(store.sessions.all.first?.isWaiting == true)
    }

    /// The hook process died in the instant between the worker's last look and the click: the line cannot be
    /// written, so the decision is recorded as lost and the session is not marked working on an allow nothing
    /// received.
    @MainActor @Test func aDecisionTheSocketCannotTakeIsLostNotDelivered() throws {
        let suite = "NotchmeterTests.lost"
        let (store, defaults) = store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        var ended: [String] = []
        store.promptEnded = { ended.append($0) }
        let (reply, peer) = try Self.pair()
        store.hookReceived(HookSocketDecisions.request("r1"), now: t0, reply: reply)
        close(peer)
        store.decide("r1", .allow, now: t0.addingTimeInterval(1))
        #expect(reply.isAnswered)
        #expect(store.sessions.pending(now: t0.addingTimeInterval(1)).isEmpty)
        #expect(ended == ["r1"])
        #expect(store.sessions.all.first?.isWaiting == true, "nothing received the allow, so the session is not put back to work on it")
    }

    /// A second line under an id already standing is a replay (the ids are UUIDs the hook generated): the first
    /// keeps its place and its clock, the second's connection is released at once rather than parked for the
    /// cap, and the decision goes to the first.
    @MainActor @Test func aSecondLineUnderAStandingRequestIDIsReleasedAtOnce() throws {
        let suite = "NotchmeterTests.replay"
        let (store, defaults) = store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        var prompted: [String] = []
        store.promptRequested = { _, request in prompted.append(request.id) }
        let first = try Self.pair()
        defer { close(first.peer) }
        let second = try Self.pair()
        defer { close(second.peer) }
        store.hookReceived(HookSocketDecisions.request("r1"), now: t0, reply: first.reply)
        store.hookReceived(HookSocketDecisions.request("r1"), now: t0.addingTimeInterval(1), reply: second.reply)
        #expect(!first.reply.isAnswered, "the first keeps its place")
        #expect(second.reply.isAnswered, "the replay is released, so its connection holds no slot")
        #expect(Self.read(second.peer).isEmpty)
        #expect(prompted == ["r1"])
        #expect(store.sessions.pending(now: t0.addingTimeInterval(1)).map(\.request.since) == [t0])
        store.decide("r1", .allow, now: t0.addingTimeInterval(2))
        #expect(String(decoding: Self.read(first.peer), as: UTF8.self) == "{\"decision\":{\"behavior\":\"allow\"}}\n")
        #expect(store.sessions.pending(now: t0.addingTimeInterval(2)).isEmpty)
    }

    /// Turning *Show what a session is working on* off drops the titles already held, not only the ones to come:
    /// an idle session's next prompt may never arrive, and docs/hooks.md promises nothing of a prompt is held
    /// anywhere with the setting off.
    @MainActor @Test func titlesOffClearsTheTitlesAlreadyHeld() async throws {
        let suite = "NotchmeterTests.titlesOff"
        let (store, defaults) = store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        var prompt = Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "s")
        prompt.title = "the secret plan"
        store.hookReceived(prompt, now: t0)
        #expect(store.sessions.all.first?.title == "the secret plan")
        store.prefs.sessionTitles = false
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.sessions.all.first?.title == nil, "off drops what was held, not only what comes next")
        #expect(store.sessions.all.count == 1, "the session itself stays")
        store.prefs.sessionTitles = true
        try await Task.sleep(for: .milliseconds(100))
        store.hookReceived(prompt, now: t0.addingTimeInterval(1))
        #expect(store.sessions.all.first?.title == "the secret plan", "and on again takes titles as before")
    }

    @Test func theOracleHearsTheShapeOfARequestAndNeverItsContent() throws {
        var message = Hook.Message(event: "PermissionRequest", needsInput: true, sessionID: "s", project: "proj")
        message.request = Hook.Request(id: "r1", kind: .permission(tool: "Bash", summary: "rm -rf secret", detail: "rm -rf secret\necho token", suggestions: [
            PendingRequest.Suggestion(index: 0, grant: .rules(["Bash(rm:*)"]), place: .localSettings)]))
        message.title = "the secret plan"
        message.terminal = TerminalRef(program: "iTerm.app", bundleID: "com.googlecode.iterm2", tty: "/dev/ttys003", sessionID: "w0t0p0:X")
        let facts = UsageStore.hookFacts(message)
        #expect(Set(facts.keys) == ["name", "needsInput", "session", "project", "host", "branch", "agent", "failure", "request", "wait"])
        #expect(facts["wait"] as? String == "permission")
        #expect(facts["request"] as? String == "permission")
        for key in ["title", "toolName", "toolSummary", "toolDetail", "suggestions", "questions", "terminal", "terminal_tty", "terminal_program", "requestID"] {
            #expect(facts[key] == nil, "\(key)")
        }
        let line = try #require(Oracle.line(event: "hook", fields: facts, at: t0, home: "/Users/me"))
        for secret in ["secret", "token", "rm:*", "ttys003", "iTerm", "w0t0p0", "r1"] {
            #expect(!line.contains(secret), "\(secret) must not reach the oracle")
        }
        var question = Hook.Message(event: "PreToolUse", needsInput: true, sessionID: "s")
        question.request = Hook.Request(id: "r2", kind: .question([PendingRequest.Question(text: "Which secret?", options: [PendingRequest.Option(label: "A")])]))
        #expect(UsageStore.hookFacts(question)["request"] as? String == "question")
        #expect(UsageStore.hookFacts(Hook.Message(event: "Stop", needsInput: false)).keys.contains("request") == false)
    }
}
