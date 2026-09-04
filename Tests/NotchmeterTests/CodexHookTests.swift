import Foundation
import Testing
@testable import Notchmeter

/// Codex's hook read onto the same Message Claude Code's fills: how its borrowed UpperCamel names land on the
/// tracker's vocabulary, the one name (Interrupt) Claude Code has no word for, which of its fields are read, and
/// the one wait it documents. Every test here parses the JSON Codex documents at learn.chatgpt.com/docs/hooks
/// rather than a Message built by hand, because the parser is the whole feature: above it nothing knows Codex
/// exists. The flag is passed by default because a Codex payload is shaped like Claude Code's and nothing else
/// tells them apart; the two tests that leave it out say so.
@Suite struct CodexHookMessages {
    init() { Localization.use(language: "en") }

    /// The twelve names Codex documents, for the tests that walk the whole vocabulary.
    static let documentedEvents = [
        "SessionStart", "UserPromptSubmit", "PermissionRequest", "PreToolUse", "PostToolUse", "PreCompact", "PostCompact",
        "Stop", "Interrupt", "SubagentStart", "SubagentStop", "SessionEnd",
    ]

    /// The branch closure stands in for `.git/HEAD`: it answers only for the root the payload names, so a branch
    /// on the message proves the parser asked about the right folder.
    func parse(_ json: String, tool: ToolID? = .codex, environment: [String: String] = [:]) -> Hook.Message? {
        Hook.message(from: Data(json.utf8), tool: tool, environment: environment, branch: { $0 == "/Users/x/proj" ? "main" : nil })
    }

    @Test func sessionStartReadsAsCodexWithTheFlag() throws {
        let json = #"{"session_id":"b5f6c1c2-1111-2222-3333-444455556666","transcript_path":"/Users/x/.codex/sessions/r.jsonl","cwd":"/Users/x/proj","hook_event_name":"SessionStart","source":"startup","model":"gpt-5-codex","permission_mode":"default"}"#
        let message = try #require(parse(json))
        #expect(message == Hook.Message(event: "SessionStart", needsInput: false, sessionID: "b5f6c1c2-1111-2222-3333-444455556666", project: "proj",
                                        branch: "main", permissionMode: "default", tool: .codex))
        #expect(message.userInfo[Hook.toolKey] as? String == "codex")
        #expect(Hook.Message(userInfo: message.userInfo) == message, "the tool survives the notification payload, or the store would light Claude's ring")
    }

    @Test func permissionRequestIsTheOnlyWait() throws {
        let mapped = Set(Hook.Codex.events.keys)
        for name in Self.documentedEvents {
            let message = try #require(parse("{\"hook_event_name\":\"\(name)\",\"session_id\":\"s\",\"cwd\":\"/Users/x/proj\"}"))
            #expect(message.tool == .codex)
            #expect(message.needsInput == (name == "PermissionRequest"),
                    "\(name): PermissionRequest is documented as \"runs when Codex is about to ask for approval\" and is the one wait; Codex has no Notification, no question, no idle prompt and no elicitation event, so nothing else may light the hand")
            #expect(message.notificationType == nil, "\(name): Codex has no notification types, and a nil type is what keeps Claude's completion types from ending a wait they did not answer")
            guard !mapped.contains(name) else { continue }
            #expect(message.event == name, "an event the tracker has no case for passes through verbatim and does nothing")
            #expect(!message.clearsWaiting, "\(name) must not end a wait either: only the events the reference ties to a turn's start or end do")
        }
        let permission = try #require(parse(#"{"hook_event_name":"PermissionRequest","session_id":"s","cwd":"/Users/x/proj","tool_name":"Bash","tool_input":{"command":"rm -rf build"},"permission_mode":"default","turn_id":"t1"}"#))
        #expect(permission.event == "PermissionRequest")
        #expect(permission.needsInput)
        #expect(!permission.clearsWaiting)
    }

    @Test func stopIsAFinishAndInterruptIsNot() throws {
        let stop = try #require(parse(#"{"hook_event_name":"Stop","session_id":"s","cwd":"/Users/x/proj","turn_id":"t1","stop_hook_active":false,"last_assistant_message":"Done.","permission_mode":"default"}"#))
        #expect(stop.event == "Stop")
        #expect(stop.failure == nil, "Stop carries no status field, so it is always a finish; there is nothing in the payload that could make it a failure")
        let interrupt = try #require(parse(#"{"hook_event_name":"Interrupt","session_id":"s","cwd":"/Users/x/proj","turn_id":"t1","permission_mode":"default"}"#))
        #expect(interrupt.event == "StopFailure", "Interrupt is documented as \"when you interrupt an active turn\": the turn ends, but a ring that ticked for it would congratulate a turn the user cut short")
        #expect(interrupt.failure == "interrupted")
        for message in [stop, interrupt] {
            #expect(!message.hitRateLimit, "Codex has no rate-limit event, so none of its stops may plan a limit-hit alert")
            #expect(message.clearsWaiting, "both end a turn, so both bring a waiting hand down")
        }

        // Through the tracker: a Stop after a prompt is a finish with a turn length; an Interrupt after a prompt
        // ends the turn without one.
        var tracker = SessionTracker()
        let start = Date(timeIntervalSince1970: 1_788_300_000)
        let prompt = try #require(parse(#"{"hook_event_name":"UserPromptSubmit","session_id":"s","cwd":"/Users/x/proj","prompt":"fix it"}"#))
        tracker.apply(prompt, now: start)
        let finished = tracker.apply(stop, now: start.addingTimeInterval(25))
        #expect(finished.finished?.turn == 25)
        tracker.apply(prompt, now: start.addingTimeInterval(60))
        let cut = tracker.apply(interrupt, now: start.addingTimeInterval(70))
        #expect(cut.finished == nil)
        #expect(cut.limitHit == nil)
    }

    @Test func compactSessionStartStaysTheSameSession() throws {
        let startup = try #require(parse(#"{"hook_event_name":"SessionStart","session_id":"s","cwd":"/Users/x/proj","source":"startup"}"#))
        let compact = try #require(parse(#"{"hook_event_name":"SessionStart","session_id":"s","cwd":"/Users/x/proj","source":"compact"}"#))
        #expect(compact == startup, "source is not read: a SessionStart after compaction is the same session under the same id, and the parser has no second word for it")
        for source in ["startup", "resume", "clear", "compact"] {
            let message = try #require(parse("{\"hook_event_name\":\"SessionStart\",\"session_id\":\"s\",\"source\":\"\(source)\"}"))
            #expect(message.event == "SessionStart", "\(source)")
        }
        // Through the tracker: the compact SessionStart lands on the session already there and neither restarts
        // its turn nor opens a second entry.
        var tracker = SessionTracker()
        let now = Date(timeIntervalSince1970: 1_788_300_000)
        tracker.apply(startup, now: now)
        let prompt = try #require(parse(#"{"hook_event_name":"UserPromptSubmit","session_id":"s","cwd":"/Users/x/proj"}"#))
        tracker.apply(prompt, now: now.addingTimeInterval(5))
        tracker.apply(compact, now: now.addingTimeInterval(10))
        #expect(tracker.sessions.count == 1)
        let session = try #require(tracker.sessions[SessionTracker.key(tool: .codex, session: "s", host: nil)])
        #expect(session.isWorking, "compaction happens mid-turn; the turn is still running")
        #expect(session.turnStarted == now.addingTimeInterval(5))
        #expect(session.tool == .codex)
    }

    @Test func subagentsCarryTheirId() throws {
        let start = try #require(parse(#"{"hook_event_name":"SubagentStart","session_id":"parent","cwd":"/Users/x/proj","turn_id":"t1","agent_id":"agent-7","agent_type":"explorer","permission_mode":"default"}"#))
        #expect(start.event == "SubagentStart")
        #expect(start.agentID == "agent-7")
        #expect(start.sessionID == "parent", "session_id on a subagent event is documented as the parent's, so the agent counts on the session that spawned it")
        let stop = try #require(parse(#"{"hook_event_name":"SubagentStop","session_id":"parent","cwd":"/Users/x/proj","turn_id":"t1","agent_id":"agent-7","agent_type":"explorer","agent_transcript_path":"/tmp/a.jsonl","stop_hook_active":false,"last_assistant_message":null}"#))
        #expect(stop.event == "SubagentStop")
        #expect(stop.agentID == "agent-7", "SubagentStop names its agent, unlike Cursor's, so the exact agent is dropped rather than the oldest")
        #expect(stop.sessionID == "parent")
        let blank = try #require(parse(#"{"hook_event_name":"SubagentStop","session_id":"parent","agent_id":""}"#))
        #expect(blank.agentID == nil, "an empty id is no id")

        var tracker = SessionTracker()
        let now = Date(timeIntervalSince1970: 1_788_300_000)
        tracker.apply(start, now: now)
        let second = try #require(parse(#"{"hook_event_name":"SubagentStart","session_id":"parent","agent_id":"agent-8"}"#))
        tracker.apply(second, now: now.addingTimeInterval(1))
        tracker.apply(stop, now: now.addingTimeInterval(2))
        let session = try #require(tracker.sessions[SessionTracker.key(tool: .codex, session: "parent", host: nil)])
        #expect(Set(session.agents.keys) == ["agent-8"], "the named agent is the one dropped")
    }

    @Test func aSubagentsPromptDoesNotRestartTheParentsTurn() throws {
        // Codex's UserPromptSubmit schema declares an optional agent_id, present when a subagent submits, and the
        // session_id on it is the parent's. Read as the parent's UserPromptSubmit it would restart the turn clock
        // mid-turn and wipe a finished mark, so it passes through under a name the tracker only counts as activity.
        let parent = try #require(parse(#"{"hook_event_name":"UserPromptSubmit","session_id":"s","cwd":"/Users/x/proj","prompt":"go","turn_id":"t1","permission_mode":"default"}"#))
        #expect(parent.event == "UserPromptSubmit", "the user's own prompt carries no agent_id and starts the turn")
        let sub = try #require(parse(#"{"hook_event_name":"UserPromptSubmit","session_id":"s","cwd":"/Users/x/proj","prompt":"explore","turn_id":"t1","agent_id":"agent-7","agent_type":"explorer","permission_mode":"default"}"#))
        #expect(sub.event == Hook.Codex.subagentPromptEvent)
        #expect(sub.tool == .codex)
        #expect(!sub.needsInput)
        #expect(!sub.clearsWaiting, "a subagent's prompt answers no permission prompt of the parent's")
        #expect(sub.sessionID == "s", "session_id is documented as the parent's, so the event still lands on the parent and counts as its activity")
        #expect(sub.agentID == "agent-7")
        let blank = try #require(parse(#"{"hook_event_name":"UserPromptSubmit","session_id":"s","agent_id":""}"#))
        #expect(blank.event == "UserPromptSubmit", "an empty id is no id")

        var tracker = SessionTracker()
        let start = Date(timeIntervalSince1970: 1_788_300_000)
        tracker.apply(parent, now: start)
        tracker.apply(try #require(parse(#"{"hook_event_name":"SubagentStart","session_id":"s","agent_id":"agent-7"}"#)), now: start.addingTimeInterval(5))
        tracker.apply(sub, now: start.addingTimeInterval(6))
        let session = try #require(tracker.sessions[SessionTracker.key(tool: .codex, session: "s", host: nil)])
        #expect(session.turnStarted == start, "the parent's clock still reads from the user's prompt")
        #expect(session.lastEvent == start.addingTimeInterval(6), "and the subagent's prompt still counts as activity on the parent")
        #expect(Set(session.agents.keys) == ["agent-7"], "the subagent is counted once, from SubagentStart")
        let stop = try #require(parse(#"{"hook_event_name":"Stop","session_id":"s","cwd":"/Users/x/proj"}"#))
        #expect(tracker.apply(stop, now: start.addingTimeInterval(25)).finished?.turn == 25, "the turn is measured from the user's prompt, not the subagent's")
    }

    @Test func permissionModeRidesAlong() throws {
        let bypass = try #require(parse(#"{"hook_event_name":"UserPromptSubmit","session_id":"s","cwd":"/Users/x/proj","permission_mode":"bypassPermissions"}"#))
        #expect(bypass.permissionMode == "bypassPermissions")
        #expect(Hook.permissionBadge(bypass.permissionMode) != nil, "Codex's five modes are the vocabulary Claude Code's badge already renders")
        for mode in ["default", "acceptEdits", "plan", "dontAsk", "bypassPermissions"] {
            let message = try #require(parse("{\"hook_event_name\":\"Stop\",\"session_id\":\"s\",\"permission_mode\":\"\(mode)\"}"))
            #expect(message.permissionMode == mode, "\(mode)")
        }
        let end = try #require(parse(#"{"hook_event_name":"SessionEnd","session_id":"s","cwd":"/Users/x/proj","reason":"other","transcript_path":"/tmp/r.jsonl"}"#))
        #expect(end.event == "SessionEnd")
        #expect(end.permissionMode == nil, "SessionEnd's payload carries no permission_mode, and none is invented")
        let empty = try #require(parse(#"{"hook_event_name":"Stop","session_id":"s","permission_mode":""}"#))
        #expect(empty.permissionMode == nil)
    }

    @Test func onlyTheListedFieldsAreRead() throws {
        let json = #"{"session_id":"s","transcript_path":"/Users/x/.codex/sessions/r.jsonl","cwd":"/Users/x/proj","hook_event_name":"Stop","model":"gpt-5-codex","permission_mode":"plan","turn_id":"t9","stop_hook_active":true,"last_assistant_message":"secret","prompt":"also secret"}"#
        let message = try #require(parse(json))
        let info = message.userInfo
        #expect(Set(info.keys) == [Hook.eventKey, Hook.needsInputKey, Hook.sessionKey, Hook.projectKey, Hook.branchKey, Hook.permissionKey, Hook.toolKey])
        for key in ["model", "turn_id", "transcript_path", "prompt", "last_assistant_message", "stop_hook_active", "cwd"] {
            #expect(info[key] == nil, "\(key) is not read, and the working directory travels only as its basename")
        }
        #expect(info[Hook.projectKey] as? String == "proj")
        let permission = try #require(parse(#"{"hook_event_name":"PermissionRequest","session_id":"s","tool_name":"Bash","tool_input":{"command":"ls","description":"List files"}}"#))
        #expect(permission.userInfo["tool_name"] == nil)
        #expect(permission.userInfo["tool_input"] == nil)
        let nowhere = try #require(parse(#"{"hook_event_name":"Stop","session_id":"s","cwd":""}"#))
        #expect(nowhere.project == nil, "an empty cwd is skipped rather than read as the basename of nothing")
        #expect(nowhere.branch == nil)
        let blankSession = try #require(parse(#"{"hook_event_name":"Stop","session_id":""}"#))
        #expect(blankSession.sessionID == nil)
    }

    @Test func aCodexPayloadWithoutTheFlagReadsAsClaude() throws {
        // Codex's importer can copy the Claude Code entry into hooks.json on a plain --hook. The payload is
        // shaped like Claude Code's — same keys, same UpperCamel names — so nothing can tell them apart, and
        // those events light the Claude ring until Repair gives the entry its flag. This test documents the
        // hazard rather than a wish.
        let json = #"{"session_id":"s","cwd":"/Users/x/proj","hook_event_name":"Stop","model":"gpt-5-codex","permission_mode":"default","turn_id":"t1"}"#
        let message = try #require(parse(json, tool: nil))
        #expect(message.tool == .claude)
        #expect(message.userInfo[Hook.toolKey] == nil)
        let interrupt = try #require(parse(#"{"hook_event_name":"Interrupt","session_id":"s"}"#, tool: nil))
        #expect(interrupt.event == "Interrupt", "without the flag Claude Code's parser passes Codex's one foreign name through verbatim: no StopFailure, no tick, nothing")
        #expect(interrupt.failure == nil)
    }

    @Test func theFlagOutranksAClaudeShapedPayload() throws {
        let stopFailure = try #require(parse(#"{"hook_event_name":"StopFailure","session_id":"s","cwd":"/Users/x/proj","error":"rate_limit"}"#))
        #expect(stopFailure.tool == .codex)
        #expect(stopFailure.event == "StopFailure", "an unknown name passes through")
        #expect(stopFailure.failure == nil, "Codex documents no StopFailure and no error field, so a failure kind is never read from one; only Interrupt sets one")
        #expect(!stopFailure.hitRateLimit)
        let notification = try #require(parse(#"{"hook_event_name":"Notification","session_id":"s","notification_type":"permission_prompt"}"#))
        #expect(notification.tool == .codex)
        #expect(!notification.needsInput, "Codex has no Notification event; a Claude-shaped one under the Codex flag lights nothing")
        #expect(notification.notificationType == nil)
        let completed = try #require(parse(#"{"hook_event_name":"Notification","session_id":"s","notification_type":"agent_completed"}"#))
        #expect(!completed.clearsWaiting, "and none of Claude's completion types can end a Codex wait through it")
    }

    @Test func aRemotePostWithToolCodexIsCodexs() throws {
        let body = Data(#"{"hook_event_name":"Stop","session_id":"s","cwd":"/home/me/proj","tool":"codex","branch":"main","host":"devbox"}"#.utf8)
        let message = try #require(LocalAPI.hookMessage(from: body))
        #expect(message.tool == .codex, "a remote Codex payload is Claude-shaped, so the \"tool\" key the remote side adds is what says which ring it lights")
        #expect(message.event == "Stop")
        #expect(message.host == "devbox")
        #expect(message.project == "proj")
        #expect(message.branch == "main")
        let interrupt = try #require(LocalAPI.hookMessage(from: Data(#"{"hook_event_name":"Interrupt","session_id":"s","tool":"codex","host":"devbox"}"#.utf8)))
        #expect(interrupt.event == "StopFailure")
        #expect(interrupt.failure == "interrupted")
        #expect(interrupt.host == "devbox")
        let untagged = try #require(LocalAPI.hookMessage(from: Data(#"{"hook_event_name":"Stop","session_id":"s","cwd":"/home/me/proj","host":"devbox"}"#.utf8)))
        #expect(untagged.tool == .claude, "without the key it is Claude Code's, as it always was")
    }
}


/// The `hooks.json` installer for Codex: Claude Code's nested groups with Codex's own handler dictionaries (three
/// of them, by event) through the same merge, repair, status and install the Claude Code hook has, and the file's
/// place beside config.toml.
@Suite struct CodexHookInstallation {
    init() { Localization.use(language: "en") }

    let executable = "/Applications/Notchmeter.app/Contents/MacOS/Notchmeter"
    var expected: String { "'\(executable)' --hook --tool codex" }

    /// A hooks.json with every event Notchmeter registers, each carrying one group with one handler on `command`
    /// (the one an import from Claude Code's settings would write carries only `--hook`).
    func file(command: String, without missing: String? = nil) -> [String: Any] {
        var hooks: [String: Any] = [:]
        for event in HookVendor.codex.events where event != missing {
            hooks[event] = [["hooks": [HookVendor.codex.handler(command: command, event: event)]]]
        }
        return ["hooks": hooks]
    }

    @Test func snippetParsesAndPerEventHandlersDiffer() throws {
        let snippet = HookSettings.snippet(vendor: .codex, executable: "/Users/me/My Apps/Notchmeter.app/Contents/MacOS/Notchmeter")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(snippet.utf8)) as? [String: Any])
        #expect(root["version"] == nil, "Codex's file has no version key")
        #expect(root["description"] == nil, "and no description is invented")
        let hooks = try #require(root["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == Set(HookVendor.codex.events))
        for event in HookVendor.codex.events {
            let groups = try #require(hooks[event] as? [[String: Any]], "\(event)")
            #expect(groups.count == 1, "\(event)")
            let group = try #require(groups.first)
            #expect(Set(group.keys) == ["hooks"], "\(event): no matcher (omitted receives every source, reason and agent type)")
            let handlers = try #require(group["hooks"] as? [[String: Any]], "\(event)")
            #expect(handlers.count == 1, "\(event)")
            let handler = try #require(handlers.first)
            #expect(handler["type"] as? String == "command", "\(event)")
            #expect(handler["command"] as? String == "'/Users/me/My Apps/Notchmeter.app/Contents/MacOS/Notchmeter' --hook --tool codex", "\(event)")
            switch event {
            case "SessionEnd", "Interrupt":
                #expect(Set(handler.keys) == ["type", "command", "timeout"], "\(event) always runs synchronously, so async would be a lie")
                #expect(handler["timeout"] as? Int == 3, "\(event): the documented cap is 3 s")
            case "PermissionRequest":
                #expect(Set(handler.keys) == ["type", "command", "timeout"], "\(event) stays synchronous: an async hook's output lands at the next safe point, which may be after the prompt is drawn")
                #expect(handler["timeout"] as? Int == 5, "\(event)")
            default:
                #expect(Set(handler.keys) == ["type", "command", "async", "timeout"], "\(event)")
                #expect(handler["async"] as? Bool == true, "\(event)")
                #expect(handler["timeout"] as? Int == 5, "\(event): seconds, not Gemini's milliseconds")
            }
        }
        #expect(HookVendor.codex.flag == "--hook --tool codex")
        #expect(HookVendor.codex.flag(for: "Stop") == "--hook --tool codex", "only Copilot's flag names the event")
        #expect(HookVendor.codex.fileName == "hooks.json")
        #expect(HookVendor.codex.shape == .nestedGroups)
        #expect(HookVendor.codex.displayName == "Codex")
        #expect(HookVendor.codex.tool == .codex)
        #expect(!HookVendor.codex.reloadsLive, "hooks.json is read when a session starts, and a new entry waits for trust in /hooks")
        #expect(HookVendor.vendor(for: .codex) == .codex)
        #expect(HookSettings.executable(in: expected) == executable, "status reads the path back out of the longer command")
        #expect(HookSettings.snippet(vendor: .codex, executable: executable) == HookSettings.snippet(vendor: .codex, executable: executable))
    }

    @Test func mergeKeepsDescriptionAndForeignMatcherGroupsAndIsIdempotent() throws {
        let foreignGroup: [String: Any] = [
            "matcher": "startup|resume",
            "hooks": [["type": "command", "command": "python3 ~/.codex/hooks/session_start.py", "statusMessage": "Loading session notes", "additionalContextLimit": 5000]],
        ]
        let existing: [String: Any] = [
            "description": "Optional lifecycle hooks for this workspace.",
            "hooks": [
                "SessionStart": [foreignGroup],
                "Stop": [["hooks": [["type": "mcp_tool", "server": "notes", "tool": "record"]]]],
                "SessionEnd": "not an array",
                "PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "/usr/local/bin/guard.sh"]]]],
            ],
        ]
        let first = HookSettings.merge(into: existing, vendor: .codex, executable: executable)
        #expect(first.added == ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Stop", "Interrupt", "SubagentStart", "SubagentStop"])
        #expect(first.present == ["SessionEnd"], "a value that is not an array is left alone rather than replaced")
        #expect(first.settings["description"] as? String == "Optional lifecycle hooks for this workspace.", "Codex's top-level description is the user's and is kept")
        #expect(first.settings["version"] == nil, "Codex's file wants no version key, and none is added")
        let hooks = try #require(first.settings["hooks"] as? [String: Any])
        let start = try #require(hooks["SessionStart"] as? [[String: Any]])
        #expect(start.count == 2)
        #expect(NSDictionary(dictionary: start[0]) == NSDictionary(dictionary: foreignGroup), "the matcher group is structurally what it was")
        #expect(NSDictionary(dictionary: start[1]) == NSDictionary(dictionary: ["hooks": [HookVendor.codex.handler(command: expected, event: "SessionStart")]]))
        let stop = try #require(hooks["Stop"] as? [[String: Any]])
        #expect(stop.count == 2)
        #expect((stop[0]["hooks"] as? [[String: Any]])?.first?["type"] as? String == "mcp_tool", "an mcp_tool handler is never ours and is never touched")
        let interrupt = try #require(hooks["Interrupt"] as? [[String: Any]])
        let interruptHandler = try #require((interrupt.first?["hooks"] as? [[String: Any]])?.first)
        #expect(interruptHandler["timeout"] as? Int == 3)
        #expect(interruptHandler["async"] == nil)
        #expect(hooks["SessionEnd"] as? String == "not an array")
        #expect((hooks["PreToolUse"] as? [[String: Any]])?.count == 1, "events Notchmeter does not register are not visited")

        let second = HookSettings.merge(into: first.settings, vendor: .codex, executable: "/somewhere/else/Notchmeter")
        #expect(second.added.isEmpty)
        #expect(Set(second.present) == Set(HookVendor.codex.events))
        #expect(NSDictionary(dictionary: second.settings) == NSDictionary(dictionary: first.settings))

        let fresh = HookSettings.merge(into: [:], vendor: .codex, executable: executable)
        #expect(fresh.added == HookVendor.codex.events)
        #expect(Set(fresh.settings.keys) == ["hooks"], "a new file is the hooks object and nothing else")
    }

    @Test func statusPartialOnPlainHookAndRepairAddsTheFlag() {
        #expect(HookSettings.status(settings: [:], vendor: .codex, executable: executable) == .notInstalled)
        #expect(HookSettings.status(settings: ["hooks": ["PreToolUse": [["hooks": [["type": "command", "command": expected]]]]]], vendor: .codex, executable: executable) == .notInstalled,
                "an entry under an event Notchmeter does not register does not count")
        #expect(HookSettings.status(settings: file(command: expected), vendor: .codex, executable: executable) == .installed(path: executable))
        #expect(!HookSettings.status(settings: file(command: expected), vendor: .codex, executable: executable).needsRepair)
        let other = "/Users/me/Downloads/Notchmeter.app/Contents/MacOS/Notchmeter"
        let moved = HookSettings.status(settings: file(command: "'\(other)' --hook --tool codex"), vendor: .codex, executable: executable)
        #expect(moved == .stale(path: other))
        #expect(moved.needsRepair)
        let missing = HookSettings.status(settings: file(command: expected, without: "Interrupt"), vendor: .codex, executable: executable)
        #expect(missing == .partial(path: executable), "the right path with an event missing is out of date, not pointing at an old copy")
        #expect(missing.needsRepair)
        #expect(missing.text == "Installed, but an entry is out of date: Repair updates it")
        // The imported file: Codex's importer copies the Claude Code entry across on a plain --hook, whose events
        // light the Claude ring because the payload cannot say otherwise.
        let plain = HookSettings.status(settings: file(command: "'\(executable)' --hook"), vendor: .codex, executable: executable)
        #expect(plain == .partial(path: executable), "a plain --hook reads as Claude's, so Repair must upgrade it")
        #expect(plain.needsRepair)
        let decorated = HookSettings.status(settings: file(command: "\(expected) 2>/dev/null"), vendor: .codex, executable: executable)
        #expect(decorated == .installed(path: executable), "the path and the flag are what count; a redirect the user added is theirs to keep")
        let cursor = HookSettings.status(settings: file(command: "'\(executable)' --hook --tool cursor"), vendor: .codex, executable: executable)
        #expect(cursor == .partial(path: executable), "another vendor's flag in Codex's file is out of date, not installed")

        let eight = HookSettings.repair(file(command: "'\(executable)' --hook"), vendor: .codex, executable: executable)
        #expect(eight.repaired == HookVendor.codex.events, "every plain entry at the right path is rewritten to carry the flag, in the vendor's order")
        #expect(eight.added.isEmpty)
        #expect(HookSettings.status(settings: eight.settings, vendor: .codex, executable: executable) == .installed(path: executable))
        let again = HookSettings.repair(eight.settings, vendor: .codex, executable: executable)
        #expect(again.repaired.isEmpty)
        #expect(again.added.isEmpty)
        #expect(NSDictionary(dictionary: again.settings) == NSDictionary(dictionary: eight.settings))
    }

    @Test func repairRewritesOnlyTheCommand() throws {
        var settings = file(command: "'\(executable)' --hook", without: "SubagentStop")
        var hooks = try #require(settings["hooks"] as? [String: Any])
        // A user who tuned our Stop handler by hand, beside a foreign handler in the same group and a foreign
        // group of their own.
        let ours: [String: Any] = ["type": "command", "command": "'\(executable)' --hook", "async": false, "timeout": 30, "statusMessage": "Notchmeter"]
        let neighbour: [String: Any] = ["type": "command", "command": "/usr/local/bin/worklog.sh", "timeout": 15]
        let foreignGroup: [String: Any] = ["matcher": "^compact$", "hooks": [["type": "command", "command": "python3 ~/.codex/hooks/compact.py"]]]
        hooks["Stop"] = [foreignGroup, ["hooks": [neighbour, ours]]]
        hooks["SessionStart"] = [foreignGroup, ["matcher": "startup", "hooks": [["type": "command", "command": "'\(executable)' --hook", "async": true, "timeout": 5]]]]
        settings["hooks"] = hooks
        let repaired = HookSettings.repair(settings, vendor: .codex, executable: executable)
        #expect(repaired.repaired == ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Stop", "Interrupt", "SubagentStart", "SessionEnd"])
        #expect(repaired.added == ["SubagentStop"])
        #expect(HookSettings.status(settings: repaired.settings, vendor: .codex, executable: executable) == .installed(path: executable))
        let written = try #require(repaired.settings["hooks"] as? [String: Any])
        let stop = try #require(written["Stop"] as? [[String: Any]])
        #expect(stop.count == 2)
        #expect(NSDictionary(dictionary: stop[0]) == NSDictionary(dictionary: foreignGroup), "the foreign group is structurally what it was")
        let handlers = try #require(stop[1]["hooks"] as? [[String: Any]])
        #expect(handlers.count == 2)
        #expect(NSDictionary(dictionary: handlers[0]) == NSDictionary(dictionary: neighbour), "a foreign handler in our group is untouched")
        var rewritten = ours
        rewritten["command"] = expected
        #expect(NSDictionary(dictionary: handlers[1]) == NSDictionary(dictionary: rewritten), "only the command changes: async, timeout and statusMessage are the user's")
        let start = try #require(written["SessionStart"] as? [[String: Any]])
        #expect(start[1]["matcher"] as? String == "startup", "a matcher the user put on our group is kept")
        #expect((start[1]["hooks"] as? [[String: Any]])?.first?["command"] as? String == expected)
        let added = try #require((written["SubagentStop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
        #expect(NSDictionary(dictionary: added[0]) == NSDictionary(dictionary: HookVendor.codex.handler(command: expected, event: "SubagentStop")))
        for event in HookVendor.codex.events {
            let groups = try #require(written[event] as? [[String: Any]], "\(event)")
            #expect(groups.contains { ($0["hooks"] as? [[String: Any]])?.contains { $0["command"] as? String == expected } == true }, "\(event)")
        }
    }

    @Test func installBacksUpAndPreservesPermissions() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("notchmeter-codex-hook-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let now = Date(timeIntervalSince1970: 1_788_300_000)

        let missing = dir.appendingPathComponent("fresh/.codex/hooks.json")
        let created = try HookSettings.install(vendor: .codex, at: missing, executable: executable, now: now)
        #expect(created.backup == nil)
        #expect(created.added == HookVendor.codex.events)
        #expect(fm.fileExists(atPath: missing.path), "the folder is created for a Codex home that has no hooks.json yet")
        let fresh = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: missing)) as? [String: Any])
        #expect(Set(fresh.keys) == ["hooks"])
        #expect(HookSettings.status(vendor: .codex, at: missing, executable: executable) == .installed(path: executable))
        #expect(!(try String(contentsOf: missing, encoding: .utf8)).contains("\\/"))

        let url = dir.appendingPathComponent("hooks.json")
        let original = #"{"description":"Mine.","hooks":{"Stop":[{"hooks":[{"type":"command","command":"python3 ~/.codex/hooks/stop.py","timeout":30}]}]}}"#
        try Data(original.utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let installed = try HookSettings.install(vendor: .codex, at: url, executable: executable, now: now)
        #expect(installed.added == HookVendor.codex.events)
        let backup = try #require(installed.backup)
        #expect(backup.lastPathComponent.hasPrefix("hooks.json.bak-2026"))
        #expect(backup.lastPathComponent.range(of: #"^hooks\.json\.bak-\d{8}-\d{6}$"#, options: .regularExpression) != nil)
        #expect(try String(contentsOf: backup, encoding: .utf8) == original)
        #expect((try fm.attributesOfItem(atPath: url.path))[.posixPermissions] as? Int == 0o600)
        let written = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(written["description"] as? String == "Mine.")
        let stop = try #require((written["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        #expect(stop.count == 2)
        #expect((stop[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String == "python3 ~/.codex/hooks/stop.py")

        let again = try HookSettings.install(vendor: .codex, at: url, executable: executable, now: now.addingTimeInterval(60))
        #expect(again.added.isEmpty)
        #expect(again.backup == nil)
        #expect(try fm.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".bak-") }.count == 1)

        // The imported case at launch: a plain --hook file is repaired to carry the flag, once.
        try JSONSerialization.data(withJSONObject: file(command: "'\(executable)' --hook")).write(to: url)
        #expect(HookSettings.status(vendor: .codex, at: url, executable: executable) == .partial(path: executable))
        let repaired = try HookSettings.repairInstall(vendor: .codex, at: url, executable: executable, now: now.addingTimeInterval(120))
        #expect(repaired.backup != nil)
        #expect(repaired.added.count == 8)
        #expect(HookSettings.status(vendor: .codex, at: url, executable: executable) == .installed(path: executable))
        #expect(try HookSettings.repairInstall(vendor: .codex, at: url, executable: executable, now: now.addingTimeInterval(180)).backup == nil)
        #expect(try fm.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".bak-") }.count == 2)

        try Data("[]".utf8).write(to: url)
        #expect(throws: HookSettings.Failure.self) {
            try HookSettings.install(vendor: .codex, at: url, executable: executable, now: now)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "[]")
    }

    @Test func fileURLFollowsCodexHome() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("notchmeter-codex-home-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        // TERM is set so ProcessEnvironment.value stays inside the dictionary: without it, a missing CODEX_HOME
        // would be looked up in launchd's environment, and a developer who exported one there would fail this test.
        let shell = ["TERM": "xterm"]
        #expect(HookVendor.codex.fileURL(environment: shell.merging(["CODEX_HOME": "/srv/codex"]) { $1 }, home: home).path == "/srv/codex/hooks.json",
                "CODEX_HOME is the root of Codex's state, and hooks.json sits beside config.toml in it")
        #expect(HookVendor.codex.fileURL(environment: shell.merging(["CODEX_HOME": "~/codex"]) { $1 }, home: home).path == ("~/codex/hooks.json" as NSString).expandingTildeInPath)
        #expect(HookVendor.codex.fileURL(environment: shell.merging(["CODEX_HOME": ""]) { $1 }, home: home).path == home.appendingPathComponent(".codex/hooks.json").path,
                "an empty override is no override")
        #expect(HookVendor.codex.fileURL(environment: shell, home: home).path == home.appendingPathComponent(".codex/hooks.json").path,
                "without ~/.config/codex the default is ~/.codex, as it is for Codex")
        try fm.createDirectory(at: home.appendingPathComponent(".config/codex"), withIntermediateDirectories: true)
        #expect(HookVendor.codex.fileURL(environment: shell, home: home).path == home.appendingPathComponent(".codex/hooks.json").path,
                "Codex resolves $CODEX_HOME, else ~/.codex, and nothing else: an XDG-style folder that exists must not draw the file to a place Codex never reads")
        #expect(HookVendor.codex.fileURL(environment: shell.merging(["CODEX_HOME": "/srv/codex"]) { $1 }, home: home).path == "/srv/codex/hooks.json",
                "and CODEX_HOME still outranks both")
        #expect(HookVendor.codex.fileURL.path.hasSuffix("/hooks.json"))
    }
}
