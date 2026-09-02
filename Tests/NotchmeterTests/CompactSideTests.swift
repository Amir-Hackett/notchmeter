import CoreGraphics
import Foundation
import Testing
@testable import Notchmeter

/// Auto's rule, without a menu bar: menu titles that end clear of the leading readouts leave both sides in use,
/// titles that would reach into them push everything right of the notch, and nothing measured (Accessibility not
/// granted, or revoked) keeps the fixed side chosen before Auto.
@Suite struct AutoCompactSide {
    /// A 14-inch notch: the screen 1512 wide, the notch 200 wide across the middle of a 37 pt menu bar.
    static let notch = CGRect(x: 656, y: 945, width: 200, height: 37)
    static let leadingWidth: CGFloat = 90

    func resolve(_ menuEndX: CGFloat?, fallback: CompactSide = .trailing) -> CompactSide {
        CompactSide.resolve(menuEndX: menuEndX, leadingWidth: Self.leadingWidth, notch: Self.notch, fallback: fallback)
    }

    @Test func menusEndingClearOfTheReadoutsKeepBothSides() {
        #expect(resolve(120) == .split)
        // Right up to the clearance and no further.
        #expect(resolve(Self.notch.minX - Self.leadingWidth - CompactSide.autoClearance) == .split)
    }

    @Test func menusReachingTheReadoutsPushThemRight() {
        #expect(resolve(Self.notch.minX - Self.leadingWidth - CompactSide.autoClearance + 1) == .trailing)
        // A menu-heavy app whose titles run past the notch's left edge.
        #expect(resolve(640) == .trailing)
    }

    @Test func withoutPermissionItKeepsTheSideChosenBefore() {
        #expect(resolve(nil, fallback: .trailing) == .trailing)
        #expect(resolve(nil, fallback: .leading) == .leading)
        #expect(resolve(nil, fallback: .split) == .split)
        // A fallback that is itself Auto cannot be answered with Auto.
        #expect(resolve(nil, fallback: .auto) == .split)
    }

    @Test func neverAnswersAuto() {
        for menuEndX in [nil, 0, 400, 700, 1400] as [CGFloat?] {
            for fallback in CompactSide.allCases {
                #expect(resolve(menuEndX, fallback: fallback) != .auto)
            }
        }
    }

    @Test func noLeadingReadoutsMeansNothingToClear() {
        #expect(CompactSide.resolve(menuEndX: 1400, leadingWidth: 0, notch: Self.notch, fallback: .trailing) == .split)
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
        prefs.autoCompactSide = .trailing
        #expect(prefs.resolvedCompactSide == .trailing)
        // The fallback outlives a relaunch, so Auto degrades to the same side next time.
        let reopened = Preferences(defaults: defaults)
        #expect(reopened.compactSide == .auto)
        #expect(reopened.resolvedCompactSide == .leading)
    }
}
