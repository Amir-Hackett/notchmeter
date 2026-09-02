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
        #expect(HookSettings.status(settings: older, executable: executable) == .stale(path: executable))
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
