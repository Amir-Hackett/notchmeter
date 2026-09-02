import Foundation

/// One line saying what to do next. Priority orders the strip and the notifications; the symbol is the
/// non-colour channel beside the text.
struct Advice: Identifiable, Equatable, Sendable {
    enum Priority: Int, Comparable, Sendable {
        /// A tool is waiting on the user.
        case attention
        /// A window runs out before its reset.
        case danger
        /// A concrete move is available now: switch models, wait for a reset, notice an unusual burn.
        case warn
        /// Headroom elsewhere.
        case info

        static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let id: String
    let tool: ToolID?
    let priority: Priority
    let symbol: String
    let text: String
}

/// The prescriptive layer: every meter in the panel says how much; these rules say what to do about it. Each
/// rule is a pure function of the current readings and the cost summary, so it can be pinned by a test. The
/// combined list is sorted by priority, capped at three, and empty when there is nothing worth saying.
enum Advisor {
    struct Context {
        /// Live readings of the visible tools, in the user's tool order; a stale reading kept beside an error is not one.
        var readings: [UsageReading]
        var awaitingInput: Set<ToolID> = []
        /// The Claude Code sessions waiting on the user, newest first, when the hook reports them.
        var waitingSessions: [AgentSession] = []
        var cost: CostSummary? = nil
        var timeFormat: TimeFormatPreference = .auto
        /// Preferences.toolOrder: lists waiting tools in this order and breaks a tie for the tool with the most room.
        var toolOrder: [ToolID] = ToolID.allCases
        /// Measured drain per window ("tool/window" → fraction per hour) from the drain log; used before the even-burn projection.
        var drainRates: [String: Double] = [:]
        var now: Date = Date()
        var calendar: Calendar = .current

        func rank(_ tool: ToolID) -> Int {
            toolOrder.firstIndex(of: tool) ?? toolOrder.count
        }
    }

    static let limit = 3
    /// Another tool counts as somewhere to route work once this much of its main window is left.
    static let routingHeadroom = 0.5
    /// A per-model window this far used is worth routing away from...
    static let modelNearlyOut = 0.85
    /// ...to a model or the overall weekly window with at least this much left.
    static let modelHeadroom = 0.4
    /// The last hour costing this many times the usual active hour is worth a line.
    static let burnThreshold = 3.0
    /// A window that is out or behind and resets within this is worth waiting for rather than switching away from.
    static let waitHorizon: TimeInterval = 3600
    /// A Codex reset credit expiring within this while a window is behind is worth a line.
    static let creditHorizon: TimeInterval = 24 * 3600

    static func advise(_ context: Context) -> [Advice] {
        let runOuts = runOut(context)
        let alreadyRouted = Set(runOuts.compactMap(\.tool))
        let all = waiting(context)
            + runOuts
            + modelRouting(context)
            + waitForReset(context)
            + resetCredits(context)
            + [sessionBurn(context.cost)].compactMap { $0 }
            + crossProvider(context).filter { $0.tool.map { !alreadyRouted.contains($0) } ?? true }
        return Array(all.enumerated()
            .sorted { ($0.element.priority.rawValue, $0.offset) < ($1.element.priority.rawValue, $1.offset) }
            .map(\.element)
            .prefix(limit))
    }

    // MARK: - Rules

    /// A tool waiting for the user outranks everything: the meters cannot move until they answer. With the hook's
    /// session ids the line names the project: "Claude Code is waiting in notchmeter (and 1 more)."
    static func waiting(_ context: Context) -> [Advice] {
        ToolID.allCases.filter(context.awaitingInput.contains).sorted { context.rank($0) < context.rank($1) }.map { tool in
            let name = tool.productName
            if tool == .claude, let phrase = SessionTracker.waitingPhrase(context.waitingSessions) {
                return Advice(id: "waiting/\(tool.rawValue)", tool: tool, priority: .attention, symbol: "hand.raised.fill",
                              text: L("%1$@ is waiting in %2$@.", name, phrase))
            }
            return Advice(id: "waiting/\(tool.rawValue)", tool: tool, priority: .attention, symbol: "hand.raised.fill",
                          text: L("%@ is waiting for your input.", name))
        }
    }

    /// Every window behind pace with a run-out time, soonest first, each pointing at the tool with the most room.
    static func runOut(_ context: Context) -> [Advice] {
        var found: [(eta: TimeInterval, advice: Advice)] = []
        for reading in context.readings {
            for window in reading.windows {
                guard let eta = secondsToRunOut(window, tool: reading.tool, context: context),
                      let text = runOutText(tool: reading.tool, window: window, context: context) else { continue }
                found.append((eta, Advice(id: "run-out/\(reading.tool.rawValue)/\(window.id)", tool: reading.tool, priority: .danger,
                                          symbol: "exclamationmark.triangle.fill", text: text)))
            }
        }
        return found.sorted { $0.eta < $1.eta }.map(\.advice)
    }

    /// A tool whose main window is on track or behind, while another tool still has most of its own left.
    static func crossProvider(_ context: Context) -> [Advice] {
        context.readings.compactMap { reading in
            guard let main = mainWindow(of: reading), let pace = Pace.status(for: main, now: context.now), pace != .ahead,
                  let other = headroom(besides: reading.tool, in: context)
            else { return nil }
            return Advice(id: "route/\(reading.tool.rawValue)/\(other.tool.rawValue)", tool: reading.tool, priority: .info, symbol: "arrow.triangle.branch",
                          text: L("%1$@ has %2$ld%% of its %3$@ left.", other.tool.displayName, percent(other.left), name(other.window)))
        }
    }

    /// A per-model window nearly used up while another model, or the overall window, has room: the cheapest move
    /// there is, so it is said once per tool for the fullest model.
    static func modelRouting(_ context: Context) -> [Advice] {
        context.readings.compactMap { reading in
            let scoped = reading.windows.filter { $0.model != nil && $0.usedFraction != nil }
            guard let hot = scoped.filter({ ($0.usedFraction ?? 0) >= modelNearlyOut }).max(by: { ($0.usedFraction ?? 0) < ($1.usedFraction ?? 0) }),
                  let used = hot.usedFraction
            else { return nil }
            let alternative: (name: String, used: Double)?
            if let other = scoped.filter({ $0.model != hot.model && left(of: $0) >= modelHeadroom }).max(by: { left(of: $0) < left(of: $1) }),
               let otherModel = other.model, let otherUsed = other.usedFraction {
                alternative = (otherModel, otherUsed)
            } else if let main = mainWindow(of: reading), let mainUsed = main.usedFraction, 1 - mainUsed >= modelHeadroom {
                alternative = (L("Overall %@", name(main)), mainUsed)
            } else {
                alternative = nil
            }
            guard let alternative else { return nil }
            return Advice(id: "model/\(reading.tool.rawValue)/\(hot.id)", tool: reading.tool, priority: .warn, symbol: "arrow.left.arrow.right",
                          text: L("%1$@ is %2$ld%%. %3$@ is %4$ld%%. Switch models, not tools.",
                                  name(hot), percent(used), alternative.name, percent(alternative.used)))
        }
    }

    /// A window that is out or behind pace, resetting within the hour, while no other tool has room: waiting beats
    /// switching. Said once per tool for the soonest reset.
    static func waitForReset(_ context: Context) -> [Advice] {
        context.readings.compactMap { reading in
            guard headroom(besides: reading.tool, in: context) == nil else { return nil }
            let soon = reading.windows.filter { window in
                guard let used = window.usedFraction, let resetsAt = window.resetsAt, resetsAt > context.now,
                      resetsAt.timeIntervalSince(context.now) <= waitHorizon else { return false }
                return used >= 1 || Pace.status(for: window, now: context.now) == .behind
            }
            guard let window = soon.min(by: { ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture) }), let resetsAt = window.resetsAt else { return nil }
            return Advice(id: "wait/\(reading.tool.rawValue)/\(window.id)", tool: reading.tool, priority: .warn, symbol: "clock.arrow.circlepath",
                          text: L("%1$@ %2$@ resets in %3$@; wait rather than switch.", reading.tool.displayName, name(window),
                                  ResetText.duration(resetsAt.timeIntervalSince(context.now))))
        }
    }

    /// A Codex reset credit that expires within a day while a Codex window is behind pace: claim it in Codex.
    static func resetCredits(_ context: Context) -> [Advice] {
        context.readings.compactMap { reading in
            guard let credit = reading.windows.first(where: { $0.id == "reset_credits" }), let expiresAt = credit.resetsAt,
                  expiresAt > context.now, expiresAt.timeIntervalSince(context.now) <= creditHorizon,
                  reading.windows.contains(where: { Pace.status(for: $0, now: context.now) == .behind || ($0.usedFraction ?? 0) >= 1 })
            else { return nil }
            return Advice(id: "credit/\(reading.tool.rawValue)", tool: reading.tool, priority: .warn, symbol: "gift.fill",
                          text: L("A %1$@ reset credit expires in %2$@. Claim it in %1$@.", reading.tool.displayName,
                                  ResetText.duration(expiresAt.timeIntervalSince(context.now))))
        }
    }

    static func sessionBurn(_ cost: CostSummary?) -> Advice? {
        guard let cost, let burn = cost.burnMultiple, burn >= burnThreshold else { return nil }
        return Advice(id: "burn", tool: .claude, priority: .warn, symbol: "flame.fill",
                      text: L("This hour burned %1$@ — %2$@ your 30-day average.", Money.dollars(cost.lastHour), Burn.multiple(burn)))
    }

    // MARK: - Notification copy

    static func alertTitle(_ alert: PaceAlert) -> String {
        "\(alert.tool.displayName) \(alert.window.label)"
    }

    /// The same prescriptive line the strip would show for the window, in the state the alert reports.
    static func alertBody(_ alert: PaceAlert, context: Context) -> String {
        let window = alert.window
        let suffix = headroomSuffix(besides: alert.tool, in: context)
        switch alert.stage {
        case .behind, .runningOut:
            if let text = runOutText(tool: alert.tool, window: window, context: context) { return text }
            let reset = ResetText.line(resetsAt: window.resetsAt, hasLimit: true, display: .exact, timeFormat: context.timeFormat,
                                       now: context.now, calendar: context.calendar)
            return L("%1$@ %2$@ has run out. %3$@.%4$@", alert.tool.displayName, name(window), reset, suffix)
        case .onTrack:
            let projected = window.usedFraction.flatMap { used in
                window.resetsAt.flatMap { resetsAt in
                    window.periodDuration.flatMap { Pace.evaluate(usedFraction: used, resetsAt: resetsAt, period: $0, now: context.now)?.projectedFraction }
                }
            } ?? 1
            return L("%1$@ %2$@ is close to pace: ~%3$ld%% left at reset.%4$@", alert.tool.displayName, name(window), percent(max(0, 1 - projected)), suffix)
        case .reminder:
            let remaining = window.resetsAt.map { ResetText.duration($0.timeIntervalSince(context.now)) } ?? ""
            return L("%1$@ %2$@ resets in %3$@.", alert.tool.displayName, name(window), remaining)
        case .reset:
            let next = window.resetsAt.flatMap { resetsAt in
                window.periodDuration.map { period in
                    ResetText.line(resetsAt: resetsAt.addingTimeInterval(period), hasLimit: true, display: .exact, timeFormat: context.timeFormat,
                                   now: context.now, calendar: context.calendar)
                }
            }
            if let next { return L("%1$@ %2$@ reset — 100%% until it %3$@.", alert.tool.displayName, name(window), next.prefix(1).lowercased() + next.dropFirst()) }
            return L("%1$@ %2$@ reset — 100%% available.", alert.tool.displayName, name(window))
        }
    }

    // MARK: - Pieces

    /// "At this rate you hit the Claude weekly cap tomorrow at 2:00 PM, 3d 4h before reset. Codex weekly is at 22%."
    static func runOutText(tool: ToolID, window: LimitWindow, context: Context) -> String? {
        guard let resetsAt = window.resetsAt, let eta = secondsToRunOut(window, tool: tool, context: context) else { return nil }
        let runsOutAt = context.now.addingTimeInterval(eta)
        let when = L("%1$@ at %2$@", ResetText.dayPhrase(runsOutAt, now: context.now, calendar: context.calendar),
                     ResetText.time(runsOutAt, format: context.timeFormat, calendar: context.calendar))
        let margin = ResetText.duration(resetsAt.timeIntervalSince(runsOutAt))
        return L("At this rate you hit the %1$@ %2$@ cap %3$@, %4$@ before reset.%5$@",
                 tool.displayName, name(window), when, margin, headroomSuffix(besides: tool, in: context))
    }

    /// The window a routing decision spends: the longest tool-wide window with a limit (weekly for Claude and
    /// Codex, the billing cycle for Cursor).
    static func mainWindow(of reading: UsageReading) -> LimitWindow? {
        reading.windows
            .filter { $0.usedFraction != nil && $0.model == nil && $0.periodDuration != nil }
            .max { ($0.periodDuration ?? 0) < ($1.periodDuration ?? 0) }
    }

    /// The other tool with the most of its main window left, when that is at least the routing headroom; on a tie,
    /// the one the user placed first.
    static func headroom(besides tool: ToolID, in context: Context) -> (tool: ToolID, window: LimitWindow, left: Double)? {
        context.readings
            .filter { $0.tool != tool }
            .compactMap { reading in mainWindow(of: reading).map { (tool: reading.tool, window: $0, left: left(of: $0)) } }
            .filter { $0.left >= routingHeadroom }
            .max { ($0.left, -Double(context.rank($0.tool))) < ($1.left, -Double(context.rank($1.tool))) }
    }

    static func headroomSuffix(besides tool: ToolID, in context: Context) -> String {
        guard let other = headroom(besides: tool, in: context), let used = other.window.usedFraction else { return "" }
        return L(" %1$@ %2$@ is at %3$ld%%.", other.tool.displayName, name(other.window), percent(used))
    }

    /// "weekly", "session", "included usage"; a per-model window carries its cadence: "Fable weekly", "Gemini Pro
    /// daily", or "Gemini Pro quota" while the tool declares no window length.
    static func name(_ window: LimitWindow) -> String {
        guard let model = window.model else { return window.label.lowercased() }
        return "\(model) \(cadence(window.periodDuration))"
    }

    static func cadence(_ period: TimeInterval?) -> String {
        switch period {
        case nil: L("quota")
        case Period.week?: L("weekly")
        case Period.day?: L("daily")
        case Period.fiveHours?: L("session")
        case let period?: L("%@ window", ResetText.windowName(period: period))
        }
    }

    static func percent(_ fraction: Double) -> Int {
        Int((fraction * 100).rounded())
    }

    private static func left(of window: LimitWindow) -> Double {
        1 - (window.usedFraction ?? 1)
    }

    /// The measured drain when the log has one for the window, else the even-burn projection.
    private static func secondsToRunOut(_ window: LimitWindow, tool: ToolID, context: Context) -> TimeInterval? {
        guard let used = window.usedFraction, let resetsAt = window.resetsAt, let period = window.periodDuration else { return nil }
        guard Pace.status(for: window, now: context.now) == .behind else { return nil }
        if let measured = Pace.secondsToRunOut(usedFraction: used, rate: context.drainRates["\(tool.rawValue)/\(window.id)"], resetsAt: resetsAt, now: context.now) {
            return measured
        }
        return Pace.secondsToRunOut(usedFraction: used, resetsAt: resetsAt, period: period, now: context.now)
    }
}
