import AppKit
import Testing
@testable import Notchmeter

/// Settings opens centred under the notch, its top 60 pt below the safe area, and never below the usable area.
@Suite struct SettingsPlacement {
    let size = SettingsWindowController.contentSize

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

        // The side notch, flush against the glass and grown a point past it for the pointer: the settings
        // window is centred and never shares its column, whichever side it is on.
        let sideStrip = NSRect(x: -1, y: 402, width: 83, height: 234)
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

/// The sidebar's tiles carry an 11 pt white glyph, which makes each one a graphical object owing WCAG 1.4.11's
/// 3:1. The system colours do not earn it by being system colours: `.gray` is 2.87:1 against white in the dark
/// appearance, and Increase Contrast hands back the identical sRGB values, so a tile that fails fails with every
/// system remedy on. The numbers are measured in the appearance the window is actually drawn in — the app applies
/// its own Appearance preference to the window — rather than in whichever one the test machine happens to be set
/// to.
@MainActor
@Suite struct SettingsSidebarTiles {
    /// WCAG's relative luminance, on the sRGB values the appearance resolves the colour to.
    static func luminance(_ colour: NSColor) -> Double {
        guard let srgb = colour.usingColorSpace(.sRGB) else { return 0 }
        func channel(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(srgb.redComponent) + 0.7152 * channel(srgb.greenComponent) + 0.0722 * channel(srgb.blueComponent)
    }

    static func contrast(_ colour: NSColor, _ other: NSColor) -> Double {
        let (a, b) = (luminance(colour), luminance(other))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// A symbol name macOS does not know is not an error anywhere: `Image(systemName:)` draws nothing, the tile
    /// keeps its colour, and the row goes out with an empty square. Only a test notices.
    @Test func everyPaneNamesASymbolThisMacCanDraw() {
        for pane in SettingsPane.allCases {
            #expect(NSImage(systemSymbolName: pane.symbol, accessibilityDescription: nil) != nil,
                    "\(pane.title) asks for \(pane.symbol), which does not resolve")
        }
    }

    /// One fill weight across the six, so the sidebar reads as one list. Outline and solid glyphs side by side
    /// were the first pass's mistake; this pins the fix rather than trusting the next editor to see it.
    @Test func theSixGlyphsShareOneFillWeight() {
        for pane in SettingsPane.allCases {
            #expect(pane.symbol.hasSuffix(".fill"), "\(pane.title) wears \(pane.symbol), which is not a fill")
        }
    }

    @Test func everyTileClearsThreeToOneAgainstItsWhiteGlyphInBothAppearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                for pane in SettingsPane.allCases {
                    let ratio = Self.contrast(NSColor(pane.tint), .white)
                    #expect(ratio >= 3, "\(pane.title) is \(ratio) against its glyph in \(name.rawValue)")
                }
            }
        }
    }

    /// General is the pane the window opens on, so its tile is the first one a low-vision reader meets. It wears a
    /// fixed sRGB grey rather than `.gray`, which is the worst tile in the sidebar at 2.87:1 in the dark.
    @Test func theDefaultPanesTileIsTheOneSystemGreyCouldNotBe() throws {
        let dark = try #require(NSAppearance(named: .darkAqua))
        dark.performAsCurrentDrawingAppearance {
            #expect(Self.contrast(NSColor(SettingsPane.general.tint), .white) > 6)
            #expect(Self.contrast(NSColor(.gray), .white) < 3, "system grey against white in the dark appearance")
        }
    }
}
