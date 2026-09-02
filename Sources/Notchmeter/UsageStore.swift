import AppKit
import Foundation
import Observation
import os

private let log = Logger(subsystem: "com.amirhackett.notchmeter", category: "usage")

/// Last good reading per tool, so rings are populated the moment the app launches.
struct ReadingCache {
    private let defaults: UserDefaults
    private let key = "lastGoodReadings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [ToolID: UsageReading] {
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([UsageReading].self, from: data)
        else { return [:] }
        return list.reduce(into: [:]) { $0[$1.tool] = $1 }
    }

    func store(_ reading: UsageReading) {
        var all = load()
        all[reading.tool] = reading
        save(all)
    }

    func remove(_ tool: ToolID) {
        var all = load()
        all[tool] = nil
        save(all)
    }

    private func save(_ all: [ToolID: UsageReading]) {
        if let data = try? JSONEncoder().encode(Array(all.values)) {
            defaults.set(data, forKey: key)
        }
    }
}

@MainActor
@Observable
final class UsageStore {
    /// Every change is reported to the oracle once the store has started; start() reports the launch state itself.
    private(set) var statuses: [ToolID: ToolStatus] = [:] {
        didSet {
            guard started else { return }
            for tool in ToolID.allCases where statuses[tool] != oldValue[tool] {
                Oracle.shared.emit("reading", Oracle.fields(tool, status(tool)))
            }
        }
    }
    private(set) var lastUpdated: Date?
    private(set) var nextRefresh: [ToolID: Date] = [:]
    private(set) var cost: CostSummary?
    private(set) var costScanning = false
    /// Why every read is on hold, for the footer; nil while polling.
    private(set) var pauseReason: PauseReason?
    private(set) var onBattery = false
    private(set) var lowPowerMode = false
    /// When each tool's files last changed, or a Claude Code hook last fired.
    private(set) var lastActivity: [ToolID: Date] = [:]
    /// The Claude Code sessions the hook reports, and which are waiting on the user.
    private(set) var sessions = SessionTracker()
    /// The newest status-line payload from Claude Code, while a session runs.
    private(set) var statusline: Statusline.Message?
    /// The last hour's move per window, and 24 hourly points per window, from the drain log.
    private(set) var drains: [DrainLog.Key: Drain] = [:]
    private(set) var drainSeries: [DrainLog.Key: [Double?]] = [:]
    /// Set by `--smoke --idle-sim`: the idle clock pretends this much time has passed since any activity.
    private(set) var simulatedIdle: TimeInterval?
    /// Something is capturing the screen (ScreenCaptureMonitor); with the privacy setting on, figures are hidden.
    private(set) var screenCaptured = false
    let prefs: Preferences

    @ObservationIgnored private let providers: [ToolID: any UsageProvider]
    @ObservationIgnored private var loops: [ToolID: Task<Void, Never>] = [:]
    @ObservationIgnored private var sleepers: [ToolID: Task<Void, Error>] = [:]
    @ObservationIgnored private var inflight: Set<ToolID> = []
    @ObservationIgnored private var backoff: [ToolID: TimeInterval] = [:]
    @ObservationIgnored private var lastFetch: [ToolID: Date] = [:]
    @ObservationIgnored private let cache: ReadingCache
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var costScanner: ClaudeCostScanner
    @ObservationIgnored private var activity: AgentActivity
    @ObservationIgnored private let drainLog: DrainLog?
    @ObservationIgnored private var drainSamples: [DrainLog.Key: [DrainSample]] = [:]
    @ObservationIgnored private var tick: Task<Void, Never>?
    @ObservationIgnored private var resetTimer: Task<Void, Never>?
    @ObservationIgnored private var lastCostScan: Date?
    @ObservationIgnored private var screenLocked = false
    @ObservationIgnored private var asleep = false
    @ObservationIgnored private var screensAsleep = false
    @ObservationIgnored private var lastHook: Date?
    @ObservationIgnored private var lastHookRefresh: Date?
    @ObservationIgnored private var wokeAt: Date?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var alertMemory: AlertMemory
    @ObservationIgnored private var watchedResets: [String: WatchedReset] = [:]
    @ObservationIgnored private var reportedAdvice: [String]?
    @ObservationIgnored private var started = false
    /// Receives each batch of pace alerts the scheduler decides on; wired to the Notifier by the app delegate.
    @ObservationIgnored var deliverAlerts: ([PaceAlert]) -> Void = { _ in }
    /// A Claude Code session began waiting, or finished a turn; wired to the Notifier by the app delegate.
    @ObservationIgnored var deliverSessionEvent: (Notifier.SessionEvent, AgentSession) -> Void = { _, _ in }

    static let costInterval: TimeInterval = 60
    static let hookRefreshSpacing: TimeInterval = 30
    static let awaitingInputTimeout: TimeInterval = SessionTracker.waitingTimeout
    static let resetCheckInterval: TimeInterval = 30

    init(prefs: Preferences, providers: [any UsageProvider] = ProviderRegistry.all(), cache: ReadingCache = ReadingCache(),
         defaults: UserDefaults = .standard, drainLog: DrainLog? = DrainLog()) {
        self.prefs = prefs
        self.cache = cache
        self.defaults = defaults
        self.drainLog = drainLog
        self.alertMemory = AlertMemory.load(from: defaults)
        self.providers = providers.reduce(into: [:]) { $0[$1.tool] = $1 }
        let roots = ClaudeCostScanner.defaultRoots(extra: prefs.extraTranscriptRoots)
        self.costScanner = ClaudeCostScanner(roots: roots)
        self.activity = AgentActivity(claudeRoots: roots)
        let cached = cache.load()
        for tool in ToolID.allCases {
            statuses[tool] = initialStatus(for: tool, cached: cached[tool])
        }
    }

    /// The tools on screen, in the user's order (Preferences.toolOrder).
    var visibleTools: [ToolID] { prefs.toolOrder.filter(isShown) }

    func isInstalled(_ tool: ToolID) -> Bool {
        providers[tool]?.isInstalled() ?? false
    }

    func isShown(_ tool: ToolID) -> Bool {
        prefs.enabledTools.contains(tool) && isInstalled(tool)
    }

    func status(_ tool: ToolID) -> ToolStatus {
        statuses[tool] ?? .waiting
    }

    /// Tools waiting on the user: a permission prompt or a question in Claude Code, reported by its hook.
    var awaitingInput: Set<ToolID> {
        sessions.waiting.isEmpty ? [] : [.claude]
    }

    func isAwaitingInput(_ tool: ToolID) -> Bool {
        awaitingInput.contains(tool)
    }

    /// How many Claude Code sessions are waiting, for the dot beside the ring.
    var waitingCount: Int { sessions.waiting.count }

    /// The context window's fill from the status line, while its report is fresh.
    var contextUsed: Double? {
        guard let statusline, Date().timeIntervalSince(statusline.receivedAt) < PollingPolicy.statuslineFreshFor * 4 else { return nil }
        return statusline.contextUsed
    }

    /// How loud the compact rings are, from every visible reading; the rule is in Presence.swift. Hide when idle
    /// turns quiet into hidden once no agent has been active for half an hour.
    var presence: PresenceLevel {
        let level = Presence.level(windows: visibleTools.flatMap { status($0).reading.map(prefs.shownWindows) ?? [] },
                                   awaitingInput: visibleTools.contains(where: isAwaitingInput), sessions: sessions.knownCount)
        guard prefs.visibility == .hideWhenIdle else { return level }
        let now = Date()
        let idleFor = simulatedIdle ?? visibleTools.compactMap { lastActivity[$0] }.max().map { now.timeIntervalSince($0) }
        let nudge = lastHook.map { now.timeIntervalSince($0) < PollingPolicy.idleAfter } ?? false
        return Presence.hides(level: level, idleFor: nudge ? 0 : idleFor, wokeAgo: wokeAt.map { now.timeIntervalSince($0) }) ? .hidden : level
    }

    /// The pointer rested on the rings, or something else that should bring hidden rings back at once.
    func wakeFromIdle() {
        guard prefs.visibility == .hideWhenIdle else { return }
        wokeAt = Date()
    }

    /// `--smoke --idle-sim`: every tool has been idle this long.
    func simulateIdle(minutes: Double?) {
        simulatedIdle = minutes.map { $0 * 60 }
        wokeAt = nil
    }

    func setScreenCaptured(_ captured: Bool) {
        if screenCaptured != captured { screenCaptured = captured }
    }

    /// Digits and dollar figures are withheld while the screen is shared and the privacy setting is on.
    var hidesFigures: Bool {
        prefs.hideFromScreenShare && screenCaptured
    }

    /// Live readings of the visible tools; a cached reading shown beside an error is left out.
    var readyReadings: [UsageReading] {
        visibleTools.compactMap {
            if case .ready(let reading) = status($0) { return reading }
            return nil
        }
    }

    var drainRates: [String: Double] {
        drains.reduce(into: [:]) { if let rate = $1.value.perHour { $0["\($1.key.tool.rawValue)/\($1.key.window)"] = rate } }
    }

    func adviceContext(now: Date = Date()) -> Advisor.Context {
        Advisor.Context(readings: readyReadings, awaitingInput: awaitingInput.filter(isShown), waitingSessions: sessions.waiting,
                        cost: prefs.showSpend ? cost : nil, timeFormat: prefs.timeFormat, toolOrder: prefs.toolOrder, drainRates: drainRates, now: now)
    }

    /// What to do next, from Advisor.swift; empty when there is nothing to say.
    var advice: [Advice] {
        Advisor.advise(adviceContext())
    }

    /// When the next scheduled provider read happens, for the footer.
    var nextUpdate: Date? {
        visibleTools.compactMap { nextRefresh[$0] }.min()
    }

    /// Why the next read is later than the provider's own cadence, for the footer.
    var scheduleNote: String? {
        guard let tool = visibleTools.min(by: { (nextRefresh[$0] ?? .distantFuture) < (nextRefresh[$1] ?? .distantFuture) }) else { return nil }
        var notes: [String] = []
        if PollingPolicy.isIdle(pollingInputs(for: tool)) { notes.append(L("no agent activity")) }
        if onBattery { notes.append(L("on battery")) }
        if lowPowerMode { notes.append(L("low power mode")) }
        if visibleTools.contains(where: { status($0).isOffline }) { notes.append(L("Offline, retrying")) }
        return notes.isEmpty ? nil : notes.joined(separator: ", ")
    }

    /// Everything the app knows, for `--probe --json`, the local API and the oracle.
    func report(now: Date = Date()) -> UsageReport {
        UsageReport(tools: statuses, order: prefs.toolOrder, cost: prefs.showSpend ? cost : nil, advice: advice, drains: drains, sessions: sessions.all, now: now)
    }

    func start() {
        onBattery = PowerSource.onBattery()
        lowPowerMode = PowerSource.lowPowerMode()
        for tool in ToolID.allCases {
            Oracle.shared.emit("reading", Oracle.fields(tool, status(tool)))
        }
        started = true
        loadDrains()
        observeAdvice()
        for tool in ToolID.allCases where isShown(tool) {
            startLoop(tool)
        }
        startTick()
        startResetTimer()
        observeEnvironment()
    }

    /// Reports the advice strip to the oracle whenever its lines change; the tracking is one-shot, so it re-arms.
    private func observeAdvice() {
        guard Oracle.shared.isActive else { return }
        withObservationTracking {
            let lines = advice.map(\.text)
            if lines != reportedAdvice {
                reportedAdvice = lines
                Oracle.shared.emit("advice", ["titles": lines])
            }
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeAdvice() }
        }
    }

    func setEnabled(_ tool: ToolID, _ enabled: Bool) {
        if enabled {
            prefs.enabledTools.insert(tool)
            statuses[tool] = initialStatus(for: tool, cached: nil)
            startLoop(tool)
        } else {
            prefs.enabledTools.remove(tool)
            stopLoop(tool)
            statuses[tool] = .off
            cache.remove(tool)
        }
    }

    /// The transcript roots changed in Settings: the scanner and the activity check follow, and the cost is rescanned.
    func reloadRoots() {
        let roots = ClaudeCostScanner.defaultRoots(extra: prefs.extraTranscriptRoots)
        costScanner = ClaudeCostScanner(roots: roots)
        activity = AgentActivity(claudeRoots: roots)
        lastCostScan = nil
        Task { await refreshCost() }
    }

    func refreshAll(force: Bool = true) {
        for tool in visibleTools {
            Task { await refresh(tool, force: force) }
        }
        Task { await refreshCost() }
    }

    /// Prices Claude Code's local transcripts. Incremental after the first pass, so it is cheap to call often. The
    /// live Claude reading's resets align the "this week" range and the current 5-hour block.
    func refreshCost() async {
        guard prefs.showSpend, isShown(.claude) else { return }
        if cost == nil { costScanning = true }
        lastCostScan = Date()
        let claude = status(.claude).reading
        let weekly = claude?.windows.first { $0.id == "seven_day" }
        let session = claude?.windows.first { $0.id == "five_hour" }
        let scanner = costScanner
        let summary = await scanner.scan(weeklyResetsAt: weekly?.resetsAt, weeklyUsed: weekly?.usedFraction, sessionResetsAt: session?.resetsAt)
        cost = summary
        costScanning = false
    }

    /// Unforced refreshes are throttled so hovering the notch cannot hammer the APIs. While the Claude Code status
    /// line is reporting the same windows, the Claude read takes them from it and the endpoint is left alone.
    func refresh(_ tool: ToolID, force: Bool = false) async {
        guard let provider = providers[tool], prefs.enabledTools.contains(tool) else { return }
        guard provider.isInstalled() else {
            statuses[tool] = .notInstalled
            return
        }
        if !force, let last = lastFetch[tool], Date().timeIntervalSince(last) < 60 { return }
        guard !inflight.contains(tool) else { return }
        inflight.insert(tool)
        defer { inflight.remove(tool) }
        if tool == .claude, let reading = statuslineReading() {
            adopt(reading)
            return
        }
        lastFetch[tool] = Date()

        let cached = statuses[tool]?.reading
        do {
            let reading = try await provider.fetch()
            log.info("\(tool.displayName, privacy: .public) usage -> \(Probe.describe(reading), privacy: .public)")
            adopt(reading)
        } catch let error as ProviderError {
            log.error("\(tool.displayName, privacy: .public) failed: \(error.message, privacy: .public)")
            if case .nothingYet(let message) = error {
                statuses[tool] = .idle(message)
                backoff[tool] = 0
            } else if case .offline = error {
                statuses[tool] = .offline(cached: cached)
                backoff[tool] = min(300, max(30, (backoff[tool] ?? 15) * 2))
            } else if case .rateLimited(let retry) = error {
                // Transient: keep the last good numbers on screen and try again later.
                let wait = max(60, retry ?? 0)
                backoff[tool] = wait
                if let cached {
                    statuses[tool] = .ready(cached)
                } else {
                    statuses[tool] = .failed(L("Rate limited, retrying in %lds", Int(wait)), cached: nil)
                }
            } else if error.needsAttention {
                statuses[tool] = .needsAttention(error.message, cached: cached)
                backoff[tool] = 60
            } else {
                backoff[tool] = min(600, max(30, (backoff[tool] ?? 15) * 2))
                statuses[tool] = .failed(error.message, cached: cached)
            }
        } catch {
            log.error("\(tool.displayName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            if let offline = ProviderError.offline(from: error), case .offline = offline {
                statuses[tool] = .offline(cached: cached)
                backoff[tool] = min(300, max(30, (backoff[tool] ?? 15) * 2))
            } else {
                backoff[tool] = min(600, max(30, (backoff[tool] ?? 15) * 2))
                statuses[tool] = .failed(error.localizedDescription, cached: cached)
            }
        }
    }

    /// A good reading: on screen, cached, logged for the drain, and checked for alerts.
    private func adopt(_ reading: UsageReading, now: Date = Date()) {
        statuses[reading.tool] = .ready(reading)
        backoff[reading.tool] = 0
        cache.store(reading)
        lastUpdated = now
        recordDrain(reading, now: now)
        for window in reading.windows {
            let key = AlertMemory.key(reading.tool, window)
            if let watch = WatchedReset.watch(reading.tool, window, now: now) {
                watchedResets[key] = watch
            } else if let existing = watchedResets[key], existing.window.resetsAt != window.resetsAt {
                watchedResets[key] = nil
            }
        }
        evaluateAlerts(now: now)
    }

    /// The session and weekly windows from a status line under three minutes old, laid over the cached reading.
    private func statuslineReading(now: Date = Date()) -> UsageReading? {
        guard let statusline, !statusline.windows.isEmpty, now.timeIntervalSince(statusline.receivedAt) < PollingPolicy.statuslineFreshFor else { return nil }
        let base = statuses[.claude]?.reading ?? UsageReading(tool: .claude, windows: [], plan: nil, fetchedAt: now, observedAt: nil)
        return base.replacing(windows: statusline.windows, fetchedAt: statusline.receivedAt)
    }

    /// `--render-assets` (DemoFixtures): readings and a cost summary in place of provider reads. The loops never
    /// start, so nothing is fetched, cached or written.
    func seed(readings: [UsageReading], cost: CostSummary, nextUpdate: Date, now: Date = Date()) {
        for reading in readings {
            statuses[reading.tool] = .ready(reading)
            nextRefresh[reading.tool] = nextUpdate
            lastActivity[reading.tool] = now
        }
        self.cost = cost
        lastUpdated = now
    }

    // MARK: - Drain log

    private func loadDrains(now: Date = Date()) {
        guard let drainLog else { return }
        let log = drainLog
        Task.detached(priority: .utility) {
            let samples = log.load(now: now)
            await MainActor.run { [weak self] in
                self?.drainSamples = samples
                self?.recomputeDrains(now: now)
            }
        }
    }

    private func recordDrain(_ reading: UsageReading, now: Date) {
        for window in reading.windows {
            guard let used = window.usedFraction else { continue }
            drainSamples[DrainLog.Key(tool: reading.tool, window: window.id), default: []].append(DrainSample(t: now, used: used, resetsAt: window.resetsAt))
        }
        drainLog?.append(reading, previous: drainSamples, now: now)
        recomputeDrains(now: now)
    }

    private func recomputeDrains(now: Date) {
        var drains: [DrainLog.Key: Drain] = [:]
        var series: [DrainLog.Key: [Double?]] = [:]
        for (key, samples) in drainSamples {
            if let drain = DrainLog.drain(samples, now: now) { drains[key] = drain }
            series[key] = DrainLog.hourly(samples, now: now)
        }
        self.drains = drains
        drainSeries = series
    }

    func drain(for tool: ToolID, window: LimitWindow) -> Drain? {
        drains[DrainLog.Key(tool: tool, window: window.id)]
    }

    func drainSeries(for tool: ToolID, window: LimitWindow) -> [Double?]? {
        drainSeries[DrainLog.Key(tool: tool, window: window.id)]
    }

    // MARK: - Pace alerts

    private var alertOptions: NotificationScheduler.Options {
        NotificationScheduler.Options(onTrack: prefs.notifyOnTrack, behind: prefs.notifyBehind, runningOut: prefs.notifyRunningOut,
                                      reset: prefs.notifyOnReset, reminderLead: prefs.resetReminder.lead)
    }

    /// Only new readings can make a pace worse, so this runs after each one; nothing is remembered while the
    /// setting is off, so switching it on reports whatever is behind at that moment.
    private func evaluateAlerts(now: Date = Date()) {
        guard prefs.notificationsEnabled else { return }
        let plan = NotificationScheduler.plan(memory: alertMemory, readings: readyReadings, now: now, options: alertOptions, rates: drainRates)
        remember(plan.memory)
        send(plan.alerts)
    }

    /// The timer's half: resets and reminders for windows that were nearly gone when last seen.
    private func checkResets(now: Date = Date()) {
        guard prefs.notificationsEnabled, !watchedResets.isEmpty else { return }
        let plan = NotificationScheduler.planResets(memory: alertMemory, watched: Array(watchedResets.values), now: now, options: alertOptions)
        watchedResets = plan.watched.reduce(into: [:]) { $0[AlertMemory.key($1.tool, $1.window)] = $1 }
        remember(plan.memory)
        send(plan.alerts)
        if plan.alerts.contains(where: { $0.stage == .reset }) {
            Task { await refresh(.claude, force: true) }
        }
    }

    private func remember(_ memory: AlertMemory) {
        if memory != alertMemory {
            alertMemory = memory
            alertMemory.save(to: defaults)
        }
    }

    private func send(_ alerts: [PaceAlert]) {
        guard !alerts.isEmpty else { return }
        for alert in alerts {
            log.info("pace alert \(alert.identifier, privacy: .public)")
            Oracle.shared.emit("notification", ["action": "scheduled", "title": Advisor.alertTitle(alert), "stage": alert.stage.rawValue])
        }
        deliverAlerts(alerts)
    }

    // MARK: - Scheduling

    func pollingInputs(for tool: ToolID, base: TimeInterval? = nil, now: Date = Date()) -> PollingInputs {
        PollingInputs(
            baseInterval: base ?? providers[tool]?.refreshInterval ?? 60,
            screenLocked: screenLocked,
            asleep: asleep,
            screensAsleep: screensAsleep,
            onBattery: onBattery,
            lowPowerMode: lowPowerMode,
            minutesSinceLastAgentActivity: simulatedIdle.map { $0 / 60 } ?? lastActivity[tool].map { now.timeIntervalSince($0) / 60 },
            hookNudge: tool == .claude && simulatedIdle == nil && (lastHook.map { now.timeIntervalSince($0) < PollingPolicy.idleAfter } ?? false),
            secondsSinceStatusline: tool == .claude && base == nil ? statusline.flatMap { $0.windows.isEmpty ? nil : now.timeIntervalSince($0.receivedAt) } : nil
        )
    }

    /// One line for `--smoke`: the environment and each tool's cadence.
    func scheduleDescription() -> String {
        var parts = ["battery=\(onBattery)", "lowPower=\(lowPowerMode)", "locked=\(screenLocked)", "asleep=\(asleep)", "screensAsleep=\(screensAsleep)"]
        for tool in visibleTools {
            let seen = lastActivity[tool].map { RelativeTime.ago($0) } ?? "never"
            let cadence: String = switch PollingPolicy.decide(pollingInputs(for: tool)) {
            case .paused(let reason): reason.footerText.lowercased()
            case .after(let seconds): "every \(ResetText.duration(seconds))"
            }
            parts.append("\(tool.displayName.lowercased()) active \(seen) → \(cadence)")
        }
        return parts.joined(separator: "; ")
    }

    private func startLoop(_ tool: ToolID) {
        stopLoop(tool)
        loops[tool] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(tool, force: true)
                await self.waitUntilDue(tool)
            }
        }
    }

    private func stopLoop(_ tool: ToolID) {
        loops[tool]?.cancel()
        loops[tool] = nil
        sleepers[tool]?.cancel()
        nextRefresh[tool] = nil
    }

    /// Sleeps until the policy says the tool's next read is due, waking early whenever the inputs change.
    private func waitUntilDue(_ tool: ToolID) async {
        while !Task.isCancelled {
            switch PollingPolicy.decide(pollingInputs(for: tool)) {
            case .paused(.statusline):
                // The status line is feeding the windows; check again when its report would go stale.
                let stale = (statusline?.receivedAt ?? Date()).addingTimeInterval(PollingPolicy.statuslineFreshFor)
                nextRefresh[tool] = stale
                if await sleep(tool, for: max(1, stale.timeIntervalSinceNow)) { return }
            case .paused:
                nextRefresh[tool] = nil
                await sleep(tool, for: nil)
            case .after(let interval):
                let due = (lastFetch[tool] ?? Date()).addingTimeInterval(interval + (backoff[tool] ?? 0))
                nextRefresh[tool] = due
                let remaining = due.timeIntervalSinceNow
                if remaining <= 0 { return }
                if await sleep(tool, for: remaining) { return }
            }
        }
    }

    /// True when the whole interval passed, false when `reschedule` cut it short. nil sleeps until rescheduled.
    @discardableResult
    private func sleep(_ tool: ToolID, for seconds: TimeInterval?) async -> Bool {
        let sleeper = Task<Void, Error> {
            if let seconds {
                try await Task.sleep(for: .seconds(seconds))
            } else {
                while true { try await Task.sleep(for: .seconds(3600)) }
            }
        }
        sleepers[tool] = sleeper
        defer { if sleepers[tool] == sleeper { sleepers[tool] = nil } }
        do {
            try await sleeper.value
            return true
        } catch {
            return false
        }
    }

    private func reschedule() {
        for sleeper in sleepers.values { sleeper.cancel() }
    }

    private func restartLoops() {
        for tool in ToolID.allCases where isShown(tool) {
            startLoop(tool)
        }
    }

    // MARK: - Environment

    /// Once a minute: power source, each tool's newest file, and the cost scan when its own cadence says so.
    private func startTick() {
        tick?.cancel()
        tick = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sampleEnvironment()
                await self.refreshCostIfDue()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Every thirty seconds: resets and reminders, which depend on the clock rather than on a reading.
    private func startResetTimer() {
        resetTimer?.cancel()
        resetTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.resetCheckInterval))
                guard !Task.isCancelled, let self else { return }
                self.sessions.expire(now: Date())
                self.checkResets()
            }
        }
    }

    private func sampleEnvironment() async {
        let activity = self.activity
        var sampled = await Task.detached(priority: .utility) { activity.sample() }.value
        if let lastHook, sampled[.claude].map({ lastHook > $0 }) ?? true { sampled[.claude] = lastHook }
        let battery = PowerSource.onBattery()
        let lowPower = PowerSource.lowPowerMode()
        let before = visibleTools.map { PollingPolicy.decide(pollingInputs(for: $0)) }
        if sampled != lastActivity { lastActivity = sampled }
        if battery != onBattery { onBattery = battery }
        if lowPower != lowPowerMode { lowPowerMode = lowPower }
        let after = visibleTools.map { PollingPolicy.decide(pollingInputs(for: $0)) }
        if before != after { reschedule() }
    }

    private func refreshCostIfDue(now: Date = Date()) async {
        guard case .after(let interval) = PollingPolicy.decide(pollingInputs(for: .claude, base: Self.costInterval, now: now)) else { return }
        if let lastCostScan, now.timeIntervalSince(lastCostScan) < interval { return }
        await refreshCost()
    }

    private func observeEnvironment() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setAsleep(true) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setAsleep(false) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setScreensAsleep(true) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setScreensAsleep(false) }
        })
        observers.append(distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setScreenLocked(true) }
        })
        observers.append(distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setScreenLocked(false) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setLowPowerMode(PowerSource.lowPowerMode()) }
        })
        observers.append(distributed.addObserver(forName: Hook.notificationName, object: nil, queue: .main) { [weak self] note in
            guard let message = Hook.Message(userInfo: note.userInfo) else { return }
            Task { @MainActor in self?.hookReceived(message) }
        })
        observers.append(distributed.addObserver(forName: Statusline.notificationName, object: nil, queue: .main) { [weak self] note in
            guard let message = Statusline.Message(userInfo: note.userInfo) else { return }
            Task { @MainActor in self?.statuslineReceived(message) }
        })
    }

    private func setAsleep(_ value: Bool) {
        guard asleep != value else { return }
        asleep = value
        environmentChanged(delayed: !value)
    }

    private func setScreensAsleep(_ value: Bool) {
        guard screensAsleep != value else { return }
        screensAsleep = value
        environmentChanged(delayed: !value)
    }

    private func setScreenLocked(_ value: Bool) {
        guard screenLocked != value else { return }
        screenLocked = value
        environmentChanged()
    }

    private func setLowPowerMode(_ value: Bool) {
        guard lowPowerMode != value else { return }
        lowPowerMode = value
        reschedule()
    }

    /// Pausing parks every loop and the minute tick; resuming reads everything at once, a few seconds after a wake
    /// so the network has come back first.
    private func environmentChanged(delayed: Bool = false) {
        if case .paused(let reason) = PollingPolicy.decide(pollingInputs(for: .claude, base: 1)) {
            pauseReason = reason
            tick?.cancel()
            reschedule()
        } else {
            pauseReason = nil
            if delayed {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(4))
                    self?.restartLoops()
                    self?.startTick()
                }
            } else {
                restartLoops()
                startTick()
            }
        }
    }

    // MARK: - Claude Code hook and status line

    /// Every event is activity; a refresh follows at most once every 30 s, and the session tracker keeps who is
    /// working, idle or waiting for the user.
    func hookReceived(_ message: Hook.Message, now: Date = Date()) {
        log.info("hook \(message.event, privacy: .public)\(message.needsInput ? " (needs input)" : "", privacy: .public)")
        Oracle.shared.emit("hook", ["name": message.event, "needsInput": message.needsInput, "session": message.sessionID as Any, "project": message.project as Any])
        lastHook = now
        lastActivity[.claude] = now
        wokeAt = now
        let outcome = sessions.apply(message, now: now)
        if let waiting = outcome.startedWaiting, prefs.notifyWaiting {
            deliverSessionEvent(.waiting, waiting)
        }
        if let finished = outcome.finished, prefs.notifyFinished, finished.turn >= TimeInterval(prefs.finishedAfterMinutes * 60) {
            deliverSessionEvent(.finished(turn: finished.turn), finished.session)
        }
        guard isShown(.claude) else { return }
        if lastHookRefresh.map({ now.timeIntervalSince($0) >= Self.hookRefreshSpacing }) ?? true {
            lastHookRefresh = now
            Task {
                await refresh(.claude, force: true)
                reschedule()
            }
        } else {
            reschedule()
        }
    }

    /// The status line's windows replace the endpoint's for as long as they keep arriving; the context fill and the
    /// session cost go to the Claude card.
    func statuslineReceived(_ message: Statusline.Message, now: Date = Date()) {
        Oracle.shared.emit("statusline", ["context": message.contextUsed.map(Oracle.fraction) as Any, "windows": message.windows.map(\.id),
                                          "session": message.sessionID as Any, "model": message.model as Any])
        statusline = message
        lastHook = now
        lastActivity[.claude] = now
        sessions.statusline(sessionID: message.sessionID, project: message.project, now: now)
        guard isShown(.claude) else { return }
        if let reading = statuslineReading(now: now) {
            adopt(reading, now: now)
        }
        reschedule()
    }

    private func initialStatus(for tool: ToolID, cached: UsageReading?) -> ToolStatus {
        guard isInstalled(tool) else { return .notInstalled }
        guard prefs.enabledTools.contains(tool) else { return .off }
        if let cached { return .ready(cached) }
        return .waiting
    }
}
