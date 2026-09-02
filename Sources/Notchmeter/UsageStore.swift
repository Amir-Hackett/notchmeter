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
    private(set) var statuses: [ToolID: ToolStatus] = [:]
    private(set) var lastUpdated: Date?
    private(set) var nextRefresh: [ToolID: Date] = [:]
    private(set) var cost: CostSummary?
    private(set) var costScanning = false
    /// Why every read is on hold, for the footer; nil while polling.
    private(set) var pauseReason: PauseReason?
    private(set) var onBattery = false
    /// When each tool's files last changed, or a Claude Code hook last fired.
    private(set) var lastActivity: [ToolID: Date] = [:]
    /// Tools waiting on the user: a permission prompt or a question in Claude Code, reported by its hook.
    private(set) var awaitingInput: Set<ToolID> = []
    let prefs: Preferences

    @ObservationIgnored private let providers: [ToolID: any UsageProvider]
    @ObservationIgnored private var loops: [ToolID: Task<Void, Never>] = [:]
    @ObservationIgnored private var sleepers: [ToolID: Task<Void, Error>] = [:]
    @ObservationIgnored private var inflight: Set<ToolID> = []
    @ObservationIgnored private var backoff: [ToolID: TimeInterval] = [:]
    @ObservationIgnored private var lastFetch: [ToolID: Date] = [:]
    @ObservationIgnored private let cache: ReadingCache
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let costScanner = ClaudeCostScanner()
    @ObservationIgnored private let activity = AgentActivity()
    @ObservationIgnored private var tick: Task<Void, Never>?
    @ObservationIgnored private var lastCostScan: Date?
    @ObservationIgnored private var screenLocked = false
    @ObservationIgnored private var asleep = false
    @ObservationIgnored private var lastHook: Date?
    @ObservationIgnored private var lastHookRefresh: Date?
    @ObservationIgnored private var awaitingInputExpiry: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var alertMemory: AlertMemory
    /// Receives each batch of pace alerts the scheduler decides on; wired to the Notifier by the app delegate.
    @ObservationIgnored var deliverAlerts: ([PaceAlert]) -> Void = { _ in }

    static let costInterval: TimeInterval = 60
    static let hookRefreshSpacing: TimeInterval = 30
    static let awaitingInputTimeout: TimeInterval = 600

    init(prefs: Preferences, providers: [any UsageProvider] = ProviderRegistry.all(), cache: ReadingCache = ReadingCache(),
         defaults: UserDefaults = .standard) {
        self.prefs = prefs
        self.cache = cache
        self.defaults = defaults
        self.alertMemory = AlertMemory.load(from: defaults)
        self.providers = providers.reduce(into: [:]) { $0[$1.tool] = $1 }
        let cached = cache.load()
        for tool in ToolID.allCases {
            statuses[tool] = initialStatus(for: tool, cached: cached[tool])
        }
    }

    var visibleTools: [ToolID] { ToolID.allCases.filter(isShown) }

    func isInstalled(_ tool: ToolID) -> Bool {
        providers[tool]?.isInstalled() ?? false
    }

    func isShown(_ tool: ToolID) -> Bool {
        prefs.enabledTools.contains(tool) && isInstalled(tool)
    }

    func status(_ tool: ToolID) -> ToolStatus {
        statuses[tool] ?? .waiting
    }

    func isAwaitingInput(_ tool: ToolID) -> Bool {
        awaitingInput.contains(tool)
    }

    /// How loud the compact rings are, from every visible reading; the rule is in Presence.swift.
    var presence: PresenceLevel {
        Presence.level(windows: visibleTools.flatMap { status($0).reading?.windows ?? [] },
                       awaitingInput: visibleTools.contains(where: isAwaitingInput))
    }

    /// Live readings of the visible tools; a cached reading shown beside an error is left out.
    var readyReadings: [UsageReading] {
        visibleTools.compactMap {
            if case .ready(let reading) = status($0) { return reading }
            return nil
        }
    }

    func adviceContext(now: Date = Date()) -> Advisor.Context {
        Advisor.Context(readings: readyReadings, awaitingInput: awaitingInput.filter(isShown), cost: prefs.showSpend ? cost : nil,
                        timeFormat: prefs.timeFormat, now: now)
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
        if PollingPolicy.isIdle(pollingInputs(for: tool)) { notes.append("no agent activity") }
        if onBattery { notes.append("on battery") }
        return notes.isEmpty ? nil : notes.joined(separator: ", ")
    }

    func start() {
        onBattery = PowerSource.onBattery()
        for tool in ToolID.allCases where isShown(tool) {
            startLoop(tool)
        }
        startTick()
        observeEnvironment()
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

    func refreshAll(force: Bool = true) {
        for tool in visibleTools {
            Task { await refresh(tool, force: force) }
        }
        Task { await refreshCost() }
    }

    /// Prices Claude Code's local transcripts. Incremental after the first pass, so it is cheap to call often.
    func refreshCost() async {
        guard prefs.showSpend, isShown(.claude) else { return }
        if cost == nil { costScanning = true }
        lastCostScan = Date()
        let summary = await costScanner.scan()
        cost = summary
        costScanning = false
    }

    /// Unforced refreshes are throttled so hovering the notch cannot hammer the APIs.
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
        lastFetch[tool] = Date()

        let cached = statuses[tool]?.reading
        do {
            let reading = try await provider.fetch()
            log.info("\(tool.displayName, privacy: .public) usage -> \(Probe.describe(reading), privacy: .public)")
            statuses[tool] = .ready(reading)
            backoff[tool] = 0
            cache.store(reading)
            lastUpdated = Date()
            evaluateAlerts()
        } catch let error as ProviderError {
            log.error("\(tool.displayName, privacy: .public) failed: \(error.message, privacy: .public)")
            if case .nothingYet(let message) = error {
                statuses[tool] = .idle(message)
                backoff[tool] = 0
            } else if case .rateLimited(let retry) = error {
                // Transient: keep the last good numbers on screen and try again later.
                let wait = max(60, retry ?? 0)
                backoff[tool] = wait
                if let cached {
                    statuses[tool] = .ready(cached)
                } else {
                    statuses[tool] = .failed("Rate limited, retrying in \(Int(wait))s", cached: nil)
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
            backoff[tool] = min(600, max(30, (backoff[tool] ?? 15) * 2))
            statuses[tool] = .failed(error.localizedDescription, cached: cached)
        }
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

    // MARK: - Pace alerts

    /// Only new readings can make a pace worse, so this runs after each one; nothing is remembered while the
    /// setting is off, so switching it on reports whatever is behind at that moment.
    private func evaluateAlerts(now: Date = Date()) {
        guard prefs.notificationsEnabled else { return }
        let plan = NotificationScheduler.plan(memory: alertMemory, readings: readyReadings, now: now)
        if plan.memory != alertMemory {
            alertMemory = plan.memory
            alertMemory.save(to: defaults)
        }
        guard !plan.alerts.isEmpty else { return }
        for alert in plan.alerts {
            log.info("pace alert \(alert.identifier, privacy: .public)")
        }
        deliverAlerts(plan.alerts)
    }

    // MARK: - Scheduling

    func pollingInputs(for tool: ToolID, base: TimeInterval? = nil, now: Date = Date()) -> PollingInputs {
        PollingInputs(
            baseInterval: base ?? providers[tool]?.refreshInterval ?? 60,
            screenLocked: screenLocked,
            asleep: asleep,
            onBattery: onBattery,
            minutesSinceLastAgentActivity: lastActivity[tool].map { now.timeIntervalSince($0) / 60 },
            hookNudge: tool == .claude && (lastHook.map { now.timeIntervalSince($0) < PollingPolicy.idleAfter } ?? false)
        )
    }

    /// One line for `--smoke`: the environment and each tool's cadence.
    func scheduleDescription() -> String {
        var parts = ["battery=\(onBattery)", "locked=\(screenLocked)", "asleep=\(asleep)"]
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

    private func sampleEnvironment() async {
        let activity = self.activity
        var sampled = await Task.detached(priority: .utility) { activity.sample() }.value
        if let lastHook, sampled[.claude].map({ lastHook > $0 }) ?? true { sampled[.claude] = lastHook }
        let battery = PowerSource.onBattery()
        let before = visibleTools.map { PollingPolicy.decide(pollingInputs(for: $0)) }
        if sampled != lastActivity { lastActivity = sampled }
        if battery != onBattery { onBattery = battery }
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
        observers.append(distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setScreenLocked(true) }
        })
        observers.append(distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setScreenLocked(false) }
        })
        observers.append(distributed.addObserver(forName: Hook.notificationName, object: nil, queue: .main) { [weak self] note in
            guard let message = Hook.Message(userInfo: note.userInfo) else { return }
            Task { @MainActor in self?.hookReceived(message) }
        })
    }

    private func setAsleep(_ value: Bool) {
        guard asleep != value else { return }
        asleep = value
        environmentChanged()
    }

    private func setScreenLocked(_ value: Bool) {
        guard screenLocked != value else { return }
        screenLocked = value
        environmentChanged()
    }

    /// Pausing parks every loop and the minute tick; resuming reads everything at once.
    private func environmentChanged() {
        if case .paused(let reason) = PollingPolicy.decide(pollingInputs(for: .claude)) {
            pauseReason = reason
            tick?.cancel()
            reschedule()
        } else {
            pauseReason = nil
            restartLoops()
            startTick()
        }
    }

    // MARK: - Claude Code hook

    /// Every event is activity; a refresh follows at most once every 30 s, and a waiting Claude shows a badge
    /// until its Stop, the next prompt, or ten minutes.
    func hookReceived(_ message: Hook.Message, now: Date = Date()) {
        log.info("hook \(message.event, privacy: .public)\(message.needsInput ? " (needs input)" : "", privacy: .public)")
        lastHook = now
        lastActivity[.claude] = now
        if message.needsInput {
            setAwaitingInput(true)
        } else if Hook.clearingEvents.contains(message.event) {
            setAwaitingInput(false)
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

    private func setAwaitingInput(_ waiting: Bool) {
        awaitingInputExpiry?.cancel()
        if waiting {
            awaitingInput.insert(.claude)
            awaitingInputExpiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.awaitingInputTimeout))
                guard !Task.isCancelled else { return }
                self?.awaitingInput.remove(.claude)
            }
        } else {
            awaitingInput.remove(.claude)
        }
    }

    private func initialStatus(for tool: ToolID, cached: UsageReading?) -> ToolStatus {
        guard isInstalled(tool) else { return .notInstalled }
        guard prefs.enabledTools.contains(tool) else { return .off }
        if let cached { return .ready(cached) }
        return .waiting
    }
}
