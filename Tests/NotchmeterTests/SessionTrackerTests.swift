import Foundation
import Testing
@testable import Notchmeter

/// The per-session state machine the hook feeds: start, work, wait, resume, stop, end, and the two expiries.
@Suite struct SessionTracking {
    init() { Localization.use(language: "en") }

    let t0 = DateParsing.iso8601("2026-09-01T12:00:00Z")!

    func message(_ event: String, session: String = "a", project: String? = "notchmeter", type: String? = nil, failure: String? = nil,
                 tool: ToolID = .claude) -> Hook.Message {
        Hook.Message(event: event, needsInput: Hook.needsInput(event: event, notificationType: type), sessionID: session, project: project,
                     notificationType: type, failure: failure, tool: tool)
    }

    /// A wait nobody answers times out on the ring after ten minutes. The banner it raised has to come down with
    /// it: `expire` is the only witness to that ending, so it reports what it demoted, and reports it once.
    @Test func anExpiredWaitIsReportedSoItsNoticeCanBeWithdrawn() {
        var tracker = SessionTracker()
        tracker.apply(message("UserPromptSubmit"), now: t0)
        let started = tracker.apply(message("Notification", type: "permission_prompt"), now: t0.addingTimeInterval(10))
        #expect(started.startedWaiting != nil)
        #expect(started.stoppedWaiting.isEmpty)
        #expect(tracker.waiting.count == 1)
        let timeout = t0.addingTimeInterval(10 + SessionTracker.waitingTimeout)
        #expect(tracker.expire(now: timeout) == ["a"])
        #expect(tracker.waiting.isEmpty)
        #expect(tracker.expire(now: timeout.addingTimeInterval(60)).isEmpty, "an ended wait is announced once, not on every sweep")
    }

    /// The same withdrawal when the whole session goes stale rather than the wait merely timing out, and nothing
    /// is reported for a session that was not waiting when it went.
    @Test func aWaitLostToStalenessIsReportedAndAnIdleSessionIsNot() {
        var waiting = SessionTracker()
        waiting.apply(message("Notification", type: "permission_prompt"), now: t0)
        #expect(waiting.expire(now: t0.addingTimeInterval(SessionTracker.staleAfter)) == ["a"])
        #expect(waiting.all.isEmpty)
        var idle = SessionTracker()
        idle.apply(message("SessionStart"), now: t0)
        #expect(idle.expire(now: t0.addingTimeInterval(SessionTracker.staleAfter)).isEmpty)
        #expect(idle.all.isEmpty)
    }

    @Test func aTurnGoesWorkingThenIdleAndReportsItsLength() {
        var tracker = SessionTracker()
        #expect(tracker.knownCount == nil)
        tracker.apply(message("SessionStart"), now: t0)
        #expect(tracker.knownCount == 1)
        #expect(tracker.all.first?.state == .idle)
        tracker.apply(message("UserPromptSubmit"), now: t0.addingTimeInterval(10))
        #expect(tracker.working.count == 1)
        #expect(tracker.working.first?.stateDuration(now: t0.addingTimeInterval(140)) == 130)
        let outcome = tracker.apply(message("Stop"), now: t0.addingTimeInterval(190))
        #expect(outcome.finished?.turn == 180)
        #expect(outcome.finished?.session.project == "notchmeter")
        #expect(tracker.working.isEmpty)
        #expect(tracker.all.first?.state == .idle)
        tracker.apply(message("SessionEnd"), now: t0.addingTimeInterval(200))
        #expect(tracker.count == 0)
        #expect(tracker.knownCount == 0)
    }

    @Test func waitingIsPerSessionAndClearsOnResumeStopOrTimeout() {
        var tracker = SessionTracker()
        tracker.apply(message("UserPromptSubmit", session: "a"), now: t0)
        tracker.apply(message("UserPromptSubmit", session: "b", project: "scout"), now: t0)
        let waited = tracker.apply(message("PermissionRequest", session: "a"), now: t0.addingTimeInterval(5))
        #expect(waited.startedWaiting?.id == "a")
        #expect(tracker.waiting.map(\.id) == ["a"])
        #expect(tracker.working.map(\.id) == ["b"])
        #expect(tracker.apply(message("PermissionRequest", session: "a"), now: t0.addingTimeInterval(6)).startedWaiting == nil)
        tracker.apply(message("Notification", session: "a", type: "agent_completed"), now: t0.addingTimeInterval(20))
        #expect(tracker.waiting.isEmpty)
        #expect(tracker.working.map(\.id).sorted() == ["a", "b"])
        tracker.apply(message("Notification", session: "b", type: "elicitation_url_dialog"), now: t0.addingTimeInterval(30))
        #expect(tracker.waiting.map(\.id) == ["b"])
        tracker.apply(message("Stop", session: "b"), now: t0.addingTimeInterval(40))
        #expect(tracker.waiting.isEmpty)
        tracker.apply(message("Notification", session: "a", type: "idle_prompt"), now: t0.addingTimeInterval(50))
        tracker.expire(now: t0.addingTimeInterval(50 + SessionTracker.waitingTimeout))
        #expect(tracker.waiting.isEmpty)
        #expect(tracker.count == 2)
        tracker.expire(now: t0.addingTimeInterval(SessionTracker.staleAfter + 60))
        #expect(tracker.count == 0)
    }

    @Test func eventsWithoutASessionIdShareOneSlotAndTheStatuslineKeepsASessionAlive() {
        var tracker = SessionTracker()
        tracker.apply(Hook.Message(event: "UserPromptSubmit", needsInput: false), now: t0)
        tracker.apply(Hook.Message(event: "PermissionRequest", needsInput: true), now: t0.addingTimeInterval(1))
        #expect(tracker.count == 1)
        #expect(tracker.waiting.first?.id == SessionTracker.unknownSession)
        tracker.statusline(sessionID: "s", project: "scout", now: t0.addingTimeInterval(2))
        #expect(tracker.count == 2)
        #expect(tracker.all.first { $0.id == "s" }?.project == "scout")
        tracker.statusline(sessionID: nil, project: "x", now: t0)
        #expect(tracker.count == 2)
    }

    @Test func waitingPhraseNamesTheProjectAndTheRest() {
        let a = AgentSession(id: "a", project: "notchmeter", state: .waiting(since: t0), started: t0, lastEvent: t0, turnStarted: nil)
        let b = AgentSession(id: "b", project: nil, state: .waiting(since: t0), started: t0, lastEvent: t0, turnStarted: nil)
        #expect(SessionTracker.waitingPhrase([]) == nil)
        #expect(SessionTracker.waitingPhrase([a]) == "notchmeter")
        #expect(SessionTracker.waitingPhrase([a, b]) == "notchmeter (and 1 more)")
        #expect(SessionTracker.waitingPhrase([b]) == "a session")
    }

    @Test func presenceGoesQuietWithNoSessionAndHidesWhenIdle() {
        let window = LimitWindow(id: "seven_day", label: "Weekly", usedFraction: 0.5, resetsAt: t0.addingTimeInterval(3 * 86400), periodDuration: Period.week)
        // 50 % four days into a week is ahead of pace; with sessions known to be zero the ring stays quiet.
        #expect(Presence.level(windows: [window], awaitingInput: false, sessions: nil, now: t0) == .legible)
        #expect(Presence.level(windows: [window], awaitingInput: false, sessions: 0, now: t0) == .quiet)
        #expect(Presence.level(windows: [window], awaitingInput: false, sessions: 1, now: t0) == .legible)
        #expect(Presence.hides(level: .quiet, idleFor: PollingPolicy.idleAfter, wokeAgo: nil))
        #expect(Presence.hides(level: .quiet, idleFor: nil, wokeAgo: nil))
        #expect(!Presence.hides(level: .quiet, idleFor: 60, wokeAgo: nil))
        #expect(!Presence.hides(level: .quiet, idleFor: PollingPolicy.idleAfter, wokeAgo: 10))
        #expect(!Presence.hides(level: .legible, idleFor: PollingPolicy.idleAfter, wokeAgo: nil))
        #expect(!Presence.hides(level: .urgent, idleFor: nil, wokeAgo: nil))
    }

    /// The dictionary key carries the tool for every tool but Claude, whose ids stay what every log line,
    /// notification identifier and `--json` report has always shown.
    @Test func claudeKeysAreWhatTheyHaveAlwaysBeen() {
        #expect(SessionTracker.key(tool: .claude, session: "a", host: nil) == "a")
        #expect(SessionTracker.key(tool: .claude, session: "a", host: "devbox") == "a@devbox")
        #expect(SessionTracker.key(tool: .claude, session: nil, host: nil) == SessionTracker.unknownSession)
        #expect(SessionTracker.key(tool: .cursor, session: "a", host: "devbox") == "cursor:a@devbox")
        #expect(SessionTracker.key(tool: .cursor, session: nil, host: nil) == "cursor:unknown")
        #expect(SessionTracker.key(tool: .cursor, session: "a", host: nil) == "cursor:a")
    }

    @Test func aCursorAndAClaudeSessionWithTheSameIdDoNotCollide() {
        var tracker = SessionTracker()
        tracker.apply(message("UserPromptSubmit"), now: t0)
        tracker.apply(message("UserPromptSubmit", tool: .cursor), now: t0.addingTimeInterval(1))
        #expect(tracker.count == 2, "the same id from two tools is two conversations, never one entry the first writer's tool sticks to")
        #expect(tracker.all.map(\.id).sorted() == ["a", "cursor:a"])
        #expect(tracker.isWorking(.claude))
        #expect(tracker.isWorking(.cursor))
        let outcome = tracker.apply(message("Stop"), now: t0.addingTimeInterval(30))
        #expect(outcome.finished?.session.id == "a")
        #expect(outcome.finished?.session.tool == .claude)
        #expect(!tracker.isWorking(.claude))
        #expect(tracker.isWorking(.cursor), "Claude Code's Stop ends Claude Code's turn and nobody else's")
    }

    @Test func aCompletedCursorStopFinishesTheTurn() {
        var tracker = SessionTracker()
        tracker.apply(message("UserPromptSubmit", tool: .cursor), now: t0)
        let outcome = tracker.apply(message("Stop", tool: .cursor), now: t0.addingTimeInterval(30))
        #expect(outcome.finished?.turn == 30)
        #expect(outcome.finished?.session.tool == .cursor)
        #expect(tracker.finish(of: .cursor, now: t0.addingTimeInterval(31)) != nil)
        #expect(tracker.finish(of: .claude, now: t0.addingTimeInterval(31)) == nil, "the tick lights the ring of the tool that finished")
        #expect(tracker.all.first?.state == .idle)
    }

    @Test func anAbortedCursorStopEndsWithoutAFinishOrALimit() {
        var tracker = SessionTracker()
        tracker.apply(message("UserPromptSubmit", tool: .cursor), now: t0)
        let outcome = tracker.apply(message("StopFailure", failure: "aborted", tool: .cursor), now: t0.addingTimeInterval(30))
        #expect(outcome.finished == nil, "a turn the user aborted has not finished, and the ring must not congratulate it")
        #expect(outcome.limitHit == nil, "aborted is not rate_limit; Cursor has no limit event, so no limit is ever planned")
        #expect(tracker.all.first?.state == .idle)
        #expect(tracker.finish(of: .cursor, now: t0.addingTimeInterval(31)) == nil)
        #expect(!tracker.limitHit(now: t0.addingTimeInterval(31)))
        #expect(tracker.limitHitTools(now: t0.addingTimeInterval(31)).isEmpty)
    }

    @Test func sessionEndRemovesOnlyTheCursorSession() {
        var tracker = SessionTracker()
        tracker.apply(message("SessionStart"), now: t0)
        tracker.apply(message("SessionStart", tool: .cursor), now: t0)
        #expect(tracker.count == 2)
        tracker.apply(message("SessionEnd", tool: .cursor), now: t0.addingTimeInterval(1))
        #expect(tracker.count == 1)
        #expect(tracker.all.first?.id == "a")
        #expect(tracker.all.first?.tool == .claude)
    }

    @Test func onlyKeepsOneToolsSessionsAndThatAHookWasSeen() {
        var tracker = SessionTracker()
        #expect(tracker.only(.cursor).knownCount == nil, "a card must not say zero sessions before any hook has spoken")
        tracker.apply(message("UserPromptSubmit"), now: t0)
        tracker.apply(message("UserPromptSubmit", session: "b", tool: .cursor), now: t0)
        tracker.apply(message("UserPromptSubmit", session: "c", tool: .cursor), now: t0)
        let cursor = tracker.only(.cursor)
        #expect(cursor.count == 2)
        #expect(cursor.all.allSatisfy { $0.tool == .cursor })
        #expect(cursor.knownCount == 2)
        let claude = tracker.only(.claude)
        #expect(claude.all.map(\.id) == ["a"])
        #expect(claude.knownCount == 1)
        let codex = tracker.only(.codex)
        #expect(codex.count == 0)
        #expect(codex.knownCount == 0, "hookSeen survives the filter, so a tool with no sessions reads as zero rather than unknown")
        #expect(tracker.count == 3, "only() is a copy; the tracker itself is untouched")
    }

    /// The calm rule quietens a ring whose hook says nothing is running. That is one tool's hook speaking about
    /// one tool: Cursor's hook reporting no conversation is not proof that Claude Code is idle.
    @Test func knownCountOfAToolIsNilUntilItsOwnHookSpeaks() {
        var tracker = SessionTracker()
        #expect(tracker.knownCount(of: .claude) == nil)
        tracker.apply(message("SessionStart", session: "c", tool: .cursor), now: t0)
        tracker.apply(message("SessionEnd", session: "c", tool: .cursor), now: t0.addingTimeInterval(1))
        #expect(tracker.knownCount == 0, "every hook together: one has spoken and no session is open")
        #expect(tracker.knownCount(of: .cursor) == 0)
        #expect(tracker.knownCount(of: .claude) == nil, "Claude Code's hook has not spoken, so its count is unknown, not zero")
        tracker.apply(message("SessionStart"), now: t0.addingTimeInterval(2))
        tracker.apply(message("UserPromptSubmit", session: "d", tool: .cursor), now: t0.addingTimeInterval(2))
        #expect(tracker.knownCount(of: .claude) == 1)
        #expect(tracker.knownCount(of: .cursor) == 1)
        #expect(tracker.knownCount == 2)
        #expect(tracker.only(.claude).knownCount(of: .cursor) == 0, "the filter drops the sessions, not the fact that Cursor's hook has reported")
    }
}


/// Subagents, stop failures, quota waits, the withdrawn-notice outcome and the remote host label.
@Suite struct SessionTrackingRoundTwo {
    init() { Localization.use(language: "en") }

    let t0 = DateParsing.iso8601("2026-09-01T12:00:00Z")!

    func message(_ event: String, session: String = "a", type: String? = nil, agent: String? = nil, failure: String? = nil, host: String? = nil) -> Hook.Message {
        Hook.Message(event: event, needsInput: Hook.needsInput(event: event, notificationType: type), sessionID: session, project: "notchmeter",
                     notificationType: type, agentID: agent, failure: failure, host: host)
    }

    @Test func subagentsArePairedAndTimeOutAfterTenMinutes() {
        var tracker = SessionTracker()
        tracker.apply(message("UserPromptSubmit"), now: t0)
        tracker.apply(message("SubagentStart", agent: "a1"), now: t0.addingTimeInterval(1))
        tracker.apply(message("SubagentStart", agent: "a2"), now: t0.addingTimeInterval(2))
        tracker.apply(message("SubagentStart", agent: "a3"), now: t0.addingTimeInterval(3))
        #expect(tracker.agentCount == 3)
        tracker.apply(message("SubagentStop", agent: "a2"), now: t0.addingTimeInterval(10))
        #expect(tracker.agentCount == 2)
        tracker.apply(message("SubagentStop"), now: t0.addingTimeInterval(11))
        #expect(tracker.agentCount == 1)
        #expect(tracker.all.first?.agents.keys.sorted() == ["a3"])
        tracker.expire(now: t0.addingTimeInterval(3 + SessionTracker.agentTimeout))
        #expect(tracker.agentCount == 0)
        tracker.apply(message("SubagentStart"), now: t0.addingTimeInterval(700))
        tracker.apply(message("SubagentStart"), now: t0.addingTimeInterval(701))
        #expect(tracker.agentCount == 2)
        tracker.apply(message("Stop"), now: t0.addingTimeInterval(800))
        #expect(tracker.agentCount == 0)
        #expect(SessionTracker.waitingPhrase([]) == nil)
    }

    /// Claude Code reports a permission prompt and never its answer, so the only thing that says the answer came
    /// is the session doing something a held session cannot. Starting an agent is that; an agent stopping is not,
    /// because a background agent can finish while the main loop is still held at the prompt.
    @Test func startingAnAgentProvesAnAnsweredPromptButAnAgentStoppingDoesNot() {
        var tracker = SessionTracker()
        tracker.apply(message("UserPromptSubmit"), now: t0)
        tracker.apply(message("PermissionRequest"), now: t0.addingTimeInterval(5))
        #expect(tracker.waiting(of: .claude).count == 1)
        tracker.apply(message("SubagentStop"), now: t0.addingTimeInterval(6))
        #expect(tracker.waiting(of: .claude).count == 1, "a background agent finishing says nothing about the prompt")
        let resumed = tracker.apply(message("SubagentStart", agent: "a1"), now: t0.addingTimeInterval(7))
        #expect(tracker.waiting(of: .claude).isEmpty)
        #expect(tracker.working.count == 1)
        #expect(tracker.agentCount == 1)
        #expect(resumed.stoppedWaiting == ["a"], "the waiting notice is withdrawn like any other resume")
        let again = tracker.apply(message("SubagentStart", agent: "a2"), now: t0.addingTimeInterval(8))
        #expect(again.stoppedWaiting.isEmpty)
        #expect(tracker.all.first?.stateDuration(now: t0.addingTimeInterval(17)) == 10, "the working clock starts at the resume")
    }

    @Test func aStopOnARateLimitMarksTheSessionAndAQuotaResumeClearsIt() {
        var tracker = SessionTracker()
        tracker.apply(message("UserPromptSubmit"), now: t0)
        let hit = tracker.apply(message("StopFailure", failure: "rate_limit"), now: t0.addingTimeInterval(60))
        #expect(hit.limitHit?.id == "a")
        #expect(hit.finished == nil)
        #expect(tracker.working.isEmpty)
        #expect(tracker.limitHit(now: t0.addingTimeInterval(120)))
        #expect(!tracker.limitHit(now: t0.addingTimeInterval(60 + 3601)))
        let stale = tracker.apply(message("Notification", type: "quota_auto_resume_stale"), now: t0.addingTimeInterval(90))
        #expect(stale.limitHit == nil)
        #expect(tracker.quotaWaiting.map(\.id) == ["a"])
        #expect(tracker.limitHit(now: t0.addingTimeInterval(60 + 3601)))
        let resumed = tracker.apply(message("Notification", type: "quota_auto_resume_fired"), now: t0.addingTimeInterval(4000))
        #expect(resumed.quotaResumed)
        #expect(tracker.quotaWaiting.isEmpty)
        #expect(!tracker.limitHit(now: t0.addingTimeInterval(4000)))
        let other = tracker.apply(message("StopFailure", failure: "overloaded"), now: t0.addingTimeInterval(4100))
        #expect(other.limitHit == nil)
        var context = Advisor.Context(readings: [UsageReading(tool: .claude, windows: [
            LimitWindow(id: "five_hour", label: "Session", usedFraction: 1, resetsAt: t0.addingTimeInterval(2 * 3600 + 600), periodDuration: Period.fiveHours),
            LimitWindow(id: "seven_day", label: "Weekly", usedFraction: 0.5, resetsAt: t0.addingTimeInterval(3 * 86400), periodDuration: Period.week),
        ], plan: nil, fetchedAt: t0, observedAt: nil)], now: t0)
        context.limitHitTools = [.claude]
        #expect(Advisor.limitHit(context).map(\.text) == ["Claude Code hit its limit; session resets in 2h 10m."])
        #expect(Advisor.waitForReset(context).isEmpty)
        context.readings = []
        #expect(Advisor.limitHit(context).isEmpty)
        context.readings = [UsageReading(tool: .claude, windows: [], plan: nil, fetchedAt: t0, observedAt: nil)]
        #expect(Advisor.limitHit(context).map(\.text) == ["Claude Code hit its rate limit; wait for the reset."])
    }

    @Test func leavingTheWaitingStateNamesTheSessionSoItsNoticeCanBeWithdrawn() {
        var tracker = SessionTracker()
        tracker.apply(message("PermissionRequest"), now: t0)
        #expect(tracker.waiting.count == 1)
        let resumed = tracker.apply(message("UserPromptSubmit"), now: t0.addingTimeInterval(5))
        #expect(resumed.stoppedWaiting == ["a"])
        tracker.apply(message("PermissionRequest"), now: t0.addingTimeInterval(10))
        let ended = tracker.apply(message("SessionEnd"), now: t0.addingTimeInterval(20))
        #expect(ended.stoppedWaiting == ["a"])
        #expect(tracker.apply(message("Stop"), now: t0.addingTimeInterval(30)).stoppedWaiting.isEmpty)
        #expect(Notifier.identifier(session: "a", kind: "waiting") == "session/a/waiting")
    }

    @Test func remoteSessionsCarryTheirHost() {
        var tracker = SessionTracker()
        tracker.apply(message("UserPromptSubmit", host: "devbox"), now: t0)
        let session = tracker.all[0]
        #expect(session.id == "a@devbox")
        #expect(session.host == "devbox")
        #expect(session.displayName == "notchmeter@devbox")
        let bare = AgentSession(id: "x", project: nil, state: .idle, started: t0, lastEvent: t0, turnStarted: nil, host: "vps")
        #expect(bare.displayName == "@vps")
        let pr = AgentSession(id: "y", project: "notchmeter", state: .idle, started: t0, lastEvent: t0, turnStarted: nil, branch: "feat/hooks", prURL: "https://github.com/a/b/pull/12")
        #expect(pr.prNumber == "#12")
        #expect(AgentSession(id: "z", project: nil, state: .idle, started: t0, lastEvent: t0, turnStarted: nil, prURL: "https://x/y").prNumber == nil)
        var statusline = SessionTracker()
        statusline.statusline(sessionID: "s", project: "p", branch: "main", prURL: "https://github.com/a/b/pull/3", now: t0)
        #expect(statusline.all[0].branch == "main")
        #expect(statusline.all[0].prNumber == "#3")
    }
}
