import CoreGraphics
import Foundation
import Testing
@testable import Notchmeter

/// Auto's rule, without a menu bar. The strip has to fit a gap squeezed from both ends: menu titles growing right
/// from the left, status items growing left from the right. When a whole side is free it uses both sides of the
/// notch; when one end reaches in it moves to the other; when neither end leaves room it gives up the numbers, and
/// then the tools the user put last, before it will ever overlap. Nothing measured keeps the fixed side chosen
/// before Auto, whole.
@Suite struct AutoCompactFit {
    /// A 14-inch notch: the screen 1512 wide, the notch 200 wide across the middle of a 37 pt menu bar.
    static let notch = CGRect(x: 656, y: 945, width: 200, height: 37)

    /// A stand-in for the real strip: 30 pt a tool with rings, 60 pt with numbers, plus 12 pt of padding once
    /// there is anything at all. Close enough in shape to the drawn one that the ladder is exercised the same way.
    static func width(_ run: CompactFit.Run) -> CGFloat {
        guard !run.isEmpty else { return 0 }
        return CGFloat(run.readouts.count) * (run.style.showsNumbers ? 60 : 30) + (run.overflow > 0 ? 14 : 0) + 12
    }

    func fit(menus: CGFloat?, statusItems: CGFloat?, tools: Int = 4, style: CompactStyle = .numbers) -> CompactFit {
        CompactFit.resolve(notch: Self.notch, menusEndX: menus, statusItemsStartX: statusItems, tools: tools,
                           style: style, width: Self.width)
    }

    @Test func bothEndsClearKeepsBothSidesOfTheNotch() {
        // Menus stop at 200 and the status items start at 1400: 448 pt free left, 536 pt right, against 2 tools
        // (132 pt) a side at numbers.
        let fit = fit(menus: 200, statusItems: 1400)
        #expect(fit == CompactFit(side: .split, style: .numbers, toolCount: 4, dropped: 0, splitLeading: 2))
    }

    @Test func menusReachingPastTheNotchLeaveOnlyTheTrailingSide() {
        // A menu-heavy app whose titles run past the notch's left edge; nothing at all fits to the left.
        let fit = fit(menus: 900, statusItems: 1500)
        #expect(fit.side == .trailing)
        #expect(fit.style == .numbers)
        #expect(fit.dropped == 0)
    }

    @Test func statusItemsReachingInLeaveOnlyTheLeadingSide() {
        // Menus stop early, but the status items reach to 870 — past the notch, so nothing fits to its right.
        let fit = fit(menus: 100, statusItems: 870)
        #expect(fit.side == .leading)
        #expect(fit.style == .numbers)
        #expect(fit.dropped == 0)
    }

    @Test func neitherSideFittingAtNumbersFallsBackToRings() {
        // 100 pt free each side. Four tools want 132 pt a side at numbers and 252 pt whole, neither of which fits;
        // at rings a side wants 72 pt, so split survives with the digits given up.
        let fit = fit(menus: 548, statusItems: 964)
        #expect(fit == CompactFit(side: .split, style: .rings, toolCount: 4, dropped: 0, splitLeading: 2))
    }

    @Test func neitherSideFittingAtRingsDropsTheToolsPutLast() {
        // 50 pt free left, 60 pt right: at rings not even two tools fit on one side, so the two the user put last
        // go, and the "+2" says so.
        let fit = fit(menus: 598, statusItems: 924)
        #expect(fit == CompactFit(side: .split, style: .rings, toolCount: 2, dropped: 2, splitLeading: 1))
    }

    @Test func withNoRoomAtAllItShowsTheSmallestStripThereIs() {
        // Both ends right up against the notch: nothing fits, so one tool with rings on the roomier side.
        let fit = fit(menus: 700, statusItems: 800)
        #expect(fit.style == .rings)
        #expect(fit.toolCount == 1)
        #expect(fit.dropped == 3)
        #expect(fit.side != .split)
    }

    /// An odd run cannot be halved, so one end carries the extra readout. It rests on the right — the left is
    /// where menu titles grow — and moves only when the right will not hold two, never because the left merely
    /// measured a little wider.
    @Test func anOddRunRestsWithItsExtraReadoutOnTheRight() {
        // The resting shape, with no menu bar to consult: one left, two right, at every odd size.
        #expect(CompactFit.splitLeadingCount(of: 3) == 1)
        #expect(CompactFit.splitLeadingCount(of: 1) == 0)
        #expect(CompactFit.splitLeadingCount(of: 5) == 2)
        // An even run halves cleanly and has no extra to place.
        #expect(CompactFit.splitLeadingCount(of: 4) == 2)

        // Both ends roomy: the resting shape stands, and the resolved fit carries it so the view does not guess.
        let roomy = fit(menus: 200, statusItems: 1400, tools: 3, style: .rings)
        #expect(roomy.side == .split)
        #expect(roomy.splitLeading == 1)

        // The left measuring wider is not on its own a reason to move anything. Menus to 400 leave 248 pt left;
        // status items at 1050 leave 186 pt right, which still holds two rings (72 pt), so nothing moves.
        let widerLeft = fit(menus: 400, statusItems: 1050, tools: 3, style: .rings)
        #expect(widerLeft.side == .split)
        #expect(widerLeft.splitLeading == 1, "a roomier left is not a reason to move a readout that already fits")

        // Crowd the right until two rings no longer fit there — 60 pt of room against 72 pt of readouts.
        let crowdedRight = fit(menus: 400, statusItems: 924, tools: 3, style: .rings)
        #expect(crowdedRight.side == .leading, "an end that cannot hold its half moves the strip, not a readout across the notch")
        #expect(crowdedRight.splitLeading == nil, "a strip on one side of the notch has no split to record")
        #expect(crowdedRight.dropped == 0, "moving aside comes before giving anything up")

        // A single side has no split to record.
        #expect(fit(menus: 900, statusItems: nil).splitLeading == nil)
    }

    @Test func nothingMeasuredSitsCentredWithEveryTool() {
        // Auto's resting arrangement, which is also where it goes back to whenever the ends let go.
        #expect(fit(menus: nil, statusItems: nil) == CompactFit.whole(side: .split, style: .numbers))
    }

    /// The order the user asked for in so many words: centred while there is room, then over to the side that
    /// still has room, and only once both ends have closed in does anything get given up.
    @Test func theStripMovesAsideBeforeItGivesAnythingUp() {
        // Menus creeping right, status items where they were: centred, then trailing, both with every tool.
        #expect(fit(menus: 200, statusItems: 1400).side == .split)
        #expect(fit(menus: 700, statusItems: 1400) == CompactFit(side: .trailing, style: .numbers, toolCount: 4, dropped: 0))
        // Now the right closes in too, and only then does the strip start shedding.
        #expect(fit(menus: 700, statusItems: 1000).style == .rings)
    }

    @Test func oneEndUnmeasuredOnlyConstrainsTheOther() {
        // The status items could not be read, so only the menus limit anything: they reach past the notch, and the
        // unconstrained right-hand side takes the whole strip.
        #expect(fit(menus: 900, statusItems: nil).side == .trailing)
        // And the mirror: the menus could not be read, the status items reach in, so the strip goes left.
        #expect(fit(menus: nil, statusItems: 870).side == .leading)
    }

    @Test func neverAnswersAutoAndNeverDropsWhatItKeeps() {
        let edges: [CGFloat?] = [nil, 0, 400, 700, 900, 1400]
        for menus in edges {
            for statusItems in edges {
                for style in CompactStyle.allCases {
                    let fit = fit(menus: menus, statusItems: statusItems, style: style)
                    #expect(fit.side != .auto)
                    #expect(fit.toolCount >= 1)
                    #expect(fit.dropped >= 0)
                    // Numbers are given up before tools are, never the other way round.
                    #expect(fit.dropped == 0 || fit.style == .rings)
                }
            }
        }
    }

    @Test func noReadoutsMeansNothingToFit() {
        let fit = fit(menus: 1400, statusItems: 200, tools: 0)
        #expect(fit == CompactFit.whole(side: .split, style: .numbers))
    }

    @MainActor @Test func autoIsNotTheDefaultAndRestsInTheMiddle() {
        let suite = "NotchmeterTests.CompactSide.auto"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        #expect(prefs.compactSide == .split)
        #expect(prefs.resolvedCompactSide == .split)
        prefs.compactSide = .leading
        #expect(prefs.resolvedCompactSide == .leading)
        // Auto with nothing measured yet sits in the middle rather than inheriting the side chosen before it.
        prefs.compactSide = .auto
        #expect(prefs.resolvedCompactSide == .split)
        // A fixed side keeps every tool, whatever Auto last measured.
        #expect(prefs.compactFit.dropped == 0)
        prefs.autoCompactFit = CompactFit(side: .trailing, style: .rings, toolCount: 2, dropped: 2)
        #expect(prefs.resolvedCompactSide == .trailing)
        #expect(prefs.compactFit.style == .rings)
        prefs.compactSide = .trailing
        #expect(prefs.compactFit == CompactFit.whole(side: .trailing, style: prefs.compactStyle))
        prefs.compactSide = .auto
        // A relaunch has measured nothing yet, so Auto opens centred and with every tool rather than wherever the
        // squeeze last pushed it.
        let reopened = Preferences(defaults: defaults)
        #expect(reopened.compactSide == .auto)
        #expect(reopened.resolvedCompactSide == .split)
        #expect(reopened.compactFit.dropped == 0)
    }

    @Test func aSplitIsAlwaysTheRestingOne() {
        let edges: [CGFloat?] = [nil, 0, 200, 400, 548, 598, 628, 700, 900, 924, 1050, 1096, 1400]
        for menus in edges {
            for statusItems in edges {
                for tools in 1 ... 5 {
                    for style in CompactStyle.allCases {
                        let fit = fit(menus: menus, statusItems: statusItems, tools: tools, style: style)
                        guard let leading = fit.splitLeading else { continue }
                        #expect(fit.side == .split, "only a strip drawn both sides of the notch records how it was divided")
                        #expect(leading == CompactFit.splitLeadingCount(of: fit.toolCount),
                                "a measured gap decides how much of the strip is drawn, never which side a readout is drawn on")
                    }
                }
            }
        }
    }

    @Test func eachHalfOfASplitIsSizedAsTheHalfItWillBeDrawnAs() {
        let widths: [CGFloat] = [60, 30, 30]
        func width(_ run: CompactFit.Run) -> CGFloat {
            guard !run.isEmpty else { return 0 }
            return widths[run.readouts].reduce(0, +) + (run.overflow > 0 ? 14 : 0) + 12
        }
        var asked: [CompactFit.Run] = []
        let fit = CompactFit.resolve(notch: Self.notch, menusEndX: 568, statusItemsStartX: 964, tools: 3,
                                     style: .rings) { asked.append($0); return width($0) }
        #expect(fit == CompactFit(side: .split, style: .rings, toolCount: 3, dropped: 0, splitLeading: 1))
        #expect(asked.contains(CompactFit.Run(style: .rings, readouts: 0 ..< 1, overflow: 0)),
                "the half left of the notch draws the first readout and no count of what was left out")
        #expect(asked.contains(CompactFit.Run(style: .rings, readouts: 1 ..< 3, overflow: 0)),
                "the half right of the notch draws the last two readouts, which are not the first two")
    }

    @Test func onlyTheRunThatEndsTheStripCountsWhatWasLeftOut() {
        let split = CompactFit(side: .split, style: .rings, toolCount: 2, dropped: 2, splitLeading: 1).halves(visible: 4)
        #expect(split.leading == CompactFit.Run(style: .rings, readouts: 0 ..< 1, overflow: 0))
        #expect(split.trailing == CompactFit.Run(style: .rings, readouts: 1 ..< 2, overflow: 2))
        let left = CompactFit(side: .leading, style: .rings, toolCount: 2, dropped: 1).halves(visible: 3)
        #expect(left.leading == CompactFit.Run(style: .rings, readouts: 0 ..< 2, overflow: 1))
        #expect(left.trailing.isEmpty)
        let right = CompactFit(side: .trailing, style: .rings, toolCount: 2, dropped: 1).halves(visible: 3)
        #expect(right.trailing.overflow == 1)
        #expect(right.leading.isEmpty)
        let one = CompactFit(side: .split, style: .rings, toolCount: 1, dropped: 0, splitLeading: nil).halves(visible: 1)
        #expect(one.leading.isEmpty)
        #expect(one.trailing == CompactFit.Run(style: .rings, readouts: 0 ..< 1, overflow: 0))
    }
}
