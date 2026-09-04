import Foundation

/// What `--render-assets` shows: one afternoon on a Mac with Claude Code, Codex and Cursor signed in and the
/// Claude Code hook installed, fixed so the README's pictures come out the same on every render. Nothing here
/// reaches a provider, the Keychain or the network: the store is seeded and its loops never start.
enum DemoFixtures {
    static let suiteName = "com.amirhackett.notchmeter.render-assets"

    /// What the hook is reporting while a picture is drawn. A tool has one ring and `ToolSignal.resolve` gives a
    /// wait the better claim on it, so the two states cannot both be true of Claude Code at one instant and no
    /// single frame can honestly show both. They are two moments of the same afternoon instead, and the renderer
    /// draws the pair side by side (`AssetRenderer.signalRings`).
    ///
    /// Both states are Claude Code's, and that is not an oversight. Claude Code's hook is the only one that
    /// reports these events today (`ToolSignal`), so a fixture that lit Codex's or Cursor's ring would be a
    /// picture of something no user can currently see — which is the exact failure the stale `edge-left.png`
    /// already cost this repository once.
    enum Moment {
        /// A permission prompt is open: the ring takes the colour and the white dot.
        case waiting
        /// A turn has just ended inside the ninety-second hold: the ring takes the colour and the tick.
        case justFinished
    }

    @MainActor
    static func store(now: Date = Date(), moment: Moment = .waiting) -> (store: UsageStore, prefs: Preferences) {
        // A suite nothing writes to. The registration domain lives in memory only, so the countdown style the
        // pictures rely on is neither read from nor written to the user's own preferences.
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.register(defaults: ["resetDisplay": ResetDisplay.countdown.rawValue])
        let prefs = Preferences(defaults: defaults)
        let readings = readings(now: now)
        let store = UsageStore(prefs: prefs, providers: readings.map { FixtureProvider(reading: $0) },
                               cache: ReadingCache(defaults: defaults), defaults: defaults, drainLog: nil)
        store.seed(readings: readings, cost: cost(now: now), nextUpdate: now.addingTimeInterval(2 * 60 + 40),
                   sessions: sessions(now: now, moment: moment), now: now)
        return (store, prefs)
    }

    /// Two Claude Code sessions the hook has reported, built by feeding `SessionTracker.apply` the events a real
    /// hook sends rather than by setting the fields — so a change to the state machine changes the pictures, and a
    /// state the machine cannot reach cannot be drawn.
    ///
    /// Every timestamp is an offset from the render's own `now`, because both signal states are read against the
    /// clock: a wait times out at ten minutes and a finish is held for ninety seconds, so absolute dates would
    /// give a blank strip on every render but the first. The offsets are deliberately well inside those windows —
    /// the wait is thirty-five seconds old and the finish twelve — since a render lays out every view and writes
    /// every file between seeding the store and drawing the last of them.
    ///
    /// The second session is idle and stays idle. It is there so the card's session line reads "2 sessions ·
    /// waiting in notchmeter" rather than "1 session", which is the count the README claims the hook keeps; its
    /// own turn ended six minutes ago, far outside the hold, so it adds nothing to the ring in either moment.
    static func sessions(now: Date, moment: Moment) -> SessionTracker {
        var tracker = SessionTracker()
        func send(_ event: String, _ ago: TimeInterval, session: String, project: String, branch: String, type: String? = nil) {
            tracker.apply(Hook.Message(event: event, needsInput: Hook.needsInput(event: event, notificationType: type),
                                       sessionID: session, project: project, notificationType: type, branch: branch),
                          now: now.addingTimeInterval(-ago))
        }
        // Ascending in time: `apply` expires against the clock it is handed, so an event out of order would age
        // the state the one before it had just set. That is why scout's turn ends inside each branch below rather
        // than above them: it stopped six minutes ago, which in either moment falls after the notchmeter session
        // opened and took its prompt and before the event that moment turns on.
        send("SessionStart", 22 * 60, session: "scout", project: "scout", branch: "main")
        send("UserPromptSubmit", 19 * 60, session: "scout", project: "scout", branch: "main")
        send("SessionStart", 14 * 60, session: "notchmeter", project: "notchmeter", branch: "feat/side-notch")
        switch moment {
        case .waiting:
            send("UserPromptSubmit", 9 * 60, session: "notchmeter", project: "notchmeter", branch: "feat/side-notch")
            send("Stop", 6 * 60, session: "scout", project: "scout", branch: "main")
            send("Notification", 35, session: "notchmeter", project: "notchmeter", branch: "feat/side-notch", type: "permission_prompt")
        case .justFinished:
            // Eight minutes and forty seconds, twenty-six times `ToolSignal.finishedAfter` and so a turn the ring
            // is meant to report rather than one the user watched end.
            send("UserPromptSubmit", 8 * 60 + 52, session: "notchmeter", project: "notchmeter", branch: "feat/side-notch")
            send("Stop", 6 * 60, session: "scout", project: "scout", branch: "main")
            send("Stop", 12, session: "notchmeter", project: "notchmeter", branch: "feat/side-notch")
        }
        return tracker
    }

    /// Claude on Max 5x a third of the way into a quiet session, Codex on a free plan with an untouched monthly
    /// window, Cursor on a free plan with nothing to meter: every ring under 40 % and on pace.
    ///
    /// Every reset is placed in the middle of the unit its countdown prints rather than on the boundary of it,
    /// which is what the odd half-minute and half-hour below are. `ResetText.duration` rounds the remaining
    /// seconds and then divides, so a reset laid exactly 3h 19m out prints "3h 19m" only while the draw happens
    /// inside the first half-second of the render and "3h 18m" after that. That is how `expanded.png` and
    /// `expanded-contrast.png` came to disagree with one another inside a single run — the two captures are
    /// seconds apart, and the pair is offered in docs/testing.md as evidence about contrast, which it cannot be
    /// while the two frames read different clocks. Half a unit is the furthest a printed value can be from
    /// changing: thirty seconds for a countdown printed in minutes, thirty minutes for one printed in hours,
    /// against a render that takes about two seconds end to end.
    static func readings(now: Date) -> [UsageReading] {
        let sessionSeconds: Int = 3 * 3600 + 19 * 60 + 30
        let weekSeconds: Int = 4 * 86_400 + 17 * 3600 + 30 * 60
        let monthSeconds: Int = 18 * 86_400 + 6 * 3600 + 30 * 60
        let cycleSeconds: Int = 12 * 86_400 + 12 * 3600 + 30 * 60
        let sessionReset = now.addingTimeInterval(TimeInterval(sessionSeconds))
        let weekReset = now.addingTimeInterval(TimeInterval(weekSeconds))
        return [
            UsageReading(tool: .claude, windows: [
                LimitWindow(id: "five_hour", label: .key("Session"), usedFraction: 0.14, resetsAt: sessionReset, periodDuration: Period.fiveHours),
                LimitWindow(id: "seven_day", label: .key("Weekly"), usedFraction: 0.04, resetsAt: weekReset, periodDuration: Period.week),
                LimitWindow(id: "scoped_fable", label: "Fable", usedFraction: 0.06, resetsAt: weekReset, periodDuration: Period.week, model: "Fable"),
            ], plan: "Max 5x", fetchedAt: now, observedAt: nil),
            UsageReading(tool: .codex, windows: [
                LimitWindow(id: "session", label: .key("Session"), usedFraction: nil, resetsAt: nil, note: L("No data")),
                LimitWindow(id: "monthly", label: .key("Monthly"), usedFraction: 0, resetsAt: now.addingTimeInterval(TimeInterval(monthSeconds)), periodDuration: 30 * Period.day),
            ], plan: "Free", fetchedAt: now, observedAt: nil),
            UsageReading(tool: .cursor, windows: [
                LimitWindow(id: "included", label: .key("Included usage"), usedFraction: nil, resetsAt: now.addingTimeInterval(TimeInterval(cycleSeconds)),
                            note: L("%@ plan has nothing for Cursor to meter yet", "Free")),
            ], plan: "Free", fetchedAt: now, observedAt: nil),
        ]
    }

    /// $6,600 over 30 days of Claude Code with quiet weekends, a heavy $548.76 yesterday and $118.31 so far
    /// today, beside a Cursor export at a ninth of it. The last hour ran at 3.2x the 30-day average active hour,
    /// which is what puts a line in the Advice strip.
    static func cost(now: Date) -> CostSummary {
        let today = 118.31
        let yesterday = 548.76
        let last30Days = 6600.0
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let weights: [Double] = [
            210, 265, 190, 305, 240, 35, 12,
            280, 330, 255, 410, 295, 48, 20,
            225, 360, 300, 445, 250, 60, 15,
            310, 380, 290, 520, 315, 70, 25,
        ]
        let perWeight = (last30Days - yesterday - today) / weights.reduce(0, +)
        let models = ["claude-opus-5": 0.6, "claude-sonnet-5": 0.33, "claude-haiku-4-5": 0.07]
        let projects = ["notchmeter": 0.63, "scout": 0.27, "Other": 0.1]
        var days: [Date: CostHistory.Record] = [:]
        for offset in 0..<30 {
            guard let day = calendar.date(byAdding: .day, value: offset - 29, to: start) else { continue }
            let cost = offset == 29 ? today : offset == 28 ? yesterday : weights[offset] * perWeight
            let tokens = Int(cost * 62_000)
            days[day] = CostHistory.Record(
                cost: cost,
                tokens: TokenBreakdown(input: tokens / 60, cacheWrite5m: tokens / 40, cacheWrite1h: tokens / 20,
                                       cacheRead: tokens - tokens / 60 - tokens / 40 - tokens / 20 - tokens / 100, output: tokens / 100),
                byModel: models.mapValues { $0 * cost }, byProject: projects.mapValues { $0 * cost },
                byModelTokens: models.mapValues { Int($0 * Double(tokens)) }, byProjectTokens: projects.mapValues { Int($0 * Double(tokens)) })
        }
        // Cursor's own export, day-resolution, so it reports no hour of its own.
        let cursorDays = days.mapValues { record in
            CostHistory.Record(cost: record.cost * 0.11, tokens: TokenBreakdown(input: record.tokens.total / 6, output: record.tokens.total / 60),
                               byModel: ["claude-4.5-sonnet": record.cost * 0.08, "gpt-5.3-codex": record.cost * 0.03], byProject: [:])
        }
        let weekStart = CostEngine.weekStart(weeklyResetsAt: nil, now: now, calendar: calendar)
        let claude = ProviderCost.build(tool: .claude, source: .localTranscripts, days: days, now: now, weekStart: weekStart,
                                        calendar: calendar, hourly: HourlyBurn(lastHour: 31.20, typicalHourly: 9.75, activeHours: 380),
                                        scannedAt: now)
        let cursor = ProviderCost.build(tool: .cursor, source: .billingExport, days: cursorDays, now: now, weekStart: weekStart,
                                        calendar: calendar, scannedAt: now.addingTimeInterval(-240))
        let base = CostSummary(today: 0, yesterday: 0, last30Days: 0, daily: [], lastHour: 0, typicalHourly: 0, burnMultiple: nil,
                               unpricedModels: [], scannedAt: now,
                               week: WeekCost(start: weekStart, cost: 903, perPercent: 12.4),
                               firstUse: calendar.date(byAdding: .day, value: -212, to: start), sinceFirstUse: 41_300)
        return base.adding([claude, cursor].compactMap { $0 })
    }
}

/// Installed, and never read: the demo store is seeded with the reading instead.
struct FixtureProvider: UsageProvider {
    let reading: UsageReading

    var tool: ToolID { reading.tool }
    var refreshInterval: TimeInterval { 300 }
    func isInstalled() -> Bool { true }
    func fetch() async throws -> UsageReading { reading }
}
