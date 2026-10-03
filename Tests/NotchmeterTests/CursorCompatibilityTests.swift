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

    @Test func aFutureShapeDegradesToNothingRatherThanToAGuess() throws {
        let mode = try #require(parse(Self.fixtures[10]))
        #expect(mode.composerMode == nil, "an unknown mode is not shown")
        #expect(!mode.background, "only a real true marks a background agent")
        let compact = try #require(parse(Self.fixtures[11]))
        #expect(compact.context == nil)
    }
}
