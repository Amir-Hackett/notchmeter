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

/// The rings that sit beside the physical notch all the time.
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

/// The full panel shown below the notch on hover (or always, if preferred).
struct NotchExpandedView: View {
    let store: UsageStore
    let prefs: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let tools = store.visibleTools
            if tools.isEmpty {
                Text("Connect an assistant to get started")
                    .font(.callout)
                Text("Install and sign in to Claude Code, Codex or Cursor; its rings appear here.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(tools, id: \.self) { tool in
                    ToolRow(tool: tool, status: store.status(tool))
                }
            }
            TimelineView(.periodic(from: .now, by: 15)) { context in
                HStack {
                    Text(footer(now: context.date))
                    Spacer()
                    Text("Right-click for options")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(width: 380, alignment: .leading)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private func footer(now: Date) -> String {
        guard let updated = store.lastUpdated else { return "Waiting for the first reading" }
        return "Updated \(RelativeTime.ago(updated, now: now))"
    }
}

struct ToolRow: View {
    let tool: ToolID
    let status: ToolStatus

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Label(tool.displayName, systemImage: tool.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tool.color)
                if let plan = status.reading?.plan {
                    Text(plan)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 84, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                if let reading = status.reading {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 124), alignment: .leading)], alignment: .leading, spacing: 8) {
                        ForEach(reading.windows) { window in
                            WindowCell(window: window, color: tool.color)
                        }
                    }
                    .opacity(status.problem == nil ? 1 : 0.55)
                    if let observed = reading.observedAt, Date().timeIntervalSince(observed) > 600 {
                        Text("As of \(RelativeTime.ago(observed))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                switch status {
                case .waiting:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Waiting for the first reading")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                case .idle(let message):
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .needsAttention(let message, _):
                    Label(message, systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                case .failed(let message, _):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                default:
                    EmptyView()
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct WindowCell: View {
    let window: LimitWindow
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            RingView(fraction: window.usedFraction, color: color, lineWidth: 3)
                .frame(width: 30, height: 30)
                .overlay(
                    Text(percentText)
                        .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(window.label)
                    .font(.caption)
                    .fontWeight(.medium)
                Text(window.note ?? RelativeTime.resets(window.resetsAt, hasLimit: window.usedFraction != nil))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var percentText: String {
        window.usedFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
    }
}
