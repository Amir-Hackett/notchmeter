import AppKit
import Testing
@testable import Notchmeter

/// The full-screen rule over window sizes: the whole display, the display below the camera housing while the
/// menu bar is away, Split View, and the shapes that must not count, above all a zoomed window under the menu
/// bar, which on a notched display is exactly the below-the-housing size.
@Suite struct FullScreenRule {
    let notched = FullScreen.Display(size: CGSize(width: 1512, height: 982), safeAreaTop: 37, menuBarHeight: 37)
    let notchedBarAway = FullScreen.Display(size: CGSize(width: 1512, height: 982), safeAreaTop: 37, menuBarHeight: 0)
    let plain = FullScreen.Display(size: CGSize(width: 2560, height: 1440), safeAreaTop: 0, menuBarHeight: 24)
    let plainBarAway = FullScreen.Display(size: CGSize(width: 2560, height: 1440), safeAreaTop: 0, menuBarHeight: 0)

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
        #expect(!FullScreen.isActive([], on: notchedBarAway))
    }

    @MainActor @Test func theRealDisplayReadsWithoutPermissionAndDescribesItself() {
        // The scan itself needs no Screen Recording permission; on a test runner it may see nothing at all.
        let line = FullScreen.describe(on: NSScreen.panelScreen)
        #expect(line.hasPrefix("active="))
        #expect(line.contains("safeAreaTop="))
    }
}
