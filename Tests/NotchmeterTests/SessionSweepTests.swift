import Foundation
import Observation
import Testing
@testable import Notchmeter

/// The thirty-second sweep over the sessions publishes to the store's observers only when it changed one. Every
/// presenter and the menu bar item lay out again on each publish of `store.sessions`, so a sweep that found nothing
/// to expire must leave them alone.
@MainActor @Suite struct SessionSweep {
    let t0 = DateParsing.iso8601("2026-09-01T12:00:00Z")!

    func message(_ event: String, session: String = "a", type: String? = nil) -> Hook.Message {
        Hook.Message(event: event, needsInput: Hook.needsInput(event: event, notificationType: type), sessionID: session, project: "notchmeter",
                     notificationType: type, failure: nil, tool: .claude)
    }

    func store(_ suite: String) -> (UsageStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let prefs = Preferences(defaults: defaults)
        let store = UsageStore(prefs: prefs, providers: [], cache: ReadingCache(defaults: defaults), defaults: defaults,
                               drainLog: nil, reportFile: nil)
        return (store, defaults)
    }

    /// Counts how many times observers of `store.sessions` are told to look again across one sweep.
    func publishes(of store: UsageStore, during sweep: () -> Void) -> Int {
        var fired = 0
        withObservationTracking { _ = store.sessions } onChange: { fired += 1 }
        sweep()
        return fired
    }

    /// Nothing running, nothing to expire: the sweep must not publish. In place, `sessions.expire` fired the
    /// observers once per sweep even here.
    @Test func aSweepWithNothingToExpireIsSilent() {
        let suite = "NotchmeterTests.SessionSweep.silent"
        let (store, defaults) = store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let expected = 0
        #expect(publishes(of: store) { store.sweepSessions(now: t0) } == expected)
        store.hookReceived(message("UserPromptSubmit"), now: t0)
        #expect(publishes(of: store) { store.sweepSessions(now: t0.addingTimeInterval(30)) } == expected)
    }

    /// A wait that has run past ten minutes is a real change: the sweep publishes once and withdraws its notice.
    @Test func aSweepThatExpiresAWaitPublishesOnceAndWithdrawsItsNotice() {
        let suite = "NotchmeterTests.SessionSweep.expires"
        let (store, defaults) = store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        var withdrawn: [String] = []
        store.removeNotifications = { withdrawn.append(contentsOf: $0) }
        store.hookReceived(message("Notification", type: "permission_prompt"), now: t0)
        #expect(store.isAwaitingInput(.claude))
        let expected = 1
        #expect(publishes(of: store) { store.sweepSessions(now: t0.addingTimeInterval(601)) } == expected)
        #expect(!store.isAwaitingInput(.claude))
        #expect(withdrawn == ["session/a/waiting"])
    }
}
