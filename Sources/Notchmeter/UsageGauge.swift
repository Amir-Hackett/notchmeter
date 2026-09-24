import SwiftUI

// MARK: - The hour clock

/// The small clock beside the reset of a window measured in hours (Settings › Appearance › *Draw hour limits on a
/// clock*): a face whose hand is where the window stands and whose filled part, from the hand round to twelve, is
/// the time still to run before it resets. Twelve o'clock is the reset.
///
/// It is a picture of the reset line beside it and nothing more, so it is held to the reset line's sources
/// (docs/accuracy.md, *The hour clock*): the vendor's reset instant and the window's period, the same two figures
/// the pace tick is drawn from. Nothing is drawn where either is missing, with one exception the vendor states
/// outright: a window that reports nothing used and no reset has not started, and its whole period is ahead of it,
/// so its clock is full. A window of a day or longer keeps its words: a clock face says "hours", and a week drawn
/// on one would be a week read as hours.
enum HourClock {
    /// The longest window drawn on a clock. Strictly shorter than a day: the five-hour session is the case in point.
    static let longestPeriod: TimeInterval = 24 * 3600

    static func isHourly(_ window: LimitWindow) -> Bool {
        guard let period = window.periodDuration else { return false }
        return period > 0 && period < longestPeriod
    }

    /// The share of the window's time still to run, 0…1, or nil where no clock is drawn. A reset already past reads
    /// empty rather than being guessed at, and a reset further away than the period (a reading whose period was
    /// inferred shorter than the vendor's) reads full rather than more than full.
    static func remaining(_ window: LimitWindow, now: Date = Date()) -> Double? {
        guard isHourly(window), let period = window.periodDuration else { return nil }
        guard let resetsAt = window.resetsAt else { return window.usedFraction == 0 ? 1 : nil }
        return min(1, max(0, resetsAt.timeIntervalSince(now) / period))
    }
}

/// The clock face itself: a ring, the time still to run filled from the hand round to twelve, in the secondary
/// ink. Decoration for VoiceOver, which reads the reset line it stands beside.
struct ClockFace: View {
    let remaining: Double
    var size: CGFloat = 11

    var body: some View {
        ZStack {
            Circle().strokeBorder(Ink.secondary, lineWidth: 1)
            ClockSector(remaining: remaining).fill(Ink.secondary).padding(2)
        }
        .frame(width: size, height: size)
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityHidden(true)
    }
}

/// The filled part of the clock: from the hand, at the share of the period already gone, clockwise round to twelve.
struct ClockSector: Shape {
    var remaining: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let share = min(1, max(0, remaining))
        guard share > 0 else { return path }
        guard share < 1 else { path.addEllipse(in: rect); return path }
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        // SwiftUI's y runs down, so an arc that is not "clockwise" by the API's reckoning turns clockwise on screen.
        path.move(to: centre)
        path.addArc(center: centre, radius: radius, startAngle: .degrees(-90 + 360 * (1 - share)), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}

// MARK: - The dial

/// Gauges (UsageStyle.gauges): one dial per assistant with a ring per window nested inside it, outermost first in
/// the card's own order, as the rings beside the notch are nested. At most three rings, the notch's own ceiling
/// (RingSelection.maximum): a fourth ring leaves an inner hole too small to read and a line too thin to see, so a
/// window past the third keeps its meter under the dial. A window with nothing to draw (no figure) is never a ring;
/// it keeps its meter and its words, as it has on the bars.
enum UsageDial {
    static let maximum = RingSelection.maximum

    /// The windows the dial draws, outermost first, and the ones left to meters, both in the order they came.
    static func split(_ windows: [LimitWindow]) -> (rings: [LimitWindow], bars: [LimitWindow]) {
        var rings: [LimitWindow] = []
        var bars: [LimitWindow] = []
        for window in windows {
            if rings.count < maximum, window.usedFraction != nil { rings.append(window) } else { bars.append(window) }
        }
        return (rings, bars)
    }

    /// Each ring's diameter and line, outermost first, for a dial `size` across: the line a thirteenth of the dial
    /// and a gap of a third of the line between rings, so three rings leave a centre wide enough for "100%".
    static func geometry(count: Int, size: CGFloat) -> [(diameter: CGFloat, lineWidth: CGFloat)] {
        let line = max(2, (size / 13).rounded(.down))
        let gap = max(1, (line / 3).rounded())
        return (0 ..< max(0, count)).map { index in (size - 2 * CGFloat(index) * (line + gap), line) }
    }

    /// The figure in the middle: the window the Simple row would name, the most urgent and then the most used.
    static func centre(_ rings: [LimitWindow], now: Date = Date()) -> LimitWindow? {
        SimpleFigure.window(of: rings, now: now)
    }

    /// The ring's colour: the pace colour once a window is on track or behind, as a meter's fill turns, and the
    /// assistant's own ring colour otherwise, so the dial and the nest beside the notch agree ring for ring.
    static func colour(_ window: LimitWindow, tool: ToolID, index: Int, now: Date = Date()) -> Color {
        Pace.status(for: window, now: now)?.meterColor ?? tool.ringColor(at: index)
    }
}

/// The dial: its rings, each with the tick where an even burn would be, and optionally the centre figure.
struct UsageDialView: View {
    let tool: ToolID
    /// The rings, outermost first (`UsageDial.split`).
    let windows: [LimitWindow]
    var size: CGFloat = 84
    var display: UsageDisplay = .used
    /// The figure in the middle; off on the Simple row's small dial, whose row carries the figure beside it, and
    /// while the screen is shared.
    var showsCentre = true

    var body: some View {
        let geometry = UsageDial.geometry(count: windows.count, size: size)
        ZStack {
            ForEach(Array(zip(windows, geometry).enumerated()), id: \.offset) { index, pair in
                GaugeRing(fraction: pair.0.usedFraction ?? 0,
                          tick: pair.0.resetsAt.flatMap { resetsAt in pair.0.periodDuration.flatMap { Pace.elapsedFraction(resetsAt: resetsAt, period: $0) } },
                          colour: UsageDial.colour(pair.0, tool: tool, index: index), lineWidth: pair.1.lineWidth)
                    .frame(width: pair.1.diameter, height: pair.1.diameter)
            }
            if showsCentre, let centre = UsageDial.centre(windows), let text = SimpleFigure.text(centre, display: display) {
                let hole = (geometry.last?.diameter ?? size) - 2 * (geometry.last?.lineWidth ?? 0) - 4
                Text(verbatim: text.figure)
                    // A third of the hole, between 9 and 18 points: one ring leaves a hole a figure would shout in.
                    .font(.system(size: min(18, max(9, hole * 0.34)), weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .frame(width: max(0, hole))
            }
        }
        .frame(width: size, height: size)
        // Quantity and time run clockwise from twelve in every language, as they run left to right on a meter.
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityHidden(true)
    }
}

/// One ring of the dial: the track, the arc from twelve, and the pace tick across the ring. The track and the tick
/// are the meter's own (Meter), so a reader who knows one reads the other.
private struct GaugeRing: View {
    let fraction: Double
    let tick: Double?
    let colour: Color
    let lineWidth: CGFloat

    var body: some View {
        let contrast = AccessibilityDisplay.shared.contrast
        ZStack {
            Circle()
                .inset(by: lineWidth / 2)
                .stroke(Themed.wash(.white, contrast ? 0.28 : 0.12), lineWidth: lineWidth)
            if fraction > 0 {
                Circle()
                    .inset(by: lineWidth / 2)
                    .trim(from: 0, to: CGFloat(max(0.015, min(1, fraction))))
                    .stroke(Themed(colour), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            if let tick {
                GaugeTick(fraction: tick, lineWidth: lineWidth)
                    .stroke(Themed(.white, opacity: contrast ? 1 : 0.7), lineWidth: 1.5)
            }
        }
        .animation(AccessibilityDisplay.shared.motionReduced ? nil : .snappy(duration: 0.4), value: fraction)
    }
}

/// The pace tick: a short radial line across the ring at the share of the period gone.
private struct GaugeTick: Shape {
    let fraction: Double
    let lineWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2 - lineWidth / 2
        let angle = -Double.pi / 2 + 2 * .pi * min(1, max(0, fraction))
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        func point(_ distance: CGFloat) -> CGPoint {
            CGPoint(x: centre.x + distance * CGFloat(cos(angle)), y: centre.y + distance * CGFloat(sin(angle)))
        }
        var path = Path()
        path.move(to: point(radius - lineWidth / 2 - 1))
        path.addLine(to: point(radius + lineWidth / 2 + 1))
        return path
    }
}

/// Which ring of the dial a legend row is: a small nest of the same number of rings with this row's drawn in its
/// ring's colour and the rest faint. Position says it as well as colour does, so a reader who cannot tell the
/// companions apart, or a ring turned orange for its pace, still finds the row's ring.
struct DialSwatch: View {
    let index: Int
    let count: Int
    let colour: Color
    static let size: CGFloat = 13

    /// The nest's diameters, outermost first: evenly spaced from the whole swatch down to a third of it.
    static func diameters(count: Int) -> [CGFloat] {
        guard count > 1 else { return [size] }
        let span: CGFloat = size * 2 / 3
        let step: CGFloat = span / CGFloat(count - 1)
        return (0 ..< count).map { index in size - CGFloat(index) * step }
    }

    var body: some View {
        ZStack {
            ForEach(Array(Self.diameters(count: count).enumerated()), id: \.offset) { ring, diameter in
                Circle()
                    .inset(by: 0.75)
                    .stroke(ring == index ? Themed(colour) : Themed(.white, opacity: 0.3), lineWidth: ring == index ? 1.5 : 0.75)
                    .frame(width: diameter, height: diameter)
            }
        }
        .frame(width: Self.size, height: Self.size)
        .accessibilityHidden(true)
    }
}
