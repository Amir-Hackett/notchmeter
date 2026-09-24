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
    /// This tool's hook (Claude Code's or Cursor's) fired recently: proof of activity the file check can lag behind.
    var hookNudge = false
    /// A Claude Code status line reported the same windows this recently; the endpoint read is skipped while it is fresh.
    var secondsSinceStatusline: TimeInterval?
    /// Another user's session is in front (fast user switching): nobody can see this one's screen, but this
    /// account's own agents go on running behind it and its limits are shared with every other device signed in.
    var sessionInactive = false
    /// The tool's main window is at 100 % with a known reset: nothing can change before it, so the tool idles until then.
    var exhaustedUntil: Date?
    var now = Date()
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

/// Adaptive polling: nothing while nobody can see the screen (locked or asleep), half as often on battery or in
/// Low Power Mode, a quarter as often once no agent has been active for half an hour, at the ceiling while a
/// window is exhausted with a known reset (nothing can change before it; a reset timer reads at the reset itself)
/// or while another user's session is in front, never more than fifteen minutes apart while awake, and never
/// faster than the provider's own cadence. A fresh status-line reading replaces the read, save for the half-hourly
/// one `endpointDue` keeps for the figures only Claude's endpoint carries.
///
/// Fast user switching slows the cadence rather than stopping it, which the other pauses do not. Locked and
/// asleep mean the work has stopped too; a switched-out session's agents keep running, and the limits being
/// metered belong to an account, not to a Mac, so they drain from the other login and from every other device
/// signed into the same account. Stopping there would lose the drain rows and hold back the run-out warning for
/// exactly as long as nobody was looking, which is when it is worth the most.
enum PollingPolicy {
    static let idleAfter: TimeInterval = 30 * 60
    static let idleMultiplier: Double = 4
    static let batteryMultiplier: Double = 2
    static let ceiling: TimeInterval = 15 * 60
    static let statuslineFreshFor: TimeInterval = 180
    /// How often the endpoint is still read while the status line stands in, and then only for an account whose
    /// endpoint carries something the status line does not (`endpointDue`).
    static let endpointBesideStatusline: TimeInterval = 30 * 60

    static func decide(_ inputs: PollingInputs) -> PollingDecision {
        if inputs.asleep { return .paused(.asleep) }
        if inputs.screenLocked { return .paused(.screenLocked) }
        if inputs.screensAsleep { return .paused(.screensAsleep) }
        if let seconds = inputs.secondsSinceStatusline, seconds < statuslineFreshFor { return .paused(.statusline) }
        var interval = inputs.baseInterval
        if isIdle(inputs) { interval = min(interval * idleMultiplier, ceiling) }
        if inputs.onBattery || inputs.lowPowerMode { interval = min(interval * batteryMultiplier, ceiling) }
        if isExhausted(inputs) { interval = ceiling }
        if inputs.sessionInactive { interval = ceiling }
        return .after(max(interval, inputs.baseInterval))
    }

    /// When Claude's usage endpoint is next worth reading while a status line stands in for it; nil for never.
    ///
    /// The status line carries the session and weekly windows (and a gateway's spend limit), and those are taken
    /// from it rather than from the network. The endpoint also answers figures the status line has no field for:
    /// the per-model weekly limits and the extra-usage spend, and the weekly window itself when a payload leaves it
    /// out. Showing only what the status line has would drop those from the card and silence the extra-usage
    /// notice for exactly the people who use Claude Code most, whose status line never goes stale; carrying them
    /// over from the last endpoint answer without ever asking again would show an hours-old spend as current,
    /// because the reading takes the status line's time. So the endpoint is read beside the status line every half
    /// hour, a sixth of its own cadence, and only while the last reading holds a figure it alone supplied. An
    /// account whose endpoint says nothing the status line does not is never read while the status line is fresh.
    /// With no endpoint figure on record and no read yet this run, one read learns which kind of account it is;
    /// after that read the answer stands until the next launch. A reset on an endpoint-only window brings the read
    /// forward to the reset.
    static func endpointDue(besideStatusline carried: [LimitWindow], reading: UsageReading?, lastEndpointRead: Date?, now: Date) -> Date? {
        let fromEndpoint = (reading?.windows ?? []).filter { $0.source == .vendorEndpoint || $0.source == .rateLimitHeaders }
        guard !fromEndpoint.isEmpty else { return lastEndpointRead == nil ? now : nil }
        let ids = Set(carried.map(\.id))
        let endpointOnly = fromEndpoint.filter { !ids.contains($0.id) }
        guard !endpointOnly.isEmpty else { return nil }
        let lastRead = lastEndpointRead ?? .distantPast
        // A reset on a window only the endpoint carries is due at once: the status line cannot say it happened, so
        // without this the reset refresh took the status line's reading and carried the used-up figure past it.
        let resets = endpointOnly.compactMap(\.resetsAt).filter { $0 > lastRead }
        if resets.contains(where: { $0 <= now }) { return now }
        let cadence = lastRead.addingTimeInterval(endpointBesideStatusline)
        return resets.min().map { min($0, cadence) } ?? cadence
    }

    /// The main window is used up and its reset is still ahead.
    static func isExhausted(_ inputs: PollingInputs) -> Bool {
        guard let until = inputs.exhaustedUntil else { return false }
        return until > inputs.now
    }

    static func isIdle(_ inputs: PollingInputs) -> Bool {
        if inputs.hookNudge { return false }
        guard let minutes = inputs.minutesSinceLastAgentActivity else { return true }
        return minutes * 60 >= idleAfter
    }
}
