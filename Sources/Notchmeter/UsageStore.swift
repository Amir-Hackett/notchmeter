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
    let prefs: Preferences

    @ObservationIgnored private let providers: [ToolID: any UsageProvider]
    @ObservationIgnored private var loops: [ToolID: Task<Void, Never>] = [:]
    @ObservationIgnored private var inflight: Set<ToolID> = []
    @ObservationIgnored private var backoff: [ToolID: TimeInterval] = [:]
    @ObservationIgnored private var lastFetch: [ToolID: Date] = [:]
    @ObservationIgnored private let cache: ReadingCache
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private let costScanner = ClaudeCostScanner()
    @ObservationIgnored private var costLoop: Task<Void, Never>?

    init(prefs: Preferences, providers: [any UsageProvider] = ProviderRegistry.all(), cache: ReadingCache = ReadingCache()) {
        self.prefs = prefs
        self.cache = cache
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

    /// When the next scheduled provider read happens, for the footer.
    var nextUpdate: Date? {
        visibleTools.compactMap { nextRefresh[$0] }.min()
    }

    func start() {
        for tool in ToolID.allCases where isShown(tool) {
            startLoop(tool)
        }
        startCostLoop()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
    }

    func setEnabled(_ tool: ToolID, _ enabled: Bool) {
        if enabled {
            prefs.enabledTools.insert(tool)
            statuses[tool] = initialStatus(for: tool, cached: nil)
            startLoop(tool)
        } else {
            prefs.enabledTools.remove(tool)
            loops[tool]?.cancel()
            loops[tool] = nil
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
        let summary = await costScanner.scan()
        cost = summary
        costScanning = false
    }

    private func startCostLoop() {
        costLoop?.cancel()
        costLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshCost()
                try? await Task.sleep(for: .seconds(60))
            }
        }
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

    private func startLoop(_ tool: ToolID) {
        loops[tool]?.cancel()
        loops[tool] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(tool, force: true)
                let delay = (self.providers[tool]?.refreshInterval ?? 60) + (self.backoff[tool] ?? 0)
                self.nextRefresh[tool] = Date().addingTimeInterval(delay)
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func initialStatus(for tool: ToolID, cached: UsageReading?) -> ToolStatus {
        guard isInstalled(tool) else { return .notInstalled }
        guard prefs.enabledTools.contains(tool) else { return .off }
        if let cached { return .ready(cached) }
        return .waiting
    }
}
