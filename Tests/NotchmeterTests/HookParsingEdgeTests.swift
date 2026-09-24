import Foundation
import Testing
@testable import Notchmeter

/// The hook's parsing layer at its edges: what each piece does with a field that is missing, empty, the wrong type
/// or shaped some way no vendor documents, and with a name nobody registered. The vendors' own suites (Codex,
/// Copilot, Cursor, Gemini) walk each documented payload and HookDecisions walks the happy path of the two-way
/// hook; this one is the other side of those, because a hook reads JSON another program wrote, and the one thing
/// it must never do with a payload it half understands is claim more than the payload says.
@Suite struct HookDecisionEdges {
    func parse(_ json: String, tool: ToolID? = nil, event: String? = nil) -> Hook.Message? {
        Hook.message(from: Data(json.utf8), tool: tool, event: event, environment: [:], branch: { _ in nil }, requestID: "r1")
    }

    @Test func aTitleIsOnlyEverAStringWithWordsOnIt() {
        #expect(Hook.title(fromPrompt: nil) == nil)
        #expect(Hook.title(fromPrompt: ["fix the tests"]) == nil, "a prompt that is not a string is no title")
        #expect(Hook.title(fromPrompt: "") == nil)
        #expect(Hook.title(fromPrompt: "\n\r\n") == nil, "a prompt of blank lines has no first line to show")
        let exact = String(repeating: "a", count: Hook.titleLimit)
        #expect(Hook.title(fromPrompt: exact) == exact, "a title at the limit is kept whole, with no ellipsis")
        let over = String(repeating: "a", count: Hook.titleLimit + 1)
        let expected = String(repeating: "a", count: Hook.titleLimit) + "…"
        #expect(Hook.title(fromPrompt: over) == expected)
        let spaced = String(repeating: "a", count: Hook.titleLimit - 1) + " bcd"
        let trimmed = String(repeating: "a", count: Hook.titleLimit - 1) + "…"
        #expect(Hook.title(fromPrompt: spaced) == trimmed, "a cut that lands on a space does not leave it before the ellipsis")
    }

    /// Only a `PermissionRequest` with a tool's name, or a `PreToolUse` asking `AskUserQuestion` something, is a
    /// request; every other event, and either of those with its deciding field missing, is not, so the command
    /// never holds the socket for an answer the notch could not ask for.
    @Test func onlyTheTwoDecidingShapesAreRequests() {
        let bash: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": "ls"]]
        for event in ["Stop", "UserPromptSubmit", "Notification", "PostToolUse", "permissionRequest", "SomethingNew", ""] {
            #expect(Hook.request(event: event, object: bash, id: "x") == nil, "\(event) is not a deciding event")
        }
        #expect(Hook.request(event: "PermissionRequest", object: [:], id: "x") == nil, "no tool, nothing to ask about")
        #expect(Hook.request(event: "PermissionRequest", object: ["tool_name": ""], id: "x") == nil)
        #expect(Hook.request(event: "PermissionRequest", object: ["tool_name": 7], id: "x") == nil, "a tool name that is not a string is no tool name")
        #expect(Hook.request(event: "PreToolUse", object: ["tool_name": "Bash", "tool_input": ["questions": [["question": "q", "options": [["label": "a"]]]]]], id: "x") == nil,
                "questions on any tool but AskUserQuestion are not a question")
        #expect(Hook.request(event: "PreToolUse", object: ["tool_name": "AskUserQuestion"], id: "x") == nil, "no input, no questions")
        #expect(Hook.request(event: "PreToolUse", object: ["tool_name": "AskUserQuestion", "tool_input": "questions"], id: "x") == nil)
    }

    @Test func aPermissionReadsEitherSpellingAndSurvivesAMalformedInput() throws {
        // Copilot's camelCase toolName/toolInput, and the snake_case spelling winning when a payload carries both.
        let camel = try #require(Hook.request(event: "PermissionRequest", object: ["toolName": "Bash", "toolInput": ["command": "make"]], id: "c"))
        #expect(camel == Hook.Request(id: "c", kind: .permission(tool: "Bash", summary: "make", detail: "make", suggestions: [])))
        let both = try #require(Hook.request(event: "PermissionRequest",
                                             object: ["tool_name": "Bash", "toolName": "Write", "tool_input": ["command": "ls"], "toolInput": ["command": "rm"]], id: "b"))
        #expect(both.kind == .permission(tool: "Bash", summary: "ls", detail: "ls", suggestions: []), "the snake_case spelling is Claude Code's and is read first")
        // An input that is not an object is read as no input: the tool is still named, and nothing is invented.
        let malformed = try #require(Hook.request(event: "PermissionRequest", object: ["tool_name": "Bash", "tool_input": "ls -la"], id: "m"))
        #expect(malformed.kind == .permission(tool: "Bash", summary: "Bash", detail: nil, suggestions: []))
        let suggestions = try #require(Hook.request(event: "PermissionRequest", object: ["tool_name": "Bash", "permission_suggestions": "allow everything"], id: "s"))
        #expect(suggestions.kind == .permission(tool: "Bash", summary: "Bash", detail: nil, suggestions: []))
    }

    @Test func suggestionsAreOnlyTheUpdatesThatAllowMore() {
        typealias S = PendingRequest.Suggestion
        #expect(Hook.suggestions(from: nil) == [])
        #expect(Hook.suggestions(from: "rm -rf /") == [])
        #expect(Hook.suggestions(from: ["type": "addRules"]) == [], "one entry that is not in an array is not Claude Code's shape")
        #expect(Hook.suggestions(from: ["npm test"]) == [], "a bare string in the array is not an update")
        let entries: [Any] = [
            "npm test",
            ["type": "setMode", "mode": "acceptEdits", "destination": "session"],
            ["type": "addRules", "rules": "npm test", "behavior": "allow"],
            ["type": "addRules", "rules": [["ruleContent": "a"], ["toolName": "Bash"], ["toolName": "Bash", "ruleContent": ""], ["toolName": "Bash", "ruleContent": "b"]],
             "behavior": "allow", "destination": "localSettings"],
            ["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "rm -rf /"]], "behavior": "deny", "destination": "localSettings"],
            ["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "x"]], "destination": "localSettings"],
            ["type": "replaceRules", "rules": [["toolName": "Bash"]], "behavior": "allow", "destination": "userSettings"],
            ["type": "setMode", "mode": "bypassPermissions", "destination": "session"],
            ["type": "addDirectories", "directories": ["/Users/me/proj/sub", "", 4, "/Users/me/other"], "destination": "somewhereNew"],
            ["type": "addDirectories", "directories": []],
            ["type": "setMode", "mode": "acceptEdits", "destination": "session"],
        ]
        #expect(Hook.suggestions(from: entries, cwd: "/Users/me/proj", home: "/Users/me") == [
            S(index: 1, grant: .acceptEdits, place: .session),
            S(index: 3, grant: .rules(["Bash", "Bash(b)"]), place: .localSettings),
            S(index: 8, grant: .directories(["sub", "~/other"]), place: nil),
        ], """
        each keeps its position in the array; a rule is Tool(content) or the tool alone, and one without a tool is \
        skipped; deny, behaviourless, replace and bypass entries are not offered; an unknown destination is nil; \
        a repeat is dropped
        """)
    }

    @Test func aSuggestionSurvivesTheWireAndAnOldLineReadsAsNone() {
        typealias S = PendingRequest.Suggestion
        let all = [S(index: 0, grant: .rules(["Bash(npm test:*)"]), place: .projectSettings),
                   S(index: 2, grant: .directories(["~/src"]), place: .userSettings),
                   S(index: 5, grant: .acceptEdits, place: nil)]
        for suggestion in all {
            #expect(Hook.suggestion(wire: Hook.wire(suggestion: suggestion)) == suggestion)
        }
        #expect(Hook.wire(suggestion: all[2])["destination"] == nil, "no destination writes no key")
        #expect(Hook.suggestion(wire: "npm test:*") == nil, "0.7.x sent the bare rule strings")
        #expect(Hook.suggestion(wire: ["rules": ["Bash"]]) == nil, "no index is nothing to answer with")
        #expect(Hook.suggestion(wire: ["index": -1, "rules": ["Bash"]]) == nil)
        #expect(Hook.suggestion(wire: ["index": 0, "mode": "bypassPermissions"]) == nil, "the only mode is acceptEdits")
        #expect(Hook.suggestion(wire: ["index": 0, "rules": [""]]) == nil)
    }

    @Test func aQuestionWithoutTextOrAnOptionIsDropped() {
        #expect(Hook.questions(from: nil) == [])
        #expect(Hook.questions(from: ["question": "Which?"]) == [])
        let entries: [[String: Any]] = [
            ["header": "No text", "options": [["label": "a"]]],
            ["question": "", "options": [["label": "a"]]],
            ["question": 4, "options": [["label": "a"]]],
            ["question": "Only bad options", "options": [["label": ""], ["description": "no label"], ["label": 9]]],
            ["question": "Options not an array", "options": "a, b"],
            ["question": "Kept", "options": [["label": ""], ["label": "Yes", "description": ""], ["label": "No", "description": "Stop here"]],
             "multiSelect": "true"],
        ]
        let expected = [PendingRequest.Question(text: "Kept", header: "", options: [PendingRequest.Option(label: "Yes"), PendingRequest.Option(label: "No", description: "Stop here")])]
        #expect(Hook.questions(from: entries) == expected,
                "a missing header reads as empty, an empty description as none, a multiSelect that is not a Bool as single, and an option without a label is dropped")
    }

    @Test func aFileToolWithNothingToShowShowsOnlyItsPath() {
        let describe = { (tool: String, input: [String: Any]) in Hook.ToolSummary.describe(tool: tool, input: input, cwd: nil, home: "/Users/me") }
        let edit = describe("Edit", ["file_path": "/tmp/a.swift"])
        #expect(edit.summary == "/tmp/a.swift")
        #expect(edit.detail == nil, "an Edit with neither old nor new text has no diff to show")
        let insert = describe("Edit", ["file_path": "/tmp/a.swift", "new_string": "x"])
        #expect(insert.detail == "- \n+ x", "an empty old string is one empty removed line")
        let multi = describe("MultiEdit", ["file_path": "/tmp/a.swift", "old_string": "a", "new_string": "b"])
        #expect(multi.summary == "/tmp/a.swift")
        #expect(multi.detail == "- a\n+ b")
        let empty = describe("Write", ["file_path": "/Users/me/new.txt", "content": ""])
        #expect(empty.summary == "~/new.txt")
        #expect(empty.detail == nil, "an empty file has no excerpt")
        let forty = (1...Hook.writeDetailLines).map { "line \($0)" }.joined(separator: "\n")
        #expect(describe("Write", ["file_path": "/tmp/x", "content": forty]).detail == forty, "forty lines is the whole file, with nothing said about more")
        let pathless = describe("Write", ["content": "hi"])
        #expect(pathless.summary == "Write", "without a path the tool's name is the summary")
        #expect(describe("NotebookRead", ["notebook_path": "/tmp/n.ipynb"]).summary == "/tmp/n.ipynb")
        #expect(describe("Read", ["file_path": 42]).summary == "Read", "a path that is not a string is no path")
        #expect(describe("Read", ["file_path": "", "path": "/tmp/p"]).summary == "/tmp/p", "an empty file_path gives way to the next field")
    }

    @Test func anyOtherToolIsNamedByTheFirstFieldItCarries() {
        let describe = { (tool: String, input: [String: Any]) in Hook.ToolSummary.describe(tool: tool, input: input, cwd: nil, home: "") }
        let mcp = describe("mcp__linear__create", ["description": "File the bug", "title": "secret"])
        #expect(mcp.summary == "mcp__linear__create")
        #expect(mcp.detail == "File the bug", "an MCP tool's own description of the call is the only input it shows")
        let command = describe("apply_patch", ["command": "\n  git status  \nmore"])
        #expect(command.summary == "git status", "the first line with something on it, trimmed")
        #expect(command.detail == "\n  git status  \nmore", "the detail is the command as it will run")
        #expect(describe("X", ["prompt": "p", "description": "d", "query": "q", "pattern": "*", "url": "u"]).summary == "u", "url outranks the rest")
        #expect(describe("X", ["prompt": "p", "description": "d", "query": "q"]).summary == "q")
        #expect(describe("X", ["prompt": "p", "description": "d"]).summary == "d")
        #expect(describe("X", ["prompt": "first\nsecond"]).summary == "first")
        #expect(describe("X", ["prompt": "p"]).detail == nil, "a well-known field names the call but is not shown as a detail")
        #expect(describe("X", ["url": "", "query": 3]).summary == "X", "empty and non-string fields are skipped")
        #expect(describe("X", ["command": "ls", "path": "/tmp"]).summary == "ls", "a command outranks a path")
    }

    @Test func aPathIsShortenedOnlyAtAFolderBoundary() {
        let short = { (path: String, cwd: String?) in Hook.ToolSummary.shortened(path, cwd: cwd, home: "/Users/me/") }
        #expect(short("/Users/me/proj/a.swift", "/Users/me/proj/") == "a.swift", "a cwd with its trailing slash is the same folder")
        #expect(short("/Users/me/proj/", "/Users/me/proj/") == ".", "the folder itself is the project")
        #expect(short("/Users/me/project2/a.swift", "/Users/me/proj") == "~/project2/a.swift", "a sibling that shares a prefix is not under the project")
        #expect(short("/Users/me", nil) == "/Users/me", "the home folder itself is not under it")
        #expect(short("/Users/meyer/a", nil) == "/Users/meyer/a")
    }

    @Test func theDetailIsCutOnlyPastTheLimit() {
        let exact = String(repeating: "x", count: Hook.detailLimit)
        #expect(Hook.ToolSummary.bounded(exact) == exact)
        let over = exact + "y"
        let cut = exact + "…"
        #expect(Hook.ToolSummary.bounded(over) == cut)
        #expect(Hook.ToolSummary.bounded("") == "")
    }

    @Test func aRequestOnTheWireCarriesOnlyWhatItHas() throws {
        let bare = Hook.Request(id: "r", kind: .permission(tool: "Read", summary: "a", detail: nil, suggestions: []))
        let info = Hook.userInfo(request: bare)
        #expect(Set(info.keys) == ["awaitsDecision", "requestID", "toolName", "toolSummary"], "no detail and no suggestions write no key")
        #expect(Hook.request(userInfo: info) == bare)
        let question = Hook.Request(id: "q", kind: .question([PendingRequest.Question(text: "Which?", header: "H", options: [PendingRequest.Option(label: "A")])]))
        let questionInfo = Hook.userInfo(request: question)
        let options = try #require((questionInfo["questions"] as? [[String: Any]])?.first?["options"] as? [[String: Any]])
        #expect(options.first?["description"] == nil, "an option without a description writes no key")
        #expect(Hook.request(userInfo: questionInfo) == question)
    }

    @Test func aLineThatDoesNotSayItAwaitsADecisionIsNone() {
        let permission: [String: Any] = ["requestID": "r", "toolName": "Bash", "toolSummary": "ls"]
        #expect(Hook.request(userInfo: nil) == nil)
        #expect(Hook.request(userInfo: permission) == nil)
        #expect(Hook.request(userInfo: permission.merging(["awaitsDecision": "true"]) { $1 }) == nil, "the flag is a Bool, not the word")
        #expect(Hook.request(userInfo: permission.merging(["awaitsDecision": false]) { $1 }) == nil)
        #expect(Hook.request(userInfo: ["awaitsDecision": true, "requestID": "", "toolName": "Bash", "toolSummary": "ls"]) == nil, "an empty id could never be answered")
        #expect(Hook.request(userInfo: ["awaitsDecision": true, "toolName": "Bash", "toolSummary": "ls"]) == nil)
        #expect(Hook.request(userInfo: ["awaitsDecision": true, "requestID": "r", "toolName": "Bash"]) == nil, "a tool without its summary is not a permission, and nothing else is there")
        let odd = Hook.request(userInfo: ["awaitsDecision": true, "requestID": "r", "toolName": "Bash", "toolSummary": "ls", "toolDetail": 5, "suggestions": "npm:*"])
        #expect(odd == Hook.Request(id: "r", kind: .permission(tool: "Bash", summary: "ls", detail: nil, suggestions: [])), "a detail or suggestions of the wrong type are read as none")
        #expect(Hook.request(userInfo: ["awaitsDecision": true, "requestID": "r", "questions": [["question": "q", "options": []]]]) == nil)
    }

    @Test func aTerminalOnTheWireKeepsOnlyWhatItCanUse() {
        let full = TerminalRef(program: "kitty", bundleID: "net.kovidgoyal.kitty", tty: "/dev/ttys004", sessionID: "7",
                               focusURL: "warp://session/0123456789abcdef0123456789abcdef", tmux: "/tmp/tmux-501/default,1,0", tmuxPane: "%3",
                               kittySocket: "unix:/tmp/kitty", ghostty: true, workspace: "/Users/me/proj")
        #expect(Hook.terminal(userInfo: Hook.userInfo(terminal: full)) == full, "every field round-trips")
        #expect(Hook.userInfo(terminal: TerminalRef()).isEmpty)
        #expect(Hook.terminal(userInfo: nil) == nil)
        #expect(Hook.terminal(userInfo: ["terminal_program": "", "terminal_tty": "", "terminal_ghostty": "0"]) == nil,
                "empty strings and a ghostty flag that is not \"1\" are nothing, so a hook that read nothing leaves the session's terminal alone")
        #expect(Hook.terminal(userInfo: ["terminal_ghostty": "true"]) == nil)
        #expect(Hook.terminal(userInfo: ["terminal_tty": 3, "terminal_program": "iTerm.app"]) == TerminalRef(program: "iTerm.app"))
    }

    @Test func aReplyIsReadStrictly() throws {
        let custom = try #require(Hook.Answer.line(for: .deny(message: "Not on main")))
        #expect(Hook.Answer.decision(from: custom) == .deny(message: "Not on main"))
        #expect(Hook.Answer.decision(from: Data(#"{"decision":{"behavior":"deny"}}"#.utf8)) == .deny(message: nil), "a deny with no message is still a deny")
        #expect(Hook.Answer.decision(from: Data(#"{"decision":{"answers":{},"behavior":"allow"}}"#.utf8)) == .allow, "no answers is not an answer")
        #expect(Hook.Answer.decision(from: Data(#"{"decision":{"answers":{"q":1},"behavior":"deny"}}"#.utf8)) == .deny(message: nil),
                "answers that are not strings are not answers")
        #expect(Hook.Answer.decision(from: Data(#"{"decision":{"answers":{"q":"a"},"behavior":"deny"}}"#.utf8)) == .answers(["q": "a"]), "answers outrank a behaviour")
        #expect(Hook.Answer.decision(from: Data(#"{"decision":"allow"}"#.utf8)) == nil)
        #expect(Hook.Answer.decision(from: Data(#"{"behavior":"allow"}"#.utf8)) == nil, "the body sits under decision or it is not one")
        #expect(Hook.Answer.decision(from: Data(#"[{"decision":{"behavior":"allow"}}]"#.utf8)) == nil)
        #expect(Hook.Answer.decision(from: Data(#"{"decision":{"behavior":"ALLOW"}}"#.utf8)) == nil)
    }

    @Test func thePrintedDecisionIsOneLineInTheEventsOwnShape() throws {
        let allow = try #require(Hook.Answer.line(for: .allow))
        let deny = Data(#"{"decision":{"behavior":"deny"}}"#.utf8)
        let custom = try #require(Hook.Answer.line(for: .deny(message: "Use ./scripts/test.sh")))
        let answers = try #require(Hook.Answer.line(for: .answers(["q": "a"])))
        let permission = Data(#"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#.utf8)
        #expect(Hook.Answer.output(event: "PermissionRequest", reply: deny, payload: permission)
                == #"{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"Denied from Notchmeter"},"hookEventName":"PermissionRequest"}}"#,
                "a deny that says nothing is given the app's own words")
        #expect(Hook.Answer.output(event: "PermissionRequest", reply: custom, payload: permission)
                == #"{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"Use ./scripts/test.sh"},"hookEventName":"PermissionRequest"}}"#,
                "the message is the user's, slashes and all")
        #expect(Hook.Answer.output(event: "PermissionRequest", reply: allow, payload: Data("broken".utf8)) != nil,
                "a permission's answer needs nothing from the payload, so a payload it cannot read does not stop it")
        for event in ["permissionRequest", "Notification", "Stop", "SomethingNew", ""] {
            #expect(Hook.Answer.output(event: event, reply: allow, payload: permission) == nil, "\(event) is not a deciding event")
        }
        #expect(Hook.Answer.output(event: "PreToolUse", reply: deny, payload: permission) == nil, "a question is answered, not denied")
        #expect(Hook.Answer.output(event: "PreToolUse", reply: answers, payload: Data(#"{"tool_name":"AskUserQuestion"}"#.utf8)) == nil,
                "without the input to echo back there is nothing to hand the tool")
        #expect(Hook.Answer.output(event: "PreToolUse", reply: answers, payload: Data(#"{"tool_input":"q"}"#.utf8)) == nil)
        #expect(Hook.Answer.output(event: "PermissionRequest", reply: Data("{}".utf8), payload: permission) == nil)
    }

    @Test func aPayloadThatIsNotAnObjectIsNoMessage() {
        #expect(parse("[]") == nil)
        #expect(parse("null") == nil)
        #expect(parse(#""Stop""#) == nil)
        #expect(parse(#"{"hook_event_name":7,"session_id":"s"}"#) == nil, "a name that is not a string is no name")
        #expect(parse(#"{"hook_event_name":7,"session_id":"s"}"#, event: "Stop")?.event == "Stop", "and the argument fills it as it fills a missing one")
    }
}

/// Each vendor's parser at its edges: the event-name table read as a table, the fields that decide the session and
/// the wait read when they are empty or the wrong type, and the deciding fields of Claude Code's grammar arriving on
/// a vendor that documents no decision.
@Suite struct VendorHookEdges {
    func parse(_ json: String, tool: ToolID?, event: String? = nil, environment: [String: String] = [:]) -> Hook.Message? {
        Hook.message(from: Data(json.utf8), tool: tool, event: event, environment: environment,
                     branch: { $0 == "/Users/x/proj" ? "main" : nil }, requestID: "r1")
    }

    @Test func everyVendorsTableMapsOntoClaudesGrammarAndPassesTheRestThrough() {
        let claude: Set<String> = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Notification", "Stop", "StopFailure",
                                   "SubagentStart", "SubagentStop", "SessionEnd"]
        for (name, canonical) in Hook.Codex.events { #expect(claude.contains(canonical), "Codex \(name) → \(canonical)") }
        for (name, canonical) in Hook.Copilot.events { #expect(claude.contains(canonical), "Copilot \(name) → \(canonical)") }
        for (name, canonical) in Hook.Cursor.events { #expect(claude.contains(canonical), "Cursor \(name) → \(canonical)") }
        for (name, canonical) in Hook.Gemini.events { #expect(claude.contains(canonical), "Gemini \(name) → \(canonical)") }
        for name in ["PreToolUse", "somethingNew", ""] {
            #expect(Hook.Codex.canonicalEvent(name) == name)
            #expect(Hook.Copilot.canonicalEvent(name) == name)
            #expect(Hook.Cursor.canonicalEvent(name, status: "completed") == name)
            #expect(Hook.Gemini.canonicalEvent(name) == name)
        }
        #expect(Hook.Codex.canonicalEvent("Interrupt") == "StopFailure")
        #expect(Hook.Codex.canonicalEvent("interrupt") == "interrupt", "names are matched exactly; a case Codex does not send is not guessed at")
        #expect(Hook.Gemini.canonicalEvent("beforeAgent") == "beforeAgent")
    }

    @Test func cursorsStopIsAFinishOnlyWhenItSaysCompleted() throws {
        #expect(Hook.Cursor.canonicalEvent("stop", status: "completed") == "Stop")
        #expect(Hook.Cursor.canonicalEvent("Stop", status: "completed") == "Stop")
        #expect(Hook.Cursor.canonicalEvent("Stop", status: nil) == "StopFailure")
        #expect(Hook.Cursor.canonicalEvent("stop", status: "Completed") == "StopFailure", "the status is matched exactly")
        #expect(Hook.Cursor.canonicalEvent("STOP", status: "completed") == "STOP")
        let numeric = try #require(parse(#"{"hook_event_name":"stop","conversation_id":"c","status":1}"#, tool: .cursor))
        #expect(numeric.event == "StopFailure")
        #expect(numeric.failure == nil, "a status that is not a string names no failure")
        let replay = try #require(parse(#"{"hook_event_name":"Stop","conversation_id":"c","status":"aborted"}"#, tool: .cursor))
        #expect(replay.event == "StopFailure")
        #expect(replay.failure == "aborted")
        let other = try #require(parse(#"{"hook_event_name":"afterAgentResponse","conversation_id":"c","status":"error"}"#, tool: .cursor))
        #expect(other.failure == nil, "only a stop carries its status as a failure")
    }

    @Test func cursorsSessionAndRootFallBackInOrder() throws {
        let env = ["CURSOR_PROJECT_DIR": "/Users/x/env"]
        #expect(Hook.Cursor.root(of: ["workspace_roots": ["/Users/x/proj", "/Users/x/other"], "cwd": "/Users/x/cwd"], environment: env) == "/Users/x/proj",
                "the first workspace root outranks cwd and the environment")
        #expect(Hook.Cursor.root(of: ["workspace_roots": ["", "/Users/x/second"]], environment: env) == "/Users/x/second")
        #expect(Hook.Cursor.root(of: ["workspace_roots": "/Users/x/proj", "cwd": "/Users/x/cwd"], environment: env) == "/Users/x/cwd",
                "roots that are not an array of strings are passed over")
        #expect(Hook.Cursor.root(of: ["workspace_roots": [1, 2]], environment: env) == "/Users/x/env")
        #expect(Hook.Cursor.root(of: [:], environment: [:]) == nil)

        let parentEmpty = try #require(parse(#"{"hook_event_name":"subagentStart","parent_conversation_id":"","conversation_id":"c","subagent_id":""}"#, tool: .cursor))
        #expect(parentEmpty.sessionID == "c", "an empty parent id gives way to the conversation")
        #expect(parentEmpty.agentID == nil, "an empty subagent id is no id")
        let sessionOnly = try #require(parse(#"{"hook_event_name":"sessionStart","session_id":"s"}"#, tool: .cursor))
        #expect(sessionOnly.sessionID == "s")
        let none = try #require(parse(#"{"hook_event_name":"sessionStart","conversation_id":""}"#, tool: .cursor))
        #expect(none.sessionID == nil)
    }

    @Test func cursorNeverTitlesAnythingButAPromptAndNeverDecides() throws {
        let stop = try #require(parse(#"{"hook_event_name":"stop","conversation_id":"c","status":"completed","prompt":"not a title"}"#, tool: .cursor))
        #expect(stop.title == nil)
        let blank = try #require(parse(#"{"hook_event_name":"beforeSubmitPrompt","conversation_id":"c","prompt":"   "}"#, tool: .cursor))
        #expect(blank.title == nil)
        let claudeShaped = try #require(parse(#"{"hook_event_name":"PermissionRequest","conversation_id":"c","tool_name":"Bash","tool_input":{"command":"ls"}}"#, tool: .cursor))
        #expect(claudeShaped.request == nil, "Cursor documents no decision, so the command never holds its socket")
        #expect(!claudeShaped.needsInput)
        #expect(claudeShaped.event == "PermissionRequest")
    }

    @Test func codexReadsItsFieldsOnlyWhenTheyAreStringsWithSomethingInThem() throws {
        let odd = try #require(parse(#"{"hook_event_name":"SessionStart","session_id":7,"cwd":["/Users/x/proj"],"permission_mode":"","agent_id":false}"#, tool: .codex))
        #expect(odd == Hook.Message(event: "SessionStart", needsInput: false, tool: .codex))
        let emptyAgent = try #require(parse(#"{"hook_event_name":"UserPromptSubmit","session_id":"s","agent_id":"","prompt":"mine"}"#, tool: .codex))
        #expect(emptyAgent.event == "UserPromptSubmit", "an empty agent id is no subagent, so the prompt is the user's")
        #expect(emptyAgent.title == "mine")
        let subagent = try #require(parse(#"{"hook_event_name":"UserPromptSubmit","session_id":"s","agent_id":"a1","prompt":"theirs"}"#, tool: .codex))
        #expect(subagent.event == Hook.Codex.subagentPromptEvent)
        #expect(!subagent.clearsWaiting, "a subagent's prompt does not answer the parent's wait")
        let interrupt = try #require(parse(#"{"hook_event_name":"Interrupt","session_id":"s","prompt":"x"}"#, tool: .codex))
        #expect(interrupt.title == nil)
        #expect(!interrupt.hitRateLimit)
    }

    @Test func codexWaitsOnAPermissionItCannotDecide() throws {
        let unnamed = try #require(parse(#"{"hook_event_name":"PermissionRequest","session_id":"s","tool_input":{"command":"ls"}}"#, tool: .codex))
        #expect(unnamed.needsInput, "the approval is on screen whether or not the payload names the tool")
        #expect(unnamed.request == nil, "but with no tool there is nothing the notch can show or answer")
        let named = try #require(parse(#"{"hook_event_name":"PermissionRequest","session_id":"s","tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch"}}"#, tool: .codex))
        #expect(named.request?.id == "r1")
        #expect(named.request?.kind == .permission(tool: "apply_patch", summary: "*** Begin Patch", detail: "*** Begin Patch", suggestions: []))
        let question = try #require(parse(#"{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"q","options":[{"label":"a"}]}]}}"#, tool: .codex))
        #expect(question.request == nil, "Codex documents no question tool; only its PermissionRequest is asked")
        #expect(!question.needsInput)
    }

    @Test func copilotReadsTheWaitOnlyOnANotificationAndTheDecisionOnlyOnPascalCase() throws {
        let stopWithType = try #require(parse(#"{"sessionId":"s","notification_type":"permission_prompt"}"#, tool: .copilot, event: "agentStop"))
        #expect(!stopWithType.needsInput, "a waiting type on any event but the notification is not a wait")
        #expect(stopWithType.notificationType == nil)
        let emptyType = try #require(parse(#"{"sessionId":"s","notification_type":""}"#, tool: .copilot, event: "notification"))
        #expect(!emptyType.needsInput)
        let numericType = try #require(parse(#"{"sessionId":"s","notification_type":1}"#, tool: .copilot, event: "notification"))
        #expect(!numericType.needsInput)

        let camel = try #require(parse(#"{"sessionId":"s","toolName":"bash","toolInput":{"command":"git push"}}"#, tool: .copilot, event: "PermissionRequest"))
        #expect(camel.needsInput, "the PascalCase event is the one registered for a decision")
        #expect(camel.request?.kind == .permission(tool: "bash", summary: "git push", detail: "git push", suggestions: []))
        let lower = try #require(parse(#"{"sessionId":"s","toolName":"bash","toolInput":{"command":"git push"}}"#, tool: .copilot, event: "permissionRequest"))
        #expect(lower.request == nil, "the camelCase permissionRequest fires before any rule is applied, so it is never held")
        let nameless = try #require(parse(#"{"sessionId":"s","toolInput":{"command":"ls"}}"#, tool: .copilot, event: "PermissionRequest"))
        #expect(nameless.request == nil)
        #expect(!nameless.needsInput, "unlike Codex's, Copilot's PermissionRequest is a wait only when it can be decided")
    }

    @Test func copilotsSessionIdOutranksTheSnakeSpellingAndOnlyAPromptTitles() throws {
        let both = try #require(parse(#"{"sessionId":"camel","session_id":"snake"}"#, tool: .copilot, event: "sessionStart"))
        #expect(both.sessionID == "camel")
        let emptyCamel = try #require(parse(#"{"sessionId":"","session_id":"snake"}"#, tool: .copilot, event: "sessionStart"))
        #expect(emptyCamel.sessionID == "snake")
        let stop = try #require(parse(#"{"sessionId":"s","prompt":"not a title"}"#, tool: .copilot, event: "agentStop"))
        #expect(stop.title == nil)
        let pascal = try #require(parse(#"{"hook_event_name":"UserPromptSubmit","session_id":"s","prompt":"pascal task"}"#, tool: .copilot))
        #expect(pascal.title == "pascal task")
        let numeric = try #require(parse(#"{"sessionId":"s","prompt":5}"#, tool: .copilot, event: "userPromptSubmitted"))
        #expect(numeric.title == nil)
        #expect(Hook.Copilot.recognises(object: ["sessionId": ""]), "the key is Copilot's mark whatever it holds")
        #expect(!Hook.Copilot.recognises(object: ["session_id": "s"]))
        #expect(Hook.Copilot.recognises(event: "errorOccurred", object: [:]))
        #expect(!Hook.Copilot.recognises(event: "Stop", object: [:]))
    }

    @Test func geminiWaitsOnlyOnItsNotificationAndNeverDecides() throws {
        let beforeTool = try #require(parse(#"{"hook_event_name":"BeforeTool","session_id":"s","notification_type":"ToolPermission","tool_name":"run_shell_command"}"#, tool: .antigravity))
        #expect(!beforeTool.needsInput, "ToolPermission is a wait only on the Notification event")
        #expect(beforeTool.notificationType == nil)
        let claudeShaped = try #require(parse(#"{"hook_event_name":"PermissionRequest","session_id":"s","tool_name":"Bash","tool_input":{"command":"ls"}}"#, tool: .antigravity))
        #expect(claudeShaped.request == nil, "Gemini's alert is observability only; nothing a hook prints can grant it")
        #expect(!claudeShaped.needsInput)
        let numericType = try #require(parse(#"{"hook_event_name":"Notification","session_id":"s","notification_type":true}"#, tool: .antigravity))
        #expect(!numericType.needsInput)
        let stop = try #require(parse(#"{"hook_event_name":"AfterAgent","session_id":"s","prompt":"not a title"}"#, tool: .antigravity))
        #expect(stop.title == nil, "AfterAgent carries the prompt too, but only the prompt's own event titles the session")
        #expect(!Hook.Gemini.recognises(event: "Notification", object: ["notification_type": "permission_prompt"], environment: [:]))
        #expect(!Hook.Gemini.recognises(event: "BeforeTool2", object: [:], environment: [:]))
    }

    /// An empty `cwd` is no folder: Cursor's own project directory is used, as an empty workspace root already was.
    @Test func anEmptyCursorCwdFallsBackToTheProjectDirectory() {
        #expect(Hook.Cursor.root(of: ["cwd": ""], environment: ["CURSOR_PROJECT_DIR": "/Users/x/proj"]) == "/Users/x/proj")
        #expect(Hook.Cursor.root(of: ["cwd": ""], environment: [:]) == nil)
    }
}
