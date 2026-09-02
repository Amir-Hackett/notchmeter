import Foundation

/// What the scheduler knows when it decides how long to wait before a tool's next read.
struct PollingInputs: Equatable {
    /// The provider's own cadence; the decision never goes below it.
    var baseInterval: TimeInterval
    var screenLocked = false
    var asleep = false
    /// The displays are asleep while the Mac is not (a desktop, or a lid closed with sleep off): nobody can see the rings.
    var screensAsleep = false
    var onBattery = false
    /// macOS Low Power Mode, which Apple describes as pausing discretionary background activity; treated like battery.
    var lowPowerMode = false
    /// Minutes since the tool's files on disk last changed; nil when nothing of the tool's has ever been seen.
    var minutesSinceLastAgentActivity: Double?
    /// A Claude Code hook fired recently: proof of activity the file check can lag behind.
    var hookNudge = false
    /// A Claude Code status line reported the same windows this recently; the endpoint read is skipped while it is fresh.
    var secondsSinceStatusline: TimeInterval?
}

enum PauseReason: Equatable {
    case screenLocked, asleep, screensAsleep
    /// The Claude Code status line is supplying the windows; nothing is asked of the endpoint meanwhile.
    case statusline

    var footerText: String {
        switch self {
        case .screenLocked: L("Paused while the screen is locked")
        case .asleep: L("Paused until wake")
        case .screensAsleep: L("Paused while the display sleeps")
        case .statusline: L("From Claude Code's status line")
        }
    }
}

enum PollingDecision: Equatable {
    case paused(PauseReason)
    case after(TimeInterval)
}

/// Adaptive polling: nothing while nobody can see the screen, half as often on battery or in Low Power Mode, a
/// quarter as often once no agent has been active for half an hour, never more than fifteen minutes apart while
/// awake, and never faster than the provider's own cadence. A fresh status-line reading replaces the read entirely.
enum PollingPolicy {
    static let idleAfter: TimeInterval = 30 * 60
    static let idleMultiplier: Double = 4
    static let batteryMultiplier: Double = 2
    static let ceiling: TimeInterval = 15 * 60
    static let statuslineFreshFor: TimeInterval = 180

    static func decide(_ inputs: PollingInputs) -> PollingDecision {
        if inputs.asleep { return .paused(.asleep) }
        if inputs.screenLocked { return .paused(.screenLocked) }
        if inputs.screensAsleep { return .paused(.screensAsleep) }
        if let seconds = inputs.secondsSinceStatusline, seconds < statuslineFreshFor { return .paused(.statusline) }
        var interval = inputs.baseInterval
        if isIdle(inputs) { interval = min(interval * idleMultiplier, ceiling) }
        if inputs.onBattery || inputs.lowPowerMode { interval = min(interval * batteryMultiplier, ceiling) }
        return .after(max(interval, inputs.baseInterval))
    }

    static func isIdle(_ inputs: PollingInputs) -> Bool {
        if inputs.hookNudge { return false }
        guard let minutes = inputs.minutesSinceLastAgentActivity else { return true }
        return minutes * 60 >= idleAfter
    }
}
