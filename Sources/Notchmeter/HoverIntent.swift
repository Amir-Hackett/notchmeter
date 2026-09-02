import CoreGraphics
import Foundation

/// Decides when the panel opens and closes from timestamped facts about the pointer. Pure: no clock and no
/// AppKit, so the rules are unit-tested and a shape that morphs under a stationary cursor cannot flip them.
/// Counts in whole milliseconds so the thresholds are exact.
///
/// Open only once the pointer has rested in the compact region for `expandDwell`. After any transition ignore
/// the pointer until the morph settles or `settleTimeout` passes, whichever is first. Close only once the pointer
/// has been outside the expanded region (widened by `expandedMargin`) for `collapseDwell`, or at once on a click
/// outside, a Spaces switch or the screen lock. Never close in Always mode; never repeat the current state.
struct HoverIntent: Equatable {
    enum Mode: Equatable { case onHover, always }
    enum State: String, Equatable { case compact, expanded }
    enum Output: Equatable { case expand, collapse, none }

    static let expandDwell: TimeInterval = 0.25
    static let collapseDwell: TimeInterval = 0.4
    static let settleTimeout: TimeInterval = 0.35
    static let expandedMargin: CGFloat = 8

    var mode: Mode
    private(set) var state: State
    private var settlingUntil: Int?
    private var insideCompactSince: Int?
    private var outsideExpandedSince: Int?

    init(mode: Mode, state: State = .compact) {
        self.mode = mode
        self.state = state
    }

    /// When re-sampling an unchanged pointer would decide something; nil while nothing is pending.
    var nextDeadline: TimeInterval? {
        switch state {
        case .compact: insideCompactSince.map { Self.seconds($0 + Self.milliseconds(Self.expandDwell)) }
        case .expanded: outsideExpandedSince.map { Self.seconds($0 + Self.milliseconds(Self.collapseDwell)) }
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
            guard inCompact else {
                insideCompactSince = nil
                return .none
            }
            guard let since = insideCompactSince else {
                insideCompactSince = now
                return .none
            }
            guard now - since >= Self.milliseconds(Self.expandDwell) else { return .none }
            return begin(.expanded, at: now)
        case .expanded:
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

    mutating func spaceChangedOrLocked(at time: TimeInterval) -> Output {
        collapseNow(at: time)
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
        guard state == .expanded, mode == .onHover else { return .none }
        return begin(.compact, at: Self.milliseconds(time))
    }

    private mutating func begin(_ next: State, at now: Int) -> Output {
        state = next
        settlingUntil = now + Self.milliseconds(Self.settleTimeout)
        insideCompactSince = nil
        outsideExpandedSince = nil
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
