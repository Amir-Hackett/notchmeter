import Foundation
import Testing
@testable import Notchmeter

/// The banner copy for a session event names the session's tool, so a Cursor turn is announced as Cursor's and a
/// Claude Code turn reads exactly as it always has. `copy(for:session:)` is pure so the English is pinned without
/// Notification Center.
@Suite struct NotifierCopy {
    init() { Localization.use(language: "en") }

    let t0 = DateParsing.iso8601("2026-09-01T12:00:00Z")!

    func session(_ tool: ToolID, project: String? = "proj") -> AgentSession {
        AgentSession(id: tool == .claude ? "c1" : "\(tool.rawValue):c1", tool: tool, project: project, state: .idle, started: t0, lastEvent: t0, turnStarted: nil)
    }

    @Test func aFinishIsNamedAfterTheToolThatFinished() {
        #expect(ResetText.duration(600) == "10m")
        let cursor = Notifier.copy(for: .finished(turn: 600), session: session(.cursor))
        #expect(cursor.title == "Cursor finished")
        #expect(cursor.body == "Cursor finished a 10m turn in proj.")
        let claude = Notifier.copy(for: .finished(turn: 600), session: session(.claude))
        #expect(claude.title == "Claude Code finished")
        #expect(claude.body == "Claude Code finished a 10m turn in proj.", "Claude Code's banner reads as it always has")
        #expect(Notifier.copy(for: .finished(turn: 90), session: session(.cursor, project: nil)).body == "Cursor finished a 1m turn in a session.")
    }

    @Test func aWaitIsClaudesBecauseOnlyClaudeCanWait() {
        let claude = Notifier.copy(for: .waiting(blocking: true), session: session(.claude))
        #expect(claude.title == "Claude Code is waiting")
        #expect(claude.body == "Claude Code is waiting in proj.")
    }
}
