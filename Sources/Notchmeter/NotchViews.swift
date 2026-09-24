import AppKit
import Observation
import SwiftUI

extension ToolID {
    /// The assistant's own colour on the black panel and beside the notch (`PanelInk`, which also holds its Paper
    /// counterpart): Claude's terracotta, Codex's green, Cursor's violet, Wong's sky blue for Antigravity and his
    /// yellow for Copilot.
    var color: Color { PanelInk.tool(self).onBlack.color }

    /// The colour of each nested ring, outermost first: the assistant's own on the outer ring, then two companions
    /// near it in hue, so the inner rings read as the same assistant but can be told apart from the outer one at a
    /// glance ("Cursor models" beside "All models"). None of them is a status colour (`Palette`), so a companion is
    /// never mistaken for a warning.
    func ringColor(at index: Int) -> Color {
        guard index > 0 else { return color }
        return PanelInk.companion(self, min(index, 2)).onBlack.color
    }
}

/// Status colours are Wong's colour-blind-safe set, and every status also carries a shape or a symbol so the
/// meaning never rests on hue alone. Tool identity keeps its own colours on the bars. The values live in `PanelInk`
/// beside their Paper counterparts; these are the black panel's, which is also what everything outside the open
/// panel draws in.
enum Palette {
    static let calm = PanelInk.calm.onBlack.color      // #0072B2 blue: needs you, not running out
    static let warn = PanelInk.warn.onBlack.color      // #E69F00 orange: on track, nearly full, needs attention
    static let danger = PanelInk.danger.onBlack.color  // #D55E00 vermillion: behind pace, out
    /// The brand terracotta, the icon's colour (scripts/make-icon.swift) and Claude Code's identity colour on
    /// the rings. Not a status colour: it is the app's own accent, on the Cost card's range control and on the
    /// card's "Waiting for your answer" line, where the system's blue would have been. 5.7:1 against the panel's
    /// black, 3.7:1 under white, so a selected segment carries black text on it rather than white. On the open
    /// panel it is drawn as the accent the reader chose (`Themed(.accent, …)`, Settings › Appearance › Theme).
    static let accent = PanelInk.accent.onBlack.color
    /// The accent under Increase Contrast: the same hue lifted so black text on it clears 7:1.
    static let accentContrast = PanelInk.accentContrast.onBlack.color
    /// Not a status colour and never on a reading: the neutral chrome tile behind a white glyph (the Settings
    /// sidebar). 6.45:1 against white in both appearances, where `.gray` is 3.26 light and 2.87 dark.
    static let pine = PanelInk.pine.onBlack.color      // #1D7A5F green: the Dashboard tile in Settings, 5.4:1 under white
    /// Settings' chrome only, never on the panel, so it has no Paper counterpart.
    static let slate = RGB(hex: 0x5E5E63).color         // #5E5E63 grey: chrome, says nothing about a limit
}

extension ToolSignal {
    /// Both states take `Palette.calm`. It is already this app's documented hue for "needs you, not running out",
    /// and already the colour of the Advice line that says Claude Code is waiting in some project, so the ring
    /// beside the notch and the strip inside the panel now say the same thing in the same colour rather than
    /// inventing a second vocabulary. Against orange and vermillion it is the blue-yellow axis, the one both
    /// deuteranopia and protanopia keep, so a waiting ring can never be read as a window running out.
    ///
    /// One hue for two states, not two, because the two states ask the same thing of the reader and because a
    /// third safe hue does not exist here: Wong's remaining green and yellow are Codex's and Copilot's identity
    /// colours on the same strip, its brighter sky blue is Antigravity's, and reddish purple collapses towards
    /// blue for a protanope. The shape carries the difference instead (SignalMark).
    var colour: Color { Palette.calm }
}

/// The accessibility display settings the custom drawing honours: Increase Contrast raises the low-opacity
/// tracks and fills and floors captions at secondary; Reduce Transparency swaps glass for solid black; Reduce
/// Motion (the system's, or the app's own toggle) stills every animation. Re-read on the system's notification.
@MainActor
@Observable
final class AccessibilityDisplay {
    static let shared = AccessibilityDisplay()

    private(set) var increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    private(set) var reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    private(set) var systemReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// Preferences.reduceAnimations, mirrored here by the app delegate.
    var reduceAnimations = false
    @ObservationIgnored private var forcedContrast: Bool?
    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AccessibilityDisplay.shared.refresh() }
        }
    }

    var motionReduced: Bool { systemReduceMotion || reduceAnimations }
    var contrast: Bool { forcedContrast ?? increaseContrast }

    func refresh() {
        increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        systemReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// `--render-assets` draws an increased-contrast variant without changing System Settings.
    func force(contrast: Bool?) {
        forcedContrast = contrast
        increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    var description: String {
        "increaseContrast=\(increaseContrast) reduceTransparency=\(reduceTransparency) reduceMotion=\(systemReduceMotion) reduceAnimations=\(reduceAnimations)"
    }
}

private struct DensityKey: EnvironmentKey {
    static let defaultValue = Density.comfortable
}

extension EnvironmentValues {
    var density: Density {
        get { self[DensityKey.self] }
        set { self[DensityKey.self] = newValue }
    }
}

extension Pace.Status {
    var meterColor: Color? {
        switch self {
        case .ahead: nil
        case .onTrack: Palette.warn
        case .behind: Palette.danger
        }
    }

    var noteColor: Color {
        switch self {
        case .ahead: .secondary
        case .onTrack: Palette.warn
        case .behind: Palette.danger
        }
    }

    /// The non-colour channel beside a pace note; ahead is the quiet state and carries none.
    var symbolName: String? {
        switch self {
        case .ahead: nil
        case .onTrack: "arrow.up.right"
        case .behind: "exclamationmark.triangle.fill"
        }
    }
}

extension Advice.Priority {
    var color: Color {
        switch self {
        case .attention: Palette.calm
        case .danger: Palette.danger
        case .warn: Palette.warn
        case .info: .secondary
        }
    }

    /// The colour of the line's symbol, which is where the state colour goes: the text stays in a text colour.
    /// The "needs you" blue goes white under Increase Contrast, as SessionRow.needsYouMark does, where it is under
    /// 3:1 on the lighter card and the row's wash.
    @MainActor var mark: Color {
        self == .attention && AccessibilityDisplay.shared.contrast ? .white : color
    }
}

extension String {
    /// The text with its hyphens made non-breaking, so "30-day" stays whole when a line wraps.
    var keepingHyphensWhole: String { replacingOccurrences(of: "-", with: "\u{2011}") }
}

/// Captions are secondary on black by default and primary under Increase Contrast. Tertiary was tried first and
/// on the black panel it blended in: the lines it carried ("$108.76 of a usual $107 day", "no spend read yet") could
/// not be read at a glance, which is the only way the panel is read.
/// The levels are the panel's inks (`Ink`), which on the black panel are SwiftUI's own and on every other look the
/// measured ones: SwiftUI's secondary is 3.1:1 on a light sheet.
struct Caption: ViewModifier {
    @MainActor
    static var style: AnyShapeStyle {
        AccessibilityDisplay.shared.contrast ? AnyShapeStyle(Ink.primary) : AnyShapeStyle(Ink.secondary)
    }

    func body(content: Content) -> some View {
        content.font(.caption2).foregroundStyle(Self.style)
    }
}

/// The box a Detailed card sits in. `boxed: false` draws the content bare, for a card opened in place under a
/// Simple row (SimplePanel.swift), where the sheet is the only surface and the row above already frames it.
struct CardBackground: ViewModifier {
    var boxed = true
    @Environment(\.density) private var density

    func body(content: Content) -> some View {
        content
            .padding(boxed ? density.cardPadding : 0)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Themed.wash(.white, boxed ? (AccessibilityDisplay.shared.contrast ? 0.16 : 0.07) : 0)))
    }
}

// MARK: - Rings (compact states)

struct RingView: View {
    var fraction: Double?
    var color: Color
    var lineWidth: CGFloat = 3
    /// Drawn as a cap on the arc's end: hollow when on track, filled when behind. Shape, not colour, carries it.
    var pace: Pace.Status? = nil
    /// What the tool's agent is asking of the user (ToolSignal). While one holds it takes the whole ring, track and
    /// arc alike, and the fullness tint it displaced moves onto the cap.
    var signal: ToolSignal? = nil

    var body: some View {
        let contrast = AccessibilityDisplay.shared.contrast
        let ground = signal?.colour ?? color
        let cap = Self.cap(fraction: fraction, pace: pace, signal: signal)
        ZStack {
            Circle()
                .stroke(ground.opacity(Self.trackOpacity(signal: signal, contrast: contrast)), lineWidth: lineWidth)
            if let fraction {
                let shown = max(0.015, min(1, fraction))
                Circle()
                    .trim(from: 0, to: CGFloat(shown))
                    .stroke(Self.arcColour(fraction: fraction, tool: color, signal: signal), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if let cap {
                    GeometryReader { geometry in
                        let radius = min(geometry.size.width, geometry.size.height) / 2 - lineWidth / 2
                        let angle = -Double.pi / 2 + 2 * .pi * shown
                        PaceCap(filled: cap.filled, color: cap.color, diameter: lineWidth * 2.2)
                            .position(x: geometry.size.width / 2 + radius * cos(angle), y: geometry.size.height / 2 + radius * sin(angle))
                    }
                }
            } else {
                Circle()
                    .stroke(ground.opacity(contrast ? 0.8 : 0.55), style: StrokeStyle(lineWidth: lineWidth, dash: [2, 3]))
            }
        }
        .animation(AccessibilityDisplay.shared.motionReduced ? nil : .snappy(duration: 0.4), value: fraction)
        .animation(AccessibilityDisplay.shared.motionReduced ? nil : .snappy(duration: 0.4), value: signal)
    }

    /// A tool at 4 % has fifteen thousandths of a circle of arc, so a signal that recoloured the arc alone would be
    /// invisible on exactly the ring that most needs seeing. The track is what carries a recolour at low fill, so it
    /// lifts while a signal holds: 0.22 to 0.38, and 0.45 to 0.6 under Increase Contrast, which keeps the same step
    /// between the two settings that the ordinary track has.
    static func trackOpacity(signal: ToolSignal?, contrast: Bool) -> Double {
        if signal != nil { return contrast ? 0.6 : 0.38 }
        return contrast ? 0.45 : 0.22
    }

    /// The colour the arc takes: a signal's, else the tool's own, however full the window. A ring that turned orange
    /// at 80 % and vermillion at 95 % stopped saying which assistant it was at exactly the moment the reader most
    /// needs to know. Dashes from 80 % and ticks from 95 % were tried in 0.4.0 to carry fullness in the line instead,
    /// and on the real notch they read as noise. A ring nearly closed already looks full, the digits beside it give
    /// the figure, and the cap still carries pace, so nothing is drawn for fullness on its own. A signal outranks
    /// the tool's colour, because a permission prompt is the only fact the reader can act on this second.
    static func arcColour(fraction: Double, tool: Color, signal: ToolSignal?) -> Color {
        signal?.colour ?? tool
    }

    /// The tint a nearly-full window earns on its own account, or nil while it still has room.
    static func fullness(_ fraction: Double) -> Color? {
        fraction >= 0.95 ? Palette.danger : fraction >= 0.8 ? Palette.warn : nil
    }

    /// What rides the arc's end. Pace has first claim, as it always has, with the shape it has always had. Failing
    /// that, a signal holding the arc hands the fullness tint it displaced to the cap, so recolouring the ring never
    /// costs the reader the fact that the window is nearly gone. That fallback covers a narrow gap rather than a
    /// broad one: past 95 % the pace can never be ahead, since the projection is at least the fraction already
    /// spent, so a cap is drawn anyway. What it does cover is a session at 85 % with the reset almost here, where
    /// the pace is ahead and draws nothing, and any window with no reset at all to read a pace from.
    static func cap(fraction: Double?, pace: Pace.Status?, signal: ToolSignal?) -> (filled: Bool, color: Color)? {
        if let pace, pace != .ahead {
            return (pace == .behind, pace == .behind ? Palette.danger : Palette.warn)
        }
        guard signal != nil, let fraction, let displaced = fullness(fraction) else { return nil }
        return (fraction >= 0.95, displaced)
    }
}

private struct PaceCap: View {
    let filled: Bool
    let color: Color
    let diameter: CGFloat

    var body: some View {
        Circle()
            .fill(filled ? color : .black)
            .overlay(Circle().stroke(color, lineWidth: filled ? 0 : 1))
            .frame(width: diameter, height: diameter)
    }
}

/// The thin arc outside the Claude ring while a session runs: how full its context window is (from the status line).
private struct ContextArc: View {
    let fraction: Double
    let diameter: CGFloat

    var body: some View {
        Circle()
            .trim(from: 0, to: CGFloat(max(0.01, min(1, fraction))))
            .stroke(.white.opacity(fraction >= 0.9 ? 0.95 : 0.6), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .frame(width: diameter, height: diameter)
            .accessibilityHidden(true)
    }
}

/// One tool's rings: the main window outside, the others nested inside it (Preferences.ringWindows, up to
/// RingSelection.maximum), a "!" for a problem, a mark while the assistant is asking something of the user, and a
/// context arc while the Claude Code status line reports one. The presence level sets the size (Presence.swift):
/// 14 pt when quiet, 18 pt otherwise, and a 4 pt dot when hidden. Two rings keep the diameters they have always
/// had; a third re-spaces the nest so the innermost still reads as a ring rather than a dot.
///
/// A signal takes every ring in the nest, not the outer one alone, so the nest reads as one thing rather than an
/// outer ring that has changed and inner ones that have not; the inner rings' identity colour is redundant while it
/// holds, since the reader already knows which tool this is from where it sits in the strip.
///
/// The mark is drawn outside the quiet dimming rather than inside it, which is why it is a sibling of the dimmed
/// stack rather than a member of it. A 5 pt mark on a 14 pt ring at 70 % opacity is not something anyone reads in
/// passing, and the answer to that was briefly to lift the presence level while a finish held. That was reverted
/// (Presence.swift): the calm rule would have been answering a ninety-second clock as well as a set of limits, the
/// nest would have churned between 14 and 18 points after every long turn, and the clock would have been an input
/// to the view CompactStripProbe renders to measure the strip. The measured footprint never moved between the
/// quiet size and the loud one, at any ring count and in any style — but by two mechanisms, not one. Where this
/// view is drawn (the rings and ringsAndNumbers styles) it is the hard 18 pt frame at the foot of it, which the
/// 14 pt quiet nest and the 18 pt loud one both sit inside; in the numbers style this view is not drawn at all,
/// and what holds the digits still is that presence reaches nothing there but their opacity. So what the lift
/// really bought was a fit resting on those two rather than on the calm rule. The rings go quiet on the calm rule
/// alone and the mark stays loud on its own terms: full opacity at either ring size, and a disc sized by the state
/// it reports rather than by the ring under it — 5 pt for a single wait, 9 pt for a counted one or a finished turn.
/// `SignalMark.cornerOffset` is what keeps each of those sizes inside the 18 pt box.
struct CompactRings: View {
    /// The hard box every ring nest and every mark is drawn inside, so that neither the calm rule nor the
    /// ninety-second signal hold can move the strip's measured width.
    static let side: CGFloat = 18

    let tool: ToolID
    let status: ToolStatus
    var windows: [LimitWindow] = []
    var signal: ToolSignal? = nil
    /// Whether the rings take the state colour, or only the mark carries it (Preferences.signalRings).
    var signalColours = true
    var contextUsed: Double? = nil
    var presence: PresenceLevel = .legible
    /// The assistant's own symbol drawn with the rings (Preferences.ringSymbols), for a reader who cannot tell the
    /// identity colours apart.
    var symbol = false

    /// Diameter and stroke for each nested ring, outermost first.
    static func nest(count: Int, quiet: Bool) -> [(diameter: CGFloat, lineWidth: CGFloat)] {
        let outer: CGFloat = quiet ? 14 : 18
        if count > 2 {
            return [(outer, quiet ? 2 : 2.5), (quiet ? 9.5 : 12.5, quiet ? 1.5 : 2), (quiet ? 5 : 7, quiet ? 1.25 : 1.5)]
        }
        return [(outer, quiet ? 2 : 2.5), (quiet ? 8 : 10, quiet ? 1.5 : 2)]
    }

    /// Where the assistant's symbol goes: in the middle of the nest when the innermost ring leaves a hole a glyph
    /// can be read in, and otherwise beside the nest, never over it. Anywhere over the rings would hide an arc's
    /// end or the pace cap for the windows whose fill has reached it, and those are the shape channel for on track,
    /// behind and nearly gone. The place is fixed by the number of rings alone, worked out on the quiet nest (the
    /// smaller hole), so the symbol does not jump as the strip goes quiet or wakes: it is a mark learnt by where it
    /// is as much as by its shape. One ring holds it in the middle; two leave a hole under six points and three a
    /// dot's worth, so they carry it beside.
    enum Glyph: Equatable {
        case centre(CGFloat)
        case beside(CGFloat)
    }

    /// The smallest glyph worth drawing in the middle; below it the symbol goes beside the nest.
    static let smallestCentreGlyph: CGFloat = 6
    /// The symbol's size beside the nest, and the gap between them.
    static let besideGlyph: CGFloat = 8
    static let besideGap: CGFloat = 2

    static func glyph(rings: Int) -> Glyph {
        let nest = nest(count: rings, quiet: true)
        let innermost = nest[max(0, min(rings, nest.count) - 1)]
        let hole = innermost.diameter - innermost.lineWidth - 1
        return hole >= smallestCentreGlyph ? .centre(min(hole, 9)) : .beside(besideGlyph)
    }

    /// The width the readout takes: the 18 pt box, and the symbol beside it when that is where it goes.
    static func width(rings: Int, symbol: Bool) -> CGFloat {
        guard symbol, case .beside(let size) = glyph(rings: rings) else { return side }
        return side + besideGap + size + 2
    }

    var body: some View {
        let quiet = presence == .quiet
        let nest = Self.nest(count: windows.count, quiet: quiet)
        let painted = signalColours ? signal : nil
        ZStack {
            ZStack {
                if presence == .hidden {
                    // A 4 pt dot has no room for a mark, so colour would be the only channel left to it. The branch
                    // is unreachable while a signal holds — a wait makes the presence urgent, which `Presence.hides`
                    // never collapses, and every hook event sets the wake that keeps the rings up for five minutes,
                    // which outlasts the ninety-second hold — so the dot keeps the tool's own colour and the rule
                    // that hue never carries a meaning alone is never put to the test here.
                    Circle().fill(tool.color.opacity(0.8)).frame(width: 4, height: 4)
                } else {
                    RingView(fraction: windows.first?.usedFraction, color: tool.color, lineWidth: nest[0].lineWidth,
                             pace: windows.first.flatMap { Pace.status(for: $0) }, signal: painted)
                        .frame(width: nest[0].diameter, height: nest[0].diameter)
                    ForEach(Array(zip(windows, nest).dropFirst().enumerated()), id: \.offset) { offset, pair in
                        RingView(fraction: pair.0.usedFraction, color: tool.ringColor(at: offset + 1), lineWidth: pair.1.lineWidth,
                                 pace: Pace.status(for: pair.0), signal: painted)
                            .frame(width: pair.1.diameter, height: pair.1.diameter)
                    }
                    if let contextUsed {
                        ContextArc(fraction: contextUsed, diameter: quiet ? 18 : 22)
                    }
                    if status.problem != nil {
                        ProblemMark()
                    }
                    if symbol, status.problem == nil, case .centre(let size) = Self.glyph(rings: windows.count) {
                        ToolGlyph(tool: tool, size: size)
                    }
                }
            }
            .opacity(presence.readoutOpacity)
            if presence != .hidden, let signal {
                SignalMark(signal: signal).offset(SignalMark.cornerOffset(of: signal, in: Self.side))
            }
        }
        .frame(width: Self.side, height: Self.side)
        .overlay(alignment: .leading) {
            // Beside the nest, in room of its own the fit measures (`width`), so it covers no arc and no cap. Kept,
            // invisible, while the rings are a dot, so the strip's width does not move with the presence.
            if symbol, case .beside(let size) = Self.glyph(rings: windows.count) {
                ToolGlyph(tool: tool, size: size)
                    .opacity(presence == .hidden ? 0 : presence.readoutOpacity)
                    .offset(x: Self.side + Self.besideGap)
            }
        }
        .frame(width: Self.width(rings: windows.count, symbol: symbol), height: Self.side, alignment: .leading)
        .opacity(status.reading == nil && status.problem == nil ? 0.5 : 1)
        .animation(AccessibilityDisplay.shared.motionReduced ? nil : .snappy(duration: 0.4), value: presence)
    }
}

/// An assistant's symbol (ToolID.symbolName, the one on its card) at ring size. White, for the reason the signal
/// marks are: it has to read on any of the identity colours and on the black notch, and the shape is the point
/// of it. It never sits over a ring, so it needs no backing to keep an arc out of its outline.
private struct ToolGlyph: View {
    let tool: ToolID
    let size: CGFloat

    var body: some View {
        Image(systemName: tool.symbolName)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size + 2, height: size + 2)
            .accessibilityHidden(true)
    }
}

/// The digits beside a ring, or in its place (CompactStyle): 11 pt semibold rounded, monospaced, in the tool's
/// colour until a window is on track or behind, when that window's figure takes the status colour. With no ring
/// to carry them, the problem mark and the signal mark sit beside the digits. The size is fixed: the digits must
/// fit beside the notch whatever the text size setting.
///
/// A signal never takes the digits. Someone who chose figures over rings chose the figures' own meaning, and a
/// number that turned blue for a permission prompt would read as a claim about that number rather than about the
/// session; the mark on the corner of them carries the state instead, as it has for a wait since the hook shipped.
///
/// The mark is an overlay on the corner of the digits rather than another item in the row, because an item in the
/// row costs width: the digits measured 53 pt plain and 65 pt with a tick, and `CompactStripProbe` measures this
/// view to fit the strip, so the fit would have depended on what time it was. Drawn on the corner it costs nothing,
/// and it is applied after the quiet dimming so it stays legible at 70 % digits, for the reason CompactRings gives.
struct CompactNumbers: View {
    let tool: ToolID
    let status: ToolStatus
    var windows: [LimitWindow] = []
    let display: UsageDisplay
    /// At Auto's outer-figure rung (CompactFit.Figures) the row is one figure, the outer ring's, with no dot after
    /// it and no countdown.
    var figures: CompactFit.Figures = .all
    var countdown = false
    var badges = false
    var signal: ToolSignal? = nil
    var presence: PresenceLevel = .legible
    /// Whether the quiet level dims the digits as it dims the rings. The primary figure beside plain rings
    /// (Preferences.compactPrimary) keeps full opacity: the rings say quiet, the number stays readable.
    var quietDims = true
    /// One figure a line, for the side edges. A notch is a shallow shape — the hardware one is 185 across and 38
    /// deep — and the depth of a side notch is set by nothing but the width of the widest thing in it. Laid out
    /// the way the top strip lays them out, "100% · 50%" made the shape 76 points deep against a 181 point run:
    /// a ratio of 0.42 where the notch it imitates is 0.17, which is what made it read as a slab bolted to the
    /// edge rather than a piece taken out of the screen. Stacked, and a point and a half smaller because two
    /// lines have to fit where one did, the same two figures take about 26 points across instead of 62 and the
    /// shape comes back to a notch's proportions without losing a number.
    var stacked = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: countdown ? 60 : 3600)) { context in
            let segments = CompactLabel.segments(for: windows, display: display, figures: figures, countdown: countdown, now: context.date)
            let figures = ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                if index > 0, !stacked {
                    Text(verbatim: CompactLabel.separator).foregroundStyle(.secondary)
                }
                Text(verbatim: segment.text)
                    .foregroundStyle(color(for: segment))
                    .contentTransition(AccessibilityDisplay.shared.motionReduced ? .identity : .numericText())
            }
            Group {
                if stacked {
                    // No separator between them: the line break is the separator, and a dot on its own line reads
                    // as a bullet rather than as the join it is.
                    VStack(alignment: .center, spacing: 0) { figures }
                } else {
                    HStack(spacing: 3) {
                        if badges, status.problem != nil {
                            ProblemMark()
                        }
                        figures
                    }
                }
            }
            .font(.system(size: stacked ? 9.5 : 11, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .opacity(quietDims ? presence.readoutOpacity : 1)
            .overlay(alignment: .topTrailing) {
                if badges, let signal {
                    SignalMark(signal: signal).offset(x: 4, y: -4)
                }
            }
            .opacity(status.reading == nil && status.problem == nil ? 0.5 : 1)
            .animation(AccessibilityDisplay.shared.motionReduced ? nil : .snappy(duration: 0.4), value: segments)
        }
    }

    private func color(for segment: CompactLabel.Segment) -> Color {
        switch segment.pace {
        case .onTrack: Palette.warn
        case .behind: Palette.danger
        case .ahead, nil: tool.color
        }
    }
}

extension PresenceLevel {
    /// How far a readout dims at this level. The quiet level drops to 70 %, which with the smaller rings is the
    /// whole of what quiet means; Increase Contrast keeps it at full, because a reader who asked for contrast did
    /// not ask for a calm readout they cannot see. It is a level's own property rather than a line repeated in
    /// four view bodies so that the one subtree that must not take it — the signal mark — is a visible exception
    /// rather than an omission someone puts back by tidying.
    @MainActor var readoutOpacity: Double {
        self == .quiet && !AccessibilityDisplay.shared.contrast ? 0.7 : 1
    }
}

private struct ProblemMark: View {
    var body: some View {
        Image(systemName: "exclamationmark")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(Palette.warn)
    }
}

/// The mark beside the rings, and beside the digits where there is no ring. Both marks are a white disc with a 1 pt
/// black stroke, which is what keeps them legible over a tool colour, over Liquid Glass and over the black notch
/// alike; the shape inside is what tells the two states apart, so nothing here rests on the ring's hue and the
/// distinction survives the colouring being turned off.
private struct SignalMark: View {
    /// The black ring both marks carry. `Circle().stroke` is centred on the path, so a 1 pt stroke adds half a
    /// point outside the disc on every side and a mark covers its disc plus one whole point.
    static let strokeWidth: CGFloat = 1

    let signal: ToolSignal

    /// What this mark actually covers, the stroke included. It is not one number: a single waiting session draws
    /// a 5 pt disc and everything else — a counted wait, a finished turn — draws a 9 pt one.
    static func drawnDiameter(of signal: ToolSignal) -> CGFloat {
        let disc: CGFloat
        switch signal {
        case .waiting(let count): disc = WaitingDot.diameter(count: count)
        case .finished: disc = FinishedTick.diameter
        }
        return disc + strokeWidth
    }

    /// Where to put the mark's centre so that, drawn on the top-right corner of a square frame `side` points
    /// across, none of it falls outside that frame.
    ///
    /// This was a pair of literals — seven points out and seven up — carried over from when the only mark on the
    /// strip was the 5 pt disc a single waiting session draws, and it was never right for any mark. Seven out of a
    /// centre at (9, 9) puts a mark's centre at (16, 2). Counted the way the property above counts, disc plus the
    /// whole point its stroke adds, that leaves the 5 pt disc one point over the top edge and one over the right,
    /// and a 9 pt one — a finished turn, or a two-session wait — three points over each.
    ///
    /// The 18 pt frame does not itself do the cutting: a SwiftUI `.frame` measures and does not clip, and there is
    /// no clip anywhere in this file. What the frame does is tell every container upstream that the readout is
    /// 18 pt wide, so a mark hanging past that edge is at the mercy of whatever the strip is drawn inside. That is
    /// how the tick came to render 16 px across and only 12 tall — the full width of an unclipped disc, cut flat
    /// along the top by the notch bar it overflowed. An inset worked from the mark's own drawn diameter is right
    /// at every size and cannot go stale the next time a mark changes size, which is how one pair of numbers came
    /// to be wrong for every mark it covered.
    static func cornerOffset(of signal: ToolSignal, in side: CGFloat) -> CGSize {
        let inset = (side - drawnDiameter(of: signal)) / 2
        return CGSize(width: inset, height: -inset)
    }

    var body: some View {
        switch signal {
        case .waiting(let count): WaitingDot(count: count)
        case .finished: FinishedTick()
        }
    }
}

/// The same 9 pt disc the waiting count uses, with a tick where the digit would be. At this size a tick is the only
/// shape anyone reads as "done" without being told, and borrowing the counted dot's chassis means it takes no more
/// room than a two-session wait already does — which is what keeps a state change out of the compact strip's width
/// wherever a mark was drawn before it.
private struct FinishedTick: View {
    static let diameter: CGFloat = 9

    var body: some View {
        ZStack {
            Circle()
                .fill(.white)
                .frame(width: Self.diameter, height: Self.diameter)
                .overlay(Circle().stroke(.black, lineWidth: 1))
            Image(systemName: "checkmark")
                .font(.system(size: 5.5, weight: .heavy))
                .foregroundStyle(.black)
        }
    }
}

/// The white disc a waiting session has always drawn, with the count in it past one. Untouched by the state
/// colours: it is the app's only non-colour carrier of a wait, and white on a black stroke is the one treatment
/// that survives any base colour underneath it.
private struct WaitingDot: View {
    /// A bare wait is a 5 pt dot; a counted one grows to 9 so a digit fits inside it.
    static func diameter(count: Int) -> CGFloat { count > 1 ? 9 : 5 }

    var count = 1

    var body: some View {
        ZStack {
            Circle()
                .fill(.white)
                .frame(width: Self.diameter(count: count), height: Self.diameter(count: count))
                .overlay(Circle().stroke(.black, lineWidth: 1))
            if count > 1 {
                Text(verbatim: "\(min(count, 9))")
                    .font(.system(size: 6, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
            }
        }
    }
}

/// One tool while the panel is closed, in the style the user chose. The presence level sets how loud it is
/// (Presence.swift): 70 % opacity when quiet, full when legible, three 1.5 s opacity pulses on becoming urgent and
/// then steady, because a SwiftUI animation that never ends re-renders the readout every frame (measured at 5–9 % of
/// a core while a ring pulsed); no pulse under Reduce Motion. While the screen is shared and the privacy setting is
/// on, the digits are withheld.
/// VoiceOver reads the tool and every window's figure and pace, whatever is drawn — including at Auto's
/// outer-figure rung, where the screen shows one of them.
///
/// The quiet dimming is applied by each part rather than here, over the rings and over the digits but never over
/// the mark beside them. A parent's `.opacity` composites everything under it, so a mark drawn inside this view's
/// dimming could not be exempted from it, and a mark at 70 % on a 14 pt ring is not something anyone reads in
/// passing. Lifting the whole readout instead was tried and reverted: presence is what the calm rule says about
/// limits, and a state that lifted it put a ninety-second clock into that rule and into the view the compact fit
/// is measured from, to buy a legibility the exempted mark already gives for nothing (CompactRings).
struct CompactReadout: View {
    let tool: ToolID
    let status: ToolStatus
    let style: CompactStyle
    /// How much of each readout's digits the fit in force keeps (CompactFit.Figures); only a style with numbers
    /// beside a ring has any to thin.
    var figures: CompactFit.Figures = .all
    let display: UsageDisplay
    var windows: [LimitWindow] = []
    /// What the assistant is asking of the user (ToolSignal): the rings' colour, the mark and what VoiceOver reads
    /// first all come from this one value, so none of the three can disagree with another.
    var signal: ToolSignal? = nil
    /// Whether the rings take the colour, or only the mark carries it (Preferences.signalRings).
    var signalColours = true
    var contextUsed: Double? = nil
    var countdown = false
    /// The outer window's figure beside plain rings (Preferences.compactPrimary); nothing at the other styles,
    /// which draw their digits anyway.
    var primary = false
    var hideFigures = false
    var presence: PresenceLevel = .legible
    var axis: Axis = .horizontal
    /// Claude Code on an API key: no rings to draw; the month's cost stands in for the digits when they are shown.
    var apiKeyCost: String? = nil
    /// The assistant's symbol with its rings (Preferences.ringSymbols).
    var ringSymbol = false
    @State private var pulsing = false
    @State private var pulseTask: Task<Void, Never>?
    static let pulseCycles = 3
    static let pulseDuration = 1.5

    var body: some View {
        let reduceMotion = AccessibilityDisplay.shared.motionReduced
        Group {
            if axis == .vertical {
                VStack(spacing: 2) { parts }
            } else {
                HStack(spacing: 5) { parts }
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.4), value: presence)
        .opacity(pulsing ? 0.4 : 1)
        .animation(pulsing ? .easeInOut(duration: Self.pulseDuration).repeatCount(Self.pulseCycles * 2 - 1, autoreverses: true) : .easeInOut(duration: 0.3), value: pulsing)
        .onChange(of: presence, initial: true) { updatePulse() }
        .onChange(of: reduceMotion) { updatePulse() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tool.displayName)
        .accessibilityValue(Spoken.status(status, signal: signal))
    }

    @ViewBuilder private var parts: some View {
        let drawn = CompactLabel.figures(style: style, primary: primary, fit: figures)
        let showNumbers = drawn != nil && !hideFigures && presence != .hidden
        if let apiKeyCost {
            if showNumbers {
                // Claude Code on an API key draws no ring, which left the assistant whose hook reports the most of
                // these events as the one with nowhere to report them. The mark goes on the corner of the figure,
                // where CompactRings puts it on the corner of the nest, rather than in a slot beside it: a slot
                // took 12 pt of strip width that came and went with the ninety-second hold, and the fit is
                // measured from what is drawn. It reaches the two styles that draw digits and no further: at plain
                // rings `compactTools(style:)` leaves this readout out of the strip altogether, and while the
                // screen is shared there are no digits to sit beside.
                Text(verbatim: apiKeyCost)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tool.color)
                    .opacity(presence.readoutOpacity)
                    .overlay(alignment: .topTrailing) {
                        if let signal {
                            SignalMark(signal: signal).offset(x: 4, y: -4)
                        }
                    }
            }
        } else {
            if style.showsRings || hideFigures || presence == .hidden {
                CompactRings(tool: tool, status: status, windows: windows, signal: signal, signalColours: signalColours,
                             contextUsed: contextUsed, presence: presence, symbol: ringSymbol)
            }
            if showNumbers {
                CompactNumbers(tool: tool, status: status, windows: windows, display: display, figures: drawn ?? .all, countdown: countdown,
                               badges: !style.showsRings, signal: signal, presence: presence, quietDims: style.showsNumbers, stacked: axis == .vertical)
            }
        }
    }

    private func updatePulse() {
        pulseTask?.cancel()
        let urgent = presence == .urgent && !AccessibilityDisplay.shared.motionReduced
        pulsing = urgent
        guard urgent else { return }
        pulseTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Double(Self.pulseCycles * 2 - 1) * Self.pulseDuration))
            guard !Task.isCancelled else { return }
            pulsing = false
        }
    }
}

private extension UsageStore {
    /// One readout for the notch strip and for an edge pill both; they share this call site, so a fix here is a fix
    /// in both places at once. The waiting count used to be handed over as `tool == .claude ? waitingCount : 0`; it
    /// is now `signal(tool)`, which answers for every assistant with no tool named anywhere above `SessionTracker`.
    /// The context arc keeps its own ternary: that figure comes from Claude Code's status line rather than from a
    /// hook, which is a different fact with a different reason to be Claude-only, and collapsing the two would hide
    /// that.
    func readout(_ tool: ToolID, presence: PresenceLevel, axis: Axis = .horizontal, style: CompactStyle,
                 figures: CompactFit.Figures = .all) -> CompactReadout {
        let status = status(tool)
        let apiKeyCost = tool == .claude && claudeOnAPIKey ? Money.dollars(cost?.totals(.month).cost ?? 0, cents: false) : nil
        return CompactReadout(tool: tool, status: status, style: style, figures: figures, display: prefs.usageDisplay,
                              windows: status.reading.map(prefs.ringWindows) ?? [], signal: signal(tool), signalColours: prefs.signalRings,
                              contextUsed: tool == .claude ? contextUsed : nil, countdown: prefs.showResetCountdown, primary: prefs.compactPrimary,
                              hideFigures: hidesFigures, presence: presence, axis: axis, apiKeyCost: apiKeyCost, ringSymbol: prefs.ringSymbols)
    }

    /// The tools with a compact readout: Claude on an API key has nothing to draw unless a figure is shown, which
    /// the digits styles always do and plain rings do while the primary figure is on.
    func compactTools(style: CompactStyle) -> [ToolID] {
        visibleTools.filter { !($0 == .claude && claudeOnAPIKey && CompactLabel.figures(style: style, primary: prefs.compactPrimary) == nil) }
    }
}

/// The tools the fit could not keep, drawn after the last readout as a quiet "+2".
private struct CompactOverflow: View {
    let count: Int
    let presence: PresenceLevel

    var body: some View {
        Text(L("+%ld", count))
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .opacity(presence.readoutOpacity)
            .accessibilityLabel(L("%ld more", count))
    }
}

/// The readouts beside the physical notch: the first visible tool on its left, the rest on its right
/// (Preferences.toolOrder). NotchController measures this view to place the hover region, so its width follows
/// the style. The strip refers to the physical notch, so it is laid out left to right in every language.
struct NotchCompactView: View {
    enum Side { case leading, trailing }

    let store: UsageStore
    let side: Side
    /// The run to draw, when it is not the one the fit in force asks of this side.
    var run: CompactFit.Run?

    /// What this side of the notch draws: the run it was handed, or this side's half of the fit in force.
    private var drawn: CompactFit.Run {
        if let run { return run }
        let fit = store.prefs.compactFit
        let halves = fit.halves(visible: store.compactTools(style: fit.style).count)
        return side == .leading ? halves.leading : halves.trailing
    }

    /// Opens the panel on the peek's session; nil where the view is only measured.
    var openNews: ((NotchNews) -> Void)? = nil

    /// The news this side names, and how: nil when there is no peek, when it is switched off, when this view was
    /// handed a run to measure (CompactStripProbe asks for readouts, never for a peek), or when the layout gives
    /// this side nothing, in which case it keeps its readouts. `speaks` is whether this side is the one VoiceOver
    /// meets: the side holding the reason, so a peek split across the notch is one button, not two alike.
    private var peek: (news: NotchNews, words: NotchNews.Words, parts: [NotchPeek.Part], room: CGFloat, speaks: Bool)? {
        guard run == nil, store.prefs.notchNews, let news = store.peek else { return nil }
        let words = news.words(hidesFigures: store.hidesFigures, title: store.peekTitle(news))
        guard let layout = NotchPeekHalf.layout(words: words, room: store.prefs.peekRoom) else { return nil }
        let parts = side == .leading ? layout.leading : layout.trailing
        guard !parts.isEmpty else { return nil }
        return (news, words, parts, side == .leading ? layout.leadingWidth : layout.trailingWidth, NotchPeek.speaks(parts))
    }

    /// The peek's motion: in over 250 ms easing out, away over 180 ms easing in, the quicker exit so the readouts
    /// it displaced are back without a wait. It is only a crossfade (the shape's width follows at once under
    /// Reduce Motion, DynamicNotch.reduceMotion), so Reduce Motion keeps it.
    static func peekAnimation(appearing: Bool) -> Animation {
        appearing ? .easeOut(duration: 0.25) : .easeIn(duration: 0.18)
    }

    var body: some View {
        ZStack {
            if let peek {
                if peek.speaks {
                    NotchPeekHalf(news: peek.news, words: peek.words, parts: peek.parts, room: peek.room, side: side)
                        .transition(.opacity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(peek.words.spoken)
                        .accessibilityHint(L("Opens the panel on this session"))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { openNews?(peek.news) }
                } else {
                    NotchPeekHalf(news: peek.news, words: peek.words, parts: peek.parts, room: peek.room, side: side)
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }
            } else {
                readouts.transition(.opacity)
            }
        }
        .animation(Self.peekAnimation(appearing: store.peek != nil), value: store.peek)
    }

    private var readouts: some View {
        let presence = store.presence
        let run = drawn
        let visible = store.compactTools(style: run.style)
        // Clamped because the store can lose a tool between the fit being resolved and this being drawn.
        let tools = Array(visible[run.readouts.clamped(to: 0 ..< visible.count)])
        return HStack(spacing: run.style.showsNumbers ? 9 : 7) {
            ForEach(tools, id: \.self) { tool in
                store.readout(tool, presence: presence, style: run.style, figures: run.figures)
            }
            if run.overflow > 0 {
                CompactOverflow(count: run.overflow, presence: presence)
            }
        }
        .padding(.horizontal, tools.isEmpty && run.overflow == 0 ? 0 : 6)
        .environment(\.layoutDirection, .leftToRight)
    }
}

/// The readouts inside the pill that sits on a screen edge (Codenotch-style layouts); EdgePanelRoot draws the
/// pill. A side pill stacks each tool's digits under its ring; the top and bottom bars run them side by side.
struct EdgeCompactView: View {
    let store: UsageStore
    let edge: PanelEdge

    var body: some View {
        let style = store.prefs.compactStyle
        let tools = store.compactTools(style: style)
        let presence = store.presence
        let horizontal = edge == .bottom || edge == .top
        let readouts = ForEach(tools, id: \.self) { tool in
            store.readout(tool, presence: presence, axis: horizontal ? .horizontal : .vertical, style: style)
        }
        Group {
            if horizontal {
                HStack(spacing: 10) { readouts }.padding(.horizontal, 12).padding(.vertical, 7)
            } else {
                VStack(spacing: 6) { readouts }.padding(.vertical, 8).padding(.horizontal, 6)
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AppInfo.name)
        .accessibilityValue(tools.map { "\($0.displayName): \(Spoken.status(store.status($0), signal: store.signal($0)))" }.joined(separator: ". "))
    }
}

// MARK: - Expanded panel

private struct PanelContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// What leads the panel: which session's request card is drawn when several hold one, and whether the attention
/// card outranks it. Normally the newest request, and the attention card only with no request on the panel. A panel
/// opened from the news peek names its session (UsageStore.promptFocus): that session's request is drawn in place
/// of the newest, and that session's own card stands in front of another session's request. Pure, so it is tested
/// without a panel.
enum PanelLead {
    /// The index into `pendingSessions` (newest first) of the request to draw, or nil for none.
    static func request(pendingSessions: [String], focus: String?) -> Int? {
        guard !pendingSessions.isEmpty else { return nil }
        return focus.flatMap { pendingSessions.firstIndex(of: $0) } ?? 0
    }

    /// Whether the attention card is drawn alone, with the link to the rest.
    static func noticeLeads(notice: String?, pendingSessions: [String], promptOnly: Bool, focus: String?) -> Bool {
        guard let notice, !promptOnly else { return false }
        return pendingSessions.isEmpty || notice == focus
    }
}

/// The panel's content, never taller than the screen's usable height: past that it scrolls, with no scroller and
/// no bounce while it fits. The cap is read from the screen at each layout unless `maxHeight` overrides it.
struct NotchExpandedView: View {
    let store: UsageStore
    let prefs: Preferences
    let actions: NotchActions
    var maxHeight: CGFloat? = nil
    var screen: NSScreen? = nil
    /// Measures the content at its natural height, so the sizing self-check reads what the panel wants
    /// rather than what the cap already forced on it.
    var unclamped = false
    /// Whether the parts stagger in as the panel opens (PanelMotion). Only the panels on screen ask for it; every
    /// other build of this view — the sizing probes, the renders, "Copy as image" — draws the parts where they rest.
    var entrance = false
    /// Drawn in the card an edge layout opens, rather than under the notch: the two keep different materials until
    /// one is chosen (`PanelMaterial.unchosen`), and the material moves the colours (PanelLook).
    var edgeCard = false
    @State private var contentHeight: CGFloat = 0
    /// Set as the live panel appears, which is what starts the stagger.
    @State private var appeared = false
    /// Whether the Sessions card leads (PanelLayout.sessionsLead), as it was when this opening appeared. The order
    /// is decided once per opening: a session starting or ending a turn while the panel is open would otherwise
    /// move the Sessions card above or below Cost under the reader's eye. The next opening reads it afresh.
    @State private var openedWithSessionsLead: Bool?

    static let screenMargin: CGFloat = 24
    /// The room the content keeps above its first card.
    static let contentTopPadding: CGFloat = 8
    /// The margin either side of the cards. `panelWidth - 2 * this` is the column every card has to fit
    /// (ExpandedPanelWidth); a card wider than it is drawn past the panel's edge and clipped by the notch shape.
    static let contentHorizontalPadding: CGFloat = 14

    /// The room between the top of the scrolled content and the panel's first line: this padding and the header
    /// bar's (PanelHeader). A reading of where the panel opens counts from that line, which is what has to clear
    /// the notch (PanelScroll). Until the header came in, the first line was the Cost card's title, a card's
    /// padding further down; a panel opened on a request alone still starts there, deeper than this, so the check
    /// errs on the side of the notch.
    static func titleInset(density: Density) -> CGFloat { contentTopPadding + PanelHeader.topPadding(density: density) }

    /// Room for the content: the screen's usable height less a margin above the Dock. `visibleFrame` already
    /// excludes the menu bar the notch sits in, so the notch height is not subtracted a second time.
    static func maxHeight(visibleHeight: CGFloat, notchHeight: CGFloat) -> CGFloat {
        max(0, visibleHeight - screenMargin)
    }

    static func maxHeight(on screen: NSScreen) -> CGFloat {
        maxHeight(visibleHeight: screen.visibleFrame.height, notchHeight: NotchController.notchRect(on: screen).height)
    }

    /// What a measurement of the open panel means. The content is drawn inside a scroll view capped at
    /// `maxHeight`, so content taller than the cap is the design working, not a fault; the fault is a panel drawn
    /// taller than the room it has.
    enum Fit: String {
        case fits
        case scrolls
        case clipped

        /// `drawn` is the panel as it is laid out (capped), `natural` the same content with no cap on it.
        static func of(drawn: CGFloat, natural: CGFloat, room: CGFloat, cap: CGFloat, tolerance: CGFloat = 0.5) -> Fit {
            if drawn > min(room, cap) + tolerance { return .clipped }
            return natural > cap + tolerance ? .scrolls : .fits
        }

        var holds: Bool { self != .clipped }
    }

    var body: some View {
        let cap = maxHeight ?? Self.maxHeight(on: screen ?? .panelScreen)
        let overflows = contentHeight > cap + 0.5
        return Group {
            if unclamped {
                content
            } else {
                ScrollView(.vertical) {
                    content
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: PanelContentHeight.self, value: proxy.size.height)
                        })
                }
                // The scroll view paints its own light backing, which would show through the notch's black
                // on the first frame; the panel draws the background itself.
                .scrollContentBackground(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.never)
                // Nothing pins the offset: the scroll view is destroyed when the panel closes and rebuilt on the
                // next open, so it already starts at the header. An anchor here would fight a real scroll.
                .scrollDisabled(!overflows)
                .frame(maxHeight: cap)
                .onPreferenceChange(PanelContentHeight.self) { contentHeight = $0 }
            }
        }
        // The look is resolved here, at the root every build of the panel shares — the live panel, its probes,
        // "Copy as image" and the renders — so all of them draw the same colours (PanelLook). Paper's sheet is the
        // panel's own ground inside the black the notch or the card draws round it; the black panel draws none.
        .modifier(PaperSheet(look: look))
        .modifier(PanelInkEnvironment(look: look))
        .environment(\.density, prefs.density)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    /// The look this panel is drawn in, for its layout.
    var look: PanelLook { PanelLook.current(prefs, edgeCard: edgeCard) }

    /// The Cost card at the top of the panel, or nil while there is nothing to price: spend hidden, figures hidden
    /// for a capture, or no carried tool that can report a cost. Built with no range, so it shows the store's
    /// (`UsageStore.spendRange`): the panel on screen sets it, and the panel rebuilt for "Copy as image"
    /// (App.swift, copyPanelImage) reads the same value, which is what makes the pasted PNG match the panel.
    /// Until 0.6.0 that rebuilt panel's card opened on Today. Exposed so CostCardCopyImage can check the card the
    /// panel builds without rendering it.
    var spendCard: SpendCard? {
        let tools = store.visibleTools
        guard prefs.showSpend, !store.hidesFigures, tools.contains(where: { $0.reportsCost && prefs.costCardTools.contains($0) }) else { return nil }
        return SpendCard(store: store)
    }

    /// The whole panel's parts, top to bottom, for what the store holds now (PanelLayout.parts), with the Sessions
    /// card's place held where this opening found it. Exposed so the oracle can report the order the reader is
    /// looking at, and a test can check it, without drawing the panel.
    var parts: [PanelPart] {
        let tools = store.visibleTools
        if simple {
            return PanelLayout.simpleParts(prompt: !store.sessions.pending(now: Date()).isEmpty, spend: spendCard != nil,
                                           notes: !(placedAdvice[.notes] ?? []).isEmpty, sessions: showsSessions,
                                           connect: tools.isEmpty, tools: tools, addTool: !store.hiddenEmptyTools.isEmpty)
        }
        return PanelLayout.parts(prompt: !store.sessions.pending(now: Date()).isEmpty, spend: spendCard != nil,
                                 advice: !store.advice.isEmpty,
                                 // With a hook installed the card stays when nothing is running, saying so in one
                                 // line, so an empty list is not mistaken for a setup that never worked
                                 // (UsageStore.hooksInstalled).
                                 sessions: showsSessions,
                                 sessionsLead: openedWithSessionsLead ?? PanelLayout.sessionsLead(store.sessions.all),
                                 connect: tools.isEmpty, tools: tools, addTool: !store.hiddenEmptyTools.isEmpty)
    }

    /// Whether the Sessions card, or on the Simple panel the Sessions section, is on the panel.
    private var showsSessions: Bool { prefs.sessionsCard && (store.sessions.count > 0 || store.hooksInstalled) }

    /// Whether this is the Simple panel (PanelMode, SimplePanel.swift) rather than the Detailed one.
    var simple: Bool { prefs.panelMode == .simple }

    /// The Simple panel's advice, each line on the row it is about (AdvicePlacement), for the rows this panel has.
    var placedAdvice: [AdvicePlacement.Slot: [Advice]] {
        AdvicePlacement.assign(store.advice, tools: store.visibleTools, cost: spendCard != nil, sessions: showsSessions)
    }

    /// What the panel draws right now: the one card of a prompt-only or notice-only opening, else every part.
    var shownParts: [PanelPart] {
        if store.panelOpenedForPrompt { return store.sessions.pending(now: Date()).isEmpty ? [] : [.prompt] }
        let pendingSessions = store.sessions.pending(now: Date()).map(\.session.id)
        if PanelLead.noticeLeads(notice: store.attentionNotice?.session.id, pendingSessions: pendingSessions,
                                 promptOnly: false, focus: store.promptFocus) { return [.notice] }
        return parts
    }

    /// Whether the parts are drawn where they rest: always, except on the live panel before it has appeared.
    private var arrived: Bool { appeared || !entrance || AccessibilityDisplay.shared.motionReduced }

    private var content: some View {
        let pending = store.sessions.pending(now: Date())
        let pendingSessions = pending.map(\.session.id)
        let promptOnly = store.panelOpenedForPrompt
        let noticeLeads = PanelLead.noticeLeads(notice: store.attentionNotice?.session.id, pendingSessions: pendingSessions,
                                                promptOnly: promptOnly, focus: store.promptFocus)
        let lead = noticeLeads ? nil : PanelLead.request(pendingSessions: pendingSessions, focus: store.promptFocus).map { pending[$0] }
        let arrived = self.arrived
        let simple = self.simple
        let placed = simple ? placedAdvice : [:]
        return VStack(alignment: .leading, spacing: simple ? 0 : prefs.density.cardSpacing) {
            // A request the assistant is holding a session for outranks the cost and the advice: it is the one
            // thing on the panel that is waiting on the reader. Only one is drawn, the newest unless the peek opened
            // the panel on another (PanelLead); the rest queue behind it. A panel the request itself opened carries
            // the card and nothing else (UsageStore.panelOpenedForPrompt), with one link to the rest; a panel already
            // open takes the card under its header and above every other card (PanelLayout.parts).
            if promptOnly, let newest = lead {
                PromptCard(session: newest.session, request: newest.request, hideFigures: store.hidesFigures,
                           decide: { store.decide($0, $1) },
                           unfolded: store.unfoldedSuggestions.contains(newest.request.id),
                           setUnfolded: { store.unfoldSuggestions(newest.request.id, $0) })
                    .modifier(PanelEntranceStep(index: 0, arrived: arrived))
                Button { store.panelOpenedForPrompt = false } label: {
                    Text(L("Show the whole panel")).font(.caption).foregroundStyle(Ink.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, prefs.density.cardPadding)
                .modifier(PanelEntranceStep(index: 1, arrived: arrived))
            }
            // A card the attention setting opened (SessionAttention.glance) is drawn the same way, alone with the one
            // link, unless a request is on the panel, which outranks it; a card the peek opened on its own session
            // outranks another session's request (PanelLead).
            if noticeLeads, let notice = store.attentionNotice {
                NoticeCard(notice: notice, hideFigures: store.hidesFigures, hideTitle: !prefs.sessionTitles,
                           canJump: NoticeCard.canJump(notice.session, enabled: prefs.jumpToTerminal),
                           jump: { actions.jump(notice.session) })
                    .modifier(PanelEntranceStep(index: 0, arrived: arrived))
                Button { store.attentionNotice = nil } label: {
                    Text(L("Show the whole panel")).font(.caption).foregroundStyle(Ink.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, prefs.density.cardPadding)
                .modifier(PanelEntranceStep(index: 1, arrived: arrived))
            }
            if promptOnly || noticeLeads {
                // The request has just ended and the panel is on its way closed: nothing else appears for the frame.
                EmptyView()
            } else {
                let parts = self.parts
                ForEach(Array(parts.enumerated()), id: \.element) { index, part in
                    VStack(alignment: .leading, spacing: 0) {
                        if simple {
                            simpleBreak(PanelLayout.simpleBreak(before: part, after: index > 0 ? parts[index - 1] : nil))
                            simplePart(part, lead: lead, placed: placed)
                        } else {
                            self.part(part, lead: lead)
                        }
                    }
                    .modifier(PanelEntranceStep(index: index, arrived: arrived))
                }
            }
        }
        .padding(.horizontal, Self.contentHorizontalPadding)
        .padding(.top, Self.contentTopPadding)
        .padding(.bottom, 10)
        .frame(width: prefs.panelWidth.points, alignment: .leading)
        // The live panel is built fresh on every open (DynamicNotchKit drops the expanded content when it closes,
        // the edge layouts drop their card), so this runs once per opening: it starts that opening's stagger and
        // holds the Sessions card where the opening put it.
        .onAppear {
            openedWithSessionsLead = PanelLayout.sessionsLead(store.sessions.all)
            if entrance { appeared = true }
        }
    }

    @ViewBuilder
    fileprivate func part(_ part: PanelPart, lead: (session: AgentSession, request: PendingRequest)?) -> some View {
        switch part {
        case .header:
            PanelHeader(sessions: store.sessions.count, actions: actions)
        case .prompt:
            if let newest = lead {
                PromptCard(session: newest.session, request: newest.request, hideFigures: store.hidesFigures,
                           decide: { store.decide($0, $1) },
                           unfolded: store.unfoldedSuggestions.contains(newest.request.id),
                           setUnfolded: { store.unfoldSuggestions(newest.request.id, $0) })
            }
        case .spend:
            if let spendCard { spendCard }
        case .advice:
            AdviceStrip(advice: store.advice, open: actions.open)
        case .sessions:
            SessionsCard(store: store, prefs: prefs, actions: actions)
        case .connect:
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Connect an assistant to get started"))
                    .font(.callout)
                Text(L("Install and sign in to Claude Code, Codex, Cursor, Gemini CLI or GitHub Copilot; its meters appear here."))
                    .modifier(Caption())
            }
            .modifier(CardBackground())
        case .tool(let tool):
            ToolCard(tool: tool, status: store.status(tool), store: store, prefs: prefs, actions: actions)
        case .addTool:
            AddToolRow(hidden: store.hiddenEmptyTools, actions: actions)
        case .footer:
            FooterView(store: store, actions: actions)
        case .notice, .notes:
            // Never laid out among the others (PanelLayout.parts): a notice opening draws its card alone, above.
            // Notes is the Simple panel's alone (simplePart).
            EmptyView()
        }
    }
}

extension NotchExpandedView {
    /// The room, or the room and a hairline, above a part of the Simple panel (PanelLayout.simpleBreak): 12 pt
    /// between sections either side of the rule, 10 pt under the header and the request card.
    @ViewBuilder
    fileprivate func simpleBreak(_ kind: PanelLayout.SimpleBreak) -> some View {
        switch kind {
        case .none: EmptyView()
        case .space: Color.clear.frame(height: 10)
        case .divider:
            SimpleDivider().padding(.vertical, 12)
        }
    }

    /// A part of the Simple panel: the same header, request and "Add a tool" as the Detailed panel, and a row in
    /// place of each card.
    @ViewBuilder
    fileprivate func simplePart(_ part: PanelPart, lead: (session: AgentSession, request: PendingRequest)?,
                                placed: [AdvicePlacement.Slot: [Advice]]) -> some View {
        switch part {
        case .header:
            PanelHeader(sessions: store.sessions.count, actions: actions, refresh: store)
        case .tool(let tool):
            SimpleToolRow(tool: tool, store: store, prefs: prefs, actions: actions, advice: placed[.tool(tool)] ?? [])
        case .spend:
            SimpleCostRow(store: store, actions: actions, advice: placed[.cost] ?? [])
        case .sessions:
            SessionsCard(store: store, prefs: prefs, actions: actions, embedded: true, advice: placed[.sessions] ?? [])
        case .notes:
            SimpleNotesRow(store: store, actions: actions, advice: placed[.notes] ?? [])
        case .connect:
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Connect an assistant to get started"))
                    .font(.body.weight(.semibold))
                Text(L("Install and sign in to Claude Code, Codex, Cursor, Gemini CLI or GitHub Copilot; its meters appear here."))
                    .modifier(Caption())
            }
            .padding(.horizontal, prefs.density.cardPadding)
        case .prompt, .addTool, .footer, .advice, .notice:
            self.part(part, lead: lead)
        }
    }
}

/// One part of the panel arriving (PanelMotion): faint and a few points high until `arrived`, then settling into
/// place at its own delay. `arrived` is true from the start wherever there is no entrance, so nothing but the live
/// panel ever draws a part in its hidden state. The animation is scoped to `arrived`, so a reading that changes a
/// card later is drawn as it always was, not faded in again. An offset moves the drawing and not the layout, so
/// the panel's measured height (PanelSizing) and its scroll position (PanelScroll) never see the stagger.
private struct PanelEntranceStep: ViewModifier {
    let index: Int
    let arrived: Bool

    func body(content: Content) -> some View {
        content
            .opacity(arrived ? 1 : PanelMotion.hiddenOpacity)
            .offset(y: arrived ? 0 : -PanelMotion.rise)
            .animation(AccessibilityDisplay.shared.motionReduced ? nil
                       : .easeOut(duration: PanelMotion.fade).delay(PanelMotion.delay(index: index)), value: arrived)
    }
}

/// The bar above the cards: how many sessions the hooks know about on the left, and on the right the three ways
/// out of the panel — the Usage Dashboard, Settings and the Options menu, whose button sat in the footer until the
/// header came in. Icon buttons, always drawn and never only on hover, each with a VoiceOver label and a tooltip
/// that names its shortcut; the shortcuts themselves live in the main menu (MainMenu), so they work from every
/// window and did not move with the buttons.
///
/// The count is the tracker's whole list, whether or not the Sessions card is on, and nothing at all when it is
/// empty. It carries no title or project, so it stays while the screen is shared.
struct PanelHeader: View {
    let sessions: Int
    let actions: NotchActions
    /// The Simple panel's header carries the refresh line under the count, in place of the footer it does not have.
    var refresh: UsageStore? = nil
    @Environment(\.density) private var density

    /// The room above the bar, inside the content's own top padding. The bar is the panel's first line, so this and
    /// `NotchExpandedView.contentTopPadding` are what hold it clear of the notch (NotchExpandedView.titleInset).
    static func topPadding(density: Density) -> CGFloat { density.lineSpacing }

    /// "3 sessions", or nil when there are none.
    static func count(_ sessions: Int) -> String? {
        switch sessions {
        case ...0: nil
        case 1: L("1 session")
        default: L("%ld sessions", sessions)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                if let count = Self.count(sessions) {
                    Text(count)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Caption.style)
                        .monospacedDigit()
                        .accessibilityAddTraits(.isHeader)
                }
                if let refresh {
                    RefreshLine(store: refresh, actions: actions)
                }
            }
            Spacer(minLength: 8)
            PanelHeaderButton(symbol: "chart.bar.xaxis", label: L("Usage Dashboard"), help: L("Open the Usage Dashboard (⌘U)")) {
                actions.openDashboard()
            }
            PanelHeaderButton(symbol: "gearshape", label: L("Settings"), help: L("Open Settings (⌘,)")) {
                actions.openSettings()
            }
            // The one button that opens a menu rather than a window says so to VoiceOver, since the ellipsis alone
            // does not (the footer's old Options button carried a chevron).
            PanelHeaderButton(symbol: "ellipsis", label: L("Options"), help: L("How the panel opens, its layout, refreshing and quitting"),
                              hint: L("Opens a menu")) {
                actions.showOptions()
            }
        }
        .padding(.horizontal, density.cardPadding)
        .padding(.top, Self.topPadding(density: density))
    }
}

/// One of the header's icon buttons: a 30 × 24 target on a quiet well, so a click lands without aiming at the glyph
/// and the button reads as a button before the pointer is on it. The well is raised under Increase Contrast.
private struct PanelHeaderButton: View {
    let symbol: String
    let label: String
    let help: String
    /// What the button does, for VoiceOver, where the label alone does not say it.
    var hint: String? = nil
    let action: () -> Void

    var body: some View {
        let contrast = AccessibilityDisplay.shared.contrast
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(contrast ? AnyShapeStyle(Ink.primary) : AnyShapeStyle(Ink.secondary))
        }
        .buttonStyle(PanelHeaderButtonStyle(contrast: contrast))
        .help(help)
        .accessibilityLabel(label)
        .accessibilityHint(hint ?? "")
    }
}

/// The header button's well, which answers the pointer: a shade lighter under it and lighter again while pressed,
/// so a click on a panel that never becomes key is seen to land before the window or menu it opens is up. The
/// change is in the fill alone, with no scale, so there is no motion for Reduce Motion to take away, and each state
/// keeps the glyph and its label, so none is told by the shade only.
struct PanelHeaderButtonStyle: ButtonStyle {
    let contrast: Bool

    /// The well's white opacity at rest, under the pointer and pressed; raised throughout under Increase Contrast.
    static func fill(contrast: Bool, hovered: Bool, pressed: Bool) -> Double {
        switch (pressed, hovered) {
        case (true, _): contrast ? 0.28 : 0.16
        case (false, true): contrast ? 0.23 : 0.12
        case (false, false): contrast ? 0.18 : 0.08
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        Well(configuration: configuration, contrast: contrast)
    }

    private struct Well: View {
        let configuration: ButtonStyleConfiguration
        let contrast: Bool
        @State private var hovered = false

        var body: some View {
            configuration.label
                .frame(width: 30, height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Themed.wash(.white, PanelHeaderButtonStyle.fill(contrast: contrast, hovered: hovered, pressed: configuration.isPressed))))
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
        }
    }
}

/// Copies a card or the whole panel to the pasteboard as a 2x PNG with a small wordmark, for Slack or a bug report,
/// in the look the panel is drawn in: a Paper card is pasted on paper. The whole panel draws its own sheet, so it
/// is framed in the notch's black like the panel on screen.
@MainActor
enum CardImage {
    static func copy<Content: View>(_ content: Content, width: CGFloat, look: PanelLook = .standard, wholePanel: Bool = false) {
        // Only Paper differs: the black panel's ground is the notch's black either way.
        let framedInBlack = wholePanel && look.theme == .paper
        let framed = VStack(alignment: .leading, spacing: 8) {
            content
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.33percent").font(.caption2)
                Text(verbatim: AppInfo.name).font(.caption2.weight(.semibold))
            }
            .foregroundStyle(framedInBlack ? AnyShapeStyle(Color.white.opacity(0.6)) : AnyShapeStyle(Ink.secondary)) // panel-ink: on the notch's black frame, outside the sheet
        }
        .padding(12)
        .frame(width: width)
        .background(framedInBlack ? Color.black : look.ground.color)
        .modifier(PanelInkEnvironment(look: look))
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        guard let image = renderer.nsImage else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        Oracle.shared.emit("clipboard", ["kind": "image", "width": Int(image.size.width), "height": Int(image.size.height)])
    }
}

/// A segmented control that fits the width it is offered, which AppKit's own will not.
///
/// `Picker(.segmented)` lays every title out at its full width and reports that sum as its minimum however
/// little it is given, so the card grew to fit the control instead of the control fitting the card: six range
/// titles at the small control size want 432 pt against the 328 pt the Standard panel's text column has, and
/// 408 pt on Wide. Worse, the minimum moves with the selection, because the selected title is the one AppKit
/// will not squeeze -- so the Cost card, and every note under it, jumped ~29 pt to the right and out past the
/// panel's edge the moment the range changed (0.4.1). `.controlSize(.mini)` and shorter English titles each
/// only narrow the gap, and neither survives ja/ko/vi/zh, where "Yesterday" is longer than it is here.
///
/// Equal columns, so the bar is exactly as wide as the column it sits in whatever is selected; a title that
/// shrinks before the bar does; and the selection drawn behind it rather than sized around it.
struct SegmentedBar<Value: Hashable>: View {
    let values: [Value]
    let title: (Value) -> String
    @Binding var selection: Value

    /// Matches the small segmented control the panel used to draw: 5 pt on the pill, 7 pt on the trough it sits in.
    private static var pillRadius: CGFloat { 5 }
    private static var troughRadius: CGFloat { 7 }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(values.enumerated()), id: \.element) { index, value in
                // The divider belongs to the gap before a segment, and a gap beside the selection has the pill
                // in it already; drawing both is the one place the native control looks busy.
                if index > 0 {
                    Rectangle()
                        .fill(Themed.wash(.white, divided(index) ? 0.18 : 0))
                        .frame(width: 1, height: 11)
                        .accessibilityHidden(true)
                }
                segment(value)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Self.troughRadius, style: .continuous)
            .fill(Themed.wash(.white, AccessibilityDisplay.shared.contrast ? 0.2 : 0.1)))
        .accessibilityElement(children: .contain)
    }

    /// True where the gap before `index` separates two unselected segments.
    private func divided(_ index: Int) -> Bool {
        values[index] != selection && values[index - 1] != selection
    }

    private func segment(_ value: Value) -> some View {
        let selected = value == selection
        return Button { selection = value } label: {
            Text(title(value))
                .font(.caption)
                .fontWeight(selected ? .semibold : .regular)
                .lineLimit(1)
                // The column is fixed, so a title too long for it shrinks rather than widening the bar. Long
                // enough to matter only outside English; at the Standard width the shipped titles all fit whole.
                .minimumScaleFactor(0.6)
                // Selected: the app's own accent (the one chosen under Theme, terracotta unless changed) rather
                // than `Color.accentColor`, which is the user's system accent and read as a stray piece of blue on a
                // panel that is otherwise the app's own colours. The title on it is the panel's ground colour —
                // black on the black panel, paper on Paper: terracotta is 5.7:1 under black and 3.7:1 under white,
                // and a caption at this size is text, not a control, so it owes 4.5:1 (PanelLook.audit holds every
                // accent to it). Increase Contrast lightens the pill on the black panel and darkens it on Paper, so
                // the same text clears 7:1 on either face (PanelAccent.onBlackContrast, onPaperContrast).
                // Unselected: `.foreground` and not `.primary`, because the panel paints its content in its own
                // ink whatever appearance the window carries, and `.primary` would resolve to that appearance's
                // label colour and turn the title black on the black panel's trough.
                .foregroundStyle(selected ? AnyShapeStyle(Themed(.black, .text)) : AnyShapeStyle(.foreground))
                .padding(.vertical, 3)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity)
                .background(selected ? AnyShapeStyle(Themed(AccessibilityDisplay.shared.contrast ? PanelInk.accentContrast : .accent)) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: Self.pillRadius, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(AccessibilityDisplay.shared.motionReduced ? nil : .snappy(duration: 0.15), value: selected)
        .accessibilityLabel(title(value))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

struct SpendCard: View {
    enum Range: CaseIterable, Identifiable {
        case today, yesterday, week, month, thirtyDays, ninetyDays
        var id: Self { self }

        var title: String {
            switch self {
            case .today: L("Today")
            case .yesterday: L("Yesterday")
            case .week: L("Week")
            case .month: L("Month")
            case .thirtyDays: L("30d")
            case .ninetyDays: L("90d")
            }
        }

        var costRange: CostRange {
            switch self {
            case .today: .today
            case .yesterday: .yesterday
            case .week: .week
            case .month: .month
            case .thirtyDays: .last30Days
            case .ninetyDays: .last90Days
            }
        }
    }

    let store: UsageStore
    /// A range this card is pinned to, or nil for a card that shows and sets the store's (`UsageStore.spendRange`).
    private let seeded: Range?
    /// Drawn open under the Simple panel's cost row: no box and no title, which the row already carries.
    private let embedded: Bool
    @Environment(\.density) private var density
    @Environment(\.panelLook) private var look

    /// The card on the panel passes no range: it draws the store's and its SegmentedBar sets it, so the range
    /// lives as long as the app rather than as long as the panel. Until 0.6.0 it was the card's own `@State`,
    /// which died with the panel and left every detached render of the card on Today (see `imageCard`). Tests
    /// and rendered stills pass the range they want, and a copy passes the one on screen.
    init(store: UsageStore, range: Range? = nil, embedded: Bool = false) {
        self.store = store
        seeded = range
        self.embedded = embedded
    }

    private var range: Range { seeded ?? store.spendRange }

    /// The SegmentedBar's selection. A seeded card is a picture of one range (a copy, a still, a width test) and
    /// nothing taps its bar, so the setter only has to serve the live card.
    private var selectedRange: Binding<Range> {
        Binding(get: { seeded ?? store.spendRange }, set: { if seeded == nil { store.spendRange = $0 } })
    }

    /// The range this card draws when rendered, read back by CostCardCopyImage: the seeded one, else the store's.
    var openingRange: Range { range }

    /// The card "Copy as image" renders: a fresh copy pinned to the range on screen. `CardImage.copy` renders a
    /// detached hierarchy, so nothing the user tapped carries over on its own -- until 0.5.0 the action built
    /// `SpendCard(store:)`, and a user who had picked 90d and read $6,412 pasted a Today card saying $118, with
    /// Today highlighted. Since 0.6.0 a fresh card reads the store's range and would already match; pinning it
    /// keeps the copy a picture of what was on screen when the menu opened. The context-menu Button below must
    /// render this, not a fresh `SpendCard(store:)`; CostCardCopyImage checks the pinning but cannot see the Button.
    var imageCard: SpendCard { SpendCard(store: store, range: range) }

    private var mode: CostCardMode { store.prefs.costCardMode }

    /// The assistants this card carries, in the user's order. Every figure on the card is theirs added up, so
    /// leaving one out under Settings takes it out of the total as well as out of the donut.
    private var selection: CostSelection { store.costSelection }

    private var totals: RangeTotals? {
        let selection = selection
        return selection.isEmpty ? nil : selection.totals(range.costRange)
    }

    private var amount: Double? { totals?.cost }

    /// The ring's figure in the chosen unit: dollars, tokens, or dollars per million tokens.
    static func headline(mode: CostCardMode, amount: Double?, totals: RangeTotals?) -> String {
        switch mode {
        case .cost: return amount.map { Money.dollars($0, cents: false) } ?? "—"
        case .tokens: return totals.map { Money.tokens($0.tokens.total).replacingOccurrences(of: " tokens", with: "") } ?? "—"
        case .perMillionTokens: return totals?.costPerMillionTokens.map { Money.dollars($0) } ?? "—"
        }
    }

    static func unit(mode: CostCardMode) -> String {
        switch mode {
        case .cost: Money.code == "USD" ? L("dollars") : Money.code
        case .tokens: L("tokens")
        case .perMillionTokens: L("per MTok")
        }
    }

    /// One assistant's figure in the chosen unit, for its row in the legend: the figure in the middle keeps the
    /// cents off a total that has to fit a ring, a row has the room for them.
    static func rowFigure(mode: CostCardMode, totals: RangeTotals) -> String {
        switch mode {
        case .cost: return Money.dollars(totals.cost)
        case .tokens: return Money.tokens(totals.tokens.total).replacingOccurrences(of: " tokens", with: "")
        case .perMillionTokens: return totals.costPerMillionTokens.map { Money.dollars($0) } ?? "—"
        }
    }

    /// The month's spend against the budget: the ring's fill and where an even burn would sit right now.
    private var budget: (fill: Double, tick: Double, budget: Double)? {
        guard let budget = store.prefs.monthlyBudgetUSD, budget > 0, !selection.isEmpty else { return nil }
        let period = BudgetPeriod.month(now: Date())
        return (min(1, selection.totals(.month).cost / budget), period.elapsedFraction(now: Date()), budget)
    }

    /// The donut's line, drawn inside its frame so the ring lines up with the card's text margin.
    static let ringWidth: CGFloat = 13

    /// The legend's two right-hand columns. Fixed so every row's percentage and every row's amount end on the
    /// same two edges however wide the figures are; the source label beside the name gives way first.
    static let shareColumn: CGFloat = 26
    static let figureColumn: CGFloat = 58

    /// The detail block describes the assistant at the top of the card's order, not the blend: one tool's own
    /// last hour, tokens, cache tiers and folders, with any line its source cannot answer simply absent.
    private var detail: CostDetail? {
        selection.providers.first.map { CostDetail(provider: $0, range: range.costRange, claude: store.cost, timeFormat: store.prefs.timeFormat,
                                                   mode: mode, promptCache: store.promptCacheToday) }
    }

    private var burnLine: String? { detail?.burn }

    /// The month against the budget stays a total: the budget is set against every carried assistant at once, and
    /// one of them has no share of it to print.
    private var budgetLine: String? {
        guard let budget else { return nil }
        return L("Month %1$@ of a %2$@ budget", Money.dollars(selection.totals(.month).cost, cents: false), Money.dollars(budget.budget, cents: false))
    }

    /// One row per assistant the card carries, in the user's order. One that cannot report spend, or that the
    /// card is set to leave out, is absent rather than a zero row.
    private var providers: [ProviderCost] { selection.providers }

    /// The lines the card keeps behind Show details, so the donut, the legend and the burn line hold the height
    /// budget on their own however many assistants report.
    private var detailLines: [String] {
        [budgetLine].compactMap { $0 } + (detail?.detailLines ?? [])
    }

    private var detailCaptions: [String] { detail?.detailCaptions ?? [] }

    /// What kind of number the block above it is, for the assistant the block describes; nil with no assistant
    /// reporting, where there is no figure to have a provenance.
    private var sourceLine: String? { detail?.source }

    /// A tool whose figures are stale or partial says so under its row.
    private var problemLines: [String] {
        providers.compactMap { provider in provider.problem.map { "\(provider.tool.displayName): \($0)" } }
    }

    /// The assistants the card carries that reported nothing, each with the reason the app knows for it. Leaving
    /// one out in silence reads as "it costs nothing", which is not what a missing read means.
    private var gaps: [CostGap] { store.costGaps }

    /// The donut's arcs: one per assistant that spent in the range, sized by its share of it. Against a monthly
    /// budget the arc is the month against that budget, so it is split by who spent the month rather than the
    /// range on show above it.
    private var arcs: [CostArc] {
        let selection = selection
        guard let budget else { return CostDonut.arcs(selection.weights(range: range.costRange, mode: mode)) }
        return CostDonut.arcs(selection.weights(range: .month, mode: .cost), fill: budget.fill)
    }

    /// Each assistant's own colour, except where the month is over its budget or past its pace: a warning
    /// outranks identity, and it is the same colour the single ring has always turned.
    private func arcColor(_ arc: CostArc) -> Color {
        guard let budget else { return arc.tool.color }
        return budget.fill >= 1 ? Palette.danger : budget.fill > budget.tick + 0.1 ? Palette.warn : arc.tool.color
    }

    /// A provider's share of the range, printed beside its figure once there is something to share it with.
    private func share(_ provider: ProviderCost) -> Double? {
        guard providers.count > 1 else { return nil }
        return selection.share(of: provider.tool, range: range.costRange, mode: mode)
    }

    /// Everything the card says in prose, in reading order: what is missing, what it burned, the detail behind
    /// it and where the figures came from. `quiet` marks the lines the caption style keeps a step back.
    @MainActor
    private var noteLines: [(text: String, quiet: Bool)] {
        var lines: [(text: String, quiet: Bool)] = problemLines.map { (text: $0, quiet: true) }
        lines += gaps.map { (text: $0.text, quiet: true) }
        if let burnLine {
            // A non-breaking hyphen keeps "30-day" whole when the line wraps.
            lines.append((text: burnLine.keepingHyphensWhole, quiet: false))
        }
        if store.prefs.showDetails {
            lines += detailLines.map { (text: $0, quiet: false) }
            lines += detailCaptions.map { (text: $0, quiet: true) }
        }
        // The $/MTok caveat stands whenever that unit is on show, details or not: it is about the headline figure.
        if let note = detail?.tokenizerNote { lines.append((text: note, quiet: true)) }
        if !selection.unpricedModels.isEmpty {
            lines.append((text: L("Unpriced: %@", selection.unpricedModels.sorted().joined(separator: ", ")), quiet: true))
        }
        if let sourceLine { lines.append((text: sourceLine, quiet: true)) }
        return lines
    }

    /// The legend as one spoken phrase.
    private var providerSpoken: String {
        guard !providers.isEmpty else { return L("no cost yet") }
        return providers.map { provider in
            let figure = Self.rowFigure(mode: mode, totals: provider.totals(range.costRange))
            guard let share = share(provider) else { return "\(provider.tool.displayName) \(figure)" }
            return L("%1$@ %2$@, %3$ld%% of it", provider.tool.displayName, figure, Int((share * 100).rounded()))
        }.joined(separator: ", ")
    }

    var body: some View {
        let headline = Self.headline(mode: mode, amount: amount, totals: totals)
        let unit = Self.unit(mode: mode)
        VStack(alignment: .leading, spacing: density.rowSpacing) {
            if !embedded || store.costScanning {
                HStack {
                    if !embedded { Text(L("Cost")).font(.headline) }
                    Spacer()
                    if store.costScanning {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.mini)
                            Text(L("Pricing local files")).font(.caption2).foregroundStyle(Ink.secondary)
                        }
                    }
                }
            }
            // Never a segmented Picker: it takes whatever width its titles come to, and the width it takes
            // changes with the selection, so the card hung past the panel's right margin and moved when the
            // range did. SegmentedBar is exactly as wide as the column it is given.
            SegmentedBar(values: Range.allCases, title: \.title, selection: selectedRange)
                .accessibilityLabel(L("Range"))
            // Centred against the ring: the column beside it is the legend alone, which is shorter than the ring
            // on every plan anyone has, and top-aligning it left the card's right half empty under two rows.
            VStack(alignment: .leading, spacing: density.rowSpacing) {
                HStack(alignment: .center, spacing: 16) {
                    ZStack {
                        // strokeBorder and an inset arc, never stroke: a stroked path is centred on the circle, so
                        // half the 13 pt line falls outside the frame and the ring hangs past the card's text margin.
                        Circle().strokeBorder(Themed.wash(.white, AccessibilityDisplay.shared.contrast ? 0.25 : 0.1), lineWidth: Self.ringWidth)
                        ForEach(arcs) { arc in
                            Circle()
                                .inset(by: Self.ringWidth / 2)
                                .trim(from: arc.start, to: arc.end)
                                .stroke(Themed(arcColor(arc)), style: StrokeStyle(lineWidth: Self.ringWidth, lineCap: .butt))
                                .rotationEffect(.degrees(-90))
                        }
                        if let budget {
                            Rectangle()
                                .fill(Themed(.white, opacity: AccessibilityDisplay.shared.contrast ? 1 : 0.8))
                                .frame(width: 2, height: 15)
                                .offset(y: -(density.costRing - Self.ringWidth) / 2)
                                .rotationEffect(.degrees(360 * budget.tick))
                                .accessibilityHidden(true)
                        }
                        VStack(spacing: 1) {
                            Text(headline)
                                .font(.system(.title2, design: .rounded).bold())
                                .monospacedDigit()
                                .minimumScaleFactor(0.6)
                                .lineLimit(1)
                            Text(unit).font(.caption2).foregroundStyle(Ink.secondary)
                        }
                        .padding(.horizontal, 10)
                    }
                    .frame(width: density.costRing, height: density.costRing)
                    .contentShape(Circle())
                    .onTapGesture { store.prefs.costCardMode = mode.next }
                    .help(L("Click to show %@", mode.next.title))
                    .contextMenu {
                        ForEach(CostCardMode.allCases, id: \.self) { choice in
                            Button(choice.title) { store.prefs.costCardMode = choice }
                        }
                    }
                    .accessibilityAction(named: L("Show %@", mode.next.title)) { store.prefs.costCardMode = mode.next }
                    VStack(alignment: .leading, spacing: density.lineSpacing) {
                        if providers.isEmpty {
                            Text(L("no cost yet")).font(.callout).foregroundStyle(Ink.secondary)
                        }
                        ForEach(providers) { provider in
                            let totals = provider.totals(range.costRange)
                            HStack(spacing: 6) {
                                Circle().fill(Themed(provider.tool.color)).frame(width: 7, height: 7)
                                Text(verbatim: provider.tool.displayName).font(.callout).lineLimit(1)
                                Text(provider.source.shortLabel).font(.caption2).foregroundStyle(Ink.secondary).lineLimit(1).layoutPriority(-1)
                                Spacer(minLength: 4)
                                // Both figures keep a column of their own, so a shorter amount on one row does not
                                // drag that row's percentage in from the one above it.
                                if let share = share(provider) {
                                    Text(verbatim: "\(Int((share * 100).rounded()))%")
                                        .font(.caption2).foregroundStyle(Ink.secondary).monospacedDigit()
                                        // "100%" is wider than the column: drawn at its own width it reaches left into
                                        // the spacer and still ends on the column's edge, where wrapping it put "%" on
                                        // a line of its own and the row off centre. Widening the column instead cut the
                                        // source label ("transcri…") on every row to serve the one that rarely occurs.
                                        .fixedSize()
                                        .frame(width: Self.shareColumn, alignment: .trailing)
                                }
                                Text(Self.rowFigure(mode: mode, totals: totals)).font(.callout).monospacedDigit()
                                    .lineLimit(1).minimumScaleFactor(0.7)
                                    .frame(width: Self.figureColumn, alignment: .trailing)
                            }
                        }
                    }
                }
                // The notes are prose, not legend rows: at the card's own text margin they line up with the title
                // and the model rows and have the full width to wrap in, rather than the column beside the ring.
                if !noteLines.isEmpty {
                    VStack(alignment: .leading, spacing: density.lineSpacing) {
                        ForEach(noteLines, id: \.text) { note in
                            Text(note.text)
                                .font(.caption2)
                                .foregroundStyle(note.quiet ? Caption.style : AnyShapeStyle(Ink.secondary))
                                .monospacedDigit()
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L("Cost, %@", range.title))
            .accessibilityValue(Spoken.line("\(headline) \(unit)", providerSpoken, burnLine, problemLines.first, gaps.first?.text,
                                            store.prefs.showDetails ? (detailLines + detailCaptions).joined(separator: " · ") : nil, sourceLine))
            if store.prefs.showDetails, let totals, !totals.models.isEmpty, totals.cost > 0 {
                ModelShares(shares: totals.models, total: totals.cost, byModel: totals.byModel, tokensByModel: nil, mode: mode, rangeTokens: totals.tokens.total)
            }
        }
        .modifier(CardBackground(boxed: !embedded))
        .contextMenu {
            Button(L("Copy as image")) {
                CardImage.copy(imageCard.environment(\.density, density), width: store.prefs.panelWidth.points - 28, look: look)
            }
        }
    }
}

/// The range's models ranked by cost, each with its share; the fifth and beyond fold into Other. In the tokens
/// and per-MTok modes the figure follows the mode: the model's share of the range's tokens, or its cost per
/// million of the range's tokens (per-model token counts are not kept in the digests, so the share stands in).
private struct ModelShares: View {
    let shares: [CostShare]
    let total: Double
    let byModel: [String: Double]
    let tokensByModel: [String: Int]?
    let mode: CostCardMode
    let rangeTokens: Int
    @Environment(\.density) private var density

    private func figure(_ share: CostShare) -> String {
        switch mode {
        case .cost: return Money.dollars(share.cost)
        case .tokens:
            let tokens = share.tokens > 0 ? Double(share.tokens) : Double(rangeTokens) * share.cost / max(total, 0.0001)
            return Money.tokens(Int(tokens.rounded())).replacingOccurrences(of: " tokens", with: "")
        case .perMillionTokens:
            // From this share's own tokens: apportioning the range's tokens by cost cancels the cost out and
            // prints the blended rate on every row.
            return share.tokens > 0 ? Money.dollars(share.cost / Double(share.tokens) * 1_000_000) : "—"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density.lineSpacing) {
            ForEach(shares) { share in
                HStack(spacing: 6) {
                    Text(share.name == CostShare.other ? L("Other") : ModelNames.display(share.name))
                        .font(.caption2).foregroundStyle(Ink.secondary).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(verbatim: "\(Int((share.cost / max(total, 0.0001) * 100).rounded()))%")
                        .font(.caption2).foregroundStyle(Ink.secondary).monospacedDigit()
                    Text(figure(share)).font(.caption2).monospacedDigit().frame(width: 62, alignment: .trailing)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("By model"))
        .accessibilityValue(shares.map { "\($0.name == CostShare.other ? L("Other") : ModelNames.display($0.name)) \(figure($0))" }.joined(separator: ", "))
    }
}

/// What to do next, under the Cost card (or at the top when spend is hidden); absent when there is nothing to say.
struct AdviceStrip: View {
    let advice: [Advice]
    var open: (URL) -> Void = { _ in }

    var body: some View {
        AdviceLines(advice: advice, open: open)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(CardBackground())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L("Advice"))
            .accessibilityValue(advice.map { Spoken.phrase($0.text) }.joined(separator: " "))
    }
}

/// The advice lines themselves, each with its symbol and its link: the strip's content on the Detailed panel, and
/// on the Simple panel the lines a row carries (AdvicePlacement).
struct AdviceLines: View {
    let advice: [Advice]
    var open: (URL) -> Void = { _ in }
    @Environment(\.density) private var density

    var body: some View {
        VStack(alignment: .leading, spacing: density.lineSpacing) {
            ForEach(advice) { item in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    // Leading, not centred: the symbol is the bullet and starts on the card's text margin
                    // whatever glyph it is.
                    Image(systemName: item.symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Themed(item.priority.mark))
                        .frame(width: 13, alignment: .leading)
                    Text(item.text.keepingHyphensWhole)
                        .font(.caption)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                    if let url = item.url {
                        Button {
                            open(url)
                        } label: {
                            Image(systemName: "arrow.up.right.square").font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Ink.secondary)
                        .help(url.host ?? url.absoluteString)
                        .accessibilityLabel(L("Open %@", url.host ?? url.absoluteString))
                    }
                }
            }
        }
    }
}

struct ToolCard: View {
    let tool: ToolID
    let status: ToolStatus
    let store: UsageStore
    let prefs: Preferences
    var actions: NotchActions? = nil
    /// Drawn open under the Simple panel's row for this assistant: no box, and no glyph, name or state on the title
    /// line, which the row above already carries. The plan, the usage-page link and the problem mark stay.
    var embedded = false
    @Environment(\.density) private var density
    @Environment(\.panelLook) private var look

    /// This assistant's own spend, where it reports any and the panel is showing figures. The spend line and the
    /// trend below both come from it, so no card has to know which assistants can report cost: one that cannot
    /// has no `ProviderCost` and so shows neither (docs/accuracy.md).
    private var spend: ProviderCost? {
        guard prefs.showSpend, !store.hidesFigures else { return nil }
        return store.cost?.provider(tool)
    }

    /// "$118.31 today · $6,600 over 30 days · local transcripts".
    private var spendLine: String? {
        guard let spend else { return nil }
        let today = spend.totals(.today).cost
        let month = spend.totals(.last30Days).cost
        guard today > 0 || month > 0 else { return nil }
        return L("%1$@ today · %2$@ over 30 days · %3$@", Money.dollars(today), Money.dollars(month, cents: false), spend.source.label)
    }

    /// The title sits inside the card rather than above it, so the icon and the link button end on the same two
    /// margins as the window labels and the meters below them.
    var body: some View {
        VStack(alignment: .leading, spacing: density.rowSpacing) {
            HStack(spacing: 6) {
                if !embedded {
                    Image(systemName: tool.symbolName).foregroundStyle(Themed(tool.color)).font(.subheadline.weight(.semibold))
                    Text(tool.displayName).font(.headline)
                }
                if let plan = status.reading?.plan {
                    Text(plan).font(.subheadline).foregroundStyle(Ink.secondary)
                }
                // The rings recolour because they have no room for anything else. A card has room for words, so it
                // says which state it is in rather than leaving the reader to learn a hue.
                // In the app's accent rather than Palette.calm: the calm blue stays on the rings and the marks,
                // where it is the "needs you" colour a reader learns; on the card the words already say it, and
                // the blue beside them read as the system's link colour.
                if !embedded, let signal = store.signal(tool) {
                    Label(signal.cardText, systemImage: signal.symbolName)
                        .font(.caption)
                        .foregroundStyle(Themed(.accent, .text))
                        .accessibilityLabel(signal.cardText)
                }
                Spacer()
                Button {
                    actions?.open(ProviderLinks.usage(tool))
                } label: {
                    Image(systemName: "arrow.up.right.square").font(.caption).foregroundStyle(Ink.secondary)
                }
                .buttonStyle(.plain)
                .help(L("Open %@'s usage page", tool.displayName))
                .accessibilityLabel(L("Open %@'s usage page", tool.displayName))
                if let problem = status.problem {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Themed(Palette.warn))
                        .help(problem)
                        .accessibilityLabel(problem)
                }
            }
            SessionLine(store: store, tool: tool)
            if let reading = status.reading {
                meters(prefs.panelWindows(of: reading))
                    .opacity(status.problem == nil ? 1 : 0.55)
                if let observed = reading.observedAt, Date().timeIntervalSince(observed) > 600 {
                    Text(L("As of %@", RelativeTime.ago(observed))).modifier(Caption()).monospacedDigit()
                }
            }
            switch status {
            case .waiting:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(L("Waiting for the first reading"))
                }
                .font(.caption).foregroundStyle(Ink.secondary)
            case .idle(let message):
                Text(message).font(.caption).foregroundStyle(Ink.secondary)
            case .needsAttention(let message, _):
                Label(message, systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.caption).foregroundStyle(Themed(Palette.warn, .text))
            case .failed(let message, _):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Ink.secondary).monospacedDigit()
            case .offline:
                Label(L("Offline, retrying"), systemImage: "wifi.slash")
                    .font(.caption).foregroundStyle(Ink.secondary)
            case .rateLimited(let message, _):
                Label(message, systemImage: "clock.badge.exclamationmark")
                    .font(.caption).foregroundStyle(Ink.secondary).monospacedDigit()
            default:
                EmptyView()
            }
            if let stale = status.staleReading {
                Text(StaleReading.line(fetchedAt: stale.fetchedAt, timeFormat: prefs.timeFormat))
                    .modifier(Caption()).monospacedDigit()
            }
            if let spendLine {
                Text(spendLine)
                    .modifier(Caption()).monospacedDigit().lineLimit(2)
                    .accessibilityLabel(L("Spend"))
                    .accessibilityValue(Spoken.phrase(spendLine))
            }
            if prefs.showDetails, let reading = status.reading, let main = prefs.shownWindows(of: reading).first(where: { $0.usedFraction != nil }),
               let series = store.drainSeries(for: tool, window: main), series.contains(where: { $0 != nil }) {
                HStack {
                    Text(L("Last 24h")).font(.subheadline.weight(.semibold))
                    Spacer()
                    DrainSparkline(points: series, color: tool.color).frame(width: 160, height: 22)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(L("Last 24h"))
                .accessibilityValue(Spoken.phrase(L("%1$@ %2$ld percent used", main.label, Int(((series.last { $0 != nil } ?? 0) ?? 0) * 100))))
            }
            if prefs.showDetails, let trend = spend?.daily, trend.contains(where: { $0.cost > 0 }) {
                HStack {
                    Text(L("Usage Trend")).font(.subheadline.weight(.semibold))
                    Spacer()
                    Sparkline(series: trend, color: tool.color).frame(width: 160, height: 22)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(L("Usage Trend"))
                .accessibilityValue(Spoken.phrase(Sparkline.summary(trend)))
            }
        }
        .modifier(CardBackground(boxed: !embedded))
        .contextMenu {
            Button(L("Refresh")) { Task { await store.refresh(tool, force: true, interactive: true) } }
            Button(L("Copy as image")) {
                CardImage.copy(ToolCard(tool: tool, status: status, store: store, prefs: prefs).environment(\.density, density), width: prefs.panelWidth.points - 28,
                               look: look)
            }
            Divider()
            Button(L("Open %@'s usage page", tool.displayName)) { actions?.open(ProviderLinks.usage(tool)) }
            if let status = ProviderLinks.status(tool) {
                Button(L("Open %@'s status page", tool.displayName)) { actions?.open(status) }
            }
        }
    }
}

extension ToolCard {
    /// The card's windows as the chosen usage style draws them (UsageStyle): a meter each, or a dial of up to three
    /// rings beside the same rows without their bars, each row led by a swatch saying which ring is its own, and a
    /// meter for any window past the third or with no figure. The rows keep every line they carry either way — pace,
    /// source, reset, drain and metering — so the dial adds a picture and takes no words away.
    @ViewBuilder
    fileprivate func meters(_ windows: [LimitWindow]) -> some View {
        if windows.isEmpty {
            EmptyView()
        } else if look.usageStyle == .gauges, case let split = UsageDial.split(windows), !split.rings.isEmpty {
            VStack(alignment: .leading, spacing: density.rowSpacing) {
                HStack(alignment: .center, spacing: 14) {
                    UsageDialView(tool: tool, windows: split.rings, size: density == .compact ? 72 : 84, display: prefs.usageDisplay,
                                  showsCentre: !store.hidesFigures)
                    VStack(alignment: .leading, spacing: density.rowSpacing) {
                        ForEach(Array(split.rings.enumerated()), id: \.element.id) { index, window in
                            meter(window, gauge: MeterRow.Gauge(index: index, count: split.rings.count,
                                                                colour: UsageDial.colour(window, tool: tool, index: index)))
                        }
                    }
                }
                ForEach(split.bars) { window in meter(window) }
            }
        } else {
            VStack(alignment: .leading, spacing: density.rowSpacing) {
                ForEach(windows) { window in meter(window) }
            }
        }
    }

    private func meter(_ window: LimitWindow, gauge: MeterRow.Gauge? = nil) -> MeterRow {
        MeterRow(toolName: tool.displayName, window: window, color: tool.color, prefs: prefs,
                 stale: status.staleReading != nil, hideFigures: store.hidesFigures,
                 drain: store.drain(for: tool, window: window), runOut: store.runOut(for: tool, window: window),
                 metering: tool == .claude && window.id == "five_hour" && prefs.showSpend ? store.cost?.sessionMetering : nil,
                 gauge: gauge)
    }
}

/// "2 sessions · working 2m 10s" and, while the status line reports, "Context 62% · Opus · $1.23 this session".
/// Every card gets one, showing only its own tool's sessions; the status line's context and cost are Claude Code's
/// alone, so they are consulted on its card and on no other. A card with nothing to say draws nothing.
private struct SessionLine: View {
    let store: UsageStore
    let tool: ToolID
    @Environment(\.density) private var density

    var body: some View {
        let sessions = store.sessions.only(tool)
        let statusline = tool == .claude ? store.statusline : nil
        let contextUsed = tool == .claude ? store.contextUsed : nil
        if sessions.count > 0 || contextUsed != nil {
            TimelineView(.periodic(from: .now, by: sessions.working.isEmpty && sessions.waiting.isEmpty ? 60 : 1)) { context in
                VStack(alignment: .leading, spacing: density.lineSpacing) {
                    if sessions.count > 0 {
                        Text(Self.sessionsText(sessions, now: context.date))
                            .font(.caption).foregroundStyle(Ink.secondary).monospacedDigit()
                    }
                    if let place = Self.placeText(sessions) {
                        HStack(spacing: 5) {
                            Text(place.text).font(.caption).foregroundStyle(Ink.secondary).lineLimit(1).truncationMode(.middle)
                            if let badge = place.badge {
                                Text(badge)
                                    .font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Capsule().fill(Themed.wash(.white, 0.14)))
                                    .accessibilityLabel(L("permission mode %@", badge))
                            }
                            if let pr = place.pr {
                                Button { store.openURL(pr) } label: { Image(systemName: "arrow.up.right.square").font(.caption2) }
                                    .buttonStyle(.plain).foregroundStyle(Ink.secondary)
                                    .help(pr.absoluteString)
                                    .accessibilityLabel(L("Open the pull request"))
                            }
                        }
                    }
                    if let contextUsed {
                        Text(Self.contextText(contextUsed, statusline: statusline, hideFigures: store.hidesFigures))
                            .font(.caption)
                            .foregroundStyle(contextUsed >= 0.9 ? AnyShapeStyle(Themed(Palette.warn, .text)) : AnyShapeStyle(Ink.secondary))
                            .monospacedDigit()
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(L("Sessions"))
                .accessibilityValue(Spoken.line(Self.sessionsText(sessions, now: context.date), Self.placeText(sessions)?.text,
                                                Self.placeText(sessions)?.badge.map { L("permission mode %@", $0) }))
            }
        }
    }

    /// "2 sessions · 3 agents · working 2m 10s", then the newest session's place: "notchmeter · feat/hooks · PR #12".
    static func sessionsText(_ sessions: SessionTracker, now: Date) -> String {
        var parts = [sessions.count == 1 ? L("1 session") : L("%ld sessions", sessions.count)]
        if sessions.agentCount > 0 {
            parts.append(sessions.agentCount == 1 ? L("1 agent") : L("%ld agents", sessions.agentCount))
        }
        if let waiting = SessionTracker.waitingPhrase(sessions.waiting) {
            parts.append(L("waiting in %@", waiting))
        } else if let working = sessions.working.first, let since = working.stateDuration(now: now) {
            parts.append(L("working %@", ResetText.duration(since)))
        }
        if sessions.quotaWaiting.count > 0 { parts.append(L("waiting on quota")) }
        return parts.joined(separator: " · ")
    }

    /// The newest session's project, branch and pull request, when the hook or status line reported them.
    static func placeText(_ sessions: SessionTracker) -> (text: String, pr: URL?, badge: String?)? {
        guard let session = sessions.all.first else { return nil }
        var parts: [String] = []
        if let name = session.displayName { parts.append(name) }
        if let branch = session.branch { parts.append(branch) }
        if let pr = session.prNumber { parts.append(L("PR %@", pr)) }
        guard !parts.isEmpty else { return nil }
        return (parts.joined(separator: " · "), session.prLink, Hook.permissionBadge(session.permissionMode))
    }

    static func contextText(_ used: Double, statusline: Statusline.Message?, hideFigures: Bool) -> String {
        var parts = [L("Context %ld%%", Int((used * 100).rounded()))]
        if let model = statusline?.model { parts.append(statusline?.effort.map { "\(model) \($0)" } ?? model) }
        if !hideFigures, let cost = statusline?.sessionCost { parts.append(L("%@ this session", Money.dollars(cost))) }
        return parts.joined(separator: " · ")
    }
}

struct MeterRow: View {
    let toolName: String
    let window: LimitWindow
    let color: Color
    let prefs: Preferences
    /// The window comes from a reading its tool can no longer refresh (ToolStatus.staleReading).
    var stale = false
    var hideFigures = false
    var drain: Drain? = nil
    var runOut: RunOutInterval? = nil
    var metering: MeteringRatio? = nil
    /// Drawn beside a dial (UsageStyle.gauges): which ring is this row's, and no bar of its own.
    var gauge: Gauge? = nil
    @Environment(\.density) private var density
    @Environment(\.panelLook) private var look

    /// A row's place in the dial it stands beside: its ring, of how many, in the ring's colour.
    struct Gauge {
        let index: Int
        let count: Int
        let colour: Color
    }

    /// The pace note, with the run-out interval's range in place of the point when the log has a wide one.
    static func paceNote(window: LimitWindow, runOut: RunOutInterval?, format: TimeFormatPreference, now: Date = Date()) -> (text: String, status: Pace.Status)? {
        guard let pace = Pace.note(for: window, now: now) else { return nil }
        guard pace.status == .behind, let runOut, let resetsAt = window.resetsAt, let text = runOut.text(now: now, resetsAt: resetsAt, format: format) else { return pace }
        return (text, pace.status)
    }

    var body: some View {
        let pace = Self.paceNote(window: window, runOut: runOut, format: prefs.timeFormat)
        let usage = hideFigures ? nil : prefs.usageLine(for: window)
        let reset = window.usedFraction == nil
            ? (window.note ?? prefs.resetLine(for: window, stale: stale))
            : (window.resetsAt == nil && window.usedFraction != 0 ? (window.note ?? "") : prefs.resetLine(for: window, stale: stale))
        let detail = window.usedFraction != nil && (window.resetsAt != nil || window.usedFraction == 0) ? window.note : nil
        let unused = window.usedFraction == 0 ? window.periodDuration.map(ResetText.unusedLine) : nil
        let drainLine = drain.flatMap { $0.to > $0.from + 0.005 && !hideFigures ? DrainLog.line($0) : nil }
        let meteringLine = metering.flatMap { ratio -> String? in
            guard !hideFigures else { return nil }
            let today = Money.tokens(Int(ratio.tokensPerPercent.rounded()))
            guard let median = ratio.median else { return L("%@ per 1%% of session today", today) }
            return L("%1$@ per 1%% of session today vs %2$@ 30-day median", today, Money.tokens(Int(median.rounded())))
        }
        // The clock beside the reset, for a window measured in hours when the reader asked for one (HourClock).
        let clock = look.hourClock ? HourClock.remaining(window) : nil
        VStack(alignment: .leading, spacing: density.lineSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if let gauge {
                    DialSwatch(index: gauge.index, count: gauge.count, colour: gauge.colour)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                }
                Text(window.label).font(.subheadline.weight(.semibold))
                if let tag = window.source.tag {
                    Text(tag)
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(Themed.wash(.white, 0.12)))
                        .foregroundStyle(Ink.secondary)
                        .help(L("Source: %@", tag))
                }
                Spacer(minLength: 8)
                if let pace, !hideFigures {
                    HStack(spacing: 3) {
                        if let symbol = pace.status.symbolName {
                            Image(systemName: symbol).font(.caption2.weight(.semibold))
                        }
                        Text(pace.text).monospacedDigit()
                    }
                    .font(.caption).foregroundStyle(Themed(pace.status.noteColor, .text))
                }
            }
            if let used = window.usedFraction {
                if gauge == nil {
                    Meter(
                        fraction: used,
                        tick: window.resetsAt.flatMap { resetsAt in window.periodDuration.flatMap { Pace.elapsedFraction(resetsAt: resetsAt, period: $0) } },
                        color: pace?.status.meterColor ?? color
                    )
                }
                HStack {
                    if let unused {
                        HStack(spacing: 4) {
                            if let clock { ClockFace(remaining: clock) }
                            Text(unused).monospacedDigit()
                        }
                    } else {
                        Text(usage ?? "").monospacedDigit()
                            .help(L("Click to show %@", prefs.usageDisplay == .used ? UsageDisplay.left.title : UsageDisplay.used.title))
                            .onTapGesture { flipUsage() }
                            .accessibilityAction(named: L("Flip used and left")) { flipUsage() }
                        Spacer()
                        HStack(spacing: 4) {
                            if let clock { ClockFace(remaining: clock) }
                            Text(reset).monospacedDigit()
                                .help(L("Click to show %@", prefs.resetDisplay == .countdown ? ResetDisplay.exact.title : ResetDisplay.countdown.title))
                                .onTapGesture { flipReset() }
                                .accessibilityAction(named: L("Flip countdown and exact time")) { flipReset() }
                        }
                    }
                }
                .font(.caption).foregroundStyle(Ink.secondary)
                if let detail {
                    Text(detail).modifier(Caption()).monospacedDigit()
                }
                if let drainLine {
                    Text(drainLine).modifier(Caption()).monospacedDigit()
                }
                if let meteringLine {
                    Text(meteringLine).modifier(Caption()).monospacedDigit()
                }
            } else {
                Meter(fraction: 0, tick: nil, color: .clear)
                HStack {
                    Text(verbatim: "—")
                    Spacer()
                    Text(reset).monospacedDigit()
                }
                .font(.caption).foregroundStyle(Ink.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(toolName) \(window.label)")
        .accessibilityValue(Spoken.line(unused ?? usage, unused == nil ? reset : nil, detail, hideFigures ? nil : pace?.text, drainLine, meteringLine,
                                        window.source.tag.map { L("Source: %@", $0) }))
    }

    private func flipUsage() {
        prefs.usageDisplay = prefs.usageDisplay == .used ? .left : .used
    }

    private func flipReset() {
        prefs.resetDisplay = prefs.resetDisplay == .countdown ? .exact : .countdown
    }
}

/// The pace meter: the fill grows from the left and the tick sits where an even burn would be. Quantity and time
/// run left to right in every language, so the meter is pinned to that direction rather than mirrored under a
/// right-to-left layout, where the fill would mirror and the offset tick would not.
struct Meter: View {
    let fraction: Double
    let tick: Double?
    let color: Color

    /// The tick's x from the leading edge, kept inside the bar.
    static func tickOffset(width: CGFloat, tick: Double) -> CGFloat {
        min(max(width * CGFloat(tick) - 1, 0), max(width - 2, 0))
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Themed.wash(.white, AccessibilityDisplay.shared.contrast ? 0.28 : 0.12))
                if fraction > 0 {
                    Capsule().fill(Themed(color)).frame(width: max(6, width * CGFloat(min(1, fraction))))
                }
                if let tick {
                    Rectangle()
                        .fill(Themed(.white, opacity: AccessibilityDisplay.shared.contrast ? 1 : 0.7))
                        .frame(width: 2, height: 11)
                        .offset(x: Self.tickOffset(width: width, tick: tick))
                }
            }
            .animation(AccessibilityDisplay.shared.motionReduced ? nil : .snappy(duration: 0.4), value: fraction)
        }
        .frame(height: 6)
        .environment(\.layoutDirection, .leftToRight)
    }
}

/// The 30-day cost trend; hovering a bar names the day, its cost and its top model.
struct Sparkline: View {
    let series: [DailySpend]
    let color: Color

    var body: some View {
        let peak = max(series.map(\.cost).max() ?? 0, 0.0001)
        GeometryReader { geometry in
            let count = max(series.count, 1)
            let spacing: CGFloat = 2
            let barWidth = max(1, (geometry.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(series) { day in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Themed(color, opacity: day.cost > 0 ? 1 : 0.3))
                        .frame(width: barWidth, height: max(2, geometry.size.height * CGFloat(day.cost / peak)))
                        .help(Self.tooltip(day))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottomLeading)
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    static func tooltip(_ day: DailySpend) -> String {
        var parts = [ResetText.dayPhrase(day.day, now: Date(), calendar: .current), Money.dollars(day.cost)]
        if let model = day.topModel { parts.append(ModelNames.display(model)) }
        return parts.joined(separator: " · ")
    }

    /// "30 days, $118 today, peak $212 on Tuesday, top model Opus": the series as VoiceOver reads it.
    static func summary(_ series: [DailySpend], now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let today = series.last else { return "" }
        var parts = [L("%ld days", series.count), L("%@ today", Money.dollars(today.cost, cents: false))]
        if let peak = series.max(by: { $0.cost < $1.cost }), peak.cost > 0 {
            parts.append(L("peak %1$@ on %2$@", Money.dollars(peak.cost, cents: false), ResetText.dayPhrase(peak.day, now: now, calendar: calendar)))
        }
        if let model = today.topModel { parts.append(L("top model %@", ModelNames.display(model))) }
        return parts.joined(separator: ", ")
    }
}

/// The last 24 hours of a window's fill from the drain log: one column per hour, an hour without a row left empty.
struct DrainSparkline: View {
    let points: [Double?]
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let count = max(points.count, 1)
            let spacing: CGFloat = 2
            let barWidth = max(1, (geometry.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Themed(point.map { $0 >= 0.95 ? Palette.danger : $0 >= 0.8 ? Palette.warn : color } ?? color, opacity: point == nil ? 0.2 : 1))
                        .frame(width: barWidth, height: max(2, geometry.size.height * CGFloat(point ?? 0)))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottomLeading)
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}

/// The one row that stands for the assistants `Preferences.hideEmptyTools` keeps off the panel: signed in but with
/// no reading, no spend and no session yet. Not a card — a card for what is not there is what the setting removed —
/// but a quiet line at the foot of the cards that names them and opens Settings › Assistants, where each one's row
/// says what it is waiting for. It carries the cards' inner padding so it ends on the same margins as they do.
struct AddToolRow: View {
    let hidden: [ToolID]
    let actions: NotchActions
    @Environment(\.density) private var density

    var body: some View {
        Button {
            actions.openSettingsPane(.assistants)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus.circle").font(.caption.weight(.semibold))
                Text(L("Add a tool")).font(.caption)
                Text(verbatim: hidden.map(\.displayName).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(Ink.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Assistants with nothing to show yet stay off the panel. Opens Settings › Assistants, where each one's row says what it is waiting for."))
        .accessibilityLabel(L("Add a tool"))
        .accessibilityValue(hidden.map(\.displayName).joined(separator: ", "))
        .padding(.horizontal, density.cardPadding)
    }
}

struct FooterView: View {
    let store: UsageStore
    let actions: NotchActions
    @Environment(\.density) private var density

    var body: some View {
        HStack(alignment: .center) {
            // The refresh line alone: the version and build that stood above it until 0.7.0 are in
            // Settings › About, where someone filing a bug looks, and were a line of the panel nobody
            // opened it for. VoiceOver reads the line itself, which is what the version used to label.
            RefreshLine(store: store, actions: actions)
            // The Options button that sat here is in the header now (PanelHeader), beside Settings and the
            // Dashboard, so the three ways out of the panel are in one place at the top.
            Spacer()
        }
        // The footer carries no card of its own, so it takes the cards' inner padding: the refresh line starts
        // on the same margin as everything above it.
        .padding(.horizontal, density.cardPadding)
    }
}

/// "Next update in 2m", a button that refreshes (⌘R). The Detailed panel's footer; on the Simple panel, which has
/// no footer, it sits in the header under the session count (PanelHeader).
struct RefreshLine: View {
    let store: UsageStore
    let actions: NotchActions

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            let next = nextUpdate(now: context.date)
            Button {
                actions.refresh()
            } label: {
                Text(next).monospacedDigit().fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r", modifiers: .command)
            .help(L("Refresh now (⌘R)"))
            .font(.caption2)
            .foregroundStyle(Ink.secondary)
            .accessibilityLabel(Spoken.phrase(next))
            .accessibilityAction(named: L("Refresh now")) { actions.refresh() }
        }
    }

    private func nextUpdate(now: Date) -> String {
        if let reason = store.pauseReason { return reason.footerText }
        guard let next = store.nextUpdate else {
            if store.pauseReason == nil, store.visibleTools.contains(where: { store.status($0).isOffline }) { return L("Offline, retrying") }
            return L("Waiting for the first reading")
        }
        let seconds = next.timeIntervalSince(now)
        if seconds <= 5 { return L("Updating…") }
        let line = L("Next update in %@", ResetText.duration(seconds))
        let withNote = store.scheduleNote.map { "\(line) · \($0)" } ?? line
        return store.footerNote.map { "\(withNote) · \($0)" } ?? withNote
    }
}


/// What a run of readouts would need beside the notch, for `CompactSide.auto`. One hosting view for the life of
/// the app, re-laid out per measurement, as NotchController does for its hover regions. Sizing candidate fits
/// rather than the one in force keeps the rule from feeding on its own answer.
@MainActor
final class CompactStripProbe {
    private let store: UsageStore
    private let probe: NSHostingView<NotchCompactView>

    init(store: UsageStore) {
        self.store = store
        probe = NSHostingView(rootView: NotchCompactView(store: store, side: .leading,
                                                        run: CompactFit.Run(style: .rings, readouts: 0 ..< 0, overflow: 0)))
    }

    /// The room one side of the notch takes for a run of readouts, drawn exactly as that side will draw it.
    func width(_ run: CompactFit.Run) -> CGFloat {
        probe.rootView = NotchCompactView(store: store, side: .leading, run: run)
        probe.layoutSubtreeIfNeeded()
        return probe.fittingSize.width
    }

    /// How many readouts there would be with nothing dropped.
    var toolCount: Int { store.compactTools(style: store.prefs.compactStyle).count }
}
