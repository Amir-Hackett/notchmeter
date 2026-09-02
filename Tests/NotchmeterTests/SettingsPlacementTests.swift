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
}
