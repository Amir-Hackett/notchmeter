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
    static func width(_ style: CompactStyle, _ tools: Int) -> CGFloat {
        guard tools > 0 else { return 0 }
        return CGFloat(tools) * (style.showsNumbers ? 60 : 30) + 12
    }

    func fit(menus: CGFloat?, statusItems: CGFloat?, tools: Int = 4, style: CompactStyle = .numbers,
             fallback: CompactSide = .trailing) -> CompactFit {
        CompactFit.resolve(notch: Self.notch, menusEndX: menus, statusItemsStartX: statusItems, tools: tools,
                           style: style, fallback: fallback, width: Self.width)
    }

    @Test func bothEndsClearKeepsBothSidesOfTheNotch() {
        // Menus stop at 200 and the status items start at 1400: 448 pt free left, 536 pt right, against 2 tools
        // (132 pt) a side at numbers.
        let fit = fit(menus: 200, statusItems: 1400)
        #expect(fit == CompactFit(side: .split, style: .numbers, toolCount: 4, dropped: 0))
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
        #expect(fit == CompactFit(side: .split, style: .rings, toolCount: 4, dropped: 0))
    }

    @Test func neitherSideFittingAtRingsDropsTheToolsPutLast() {
        // 50 pt free left, 60 pt right: at rings not even two tools fit on one side, so the two the user put last
        // go, and the "+2" says so.
        let fit = fit(menus: 598, statusItems: 924)
        #expect(fit == CompactFit(side: .split, style: .rings, toolCount: 2, dropped: 2))
    }

    @Test func withNoRoomAtAllItShowsTheSmallestStripThereIs() {
        // Both ends right up against the notch: nothing fits, so one tool with rings on the roomier side.
        let fit = fit(menus: 700, statusItems: 800)
        #expect(fit.style == .rings)
        #expect(fit.toolCount == 1)
        #expect(fit.dropped == 3)
        #expect(fit.side != .split)
    }

    @Test func nothingMeasuredKeepsTheSideChosenBeforeWithEveryTool() {
        for fallback in [CompactSide.trailing, .leading, .split] {
            let fit = fit(menus: nil, statusItems: nil, fallback: fallback)
            #expect(fit == CompactFit.whole(side: fallback, style: .numbers))
            #expect(fit.dropped == 0)
        }
        // A fallback that is itself Auto cannot be answered with Auto.
        #expect(fit(menus: nil, statusItems: nil, fallback: .auto).side == .split)
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
                    for fallback in CompactSide.allCases {
                        let fit = fit(menus: menus, statusItems: statusItems, style: style, fallback: fallback)
                        #expect(fit.side != .auto)
                        #expect(fit.toolCount >= 1)
                        #expect(fit.dropped >= 0)
                        // Numbers are given up before tools are, never the other way round.
                        #expect(fit.dropped == 0 || fit.style == .rings)
                    }
                }
            }
        }
    }

    @Test func noReadoutsMeansNothingToFit() {
        let fit = fit(menus: 1400, statusItems: 200, tools: 0)
        #expect(fit == CompactFit.whole(side: .trailing, style: .numbers))
    }

    @MainActor @Test func autoIsNotTheDefaultAndRemembersTheSideChosenBeforeIt() {
        let suite = "NotchmeterTests.CompactSide.auto"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        #expect(prefs.compactSide == .split)
        #expect(prefs.resolvedCompactSide == .split)
        prefs.compactSide = .leading
        prefs.compactSide = .auto
        #expect(prefs.compactSideFallback == .leading)
        #expect(prefs.resolvedCompactSide == .leading)
        // A fixed side keeps every tool, whatever Auto last measured.
        #expect(prefs.compactFit.dropped == 0)
        prefs.autoCompactFit = CompactFit(side: .trailing, style: .rings, toolCount: 2, dropped: 2)
        #expect(prefs.resolvedCompactSide == .trailing)
        #expect(prefs.compactFit.style == .rings)
        prefs.compactSide = .trailing
        #expect(prefs.compactFit == CompactFit.whole(side: .trailing, style: prefs.compactStyle))
        prefs.compactSide = .auto
        // The fallback outlives a relaunch, so Auto degrades to the same side next time.
        let reopened = Preferences(defaults: defaults)
        #expect(reopened.compactSide == .auto)
        #expect(reopened.resolvedCompactSide == .trailing)
        #expect(reopened.compactFit.dropped == 0)
    }
}
