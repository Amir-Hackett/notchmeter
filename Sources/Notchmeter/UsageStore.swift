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

extension ProviderRegistry {
    /// Every provider, each reading its own opt-in switch (ProviderOptIn) from these defaults at fetch time. This
    /// is the only registry: a second, argument-free overload of it once shadowed this one and built providers
    /// with their second reads hard-wired off, which is how Cursor's usage export never ran in the app.
    static func all(defaults: UserDefaults = .standard) -> [any UsageProvider] {
        [ClaudeProvider(),
         CodexProvider(defaults: defaults),
         CursorProvider(defaults: defaults),
         AntigravityProvider(),
         CopilotProvider(defaults: defaults)]
    }
}

/// The last extra-usage figure seen, persisted so a relaunch cannot report the same rise twice.
struct ExtraUsageMemory: Codable, Equatable {
    var amountUSD: Double
    var seenAt: Date
    /// "2026-09": the month a rise was last reported in.
    var risenIn: String?

    static let defaultsKey = "extraUsageMemory"
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
    /// When each tool's files last changed, or its hook last fired (every assistant's).
    private(set) var lastActivity: [ToolID: Date] = [:]
    /// The sessions the hooks report, each under its tool, and which are waiting on the user.
    private(set) var sessions = SessionTracker()
    /// The newest status-line payload from Claude Code, while a session runs.
    private(set) var statusline: Statusline.Message?
    /// The last hour's move per window, and 24 hourly points per window, from the drain log.
    private(set) var drains: [DrainLog.Key: Drain] = [:]
    private(set) var drainSeries: [DrainLog.Key: [Double?]] = [:]
    /// The run-out interval per window where the drain log holds enough history.
    private(set) var runOuts: [DrainLog.Key: RunOutInterval] = [:]
    /// Set by `--smoke --idle-sim`: the idle clock pretends this much time has passed since any activity.
    private(set) var simulatedIdle: TimeInterval?
    /// Something is capturing the screen (ScreenCaptureMonitor); with the privacy setting on, figures are hidden.
    private(set) var screenCaptured = false
    /// One line the footer shows beside the schedule: a hook repaired at launch, the awake assertion held.
    private(set) var footerNote: String?
    /// Extra-usage credits rose since the last reading (kept for an hour, for the advice strip).
    private(set) var extraUsageRise: ExtraUsageRise?
    /// Tools whose endpoint last answered a server error, by status code.
    private(set) var serverTrouble: [ToolID: Int] = [:]
    /// Whether the awake assertion is held right now (AwakeKeeper mirrors it).
    private(set) var keepingAwake = false
    /// What Cursor's usage export last answered, so the Cost card can say why Cursor has no figure of its own.
    private(set) var cursorExport: CursorExportRead?
    let prefs: Preferences

    @ObservationIgnored private let providers: [ToolID: any UsageProvider]
    @ObservationIgnored private var loops: [ToolID: Task<Void, Never>] = [:]
    @ObservationIgnored private var sleepers: [ToolID: Task<Void, Error>] = [:]
    @ObservationIgnored private var resetTimers: [ToolID: Task<Void, Never>] = [:]
    @ObservationIgnored private var inflight: Set<ToolID> = []
    @ObservationIgnored private var backoff: [ToolID: TimeInterval] = [:]
    @ObservationIgnored private var lastFetch: [ToolID: Date] = [:]
    @ObservationIgnored private let cache: ReadingCache
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var costEngine: CostEngine
    @ObservationIgnored private var activity: AgentActivity
    @ObservationIgnored private let drainLog: DrainLog?
    @ObservationIgnored private var drainSamples: [DrainLog.Key: [DrainSample]] = [:]
    @ObservationIgnored private var tick: Task<Void, Never>?
    @ObservationIgnored private var resetTimer: Task<Void, Never>?
    /// Releases a waiting or finished ring the moment its own clock runs out (armSignalRelease).
    @ObservationIgnored private var signalRelease: Task<Void, Never>?
    @ObservationIgnored private var lastCostScan: Date?
    @ObservationIgnored private var screenLocked = false
    @ObservationIgnored private var asleep = false
    @ObservationIgnored private var screensAsleep = false
    @ObservationIgnored private var sessionInactive = false
    /// When each tool's hook last fired (the status line counts as Claude's), and when a hook last forced that
    /// tool's refresh; per tool, so a Cursor event nudges Cursor's cadence and never Claude's.
    @ObservationIgnored private var lastHook: [ToolID: Date] = [:]
    @ObservationIgnored private var lastHookRefresh: [ToolID: Date] = [:]
    @ObservationIgnored private var wokeAt: Date?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var alertMemory: AlertMemory
    @ObservationIgnored private var watchedResets: [String: WatchedReset] = [:]
    @ObservationIgnored private var reportedAdvice: [String]?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var extraUsageMemory: ExtraUsageMemory?
    @ObservationIgnored private var extraUsageRiseAt: Date?
    @ObservationIgnored private var lastReportWrite: Date?
    @ObservationIgnored private let reportFile: URL?
    /// Receives each batch of pace alerts the scheduler decides on; wired to the Notifier by the app delegate.
    @ObservationIgnored var deliverAlerts: ([PaceAlert]) -> Void = { _ in }
    /// Advice lines worth a banner of their own (extra usage, a cache-tier shift, heavy metering).
    @ObservationIgnored var deliverAdvice: ([Advice]) -> Void = { _ in }
    /// A session (any assistant's) began waiting, or finished a turn; wired to the Notifier by the app
    /// delegate, which names the session's tool.
    @ObservationIgnored var deliverSessionEvent: (Notifier.SessionEvent, AgentSession) -> Void = { _, _ in }
    /// Notices whose state has passed, to withdraw from Notification Center.
    @ObservationIgnored var removeNotifications: ([String]) -> Void = { _ in }
    /// The working-session count changed, or the power source did; the app applies the awake assertion.
    @ObservationIgnored var awakeChanged: (Bool) -> Void = { _ in }

    static let costInterval: TimeInterval = 60
    static let hookRefreshSpacing: TimeInterval = 30
    static let awaitingInputTimeout: TimeInterval = SessionTracker.waitingTimeout
    static let resetCheckInterval: TimeInterval = 30
    /// A refresh a few seconds after a window's reset, so the freshly reset figure is on the ring at once.
    static let resetRefreshDelay: TimeInterval = 5
    static let reportWriteSpacing: TimeInterval = 30
    static let extraUsageRiseShownFor: TimeInterval = 3600

    init(prefs: Preferences, providers: [any UsageProvider] = ProviderRegistry.all(), cache: ReadingCache = ReadingCache(),
         defaults: UserDefaults = .standard, drainLog: DrainLog? = DrainLog(), reportFile: URL? = Paths.reportFile) {
        self.prefs = prefs
        self.cache = cache
        self.defaults = defaults
        self.drainLog = drainLog
        self.reportFile = reportFile
        self.alertMemory = AlertMemory.load(from: defaults)
        self.providers = providers.reduce(into: [:]) { $0[$1.tool] = $1 }
        let roots = ClaudeCostScanner.defaultRoots(extra: prefs.extraTranscriptRoots)
        self.costEngine = CostEngine(claude: ClaudeCostScanner(roots: roots))
        self.activity = AgentActivity(claudeRoots: roots)
        if let data = defaults.data(forKey: ExtraUsageMemory.defaultsKey) {
            extraUsageMemory = try? JSONDecoder().decode(ExtraUsageMemory.self, from: data)
        }
        cursorExport = CursorExportRead.load(from: defaults)
        let cached = cache.load()
        for tool in ToolID.allCases {
            statuses[tool] = initialStatus(for: tool, cached: cached[tool])
        }
    }

    /// The tools on screen, in the user's order (Preferences.toolOrder).
    var visibleTools: [ToolID] { prefs.toolOrder.filter(isShown) }

    /// The assistants the Cost card carries, in the user's order, less any the card is set to leave out. The card
    /// draws this, the self check prints it and the oracle reports it, so a tester who cannot see the card reads
    /// the same order the card does.
    var costSelection: CostSelection {
        CostSelection(all: cost?.providers ?? [], order: prefs.toolOrder, carried: prefs.costCardTools)
    }

    /// The carried assistants that reported nothing, each with the reason the app already knows. Empty before the
    /// first scan, where every tool is missing because the scan is still running.
    var costGaps: [CostGap] {
        guard cost != nil else { return [] }
        let carried = visibleTools.filter { prefs.costCardTools.contains($0) }
        return CostAbsence.gaps(carried: carried, reporting: Set(costSelection.providers.map(\.tool)),
                                cursorUsageEvents: prefs.cursorUsageEvents, cursorExport: cursorExport,
                                problems: carried.reduce(into: [:]) { $0[$1] = status($1).problem },
                                nothingLocal: Set(carried.filter { status($0).hasNothingYet }))
    }

    func isInstalled(_ tool: ToolID) -> Bool {
        providers[tool]?.isInstalled() ?? false
    }

    func isShown(_ tool: ToolID) -> Bool {
        prefs.enabledTools.contains(tool) && isInstalled(tool)
    }

    func status(_ tool: ToolID) -> ToolStatus {
        statuses[tool] ?? .waiting
    }

    /// Claude Code is billed by API key on this Mac: no plan windows to meter, the Cost card is the meter.
    var claudeOnAPIKey: Bool {
        if case .idle(let message) = status(.claude), message.contains("API key") { return true }
        return false
    }

    /// Tools waiting on the user: a permission prompt or a question, reported by that tool's hook. Claude Code,
    /// Codex, Gemini CLI and Copilot document a wait; Cursor does not, so its ring is never in this set. The set is
    /// read off the sessions rather than named here, so a hook that gains a wait lights the same lamps without a
    /// change in this file.
    var awaitingInput: Set<ToolID> {
        Set(sessions.waiting.map(\.tool))
    }

    func isAwaitingInput(_ tool: ToolID) -> Bool {
        awaitingInput.contains(tool)
    }

    /// When the user last attended to the rings, from `wakeFromIdle`. Not `wokeAt`: every hook event sets that one
    /// too, so it cannot tell the user's attention from the agent's own noise.
    private(set) var attendedAt: Date?

    /// What one tool is asking of the user right now (ToolSignal). The rings, the mark beside them, the card's
    /// label, the menu bar item and VoiceOver all read this one answer, so none of them can contradict another.
    /// It answers whatever `Preferences.signalRings` says: that setting decides whether the rings take the colour,
    /// not whether the fact is told, and every mark stays either way.
    func signal(_ tool: ToolID, now: Date = Date()) -> ToolSignal? {
        ToolSignal.resolve(waiting: sessions.waiting(of: tool).count, finish: sessions.finish(of: tool, now: now),
                           working: sessions.isWorking(tool), attended: attendedAt, now: now)
    }

    /// The strongest signal across a run of tools, for the menu bar pin, which has one glyph to say it in and
    /// several tools to say it about. A wait outranks a finish for the same reason it does on a ring: only the
    /// wait is blocking.
    func strongestSignal(among tools: [ToolID]? = nil, now: Date = Date()) -> (tool: ToolID, signal: ToolSignal)? {
        let found = (tools ?? visibleTools).compactMap { tool in signal(tool, now: now).map { (tool: tool, signal: $0) } }
        return found.first(where: { $0.signal.isWaiting }) ?? found.first
    }

    /// The context window's fill from the status line, while its report is fresh.
    var contextUsed: Double? {
        guard let statusline, Date().timeIntervalSince(statusline.receivedAt) < PollingPolicy.statuslineFreshFor * 4 else { return nil }
        return statusline.contextUsed
    }

    /// How loud the compact rings are, from every visible reading; the rule is in Presence.swift. It is asked per
    /// tool and the loudest answer kept, because the rule's session count is proof about one tool only: Cursor's
    /// hook saying "no conversation open" must not quieten a Claude ring whose own hook has never spoken. Hide
    /// when idle turns quiet into hidden once no agent has been active for half an hour.
    var presence: PresenceLevel {
        let level = visibleTools.map { tool in
            Presence.level(windows: status(tool).reading.map(prefs.shownWindows) ?? [],
                           awaitingInput: isAwaitingInput(tool),
                           sessions: sessions.knownCount(of: tool))
        }.max() ?? .quiet
        guard prefs.visibility == .hideWhenIdle else { return level }
        let now = Date()
        let idleFor = simulatedIdle ?? visibleTools.compactMap { lastActivity[$0] }.max().map { now.timeIntervalSince($0) }
        let nudge = visibleTools.compactMap { lastHook[$0] }.max().map { now.timeIntervalSince($0) < PollingPolicy.idleAfter } ?? false
        return Presence.hides(level: level, idleFor: nudge ? 0 : idleFor, wokeAgo: wokeAt.map { now.timeIntervalSince($0) }) ? .hidden : level
    }

    /// Whether any visible tool has just finished a turn. `wakeFromIdle` guards its publication with this: a look
    /// releases a finish, so attendance is worth recording while one is lit and worth nothing otherwise, and this
    /// is the cheapest question that tells the two apart. It deliberately does not reach `presence`: a finish that
    /// changed how loud the rings are would change how wide they are, and the strip is fitted from that width
    /// (Presence.level says what that cost).
    private var showsFinish: Bool {
        visibleTools.contains { tool in
            if case .finished = signal(tool) { return true }
            return false
        }
    }

    /// The pointer rested on the rings, or something else that should bring hidden rings back at once. The
    /// attendance is recorded whatever the visibility setting says, because a finished ring releases on being
    /// looked at and most users never turn Hide when idle on — but only while a finish is actually lit, because
    /// `attendedAt` is observed and this runs on every pointer entry into the strip: publishing it unconditionally
    /// would re-measure the notch, re-fit the edge pill and rebuild the menu bar item's menu on every hover, which
    /// is the one moment that geometry must not move. Once the look has released the finish the guard is false
    /// again, so a turn costs at most one publication however long the pointer plays over the rings.
    func wakeFromIdle() {
        if showsFinish { attendedAt = Date() }
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

    func setFooterNote(_ note: String?) {
        footerNote = note
    }

    /// A vendor's page or a pull request, from the card.
    func openURL(_ url: URL) {
        Oracle.shared.emit("open", ["host": url.host ?? url.absoluteString])
        NSWorkspace.shared.open(url)
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

    var runOutsByKey: [String: RunOutInterval] {
        runOuts.reduce(into: [:]) { $0["\($1.key.tool.rawValue)/\($1.key.window)"] = $1.value }
    }

    /// Inside a tool's peak window right now, for the footer.
    var peakNow: Bool {
        visibleTools.contains { prefs.peakHours(for: $0)?.isPeak(at: Date()) ?? false }
    }

    func adviceContext(now: Date = Date()) -> Advisor.Context {
        var context = Advisor.Context(readings: readyReadings, awaitingInput: awaitingInput.filter(isShown), waitingSessions: sessions.waiting,
                                      cost: prefs.showSpend ? cost : nil, timeFormat: prefs.timeFormat, toolOrder: prefs.toolOrder, drainRates: drainRates, now: now)
        context.runOuts = runOutsByKey
        context.monthlyBudgetUSD = prefs.showSpend ? prefs.monthlyBudgetUSD : nil
        context.weeklyBudgetUSD = prefs.showSpend ? prefs.weeklyBudgetUSD : nil
        context.extraUsageRise = extraUsageRiseAt.map { now.timeIntervalSince($0) < Self.extraUsageRiseShownFor } == true ? extraUsageRise : nil
        context.peakHours = visibleTools.reduce(into: [:]) { $0[$1] = prefs.peakHours(for: $1) }
        context.limitHitTools = sessions.limitHitTools(now: now).filter(isShown)
        context.serverTrouble = serverTrouble.filter { isShown($0.key) }
        context.metering = prefs.showSpend ? cost?.sessionMetering : nil
        return context
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
        let inputs = pollingInputs(for: tool)
        if let until = inputs.exhaustedUntil, PollingPolicy.isExhausted(inputs) { notes.append(L("Resets in %@", ResetText.duration(until.timeIntervalSinceNow))) }
        if inputs.sessionInactive { notes.append(L("another user is logged in")) }
        if PollingPolicy.isIdle(inputs) { notes.append(L("no agent activity")) }
        if onBattery { notes.append(L("on battery")) }
        if lowPowerMode { notes.append(L("low power mode")) }
        if peakNow { notes.append(L("peak hours")) }
        if visibleTools.contains(where: { status($0).isOffline }) { notes.append(L("Offline, retrying")) }
        return notes.isEmpty ? nil : notes.joined(separator: ", ")
    }

    /// Everything the app knows, for `--probe --json`, the local API and the oracle.
    func report(now: Date = Date(), history: Bool = false) -> UsageReport {
        UsageReport(tools: statuses, order: prefs.toolOrder, cost: prefs.showSpend ? cost : nil, advice: advice, drains: drains, runOuts: runOuts,
                    sessions: sessions.all, history: history ? costEngine.claude.history?.load() : nil, now: now)
    }

    func start() {
        onBattery = PowerSource.onBattery()
        lowPowerMode = PowerSource.lowPowerMode()
        sessionInactive = !LoginSession.isOnConsole()
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
            if tool == .claude { Keychain.setInteractive(true) }
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
        costEngine = CostEngine(claude: ClaudeCostScanner(roots: roots))
        activity = AgentActivity(claudeRoots: roots)
        lastCostScan = nil
        Task { await refreshCost() }
    }

    /// `interactive` marks a read the user asked for (Refresh, the ring, a card's menu): the one kind that may
    /// raise the Keychain dialog under the "On Refresh only" policy.
    func refreshAll(force: Bool = true, interactive: Bool = false) {
        if interactive { Keychain.setInteractive(true) }
        for tool in visibleTools {
            Task { await refresh(tool, force: force) }
        }
        Task { await refreshCost() }
    }

    /// Prices what every tool that can report spend has written down: Claude Code's transcripts, Codex's session
    /// rollouts, and the Cursor usage export the Cursor provider folds into the daily history. Each scanner runs
    /// against its own source, so a tool with nothing to say leaves the others alone. Incremental after the first
    /// pass, so it is cheap to call often. The live Claude reading's resets align the week and the 5-hour block.
    func refreshCost() async {
        let tools = Set(ToolID.allCases.filter { $0.reportsCost && isShown($0) })
        guard prefs.showSpend, !tools.isEmpty else { return }
        if cost == nil { costScanning = true }
        lastCostScan = Date()
        let claude = status(.claude).reading
        let weekly = claude?.windows.first { $0.id == "seven_day" }
        let session = claude?.windows.first { $0.id == "five_hour" }
        let reads = tools.reduce(into: [ToolID: ProviderReadState]()) { reads, tool in
            reads[tool] = ProviderReadState(readAt: status(tool).reading?.fetchedAt, problem: status(tool).problem)
        }
        let summary = await costEngine.scan(tools: tools, reads: reads, weeklyResetsAt: weekly?.resetsAt, weeklyUsed: weekly?.usedFraction,
                                            sessionResetsAt: session?.resetsAt, sessionUsed: session?.usedFraction)
        cost = summary
        cursorExport = CursorExportRead.load(from: defaults)
        costScanning = false
        evaluateAlerts()
        writeReportIfDue()
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
        defer {
            inflight.remove(tool)
            if tool == .claude { Keychain.setInteractive(false) }
        }
        if tool == .claude, let reading = statuslineReading() {
            adopt(reading)
            return
        }
        lastFetch[tool] = Date()

        let cached = statuses[tool]?.reading
        do {
            let reading = try await provider.fetch()
            log.info("\(tool.displayName, privacy: .public) usage -> \(Probe.describe(reading), privacy: .public)")
            serverTrouble[tool] = nil
            adopt(reading)
        } catch let error as ProviderError {
            log.error("\(tool.displayName, privacy: .public) failed: \(error.message, privacy: .public)")
            if case .http(let code, _) = error, code >= 500 { serverTrouble[tool] = code } else { serverTrouble[tool] = nil }
            if error.isCalm {
                statuses[tool] = .idle(error.message)
                backoff[tool] = 0
            } else if case .offline = error {
                statuses[tool] = .offline(cached: cached)
                backoff[tool] = min(300, max(30, (backoff[tool] ?? 15) * 2))
            } else if case .rateLimited(let retry) = error {
                // Transient: keep the last good numbers on screen and try again later.
                let wait = ProviderError.rateLimitWait(retryAfter: retry)
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

    /// A good reading: on screen, cached, logged for the drain, watched for its reset, and checked for alerts.
    private func adopt(_ reading: UsageReading, now: Date = Date()) {
        var reading = reading
        if reading.tool == .antigravity {
            let resets = drainSamples.filter { $0.key.tool == .antigravity }.reduce(into: [String: [Date]]()) { $0[$1.key.window] = $1.value.compactMap(\.resetsAt) }
            reading = AntigravityPeriods.apply(reading, resets: resets, now: now)
        }
        if reading.tool == .claude { noteExtraUsage(reading, now: now) }
        statuses[reading.tool] = .ready(reading)
        backoff[reading.tool] = 0
        cache.store(reading)
        lastUpdated = now
        recordDrain(reading, now: now)
        for window in reading.windows {
            let key = AlertMemory.key(reading.tool, window)
            if let watch = WatchedReset.watch(reading.tool, window, now: now) {
                watchedResets[key] = watch
            } else if let existing = watchedResets[key], !ResetPeriod.same(existing.window.resetsAt, window.resetsAt) {
                watchedResets[key] = nil
            }
        }
        scheduleResetRefresh(for: reading, now: now)
        evaluateAlerts(now: now)
        writeReportIfDue(now: now)
    }

    /// Extra-usage credits rose since the last reading: remember it, log it with the plan windows beside it, and
    /// keep the rise for the advice strip.
    private func noteExtraUsage(_ reading: UsageReading, now: Date) {
        guard let extra = reading.windows.first(where: { $0.id == "extra_usage" }), let amount = extra.amountUSD else { return }
        let month = String(CostHistory.key(now).prefix(7))
        var memory = extraUsageMemory ?? ExtraUsageMemory(amountUSD: amount, seenAt: now, risenIn: nil)
        if amount > memory.amountUSD + 0.005 {
            let plan = reading.windows.filter { $0.id == "five_hour" || $0.id == "seven_day" }
            let rise = ExtraUsageRise(amountUSD: amount - memory.amountUSD, over: now.timeIntervalSince(memory.seenAt),
                                      planUsed: plan.compactMap(\.usedFraction).max(), firstThisMonth: memory.risenIn != month)
            drainLog?.appendExtraUsage(tool: .claude, amountUSD: amount, previousUSD: memory.amountUSD, planWindows: plan, now: now)
            log.notice("extra usage rose by \(Money.dollars(rise.amountUSD), privacy: .public)")
            extraUsageRise = rise
            extraUsageRiseAt = now
            memory.risenIn = month
        }
        memory.amountUSD = amount
        memory.seenAt = now
        if memory != extraUsageMemory {
            extraUsageMemory = memory
            if let data = try? JSONEncoder().encode(memory) { defaults.set(data, forKey: ExtraUsageMemory.defaultsKey) }
        }
    }

    /// A refresh of the tool a few seconds after its soonest reset, whatever the notification settings, so a ring
    /// at 100 % does not sit there for a poll interval after the limit has lifted.
    private func scheduleResetRefresh(for reading: UsageReading, now: Date) {
        resetTimers[reading.tool]?.cancel()
        guard let soonest = reading.windows.compactMap({ $0.usedFraction != nil ? $0.resetsAt : nil }).filter({ $0 > now }).min() else {
            resetTimers[reading.tool] = nil
            return
        }
        let wait = soonest.timeIntervalSince(now) + Self.resetRefreshDelay
        let tool = reading.tool
        resetTimers[tool] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            log.info("\(tool.displayName, privacy: .public) reset passed; refreshing")
            Oracle.shared.emit("resetRefresh", ["tool": tool.rawValue])
            await self.refresh(tool, force: true)
        }
    }

    /// The session and weekly windows from a status line under three minutes old, laid over the cached reading.
    private func statuslineReading(now: Date = Date()) -> UsageReading? {
        guard let statusline, !statusline.windows.isEmpty, now.timeIntervalSince(statusline.receivedAt) < PollingPolicy.statuslineFreshFor else { return nil }
        let base = statuses[.claude]?.reading ?? UsageReading(tool: .claude, windows: [], plan: nil, fetchedAt: now, observedAt: nil)
        return base.replacing(windows: statusline.windows, fetchedAt: statusline.receivedAt)
    }

    /// `--render-assets` (DemoFixtures): readings, a cost summary and a set of hook sessions in place of provider
    /// reads and of a hook that has actually run. The loops never start, so nothing is fetched, cached or written.
    ///
    /// The sessions go in whole rather than through `hookReceived`, which is the one route a live event takes.
    /// That route refreshes a provider, delivers notifications and arms a release timer, none of which a picture
    /// wants and the first of which would reach the network from a command whose whole promise is that it does
    /// not. `DemoFixtures` builds the tracker by feeding `SessionTracker.apply` the same messages a hook would
    /// send, so the state in the pictures is still the state machine's own answer rather than a hand-set field.
    func seed(readings: [UsageReading], cost: CostSummary, nextUpdate: Date, sessions: SessionTracker = SessionTracker(), now: Date = Date()) {
        for reading in readings {
            statuses[reading.tool] = .ready(reading)
            nextRefresh[reading.tool] = nextUpdate
            lastActivity[reading.tool] = now
        }
        self.sessions = sessions
        self.cost = cost
        lastUpdated = now
    }

    /// The report file beside the drain log, for the command-line tool and the status line, at most every 30 s.
    private func writeReportIfDue(now: Date = Date()) {
        guard let reportFile, started, lastReportWrite.map({ now.timeIntervalSince($0) >= Self.reportWriteSpacing }) ?? true else { return }
        lastReportWrite = now
        let data = report(now: now).json
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: reportFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: reportFile, options: .atomic)
        }
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

    /// Internal rather than private so `DrainLogRules` can pin the statement order below, which is the whole bug.
    func recordDrain(_ reading: UsageReading, now: Date) {
        // The log skips a window whose figure has not moved since its last row, so it must be handed the samples as
        // they stood *before* this reading. Handing it the mutated dictionary made every window its own predecessor
        // — nothing ever moved, nothing was ever written, and the file was never created.
        let previous = drainSamples
        for window in reading.windows {
            guard let used = window.usedFraction else { continue }
            drainSamples[DrainLog.Key(tool: reading.tool, window: window.id), default: []].append(DrainSample(t: now, used: used, resetsAt: window.resetsAt))
        }
        drainLog?.append(reading, previous: previous, now: now)
        recomputeDrains(now: now)
    }

    private func recomputeDrains(now: Date) {
        var drains: [DrainLog.Key: Drain] = [:]
        var series: [DrainLog.Key: [Double?]] = [:]
        var runOuts: [DrainLog.Key: RunOutInterval] = [:]
        for (key, samples) in drainSamples {
            if let drain = DrainLog.drain(samples, now: now) { drains[key] = drain }
            series[key] = DrainLog.hourly(samples, now: now)
            if let window = statuses[key.tool]?.reading?.windows.first(where: { $0.id == key.window }), let used = window.usedFraction, let resetsAt = window.resetsAt,
               let interval = RunOutInterval.estimate(samples: samples, usedFraction: used, resetsAt: resetsAt, now: now, peak: prefs.peakHours(for: key.tool)) {
                runOuts[key] = interval
            }
        }
        self.drains = drains
        drainSeries = series
        self.runOuts = runOuts
    }

    func drain(for tool: ToolID, window: LimitWindow) -> Drain? {
        drains[DrainLog.Key(tool: tool, window: window.id)]
    }

    func drainSeries(for tool: ToolID, window: LimitWindow) -> [Double?]? {
        drainSeries[DrainLog.Key(tool: tool, window: window.id)]
    }

    func runOut(for tool: ToolID, window: LimitWindow) -> RunOutInterval? {
        runOuts[DrainLog.Key(tool: tool, window: window.id)]
    }

    // MARK: - Pace alerts

    private var alertOptions: NotificationScheduler.Options {
        NotificationScheduler.Options(onTrack: prefs.notifyOnTrack, behind: prefs.notifyBehind, runningOut: prefs.notifyRunningOut,
                                      reset: prefs.notifyOnReset, reminderLead: prefs.resetReminder.lead)
    }

    /// Only new readings can make a pace worse, so this runs after each one; nothing is remembered while the
    /// setting is off, so switching it on reports whatever is behind at that moment. The budget rides along as a
    /// window of its own, and advice lines worth a banner go out here too.
    private func evaluateAlerts(now: Date = Date()) {
        guard prefs.notificationsEnabled else { return }
        var readings = readyReadings
        if let budget = NotificationScheduler.budgetReading(cost: prefs.showSpend ? cost : nil, monthlyUSD: prefs.monthlyBudgetUSD, weeklyUSD: prefs.weeklyBudgetUSD, now: now) {
            readings.append(budget)
        }
        let plan = NotificationScheduler.plan(memory: alertMemory, readings: readings, now: now, options: alertOptions, rates: drainRates, runOuts: runOutsByKey)
        remember(plan.memory)
        send(plan.alerts)
        let lines = NotificationScheduler.planAdvice(memory: alertMemory, advice: advice, now: now) { line in
            if line.id.hasPrefix("extra/") { return prefs.notifyExtraUsage ? (line.id == "extra/room" ? 3600 : 30 * 86400) : nil }
            if line.id == "cache-ttl" { return prefs.notifyCacheShift ? 86400 : nil }
            if line.id == "metering" { return prefs.notifyCacheShift ? 86400 : nil }
            return nil
        }
        remember(lines.memory)
        if !lines.advice.isEmpty {
            for line in lines.advice { Oracle.shared.emit("notification", ["action": "scheduled", "title": line.text, "stage": "advice"]) }
            deliverAdvice(lines.advice)
        }
    }

    /// The timer's half: resets and reminders for windows that were nearly gone when last seen; the pace notices
    /// of a window that has reset are withdrawn.
    private func checkResets(now: Date = Date()) {
        guard prefs.notificationsEnabled, !watchedResets.isEmpty else { return }
        let plan = NotificationScheduler.planResets(memory: alertMemory, watched: Array(watchedResets.values), now: now, options: alertOptions)
        watchedResets = plan.watched.reduce(into: [:]) { $0[AlertMemory.key($1.tool, $1.window)] = $1 }
        remember(plan.memory)
        send(plan.alerts)
        let passed = plan.alerts.filter { $0.stage == .reset }
        if !passed.isEmpty {
            removeNotifications(passed.flatMap { PaceAlert.identifiers(tool: $0.tool, window: $0.window) })
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
        let main = status(tool).reading.flatMap(Advisor.mainWindow(of:))
        return PollingInputs(
            baseInterval: base ?? providers[tool]?.refreshInterval ?? 60,
            screenLocked: screenLocked,
            asleep: asleep,
            screensAsleep: screensAsleep,
            onBattery: onBattery,
            lowPowerMode: lowPowerMode,
            minutesSinceLastAgentActivity: simulatedIdle.map { $0 / 60 } ?? lastActivity[tool].map { now.timeIntervalSince($0) / 60 },
            hookNudge: simulatedIdle == nil && (lastHook[tool].map { now.timeIntervalSince($0) < PollingPolicy.idleAfter } ?? false),
            secondsSinceStatusline: tool == .claude && base == nil ? statusline.flatMap { $0.windows.isEmpty ? nil : now.timeIntervalSince($0.receivedAt) } : nil,
            sessionInactive: sessionInactive,
            exhaustedUntil: main.flatMap { ($0.usedFraction ?? 0) >= 1 ? $0.resetsAt : nil },
            now: now
        )
    }

    /// One line for `--smoke`: the environment and each tool's cadence.
    func scheduleDescription() -> String {
        var parts = ["battery=\(onBattery)", "lowPower=\(lowPowerMode)", "locked=\(screenLocked)", "asleep=\(asleep)", "screensAsleep=\(screensAsleep)", "sessionInactive=\(sessionInactive)"]
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
        resetTimers[tool]?.cancel()
        resetTimers[tool] = nil
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
                let before = self.sessions
                self.sessions.expire(now: Date())
                if before != self.sessions { self.applyAwake() }
                self.checkResets()
            }
        }
    }

    private func sampleEnvironment() async {
        let activity = self.activity
        var sampled = await Task.detached(priority: .utility) { activity.sample() }.value
        for (tool, at) in lastHook where sampled[tool].map({ at > $0 }) ?? true { sampled[tool] = at }
        let battery = PowerSource.onBattery()
        let lowPower = PowerSource.lowPowerMode()
        let before = visibleTools.map { PollingPolicy.decide(pollingInputs(for: $0)) }
        if sampled != lastActivity { lastActivity = sampled }
        if battery != onBattery {
            onBattery = battery
            applyAwake()
        }
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
        observers.append(workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setSessionInactive(true) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setSessionInactive(false) }
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

    /// Fast user switching: the session behind another user's reads at the ceiling rather than pausing, because
    /// its agents keep running and its limits are the account's rather than the Mac's. The app may also have been
    /// launched straight into an inactive session, which sends no notification at all; `start()` seeds the flag
    /// from the window server for that, and `--smoke` sets it here directly, which it cannot otherwise simulate.
    func setSessionInactive(_ value: Bool) {
        guard sessionInactive != value else { return }
        sessionInactive = value
        Oracle.shared.emit("session", ["inactive": value])
        environmentChanged(delayed: !value)
    }

    var isSessionInactive: Bool { sessionInactive }

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

    // MARK: - Signals

    /// A waiting or finished colour must leave the rings when it stops being true, whether or not another hook
    /// event ever arrives. The state is already a pure function of the clock, so this timer is not what makes the
    /// answer right; it is what makes the screen ask again at the moment the answer changes, since `Date()` is not
    /// something the observation machinery can watch. Neither existing clock is fine enough — the environment tick
    /// is a minute and the reset sweep thirty seconds — and a ring holding a ninety-second state for two minutes
    /// would be telling the reader something that stopped being true while they were looking at it. One task for
    /// the whole app, armed for the earliest state still running and re-armed after it fires so several retire in
    /// turn; nothing is armed when nothing is on. The handle is dropped before the re-arm so the task cannot
    /// cancel itself on the way out.
    private func armSignalRelease(now: Date = Date()) {
        signalRelease?.cancel()
        guard let due = sessions.nextRelease(now: now) else { return }
        let interval = max(0.25, due.timeIntervalSince(now))
        signalRelease = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled, let self else { return }
            signalRelease = nil
            var expired = sessions
            expired.expire(now: Date())
            if expired != sessions { sessions = expired }
            armSignalRelease()
        }
    }

    // MARK: - Keep awake

    /// The rule in AwakeKeeper.swift over the working sessions and the power source; the app holds the assertion.
    func applyAwake() {
        let hold = AwakeRule.shouldHold(working: sessions.working.count, enabled: prefs.keepAwake, onBattery: onBattery, allowOnBattery: prefs.keepAwakeOnBattery)
        guard hold != keepingAwake else { return }
        keepingAwake = hold
        awakeChanged(hold)
    }

    // MARK: - The hooks (every assistant's) and Claude Code's status line

    /// Every event is activity for the tool that sent it; that tool's meter refreshes at most once every 30 s, and
    /// the session tracker keeps who is working, idle or waiting for the user. A remote host's event arrives here
    /// through the local API. The log line and the oracle name the tool only when it is not Claude Code, so
    /// Claude's output reads exactly as it always has.
    func hookReceived(_ message: Hook.Message, now: Date = Date()) {
        let tool = message.tool
        log.info("hook \(message.event, privacy: .public)\(tool == .claude ? "" : " (\(tool.rawValue))", privacy: .public)\(message.needsInput ? " (needs input)" : "", privacy: .public)\(message.host.map { " from \($0)" } ?? "", privacy: .public)")
        var facts: [String: Any] = ["name": message.event, "needsInput": message.needsInput, "session": message.sessionID as Any, "project": message.project as Any,
                                    "host": message.host as Any, "branch": message.branch as Any, "agent": message.agentID as Any, "failure": message.failure as Any]
        if tool != .claude { facts["tool"] = tool.rawValue }
        Oracle.shared.emit("hook", facts)
        lastHook[tool] = now
        lastActivity[tool] = now
        wokeAt = now
        let outcome = sessions.apply(message, now: now)
        applyAwake()
        armSignalRelease(now: now)
        if let waiting = outcome.startedWaiting, prefs.notifyWaiting {
            deliverSessionEvent(.waiting, waiting)
        }
        if !outcome.stoppedWaiting.isEmpty {
            removeNotifications(outcome.stoppedWaiting.map { Notifier.identifier(session: $0, kind: "waiting") })
        }
        if let finished = outcome.finished, prefs.notifyFinished, finished.turn >= TimeInterval(prefs.finishedAfterMinutes * 60) {
            deliverSessionEvent(.finished(turn: finished.turn), finished.session)
        }
        guard isShown(tool) else { return }
        if outcome.limitHit != nil, prefs.notificationsEnabled {
            let plan = NotificationScheduler.planLimitHit(memory: alertMemory, tool: tool, reading: status(tool).reading, now: now, options: alertOptions)
            remember(plan.memory)
            send(plan.alerts)
        }
        let urgent = outcome.limitHit != nil || outcome.quotaResumed
        if urgent || (lastHookRefresh[tool].map({ now.timeIntervalSince($0) >= Self.hookRefreshSpacing }) ?? true) {
            lastHookRefresh[tool] = now
            Task {
                await refresh(tool, force: true)
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
                                          "session": message.sessionID as Any, "model": message.model as Any, "branch": message.branch as Any])
        statusline = message
        lastHook[.claude] = now
        lastActivity[.claude] = now
        sessions.statusline(sessionID: message.sessionID, project: message.project, branch: message.branch, prURL: message.prURL, now: now)
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
