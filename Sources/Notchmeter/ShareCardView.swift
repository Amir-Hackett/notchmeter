import AppKit
import SwiftUI

private extension Color {
    init(card hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// The picture itself: drawn at the format's size in points and rendered at one pixel a point, so what the studio
/// previews, what Save PNG writes and what the share sheet hands on are the same pixels (ShareCardRenderer).
///
/// Every size below is a multiple of `unit`, the format's width over 1080, so the feed card (1200 wide) is the
/// square card's type set a tenth larger and the story shares the square's width. The square is the tight one:
/// it gives up a line of caption and folds three or four assistants into two columns before the chart shrinks.
/// Text that runs long in German or Russian wraps, never truncates (`fixedSize(vertical:)`), and the headline
/// alone may scale down, since a figure cut short would be a different figure.
struct ShareCardView: View {
    let content: ShareCardContent
    let format: ShareCardFormat
    let theme: ShareCardTheme
    var calendar: Calendar = .current

    private var unit: CGFloat { format.size.width / 1080 }
    private var square: Bool { format == .square }
    private var padding: CGFloat { (square ? 60 : 76) * unit }

    private var primary: Color { Color(card: theme.primary) }
    private var secondary: Color { Color(card: theme.secondary) }

    var body: some View {
        // Fixed gaps above and below, so the one flexible thing on the card is the chart (or, where there is no
        // chart, the space it would have had): two Spacers and a chart would share the slack three ways.
        VStack(alignment: .leading, spacing: 0) {
            header
            Color.clear.frame(height: (square ? 28 : 48) * unit)
            if content.isEmpty {
                Text(L("Nothing recorded in this range"))
                    .font(.system(size: 52 * unit, weight: .semibold, design: .rounded))
                    .foregroundStyle(secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else {
                figures
            }
            Color.clear.frame(height: (square ? 20 : 36) * unit)
            footer
        }
        .padding(padding)
        .frame(width: format.size.width, height: format.size.height, alignment: .topLeading)
        .background(Color(card: theme.background))
        .environment(\.colorScheme, theme == .white ? .light : .dark)
        .environment(\.layoutDirection, .leftToRight)
    }

    /// The wordmark on the left, the span on the right.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12 * unit) {
            Label {
                Text(verbatim: AppInfo.name).font(.system(size: 34 * unit, weight: .bold))
            } icon: {
                Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 30 * unit, weight: .semibold))
            }
            .foregroundStyle(primary)
            Spacer(minLength: 12 * unit)
            VStack(alignment: .trailing, spacing: 4 * unit) {
                Text(content.range.title).font(.system(size: 30 * unit, weight: .semibold)).foregroundStyle(primary)
                Text(content.span(calendar: calendar)).font(.system(size: 26 * unit)).foregroundStyle(secondary)
            }
            .multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder
    private var figures: some View {
        VStack(alignment: .leading, spacing: (square ? 8 : 12) * unit) {
            Text(content.headline)
                .font(.system(size: (square ? 120 : 150) * unit, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(primary)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
            if let caption = content.headlineCaption {
                Text(caption)
                    .font(.system(size: (square ? 30 : 36) * unit, weight: .medium))
                    .foregroundStyle(secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let plan = content.plan, let ratio = content.ratioCaption {
                HStack(alignment: .center, spacing: 16 * unit) {
                    Text(plan.multiple)
                        .font(.system(size: (square ? 40 : 48) * unit, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color(card: theme.onBadge))
                        .padding(.horizontal, 22 * unit)
                        .padding(.vertical, 8 * unit)
                        .background(Capsule().fill(Color(card: theme.badge)))
                    Text(ratio)
                        .font(.system(size: (square ? 28 : 32) * unit, weight: .semibold))
                        .foregroundStyle(primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8 * unit)
            }
        }
        if content.days.count > 1 {
            ShareCardChart(content: content, theme: theme)
                .frame(maxWidth: .infinity, minHeight: (square ? 120 : 200) * unit, maxHeight: .infinity)
                .padding(.vertical, (square ? 24 : 40) * unit)
        } else {
            Spacer(minLength: (square ? 24 : 40) * unit)
        }
        rows
        if let advice = content.advice {
            HStack(alignment: .firstTextBaseline, spacing: 14 * unit) {
                Image(systemName: "lightbulb.fill").font(.system(size: 26 * unit, weight: .semibold)).foregroundStyle(Color(card: theme.badge))
                Text(advice)
                    .font(.system(size: (square ? 28 : 32) * unit, weight: .medium))
                    .foregroundStyle(primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, (square ? 18 : 30) * unit)
        }
    }

    /// One row per assistant, or two columns of them on the square once there are more than two.
    @ViewBuilder
    private var rows: some View {
        let columns = square && content.rows.count > 2 ? 2 : 1
        let grid = Array(repeating: GridItem(.flexible(), spacing: 36 * unit, alignment: .leading), count: columns)
        LazyVGrid(columns: grid, alignment: .leading, spacing: (square ? 10 : 16) * unit) {
            ForEach(content.rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 14 * unit) {
                    Circle().fill(Color(card: theme.tool(row.tool))).frame(width: 20 * unit, height: 20 * unit)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 11 * unit }
                    Text(verbatim: row.tool.displayName)
                        .font(.system(size: (square ? 30 : 34) * unit, weight: .medium))
                        .foregroundStyle(primary)
                        .lineLimit(1)
                    Spacer(minLength: 8 * unit)
                    if let share = row.share {
                        Text(verbatim: "\(Int((share * 100).rounded()))%")
                            .font(.system(size: (square ? 26 : 30) * unit))
                            .monospacedDigit()
                            .foregroundStyle(secondary)
                    }
                    Text(ShareCardContent.amount(row.amount, metric: content.metric, cents: false))
                        .font(.system(size: (square ? 30 : 34) * unit, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
        }
    }

    /// The signature over the site and what kind of number the card is.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 14 * unit) {
            if let signature = content.signature {
                Text(verbatim: signature)
                    .font(.system(size: 30 * unit, weight: .medium).italic())
                    .foregroundStyle(secondary)
                    .lineLimit(1)
            }
            Rectangle().fill(Color(card: theme.rule)).frame(height: max(1, 2 * unit))
            HStack(alignment: .firstTextBaseline, spacing: 16 * unit) {
                Text(verbatim: ShareCard.site).font(.system(size: 26 * unit, weight: .bold)).foregroundStyle(primary)
                Spacer(minLength: 12 * unit)
                Text(content.footnote)
                    .font(.system(size: 24 * unit, weight: .medium))
                    .foregroundStyle(secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The span's running total, stacked by assistant in the rows' order (the first at the bottom), each band in the
/// assistant's colour for the theme, with a hairline of the ground between bands so two close hues stay apart.
/// The rows below name every band with its figure, so no band is told by colour alone.
struct ShareCardChart: View {
    let content: ShareCardContent
    let theme: ShareCardTheme

    var body: some View {
        Canvas { context, size in
            let count = content.days.count
            guard count > 1, content.total > 0 else { return }
            let step = size.width / CGFloat(count - 1)
            func y(_ value: Double) -> CGFloat { size.height - CGFloat(value / content.total) * size.height }
            var below = [Double](repeating: 0, count: count)
            var bands: [(tool: ToolID, top: [Double], bottom: [Double])] = []
            for (index, row) in content.rows.enumerated() {
                let series = content.cumulative[index]
                let top = zip(below, series).map { $0 + $1 }
                bands.append((row.tool, top, below))
                below = top
            }
            let separator = max(1, size.width / 540)
            for band in bands {
                var area = Path()
                area.move(to: CGPoint(x: 0, y: y(band.bottom[0])))
                for index in 0..<count { area.addLine(to: CGPoint(x: CGFloat(index) * step, y: y(band.top[index]))) }
                for index in (0..<count).reversed() { area.addLine(to: CGPoint(x: CGFloat(index) * step, y: y(band.bottom[index]))) }
                area.closeSubpath()
                context.fill(area, with: .color(Color(card: theme.tool(band.tool))))
                var edge = Path()
                edge.move(to: CGPoint(x: 0, y: y(band.top[0])))
                for index in 1..<count { edge.addLine(to: CGPoint(x: CGFloat(index) * step, y: y(band.top[index]))) }
                context.stroke(edge, with: .color(Color(card: theme.background)), lineWidth: separator)
            }
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: size.height))
            baseline.addLine(to: CGPoint(x: size.width, y: size.height))
            context.stroke(baseline, with: .color(Color(card: theme.rule)), lineWidth: separator * 2)
        }
        .accessibilityHidden(true)
    }
}

/// Draws a card to pixels: `ImageRenderer` at one pixel a point over the format's own size, so a 1200×1500 feed
/// card is a 1200×1500 PNG whatever display it was made on.
@MainActor
enum ShareCardRenderer {
    static func image(_ content: ShareCardContent, format: ShareCardFormat, theme: ShareCardTheme, calendar: Calendar = .current) -> CGImage? {
        let renderer = ImageRenderer(content: ShareCardView(content: content, format: format, theme: theme, calendar: calendar))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(format.size)
        return renderer.cgImage
    }

    static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
