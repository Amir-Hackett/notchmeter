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

private extension Pace.Status {
    var meterColor: Color? {
        switch self {
        case .ahead: nil
        case .onTrack: .yellow
        case .behind: .red
        }
    }

    var noteColor: Color {
        switch self {
        case .ahead: .secondary
        case .onTrack: .yellow
        case .behind: .red
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

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.22), lineWidth: lineWidth)
            if let fraction {
                Circle()
                    .trim(from: 0, to: CGFloat(max(0.015, min(1, fraction))))
                    .stroke(tint(fraction), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                Circle()
                    .stroke(color.opacity(0.55), style: StrokeStyle(lineWidth: lineWidth, dash: [2, 3]))
            }
        }
        .animation(.snappy(duration: 0.4), value: fraction)
    }

    private func tint(_ fraction: Double) -> Color {
        fraction >= 0.95 ? .red : fraction >= 0.8 ? .yellow : color
    }
}

struct CompactRings: View {
    let status: ToolStatus
    let color: Color

    var body: some View {
        let windows = status.reading?.windows ?? []
        ZStack {
            RingView(fraction: windows.first?.usedFraction, color: color, lineWidth: 2.5)
                .frame(width: 18, height: 18)
            if windows.count > 1 {
                RingView(fraction: windows[1].usedFraction, color: color.opacity(0.8), lineWidth: 2)
                    .frame(width: 10, height: 10)
            }
            if status.problem != nil {
                Image(systemName: "exclamationmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.yellow)
            }
        }
        .opacity(status.reading == nil && status.problem == nil ? 0.5 : 1)
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
        HStack(spacing: 7) {
            ForEach(tools, id: \.self) { tool in
                CompactRings(status: store.status(tool), color: tool.color)
            }
        }
        .padding(.horizontal, tools.isEmpty ? 0 : 6)
    }
}

/// The pill that sits on a screen edge (Codenotch-style layouts).
struct EdgeCompactView: View {
    let store: UsageStore
    let edge: PanelEdge

    var body: some View {
        let rings = ForEach(store.visibleTools, id: \.self) { tool in
            CompactRings(status: store.status(tool), color: tool.color)
        }
        Group {
            if edge == .bottom {
                HStack(spacing: 10) { rings }.padding(.horizontal, 12).padding(.vertical, 7)
            } else {
                VStack(spacing: 10) { rings }.padding(.vertical, 12).padding(.horizontal, 7)
            }
        }
        .background(Capsule().fill(.black))
        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
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
                         trend: tool == .claude && prefs.showSpend ? store.cost?.daily : nil)
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
                    if let cost = store.cost, !cost.unpricedModels.isEmpty {
                        Text("Unpriced: \(cost.unpricedModels.sorted().joined(separator: ", "))")
                            .font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                    }
                    Text("Claude Code sessions at API list prices")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 2)
        }
        .modifier(CardBackground())
    }
}

struct ToolCard: View {
    let tool: ToolID
    let status: ToolStatus
    let prefs: Preferences
    let trend: [DailySpend]?

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
                        .foregroundStyle(.yellow)
                        .help(problem)
                }
            }
            .padding(.leading, 2)
            VStack(alignment: .leading, spacing: 12) {
                if let reading = status.reading {
                    ForEach(reading.windows) { window in
                        MeterRow(window: window, color: tool.color, prefs: prefs)
                    }
                    .opacity(status.problem == nil ? 1 : 0.55)
                    if let observed = reading.observedAt, Date().timeIntervalSince(observed) > 600 {
                        Text("As of \(RelativeTime.ago(observed))").font(.caption2).foregroundStyle(.tertiary)
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
                        .font(.caption).foregroundStyle(.yellow)
                case .failed(let message, _):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
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
    let window: LimitWindow
    let color: Color
    let prefs: Preferences

    var body: some View {
        let pace = Pace.note(for: window)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                if let pace {
                    Text(pace.text).font(.caption).foregroundStyle(pace.status.noteColor)
                }
            }
            if let used = window.usedFraction {
                Meter(
                    fraction: used,
                    tick: window.resetsAt.flatMap { resetsAt in window.periodDuration.flatMap { Pace.elapsedFraction(resetsAt: resetsAt, period: $0) } },
                    color: pace?.status.meterColor ?? color
                )
                HStack {
                    Text(prefs.usageLine(for: window) ?? "")
                    Spacer()
                    Text(window.resetsAt == nil ? (window.note ?? "") : prefs.resetLine(for: window))
                }
                .font(.caption).foregroundStyle(.secondary)
                if window.resetsAt != nil, let note = window.note {
                    Text(note).font(.caption2).foregroundStyle(.tertiary)
                }
            } else {
                Meter(fraction: 0, tick: nil, color: .clear)
                HStack {
                    Text("—")
                    Spacer()
                    Text(window.note ?? prefs.resetLine(for: window))
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct Meter: View {
    let fraction: Double
    let tick: Double?
    let color: Color

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
            .animation(.snappy(duration: 0.4), value: fraction)
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
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(AppInfo.name) \(AppInfo.version)")
                    Text(nextUpdate(now: context.date))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
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
        guard let next = store.nextUpdate else { return "Waiting for the first reading" }
        let seconds = next.timeIntervalSince(now)
        if seconds <= 5 { return "Updating…" }
        return "Next update in \(ResetText.duration(seconds))"
    }
}
