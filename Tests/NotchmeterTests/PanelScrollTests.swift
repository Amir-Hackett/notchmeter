import CoreGraphics
import Foundation
import Testing
@testable import Notchmeter

/// Where the panel opens, as `--smoke` and the oracle read it. The numbers are measurements from the notch layout
/// on a 1512 × 982 screen with a 32 pt notch: the panel resting at its scroll anchor, and the same panel with the
/// offset forced to zero, which is the version that drew the first card under the hardware.
@Suite struct PanelScrollReadings {
    /// The room above the first card's title in the comfortable density: the content's 8 pt and the card's 12.
    let titleInset: CGFloat = 20

    private func reading(offset: CGFloat, contentTop: CGFloat?, notchBottom: CGFloat? = 950,
                         contentHeight: CGFloat = 1372.5, visibleHeight: CGFloat = 885) -> PanelScroll {
        PanelScroll(offset: offset, insetTop: 32, contentHeight: contentHeight, visibleHeight: visibleHeight,
                    contentTopOnScreen: contentTop, titleInset: titleInset, notchBottom: notchBottom)
    }

    /// The title is what has to clear the notch: the card's corner may touch its bottom edge, the title may not
    /// cross it. Resting, the title is 14 pt below the notch; pinned to the top of the content it is 38 pt above.
    @Test func aPanelPinnedToTheTopOfItsContentPutsTheTitleUnderTheNotch() {
        let resting = reading(offset: -26, contentTop: 956)
        #expect(resting.titleTopOnScreen == 936)
        #expect(resting.clearsNotch == true)
        let pinned = reading(offset: 26, contentTop: 1008)
        #expect(pinned.titleTopOnScreen == 988)
        #expect(pinned.clearsNotch == false)
        // A title exactly on the edge is clear; half a point of rounding above it still is.
        #expect(reading(offset: -26, contentTop: 970).clearsNotch == true)
        #expect(reading(offset: -26, contentTop: 971).clearsNotch == false)
    }

    /// Nothing sits over the edge pills, so there is nothing for them to be clear of and no verdict to give.
    @Test func aPanelWithNothingOverItHasNoClearanceToReport() {
        #expect(reading(offset: -26, contentTop: 956, notchBottom: nil).clearsNotch == nil)
        #expect(reading(offset: -26, contentTop: nil).clearsNotch == nil)
    }

    /// Openings land a few points apart, which is the panel settling; a panel that kept where the last look left
    /// it is out by a card at least. Openings measured across runs and layouts: −23.5, −25.5, −26.0, −29.0.
    @Test func openingsMatchEachOtherAndAScrolledPanelDoesNot() {
        let opened = reading(offset: -26, contentTop: 956)
        #expect(opened.isAt(reading(offset: -23.5, contentTop: 958.5)))
        #expect(opened.isAt(reading(offset: -29, contentTop: 953)))
        #expect(opened.isAt(opened))
        // A scroll of 200 pt, and the shortest card on the panel.
        #expect(!opened.isAt(reading(offset: 174, contentTop: 756)))
        #expect(!opened.isAt(reading(offset: 34, contentTop: 896)))
    }

    /// Content taller than the room it is drawn in is what makes the panel scrollable at all; without that there
    /// is no scroll for a reopening to undo, and the self check says so rather than claiming a verdict.
    @Test func onlyContentPastTheVisibleHeightScrolls() {
        #expect(reading(offset: -26, contentTop: 956).overflows)
        #expect(!reading(offset: -26, contentTop: 956, contentHeight: 600, visibleHeight: 885).overflows)
        #expect(!reading(offset: -26, contentTop: 956, contentHeight: 885.4, visibleHeight: 885).overflows)
    }

    /// The oracle's snapshot carries the reading as one object; a layout with nothing over it carries nulls rather
    /// than a missing key, so a tester can tell "no notch here" from "the app said nothing".
    @Test func theSnapshotCarriesEveryFieldOrANull() throws {
        let line = try #require(Oracle.line(event: "snapshot", fields: ["panelScroll": reading(offset: -26, contentTop: 956).fields],
                                            at: Date(), home: ""))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let scroll = try #require(object["panelScroll"] as? [String: Any])
        #expect(scroll["offset"] as? Double == -26)
        #expect(scroll["insetTop"] as? Double == 32)
        #expect(scroll["contentTopOnScreen"] as? Double == 956)
        #expect(scroll["titleTopOnScreen"] as? Double == 936)
        #expect(scroll["notchBottom"] as? Double == 950)
        #expect(scroll["clearsNotch"] as? Bool == true)
        #expect(scroll["scrollable"] as? Bool == true)
        let pill = reading(offset: -26, contentTop: 956, notchBottom: nil).fields
        let pillLine = try #require(Oracle.line(event: "snapshot", fields: ["panelScroll": pill], at: Date(), home: ""))
        let pillObject = try #require(try JSONSerialization.jsonObject(with: Data(pillLine.utf8)) as? [String: Any])
        let pillScroll = try #require(pillObject["panelScroll"] as? [String: Any])
        #expect(pillScroll["notchBottom"] is NSNull)
        #expect(pillScroll["clearsNotch"] is NSNull)
    }
}
