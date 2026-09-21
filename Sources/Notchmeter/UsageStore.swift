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
    /// What GitHub last said about the Copilot seat's AI credits, for the same line on the card.
    private(set) var copilotCredits: CopilotCreditsRead?
    /// How many polls in a row each Antigravity window has read untouched, for the staleness guard.
    @ObservationIgnored private var antigravityRuns: [String: AntigravityStaleness.Run] = [:]
    /// The range the Cost card on the open panel is showing. It lived in the card as `@State` until 0.6.0, which
    /// left every other render of the card guessing: "Copy as image" on the whole panel rebuilt NotchExpandedView
    /// for the pasteboard, and the fresh card inside it opened on Today whatever the panel said, so a user reading
    /// $6,412 on 90d pasted a panel saying $118. The per-card copy was seeded by hand in 0.5.0; the panel copy
    /// could not be, because the action in App.swift cannot see a card's state. Held here, the live card writes
    /// it and every card built with no range of its own reads it, so a whole-panel render matches the panel
    /// without being told. Not a preference: it is not saved, and a launch starts on Today.
    var spendRange: SpendCard.Range = .today
    let prefs: Preferences

    @ObservationIgnored private let providers: [ToolID: any UsageProvider]
    @ObservationIgnored private var loops: [ToolID: Task<Void, Never>] = [:]
    @ObservationIgnored private var sleepers: [ToolID: Task<Void, Error>] = [:]
    @ObservationIgnored private var resetTimers: [ToolID: Task<Void, Never>] = [:]
    /// The read in progress for each tool, so a second one can wait for it rather than run beside it or be lost.
    @ObservationIgnored private var inflight: [ToolID: Task<Void, Never>] = [:]
    @ObservationIgnored private var backoff: [ToolID: TimeInterval] = [:]
    @ObservationIgnored private var lastFetch: [ToolID: Date] = [:]
    @ObservationIgnored private let cache: ReadingCache
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// The socket the hook and status-line commands write to (HookSocket.swift); nil until `start`, and in a
    /// sidecar run, which must never take the running app's socket from under it.
    @ObservationIgnored private var hookSocket: HookSocket.Listener?
    /// IOKit's mains/battery transition source (PowerSource.observeTransitions), held so it is not collected.
    @ObservationIgnored private var powerSourceWatch: CFRunLoopSource?
    @ObservationIgnored private var costEngine: CostEngine
    @ObservationIgnored private var activity: AgentActivity
    @ObservationIgnored private let drainLog: DrainLog?
    @ObservationIgnored private(set) var drainSamples: [DrainLog.Key: [DrainSample]] = [:]
    /// The drain log's boundary rows (DrainLog.Boundary), read once at launch; the newest Claude one floors the
    /// metering median (`meteringSince`).
    @ObservationIgnored private(set) var drainBoundaries: [DrainLog.Boundary] = []
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
    /// True while the panel is open because a request opened it (App.promptRequested on a compact panel): the
    /// panel then draws the request's card alone, and closes again when the request ends. A panel the pointer
    /// had already opened keeps everything and takes the card on top. Cleared by every collapse, and by the
    /// card's own *Show the whole panel*.
    var panelOpenedForPrompt = false
    /// The session a glance is about (SessionAttention.glance): while set, the panel draws its
    /// NoticeCard alone, the way `panelOpenedForPrompt` draws a request's. Cleared by every collapse and by the
    /// card's own *Show the whole panel*.
    var attentionNotice: AttentionNotice?
    /// A session began holding for a decision its hook is waiting on; wired to NotchActions.showPrompt by the app
    /// delegate, so the panel can open on the request.
    @ObservationIgnored var promptRequested: (AgentSession, PendingRequest) -> Void = { _, _ in }
    /// A request ended (answered, passed back, overtaken or timed out), by id; wired to NotchActions.promptEnded.
    @ObservationIgnored var promptEnded: (String) -> Void = { _ in }
    /// The socket replies parked on a decision, by request id. Only `decide` writes to one, which is what makes
    /// the request id a nonce: a line on the socket can start a request but never settle one (HookSocket.swift).
    @ObservationIgnored private var pendingReplies: [String: HookSocket.Reply] = [:]
    /// The app-side hold per request (Preferences.promptHoldSeconds), after which the request is passed back.
    @ObservationIgnored private var promptHolds: [String: Task<Void, Never>] = [:]
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
        copilotCredits = CopilotCreditsRead.load(from: defaults)
        let cached = cache.load()
        for tool in ToolID.allCases {
            statuses[tool] = initialStatus(for: tool, cached: cached[tool])
        }
        // Armed here rather than in `start`: the setting governs what the tracker holds whether or not the loops run.
        observeSessionTitles()
    }

    /// The tools on screen, in the user's order (Preferences.toolOrder), less the ones with nothing to show while
    /// `Preferences.hideEmptyTools` is on. Filtered here rather than in a view, because the panel's cards, the
    /// compact strip (`compactTools`), the footer, the presence rule and the Cost card's order check all read this
    /// one list and have to agree. The floor is WindowFloor's: a rule that hides everything shows the first one.
    var visibleTools: [ToolID] {
        let shown = prefs.toolOrder.filter(isShown)
        guard prefs.hideEmptyTools else { return shown }
        let kept = shown.filter { !isEmpty($0) }
        return kept.isEmpty ? Array(shown.prefix(1)) : kept
    }

    /// The tools `visibleTools` left out for having nothing to show, in the same order; empty while the setting is
    /// off. The panel's "Add a tool" row names them.
    var hiddenEmptyTools: [ToolID] {
        let visible = Set(visibleTools)
        return prefs.toolOrder.filter { isShown($0) && !visible.contains($0) }
    }

    /// Switched on and installed, and with nothing yet to put on a card: no reading at all (`ToolStatus.idle` — a
    /// tool set up with nothing to show, which is not a fault), no spend the cost scan found, and no session its
    /// hook has reported. A tool still waiting on its first read, or one with a problem to report, is not empty:
    /// there is something coming, or something to say.
    func isEmpty(_ tool: ToolID) -> Bool {
        status(tool).hasNothingYet && cost?.provider(tool) == nil && (sessions.knownCount(of: tool) ?? 0) == 0
    }

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
                                cursorUsageEvents: prefs.cursorUsageEvents, cursorExport: cursorExport, copilotCredits: copilotCredits,
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

    /// A vendor's page or a pull request, from the card. Only web links leave here: `AgentSession.prLink` already
    /// refuses anything else, but a pull request URL is the one string on this path that an untrusted process can
    /// supply, so the sink checks the scheme again rather than trusting every future caller to have done so (0.5.0).
    func openURL(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            Oracle.shared.emit("open", ["refused": url.scheme ?? ""])
            return
        }
        Oracle.shared.emit("open", ["host": url.host ?? url.absoluteString])
        NSWorkspace.shared.open(url)
    }

    /// Digits and dollar figures are withheld while the screen is shared and the privacy setting is on.
    var hidesFigures: Bool {
        prefs.hideFromScreenShare && screenCaptured
    }

    /// Readings the Advisor may steer by: live ones, plus the cached reading a rate-limit wait keeps on screen. A
    /// reading kept beside a fault (needsAttention, failed, offline) is left out; a 429 is a wait, not a fault, and
    /// its figures still drive the rings, the card and the JSON, so the advice strip should not empty on it. It did
    /// for the first cut of 0.5.0: a 429 used to launder the cache into `.ready` and every advice line stayed up,
    /// and marking it stale dropped the tool's lines for the whole backoff while the card under them kept the figure.
    var readyReadings: [UsageReading] {
        visibleTools.compactMap {
            switch status($0) {
            case .ready(let reading): return reading
            case .rateLimited(_, let cached): return cached
            default: return nil
            }
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
        // The current 5-hour block: the cost scan's block when it has one, else the five hours behind now.
        context.promptCache = promptCache(since: cost?.block?.start ?? now.addingTimeInterval(-Period.fiveHours))
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
                    sessions: sessions.all, history: history ? costEngine.claude.history?.load() : nil, promptCache: promptCacheToday, now: now)
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

    /// Titles off is titles gone: the titles and session names the tracker already holds are cleared the moment
    /// *Show what a session is working on* turns off, not at each session's next event, which for an idle
    /// session may never come (docs/hooks.md: with the setting off nothing of a prompt is held anywhere). The
    /// tracking is one-shot, so it re-arms; the preference alone is read inside it, so a hook event does not
    /// re-arm it.
    private func observeSessionTitles() {
        let titles = withObservationTracking {
            prefs.sessionTitles
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeSessionTitles() }
        }
        if !titles { sessions.clearTitles() }
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
            // The user just switched the tool on, so the loop's first read is theirs and may ask for the Keychain;
            // the timer reads that follow it never may.
            startLoop(tool, interactive: true)
        } else {
            prefs.enabledTools.remove(tool)
            stopLoop(tool)
            statuses[tool] = .off
            cache.remove(tool)
            // The watched resets went with nothing until 0.6.0, so a tool switched off at 90 % still announced its
            // reset from the thirty-second timer, and one switched back on after the reset announced a period that
            // had ended while it was off. The tool's pace notices go with the watch: the reset that would have
            // withdrawn them is no longer announced. The drop lives here rather than in `stopLoop`, which
            // `startLoop` calls on every restart and which must not lose a watch to a wake or a settings change.
            dropWatches { $0.tool == tool }
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
        for tool in visibleTools {
            Task { await refresh(tool, force: force, interactive: interactive) }
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
                                            sessionResetsAt: session?.resetsAt, sessionUsed: session?.usedFraction, meteringSince: meteringSince())
        cost = summary
        cursorExport = CursorExportRead.load(from: defaults)
        copilotCredits = CopilotCreditsRead.load(from: defaults)
        costScanning = false
        evaluateAlerts()
        writeReportIfDue()
    }

    /// Unforced refreshes are throttled so hovering the notch cannot hammer the APIs. While the Claude Code status
    /// line is reporting the same windows, the Claude read takes them from it and the endpoint is left alone.
    /// `interactive` marks a read the user asked for: it travels to the provider, where it is the one thing that
    /// may let the Keychain dialog appear (KeychainPromptPolicy), and it is the one kind of read that waits its
    /// turn behind a read already in flight rather than being dropped. A timer read that collides with one simply
    /// returns, as before: the figures it wanted are about to arrive anyway.
    func refresh(_ tool: ToolID, force: Bool = false, interactive: Bool = false) async {
        guard let provider = providers[tool], prefs.enabledTools.contains(tool) else { return }
        guard provider.isInstalled() else {
            statuses[tool] = .notInstalled
            return
        }
        if !force, let last = lastFetch[tool], Date().timeIntervalSince(last) < 60 { return }
        if let running = inflight[tool] {
            // A Refresh pressed while the poll was mid-fetch used to hit this guard and return having done
            // nothing, which for Claude Code meant the one read allowed to raise the Keychain dialog after a
            // token refresh had wiped the user's "Always Allow" never happened; the user pressed Refresh and
            // nothing changed. So an interactive read lets the running one finish and then goes itself. The one
            // wait plus the check after it bound this at a single re-run: if some other read has taken the slot in
            // the meantime, the figures are on their way and there is nothing left to add.
            guard interactive else { return }
            await running.value
            // The wait is an await like any other, and the guards above were checked before it. The user may have
            // switched the tool off while this read waited (setEnabled stops the loop but has no handle on a parked
            // press), or some other read may have taken the slot; either way there is nothing left for it to do.
            // Without the enabled check a Refresh pressed during the poll and followed by an untick started a full
            // read for the tool that is now off: for Claude Code that adopted the status line straight into `.ready`,
            // re-wrote the cache entry the untick had just cleared, or raised the Keychain dialog over the user's
            // work for a tool they no longer wanted read (0.5.0).
            guard inflight[tool] == nil, prefs.enabledTools.contains(tool), provider.isInstalled() else { return }
        }
        let read = Task { await self.read(tool, from: provider, interactive: interactive) }
        inflight[tool] = read
        await read.value
    }

    /// One read of the tool, start to finish; `refresh` decides whether it runs. Clearing `inflight` here, inside
    /// the task `refresh` stored, is what lets a read waiting on `running.value` find the slot empty when it wakes.
    private func read(_ tool: ToolID, from provider: any UsageProvider, interactive: Bool) async {
        defer { inflight[tool] = nil }
        if tool == .claude, let reading = statuslineReading() {
            adopt(reading)
            return
        }
        // With the endpoint switched off, the status line is the whole Claude source: a fresh one was adopted
        // above, a stale one leaves the last reading standing, and with none at all the card says calmly why.
        if tool == .claude, !prefs.pollClaudeEndpoint {
            if statuses[.claude]?.reading == nil {
                statuses[.claude] = .idle(L("Claude's usage endpoint is not polled; install the status line and run a turn for a reading"))
            }
            return
        }
        lastFetch[tool] = Date()

        let cached = statuses[tool]?.reading
        let outcome: Result<UsageReading, any Error>
        do {
            outcome = .success(try await provider.fetch(interactive: interactive))
        } catch {
            outcome = .failure(error)
        }
        // The user may have switched the tool off while this read was on the wire. setEnabled has already torn
        // the state down (.off, the cache entry removed, the loop stopped), and a reading adopted past this point
        // put every piece back: the cache entry the user had just cleared, a drain-log row for a tool they had
        // disabled, and a reset timer for it. The one check sits above the switch so that a failure cannot
        // overwrite `.off` with `.failed` either; the guard above the fetch checks the same thing, and anything
        // written after an `await` has to check it again.
        guard prefs.enabledTools.contains(tool) else { return }
        switch outcome {
        case .success(let reading):
            log.info("\(tool.displayName, privacy: .public) usage -> \(Probe.describe(reading), privacy: .public)")
            serverTrouble[tool] = nil
            adopt(reading)
        case .failure(let error as ProviderError):
            log.error("\(tool.displayName, privacy: .public) failed: \(error.message, privacy: .public)")
            if case .http(let code, _) = error, code >= 500 { serverTrouble[tool] = code } else { serverTrouble[tool] = nil }
            // The status is one mapping shared with the probe (ToolStatus.init(_:cached:)); only the backoff is
            // decided here, because only the store has a loop to back off.
            statuses[tool] = ToolStatus(error, cached: cached)
            if error.isCalm {
                backoff[tool] = 0
            } else if case .offline = error {
                backoff[tool] = min(300, max(30, (backoff[tool] ?? 15) * 2))
            } else if case .rateLimited(let retry) = error {
                // Transient: keep the last good numbers on screen, marked as the old numbers they are, and try again
                // later. This branch used to set `.ready(cached)`, which presented them as a live reading everywhere
                // (ToolStatus.rateLimited says where). The wait is clamped like its neighbours' because it is the
                // only one a vendor sets: a `Retry-After: 1800` was honoured verbatim and held the reading for half
                // an hour. The clamp is in rateLimitWait, so the log line above, the footer and the probe all name
                // the wait the app really takes.
                backoff[tool] = ProviderError.rateLimitWait(retryAfter: retry)
            } else if error.needsAttention {
                backoff[tool] = 60
            } else {
                backoff[tool] = min(600, max(30, (backoff[tool] ?? 15) * 2))
            }
        case .failure(let error):
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
            // The run is counted from the figure as read, before the guard strips it, so a pinned meter keeps
            // counting rather than restarting the moment it is first doubted (AntigravityStaleness).
            antigravityRuns = AntigravityStaleness.runs(after: reading, previous: antigravityRuns, now: now)
            reading = AntigravityStaleness.unverified(reading, runs: antigravityRuns, activeSince: lastActivity[.antigravity])
        }
        if reading.tool == .claude { noteExtraUsage(reading, now: now) }
        statuses[reading.tool] = .ready(reading)
        backoff[reading.tool] = 0
        cache.store(reading)
        lastUpdated = now
        recordDrain(reading, now: now)
        // The notification pipeline sees one instant per period for each window, not the reset as this read
        // reported it (`NotificationScheduler.canonicalReset`). Every notification embeds its window's reset in its
        // identifier, and a Codex snapshot's reset is measured from when the snapshot was written, so it moves by
        // a few seconds on every read. 0.5.0 pinned only the watched reset, and only against itself: the reminder
        // and the reset notice held steady, but the pace notices `evaluateAlerts` planned from the reading as it
        // came carried the moved instant, and `checkResets`, withdrawing by the pinned window's identifiers at the
        // reset, left them standing. The reading on the ring and in the cache stays as the vendor gave it; only
        // what is planned, watched and remembered from it is pinned.
        for window in NotificationScheduler.pinned(reading, memory: alertMemory, watched: watchedResets).windows {
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

    /// The session and weekly windows from a status line that can still stand in (`standsIn`), laid over the cached reading.
    private func statuslineReading(now: Date = Date()) -> UsageReading? {
        guard let statusline, statusline.standsIn(at: now) else { return nil }
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
    /// `nothingYet` seeds a tool as set up with nothing to show (`ToolStatus.idle`, keyed by its message), the
    /// state `hideEmptyTools` acts on, which a fixture reading cannot express.
    func seed(readings: [UsageReading], cost: CostSummary, nextUpdate: Date, sessions: SessionTracker = SessionTracker(),
              nothingYet: [ToolID: String] = [:], now: Date = Date()) {
        for reading in readings {
            statuses[reading.tool] = .ready(reading)
            nextRefresh[reading.tool] = nextUpdate
            lastActivity[reading.tool] = now
        }
        for (tool, message) in nothingYet {
            statuses[tool] = .idle(message)
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
            // The 2026-09-14 weekly-cap boundary, once; `appendBoundary` is idempotent, so every launch may ask.
            log.appendBoundary(tool: .claude, window: "seven_day", at: DrainLog.weeklyDenominatorChangedAt, note: "weekly cap changed")
            let boundaries = log.loadBoundaries()
            await MainActor.run { [weak self] in
                guard let self else { return }
                // The loops start the moment this task is spawned, and a reading can be adopted before the file
                // comes back, so what the store holds by now is not empty: fold the file into it rather than over it.
                drainSamples = DrainLog.merged(samples, with: drainSamples)
                drainBoundaries = boundaries
                recomputeDrains(now: now)
            }
        }
    }

    /// The newest Claude boundary on file, the floor under the metering median (ClaudeCostScanner.metering).
    func meteringSince(now: Date = Date()) -> Date? {
        DrainLog.latestBoundary(drainBoundaries, tool: .claude, now: now)
    }

    /// The Claude sessions' prompt-cache figures over today, for the Cost card and the report; nil while no session
    /// has reported a status line with `prompt_cache`, or while Claude is not shown.
    var promptCacheToday: PromptCacheSummary? {
        promptCache(since: Calendar.current.startOfDay(for: Date()))
    }

    func promptCache(since: Date) -> PromptCacheSummary? {
        guard isShown(.claude) else { return nil }
        return PromptCache.summary(sessions: sessions.all, since: since)
    }

    /// Internal rather than private so `DrainLogRules` can pin the statement order below, which is the whole bug.
    func recordDrain(_ reading: UsageReading, now: Date) {
        // The log skips a window whose figure has not moved since its last row, so it must be handed the samples as
        // they stood *before* this reading. Handing it the mutated dictionary made every window its own predecessor
        // — nothing ever moved, nothing was ever written, and the file was never created.
        let previous = drainSamples
        // The same skip applies in memory, so this dictionary stays a mirror of what `load` returns after a relaunch
        // rather than growing on every poll, and rows past the seven-day keep window leave from the front the way
        // they leave the file. Nothing downstream looks back further: the drain spans an hour, the sparkline a day,
        // the run-out estimate a week. Without the trim a month's uptime meant a third of a million samples that
        // `recomputeDrains` filtered afresh several times a minute.
        let cutoff = now.addingTimeInterval(-DrainLog.keepFor)
        for window in reading.windows {
            guard let used = window.usedFraction else { continue }
            let key = DrainLog.Key(tool: reading.tool, window: window.id)
            var samples = drainSamples[key] ?? []
            if DrainLog.moved(samples.last, used: used, resetsAt: window.resetsAt, now: now) {
                samples.append(DrainSample(t: now, used: used, resetsAt: window.resetsAt))
            }
            samples.removeFirst(samples.prefix { $0.t < cutoff }.count)
            drainSamples[key] = samples
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
            if let window = statuses[key.tool]?.reading?.windows.first(where: { $0.id == key.window }), !window.isComparison,
               let used = window.usedFraction, let resetsAt = window.resetsAt,
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
        var readings = readyReadings.map { NotificationScheduler.pinned($0, memory: alertMemory, watched: watchedResets) }
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
            if line.id == "prompt-cache" { return prefs.notifyPromptCache ? 86400 : nil }
            return nil
        }
        remember(lines.memory)
        if !lines.advice.isEmpty {
            for line in lines.advice { Oracle.shared.emit("notification", ["action": "scheduled", "title": line.text, "stage": "advice"]) }
            deliverAdvice(lines.advice)
        }
    }

    /// The timer's half: resets and reminders for windows that were nearly gone when last seen; the pace notices
    /// of a window that has reset are withdrawn. Only the tools on screen are checked: a watch belonging to a tool
    /// that is off or no longer installed is dropped here rather than kept, because a watch kept through an
    /// absence would announce, the moment the tool came back, a reset that passed while nobody was metering it.
    /// The next reading re-watches whatever is still worth watching. Internal, not private, so a test can drive
    /// the clock past a reset without the thirty-second timer.
    func checkResets(now: Date = Date()) {
        guard prefs.notificationsEnabled else { return }
        dropWatches { !isShown($0.tool) }
        guard !watchedResets.isEmpty else { return }
        let plan = NotificationScheduler.planResets(memory: alertMemory, watched: Array(watchedResets.values), now: now, options: alertOptions)
        watchedResets = plan.watched.reduce(into: [:]) { $0[AlertMemory.key($1.tool, $1.window)] = $1 }
        remember(plan.memory)
        send(plan.alerts)
        let passed = plan.alerts.filter { $0.stage == .reset }
        if !passed.isEmpty {
            removeNotifications(passed.flatMap { PaceAlert.identifiers(tool: $0.tool, window: $0.window) })
        }
    }

    /// Drops every watch that `dropped` selects and takes its period's pace notices down with it. A watch is the
    /// only thing that withdraws a window's notices (`checkResets`, once the reset has passed), so a watch dropped
    /// early, for a tool switched off or no longer installed, would otherwise leave a "running out" or "limit hit"
    /// banner in Notification Center for good: the tool's next period builds identifiers from its own reset and
    /// never matches the old ones. Until 0.6.0 the withdrawal rode on the reset announcement that a dropped watch
    /// wrongly kept making; now it happens at the drop, whether or not resets are announced at all.
    private func dropWatches(where dropped: (WatchedReset) -> Bool) {
        let gone = watchedResets.values.filter(dropped)
        guard !gone.isEmpty else { return }
        watchedResets = watchedResets.filter { !dropped($0.value) }
        removeNotifications(gone.flatMap { PaceAlert.identifiers(tool: $0.tool, window: $0.window) })
    }

    /// Takes down the "is waiting" notices of sessions that have stopped waiting, however they stopped: answered,
    /// ended, timed out or gone stale.
    private func withdrawWaiting(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        removeNotifications(ids.map { Notifier.identifier(session: $0, kind: "waiting") })
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
            secondsSinceStatusline: tool == .claude && base == nil ? statusline.flatMap { $0.standsIn(at: now) ? now.timeIntervalSince($0.receivedAt) : nil } : nil,
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

    /// `interactive` marks the loop's first read as one the user asked for (the Assistants toggle); the reads the
    /// timer takes after it are never interactive.
    private func startLoop(_ tool: ToolID, interactive: Bool = false) {
        stopLoop(tool)
        loops[tool] = Task { [weak self] in
            var interactive = interactive
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(tool, force: true, interactive: interactive)
                interactive = false
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
                self.sweepSessions()
                self.checkResets()
            }
        }
    }

    /// The clock's pass over the sessions: waits past ten minutes, finished marks past ninety seconds and sessions
    /// silent for four hours are retired (SessionTracker.expire), and the notices of any wait that ended this way
    /// are withdrawn. The tracker is copied out, expired, and written back only when the copy differs. `sessions`
    /// is a stored property of an `@Observable` class, and a `mutating` call straight on it goes through the
    /// generated accessor, which publishes to every observer whether or not the call changed a thing; an equality
    /// check after the fact is too late, the notification has already gone out. Until 0.5.0 the thirty-second
    /// sweep did exactly that, so with no assistant running and nothing to expire, every presenter on every screen
    /// re-measured the whole expanded card, reframed its window and rebuilt the menu bar item twice a minute for
    /// the life of the process, to arrive at the frame it already had. Both clocks that retire sessions, the sweep
    /// and `armSignalRelease`, come through here so neither can drift back to the in-place call. The awake
    /// assertion is re-applied on a change because a session dropped for silence may have been the last one working.
    /// The Sessions card's Remove (SessionTracker.dismiss): the row goes until the session sends another event.
    func dismissSession(_ id: String) {
        var tracker = sessions
        let result = tracker.dismiss(id)
        guard result.removed else { return }
        sessions = tracker
        if attentionNotice?.session.id == id { attentionNotice = nil }
        if result.wasWaiting { withdrawWaiting([id]) }
        applyAwake()
        Oracle.shared.emit("session", ["action": "dismissed", "session": id])
    }

    /// *Remove all idle sessions* from the card's menu.
    func dismissIdleSessions() {
        var tracker = sessions
        let removed = tracker.dismissIdle()
        guard !removed.isEmpty else { return }
        sessions = tracker
        applyAwake()
        Oracle.shared.emit("session", ["action": "dismissedIdle", "count": removed.count])
    }

    func sweepSessions(now: Date = Date()) {
        var expired = sessions
        let stopped = expired.expire(now: now)
        let nudged = expired.quietNudges(now: now)
        if expired != sessions {
            sessions = expired
            applyAwake()
        }
        withdrawWaiting(stopped)
        // A quiet Cursor turn (SessionTracker.quietNudges) is reported as a wait that may be one, through the same
        // notice, rules and attention setting as a wait a hook announced. As a blocking one: what it stands for is
        // an approval the turn has stopped for, and a non-blocking wait is held back while an editor is in front,
        // which for Cursor is exactly when it asks (the ten-minute ceiling on blocking banners still applies).
        if prefs.notifyWaiting {
            for session in nudged { deliverSessionEvent(.waiting(blocking: true), session) }
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
        setOnBattery(battery)
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
        // The power-state notification above is Low Power Mode, not the charger: nothing here heard the Mac
        // move to battery until 0.5.0, so `onBattery` was the minute tick's alone, and the tick is parked while
        // the display sleeps or the screen is locked. That is where an unattended run spends its time, so the
        // charger came out and the awake assertion kept holding on the last snapshot it had. IOKit tells us
        // directly, tick or no tick.
        powerSourceWatch = PowerSource.observeTransitions { [weak self] in
            Task { @MainActor in self?.setOnBattery(PowerSource.onBattery()) }
        }
        listenForHooks()
    }

    /// The hook and status-line commands reach the store over a socket only this app's own signature may write to
    /// (HookSocket.swift). Until 0.6.0 they were two distributed notifications, which any process of the same
    /// user could read as they went by and post in an assistant's name. The listener is the app's alone: a
    /// `--smoke` or `--probe` run beside the installed copy goes through this same `start`, and binding here would
    /// unlink the running app's socket and leave its hooks talking to a process about to exit, so a sidecar never
    /// listens. Delivery is on a background queue and hops to the main actor, as the observers did.
    private func listenForHooks(arguments: [String] = CommandLine.arguments) {
        guard hookSocket == nil, !SingleInstance.isSidecar(arguments: arguments) else { return }
        let listener = HookSocket.Listener { [weak self] message, reply in
            Task { @MainActor in
                guard let self else {
                    reply.answer(nil)
                    return
                }
                switch message {
                case .hook(let hook): self.hookReceived(hook, reply: reply)
                case .statusline(let line):
                    reply.answer(nil)
                    self.statuslineReceived(line)
                }
            }
        }
        listener.start()
        hookSocket = listener
    }

    /// Removes the socket at quit, so a hook that fires afterwards finds nothing rather than a file that refuses it.
    func stopListeningForHooks() {
        hookSocket?.stop()
        hookSocket = nil
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

    /// The one writer for `onBattery` after `start()`, fed by IOKit's transition callback and backstopped by the
    /// minute tick. The awake assertion is re-decided here because the power source is one of its two inputs and
    /// nothing else asks again when it moves; the loops are rescheduled because the cadence multiplier reads it
    /// too. Internal rather than private so a test can move the power source, which the hardware will not do on
    /// cue.
    func setOnBattery(_ value: Bool) {
        guard onBattery != value else { return }
        onBattery = value
        applyAwake()
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
            sweepSessions()
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
    /// Claude's output reads exactly as it always has. `reply` is the socket's end of a local event, parked while
    /// the message awaits a decision: it is kept under the request's id for `decide`, or answered nothing at once
    /// when the request is not going to be shown (answering from the notch is off, or the tracker did not take
    /// it). The title, the summary and the terminal never reach the log or the oracle (`hookFacts`).
    func hookReceived(_ message: Hook.Message, now: Date = Date(), reply: HookSocket.Reply? = nil) {
        var message = message
        if !prefs.sessionTitles { message.title = nil }
        if message.request != nil, !prefs.answerFromNotch {
            reply?.answer(nil)
            message.request = nil
        }
        let tool = message.tool
        log.info("hook \(message.event, privacy: .public)\(tool == .claude ? "" : " (\(tool.rawValue))", privacy: .public)\(message.needsInput ? " (needs input)" : "", privacy: .public)\(message.request.map { " (\($0.kind.name) request)" } ?? "", privacy: .public)\(message.host.map { " from \($0)" } ?? "", privacy: .public)")
        Oracle.shared.emit("hook", Self.hookFacts(message))
        lastHook[tool] = now
        lastActivity[tool] = now
        wokeAt = now
        let outcome = sessions.apply(message, now: now)
        applyAwake()
        armSignalRelease(now: now)
        // The withdrawal goes first because one message can end a wait and start another for the same session:
        // `apply` seeds stoppedWaiting from `expire`, so a needsInput arriving after its own wait timed out is
        // demoted and re-raised inside the one call, and both lists name it. Delivered first, the withdrawal took
        // the new banner straight back down — and the notifier had already spent that session's ten minutes on a
        // banner nobody saw. Withdrawn first, the notice standing for the wait that expired goes, and the new one
        // is what is left.
        withdrawWaiting(outcome.stoppedWaiting)
        for ended in outcome.requestsEnded { endRequest(ended.requestID) }
        if let requested = outcome.requested {
            let requestID = requested.request.id
            if let reply {
                // A Reply already parked under this id (a replayed line; the tracker refuses the duplicate, so
                // this is belt and braces) is released rather than left holding a slot for the whole cap.
                pendingReplies.updateValue(reply, forKey: requestID)?.answer(nil)
                reply.whenPeerCloses { [weak self] in
                    Task { @MainActor in self?.requestPeerGone(requestID) }
                }
            }
            holdPrompt(requestID)
            promptRequested(requested.session, requested.request)
        } else {
            reply?.answer(nil)
        }
        if let waiting = outcome.startedWaiting, prefs.notifyWaiting {
            deliverSessionEvent(.waiting(blocking: message.blocksSession), waiting)
        }
        if let finished = outcome.finished, prefs.notifyFinished, finished.turn >= TimeInterval(prefs.finishedAfterMinutes * 60) {
            deliverSessionEvent(.finished(turn: finished.turn), finished.session)
        }
        guard isShown(tool) else { return }
        if outcome.limitHit != nil, prefs.notificationsEnabled {
            let reading = status(tool).reading.map { NotificationScheduler.pinned($0, memory: alertMemory, watched: watchedResets) }
            let plan = NotificationScheduler.planLimitHit(memory: alertMemory, tool: tool, reading: reading, now: now, options: alertOptions)
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

    /// What the oracle records for a hook event: the event's name and shape, never the title, the summary, the
    /// detail, a question or the terminal. Static and pure so a test can pin the key set.
    nonisolated static func hookFacts(_ message: Hook.Message) -> [String: Any] {
        var facts: [String: Any] = ["name": message.event, "needsInput": message.needsInput, "session": message.sessionID as Any, "project": message.project as Any,
                                    "host": message.host as Any, "branch": message.branch as Any, "agent": message.agentID as Any, "failure": message.failure as Any]
        if message.tool != .claude { facts["tool"] = message.tool.rawValue }
        if let request = message.request { facts["request"] = request.kind.name }
        return facts
    }

    /// The user's answer to the request `requestID`, from the panel (or the hold running out, as a pass): the
    /// reply line goes to the hook's socket (`Hook.Answer.line`), the request leaves the session, the wait notice
    /// comes down, and the oracle records what was decided and never what about. Nothing happens for an id the
    /// app is not showing: that is the whole of the security model, since the id is a nonce the hook generated
    /// and a decision reaches the socket from here alone.
    func decide(_ requestID: String, _ decision: Decision, now: Date = Date()) {
        let kind = sessions.pending(now: now).first { $0.request.id == requestID }?.request.kindName
        let reply = pendingReplies.removeValue(forKey: requestID)
        promptHolds.removeValue(forKey: requestID)?.cancel()
        guard reply != nil || kind != nil else { return }
        // A line the socket could not take whole (the hook process went away between the worker's last look at
        // it and now) is a decision the assistant will never see: it is recorded as lost, and the session is left
        // waiting as for a pass, because the terminal is asking or has moved on, not acting on this.
        let delivered = reply.map { $0.answer(Hook.Answer.line(for: decision)) } ?? true
        let behavior = delivered ? decision.behavior : "lost"
        let session = sessions.resolve(requestID: requestID, resumes: delivered && decision != .pass, now: now)
        log.info("decision \(behavior, privacy: .public) for a \(kind ?? "gone", privacy: .public) request")
        Oracle.shared.emit("decision", ["request": requestID, "kind": kind as Any, "behavior": behavior, "session": session?.id as Any])
        if let session { withdrawWaiting([session.id]) }
        applyAwake()
        armSignalRelease(now: now)
        promptEnded(requestID)
    }

    /// The hook process behind `requestID` went away before the app answered (the socket's worker saw its
    /// connection go: the vendor cancelled the command, the turn was interrupted, an out-of-date entry's five
    /// seconds ran out): the card comes down, the hold is dropped and the session is left waiting, as after a
    /// pass, because the terminal is asking or has already gone on. Nothing for an id no longer parked.
    private func requestPeerGone(_ requestID: String, now: Date = Date()) {
        guard pendingReplies.removeValue(forKey: requestID) != nil else { return }
        let kind = sessions.pending(now: now).first { $0.request.id == requestID }?.request.kindName
        promptHolds.removeValue(forKey: requestID)?.cancel()
        let session = sessions.resolve(requestID: requestID, resumes: false, now: now)
        log.info("decision gone for a \(kind ?? "gone", privacy: .public) request: its hook went away unanswered")
        Oracle.shared.emit("decision", ["request": requestID, "kind": kind as Any, "behavior": "gone", "session": session?.id as Any])
        armSignalRelease(now: now)
        promptEnded(requestID)
    }

    /// A request that ended without the app deciding it: its parked reply is released with nothing, so the
    /// terminal asks, and the panel is told.
    private func endRequest(_ requestID: String) {
        pendingReplies.removeValue(forKey: requestID)?.answer(nil)
        promptHolds.removeValue(forKey: requestID)?.cancel()
        promptEnded(requestID)
    }

    /// Starts the app-side hold on a request: after `promptHoldSeconds` it is passed back to the terminal, well
    /// inside the socket's cap and the entries' timeouts.
    private func holdPrompt(_ requestID: String) {
        promptHolds[requestID]?.cancel()
        let seconds = TimeInterval(prefs.promptHoldSeconds)
        promptHolds[requestID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.decide(requestID, .pass)
        }
    }

    /// The status line's windows replace the endpoint's for as long as they keep arriving; the context fill and the
    /// session cost go to the Claude card.
    func statuslineReceived(_ message: Statusline.Message, now: Date = Date()) {
        // The figures, never the session's name: it is a title the user typed or Claude Code wrote.
        Oracle.shared.emit("statusline", ["context": message.contextUsed.map(Oracle.fraction) as Any, "windows": message.windows.map(\.id),
                                          "session": message.sessionID as Any, "model": message.model as Any, "branch": message.branch as Any,
                                          "cacheMisses": message.promptCache?.misses as Any])
        statusline = message
        lastHook[.claude] = now
        lastActivity[.claude] = now
        // The session's name is shown under the same setting as the prompt title (hookReceived drops that one).
        sessions.statusline(sessionID: message.sessionID, project: message.project, branch: message.branch, prURL: message.prURL,
                            model: message.model, sessionName: prefs.sessionTitles ? message.sessionName : nil,
                            linesAdded: message.linesAdded, linesRemoved: message.linesRemoved,
                            promptCache: message.promptCache, now: now)
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
