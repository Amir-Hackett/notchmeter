import AppKit
import SwiftUI
import Testing
@testable import Notchmeter

/// The open panel never outgrows the screen: content is capped at the usable height and scrolls past it.
@Suite struct ExpandedPanelHeight {
    @Test func capKeepsTheNotchAndAMarginClear() {
        #expect(NotchExpandedView.maxHeight(visibleHeight: 859, notchHeight: 32) == 803)
        #expect(NotchExpandedView.maxHeight(visibleHeight: 1055, notchHeight: 25) == 1006)
        #expect(NotchExpandedView.maxHeight(visibleHeight: 40, notchHeight: 32) == 0)
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
