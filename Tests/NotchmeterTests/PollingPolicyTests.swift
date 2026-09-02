import Foundation
import Testing
@testable import Notchmeter

@Suite struct PollingRules {
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

    @Test func neverBelowTheProviderInterval() {
        #expect(PollingPolicy.decide(inputs(minutes: 90, base: 1200)) == .after(1200))
        #expect(PollingPolicy.decide(inputs(battery: true, minutes: nil, base: 3600)) == .after(3600))
        #expect(PollingPolicy.decide(inputs(minutes: 1, base: 30)) == .after(30))
    }
}
