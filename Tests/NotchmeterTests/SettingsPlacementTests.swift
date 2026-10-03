import AppKit
import SwiftUI
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

/// The sidebar's icons stand on the sidebar itself since 0.9.12, with no tile behind them, so each assistant's icon
/// is a graphical object owing WCAG 1.4.11's 3:1 against the sidebar. The numbers are measured in the appearance the
/// window is drawn in — the app applies its own Appearance preference to the window — rather than in whichever one
/// the test machine happens to be set to, against `SettingsPane.sidebar`.
@MainActor
@Suite struct SettingsSidebarTiles {
    static let ground: [NSAppearance.Name: NSColor] = [.aqua: NSColor(SettingsPane.sidebar.light.color), .darkAqua: NSColor(SettingsPane.sidebar.dark.color)]

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

    /// `ToolID.color` and the icon colours are adaptive, a fresh provider on every read, so two reads are never equal
    /// as `Color` values: they are compared as the sRGB values they resolve to under an appearance instead.
    static func resolved(_ colour: Color, under name: NSAppearance.Name) throws -> String {
        let appearance = try #require(NSAppearance(named: name))
        var out: NSColor?
        appearance.performAsCurrentDrawingAppearance { out = NSColor(colour).usingColorSpace(.sRGB) }
        let c = try #require(out)
        return String(format: "%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }

    /// A symbol name macOS does not know is not an error anywhere: `Image(systemName:)` draws nothing and the row
    /// goes out with an empty space where its icon was. Only a test notices.
    @Test func everyPaneNamesASymbolThisMacCanDraw() {
        for pane in SettingsPane.allCases {
            #expect(NSImage(systemSymbolName: pane.symbol, accessibilityDescription: nil) != nil,
                    "\(pane.title) asks for \(pane.symbol), which does not resolve")
        }
    }

    /// Line icons down the app's own panes, so the sidebar reads as one list: a filled glyph among outlines was
    /// the first sidebar's mistake, and the filled set on tiles was the owner's complaint in 0.9.11.
    @Test func theAppPanesWearLineIcons() {
        for pane in SettingsPane.app {
            #expect(!pane.symbol.hasSuffix(".fill"), "\(pane.title) wears \(pane.symbol), which is filled")
        }
    }

    /// The app's own panes are grey, so the only colour in the list is the assistants'.
    @Test func theAppPanesAreTheSystemsSecondaryGrey() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let grey = try Self.resolved(Color(nsColor: .secondaryLabelColor), under: name)
            for pane in SettingsPane.app {
                #expect(try Self.resolved(pane.iconColor, under: name) == grey, "\(pane.title) in \(name.rawValue)")
            }
        }
    }

    /// An assistant's page wears its own card's symbol in the colour its rings wear: on the notch's black under
    /// Dark, and in their deep tone on Paper under Light, so the sidebar and the notch name it the same way. Where
    /// that colour falls short on the sidebar it is moved in lightness alone, so it is still recognisably the same.
    @Test func anAssistantsPageWearsItsCardsSymbolInItsRingColour() throws {
        var moved: [String] = []
        for tool in ToolID.allCases {
            let pane = SettingsPane.agent(tool)
            let ink = PanelInk.tool(tool)
            #expect(pane.symbol == tool.symbolName)
            #expect(pane.title == tool.productName)
            for (name, ring) in [(NSAppearance.Name.aqua, ink.onPaper), (.darkAqua, ink.onBlack)] {
                let icon = try Self.resolved(pane.iconColor, under: name)
                guard icon != ring.description.dropFirst() else { continue }
                moved.append("\(tool) \(name.rawValue)")
                var drawn: NSColor?
                try #require(NSAppearance(named: name)).performAsCurrentDrawingAppearance { drawn = NSColor(pane.iconColor) }
                #expect(Self.contrast(try #require(drawn), NSColor(ring.color)) < 1.5, "\(tool)'s icon in \(name.rawValue) is no longer its ring colour")
            }
        }
        #expect(moved == ["opencode NSAppearanceNameDarkAqua"], "the icons that leave their ring colour: \(moved)")
    }

    /// Every assistant's icon against the sidebar in both appearances.
    @Test func everyAssistantsIconClearsThreeToOneOnTheSidebar() throws {
        for (name, ground) in Self.ground {
            let appearance = try #require(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                for tool in ToolID.allCases {
                    let ratio = Self.contrast(NSColor(SettingsPane.agent(tool).iconColor), ground)
                    #expect(ratio >= 3, "\(tool) is \(ratio) against the sidebar in \(name.rawValue)")
                }
            }
        }
    }

    /// The reason Light takes the deep tone rather than the ring colour on the notch: those are light tints chosen
    /// for the panel's black, and the lightest of them fades on a light sidebar.
    @Test func theNotchsOwnColoursWouldFadeOnALightSidebar() throws {
        let light = try #require(Self.ground[.aqua])
        let ratios = ToolID.allCases.map { Self.contrast(NSColor(PanelInk.tool($0).onBlack.color), light) }
        #expect(ratios.contains { $0 < 3 }, "every ring colour now clears a light sidebar: \(ratios)")
    }

    /// No chrome pane borrows an assistant's mark: the Assistants row once wore the terminal, Gemini CLI's own
    /// symbol, one row above Gemini's page.
    @Test func noAppPaneWearsAnAssistantsSymbol() {
        let marks = Set(ToolID.allCases.map { $0.symbolName.replacingOccurrences(of: ".fill", with: "") })
        for pane in SettingsPane.app {
            #expect(!marks.contains(pane.symbol), "\(pane.title) wears \(pane.symbol), an assistant's mark")
        }
    }

    /// Every disclosure in Settings is drawn as a settings row (SettingsDisclosureStyle) rather than with the system's
    /// 9 pt triangle in the leading margin, which read as a stray mark beside its title. Each disclosure is checked on
    /// its own, however it is written (with `isExpanded:`, a title string or a trailing closure): the text from it to
    /// the next one has to carry exactly one style modifier, so an unstyled disclosure cannot hide behind a
    /// duplicated modifier elsewhere, as it could while the test compared totals.
    @Test func everyDisclosureInSettingsIsDrawnAsASettingsRow() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Notchmeter/SettingsWindow.swift")
        let text = try String(contentsOf: source, encoding: .utf8) as NSString
        // `DisclosureGroup` followed by its arguments or its content, which leaves `DisclosureGroupStyle` and
        // `DisclosureGroupStyleConfiguration` out.
        let opener = try NSRegularExpression(pattern: #"\bDisclosureGroup\s*[({]"#)
        let starts = opener.matches(in: text as String, range: NSRange(location: 0, length: text.length)).map(\.range.location)
        #expect(!starts.isEmpty, "no disclosure found; the scan is looking at the wrong file")
        let modifier = ".disclosureGroupStyle(SettingsDisclosureStyle("
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] : text.length
            let segment = text.substring(with: NSRange(location: start, length: end - start))
            let line = text.substring(to: start).components(separatedBy: "\n").count
            let styled = segment.components(separatedBy: modifier).count - 1
            #expect(styled == 1, "the disclosure at SettingsWindow.swift:\(line) wears SettingsDisclosureStyle \(styled) times")
        }
    }
}
