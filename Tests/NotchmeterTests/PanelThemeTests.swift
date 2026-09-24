import Foundation
import SwiftUI
import Testing
@testable import Notchmeter

/// The panel's theme (PanelTheme.swift): how the choices resolve against the layout and the accessibility settings,
/// how each colour a view hands over is found and moved for the look, and that every pairing on every look reaches
/// the contrast the panel promises — 4.5:1 for words, 3:1 for marks, on the sheet as it looks over a white window.
@Suite struct PanelLookResolution {
    func resolve(theme: PanelTheme = .black, material: PanelMaterial? = nil, accent: PanelAccent = .terracotta, edgeCard: Bool = false,
                 liquidGlass: Bool = false, contrast: Bool = false, reduceTransparency: Bool = false) -> PanelLook {
        PanelLook.resolve(theme: theme, material: material, accent: accent, usageStyle: .bars, hourClock: false, edgeCard: edgeCard,
                          liquidGlass: liquidGlass, increaseContrast: contrast, reduceTransparency: reduceTransparency)
    }

    /// An install that never opens the Theme section is drawn exactly as before, in the notch layout on every OS.
    @Test func nothingChosenIsThePanelAsItWas() {
        #expect(resolve() == .standard)
        #expect(resolve(liquidGlass: true) == .standard)
    }

    /// Until a material is chosen each layout keeps what it drew: the notch's panel solid, the edge card Liquid Glass
    /// from macOS 26 (Glassy, now tinted) and solid before it.
    @Test func anUnchosenMaterialIsWhatTheLayoutDrew() {
        #expect(resolve(edgeCard: false, liquidGlass: true).material == .solid)
        #expect(resolve(edgeCard: true, liquidGlass: true).material == .glassy)
        #expect(resolve(edgeCard: true, liquidGlass: false).material == .solid)
        #expect(resolve(material: .smoked, edgeCard: true, liquidGlass: true).material == .smoked)
        #expect(resolve(material: .glassy).material == .glassy)
    }

    /// Paper is always solid, and so is any panel under Reduce Transparency or Increase Contrast.
    @Test func paperAndTheAccessibilitySettingsAreSolid() {
        #expect(resolve(theme: .paper, material: .glassy).material == .solid)
        #expect(resolve(material: .glassy, reduceTransparency: true).material == .solid)
        let contrast = resolve(material: .smoked, contrast: true)
        #expect(contrast.material == .solid)
        #expect(contrast.contrast)
    }

    @Test func theRestOfTheChoicesCarryThrough() {
        let look = PanelLook.resolve(theme: .paper, material: nil, accent: .lilac, usageStyle: .gauges, hourClock: true, edgeCard: false,
                                     liquidGlass: false, increaseContrast: false, reduceTransparency: false)
        #expect(look.theme == .paper)
        #expect(look.accent == .lilac)
        #expect(look.usageStyle == .gauges)
        #expect(look.hourClock)
        #expect(look.colorScheme == .light)
        #expect(PanelLook.standard.colorScheme == .dark)
    }
}

@Suite struct PanelLookColours {
    /// `Palette` and `ToolID` are built from `PanelInk`, so the colour a view passes is the one the table knows.
    @Test func thePaletteIsTheTable() {
        #expect(Palette.calm == RGB(hex: 0x0072B2).color)
        #expect(Palette.warn == RGB(hex: 0xE69F00).color)
        #expect(Palette.danger == RGB(hex: 0xD55E00).color)
        #expect(Palette.accentContrast == RGB(hex: 0xE8A084).color)
        #expect(ToolID.claude.color == RGB(red: 0.85, green: 0.47, blue: 0.34).color)
        #expect(ToolID.copilot.color == RGB(hex: 0xF0E442).color)
        #expect(ToolID.cursor.ringColor(at: 1) == RGB(hex: 0xF08BD6).color)
        #expect(ToolID.cursor.ringColor(at: 2) == RGB(hex: 0x8FC0FF).color)
        #expect(ToolID.cursor.ringColor(at: 5) == RGB(hex: 0x8FC0FF).color)
    }

    /// Every identity and ring colour and every status colour can be looked up; the accent cannot, since it is
    /// Claude's colour to the digit, and a view that means the accent names it.
    @Test func theRegistryKnowsEveryColourButTheAccent() {
        let known = PanelInk.registry
        let expected = PanelInk.all.count - 2
        #expect(known.count == expected)
        for tool in ToolID.allCases {
            #expect(known[tool.color] == .tool(tool))
            #expect(known[tool.ringColor(at: 1)] == .companion(tool, 1))
            #expect(known[tool.ringColor(at: 2)] == .companion(tool, 2))
        }
        #expect(known[Palette.accent] == .tool(.claude))
        #expect(known[Palette.warn] == .warn)
    }

    /// On the standard look every mark is its own colour, unchanged: the black panel's rings, meters and glyphs
    /// look as they always have.
    @Test func theStandardLookLeavesEveryMarkAlone() {
        let look = PanelLook.standard
        for name in PanelInk.all {
            #expect(look.rgb(name, role: .mark) == name.onBlack, "\(name) moved as a mark")
        }
        #expect(look.colour(Palette.warn) == Palette.warn)
        #expect(look.colour(ToolID.codex.color) == ToolID.codex.color)
        #expect(look.colour(.white) == .white)
        #expect(look.colour(.black) == .black)
        #expect(look.colour(.secondary) == .secondary)
    }

    /// What moves on the standard look is text that never read at 4.5:1: the "needs you" blue and the pine green in
    /// a line of words (4.0:1 on black), and the vermillion on the wash. The warning orange and white do not move.
    @Test func theStandardLookLiftsOnlyTheWordsThatFellShort() {
        let look = PanelLook.standard
        #expect(look.rgb(.warn, role: .text) == PanelInk.warn.onBlack)
        let calm = look.rgb(.calm, role: .text)
        #expect(calm != PanelInk.calm.onBlack)
        #expect(calm.luminance > PanelInk.calm.onBlack.luminance)
        let floor = 4.5
        #expect(calm.contrast(.black) >= floor)
        #expect(look.rgb(.pine, role: .text).contrast(look.box) >= floor)
        #expect(look.rgb(.danger, role: .text).contrast(look.wash) >= floor)
    }

    /// On Paper the ink is near-black, the ground is the sheet's paper, and every colour is darker than its black
    /// panel counterpart.
    @Test func paperInvertsTheInkAndDarkensTheColours() {
        let look = PanelLook(theme: .paper)
        #expect(look.colour(.white) == PanelLook.paperInk.color)
        #expect(look.colour(.black) == PanelLook.paper.color)
        for name in PanelInk.all {
            #expect(look.rgb(name, role: .mark).luminance < name.onBlack.luminance, "\(name) is not darker on Paper")
        }
    }

    /// The accent follows the choice; Claude's own colour does not.
    @Test func theAccentFollowsTheChoiceAndClaudeKeepsItsColour() {
        let teal = PanelLook(accent: .teal)
        #expect(teal.rgb(.accent, role: .mark) == PanelAccent.teal.onBlack)
        #expect(teal.rgb(.accentContrast, role: .mark) == PanelAccent.teal.onBlackContrast)
        #expect(teal.colour(ToolID.claude.color) == ToolID.claude.color)
        #expect(PanelLook(theme: .paper, accent: .lilac).rgb(.accent, role: .mark) == PanelAccent.lilac.onPaper)
    }

    /// A translucent panel is judged over a white window: the sheet is the tint's black over white.
    @Test func aTranslucentSheetIsTheTintOverWhite() {
        let glassy = PanelLook(material: .glassy)
        #expect(glassy.sheet == RGB.black.over(.white, alpha: PanelMaterial.glassy.tint))
        #expect(PanelLook(material: .smoked).sheet == RGB.black.over(.white, alpha: PanelMaterial.smoked.tint))
        #expect(PanelLook.standard.sheet == .black)
        #expect(PanelLook(theme: .paper).sheet == PanelLook.paper)
        // Paper draws its washes at six tenths of the black panel's.
        let scaled = PanelLook(theme: .paper).washOpacity(0.5)
        #expect(abs(scaled - 0.3) < 0.0001)
    }
}

/// Every look, every element: the audit is empty.
@Suite struct ThemeContrastTests {
    static var everyLook: [PanelLook] {
        var looks: [PanelLook] = []
        for theme in PanelTheme.allCases {
            for material in PanelMaterial.allCases {
                for accent in PanelAccent.allCases {
                    for contrast in [false, true] {
                        let look = PanelLook.resolve(theme: theme, material: material, accent: accent, usageStyle: .bars, hourClock: false,
                                                     edgeCard: false, liquidGlass: false, increaseContrast: contrast, reduceTransparency: false)
                        if !looks.contains(look) { looks.append(look) }
                    }
                }
            }
        }
        return looks
    }

    @Test func everyPairingOnEveryLookPasses() {
        let looks = Self.everyLook
        // Black: three materials × three accents × contrast off, plus three accents solid under contrast; Paper: three
        // accents × contrast on and off.
        let expected = 9 + 3 + 6
        #expect(looks.count == expected)
        for look in looks {
            let findings = look.audit()
            #expect(findings.isEmpty, "\(look.summary): \(findings.map(\.description))")
        }
    }

    /// The weakest pairing reported is at least the threshold, which is what `--smoke` and the renders print.
    @Test func theWeakestPairingIsAtTheThreshold() {
        for look in Self.everyLook {
            let weakest = look.weakest
            #expect(weakest.text >= 4.5, "\(look.summary)")
            #expect(weakest.mark >= 3, "\(look.summary)")
        }
    }

    /// The hand-picked Paper colours are already where the rules would put a mark: the audit darkens none of them,
    /// so what was chosen by eye is what is drawn.
    @Test func paperMarksAreDrawnAsChosen() {
        let look = PanelLook(theme: .paper)
        for name in PanelInk.all where name != .accent && name != .accentContrast {
            #expect(look.rgb(name, role: .mark) == name.onPaper, "\(name) was darkened as a mark")
        }
    }

    /// The contrast arithmetic itself, against WCAG's own figures.
    @Test func theArithmeticIsWCAGs() {
        let extremes = RGB.white.contrast(.black)
        #expect(abs(extremes - 21) < 0.001)
        // #767676 is the lightest grey that reads at 4.5:1 on white.
        let grey = RGB(hex: 0x767676).contrast(.white)
        #expect(grey >= 4.5 && grey < 4.6)
        #expect(RGB(hex: 0x777777).contrast(.white) < 4.5)
        let half = RGB.white.over(.black, alpha: 0.5)
        #expect(abs(half.red - 0.5) < 0.0001)
        #expect(RGB(hex: 0xD97857).description == "#D97857")
    }

    /// `readable` leaves a colour that passes alone, and otherwise moves it in lightness alone, the least it must.
    @Test func readableMovesOnlyInLightnessAndOnlyWhenItMust() {
        let orange = RGB(hex: 0xE69F00)
        #expect(orange.readable(against: [.black], target: 4.5, lighter: true) == orange)
        let blue = RGB(hex: 0x0072B2)
        let lifted = blue.readable(against: [.black], target: 4.5, lighter: true)
        #expect(lifted.contrast(.black) >= 4.5)
        #expect(lifted.contrast(.black) < 4.7)
        // Still blue: the channels keep their order.
        #expect(lifted.blue > lifted.green && lifted.green > lifted.red)
        let darkened = orange.readable(against: [PanelLook.paper], target: 4.5, lighter: false)
        #expect(darkened.contrast(PanelLook.paper) >= 4.5)
        #expect(darkened.red > darkened.green && darkened.green >= darkened.blue)
    }
}

/// The two accents beside terracotta, by measurement: readable on the black panel, black text on their pill, and
/// apart from the status colours and each other under colour-blindness simulated (Machado, Oliveira and
/// Fernandes 2009, full severity), in CIELAB ΔE.
@Suite struct PanelAccentChoice {
    static let protan = [[0.152286, 1.052583, -0.204868], [0.114503, 0.786281, 0.099216], [-0.003882, -0.048116, 1.051998]]
    static let deutan = [[0.367322, 0.860646, -0.227968], [0.280085, 0.672501, 0.047413], [-0.011820, 0.042940, 0.968881]]
    static let tritan = [[1.255528, -0.076749, -0.178779], [-0.078411, 0.930809, 0.147602], [0.004733, 0.691367, 0.303900]]

    static func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
    static func encoded(_ value: Double) -> Double {
        let v = max(0, min(1, value))
        return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    static func simulate(_ colour: RGB, _ matrix: [[Double]]) -> RGB {
        let l: [Double] = [linear(colour.red), linear(colour.green), linear(colour.blue)]
        var out: [Double] = []
        for row in matrix {
            var sum: Double = 0
            for index in 0 ..< 3 { sum += row[index] * l[index] }
            out.append(sum)
        }
        return RGB(red: encoded(out[0]), green: encoded(out[1]), blue: encoded(out[2]))
    }

    /// sRGB to CIELAB under D65. Each sum is named before it is used: bare literals in one long expression are what
    /// the type checker's scope budget is set to catch (scripts/test.sh).
    static func lab(_ colour: RGB) -> [Double] {
        let r: Double = linear(colour.red)
        let g: Double = linear(colour.green)
        let b: Double = linear(colour.blue)
        let xr: Double = 0.4124 * r + 0.3576 * g + 0.1805 * b
        let yr: Double = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let zr: Double = 0.0193 * r + 0.1192 * g + 0.9505 * b
        func f(_ t: Double) -> Double {
            let cube: Double = pow(t, 1.0 / 3)
            let slope: Double = 7.787 * t + 16.0 / 116
            return t > 0.008856 ? cube : slope
        }
        let (fx, fy, fz) = (f(xr / 0.95047), f(yr), f(zr / 1.08883))
        let l: Double = 116 * fy - 16
        let a: Double = 500 * (fx - fy)
        let bb: Double = 200 * (fy - fz)
        return [l, a, bb]
    }

    static func distance(_ a: RGB, _ b: RGB) -> Double {
        let (p, q) = (lab(a), lab(b))
        var sum: Double = 0
        for index in 0 ..< 3 {
            let delta: Double = p[index] - q[index]
            sum += delta * delta
        }
        return sum.squareRoot()
    }

    /// The smallest ΔE between two colours as seen with typical vision and under each of the three simulations.
    static func apart(_ a: RGB, _ b: RGB) -> Double {
        var gaps: [Double] = [distance(a, b)]
        for matrix in [protan, deutan, tritan] {
            gaps.append(distance(simulate(a, matrix), simulate(b, matrix)))
        }
        return gaps.min() ?? 0
    }

    @Test func eachNewAccentReadsOnTheBlackPanelAndCarriesBlackText() {
        let box = RGB.white.over(.black, alpha: 0.07)
        for accent in [PanelAccent.teal, .lilac] {
            #expect(accent.onBlack.contrast(box) >= 8.5, "\(accent)")
            #expect(RGB.black.contrast(accent.onBlack) >= 9, "\(accent)")
            #expect(RGB.black.contrast(accent.onBlackContrast) >= 7, "\(accent)")
            #expect(PanelLook.paper.contrast(accent.onPaper) >= 4.5, "\(accent)")
        }
    }

    @Test func eachNewAccentStaysApartFromTheStatusColoursForColourBlindEyes() {
        for accent in [PanelAccent.teal, .lilac] {
            for status in [PanelInk.warn, .danger, .calm] {
                let gap = Self.apart(accent.onBlack, status.onBlack)
                #expect(gap >= 23, "\(accent) is \(gap) from \(status)")
            }
            let fromTerracotta = Self.apart(accent.onBlack, PanelAccent.terracotta.onBlack)
            #expect(fromTerracotta >= 30, "\(accent) is \(fromTerracotta) from terracotta")
        }
        let between = Self.apart(PanelAccent.teal.onBlack, PanelAccent.lilac.onBlack)
        #expect(between >= 30)
        // The reason to offer them: terracotta itself sits close to the warning orange.
        let terracotta = Self.apart(PanelAccent.terracotta.onBlack, PanelInk.warn.onBlack)
        #expect(terracotta < 15)
    }
}

/// The hour clock (HourClock): drawn for a window shorter than a day, from its reset and its period, full for one
/// that reports nothing used and no reset, and never guessed.
@Suite struct HourClockTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func window(used: Double?, resetsIn: TimeInterval?, period: TimeInterval?) -> LimitWindow {
        LimitWindow(id: "five_hour", label: "Session", usedFraction: used, resetsAt: resetsIn.map { now.addingTimeInterval($0) }, periodDuration: period)
    }

    @Test func theFilledShareIsTheTimeLeftOverThePeriod() {
        let five = Period.fiveHours
        let remaining = HourClock.remaining(window(used: 0.14, resetsIn: 3 * 3600, period: five), now: now)
        let expected = 0.6
        #expect(abs((remaining ?? 0) - expected) < 0.0001)
        #expect(HourClock.remaining(window(used: 0.9, resetsIn: -60, period: five), now: now) == 0)
        #expect(HourClock.remaining(window(used: 0.1, resetsIn: 7 * 3600, period: five), now: now) == 1)
    }

    @Test func aWindowThatHasNotStartedIsAFullClockAndOneWithNoResetIsNone() {
        #expect(HourClock.remaining(window(used: 0, resetsIn: nil, period: Period.fiveHours), now: now) == 1)
        #expect(HourClock.remaining(window(used: 0.2, resetsIn: nil, period: Period.fiveHours), now: now) == nil)
        #expect(HourClock.remaining(window(used: nil, resetsIn: nil, period: Period.fiveHours), now: now) == nil)
    }

    @Test func onlyAWindowShorterThanADayGetsAClock() {
        let day: TimeInterval = 24 * 3600
        #expect(HourClock.remaining(window(used: 0.5, resetsIn: 3600, period: day), now: now) == nil)
        #expect(HourClock.remaining(window(used: 0.5, resetsIn: 3600, period: 7 * day), now: now) == nil)
        #expect(HourClock.remaining(window(used: 0.5, resetsIn: 3600, period: nil), now: now) == nil)
        #expect(HourClock.isHourly(window(used: 0.5, resetsIn: 3600, period: 2 * 3600)))
    }

    @Test func theSectorIsAnEmptyPathEmptyAndAWholeDiscFull() {
        let rect = CGRect(x: 0, y: 0, width: 10, height: 10)
        #expect(ClockSector(remaining: 0).path(in: rect).isEmpty)
        #expect(ClockSector(remaining: 1).path(in: rect).boundingRect == rect)
        #expect(!ClockSector(remaining: 0.4).path(in: rect).isEmpty)
    }
}

/// The dial (UsageDial): up to three rings from the windows with a figure, in the card's order; the rest keep
/// their meters; the centre is the figure the Simple row would name; the rings nest inside one another.
@Suite struct UsageDialTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func window(_ id: String, used: Double?) -> LimitWindow {
        LimitWindow(id: id, label: .vendor(id), usedFraction: used, resetsAt: now.addingTimeInterval(3600), periodDuration: Period.fiveHours)
    }

    @Test func theFirstThreeWindowsWithAFigureAreRingsAndTheRestKeepTheirMeters() {
        let windows = [window("a", used: 0.1), window("b", used: nil), window("c", used: 0.2), window("d", used: 0.3), window("e", used: 0.4)]
        let split = UsageDial.split(windows)
        #expect(split.rings.map(\.id) == ["a", "c", "d"])
        #expect(split.bars.map(\.id) == ["b", "e"])
        #expect(UsageDial.split([]).rings.isEmpty)
    }

    @Test func theRingsNestWithRoomInTheMiddle() {
        let geometry = UsageDial.geometry(count: 3, size: 84)
        #expect(geometry.count == 3)
        #expect(geometry[0].diameter == 84)
        for index in 1 ..< geometry.count {
            let gap = (geometry[index - 1].diameter - geometry[index].diameter) / 2
            #expect(gap > geometry[index].lineWidth, "rings \(index - 1) and \(index) overlap")
        }
        let innermost = geometry[2]
        let hole = innermost.diameter - 2 * innermost.lineWidth
        #expect(hole >= 30, "no room for a figure")
        #expect(UsageDial.geometry(count: 0, size: 84).isEmpty)
        #expect(DialSwatch.diameters(count: 3).first == DialSwatch.size)
    }

    @Test func theCentreIsTheMostUrgentWindow() {
        let behind = LimitWindow(id: "weekly", label: "Weekly", usedFraction: 0.9, resetsAt: now.addingTimeInterval(4 * 86400), periodDuration: 7 * 86400)
        let calm = LimitWindow(id: "five_hour", label: "Session", usedFraction: 0.05, resetsAt: now.addingTimeInterval(4 * 3600), periodDuration: Period.fiveHours)
        #expect(UsageDial.centre([calm, behind], now: now)?.id == "weekly")
        // A ring behind pace takes the pace colour, as a meter's fill does; one ahead keeps its ring colour.
        #expect(UsageDial.colour(behind, tool: .claude, index: 1, now: now) == Palette.danger)
        #expect(UsageDial.colour(calm, tool: .claude, index: 0, now: now) == ToolID.claude.color)
        #expect(UsageDial.colour(calm, tool: .claude, index: 2, now: now) == ToolID.claude.ringColor(at: 2))
    }
}

/// The five settings: their defaults are the panel as it was, each persists, and a material that was never chosen
/// is stored as nothing, so the layout's own default stays in force.
@MainActor @Suite struct PanelThemePreferences {
    @Test func theDefaultsAreThePanelAsItWasAndEachChoicePersists() {
        let suite = "NotchmeterTests.PanelTheme"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        #expect(prefs.panelTheme == .black)
        #expect(prefs.panelMaterial == nil)
        #expect(prefs.panelAccent == .terracotta)
        #expect(prefs.usageStyle == .bars)
        #expect(!prefs.hourClock)
        prefs.panelTheme = .paper
        prefs.panelMaterial = .smoked
        prefs.panelAccent = .teal
        prefs.usageStyle = .gauges
        prefs.hourClock = true
        let reread = Preferences(defaults: defaults)
        #expect(reread.panelTheme == .paper)
        #expect(reread.panelMaterial == .smoked)
        #expect(reread.panelAccent == .teal)
        #expect(reread.usageStyle == .gauges)
        #expect(reread.hourClock)
        reread.panelMaterial = nil
        #expect(defaults.object(forKey: "panelMaterial") == nil)
        #expect(Preferences(defaults: defaults).panelMaterial == nil)
    }
}

/// Everything the open panel draws goes through the look: no view in the panel's files paints SwiftUI's own
/// secondary or tertiary, a bare white or black, or a palette colour straight, since any of those is the black
/// panel's colour on Paper — SwiftUI's secondary is 3.1:1 on the sheet, and Wong's orange 2.1:1. A line that means
/// it (the wordmark on the black frame round a copied Paper panel) says so with `// panel-ink:`.
@Suite struct PanelInkDiscipline {
    static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Notchmeter")

    static let forbidden = [
        #"\.foregroundStyle\(\.(secondary|tertiary|primary)\)"#,
        #"AnyShapeStyle\(\.(secondary|primary|tertiary)\)"#,
        #"\.(fill|stroke|strokeBorder)\(\.(white|black)"#,
        #"\.(white|black)\.opacity\("#,
        #"\.foregroundStyle\((Palette\.|Color\.(white|black)\)|\.(white|black)\)|tool\.color\))"#,
        #"\.fill\(Palette\."#,
    ]

    /// The panel's own files whole, and NotchViews.swift from the open panel on (the strip beside the notch, above
    /// it, is always on the notch's black).
    static func panelSource() throws -> [(file: String, line: Int, text: String)] {
        var lines: [(String, Int, String)] = []
        for file in ["SimplePanel.swift", "SessionsCard.swift", "PromptCard.swift", "NoticeCard.swift", "UsageGauge.swift", "NotchViews.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            var inPanel = file != "NotchViews.swift"
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                if line.contains("// MARK: - Expanded panel") { inPanel = true }
                if inPanel { lines.append((file, index + 1, line)) }
            }
        }
        return lines
    }

    @Test func noPanelViewPaintsAColourTheLookCannotMove() throws {
        let patterns = try Self.forbidden.map { try NSRegularExpression(pattern: $0) }
        let lines = try Self.panelSource()
        #expect(lines.count > 1500)
        for (file, number, text) in lines where !text.contains("// panel-ink:") && !text.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
            for pattern in patterns where pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                Issue.record("\(file):\(number) paints outside the look: \(text.trimmingCharacters(in: .whitespaces))")
            }
        }
    }
}
