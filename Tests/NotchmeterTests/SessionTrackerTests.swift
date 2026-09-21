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
        // The session was the window hit and the week has room, so the quieter /limit-reset offer (a rule of its
        // own since it needs no hook) follows the line.
        #expect((Advisor.limitHit(context) + Advisor.limitReset(context)).map(\.text) == ["Claude Code hit its limit; session resets in 2h 10m.",
                                                                                          "Claude Code may have a /limit-reset this week: it clears the 5-hour window, not the weekly cap."])
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

    /// The status-line bus is unauthenticated, so a pull request link is only a link when it is an ordinary web
    /// address: a `file:` path or a custom scheme draws no button and no "PR #n", however the path ends.
    @Test func onlyWebLinksBecomeAPullRequest() throws {
        func session(_ prURL: String) -> AgentSession {
            AgentSession(id: "s", project: "p", state: .idle, started: t0, lastEvent: t0, turnStarted: nil, prURL: prURL)
        }
        let github = URL(string: "https://github.com/o/r/pull/12")
        #expect(session("https://github.com/o/r/pull/12").prLink == github)
        #expect(session("https://github.com/o/r/pull/12").prNumber == "#12")
        #expect(session("HTTP://github.com/o/r/pull/7").prNumber == "#7")
        #expect(session("file:///Volumes/Installer/Setup.app").prLink == nil)
        #expect(session("file:///Volumes/Installer/12").prNumber == nil)
        #expect(session("x-apple.systempreferences:com.apple.preference.security").prLink == nil)
        #expect(session("https:///pull/12").prLink == nil)
        #expect(session("not a url").prLink == nil)
        var tracker = SessionTracker()
        tracker.statusline(sessionID: "s", project: "p", prURL: "file:///Volumes/X/9", now: t0)
        #expect(tracker.all[0].prLink == nil)
        #expect(tracker.all[0].prNumber == nil)

        // The report is a reader of the link too: the local API, the command-line tool and the MCP server all get
        // its `pr`, and until 0.5.0 it carried the raw string the panel had refused.
        func reported(_ tracker: SessionTracker) throws -> Any? {
            let json = try JSONSerialization.jsonObject(with: UsageReport(tools: [:], cost: nil, advice: [], sessions: tracker.all, now: t0).json)
            let sessions = try #require(json as? [String: Any])["sessions"] as? [[String: Any]]
            return try #require(sessions?.first)["pr"]
        }
        #expect(try reported(tracker) is NSNull)
        tracker.statusline(sessionID: "s", project: "p", prURL: "https://github.com/o/r/pull/9", now: t0)
        #expect(try reported(tracker) as? String == "https://github.com/o/r/pull/9")
    }

    /// One message can end a wait and start another for the same session, because `apply` seeds stoppedWaiting from
    /// `expire`: a prompt arriving after its own wait timed out demotes the session and re-raises it inside the one
    /// call, so both lists name it. The tracker is right to report both; what matters is the order the store acts on
    /// them in.
    @Test func aPromptAfterItsOwnWaitTimedOutIsBothEndedAndStarted() {
        var tracker = SessionTracker()
        tracker.apply(message("Notification", type: "permission_prompt"), now: t0)
        let outcome = tracker.apply(message("Notification", type: "permission_prompt"), now: t0.addingTimeInterval(601))
        #expect(outcome.startedWaiting?.id == "a")
        #expect(outcome.stoppedWaiting == ["a"], "expire demoted the wait that timed out, and the fresh prompt raised it again")
    }

    /// Delivered first, the withdrawal took the new banner straight back down — and the notifier had already spent
    /// that session's ten minutes on a banner nobody saw, so the next prompt was capped too. Withdrawn first, the
    /// notice standing for the wait that expired goes and the new one is what is left.
    @MainActor @Test func theExpiredNoticeIsWithdrawnBeforeTheFreshOneIsRaised() {
        let suite = "NotchmeterTests.waitRestart"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        prefs.notifyWaiting = true
        let store = UsageStore(prefs: prefs, providers: [], cache: ReadingCache(defaults: defaults), defaults: defaults,
                               drainLog: nil, reportFile: nil)
        var acted: [String] = []
        store.deliverSessionEvent = { _, session in acted.append("raise \(session.id)") }
        store.removeNotifications = { acted.append("withdraw \($0.joined(separator: ","))") }
        store.hookReceived(message("Notification", type: "permission_prompt"), now: t0)
        #expect(acted == ["raise a"])
        store.hookReceived(message("Notification", type: "permission_prompt"), now: t0.addingTimeInterval(601))
        #expect(acted == ["raise a", "withdraw session/a/waiting", "raise a"])
    }
}

/// The 0.7.0 fields: a request the hook is holding the session for, the title a prompt leaves, the terminal that
/// merges across events, and the model the status line names; each with the end that arrives without another event.
@Suite struct SessionTrackingRequests {
    let t0 = DateParsing.iso8601("2026-09-01T12:00:00Z")!

    func request(_ id: String, session: String = "a", kind: PendingRequest.Kind = .permission(tool: "Bash", summary: "ls", detail: nil, suggestions: [])) -> Hook.Message {
        var message = Hook.Message(event: "PermissionRequest", needsInput: true, sessionID: session, project: "notchmeter")
        message.request = Hook.Request(id: id, kind: kind)
        return message
    }

    func message(_ event: String, session: String = "a", type: String? = nil, agent: String? = nil, title: String? = nil, terminal: TerminalRef? = nil) -> Hook.Message {
        var message = Hook.Message(event: event, needsInput: Hook.needsInput(event: event, notificationType: type), sessionID: session, project: "notchmeter",
                                   notificationType: type, agentID: agent)
        message.title = title
        message.terminal = terminal
        return message
    }

    @Test func aRequestHoldsTheSessionAndIsReportedOnce() {
        var tracker = SessionTracker()
        tracker.apply(message("UserPromptSubmit"), now: t0)
        let outcome = tracker.apply(request("r1"), now: t0.addingTimeInterval(5))
        #expect(outcome.startedWaiting?.id == "a")
        #expect(outcome.requested?.session.id == "a")
        #expect(outcome.requested?.request == PendingRequest(id: "r1", kind: .permission(tool: "Bash", summary: "ls", detail: nil, suggestions: []), since: t0.addingTimeInterval(5)))
        #expect(outcome.requestsEnded.isEmpty)
        #expect(tracker.waiting.map(\.id) == ["a"])
        #expect(tracker.all.first?.pending?.id == "r1")
        #expect(tracker.pending(now: t0.addingTimeInterval(6)).map(\.request.id) == ["r1"])

        // A second request on the same session replaces the first, which is reported ended.
        let replaced = tracker.apply(request("r2"), now: t0.addingTimeInterval(10))
        #expect(replaced.requested?.request.id == "r2")
        #expect(replaced.requestsEnded == [SessionTracker.EndedRequest(sessionID: "a", requestID: "r1")])
        #expect(replaced.startedWaiting == nil, "already waiting")
        #expect(tracker.pending(now: t0.addingTimeInterval(11)).map(\.request.id) == ["r2"])

        // Newest first across sessions.
        tracker.apply(request("r3", session: "b"), now: t0.addingTimeInterval(20))
        #expect(tracker.pending(now: t0.addingTimeInterval(21)).map(\.request.id) == ["r3", "r2"])
    }

    @Test func aQuestionIsAWaitWhateverTheEventSaid() {
        var tracker = SessionTracker()
        var question = Hook.Message(event: "PreToolUse", needsInput: true, sessionID: "a")
        question.request = Hook.Request(id: "q1", kind: .question([PendingRequest.Question(text: "Which?", options: [PendingRequest.Option(label: "A")])]))
        let outcome = tracker.apply(question, now: t0)
        #expect(outcome.startedWaiting?.id == "a")
        #expect(outcome.requested?.request.kindName == "question")
        #expect(tracker.all.first?.isWaiting == true)
        let plain = tracker.apply(Hook.Message(event: "PreToolUse", needsInput: false, sessionID: "a"), now: t0.addingTimeInterval(1))
        #expect(plain.requested == nil)
        #expect(tracker.all.first?.pending?.id == "q1", "an ordinary tool call neither starts nor ends a request")
    }

    @Test func theSameEventsThatEndAWaitEndTheRequest() {
        for (event, agent) in [("UserPromptSubmit", nil), ("Stop", nil), ("StopFailure", nil), ("SessionStart", nil), ("SubagentStart", "a1")] {
            var tracker = SessionTracker()
            tracker.apply(request("r1"), now: t0)
            let outcome = tracker.apply(message(event, agent: agent), now: t0.addingTimeInterval(5))
            #expect(outcome.requestsEnded == [SessionTracker.EndedRequest(sessionID: "a", requestID: "r1")], "\(event)")
            #expect(tracker.all.first?.pending == nil, "\(event)")
        }
        var tracker = SessionTracker()
        tracker.apply(request("r1"), now: t0)
        let completed = tracker.apply(message("Notification", type: "agent_completed"), now: t0.addingTimeInterval(5))
        #expect(completed.requestsEnded.map(\.requestID) == ["r1"], "a completion notification ends it too")
        tracker.apply(request("r2"), now: t0.addingTimeInterval(10))
        let prompt = tracker.apply(message("Notification", type: "permission_prompt"), now: t0.addingTimeInterval(16))
        #expect(prompt.requestsEnded.isEmpty, "the six-second permission_prompt is the same wait, not the end of it")
        #expect(tracker.all.first?.pending?.id == "r2")
        let ended = tracker.apply(message("SessionEnd"), now: t0.addingTimeInterval(20))
        #expect(ended.requestsEnded == [SessionTracker.EndedRequest(sessionID: "a", requestID: "r2")])
        #expect(ended.stoppedWaiting == ["a"])
        #expect(tracker.count == 0)
    }

    @Test func resolveEndsTheRequestTheAppAnswered() {
        var tracker = SessionTracker()
        tracker.apply(message("UserPromptSubmit"), now: t0)
        tracker.apply(request("r1"), now: t0.addingTimeInterval(5))
        #expect(tracker.resolve(requestID: "nobody", resumes: true, now: t0.addingTimeInterval(6)) == nil)
        #expect(tracker.all.first?.pending?.id == "r1", "an unknown id changes nothing")
        let allowed = tracker.resolve(requestID: "r1", resumes: true, now: t0.addingTimeInterval(7))
        #expect(allowed?.id == "a")
        #expect(allowed?.pending == nil)
        #expect(tracker.all.first?.isWorking == true, "a decision the assistant acts on puts the session back to work")
        #expect(tracker.all.first?.stateDuration(now: t0.addingTimeInterval(17)) == 10)
        #expect(tracker.pending(now: t0.addingTimeInterval(8)).isEmpty)

        tracker.apply(request("r2"), now: t0.addingTimeInterval(20))
        let passed = tracker.resolve(requestID: "r2", resumes: false, now: t0.addingTimeInterval(21))
        #expect(passed?.pending == nil)
        #expect(tracker.all.first?.isWaiting == true, "a pass leaves the terminal asking")
        #expect(tracker.resolve(requestID: "r2", resumes: true, now: t0.addingTimeInterval(22)) == nil, "resolved once")
    }

    @Test func aRequestExpiresWithTheHoldCapAndAWaitOnItsOwnClock() {
        var tracker = SessionTracker()
        tracker.apply(request("r1"), now: t0)
        #expect(SessionTracker.pendingTimeout == HookSocket.Listener.holdCap)
        #expect(tracker.pending(now: t0.addingTimeInterval(SessionTracker.pendingTimeout - 1)).count == 1)
        #expect(tracker.pending(now: t0.addingTimeInterval(SessionTracker.pendingTimeout)).isEmpty, "read against the clock before the sweep gets there")
        tracker.expire(now: t0.addingTimeInterval(SessionTracker.pendingTimeout))
        #expect(tracker.all.first?.pending == nil)
        #expect(tracker.all.first?.isWaiting == false, "the wait's own timeout is the same figure and fell at the same moment")
    }

    /// *Show what a session is working on* turned off drops every title and session name already held, and the
    /// sessions themselves stay.
    @Test func titlesOffClearsWhatIsHeld() {
        var tracker = SessionTracker()
        tracker.apply(message("UserPromptSubmit", title: "fix the tests"), now: t0)
        tracker.statusline(sessionID: "b", project: nil, sessionName: "named", now: t0)
        #expect(tracker.all.compactMap(\.displayTitle).sorted() == ["fix the tests", "named"])
        tracker.clearTitles()
        #expect(tracker.all.allSatisfy { $0.title == nil && $0.sessionName == nil })
        #expect(tracker.all.count == 2, "the sessions themselves stay")
    }

    /// A second line under a request id already standing is a replay (the ids are UUIDs the hook generated):
    /// the first keeps its place and its clock and nothing is reported, on this session or another, so the store
    /// releases the second's connection at once; the line still lands as the display-only wait.
    @Test func aReplayedRequestIDKeepsTheFirstAndReportsNothing() {
        var tracker = SessionTracker()
        let first = tracker.apply(request("r1"), now: t0)
        #expect(first.requested?.request.id == "r1")
        let replay = tracker.apply(request("r1"), now: t0.addingTimeInterval(1))
        #expect(replay.requested == nil)
        #expect(replay.requestsEnded.isEmpty)
        #expect(tracker.pending(now: t0.addingTimeInterval(1)).map(\.request.since) == [t0], "the first keeps its place and its clock")
        let elsewhere = tracker.apply(request("r1", session: "b"), now: t0.addingTimeInterval(2))
        #expect(elsewhere.requested == nil)
        #expect(elsewhere.startedWaiting?.id == "b", "the line still lands as the display-only wait")
        #expect(tracker.pending(now: t0.addingTimeInterval(2)).map(\.session.id) == ["a"])
        #expect(tracker.all.first { $0.id == "b" }?.pending == nil)
    }

    @Test func theTitleTheTerminalAndTheModelLiveOnTheSession() {
        var tracker = SessionTracker()
        let iterm = TerminalRef(program: "iTerm.app", bundleID: "com.googlecode.iterm2", sessionID: "w0t0p0:X")
        tracker.apply(message("SessionStart", terminal: iterm), now: t0)
        #expect(tracker.all.first?.terminal == iterm)
        #expect(tracker.all.first?.title == nil)
        tracker.apply(message("UserPromptSubmit", title: "fix the tests", terminal: TerminalRef(tty: "/dev/ttys003")), now: t0.addingTimeInterval(1))
        #expect(tracker.all.first?.title == "fix the tests")
        #expect(tracker.all.first?.terminal == TerminalRef(program: "iTerm.app", bundleID: "com.googlecode.iterm2", tty: "/dev/ttys003", sessionID: "w0t0p0:X"),
                "each event adds what it could read and erases nothing")
        tracker.apply(message("Stop"), now: t0.addingTimeInterval(2))
        #expect(tracker.all.first?.title == "fix the tests", "the title stands until the next prompt")
        tracker.apply(message("UserPromptSubmit"), now: t0.addingTimeInterval(3))
        #expect(tracker.all.first?.title == nil, "a prompt the hook sent no title for clears it: titles off is titles gone")
        tracker.apply(message("Stop", terminal: TerminalRef()), now: t0.addingTimeInterval(4))
        #expect(tracker.all.first?.terminal?.tty == "/dev/ttys003", "an empty reference changes nothing")
        tracker.statusline(sessionID: "a", project: nil, model: "Opus", now: t0.addingTimeInterval(5))
        #expect(tracker.all.first?.model == "Opus")
        tracker.statusline(sessionID: "a", project: nil, now: t0.addingTimeInterval(6))
        #expect(tracker.all.first?.model == "Opus", "a status line naming no model keeps the last one")
    }

    @Test func theReportCarriesNoneOfIt() throws {
        var tracker = SessionTracker()
        tracker.apply(message("UserPromptSubmit", title: "the secret plan", terminal: TerminalRef(program: "iTerm.app", tty: "/dev/ttys003")), now: t0)
        tracker.apply(request("r1", kind: .permission(tool: "Bash", summary: "rm -rf secret", detail: "rm -rf secret", suggestions: [])), now: t0.addingTimeInterval(1))
        let report = UsageReport(tools: [:], cost: nil, advice: [], sessions: tracker.all, now: t0.addingTimeInterval(2))
        let text = String(decoding: report.json, as: UTF8.self)
        for secret in ["secret", "ttys003", "iTerm", "r1", "title", "terminal", "pending"] {
            #expect(!text.contains(secret), "\(secret) must not reach the report, the local API, --json or MCP")
        }
        let sessions = try #require((try JSONSerialization.jsonObject(with: report.json) as? [String: Any])?["sessions"] as? [[String: Any]])
        #expect(sessions.first?["state"] as? String == "waiting")
    }
}

/// The quiet-turn nudge (0.7.6): Cursor never says it is waiting for an approval, so a working turn that goes quiet
/// with nothing running, on an install that sends heartbeats, becomes a possible wait once per turn.
@Suite struct QuietTurnNudge {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    func cursor(_ event: String) -> Hook.Message { Hook.Message(event: event, needsInput: false, sessionID: "c1", project: "p", tool: .cursor) }

    @Test func aQuietTurnWithNothingRunningIsNudgedOnce() throws {
        var tracker = SessionTracker()
        tracker.apply(cursor("UserPromptSubmit"), now: t0)
        tracker.apply(cursor("afterAgentThought"), now: t0.addingTimeInterval(5))
        #expect(tracker.nextRelease(now: t0.addingTimeInterval(6)) == t0.addingTimeInterval(5 + SessionTracker.quietAfter))
        #expect(tracker.quietNudges(now: t0.addingTimeInterval(30)).isEmpty, "not quiet long enough")
        let nudged = tracker.quietNudges(now: t0.addingTimeInterval(51))
        #expect(nudged.map(\.id) == ["cursor:c1"])
        let session = try #require(tracker.sessions["cursor:c1"])
        #expect(session.isWaiting && session.quietNudge)
        #expect(Notifier.copy(for: .waiting(blocking: false), session: session).title == "Cursor may be waiting")
        #expect(tracker.quietNudges(now: t0.addingTimeInterval(500)).isEmpty, "once per turn")
    }

    @Test func theNextSignOfLifeEndsTheWaitAndANewTurnRearms() throws {
        var tracker = SessionTracker()
        tracker.apply(cursor("UserPromptSubmit"), now: t0)
        tracker.apply(cursor("afterAgentResponse"), now: t0.addingTimeInterval(1))
        _ = tracker.quietNudges(now: t0.addingTimeInterval(60))
        let outcome = tracker.apply(cursor("beforeShellExecution"), now: t0.addingTimeInterval(70))
        #expect(outcome.stoppedWaiting == ["cursor:c1"], "the approval was given: the command is running")
        #expect(tracker.sessions["cursor:c1"]?.isWorking == true)
        tracker.apply(cursor("Stop"), now: t0.addingTimeInterval(80))
        tracker.apply(cursor("UserPromptSubmit"), now: t0.addingTimeInterval(90))
        tracker.apply(cursor("afterFileEdit"), now: t0.addingTimeInterval(91))
        #expect(tracker.quietNudges(now: t0.addingTimeInterval(140)).count == 1, "a new turn can be nudged again")
    }

    @Test func aRunningCommandNoHeartbeatsOrAnotherToolIsNeverNudged() {
        var running = SessionTracker()
        running.apply(cursor("UserPromptSubmit"), now: t0)
        running.apply(cursor("beforeShellExecution"), now: t0.addingTimeInterval(1))
        #expect(running.quietNudges(now: t0.addingTimeInterval(600)).isEmpty, "a long build is busy, not waiting")
        running.apply(cursor("afterShellExecution"), now: t0.addingTimeInterval(700))
        #expect(running.quietNudges(now: t0.addingTimeInterval(760)).count == 1)

        var old = SessionTracker()
        old.apply(cursor("UserPromptSubmit"), now: t0)
        #expect(old.quietNudges(now: t0.addingTimeInterval(600)).isEmpty, "an install without heartbeats says nothing by its silence")

        var claude = SessionTracker()
        claude.apply(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "s"), now: t0)
        claude.apply(Hook.Message(event: "afterAgentThought", needsInput: false, sessionID: "s"), now: t0.addingTimeInterval(1))
        #expect(claude.quietNudges(now: t0.addingTimeInterval(600)).isEmpty, "Claude Code says when it waits")
    }
}
