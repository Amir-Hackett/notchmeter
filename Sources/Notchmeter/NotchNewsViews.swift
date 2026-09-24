import AppKit
import Observation
import SwiftUI

// MARK: - The peek

/// One side of the notch's share of a peek (NotchPeek.Layout): the assistant's symbol and the project on one
/// side, the reason's symbol and its words on the other, or all of it on one side when the other has no room.
///
/// The width is worked out here and set as a fixed frame rather than left to a `maxWidth`. DynamicNotchKit lays
/// the compact halves out at their ideal size (`fixedSize`), and a text proposed no width draws whole whatever
/// frame is round it; a fixed frame is what makes a long project name truncate in its middle inside the gap
/// Auto measured instead of running on over the menus.
struct NotchPeekHalf: View {
    let news: NotchNews
    let words: NotchNews.Words
    let parts: [NotchPeek.Part]
    let room: CGFloat
    let side: NotchCompactView.Side

    static let fontSize: CGFloat = 11
    static let symbolSize: CGFloat = 10
    static let spacing: CGFloat = 4
    static let padding: CGFloat = 6

    var body: some View {
        let contrast = AccessibilityDisplay.shared.contrast
        HStack(spacing: Self.spacing) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                switch part {
                case .tool:
                    Image(systemName: words.toolSymbol)
                        .font(.system(size: Self.symbolSize, weight: .semibold))
                        .foregroundStyle(news.tool.color)
                case .name:
                    Text(verbatim: words.name ?? "")
                        .foregroundStyle(contrast ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(0)
                case .reason:
                    if index > 0, parts.contains(.name) {
                        Text(verbatim: "·").foregroundStyle(.secondary)
                    }
                    Image(systemName: words.reasonSymbol)
                        .font(.system(size: Self.symbolSize, weight: .semibold))
                        .foregroundStyle(Self.reasonColour(news.reason, contrast: contrast))
                    Text(verbatim: words.reason)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                }
            }
        }
        .font(.system(size: Self.fontSize, weight: .semibold, design: .rounded))
        .foregroundStyle(.white)
        .padding(.horizontal, Self.padding)
        .frame(width: Self.width(parts: parts, words: words, room: room), alignment: side == .leading ? .trailing : .leading)
        .environment(\.layoutDirection, .leftToRight)
    }

    /// The reason's symbol takes the colour the rings take for it — blue for a wait, white for a finish — lifted
    /// under Increase Contrast, where Palette.calm on black is too dark to read at ten points. The symbol's shape
    /// and the word beside it carry the reason either way.
    static func reasonColour(_ reason: NotchNews.Reason, contrast: Bool) -> Color {
        guard reason.isWait else { return .white }
        return contrast ? Color(red: 0.55, green: 0.78, blue: 1) : Color(red: 0.34, green: 0.62, blue: 0.95)
    }

    /// What the half needs for its parts, no more than the room it has.
    static func width(parts: [NotchPeek.Part], words: NotchNews.Words, room: CGFloat) -> CGFloat {
        var total = 2 * padding
        for (index, part) in parts.enumerated() {
            if index > 0 { total += spacing }
            switch part {
            case .tool: total += symbolSize + 2
            case .name: total += textWidth(words.name ?? "")
            case .reason:
                if index > 0, parts.contains(.name) { total += textWidth("·") + spacing }
                total += symbolSize + 2 + spacing + textWidth(words.reason)
            }
        }
        return min(ceil(total), room)
    }

    /// The rounded semibold the half draws in, measured the way AppKit sets it.
    static func textWidth(_ text: String) -> CGFloat {
        let base = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: fontSize) } ?? base
        return ceil((text as NSString).size(withAttributes: [.font: font]).width) + 1
    }
}

/// Tells VoiceOver about news the notch is showing, since a light and two words that come and go are otherwise
/// lost on a listener. High priority, the level macOS gives an announcement that should interrupt what is
/// being read: a session is blocked on the user, or has just finished.
@MainActor
enum NotchNewsAnnouncer {
    static func post(_ words: NotchNews.Words) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: words.spoken, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

// MARK: - The glow

/// What the glow window draws, and where; the presenter sets it and the view follows.
@MainActor
@Observable
final class NotchGlowModel {
    var state: NotchGlow?
    /// The width of the compact shape the light spills from.
    var width: CGFloat = 0
}

/// The light under the collapsed notch (NotchGlow). An elliptical wash centred on the shape's bottom edge, so
/// only its lower half shows: the notch covers the rest. A bloom grows out from the edge and fades after
/// `NotchGlow.bloomFor`; the ember stays while a session waits. Under Reduce Motion there is no growth and no
/// fade: the tint is simply there, and then it is not. Increase Contrast makes both brighter.
struct NotchGlowView: View {
    let model: NotchGlowModel

    static let depth: CGFloat = 44
    static let spread: CGFloat = 48

    var body: some View {
        let state = model.state
        let reduce = AccessibilityDisplay.shared.motionReduced
        let contrast = AccessibilityDisplay.shared.contrast
        let blooming: Bool = if case .bloom = state { true } else { false }
        GeometryReader { geometry in
            Rectangle()
                .fill(EllipticalGradient(colors: [Self.tint(state).opacity(Self.strength(state, contrast: contrast)),
                                                  Self.tint(state).opacity(Self.strength(state, contrast: contrast) * 0.35),
                                                  .clear],
                                         center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5))
                .frame(width: Self.coreWidth(state, width: model.width), height: 2 * Self.depth)
                .scaleEffect(x: blooming || reduce ? 1 : 0.7, y: 1, anchor: .center)
                .position(x: geometry.size.width / 2, y: 0)
        }
        .opacity(state == nil ? 0 : 1)
        .animation(reduce ? nil : Self.animation(from: state), value: state)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The light's motion, by where it is going: a bloom comes in over 250 ms easing out, and the step down to
    /// the ember or out altogether takes 200 ms easing in, quicker than it came, so it never lingers past the
    /// news it stood for.
    static func animation(from state: NotchGlow?) -> Animation {
        if case .bloom = state { return .easeOut(duration: 0.25) }
        return .easeIn(duration: 0.2)
    }

    static func tint(_ state: NotchGlow?) -> Color {
        if case .bloom(.soft) = state { return .white }
        return Palette.calm
    }

    /// The bloom is bright enough to catch the eye from the corner of it; the ember only to say "still waiting"
    /// to someone who looks.
    static func strength(_ state: NotchGlow?, contrast: Bool) -> Double {
        switch state {
        case .bloom(.calm): contrast ? 1 : 0.85
        case .bloom(.soft): contrast ? 0.7 : 0.45
        case .ember: contrast ? 0.55 : 0.35
        case nil: 0
        }
    }

    /// A bloom spills past the shape's sides; the ember keeps under it, so a wait that stands for minutes never
    /// tints the menus beside the notch.
    static func coreWidth(_ state: NotchGlow?, width: CGFloat) -> CGFloat {
        if case .ember = state { return max(0, width - 24) }
        return width + 2 * spread
    }
}

/// A click-through window of its own under the notch for the glow. The notch panel's window cannot draw it: its
/// transparent area is click-through only where a pixel is fully clear, and a soft light is not, so a glow drawn
/// there would take the clicks meant for the window under it for as long as a session waited. This window
/// ignores the mouse outright and sits one level under the notch panel, which covers the part of the light that
/// falls behind the shape.
@MainActor
final class NotchGlowPresenter {
    private let model = NotchGlowModel()
    private var window: NSPanel?
    private var reported: String?

    /// Draws `state` under `compact` (the collapsed shape, in screen coordinates), or nothing.
    func show(_ state: NotchGlow?, under compact: CGRect, behavior: NSWindow.CollectionBehavior, screen: String) {
        report(state, screen: screen)
        guard state != nil || window != nil else { return }
        let window = self.window ?? makeWindow()
        let frame = CGRect(x: compact.minX - NotchGlowView.spread, y: compact.minY - NotchGlowView.depth,
                           width: compact.width + 2 * NotchGlowView.spread, height: NotchGlowView.depth)
        if window.frame != frame { window.setFrame(frame, display: false) }
        window.collectionBehavior = behavior
        model.width = compact.width
        model.state = state
        if state != nil, !window.isVisible { window.orderFrontRegardless() }
    }

    /// Takes the window away: the presenter is being discarded.
    func close() {
        window?.orderOut(nil)
        window = nil
    }

    private func report(_ state: NotchGlow?, screen: String) {
        let name = NotchGlow.name(state)
        guard name != reported else { return }
        reported = name
        Oracle.shared.emit("glow", ["state": name, "screen": screen])
    }

    private func makeWindow() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        panel.contentView = NSHostingView(rootView: NotchGlowView(model: model))
        window = panel
        return panel
    }
}
