import Foundation
import Testing
@testable import Notchmeter

/// The per-session state machine the hook feeds: start, work, wait, resume, stop, end, and the two expiries.
@Suite struct SessionTracking {
    init() { Localization.use(language: "en") }

    let t0 = DateParsing.iso8601("2026-09-01T12:00:00Z")!

    func message(_ event: String, session: String = "a", project: String? = "notchmeter", type: String? = nil) -> Hook.Message {
        Hook.Message(event: event, needsInput: Hook.needsInput(event: event, notificationType: type), sessionID: session, project: project, notificationType: type)
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
}
