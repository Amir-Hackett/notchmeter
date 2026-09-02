import Foundation

/// What `--render-assets` shows: one afternoon on a Mac with Claude Code, Codex and Cursor signed in, fixed so
/// the README's pictures come out the same on every render. Nothing here reaches a provider, the Keychain or the
/// network: the store is seeded and its loops never start.
enum DemoFixtures {
    static let suiteName = "com.amirhackett.notchmeter.render-assets"

    @MainActor
    static func store(now: Date = Date()) -> (store: UsageStore, prefs: Preferences) {
        // A suite nothing writes to. The registration domain lives in memory only, so the countdown style the
        // pictures rely on is neither read from nor written to the user's own preferences.
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.register(defaults: ["resetDisplay": ResetDisplay.countdown.rawValue])
        let prefs = Preferences(defaults: defaults)
        let readings = readings(now: now)
        let store = UsageStore(prefs: prefs, providers: readings.map { FixtureProvider(reading: $0) },
                               cache: ReadingCache(defaults: defaults), defaults: defaults)
        store.seed(readings: readings, cost: cost(now: now), nextUpdate: now.addingTimeInterval(2 * 60 + 40), now: now)
        return (store, prefs)
    }

    /// Claude on Max 5x a third of the way into a quiet session, Codex on a free plan with an untouched monthly
    /// window, Cursor on a free plan with nothing to meter: every ring under 40 % and on pace.
    static func readings(now: Date) -> [UsageReading] {
        let sessionReset = now.addingTimeInterval(3 * 3600 + 19 * 60)
        let weekReset = now.addingTimeInterval(4 * 86400 + 17 * 3600)
        return [
            UsageReading(tool: .claude, windows: [
                LimitWindow(id: "five_hour", label: L("Session"), usedFraction: 0.14, resetsAt: sessionReset, periodDuration: Period.fiveHours),
                LimitWindow(id: "seven_day", label: L("Weekly"), usedFraction: 0.04, resetsAt: weekReset, periodDuration: Period.week),
                LimitWindow(id: "scoped_fable", label: "Fable", usedFraction: 0.06, resetsAt: weekReset, periodDuration: Period.week, model: "Fable"),
            ], plan: "Max 5x", fetchedAt: now, observedAt: nil),
            UsageReading(tool: .codex, windows: [
                LimitWindow(id: "session", label: L("Session"), usedFraction: nil, resetsAt: nil, note: L("No data")),
                LimitWindow(id: "monthly", label: L("Monthly"), usedFraction: 0, resetsAt: now.addingTimeInterval(18 * 86400 + 6 * 3600), periodDuration: 30 * Period.day),
            ], plan: "Free", fetchedAt: now, observedAt: nil),
            UsageReading(tool: .cursor, windows: [
                LimitWindow(id: "included", label: L("Included usage"), usedFraction: nil, resetsAt: now.addingTimeInterval(12 * 86400),
                            note: L("%@ plan has nothing for Cursor to meter yet", "Free")),
            ], plan: "Free", fetchedAt: now, observedAt: nil),
        ]
    }

    /// $6,600 over 30 days with quiet weekends, a heavy $548.76 yesterday and $118.31 so far today. The last hour
    /// ran at 3.2x the 30-day average active hour, which is what puts a line in the Advice strip.
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
        var daily: [DailySpend] = []
        for offset in 0..<30 {
            let day = calendar.date(byAdding: .day, value: offset - 29, to: start) ?? start
            let cost = offset == 29 ? today : offset == 28 ? yesterday : weights[offset] * perWeight
            daily.append(DailySpend(day: day, cost: cost, tokens: Int(cost * 62_000)))
        }
        return CostSummary(today: today, yesterday: yesterday, last30Days: last30Days, daily: daily, lastHour: 31.20,
                           typicalHourly: 9.75, burnMultiple: 3.2, unpricedModels: [], scannedAt: now)
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
