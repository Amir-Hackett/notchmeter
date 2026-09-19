import Foundation
import Testing
@testable import Notchmeter

/// What `UsageStore.refresh` does about the reads it cannot see across its `await`. Its preconditions are checked
/// before the fetch; the state they describe can change while the fetch is on the wire, and two of the findings
/// against 0.4.7 were reads that acted on the state as it had been.
@Suite struct RefreshRaces {
    init() { Localization.use(language: "en") }

    @MainActor func store(suite: String, provider: ParkedProvider) -> (UsageStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let prefs = Preferences(defaults: defaults)
        let store = UsageStore(prefs: prefs, providers: [provider], cache: ReadingCache(defaults: defaults), defaults: defaults,
                               drainLog: nil, reportFile: nil)
        return (store, defaults)
    }

    /// A Refresh pressed while a timer read was mid-fetch used to return at the in-flight guard having done
    /// nothing. For Claude Code that was the one read allowed to raise the Keychain dialog, and the permission
    /// went with it: it lived in a process-wide flag that the timer read's `defer` then cleared, so pressing
    /// Refresh changed nothing, repeatedly. The permission now travels with the read, and an interactive read
    /// waits for the running one and then goes itself; a colliding timer read still just returns.
    @MainActor @Test func anInteractiveRefreshWaitsForTheReadInFlightRatherThanBeingDropped() async {
        let suite = "NotchmeterTests.RefreshRaces.interactive"
        let provider = ParkedProvider(tool: .claude)
        let (store, defaults) = store(suite: suite, provider: provider)
        defer { defaults.removePersistentDomain(forName: suite) }

        let timer = Task { await store.refresh(.claude, force: true) }
        #expect(await provider.fetchesBegun(1))
        // A second timer read finds the first in flight and leaves it to finish.
        await store.refresh(.claude, force: true)
        #expect(await provider.interactives == [false])

        let pressed = Task { await store.refresh(.claude, force: true, interactive: true) }
        await Task.yield()
        // The press is waiting, not reading beside the timer read.
        #expect(await provider.interactives == [false])
        await provider.release()
        await timer.value
        #expect(await provider.fetchesBegun(2))
        await provider.release()
        await pressed.value

        let expected = [false, true]
        #expect(await provider.interactives == expected)
        #expect(store.status(.claude) == .ready(provider.reading))
    }

    /// The user turns a tool off while its read is on the wire. setEnabled tears the state down at once; the read
    /// then completes, and used to run the whole adopt path against it: the cache entry the user had just cleared
    /// was written back, a drain row was logged for a tool they had disabled, and the status went from `.off` to
    /// `.ready`. The read now checks the switch again once the fetch is back, and a disabled tool's answer is dropped.
    @MainActor @Test func aReadThatOutlivesTheSwitchIsDropped() async {
        let suite = "NotchmeterTests.RefreshRaces.disabled"
        let provider = ParkedProvider(tool: .cursor)
        let (store, defaults) = store(suite: suite, provider: provider)
        defer { defaults.removePersistentDomain(forName: suite) }

        let read = Task { await store.refresh(.cursor, force: true) }
        #expect(await provider.fetchesBegun(1))
        store.setEnabled(.cursor, false)
        #expect(store.status(.cursor) == .off)
        await provider.release()
        await read.value

        #expect(store.status(.cursor) == .off)
        #expect(ReadingCache(defaults: defaults).load()[.cursor] == nil)
        #expect(!store.prefs.enabledTools.contains(.cursor))
    }

    /// The user switches the tool off while a Refresh is waiting behind the timer read. setEnabled stops the loop
    /// but has no handle on the parked press, so it wakes to an empty slot; it must check the switch again rather
    /// than go, because the tool is off, and for Claude Code that read could raise the Keychain dialog. The wait
    /// was the one await in `refresh` whose preconditions were not re-checked after it (0.5.0).
    @MainActor @Test func aWaitingRefreshDoesNotStartForAToolSwitchedOffMeanwhile() async {
        let suite = "NotchmeterTests.RefreshRaces.disabledWhileWaiting"
        let provider = ParkedProvider(tool: .cursor)
        let (store, defaults) = store(suite: suite, provider: provider)
        defer { defaults.removePersistentDomain(forName: suite) }

        let timer = Task { await store.refresh(.cursor, force: true) }
        #expect(await provider.fetchesBegun(1))
        let pressed = Task { await store.refresh(.cursor, force: true, interactive: true) }
        await Task.yield()
        store.setEnabled(.cursor, false)
        await provider.release()
        await timer.value
        // The press must never reach the provider: this wait is expected to give up. Once it has, a read that did
        // start late passes straight through rather than parking for ever, so `pressed` still finishes.
        let pressBegan = await provider.fetchesBegun(2)
        #expect(!pressBegan, "the press's read must not start for a tool switched off while it waited")
        await provider.release()
        await pressed.value

        // One read only, the timer's; the press never reached the provider.
        let expected = [false]
        #expect(await provider.interactives == expected)
        #expect(store.status(.cursor) == .off)
        #expect(ReadingCache(defaults: defaults).load()[.cursor] == nil)
    }
}

/// Installed, and every read parks until the test lets it go, remembering whether it was asked for by the user.
actor ParkedProvider: UsageProvider {
    let tool: ToolID
    let reading: UsageReading
    private(set) var interactives: [Bool] = []
    private var parked: [CheckedContinuation<Void, Never>] = []

    init(tool: ToolID) {
        self.tool = tool
        reading = UsageReading(tool: tool, windows: [
            LimitWindow(id: "session", label: "Session", usedFraction: 0.3, resetsAt: nil),
        ], plan: nil, fetchedAt: Date(), observedAt: nil)
    }

    nonisolated var refreshInterval: TimeInterval { 300 }
    nonisolated func isInstalled() -> Bool { true }

    func fetch() async throws -> UsageReading { try await fetch(interactive: false) }

    func fetch(interactive: Bool) async throws -> UsageReading {
        interactives.append(interactive)
        // A read that arrives after the test gave up waiting for it returns at once rather than parking: nothing
        // will call `release` for it any more, and a continuation nobody resumes is a test that never ends.
        if abandoned { return reading }
        await withCheckedContinuation { parked.append($0) }
        return reading
    }

    /// Whether `fetchesBegun` has given up on a read; from then on reads pass straight through (see `fetch`).
    private var abandoned = false

    /// Returns once `count` reads have started, so the test can act while one is on the wire, and says whether they
    /// did. Bounded: a read that never comes returns false after a thousand yields instead of hanging the run, and
    /// from then on any late read passes straight through `fetch` rather than parking where no `release` will reach
    /// it. The one test that expects a read *not* to start asserts the false; the others assert the true, so a store
    /// that dropped a read fails at the line that waited for it rather than at some later one.
    @discardableResult
    func fetchesBegun(_ count: Int) async -> Bool {
        for _ in 0..<1000 where interactives.count < count {
            await Task.yield()
        }
        let begun = interactives.count >= count
        if !begun { abandoned = true }
        return begun
    }

    /// Lets every parked read return its reading.
    func release() {
        let waiting = parked
        parked = []
        for continuation in waiting { continuation.resume() }
    }
}
