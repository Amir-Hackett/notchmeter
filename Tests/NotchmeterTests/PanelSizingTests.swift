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

    /// The self check reads the panel as it is drawn. Content taller than the cap scrolls, which is what the panel's
    /// scroll view is for; only a panel drawn larger than the room it has is a fault.
    @Test func contentPastTheCapScrollsAndOnlyAnOversizedPanelIsAFault() {
        #expect(NotchExpandedView.Fit.of(drawn: 400, natural: 400, room: 982, cap: 835) == .fits)
        #expect(NotchExpandedView.Fit.of(drawn: 835, natural: 1114, room: 982, cap: 835) == .scrolls)
        #expect(NotchExpandedView.Fit.of(drawn: 835.4, natural: 1114, room: 982, cap: 835) == .scrolls)
        #expect(NotchExpandedView.Fit.of(drawn: 900, natural: 1114, room: 982, cap: 835) == .clipped)
        #expect(NotchExpandedView.Fit.of(drawn: 780, natural: 780, room: 700, cap: 835) == .clipped)
        #expect(NotchExpandedView.Fit.of(drawn: 835, natural: 1114, room: 982, cap: 835).holds)
        #expect(!NotchExpandedView.Fit.of(drawn: 900, natural: 1114, room: 982, cap: 835).holds)
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
        let expectedTick: CGFloat = 320 * 0.4 - 1
        #expect(tick == expectedTick)
        let sparkline = NSHostingView(rootView: Sparkline(series: [DailySpend(day: now, cost: 1, tokens: 1)], color: .orange).frame(width: 160, height: 22).environment(\.layoutDirection, .rightToLeft))
        sparkline.layoutSubtreeIfNeeded()
        #expect(sparkline.fittingSize.width == 160)
    }
}

/// The open panel is one width. Every card is offered the panel's text column and has to come out exactly
/// that wide: narrower and it no longer lines up with the cards above and below it, wider and it is drawn past
/// the panel's right edge where the notch shape clips it. The card must also not change width as its own
/// content changes, or picking something inside it moves everything under it sideways and picking back moves
/// it all home again.
///
/// The Cost card's range picker is the control that broke both halves. A segmented `Picker` reports the sum of
/// its titles' full widths as its minimum however little it is offered, and that sum moves with the selection,
/// because AppKit squeezes every title except the selected one. So the card sat 29 pt past the panel's right
/// edge on Yesterday, Week, Month, 30d and 90d with "90d" clipped off it, and snapped back inside on Today.
/// SegmentedBar replaces it.
@Suite struct ExpandedPanelWidth {
    init() { Localization.use(language: "en") }

    @MainActor @Test func theCostCardIsTheSameWidthInEveryRangeAndEveryLanguage() {
        let defaults = UserDefaults(suiteName: "NotchmeterTests.PanelWidth")!
        defaults.removePersistentDomain(forName: "NotchmeterTests.PanelWidth")
        defer {
            defaults.removePersistentDomain(forName: "NotchmeterTests.PanelWidth")
            Localization.use(language: "en")
        }
        let prefs = Preferences(defaults: defaults)
        let store = UsageStore(prefs: prefs, providers: [], cache: ReadingCache(defaults: defaults), defaults: defaults, drainLog: nil)
        // Standard is the tight one, so every language is measured there; Wide only has to hold in English to
        // prove the card is not simply pinned to one number.
        for language in Localization.languages {
            Localization.use(language: language)
            for width in language == "en" ? PanelWidth.allCases : [.standard] {
                prefs.panelWidth = width
                let column = width.points - 2 * NotchExpandedView.contentHorizontalPadding
                for range in SpendCard.Range.allCases {
                    let drawn = drawnWidth(SpendCard(store: store, range: range), column: column)
                    // Equal, not merely no wider: a range that draws the card to a different width from the
                    // others is the bug whichever side of the column it lands on.
                    #expect(abs(drawn - column) <= 0.5, "Cost card in \(language)/\(width.rawValue) on \(range.title) drew \(drawn) pt in a \(column) pt column")
                }
            }
        }
    }

    /// The width a card actually takes when it is offered `column`, which is not `fittingSize`: a child that
    /// cannot fit the proposal overflows it, and a `.frame(width:)` around it reports the frame either way.
    @MainActor private func drawnWidth(_ card: some View, column: CGFloat) -> CGFloat {
        let measured = DrawnWidth()
        let content = VStack(alignment: .leading) {
            card.background(GeometryReader { geometry in
                Color.clear.onAppear { measured.width = geometry.size.width }
            })
        }
        .frame(width: column, alignment: .leading)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: column, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(2)
        while measured.width == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return measured.width ?? .infinity
    }
}

/// A box for the width a `GeometryReader` reports back out of a rendered view.
@MainActor private final class DrawnWidth {
    var width: CGFloat?
}
