import SwiftUI

/// Settings › Appearance › Theme's live preview: a scrap of the open panel in the look being chosen, drawn by the
/// panel's own views (a Simple row, a window's meter or dial, the range control) from the sample data the Welcome
/// tour uses, hanging from a black band over a scrap of desktop. The desktop runs from colour to white, so a
/// translucent material shows what it lets through and the white end shows the worst case the tints are chosen
/// against (PanelMaterial). It is a picture: it takes no clicks, and VoiceOver reads it as one item naming the look.
struct ThemePreview: View {
    let look: PanelLook
    /// The sample store, built when the preview first appears rather than with every rebuild of the form, and
    /// afresh each time the pane is opened, so its clock is never hours old.
    @State private var sample: UsageStore?

    static let panelWidth: CGFloat = 300
    static let height: CGFloat = 206

    var body: some View {
        ZStack(alignment: .top) {
            PreviewDesktop()
            if let sample {
                PreviewPanel(store: sample, look: look)
                    .frame(width: Self.panelWidth)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            // On its own dark backing: the desktop under this corner is the white window.
            Text(L("Sample data"))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.black.opacity(0.75)))
                .padding(6)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Preview of the open panel"))
        .accessibilityValue(Spoken.line(look.theme.title, look.material.title, look.accent.title, look.usageStyle.title,
                                        look.hourClock ? L("Draw hour limits on a clock") : nil))
        .onAppear {
            if sample == nil { sample = DemoFixtures.store(moment: .waiting, suite: DemoFixtures.themePreviewSuiteName).store }
        }
    }
}

/// A scrap of desktop: a wallpaper's colour running out into a white window, the backdrop a translucent panel is
/// judged against.
private struct PreviewDesktop: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.86, green: 0.42, blue: 0.28), Color(red: 0.18, green: 0.5, blue: 0.72), .white, .white],
                       startPoint: .leading, endPoint: .trailing)
    }
}

/// The panel itself, in miniature: the notch's black band, then the body in the look — the black with the
/// material's tint over the desktop, or Paper's sheet in its black frame — holding the views the panel draws.
private struct PreviewPanel: View {
    let store: UsageStore
    let look: PanelLook

    var body: some View {
        let claude = store.status(.claude).reading.map { store.prefs.panelWindows(of: $0) } ?? []
        let rings = UsageDial.split(claude).rings
        VStack(spacing: 0) {
            Color.black.frame(height: 12)
            VStack(alignment: .leading, spacing: 8) {
                SimpleToolRow(tool: .claude, store: store, prefs: store.prefs, actions: NotchActions(), advice: [])
                if let first = claude.first {
                    Group {
                        if look.usageStyle == .gauges, !rings.isEmpty {
                            HStack(alignment: .center, spacing: 10) {
                                UsageDialView(tool: .claude, windows: rings, size: 56, display: store.prefs.usageDisplay)
                                MeterRow(toolName: ToolID.claude.displayName, window: rings[0], color: ToolID.claude.color, prefs: store.prefs,
                                         gauge: MeterRow.Gauge(index: 0, count: rings.count, colour: UsageDial.colour(rings[0], tool: .claude, index: 0)))
                            }
                        } else {
                            MeterRow(toolName: ToolID.claude.displayName, window: first, color: ToolID.claude.color, prefs: store.prefs)
                        }
                    }
                    .padding(.horizontal, 6)
                }
                SegmentedBar(values: [SpendCard.Range.today, .week, .month], title: \.title, selection: .constant(.today))
                    .padding(.horizontal, 6)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .modifier(PaperSheet(look: look))
            .padding(look.theme == .paper ? EdgeInsets(top: 0, leading: 6, bottom: 6, trailing: 6) : EdgeInsets())
            .background(ground(look))
        }
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16, style: .continuous))
        .modifier(PanelInkEnvironment(look: look))
        .environment(\.density, .comfortable)
    }

    /// The ground under the body: the notch's black, or the material's tint with the desktop behind it (the blur
    /// the live panel adds is left out; the tint is what the contrast rules count on).
    @ViewBuilder
    private func ground(_ look: PanelLook) -> some View {
        if look.theme == .black, look.material.translucent {
            Color.black.opacity(look.material.tint)
        } else {
            Color.black
        }
    }
}

/// One accent in Settings › Appearance › Theme: its swatch and its name, and when chosen a tick, a heavier name and
/// a stronger outline, so the choice never rests on the colour alone. A 24-point target the whole width of the chip.
struct AccentChoice: View {
    let accent: PanelAccent
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 5) {
                // On the black it is drawn on in the default theme, so the swatch is the colour as the panel shows it.
                Circle().fill(Color.black).frame(width: 16, height: 16)
                    .overlay(Circle().fill(accent.onBlack.color).padding(3))
                Text(accent.title).fontWeight(selected ? .semibold : .regular)
                if selected {
                    Image(systemName: "checkmark").font(.caption.weight(.bold))
                }
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 24)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Color.primary.opacity(0.1) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(selected ? 0.55 : 0.2), lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accent.title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
