import Foundation
import Testing
@testable import Notchmeter

@Suite struct PollingRules {
    init() { Localization.use(language: "en") }

    let base: TimeInterval = 180

    func inputs(locked: Bool = false, asleep: Bool = false, battery: Bool = false, minutes: Double? = 5, hook: Bool = false, base: TimeInterval? = nil) -> PollingInputs {
        PollingInputs(baseInterval: base ?? self.base, screenLocked: locked, asleep: asleep, onBattery: battery,
                      minutesSinceLastAgentActivity: minutes, hookNudge: hook)
    }

    @Test func pausesWhileLockedOrAsleep() {
        #expect(PollingPolicy.decide(inputs(locked: true)) == .paused(.screenLocked))
        #expect(PollingPolicy.decide(inputs(asleep: true)) == .paused(.asleep))
        #expect(PollingPolicy.decide(inputs(locked: true, asleep: true, battery: true, minutes: 90)) == .paused(.asleep))
    }

    @Test func baseWhileAnAgentIsActive() {
        #expect(PollingPolicy.decide(inputs(minutes: 0)) == .after(180))
        #expect(PollingPolicy.decide(inputs(minutes: 29.9)) == .after(180))
    }

    @Test func doublesOnBattery() {
        #expect(PollingPolicy.decide(inputs(battery: true)) == .after(360))
        #expect(PollingPolicy.decide(inputs(battery: true, base: 120)) == .after(240))
    }

    @Test func quadruplesWhenIdleUnderAFifteenMinuteCeiling() {
        #expect(PollingPolicy.decide(inputs(minutes: 30)) == .after(720))
        #expect(PollingPolicy.decide(inputs(minutes: nil)) == .after(720))
        #expect(PollingPolicy.decide(inputs(minutes: 600, base: 300)) == .after(900))
        #expect(PollingPolicy.decide(inputs(battery: true, minutes: 45, base: 120)) == .after(900))
    }

    @Test func hookNudgeCountsAsActivity() {
        #expect(PollingPolicy.decide(inputs(minutes: 400, hook: true)) == .after(180))
        #expect(PollingPolicy.decide(inputs(minutes: nil, hook: true, base: 120)) == .after(120))
        #expect(PollingPolicy.isIdle(inputs(minutes: 31)))
        #expect(!PollingPolicy.isIdle(inputs(minutes: 31, hook: true)))
    }

    @Test func displaySleepPausesAndLowPowerModeHalvesTheCadence() {
        var sleeping = inputs()
        sleeping.screensAsleep = true
        #expect(PollingPolicy.decide(sleeping) == .paused(.screensAsleep))
        #expect(PauseReason.screensAsleep.footerText == "Paused while the display sleeps")
        var lowPower = inputs()
        lowPower.lowPowerMode = true
        #expect(PollingPolicy.decide(lowPower) == .after(360))
        lowPower.onBattery = true
        #expect(PollingPolicy.decide(lowPower) == .after(360))
        var statusline = inputs()
        statusline.secondsSinceStatusline = 10
        #expect(PollingPolicy.decide(statusline) == .paused(.statusline))
        statusline.screenLocked = true
        #expect(PollingPolicy.decide(statusline) == .paused(.screenLocked))
    }

    @Test func neverBelowTheProviderInterval() {
        #expect(PollingPolicy.decide(inputs(minutes: 90, base: 1200)) == .after(1200))
        #expect(PollingPolicy.decide(inputs(battery: true, minutes: nil, base: 3600)) == .after(3600))
        #expect(PollingPolicy.decide(inputs(minutes: 1, base: 30)) == .after(30))
    }
}


/// A switched-out user session slows to the ceiling rather than stopping; an exhausted main window does the same.
@Suite struct PollingRoundTwo {
    init() { Localization.use(language: "en") }

    let now = DateParsing.iso8601("2026-09-01T12:00:00Z")!

    /// The reading has to survive the switch. The other user's session goes on spending the same account's
    /// limits, so stopping here would lose the drain rows and the run-out warning for the whole time away.
    @Test func anotherUsersSessionSlowsToTheCeilingRatherThanStopping() {
        var inputs = PollingInputs(baseInterval: 300, minutesSinceLastAgentActivity: 1)
        inputs.sessionInactive = true
        #expect(PollingPolicy.decide(inputs) == .after(PollingPolicy.ceiling))
        inputs.sessionInactive = false
        #expect(PollingPolicy.decide(inputs) == .after(300))
    }

    /// Being switched out never makes a tool read faster than its provider allows.
    @Test func aSlowProviderStaysSlowerThanTheCeiling() {
        var inputs = PollingInputs(baseInterval: 3600, minutesSinceLastAgentActivity: 1)
        inputs.sessionInactive = true
        #expect(PollingPolicy.decide(inputs) == .after(3600))
    }

    /// A sleeping or locked Mac still stops outright: there the work has stopped too.
    @Test func sleepStillWinsOverASwitchedOutSession() {
        var inputs = PollingInputs(baseInterval: 300, minutesSinceLastAgentActivity: 1)
        inputs.sessionInactive = true
        inputs.asleep = true
        #expect(PollingPolicy.decide(inputs) == .paused(.asleep))
        inputs.asleep = false
        inputs.screenLocked = true
        #expect(PollingPolicy.decide(inputs) == .paused(.screenLocked))
    }

    /// Launched behind another user's session, the app is told by nobody: no switch notification ever fires for
    /// the session it started in, so the flag is seeded from the window server instead.
    @Test func aSessionBehindAnotherIsRecognisedAtLaunch() {
        #expect(LoginSession.isOnConsole(["kCGSSessionOnConsoleKey": true]))
        #expect(!LoginSession.isOnConsole(["kCGSSessionOnConsoleKey": false]))
        #expect(!LoginSession.isOnConsole(["kCGSSessionOnConsoleKey": NSNumber(value: false)]))
        #expect(LoginSession.isOnConsole([:]))
        #expect(LoginSession.isOnConsole(nil))
    }

    @Test func anExhaustedWindowIdlesUntilItsResetAndTheFooterSaysWhen() {
        var inputs = PollingInputs(baseInterval: 300, minutesSinceLastAgentActivity: 1, now: now)
        inputs.exhaustedUntil = now.addingTimeInterval(32 * 60)
        #expect(PollingPolicy.isExhausted(inputs))
        #expect(PollingPolicy.decide(inputs) == .after(PollingPolicy.ceiling))
        inputs.exhaustedUntil = now.addingTimeInterval(-1)
        #expect(!PollingPolicy.isExhausted(inputs))
        #expect(PollingPolicy.decide(inputs) == .after(300))
        inputs.exhaustedUntil = nil
        #expect(PollingPolicy.decide(inputs) == .after(300))
        #expect(L("Resets in %@", ResetText.duration(32 * 60)) == "Resets in 32m")
    }

    @MainActor @Test func theStoreBacksOffAnExhaustedToolAndNamesTheReset() {
        let suite = "NotchmeterTests.Polling.exhausted"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        let now = Date()
        let out = UsageReading(tool: .codex, windows: [
            LimitWindow(id: "session", label: "Session", usedFraction: 0.2, resetsAt: now.addingTimeInterval(3600), periodDuration: Period.fiveHours),
            LimitWindow(id: "weekly", label: "Weekly", usedFraction: 1, resetsAt: now.addingTimeInterval(32 * 60), periodDuration: Period.week),
        ], plan: nil, fetchedAt: now, observedAt: nil)
        let store = UsageStore(prefs: prefs, providers: [FixtureProvider(reading: out)], cache: ReadingCache(defaults: defaults), defaults: defaults, drainLog: nil, reportFile: nil)
        store.seed(readings: [out], cost: .empty, nextUpdate: now.addingTimeInterval(60), now: now)
        let inputs = store.pollingInputs(for: .codex, now: now)
        #expect(inputs.exhaustedUntil == now.addingTimeInterval(32 * 60))
        #expect(PollingPolicy.decide(inputs) == .after(PollingPolicy.ceiling))
        #expect(store.scheduleNote?.hasPrefix("Resets in 3") == true)
    }
}
