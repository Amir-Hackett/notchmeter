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
