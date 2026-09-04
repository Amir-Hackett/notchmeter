import Foundation
import Testing
@testable import Notchmeter

/// Gemini CLI's hook read onto the same Message Claude Code's fills, lighting the Antigravity ring: how its five
/// registered names land on the tracker's vocabulary, which of its fields are read, and the one signal that may
/// light the hand. Every test here parses the JSON Gemini documents at geminicli.com/docs/hooks/reference rather
/// than a Message built by hand, because the parser is the whole feature: above it nothing knows Gemini exists.
@Suite struct GeminiHookMessages {
    /// The branch closure stands in for `.git/HEAD`: it answers only for the root the payload names, so a branch
    /// on the message proves the parser asked about the right folder.
    func parse(_ json: String, tool: ToolID? = .antigravity, environment: [String: String] = [:]) -> Hook.Message? {
        Hook.message(from: Data(json.utf8), tool: tool, environment: environment, branch: { $0 == "/Users/x/proj" ? "main" : nil })
    }

    /// Every event the reference documents, with the extra fields each carries.
    static let documented: [(event: String, extra: String)] = [
        ("SessionStart", #""source":"startup""#), ("SessionEnd", #""reason":"exit""#),
        ("BeforeAgent", #""prompt":"fix the tests""#), ("AfterAgent", #""prompt":"fix the tests","prompt_response":"done","stop_hook_active":false"#),
        ("BeforeModel", #""llm_request":{}"#), ("AfterModel", #""llm_response":{}"#), ("BeforeToolSelection", #""llm_request":{}"#),
        ("BeforeTool", #""tool_name":"write_file","tool_input":{}"#), ("AfterTool", #""tool_name":"write_file","tool_input":{},"tool_response":{}"#),
        ("PreCompress", #""trigger":"auto""#), ("Notification", #""notification_type":"ToolPermission","message":"Tool write_file requires editing","details":{}"#),
    ]

    func payload(_ event: String, extra: String = "", session: String = "s1") -> String {
        #"{"hook_event_name":"\#(event)","session_id":"\#(session)","transcript_path":"/Users/x/.gemini/tmp/t.json","cwd":"/Users/x/proj","timestamp":"2026-09-04T10:00:00Z"\#(extra.isEmpty ? "" : "," + extra)}"#
    }

    @Test func toolPermissionIsTheOnlyWait() throws {
        for (event, extra) in Self.documented {
            let message = try #require(parse(payload(event, extra: extra)), "\(event)")
            #expect(message.tool == .antigravity, "\(event)")
            #expect(message.needsInput == (event == "Notification"),
                    "\(event): the ToolPermission alert is the one signal Gemini documents as the CLI stopping for the user")
        }
        for type in ["ToolPermission", "Info", "Error", "Warning", "permission_prompt", "idle_prompt", ""] {
            let message = try #require(parse(payload("Notification", extra: #""notification_type":"\#(type)","message":"m""#)), "\(type)")
            #expect(message.event == "Notification", "\(type)")
            #expect(message.needsInput == (type == "ToolPermission"), "\(type): only the documented type lights the hand; Claude Code's words prove nothing here")
        }
        let untyped = try #require(parse(payload("Notification", extra: #""message":"m""#)))
        #expect(!untyped.needsInput, "a notice with no type is not a wait")
        #expect(untyped.notificationType == nil)
        #expect(Set(Hook.Gemini.waitingNotificationTypes) == ["ToolPermission"], "the reference documents one notification type; the set is the whole wait")
    }

    @Test func theWaitCarriesTheVendorsWordAndSurvivesTheNotificationPayload() throws {
        let message = try #require(parse(payload("Notification", extra: #""notification_type":"ToolPermission","message":"Tool run_shell_command requires execution","details":{"type":"exec"}"#)))
        #expect(message == Hook.Message(event: "Notification", needsInput: true, sessionID: "s1", project: "proj", notificationType: "ToolPermission", branch: "main", tool: .antigravity),
                "the type is Gemini's own word, not renamed onto Claude Code's permission_prompt")
        #expect(message.userInfo[Hook.toolKey] as? String == "antigravity")
        #expect(message.userInfo[Hook.typeKey] as? String == "ToolPermission")
        #expect(Hook.Message(userInfo: message.userInfo) == message, "the tool and the type survive the notification payload, or the store would light Claude's ring")
    }

    @Test func otherNotificationsCarryNoTypeAndNeitherStartNorEndAWait() throws {
        let other = try #require(parse(payload("Notification", extra: #""notification_type":"agent_completed","message":"m""#)))
        #expect(!other.needsInput)
        #expect(other.notificationType == nil, "a type that is not the documented wait is dropped, so Claude Code's completion types can never end a Gemini wait they do not answer")
        #expect(!other.clearsWaiting)
        #expect(!other.waitsOnQuota)
        #expect(!other.resumesFromQuota)

        let t0 = Date(timeIntervalSince1970: 1_788_300_000)
        var tracker = SessionTracker()
        tracker.apply(try #require(parse(payload("BeforeAgent"))), now: t0)
        let waited = tracker.apply(try #require(parse(payload("Notification", extra: #""notification_type":"ToolPermission""#))), now: t0.addingTimeInterval(5))
        #expect(waited.startedWaiting?.id == "antigravity:s1")
        #expect(tracker.sessions["antigravity:s1"]?.isWaiting == true)
        let unmoved = tracker.apply(other, now: t0.addingTimeInterval(10))
        #expect(unmoved.stoppedWaiting.isEmpty)
        #expect(tracker.sessions["antigravity:s1"]?.isWaiting == true, "an unrelated notice leaves the hand where it was")
        let ended = tracker.apply(try #require(parse(payload("AfterAgent"))), now: t0.addingTimeInterval(20))
        #expect(ended.stoppedWaiting == ["antigravity:s1"], "the end of the turn is the first documented signal that the CLI is no longer held")
        #expect(tracker.sessions["antigravity:s1"]?.isWaiting == false)
    }

    @Test func beforeAndAfterAgentBracketATurn() throws {
        let before = try #require(parse(payload("BeforeAgent", extra: #""prompt":"fix the tests""#)))
        #expect(before.event == "UserPromptSubmit")
        #expect(before.sessionID == "s1")
        let after = try #require(parse(payload("AfterAgent", extra: #""prompt":"fix the tests","prompt_response":"done","stop_hook_active":false"#)))
        #expect(after.event == "Stop")
        #expect(after.failure == nil, "AfterAgent has no status field; it is always a finish, never a StopFailure")
        #expect(!after.hitRateLimit)
        #expect(after.clearsWaiting)

        let t0 = Date(timeIntervalSince1970: 1_788_300_000)
        var tracker = SessionTracker()
        tracker.apply(try #require(parse(payload("SessionStart", extra: #""source":"startup""#))), now: t0)
        tracker.apply(before, now: t0.addingTimeInterval(1))
        #expect(tracker.isWorking(.antigravity))
        let outcome = tracker.apply(after, now: t0.addingTimeInterval(26))
        #expect(outcome.finished?.turn == 25)
        #expect(outcome.finished?.session.tool == .antigravity)
        #expect(outcome.finished?.session.project == "proj")
        #expect(outcome.finished?.session.branch == "main")
        #expect(tracker.finish(of: .antigravity, now: t0.addingTimeInterval(27))?.turn == 25, "the Antigravity ring shows the finished tick for Gemini CLI's turn")
        #expect(tracker.finish(of: .claude, now: t0.addingTimeInterval(27)) == nil, "and no other ring borrows it")
        #expect(!tracker.isWorking(.antigravity))
    }

    @Test func clearEndsAndStartsWithDifferentIds() throws {
        let t0 = Date(timeIntervalSince1970: 1_788_300_000)
        var tracker = SessionTracker()
        tracker.apply(try #require(parse(payload("SessionStart", extra: #""source":"startup""#, session: "old"))), now: t0)
        tracker.apply(try #require(parse(payload("BeforeAgent", session: "old"))), now: t0.addingTimeInterval(1))
        #expect(tracker.sessions.keys.contains("antigravity:old"))
        // /clear issues a new id: SessionEnd with the old one and reason "clear", then SessionStart with the new one.
        let end = try #require(parse(payload("SessionEnd", extra: #""reason":"clear""#, session: "old")))
        #expect(end.event == "SessionEnd")
        tracker.apply(end, now: t0.addingTimeInterval(2))
        let start = try #require(parse(payload("SessionStart", extra: #""source":"clear""#, session: "new")))
        #expect(start.event == "SessionStart", "every source (startup, resume, clear) is the same event; the tracker's SessionStart only touches lastEvent")
        tracker.apply(start, now: t0.addingTimeInterval(3))
        #expect(Set(tracker.sessions.keys) == ["antigravity:new"], "the cleared conversation is gone and the new one stands alone")
        #expect(tracker.sessions["antigravity:new"]?.tool == .antigravity)
        for reason in ["exit", "clear", "logout", "prompt_input_exit", "other"] {
            #expect(try #require(parse(payload("SessionEnd", extra: #""reason":"\#(reason)""#))).event == "SessionEnd", "\(reason)")
        }
    }

    @Test func theRootFallsBackToGeminiEnvNotTheClaudeAlias() throws {
        let bare = #"{"hook_event_name":"BeforeAgent","session_id":"s1","prompt":"p"}"#
        let fromCwd = try #require(parse(bare, environment: ["GEMINI_CWD": "/Users/x/proj"]))
        #expect(fromCwd.project == "proj")
        #expect(fromCwd.branch == "main", "the branch is read from the folder the environment names")
        let fromProjectDir = try #require(parse(bare, environment: ["GEMINI_PROJECT_DIR": "/Users/x/proj"]))
        #expect(fromProjectDir.project == "proj")
        #expect(fromProjectDir.branch == "main")
        let fromAlias = try #require(parse(bare, environment: ["CLAUDE_PROJECT_DIR": "/Users/x/proj"]))
        #expect(fromAlias.project == nil, "CLAUDE_PROJECT_DIR is Gemini's compatibility alias and Claude Code's real variable; reading it would let one assistant name the other's folder")
        #expect(fromAlias.branch == nil)
        let ordered = try #require(parse(bare, environment: ["GEMINI_CWD": "/Users/x/proj", "GEMINI_PROJECT_DIR": "/Users/x/other"]))
        #expect(ordered.project == "proj", "GEMINI_CWD is where the session runs; GEMINI_PROJECT_DIR is the fallback")
        let payloadWins = try #require(parse(#"{"hook_event_name":"BeforeAgent","session_id":"s1","cwd":"/Users/x/proj"}"#, environment: ["GEMINI_CWD": "/Users/x/other"]))
        #expect(payloadWins.project == "proj", "the payload's cwd outranks the environment")
        let empty = try #require(parse(#"{"hook_event_name":"BeforeAgent","session_id":"s1","cwd":""}"#, environment: ["GEMINI_CWD": ""]))
        #expect(empty.project == nil)
        #expect(Hook.Gemini.root(of: ["cwd": ""], environment: ["GEMINI_CWD": "", "GEMINI_PROJECT_DIR": "/Users/x/proj"]) == "/Users/x/proj", "an empty value is no value")
    }

    @Test func theSessionIdFallsBackToTheHookEnvironment() throws {
        let fromEnv = try #require(parse(#"{"hook_event_name":"BeforeAgent","cwd":"/Users/x/proj"}"#, environment: ["GEMINI_SESSION_ID": "env-1"]))
        #expect(fromEnv.sessionID == "env-1", "GEMINI_SESSION_ID is documented in the hook's environment and stands in for a payload without the id")
        let payloadWins = try #require(parse(payload("BeforeAgent"), environment: ["GEMINI_SESSION_ID": "env-1"]))
        #expect(payloadWins.sessionID == "s1")
        let neither = try #require(parse(#"{"hook_event_name":"BeforeAgent","session_id":""}"#, environment: ["GEMINI_SESSION_ID": ""]))
        #expect(neither.sessionID == nil)
        #expect(SessionTracker.key(tool: .antigravity, session: neither.sessionID, host: nil) == "antigravity:unknown")
    }

    @Test func geminiOnlyNamesEnvAndToolPermissionAreRecognisedWithoutTheFlag() throws {
        // A plain --hook (Gemini ran the Claude Code entry, or the user wrote the command by hand): the payload's
        // own marks still tag it Gemini's.
        for name in Hook.Gemini.geminiOnlyEvents.sorted() {
            let message = try #require(parse(payload(name), tool: nil), "\(name)")
            #expect(message.tool == .antigravity, "\(name) is a name only Gemini CLI sends")
        }
        let byName = try #require(parse(payload("AfterAgent"), tool: nil))
        #expect(byName == Hook.Message(event: "Stop", needsInput: false, sessionID: "s1", project: "proj", branch: "main", tool: .antigravity))
        let byEnvironment = try #require(parse(payload("SessionStart", extra: #""source":"startup""#), tool: nil, environment: ["GEMINI_SESSION_ID": "s1"]))
        #expect(byEnvironment.tool == .antigravity, "GEMINI_SESSION_ID in the hook's environment is Gemini's documented mark on a name Claude Code shares")
        let byType = try #require(parse(payload("Notification", extra: #""notification_type":"ToolPermission""#), tool: nil))
        #expect(byType.tool == .antigravity, "ToolPermission is a type Claude Code never sends")
        #expect(byType.needsInput)
        #expect(Hook.Gemini.recognises(event: "SessionEnd", object: ["session_id": "s"], environment: ["GEMINI_SESSION_ID": ""]) == false, "an empty variable is no mark")
    }

    @Test func aClaudePayloadStaysClaudeWithoutGeminiMarkers() throws {
        // The three names Gemini shares with Claude Code, on a plain --hook with nothing Gemini adds: Claude's, as
        // they have always been, because the installed flag is what tells Gemini's apart.
        let start = try #require(parse(payload("SessionStart", extra: #""source":"startup""#), tool: nil))
        #expect(start.tool == .claude)
        #expect(start.userInfo[Hook.toolKey] == nil, "Claude Code's payload writes no tool, byte for byte what it has always been")
        let end = try #require(parse(payload("SessionEnd", extra: #""reason":"exit""#), tool: nil))
        #expect(end.tool == .claude)
        let prompt = try #require(parse(#"{"hook_event_name":"Notification","session_id":"s1","cwd":"/Users/x/proj","notification_type":"permission_prompt"}"#, tool: nil))
        #expect(prompt.tool == .claude, "permission_prompt is Claude Code's word for the wait, not Gemini's")
        #expect(prompt.needsInput)
        #expect(prompt.notificationType == "permission_prompt")
        let stop = try #require(parse(#"{"hook_event_name":"Stop","session_id":"s1","cwd":"/Users/x/proj"}"#, tool: nil, environment: ["CLAUDE_PROJECT_DIR": "/Users/x/proj"]))
        #expect(stop.tool == .claude, "Claude Code's own environment variable is not a Gemini mark")
    }

    @Test func theFlagOutranksAClaudeShapedPayload() throws {
        // Claude Code's words on Gemini's flag are still Gemini's: permission_prompt is not a Gemini type, so it is
        // dropped rather than read as a wait, and the tool is the flag's.
        let claudeWords = try #require(parse(#"{"hook_event_name":"Notification","session_id":"s1","cwd":"/Users/x/proj","notification_type":"permission_prompt"}"#))
        #expect(claudeWords.tool == .antigravity)
        #expect(!claudeWords.needsInput, "under Gemini's flag only Gemini's documented type is a wait")
        #expect(claudeWords.notificationType == nil)
        let remote = try #require(parse(#"{"hook_event_name":"AfterAgent","session_id":"s1","cwd":"/Users/x/proj","tool":"antigravity"}"#, tool: nil))
        #expect(remote.tool == .antigravity, "a \"tool\" key in the payload is the flag's equivalent for a remote post")
        #expect(remote.event == "Stop")
    }

    @Test func noEventEverYieldsAgentOrModeOrFailure() throws {
        // Gemini documents no subagent, no permission mode and no failing stop; fields borrowed from Claude Code's
        // vocabulary in the payload are not read, so nothing above the parser can be told a story Gemini never told.
        let borrowed = #""agent_id":"a-1","permission_mode":"bypassPermissions","error":"rate_limit","error_type":"rate_limit","status":"aborted","stop_reason":"error""#
        for (event, extra) in Self.documented {
            let message = try #require(parse(payload(event, extra: extra + "," + borrowed)), "\(event)")
            #expect(message.agentID == nil, "\(event)")
            #expect(message.permissionMode == nil, "\(event)")
            #expect(Hook.permissionBadge(message.permissionMode) == nil, "\(event)")
            #expect(message.failure == nil, "\(event)")
            #expect(!message.hitRateLimit, "\(event)")
            #expect(message.event != "StopFailure", "\(event): no Gemini event is ever a StopFailure")
            #expect(message.host == nil, "\(event)")
            for key in ["transcript_path", "timestamp", "prompt", "prompt_response", "stop_hook_active", "message", "details", "reason", "trigger", "source", Hook.agentKey, Hook.permissionKey, Hook.failureKey] {
                #expect(message.userInfo[key] == nil, "\(event): \(key) is not read")
            }
        }
        let unknown = try #require(parse(payload("SomethingNew")))
        #expect(unknown.event == "SomethingNew", "a name the parser does not know passes through verbatim for the tracker to ignore")
        #expect(!unknown.needsInput)
    }

    @Test func remotePostWithToolAntigravity() throws {
        let body = Data(#"{"hook_event_name":"AfterAgent","session_id":"s1","cwd":"/home/me/proj","tool":"antigravity","branch":"main","host":"devbox"}"#.utf8)
        let message = try #require(LocalAPI.hookMessage(from: body))
        #expect(message.tool == .antigravity, "Gemini's shared names need the \"tool\" key on a remote post, the way Codex's do")
        #expect(message.event == "Stop")
        #expect(message.host == "devbox")
        #expect(message.project == "proj")
        #expect(message.branch == "main")
        let byName = try #require(LocalAPI.hookMessage(from: Data(#"{"hook_event_name":"BeforeAgent","session_id":"s1","cwd":"/home/me/proj","host":"devbox"}"#.utf8)))
        #expect(byName.tool == .antigravity, "and a Gemini-only name is recognised by shape without it")
        #expect(byName.event == "UserPromptSubmit")
    }

    @Test func keyIsPrefixedAntigravity() throws {
        #expect(SessionTracker.key(tool: .antigravity, session: "s1", host: nil) == "antigravity:s1")
        #expect(SessionTracker.key(tool: .antigravity, session: "s1", host: "devbox") == "antigravity:s1@devbox")
        #expect(SessionTracker.key(tool: .antigravity, session: nil, host: nil) == "antigravity:unknown")
        let t0 = Date(timeIntervalSince1970: 1_788_300_000)
        var tracker = SessionTracker()
        tracker.apply(try #require(parse(payload("BeforeAgent"))), now: t0)
        tracker.apply(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "s1"), now: t0)
        #expect(Set(tracker.sessions.keys) == ["antigravity:s1", "s1"], "a Gemini session and a Claude session with the same id never share an entry")
        #expect(tracker.sessions["antigravity:s1"]?.tool == .antigravity)
    }
}


/// The `~/.gemini/settings.json` installer: Gemini CLI's nested groups, its millisecond `timeout` and `name`, the
/// other settings that file holds and must keep, and the refusal that keeps a commented file from being flattened.
@Suite struct GeminiHookInstallation {
    init() { Localization.use(language: "en") }

    let executable = "/Applications/Notchmeter.app/Contents/MacOS/Notchmeter"
    var expected: String { "'\(executable)' --hook --tool antigravity" }

    /// The handler Gemini's file wants, as the installer writes it.
    func handler(command: String) -> [String: Any] {
        ["name": "notchmeter", "type": "command", "command": command, "timeout": 5000]
    }

    /// A settings.json with every event Notchmeter registers, each a group of one handler carrying `command`.
    func file(command: String, without missing: String? = nil) -> [String: Any] {
        var hooks: [String: Any] = [:]
        for event in HookVendor.antigravity.events where event != missing {
            hooks[event] = [["hooks": [handler(command: command)]]]
        }
        return ["hooks": hooks]
    }

    @Test func snippetWritesMillisecondsNameAndNoAsync() throws {
        let snippet = HookSettings.snippet(vendor: .antigravity, executable: "/Users/me/My Apps/Notchmeter.app/Contents/MacOS/Notchmeter")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(snippet.utf8)) as? [String: Any])
        #expect(root["version"] == nil, "Gemini's file has no version key")
        #expect(Set(root.keys) == ["hooks"])
        let hooks = try #require(root["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == Set(HookVendor.antigravity.events))
        for event in HookVendor.antigravity.events {
            let groups = try #require(hooks[event] as? [[String: Any]], "\(event)")
            #expect(groups.count == 1)
            let group = try #require(groups.first)
            #expect(Set(group.keys) == ["hooks"], "\(event): no matcher — lifecycle matchers are exact strings and omitting one receives every source, reason and type")
            let handlers = try #require(group["hooks"] as? [[String: Any]], "\(event)")
            #expect(handlers.count == 1)
            let handler = try #require(handlers.first)
            #expect(Set(handler.keys) == ["type", "name", "command", "timeout"], "\(event): no async (Gemini has no such field); the name is what its /hooks panel lists")
            #expect(handler["type"] as? String == "command")
            #expect(handler["name"] as? String == "notchmeter")
            #expect(handler["timeout"] as? Int == 5000, "\(event): Gemini's timeout is in milliseconds, so 5 would be five milliseconds")
            #expect(handler["command"] as? String == "'/Users/me/My Apps/Notchmeter.app/Contents/MacOS/Notchmeter' --hook --tool antigravity")
        }
        #expect(snippet.contains(#"{ "type": "command", "name": "notchmeter", "command": "'/Users/me/My Apps/Notchmeter.app/Contents/MacOS/Notchmeter' --hook --tool antigravity", "timeout": 5000 }"#),
                "one handler per line, keys in the fixed order, the path unescaped")
        #expect(!snippet.contains("async"))
        #expect(!snippet.contains("\\/"))
        #expect(HookVendor.antigravity.flag == "--hook --tool antigravity")
        #expect(HookVendor.antigravity.flag(for: "Notification") == "--hook --tool antigravity", "Gemini's payload names its event, so no --event is added")
        #expect(HookVendor.antigravity.shape == .nestedGroups)
        #expect(HookVendor.antigravity.events == ["SessionStart", "BeforeAgent", "AfterAgent", "Notification", "SessionEnd"])
        for event in HookVendor.antigravity.events {
            #expect(NSDictionary(dictionary: HookVendor.antigravity.handler(command: expected, event: event)) == NSDictionary(dictionary: handler(command: expected)),
                    "\(event): the same handler for every event; Gemini documents no per-event cap")
        }
        #expect(HookSettings.executable(in: expected) == executable, "status reads the path back out of the longer command")
    }

    @Test func displayNameIsGeminiCli() {
        #expect(HookVendor.antigravity.displayName == "Gemini CLI", "the row is Gemini CLI's; the ring is Antigravity's")
        #expect(HookVendor.antigravity.tool == .antigravity)
        #expect(HookVendor.antigravity.fileName == "settings.json")
        #expect(HookVendor.antigravity.fileURL.path.hasSuffix("/.gemini/settings.json"))
        #expect(!HookVendor.antigravity.reloadsLive, "Gemini reads settings.json when it starts; the note after Add says so")
        #expect(HookVendor.vendor(for: .antigravity) == .antigravity)
        #expect(HookVendor.allCases.filter { $0.tool == .antigravity } == [.antigravity], "one row lights the Antigravity ring, and it is Gemini CLI's")
    }

    @Test func fileURLFollowsGeminiCliHome() {
        let home = URL(fileURLWithPath: "/Users/me")
        #expect(HookVendor.antigravity.fileURL(environment: [:], home: home).path == "/Users/me/.gemini/settings.json")
        #expect(HookVendor.antigravity.fileURL(environment: ["GEMINI_CLI_HOME": "/srv/gemini"], home: home).path == "/srv/gemini/.gemini/settings.json",
                "GEMINI_CLI_HOME replaces the home directory that .gemini is appended to; it is not the .gemini folder itself")
        #expect(HookVendor.antigravity.fileURL(environment: ["GEMINI_CLI_HOME": ""], home: home).path == "/Users/me/.gemini/settings.json", "an empty variable is no override")
        #expect(HookVendor.antigravity.fileURL(environment: ["GEMINI_CLI_HOME": "~/cfg"], home: home).path == Paths.home.appendingPathComponent("cfg/.gemini/settings.json").path,
                "a tilde in the variable is expanded the way a shell would")
        #expect(HookVendor.antigravity.fileURL(environment: ["CLAUDE_CONFIG_DIR": "/srv/claude", "CODEX_HOME": "/srv/codex", "COPILOT_HOME": "/srv/copilot"], home: home).path == "/Users/me/.gemini/settings.json",
                "the other assistants' overrides do not move Gemini's file")
    }

    @Test func mergePreservesOtherSettingsKeys() throws {
        let existing: [String: Any] = [
            "theme": "GitHub",
            "selectedAuthType": "oauth-personal",
            "mcpServers": ["github": ["command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"]]],
            "hooksConfig": ["enabled": true, "notifications": false],
            "hooks": [
                "BeforeTool": [["matcher": "write_file|replace", "hooks": [["name": "security-check", "type": "command", "command": "$GEMINI_PROJECT_DIR/.gemini/hooks/security.sh", "timeout": 5000]]]],
                "Notification": [["matcher": "ToolPermission", "hooks": [["type": "command", "command": "/usr/local/bin/ping-phone.sh", "env": ["TOKEN": "x"]]]]],
                "SessionEnd": "not an array",
            ],
        ]
        let first = HookSettings.merge(into: existing, vendor: .antigravity, executable: executable)
        #expect(first.added == ["SessionStart", "BeforeAgent", "AfterAgent", "Notification"])
        #expect(first.present == ["SessionEnd"], "a value that is not an array is left alone rather than replaced")
        #expect(first.settings["theme"] as? String == "GitHub")
        #expect(first.settings["selectedAuthType"] as? String == "oauth-personal")
        #expect(NSDictionary(dictionary: try #require(first.settings["mcpServers"] as? [String: Any])) == NSDictionary(dictionary: try #require(existing["mcpServers"] as? [String: Any])),
                "settings.json holds everything Gemini knows; only `hooks` is touched")
        #expect(NSDictionary(dictionary: try #require(first.settings["hooksConfig"] as? [String: Any])) == NSDictionary(dictionary: ["enabled": true, "notifications": false]))
        #expect(first.settings["version"] == nil, "the nested shape wants no root key")
        let hooks = try #require(first.settings["hooks"] as? [String: Any])
        let security = try #require(hooks["BeforeTool"] as? [[String: Any]])
        #expect(security.count == 1, "events Notchmeter does not register are not visited")
        #expect(security[0]["matcher"] as? String == "write_file|replace")
        let notification = try #require(hooks["Notification"] as? [[String: Any]])
        #expect(notification.count == 2)
        #expect(notification[0]["matcher"] as? String == "ToolPermission", "the foreign group keeps its matcher")
        let foreign = try #require((notification[0]["hooks"] as? [[String: Any]])?.first)
        #expect(foreign["command"] as? String == "/usr/local/bin/ping-phone.sh")
        #expect((foreign["env"] as? [String: String]) == ["TOKEN": "x"], "and its undocumented env")
        #expect(Set(notification[1].keys) == ["hooks"], "ours carries no matcher: omitting one receives every notification type")
        let ours = try #require((notification[1]["hooks"] as? [[String: Any]])?.first)
        #expect(NSDictionary(dictionary: ours) == NSDictionary(dictionary: handler(command: expected)))
        #expect(hooks["SessionEnd"] as? String == "not an array")

        let second = HookSettings.merge(into: first.settings, vendor: .antigravity, executable: "/somewhere/else/Notchmeter")
        #expect(second.added.isEmpty)
        #expect(Set(second.present) == Set(HookVendor.antigravity.events))
        #expect(NSDictionary(dictionary: second.settings) == NSDictionary(dictionary: first.settings), "idempotent: a second merge, even from another path, changes nothing")

        let fresh = HookSettings.merge(into: [:], vendor: .antigravity, executable: executable)
        #expect(fresh.added == HookVendor.antigravity.events)
        #expect(Set(fresh.settings.keys) == ["hooks"])
        let claude = HookSettings.merge(into: [:], executable: executable)
        let claudeStart = try #require(((claude.settings["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
        #expect(NSDictionary(dictionary: try #require(claudeStart.first)) == NSDictionary(dictionary: ["type": "command", "command": "'\(executable)' --hook", "async": true, "timeout": 5]),
                "Claude Code's handler is what it has always been: no name, seconds, async")
    }

    @Test func statusAndRepair() throws {
        #expect(HookSettings.status(settings: [:], vendor: .antigravity, executable: executable) == .notInstalled)
        #expect(HookSettings.status(settings: ["hooks": ["BeforeTool": [["hooks": [handler(command: expected)]]]]], vendor: .antigravity, executable: executable) == .notInstalled,
                "an entry under an event Notchmeter does not register does not count")
        #expect(HookSettings.status(settings: file(command: expected), vendor: .antigravity, executable: executable) == .installed(path: executable))
        #expect(!HookSettings.status(settings: file(command: expected), vendor: .antigravity, executable: executable).needsRepair)
        let other = "/Users/me/Downloads/Notchmeter.app/Contents/MacOS/Notchmeter"
        let moved = HookSettings.status(settings: file(command: "'\(other)' --hook --tool antigravity"), vendor: .antigravity, executable: executable)
        #expect(moved == .stale(path: other))
        #expect(moved.needsRepair)
        let missing = HookSettings.status(settings: file(command: expected, without: "AfterAgent"), vendor: .antigravity, executable: executable)
        #expect(missing == .partial(path: executable), "the right path with an event missing is out of date, not pointing at an old copy")
        #expect(missing.text == "Installed, but an entry is out of date: Repair updates it")
        let plain = HookSettings.status(settings: file(command: "'\(executable)' --hook"), vendor: .antigravity, executable: executable)
        #expect(plain == .partial(path: executable), "a plain --hook lights the Claude ring for SessionStart and SessionEnd; Repair upgrades it")
        let claudeFile = HookSettings.status(settings: file(command: expected), executable: executable)
        #expect(claudeFile == .partial(path: executable), "read as Claude Code's file the same entries are there but on the wrong flag for four of nine events")

        // Repair: the command is rewritten and nothing else about the handler or its group is touched.
        var settings = file(command: "'\(other)' --hook")
        var hooks = try #require(settings["hooks"] as? [String: Any])
        hooks["AfterAgent"] = [["matcher": "", "hooks": [["name": "notchmeter", "type": "command", "command": "'\(other)' --hook", "timeout": 9000, "env": ["A": "b"]]]]]
        hooks["BeforeTool"] = [["matcher": "write_file", "hooks": [["name": "security-check", "type": "command", "command": "/usr/local/bin/guard.sh", "timeout": 5000]]]]
        hooks["SessionEnd"] = nil
        settings["hooks"] = hooks
        settings["theme"] = "GitHub"
        let repaired = HookSettings.repair(settings, vendor: .antigravity, executable: executable)
        #expect(repaired.repaired == ["SessionStart", "BeforeAgent", "AfterAgent", "Notification"], "in the vendor's order")
        #expect(repaired.added == ["SessionEnd"])
        #expect(repaired.settings["theme"] as? String == "GitHub")
        let written = try #require(repaired.settings["hooks"] as? [String: Any])
        let after = try #require((written["AfterAgent"] as? [[String: Any]])?.first)
        #expect(after["matcher"] as? String == "", "the group's matcher is kept")
        let fixed = try #require((after["hooks"] as? [[String: Any]])?.first)
        #expect(fixed["command"] as? String == expected)
        #expect(fixed["timeout"] as? Int == 9000, "a timeout the user changed is theirs")
        #expect(fixed["name"] as? String == "notchmeter")
        #expect((fixed["env"] as? [String: String]) == ["A": "b"])
        let guardGroup = try #require((written["BeforeTool"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
        #expect(guardGroup.first?["command"] as? String == "/usr/local/bin/guard.sh", "a foreign hook is never rewritten")
        let end = try #require((written["SessionEnd"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
        #expect(NSDictionary(dictionary: try #require(end.first)) == NSDictionary(dictionary: self.handler(command: expected)))
        #expect(HookSettings.status(settings: repaired.settings, vendor: .antigravity, executable: executable) == .installed(path: executable))
        let again = HookSettings.repair(repaired.settings, vendor: .antigravity, executable: executable)
        #expect(again.repaired.isEmpty)
        #expect(again.added.isEmpty)
        #expect(NSDictionary(dictionary: again.settings) == NSDictionary(dictionary: repaired.settings))
    }

    @Test func installMergesBacksUpAndKeepsPermissions() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("notchmeter-gemini-hook-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let now = Date(timeIntervalSince1970: 1_788_300_000)

        let missing = dir.appendingPathComponent("fresh/.gemini/settings.json")
        let created = try HookSettings.install(vendor: .antigravity, at: missing, executable: executable, now: now)
        #expect(created.backup == nil)
        #expect(created.added == HookVendor.antigravity.events)
        #expect(fm.fileExists(atPath: missing.path), "a first run has no .gemini folder yet; the directory is created")
        let fresh = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: missing)) as? [String: Any])
        #expect(Set(fresh.keys) == ["hooks"])
        #expect(HookSettings.status(vendor: .antigravity, at: missing, executable: executable) == .installed(path: executable))
        #expect(!(try String(contentsOf: missing, encoding: .utf8)).contains("\\/"))

        let url = dir.appendingPathComponent("settings.json")
        let original = #"{"theme":"GitHub","mcpServers":{"github":{"command":"npx"}},"hooks":{"BeforeTool":[{"matcher":"write_file","hooks":[{"type":"command","command":"/usr/local/bin/guard.sh"}]}]}}"#
        try Data(original.utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let installed = try HookSettings.install(vendor: .antigravity, at: url, executable: executable, now: now)
        #expect(installed.added == HookVendor.antigravity.events)
        let backup = try #require(installed.backup)
        #expect(backup.lastPathComponent.hasPrefix("settings.json.bak-2026"))
        #expect(backup.lastPathComponent.range(of: #"^settings\.json\.bak-\d{8}-\d{6}$"#, options: .regularExpression) != nil)
        #expect(try String(contentsOf: backup, encoding: .utf8) == original)
        #expect((try fm.attributesOfItem(atPath: url.path))[.posixPermissions] as? Int == 0o600)
        let written = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(written["theme"] as? String == "GitHub")
        #expect(((written["mcpServers"] as? [String: Any])?["github"] as? [String: Any])?["command"] as? String == "npx")
        let hooks = try #require(written["hooks"] as? [String: Any])
        #expect((hooks["BeforeTool"] as? [[String: Any]])?.count == 1)
        #expect(Set(hooks.keys) == Set(HookVendor.antigravity.events).union(["BeforeTool"]))
        #expect(HookSettings.status(vendor: .antigravity, at: url, executable: executable) == .installed(path: executable))

        let again = try HookSettings.install(vendor: .antigravity, at: url, executable: executable, now: now.addingTimeInterval(60))
        #expect(again.added.isEmpty)
        #expect(again.backup == nil)
        #expect(try fm.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".bak-") }.count == 1)

        // A file at the right path but on a plain --hook is repaired to carry the flag, once.
        try JSONSerialization.data(withJSONObject: file(command: "'\(executable)' --hook")).write(to: url)
        #expect(HookSettings.status(vendor: .antigravity, at: url, executable: executable) == .partial(path: executable))
        let repaired = try HookSettings.repairInstall(vendor: .antigravity, at: url, executable: executable, now: now.addingTimeInterval(120))
        #expect(repaired.backup != nil)
        #expect(repaired.added.count == 5)
        #expect(HookSettings.status(vendor: .antigravity, at: url, executable: executable) == .installed(path: executable))
        #expect(try HookSettings.repairInstall(vendor: .antigravity, at: url, executable: executable, now: now.addingTimeInterval(180)).backup == nil)
        #expect(try fm.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".bak-") }.count == 2)

        try Data("[]".utf8).write(to: url)
        #expect(throws: HookSettings.Failure.self) {
            try HookSettings.install(vendor: .antigravity, at: url, executable: executable, now: now)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "[]")
    }

    @Test func aCommentedSettingsFileIsRefusedNotRewritten() throws {
        // Gemini may tolerate comments in settings.json (unverified); a file that is not strict JSON is never
        // parsed loosely and written back flattened by .sortedKeys — the row reads not installed, Add shows the
        // error and the row help says to paste the snippet.
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("notchmeter-gemini-comments-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        let commented = """
        {
          // The theme I like.
          "theme": "GitHub",
          "hooks": {
            "BeforeTool": [ { "hooks": [ { "type": "command", "command": "/usr/local/bin/guard.sh" } ] } ] /* keep */
          }
        }
        """
        try Data(commented.utf8).write(to: url)
        let now = Date(timeIntervalSince1970: 1_788_300_000)

        #expect(throws: HookSettings.Failure.self) { try HookSettings.readSettings(at: url) }
        #expect(HookSettings.status(vendor: .antigravity, at: url, executable: executable) == .notInstalled)
        #expect(throws: HookSettings.Failure.self) { try HookSettings.install(vendor: .antigravity, at: url, executable: executable, now: now) }
        #expect(throws: HookSettings.Failure.self) { try HookSettings.repairInstall(vendor: .antigravity, at: url, executable: executable, now: now) }
        #expect(try String(contentsOf: url, encoding: .utf8) == commented, "the bytes are exactly what they were: no comment lost, no key reordered")
        #expect(try fm.contentsOfDirectory(atPath: dir.path) == ["settings.json"], "nothing was written, so nothing was backed up")
        do {
            try HookSettings.install(vendor: .antigravity, at: url, executable: executable, now: now)
        } catch let failure as HookSettings.Failure {
            #expect(failure.errorDescription == "\(url.path) is not a JSON object, so it was left untouched")
        }
        let snippet = HookSettings.snippet(vendor: .antigravity, executable: executable)
        #expect(try JSONSerialization.jsonObject(with: Data(snippet.utf8)) is [String: Any], "what the row help offers to paste instead is itself valid JSON")
    }
}
