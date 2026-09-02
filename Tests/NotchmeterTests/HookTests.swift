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
