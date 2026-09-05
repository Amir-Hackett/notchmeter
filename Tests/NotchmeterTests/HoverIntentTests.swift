import Foundation
import Testing
@testable import Notchmeter

/// Times are seconds; the pointer is sampled at the moments a real mouse monitor or tick would report it.
@Suite struct HoverRules {
    let dwell = HoverIntent.expandDwell
    let leave = HoverIntent.collapseDwell
    let settle = HoverIntent.settleTimeout

    func compact(_ mode: HoverIntent.Mode = .onHover) -> HoverIntent {
        HoverIntent(mode: mode)
    }

    /// Expanded by resting in the compact region from t = 0; the expand is issued at `dwell`.
    func expanded(_ mode: HoverIntent.Mode = .onHover) -> HoverIntent {
        var intent = compact(mode)
        #expect(intent.pointer(inCompact: true, inExpanded: true, at: 0) == .none)
        #expect(intent.pointer(inCompact: true, inExpanded: true, at: dwell) == .expand)
        intent.transitionSettled(at: dwell + 0.1)
        return intent
    }

    @Test func nothingBeforeTheDwell() {
        var intent = compact()
        #expect(intent.pointer(inCompact: true, inExpanded: true, at: 0) == .none)
        #expect(intent.pointer(inCompact: true, inExpanded: true, at: 0.1) == .none)
        #expect(intent.pointer(inCompact: true, inExpanded: true, at: dwell - 0.001) == .none)
        #expect(intent.state == .compact)
        #expect(intent.nextDeadline == dwell)
    }

    @Test func passingThroughNeverOpens() {
        var intent = compact()
        #expect(intent.pointer(inCompact: true, inExpanded: true, at: 0) == .none)
        #expect(intent.pointer(inCompact: false, inExpanded: false, at: 0.1) == .none)
        #expect(intent.pointer(inCompact: true, inExpanded: true, at: 0.2) == .none)
        #expect(intent.pointer(inCompact: true, inExpanded: true, at: 0.4) == .none)
        #expect(intent.pointer(inCompact: true, inExpanded: true, at: 0.2 + dwell) == .expand)
        #expect(intent.nextDeadline == nil)
    }

    @Test func restingOpensExactlyOnce() {
        var intent = compact()
        #expect(intent.pointer(inCompact: true, inExpanded: true, at: 0) == .none)
        #expect(intent.pointer(inCompact: true, inExpanded: true, at: dwell) == .expand)
        #expect(intent.state == .expanded)
        for step in 1...40 {
            #expect(intent.pointer(inCompact: true, inExpanded: true, at: dwell + Double(step) * 0.1) == .none)
        }
        #expect(intent.state == .expanded)
    }

    @Test func flappingDuringTheSettleWindowIsIgnored() {
        var intent = compact()
        _ = intent.pointer(inCompact: true, inExpanded: true, at: 0)
        #expect(intent.pointer(inCompact: true, inExpanded: true, at: dwell) == .expand)
        for step in 1...16 {
            let inside = step % 2 == 0
            #expect(intent.pointer(inCompact: inside, inExpanded: inside, at: dwell + Double(step) * 0.02) == .none)
        }
        #expect(intent.nextDeadline == nil)
        #expect(intent.state == .expanded)
        // Once the window passes, the outside clock starts fresh rather than from the flapping.
        let after = dwell + settle
        #expect(intent.pointer(inCompact: false, inExpanded: false, at: after) == .none)
        #expect(intent.pointer(inCompact: false, inExpanded: false, at: after + leave - 0.01) == .none)
        #expect(intent.pointer(inCompact: false, inExpanded: false, at: after + leave) == .collapse)
    }

    @Test func settlingEarlyEndsTheWindow() {
        var intent = compact()
        _ = intent.pointer(inCompact: true, inExpanded: true, at: 0)
        _ = intent.pointer(inCompact: true, inExpanded: true, at: dwell)
        intent.transitionSettled(at: dwell + 0.1)
        #expect(intent.pointer(inCompact: false, inExpanded: false, at: dwell + 0.15) == .none)
        #expect(intent.pointer(inCompact: false, inExpanded: false, at: dwell + 0.15 + leave) == .collapse)
    }

    @Test func aStationaryPointerInsideTheOpenPanelNeverCollapses() {
        var intent = expanded()
        var time = dwell
        while time < 30 {
            time += 0.05
            #expect(intent.pointer(inCompact: false, inExpanded: true, at: time) == .none)
        }
        #expect(intent.state == .expanded)
        #expect(intent.nextDeadline == nil)
    }

    @Test func restingOnRingsThatOverhangTheOpenPanelKeepsItOpen() {
        // A readout strip wider than the panel it opens: the pointer that opened it rests on the part of the strip
        // the panel does not reach. It is still on the rings, so the panel stays open rather than flickering.
        var intent = expanded()
        var time = dwell
        while time < 30 {
            time += 0.05
            #expect(intent.pointer(inCompact: true, inExpanded: false, at: time) == .none)
        }
        #expect(intent.state == .expanded)
        #expect(intent.nextDeadline == nil)
    }

    @Test func leavingTheRingsAndThePanelStillCollapses() {
        var intent = expanded()
        let left = 2.0
        #expect(intent.pointer(inCompact: true, inExpanded: false, at: left) == .none)
        #expect(intent.pointer(inCompact: false, inExpanded: false, at: left + 0.05) == .none)
        #expect(intent.pointer(inCompact: false, inExpanded: false, at: left + 0.05 + leave) == .collapse)
        #expect(intent.state == .compact)
    }

    @Test func morphingShapeCannotFlipTheDecision() {
        // The rings' region shrinks and grows under a cursor that has not moved: only the pre-computed rects count,
        // and inside the expanded rect the compact flag is irrelevant.
        var intent = expanded()
        for step in 0..<100 {
            let time = dwell + 0.2 + Double(step) * 0.03
            #expect(intent.pointer(inCompact: step % 2 == 0, inExpanded: true, at: time) == .none)
        }
        #expect(intent.state == .expanded)
    }

    @Test func leavingForTheDwellCollapsesOnce() {
        var intent = expanded()
        let left = 2.0
        #expect(intent.pointer(inCompact: false, inExpanded: false, at: left) == .none)
        #expect(intent.nextDeadline == left + leave)
        #expect(intent.pointer(inCompact: false, inExpanded: false, at: left + 0.25) == .none)
        #expect(intent.pointer(inCompact: false, inExpanded: false, at: left + leave) == .collapse)
        #expect(intent.state == .compact)
        #expect(intent.pointer(inCompact: false, inExpanded: false, at: left + leave + settle + 1) == .none)
        #expect(intent.pointer(inCompact: false, inExpanded: false, at: left + leave + settle + 2) == .none)
    }

    @Test func aBriefExitDoesNotCollapse() {
        var intent = expanded()
        #expect(intent.pointer(inCompact: false, inExpanded: false, at: 2) == .none)
        #expect(intent.pointer(inCompact: false, inExpanded: false, at: 2.3) == .none)
        #expect(intent.pointer(inCompact: false, inExpanded: true, at: 2.35) == .none)
        #expect(intent.nextDeadline == nil)
        #expect(intent.pointer(inCompact: false, inExpanded: false, at: 2.5) == .none)
        #expect(intent.pointer(inCompact: false, inExpanded: false, at: 2.5 + leave - 0.01) == .none)
        #expect(intent.pointer(inCompact: false, inExpanded: false, at: 2.5 + leave) == .collapse)
    }

    @Test func alwaysModeNeverCollapses() {
        var intent = expanded(.always)
        var time = dwell
        while time < 10 {
            time += 0.25
            #expect(intent.pointer(inCompact: false, inExpanded: false, at: time) == .none)
        }
        #expect(intent.clickOutside(at: 11) == .none)
        #expect(intent.spaceChangedOrLocked(at: 12) == .none)
        #expect(intent.state == .expanded)
        #expect(intent.nextDeadline == nil)
    }

    @Test func switchingToAlwaysWhileOutsideStopsThePendingCollapse() {
        var intent = expanded()
        #expect(intent.pointer(inCompact: false, inExpanded: false, at: 2) == .none)
        intent.mode = .always
        #expect(intent.pointer(inCompact: false, inExpanded: false, at: 2 + leave) == .none)
        intent.mode = .onHover
        #expect(intent.pointer(inCompact: false, inExpanded: false, at: 3) == .none)
        #expect(intent.pointer(inCompact: false, inExpanded: false, at: 3 + leave) == .collapse)
    }

    @Test func clickingOutsideCollapsesAtOnce() {
        var intent = expanded()
        #expect(intent.clickOutside(at: 1) == .collapse)
        #expect(intent.state == .compact)
        #expect(intent.clickOutside(at: 1.1) == .none)
        // Even inside the settle window of the expand it interrupts.
        var fresh = compact()
        _ = fresh.pointer(inCompact: true, inExpanded: true, at: 0)
        #expect(fresh.pointer(inCompact: true, inExpanded: true, at: dwell) == .expand)
        #expect(fresh.clickOutside(at: dwell + 0.05) == .collapse)
    }

    @Test func spaceChangeAndScreenLockCollapseAtOnce() {
        var intent = expanded()
        #expect(intent.spaceChangedOrLocked(at: 1) == .collapse)
        #expect(intent.state == .compact)
        #expect(intent.spaceChangedOrLocked(at: 2) == .none)
        var other = expanded()
        #expect(other.spaceChangedOrLocked(at: 1) == .collapse)
    }

    @Test func afterAnInterruptTheDwellStartsOver() {
        var intent = expanded()
        #expect(intent.spaceChangedOrLocked(at: 1) == .collapse)
        // The pointer happens to rest where the rings are: only a fresh dwell after the settle window reopens.
        #expect(intent.pointer(inCompact: true, inExpanded: true, at: 1.2) == .none)
        #expect(intent.pointer(inCompact: true, inExpanded: true, at: 1 + settle) == .none)
        #expect(intent.pointer(inCompact: true, inExpanded: true, at: 1 + settle + dwell - 0.001) == .none)
        #expect(intent.pointer(inCompact: true, inExpanded: true, at: 1 + settle + dwell) == .expand)
    }

    @Test func noRepeatedTransitions() {
        var intent = expanded()
        #expect(intent.pointer(inCompact: true, inExpanded: true, at: 5) == .none)
        #expect(intent.pointer(inCompact: true, inExpanded: true, at: 5 + dwell) == .none)
        var closed = compact()
        #expect(closed.clickOutside(at: 0) == .none)
        #expect(closed.spaceChangedOrLocked(at: 0) == .none)
        #expect(closed.pointer(inCompact: false, inExpanded: false, at: 0) == .none)
        #expect(closed.pointer(inCompact: false, inExpanded: false, at: 1) == .none)
        #expect(closed.state == .compact)
    }

    @Test func adoptingAStateSettlesFromThere() {
        var intent = compact(.always)
        intent.adopt(.expanded, at: 0)
        #expect(intent.state == .expanded)
        #expect(intent.pointer(inCompact: false, inExpanded: false, at: 0.1) == .none)
        intent.mode = .onHover
        #expect(intent.pointer(inCompact: false, inExpanded: false, at: settle) == .none)
        #expect(intent.pointer(inCompact: false, inExpanded: false, at: settle + leave) == .collapse)
        let before = intent
        intent.adopt(.compact, at: 3)
        #expect(intent == before)
    }

    @Test func aLateSettleChangesNothing() {
        var intent = expanded()
        #expect(intent.clickOutside(at: 1) == .collapse)
        intent.transitionSettled(at: 1 + settle + 0.5)
        #expect(intent.state == .compact)
        #expect(intent.nextDeadline == nil)
        #expect(intent.pointer(inCompact: true, inExpanded: true, at: 1.9) == .none)
        #expect(intent.pointer(inCompact: true, inExpanded: true, at: 1.9 + dwell) == .expand)
    }

    @Test func thresholdsAreExactToTheMillisecond() {
        var intent = expanded()
        #expect(intent.pointer(inCompact: false, inExpanded: false, at: 2.0) == .none)
        #expect(intent.pointer(inCompact: false, inExpanded: false, at: 2.399) == .none)
        #expect(intent.pointer(inCompact: false, inExpanded: false, at: 2.4) == .collapse)
        var fresh = compact()
        #expect(fresh.pointer(inCompact: true, inExpanded: true, at: 0.1) == .none)
        #expect(fresh.pointer(inCompact: true, inExpanded: true, at: 0.349) == .none)
        #expect(fresh.pointer(inCompact: true, inExpanded: true, at: 0.35) == .expand)
    }
}

@Suite struct ClickSwipeAndShortcutRules {
    let dwell = HoverIntent.expandDwell
    let settle = HoverIntent.settleTimeout

    @Test func openOnClickIgnoresThePointerAndTogglesOnAClick() {
        var intent = HoverIntent(mode: .onClick)
        #expect(intent.pointer(inCompact: true, inExpanded: true, at: 0) == .none)
        #expect(intent.pointer(inCompact: true, inExpanded: true, at: 5) == .none)
        #expect(intent.nextDeadline == nil)
        #expect(intent.clickInside(at: 6) == .expand)
        #expect(intent.state == .expanded)
        #expect(intent.pointer(inCompact: false, inExpanded: false, at: 10) == .none)
        #expect(intent.pointer(inCompact: false, inExpanded: false, at: 20) == .none)
        #expect(intent.clickOutside(at: 21) == .collapse)
        #expect(intent.clickInside(at: 22) == .expand)
        #expect(intent.clickInside(at: 23) == .collapse)
        var hover = HoverIntent(mode: .onHover)
        #expect(hover.clickInside(at: 0) == .none)
    }

    @Test func theHoverDelayIsConfigurableAndClamped() {
        var slow = HoverIntent(mode: .onHover, expandDwell: 0.8)
        #expect(slow.pointer(inCompact: true, inExpanded: true, at: 0) == .none)
        #expect(slow.pointer(inCompact: true, inExpanded: true, at: 0.5) == .none)
        #expect(slow.nextDeadline == 0.8)
        #expect(slow.pointer(inCompact: true, inExpanded: true, at: 0.8) == .expand)
        #expect(HoverIntent(mode: .onHover, expandDwell: 5).expandDwell == 1)
        #expect(HoverIntent(mode: .onHover, expandDwell: 0).expandDwell == 0.1)
    }

    @Test func swipesOpenAndCloseEscapeClosesTheShortcutToggles() {
        var intent = HoverIntent(mode: .onHover)
        #expect(intent.swipe(.up, inCompact: true, inExpanded: true, at: 0) == .none)
        #expect(intent.swipe(.down, inCompact: false, inExpanded: false, at: 0) == .none)
        #expect(intent.swipe(.down, inCompact: true, inExpanded: true, at: 0) == .expand)
        #expect(intent.swipe(.down, inCompact: true, inExpanded: true, at: 1) == .none)
        // Over the panel's own content an upward swipe is a scroll, so it must not close.
        #expect(intent.swipe(.up, inCompact: false, inExpanded: true, at: 2) == .none)
        #expect(intent.swipe(.up, inCompact: true, inExpanded: false, at: 2) == .collapse)
        #expect(intent.escape(at: 3) == .none)
        #expect(intent.toggle(at: 4) == .expand)
        #expect(intent.escape(at: 5) == .collapse)
        #expect(intent.toggle(at: 6) == .expand)
        #expect(intent.toggle(at: 7) == .collapse)
        var always = HoverIntent(mode: .always, state: .expanded)
        #expect(always.swipe(.up, inCompact: true, inExpanded: false, at: 0) == .none)
        #expect(always.escape(at: 1) == .none)
        #expect(always.toggle(at: 2) == .collapse)
        #expect(always.toggle(at: 3) == .expand)
    }

    @Test func controlClicksAndScrollsAreReducedApart() {
        #expect(PointerEvent(kind: .controlClick) != PointerEvent(kind: .click))
        #expect(PointerEvent(kind: .moved) == PointerEvent(kind: .moved))
    }
}

@Suite struct HoverRegionRules {
    let regions = HoverRegions(compact: CGRect(x: 600, y: 950, width: 300, height: 32),
                               expanded: CGRect(x: 550, y: 500, width: 400, height: 482))

    @Test func compactIsExact() {
        #expect(regions.hit(CGPoint(x: 601, y: 960)).inCompact)
        #expect(!regions.hit(CGPoint(x: 599, y: 960)).inCompact)
        #expect(!regions.hit(CGPoint(x: 700, y: 949)).inCompact)
    }

    @Test func expandedCarriesTheMargin() {
        let margin = HoverIntent.expandedMargin
        #expect(margin == 8)
        #expect(regions.hit(CGPoint(x: 550 - margin + 1, y: 700)).inExpanded)
        #expect(!regions.hit(CGPoint(x: 550 - margin - 1, y: 700)).inExpanded)
        #expect(regions.hit(CGPoint(x: 700, y: 500 - margin + 1)).inExpanded)
        #expect(!regions.hit(CGPoint(x: 700, y: 500 - margin - 1)).inExpanded)
    }

    @Test func clicksUseThePanelWithoutTheMargin() {
        #expect(!regions.isOutsidePanel(CGPoint(x: 700, y: 700)))
        #expect(regions.isOutsidePanel(CGPoint(x: 545, y: 700)))
        #expect(HoverRegions.none.isOutsidePanel(.zero))
        #expect(!HoverRegions.none.hit(.zero).inCompact)
    }
}


/// The glance: opens a closed panel for a few seconds, keeps it open when the pointer comes in, never fights it.
@Suite struct GlanceRules {
    let settle = HoverIntent.settleTimeout

    @Test func aGlanceOpensAndSettlesUnlessThePointerComesIn() {
        var intent = HoverIntent(mode: .onHover)
        #expect(intent.glance(at: 0) == .expand)
        #expect(intent.isGlancing)
        #expect(intent.state == .expanded)
        #expect(intent.nextDeadline == HoverIntent.glanceDuration)
        #expect(intent.pointer(inCompact: false, inExpanded: false, at: 1) == .none)
        #expect(intent.pointer(inCompact: false, inExpanded: false, at: HoverIntent.glanceDuration - 0.01) == .none)
        #expect(intent.pointer(inCompact: false, inExpanded: false, at: HoverIntent.glanceDuration) == .collapse)
        #expect(!intent.isGlancing)
        #expect(intent.state == .compact)
        var kept = HoverIntent(mode: .onHover)
        _ = kept.glance(at: 0)
        #expect(kept.pointer(inCompact: false, inExpanded: true, at: settle + 0.1) == .none)
        #expect(!kept.isGlancing)
        #expect(kept.pointer(inCompact: false, inExpanded: true, at: 10) == .none)
        #expect(kept.pointer(inCompact: false, inExpanded: false, at: 11) == .none)
        #expect(kept.pointer(inCompact: false, inExpanded: false, at: 11 + HoverIntent.collapseDwell) == .collapse)
    }

    @Test func aGlanceNeverFightsAnOpenPanelOrAlwaysMode() {
        var open = HoverIntent(mode: .onHover, state: .expanded)
        #expect(open.glance(at: 0) == .none)
        #expect(!open.isGlancing)
        var always = HoverIntent(mode: .always)
        #expect(always.glance(at: 0) == .none)
        var click = HoverIntent(mode: .onClick)
        #expect(click.glance(at: 0) == .expand)
        #expect(click.pointer(inCompact: false, inExpanded: false, at: HoverIntent.glanceDuration + 1) == .collapse)
        var interrupted = HoverIntent(mode: .onHover)
        _ = interrupted.glance(at: 0)
        #expect(interrupted.clickOutside(at: 1) == .collapse)
        #expect(!interrupted.isGlancing)
        var custom = HoverIntent(mode: .onHover)
        _ = custom.glance(for: 5, at: 0)
        #expect(custom.nextDeadline == 5)
    }

    /// A notification's click opens the panel on the same clock, for longer: nothing that follows that click is
    /// bound to close it again, and in the click-to-open modes a click landing where the panel stands does not.
    @Test func aNotificationsGlanceRunsLongerAndStillYieldsToThePointer() {
        var intent = HoverIntent(mode: .onClick)
        #expect(intent.glance(for: HoverIntent.notificationGlance, at: 0) == .expand)
        intent.transitionSettled(at: 0.1)
        #expect(intent.pointer(inCompact: false, inExpanded: false, at: HoverIntent.glanceDuration + 1) == .none)
        #expect(intent.pointer(inCompact: false, inExpanded: false, at: HoverIntent.notificationGlance) == .collapse)

        // Reading it cancels the clock — and then leaving it closes it, in a mode where nothing else would. A
        // panel that opened for a look is not a panel the user asked to keep.
        var read = HoverIntent(mode: .onClick)
        _ = read.glance(for: HoverIntent.notificationGlance, at: 0)
        read.transitionSettled(at: 0.1)
        #expect(read.pointer(inCompact: false, inExpanded: true, at: 2) == .none)
        #expect(read.isGlancing == false)
        #expect(read.state == .expanded)
        #expect(read.pointer(inCompact: false, inExpanded: true, at: 20) == .none)
        #expect(read.pointer(inCompact: false, inExpanded: false, at: 21) == .none)
        #expect(read.pointer(inCompact: false, inExpanded: false, at: 21 + HoverIntent.collapseDwell) == .collapse)

        // A panel the user opened themselves keeps the mode's own rule: leaving it does not close it in click mode.
        var asked = HoverIntent(mode: .onClick)
        #expect(asked.clickInside(at: 0) == .expand)
        asked.transitionSettled(at: 0.1)
        #expect(asked.pointer(inCompact: false, inExpanded: true, at: 1) == .none)
        #expect(asked.pointer(inCompact: false, inExpanded: false, at: 2 + HoverIntent.collapseDwell) == .none)
        #expect(asked.state == .expanded)
    }

    @Test func aClickedOpenPanelTakesTheKeyboardAndEscapeGivesItBack() {
        var intent = HoverIntent(mode: .onClick)
        #expect(intent.clickInside(at: 0) == .expand)
        #expect(PanelKeyPolicy.takesKeyboard(.click))
        #expect(PanelKeyPolicy.takesKeyboard(.swipe))
        #expect(PanelKeyPolicy.takesKeyboard(.hotkey))
        #expect(PanelKeyPolicy.takesKeyboard(.notification))
        #expect(!PanelKeyPolicy.takesKeyboard(.dwell))
        #expect(!PanelKeyPolicy.takesKeyboard(.glance))
        #expect(!PanelKeyPolicy.takesKeyboard(.always))
        #expect(intent.escape(at: 1) == .collapse)
        #expect(intent.state == .compact)
        var swiped = HoverIntent(mode: .onHover)
        #expect(swiped.swipe(.down, inCompact: true, inExpanded: true, at: 0) == .expand)
        #expect(swiped.escape(at: 1) == .collapse)
    }
}

/// A click a point or two under the strip used to land nowhere — not on the readouts, not outside the panel —
/// so the first click did nothing and the second one worked.
@Suite struct ClicksHaveSlop {
    private let regions = HoverRegions(compact: CGRect(x: 600, y: 950, width: 300, height: 32),
                                       expanded: CGRect(x: 550, y: 100, width: 410, height: 850))

    @Test func justUnderTheStripStillCounts() {
        #expect(regions.isClickOnCompact(CGPoint(x: 750, y: 947)))
        #expect(regions.isClickOnCompact(CGPoint(x: 750, y: 960)))
        #expect(regions.isClickOnCompact(CGPoint(x: 596, y: 960)))
    }

    @Test func wellAwayDoesNot() {
        #expect(!regions.isClickOnCompact(CGPoint(x: 750, y: 900)))
        #expect(!regions.isClickOnCompact(CGPoint(x: 300, y: 960)))
        #expect(!HoverRegions.none.isClickOnCompact(CGPoint(x: 750, y: 960)))
    }

    @Test func hoveringKeepsTheExactShape() {
        // The slop is for aiming a click, not for opening on a near miss.
        #expect(!regions.hit(CGPoint(x: 750, y: 947)).inCompact)
        #expect(regions.hit(CGPoint(x: 750, y: 960)).inCompact)
    }
}
