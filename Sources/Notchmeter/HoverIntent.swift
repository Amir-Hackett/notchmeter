import CoreGraphics
import Foundation

/// Decides when the panel opens and closes from timestamped facts about the pointer. Pure: no clock and no
/// AppKit, so the rules are unit-tested and a shape that morphs under a stationary cursor cannot flip them.
/// Counts in whole milliseconds so the thresholds are exact.
///
/// Open only once the pointer has rested in the compact region for `expandDwell` (the Hover delay setting). After
/// any transition ignore the pointer until the morph settles or `settleTimeout` passes, whichever is first. Close
/// only once the pointer has been outside the expanded region (widened by `expandedMargin`) for `collapseDwell`,
/// or at once on a click outside, a Spaces switch, the screen lock or Escape. In Open on click mode the pointer
/// never opens or closes anything: a click on the rings toggles, a click outside closes. A swipe down over the
/// rings opens and a swipe up over the panel closes. Never close in Always mode by pointer; a hotkey toggle
/// still can. A glance opens a closed panel for a few seconds and closes it again unless the pointer has come in
/// meanwhile, in which case it is an ordinary open from then on. Never repeat the current state.
struct HoverIntent: Equatable {
    enum Mode: Equatable { case onHover, onClick, always }
    enum State: String, Equatable { case compact, expanded }
    enum Output: Equatable { case expand, collapse, none }
    enum Swipe: Equatable { case down, up }

    static let expandDwell: TimeInterval = 0.25
    static let collapseDwell: TimeInterval = 0.4
    static let settleTimeout: TimeInterval = 0.35
    static let expandedMargin: CGFloat = 8
    static let glanceDuration: TimeInterval = 3

    var mode: Mode
    /// The rest before an open, 0.1 to 1 s.
    var expandDwell: TimeInterval
    private(set) var state: State
    private var settlingUntil: Int?
    private var insideCompactSince: Int?
    private var outsideExpandedSince: Int?
    private var glanceUntil: Int?

    init(mode: Mode, state: State = .compact, expandDwell: TimeInterval = HoverIntent.expandDwell) {
        self.mode = mode
        self.state = state
        self.expandDwell = min(1, max(0.1, expandDwell))
    }

    /// A glance is open and the pointer has not come in.
    var isGlancing: Bool { glanceUntil != nil }

    /// When re-sampling an unchanged pointer would decide something; nil while nothing is pending.
    var nextDeadline: TimeInterval? {
        switch state {
        case .compact:
            return insideCompactSince.map { Self.seconds($0 + Self.milliseconds(expandDwell)) }
        case .expanded:
            let leave = outsideExpandedSince.map { Self.seconds($0 + Self.milliseconds(Self.collapseDwell)) }
            let glance = glanceUntil.map(Self.seconds)
            return [leave, glance].compactMap { $0 }.min()
        }
    }

    mutating func pointer(inCompact: Bool, inExpanded: Bool, at time: TimeInterval) -> Output {
        let now = Self.milliseconds(time)
        if let settlingUntil {
            guard now >= settlingUntil else { return .none }
            self.settlingUntil = nil
        }
        switch state {
        case .compact:
            guard mode != .onClick, inCompact else {
                insideCompactSince = nil
                return .none
            }
            guard let since = insideCompactSince else {
                insideCompactSince = now
                return .none
            }
            guard now - since >= Self.milliseconds(expandDwell) else { return .none }
            return begin(.expanded, at: now)
        case .expanded:
            if let until = glanceUntil {
                if inExpanded {
                    glanceUntil = nil
                } else if now >= until {
                    glanceUntil = nil
                    return begin(.compact, at: now)
                } else {
                    return .none
                }
            }
            guard mode == .onHover, !inExpanded else {
                outsideExpandedSince = nil
                return .none
            }
            guard let since = outsideExpandedSince else {
                outsideExpandedSince = now
                return .none
            }
            guard now - since >= Self.milliseconds(Self.collapseDwell) else { return .none }
            return begin(.compact, at: now)
        }
    }

    mutating func clickOutside(at time: TimeInterval) -> Output {
        collapseNow(at: time)
    }

    /// A click on the rings: toggles in Open on click mode, nothing otherwise.
    mutating func clickInside(at time: TimeInterval) -> Output {
        guard mode == .onClick else { return .none }
        return begin(state == .compact ? .expanded : .compact, at: Self.milliseconds(time))
    }

    mutating func spaceChangedOrLocked(at time: TimeInterval) -> Output {
        collapseNow(at: time)
    }

    mutating func escape(at time: TimeInterval) -> Output {
        collapseNow(at: time)
    }

    /// A swipe down over the rings opens; a swipe up over the open panel closes (not in Always mode).
    mutating func swipe(_ swipe: Swipe, inCompact: Bool, inExpanded: Bool, at time: TimeInterval) -> Output {
        switch (swipe, state) {
        case (.down, .compact) where inCompact:
            return begin(.expanded, at: Self.milliseconds(time))
        // Only over the strip beside the notch: inside the panel an upward swipe is the user scrolling
        // the content, and closing on it makes a scrollable panel impossible to read.
        case (.up, .expanded) where inCompact && !inExpanded && mode != .always:
            return begin(.compact, at: Self.milliseconds(time))
        default:
            return .none
        }
    }

    /// The global shortcut: opens a closed panel, closes an open one, whatever the mode.
    mutating func toggle(at time: TimeInterval) -> Output {
        begin(state == .compact ? .expanded : .compact, at: Self.milliseconds(time))
    }

    /// Opens a closed panel for `duration`; nothing while it is already open or in Always mode.
    mutating func glance(for duration: TimeInterval = HoverIntent.glanceDuration, at time: TimeInterval) -> Output {
        guard state == .compact, mode != .always else { return .none }
        let now = Self.milliseconds(time)
        let output = begin(.expanded, at: now)
        glanceUntil = now + Self.milliseconds(duration)
        return output
    }

    /// The morph finished; pointer facts count again from here.
    mutating func transitionSettled(at time: TimeInterval) {
        settlingUntil = nil
    }

    /// The controller moved the panel itself (Always open at launch, a layout swap); settle from here.
    mutating func adopt(_ state: State, at time: TimeInterval) {
        guard state != self.state else { return }
        _ = begin(state, at: Self.milliseconds(time))
    }

    private mutating func collapseNow(at time: TimeInterval) -> Output {
        guard state == .expanded, mode != .always else { return .none }
        return begin(.compact, at: Self.milliseconds(time))
    }

    private mutating func begin(_ next: State, at now: Int) -> Output {
        state = next
        settlingUntil = now + Self.milliseconds(Self.settleTimeout)
        insideCompactSince = nil
        outsideExpandedSince = nil
        glanceUntil = nil
        return next == .expanded ? .expand : .collapse
    }

    private static func milliseconds(_ seconds: TimeInterval) -> Int {
        Int((seconds * 1000).rounded())
    }

    private static func seconds(_ milliseconds: Int) -> TimeInterval {
        TimeInterval(milliseconds) / 1000
    }
}

/// The two visible shapes in screen coordinates. Never a window frame: DynamicNotchKit's window is an invisible
/// column half the screen wide and the full screen tall, hung from the notch.
struct HoverRegions: Equatable {
    var compact: CGRect
    var expanded: CGRect

    static let none = HoverRegions(compact: .null, expanded: .null)

    func hit(_ point: CGPoint) -> (inCompact: Bool, inExpanded: Bool) {
        let margin = HoverIntent.expandedMargin
        return (compact.contains(point), expanded.insetBy(dx: -margin, dy: -margin).contains(point))
    }

    /// Clicks use the panel itself, without the hover margin.
    func isOutsidePanel(_ point: CGPoint) -> Bool {
        !expanded.contains(point)
    }
}
