import AppKit
import Testing
@testable import Notchmeter

/// The full-screen rule, over readings taken from a 14-inch MacBook Pro running a full-screen video in Chrome
/// and then the same Chrome window zoomed on the desktop. The two look alike by size alone: both are 1512×949
/// on a 1512×982 display under a menu bar the window list reports as on screen either way. What tells them
/// apart is the company the window keeps and whether the Dock has a window.
@Suite struct FullScreenRule {
    /// A full-screen Space on the 14-inch: no Dock window, and the menu bar's window on screen all the same.
    let space = FullScreen.Display(size: CGSize(width: 1512, height: 982), safeAreaTop: 32,
                                   dockOnScreen: false, menuBarShowing: true)
    /// The desktop on the same Mac.
    let desktop = FullScreen.Display(size: CGSize(width: 1512, height: 982), safeAreaTop: 32,
                                     dockOnScreen: true, menuBarShowing: true)
    /// An external display, no camera housing.
    let plainSpace = FullScreen.Display(size: CGSize(width: 2560, height: 1440), safeAreaTop: 0,
                                        dockOnScreen: false, menuBarShowing: true)
    let plainDesktop = FullScreen.Display(size: CGSize(width: 2560, height: 1440), safeAreaTop: 0,
                                          dockOnScreen: true, menuBarShowing: true)

    func window(_ width: CGFloat, _ height: CGFloat, owner: String = "Safari") -> FullScreen.Candidate {
        FullScreen.Candidate(owner: owner, size: CGSize(width: width, height: height))
    }

    /// The reading the bug was found on: three Chrome windows, one of them the video, and nothing else.
    var theVideo: [FullScreen.Candidate] {
        [window(1512, 949, owner: "Google Chrome"), window(560, 320, owner: "Google Chrome"),
         window(1, 1, owner: "Google Chrome")]
    }

    /// The same Mac's desktop a moment later: the Chrome window smaller, and seven other apps still on screen.
    var theDesktop: [FullScreen.Candidate] {
        [window(1424, 822, owner: "Google Chrome"), window(990, 753, owner: "Claude"),
         window(937, 650, owner: "Finder"), window(1125, 750, owner: "Notes"),
         window(1175, 730, owner: "TV"), window(800, 500, owner: "iTerm2"),
         window(600, 400, owner: "System Settings"), window(1, 1, owner: "MobileDeviceUpdater")]
    }

    @Test func theVideoOnTheNotchedMacCounts() {
        #expect(FullScreen.isActive(theVideo, on: space))
    }

    @Test func theSameWindowOnTheDesktopDoesNot() {
        // Zoomed to the same height with the Dock hidden, the window is indistinguishable by size; the Dock's
        // own window is what says this is a desktop.
        #expect(!FullScreen.isActive(theVideo, on: desktop))
        #expect(!FullScreen.isActive(theDesktop, on: desktop))
        // Even with no Dock window, a covering window that shares the screen with other apps is not full-screen.
        #expect(!FullScreen.isActive(theDesktop + [window(1512, 949, owner: "Google Chrome")], on: space))
    }

    @Test func aWindowTheSizeOfTheWholeDisplayCounts() {
        // A game that draws into the housing's band, and every full-screen window on a display without one.
        #expect(FullScreen.isActive([window(1512, 982)], on: space))
        #expect(FullScreen.isActive([window(2560, 1440)], on: plainSpace))
        #expect(!FullScreen.isActive([window(2560, 1440)], on: plainDesktop))
    }

    @Test func aDisplayWithoutAHousingHasNoBandToSubtract() {
        // One menu bar short of the display is a zoomed window there, whatever else is on screen.
        #expect(!FullScreen.isActive([window(2560, 1416)], on: plainSpace))
    }

    @Test func splitViewCountsAndOnlyForItsTwoApps() {
        let pair = [window(754, 949, owner: "Safari"), window(754, 949, owner: "Notes")]
        #expect(FullScreen.isActive(pair, on: space))
        #expect(!FullScreen.isActive(pair, on: desktop))
        #expect(!FullScreen.isActive(pair + [window(300, 200, owner: "Finder")], on: space))
        // One half-width window alone is a tile beside the desktop, not a Space of its own.
        #expect(!FullScreen.isActive([window(754, 949, owner: "Safari")], on: space))
    }

    @Test func anythingShorterDoesNotCount() {
        #expect(!FullScreen.isActive([window(1512, 945 - 70)], on: space))
        #expect(!FullScreen.isActive([window(1512, 982 - 32 - 5)], on: space))
        #expect(!FullScreen.isActive([window(1511, 982)], on: space))
        #expect(!FullScreen.isActive([], on: space))
    }

    @Test func aCoveringWindowIsWorthWatchingWhereverItIs() {
        // Suspicion keeps the watch polling across a Space change, when the rest moves one window at a time.
        #expect(FullScreen.isSuspect(theVideo, on: desktop))
        #expect(FullScreen.isSuspect(theVideo, on: space))
        #expect(!FullScreen.isSuspect(theDesktop, on: desktop))
        #expect(!FullScreen.isSuspect([], on: space))
    }

    @Test func theLineNamesTheVerdictAndWhatItWasReadFrom() {
        let reading = FullScreen.Scan(candidates: [window(1512, 949, owner: "Google Chrome")], display: space,
                                      chrome: ["Window Server L24 1512×33 y=0"])
        #expect(FullScreen.describe(reading) == "active=true over=Google Chrome display=1512×982 safeAreaTop=32 dock=away "
            + "menuBar=showing suspect=true apps=1[Google Chrome×1] "
            + "windows=[Google Chrome 1512×949] top=[Window Server L24 1512×33 y=0]")
    }

    @MainActor @Test func theRealDisplayReadsWithoutPermissionAndDescribesItself() {
        // The scan itself needs no Screen Recording permission; on a test runner it may see nothing at all.
        let line = FullScreen.describe(on: NSScreen.panelScreen)
        #expect(line.hasPrefix("active="))
        #expect(line.contains("safeAreaTop="))
        #expect(line.contains("dock=on screen") || line.contains("dock=away"))
    }
}

/// Who wins when a full-screen app is up: the preference, an exception for that app, and the shortcut, which is
/// the only one of the three that can tell a call from a film when both are the same browser.
@Suite struct FullScreenVisibility {
    func preferences(_ name: String) -> (Preferences, UserDefaults, String) {
        let suite = "NotchmeterTests.FullScreen\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (Preferences(defaults: defaults), defaults, suite)
    }

    @MainActor @Test func offByDefaultAndOnForAnythingListed() {
        let (prefs, defaults, suite) = preferences("Exceptions")
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!prefs.showOverFullScreenApps)
        #expect(!prefs.showsOverFullScreen(["Google Chrome"]))
        prefs.fullScreenExceptions = ["zoom.us"]
        #expect(prefs.showsOverFullScreen(["zoom.us"]))
        #expect(!prefs.showsOverFullScreen(["Google Chrome"]))
        // Split View: one of the two being an exception is enough, since it is on screen either way.
        #expect(prefs.showsOverFullScreen(["Google Chrome", "zoom.us"]))
        // The preference still covers everything when it is on.
        prefs.showOverFullScreenApps = true
        #expect(prefs.showsOverFullScreen(["Google Chrome"]))
    }

    @MainActor @Test func theShortcutWinsEitherWayAndIsNotWrittenDown() {
        let (prefs, defaults, suite) = preferences("Shortcut")
        defer { defaults.removePersistentDomain(forName: suite) }
        prefs.showOverFullScreenNow = true
        #expect(prefs.showsOverFullScreen(["Google Chrome"]))
        // And back the other way, over both the preference and the list.
        prefs.showOverFullScreenApps = true
        prefs.fullScreenExceptions = ["zoom.us"]
        prefs.showOverFullScreenNow = false
        #expect(!prefs.showsOverFullScreen(["zoom.us"]))
        // A new launch reads the list and the preference, never the shortcut's answer.
        let reopened = Preferences(defaults: defaults)
        #expect(reopened.fullScreenExceptions == ["zoom.us"])
        #expect(reopened.showOverFullScreenApps)
        #expect(reopened.showOverFullScreenNow == nil)
    }
}
