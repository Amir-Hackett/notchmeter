import CoreGraphics
import Foundation
import Testing
@testable import Notchmeter

/// Auto's rule, without a menu bar. The strip has to fit a gap squeezed from both ends: menu titles growing right
/// from the left, status items growing left from the right. When a whole side is free it uses both sides of the
/// notch; when one end reaches in it moves to the other; when neither end leaves room it thins the figures, a
/// level at a time, and then the tools the user put last — or, told to keep the numbers, the tools first — before
/// it will ever overlap. Nothing measured keeps the fixed side chosen before Auto, whole.
@Suite struct AutoCompactFit {
    /// A 14-inch notch: the screen 1512 wide, the notch 200 wide across the middle of a 37 pt menu bar.
    static let notch = CGRect(x: 656, y: 945, width: 200, height: 37)

    /// A stand-in for the real strip: 30 pt a ring, 45 pt a ring with its outer figure, 60 pt with both figures,
    /// plus 14 pt for a "+N" chip and 12 pt of padding once there is anything at all. Close enough in shape to the
    /// drawn one that the ladder is exercised the same way.
    static func width(_ run: CompactFit.Run) -> CGFloat {
        guard !run.isEmpty else { return 0 }
        let each: CGFloat = !run.style.showsNumbers ? 30 : run.figures == .outer ? 45 : 60
        return CGFloat(run.readouts.count) * each + (run.overflow > 0 ? 14 : 0) + 12
    }

    /// Every edge the exhaustive tests walk: unmeasured, clear of the notch, at each of the rooms the named tests
    /// use, and reaching past the notch on either side.
    static let edges: [CGFloat?] = [nil, 0, 200, 400, 548, 598, 628, 700, 900, 924, 1050, 1096, 1400]

    func fit(menus: CGFloat?, statusItems: CGFloat?, tools: Int = 4, style: CompactStyle = .numbers,
             keep: CompactKeep = .tools) -> CompactFit {
        CompactFit.resolve(notch: Self.notch, menusEndX: menus, statusItemsStartX: statusItems, tools: tools,
                           style: style, keep: keep, width: Self.width)
    }

    /// The ladder before it is dealt out across the sides, in both orders, pinned rung by rung.
    @Test func theLadderInBothOrders() {
        typealias S = CompactFit.Step
        #expect(CompactFit.steps(style: .ringsAndNumbers, tools: 3, keep: .tools) == [
            S(style: .ringsAndNumbers, figures: .all, count: 3), S(style: .ringsAndNumbers, figures: .outer, count: 3),
            S(style: .rings, figures: .all, count: 3), S(style: .rings, figures: .all, count: 2), S(style: .rings, figures: .all, count: 1),
        ], "keeping the tools thins the style with every tool intact and drops tools only at rings")
        #expect(CompactFit.steps(style: .ringsAndNumbers, tools: 3, keep: .numbers) == [
            S(style: .ringsAndNumbers, figures: .all, count: 3), S(style: .ringsAndNumbers, figures: .all, count: 2), S(style: .ringsAndNumbers, figures: .all, count: 1),
            S(style: .ringsAndNumbers, figures: .outer, count: 3), S(style: .ringsAndNumbers, figures: .outer, count: 2), S(style: .ringsAndNumbers, figures: .outer, count: 1),
            S(style: .rings, figures: .all, count: 3), S(style: .rings, figures: .all, count: 2), S(style: .rings, figures: .all, count: 1),
        ], "keeping the numbers drops tools at each level before thinning to the next")
        #expect(CompactFit.steps(style: .numbers, tools: 2, keep: .tools) == [
            S(style: .numbers, figures: .all, count: 2), S(style: .rings, figures: .all, count: 2), S(style: .rings, figures: .all, count: 1),
        ], "digits alone have no outer rung")
        #expect(CompactFit.steps(style: .numbers, tools: 2, keep: .numbers) == [
            S(style: .numbers, figures: .all, count: 2), S(style: .numbers, figures: .all, count: 1),
            S(style: .rings, figures: .all, count: 2), S(style: .rings, figures: .all, count: 1),
        ])
        #expect(CompactFit.steps(style: .rings, tools: 2, keep: .numbers) == [
            S(style: .rings, figures: .all, count: 2), S(style: .rings, figures: .all, count: 1),
        ], "plain rings have nothing to thin, so both orders are the same ladder")
        #expect(CompactFit.steps(style: .rings, tools: 0, keep: .tools) == [])
    }

    /// The complaint this rung answers: a squeeze used to throw away every number while keeping every tool. Now
    /// the second figure goes first, and the session figure — the one the outer ring is for — is the last to go,
    /// and it goes before any tool does.
    @Test func aSqueezeThinsTheFiguresBeforeItGivesUpTheRings() {
        // 110 pt a side: two full readouts want 132, two with their outer figure alone want 102.
        #expect(fit(menus: 538, statusItems: 974, style: .ringsAndNumbers)
                == CompactFit(side: .split, style: .ringsAndNumbers, figures: .outer, toolCount: 4, dropped: 0, splitLeading: 2))
        // 100 pt a side: the outer figures want 102 split and 192 on one side, so the rings stand alone at 72 —
        // and still with every tool.
        #expect(fit(menus: 548, statusItems: 964, style: .ringsAndNumbers)
                == CompactFit(side: .split, style: .rings, toolCount: 4, dropped: 0, splitLeading: 2))
    }

    /// The outer figure is a rung of the rings-with-numbers style alone: digits without a ring go straight to
    /// rings, and a fit at plain rings never claims to have thinned anything.
    @Test func theOuterFigureNeedsARingToSitBeside() {
        let digits = fit(menus: 538, statusItems: 974, style: .numbers)
        #expect(digits.style == .rings)
        #expect(digits.figures == .all)
        for menus in Self.edges {
            for statusItems in Self.edges {
                for style in CompactStyle.allCases {
                    for keep in CompactKeep.allCases {
                        for tools in 1 ... 5 {
                            let fit = fit(menus: menus, statusItems: statusItems, tools: tools, style: style, keep: keep)
                            #expect(fit.style != .rings || fit.figures == .all, "bare rings have no figure to have thinned")
                            #expect(fit.figures != .outer || fit.style == .ringsAndNumbers, "an outer figure needs a ring beside it")
                        }
                    }
                }
            }
        }
    }

    @Test func keepTheNumbersLeavesAnAssistantOutBeforeItThinsAFigure() {
        // 110 pt a side. Three tools split one and two want 72 and 146; two split one and one want 72 and 86, the
        // second carrying the "+2" — so two assistants go, and the two that stay keep both their figures.
        #expect(fit(menus: 538, statusItems: 974, style: .ringsAndNumbers, keep: .numbers)
                == CompactFit(side: .split, style: .ringsAndNumbers, figures: .all, toolCount: 2, dropped: 2, splitLeading: 1))
    }

    @Test func keepTheNumbersThinsOnlyOnceASingleReadoutNoLongerFits() {
        // 75 pt a side. One full readout with its "+3" wants 86, which fits nowhere, so the figures are thinned:
        // two outer figures split want 57 and 71.
        #expect(fit(menus: 573, statusItems: 939, style: .ringsAndNumbers, keep: .numbers)
                == CompactFit(side: .split, style: .ringsAndNumbers, figures: .outer, toolCount: 2, dropped: 2, splitLeading: 1))
        // Keeping the tools instead: four rings at 72 a side, and no figure at all.
        #expect(fit(menus: 573, statusItems: 939, style: .ringsAndNumbers, keep: .tools)
                == CompactFit(side: .split, style: .rings, toolCount: 4, dropped: 0, splitLeading: 2))
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
                    for keep in CompactKeep.allCases {
                        let fit = fit(menus: menus, statusItems: statusItems, style: style, keep: keep)
                        #expect(fit.side != .auto)
                        #expect(fit.toolCount >= 1)
                        #expect(fit.dropped >= 0)
                        switch keep {
                        case .tools:
                            // Figures are given up before tools are, never the other way round.
                            #expect(fit.dropped == 0 || fit.style == .rings)
                        case .numbers:
                            // A figure is thinned only at the chosen style; nothing thinner is invented on the way down.
                            #expect(fit.figures == .all || fit.style == style)
                        }
                    }
                }
            }
        }
    }

    /// The closing guarantee of `resolve`: nothing chosen from the ladder overlaps a menu bar item. The one
    /// answer allowed to is the fallback — a single ring on the roomier side — and only when even that does not
    /// hold, because there is no smaller strip to answer with.
    @Test func neverReturnsAFitThatOverlapsUnlessNothingFits() {
        for menus in Self.edges {
            for statusItems in Self.edges {
                for style in CompactStyle.allCases {
                    for keep in CompactKeep.allCases {
                        for tools in 1 ... 5 {
                            let fit = fit(menus: menus, statusItems: statusItems, tools: tools, style: style, keep: keep)
                            let leadingRoom = menus.map { Self.notch.minX - CompactFit.clearance - $0 } ?? .greatestFiniteMagnitude
                            let trailingRoom = statusItems.map { $0 - CompactFit.clearance - Self.notch.maxX } ?? .greatestFiniteMagnitude
                            let halves = fit.halves(visible: tools)
                            let holds = (halves.leading.isEmpty || Self.width(halves.leading) <= leadingRoom)
                                && (halves.trailing.isEmpty || Self.width(halves.trailing) <= trailingRoom)
                            let fallback = fit.toolCount == 1 && fit.style == .rings && fit.side != .split
                            #expect(holds || fallback,
                                    "a fit chosen from the ladder never overlaps (menus \(String(describing: menus)), status items \(String(describing: statusItems)), \(tools) tools, \(style.rawValue), keep \(keep.rawValue))")
                        }
                    }
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
        for menus in Self.edges {
            for statusItems in Self.edges {
                for tools in 1 ... 5 {
                    for style in CompactStyle.allCases {
                        for keep in CompactKeep.allCases {
                            let fit = fit(menus: menus, statusItems: statusItems, tools: tools, style: style, keep: keep)
                            guard let leading = fit.splitLeading else { continue }
                            #expect(fit.side == .split, "only a strip drawn both sides of the notch records how it was divided")
                            #expect(leading == CompactFit.splitLeadingCount(of: fit.toolCount),
                                    "a measured gap decides how much of the strip is drawn, never which side a readout is drawn on")
                        }
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
                                     style: .rings, keep: .tools) { asked.append($0); return width($0) }
        #expect(fit == CompactFit(side: .split, style: .rings, toolCount: 3, dropped: 0, splitLeading: 1))
        #expect(asked.contains(CompactFit.Run(style: .rings, readouts: 0 ..< 1, overflow: 0)),
                "the half left of the notch draws the first readout and no count of what was left out")
        #expect(asked.contains(CompactFit.Run(style: .rings, readouts: 1 ..< 3, overflow: 0)),
                "the half right of the notch draws the last two readouts, which are not the first two")

        // The outer-figure rung is measured as the run it draws, figures and all: the probe re-roots the strip
        // view with this run, so what is asked here is what is drawn.
        asked = []
        let thinned = CompactFit.resolve(notch: Self.notch, menusEndX: 538, statusItemsStartX: 974, tools: 4,
                                         style: .ringsAndNumbers, keep: .tools) { asked.append($0); return Self.width($0) }
        #expect(thinned.figures == .outer)
        #expect(asked.contains(CompactFit.Run(style: .ringsAndNumbers, figures: .outer, readouts: 0 ..< 2, overflow: 0)))
        #expect(asked.contains(CompactFit.Run(style: .ringsAndNumbers, figures: .outer, readouts: 2 ..< 4, overflow: 0)))
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
        // Both halves carry the fit's figures, so neither side is measured or drawn fuller than the other.
        let outer = CompactFit(side: .split, style: .ringsAndNumbers, figures: .outer, toolCount: 2, dropped: 1, splitLeading: 1).halves(visible: 3)
        #expect(outer.leading == CompactFit.Run(style: .ringsAndNumbers, figures: .outer, readouts: 0 ..< 1, overflow: 0))
        #expect(outer.trailing == CompactFit.Run(style: .ringsAndNumbers, figures: .outer, readouts: 1 ..< 2, overflow: 1))
    }
}
