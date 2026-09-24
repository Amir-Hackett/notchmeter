import Foundation
import Testing
@testable import Notchmeter

/// Claude Code's status line is the first source for Claude's session and weekly windows, and Anthropic's usage
/// endpoint the fallback: a fresh report means no endpoint read, a stale one means the endpoint as before. The one
/// exception is a slow read for what only the endpoint carries (PollingPolicy.endpointDue), and a Refresh the user
/// asked for.
@Suite struct StatuslineFirst {
    init() { Localization.use(language: "en") }

    static func endpointWindows(extra: Bool) -> [LimitWindow] {
        var windows = [
            LimitWindow(id: "five_hour", label: .key("Session"), usedFraction: 0.2, resetsAt: nil, periodDuration: Period.fiveHours),
            LimitWindow(id: "seven_day", label: .key("Weekly"), usedFraction: 0.1, resetsAt: nil, periodDuration: Period.week),
        ]
        if extra {
            windows.append(LimitWindow(id: "extra_usage", label: .key("Extra usage"), usedFraction: 0.05, resetsAt: nil, amountUSD: 2.5))
        }
        return windows
    }

    static func statusline(receivedAt: Date) -> Statusline.Message {
        let spec = Statusline.windowSpecs
        return Statusline.Message(windows: [Statusline.window(spec[0], used: 61, resetsAt: nil), Statusline.window(spec[1], used: 33, resetsAt: nil)],
                                  receivedAt: receivedAt)
    }

    @MainActor func store(suite: String, provider: CountingProvider) -> (UsageStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let prefs = Preferences(defaults: defaults)
        prefs.enabledTools.insert(.claude)
        let store = UsageStore(prefs: prefs, providers: [provider], cache: ReadingCache(defaults: defaults), defaults: defaults,
                               drainLog: nil, reportFile: nil)
        return (store, defaults)
    }

    /// A fresh status line and an endpoint that says nothing more: the timer's read, even a forced one, takes the
    /// status line's windows and never reaches the network.
    @MainActor @Test func aFreshStatusLineMeansNoEndpointRead() async {
        let suite = "NotchmeterTests.StatuslineFirst.fresh"
        let provider = CountingProvider(windows: Self.endpointWindows(extra: false))
        let (store, defaults) = store(suite: suite, provider: provider)
        defer { defaults.removePersistentDomain(forName: suite) }

        await store.refresh(.claude, force: true)
        #expect(await provider.fetches == [false], "no status line yet: the endpoint is the source")

        store.statuslineReceived(Self.statusline(receivedAt: Date()))
        await store.refresh(.claude, force: true)
        await store.refresh(.claude, force: true)
        #expect(await provider.fetches == [false], "a fresh status line leaves the endpoint alone")
        let session = store.status(.claude).reading?.windows.first { $0.id == "five_hour" }
        #expect(session?.source == .statusline)
        #expect(session?.usedFraction == 0.61)
    }

    /// A status line past its three minutes stands in for nothing, and the endpoint is read as it always was.
    @MainActor @Test func aStaleStatusLineFallsBackToTheEndpoint() async {
        let suite = "NotchmeterTests.StatuslineFirst.stale"
        let provider = CountingProvider(windows: Self.endpointWindows(extra: false))
        let (store, defaults) = store(suite: suite, provider: provider)
        defer { defaults.removePersistentDomain(forName: suite) }

        store.statuslineReceived(Self.statusline(receivedAt: Date().addingTimeInterval(-(PollingPolicy.statuslineFreshFor + 5))))
        await store.refresh(.claude, force: true)
        #expect(await provider.fetches == [false])
        let session = store.status(.claude).reading?.windows.first { $0.id == "five_hour" }
        #expect(session?.source == .vendorEndpoint)
        #expect(session?.usedFraction == 0.2)
    }

    /// A Refresh the user pressed reads the endpoint even beside a fresh status line, since the endpoint is the one
    /// source that can be asked; its answer goes under the status line's windows, not over them.
    @MainActor @Test func aRefreshTheUserAskedForStillReadsTheEndpoint() async {
        let suite = "NotchmeterTests.StatuslineFirst.interactive"
        let provider = CountingProvider(windows: Self.endpointWindows(extra: true))
        let (store, defaults) = store(suite: suite, provider: provider)
        defer { defaults.removePersistentDomain(forName: suite) }

        store.statuslineReceived(Self.statusline(receivedAt: Date()))
        await store.refresh(.claude, force: true)
        // No endpoint figure on record and no read yet this run: one read learns what the account carries.
        #expect(await provider.fetches == [false])
        await store.refresh(.claude, force: true)
        #expect(await provider.fetches == [false], "the extra-usage figure is not due again for half an hour")
        await store.refresh(.claude, force: true, interactive: true)
        #expect(await provider.fetches == [false, true])

        let windows = store.status(.claude).reading?.windows ?? []
        #expect(windows.first { $0.id == "five_hour" }?.source == .statusline)
        #expect(windows.first { $0.id == "seven_day" }?.usedFraction == 0.33)
        #expect(windows.first { $0.id == "extra_usage" }?.amountUSD == 2.5, "the endpoint's own figures are kept")
    }

    /// A read beside the status line that fails costs only the endpoint's extra figures: the card keeps the status
    /// line's reading rather than turning to an error.
    @MainActor @Test func aFailedReadBesideTheStatusLineKeepsTheCardReady() async {
        let suite = "NotchmeterTests.StatuslineFirst.failed"
        let provider = CountingProvider(windows: [], error: .rateLimited(retryAfter: 600))
        let (store, defaults) = store(suite: suite, provider: provider)
        defer { defaults.removePersistentDomain(forName: suite) }

        store.statuslineReceived(Self.statusline(receivedAt: Date()))
        await store.refresh(.claude, force: true, interactive: true)
        #expect(await provider.fetches == [true])
        guard case .ready(let reading) = store.status(.claude) else {
            Issue.record("expected the status line's reading, got \(store.status(.claude))")
            return
        }
        #expect(reading.windows.first { $0.id == "five_hour" }?.source == .statusline)
    }

    /// The rule itself: never for an endpoint that adds nothing, half-hourly for one that does, once at the start
    /// when nothing from the endpoint is on record.
    @Test func theEndpointIsDueOnlyForWhatTheStatusLineDoesNotCarry() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let carried = Self.statusline(receivedAt: now).windows
        let plain = UsageReading(tool: .claude, windows: Self.endpointWindows(extra: false), plan: nil, fetchedAt: now, observedAt: nil)
        let extra = UsageReading(tool: .claude, windows: Self.endpointWindows(extra: true), plan: nil, fetchedAt: now, observedAt: nil)
        let onlyStatusline = UsageReading(tool: .claude, windows: carried, plan: nil, fetchedAt: now, observedAt: nil)
        let read = now.addingTimeInterval(-60)

        #expect(PollingPolicy.endpointDue(besideStatusline: carried, reading: plain, lastEndpointRead: read, now: now) == nil)
        #expect(PollingPolicy.endpointDue(besideStatusline: carried, reading: plain, lastEndpointRead: nil, now: now) == nil)
        #expect(PollingPolicy.endpointDue(besideStatusline: carried, reading: extra, lastEndpointRead: read, now: now)
            == read.addingTimeInterval(PollingPolicy.endpointBesideStatusline))
        #expect(PollingPolicy.endpointDue(besideStatusline: carried, reading: extra, lastEndpointRead: nil, now: now)! <= now)
        #expect(PollingPolicy.endpointDue(besideStatusline: carried, reading: onlyStatusline, lastEndpointRead: nil, now: now) == now)
        #expect(PollingPolicy.endpointDue(besideStatusline: carried, reading: nil, lastEndpointRead: read, now: now) == nil, "an answer with nothing more settles it")
        #expect(PollingPolicy.endpointDue(besideStatusline: carried, reading: nil, lastEndpointRead: read, lastReadFailed: true, now: now)
            == read.addingTimeInterval(PollingPolicy.endpointBesideStatusline), "a failed discovery read is tried again on the half-hour")
        #expect(PollingPolicy.endpointDue(besideStatusline: carried, reading: onlyStatusline, lastEndpointRead: read, now: now) == nil)
        // A payload without the weekly window leaves the endpoint's weekly as something only it supplies.
        #expect(PollingPolicy.endpointDue(besideStatusline: Array(carried.prefix(1)), reading: plain, lastEndpointRead: read, now: now) != nil)
    }

    /// A reset on a window only the endpoint carries brings the read forward to it: the status line cannot say the
    /// per-model weekly reset, so the used-up figure would otherwise ride past its reset for up to half an hour.
    @Test func aResetOnAnEndpointOnlyWindowIsDueAtOnce() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let carried = Self.statusline(receivedAt: now).windows
        let read = now.addingTimeInterval(-600)
        func reading(resetsAt: Date) -> UsageReading {
            let opus = LimitWindow(id: "scoped_opus", label: .key("Weekly"), usedFraction: 1, resetsAt: resetsAt, periodDuration: Period.week)
            return UsageReading(tool: .claude, windows: Self.endpointWindows(extra: false) + [opus], plan: nil, fetchedAt: now, observedAt: nil)
        }
        #expect(PollingPolicy.endpointDue(besideStatusline: carried, reading: reading(resetsAt: now.addingTimeInterval(-5)), lastEndpointRead: read, now: now) == now)
        let soon = now.addingTimeInterval(120)
        #expect(PollingPolicy.endpointDue(besideStatusline: carried, reading: reading(resetsAt: soon), lastEndpointRead: read, now: now) == soon)
        // A reset the last read already saw past is not due again.
        #expect(PollingPolicy.endpointDue(besideStatusline: carried, reading: reading(resetsAt: read.addingTimeInterval(-60)), lastEndpointRead: read, now: now)
            == read.addingTimeInterval(PollingPolicy.endpointBesideStatusline))
    }
}

/// Installed, answers at once, and remembers each read and whether the user asked for it.
actor CountingProvider: UsageProvider {
    nonisolated let tool: ToolID = .claude
    let windows: [LimitWindow]
    let error: ProviderError?
    private(set) var fetches: [Bool] = []

    init(windows: [LimitWindow], error: ProviderError? = nil) {
        self.windows = windows
        self.error = error
    }

    nonisolated var refreshInterval: TimeInterval { 300 }
    nonisolated func isInstalled() -> Bool { true }

    func fetch() async throws -> UsageReading { try await fetch(interactive: false) }

    func fetch(interactive: Bool) async throws -> UsageReading {
        fetches.append(interactive)
        if let error { throw error }
        return UsageReading(tool: .claude, windows: windows, plan: nil, fetchedAt: Date(), observedAt: nil)
    }
}
