import Foundation
import Testing
import UserNotifications
@testable import Notchmeter

/// Claude Code's 0.11 hook events, from the payload to the row: what the command keeps of each (and never forwards),
/// what the installer writes for them (and the three it deliberately does not), what the tracker makes of them, and
/// what the store, the notch's news, the notices and the Sessions card say about it.
@Suite struct HookEventParsing {
    init() { Localization.use(language: "en") }

    func parse(_ json: String) -> Hook.Message? {
        Hook.message(from: Data(json.utf8), tool: nil, event: nil, environment: [:], branch: { _ in nil }, requestID: "r1")
    }

    /// The line the command would write, as text, so a test can say what never appears in it.
    func line(_ message: Hook.Message) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: message.userInfo, options: [.sortedKeys]), as: UTF8.self)
    }

    @Test func aCompactionKeepsItsTriggerAndNeverItsSummaryOrInstructions() throws {
        let pre = try #require(parse(#"{"hook_event_name":"PreCompact","session_id":"s","cwd":"/Users/me/app","trigger":"manual","custom_instructions":"keep the secret plan"}"#))
        #expect(pre.compaction == .manual)
        #expect(!pre.needsInput)
        #expect(try !line(pre).contains("secret"))
        let post = try #require(parse(#"{"hook_event_name":"PostCompact","session_id":"s","trigger":"auto","compact_summary":"The user asked about the secret plan"}"#))
        #expect(post.compaction == .auto)
        #expect(try !line(post).contains("secret"), "the summary is the conversation and never leaves the command")
        #expect(Hook.Message(userInfo: post.userInfo) == post)
        #expect(parse(#"{"hook_event_name":"PreCompact","session_id":"s","trigger":"sometimes"}"#)?.compaction == nil, "an undocumented trigger is left out")
    }

    @Test func aModelSwitchKeepsTheModelsAndTheSourceAndNothingOfTheCost() throws {
        let json = #"{"hook_event_name":"PostModelSwitch","session_id":"s","from_model":"claude-opus-5","to_model":"claude-sonnet-5","requested_model":null,"source":"auto","context_tokens":182340,"estimated_cache_write_usd":1.1396,"pricing":"catalog"}"#
        let message = try #require(parse(json))
        #expect(message.modelSwitch == ModelSwitch(from: "claude-opus-5", to: "claude-sonnet-5", source: .auto))
        #expect(message.modelSwitch?.isFallback == true)
        let text = try line(message)
        #expect(!text.contains("182340") && !text.contains("1.1396") && !text.contains("catalog"))
        #expect(Hook.Message(userInfo: message.userInfo) == message)
        #expect(parse(#"{"hook_event_name":"PostModelSwitch","session_id":"s","to_model":"not a model; rm -rf"}"#)?.modelSwitch == nil,
                "a field that is not shaped like a model id carries nothing")
        let odd = try #require(parse(#"{"hook_event_name":"PostModelSwitch","session_id":"s","to_model":"claude-opus-5","source":"magic"}"#))
        #expect(odd.modelSwitch?.source == nil)
    }

    @Test func aModelIDReadsAsTheFamilyAndItsVersion() {
        #expect(Hook.modelDisplayName("claude-opus-4-6") == "Opus 4.6")
        #expect(Hook.modelDisplayName("claude-opus-5") == "Opus 5")
        #expect(Hook.modelDisplayName("claude-opus-5[1m]") == "Opus 5")
        #expect(Hook.modelDisplayName("claude-3-5-sonnet-20241022") == "Sonnet 3.5")
        #expect(Hook.modelDisplayName("claude-haiku-4-5-20251001") == "Haiku 4.5")
        #expect(Hook.modelDisplayName("us.anthropic.claude-opus-4-6-v1:0") == "Opus 4.6")
        #expect(Hook.modelDisplayName("claude-sonnet-4-5@20250929") == "Sonnet 4.5")
        #expect(Hook.modelDisplayName("my-gateway-model") == "my-gateway-model", "a gateway's own name is the only name there is")
    }

    @Test func anMCPRequestTheNotchCannotAnswerIsAPlainWaitNamingItsServer() throws {
        let text = #"{"hook_event_name":"Elicitation","session_id":"s","mcp_server_name":"my-mcp-server","message":"Please provide your credentials","mode":"form","requested_schema":{"type":"object","properties":{"username":{"type":"string","title":"Username"}}}}"#
        let message = try #require(parse(text))
        #expect(message.needsInput)
        #expect(message.request == nil, "a text field is the terminal's to fill: nothing typed ever crosses the socket")
        #expect(message.mcpServer == "my-mcp-server")
        #expect(try !line(message).contains("credentials"), "the message of a request the notch will not show stays in the command")
        let url = #"{"hook_event_name":"Elicitation","session_id":"s","mcp_server_name":"auth","message":"Please authenticate","mode":"url","url":"https://auth.example.com/login?token=abc"}"#
        let signIn = try #require(parse(url))
        #expect(signIn.request == nil, "a sign-in in the browser goes to the terminal")
        #expect(try !line(signIn).contains("token"))
    }

    @Test func anMCPFormOfChoicesIsARequestInTheFormsOwnOrder() throws {
        let json = #"""
        {"hook_event_name":"Elicitation","session_id":"s","mcp_server_name":"deploybot","message":"Where should\nthe build go?","mode":"form",
         "requested_schema":{"type":"object","required":["environment"],"properties":{
           "notify":{"type":"boolean","title":"Tell the channel"},
           "environment":{"type":"string","title":"Environment","enum":["staging","production"],"enumNames":["Staging","Production"]}}}}
        """#
        let message = try #require(parse(json))
        guard case .elicitation(let form)? = message.request?.kind else {
            Issue.record("a form of choices is answered from the notch")
            return
        }
        #expect(form.server == "deploybot")
        #expect(form.message == "Where should the build go?")
        #expect(form.fields.map(\.key) == ["environment", "notify"], "what the server requires first, then the rest by name")
        #expect(form.fields.first?.required == true)
        #expect(form.fields.first?.kind == .choice([.init(value: "staging", label: "Staging"), .init(value: "production", label: "Production")]))
        #expect(form.fields.last?.kind == .toggle)
        #expect(message.waitKind == .question, "an MCP server's request plays the Question sound")
        let back = try #require(Hook.Message(userInfo: message.userInfo))
        #expect(back.request == message.request, "the form crosses the socket whole")
        #expect(Hook.looksDeciding(Data(json.utf8)))
        #expect(!Hook.looksDeciding(Data(#"{"hook_event_name":"ElicitationResult"}"#.utf8)))
    }

    @Test func anMCPAnswerIsNeverRead() throws {
        let json = #"{"hook_event_name":"ElicitationResult","session_id":"s","mcp_server_name":"my-mcp-server","action":"accept","content":{"username":"alice"},"mode":"form"}"#
        let message = try #require(parse(json))
        #expect(message.clearsWaiting)
        #expect(message.mcpServer == "my-mcp-server")
        #expect(try !line(message).contains("alice"))
    }

    @Test func anIdleTeammateIsNamedAndTheDeprecatedTeamIsNot() throws {
        let message = try #require(parse(#"{"hook_event_name":"TeammateIdle","session_id":"s","teammate_name":"researcher","team_name":"session-a1b2c3d4"}"#))
        #expect(message.teammate == Teammate(key: "researcher", name: "researcher"))
        #expect(try !line(message).contains("session-a1b2c3d4"))
        #expect(Hook.Message(userInfo: message.userInfo)?.teammate == message.teammate)
    }

    @Test func aFailedToolCallKeepsTheToolAndNeverTheError() throws {
        let json = #"{"hook_event_name":"PostToolUseFailure","session_id":"s","tool_name":"Bash","tool_input":{"command":"cat ~/.secret"},"tool_use_id":"toolu_1","error":"Exit code 1\nno such file: ~/.secret","is_interrupt":false,"duration_ms":4187}"#
        let message = try #require(parse(json))
        #expect(message.toolFailure == ToolFailure(tool: "Bash", interrupt: false))
        #expect(try !line(message).contains("secret"))
        let abort = try #require(parse(#"{"hook_event_name":"PostToolUseFailure","session_id":"s","tool_name":"Bash","is_interrupt":true}"#))
        #expect(abort.toolFailure?.interrupt == true)
        #expect(Hook.Message(userInfo: abort.userInfo)?.toolFailure == abort.toolFailure)
        #expect(parse(#"{"hook_event_name":"PostToolUseFailure","session_id":"s","tool_name":"Bash tool\nwith lines"}"#)?.toolFailure == nil)
    }

    @Test func aDenialKeepsTheToolAndTheKindAndNeverTheReason() throws {
        let json = #"{"hook_event_name":"PermissionDenied","session_id":"s","permission_mode":"auto","tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/build"},"tool_use_id":"toolu_1","reason":"[Irreversible Local Destruction]"}"#
        let message = try #require(parse(json))
        #expect(message.denial == Denial(tool: "Bash", kind: .rule))
        let text = try line(message)
        #expect(!text.contains("Irreversible") && !text.contains("rm -rf"))
        #expect(Hook.Message(userInfo: message.userInfo)?.denial == message.denial)
        #expect(Denial.Kind(reason: "Auto mode could not evaluate this action and is blocking it for safety") == .noVerdict)
        #expect(Denial.Kind(reason: "Classifier unavailable") == .unavailable)
        #expect(Denial.Kind(reason: "something new") == .other)
        #expect(Denial.Kind(reason: nil) == .other)
    }

    @Test func aBatchKeepsItsSizeAndNoneOfItsCalls() throws {
        let json = #"{"hook_event_name":"PostToolBatch","session_id":"s","cwd":"/Users/me/app","tool_calls":[{"tool_name":"Read","tool_input":{"file_path":"/secret.py"},"tool_use_id":"t1","tool_response":"1 secret"},{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"t2","tool_response":"a"}]}"#
        let message = try #require(parse(json))
        #expect(message.batchSize == 2)
        #expect(try !line(message).contains("secret"))
        #expect(Hook.Message(userInfo: message.userInfo)?.batchSize == 2)
    }

    /// A batch carries every tool's response, and can run past the 64 KB the command reads: what precedes the
    /// first bulky field is still the event, the session and the directory, and that is enough.
    @Test func aBatchCutShortIsReadUpToItsHead() throws {
        let big = String(repeating: "x", count: 70_000)
        let whole = #"{"session_id":"s","transcript_path":"/t.jsonl","cwd":"/Users/me/app","permission_mode":"default","hook_event_name":"PostToolBatch","tool_calls":[{"tool_name":"Read","tool_response":""# + big + #""}]}"#
        let cut = Data(whole.utf8).prefix(Hook.quickPayloadLimit)
        let message = try #require(Hook.message(from: cut, environment: [:], branch: { _ in nil }))
        #expect(message.event == "PostToolBatch")
        #expect(message.sessionID == "s")
        #expect(message.project == "app")
        #expect(message.batchSize == nil, "a size read from half the calls would be a guess")
        let request = Data(#"{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"Write","tool_input":{"content":""#.utf8) + Data(big.utf8)
        #expect(Hook.message(from: request, environment: [:], branch: { _ in nil }) == nil,
                "a deciding event cut short is never shown: its request would be one approved blind")
        #expect(Hook.headObject(of: Data(#"{"cwd":"/a/\"tool_calls\":/b","hook_event_name":"PostToolBatch","tool_calls":[1"#.utf8))?["cwd"] as? String
                == "/a/\"tool_calls\":/b", "a key's name inside a value is escaped, so it is never where the head is cut")
        #expect(Hook.headObject(of: Data(#"{"hook_event_name":"Stop"}"#.utf8)) == nil)
    }

    /// A move into a worktree is seen as it happens (`CwdChanged` names the new directory), and the row can say the
    /// session runs in one; the worktree's own folder name never travels.
    @Test func aChangeOfDirectoryNamesTheNewProjectAndWhetherItIsAWorktree() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("notchmeter-cwd-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let repo = dir.appendingPathComponent("repo")
        try fm.createDirectory(at: repo.appendingPathComponent(".git/worktrees/wt-secret"), withIntermediateDirectories: true)
        let worktree = dir.appendingPathComponent("wt-secret")
        try fm.createDirectory(at: worktree, withIntermediateDirectories: true)
        try Data("gitdir: \(repo.path)/.git/worktrees/wt-secret\n".utf8).write(to: worktree.appendingPathComponent(".git"))
        let moved = try #require(parse(#"{"hook_event_name":"CwdChanged","session_id":"s","cwd":"\#(worktree.path)","old_cwd":"\#(repo.path)","new_cwd":"\#(worktree.path)"}"#))
        #expect(moved.project == "repo")
        #expect(moved.worktree)
        #expect(try !line(moved).contains("wt-secret"))
        #expect(Hook.Message(userInfo: moved.userInfo)?.worktree == true)
        let home = try #require(parse(#"{"hook_event_name":"Stop","session_id":"s","cwd":"\#(repo.path)"}"#))
        #expect(!home.worktree)
        #expect(home.userInfo[Hook.worktreeKey] == nil, "a line from outside a worktree is what it always was")
    }

    /// Every event from before 0.11 writes exactly the keys it always did.
    @Test func theNewFieldsWriteNoKeyWhereTheyAreAbsent() throws {
        let stop = try #require(parse(#"{"hook_event_name":"Stop","session_id":"s","cwd":"/Users/me/y"}"#))
        #expect(Set(stop.userInfo.keys) == ["hook_event_name", "needsInput", "session_id", "project"])
    }
}

@Suite struct ElicitationAnswers {
    func form(_ schema: String, mode: String = "form") -> PendingRequest.Elicitation? {
        let json = #"{"hook_event_name":"Elicitation","mcp_server_name":"srv","message":"Go?","mode":"\#(mode)","requested_schema":\#(schema)}"#
        return Hook.elicitationForm(object: try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any])
    }

    @Test func onlyAFormAClickCanAnswerIsOne() {
        #expect(form(#"{"type":"object","properties":{}}"#)?.fields == [], "a form of no fields is a confirmation")
        #expect(form(#"{"type":"object","properties":{"n":{"type":"number"}}}"#) == nil)
        #expect(form(#"{"type":"object","properties":{"s":{"type":"string"}}}"#) == nil)
        #expect(form(#"{"type":"object","properties":{"s":{"type":"string","enum":["a","b"]}}}"#, mode: "url") == nil)
        let fiveFields = (1...5).map { #""f\#($0)":{"type":"boolean"}"# }.joined(separator: ",")
        #expect(form(#"{"type":"object","properties":{\#(fiveFields)}}"#) == nil, "past four fields the terminal shows it better")
        let ten = (1...10).map { #""v\#($0)""# }.joined(separator: ",")
        #expect(form(#"{"type":"object","properties":{"e":{"type":"string","enum":[\#(ten)]}}}"#) == nil, "past nine buttons there is no key for one")
        #expect(form(#"{"type":"object","properties":{"a":{"type":"boolean"},"b":{"type":"boolean"},"c":{"type":"boolean"},"d":{"type":"boolean"},"e":{"type":"boolean"}}}"#) == nil)
        let titled = form(#"{"type":"object","properties":{"p":{"type":"string","oneOf":[{"const":"hi","title":"High"},{"const":"lo","title":"Low"}]}}}"#)
        #expect(titled?.fields.first?.kind == .choice([.init(value: "hi", label: "High"), .init(value: "lo", label: "Low")]))
        #expect(form(#"{"type":"object","properties":{"e":{"type":"string","enum":["a","a"]}}}"#) == nil, "two buttons sending one value are a schema to leave alone")
    }

    @Test func theCommandPrintsOnlyAnAnswerTheFormOffered() throws {
        let payload = Data(#"{"hook_event_name":"Elicitation","mcp_server_name":"srv","message":"Go?","mode":"form","requested_schema":{"type":"object","required":["env"],"properties":{"env":{"type":"string","enum":["staging","production"]},"notify":{"type":"boolean"}}}}"#.utf8)
        func output(_ decision: Decision) -> [String: Any]? {
            guard let line = Hook.Answer.line(for: decision),
                  let text = Hook.Answer.output(event: "Elicitation", reply: line, payload: payload) else { return nil }
            return try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        }
        let accepted = try #require(output(.elicitation(.accept(["env": .choice("staging"), "notify": .flag(true)])))?["hookSpecificOutput"] as? [String: Any])
        #expect(accepted["hookEventName"] as? String == "Elicitation")
        #expect(accepted["action"] as? String == "accept")
        let content = try #require(accepted["content"] as? [String: Any])
        #expect(content["env"] as? String == "staging")
        #expect(content["notify"] as? Bool == true)
        let declined = try #require(output(.elicitation(.decline))?["hookSpecificOutput"] as? [String: Any])
        #expect(declined["action"] as? String == "decline")
        #expect(declined["content"] == nil)
        #expect(output(.elicitation(.accept(["env": .choice("prod-eu")]))) == nil, "a value the server did not list is not sent")
        #expect(output(.elicitation(.accept(["notify": .flag(true)]))) == nil, "a required field left empty is the dialog's to ask")
        #expect(output(.elicitation(.accept(["env": .choice("staging"), "extra": .choice("x")]))) == nil, "a field the form does not have")
        #expect(output(.elicitation(.accept(["env": .flag(true)]))) == nil, "a flag for a choice")
        #expect(output(.allow) == nil, "an answer to another kind of request prints nothing")
        // A 1 is not a yes: the reply's flag must be a JSON boolean.
        let numeric = Data(#"{"decision":{"elicitation":"accept","content":{"env":"staging","notify":1}}}"#.utf8)
        #expect(Hook.Answer.decision(from: numeric) == nil)
        #expect(Hook.Answer.output(event: "PermissionRequest", reply: Hook.Answer.line(for: .elicitation(.decline))!, payload: payload) == nil)
    }

    @Test func theWireCarriesTheFormAndTheAnswerBack() throws {
        let form = DemoFixtures.elicitationForm
        let request = Hook.Request(id: "r9", kind: .elicitation(form))
        #expect(Hook.request(userInfo: Hook.userInfo(request: request)) == request)
        let decision = Decision.elicitation(.accept(["environment": .choice("preview"), "notify": .flag(false)]))
        #expect(Hook.Answer.decision(from: try #require(Hook.Answer.line(for: decision))) == decision)
        #expect(decision.behavior == "accept")
        #expect(Decision.elicitation(.decline).behavior == "decline")
        #expect(request.kind.name == "elicitation")
    }

    @Test func theCardNumbersEveryButtonAndSendsOnlyAFullForm() {
        let form = DemoFixtures.elicitationForm
        let choices = PromptCard.elicitationChoices(form)
        #expect(choices.map { $0.map(\.key) } == [[1, 2, 3], [4, 5]])
        #expect(choices[1].map(\.label) == ["Yes", "No"])
        #expect(PromptCard.elicitationAnswer(form, filled: [:]) == nil, "the environment is required")
        #expect(PromptCard.elicitationAnswer(form, filled: ["environment": .choice("staging"), "stray": .flag(true)])
                == .accept(["environment": .choice("staging")]), "only the form's own fields go")
        #expect(!PromptCard.answersOnClick(form))
        #expect(PromptCard.answersOnClick(PendingRequest.Elicitation(server: nil, message: "", fields: [form.fields[0]])))
    }
}

@Suite struct HookEventInstallation {
    /// The events 0.11 registers, in the order the installer writes them.
    static let added = ["PreCompact", "PostCompact", "PostModelSwitch", "Elicitation", "ElicitationResult", "TeammateIdle",
                        "PostToolUseFailure", "PermissionDenied", "PostToolBatch", "CwdChanged"]
    let executable = "/Applications/Notchmeter.app/Contents/MacOS/Notchmeter"

    @Test func theInstallerWritesTheVerifiedEventsAndNeverTheThreeThatWouldGetInTheWay() throws {
        #expect(Array(HookSettings.events.suffix(Self.added.count)) == Self.added)
        for event in ["WorktreeCreate", "WorktreeRemove", "PreModelSwitch"] {
            #expect(!HookSettings.events.contains(event), "\(event) would put the app in the way of Claude Code")
        }
        let snippet = HookSettings.snippet(executable: executable)
        let hooks = try #require((try JSONSerialization.jsonObject(with: Data(snippet.utf8)) as? [String: Any])?["hooks"] as? [String: Any])
        for event in Self.added {
            let group = try #require((hooks[event] as? [[String: Any]])?.first, "\(event)")
            let handler = try #require((group["hooks"] as? [[String: Any]])?.first, "\(event)")
            #expect(group["matcher"] == nil, "\(event): every occurrence is wanted")
            if event == "Elicitation" {
                #expect(NSDictionary(dictionary: handler) == NSDictionary(dictionary: ["type": "command", "command": "'\(executable)' --hook", "timeout": 600]),
                        "Elicitation is the one that can be answered, so it is synchronous")
            } else {
                // Async is what makes PreCompact, TeammateIdle, PostToolBatch and ElicitationResult unable to block
                // anything: an async hook's output has no effect.
                #expect(handler["async"] as? Bool == true, "\(event)")
                #expect(handler["timeout"] as? Int == 5, "\(event)")
            }
        }
        #expect(HookVendor.claude.decidingEvents == ["PermissionRequest", "PreToolUse", "Elicitation"])
    }

    @Test func anInstallFromBeforeTheNewEventsIsPartialAndRepairAddsExactlyThem() throws {
        var older = HookSettings.merge(into: ["model": "opus"], executable: executable).settings
        var hooks = try #require(older["hooks"] as? [String: Any])
        for event in Self.added { hooks[event] = nil }
        older["hooks"] = hooks
        #expect(HookSettings.status(settings: older, executable: executable) == .partial(path: executable))
        let repaired = HookSettings.repair(older, executable: executable)
        #expect(repaired.added == Self.added)
        #expect(repaired.repaired.isEmpty, "every entry already there is left byte for byte")
        #expect(HookSettings.status(settings: repaired.settings, executable: executable) == .installed(path: executable))
        let again = HookSettings.repair(repaired.settings, executable: executable)
        #expect(again.added.isEmpty && again.repaired.isEmpty)
        #expect(repaired.settings["model"] as? String == "opus")
    }

    /// An `Elicitation` entry written async (by hand, or by a build that had it as a plain event) cannot carry an
    /// answer back, so it reads as out of date and Repair brings it to the synchronous shape.
    @Test func anAsyncElicitationEntryIsBroughtToTheDecidingShape() throws {
        var settings = HookSettings.merge(into: [:], executable: executable).settings
        var hooks = try #require(settings["hooks"] as? [String: Any])
        hooks["Elicitation"] = [["hooks": [["type": "command", "command": "'\(executable)' --hook", "async": true, "timeout": 5]]]]
        settings["hooks"] = hooks
        #expect(HookSettings.status(settings: settings, executable: executable) == .partial(path: executable))
        let repaired = HookSettings.repair(settings, executable: executable)
        #expect(repaired.repaired == ["Elicitation"])
        #expect(HookSettings.status(settings: repaired.settings, executable: executable) == .installed(path: executable))
    }
}

@Suite struct HookEventTracking {
    init() { Localization.use(language: "en") }

    let t0 = DateParsing.iso8601("2026-09-24T12:00:00Z")!

    func message(_ event: String, session: String = "s", agent: String? = nil, _ configure: (inout Hook.Message) -> Void = { _ in }) -> Hook.Message {
        var message = Hook.Message(event: event, needsInput: Hook.needsInput(event: event, notificationType: nil), sessionID: session,
                                   project: "app", agentID: agent)
        configure(&message)
        return message
    }

    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    @Test func aCompactionIsMarkedAndAnAutomaticOneIsNewsWithTheFillBeforeIt() throws {
        var tracker = SessionTracker()
        tracker.apply(message("UserPromptSubmit"), now: t0)
        tracker.statusline(sessionID: "s", project: "app", contextUsed: 0.93, now: at(5))
        let begun = tracker.apply(message("PreCompact") { $0.compaction = .auto }, now: at(10))
        #expect(begun.trouble?.trouble == .compacting(context: 0.93))
        #expect(tracker.sessions["s"]?.compacting?.value == .auto)
        let done = tracker.apply(message("PostCompact") { $0.compaction = .auto }, now: at(40))
        #expect(done.trouble == nil)
        let session = try #require(tracker.sessions["s"])
        #expect(session.compacting == nil)
        #expect(session.compactions == 1)
        #expect(session.lastCompaction == Stamped(value: .auto, at: at(40)))
        #expect(session.contextUsed == nil, "the fill before the summary is no longer this session's figure")
        let manual = tracker.apply(message("PreCompact") { $0.compaction = .manual }, now: at(60))
        #expect(manual.trouble == nil, "/compact is the user's own doing")
        tracker.apply(message("Stop"), now: at(70))
        #expect(tracker.sessions["s"]?.compacting == nil, "a compaction that never reported its end did not outlive its turn")
        tracker.apply(message("PreCompact") { $0.compaction = .manual }, now: at(80))
        tracker.expire(now: at(80 + SessionTracker.waitingTimeout))
        #expect(tracker.sessions["s"]?.compacting == nil)
    }

    @Test func aSwitchSetsTheModelAndIsRecorded() {
        var tracker = SessionTracker()
        tracker.apply(message("SessionStart"), now: t0)
        tracker.apply(message("PostModelSwitch") { $0.modelSwitch = ModelSwitch(from: "claude-opus-5", to: "claude-sonnet-5", source: .auto) }, now: at(10))
        #expect(tracker.sessions["s"]?.model == "Sonnet 5")
        #expect(tracker.sessions["s"]?.fellBack == true)
        tracker.apply(message("PostModelSwitch") { $0.modelSwitch = ModelSwitch(from: "claude-sonnet-5", to: "claude-sonnet-5", source: .resume) }, now: at(20))
        #expect(tracker.sessions["s"]?.modelSwitches.count == 1, "a model restored as it was is no switch")
        for index in 0..<12 {
            tracker.apply(message("PostModelSwitch") { $0.modelSwitch = ModelSwitch(from: "claude-a-\(index)", to: "claude-b-\(index)", source: .command) },
                          now: at(30 + Double(index)))
        }
        #expect(tracker.sessions["s"]?.modelSwitches.count == SessionTracker.switchLimit)
        #expect(tracker.sessions["s"]?.fellBack == false)
        // The status line names the model in its own words, and a later switch in the hook's; the newest wins.
        tracker.statusline(sessionID: "s", project: "app", model: "Opus 5", now: at(100))
        #expect(tracker.sessions["s"]?.model == "Opus 5")
    }

    @Test func anMCPRequestIsItsOwnWaitAndItsResultEndsIt() {
        var tracker = SessionTracker()
        tracker.apply(message("UserPromptSubmit"), now: t0)
        let asked = tracker.apply(message("Elicitation") { $0.mcpServer = "linear" }, now: at(5))
        #expect(asked.startedWaiting?.id == "s")
        #expect(tracker.sessions["s"]?.waitsOnMCP == true)
        #expect(tracker.sessions["s"]?.mcpServer == "linear")
        let dialog = Hook.Message(event: "Notification", needsInput: true, sessionID: "s", notificationType: "elicitation_dialog")
        let again = tracker.apply(dialog, now: at(11))
        #expect(again.startedWaiting == nil, "the dialog's notification is the same wait, not a second one")
        #expect(tracker.sessions["s"]?.waitsOnMCP == true)
        let answered = tracker.apply(message("ElicitationResult") { $0.mcpServer = "linear" }, now: at(20))
        #expect(answered.stoppedWaiting == ["s"])
        #expect(tracker.sessions["s"]?.isWorking == true)
        #expect(tracker.sessions["s"]?.waitsOnMCP == false)
        // A permission prompt is not an MCP wait, and an MCP answer does not end a permission request standing.
        tracker.apply(Hook.Message(event: "Notification", needsInput: true, sessionID: "s", notificationType: "permission_prompt"), now: at(30))
        #expect(tracker.sessions["s"]?.waitsOnMCP == false)
        var request = message("PermissionRequest")
        request.request = Hook.Request(id: "p1", kind: .permission(tool: "Bash", summary: "ls", detail: nil, suggestions: []))
        tracker.apply(request, now: at(40))
        tracker.apply(message("ElicitationResult"), now: at(45))
        #expect(tracker.sessions["s"]?.pending?.id == "p1")
        #expect(tracker.sessions["s"]?.isWaiting == true)
    }

    @Test func anAnswerableMCPRequestIsHeldAndItsResultEndsIt() {
        var tracker = SessionTracker()
        tracker.apply(message("UserPromptSubmit"), now: t0)
        var ask = message("Elicitation") { $0.mcpServer = "deploybot" }
        ask.request = Hook.Request(id: "e1", kind: .elicitation(DemoFixtures.elicitationForm))
        let outcome = tracker.apply(ask, now: at(5))
        #expect(outcome.requested?.request.id == "e1")
        let ended = tracker.apply(message("ElicitationResult"), now: at(9))
        #expect(ended.requestsEnded == [SessionTracker.EndedRequest(sessionID: "s", requestID: "e1")])
    }

    @Test func teammatesGoIdleOneEntryEachAndLeaveWithTheNextPrompt() {
        var tracker = SessionTracker()
        tracker.apply(message("UserPromptSubmit"), now: t0)
        for (name, second) in [("researcher", 10.0), ("reviewer", 20.0), ("researcher", 30.0)] {
            tracker.apply(message("TeammateIdle") { $0.teammate = Teammate(key: name, name: name) }, now: at(second))
        }
        #expect(tracker.sessions["s"]?.idleTeammates.map(\.value.key) == ["reviewer", "researcher"], "one entry per teammate, newest last")
        tracker.clearTitles()
        #expect(tracker.sessions["s"]?.idleTeammates.allSatisfy { $0.value.name == nil } == true, "titles off keeps the count, never the names")
        #expect(tracker.sessions["s"]?.idleTeammates.count == 2)
        tracker.apply(message("UserPromptSubmit"), now: at(40))
        #expect(tracker.sessions["s"]?.idleTeammates.isEmpty == true)
        tracker.apply(message("TeammateIdle"), now: at(50))
        tracker.expire(now: at(50 + SessionTracker.idleAfter))
        #expect(tracker.sessions["s"]?.idleTeammates.isEmpty ?? true)
    }

    /// Five failed calls with none succeeding between them, across batches that each failed whole, is a session that
    /// may be stuck; the flag is news once, and a batch in which anything worked ends it.
    @Test func fiveFailuresInARowMayBeStuckAndABatchThatWorkedEndsIt() {
        var tracker = SessionTracker()
        tracker.apply(message("UserPromptSubmit"), now: t0)
        var second = 1.0
        var troubles: [SessionTrouble] = []
        func fail(_ count: Int, batchOf size: Int?) {
            for _ in 0..<count {
                let outcome = tracker.apply(message("PostToolUseFailure") { $0.toolFailure = ToolFailure(tool: "Bash", interrupt: false) }, now: at(second))
                if let trouble = outcome.trouble?.trouble { troubles.append(trouble) }
                second += 1
            }
            let outcome = tracker.apply(message(Hook.batchEvent) { $0.batchSize = size }, now: at(second))
            if let trouble = outcome.trouble?.trouble { troubles.append(trouble) }
            second += 1
        }
        fail(2, batchOf: 2)
        fail(2, batchOf: 2)
        #expect(tracker.stuck(now: at(second)).isEmpty)
        fail(1, batchOf: 1)
        #expect(tracker.stuck(now: at(second)) == ["s"])
        #expect(troubles == [.stuck(failures: 5)])
        fail(1, batchOf: 1)
        #expect(troubles.count == 1, "news once, when the run reaches the threshold")
        fail(1, batchOf: 3)
        #expect(tracker.stuck(now: at(second)).isEmpty, "a batch in which anything worked is progress")
        #expect(tracker.sessions["s"]?.failureStreak == 0)
    }

    @Test func whatCannotBeToldIsNeverCalledStuck() {
        // Without batch boundaries, "in a row" cannot be told.
        var noBatches = SessionTracker()
        noBatches.apply(message("UserPromptSubmit"), now: t0)
        for index in 0..<8 {
            noBatches.apply(message("PostToolUseFailure") { $0.toolFailure = ToolFailure(tool: "Bash", interrupt: false) }, now: at(Double(index)))
        }
        #expect(noBatches.stuck(now: at(10)).isEmpty)
        // Aborts are not tries, a batch of unknown size is progress, and the flag goes once the last failure is old.
        var tracker = SessionTracker()
        tracker.apply(message("UserPromptSubmit"), now: t0)
        tracker.apply(message(Hook.batchEvent) { $0.batchSize = 1 }, now: at(1))
        for index in 0..<6 {
            tracker.apply(message("PostToolUseFailure") { $0.toolFailure = ToolFailure(tool: "Bash", interrupt: true) }, now: at(2 + Double(index)))
        }
        #expect(tracker.sessions["s"]?.failureStreak == 0)
        for index in 0..<5 {
            tracker.apply(message("PostToolUseFailure") { $0.toolFailure = ToolFailure(tool: "Bash", interrupt: false) }, now: at(10 + Double(index)))
        }
        #expect(tracker.stuck(now: at(20)) == ["s"])
        #expect(tracker.stuck(now: at(15 + SessionTracker.stuckFor)).isEmpty, "a streak whose last failure is old says nothing now")
        tracker.apply(message(Hook.batchEvent), now: at(30))
        #expect(tracker.sessions["s"]?.failureStreak == 0, "a batch too large to read whole counts as progress")
        // A subagent's failures are its own run, and the main loop's batch does not end it.
        for index in 0..<5 {
            tracker.apply(message("PostToolUseFailure", agent: "a1") { $0.toolFailure = ToolFailure(tool: "Read", interrupt: false) }, now: at(40 + Double(index)))
        }
        tracker.apply(message(Hook.batchEvent) { $0.batchSize = 2 }, now: at(50))
        #expect(tracker.sessions["s"]?.failureStreaks["a1"] == 5)
        tracker.apply(message("Stop"), now: at(60))
        #expect(tracker.sessions["s"]?.failureStreak == 0, "a turn's failures end with it")
    }

    /// A batch resolves only once every call in it has, so a permission prompt among them has been answered: the one
    /// proof of that the hook gives besides a subagent starting.
    @Test func aBatchEndsAPromptAnsweredInTheTerminalAndNothingItCannotSpeakFor() {
        var tracker = SessionTracker()
        tracker.apply(message("UserPromptSubmit"), now: t0)
        tracker.apply(Hook.Message(event: "Notification", needsInput: true, sessionID: "s", notificationType: "permission_prompt"), now: at(5))
        #expect(tracker.sessions["s"]?.isWaiting == true)
        tracker.apply(message(Hook.batchEvent, agent: "a1") { $0.batchSize = 1 }, now: at(8))
        #expect(tracker.sessions["s"]?.isWaiting == true, "a subagent's batch says nothing about the main loop's prompt")
        let ended = tracker.apply(message(Hook.batchEvent) { $0.batchSize = 1 }, now: at(10))
        #expect(ended.stoppedWaiting == ["s"])
        #expect(tracker.sessions["s"]?.isWorking == true)
        var request = message("PermissionRequest")
        request.request = Hook.Request(id: "p1", kind: .permission(tool: "Bash", summary: "ls", detail: nil, suggestions: []))
        tracker.apply(request, now: at(20))
        tracker.apply(message(Hook.batchEvent) { $0.batchSize = 1 }, now: at(25))
        #expect(tracker.sessions["s"]?.pending?.id == "p1", "a request the notch holds is answered from the notch")
    }

    @Test func theFirstDenialOfATurnIsNewsAndTheNextPromptClearsThem() {
        var tracker = SessionTracker()
        tracker.apply(message("UserPromptSubmit"), now: t0)
        let first = tracker.apply(message("PermissionDenied") { $0.denial = Denial(tool: "Bash", kind: .rule) }, now: at(5))
        #expect(first.trouble?.trouble == .blocked(tool: "Bash"))
        let second = tracker.apply(message("PermissionDenied") { $0.denial = Denial(tool: "WebFetch", kind: .noVerdict) }, now: at(6))
        #expect(second.trouble == nil)
        #expect(tracker.sessions["s"]?.denials.map(\.value.tool) == ["Bash", "WebFetch"])
        #expect(tracker.sessions["s"]?.isWorking == true, "a denial is not a wait: the session goes on without the call")
        for index in 0..<30 {
            tracker.apply(message("PermissionDenied") { $0.denial = Denial(tool: "T\(index)", kind: .rule) }, now: at(10 + Double(index)))
        }
        #expect(tracker.sessions["s"]?.denials.count == SessionTracker.denialLimit)
        tracker.apply(message("UserPromptSubmit"), now: at(60))
        #expect(tracker.sessions["s"]?.denials.isEmpty == true)
    }

    @Test func theWorktreeFlagFollowsTheDirectory() {
        var tracker = SessionTracker()
        tracker.apply(message("CwdChanged") { $0.worktree = true }, now: t0)
        #expect(tracker.sessions["s"]?.worktree == true)
        tracker.apply(Hook.Message(event: "Notification", needsInput: false, sessionID: "s"), now: at(1))
        #expect(tracker.sessions["s"]?.worktree == true, "an event naming no directory says nothing about it")
        tracker.apply(message("CwdChanged"), now: at(2))
        #expect(tracker.sessions["s"]?.worktree == false)
    }

    @Test func aBatchThatChangesOnlyTheClockIsNoDifference() {
        var tracker = SessionTracker()
        tracker.apply(message("UserPromptSubmit"), now: t0)
        tracker.apply(message(Hook.batchEvent) { $0.batchSize = 1 }, now: at(1))
        var next = tracker
        next.apply(message(Hook.batchEvent) { $0.batchSize = 1 }, now: at(30))
        #expect(!next.differs(from: tracker, slack: Hook.batchSlack))
        var later = tracker
        later.apply(message(Hook.batchEvent) { $0.batchSize = 1 }, now: at(1 + Hook.batchSlack))
        #expect(later.differs(from: tracker, slack: Hook.batchSlack))
        var failed = tracker
        failed.apply(message("PostToolUseFailure") { $0.toolFailure = ToolFailure(tool: "Bash", interrupt: false) }, now: at(2))
        #expect(failed.differs(from: tracker, slack: Hook.batchSlack))
    }
}

@Suite struct HookEventStore {
    let t0 = DateParsing.iso8601("2026-09-24T12:00:00Z")!

    @MainActor
    func store(_ suite: String, configure: (Preferences) -> Void = { _ in }) -> (UsageStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let prefs = Preferences(defaults: defaults)
        configure(prefs)
        let store = UsageStore(prefs: prefs, providers: [], cache: ReadingCache(defaults: defaults), defaults: defaults, drainLog: nil, reportFile: nil)
        return (store, defaults)
    }

    func message(_ event: String, _ configure: (inout Hook.Message) -> Void = { _ in }) -> Hook.Message {
        var message = Hook.Message(event: event, needsInput: Hook.needsInput(event: event, notificationType: nil), sessionID: "s", project: "app")
        configure(&message)
        return message
    }

    @MainActor @Test func titlesOffKeepsATeammateCountedAndNeverNamed() {
        let suite = "NotchmeterTests.teammates"
        let (store, defaults) = store(suite) { $0.sessionTitles = false }
        defer { defaults.removePersistentDomain(forName: suite) }
        store.hookReceived(message("TeammateIdle") { $0.teammate = Teammate(key: "researcher", name: "researcher") }, now: t0)
        store.hookReceived(message("TeammateIdle") { $0.teammate = Teammate(key: "researcher", name: "researcher") }, now: t0.addingTimeInterval(5))
        store.hookReceived(message("TeammateIdle") { $0.teammate = Teammate(key: "reviewer", name: "reviewer") }, now: t0.addingTimeInterval(9))
        let idle = store.sessions.sessions["s"]?.idleTeammates ?? []
        #expect(idle.count == 2, "the same teammate twice is one entry")
        #expect(idle.allSatisfy { $0.value.name == nil && !$0.value.key.contains("research") && !$0.value.key.contains("review") })
    }

    @MainActor @Test func troubleIsANoticeOnlyWhenAskedForAndAStuckOneComesDownWhenItEnds() {
        let suite = "NotchmeterTests.trouble"
        let (store, defaults) = store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        var notices: [String] = []
        var removed: [String] = []
        store.deliverSessionEvent = { event, _ in if case .trouble(let trouble) = event { notices.append(trouble.name) } }
        store.removeNotifications = { removed.append(contentsOf: $0) }
        store.hookReceived(message("UserPromptSubmit"), now: t0)
        store.hookReceived(message("PermissionDenied") { $0.denial = Denial(tool: "Bash", kind: .rule) }, now: t0.addingTimeInterval(1))
        #expect(notices.isEmpty, "off by default, like the other session notices")
        store.prefs.notifySessionTrouble = true
        store.hookReceived(message("PreCompact") { $0.compaction = .auto }, now: t0.addingTimeInterval(2))
        store.hookReceived(message(Hook.batchEvent) { $0.batchSize = 1 }, now: t0.addingTimeInterval(3))
        for index in 0..<5 {
            store.hookReceived(message("PostToolUseFailure") { $0.toolFailure = ToolFailure(tool: "Bash", interrupt: false) }, now: t0.addingTimeInterval(4 + Double(index)))
        }
        #expect(notices == ["compacting", "stuck"])
        #expect(!removed.contains("session/s/stuck"))
        store.hookReceived(message(Hook.batchEvent) { $0.batchSize = 6 }, now: t0.addingTimeInterval(20))
        #expect(removed.contains("session/s/stuck"), "a call in the batch worked, so the run ended and its notice is withdrawn")
    }

    /// A batch boundary arrives with every model step: it changes the session's clock, which nothing prints, so it
    /// is published at most once a minute unless it changes something else; and no in-turn event reads the meter.
    @MainActor @Test func aBatchThatChangesNothingButTheClockIsNotPublished() {
        let suite = "NotchmeterTests.batches"
        let (store, defaults) = store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        var facts: [[String: Any]] = []
        store.emitHookFacts = { facts.append($0) }
        store.hookReceived(message("UserPromptSubmit"), now: t0)
        store.hookReceived(message(Hook.batchEvent) { $0.batchSize = 1 }, now: t0.addingTimeInterval(1))
        let first = store.sessions.sessions["s"]?.lastEvent
        #expect(first == t0.addingTimeInterval(1), "the first boundary says the session reports batches, which is news")
        store.hookReceived(message(Hook.batchEvent) { $0.batchSize = 1 }, now: t0.addingTimeInterval(20))
        #expect(store.sessions.sessions["s"]?.lastEvent == first, "a boundary that changes only the clock is held back")
        store.hookReceived(message(Hook.batchEvent) { $0.batchSize = 1 }, now: t0.addingTimeInterval(1 + Hook.batchSlack))
        #expect(store.sessions.sessions["s"]?.lastEvent == t0.addingTimeInterval(1 + Hook.batchSlack))
        #expect(facts.count == 4, "the oracle still hears every one")
        #expect(facts.last?["batch"] as? Int == 1)
    }

    @MainActor @Test func aCompactionRetiresTheStatusLinesFill() {
        let suite = "NotchmeterTests.compactionFill"
        let (store, defaults) = store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        store.statuslineReceived(Statusline.Message(sessionID: "s", project: "app", contextUsed: 0.9, receivedAt: now.addingTimeInterval(-30)),
                                 now: now.addingTimeInterval(-30))
        #expect(store.contextUsed == 0.9)
        store.hookReceived(message("PostCompact") { $0.compaction = .auto }, now: now.addingTimeInterval(-10))
        #expect(store.contextUsed == nil, "the arc waits for the next status line rather than show the fill before the summary")
        store.statuslineReceived(Statusline.Message(sessionID: "s", project: "app", contextUsed: 0.2, receivedAt: now), now: now)
        #expect(store.contextUsed == 0.2)
    }

    @MainActor @Test func anMCPFormIsAnsweredOnItsParkedReply() throws {
        let suite = "NotchmeterTests.elicitationDecision"
        let (store, defaults) = store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let (reply, peer) = try StoreDecisions.pair()
        defer { close(peer) }
        var ask = message("Elicitation") { $0.mcpServer = "deploybot" }
        ask.request = Hook.Request(id: "e1", kind: .elicitation(DemoFixtures.elicitationForm))
        store.hookReceived(ask, now: t0, reply: reply)
        #expect(store.sessions.pending(now: t0).map(\.request.id) == ["e1"])
        store.decide("e1", .elicitation(.accept(["environment": .choice("preview")])), now: t0.addingTimeInterval(2))
        #expect(String(decoding: StoreDecisions.read(peer), as: UTF8.self) == "{\"decision\":{\"content\":{\"environment\":\"preview\"},\"elicitation\":\"accept\"}}\n")
        #expect(store.sessions.sessions["s"]?.isWorking == true)
    }

    @Test func theOracleHearsTheShapeOfTheNewEventsAndNeverATeammatesName() throws {
        var idle = Hook.Message(event: "TeammateIdle", needsInput: false, sessionID: "s")
        idle.teammate = Teammate(key: "secret-name", name: "secret-name")
        let line = try #require(Oracle.line(event: "hook", fields: UsageStore.hookFacts(idle)))
        #expect(!line.contains("secret-name"))
        #expect(UsageStore.hookFacts(idle)["teammate"] as? Bool == true)
        var failure = Hook.Message(event: "PostToolUseFailure", needsInput: false, sessionID: "s")
        failure.toolFailure = ToolFailure(tool: "Bash", interrupt: true)
        #expect(UsageStore.hookFacts(failure)["failedTool"] as? String == "Bash")
        #expect(UsageStore.hookFacts(failure)["interrupt"] as? Bool == true)
        var change = Hook.Message(event: "PostModelSwitch", needsInput: false, sessionID: "s")
        change.modelSwitch = ModelSwitch(from: "claude-opus-5", to: "claude-sonnet-5", source: .auto)
        #expect(UsageStore.hookFacts(change)["model"] as? String == "claude-sonnet-5")
        #expect(UsageStore.hookFacts(change)["modelSource"] as? String == "auto")
        var compact = Hook.Message(event: "PreCompact", needsInput: false, sessionID: "s")
        compact.compaction = .auto
        #expect(UsageStore.hookFacts(compact)["compaction"] as? String == "auto")
        var denied = Hook.Message(event: "PermissionDenied", needsInput: false, sessionID: "s")
        denied.denial = Denial(tool: "Bash", kind: .noVerdict)
        #expect(UsageStore.hookFacts(denied)["denial"] as? String == "noVerdict")
        #expect(UsageStore.hookFacts(Hook.Message(event: "Stop", needsInput: false))["batch"] == nil)
    }
}

@Suite struct HookEventViews {
    init() { Localization.use(language: "en") }

    let t0 = DateParsing.iso8601("2026-09-24T12:00:00Z")!

    @Test func troubleIsNewsThatNeverReplacesAWait() {
        let session = AgentSession(id: "s", project: "app", state: .working(since: t0), started: t0, lastEvent: t0, turnStarted: t0)
        var outcome = SessionTracker.Outcome()
        outcome.trouble = (session, .compacting(context: 0.9))
        let news = NotchNews.from(Hook.Message(event: "PreCompact", needsInput: false, sessionID: "s"), outcome: outcome, now: t0)
        #expect(news?.reason == .compacting)
        #expect(news?.reason.isWait == false)
        let wait = NotchNews(reason: .input, sessionID: "b", tool: .claude, project: "b", at: t0)
        #expect(wait.reason.isWait)
        #expect(!NotchNews.isDue(news!, showing: wait, last: wait, now: t0))
        #expect(NotchNews.Reason(.stuck(failures: 5)) == .stuck)
        #expect(NotchNews.Reason(.blocked(tool: "Bash")) == .blocked)
        #expect(NotchNews.reason(event: "Elicitation", notificationType: nil, request: .elicitation(DemoFixtures.elicitationForm)) == .input)
        for reason in [NotchNews.Reason.input, .compacting, .stuck, .blocked] {
            #expect(!reason.text.isEmpty)
            #expect(!reason.symbolName.isEmpty)
        }
    }

    @Test func aTroubleNoticeSaysWhatHappenedAndHidesTheFillAndProjectWhileShared() {
        let session = AgentSession(id: "s", project: "app", state: .working(since: t0), started: t0, lastEvent: t0, turnStarted: t0)
        let copy = Notifier.copy(for: .trouble(.compacting(context: 0.94)), session: session)
        #expect(copy.title == "Claude Code is compacting")
        #expect(copy.body.contains("94%") && copy.body.contains("app"))
        let shared = Notifier.copy(for: .trouble(.compacting(context: 0.94)), session: session, hidingFigures: true)
        #expect(!shared.body.contains("94") && !shared.body.contains("app"))
        #expect(Notifier.copy(for: .trouble(.stuck(failures: 5)), session: session).body.contains("5 tool calls"))
        #expect(Notifier.copy(for: .trouble(.blocked(tool: "Bash")), session: session).body.contains("Bash"))
        #expect(Notifier.soundEvent(for: .trouble(.stuck(failures: 5))) == nil, "none of them needs an answer, so none of them sounds")
        #expect(Notifier.level(for: .trouble(.blocked(tool: "Bash"))) == .active)
        #expect(Notifier.shouldSuppress(event: .trouble(.stuck(failures: 5)), frontmost: "com.googlecode.iterm2", quiet: false),
                "held back while a terminal is in front, like a finished turn")
    }

    @Test func aRowSaysWhatTheNewEventsReported() throws {
        var tracker = SessionTracker()
        var start = Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "s", project: "app", branch: "main")
        start.worktree = true
        tracker.apply(start, now: t0)
        var change = Hook.Message(event: "PostModelSwitch", needsInput: false, sessionID: "s")
        change.modelSwitch = ModelSwitch(from: "claude-opus-5", to: "claude-sonnet-5", source: .auto)
        tracker.apply(change, now: t0.addingTimeInterval(1))
        var idle = Hook.Message(event: "TeammateIdle", needsInput: false, sessionID: "s")
        idle.teammate = Teammate(key: "researcher", name: "researcher")
        tracker.apply(idle, now: t0.addingTimeInterval(2))
        var compact = Hook.Message(event: "PreCompact", needsInput: false, sessionID: "s")
        compact.compaction = .auto
        tracker.apply(compact, now: t0.addingTimeInterval(3))
        var denied = Hook.Message(event: "PermissionDenied", needsInput: false, sessionID: "s")
        denied.denial = Denial(tool: "Bash", kind: .rule)
        tracker.apply(denied, now: t0.addingTimeInterval(4))
        let rows = SessionsCard.rows(tracker.all, hideTitles: false, jump: false, now: t0.addingTimeInterval(5)).rows
        let row = try #require(rows.first)
        #expect(row.compaction == .compacting(auto: true))
        #expect(row.model?.name == "Sonnet 5")
        #expect(row.model?.fellBack == true)
        #expect(row.teammates.map(\.value.name) == ["researcher"])
        #expect(row.denials.count == 1)
        #expect(row.worktree)
        let hidden = try #require(SessionsCard.rows(tracker.all, hideTitles: true, jump: false, now: t0.addingTimeInterval(5)).rows.first)
        #expect(hidden.teammates.map(\.value.name) == [nil], "a teammate's name is hidden with the titles, and still counted")
        let oracle = try #require(SessionsCard.oracleRows(SessionsCard.groups(rows, sessions: tracker.all)).first)
        #expect(oracle["compaction"] as? String == "compacting")
        #expect(oracle["model"] as? String == "Sonnet 5")
        #expect(oracle["teammatesIdle"] as? Int == 1)
        #expect(oracle["denials"] as? Int == 1)
        #expect(oracle["worktree"] as? Bool == true)
        let text = try #require(Oracle.line(event: "snapshot", fields: ["rows": [oracle]]))
        #expect(!text.contains("researcher"))
    }

    @Test func aRowNamesAnMCPWaitAndARunOfFailures() throws {
        var tracker = SessionTracker()
        tracker.apply(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "a", project: "a"), now: t0)
        var ask = Hook.Message(event: "Elicitation", needsInput: true, sessionID: "a", project: "a")
        ask.mcpServer = "linear"
        tracker.apply(ask, now: t0.addingTimeInterval(1))
        tracker.apply(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "b", project: "b"), now: t0)
        tracker.apply(Hook.Message(event: Hook.batchEvent, needsInput: false, sessionID: "b"), now: t0.addingTimeInterval(1))
        for index in 0..<5 {
            var failure = Hook.Message(event: "PostToolUseFailure", needsInput: false, sessionID: "b")
            failure.toolFailure = ToolFailure(tool: "Bash", interrupt: false)
            tracker.apply(failure, now: t0.addingTimeInterval(2 + Double(index)))
        }
        let rows = SessionsCard.rows(tracker.all, hideTitles: false, jump: false, now: t0.addingTimeInterval(10)).rows
        #expect(rows.first { $0.id == "a" }?.note == .mcpInput(server: "linear"))
        #expect(rows.first { $0.id == "a" }?.needsYou == true)
        #expect(rows.first { $0.id == "b" }?.note == .mayBeStuck(failures: 5))
        let hidden = SessionsCard.rows(tracker.all, hideTitles: true, jump: false, now: t0.addingTimeInterval(10)).rows
        #expect(hidden.first { $0.id == "a" }?.note == .mcpInput(server: nil))
        #expect(SessionsCard.sourceText(.auto) == "fell back by itself")
        #expect(SessionsCard.denialText(.noVerdict) == "could not be judged")
    }

    @Test func chipsWrapOntoAnotherLineWhenTheRowIsNarrow() {
        let sizes = [CGSize(width: 60, height: 20), CGSize(width: 80, height: 20), CGSize(width: 50, height: 16)]
        let wide = ChipFlow.frames(sizes: sizes, width: 400, spacing: 6, lineSpacing: 4)
        #expect(wide.map(\.minY) == [0, 0, 2], "one line, each chip centred on it")
        #expect(wide.map(\.minX) == [0, 66, 152])
        let narrow = ChipFlow.frames(sizes: sizes, width: 150, spacing: 6, lineSpacing: 4)
        #expect(narrow.map(\.minX) == [0, 66, 0])
        #expect(narrow[2].minY == 24, "the third chip starts a second line")
        #expect(ChipFlow.frames(sizes: [CGSize(width: 300, height: 20)], width: 100, spacing: 6, lineSpacing: 4).first?.minX == 0,
                "a chip wider than the row still takes a line of its own")
    }
}
