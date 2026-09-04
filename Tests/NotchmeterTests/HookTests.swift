import Foundation
import Testing
@testable import Notchmeter

@Suite struct HookMessages {
    @Test func readsOnlyTheEventAndWhetherClaudeWaits() throws {
        let stop = try #require(Hook.message(from: Data(#"{"hook_event_name":"Stop","session_id":"s","transcript_path":"/x","cwd":"/Users/me/y"}"#.utf8)))
        #expect(stop == Hook.Message(event: "Stop", needsInput: false, sessionID: "s", project: "y"))
        let permission = try #require(Hook.message(from: Data(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash"}"#.utf8)))
        #expect(permission.needsInput)
        let prompt = try #require(Hook.message(from: Data(#"{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"x"}"#.utf8)))
        #expect(prompt.needsInput)
        let auth = try #require(Hook.message(from: Data(#"{"hook_event_name":"Notification","notification_type":"auth_success"}"#.utf8)))
        #expect(!auth.needsInput)
        #expect(Hook.message(from: Data()) == nil)
        #expect(Hook.message(from: Data("not json".utf8)) == nil)
        #expect(Hook.message(from: Data(#"{"session_id":"s"}"#.utf8)) == nil)
    }

    @Test func userInfoCarriesTheEventTheFlagTheSessionAndTheFolderName() throws {
        let message = Hook.Message(event: "Notification", needsInput: true)
        #expect(Set(message.userInfo.keys) == ["hook_event_name", "needsInput"])
        #expect(Hook.Message(userInfo: message.userInfo) == message)
        let full = Hook.Message(event: "PermissionRequest", needsInput: true, sessionID: "abc", project: "notchmeter", notificationType: nil)
        #expect(Set(full.userInfo.keys) == ["hook_event_name", "needsInput", "session_id", "project"])
        #expect(Hook.Message(userInfo: full.userInfo) == full)
        #expect(Hook.Message(userInfo: nil) == nil)
        #expect(Hook.Message(userInfo: ["needsInput": true]) == nil)
    }

    @Test func elicitationURLDialogWaitsAndCompletionsClear() {
        #expect(Hook.needsInput(event: "Notification", notificationType: "elicitation_url_dialog"))
        #expect(Hook.needsInput(event: "Notification", notificationType: "agent_needs_input"))
        #expect(!Hook.needsInput(event: "Notification", notificationType: "agent_completed"))
        #expect(Hook.Message(event: "Notification", needsInput: false, notificationType: "agent_completed").clearsWaiting)
        #expect(Hook.Message(event: "Notification", needsInput: false, notificationType: "elicitation_complete").clearsWaiting)
        #expect(!Hook.Message(event: "Notification", needsInput: false, notificationType: "auth_success").clearsWaiting)
        #expect(Hook.Message(event: "Stop", needsInput: false).clearsWaiting)
    }

    @Test func clearingEventsCoverStopAndTheNextPrompt() {
        #expect(Hook.clearingEvents.contains("Stop"))
        #expect(Hook.clearingEvents.contains("UserPromptSubmit"))
        #expect(!Hook.needsInput(event: "SessionStart", notificationType: nil))
        #expect(Hook.needsInput(event: "Notification", notificationType: "idle_prompt"))
        #expect(!Hook.needsInput(event: "Notification", notificationType: nil))
    }

    @Test func readsAFileOnStandardInputWithoutBlocking() throws {
        // stdin belongs to the test runner here; the budget is what keeps the read from hanging.
        let started = Date()
        _ = Hook.readStandardInput(within: 0.02)
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test func theToolFlagIsReadFromTheCommandLine() {
        #expect(Hook.tool(in: ["Notchmeter", "--hook", "--tool", "cursor"]) == .cursor)
        #expect(Hook.tool(in: ["--hook", "--tool"]) == nil, "a flag with no value is ignored, not an error")
        #expect(Hook.tool(in: ["--tool", "bogus"]) == nil, "a name that is not a ToolID is ignored, so the event still posts as Claude's")
        #expect(Hook.tool(in: ["Notchmeter", "--hook"]) == nil)
        #expect(Hook.tool(in: ["Notchmeter", "--hook", "--tool", "codex"]) == .codex)
        #expect(Hook.tool(in: ["Notchmeter", "--hook", "--tool", "antigravity"]) == .antigravity, "Gemini CLI's entries carry the ring's name")
        #expect(Hook.tool(in: ["Notchmeter", "--hook", "--tool", "copilot", "--event", "agentStop"]) == .copilot)
    }

    /// `--event` is Copilot's alone: its camelCase payload names no event, so the entry says which one it was
    /// registered under. Absent or dangling reads as nothing, the way `--tool` does.
    @Test func theEventFlagIsReadFromTheCommandLine() {
        #expect(Hook.event(in: ["Notchmeter", "--hook", "--tool", "copilot", "--event", "agentStop"]) == "agentStop")
        #expect(Hook.event(in: ["Notchmeter", "--hook", "--tool", "copilot"]) == nil, "absent")
        #expect(Hook.event(in: ["Notchmeter", "--hook", "--event"]) == nil, "dangling: a flag with no value is ignored, not an error")
        #expect(Hook.event(in: ["Notchmeter", "--hook", "--event", ""]) == nil, "an empty name is no name")
        #expect(Hook.event(in: ["Notchmeter", "--hook"]) == nil)
    }

    /// Claude Code's payload is what it has always been, byte for byte: no flag, no tool key, the same userInfo.
    @Test func aClaudePayloadStillReadsAsClaudeWithTheSameUserInfo() throws {
        let stop = try #require(Hook.message(from: Data(#"{"hook_event_name":"Stop","session_id":"s","transcript_path":"/x","cwd":"/Users/me/y"}"#.utf8)))
        #expect(stop.tool == .claude)
        #expect(Set(stop.userInfo.keys) == ["hook_event_name", "needsInput", "session_id", "project"])
        let permission = try #require(Hook.message(from: Data(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash"}"#.utf8)))
        #expect(permission.tool == .claude)
        #expect(Set(permission.userInfo.keys) == ["hook_event_name", "needsInput"])
        #expect(permission.userInfo[Hook.toolKey] == nil, "the one hook that ships says nothing here, and its absence already says Claude")
    }

    @Test func theFlagOutranksTheShape() throws {
        let claudeStop = Data(#"{"hook_event_name":"Stop","session_id":"s","cwd":"/Users/me/y"}"#.utf8)
        let asCursor = try #require(Hook.message(from: claudeStop, tool: .cursor))
        #expect(asCursor.tool == .cursor)
        #expect(asCursor.event == "StopFailure",
                "Cursor's parser owns a payload the flag hands it: a Stop with no status is not a completed stop, so it is no finish")
        #expect(asCursor.failure == nil)
        #expect(asCursor.sessionID == "s", "session_id is Cursor's fallback id when there is no conversation_id")
        let cursorStop = Data(#"{"hook_event_name":"stop","conversation_id":"c","status":"completed"}"#.utf8)
        let asClaude = try #require(Hook.message(from: cursorStop, tool: .claude))
        #expect(asClaude.tool == .claude)
        #expect(asClaude.event == "stop", "Claude Code's parser passes an unknown name through verbatim, and the tracker ignores it")
        #expect(!asClaude.needsInput)
        #expect(!asClaude.clearsWaiting)

        // Codex: a Claude-shaped payload, which nothing recognises by shape; the flag is what makes it Codex's.
        let asCodex = try #require(Hook.message(from: claudeStop, tool: .codex))
        #expect(asCodex.tool == .codex)
        #expect(asCodex.event == "Stop", "Codex's Stop has no status field and is always a finish")
        #expect(asCodex.failure == nil)
        #expect(asCodex.sessionID == "s")
        let claudePrompt = Data(#"{"hook_event_name":"Notification","notification_type":"permission_prompt","session_id":"s"}"#.utf8)
        // Gemini CLI: Claude's notification vocabulary under Gemini's flag is not Gemini's documented wait.
        let asGemini = try #require(Hook.message(from: claudePrompt, tool: .antigravity, environment: [:]))
        #expect(asGemini.tool == .antigravity)
        #expect(!asGemini.needsInput, "only Gemini's ToolPermission lights the hand; Claude Code's permission_prompt is not its word")
        #expect(asGemini.notificationType == nil, "a type that is not a documented wait is not carried, so it can never end one either")
        let geminiPrompt = Data(#"{"hook_event_name":"Notification","notification_type":"ToolPermission","session_id":"s"}"#.utf8)
        let geminiAsClaude = try #require(Hook.message(from: geminiPrompt, tool: .claude))
        #expect(geminiAsClaude.tool == .claude)
        #expect(!geminiAsClaude.needsInput, "Claude Code's parser does not know Gemini's word for a wait")
        // Copilot: the flag hands a Claude-shaped Stop to Copilot's parser, which reads the PascalCase alias.
        let asCopilot = try #require(Hook.message(from: claudeStop, tool: .copilot))
        #expect(asCopilot.tool == .copilot)
        #expect(asCopilot.event == "Stop")
        #expect(asCopilot.sessionID == "s", "session_id is Copilot's fallback id when there is no camelCase sessionId")
        let copilotStop = Data(#"{"sessionId":"c","cwd":"/Users/me/y","stopReason":"end_turn"}"#.utf8)
        let copilotAsClaude = try #require(Hook.message(from: copilotStop, tool: .claude, event: "agentStop"))
        #expect(copilotAsClaude.tool == .claude)
        #expect(copilotAsClaude.event == "agentStop", "Claude Code's parser passes an unknown name through verbatim")
        #expect(copilotAsClaude.sessionID == nil, "Claude Code's parser reads session_id, never Copilot's camelCase key")
    }
}

@Suite struct HookInstallation {
    let executable = "/Applications/Notchmeter.app/Contents/MacOS/Notchmeter"

    @Test func snippetIsValidJSONForEveryEvent() throws {
        let snippet = HookSettings.snippet(executable: "/Users/me/My Apps/Notchmeter.app/Contents/MacOS/Notchmeter")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(snippet.utf8)) as? [String: Any])
        let hooks = try #require(root["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == Set(HookSettings.events))
        let groups = try #require(hooks["Stop"] as? [[String: Any]])
        let handler = try #require((groups.first?["hooks"] as? [[String: Any]])?.first)
        #expect(handler["command"] as? String == "'/Users/me/My Apps/Notchmeter.app/Contents/MacOS/Notchmeter' --hook")
        #expect(handler["async"] as? Bool == true)
        #expect(handler["timeout"] as? Int == 5)
        #expect(HookSettings.command(executable: "/it's/here") == "'/it'\\''s/here' --hook")

        // Every vendor's snippet parses, covers exactly its events, and every handler carries that event's flag.
        for vendor in HookVendor.allCases {
            let rendered = HookSettings.snippet(vendor: vendor, executable: "/Users/me/My Apps/Notchmeter.app/Contents/MacOS/Notchmeter")
            let object = try #require(try JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any], "\(vendor.rawValue)")
            let events = try #require(object["hooks"] as? [String: Any], "\(vendor.rawValue)")
            #expect(Set(events.keys) == Set(vendor.events), "\(vendor.rawValue)")
            for (key, value) in vendor.shape.requiredRootKeys {
                #expect((object[key] as? Int) == (value as? Int), "\(vendor.rawValue): \(key)")
            }
            for event in vendor.events {
                let elements = try #require(events[event] as? [[String: Any]], "\(vendor.rawValue) \(event)")
                let handlers = elements.flatMap(vendor.shape.handlers(in:))
                #expect(handlers.count == 1, "\(vendor.rawValue) \(event)")
                let command = try #require(handlers.first?["command"] as? String, "\(vendor.rawValue) \(event)")
                #expect(command == "'/Users/me/My Apps/Notchmeter.app/Contents/MacOS/Notchmeter' \(vendor.flag(for: event))", "\(vendor.rawValue) \(event)")
            }
        }
    }

    @Test func mergeKeepsExistingHooksAndIsIdempotent() throws {
        let existing: [String: Any] = [
            "model": "opus",
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": "/usr/local/bin/worklog.sh", "timeout": 15]]]],
                "SessionStart": [["matcher": "startup|resume", "hooks": [["type": "command", "command": "/usr/local/bin/verify.sh"]]]],
                "PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "/usr/local/bin/guard.sh"]]]],
            ],
        ]
        let first = HookSettings.merge(into: existing, executable: executable)
        #expect(first.added == HookSettings.events)
        #expect(first.present.isEmpty)
        #expect(first.settings["model"] as? String == "opus")
        let hooks = try #require(first.settings["hooks"] as? [String: Any])
        let stop = try #require(hooks["Stop"] as? [[String: Any]])
        #expect(stop.count == 2)
        #expect((stop[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String == "/usr/local/bin/worklog.sh")
        #expect((stop[1]["hooks"] as? [[String: Any]])?.first?["command"] as? String == "'\(executable)' --hook")
        let start = try #require(hooks["SessionStart"] as? [[String: Any]])
        #expect(start[0]["matcher"] as? String == "startup|resume")
        #expect(start.count == 2)
        #expect((hooks["PreToolUse"] as? [[String: Any]])?.count == 1)

        let second = HookSettings.merge(into: first.settings, executable: "/somewhere/else/Notchmeter")
        #expect(second.added.isEmpty)
        #expect(second.present == HookSettings.events)
        #expect((second.settings["hooks"] as? [String: Any])?.keys.count == hooks.keys.count)
    }

    @Test func installBacksUpFirstAndKeepsPermissions() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("notchmeter-hook-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        let original = #"{"env":{"KEY":"secret"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/local/bin/worklog.sh"}]}]}}"#
        try Data(original.utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        let now = Date(timeIntervalSince1970: 1_788_300_000)
        let installed = try HookSettings.install(at: url, executable: executable, now: now)
        #expect(installed.added == HookSettings.events)
        let backup = try #require(installed.backup)
        #expect(backup.lastPathComponent.hasPrefix("settings.json.bak-2026"))
        #expect(try String(contentsOf: backup, encoding: .utf8) == original)
        #expect((try fm.attributesOfItem(atPath: url.path))[.posixPermissions] as? Int == 0o600)

        let written = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect((written["env"] as? [String: Any])?["KEY"] as? String == "secret")
        let stop = try #require((written["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        #expect(stop.count == 2)
        #expect(!(try String(contentsOf: url, encoding: .utf8)).contains("\\/"))

        let again = try HookSettings.install(at: url, executable: executable, now: now.addingTimeInterval(60))
        #expect(again.added.isEmpty)
        #expect(again.backup == nil)
        #expect(try fm.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".bak-") }.count == 1)

        let missing = dir.appendingPathComponent("fresh/settings.json")
        let created = try HookSettings.install(at: missing, executable: executable, now: now)
        #expect(created.backup == nil)
        #expect(created.added == HookSettings.events)
        #expect(fm.fileExists(atPath: missing.path))

        try Data("[1,2]".utf8).write(to: url)
        #expect(throws: HookSettings.Failure.self) {
            try HookSettings.install(at: url, executable: executable, now: now)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "[1,2]")
    }

    /// The launch repair rewrites whatever `status` calls `.partial`, so an entry written by hand at the right path
    /// (an unquoted path, a redirect or a `|| true` after the flag) must read `.installed`: it did before Cursor's
    /// round, and a settings.json rewritten at every launch would be a new thing Claude Code's users saw.
    @Test func aHandWrittenEntryAtTheRightPathIsInstalledAndNotRepairedAtLaunch() {
        for command in ["\(executable) --hook", "'\(executable)' --hook 2>/dev/null", "'\(executable)' --hook || true"] {
            var hooks: [String: Any] = [:]
            for event in HookSettings.events { hooks[event] = [["hooks": [["type": "command", "command": command]]]] }
            let status = HookSettings.status(settings: ["hooks": hooks], executable: executable)
            #expect(status == .installed(path: executable), "\(command): the path and the flag are what count")
            #expect(!status.needsRepair, "\(command): nothing for the launch repair to rewrite")
        }
    }
}

@Suite struct ActivitySampling {
    @Test func findsTheNewestFileInRecentProjectFolders() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("notchmeter-activity-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let projects = dir.appendingPathComponent("projects")
        let old = projects.appendingPathComponent("-old")
        let deep = projects.appendingPathComponent("-live/session/subagents")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try fm.createDirectory(at: deep, withIntermediateDirectories: true)
        let stale = Date(timeIntervalSinceNow: -7200)
        let fresh = Date(timeIntervalSinceNow: -30)
        func write(_ url: URL, modified: Date) throws {
            try Data("{}".utf8).write(to: url)
            try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        try write(old.appendingPathComponent("a.jsonl"), modified: stale)
        try write(deep.appendingPathComponent("agent.jsonl"), modified: fresh)
        for folder in [old, deep, projects.appendingPathComponent("-live/session"), projects.appendingPathComponent("-live")] {
            try fm.setAttributes([.modificationDate: stale], ofItemAtPath: folder.path)
        }
        let newest = try #require(AgentActivity.newestClaude(projects: projects))
        #expect(abs(newest.timeIntervalSince(fresh)) < 1)
        #expect(AgentActivity.newestClaude(projects: dir.appendingPathComponent("missing")) == nil)

        let sessions = dir.appendingPathComponent("sessions")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        let today = sessions.appendingPathComponent(formatter.string(from: Date()))
        try fm.createDirectory(at: today, withIntermediateDirectories: true)
        try write(today.appendingPathComponent("rollout.jsonl"), modified: fresh)
        let codex = try #require(AgentActivity.newestCodex(sessions: sessions, now: Date()))
        #expect(abs(codex.timeIntervalSince(fresh)) < 1)

        let database = dir.appendingPathComponent("state.vscdb")
        try write(database, modified: stale)
        try write(URL(fileURLWithPath: database.path + "-wal"), modified: fresh)
        let cursor = try #require(AgentActivity.newestCursor(database: database))
        #expect(abs(cursor.timeIntervalSince(fresh)) < 1)
    }
}


/// The round-2 hook fields: the branch from `.git`, the permission mode, subagents, StopFailure, the quota
/// auto-resume types, the events the installer adds, and the launch-time repair being idempotent.
@Suite struct HookRoundTwo {
    init() { Localization.use(language: "en") }

    @Test func forwardsPermissionModeAgentIdAndAStopFailuresKind() throws {
        let plan = try #require(Hook.message(from: Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"s","cwd":"/x/notchmeter","permission_mode":"plan"}"#.utf8), branch: { _ in nil }))
        #expect(plan.permissionMode == "plan")
        #expect(Hook.permissionBadge("plan") == "plan")
        #expect(Hook.permissionBadge("bypassPermissions") == "bypass")
        #expect(Hook.permissionBadge("auto") == "auto")
        #expect(Hook.permissionBadge("default") == nil)
        #expect(Hook.permissionBadge("acceptEdits") == nil)
        let agent = try #require(Hook.message(from: Data(#"{"hook_event_name":"SubagentStart","session_id":"s","agent_id":"a1","agent_type":"Explore"}"#.utf8), branch: { _ in nil }))
        #expect(agent.agentID == "a1")
        let failure = try #require(Hook.message(from: Data(#"{"hook_event_name":"StopFailure","session_id":"s","error":"rate_limit","error_message":"You've hit your limit"}"#.utf8), branch: { _ in nil }))
        #expect(failure.failure == "rate_limit")
        #expect(failure.hitRateLimit)
        #expect(failure.clearsWaiting)
        let overloaded = try #require(Hook.message(from: Data(#"{"hook_event_name":"StopFailure","session_id":"s","error":"overloaded"}"#.utf8), branch: { _ in nil }))
        #expect(!overloaded.hitRateLimit)
        let stop = try #require(Hook.message(from: Data(#"{"hook_event_name":"Stop","session_id":"s","error":"rate_limit"}"#.utf8), branch: { _ in nil }))
        #expect(stop.failure == nil)
        let info = failure.userInfo
        #expect(info[Hook.failureKey] as? String == "rate_limit")
        #expect(Hook.Message(userInfo: info) == failure)
        let full = Hook.Message(event: "SubagentStart", needsInput: false, sessionID: "s", project: "p", branch: "main", permissionMode: "auto", agentID: "a", failure: nil, host: "box")
        #expect(Hook.Message(userInfo: full.userInfo) == full)
        #expect(Set(full.userInfo.keys) == ["hook_event_name", "needsInput", "session_id", "project", "branch", "permission_mode", "agent_id", "host"])
    }

    @Test func readsTheBranchFromDotGitWithoutForkingGit() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("notchmeter-git-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let repo = dir.appendingPathComponent("repo")
        try fm.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("ref: refs/heads/feat/hooks\n".utf8).write(to: repo.appendingPathComponent(".git/HEAD"))
        #expect(Hook.gitBranch(cwd: repo.path) == "feat/hooks")
        let message = try #require(Hook.message(from: Data("{\"hook_event_name\":\"Stop\",\"cwd\":\"\(repo.path)\"}".utf8)))
        #expect(message.branch == "feat/hooks")
        #expect(message.project == "repo")
        try Data("0123456789abcdef0123456789abcdef01234567\n".utf8).write(to: repo.appendingPathComponent(".git/HEAD"))
        #expect(Hook.gitBranch(cwd: repo.path) == nil)
        let worktree = dir.appendingPathComponent("wt")
        try fm.createDirectory(at: worktree, withIntermediateDirectories: true)
        try fm.createDirectory(at: repo.appendingPathComponent(".git/worktrees/wt"), withIntermediateDirectories: true)
        try Data("gitdir: \(repo.path)/.git/worktrees/wt\n".utf8).write(to: worktree.appendingPathComponent(".git"))
        try Data("ref: refs/heads/release/1.0\n".utf8).write(to: repo.appendingPathComponent(".git/worktrees/wt/HEAD"))
        #expect(Hook.gitBranch(cwd: worktree.path) == "release/1.0")
        #expect(Hook.gitBranch(cwd: dir.path) == nil)
    }

    @Test func quotaAutoResumeTypesEndOrExtendAWait() {
        #expect(Hook.Message(event: "Notification", needsInput: false, notificationType: "quota_auto_resume_fired").resumesFromQuota)
        #expect(Hook.Message(event: "Notification", needsInput: false, notificationType: "quota_auto_resume_fired").clearsWaiting)
        #expect(Hook.Message(event: "Notification", needsInput: false, notificationType: "quota_auto_resume_stale").waitsOnQuota)
        #expect(Hook.Message(event: "Notification", needsInput: false, notificationType: "quota_auto_resume_disabled").waitsOnQuota)
        #expect(!Hook.Message(event: "Notification", needsInput: false, notificationType: "auth_success").waitsOnQuota)
        #expect(!Hook.needsInput(event: "Notification", notificationType: "quota_auto_resume_stale"))
    }

    @Test func installerCoversSubagentsAndStopFailureAndRepairAddsThemToAnOlderInstall() throws {
        #expect(HookSettings.events.contains("SubagentStart"))
        #expect(HookSettings.events.contains("SubagentStop"))
        #expect(HookSettings.events.contains("StopFailure"))
        let executable = "/Applications/Notchmeter.app/Contents/MacOS/Notchmeter"
        var older = HookSettings.merge(into: [:], executable: executable).settings
        var hooks = older["hooks"] as? [String: Any] ?? [:]
        hooks["SubagentStart"] = nil
        hooks["SubagentStop"] = nil
        hooks["StopFailure"] = nil
        older["hooks"] = hooks
        #expect(HookSettings.status(settings: older, executable: executable) == .partial(path: executable),
                "the path is this executable; what is missing is an event, and the row must not claim an old path")
        #expect(HookSettings.status(settings: older, executable: executable).needsRepair)
        let repaired = HookSettings.repair(older, executable: executable)
        #expect(Set(repaired.added) == ["SubagentStart", "SubagentStop", "StopFailure"])
        #expect(repaired.repaired.isEmpty)
        #expect(HookSettings.status(settings: repaired.settings, executable: executable) == .installed(path: executable))
        let again = HookSettings.repair(repaired.settings, executable: executable)
        #expect(again.added.isEmpty)
        #expect(again.repaired.isEmpty)
        #expect(NSDictionary(dictionary: again.settings) == NSDictionary(dictionary: repaired.settings))
    }

    @Test func launchRepairRewritesOnlyNotchmetersEntriesOnceAndIsIdempotent() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("notchmeter-repair-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        let old = "/Users/me/Downloads/Notchmeter.app/Contents/MacOS/Notchmeter"
        let new = "/Applications/Notchmeter.app/Contents/MacOS/Notchmeter"
        var settings = HookSettings.merge(into: ["hooks": ["Stop": [["hooks": [["type": "command", "command": "/usr/local/bin/worklog.sh"]]]]]], executable: old).settings
        settings["statusLine"] = ["type": "command", "command": HookSettings.command(executable: old, flag: "--statusline"), "padding": 0]
        try JSONSerialization.data(withJSONObject: settings).write(to: url)
        #expect(HookSettings.status(at: url, executable: new) == .stale(path: old))
        #expect(HookSettings.statuslineStatus(at: url, executable: new) == .stale(path: old))
        let now = Date(timeIntervalSince1970: 1_788_300_000)
        let first = try HookSettings.repairInstall(at: url, executable: new, now: now)
        #expect(first.backup != nil)
        #expect(first.added.count == HookSettings.events.count)
        let statusline = try HookSettings.installStatusline(at: url, executable: new, now: now.addingTimeInterval(1))
        #expect(statusline.previous == nil)
        #expect(HookSettings.status(at: url, executable: new) == .installed(path: new))
        #expect(HookSettings.statuslineStatus(at: url, executable: new) == .installed(path: new))
        let written = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let stop = try #require((written["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        #expect((stop[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String == "/usr/local/bin/worklog.sh")
        let second = try HookSettings.repairInstall(at: url, executable: new, now: now.addingTimeInterval(120))
        #expect(second.backup == nil)
        #expect(second.added.isEmpty)
        #expect(try HookSettings.installStatusline(at: url, executable: new, now: now.addingTimeInterval(121)).backup == nil)
        #expect(try fm.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".bak-") }.count == 2)
    }
}
