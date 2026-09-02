import AppKit
import Testing
@testable import Notchmeter

/// Settings opens centred under the notch, its top 60 pt below the safe area, and never below the usable area.
@Suite struct SettingsPlacement {
    let size = NSSize(width: 460, height: 640)

    @Test func centredUnderTheNotchBelowTheClearance() {
        let frame = SettingsWindowController.frame(for: size, screen: NSRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32,
                                                   visible: NSRect(x: 0, y: 0, width: 1512, height: 950))
        #expect(frame.maxY == 982 - 32 - SettingsWindowController.topClearance)
        #expect(frame.midX == 756)
        #expect(frame.size == size)
    }

    @Test func aScreenWithoutANotchMeasuresFromItsTop() {
        let frame = SettingsWindowController.frame(for: size, screen: NSRect(x: -1920, y: 200, width: 1920, height: 1080), safeAreaTop: 0,
                                                   visible: NSRect(x: -1920, y: 200, width: 1920, height: 1055))
        #expect(frame.maxY == 1280 - SettingsWindowController.topClearance)
        #expect(frame.midX == -960)
    }

    @Test func restsOnTheDockRatherThanSinkingBelowIt() {
        let frame = SettingsWindowController.frame(for: size, screen: NSRect(x: 0, y: 0, width: 1280, height: 720), safeAreaTop: 0,
                                                   visible: NSRect(x: 0, y: 80, width: 1280, height: 615))
        #expect(frame.minY == 80)
    }

    /// The readouts draw above every window, so the settings window dodges the strip that shares its column:
    /// under one along the top, over one resting on the Dock, and not at all when they do not overlap.
    @Test func windowDodgesTheReadoutStripWhicheverEdgeItIsOn() {
        let size = NSSize(width: 460, height: 672)
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = NSRect(x: 0, y: 90, width: 1512, height: 862)

        let topStrip = NSRect(x: 645, y: 906, width: 222, height: 40)
        let underTop = SettingsWindowController.frame(for: size, screen: screen, safeAreaTop: 0, visible: visible, readouts: topStrip)
        #expect(underTop.maxY == topStrip.minY - SettingsWindowController.readoutClearance)
        #expect(!underTop.intersects(topStrip))

        let dockStrip = NSRect(x: 645, y: 96, width: 222, height: 40)
        let overDock = SettingsWindowController.frame(for: size, screen: screen, safeAreaTop: 0, visible: visible, readouts: dockStrip)
        #expect(overDock.minY >= dockStrip.maxY + SettingsWindowController.readoutClearance)
        #expect(!overDock.intersects(dockStrip))

        let sideStrip = NSRect(x: 6, y: 418, width: 82, height: 202)
        let ignored = SettingsWindowController.frame(for: size, screen: screen, safeAreaTop: 0, visible: visible, readouts: sideStrip)
        #expect(ignored.maxY == 982 - SettingsWindowController.topClearance)
    }

    /// The panel draws at screen-saver level so it can cover the menu bar, and it collapses on an animation:
    /// the window has to be ordered above it outright rather than waiting for the collapse to finish.
    @Test func windowOrdersOneLevelAboveThePanel() {
        #expect(SettingsWindowController.level(above: .screenSaver).rawValue == NSWindow.Level.screenSaver.rawValue + 1)
        #expect(SettingsWindowController.level(above: .floating) > .floating)
        #expect(SettingsWindowController.level(above: .normal) == .floating)
    }
}
