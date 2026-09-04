import Foundation
import Testing
@testable import Notchmeter

/// Cursor's hook read onto the same Message Claude Code's fills: how its lowerCamel names land on the tracker's
/// vocabulary, which of its fields are read, and the one thing it must never say. Every test here parses the JSON
/// Cursor documents at cursor.com/docs/agent/hooks rather than a Message built by hand, because the parser is the
/// whole feature: above it nothing knows Cursor exists.
@Suite struct CursorHookMessages {
    /// The branch closure stands in for `.git/HEAD`: it answers only for the root the payload names, so a branch
    /// on the message proves the parser asked about the right folder.
    func parse(_ json: String, tool: ToolID? = nil, environment: [String: String] = [:]) -> Hook.Message? {
        Hook.message(from: Data(json.utf8), tool: tool, environment: environment, branch: { $0 == "/Users/x/proj" ? "main" : nil })
    }

    @Test func sessionStartReadsAsCursorByShape() throws {
        let json = #"{"hook_event_name":"sessionStart","conversation_id":"c1","session_id":"c1","cursor_version":"1.7.2","workspace_roots":["/Users/x/proj"],"is_background_agent":false}"#
        let message = try #require(parse(json))
        #expect(message == Hook.Message(event: "SessionStart", needsInput: false, sessionID: "c1", project: "proj", branch: "main", tool: .cursor),
                "A plain --hook with no flag still reads as Cursor's: the conversation id and the version are shapes Claude Code never sends.")
        #expect(message.userInfo[Hook.toolKey] as? String == "cursor")
        #expect(Hook.Message(userInfo: message.userInfo) == message, "the tool survives the notification payload, or the store would light Claude's ring")
    }

    @Test func promptSendsStartATurn() throws {
        let message = try #require(parse(#"{"hook_event_name":"beforeSubmitPrompt","conversation_id":"c1","prompt":"fix the tests"}"#))
        #expect(message.event == "UserPromptSubmit")
        #expect(message.tool == .cursor)
        #expect(message.sessionID == "c1")
    }

    @Test func stopStatusesDecideBetweenAFinishAndAStopFailure() throws {
        let completed = try #require(parse(#"{"hook_event_name":"stop","conversation_id":"c1","status":"completed"}"#))
        #expect(completed.event == "Stop")
        #expect(completed.failure == nil)
        let aborted = try #require(parse(#"{"hook_event_name":"stop","conversation_id":"c1","status":"aborted"}"#))
        #expect(aborted.event == "StopFailure")
        #expect(aborted.failure == "aborted")
        let errored = try #require(parse(#"{"hook_event_name":"stop","conversation_id":"c1","status":"error"}"#))
        #expect(errored.event == "StopFailure")
        #expect(errored.failure == "error")
        let absent = try #require(parse(#"{"hook_event_name":"stop","conversation_id":"c1"}"#))
        #expect(absent.event == "StopFailure", "a stop that does not say it completed is not a finish; the tick asserts only what a documented signal proves")
        #expect(absent.failure == nil)
        for message in [completed, aborted, errored, absent] {
            #expect(!message.hitRateLimit, "Cursor has no rate-limit event, so none of its stops may plan a limit-hit alert")
            #expect(message.clearsWaiting)
        }
    }

    @Test func sessionEndAndSubagentsMap() throws {
        let end = try #require(parse(#"{"hook_event_name":"sessionEnd","conversation_id":"c1","reason":"user_exit"}"#))
        #expect(end.event == "SessionEnd")
        let start = try #require(parse(#"{"hook_event_name":"subagentStart","conversation_id":"c1","subagent_id":"abc-123"}"#))
        #expect(start.event == "SubagentStart")
        #expect(start.agentID == "abc-123")
        let stop = try #require(parse(#"{"hook_event_name":"subagentStop","conversation_id":"c1"}"#))
        #expect(stop.event == "SubagentStop")
        #expect(stop.agentID == nil, "subagentStop documents no id, so the tracker falls back to dropping its oldest agent")
        // The reference sends parent_conversation_id beside the common conversation_id on subagentStart without
        // saying whose the common one is; the parent is the session either way, or each subagent would open a
        // phantom conversation that the card counts and nothing ends.
        let nested = try #require(parse(#"{"hook_event_name":"subagentStart","conversation_id":"sub-1","parent_conversation_id":"c1","subagent_id":"abc-123"}"#))
        #expect(nested.sessionID == "c1", "the subagent's agent count belongs to the conversation that started it")
        #expect(nested.agentID == "abc-123")
    }

    @Test func noCursorEventEverNeedsInput() throws {
        let mapped = Set(Hook.Cursor.events.keys).union(["stop"])
        for name in Hook.Cursor.knownEvents.sorted() {
            let message = try #require(parse("{\"hook_event_name\":\"\(name)\",\"conversation_id\":\"c1\"}"))
            #expect(!message.needsInput,
                    "\(name): Cursor documents no event that says it is waiting for you (its Claude-compat page marks Notification and PermissionRequest unsupported), and beforeShellExecution fires whether or not the user will be asked, so a hand lit here would be false most of the time")
            #expect(message.tool == .cursor)
            guard !mapped.contains(name) else { continue }
            #expect(message.event == name, "an event the tracker has no case for passes through verbatim and does nothing")
            #expect(!message.clearsWaiting, "\(name) must not end a wait either, because nothing Cursor sends can have started one")
        }
    }

    @Test func theProjectFallsBackToTheEnvironment() throws {
        let environment = ["CURSOR_PROJECT_DIR": "/Users/x/proj"]
        let fromEnvironment = try #require(parse(#"{"hook_event_name":"stop","conversation_id":"c1","status":"completed"}"#, environment: environment))
        #expect(fromEnvironment.project == "proj", "session, prompt and stop events carry no cwd; the environment Cursor gives its hook is the last resort")
        #expect(fromEnvironment.branch == "main")
        let claude = try #require(parse(#"{"hook_event_name":"Stop","session_id":"s"}"#, environment: environment))
        #expect(claude.tool == .claude)
        #expect(claude.project == nil, "Claude Code's parser reads cwd and nothing else; a Cursor variable in the environment is not its folder")
        let blank = try #require(parse(#"{"hook_event_name":"stop","conversation_id":"c1","status":"completed","workspace_roots":[""]}"#, environment: environment))
        #expect(blank.project == "proj", "an empty root is skipped rather than read as the basename of nothing")
        let nowhere = try #require(parse(#"{"hook_event_name":"stop","conversation_id":"c1","status":"completed","workspace_roots":[""]}"#))
        #expect(nowhere.project == nil)
        let cwd = try #require(parse(#"{"hook_event_name":"afterFileEdit","conversation_id":"c1","cwd":"/Users/x/proj"}"#))
        #expect(cwd.project == "proj")
    }

    @Test func aClaudeNamedEventWithAConversationIdIsCursors() throws {
        // With "Include third-party Plugins, Skills, and other configs" on, Cursor also runs the entry in
        // ~/.claude/settings.json and sends Claude's names with its own ids; the shape tags it Cursor's.
        let replay = try #require(parse(#"{"hook_event_name":"Stop","conversation_id":"c","status":"completed"}"#))
        #expect(replay.tool == .cursor)
        #expect(replay.event == "Stop")
        #expect(replay.sessionID == "c")
    }

    @Test func aRemotePostIsTaggedByShape() throws {
        let body = Data(#"{"hook_event_name":"stop","conversation_id":"c1","status":"completed","workspace_roots":["/home/me/proj"],"branch":"main","host":"devbox"}"#.utf8)
        let message = try #require(LocalAPI.hookMessage(from: body))
        #expect(message.tool == .cursor, "a remote Cursor payload needs no \"tool\" key: its shape says which ring it lights")
        #expect(message.event == "Stop")
        #expect(message.host == "devbox")
        #expect(message.project == "proj")
        #expect(message.branch == "main")
    }
}


/// The `~/.cursor/hooks.json` installer: Cursor's flat `{command}` entries and its `version` key through the same
/// merge, repair, status and install the Claude Code hook has, and the two states Repair exists for.
@Suite struct CursorHookInstallation {
    init() { Localization.use(language: "en") }

    let executable = "/Applications/Notchmeter.app/Contents/MacOS/Notchmeter"
    var expected: String { "'\(executable)' --hook --tool cursor" }

    /// A hooks.json with every event Notchmeter registers, each carrying `command` (the one the other account
    /// wrote by hand carries only `--hook`).
    func file(command: String, version: Any? = 1, without missing: String? = nil) -> [String: Any] {
        var hooks: [String: Any] = [:]
        for event in HookVendor.cursor.events where event != missing {
            hooks[event] = [["command": command]]
        }
        var settings: [String: Any] = ["hooks": hooks]
        if let version { settings["version"] = version }
        return settings
    }

    @Test func snippetIsCursorsShapeForEveryEvent() throws {
        let snippet = HookSettings.snippet(vendor: .cursor, executable: "/Users/me/My Apps/Notchmeter.app/Contents/MacOS/Notchmeter")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(snippet.utf8)) as? [String: Any])
        #expect(root["version"] as? Int == 1)
        let hooks = try #require(root["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == Set(HookVendor.cursor.events))
        for event in HookVendor.cursor.events {
            let entries = try #require(hooks[event] as? [[String: Any]], "\(event)")
            #expect(entries.count == 1)
            let entry = try #require(entries.first)
            #expect(Set(entry.keys) == ["command"],
                    "\(event): no type (Cursor has none), no timeout (the command exits in under 50 ms), no hooks array (Cursor's entries are flat)")
            #expect(entry["command"] as? String == "'/Users/me/My Apps/Notchmeter.app/Contents/MacOS/Notchmeter' --hook --tool cursor")
        }
        #expect(HookVendor.cursor.flag == "--hook --tool cursor")
        #expect(HookVendor.cursor.fileName == "hooks.json")
        #expect(HookVendor.cursor.fileURL.path.hasSuffix("/.cursor/hooks.json"))
        #expect(HookVendor.vendor(for: .cursor) == .cursor)
        #expect(HookVendor.vendor(for: .codex) == .codex)
        #expect(HookVendor.vendor(for: .antigravity) == .antigravity, "Gemini CLI's hook lights the Antigravity ring")
        #expect(HookVendor.vendor(for: .copilot) == .copilot)
        #expect(HookVendor.allCases.map(\.tool) == ToolID.allCases, "every ring has a hook now, in the rings' order")
        #expect(HookSettings.executable(in: expected) == executable, "status reads the path back out of the longer command")
    }

    @Test func mergeKeepsForeignEntriesAndTheVersionAndIsIdempotent() throws {
        let existing: [String: Any] = [
            "version": 2,
            "hooks": [
                "stop": [["command": "/usr/local/bin/worklog.sh", "matcher": "*", "timeout": 15]],
                "beforeSubmitPrompt": [["type": "prompt", "prompt": "Is this safe?"]],
                "sessionEnd": "not an array",
                "beforeShellExecution": [["command": "/usr/local/bin/guard.sh"]],
            ],
        ]
        let first = HookSettings.merge(into: existing, vendor: .cursor, executable: executable)
        #expect(first.added == ["sessionStart", "beforeSubmitPrompt", "stop", "subagentStart", "subagentStop"])
        #expect(first.present == ["sessionEnd"], "a value that is not an array is left alone rather than replaced")
        #expect(first.settings["version"] as? Int == 2, "an existing version is never overwritten")
        let hooks = try #require(first.settings["hooks"] as? [String: Any])
        let stop = try #require(hooks["stop"] as? [[String: Any]])
        #expect(stop.count == 2)
        #expect(stop[0]["command"] as? String == "/usr/local/bin/worklog.sh")
        #expect(stop[0]["matcher"] as? String == "*")
        #expect(stop[0]["timeout"] as? Int == 15)
        #expect(NSDictionary(dictionary: stop[1]) == NSDictionary(dictionary: ["command": expected]))
        let prompt = try #require(hooks["beforeSubmitPrompt"] as? [[String: Any]])
        #expect(prompt.count == 2)
        #expect(prompt[0]["type"] as? String == "prompt", "a prompt-type entry is never ours and is never touched")
        #expect(hooks["sessionEnd"] as? String == "not an array")
        #expect((hooks["beforeShellExecution"] as? [[String: Any]])?.count == 1, "events Notchmeter does not register are not visited")

        let second = HookSettings.merge(into: first.settings, vendor: .cursor, executable: "/somewhere/else/Notchmeter")
        #expect(second.added.isEmpty)
        #expect(Set(second.present) == Set(HookVendor.cursor.events))
        #expect(NSDictionary(dictionary: second.settings) == NSDictionary(dictionary: first.settings))

        let fresh = HookSettings.merge(into: [:], vendor: .cursor, executable: executable)
        #expect(fresh.settings["version"] as? Int == 1, "Cursor wants a version at the root; a new file gets 1")
        #expect(fresh.added == HookVendor.cursor.events)
        let claude = HookSettings.merge(into: [:], executable: executable)
        #expect(claude.settings["version"] == nil, "Claude Code's file has no version key and its output does not change")
    }

    @Test func statusTellsMissingFromMovedFromOutOfDate() {
        #expect(HookSettings.status(settings: [:], vendor: .cursor, executable: executable) == .notInstalled)
        #expect(HookSettings.status(settings: ["hooks": ["beforeShellExecution": [["command": expected]]]], vendor: .cursor, executable: executable) == .notInstalled,
                "an entry under an event Notchmeter does not register does not count")
        #expect(HookSettings.status(settings: file(command: expected), vendor: .cursor, executable: executable) == .installed(path: executable))
        #expect(!HookSettings.status(settings: file(command: expected), vendor: .cursor, executable: executable).needsRepair)
        let other = "/Users/me/Downloads/Notchmeter.app/Contents/MacOS/Notchmeter"
        let moved = HookSettings.status(settings: file(command: "'\(other)' --hook --tool cursor"), vendor: .cursor, executable: executable)
        #expect(moved == .stale(path: other))
        #expect(moved.needsRepair)
        let missing = HookSettings.status(settings: file(command: expected, without: "subagentStop"), vendor: .cursor, executable: executable)
        #expect(missing == .partial(path: executable), "the right path with an event missing is out of date, not pointing at an old copy")
        #expect(missing.needsRepair)
        #expect(missing.text == "Installed, but an entry is out of date: Repair updates it")
        // The other account's file: six entries at the right path, written by hand before the flag existed.
        let plain = HookSettings.status(settings: file(command: "'\(executable)' --hook"), vendor: .cursor, executable: executable)
        #expect(plain == .partial(path: executable), "a plain --hook still works (the shape tags the payload) but Repair upgrades it")
        #expect(plain.needsRepair)
        let decorated = HookSettings.status(settings: file(command: "\(expected) 2>/dev/null"), vendor: .cursor, executable: executable)
        #expect(decorated == .installed(path: executable), "the path and the flag are what count; a redirect the user added is theirs to keep, not the launch repair's to strip")
    }

    @Test func repairRewritesPlainEntriesAddsMissingEventsAndLeavesForeignOnesAlone() throws {
        var settings = file(command: "'\(executable)' --hook", without: "subagentStop")
        var hooks = try #require(settings["hooks"] as? [String: Any])
        let foreign: [String: Any] = ["command": "/usr/local/bin/worklog.sh", "matcher": "*", "timeout": 15]
        hooks["stop"] = [foreign, ["command": "'\(executable)' --hook"]]
        settings["hooks"] = hooks
        let repaired = HookSettings.repair(settings, vendor: .cursor, executable: executable)
        #expect(repaired.repaired == ["sessionStart", "beforeSubmitPrompt", "stop", "subagentStart", "sessionEnd"])
        #expect(repaired.added == ["subagentStop"])
        #expect(HookSettings.status(settings: repaired.settings, vendor: .cursor, executable: executable) == .installed(path: executable))
        let written = try #require(repaired.settings["hooks"] as? [String: Any])
        let stop = try #require(written["stop"] as? [[String: Any]])
        #expect(NSDictionary(dictionary: stop[0]) == NSDictionary(dictionary: foreign), "the foreign entry is structurally what it was")
        #expect(stop[1]["command"] as? String == expected)
        #expect(Set(stop[1].keys) == ["command"])
        for event in HookVendor.cursor.events {
            let entries = try #require(written[event] as? [[String: Any]], "\(event)")
            #expect(entries.contains { $0["command"] as? String == expected }, "\(event)")
        }

        let six = HookSettings.repair(file(command: "'\(executable)' --hook"), vendor: .cursor, executable: executable)
        #expect(six.repaired.count == 6, "every plain entry at the right path is rewritten to carry the flag")
        #expect(six.added.isEmpty)
        let again = HookSettings.repair(six.settings, vendor: .cursor, executable: executable)
        #expect(again.repaired.isEmpty)
        #expect(again.added.isEmpty)
        #expect(NSDictionary(dictionary: again.settings) == NSDictionary(dictionary: six.settings))
    }

    @Test func installWritesHooksJSONBacksItUpAndKeepsPermissions() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("notchmeter-cursor-hook-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let now = Date(timeIntervalSince1970: 1_788_300_000)

        let missing = dir.appendingPathComponent("fresh/.cursor/hooks.json")
        let created = try HookSettings.install(vendor: .cursor, at: missing, executable: executable, now: now)
        #expect(created.backup == nil)
        #expect(created.added == HookVendor.cursor.events)
        #expect(fm.fileExists(atPath: missing.path))
        let fresh = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: missing)) as? [String: Any])
        #expect(fresh["version"] as? Int == 1)
        #expect(HookSettings.status(vendor: .cursor, at: missing, executable: executable) == .installed(path: executable))
        #expect(!(try String(contentsOf: missing, encoding: .utf8)).contains("\\/"))

        let url = dir.appendingPathComponent("hooks.json")
        let original = #"{"version":1,"hooks":{"stop":[{"command":"/usr/local/bin/worklog.sh"}]}}"#
        try Data(original.utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let installed = try HookSettings.install(vendor: .cursor, at: url, executable: executable, now: now)
        #expect(installed.added == HookVendor.cursor.events)
        let backup = try #require(installed.backup)
        #expect(backup.lastPathComponent.hasPrefix("hooks.json.bak-2026"))
        #expect(backup.lastPathComponent.range(of: #"^hooks\.json\.bak-\d{8}-\d{6}$"#, options: .regularExpression) != nil)
        #expect(try String(contentsOf: backup, encoding: .utf8) == original)
        #expect((try fm.attributesOfItem(atPath: url.path))[.posixPermissions] as? Int == 0o600)
        let written = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let stop = try #require((written["hooks"] as? [String: Any])?["stop"] as? [[String: Any]])
        #expect(stop.count == 2)
        #expect(stop[0]["command"] as? String == "/usr/local/bin/worklog.sh")

        let again = try HookSettings.install(vendor: .cursor, at: url, executable: executable, now: now.addingTimeInterval(60))
        #expect(again.added.isEmpty)
        #expect(again.backup == nil)
        #expect(try fm.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".bak-") }.count == 1)

        // The other account's case at launch: a plain --hook file is repaired to carry the flag, once.
        try JSONSerialization.data(withJSONObject: file(command: "'\(executable)' --hook")).write(to: url)
        #expect(HookSettings.status(vendor: .cursor, at: url, executable: executable) == .partial(path: executable))
        let repaired = try HookSettings.repairInstall(vendor: .cursor, at: url, executable: executable, now: now.addingTimeInterval(120))
        #expect(repaired.backup != nil)
        #expect(repaired.added.count == 6)
        #expect(HookSettings.status(vendor: .cursor, at: url, executable: executable) == .installed(path: executable))
        #expect(try HookSettings.repairInstall(vendor: .cursor, at: url, executable: executable, now: now.addingTimeInterval(180)).backup == nil)
        #expect(try fm.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".bak-") }.count == 2)

        try Data("[]".utf8).write(to: url)
        #expect(throws: HookSettings.Failure.self) {
            try HookSettings.install(vendor: .cursor, at: url, executable: executable, now: now)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "[]")
    }
}
