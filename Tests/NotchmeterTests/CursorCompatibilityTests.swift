import Foundation
import Testing
@testable import Notchmeter

/// The Cursor hook payloads Notchmeter has to keep reading, one sanitized fixture per shape Cursor has shipped:
/// the first hooks release (1.7: ids, roots and the prompt), 2.x (model, transcript, version and the user's
/// email), the current one (composer mode, background agents, tool failures, compaction fill) and a future one
/// with names nothing here knows. Every id, path and address is made up; the values that must never reach a
/// Message carry a marker so a leak is a substring search.
@Suite struct CursorCompatibilityManifest {
    static let secret = "SECRET-MARKER"

    struct Fixture {
        let era: String
        let json: String
        let event: String
    }

    static let fixtures: [Fixture] = [
        Fixture(era: "1.7", json: #"{"hook_event_name":"beforeSubmitPrompt","conversation_id":"c-17","generation_id":"g1","prompt":"Fix the login\nSECRET-MARKER","attachments":[],"workspace_roots":["/Users/x/proj"]}"#, event: "UserPromptSubmit"),
        Fixture(era: "1.7", json: #"{"hook_event_name":"stop","conversation_id":"c-17","generation_id":"g1","status":"completed","workspace_roots":["/Users/x/proj"]}"#, event: "Stop"),
        Fixture(era: "1.7", json: #"{"hook_event_name":"beforeShellExecution","conversation_id":"c-17","command":"ls","cwd":"/Users/x/proj","workspace_roots":["/Users/x/proj"]}"#, event: "beforeShellExecution"),
        Fixture(era: "2.x", json: #"{"hook_event_name":"sessionStart","conversation_id":"c-20","model":"claude-4.5-sonnet","cursor_version":"2.0.0","user_email":"SECRET-MARKER@example.com","transcript_path":null,"workspace_roots":["/Users/x/proj"]}"#, event: "SessionStart"),
        Fixture(era: "2.x", json: #"{"hook_event_name":"subagentStart","conversation_id":"c-sub","parent_conversation_id":"c-20","subagent_id":"s1","cursor_version":"2.1.0","workspace_roots":["/Users/x/proj"]}"#, event: "SubagentStart"),
        Fixture(era: "2.x", json: #"{"hook_event_name":"stop","conversation_id":"c-20","status":"aborted","cursor_version":"2.1.0","workspace_roots":["/Users/x/proj"]}"#, event: "StopFailure"),
        Fixture(era: "current", json: #"{"hook_event_name":"sessionStart","conversation_id":"c-now","composer_mode":"Plan","is_background_agent":true,"cursor_version":"3.0.0","workspace_roots":["/Users/x/proj"]}"#, event: "SessionStart"),
        Fixture(era: "current", json: #"{"hook_event_name":"postToolUseFailure","conversation_id":"c-now","tool_name":"Shell","tool_input":{"command":"SECRET-MARKER"},"error_message":"SECRET-MARKER","is_interrupt":true,"workspace_roots":["/Users/x/proj"]}"#, event: "PostToolUseFailure"),
        Fixture(era: "current", json: #"{"hook_event_name":"preCompact","conversation_id":"c-now","trigger":"auto","context_usage_percent":87,"workspace_roots":["/Users/x/proj"]}"#, event: "PreCompact"),
        Fixture(era: "current", json: #"{"hook_event_name":"beforeSubmitPrompt","conversation_id":"c-now","prompt":"Implement the plan as specified, it is attached for your reference. SECRET-MARKER","attachments":[],"workspace_roots":["/Users/x/proj"]}"#, event: "UserPromptSubmit"),
        Fixture(era: "future", json: #"{"hook_event_name":"sessionStart","conversation_id":"c-next","composer_mode":"galaxy","is_background_agent":"yes","hologram":{"x":1},"workspace_roots":["/Users/x/proj"]}"#, event: "SessionStart"),
        Fixture(era: "future", json: #"{"hook_event_name":"preCompact","conversation_id":"c-next","context_usage_percent":"lots","trigger":"warp","workspace_roots":["/Users/x/proj"]}"#, event: "PreCompact"),
        Fixture(era: "future", json: #"{"hook_event_name":"afterQuantumLeap","conversation_id":"c-next","workspace_roots":["/Users/x/proj"]}"#, event: "afterQuantumLeap"),
        // What Cursor 3.23.12 sent a recorder on 2026-10-03, key for key, during a plan's Build with one command
        // allowed, one denied from the notch and one handed back: the ids, paths, address and words replaced.
        Fixture(era: "3.23.12", json: #"{"attachments":[],"composer_mode":"agent","conversation_id":"c-live","cursor_version":"3.23.12","generation_id":"g-live","hook_event_name":"beforeSubmitPrompt","model":"cursor-grok-4.6-medium","model_id":"grok-4.6","model_params":[{"id":"effort","value":"medium"},{"id":"fast","value":"false"}],"prompt":"Implement the plan as specified, it is attached for your reference. Do NOT edit the plan file itself.\n\nTo-do's from the plan have already been created. SECRET-MARKER","session_id":"c-live","transcript_path":"/Users/x/.cursor/projects/proj/agent-transcripts/c-live/c-live.jsonl","user_email":"SECRET-MARKER@example.com","workspace_roots":["/Users/x/proj"]}"#, event: "UserPromptSubmit"),
        Fixture(era: "3.23.12", json: #"{"command":"echo SECRET-MARKER","conversation_id":"c-live","cursor_version":"3.23.12","cwd":"","generation_id":"g-live","hook_event_name":"beforeShellExecution","model":"grok-4.6","sandbox":true,"session_id":"c-live","transcript_path":"/Users/x/.cursor/projects/proj/agent-transcripts/c-live/c-live.jsonl","user_email":"SECRET-MARKER@example.com","workspace_roots":["/Users/x/proj"]}"#, event: "beforeShellExecution"),
        Fixture(era: "3.23.12", json: #"{"command":"echo SECRET-MARKER","conversation_id":"c-live","cursor_version":"3.23.12","duration":2033.566,"generation_id":"g-live","hook_event_name":"afterShellExecution","model":"grok-4.6","output":"SECRET-MARKER\n","sandbox":true,"session_id":"c-live","transcript_path":"/Users/x/.cursor/projects/proj/agent-transcripts/c-live/c-live.jsonl","user_email":"SECRET-MARKER@example.com","workspace_roots":["/Users/x/proj"]}"#, event: "afterShellExecution"),
        Fixture(era: "3.23.12", json: #"{"conversation_id":"c-live","cursor_version":"3.23.12","cwd":"","duration":0,"error_message":"Command execution was blocked by a hook: SECRET-MARKER","failure_type":"permission_denied","generation_id":"g-live","hook_event_name":"postToolUseFailure","is_interrupt":false,"model":"grok-4.6","session_id":"c-live","tool_input":{"command":"echo SECRET-MARKER","cwd":"","timeout":30000},"tool_name":"Shell","tool_use_id":"t-live","transcript_path":"/Users/x/.cursor/projects/proj/agent-transcripts/c-live/c-live.jsonl","user_email":"SECRET-MARKER@example.com","workspace_roots":["/Users/x/proj"]}"#, event: "PostToolUseFailure"),
        Fixture(era: "3.23.12", json: #"{"conversation_id":"c-live","cursor_version":"3.23.12","duration_ms":895,"generation_id":"g-live","hook_event_name":"afterAgentThought","model":"cursor-grok-4.6-medium","model_id":"grok-4.6","model_params":[{"id":"effort","value":"medium"}],"session_id":"c-live","text":"SECRET-MARKER","transcript_path":"/Users/x/.cursor/projects/proj/agent-transcripts/c-live/c-live.jsonl","user_email":"SECRET-MARKER@example.com","workspace_roots":["/Users/x/proj"]}"#, event: "afterAgentThought"),
        Fixture(era: "3.23.12", json: #"{"cache_read_tokens":205952,"cache_write_tokens":0,"conversation_id":"c-live","cursor_version":"3.23.12","generation_id":"g-live","hook_event_name":"stop","input_tokens":209917,"loop_count":0,"model":"cursor-grok-4.6-medium","model_id":"grok-4.6","model_params":[{"id":"effort","value":"medium"}],"output_tokens":654,"session_id":"c-live","status":"completed","transcript_path":"/Users/x/.cursor/projects/proj/agent-transcripts/c-live/c-live.jsonl","user_email":"SECRET-MARKER@example.com","workspace_roots":["/Users/x/proj"]}"#, event: "Stop"),
    ]

    func parse(_ fixture: Fixture) -> Hook.Message? {
        Hook.message(from: Data(fixture.json.utf8), tool: .cursor, environment: [:], branch: { _ in nil },
                     requestID: "r1", cursorApproval: false)
    }

    @Test(arguments: fixtures.indices)
    func everyShippedShapeParsesOntoTheTrackersVocabulary(index: Int) throws {
        let fixture = Self.fixtures[index]
        let message = try #require(parse(fixture), "\(fixture.era) \(fixture.event)")
        #expect(message.event == fixture.event, "\(fixture.era)")
        #expect(message.tool == .cursor)
        #expect(message.sessionID?.hasPrefix("c-") == true, "\(fixture.era) \(fixture.event) lost its session")
        #expect(message.project == "proj")
        #expect(message.request == nil, "with approval off nothing is held, in any era")
    }

    @Test(arguments: fixtures.indices)
    func noFixtureLeaksWhatNotchmeterPromisesNotToRead(index: Int) throws {
        let fixture = Self.fixtures[index]
        let message = try #require(parse(fixture))
        #expect(!String(describing: message.userInfo).contains(Self.secret), "\(fixture.era) \(fixture.event) leaked")
    }

    @Test func newerFieldsAreReadWhereTheyExistAndAbsentBeforeThem() throws {
        let old = try #require(parse(Self.fixtures[0]))
        #expect(old.composerMode == nil && !old.background && old.context == nil && old.planFile == nil)
        let mode = try #require(parse(Self.fixtures[6]))
        #expect(mode.composerMode == "plan" && mode.background)
        let failure = try #require(parse(Self.fixtures[7]))
        #expect(failure.toolFailure?.tool == "Shell" && failure.toolFailure?.interrupt == true)
        let compact = try #require(parse(Self.fixtures[8]))
        #expect(compact.context == 0.87)
        let build = try #require(parse(Self.fixtures[9]))
        #expect(build.harnessTurn, "a Build whose plan cannot be read is the harness's turn, not the user's")
    }

    @Test func whatCursorReallySendsOnABuildIsReadAsOne() throws {
        let live = Self.fixtures.filter { $0.era == "3.23.12" }
        let build = try #require(parse(live[0]))
        #expect(build.planBuild && build.composerMode == "agent")
        #expect(build.planFile == nil && build.title == nil && build.harnessTurn,
                "Cursor attaches no plan file to its Build prompt, so the app names the turn from the chat's own plan")
        #expect(build.reportedModel == "cursor-grok-4.6-medium")

        // The command it denied from the notch came back as a failure of type permission_denied: an answer, and no
        // step towards "may be stuck".
        let denied = try #require(parse(live[3]))
        #expect(denied.toolFailure == ToolFailure(tool: "Shell", interrupt: true))
        var tracker = SessionTracker()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        _ = tracker.apply(build, now: t0)
        for second in 1...6 { _ = tracker.apply(denied, now: t0.addingTimeInterval(TimeInterval(second))) }
        let session = try #require(tracker.sessions[SessionTracker.key(tool: .cursor, session: "c-live", host: nil)])
        #expect(session.failureStreaks.isEmpty, "six denials in a row are six answers")

        // The same shell call with Require notch approval on: held, with the command as its summary; `cwd` comes
        // empty and is no folder.
        let held = try #require(Hook.message(from: Data(live[1].json.utf8), tool: .cursor, environment: [:], branch: { _ in nil },
                                             requestID: "r1", cursorApproval: true))
        #expect(held.needsInput && held.request?.id == "r1")
        guard case .permission(let tool, _, _, _)? = held.request?.kind else { Issue.record("a held shell call is a permission request"); return }
        #expect(tool == Hook.Cursor.shellTool)
        #expect(try #require(parse(live[5])).event == "Stop")
    }

    @Test func aFutureShapeDegradesToNothingRatherThanToAGuess() throws {
        let mode = try #require(parse(Self.fixtures[10]))
        #expect(mode.composerMode == nil, "an unknown mode is not shown")
        #expect(!mode.background, "only a real true marks a background agent")
        let compact = try #require(parse(Self.fixtures[11]))
        #expect(compact.context == nil)
    }
}
