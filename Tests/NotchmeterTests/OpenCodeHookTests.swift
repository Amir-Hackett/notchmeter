import Foundation
import Testing
@testable import Notchmeter

/// OpenCode's plugin payloads read onto the Message Claude Code's hook fills (Hook+OpenCode.swift). Every test parses
/// the JSON the plugin writes (OpenCodePlugin.source), because the parser is the whole contract between the two.
@Suite struct OpenCodeHookMessages {
    func parse(_ json: String, tool: ToolID? = .opencode) -> Hook.Message? {
        Hook.message(from: Data(json.utf8), tool: tool, environment: [:], branch: { $0 == "/Users/x/proj" ? "main" : nil })
    }

    @Test func everyForwardedEventLandsOnTheTrackersVocabulary() throws {
        let rows: [(json: String, event: String)] = [
            (#"{"hook_event_name":"session.created","session_id":"ses_1","cwd":"/Users/x/proj"}"#, "SessionStart"),
            (#"{"hook_event_name":"session.status","session_id":"ses_1","status":"busy","cwd":"/Users/x/proj"}"#, "UserPromptSubmit"),
            (#"{"hook_event_name":"session.status","session_id":"ses_1","status":"idle","cwd":"/Users/x/proj"}"#, "Stop"),
            (#"{"hook_event_name":"session.status","session_id":"ses_1","status":"retry","cwd":"/Users/x/proj"}"#, "session.status"),
            (#"{"hook_event_name":"session.idle","session_id":"ses_1","cwd":"/Users/x/proj"}"#, "Stop"),
            (#"{"hook_event_name":"session.error","session_id":"ses_1","error":"APIError","cwd":"/Users/x/proj"}"#, "StopFailure"),
            (#"{"hook_event_name":"session.deleted","session_id":"ses_1","cwd":"/Users/x/proj"}"#, "SessionEnd"),
            (#"{"hook_event_name":"permission.asked","session_id":"ses_1","permission":"bash","cwd":"/Users/x/proj"}"#, "Notification"),
            (#"{"hook_event_name":"permission.replied","session_id":"ses_1","cwd":"/Users/x/proj"}"#, "Notification"),
        ]
        for row in rows {
            let message = try #require(parse(row.json), "\(row.json)")
            #expect(message.event == row.event, "\(row.json)")
            #expect(message.tool == .opencode)
            #expect(message.sessionID == "ses_1")
            #expect(message.project == "proj")
            #expect(message.branch == "main")
            #expect(message.source == .hook)
        }
    }

    @Test func thePromptsFirstLineIsTheTitle() throws {
        let message = try #require(parse(#"{"hook_event_name":"chat.message","session_id":"ses_1","prompt":"Paginate the audit log\nand add tests","cwd":"/Users/x/proj"}"#))
        #expect(message.event == "UserPromptSubmit")
        #expect(message.title == "Paginate the audit log")
        #expect(Hook.Message(userInfo: message.userInfo) == message, "the tool and the title survive the socket line")
    }

    @Test func aPermissionIsTheWaitAndItsReplyEndsIt() throws {
        let asked = try #require(parse(#"{"hook_event_name":"permission.asked","session_id":"ses_1","permission":"edit"}"#))
        #expect(asked.needsInput)
        #expect(asked.waitKind == .permission)
        #expect(asked.request == nil, "the plugin observes permissions and never answers them")
        let replied = try #require(parse(#"{"hook_event_name":"permission.replied","session_id":"ses_1"}"#))
        #expect(!replied.needsInput)
        #expect(replied.clearsWaiting)
        var tracker = SessionTracker()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        tracker.apply(try #require(parse(#"{"hook_event_name":"chat.message","session_id":"ses_1"}"#)), now: now)
        let waiting = tracker.apply(asked, now: now.addingTimeInterval(5))
        #expect(waiting.startedWaiting != nil)
        #expect(tracker.waiting(of: .opencode).count == 1)
        let resumed = tracker.apply(replied, now: now.addingTimeInterval(9))
        #expect(resumed.stoppedWaiting == ["opencode:ses_1"], "OpenCode says when it was answered, so the hand comes down at once")
        #expect(tracker.isWorking(.opencode))
        let stopped = tracker.apply(try #require(parse(#"{"hook_event_name":"session.idle","session_id":"ses_1"}"#)), now: now.addingTimeInterval(30))
        #expect(stopped.finished?.turn == 30)
    }

    @Test func aFailedTurnSaysWhyAndA429PlansTheLimit() throws {
        let aborted = try #require(parse(#"{"hook_event_name":"session.error","session_id":"s","error":"MessageAbortedError"}"#))
        #expect(aborted.failure == "aborted")
        #expect(!aborted.hitRateLimit)
        let limited = try #require(parse(#"{"hook_event_name":"session.error","session_id":"s","error":"APIError","status_code":429}"#))
        #expect(limited.failure == "rate_limit")
        #expect(limited.hitRateLimit)
        let other = try #require(parse(#"{"hook_event_name":"session.error","session_id":"s","error":"ProviderAuthError"}"#))
        #expect(other.failure == "error")
    }

    @Test func aSubagentsSessionCountsOnItsParent() throws {
        let start = try #require(parse(#"{"hook_event_name":"session.created","session_id":"ses_p","agent_id":"ses_c"}"#))
        #expect(start.event == "SubagentStart")
        #expect(start.agentID == "ses_c")
        #expect(start.sessionID == "ses_p")
        for name in ["session.idle", "session.error", "session.deleted"] {
            #expect(try #require(parse(#"{"hook_event_name":"\#(name)","session_id":"ses_p","agent_id":"ses_c"}"#)).event == "SubagentStop", "\(name)")
        }
        let childPrompt = try #require(parse(#"{"hook_event_name":"chat.message","session_id":"ses_p","agent_id":"ses_c","prompt":"x"}"#))
        #expect(childPrompt.event != "UserPromptSubmit", "a subagent's prompt is not a new turn of the user's session")
    }

    @Test func aDottedNameIsOpenCodesWithoutTheFlag() throws {
        let message = try #require(parse(#"{"hook_event_name":"session.idle","session_id":"ses_1"}"#, tool: nil))
        #expect(message.tool == .opencode)
        #expect(Hook.OpenCode.recognises(event: "permission.asked"))
        #expect(!Hook.OpenCode.recognises(event: "Stop"))
        #expect(!Hook.OpenCode.recognises(event: "tool.execute.before"), "only the names the plugin sends")
        let claude = try #require(parse(#"{"hook_event_name":"Stop","session_id":"x"}"#, tool: nil))
        #expect(claude.tool == .claude)
    }
}

/// The plugin file: what it says, how its status is judged, and how it is written (the consent-and-backup flow every
/// hook goes through, reached through HookSettings so every caller stays vendor-blind).
@Suite struct OpenCodePluginFile {
    let executable = "/Applications/Notchmeter.app/Contents/MacOS/Notchmeter"

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-opencode-plugin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func theModuleNamesTheExecutableItsVersionAndEveryEvent() {
        let source = OpenCodePlugin.source(executable: executable)
        #expect(source.contains(#"const NOTCHMETER = "/Applications/Notchmeter.app/Contents/MacOS/Notchmeter""#))
        #expect(source.contains(#"["--hook", "--tool", "opencode"]"#))
        #expect(source.contains("notchmeter-plugin-version: \(OpenCodePlugin.version)"))
        #expect(source.contains("export const NotchmeterPlugin"))
        for event in OpenCodePlugin.events { #expect(source.contains(#""\#(event)""#), "\(event)") }
        #expect(!source.contains("fetch("), "the plugin talks to nothing but the app's own command")
        #expect(OpenCodePlugin.executable(in: source) == executable)
        #expect(OpenCodePlugin.installedVersion(in: source) == OpenCodePlugin.version)
    }

    @Test func aPathWithQuotesCannotBreakOutOfItsString() {
        let odd = #"/Users/o"brien/Apps/No\tch "x".app/Contents/MacOS/Notchmeter"#
        let source = OpenCodePlugin.source(executable: odd)
        #expect(OpenCodePlugin.executable(in: source) == odd, "the path is written as a JSON string literal and read back the same")
    }

    @Test func theStatusIsJudgedOnThePathAndTheVersion() {
        #expect(OpenCodePlugin.status(text: nil, executable: executable) == .notInstalled)
        #expect(OpenCodePlugin.status(text: "export const Mine = async () => ({})", executable: executable) == .notInstalled,
                "a file that is not ours is not an install of ours")
        #expect(OpenCodePlugin.status(text: OpenCodePlugin.source(executable: executable), executable: executable) == .installed(path: executable))
        #expect(OpenCodePlugin.status(text: OpenCodePlugin.source(executable: "/old/Notchmeter"), executable: executable) == .stale(path: "/old/Notchmeter"))
        let older = OpenCodePlugin.source(executable: executable).replacingOccurrences(of: "notchmeter-plugin-version: \(OpenCodePlugin.version)",
                                                                                     with: "notchmeter-plugin-version: 0")
        #expect(OpenCodePlugin.status(text: older, executable: executable) == .partial(path: executable))
        #expect(OpenCodePlugin.status(text: older, executable: executable).needsRepair)
        let edited = OpenCodePlugin.source(executable: executable) + "\n// my own note\n"
        #expect(OpenCodePlugin.status(text: edited, executable: executable) == .installed(path: executable), "an edit of the user's own is theirs to keep")
    }

    @Test func installingWritesTheFileBacksUpWhatWasThereAndIsIdempotent() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("plugins/notchmeter.js")
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let first = try HookSettings.install(vendor: .opencode, at: url, executable: executable, now: now)
        #expect(first.added == ["notchmeter.js"])
        #expect(first.backup == nil, "nothing was there to back up")
        #expect(HookSettings.status(vendor: .opencode, at: url, executable: executable) == .installed(path: executable))
        let again = try HookSettings.install(vendor: .opencode, at: url, executable: executable, now: now)
        #expect(again.added.isEmpty, "the current plugin is not rewritten")
        // A file of the user's own at the path is copied aside before it is replaced, under a name OpenCode does not load.
        try Data("export const Mine = async () => ({})".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let replaced = try HookSettings.install(vendor: .opencode, at: url, executable: executable, now: now.addingTimeInterval(60))
        let backup = try #require(replaced.backup)
        #expect(backup.lastPathComponent.hasPrefix("notchmeter.js.bak-"))
        #expect(backup.pathExtension != "js")
        #expect(try String(contentsOf: backup, encoding: .utf8) == "export const Mine = async () => ({})")
        #expect(try String(contentsOf: url, encoding: .utf8) == OpenCodePlugin.source(executable: executable))
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                "the replaced file's permissions are kept")
    }

    @Test func repairRepointsAMovedApp() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notchmeter.js")
        try Data(OpenCodePlugin.source(executable: "/old/Notchmeter").utf8).write(to: url)
        #expect(HookSettings.status(vendor: .opencode, at: url, executable: executable).needsRepair)
        let repaired = try HookSettings.repairInstall(vendor: .opencode, at: url, executable: executable)
        #expect(repaired.backup != nil)
        #expect(HookSettings.status(vendor: .opencode, at: url, executable: executable) == .installed(path: executable))
    }

    @Test func theVendorIsWiredLikeEveryOther() {
        let vendor = HookVendor.opencode
        #expect(vendor.tool == .opencode)
        #expect(HookVendor.vendor(for: .opencode) == .opencode)
        #expect(vendor.displayName == "OpenCode")
        #expect(vendor.fileName == "notchmeter.js")
        #expect(vendor.shape == .pluginModule)
        #expect(vendor.decidingEvents.isEmpty)
        #expect(vendor.flag == "--hook --tool opencode")
        #expect(!vendor.reloadsLive)
        #expect(HookSettings.snippet(vendor: .opencode, executable: executable) == OpenCodePlugin.source(executable: executable))
        #expect(Hook.tool(in: ["Notchmeter", "--hook", "--tool", "opencode"]) == .opencode)
    }
}
