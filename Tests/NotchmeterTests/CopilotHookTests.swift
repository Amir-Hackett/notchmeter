import Foundation
import Testing
@testable import Notchmeter

/// GitHub Copilot CLI's hook read onto the same Message Claude Code's fills: how the event reaches the parser when
/// the payload does not say (the `--event` flag), how both spellings of each name land on the tracker's vocabulary,
/// which two notification types are the wait and why nothing else is. Every test parses the JSON the reference
/// documents at docs.github.com/en/copilot/reference/hooks-reference rather than a Message built by hand, because
/// the parser is the whole feature: above it nothing knows Copilot exists.
@Suite struct CopilotHookMessages {
    /// The branch closure stands in for `.git/HEAD`: it answers only for the folder the payload names, so a branch
    /// on the message proves the parser asked about the right cwd.
    func parse(_ json: String, tool: ToolID? = nil, event: String? = nil, environment: [String: String] = [:]) -> Hook.Message? {
        Hook.message(from: Data(json.utf8), tool: tool, event: event, environment: environment, branch: { $0 == "/Users/x/proj" ? "main" : nil })
    }

    /// A documented camelCase payload: `sessionId`, `timestamp` in milliseconds, `cwd` and the per-event extras, and
    /// no event name anywhere in it.
    let stopPayload = #"{"sessionId":"s","timestamp":1756944000000,"cwd":"/Users/x/proj","transcriptPath":"/Users/x/.copilot/t.jsonl","stopReason":"end_turn","stop_hook_active":false}"#

    @Test func theEventComesFromTheArgumentWhenThePayloadHasNone() throws {
        let message = try #require(parse(stopPayload, tool: .copilot, event: "agentStop"))
        #expect(message == Hook.Message(event: "Stop", needsInput: false, sessionID: "s", project: "proj", branch: "main", tool: .copilot),
                "a camelCase payload names no event; the entry's --event is the only thing that says which one fired")
        #expect(message.userInfo[Hook.toolKey] as? String == "copilot")
        #expect(Hook.Message(userInfo: message.userInfo) == message, "the tool survives the notification payload, or the store would light Claude's ring")
        #expect(message.clearsWaiting)
        #expect(!message.hitRateLimit, "stopReason is documented as always end_turn, so no Copilot stop may plan a limit-hit alert")
    }

    @Test func aPayloadEventNameOutranksTheArgument() throws {
        // The PascalCase registration ("VS Code compatible format") does carry hook_event_name; the vendor's own
        // word wins over the flag, which only fills a payload that has none.
        let json = #"{"hook_event_name":"Stop","session_id":"s","timestamp":"2026-09-04T00:00:00Z","cwd":"/Users/x/proj","stop_reason":"end_turn"}"#
        let message = try #require(parse(json, tool: .copilot, event: "sessionEnd"))
        #expect(message.event == "Stop")
        #expect(message.tool == .copilot)
        #expect(message.sessionID == "s")
        #expect(message.project == "proj")
        let blank = try #require(parse(#"{"hook_event_name":"","sessionId":"s"}"#, tool: .copilot, event: "agentStop"))
        #expect(blank.event == "Stop", "an empty name is no name; the argument fills it")
    }

    @Test func bothIdSpellingsAreRead() throws {
        let camel = try #require(parse(#"{"sessionId":"abc","cwd":"/Users/x/proj"}"#, tool: .copilot, event: "sessionStart"))
        #expect(camel.sessionID == "abc")
        let snake = try #require(parse(#"{"hook_event_name":"SessionStart","session_id":"def","cwd":"/Users/x/proj"}"#, tool: .copilot))
        #expect(snake.sessionID == "def")
        let empty = try #require(parse(#"{"sessionId":"","cwd":"/Users/x/proj"}"#, tool: .copilot, event: "sessionStart"))
        #expect(empty.sessionID == nil, "an empty id is no id; the tracker's shared slot takes the event")
        let none = try #require(parse(#"{"cwd":""}"#, tool: .copilot, event: "sessionStart"))
        #expect(none.project == nil, "an empty cwd is not the basename of nothing")
        #expect(none.branch == nil)
    }

    /// Every documented name in both spellings lands on the tracker's vocabulary, and every one that is not a
    /// notification carries no type, no agent id, no permission mode and no failure: Copilot documents none of them.
    @Test func everyDocumentedNameMapsInBothSpellings() throws {
        let rows: [(camel: String, pascal: String?, canonical: String)] = [
            ("sessionStart", "SessionStart", "SessionStart"),
            ("userPromptSubmitted", "UserPromptSubmit", "UserPromptSubmit"),
            ("agentStop", "Stop", "Stop"),
            ("subagentStart", "SubagentStart", "SubagentStart"),
            ("subagentStop", "SubagentStop", "SubagentStop"),
            ("sessionEnd", "SessionEnd", "SessionEnd"),
        ]
        for row in rows {
            let camel = try #require(parse(#"{"sessionId":"s","cwd":"/Users/x/proj","source":"startup","reason":"user_exit","agentId":"a1","agentName":"explore"}"#,
                                           tool: .copilot, event: row.camel), "\(row.camel)")
            #expect(camel.event == row.canonical, "\(row.camel)")
            let pascal = try #require(parse("{\"hook_event_name\":\"\(row.pascal ?? row.canonical)\",\"session_id\":\"s\",\"cwd\":\"/Users/x/proj\",\"agent_id\":\"a1\"}", tool: .copilot), "\(row.camel)")
            #expect(pascal.event == row.canonical, "\(row.pascal ?? row.canonical)")
            for message in [camel, pascal] {
                #expect(!message.needsInput, "\(row.camel): only the two documented notification types are a wait")
                #expect(message.notificationType == nil, "\(row.camel)")
                #expect(message.agentID == nil, "\(row.camel): subagentStart documents no id, so an id on the stop could never pair with it; agents are counted, not named")
                #expect(message.permissionMode == nil, "\(row.camel): Copilot documents no permission mode")
                #expect(message.failure == nil, "\(row.camel): Copilot documents no failing stop")
                #expect(message.tool == .copilot)
                #expect(message.sessionID == "s")
                #expect(message.project == "proj")
                #expect(message.branch == "main")
            }
        }
        #expect(Hook.Copilot.canonicalEvent("Notification") == "Notification")
        #expect(Hook.Copilot.canonicalEvent("notification") == "Notification")
        #expect(Hook.Copilot.canonicalEvent("preToolUse") == "preToolUse", "a name the tracker has no case for passes through verbatim")
    }

    @Test func onlyPermissionPromptAndElicitationDialogWait() throws {
        // The six documented notification types, and the payload the reference prints for the event: camelCase
        // common fields plus a snake_case hook_event_name and notification_type, uniquely for this event.
        let waiting: Set<String> = ["permission_prompt", "elicitation_dialog"]
        let documented = ["shell_completed", "shell_detached_completed", "agent_completed", "agent_idle", "permission_prompt", "elicitation_dialog"]
        for type in documented {
            let json = "{\"sessionId\":\"s\",\"timestamp\":1756944000000,\"cwd\":\"/Users/x/proj\",\"hook_event_name\":\"Notification\",\"message\":\"m\",\"title\":\"t\",\"notification_type\":\"\(type)\"}"
            let message = try #require(parse(json, tool: .copilot, event: "notification"), "\(type)")
            #expect(message.event == "Notification", "\(type)")
            if waiting.contains(type) {
                #expect(message.needsInput, "\(type) is documented as the agent asking the user")
                #expect(message.notificationType == type, "the vendor's word rides along for the card and the log")
            } else {
                #expect(!message.needsInput, "\(type) is about a background shell or subagent, not the user")
                #expect(message.notificationType == nil, "\(type): the type is dropped so it can neither start nor end a wait")
                #expect(!message.clearsWaiting, "\(type)")
            }
        }
        let untyped = try #require(parse(#"{"sessionId":"s","cwd":"/Users/x/proj"}"#, tool: .copilot, event: "notification"))
        #expect(!untyped.needsInput)
        #expect(untyped.notificationType == nil)
        #expect(Hook.Copilot.waitingNotificationTypes == waiting)
    }

    @Test func agentCompletedCarriesNoTypeAndDoesNotClearAWait() throws {
        // Claude Code's agent_completed ends a wait (Message.clearsWaiting is tool-agnostic); Copilot's means a
        // background subagent finished, which answers no permission prompt, so the parser drops the type.
        var tracker = SessionTracker()
        let t0 = DateParsing.iso8601("2026-09-01T12:00:00Z")!
        tracker.apply(try #require(parse(#"{"sessionId":"s","cwd":"/Users/x/proj","prompt":"go"}"#, tool: .copilot, event: "userPromptSubmitted")), now: t0)
        let prompt = try #require(parse(#"{"sessionId":"s","cwd":"/Users/x/proj","hook_event_name":"Notification","notification_type":"permission_prompt","message":"m"}"#, tool: .copilot, event: "notification"))
        let waited = tracker.apply(prompt, now: t0.addingTimeInterval(5))
        #expect(waited.startedWaiting?.id == "copilot:s", "the key carries the tool's name so a Copilot session never shares Claude's slot")
        let completed = try #require(parse(#"{"sessionId":"s","cwd":"/Users/x/proj","hook_event_name":"Notification","notification_type":"agent_completed","message":"m"}"#, tool: .copilot, event: "notification"))
        #expect(!completed.clearsWaiting)
        tracker.apply(completed, now: t0.addingTimeInterval(10))
        #expect(tracker.waiting.map(\.id) == ["copilot:s"], "a background agent finishing is not the user answering")
        let stop = try #require(parse(stopPayload, tool: .copilot, event: "agentStop"))
        let outcome = tracker.apply(stop, now: t0.addingTimeInterval(30))
        #expect(tracker.waiting.isEmpty, "the turn's end is what documents the wait over")
        #expect(outcome.finished?.turn == 30)
        #expect(outcome.stoppedWaiting == ["copilot:s"])
    }

    @Test func subagentsAreCountedNotNamed() throws {
        var tracker = SessionTracker()
        let t0 = DateParsing.iso8601("2026-09-01T12:00:00Z")!
        let start = #"{"sessionId":"s","cwd":"/Users/x/proj","transcriptPath":"/t","agentName":"explore","agentDisplayName":"Explore"}"#
        let stop = #"{"sessionId":"s","cwd":"/Users/x/proj","transcriptPath":"/t","agentId":"a-9","agentType":"explore","agentName":"explore","response":"done","stopReason":"end_turn"}"#
        tracker.apply(try #require(parse(start, tool: .copilot, event: "subagentStart")), now: t0)
        tracker.apply(try #require(parse(start, tool: .copilot, event: "subagentStart")), now: t0.addingTimeInterval(1))
        #expect(tracker.agentCount == 2)
        tracker.apply(try #require(parse(stop, tool: .copilot, event: "subagentStop")), now: t0.addingTimeInterval(2))
        #expect(tracker.agentCount == 1, "subagentStart documents no id, so the stop's agentId is not read and the tracker drops its oldest agent; the count is what stays right")
        #expect(tracker.all.first?.id == "copilot:s", "the subagent events use the common sessionId, which is read as the parent's")
        #expect(tracker.knownCount(of: .copilot) == 1)
    }

    @Test func permissionRequestIsNotAWait() throws {
        // permissionRequest fires "before the permission service runs (rules engine, session approvals,
        // auto-allow/auto-deny, and user prompting)", so it fires for calls the user is never asked about.
        for (event, payload) in [("permissionRequest", #"{"sessionId":"s","cwd":"/Users/x/proj","toolName":"bash","toolInput":{"command":"ls"}}"#),
                                 ("PermissionRequest", #"{"hook_event_name":"PermissionRequest","session_id":"s","cwd":"/Users/x/proj","tool_name":"Bash"}"#),
                                 ("errorOccurred", #"{"sessionId":"s","cwd":"/Users/x/proj","error":{"message":"boom","name":"Error"},"errorContext":"model_call","recoverable":true}"#),
                                 ("preToolUse", #"{"sessionId":"s","cwd":"/Users/x/proj","toolName":"ask_user","toolArgs":"{}"}"#)] {
            let message = try #require(parse(payload, tool: .copilot, event: event), "\(event)")
            #expect(!message.needsInput, "\(event): the only documented wait is the notification event's two types")
            #expect(message.event == event, "\(event) passes through verbatim; the tracker has no case for it")
            #expect(!message.clearsWaiting, "\(event) cannot end a wait either")
            #expect(message.failure == nil, "\(event): errorOccurred fires mid-turn for recoverable errors too, so it is no stop")
            #expect(message.tool == .copilot)
        }
        let claude = try #require(parse(#"{"hook_event_name":"PermissionRequest","session_id":"s","tool_name":"Bash"}"#))
        #expect(claude.needsInput, "Claude Code's PermissionRequest is still its documented wait; the flag is what hands the same name to Copilot's rule")
    }

    @Test func noEventWithoutArgumentOrNameYieldsNil() {
        #expect(parse(stopPayload, tool: .copilot) == nil, "a camelCase payload with no hook_event_name and no --event names no event; the entry must carry --event, and status reads one without it as partial")
        #expect(parse(stopPayload) == nil)
        #expect(parse(#"{"sessionId":"s","hook_event_name":""}"#, tool: .copilot) == nil)
        #expect(Hook.event(in: ["Notchmeter", "--hook", "--tool", "copilot", "--event", "agentStop"]) == "agentStop")
        #expect(Hook.event(in: ["--hook", "--event"]) == nil, "a dangling flag is ignored, not an error")
        #expect(Hook.event(in: ["--hook", "--event", ""]) == nil, "an empty --event is no event, so the command line never hands the parser one")
        #expect(Hook.event(in: ["--hook", "--tool", "copilot"]) == nil)
    }

    @Test func camelSessionIdIsRecognisedWithoutTheFlag() throws {
        // A camelCase sessionId is a key Claude Code never sends, and the camel names are Copilot's alone; a
        // PascalCase payload with snake_case fields has nothing Copilot's and stays Claude's without the flag.
        let byKey = try #require(parse(#"{"sessionId":"s","cwd":"/Users/x/proj","hook_event_name":"Notification","notification_type":"permission_prompt","message":"m"}"#))
        #expect(byKey.tool == .copilot)
        #expect(byKey.needsInput)
        #expect(byKey.sessionID == "s")
        let byName = try #require(parse(#"{"hook_event_name":"agentStop","session_id":"s","cwd":"/Users/x/proj"}"#))
        #expect(byName.tool == .copilot, "agentStop is a name only Copilot documents")
        #expect(byName.event == "Stop")
        let byArgument = try #require(parse(#"{"session_id":"s","cwd":"/Users/x/proj"}"#, event: "userPromptSubmitted"))
        #expect(byArgument.tool == .copilot, "the argument's name is the event, and Copilot's names recognise the sender")
        #expect(byArgument.event == "UserPromptSubmit")
        let claude = try #require(parse(#"{"hook_event_name":"Stop","session_id":"s","transcript_path":"/x","cwd":"/Users/me/y"}"#))
        #expect(claude.tool == .claude, "Claude Code's own payload has nothing Copilot's in it")
        #expect(claude == Hook.Message(event: "Stop", needsInput: false, sessionID: "s", project: "y"))
        let cursor = try #require(parse(#"{"hook_event_name":"subagentStart","conversation_id":"c1","subagent_id":"abc"}"#))
        #expect(cursor.tool == .cursor, "Cursor is asked first, and subagentStart with a conversation_id is Cursor's")
        #expect(Hook.Copilot.recognises(event: "sessionStart", object: [:]))
        #expect(Hook.Copilot.recognises(event: "Stop", object: ["sessionId": "s"]))
        #expect(!Hook.Copilot.recognises(event: "Stop", object: ["session_id": "s"]))
        #expect(Hook.Copilot.recognises(event: "subagentStart", object: [:]), "subagentStart is in Copilot's camel set too; Cursor's earlier claim is what settles the order")
    }

    @Test func theSessionIdKeyOutranksTheNamesCopilotSharesWithCursor() throws {
        // Eight of Copilot's camelCase names are Cursor's too, and Cursor is asked first by name; the camelCase
        // sessionId is asked before either, so a Copilot payload under a shared name keeps its id and its ring
        // whenever it carries the key, and is Cursor's whenever it does not — which is what docs/hooks.md promises.
        for name in ["sessionStart", "sessionEnd", "subagentStart", "subagentStop", "preToolUse", "postToolUse", "postToolUseFailure", "preCompact"] {
            let remote = try #require(LocalAPI.hookMessage(from: Data("{\"hook_event_name\":\"\(name)\",\"sessionId\":\"s\",\"cwd\":\"/home/me/proj\",\"host\":\"devbox\"}".utf8)))
            #expect(remote.tool == .copilot, "\(name): a remote post with sessionId and no tool key is Copilot's")
            #expect(remote.sessionID == "s", "\(name): the id must not be lost to Cursor's parser, which reads conversation_id")
            #expect(remote.event == Hook.Copilot.canonicalEvent(name))
            let local = try #require(parse(#"{"sessionId":"s","cwd":"/Users/x/proj"}"#, event: name))
            #expect(local.tool == .copilot, "\(name): a hand-written entry on --hook --event without --tool is still Copilot's")
            #expect(local.sessionID == "s")
            let cursor = try #require(parse("{\"hook_event_name\":\"\(name)\",\"conversation_id\":\"c1\"}"))
            #expect(cursor.tool == .cursor, "\(name): Cursor's own payload under the shared name stays Cursor's")
            #expect(cursor.sessionID == "c1")
            let bare = try #require(parse("{\"hook_event_name\":\"\(name)\",\"session_id\":\"s\"}"))
            #expect(bare.tool == .cursor, "\(name): a shared name with neither key settles nothing, and Cursor, asked first by name, takes it")
        }
        #expect(Hook.Copilot.recognises(object: ["sessionId": "s"]))
        #expect(!Hook.Copilot.recognises(object: ["session_id": "s", "conversation_id": "c"]), "the snake_case and Cursor ids are not the key")
    }

    @Test func remotePostWithToolCopilotAndHookEventName() throws {
        // A remote payload's camelCase form carries no event, so the remote side must send hook_event_name (or use
        // the PascalCase names); the "tool" key routes it to Copilot's parser the way "host" labels the machine.
        let body = Data(#"{"tool":"copilot","hook_event_name":"agentStop","sessionId":"s","cwd":"/home/me/proj","branch":"main","host":"devbox"}"#.utf8)
        let message = try #require(LocalAPI.hookMessage(from: body))
        #expect(message.tool == .copilot)
        #expect(message.event == "Stop")
        #expect(message.host == "devbox")
        #expect(message.project == "proj")
        #expect(message.branch == "main", "the branch comes from the payload; the checkout is not on this Mac")
        #expect(SessionTracker.key(tool: .copilot, session: message.sessionID, host: message.host) == "copilot:s@devbox")
        let pascal = try #require(LocalAPI.hookMessage(from: Data(#"{"tool":"copilot","hook_event_name":"Stop","session_id":"s","cwd":"/home/me/proj","host":"devbox"}"#.utf8)))
        #expect(pascal.tool == .copilot)
        #expect(pascal.event == "Stop")
        #expect(LocalAPI.hookMessage(from: Data(#"{"tool":"copilot","sessionId":"s","cwd":"/home/me/proj","host":"devbox"}"#.utf8)) == nil,
                "no event name and no command line to read one from: the post is dropped rather than guessed")
    }
}


/// The `~/.copilot/hooks/notchmeter.json` installer: Notchmeter's own file, so nothing is merged into anyone else's
/// JSON, with Copilot's `version` key, its flat `{type, command, timeoutSec}` entries, the `--event` each command
/// carries and the `matcher` on the notification entry, through the same merge, repair, status and install the
/// Claude Code hook has.
@Suite struct CopilotHookInstallation {
    init() { Localization.use(language: "en") }

    let executable = "/Applications/Notchmeter.app/Contents/MacOS/Notchmeter"
    func expected(_ event: String) -> String { "'\(executable)' --hook --tool copilot --event \(event)" }

    /// A notchmeter.json with every event Notchmeter registers, each carrying the command the closure gives it.
    func file(version: Any? = 1, without missing: String? = nil, command: (String) -> String) -> [String: Any] {
        var hooks: [String: Any] = [:]
        for event in HookVendor.copilot.events where event != missing {
            hooks[event] = [HookVendor.copilot.handler(command: command(event), event: event)]
        }
        var settings: [String: Any] = ["hooks": hooks]
        if let version { settings["version"] = version }
        return settings
    }

    @Test func snippetIsVersionOneFlatWithPerEventFlags() throws {
        let snippet = HookSettings.snippet(vendor: .copilot, executable: "/Users/me/My Apps/Notchmeter.app/Contents/MacOS/Notchmeter")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(snippet.utf8)) as? [String: Any])
        #expect(root["version"] as? Int == 1, "Copilot's files carry version 1")
        #expect(Set(root.keys) == ["version", "hooks"])
        let hooks = try #require(root["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == Set(HookVendor.copilot.events))
        #expect(HookVendor.copilot.events.count == 7)
        #expect(HookVendor.copilot.events == ["sessionStart", "userPromptSubmitted", "agentStop", "subagentStart", "subagentStop", "notification", "sessionEnd"])
        for event in HookVendor.copilot.events {
            let entries = try #require(hooks[event] as? [[String: Any]], "\(event)")
            #expect(entries.count == 1, "\(event)")
            let entry = try #require(entries.first)
            #expect(entry["type"] as? String == "command", "\(event)")
            #expect(entry["command"] as? String == "'/Users/me/My Apps/Notchmeter.app/Contents/MacOS/Notchmeter' --hook --tool copilot --event \(event)",
                    "\(event): the payload names no event, so the command does")
            #expect(entry["timeoutSec"] as? Int == 5, "\(event): Copilot's unit is timeoutSec, and every event but notification waits for the command")
            #expect(entry["async"] == nil, "\(event): Copilot documents no async field")
            #expect(entry["timeout"] == nil, "\(event): the alias is not written beside the real key")
            #expect(entry["hooks"] == nil, "\(event): Copilot's entries are flat")
            if event == "notification" {
                #expect(Set(entry.keys) == ["type", "command", "matcher", "timeoutSec"], "\(event)")
                #expect(entry["matcher"] as? String == "permission_prompt|elicitation_dialog", "the four other types never launch the command")
            } else {
                #expect(Set(entry.keys) == ["type", "command", "timeoutSec"], "\(event)")
            }
        }
        #expect(snippet.contains("\"version\": 1,"))
        #expect(!snippet.contains("\\/"))
        #expect(HookVendor.copilot.flag == "--hook --tool copilot")
        #expect(HookVendor.copilot.flag(for: "agentStop") == "--hook --tool copilot --event agentStop")
        #expect(HookVendor.cursor.flag(for: "stop") == "--hook --tool cursor", "only Copilot's commands name the event")
        #expect(HookVendor.copilot.fileName == "notchmeter.json")
        #expect(HookVendor.copilot.shape == .flatCommands)
        #expect(HookVendor.copilot.tool == .copilot)
        #expect(HookVendor.copilot.displayName == "GitHub Copilot")
        #expect(!HookVendor.copilot.reloadsLive, "Copilot reads its hooks directory when it starts")
        #expect(HookVendor.vendor(for: .copilot) == .copilot)
        #expect(HookSettings.executable(in: expected("agentStop")) == executable, "status reads the path back out of the longer command")
        #expect(HookSettings.isNotchmeterHook(HookVendor.copilot.handler(command: expected("notification"), event: "notification")))
    }

    @Test func notificationEntryCarriesTheMatcherAndRepairKeepsIt() throws {
        let other = "/Users/me/Downloads/Notchmeter.app/Contents/MacOS/Notchmeter"
        let moved = file { "'\(other)' --hook --tool copilot --event \($0)" }
        #expect(HookSettings.status(settings: moved, vendor: .copilot, executable: executable) == .stale(path: other))
        let repaired = HookSettings.repair(moved, vendor: .copilot, executable: executable)
        #expect(repaired.repaired == HookVendor.copilot.events, "a moved app is re-pointed under every event, in the vendor's order")
        #expect(repaired.added.isEmpty)
        let hooks = try #require(repaired.settings["hooks"] as? [String: Any])
        let notification = try #require((hooks["notification"] as? [[String: Any]])?.first)
        #expect(notification["command"] as? String == expected("notification"))
        #expect(notification["matcher"] as? String == "permission_prompt|elicitation_dialog", "only the command is rewritten; the matcher sits on the flat element and comes back whole")
        #expect(notification["timeoutSec"] as? Int == 5)
        #expect(notification["type"] as? String == "command")
        let stop = try #require((hooks["agentStop"] as? [[String: Any]])?.first)
        #expect(Set(stop.keys) == ["type", "command", "timeoutSec"])
        #expect(stop["command"] as? String == expected("agentStop"))
        #expect(HookSettings.status(settings: repaired.settings, vendor: .copilot, executable: executable) == .installed(path: executable))

        // A timeout the user raised by hand is theirs to keep.
        var loose = file { expected($0) }
        var loosened = try #require(loose["hooks"] as? [String: Any])
        loosened["notification"] = [["type": "command", "command": "'\(other)' --hook --tool copilot --event notification", "matcher": "permission_prompt", "timeoutSec": 30]]
        loose["hooks"] = loosened
        let kept = HookSettings.repair(loose, vendor: .copilot, executable: executable)
        #expect(kept.repaired == ["notification"])
        let entry = try #require(((kept.settings["hooks"] as? [String: Any])?["notification"] as? [[String: Any]])?.first)
        #expect(entry["matcher"] as? String == "permission_prompt")
        #expect(entry["timeoutSec"] as? Int == 30)
        #expect(entry["command"] as? String == expected("notification"))
    }

    @Test func statusPartialWhenEventArgumentMissingOrWrongAndRepairFixesIt() throws {
        #expect(HookSettings.status(settings: [:], vendor: .copilot, executable: executable) == .notInstalled)
        #expect(HookSettings.status(settings: ["version": 1, "hooks": [:]], vendor: .copilot, executable: executable) == .notInstalled)
        #expect(HookSettings.status(settings: ["hooks": ["preToolUse": [["type": "command", "command": expected("preToolUse")]]]], vendor: .copilot, executable: executable) == .notInstalled,
                "an entry under an event Notchmeter does not register does not count")
        #expect(HookSettings.status(settings: file { expected($0) }, vendor: .copilot, executable: executable) == .installed(path: executable))
        #expect(!HookSettings.status(settings: file { expected($0) }, vendor: .copilot, executable: executable).needsRepair)

        // Without --event the hook command reads a payload that names no event and posts nothing: out of date.
        let withoutEvent = HookSettings.status(settings: file { _ in "'\(executable)' --hook --tool copilot" }, vendor: .copilot, executable: executable)
        #expect(withoutEvent == .partial(path: executable), "the right path and the tool flag, but no event: the command cannot read one from the payload")
        #expect(withoutEvent.needsRepair)
        #expect(withoutEvent.text == "Installed, but an entry is out of date: Repair updates it")
        // Another event's --event under this event would post the wrong event every time.
        var wrong = file { expected($0) }
        var hooks = try #require(wrong["hooks"] as? [String: Any])
        hooks["agentStop"] = [HookVendor.copilot.handler(command: expected("sessionEnd"), event: "agentStop")]
        wrong["hooks"] = hooks
        #expect(HookSettings.status(settings: wrong, vendor: .copilot, executable: executable) == .partial(path: executable), "an entry carrying another event's name would end the session on every stop")
        let plain = HookSettings.status(settings: file { _ in "'\(executable)' --hook" }, vendor: .copilot, executable: executable)
        #expect(plain == .partial(path: executable))
        let missing = HookSettings.status(settings: file(without: "notification") { expected($0) }, vendor: .copilot, executable: executable)
        #expect(missing == .partial(path: executable), "the right commands with an event missing is out of date, not pointing at an old copy")
        let decorated = HookSettings.status(settings: file { "\(expected($0)) 2>/dev/null" }, vendor: .copilot, executable: executable)
        #expect(decorated == .installed(path: executable), "the path and the flags are what count; a redirect the user added is theirs to keep")

        let fixed = HookSettings.repair(wrong, vendor: .copilot, executable: executable)
        #expect(fixed.repaired == ["agentStop"])
        #expect(fixed.added.isEmpty)
        #expect(HookSettings.status(settings: fixed.settings, vendor: .copilot, executable: executable) == .installed(path: executable))
        let stop = try #require(((fixed.settings["hooks"] as? [String: Any])?["agentStop"] as? [[String: Any]])?.first)
        #expect(stop["command"] as? String == expected("agentStop"))

        let seven = HookSettings.repair(file { _ in "'\(executable)' --hook --tool copilot" }, vendor: .copilot, executable: executable)
        #expect(seven.repaired == HookVendor.copilot.events, "every entry without its event is given its own")
        #expect(seven.added.isEmpty)
        for event in HookVendor.copilot.events {
            let entries = try #require((seven.settings["hooks"] as? [String: Any])?[event] as? [[String: Any]], "\(event)")
            #expect(entries.count == 1, "\(event)")
            #expect(entries.first?["command"] as? String == expected(event), "\(event)")
        }
        let added = HookSettings.repair(file(without: "notification") { expected($0) }, vendor: .copilot, executable: executable)
        #expect(added.repaired.isEmpty)
        #expect(added.added == ["notification"])
        let notification = try #require(((added.settings["hooks"] as? [String: Any])?["notification"] as? [[String: Any]])?.first)
        #expect(notification["matcher"] as? String == "permission_prompt|elicitation_dialog", "an added notification entry gets its matcher")
        let again = HookSettings.repair(added.settings, vendor: .copilot, executable: executable)
        #expect(again.repaired.isEmpty)
        #expect(again.added.isEmpty)
        #expect(NSDictionary(dictionary: again.settings) == NSDictionary(dictionary: added.settings))
    }

    @Test func mergeIsIdempotent() throws {
        let fresh = HookSettings.merge(into: [:], vendor: .copilot, executable: executable)
        #expect(fresh.added == HookVendor.copilot.events)
        #expect(fresh.present.isEmpty)
        #expect(fresh.settings["version"] as? Int == 1, "Copilot wants a version at the root; a new file gets 1")
        #expect(Set(fresh.settings.keys) == ["version", "hooks"])
        let hooks = try #require(fresh.settings["hooks"] as? [String: Any])
        for event in HookVendor.copilot.events {
            let entries = try #require(hooks[event] as? [[String: Any]], "\(event)")
            #expect(entries.count == 1, "\(event)")
            #expect(NSDictionary(dictionary: entries[0]) == NSDictionary(dictionary: HookVendor.copilot.handler(command: expected(event), event: event)), "\(event)")
        }
        let second = HookSettings.merge(into: fresh.settings, vendor: .copilot, executable: "/somewhere/else/Notchmeter")
        #expect(second.added.isEmpty)
        #expect(Set(second.present) == Set(HookVendor.copilot.events))
        #expect(NSDictionary(dictionary: second.settings) == NSDictionary(dictionary: fresh.settings), "a second merge changes nothing, whichever executable asks")

        // The file is Notchmeter's own, but a user who edited it keeps what they added: a bash entry (which
        // carries no `command` and so is never ours), a disableAllHooks switch, a version of their own.
        let edited: [String: Any] = [
            "version": 2,
            "disableAllHooks": false,
            "hooks": [
                "agentStop": [["type": "command", "bash": "osascript -e 'display notification \"done\"'", "timeoutSec": 5]],
                "sessionEnd": "not an array",
            ],
        ]
        let merged = HookSettings.merge(into: edited, vendor: .copilot, executable: executable)
        #expect(merged.added == ["sessionStart", "userPromptSubmitted", "agentStop", "subagentStart", "subagentStop", "notification"])
        #expect(merged.present == ["sessionEnd"], "a value that is not an array is left alone rather than replaced")
        #expect(merged.settings["version"] as? Int == 2, "an existing version is never overwritten")
        #expect(merged.settings["disableAllHooks"] as? Bool == false)
        let stop = try #require((merged.settings["hooks"] as? [String: Any])?["agentStop"] as? [[String: Any]])
        #expect(stop.count == 2)
        #expect(stop[0]["bash"] as? String == "osascript -e 'display notification \"done\"'", "a bash entry has no command and is never ours")
        #expect(stop[1]["command"] as? String == expected("agentStop"))
    }

    @Test func installCreatesTheFileAndDirectory() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("notchmeter-copilot-hook-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let now = Date(timeIntervalSince1970: 1_788_300_000)

        // The usual first state: no ~/.copilot/hooks/ at all. Install creates the directory and the file.
        let url = dir.appendingPathComponent("home/.copilot/hooks/notchmeter.json")
        #expect(HookSettings.status(vendor: .copilot, at: url, executable: executable) == .notInstalled)
        let created = try HookSettings.install(vendor: .copilot, at: url, executable: executable, now: now)
        #expect(created.backup == nil, "nothing to back up when the file did not exist")
        #expect(created.added == HookVendor.copilot.events)
        #expect(created.present.isEmpty)
        #expect(fm.fileExists(atPath: url.path))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("\\/"), "slashes in the path are written bare")
        let written = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(written["version"] as? Int == 1)
        #expect(Set(written.keys) == ["version", "hooks"], "the file is Notchmeter's own and carries nothing else")
        let hooks = try #require(written["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == Set(HookVendor.copilot.events))
        #expect(hooks.count == 7)
        for event in HookVendor.copilot.events {
            let entries = try #require(hooks[event] as? [[String: Any]], "\(event)")
            #expect(entries.first?["command"] as? String == expected(event), "\(event): every entry carries its own --event")
        }
        #expect(HookSettings.status(vendor: .copilot, at: url, executable: executable) == .installed(path: executable))

        let again = try HookSettings.install(vendor: .copilot, at: url, executable: executable, now: now.addingTimeInterval(60))
        #expect(again.added.isEmpty)
        #expect(again.backup == nil)
        #expect(Set(again.present) == Set(HookVendor.copilot.events))
        #expect(try fm.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).filter { $0.contains(".bak-") }.isEmpty)

        // An app that moved: the launch repair re-points every entry after a backup, keeping permissions.
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let other = "/Users/me/Downloads/Notchmeter.app/Contents/MacOS/Notchmeter"
        try JSONSerialization.data(withJSONObject: file { "'\(other)' --hook --tool copilot --event \($0)" }).write(to: url)
        #expect(HookSettings.status(vendor: .copilot, at: url, executable: executable) == .stale(path: other))
        let repaired = try HookSettings.repairInstall(vendor: .copilot, at: url, executable: executable, now: now.addingTimeInterval(120))
        let backup = try #require(repaired.backup)
        #expect(backup.lastPathComponent.range(of: #"^notchmeter\.json\.bak-\d{8}-\d{6}$"#, options: .regularExpression) != nil)
        #expect(repaired.added == HookVendor.copilot.events, "every entry was re-pointed")
        #expect((try fm.attributesOfItem(atPath: url.path))[.posixPermissions] as? Int == 0o600)
        #expect(HookSettings.status(vendor: .copilot, at: url, executable: executable) == .installed(path: executable))
        let reread = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let notification = try #require(((reread["hooks"] as? [String: Any])?["notification"] as? [[String: Any]])?.first)
        #expect(notification["matcher"] as? String == "permission_prompt|elicitation_dialog", "the matcher survives the round trip through disk")
        #expect(try HookSettings.repairInstall(vendor: .copilot, at: url, executable: executable, now: now.addingTimeInterval(180)).backup == nil)

        // Removing the hook is deleting the file: the row reads not installed again, and nothing else is affected.
        try fm.removeItem(at: url)
        #expect(HookSettings.status(vendor: .copilot, at: url, executable: executable) == .notInstalled)
        #expect(fm.fileExists(atPath: backup.path), "the backup beside it is the user's to keep or drop")

        try Data("[]".utf8).write(to: url)
        #expect(throws: HookSettings.Failure.self) {
            try HookSettings.install(vendor: .copilot, at: url, executable: executable, now: now)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "[]", "a file that is not a JSON object is refused, not rewritten")
    }

    @Test func fileURLFollowsCopilotHome() {
        let home = URL(fileURLWithPath: "/Users/me")
        #expect(HookVendor.copilot.fileURL(environment: [:], home: home).path == "/Users/me/.copilot/hooks/notchmeter.json")
        #expect(HookVendor.copilot.fileURL(environment: ["COPILOT_HOME": "/srv/copilot"], home: home).path == "/srv/copilot/hooks/notchmeter.json",
                "COPILOT_HOME replaces ~/.copilot itself, so hooks/ is appended to it")
        #expect(HookVendor.copilot.fileURL(environment: ["COPILOT_HOME": ""], home: home).path == "/Users/me/.copilot/hooks/notchmeter.json", "an empty override is no override")
        #expect(HookVendor.copilot.fileURL(environment: ["COPILOT_HOME": "~/copilot-home"], home: home).path.hasSuffix("/copilot-home/hooks/notchmeter.json"))
        #expect(HookVendor.copilot.fileURL(environment: ["CLAUDE_CONFIG_DIR": "/elsewhere", "GEMINI_CLI_HOME": "/elsewhere"], home: home).path == "/Users/me/.copilot/hooks/notchmeter.json",
                "another vendor's override is not Copilot's")
        #expect(HookVendor.copilot.fileURL.path.hasSuffix("/hooks/notchmeter.json"))
    }
}
