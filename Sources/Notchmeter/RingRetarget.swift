import AppKit
import Observation
import SwiftUI

// MARK: - Which window comes next

/// Scroll a readout to change the window its outer ring watches: the session, the week, a model's week, the month,
/// in the order the card lists them. Settings › Assistants › Options has the same choice as a picker per ring; this
/// is the same write (Preferences.ringWindows) from where the ring is, so the choice is kept across launches and
/// the card, the oracle's `ringWindows` and the pickers all agree with what a scroll set.
enum RingCycle {
    /// The windows a scroll cycles through: the ones the card shows that carry a figure, with the derived "All
    /// models" first where there is one (Preferences.panelWindows). A window with no figure would turn the ring into
    /// a dashed circle that says nothing, and a hidden one would be revealed on the card by a scroll nobody meant
    /// as a Settings change, so neither is offered; the pickers still reach both.
    static func candidates(_ windows: [LimitWindow]) -> [LimitWindow] {
        windows.filter { $0.usedFraction != nil }
    }

    /// The ring ids after a step (+1 next, -1 previous) from the outer ring's window, wrapping at both ends. The
    /// outer ring takes the new window; if an inner ring was already showing it, the two swap, so the nest keeps
    /// its count and never shows one window twice. An outer ring on a window that is not a candidate starts the
    /// cycle at the first (or, going back, the last). Nil when there is nothing to cycle between.
    static func next(drawn: [String], candidates: [String], step: Int) -> [String]? {
        guard candidates.count > 1, step != 0 else { return nil }
        let count = candidates.count
        let target: String
        if let current = drawn.first, let index = candidates.firstIndex(of: current) {
            target = candidates[((index + step) % count + count) % count]
        } else {
            target = step > 0 ? candidates[0] : candidates[count - 1]
        }
        guard var ids = drawn.isEmpty ? nil : drawn else { return [target] }
        if let at = ids.firstIndex(of: target) {
            ids.swapAt(0, at)
        } else {
            ids[0] = target
        }
        return ids
    }

    /// The label that names the ring's new window for a moment beside it: "Weekly · 62% used", in the Used or
    /// Left sense chosen, with the source tag the card would show ("inferred") so a locally worked-out window is
    /// never mistaken for the vendor's. No figure while the screen is shared.
    static func label(_ window: LimitWindow, display: UsageDisplay, hideFigures: Bool) -> String {
        var parts = [window.label]
        if !hideFigures, let used = window.usedFraction {
            parts.append(display == .used ? L("%ld%% used", Int((used * 100).rounded())) : L("%ld%% left", Int(((1 - used) * 100).rounded())))
        }
        if let tag = window.source.tag { parts.append(tag) }
        return parts.joined(separator: " · ")
    }
}

/// How a retarget was asked for, for the oracle's `ringWindow` line.
enum RingRetargetCause: String, Sendable {
    case scroll
    case voiceOver
}

extension UsageStore {
    /// Moves a tool's outer ring one window on (+1) or back (-1) and keeps the choice (RingCycle). Returns the window
    /// the outer ring now shows, or nil when the tool has no reading or nothing to cycle between.
    @discardableResult
    func cycleRing(_ tool: ToolID, by step: Int, cause: RingRetargetCause) -> LimitWindow? {
        guard let reading = status(tool).reading else { return nil }
        let drawn = prefs.ringWindows(of: reading).map(\.id)
        guard let ids = RingCycle.next(drawn: drawn, candidates: RingCycle.candidates(prefs.panelWindows(of: reading)).map(\.id), step: step)
        else { return nil }
        prefs.ringWindows[tool] = ids
        let outer = prefs.ringWindows(of: reading).first
        Oracle.shared.emit("ringWindow", ["tool": tool.rawValue, "window": outer?.id as Any, "cause": cause.rawValue])
        return outer
    }
}

/// VoiceOver's adjustable action on a readout: increment for the next window, decrement for the previous.
struct RingAdjustable: ViewModifier {
    let retarget: ((Int) -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let retarget {
            content
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: retarget(1)
                    case .decrement: retarget(-1)
                    @unknown default: break
                    }
                }
                .accessibilityHint(L("Adjust to change which window the ring watches"))
        } else {
            content
        }
    }
}

// MARK: - A scroll, reduced to steps

/// Turns scroll events over a readout into steps, one per gesture. Pure: no clock and no AppKit, so the rules are
/// tested without a trackpad.
///
/// A two-finger swipe down over the strip already opens the panel (HoverIntent.swipe), so the axes are shared out:
/// a sideways gesture on a trackpad is the ring's, a vertical one stays the swipe it has always been — unless
/// swipes are off (Preferences.gesturesEnabled, or Reduce Motion), when it is the ring's too. A mouse wheel is the
/// ring's on either axis, since a wheel is not a swipe. A trackpad gesture steps once, when it has travelled
/// `travel` points, and the momentum after it steps nothing, so a flick is one window and not five; a wheel steps
/// once per spin, a spin ending when it has rested `wheelGap`.
struct RingScroll: Equatable {
    enum Phase: Equatable, Sendable { case began, changed, ended, none }

    struct Input: Equatable, Sendable {
        var deltaX: CGFloat
        var deltaY: CGFloat
        var phase: Phase
        /// A momentum event after the fingers have left the trackpad.
        var momentum: Bool
    }

    struct Outcome: Equatable, Sendable {
        /// +1 for the next window, -1 for the previous, nil for none.
        var step: Int?
        /// The event is the readout's, so it must not also be counted as a swipe.
        var claimed: Bool
    }

    /// Points of trackpad travel before a gesture steps: the swipe's own threshold (HoverDriver.swipeThreshold).
    static let travel: CGFloat = 24
    static let wheelGap: TimeInterval = 0.25

    private var travelX: CGFloat = 0
    private var travelY: CGFloat = 0
    private var stepped = false
    /// Whether the last trackpad gesture was the readout's, so its momentum goes the same way.
    private var claimedGesture = false
    private var lastWheel: TimeInterval?

    mutating func reset() {
        travelX = 0
        travelY = 0
        stepped = false
        claimedGesture = false
    }

    /// Scrolling down (or right) is the next window, up (or left) the previous, in whichever sense the system's
    /// scroll direction hands the deltas over; it is a cycle, so either way reaches every window.
    mutating func feed(_ input: Input, verticalSwipes: Bool, at time: TimeInterval) -> Outcome {
        if input.momentum { return Outcome(step: nil, claimed: claimedGesture) }
        guard input.phase != .none else {
            let delta = abs(input.deltaY) >= abs(input.deltaX) ? input.deltaY : input.deltaX
            guard delta != 0 else { return Outcome(step: nil, claimed: true) }
            defer { lastWheel = time }
            if let lastWheel, time - lastWheel < Self.wheelGap { return Outcome(step: nil, claimed: true) }
            return Outcome(step: delta < 0 ? 1 : -1, claimed: true)
        }
        if input.phase == .began { reset() }
        travelX += input.deltaX
        travelY += input.deltaY
        let horizontal = abs(travelX) > abs(travelY)
        let claims = horizontal || !verticalSwipes
        claimedGesture = claims
        var step: Int?
        if claims, !stepped {
            let travel = horizontal ? travelX : travelY
            if abs(travel) >= Self.travel {
                stepped = true
                step = travel < 0 ? 1 : -1
            }
        }
        if input.phase == .ended {
            travelX = 0
            travelY = 0
            stepped = false
        }
        return Outcome(step: step, claimed: claims)
    }
}

// MARK: - Where the readouts are on screen

/// The readouts on screen, each registered by the view that draws it, so a scroll at a point can be told which
/// assistant's ring it is over. The rectangles are read at the moment of the scroll from the views themselves,
/// never kept, because the strip moves: Auto shifts it, a peek takes its place, the panel opens over it.
@MainActor
final class RingTargets {
    private final class Entry {
        weak var view: NSView?
        var tool: ToolID

        init(view: NSView, tool: ToolID) {
            self.view = view
            self.tool = tool
        }
    }

    /// Points of slop around a readout, as a click on the strip gets (HoverRegions.clickSlop is 6; a scroll lands
    /// where the pointer already rests, so less is needed).
    nonisolated static let slop: CGFloat = 3

    private var entries: [Entry] = []

    func register(_ view: NSView, tool: ToolID) {
        entries.removeAll { $0.view == nil }
        if let entry = entries.first(where: { $0.view === view }) {
            entry.tool = tool
        } else {
            entries.append(Entry(view: view, tool: tool))
        }
    }

    func unregister(_ view: NSView) {
        entries.removeAll { $0.view == nil || $0.view === view }
    }

    /// Every readout on a visible window, in screen coordinates.
    var rects: [(tool: ToolID, rect: CGRect)] {
        entries.compactMap { entry in
            guard let view = entry.view, let window = view.window, window.isVisible else { return nil }
            return (entry.tool, window.convertToScreen(view.convert(view.bounds, to: nil)))
        }
    }

    func tool(at point: CGPoint) -> ToolID? { Self.hit(rects, point) }

    func rect(of tool: ToolID) -> CGRect? { rects.first { $0.tool == tool }?.rect }

    /// The readout under a point, the nearest centre winning where the slop makes two overlap.
    nonisolated static func hit(_ rects: [(tool: ToolID, rect: CGRect)], _ point: CGPoint) -> ToolID? {
        rects.filter { $0.rect.insetBy(dx: -slop, dy: -slop).contains(point) }
            .min { hypot($0.rect.midX - point.x, $0.rect.midY - point.y) < hypot($1.rect.midX - point.x, $1.rect.midY - point.y) }?
            .tool
    }
}

private struct RingTargetsKey: EnvironmentKey {
    static let defaultValue: RingTargets? = nil
}

extension EnvironmentValues {
    /// The registry the readouts in a presenter's own window register with; nil everywhere else (probes, renders).
    var ringTargets: RingTargets? {
        get { self[RingTargetsKey.self] }
        set { self[RingTargetsKey.self] = newValue }
    }
}

extension View {
    /// Registers this readout as `tool`'s scroll target, where there is a registry to register with.
    @ViewBuilder
    func ringTarget(_ tool: ToolID, in targets: RingTargets?) -> some View {
        if let targets {
            background(RingTargetReporter(tool: tool, targets: targets).accessibilityHidden(true))
        } else {
            self
        }
    }
}

/// An empty view behind a readout whose only job is to be found: it takes no click, draws nothing and is not an
/// accessibility element, so the readout in front of it behaves exactly as it did.
private struct RingTargetReporter: NSViewRepresentable {
    let tool: ToolID
    let targets: RingTargets

    final class Marker: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
    }

    final class Coordinator {
        let targets: RingTargets
        init(targets: RingTargets) { self.targets = targets }
    }

    func makeCoordinator() -> Coordinator { Coordinator(targets: targets) }

    func makeNSView(context: Context) -> Marker {
        let marker = Marker()
        targets.register(marker, tool: tool)
        return marker
    }

    func updateNSView(_ marker: Marker, context: Context) {
        targets.register(marker, tool: tool)
    }

    static func dismantleNSView(_ marker: Marker, coordinator: Coordinator) {
        coordinator.targets.unregister(marker)
    }
}

// MARK: - The label that names the new window

/// Where the label goes: under a readout at the top, above one at the bottom, and inboard of one on a side edge,
/// kept on the screen. `ring` is the readout's rectangle in screen coordinates (at the top, reaching down to the
/// foot of the notch band, so the label clears the band rather than the readout alone).
enum RingLabel {
    static let gap: CGFloat = 4
    /// How long the label stays: long enough to read two words, short enough not to sit over what is below.
    static let shownFor: TimeInterval = 1.4

    static func frame(ring: CGRect, size: CGSize, edge: PanelEdge, screen: CGRect) -> CGRect {
        var origin: CGPoint
        switch edge {
        case .top: origin = CGPoint(x: ring.midX - size.width / 2, y: ring.minY - gap - size.height)
        case .bottom: origin = CGPoint(x: ring.midX - size.width / 2, y: ring.maxY + gap)
        case .left: origin = CGPoint(x: ring.maxX + gap, y: ring.midY - size.height / 2)
        case .right: origin = CGPoint(x: ring.minX - gap - size.width, y: ring.midY - size.height / 2)
        }
        origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
        origin.y = min(max(origin.y, screen.minY), screen.maxY - size.height)
        return CGRect(origin: origin, size: size)
    }
}

@MainActor
@Observable
final class RingLabelModel {
    var text = ""
    var visible = false
}

/// The label itself: white on a black capsule with a hairline rim, so it reads over any wallpaper or window.
/// 13 pt semibold white on black is far above 4.5:1; the rim is brighter under Increase Contrast.
struct RingLabelView: View {
    let model: RingLabelModel

    var body: some View {
        Text(verbatim: model.text)
            .font(.system(size: 12, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            // A circular capsule, stroked inside its outline: the default (continuous) capsule's rim left a flat tick
            // at each end, measured in a render of this label on its own, and a centred stroke hangs half outside
            // the frame.
            .background(Capsule(style: .circular).fill(.black.opacity(0.92)))
            .overlay(Capsule(style: .circular).strokeBorder(.white.opacity(AccessibilityDisplay.shared.contrast ? 0.6 : 0.22), lineWidth: 1))
            .fixedSize()
            .padding(2)
            .opacity(model.visible ? 1 : 0)
            .environment(\.colorScheme, .dark)
            .accessibilityHidden(true)
    }
}

/// Shows the label for `RingLabel.shownFor` in a click-through window of its own, the way the glow under the notch
/// is drawn (NotchGlowPresenter): a window that ignores the mouse cannot take a click or a scroll meant for what is
/// under it, and drawing outside the notch's own window keeps the strip's measured width untouched. In over 200 ms
/// easing out, away over 150 ms easing in; under Reduce Motion it appears and goes without a fade. VoiceOver
/// hears the same words as an announcement, since the window itself is hidden from it.
@MainActor
final class RingLabelPresenter {
    private let model = RingLabelModel()
    private var window: NSPanel?
    private var host: NSHostingView<RingLabelView>?
    private var hide: Task<Void, Never>?

    func show(_ text: String, near ring: CGRect, edge: PanelEdge, screen: CGRect, behavior: NSWindow.CollectionBehavior) {
        let window = self.window ?? makeWindow()
        let reduceMotion = AccessibilityDisplay.shared.motionReduced
        model.text = text
        host?.layoutSubtreeIfNeeded()
        let size = host?.fittingSize ?? CGSize(width: 120, height: 28)
        window.setFrame(RingLabel.frame(ring: ring, size: size, edge: edge, screen: screen), display: false)
        window.collectionBehavior = behavior
        window.orderFrontRegardless()
        if reduceMotion { model.visible = true } else { withAnimation(.easeOut(duration: 0.2)) { model.visible = true } }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        hide?.cancel()
        hide = Task { [weak self] in
            try? await Task.sleep(for: .seconds(RingLabel.shownFor))
            guard !Task.isCancelled, let self else { return }
            if reduceMotion { self.model.visible = false } else { withAnimation(.easeIn(duration: 0.15)) { self.model.visible = false } }
            try? await Task.sleep(for: .seconds(reduceMotion ? 0 : 0.15))
            guard !Task.isCancelled else { return }
            self.window?.orderOut(nil)
        }
    }

    /// Takes the window away: the presenter is being discarded.
    func close() {
        hide?.cancel()
        window?.orderOut(nil)
        window = nil
        host = nil
    }

    private func makeWindow() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .screenSaver
        let host = NSHostingView(rootView: RingLabelView(model: model))
        panel.contentView = host
        self.host = host
        window = panel
        return panel
    }
}
