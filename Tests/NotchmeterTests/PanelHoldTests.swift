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

    /// The open-hold pauses the hover machine only on a panel that is open. On one still compact — a second
    /// display's, one behind Settings when the request came, one under a full-screen app — the pointer must still
    /// open it, or the card is there and unreachable for the whole hold.
    /// A click outside the open panel is what closes it for the pointer; while a request holds it open the click
    /// is ignored (a click into the terminal must not take the card down), and `dismiss` is the app's own way to
    /// close it once the request has ended.
    @Test @MainActor func aClickOutsideIsIgnoredWhileARequestHoldsThePanelOpen() {
        let hover = HoverDriver(mode: .onHover)
        hover.regions = HoverRegions(compact: CGRect(x: 100, y: 900, width: 200, height: 30), expanded: CGRect(x: 50, y: 0, width: 300, height: 800))
        var outputs: [(HoverIntent.Output, PanelCause)] = []
        hover.perform = { outputs.append(($0, $1)) }
        hover.adopt(.expanded)
        var holding = true
        hover.holdsOpen = { holding }
        hover.clicked(at: CGPoint(x: 900, y: 500))
        #expect(outputs.isEmpty, "held open: the click outside does nothing")
        hover.dismiss(cause: .notification)
        #expect(outputs.map(\.0) == [.collapse])
        #expect(outputs.map(\.1) == [.notification])
        hover.adopt(.expanded)
        holding = false
        hover.clicked(at: CGPoint(x: 900, y: 500))
        #expect(outputs.map(\.0) == [.collapse, .collapse], "released: a click outside closes the panel as ever")
        #expect(outputs.last?.1 == .clickOutside)
    }

    @Test func theOpenHoldPausesHoverOnlyOnceThePanelIsOpen() {
        #expect(PanelHolds.pausesHover(menuOpen: false, held: false, promptHeld: true, expanded: true))
        #expect(!PanelHolds.pausesHover(menuOpen: false, held: false, promptHeld: true, expanded: false), "a compact panel with a request on it opens by hover")
        #expect(PanelHolds.pausesHover(menuOpen: true, held: false, promptHeld: false, expanded: false))
        #expect(PanelHolds.pausesHover(menuOpen: false, held: true, promptHeld: false, expanded: true))
        #expect(!PanelHolds.pausesHover(menuOpen: false, held: false, promptHeld: false, expanded: true))
        #expect(!PanelHolds.pausesHover(menuOpen: false, held: false, promptHeld: false, expanded: false))
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

    /// A request on the panel holds it open, which is the other way round from every window's hold, and the two
    /// never count each other: Settings coming up still holds the panel closed while a request is showing, and
    /// the request's hold is still there when Settings goes.
    @Test func aRequestHoldsThePanelOpenAndNeverClosed() {
        var holds = PanelHolds()
        var changed = holds.set(.prompt, true)
        #expect(changed)
        #expect(holds.holdsOpen)
        #expect(holds.isHeld == false, "a request never holds the panel closed")
        changed = holds.set(.prompt, true)
        #expect(changed == false)
        changed = holds.set(.settings, true)
        #expect(changed, "Settings still changes the closed hold with a request showing")
        #expect(holds.isHeld)
        #expect(holds.holdsOpen)
        changed = holds.set(.settings, false)
        #expect(changed)
        #expect(holds.holdsOpen, "Settings going does not release the request's hold")
        changed = holds.set(.prompt, false)
        #expect(changed)
        #expect(holds.holdsOpen == false)
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
