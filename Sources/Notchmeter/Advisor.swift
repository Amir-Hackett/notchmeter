import Foundation

/// One line saying what to do next. Priority orders the strip and the notifications; the symbol is the
/// non-colour channel beside the text; a URL, when there is one, is where the line points (a vendor's status page).
struct Advice: Identifiable, Equatable, Sendable {
    enum Priority: Int, Comparable, Sendable {
        /// A tool is waiting on the user.
        case attention
        /// A window runs out before its reset, or real money started flowing.
        case danger
        /// A concrete move is available now: switch models, wait for a reset, notice an unusual burn.
        case warn
        /// Headroom elsewhere, or the time of day.
        case info

        static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let id: String
    let tool: ToolID?
    let priority: Priority
    let symbol: String
    let text: String
    let url: URL?

    init(id: String, tool: ToolID?, priority: Priority, symbol: String, text: String, url: URL? = nil) {
        self.id = id
        self.tool = tool
        self.priority = priority
        self.symbol = symbol
        self.text = text
        self.url = url
    }
}

/// Extra-usage credits rose since the last reading: by how much, over how long, and whether the plan windows
/// still had room (the "why am I paying" signature).
struct ExtraUsageRise: Equatable, Sendable {
    let amountUSD: Double
    let over: TimeInterval
    /// The most-used plan window's used fraction at the time; nil with no plan window.
    let planUsed: Double?
    let firstThisMonth: Bool
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
        /// The run-out interval per window ("tool/window") where the drain log has enough history.
        var runOuts: [String: RunOutInterval] = [:]
        /// The spend budget, in US dollars, for the calendar month and the week.
        var monthlyBudgetUSD: Double? = nil
        var weeklyBudgetUSD: Double? = nil
        var extraUsageRise: ExtraUsageRise? = nil
        /// The peak window that applies to a tool.
        var peakHours: [ToolID: PeakHours] = [:]
        /// Tools whose session stopped on a rate limit or waits on quota, per the hook.
        var limitHitTools: Set<ToolID> = []
        /// Tools whose endpoint is answering server errors, so the wait line points at the status page.
        var serverTrouble: [ToolID: Int] = [:]
        var metering: MeteringRatio? = nil
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
    /// Off-peak arriving within this is worth telling the user to queue the long job for.
    static let offPeakHorizon: TimeInterval = 3600
    /// The plan windows both under this while extra usage rises is the mis-routing signature.
    static let planRoomForAlarm = 0.9
    /// Today's 1-hour cache-write share this far under the 30-day norm is a TTL shift.
    static let cacheShiftMargin = 0.25
    static let cacheShiftMinimumWrites = 100_000

    static func advise(_ context: Context) -> [Advice] {
        let runOuts = runOut(context)
        let alreadyRouted = Set(runOuts.compactMap(\.tool))
        let all = waiting(context)
            + extraUsage(context)
            + runOuts
            + limitHit(context)
            + budget(context)
            + modelRouting(context)
            + waitForReset(context)
            + resetCredits(context)
            + burn(context)
            + [metering(context)].compactMap { $0 }
            + [cacheShift(context.cost)].compactMap { $0 }
            + serverTrouble(context)
            + peak(context)
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

    /// Real money started flowing: the first rise of extra-usage credits in a month is worth a line, and a rise
    /// while the plan windows still have room is the mis-routing signature and is said louder.
    static func extraUsage(_ context: Context) -> [Advice] {
        guard let rise = context.extraUsageRise, rise.amountUSD > 0 else { return [] }
        let over = ResetText.duration(max(60, rise.over))
        if let planUsed = rise.planUsed, planUsed < planRoomForAlarm {
            return [Advice(id: "extra/room", tool: .claude, priority: .danger, symbol: "creditcard.trianglebadge.exclamationmark",
                           text: L("Extra usage rose %1$@ in %2$@ while your plan has %3$ld%% left; check /usage.", Money.dollars(rise.amountUSD), over, percent(1 - planUsed)),
                           url: ProviderLinks.usage(.claude))]
        }
        guard rise.firstThisMonth else { return [] }
        return [Advice(id: "extra/first", tool: .claude, priority: .warn, symbol: "creditcard",
                       text: L("You are now paying: extra usage rose %@ this month.", Money.dollars(rise.amountUSD)), url: ProviderLinks.usage(.claude))]
    }

    /// The hook says a session stopped on a rate limit or waits on quota: name the reset, whatever else has room.
    static func limitHit(_ context: Context) -> [Advice] {
        context.readings.compactMap { reading in
            guard context.limitHitTools.contains(reading.tool) else { return nil }
            let candidates = reading.windows.filter { window in
                guard let resetsAt = window.resetsAt, resetsAt > context.now, let used = window.usedFraction else { return false }
                return used >= 0.9
            }
            guard let window = candidates.min(by: { ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture) }), let resetsAt = window.resetsAt else {
                return Advice(id: "limit/\(reading.tool.rawValue)", tool: reading.tool, priority: .warn, symbol: "clock.arrow.circlepath",
                              text: L("%@ hit its rate limit; wait for the reset.", reading.tool.productName))
            }
            return Advice(id: "limit/\(reading.tool.rawValue)/\(window.id)", tool: reading.tool, priority: .warn, symbol: "clock.arrow.circlepath",
                          text: L("%1$@ hit its limit; %2$@ resets in %3$@.", reading.tool.productName, name(window, of: reading.tool), ResetText.duration(resetsAt.timeIntervalSince(context.now))))
        }
    }

    /// The month (or the week since the weekly window started) projected against the budget. The budget is one
    /// number over every tool, so the spend it is measured against is the total; where more than one tool is
    /// spending, the line names whichever is most of it, because that is where a cut would come from.
    static func budget(_ context: Context) -> [Advice] {
        guard let cost = context.cost else { return [] }
        var lines: [Advice] = []
        if let budget = context.monthlyBudgetUSD, budget > 0 {
            let spent = cost.totals(.month).cost
            let elapsed = BudgetPeriod.month(now: context.now, calendar: context.calendar).elapsedFraction(now: context.now)
            lines.append(contentsOf: budgetLines(id: "month", spent: spent, budget: budget, elapsed: elapsed, period: L("month"),
                                                 leader: leader(cost, range: .month)))
        }
        if let budget = context.weeklyBudgetUSD, budget > 0, let week = cost.week {
            let elapsed = min(1, max(0, context.now.timeIntervalSince(week.start) / Period.week))
            lines.append(contentsOf: budgetLines(id: "week", spent: cost.totals(.week).cost, budget: budget, elapsed: elapsed, period: L("week"),
                                                 leader: leader(cost, range: .week)))
        }
        return lines
    }

    /// The tool that is most of a range's spend, when more than one tool is spending at all.
    static func leader(_ cost: CostSummary, range: CostRange) -> (tool: ToolID, cost: Double)? {
        let spending = cost.providers.map { (tool: $0.tool, cost: $0.totals(range).cost) }.filter { $0.cost > 0 }
        guard spending.count > 1, let top = spending.max(by: { $0.cost < $1.cost }) else { return nil }
        return top
    }

    private static func budgetLines(id: String, spent: Double, budget: Double, elapsed: Double, period: String,
                                    leader: (tool: ToolID, cost: Double)?) -> [Advice] {
        let share = leader.map { L(" %1$@ is %2$@ of it.", $0.tool.displayName, Money.dollars($0.cost, cents: false)) } ?? ""
        if spent >= budget {
            return [Advice(id: "budget/\(id)/over", tool: leader?.tool, priority: .danger, symbol: "dollarsign.circle.fill",
                           text: L("The %1$@'s %2$@ is past the %3$@ budget.", period, Money.dollars(spent, cents: false), Money.dollars(budget, cents: false)) + share)]
        }
        guard elapsed >= 0.1 else { return [] }
        let projected = spent / elapsed
        guard projected > budget else { return [] }
        return [Advice(id: "budget/\(id)", tool: leader?.tool, priority: .warn, symbol: "dollarsign.circle",
                       text: L("At this rate the %1$@ costs %2$@ against a %3$@ budget.", period, Money.dollars(projected, cents: false), Money.dollars(budget, cents: false)) + share)]
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
    /// switching. Said once per tool for the soonest reset; it points at the status page while the tool's endpoint
    /// is answering server errors.
    static func waitForReset(_ context: Context) -> [Advice] {
        context.readings.compactMap { reading in
            guard headroom(besides: reading.tool, in: context) == nil, !context.limitHitTools.contains(reading.tool) else { return nil }
            let soon = reading.windows.filter { window in
                guard let used = window.usedFraction, let resetsAt = window.resetsAt, resetsAt > context.now,
                      resetsAt.timeIntervalSince(context.now) <= waitHorizon else { return false }
                return used >= 1 || Pace.status(for: window, now: context.now) == .behind
            }
            guard let window = soon.min(by: { ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture) }), let resetsAt = window.resetsAt else { return nil }
            return Advice(id: "wait/\(reading.tool.rawValue)/\(window.id)", tool: reading.tool, priority: .warn, symbol: "clock.arrow.circlepath",
                          text: L("%1$@ %2$@ resets in %3$@; wait rather than switch.", reading.tool.displayName, name(window, of: reading.tool),
                                  ResetText.duration(resetsAt.timeIntervalSince(context.now))),
                          url: context.serverTrouble[reading.tool] != nil ? ProviderLinks.status(reading.tool) : nil)
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

    /// An hour that cost several times a normal one, named per tool. Only a source whose entries carry a time of
    /// day can say (Claude Code's transcripts, Codex's rollouts); a day-resolution export reports no burn at all.
    /// With no single tool over the line but every tool together over it, the total is said instead.
    static func burn(_ context: Context) -> [Advice] {
        guard let cost = context.cost else { return [] }
        let hot = cost.providers
            .filter { ($0.burnMultiple ?? 0) >= burnThreshold }
            .sorted { context.rank($0.tool) < context.rank($1.tool) }
        if !hot.isEmpty {
            return hot.map { provider in
                Advice(id: "burn/\(provider.tool.rawValue)", tool: provider.tool, priority: .warn, symbol: "flame.fill",
                       text: L("%1$@ burned %2$@ this hour — %3$@ its 30-day average.", provider.tool.productName,
                               Money.dollars(provider.lastHour ?? 0), Burn.multiple(provider.burnMultiple ?? 0)))
            }
        }
        guard cost.providers.count > 1, let burn = cost.burnMultiple, burn >= burnThreshold else { return [] }
        return [Advice(id: "burn", tool: nil, priority: .warn, symbol: "flame.fill",
                       text: L("Every tool together burned %1$@ this hour — %2$@ your 30-day average.", Money.dollars(cost.lastHour), Burn.multiple(burn)))]
    }

    /// The session window metering about twice as heavily as the 30-day norm: the number behind "did they change something".
    static func metering(_ context: Context) -> Advice? {
        guard let ratio = context.metering, ratio.isHeavier, let multiple = ratio.multiple, let median = ratio.median else { return nil }
        return Advice(id: "metering", tool: .claude, priority: .warn, symbol: "scalemass",
                      text: L("The session is metering about %1$@ heavier than your norm: %2$@ per 1%% vs %3$@.", Burn.multiple(multiple),
                              Money.tokens(Int(ratio.tokensPerPercent.rounded())), Money.tokens(Int(median.rounded()))))
    }

    /// Today's cache writes moved to the 5-minute tier against the 30-day norm: more re-caching, more quota per turn.
    static func cacheShift(_ cost: CostSummary?) -> Advice? {
        guard let cost, let shift = CacheTTL.shift(today: cost.totals(.today).tokens, norm: cost.totals(.last30Days).tokens) else { return nil }
        return Advice(id: "cache-ttl", tool: .claude, priority: .warn, symbol: "clock.badge.exclamationmark",
                      text: L("Cache writes today are %1$ld%% 1-hour against a 30-day norm of %2$ld%%: the 5-minute tier re-caches more often and costs more quota per turn.",
                              percent(shift.today), percent(shift.norm)))
    }

    /// A vendor answering server errors: the reading is stale through no fault of the login; the status page says why.
    static func serverTrouble(_ context: Context) -> [Advice] {
        context.serverTrouble.sorted { context.rank($0.key) < context.rank($1.key) }.map { tool, code in
            Advice(id: "status/\(tool.rawValue)", tool: tool, priority: .info, symbol: "antenna.radiowaves.left.and.right.slash",
                   text: L("%1$@'s usage endpoint is answering HTTP %2$ld; check its status page.", tool.displayName, code), url: ProviderLinks.status(tool))
        }
    }

    /// Inside Anthropic's peak window: say so, and when off-peak is under an hour away, say to queue the long job for it.
    static func peak(_ context: Context) -> [Advice] {
        context.readings.compactMap { reading in
            guard let peak = context.peakHours[reading.tool], peak.isPeak(at: context.now), let boundary = peak.nextBoundary(after: context.now) else { return nil }
            let until = boundary.date.timeIntervalSince(context.now)
            if until <= offPeakHorizon {
                return Advice(id: "peak/\(reading.tool.rawValue)/soon", tool: reading.tool, priority: .info, symbol: "moon",
                              text: L("Off-peak in %@: start the long job then.", ResetText.duration(until)))
            }
            return Advice(id: "peak/\(reading.tool.rawValue)", tool: reading.tool, priority: .info, symbol: "sun.max",
                          text: L("Peak hours until %@: the session projection assumes the peak rate.", PeakHours.clock(boundary.date, format: context.timeFormat, timeZone: context.calendar.timeZone)))
        }
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
        case .behind, .runningOut, .limitHit:
            if let text = runOutText(tool: alert.tool, window: window, context: context) { return text }
            let reset = ResetText.line(resetsAt: window.resetsAt, hasLimit: true, display: .exact, timeFormat: context.timeFormat,
                                       now: context.now, calendar: context.calendar)
            return L("%1$@ %2$@ has run out. %3$@.%4$@", alert.tool.displayName, name(window, of: alert.tool), reset, suffix)
        case .onTrack:
            let projected = window.usedFraction.flatMap { used in
                window.resetsAt.flatMap { resetsAt in
                    window.periodDuration.flatMap { Pace.evaluate(usedFraction: used, resetsAt: resetsAt, period: $0, now: context.now)?.projectedFraction }
                }
            } ?? 1
            return L("%1$@ %2$@ is close to pace: ~%3$ld%% left at reset.%4$@", alert.tool.displayName, name(window, of: alert.tool), percent(max(0, 1 - projected)), suffix)
        case .reminder:
            let remaining = window.resetsAt.map { ResetText.duration($0.timeIntervalSince(context.now)) } ?? ""
            return L("%1$@ %2$@ resets in %3$@.", alert.tool.displayName, name(window, of: alert.tool), remaining)
        case .reset:
            let next = window.resetsAt.flatMap { resetsAt in
                window.periodDuration.map { period in
                    ResetText.line(resetsAt: resetsAt.addingTimeInterval(period), hasLimit: true, display: .exact, timeFormat: context.timeFormat,
                                   now: context.now, calendar: context.calendar)
                }
            }
            if let next { return L("%1$@ %2$@ reset — 100%% until it %3$@.", alert.tool.displayName, name(window, of: alert.tool), next.prefix(1).lowercased() + next.dropFirst()) }
            return L("%1$@ %2$@ reset — 100%% available.", alert.tool.displayName, name(window, of: alert.tool))
        }
    }

    // MARK: - Pieces

    /// "At this rate you hit the Claude weekly cap tomorrow at 2:00 PM, 3d 4h before reset. Codex weekly is at 22%."
    /// With a wide run-out interval from the drain log: "…cap between 2:10 and 3:40 PM…".
    static func runOutText(tool: ToolID, window: LimitWindow, context: Context) -> String? {
        guard let resetsAt = window.resetsAt, let eta = secondsToRunOut(window, tool: tool, context: context) else { return nil }
        let runsOutAt = context.now.addingTimeInterval(eta)
        let suffix = headroomSuffix(besides: tool, in: context)
        if let interval = context.runOuts["\(tool.rawValue)/\(window.id)"], interval.isWide, context.now.addingTimeInterval(interval.latest) < resetsAt {
            let from = ResetText.time(context.now.addingTimeInterval(interval.earliest), format: context.timeFormat, calendar: context.calendar)
            let to = ResetText.time(context.now.addingTimeInterval(interval.latest), format: context.timeFormat, calendar: context.calendar)
            let day = ResetText.dayPhrase(context.now.addingTimeInterval(interval.earliest), now: context.now, calendar: context.calendar)
            return L("At this rate you hit the %1$@ %2$@ cap %3$@ between %4$@ and %5$@.%6$@", tool.displayName, name(window, of: tool), day, from, to, suffix)
        }
        let when = L("%1$@ at %2$@", ResetText.dayPhrase(runsOutAt, now: context.now, calendar: context.calendar),
                     ResetText.time(runsOutAt, format: context.timeFormat, calendar: context.calendar))
        let margin = ResetText.duration(resetsAt.timeIntervalSince(runsOutAt))
        return L("At this rate you hit the %1$@ %2$@ cap %3$@, %4$@ before reset.%5$@",
                 tool.displayName, name(window, of: tool), when, margin, suffix)
    }

    /// The window a routing decision spends: the longest tool-wide window with a limit (weekly for Claude and
    /// Codex, the billing cycle for Cursor).
    static func mainWindow(of reading: UsageReading) -> LimitWindow? {
        reading.windows
            .filter { $0.usedFraction != nil && $0.model == nil && $0.periodDuration != nil && !$0.id.hasPrefix("budget_") }
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
        return L(" %1$@ %2$@ is at %3$ld%%.", other.tool.displayName, name(other.window, of: other.tool), percent(used))
    }

    /// "weekly", "session", "included usage"; a per-model window carries its cadence: "Fable weekly", "Gemini Pro
    /// daily", or "Gemini Pro quota" while the tool declares no window length.
    static func name(_ window: LimitWindow) -> String {
        guard let model = window.model else { return window.name.inSentence }
        return "\(model) \(cadence(window.periodDuration))"
    }

    /// The window's name for a sentence that already names the tool. A per-model window is named after the label
    /// the vendor gave the model, and some vendors put their own name inside it — Cursor splits its plan into
    /// "Cursor models" and "Other models" — so the sentence would say it twice: "the Cursor Cursor models 31-day
    /// window cap". The tool's name is dropped from the front of the window's when it is already there.
    static func name(_ window: LimitWindow, of tool: ToolID) -> String {
        let full = name(window)
        let prefix = tool.displayName + " "
        guard full.hasPrefix(prefix), full.count > prefix.count else { return full }
        return String(full.dropFirst(prefix.count))
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

    /// The pessimistic edge of the run-out interval when the log has one, else the measured drain, else the even-burn projection.
    private static func secondsToRunOut(_ window: LimitWindow, tool: ToolID, context: Context) -> TimeInterval? {
        guard let used = window.usedFraction, let resetsAt = window.resetsAt, let period = window.periodDuration else { return nil }
        guard Pace.status(for: window, now: context.now) == .behind else { return nil }
        if let interval = context.runOuts["\(tool.rawValue)/\(window.id)"], context.now.addingTimeInterval(interval.earliest) < resetsAt {
            return interval.earliest
        }
        if let measured = Pace.secondsToRunOut(usedFraction: used, rate: context.drainRates["\(tool.rawValue)/\(window.id)"], resetsAt: resetsAt, now: context.now) {
            return measured
        }
        return Pace.secondsToRunOut(usedFraction: used, resetsAt: resetsAt, period: period, now: context.now)
    }
}

/// The calendar month as a budget period: where it stands between its first and last moment.
struct BudgetPeriod: Equatable, Sendable {
    let start: Date
    let end: Date

    static func month(now: Date, calendar: Calendar = .current) -> BudgetPeriod {
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? now.addingTimeInterval(Period.month)
        return BudgetPeriod(start: start, end: end)
    }

    var duration: TimeInterval { end.timeIntervalSince(start) }

    func elapsedFraction(now: Date) -> Double {
        guard duration > 0 else { return 1 }
        return min(1, max(0, now.timeIntervalSince(start) / duration))
    }
}

/// The 1-hour share of cache writes, today against the 30-day norm.
enum CacheTTL {
    static func oneHourShare(_ tokens: TokenBreakdown) -> Double? {
        let writes = tokens.cacheWrite5m + tokens.cacheWrite1h
        guard writes > 0 else { return nil }
        return Double(tokens.cacheWrite1h) / Double(writes)
    }

    /// Today's share and the norm when today sits more than the margin under it and has enough writes to mean it.
    static func shift(today: TokenBreakdown, norm: TokenBreakdown) -> (today: Double, norm: Double)? {
        guard today.cacheWrite5m + today.cacheWrite1h >= Advisor.cacheShiftMinimumWrites,
              let todayShare = oneHourShare(today), let normShare = oneHourShare(norm), normShare - todayShare > Advisor.cacheShiftMargin
        else { return nil }
        return (todayShare, normShare)
    }
}
