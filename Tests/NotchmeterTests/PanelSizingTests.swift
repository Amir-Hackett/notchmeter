import AppKit
import SwiftUI
import Testing
@testable import Notchmeter

/// The open panel never outgrows the screen: content is capped at the usable height and scrolls past it.
@Suite struct ExpandedPanelHeight {
    /// `visibleFrame` already excludes the menu bar the notch sits in, so only the margin above the Dock comes off.
    @Test func capLeavesAMarginAboveTheDock() {
        #expect(NotchExpandedView.maxHeight(visibleHeight: 859, notchHeight: 32) == 835)
        #expect(NotchExpandedView.maxHeight(visibleHeight: 1055, notchHeight: 25) == 1031)
        #expect(NotchExpandedView.maxHeight(visibleHeight: 10, notchHeight: 32) == 0)
    }

    @MainActor @Test func contentIsItsOwnHeightUntilTheCapAndTheCapPastIt() {
        let defaults = UserDefaults(suiteName: "NotchmeterTests.PanelSizing")!
        let prefs = Preferences(defaults: defaults)
        let store = UsageStore(prefs: prefs, providers: [], cache: ReadingCache(defaults: defaults), defaults: defaults, drainLog: nil)
        let actions = NotchActions()
        let natural = fittingHeight(NotchExpandedView(store: store, prefs: prefs, actions: actions, maxHeight: 10_000))
        #expect(natural > 60)
        #expect(natural < 10_000)
        #expect(fittingHeight(NotchExpandedView(store: store, prefs: prefs, actions: actions, maxHeight: 60)) == 60)
        #expect(fittingHeight(NotchExpandedView(store: store, prefs: prefs, actions: actions, maxHeight: natural + 100)) == natural)
    }

    @MainActor private func fittingHeight(_ view: NotchExpandedView) -> CGFloat {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }
}


/// The meter and both sparklines are pinned left to right, so a right-to-left layout renders them unchanged.
@Suite struct RightToLeftMeters {
    @MainActor @Test func meterRowRendersTheSameUnderRightToLeft() {
        let defaults = UserDefaults(suiteName: "NotchmeterTests.RTL")!
        defaults.removePersistentDomain(forName: "NotchmeterTests.RTL")
        defer { defaults.removePersistentDomain(forName: "NotchmeterTests.RTL") }
        let prefs = Preferences(defaults: defaults)
        let now = Date()
        let window = LimitWindow(id: "five_hour", label: "Session", usedFraction: 0.3, resetsAt: now.addingTimeInterval(3 * 3600), periodDuration: Period.fiveHours)
        let row = MeterRow(toolName: "Claude", window: window, color: .orange, prefs: prefs)
        let ltr = NSHostingView(rootView: row.frame(width: 320).environment(\.layoutDirection, .leftToRight))
        let rtl = NSHostingView(rootView: row.frame(width: 320).environment(\.layoutDirection, .rightToLeft))
        ltr.layoutSubtreeIfNeeded()
        rtl.layoutSubtreeIfNeeded()
        #expect(ltr.fittingSize.height > 20)
        #expect(ltr.fittingSize == rtl.fittingSize)
        let tick = Meter.tickOffset(width: 320, tick: 0.4)
        #expect(tick == 320 * 0.4 - 1)
        let sparkline = NSHostingView(rootView: Sparkline(series: [DailySpend(day: now, cost: 1, tokens: 1)], color: .orange).frame(width: 160, height: 22).environment(\.layoutDirection, .rightToLeft))
        sparkline.layoutSubtreeIfNeeded()
        #expect(sparkline.fittingSize.width == 160)
    }
}
