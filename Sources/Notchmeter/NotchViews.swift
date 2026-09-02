import SwiftUI

extension ToolID {
    var color: Color {
        switch self {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: Color(red: 0.36, green: 0.83, blue: 0.62)
        case .cursor: Color(red: 0.65, green: 0.55, blue: 0.98)
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

private struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.07)))
    }
}

// MARK: - Rings (compact states)

struct RingView: View {
    var fraction: Double?
    var color: Color
    var lineWidth: CGFloat = 3
    /// Drawn as a cap on the arc's end: hollow when on track, filled when behind. Shape, not colour, carries it.
    var pace: Pace.Status? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.22), lineWidth: lineWidth)
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
                    .stroke(color.opacity(0.55), style: StrokeStyle(lineWidth: lineWidth, dash: [2, 3]))
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.4), value: fraction)
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

/// One tool's rings. The presence level sets how loud they are (Presence.swift): 14 pt at 70 % when quiet,
/// 18 pt when legible, 18 pt with a 1.5 s opacity pulse when urgent; no pulse under Reduce Motion.
struct CompactRings: View {
    let tool: ToolID
    let status: ToolStatus
    var awaitingInput = false
    var presence: PresenceLevel = .legible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        let windows = status.reading?.windows ?? []
        let quiet = presence == .quiet
        ZStack {
            RingView(fraction: windows.first?.usedFraction, color: tool.color, lineWidth: quiet ? 2 : 2.5,
                     pace: windows.first.flatMap { Pace.status(for: $0) })
                .frame(width: quiet ? 14 : 18, height: quiet ? 14 : 18)
            if windows.count > 1 {
                RingView(fraction: windows[1].usedFraction, color: tool.color.opacity(0.8), lineWidth: quiet ? 1.5 : 2,
                         pace: Pace.status(for: windows[1]))
                    .frame(width: quiet ? 8 : 10, height: quiet ? 8 : 10)
            }
            if status.problem != nil {
                Image(systemName: "exclamationmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Palette.warn)
            }
            if awaitingInput {
                Circle()
                    .fill(.white)
                    .frame(width: 5, height: 5)
                    .overlay(Circle().stroke(.black, lineWidth: 1))
                    .offset(x: 7, y: -7)
            }
        }
        .frame(width: 18, height: 18)
        .opacity((status.reading == nil && status.problem == nil ? 0.5 : 1) * (quiet ? 0.7 : 1))
        .animation(reduceMotion ? nil : .snappy(duration: 0.4), value: presence)
        .opacity(pulsing ? 0.4 : 1)
        .animation(pulsing ? .easeInOut(duration: 1.5).repeatForever(autoreverses: true) : .easeInOut(duration: 0.3), value: pulsing)
        .onChange(of: presence, initial: true) { updatePulse() }
        .onChange(of: reduceMotion) { updatePulse() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tool.displayName)
        .accessibilityValue(Spoken.status(status, awaitingInput: awaitingInput))
    }

    private func updatePulse() {
        pulsing = presence == .urgent && !reduceMotion
    }
}

/// Rings beside the physical notch.
struct NotchCompactView: View {
    enum Side { case leading, trailing }

    let store: UsageStore
    let side: Side

    private var tools: [ToolID] {
        let mine: [ToolID] = side == .leading ? [.claude] : [.codex, .cursor]
        return mine.filter(store.isShown)
    }

    var body: some View {
        let presence = store.presence
        HStack(spacing: 7) {
            ForEach(tools, id: \.self) { tool in
                CompactRings(tool: tool, status: store.status(tool), awaitingInput: store.isAwaitingInput(tool), presence: presence)
            }
        }
        .padding(.horizontal, tools.isEmpty ? 0 : 6)
    }
}

/// The rings inside the pill that sits on a screen edge (Codenotch-style layouts); EdgePanelRoot draws the pill.
struct EdgeCompactView: View {
    let store: UsageStore
    let edge: PanelEdge

    var body: some View {
        let tools = store.visibleTools
        let presence = store.presence
        let rings = ForEach(tools, id: \.self) { tool in
            CompactRings(tool: tool, status: store.status(tool), awaitingInput: store.isAwaitingInput(tool), presence: presence)
        }
        Group {
            if edge == .bottom {
                HStack(spacing: 10) { rings }.padding(.horizontal, 12).padding(.vertical, 7)
            } else {
                VStack(spacing: 10) { rings }.padding(.vertical, 12).padding(.horizontal, 7)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AppInfo.name)
        .accessibilityValue(tools.map { "\($0.displayName): \(Spoken.status(store.status($0), awaitingInput: store.isAwaitingInput($0)))" }.joined(separator: ". "))
    }
}

// MARK: - Expanded panel

struct NotchExpandedView: View {
    let store: UsageStore
    let prefs: Preferences
    let actions: NotchActions

    var body: some View {
        let tools = store.visibleTools
        VStack(alignment: .leading, spacing: 10) {
            if prefs.showSpend, tools.contains(.claude) {
                SpendCard(store: store)
            }
            if tools.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connect an assistant to get started")
                        .font(.callout)
                    Text("Install and sign in to Claude Code, Codex or Cursor; its meters appear here.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .modifier(CardBackground())
            }
            ForEach(tools, id: \.self) { tool in
                ToolCard(tool: tool, status: store.status(tool), prefs: prefs,
                         trend: tool == .claude && prefs.showSpend ? store.cost?.daily : nil,
                         awaitingInput: store.isAwaitingInput(tool))
            }
            FooterView(store: store, actions: actions)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(width: 380, alignment: .leading)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }
}

struct SpendCard: View {
    enum Range: String, CaseIterable, Identifiable {
        case today = "Today", yesterday = "Yesterday", month = "30 Days"
        var id: String { rawValue }
    }

    let store: UsageStore
    @State private var range: Range = .today

    private var amount: Double? {
        guard let cost = store.cost else { return nil }
        switch range {
        case .today: return cost.today
        case .yesterday: return cost.yesterday
        case .month: return cost.last30Days
        }
    }

    private var burnLine: String? {
        guard let cost = store.cost, let burn = cost.burnMultiple else { return nil }
        return "Last hour \(Money.dollars(cost.lastHour)) · \(Burn.multiple(burn)) your usual"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Cost").font(.system(size: 15, weight: .semibold))
                Spacer()
                if store.costScanning {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("Pricing local transcripts").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Picker("Range", selection: $range) {
                ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack(spacing: 20) {
                ZStack {
                    Circle().stroke(.white.opacity(0.1), lineWidth: 13)
                    Circle()
                        .trim(from: 0.012, to: 0.988)
                        .stroke(ToolID.claude.color, style: StrokeStyle(lineWidth: 13, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 1) {
                        Text(amount.map { Money.dollars($0, cents: false) } ?? "—")
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("dollars").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 92, height: 92)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Circle().fill(ToolID.claude.color).frame(width: 7, height: 7)
                        Text("Claude").font(.callout)
                        Spacer()
                        Text(amount.map { Money.dollars($0) } ?? "—").font(.callout).monospacedDigit()
                    }
                    if let burnLine {
                        Text(burnLine)
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if let cost = store.cost, !cost.unpricedModels.isEmpty {
                        Text("Unpriced: \(cost.unpricedModels.sorted().joined(separator: ", "))")
                            .font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                    }
                    Text("Claude Code sessions at API list prices")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 2)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Cost, \(range.rawValue)")
            .accessibilityValue(Spoken.line(amount.map { "Claude \(Money.dollars($0))" } ?? "no cost yet", burnLine, "Claude Code sessions at API list prices"))
        }
        .modifier(CardBackground())
    }
}

struct ToolCard: View {
    let tool: ToolID
    let status: ToolStatus
    let prefs: Preferences
    let trend: [DailySpend]?
    var awaitingInput = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: tool.symbolName).foregroundStyle(tool.color).font(.system(size: 13, weight: .semibold))
                Text(tool.displayName).font(.system(size: 15, weight: .semibold))
                if let plan = status.reading?.plan {
                    Text(plan).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if let problem = status.problem {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.warn)
                        .help(problem)
                        .accessibilityLabel(problem)
                }
            }
            .padding(.leading, 2)
            if awaitingInput {
                Label("Claude Code is waiting for your input", systemImage: "hand.raised.fill")
                    .font(.caption)
                    .foregroundStyle(Palette.calm)
                    .padding(.leading, 2)
            }
            VStack(alignment: .leading, spacing: 12) {
                if let reading = status.reading {
                    ForEach(reading.windows) { window in
                        MeterRow(toolName: tool.displayName, window: window, color: tool.color, prefs: prefs)
                    }
                    .opacity(status.problem == nil ? 1 : 0.55)
                    if let observed = reading.observedAt, Date().timeIntervalSince(observed) > 600 {
                        Text("As of \(RelativeTime.ago(observed))").font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
                switch status {
                case .waiting:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Waiting for the first reading")
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
                default:
                    EmptyView()
                }
                if let trend, trend.contains(where: { $0.cost > 0 }) {
                    HStack {
                        Text("Usage Trend").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Sparkline(series: trend, color: tool.color).frame(width: 160, height: 22)
                    }
                }
            }
            .modifier(CardBackground())
        }
    }
}

struct MeterRow: View {
    let toolName: String
    let window: LimitWindow
    let color: Color
    let prefs: Preferences

    var body: some View {
        let pace = Pace.note(for: window)
        let usage = prefs.usageLine(for: window)
        let reset = window.usedFraction == nil
            ? (window.note ?? prefs.resetLine(for: window))
            : (window.resetsAt == nil ? (window.note ?? "") : prefs.resetLine(for: window))
        let detail = window.usedFraction != nil && window.resetsAt != nil ? window.note : nil
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                if let pace {
                    HStack(spacing: 3) {
                        if let symbol = pace.status.symbolName {
                            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
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
                    Text(usage ?? "").monospacedDigit()
                    Spacer()
                    Text(reset).monospacedDigit()
                }
                .font(.caption).foregroundStyle(.secondary)
                if let detail {
                    Text(detail).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                }
            } else {
                Meter(fraction: 0, tick: nil, color: .clear)
                HStack {
                    Text("—")
                    Spacer()
                    Text(reset).monospacedDigit()
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(toolName) \(window.label)")
        .accessibilityValue(Spoken.line(usage, reset, detail, pace?.text))
    }
}

struct Meter: View {
    let fraction: Double
    let tick: Double?
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                if fraction > 0 {
                    Capsule().fill(color).frame(width: max(6, width * CGFloat(min(1, fraction))))
                }
                if let tick {
                    Rectangle()
                        .fill(.white.opacity(0.7))
                        .frame(width: 2, height: 11)
                        .offset(x: min(max(width * CGFloat(tick) - 1, 0), max(width - 2, 0)))
                }
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.4), value: fraction)
        }
        .frame(height: 6)
    }
}

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
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottomLeading)
        }
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
                    Text("\(AppInfo.name) \(AppInfo.version)").monospacedDigit()
                    Text(next).monospacedDigit()
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(AppInfo.name) \(AppInfo.version)")
                .accessibilityValue(Spoken.phrase(next))
                Spacer()
                Button {
                    actions.showOptions()
                } label: {
                    HStack(spacing: 4) {
                        Text("Options")
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
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
        guard let next = store.nextUpdate else { return "Waiting for the first reading" }
        let seconds = next.timeIntervalSince(now)
        if seconds <= 5 { return "Updating…" }
        let line = "Next update in \(ResetText.duration(seconds))"
        return store.scheduleNote.map { "\(line) · \($0)" } ?? line
    }
}
