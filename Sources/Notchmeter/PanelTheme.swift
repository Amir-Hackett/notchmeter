import AppKit
import SwiftUI

// MARK: - The choices (Settings › Appearance › Theme)

/// The open panel's face. Black is the panel as it has always been drawn: white ink on the notch's own black, so
/// the panel reads as one shape with the hardware notch. Paper is that notch inverted — the black stays round it as
/// a bezel and a frame, and the sheet inside is light, with dark ink printed on it rather than light lit up.
///
/// Only the open panel changes. The strip beside the notch, the news peek and the glow are drawn on the notch's
/// black band in every theme, so nothing there can go black on black, and the pill an edge layout sits in keeps
/// following Appearance as it always has.
enum PanelTheme: String, CaseIterable, Codable, Sendable {
    case black, paper

    var title: String {
        switch self {
        case .black: L("Black")
        case .paper: L("Paper")
        }
    }
}

/// How much of the desktop shows through the open panel: nothing (Solid), a little (Smoked), or more (Glassy),
/// blurred either way. It says nothing about colour, which is the theme's.
///
/// The tints are not a matter of taste. The panel is drawn over whatever window is behind it, and the worst window
/// is a white one: through a tint of `a`, a white backdrop leaves a grey of `1 - a`. The two numbers are the least
/// black that still lets every line of text on the panel reach 4.5:1 and every mark 3:1 over that grey, once each
/// colour has moved as far in lightness as it has to (`PanelLook`, `PanelLook.audit`). 0.8 is where the secondary
/// ink stops needing more than a small lift; much below it the caption ink has to go nearly white and the panel's
/// two levels of text stop being two.
enum PanelMaterial: String, CaseIterable, Codable, Sendable {
    case glassy, smoked, solid

    var title: String {
        switch self {
        case .glassy: L("Glassy")
        case .smoked: L("Smoked")
        case .solid: L("Solid")
        }
    }

    /// The black laid over the blurred desktop; 1 is opaque.
    var tint: Double {
        switch self {
        case .glassy: 0.8
        case .smoked: 0.9
        case .solid: 1
        }
    }

    var translucent: Bool { self != .solid }

    /// What an install that never chose gets: what each layout has always drawn. The notch's panel is solid black,
    /// so it reads as one shape with the hardware notch; from macOS 26 the card an edge layout opens in has been
    /// Liquid Glass, which is Glassy here, now with the tint that keeps its text readable over a white window.
    static func unchosen(edgeCard: Bool, liquidGlass: Bool) -> PanelMaterial {
        edgeCard && liquidGlass ? .glassy : .solid
    }
}

/// The app's own colour on the panel: the selected range on the Cost card, the line that says a session is waiting
/// for your answer, Clear, and a card's signal label. Three, not seven, because the point is the moment someone
/// makes the panel theirs rather than a palette to browse.
///
/// Terracotta is the icon's colour and stays the default. The two others were chosen by measurement
/// (`PanelAccentChoice` in PanelThemeTests): each reads at 8.5:1 as text on a black card and carries black text on
/// its own pill at better than 9:1; and under a simulation of protanopia, deuteranopia and tritanopia (Machado
/// 2009, full severity) each stays at least 23 ΔE (CIELAB) from the warning orange, the vermillion and the "needs
/// you" blue and at least 30 from terracotta and from each other. Terracotta itself is only 14 from the orange,
/// which is why a colour-blind reader is better served by either of the others. An accent is chrome, never a ring,
/// a meter or a legend dot, so it may sit near an identity colour — teal near Codex's green, lilac near Cursor's
/// violet — as terracotta has always been Claude's own.
///
/// Under Increase Contrast the accent moves so that the text on its pill clears 7:1 rather than 4.5:1: lifted on
/// the black panel, where the text is black, and darkened on Paper, where the text is the paper. The audit holds
/// both (`PanelLook.audit`).
enum PanelAccent: String, CaseIterable, Codable, Sendable {
    case terracotta, teal, lilac

    var title: String {
        switch self {
        case .terracotta: L("Terracotta")
        case .teal: L("Teal")
        case .lilac: L("Lilac")
        }
    }

    /// On the black panel.
    var onBlack: RGB {
        switch self {
        case .terracotta: RGB(red: 0.85, green: 0.47, blue: 0.34)
        case .teal: RGB(hex: 0x4CC3B6)
        case .lilac: RGB(hex: 0xB6A4F7)
        }
    }

    /// Lifted for Increase Contrast, so black text on the selected pill clears 7:1.
    var onBlackContrast: RGB {
        switch self {
        case .terracotta: RGB(hex: 0xE8A084)
        case .teal: RGB(hex: 0x8ADBD2)
        case .lilac: RGB(hex: 0xD3C8FB)
        }
    }

    /// On Paper: dark enough to be read as text on the sheet and to carry the sheet's own colour as text on its pill.
    var onPaper: RGB {
        switch self {
        case .terracotta: RGB(hex: 0x9E4323)
        case .teal: RGB(hex: 0x136B64)
        case .lilac: RGB(hex: 0x5B45B5)
        }
    }

    /// Darkened for Increase Contrast on Paper, so the paper's own colour as text on the selected pill clears 7:1
    /// (8.1:1, 7.6:1 and 7.9:1 against #F4F1EA), as black text on `onBlackContrast` does on the black panel.
    var onPaperContrast: RGB {
        switch self {
        case .terracotta: RGB(hex: 0x7A3219)
        case .teal: RGB(hex: 0x0F5650)
        case .lilac: RGB(hex: 0x4A37A0)
        }
    }
}

/// How a window's usage is drawn on the Simple rows and the cards: a meter per window (the panel as it was), or
/// one dial per assistant with a ring per window nested inside it, outermost first, the way the rings beside the
/// notch are nested (UsageGauge.swift). Either way every figure is the same figure: this is a drawing, not a source.
enum UsageStyle: String, CaseIterable, Codable, Sendable {
    case bars, gauges

    var title: String {
        switch self {
        case .bars: L("Bars")
        case .gauges: L("Gauges")
        }
    }
}

// MARK: - Colour arithmetic

/// A colour as sRGB components, with the arithmetic the contrast rules need: WCAG 2.x relative luminance and
/// contrast ratio, alpha compositing as Core Graphics does it (in the gamma-encoded space, which is what a
/// translucent fill over a sRGB surface produces on screen), and a search that moves a colour in lightness alone
/// until it reads against a set of grounds.
struct RGB: Hashable, Sendable, CustomStringConvertible {
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    static let white = RGB(red: 1, green: 1, blue: 1)
    static let black = RGB(red: 0, green: 0, blue: 0)

    var color: Color { Color(red: red, green: green, blue: blue) }

    /// The 0xRRGGBB value, rounded as `description` prints it.
    var hex: UInt32 {
        let byte = { (value: Double) in UInt32((max(0, min(1, value)) * 255).rounded()) }
        return byte(red) << 16 | byte(green) << 8 | byte(blue)
    }

    /// "#D97857".
    var description: String {
        let byte = { (value: Double) in Int((max(0, min(1, value)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    /// WCAG 2.x relative luminance.
    var luminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The WCAG contrast ratio, 1 to 21, whichever of the two is lighter.
    func contrast(_ other: RGB) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// This colour laid over `ground` at `alpha`.
    func over(_ ground: RGB, alpha: Double) -> RGB {
        RGB(red: red * alpha + ground.red * (1 - alpha), green: green * alpha + ground.green * (1 - alpha),
            blue: blue * alpha + ground.blue * (1 - alpha))
    }

    /// Rounded to the eight bits a display draws, so a derived colour has a hex a test and a document can name.
    var quantised: RGB {
        let byte = { (value: Double) in (max(0, min(1, value)) * 255).rounded() / 255 }
        return RGB(red: byte(red), green: byte(green), blue: byte(blue))
    }

    /// The same hue and saturation, moved in lightness alone — lighter on a dark panel, darker on Paper — by the
    /// least that makes it read at `target` against every ground. A colour that already reads comes back unchanged,
    /// which is what keeps the black panel's own colours where they have always been wherever they already pass.
    /// If no lightness reaches the target the extreme is returned, which the audit then reports.
    func readable(against grounds: [RGB], target: Double, lighter: Bool) -> RGB {
        func passes(_ colour: RGB) -> Bool { grounds.allSatisfy { colour.contrast($0) >= target } }
        if passes(self) { return self }
        let (hue, saturation, lightness) = hsl
        var step = lightness
        while lighter ? step < 1 : step > 0 {
            step = lighter ? min(1, step + 0.004) : max(0, step - 0.004)
            let candidate = RGB(hue: hue, saturation: saturation, lightness: step).quantised
            if passes(candidate) { return candidate }
        }
        return lighter ? .white : .black
    }

    private var hsl: (hue: Double, saturation: Double, lightness: Double) {
        let high = max(red, green, blue), low = min(red, green, blue)
        let lightness = (high + low) / 2
        guard high != low else { return (0, 0, lightness) }
        let delta = high - low
        let saturation = lightness > 0.5 ? delta / (2 - high - low) : delta / (high + low)
        let hue: Double
        switch high {
        case red: hue = ((green - blue) / delta + (green < blue ? 6 : 0)) / 6
        case green: hue = ((blue - red) / delta + 2) / 6
        default: hue = ((red - green) / delta + 4) / 6
        }
        return (hue, saturation, lightness)
    }

    private init(hue: Double, saturation: Double, lightness: Double) {
        guard saturation > 0 else { self.init(red: lightness, green: lightness, blue: lightness); return }
        let q = lightness < 0.5 ? lightness * (1 + saturation) : lightness + saturation - lightness * saturation
        let p = 2 * lightness - q
        func channel(_ t: Double) -> Double {
            let t = t < 0 ? t + 1 : t > 1 ? t - 1 : t
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        self.init(red: channel(hue + 1.0 / 3), green: channel(hue), blue: channel(hue - 1.0 / 3))
    }
}

// MARK: - The panel's colours, by name

/// Every colour the open panel draws that is not ink: the status colours, the app's accent, the green of a finished
/// turn, each assistant's identity colour and its two ring companions. `Palette` and `ToolID.color` are built from
/// these values, so the colour a view passes around is the colour this table knows, and a theme can find its
/// counterpart by looking the view's own `Color` up (`PanelLook.colour(_:role:)`).
enum PanelInk: Hashable, Sendable {
    case calm, warn, danger, accent, accentContrast, pine
    case tool(ToolID)
    /// An assistant's inner rings: 1 is the second ring, 2 the third.
    case companion(ToolID, Int)

    static var all: [PanelInk] {
        [.calm, .warn, .danger, .accent, .accentContrast, .pine]
            + ToolID.allCases.map { .tool($0) }
            + ToolID.allCases.flatMap { tool in [1, 2].map { .companion(tool, $0) } }
    }

    /// The colour on the black panel: Wong's colour-blind-safe status set, the chrome, the assistants' own colours.
    /// The accent here is terracotta, the one `Palette.accent` has always been; the chosen accent replaces it in
    /// `PanelLook`.
    var onBlack: RGB {
        switch self {
        case .calm: RGB(hex: 0x0072B2)
        case .warn: RGB(hex: 0xE69F00)
        case .danger: RGB(hex: 0xD55E00)
        case .accent: PanelAccent.terracotta.onBlack
        case .accentContrast: PanelAccent.terracotta.onBlackContrast
        case .pine: RGB(hex: 0x1D7A5F)
        case .tool(let tool):
            switch tool {
            case .claude: RGB(red: 0.85, green: 0.47, blue: 0.34)
            case .codex: RGB(red: 0.36, green: 0.83, blue: 0.62)
            case .cursor: RGB(red: 0.65, green: 0.55, blue: 0.98)
            case .antigravity: RGB(hex: 0x56B4E9)  // Wong's sky blue
            case .copilot: RGB(hex: 0xF0E442)      // Wong's yellow
            // The three rows 0.9.0 added, in the hues the status colours leave free: Gemini CLI the orchid end of
            // Gemini's own gradient (7.3:1 on black), Kimi Code a leaf green clear of Codex's mint (11.9:1), OpenCode
            // a violet swept against every other colour the notch draws (4.98:1, and at least 9.4 ΔE from each under
            // every colour-vision simulation; a magenta scored better but sat 1.7 from the waiting blue).
            case .gemini: RGB(hex: 0xE36FC0)
            case .kimi: RGB(hex: 0x7ED957)
            case .opencode: RGB(hex: 0xBE3CE6)
            }
        case .companion(let tool, let index):
            RGB(hex: Self.companions(tool, paper: false)[max(0, min(1, index - 1))])
        }
    }

    /// The colour on Paper before the contrast rules move it: the same hue, darkened by hand to a tone that prints
    /// well. `PanelLook` darkens further wherever the rules need it; the audit holds the result.
    var onPaper: RGB {
        switch self {
        case .calm: RGB(hex: 0x00659E)
        case .warn: RGB(hex: 0x8A5A00)
        case .danger: RGB(hex: 0xB23A00)
        case .accent: PanelAccent.terracotta.onPaper
        case .accentContrast: PanelAccent.terracotta.onPaperContrast
        case .pine: RGB(hex: 0x1A6B53)
        case .tool(let tool):
            switch tool {
            case .claude: RGB(hex: 0xB0502E)
            case .codex: RGB(hex: 0x1E7A52)
            case .cursor: RGB(hex: 0x6A45E0)
            case .antigravity: RGB(hex: 0x1D72A8)
            case .copilot: RGB(hex: 0x756A00)
            // The same hues stepped down until a figure reads as text on Paper (4.5:1 or better) while a black glyph
            // still reads on them (the Settings sidebar's tiles, 3:1 or better).
            case .gemini: RGB(hex: 0xB8378F)
            case .kimi: RGB(hex: 0x367D24)
            case .opencode: RGB(hex: 0xA52ACB)
            }
        case .companion(let tool, let index):
            RGB(hex: Self.companions(tool, paper: true)[max(0, min(1, index - 1))])
        }
    }

    /// The two companions of each assistant's colour, near it in hue so the nest reads as one assistant (rose and
    /// sand in Claude's terracotta, teal and lime in Codex's green…), and on Paper the same hues printed darker.
    private static func companions(_ tool: ToolID, paper: Bool) -> [UInt32] {
        switch (tool, paper) {
        case (.claude, false): [0xE88AA8, 0xF2D0A4]       // rose, sand
        case (.codex, false): [0x4FC3E0, 0xB8E476]        // teal, lime
        case (.cursor, false): [0xF08BD6, 0x8FC0FF]       // pink, periwinkle
        case (.antigravity, false): [0x9FA8FF, 0x7FE3CF]  // indigo, mint
        case (.copilot, false): [0xC6E86A, 0xFFF4B0]      // lime, cream
        case (.gemini, false): [0xFFB0D8, 0xC3A6FF]       // blush, soft violet
        case (.kimi, false): [0xC3F08E, 0x7FE0B5]         // pale lime, seafoam
        case (.opencode, false): [0xE59BFF, 0xF6D2FF]     // orchid, lilac
        case (.claude, true): [0xB8406A, 0x8E6224]
        case (.codex, true): [0x1A7389, 0x4E7318]
        case (.cursor, true): [0xB02E8E, 0x2F63C8]
        case (.antigravity, true): [0x4B55D6, 0x1B7663]
        case (.copilot, true): [0x5A7212, 0x7D6A10]
        // The 0.9.0 rows' companions scaled down until each holds 3:1 on Paper as a mark, where the look would move it.
        case (.gemini, true): [0xAA7590, 0x907ABC]
        case (.kimi, true): [0x728C53, 0x529075]
        case (.opencode, true): [0xA771BA, 0x937D98]
        }
    }

    /// The panel's own `Color` for each name, as `Palette` and `ToolID` hand it out, keyed so a view's colour can be
    /// looked up. The accent is left out: `Palette.accent` is terracotta, which is Claude's own colour to the last
    /// digit, and a colour that is both could not say which it was. A view that means the accent names it
    /// (`Themed(.accent, …)`), and so follows the choice; one that means Claude keeps Claude's colour whatever
    /// accent is chosen.
    static let registry: [Color: PanelInk] = Dictionary(
        all.filter { $0 != .accent && $0 != .accentContrast }.map { ($0.onBlack.color, $0) }, uniquingKeysWith: { first, _ in first })
}

// MARK: - The resolved look

/// Everything the open panel is drawn in, resolved from the choices, the layout and the accessibility settings:
/// which face, how much desktop shows through, which accent, whether Increase Contrast is on, and how usage is
/// drawn. Views read it from the environment (`EnvironmentValues.panelLook`); `NotchExpandedView` sets it at the
/// root, so the live panel, its measuring probes, "Copy as image" and the renders all draw the same look.
///
/// The colours are derived rather than listed per combination. Each theme names a base for every colour (`PanelInk`)
/// and three grounds the panel can put it on — the sheet as it looks over the worst backdrop (a white window behind
/// Glassy or Smoked), a card's box on that sheet, and the "needs you" wash on that box — and every colour is moved
/// in lightness alone by the least that makes text read at 4.5:1 on all three and a mark at 3:1 on the sheet and
/// the box (`RGB.readable`). The black panel's own colours pass almost everywhere and so come back as they were;
/// what moves there is text that never passed: the "needs you" blue and the green in a line of words, and the
/// vermillion on the wash.
struct PanelLook: Equatable, Sendable {
    var theme: PanelTheme = .black
    var material: PanelMaterial = .solid
    var accent: PanelAccent = .terracotta
    var contrast = false
    var usageStyle: UsageStyle = .bars
    var hourClock = false

    /// The panel as it has always been drawn.
    static let standard = PanelLook()

    /// A colour's job where it is drawn: words, held to 4.5:1, or a mark (a fill, a ring, a glyph), held to 3:1.
    enum Role: Sendable { case text, mark }

    /// The text levels, as `Ink` draws them.
    enum InkLevel: Sendable { case primary, secondary, tertiary }

    /// The look for these choices on this Mac. Paper is always solid: dark ink on a sheet the desktop shows through
    /// would lose its contrast over a dark window, and a frosted sheet at the opacity that keeps it is solid in all
    /// but name. Reduce Transparency and Increase Contrast make any panel solid, as macOS makes its own.
    static func resolve(theme: PanelTheme, material chosen: PanelMaterial?, accent: PanelAccent, usageStyle: UsageStyle, hourClock: Bool,
                        edgeCard: Bool, liquidGlass: Bool, increaseContrast: Bool, reduceTransparency: Bool) -> PanelLook {
        var material = chosen ?? PanelMaterial.unchosen(edgeCard: edgeCard, liquidGlass: liquidGlass)
        if theme == .paper || increaseContrast || reduceTransparency { material = .solid }
        return PanelLook(theme: theme, material: material, accent: accent, contrast: increaseContrast, usageStyle: usageStyle, hourClock: hourClock)
    }

    /// Whether macOS 26's Liquid Glass is there to be used.
    static var liquidGlass: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// The look the live panel is drawn in for these preferences, in this layout, under this Mac's accessibility
    /// settings.
    @MainActor
    static func current(_ prefs: Preferences, edgeCard: Bool) -> PanelLook {
        let display = AccessibilityDisplay.shared
        return resolve(theme: prefs.panelTheme, material: prefs.panelMaterial, accent: prefs.panelAccent, usageStyle: prefs.usageStyle,
                       hourClock: prefs.hourClock, edgeCard: edgeCard, liquidGlass: liquidGlass, increaseContrast: display.contrast,
                       reduceTransparency: display.reduceTransparency)
    }

    // MARK: Grounds

    var colorScheme: ColorScheme { theme == .paper ? .light : .dark }

    /// The panel's own ground: the notch's black, or the paper of the sheet.
    var ground: RGB { theme == .paper ? Self.paper : .black }

    /// The primary ink: white on black, near-black on Paper.
    var ink: RGB { theme == .paper ? Self.paperInk : .white }

    /// The sheet as the reader sees it at worst: on a translucent panel, the tint over a white window.
    var sheet: RGB {
        guard theme == .black, material.translucent else { return ground }
        return RGB.black.over(.white, alpha: material.tint)
    }

    /// How much stronger a translucent wash of ink is on this theme. The black panel's washes are white at the
    /// opacities each view names; Paper draws the same washes in its ink at six tenths of them, because a dark
    /// wash on a light sheet reads darker than a light one on black, and at full strength the "needs you" wash
    /// under Increase Contrast would leave no lightness for the words on it.
    var washScale: Double { theme == .paper ? 0.6 : 1 }

    /// A card's box on the sheet (`CardBackground`).
    var box: RGB { ink.over(sheet, alpha: (contrast ? 0.16 : 0.07) * washScale) }

    /// The "needs you" wash (SimpleRow, SessionRow), on the box, where it is lightest.
    var wash: RGB { palette.calmMark.over(box, alpha: (contrast ? 0.32 : 0.15) * washScale) }

    // MARK: Colours

    /// The colour a view draws `base` in on this look: ink for white and for the primary label colour, the ground
    /// for black (a filled button's label, the excerpt's well), the secondary ink for the secondary label colour,
    /// and for a colour in `PanelInk` its derived counterpart for the role. A colour the table does not know is
    /// drawn as it is, and on the standard look everything that already passed is its own `Color`, unchanged.
    func colour(_ base: Color, role: Role = .mark) -> Color {
        if base == .white || base == .primary { return theme == .black ? base : ink.color }
        if base == .black { return theme == .black ? base : ground.color }
        if base == .secondary { return theme == .black && self.material == .solid ? base : inkColour(.secondary) }
        guard let name = PanelInk.registry[base] else { return base }
        let derived = rgb(name, role: role)
        return derived == name.onBlack ? base : derived.color
    }

    /// A named colour's value on this look, for the role.
    func rgb(_ name: PanelInk, role: Role) -> RGB {
        role == .text ? palette.text[name] ?? name.onBlack : palette.mark[name] ?? name.onBlack
    }

    /// The text levels as colours: the primary ink, and the secondary and tertiary as the ink at the opacity that
    /// reads at 4.5:1 on every ground (the black panel's secondary is SwiftUI's own, 146/255 over black, which
    /// already does).
    func inkColour(_ level: InkLevel) -> Color {
        switch level {
        case .primary: ink.color
        case .secondary: palette.secondary.color
        case .tertiary: palette.tertiary.color
        }
    }

    /// What `Ink` resolves to: on the standard black panel SwiftUI's own hierarchical levels, so the panel is drawn
    /// exactly as it was; everywhere else the measured colours above.
    func inkStyle(_ level: InkLevel) -> AnyShapeStyle {
        if theme == .black, material == .solid {
            switch level {
            case .primary: return AnyShapeStyle(HierarchicalShapeStyle.primary)
            case .secondary: return AnyShapeStyle(HierarchicalShapeStyle.secondary)
            case .tertiary: return AnyShapeStyle(inkColour(.tertiary))
            }
        }
        return AnyShapeStyle(inkColour(level))
    }

    /// The opacity a view's own translucent wash of ink or colour takes on this look (`Themed.wash`).
    func washOpacity(_ opacity: Double) -> Double { opacity * washScale }

    // MARK: The derived palette

    struct Palette: Sendable {
        let text: [PanelInk: RGB]
        let mark: [PanelInk: RGB]
        /// The secondary and tertiary ink as the colour they composite to over the lightest ground; the views
        /// draw them solid, so what is measured is what is drawn.
        let secondary: RGB
        let tertiary: RGB
        /// The "needs you" blue as a mark, which the wash is made of.
        let calmMark: RGB
    }

    /// The colours for this look, derived once per combination of face, material, accent and contrast.
    var palette: Palette { Self.palettes.palette(for: self) }

    /// The ink the views draw their SwiftUI hierarchical secondary in on the standard panel, as it composites over
    /// black: 146 of 255 (measured, macOS 15 and 26).
    static let hierarchicalSecondary = 146.0 / 255

    static let paper = RGB(hex: 0xF4F1EA)
    static let paperInk = RGB(hex: 0x1B1A17)
    /// Paper's secondary and tertiary inks before the rules darken them.
    static let paperSecondary = RGB(hex: 0x57534C)
    static let paperTertiary = RGB(hex: 0x6B665E)

    fileprivate func derive() -> Palette {
        let lighter = theme == .black
        let base = { (name: PanelInk) -> RGB in
            switch name {
            case .accent: self.theme == .paper ? self.accent.onPaper : self.accent.onBlack
            case .accentContrast: self.theme == .paper ? self.accent.onPaperContrast : self.accent.onBlackContrast
            default: self.theme == .paper ? name.onPaper : name.onBlack
            }
        }
        let sheet = self.sheet
        let box = ink.over(sheet, alpha: (contrast ? 0.16 : 0.07) * washScale)
        let calmMark = base(.calm).readable(against: [sheet, box], target: 3, lighter: lighter)
        let wash = calmMark.over(box, alpha: (contrast ? 0.32 : 0.15) * washScale)
        let grounds = [sheet, box, wash]
        var text: [PanelInk: RGB] = [:]
        var mark: [PanelInk: RGB] = [:]
        for name in PanelInk.all {
            text[name] = base(name).readable(against: grounds, target: 4.5, lighter: lighter)
            mark[name] = base(name).readable(against: [sheet, box], target: 3, lighter: lighter)
        }
        let secondary: RGB
        let tertiary: RGB
        if theme == .paper {
            secondary = Self.paperSecondary.readable(against: grounds, target: 4.5, lighter: false)
            tertiary = Self.paperTertiary.readable(against: grounds, target: 4.5, lighter: false)
        } else {
            // The least white that reads on every ground, and never less than SwiftUI's own secondary: drawn over
            // the sheet, since that is the ground the panel is mostly made of.
            let alpha = Self.inkAlpha(from: Self.hierarchicalSecondary, grounds: grounds)
            secondary = RGB.white.over(sheet, alpha: alpha).readable(against: grounds, target: 4.5, lighter: true)
            tertiary = secondary
        }
        return Palette(text: text, mark: mark, secondary: secondary, tertiary: tertiary, calmMark: calmMark)
    }

    /// The least opacity of white, from `floor` up, at which white over each ground reads at 4.5:1 against it.
    static func inkAlpha(from floor: Double, grounds: [RGB]) -> Double {
        var alpha = floor
        while alpha < 1, !grounds.allSatisfy({ RGB.white.over($0, alpha: alpha).contrast($0) >= 4.5 }) { alpha += 0.01 }
        return min(1, alpha)
    }

    /// One palette per combination, derived on first use. The derivation is a few hundred luminance sums; the root
    /// of the panel is re-evaluated on every reading, so it is kept rather than repeated.
    private static let palettes = PaletteCache()

    private final class PaletteCache: @unchecked Sendable {
        private struct Key: Hashable { let theme: PanelTheme; let material: PanelMaterial; let accent: PanelAccent; let contrast: Bool }
        private var cache: [Key: Palette] = [:]
        private let lock = NSLock()

        func palette(for look: PanelLook) -> Palette {
            let key = Key(theme: look.theme, material: look.material, accent: look.accent, contrast: look.contrast)
            lock.lock()
            defer { lock.unlock() }
            if let hit = cache[key] { return hit }
            let derived = look.derive()
            cache[key] = derived
            return derived
        }
    }

    // MARK: The audit

    /// One pairing that does not reach its threshold.
    struct Finding: Equatable, CustomStringConvertible {
        let what: String
        let ground: String
        let ratio: Double
        let target: Double

        var description: String { "\(what) on \(ground): \(String(format: "%.2f", ratio)):1 < \(target):1" }
    }

    /// Every pairing the panel can draw on this look, measured: each text colour and ink level against the sheet,
    /// the box and the wash at 4.5:1; each mark against the sheet and the box at 3:1; the words on the selected
    /// pill at 4.5:1, and at 7:1 on the pill Increase Contrast draws, which is the promise that setting makes on
    /// both faces; the words on a filled button at 4.5:1. Empty is a look every element of which passes.
    /// `ThemeContrastTests` holds every combination to it, and the renderer prints the worst pairing of each look
    /// it draws.
    func audit() -> [Finding] {
        let palette = self.palette
        let grounds: [(String, RGB)] = [("sheet", sheet), ("box", box), ("wash", wash)]
        var findings: [Finding] = []
        func check(_ what: String, _ colour: RGB, _ on: [(String, RGB)], _ target: Double) {
            for (name, ground) in on where colour.contrast(ground) < target {
                findings.append(Finding(what: what, ground: name, ratio: colour.contrast(ground), target: target))
            }
        }
        check("ink", ink, grounds, 4.5)
        let secondary = theme == .black && material == .solid ? nil : palette.secondary
        if let secondary {
            check("secondary ink", secondary, grounds, 4.5)
            check("tertiary ink", palette.tertiary, grounds, 4.5)
        } else {
            // SwiftUI's own secondary, composited over each ground as it is drawn.
            for (name, ground) in grounds {
                let drawn = RGB.white.over(ground, alpha: Self.hierarchicalSecondary)
                check("secondary ink", drawn, [(name, ground)], 4.5)
            }
            check("tertiary ink", palette.tertiary, grounds, 4.5)
        }
        for name in PanelInk.all {
            check("\(name) text", palette.text[name] ?? name.onBlack, grounds, 4.5)
            check("\(name) mark", palette.mark[name] ?? name.onBlack, Array(grounds.prefix(2)), 3)
        }
        // The selected range: the ground's colour (black on the black panel, paper on Paper) on the accent. The
        // contrast accent is only ever drawn under Increase Contrast, so it owes 7:1 on every look.
        let pillText = theme == .paper ? ground : RGB.black
        for (name, target) in [(PanelInk.accent, 4.5), (.accentContrast, 7)] {
            let pill = palette.mark[name] ?? name.onBlack
            check("text on the \(name) pill", pillText, [("\(name) pill", pill)], target)
        }
        // Allow, Send and Jump: the ground's colour on a filled ink button.
        check("text on a filled button", ground, [("filled button", ink)], 4.5)
        return findings
    }

    /// The weakest pairing on this look, for the renderer's log line and `--smoke`.
    var weakest: (text: Double, mark: Double) {
        let palette = self.palette
        let grounds = [sheet, box, wash]
        let texts = PanelInk.all.map { palette.text[$0] ?? $0.onBlack } + [ink, palette.secondary]
        let marks = PanelInk.all.map { palette.mark[$0] ?? $0.onBlack }
        let text = texts.flatMap { colour in grounds.map { colour.contrast($0) } }.min() ?? 21
        let mark = marks.flatMap { colour in grounds.prefix(2).map { colour.contrast($0) } }.min() ?? 21
        return (text, mark)
    }

    /// "paper · solid · teal · gauges · clock", for the logs and `--smoke`.
    var summary: String {
        ([theme.rawValue, material.rawValue, accent.rawValue, usageStyle.rawValue] + (hourClock ? ["clock"] : []) + (contrast ? ["contrast"] : []))
            .joined(separator: " · ")
    }
}

extension PanelLook {
    /// The fields the oracle's snapshot carries.
    var oracleFields: [String: Any] {
        ["theme": theme.rawValue, "material": material.rawValue, "accent": accent.rawValue, "usageStyle": usageStyle.rawValue,
         "hourClock": hourClock, "contrast": contrast]
    }
}

// MARK: - Drawing in the look

private struct PanelLookKey: EnvironmentKey {
    static let defaultValue = PanelLook.standard
}

extension EnvironmentValues {
    /// The look the open panel is drawn in. Anything drawn outside the panel — the strip beside the notch, the
    /// pill, Settings — keeps the standard look, which is the panel as it has always been.
    var panelLook: PanelLook {
        get { self[PanelLookKey.self] }
        set { self[PanelLookKey.self] = newValue }
    }
}

/// A panel colour drawn in the look it lands in: `Themed(Palette.warn, .text)` is the warning orange on the black
/// panel and its printed counterpart on Paper, `Themed(.white)` is the ink, and `Themed(.accent, .text)` is the
/// accent the reader chose. A shape style rather than a colour, because it resolves against the environment where
/// it is drawn, so no view has to carry the look to pass it on.
struct Themed: ShapeStyle {
    private enum Source: Equatable, Sendable {
        case colour(Color)
        case named(PanelInk)
    }

    private let source: Source
    private let role: PanelLook.Role
    private let opacity: Double
    /// A translucent wash of the colour (a box, a track, a well), whose strength the theme scales
    /// (`PanelLook.washScale`); a mark or text at reduced opacity keeps the opacity it names.
    private var wash = false

    init(_ base: Color, _ role: PanelLook.Role = .mark, opacity: Double = 1) {
        source = .colour(base)
        self.role = role
        self.opacity = opacity
    }

    init(_ name: PanelInk, _ role: PanelLook.Role = .mark, opacity: Double = 1) {
        source = .named(name)
        self.role = role
        self.opacity = opacity
    }

    /// A wash of `base` at `opacity` on the black panel, scaled on Paper.
    static func wash(_ base: Color, _ opacity: Double) -> Themed {
        var style = Themed(base, .mark, opacity: opacity)
        style.wash = true
        return style
    }

    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        let look = environment.panelLook
        let colour = switch source {
        case .colour(let base): look.colour(base, role: role)
        case .named(let name): look.rgb(name, role: role).color
        }
        let alpha = wash ? look.washOpacity(opacity) : opacity
        return (alpha < 1 ? colour.opacity(alpha) : colour).resolve(in: environment)
    }
}

/// The panel's text levels in the look they land in (`PanelLook.inkStyle`). On the standard panel they are
/// SwiftUI's own `.primary`, `.secondary` and a measured tertiary, so nothing moves; on every other look they are
/// the measured inks, because SwiftUI's secondary on a light ground is 3.1:1 and on a grey one less.
struct Ink: ShapeStyle {
    let level: PanelLook.InkLevel

    static let primary = Ink(level: .primary)
    static let secondary = Ink(level: .secondary)
    static let tertiary = Ink(level: .tertiary)

    func resolve(in environment: EnvironmentValues) -> AnyShapeStyle {
        environment.panelLook.inkStyle(level)
    }
}

/// The root of anything drawn as the open panel: the look in the environment, the ink as the foreground and the
/// colour scheme to match, so SwiftUI's own controls (the small progress spinner) draw light on black and dark on
/// Paper.
struct PanelInkEnvironment: ViewModifier {
    let look: PanelLook

    func body(content: Content) -> some View {
        content
            .foregroundStyle(look.theme == .black ? Color.white : look.ink.color)
            .environment(\.colorScheme, look.colorScheme)
            .environment(\.panelLook, look)
    }
}

/// Paper's sheet behind the panel's content, inside the black the notch or the card draws round it. Nothing on
/// the black panel, whose ground is the black already there.
struct PaperSheet: ViewModifier {
    let look: PanelLook
    /// The sheet's corners: a little under the notch's own 20 pt, so the black frame round it reads as even.
    static let cornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        content.background {
            if look.theme == .paper {
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous).fill(look.ground.color)
            }
        }
    }
}

/// The desktop blurred behind a translucent panel, and the black laid over it (`PanelMaterial.tint`). The blur is
/// the HUD material in the dark appearance, whatever the system's, so the backdrop darkens a white window before
/// the tint does; the tint alone is what the contrast rules count on.
struct PanelBlurBackdrop: View {
    let tint: Double

    var body: some View {
        ZStack {
            BehindWindowBlur()
            Color.black.opacity(tint)
        }
        .accessibilityHidden(true)
    }
}

/// `NSVisualEffectView` blurring what is behind the window, in the dark HUD material, always active: the panel
/// never becomes key, and an inactive material would go flat grey whenever another app is in front.
struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
