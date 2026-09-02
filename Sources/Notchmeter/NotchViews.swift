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
    func body(content: Content) -> some View {
        content.font(.caption2).foregroundStyle(AccessibilityDisplay.shared.contrast ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
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

    var body: some View {
        let contrast = AccessibilityDisplay.shared.contrast
        ZStack {
            Circle()
                .stroke(color.opacity(contrast ? 0.45 : 0.22), lineWidth: lineWidth)
            if let fraction {
                let shown = max(0.015, min(1, fraction))
                Circle()
                    .trim(from: 0, to: CGFloat(shown))
                    .stroke(tint(fraction), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if let pace, pace != .ahead {
                    GeometryReader { geometry in
                        let radius = min(geometry.size.width, geometry.size.height) / 2 - lineWidth / 2
                        let angle = -Double.pi / 2 + 2 * .pi * shown
                        PaceCap(filled: pace == .behind, color: pace == .behind ? Palette.danger : Palette.warn, diameter: lineWidth * 2.2)
                            .position(x: geometry.size.width / 2 + radius * cos(angle), y: geometry.size.height / 2 + radius * sin(angle))
                    }
                }
            } else {
                Circle()
                    .stroke(color.opacity(contrast ? 0.8 : 0.55), style: StrokeStyle(lineWidth: lineWidth, dash: [2, 3]))
            }
        }
        .animation(AccessibilityDisplay.shared.motionReduced ? nil : .snappy(duration: 0.4), value: fraction)
    }

    private func tint(_ fraction: Double) -> Color {
        fraction >= 0.95 ? Palette.danger : fraction >= 0.8 ? Palette.warn : color
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

/// One tool's rings: the main window outside, the second inside (Preferences.ringWindows), a "!" for a problem,
/// a white dot (with a count past one) while sessions wait for the user, and a context arc while the Claude Code
/// status line reports one. The presence level sets the size (Presence.swift): 14 pt when quiet, 18 pt otherwise,
/// and a 4 pt dot when hidden.
struct CompactRings: View {
    let tool: ToolID
    let status: ToolStatus
    var windows: [LimitWindow] = []
    var waiting = 0
    var contextUsed: Double? = nil
    var presence: PresenceLevel = .legible

    var body: some View {
        let quiet = presence == .quiet
        ZStack {
            if presence == .hidden {
                Circle().fill(tool.color.opacity(0.8)).frame(width: 4, height: 4)
            } else {
                RingView(fraction: windows.first?.usedFraction, color: tool.color, lineWidth: quiet ? 2 : 2.5,
                         pace: windows.first.flatMap { Pace.status(for: $0) })
                    .frame(width: quiet ? 14 : 18, height: quiet ? 14 : 18)
                if windows.count > 1 {
                    RingView(fraction: windows[1].usedFraction, color: tool.color.opacity(0.8), lineWidth: quiet ? 1.5 : 2,
                             pace: Pace.status(for: windows[1]))
                        .frame(width: quiet ? 8 : 10, height: quiet ? 8 : 10)
                }
                if let contextUsed {
                    ContextArc(fraction: contextUsed, diameter: quiet ? 18 : 22)
                }
                if status.problem != nil {
                    ProblemMark()
                }
                if waiting > 0 {
                    WaitingDot(count: waiting).offset(x: 7, y: -7)
                }
            }
        }
        .frame(width: 18, height: 18)
        .opacity(status.reading == nil && status.problem == nil ? 0.5 : 1)
        .animation(AccessibilityDisplay.shared.motionReduced ? nil : .snappy(duration: 0.4), value: presence)
    }
}

/// The digits beside a ring, or in its place (CompactStyle): 11 pt semibold rounded, monospaced, in the tool's
/// colour until a window is on track or behind, when that window's figure takes the status colour. With no ring
/// to carry them, the problem mark and the waiting dot sit beside the digits. The size is fixed: the digits must
/// fit beside the notch whatever the text size setting.
struct CompactNumbers: View {
    let tool: ToolID
    let status: ToolStatus
    var windows: [LimitWindow] = []
    let display: UsageDisplay
    var countdown = false
    var badges = false
    var waiting = 0

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
                if badges, waiting > 0 {
                    WaitingDot(count: waiting)
                }
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .monospacedDigit()
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

private struct ProblemMark: View {
    var body: some View {
        Image(systemName: "exclamationmark")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(Palette.warn)
    }
}

private struct WaitingDot: View {
    var count = 1

    var body: some View {
        ZStack {
            Circle()
                .fill(.white)
                .frame(width: count > 1 ? 9 : 5, height: count > 1 ? 9 : 5)
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
struct CompactReadout: View {
    let tool: ToolID
    let status: ToolStatus
    let style: CompactStyle
    let display: UsageDisplay
    var windows: [LimitWindow] = []
    var waiting = 0
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
        .opacity(presence == .quiet && !AccessibilityDisplay.shared.contrast ? 0.7 : 1)
        .animation(reduceMotion ? nil : .snappy(duration: 0.4), value: presence)
        .opacity(pulsing ? 0.4 : 1)
        .animation(pulsing ? .easeInOut(duration: Self.pulseDuration).repeatCount(Self.pulseCycles * 2 - 1, autoreverses: true) : .easeInOut(duration: 0.3), value: pulsing)
        .onChange(of: presence, initial: true) { updatePulse() }
        .onChange(of: reduceMotion) { updatePulse() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tool.displayName)
        .accessibilityValue(Spoken.status(status, awaitingInput: waiting > 0))
    }

    @ViewBuilder private var parts: some View {
        let showNumbers = style.showsNumbers && !hideFigures && presence != .hidden
        if let apiKeyCost {
            if showNumbers {
                Text(verbatim: apiKeyCost)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tool.color)
            }
        } else {
            if style.showsRings || hideFigures || presence == .hidden {
                CompactRings(tool: tool, status: status, windows: windows, waiting: waiting, contextUsed: contextUsed, presence: presence)
            }
            if showNumbers {
                CompactNumbers(tool: tool, status: status, windows: windows, display: display, countdown: countdown, badges: !style.showsRings, waiting: waiting)
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
    func readout(_ tool: ToolID, presence: PresenceLevel, axis: Axis = .horizontal) -> CompactReadout {
        let status = status(tool)
        let apiKeyCost = tool == .claude && claudeOnAPIKey ? Money.dollars(cost?.totals(.month).cost ?? 0, cents: false) : nil
        return CompactReadout(tool: tool, status: status, style: prefs.compactStyle, display: prefs.usageDisplay,
                              windows: status.reading.map(prefs.ringWindows) ?? [], waiting: tool == .claude ? waitingCount : 0,
                              contextUsed: tool == .claude ? contextUsed : nil, countdown: prefs.showResetCountdown, hideFigures: hidesFigures,
                              presence: presence, axis: axis, apiKeyCost: apiKeyCost)
    }

    /// The tools with a compact readout: Claude on an API key has nothing to draw unless the digits are shown.
    var compactTools: [ToolID] {
        visibleTools.filter { !($0 == .claude && claudeOnAPIKey && !prefs.compactStyle.showsNumbers) }
    }
}

/// The readouts beside the physical notch: the first visible tool on its left, the rest on its right
/// (Preferences.toolOrder). NotchController measures this view to place the hover region, so its width follows
/// the style. The strip refers to the physical notch, so it is laid out left to right in every language.
struct NotchCompactView: View {
    enum Side { case leading, trailing }

    let store: UsageStore
    let side: Side

    private var tools: [ToolID] {
        let visible = store.compactTools
        switch store.prefs.compactSide {
        case .trailing: return side == .leading ? [] : visible
        case .leading: return side == .leading ? visible : []
        case .split:
            // Half either side, so the strip reads as centred on the notch rather than hanging off one edge.
            let left = Int((Double(visible.count) / 2).rounded())
            return side == .leading ? Array(visible.prefix(left)) : Array(visible.dropFirst(left))
        }
    }

    var body: some View {
        let presence = store.presence
        HStack(spacing: store.prefs.compactStyle.showsNumbers ? 9 : 7) {
            ForEach(tools, id: \.self) { tool in
                store.readout(tool, presence: presence)
            }
        }
        .padding(.horizontal, tools.isEmpty ? 0 : 6)
        .environment(\.layoutDirection, .leftToRight)
    }
}

/// The readouts inside the pill that sits on a screen edge (Codenotch-style layouts); EdgePanelRoot draws the
/// pill. A side pill stacks each tool's digits under its ring; the top and bottom bars run them side by side.
struct EdgeCompactView: View {
    let store: UsageStore
    let edge: PanelEdge

    var body: some View {
        let tools = store.compactTools
        let presence = store.presence
        let horizontal = edge == .bottom || edge == .top
        let readouts = ForEach(tools, id: \.self) { tool in
            store.readout(tool, presence: presence, axis: horizontal ? .horizontal : .vertical)
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
        .accessibilityValue(tools.map { "\($0.displayName): \(Spoken.status(store.status($0), awaitingInput: store.isAwaitingInput($0)))" }.joined(separator: ". "))
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
        .padding(.top, 8)
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
    private var selection: CostSelection {
        CostSelection(all: store.cost?.providers ?? [], order: store.prefs.toolOrder, carried: store.prefs.costCardTools)
    }

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

    private var burnLine: String? {
        let selection = selection
        guard let burn = selection.burnMultiple else { return nil }
        return L("Last hour %1$@ · %2$@ your 30-day average", Money.dollars(selection.lastHour), Burn.multiple(burn))
    }

    private var tokensLine: String? {
        guard let totals, totals.tokens.total > 0 else { return nil }
        guard let share = totals.tokens.cacheReadShare else { return Money.tokens(totals.tokens.total) }
        return L("%1$@ · %2$ld%% cache reads", Money.tokens(totals.tokens.total), Int((share * 100).rounded()))
    }

    private var cacheWritesLine: String? {
        guard let totals, let share = CacheTTL.oneHourShare(totals.tokens) else { return nil }
        return L("cache writes %1$ld%% 1-hour · %2$ld%% 5-minute", Int((share * 100).rounded()), Int(((1 - share) * 100).rounded()))
    }

    /// The Claude weekly window, which is where the week's boundary comes from: its own spend, and what one per
    /// cent of the window has cost. Not a total — the donut above it is. Absent while the card is not carrying
    /// Claude, whose window it describes.
    private var weekLine: String? {
        guard range == .week, selection.provider(.claude) != nil, let week = store.cost?.week else { return nil }
        let since = ResetText.dayPhrase(week.start, now: Date(), calendar: .current)
        guard let perPercent = week.perPercent else { return L("Claude %1$@ since %2$@", Money.dollars(week.cost), since) }
        return L("Claude %1$@ since %2$@ · %3$@ per 1%% of weekly", Money.dollars(week.cost), since, Money.dollars(perPercent))
    }

    private var budgetLine: String? {
        guard let budget else { return nil }
        return L("Month %1$@ of a %2$@ budget", Money.dollars(selection.totals(.month).cost, cents: false), Money.dollars(budget.budget, cents: false))
    }

    private var blockLine: String? {
        guard selection.provider(.claude) != nil, let block = store.cost?.block, block.cost > 0 || block.tokens.total > 0 else { return nil }
        guard let rate = block.tokensPerMinute else { return L("This session block %@", Money.dollars(block.cost)) }
        return L("This session block %1$@ · %2$@/min", Money.dollars(block.cost), Money.tokens(Int(rate.rounded())).replacingOccurrences(of: " tokens", with: ""))
    }

    private var sinceLine: String? {
        guard range == .ninetyDays, selection.provider(.claude) != nil, let cost = store.cost, let first = cost.firstUse else { return nil }
        return L("Claude since %1$@: %2$@", ResetText.dayPhrase(first, now: Date(), calendar: .current), Money.dollars(cost.sinceFirstUse))
    }

    private var projectsLine: String? {
        guard let totals, !totals.projects.isEmpty else { return nil }
        let top = totals.projects.prefix(2).map { "\($0.name == CostShare.other ? L("Other") : $0.name) \(Money.dollars($0.cost, cents: $0.cost < 10))" }.joined(separator: " · ")
        return L("Top: %@", top)
    }

    /// One row per assistant the card carries, in the user's order. One that cannot report spend, or that the
    /// card is set to leave out, is absent rather than a zero row.
    private var providers: [ProviderCost] { selection.providers }

    /// The lines the card keeps behind Show details, so the donut, the legend and the burn line hold the height
    /// budget on their own however many assistants report.
    private var detailLines: [String] {
        [budgetLine, weekLine, sinceLine, blockLine].compactMap { $0 }
    }

    private var detailCaptions: [String] {
        [tokensLine, cacheWritesLine, projectsLine].compactMap { $0 }
    }

    /// What the figures are: this Mac's arithmetic over published rates, the vendor's own export, or both.
    private var sourceLine: String {
        providers.contains { !$0.source.isEstimate }
            ? L("Local files at published list rates; an export is the vendor's own figure")
            : L("Priced from local files at published list rates")
    }

    /// A tool whose figures are stale or partial says so under its row.
    private var problemLines: [String] {
        providers.compactMap { provider in provider.problem.map { "\(provider.tool.displayName): \($0)" } }
    }

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
        VStack(alignment: .leading, spacing: density.cardSpacing) {
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
            Picker(L("Range"), selection: $range) {
                ForEach(Range.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack(spacing: 16) {
                ZStack {
                    Circle().stroke(.white.opacity(AccessibilityDisplay.shared.contrast ? 0.25 : 0.1), lineWidth: 13)
                    ForEach(arcs) { arc in
                        Circle()
                            .trim(from: arc.start, to: arc.end)
                            .stroke(arcColor(arc), style: StrokeStyle(lineWidth: 13, lineCap: .butt))
                            .rotationEffect(.degrees(-90))
                    }
                    if let budget {
                        Rectangle()
                            .fill(.white.opacity(AccessibilityDisplay.shared.contrast ? 1 : 0.8))
                            .frame(width: 2, height: 15)
                            .offset(y: -density.costRing / 2)
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
                VStack(alignment: .leading, spacing: 6) {
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
                            if let share = share(provider) {
                                Text(verbatim: "\(Int((share * 100).rounded()))%")
                                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Text(Self.rowFigure(mode: mode, totals: totals)).font(.callout).monospacedDigit()
                        }
                    }
                    ForEach(problemLines, id: \.self) { line in
                        Text(line).modifier(Caption()).lineLimit(2)
                    }
                    if let burnLine {
                        // A non-breaking hyphen keeps "30-day" whole when the line wraps.
                        Text(burnLine.replacingOccurrences(of: "-", with: "\u{2011}"))
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if store.prefs.showDetails {
                        ForEach(detailLines, id: \.self) { line in
                            Text(line).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        }
                        ForEach(detailCaptions, id: \.self) { line in
                            Text(line).modifier(Caption()).monospacedDigit().lineLimit(2)
                        }
                    }
                    if !selection.unpricedModels.isEmpty {
                        Text(L("Unpriced: %@", selection.unpricedModels.sorted().joined(separator: ", ")))
                            .modifier(Caption()).lineLimit(2)
                    }
                    Text(sourceLine).modifier(Caption()).lineLimit(2)
                }
            }
            .padding(.top, 2)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L("Cost, %@", range.title))
            .accessibilityValue(Spoken.line("\(headline) \(unit)", providerSpoken, burnLine, problemLines.first,
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
        VStack(alignment: .leading, spacing: 3) {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(advice) { item in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: item.symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(item.priority.color)
                        .frame(width: 13)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: tool.symbolName).foregroundStyle(tool.color).font(.subheadline.weight(.semibold))
                Text(tool.displayName).font(.headline)
                if let plan = status.reading?.plan {
                    Text(plan).font(.subheadline).foregroundStyle(.secondary)
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
            .padding(.leading, 2)
            VStack(alignment: .leading, spacing: density.meterSpacing) {
                if tool == .claude {
                    SessionLine(store: store)
                }
                if let reading = status.reading {
                    ForEach(prefs.shownWindows(of: reading)) { window in
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
        }
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

    var body: some View {
        let sessions = store.sessions
        let statusline = store.statusline
        if sessions.count > 0 || store.contextUsed != nil {
            TimelineView(.periodic(from: .now, by: sessions.working.isEmpty && sessions.waiting.isEmpty ? 60 : 1)) { context in
                VStack(alignment: .leading, spacing: 2) {
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
        VStack(alignment: .leading, spacing: 5) {
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
            .padding(.horizontal, 4)
            .padding(.top, 2)
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
