import Foundation
import Testing
@testable import Notchmeter

/// The panel is held closed for as long as any window of the app's own is up, and opens again only when the last
/// of them has gone: an update session that ends while Settings is still on screen leaves the hold in place.
@Suite struct PanelHold {
    @Test func oneWindowHoldsAndReleases() {
        var holds = PanelHolds()
        #expect(holds.isHeld == false)
        var changed = holds.set(.settings, true)
        #expect(changed)
        #expect(holds.isHeld)
        changed = holds.set(.settings, false)
        #expect(changed)
        #expect(holds.isHeld == false)
    }

    @Test func onlyTheFirstHoldAndTheLastReleaseChangeAnything() {
        var holds = PanelHolds()
        var changed = holds.set(.settings, true)
        #expect(changed)
        changed = holds.set(.update, true)
        #expect(changed == false)
        changed = holds.set(.update, false)
        #expect(changed == false)
        #expect(holds.isHeld)
        changed = holds.set(.settings, false)
        #expect(changed)
        #expect(holds.isHeld == false)
    }

    @Test func repeatedAnswersFromOneWindowSayNothingNew() {
        var holds = PanelHolds()
        var changed = holds.set(.update, true)
        #expect(changed)
        changed = holds.set(.update, true)
        #expect(changed == false)
        changed = holds.set(.settings, false)
        #expect(changed == false)
        #expect(holds.isHeld)
    }
}

/// Sparkle's session: the panel is told once when the first window goes up and once when the last has gone,
/// however many of Sparkle's own callbacks arrive in between.
@Suite struct UpdateSessionHold {
    @Test func beginsOnceAndEndsOnce() {
        var calls: [Bool] = []
        let session = UpdateSession { calls.append($0) }
        session.begin()
        session.begin()
        #expect(calls == [true])
        session.end()
        session.end()
        #expect(calls == [true, false])
    }

    @Test func endingWithoutASessionSaysNothing() {
        var calls: [Bool] = []
        let session = UpdateSession { calls.append($0) }
        session.end()
        #expect(calls.isEmpty)
    }

    @Test func aSecondSessionHoldsAgain() {
        var calls: [Bool] = []
        let session = UpdateSession { calls.append($0) }
        session.begin()
        session.end()
        session.begin()
        #expect(calls == [true, false, true])
    }

    /// Sparkle warns background apps that schedule checks but never say how they want the reminder shown.
    @Test func gentleRemindersAreDeclared() {
        #expect(UpdateSession { _ in }.supportsGentleScheduledUpdateReminders)
    }
}
