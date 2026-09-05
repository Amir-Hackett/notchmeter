import AppKit
import Testing
@testable import Notchmeter

/// The full-screen rule over window sizes: the whole display, the display below the camera housing while the
/// menu bar is away, Split View, and the shapes that must not count, above all a zoomed window under the menu
/// bar, which on a notched display is exactly the below-the-housing size.
@Suite struct FullScreenRule {
    let notched = FullScreen.Display(size: CGSize(width: 1512, height: 982), safeAreaTop: 37, menuBarShowing: true)
    let notchedBarAway = FullScreen.Display(size: CGSize(width: 1512, height: 982), safeAreaTop: 37, menuBarShowing: false)
    // A 14-inch as `--smoke` reports it: the housing's inset and the menu bar differ by a point.
    let fourteen = FullScreen.Display(size: CGSize(width: 1512, height: 982), safeAreaTop: 32, menuBarShowing: true)
    let fourteenBarAway = FullScreen.Display(size: CGSize(width: 1512, height: 982), safeAreaTop: 32, menuBarShowing: false)
    let plain = FullScreen.Display(size: CGSize(width: 2560, height: 1440), safeAreaTop: 0, menuBarShowing: true)
    let plainBarAway = FullScreen.Display(size: CGSize(width: 2560, height: 1440), safeAreaTop: 0, menuBarShowing: false)

    func window(_ width: CGFloat, _ height: CGFloat, owner: String = "Safari") -> FullScreen.Candidate {
        FullScreen.Candidate(owner: owner, size: CGSize(width: width, height: height))
    }

    @Test func theWholeDisplayCountsEverywhere() {
        #expect(FullScreen.isActive([window(2560, 1440)], on: plain))
        #expect(FullScreen.isActive([window(2560, 1440)], on: plainBarAway))
        #expect(FullScreen.isActive([window(1512, 982)], on: notched))
        #expect(FullScreen.isActive([window(1512, 982)], on: notchedBarAway))
    }

    @Test func belowTheHousingCountsOnlyWhileTheMenuBarIsAway() {
        // A full-screen video on a notched MacBook: macOS lays the window out below the housing and hides the bar.
        #expect(FullScreen.isActive([window(1512, 945)], on: notchedBarAway))
        // The same size under a visible menu bar is a zoomed window with the Dock hidden or on a side: the desktop.
        #expect(!FullScreen.isActive([window(1512, 945)], on: notched))
        // The window macOS lays out is the display less the menu bar's thickness, a point short of less the inset;
        // both count with the bar away, and the zoomed Chrome window `--smoke` saw under the bar does not.
        #expect(FullScreen.isActive([window(1512, 949, owner: "Google Chrome")], on: fourteenBarAway))
        #expect(FullScreen.isActive([window(1512, 950)], on: fourteenBarAway))
        #expect(!FullScreen.isActive([window(1512, 949, owner: "Google Chrome")], on: fourteen))
        // A display without a housing has no such shape: one menu bar short is a zoomed window whatever the bar does.
        #expect(!FullScreen.isActive([window(2560, 1416)], on: plain))
        #expect(!FullScreen.isActive([window(2560, 1416)], on: plainBarAway))
    }

    @Test func splitViewCountsAsFullScreen() {
        #expect(FullScreen.isActive([window(754, 945, owner: "Safari"), window(754, 945, owner: "Notes")], on: notchedBarAway))
        #expect(FullScreen.isActive([window(1280, 1440), window(1276, 1440)], on: plainBarAway))
        // Two half-width windows on the desktop with the menu bar showing are not.
        #expect(!FullScreen.isActive([window(754, 945), window(754, 945)], on: notched))
        // One half-width full-height window alone (a tile beside the desktop) is not.
        #expect(!FullScreen.isActive([window(754, 945)], on: notchedBarAway))
    }

    @Test func anythingSmallerDoesNotCount() {
        #expect(!FullScreen.isActive([window(1511, 982)], on: notchedBarAway))
        #expect(!FullScreen.isActive([window(1512, 900)], on: notchedBarAway))
        #expect(!FullScreen.isActive([window(1512, 945 - 70)], on: notchedBarAway))
        // The slack is a few points, not a Dock's worth.
        #expect(!FullScreen.isActive([window(1512, 982 - 32 - 5)], on: fourteenBarAway))
        #expect(!FullScreen.isActive([], on: notchedBarAway))
    }

    @Test func aFullScreenWindowUnderARevealedBarIsSuspect() {
        // The pointer at the top edge of a full-screen Space brings the bar in; the verdict flips, the suspicion
        // does not, and the watch keeps polling on it.
        #expect(FullScreen.isSuspect([window(1512, 949)], on: fourteen))
        #expect(!FullScreen.isActive([window(1512, 949)], on: fourteen))
        #expect(FullScreen.isSuspect([window(754, 945), window(754, 945)], on: notched))
        // Nothing full-width at that height is nothing to watch, on any display.
        #expect(!FullScreen.isSuspect([window(1512, 900)], on: fourteen))
        #expect(!FullScreen.isSuspect([window(2560, 1416)], on: plain))
        #expect(!FullScreen.isSuspect([], on: fourteen))
    }

    @Test func theLineNamesTheVerdictAndTheWindowsItWeighed() {
        let scan = FullScreen.Scan(
            candidates: [window(1512, 949, owner: "Google Chrome"), window(300, 200, owner: "Finder")],
            display: fourteenBarAway,
            chrome: ["Window Server L24 1512×33 y=0"])
        #expect(FullScreen.describe(scan) == "active=true display=1512×982 safeAreaTop=32 menuBar=away "
            + "suspect=true apps=2[Google Chrome×1, Finder×1] "
            + "windows=[Google Chrome 1512×949] top=[Window Server L24 1512×33 y=0]")
    }

    @MainActor @Test func theRealDisplayReadsWithoutPermissionAndDescribesItself() {
        // The scan itself needs no Screen Recording permission; on a test runner it may see nothing at all.
        let line = FullScreen.describe(on: NSScreen.panelScreen)
        #expect(line.hasPrefix("active="))
        #expect(line.contains("safeAreaTop="))
        #expect(line.contains("menuBar=showing") || line.contains("menuBar=away"))
    }
}
