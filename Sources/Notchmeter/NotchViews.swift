import AppKit
import Observation
import SwiftUI

extension ToolID {
    var color: Color {
        switch self {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: Color(red: 0.36, green: 0.83, blue: 0.62)
        case .cursor: Color(red: 0.65, green: 0.55, blue: 0.98)
        case .antigravity: Color(hex: 0x56B4E9)  // #56B4E9 sky blue, from Wong's set
        case .copilot: Color(hex: 0xF0E442)      // #F0E442 yellow, from Wong's set
        }
    }
}

/// Status colours are Wong's colour-blind-safe set, and every status also carries a shape or a symbol so the
/// meaning never rests on hue alone. Tool identity keeps its own colours on the bars.
enum Palette {
    static let calm = Color(hex: 0x0072B2)    // #0072B2 blue: needs you, not running out
    static let warn = Color(hex: 0xE69F00)    // #E69F00 orange: on track, nearly full, needs attention
    static let danger = Color(hex: 0xD55E00)  // #D55E00 vermillion: behind pace, out
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
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

private extension Pace.Status {
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

private extension Advice.Priority {
    var color: Color {
        switch self {
        case .attention: Palette.calm
        case .danger: Palette.danger
        case .warn: Palette.warn
        case .info: .secondary
        }
    }
}

/// Captions are tertiary on black by default and secondary under Increase Contrast.
private struct Caption: ViewModifier {
    @MainActor
    static var style: AnyShapeStyle {
        AccessibilityDisplay.shared.contrast ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary)
    }

    func body(content: Content) -> some View {
        content.font(.caption2).foregroundStyle(Self.style)
    }
}

private struct CardBackground: ViewModifier {
    @Environment(\.density) private var density

    func body(content: Content) -> some View {
        content
            .padding(density.cardPadding)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(AccessibilityDisplay.shared.contrast ? 0.16 : 0.07)))
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

    /// The colour the arc takes. A signal outranks fullness, which outranks the tool's own colour, because a
    /// permission prompt is the only one of the three the reader can act on this second: the meter cannot move at
    /// all until they answer it. That is the order `Presence.level` and `Advisor.waiting` already put these two
    /// facts in, and nothing is lost by it — the displaced fullness tint moves to the cap.
    static func arcColour(fraction: Double, tool: Color, signal: ToolSignal?) -> Color {
        if let signal { return signal.colour }
        return fullness(fraction) ?? tool
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

    /// Diameter and stroke for each nested ring, outermost first.
    static func nest(count: Int, quiet: Bool) -> [(diameter: CGFloat, lineWidth: CGFloat)] {
        let outer: CGFloat = quiet ? 14 : 18
        if count > 2 {
            return [(outer, quiet ? 2 : 2.5), (quiet ? 9.5 : 12.5, quiet ? 1.5 : 2), (quiet ? 5 : 7, quiet ? 1.25 : 1.5)]
        }
        return [(outer, quiet ? 2 : 2.5), (quiet ? 8 : 10, quiet ? 1.5 : 2)]
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
                    ForEach(Array(zip(windows, nest).dropFirst().enumerated()), id: \.offset) { _, pair in
                        RingView(fraction: pair.0.usedFraction, color: tool.color.opacity(0.8), lineWidth: pair.1.lineWidth,
                                 pace: Pace.status(for: pair.0), signal: painted)
                            .frame(width: pair.1.diameter, height: pair.1.diameter)
                    }
                    if let contextUsed {
                        ContextArc(fraction: contextUsed, diameter: quiet ? 18 : 22)
                    }
                    if status.problem != nil {
                        ProblemMark()
                    }
                }
            }
            .opacity(presence.readoutOpacity)
            if presence != .hidden, let signal {
                SignalMark(signal: signal).offset(SignalMark.cornerOffset(of: signal, in: Self.side))
            }
        }
        .frame(width: Self.side, height: Self.side)
        .opacity(status.reading == nil && status.problem == nil ? 0.5 : 1)
        .animation(AccessibilityDisplay.shared.motionReduced ? nil : .snappy(duration: 0.4), value: presence)
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
    var countdown = false
    var badges = false
    var signal: ToolSignal? = nil
    var presence: PresenceLevel = .legible

    var body: some View {
        TimelineView(.periodic(from: .now, by: countdown ? 60 : 3600)) { context in
            let segments = CompactLabel.segments(for: windows, display: display, countdown: countdown, now: context.date)
            HStack(spacing: 3) {
                if badges, status.problem != nil {
                    ProblemMark()
                }
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    if index > 0 {
                        Text(verbatim: CompactLabel.separator).foregroundStyle(.secondary)
                    }
                    Text(verbatim: segment.text)
                        .foregroundStyle(color(for: segment))
                        .contentTransition(AccessibilityDisplay.shared.motionReduced ? .identity : .numericText())
                }
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .opacity(presence.readoutOpacity)
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
/// VoiceOver reads the tool and every window's figure and pace, whatever is drawn.
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
    let display: UsageDisplay
    var windows: [LimitWindow] = []
    /// What the assistant is asking of the user (ToolSignal): the rings' colour, the mark and what VoiceOver reads
    /// first all come from this one value, so none of the three can disagree with another.
    var signal: ToolSignal? = nil
    /// Whether the rings take the colour, or only the mark carries it (Preferences.signalRings).
    var signalColours = true
    var contextUsed: Double? = nil
    var countdown = false
    var hideFigures = false
    var presence: PresenceLevel = .legible
    var axis: Axis = .horizontal
    /// Claude Code on an API key: no rings to draw; the month's cost stands in for the digits when they are shown.
    var apiKeyCost: String? = nil
    @State private var pulsing = false
    @State private var pulseTask: Task<Void, Never>?
    static let pulseCycles = 3
    static let pulseDuration = 1.5

    var body: some View {
        let reduceMotion = AccessibilityDisplay.shared.motionReduced
        Group {
            if axis == .vertical {
                VStack(spacing: 3) { parts }
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
        let showNumbers = style.showsNumbers && !hideFigures && presence != .hidden
        if let apiKeyCost {
            if showNumbers {
                // Claude Code on an API key draws no ring, which left the one assistant whose hook reports these
                // events as the only one with nowhere to report them. The mark goes on the corner of the figure,
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
                             contextUsed: contextUsed, presence: presence)
            }
            if showNumbers {
                CompactNumbers(tool: tool, status: status, windows: windows, display: display, countdown: countdown,
                               badges: !style.showsRings, signal: signal, presence: presence)
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
    func readout(_ tool: ToolID, presence: PresenceLevel, axis: Axis = .horizontal, style: CompactStyle) -> CompactReadout {
        let status = status(tool)
        let apiKeyCost = tool == .claude && claudeOnAPIKey ? Money.dollars(cost?.totals(.month).cost ?? 0, cents: false) : nil
        return CompactReadout(tool: tool, status: status, style: style, display: prefs.usageDisplay,
                              windows: status.reading.map(prefs.ringWindows) ?? [], signal: signal(tool), signalColours: prefs.signalRings,
                              contextUsed: tool == .claude ? contextUsed : nil, countdown: prefs.showResetCountdown, hideFigures: hidesFigures,
                              presence: presence, axis: axis, apiKeyCost: apiKeyCost)
    }

    /// The tools with a compact readout: Claude on an API key has nothing to draw unless the digits are shown.
    func compactTools(style: CompactStyle) -> [ToolID] {
        visibleTools.filter { !($0 == .claude && claudeOnAPIKey && !style.showsNumbers) }
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

    var body: some View {
        let presence = store.presence
        let run = drawn
        let visible = store.compactTools(style: run.style)
        // Clamped because the store can lose a tool between the fit being resolved and this being drawn.
        let tools = Array(visible[run.readouts.clamped(to: 0 ..< visible.count)])
        HStack(spacing: run.style.showsNumbers ? 9 : 7) {
            ForEach(tools, id: \.self) { tool in
                store.readout(tool, presence: presence, style: run.style)
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
                VStack(spacing: 10) { readouts }.padding(.vertical, 12).padding(.horizontal, 7)
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
    @State private var contentHeight: CGFloat = 0

    static let screenMargin: CGFloat = 24
    /// The room the content keeps above its first card.
    static let contentTopPadding: CGFloat = 8

    /// The room between the top of the scrolled content and the first card's title: this padding and the card's
    /// own. A reading of where the panel opens counts from the title, which is what has to clear the notch
    /// (PanelScroll).
    static func titleInset(density: Density) -> CGFloat { contentTopPadding + density.cardPadding }

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
                // next open, so it already starts at the Cost card. An anchor here would fight a real scroll.
                .scrollDisabled(!overflows)
                .frame(maxHeight: cap)
                .onPreferenceChange(PanelContentHeight.self) { contentHeight = $0 }
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .environment(\.density, prefs.density)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private var content: some View {
        let tools = store.visibleTools
        let advice = store.advice
        return VStack(alignment: .leading, spacing: prefs.density.cardSpacing) {
            if prefs.showSpend, !store.hidesFigures, tools.contains(where: { $0.reportsCost && prefs.costCardTools.contains($0) }) {
                SpendCard(store: store)
            }
            if !advice.isEmpty {
                AdviceStrip(advice: advice, open: actions.open)
            }
            if tools.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Connect an assistant to get started"))
                        .font(.callout)
                    Text(L("Install and sign in to Claude Code, Codex, Cursor, Gemini CLI or GitHub Copilot; its meters appear here."))
                        .modifier(Caption())
                }
                .modifier(CardBackground())
            }
            ForEach(tools, id: \.self) { tool in
                ToolCard(tool: tool, status: store.status(tool), store: store, prefs: prefs, actions: actions)
            }
            FooterView(store: store, actions: actions)
        }
        .padding(.horizontal, 14)
        .padding(.top, Self.contentTopPadding)
        .padding(.bottom, 10)
        .frame(width: prefs.panelWidth.points, alignment: .leading)
    }
}

/// Copies a card or the whole panel to the pasteboard as a 2x PNG with a small wordmark, for Slack or a bug report.
@MainActor
enum CardImage {
    static func copy<Content: View>(_ content: Content, width: CGFloat) {
        let framed = VStack(alignment: .leading, spacing: 8) {
            content
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.33percent").font(.caption2)
                Text(verbatim: AppInfo.name).font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: width)
        .background(Color.black)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        guard let image = renderer.nsImage else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        Oracle.shared.emit("clipboard", ["kind": "image", "width": Int(image.size.width), "height": Int(image.size.height)])
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
    @State private var range: Range = .today
    @Environment(\.density) private var density

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
        selection.providers.first.map { CostDetail(provider: $0, range: range.costRange, claude: store.cost) }
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
            lines.append((text: burnLine.replacingOccurrences(of: "-", with: "\u{2011}"), quiet: false))
        }
        if store.prefs.showDetails {
            lines += detailLines.map { (text: $0, quiet: false) }
            lines += detailCaptions.map { (text: $0, quiet: true) }
        }
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
            HStack {
                Text(L("Cost")).font(.headline)
                Spacer()
                if store.costScanning {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text(L("Pricing local files")).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            // Six segments at the regular control size want more width than the card has, and a segmented picker
            // paints its whole bezel however little it is offered: the card grew to fit it and hung past the
            // panel's right margin. The small control size fits the titles inside the card's own text column.
            Picker(L("Range"), selection: $range) {
                ForEach(Range.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            // Centred against the ring: the column beside it is the legend alone, which is shorter than the ring
            // on every plan anyone has, and top-aligning it left the card's right half empty under two rows.
            VStack(alignment: .leading, spacing: density.rowSpacing) {
                HStack(alignment: .center, spacing: 16) {
                    ZStack {
                        // strokeBorder and an inset arc, never stroke: a stroked path is centred on the circle, so
                        // half the 13 pt line falls outside the frame and the ring hangs past the card's text margin.
                        Circle().strokeBorder(.white.opacity(AccessibilityDisplay.shared.contrast ? 0.25 : 0.1), lineWidth: Self.ringWidth)
                        ForEach(arcs) { arc in
                            Circle()
                                .inset(by: Self.ringWidth / 2)
                                .trim(from: arc.start, to: arc.end)
                                .stroke(arcColor(arc), style: StrokeStyle(lineWidth: Self.ringWidth, lineCap: .butt))
                                .rotationEffect(.degrees(-90))
                        }
                        if let budget {
                            Rectangle()
                                .fill(.white.opacity(AccessibilityDisplay.shared.contrast ? 1 : 0.8))
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
                            Text(unit).font(.caption2).foregroundStyle(.secondary)
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
                            Text(L("no cost yet")).font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(providers) { provider in
                            let totals = provider.totals(range.costRange)
                            HStack(spacing: 6) {
                                Circle().fill(provider.tool.color).frame(width: 7, height: 7)
                                Text(verbatim: provider.tool.displayName).font(.callout).lineLimit(1)
                                Text(provider.source.shortLabel).font(.caption2).foregroundStyle(.secondary).lineLimit(1).layoutPriority(-1)
                                Spacer(minLength: 4)
                                // Both figures keep a column of their own, so a shorter amount on one row does not
                                // drag that row's percentage in from the one above it.
                                if let share = share(provider) {
                                    Text(verbatim: "\(Int((share * 100).rounded()))%")
                                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
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
                                .foregroundStyle(note.quiet ? Caption.style : AnyShapeStyle(.secondary))
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
        .modifier(CardBackground())
        .contextMenu {
            Button(L("Copy as image")) { CardImage.copy(SpendCard(store: store), width: store.prefs.panelWidth.points - 28) }
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
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(verbatim: "\(Int((share.cost / max(total, 0.0001) * 100).rounded()))%")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
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
    @Environment(\.density) private var density

    var body: some View {
        VStack(alignment: .leading, spacing: density.lineSpacing) {
            ForEach(advice) { item in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    // Leading, not centred: the symbol is the bullet and starts on the card's text margin
                    // whatever glyph it is.
                    Image(systemName: item.symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(item.priority.color)
                        .frame(width: 13, alignment: .leading)
                    Text(item.text)
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
                        .foregroundStyle(.secondary)
                        .help(url.host ?? url.absoluteString)
                        .accessibilityLabel(L("Open %@", url.host ?? url.absoluteString))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CardBackground())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("Advice"))
        .accessibilityValue(advice.map { Spoken.phrase($0.text) }.joined(separator: " "))
    }
}

struct ToolCard: View {
    let tool: ToolID
    let status: ToolStatus
    let store: UsageStore
    let prefs: Preferences
    var actions: NotchActions? = nil
    @Environment(\.density) private var density

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
                Image(systemName: tool.symbolName).foregroundStyle(tool.color).font(.subheadline.weight(.semibold))
                Text(tool.displayName).font(.headline)
                if let plan = status.reading?.plan {
                    Text(plan).font(.subheadline).foregroundStyle(.secondary)
                }
                // The rings recolour because they have no room for anything else. A card has room for words, so it
                // says which state it is in rather than leaving the reader to learn a hue.
                if let signal = store.signal(tool) {
                    Label(signal.cardText, systemImage: signal.symbolName)
                        .font(.caption)
                        .foregroundStyle(Palette.calm)
                        .accessibilityLabel(signal.cardText)
                }
                Spacer()
                Button {
                    actions?.open(ProviderLinks.usage(tool))
                } label: {
                    Image(systemName: "arrow.up.right.square").font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("Open %@'s usage page", tool.displayName))
                .accessibilityLabel(L("Open %@'s usage page", tool.displayName))
                if let problem = status.problem {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.warn)
                        .help(problem)
                        .accessibilityLabel(problem)
                }
            }
            if tool == .claude {
                SessionLine(store: store)
            }
            if let reading = status.reading {
                ForEach(prefs.panelWindows(of: reading)) { window in
                    MeterRow(toolName: tool.displayName, window: window, color: tool.color, prefs: prefs,
                             stale: status.staleReading != nil, hideFigures: store.hidesFigures,
                             drain: store.drain(for: tool, window: window), runOut: store.runOut(for: tool, window: window),
                             metering: tool == .claude && window.id == "five_hour" && prefs.showSpend ? store.cost?.sessionMetering : nil)
                }
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
                .font(.caption).foregroundStyle(.secondary)
            case .idle(let message):
                Text(message).font(.caption).foregroundStyle(.secondary)
            case .needsAttention(let message, _):
                Label(message, systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.caption).foregroundStyle(Palette.warn)
            case .failed(let message, _):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            case .offline:
                Label(L("Offline, retrying"), systemImage: "wifi.slash")
                    .font(.caption).foregroundStyle(.secondary)
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
        .modifier(CardBackground())
        .contextMenu {
            Button(L("Refresh")) { Keychain.setInteractive(tool == .claude); Task { await store.refresh(tool, force: true) } }
            Button(L("Copy as image")) {
                CardImage.copy(ToolCard(tool: tool, status: status, store: store, prefs: prefs).environment(\.density, density), width: prefs.panelWidth.points - 28)
            }
            Divider()
            Button(L("Open %@'s usage page", tool.displayName)) { actions?.open(ProviderLinks.usage(tool)) }
            if let status = ProviderLinks.status(tool) {
                Button(L("Open %@'s status page", tool.displayName)) { actions?.open(status) }
            }
        }
    }
}

/// "2 sessions · working 2m 10s" and, while the status line reports, "Context 62% · Opus · $1.23 this session".
private struct SessionLine: View {
    let store: UsageStore
    @Environment(\.density) private var density

    var body: some View {
        let sessions = store.sessions
        let statusline = store.statusline
        if sessions.count > 0 || store.contextUsed != nil {
            TimelineView(.periodic(from: .now, by: sessions.working.isEmpty && sessions.waiting.isEmpty ? 60 : 1)) { context in
                VStack(alignment: .leading, spacing: density.lineSpacing) {
                    if sessions.count > 0 {
                        Text(Self.sessionsText(sessions, now: context.date))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if let place = Self.placeText(sessions) {
                        HStack(spacing: 5) {
                            Text(place.text).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            if let badge = place.badge {
                                Text(badge)
                                    .font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Capsule().fill(.white.opacity(0.14)))
                                    .accessibilityLabel(L("permission mode %@", badge))
                            }
                            if let pr = place.pr {
                                Button { store.openURL(pr) } label: { Image(systemName: "arrow.up.right.square").font(.caption2) }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                                    .help(pr.absoluteString)
                                    .accessibilityLabel(L("Open the pull request"))
                            }
                        }
                    }
                    if let contextUsed = store.contextUsed {
                        Text(Self.contextText(contextUsed, statusline: statusline, hideFigures: store.hidesFigures))
                            .font(.caption).foregroundStyle(contextUsed >= 0.9 ? Palette.warn : .secondary).monospacedDigit()
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
        return (parts.joined(separator: " · "), session.prURL.flatMap(URL.init(string:)), Hook.permissionBadge(session.permissionMode))
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
    @Environment(\.density) private var density

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
        VStack(alignment: .leading, spacing: density.lineSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(window.label).font(.subheadline.weight(.semibold))
                if let tag = window.source.tag {
                    Text(tag)
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(.white.opacity(0.12)))
                        .foregroundStyle(.secondary)
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
                    .font(.caption).foregroundStyle(pace.status.noteColor)
                }
            }
            if let used = window.usedFraction {
                Meter(
                    fraction: used,
                    tick: window.resetsAt.flatMap { resetsAt in window.periodDuration.flatMap { Pace.elapsedFraction(resetsAt: resetsAt, period: $0) } },
                    color: pace?.status.meterColor ?? color
                )
                HStack {
                    if let unused {
                        Text(unused).monospacedDigit()
                    } else {
                        Text(usage ?? "").monospacedDigit()
                            .help(L("Click to show %@", prefs.usageDisplay == .used ? UsageDisplay.left.title : UsageDisplay.used.title))
                            .onTapGesture { flipUsage() }
                            .accessibilityAction(named: L("Flip used and left")) { flipUsage() }
                        Spacer()
                        Text(reset).monospacedDigit()
                            .help(L("Click to show %@", prefs.resetDisplay == .countdown ? ResetDisplay.exact.title : ResetDisplay.countdown.title))
                            .onTapGesture { flipReset() }
                            .accessibilityAction(named: L("Flip countdown and exact time")) { flipReset() }
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
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
                .font(.caption).foregroundStyle(.secondary)
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
                Capsule().fill(.white.opacity(AccessibilityDisplay.shared.contrast ? 0.28 : 0.12))
                if fraction > 0 {
                    Capsule().fill(color).frame(width: max(6, width * CGFloat(min(1, fraction))))
                }
                if let tick {
                    Rectangle()
                        .fill(.white.opacity(AccessibilityDisplay.shared.contrast ? 1 : 0.7))
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
                        .fill(day.cost > 0 ? color : color.opacity(0.3))
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
                        .fill(point.map { $0 >= 0.95 ? Palette.danger : $0 >= 0.8 ? Palette.warn : color } ?? color.opacity(0.2))
                        .frame(width: barWidth, height: max(2, geometry.size.height * CGFloat(point ?? 0)))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottomLeading)
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}

struct FooterView: View {
    let store: UsageStore
    let actions: NotchActions
    @Environment(\.density) private var density

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            let next = nextUpdate(now: context.date)
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: "\(AppInfo.name) \(AppInfo.version)").monospacedDigit()
                    Button {
                        actions.refresh()
                    } label: {
                        Text(next).monospacedDigit()
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("r", modifiers: .command)
                    .help(L("Refresh now (⌘R)"))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(AppInfo.name) \(AppInfo.version)")
                .accessibilityValue(Spoken.phrase(next))
                .accessibilityAction(named: L("Refresh now")) { actions.refresh() }
                Spacer()
                Button {
                    actions.showOptions()
                } label: {
                    HStack(spacing: 4) {
                        Text(L("Options"))
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            // The footer carries no card of its own, so it takes the cards' inner padding: the version line and
            // the Options button end on the same two margins as everything above them.
            .padding(.horizontal, density.cardPadding)
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
