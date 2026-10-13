import Foundation
import Testing
@testable import Notchmeter

final class DynamicProvider: UsageProvider, @unchecked Sendable {
    let tool: ToolID
    var result: Result<UsageReading, any Error>
    var refreshInterval: TimeInterval { 300 }

    init(tool: ToolID, result: Result<UsageReading, any Error>) {
        self.tool = tool
        self.result = result
    }

    func isInstalled() -> Bool { true }
    func fetch() async throws -> UsageReading {
        switch result {
        case .success(let r): return r
        case .failure(let e): throw e
        }
    }
}

/// Tests that UsageStore properly maps provider errors to tool statuses, adjusts backoffs,
/// tracks serverTrouble codes, and handles needsAttention transitions.
@MainActor
@Suite struct UsageStoreBackoffAndStatusTests {
    init() { Localization.use(language: "en") }

    func makeStore(tool: ToolID, result: Result<UsageReading, any Error>,
                   cached: UsageReading? = nil) -> (UsageStore, DynamicProvider, String) {
        let suite = "NotchmeterTests.UsageStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let prefs = Preferences(defaults: defaults)
        let provider = DynamicProvider(tool: tool, result: result)
        let store = UsageStore(prefs: prefs, providers: [provider], cache: ReadingCache(defaults: defaults),
                               defaults: defaults, drainLog: nil, reportFile: nil)
        if let cached {
            store.seed(readings: [cached], cost: .empty, nextUpdate: Date().addingTimeInterval(60), now: Date())
        }
        return (store, provider, suite)
    }

    func cleanup(suite: String) {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    @Test func needsAttentionErrorsSet60SecondBackoffAndStatus() async {
        let tool: ToolID = .codex
        let cached = UsageReading(tool: tool, windows: [
            LimitWindow(id: "session", label: "Session", usedFraction: 0.3, resetsAt: Date().addingTimeInterval(3600), periodDuration: Period.fiveHours)
        ], plan: nil, fetchedAt: Date(), observedAt: nil)

        let errors: [ProviderError] = [
            .notSignedIn("Please sign in"),
            .tokenExpired("Token has expired"),
            .accessDenied("Access denied by vendor"),
            .http(401, "Endpoint unauthorized"),
            .http(403, "Endpoint forbidden")
        ]

        for error in errors {
            let (store, _, suite) = makeStore(tool: tool, result: .failure(error), cached: cached)
            defer { cleanup(suite: suite) }

            await store.refresh(tool, force: true)
            let status = store.status(tool)

            #expect(error.needsAttention, "\(error) must be classified as needsAttention")
            #expect(status == .needsAttention(error.message, cached: cached))
            #expect(status.staleReading == cached)
            #expect(status.problem == error.message)
            #expect(store.backoffAfterLastRead(tool) == 60, "needsAttention errors must back off for exactly 60s")
            #expect(store.serverTrouble[tool] == nil, "Client refusals are not server trouble")
        }
    }

    @Test func serverErrorsRecordTroubleCodeAndProgressivelyDoubleBackoff() async {
        let tool: ToolID = .claude
        let (store, provider, suite) = makeStore(tool: tool, result: .failure(ProviderError.http(500, "Server error")))
        defer { cleanup(suite: suite) }

        // Initial failure: (15)*2 clamped to [30, 600] -> 30
        await store.refresh(tool, force: true)
        #expect(store.status(tool) == .failed("Server error (HTTP 500)", cached: nil))
        #expect(store.serverTrouble[tool] == 500)
        #expect(store.backoffAfterLastRead(tool) == 30)

        // Second failure: 30 * 2 -> 60
        provider.result = .failure(ProviderError.http(502, "Bad gateway"))
        await store.refresh(tool, force: true)
        #expect(store.serverTrouble[tool] == 502)
        #expect(store.backoffAfterLastRead(tool) == 60)

        // Third failure: 60 * 2 -> 120
        provider.result = .failure(ProviderError.http(503, "Service unavailable"))
        await store.refresh(tool, force: true)
        #expect(store.serverTrouble[tool] == 503)
        #expect(store.backoffAfterLastRead(tool) == 120)

        // Recovery: good reading clears serverTrouble and resets backoff
        let goodReading = UsageReading(tool: tool, windows: [
            LimitWindow(id: "five_hour", label: "Session", usedFraction: 0.1, resetsAt: Date().addingTimeInterval(3600), periodDuration: Period.fiveHours)
        ], plan: "Pro", fetchedAt: Date(), observedAt: nil)
        provider.result = .success(goodReading)
        await store.refresh(tool, force: true)

        #expect(store.status(tool) == .ready(goodReading))
        #expect(store.serverTrouble[tool] == nil, "Server trouble must be cleared on success")
        #expect(store.backoffAfterLastRead(tool) == 0, "Backoff must be cleared on success")
    }

    @Test func offlineErrorsDoubleBackoffClampedAt300() async {
        let tool: ToolID = .cursor
        let (store, _, suite) = makeStore(tool: tool, result: .failure(ProviderError.offline("Offline, retrying")))
        defer { cleanup(suite: suite) }

        // 1st: 15*2 -> 30
        await store.refresh(tool, force: true)
        #expect(store.status(tool) == .offline(cached: nil))
        #expect(store.backoffAfterLastRead(tool) == 30)

        // 2nd: 30*2 -> 60
        await store.refresh(tool, force: true)
        #expect(store.backoffAfterLastRead(tool) == 60)

        // 3rd: 60*2 -> 120
        await store.refresh(tool, force: true)
        #expect(store.backoffAfterLastRead(tool) == 120)

        // 4th: 120*2 -> 240
        await store.refresh(tool, force: true)
        #expect(store.backoffAfterLastRead(tool) == 240)

        // 5th: 240*2 -> 480, clamped to 300 ceiling
        await store.refresh(tool, force: true)
        #expect(store.backoffAfterLastRead(tool) == 300)

        // 6th: remains clamped at 300
        await store.refresh(tool, force: true)
        #expect(store.backoffAfterLastRead(tool) == 300)
    }

    @Test func generalURLErrorsMapToOfflineOrFailed() async {
        let tool: ToolID = .codex

        // Offline URLErrors
        let offlineCodes: [URLError.Code] = [
            .notConnectedToInternet,
            .networkConnectionLost,
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .dnsLookupFailed
        ]

        for code in offlineCodes {
            let (store, _, suite) = makeStore(tool: tool, result: .failure(URLError(code)))
            defer { cleanup(suite: suite) }

            await store.refresh(tool, force: true)
            #expect(store.status(tool) == .offline(cached: nil), "URLError code \(code) must map to .offline")
            #expect(store.backoffAfterLastRead(tool) == 30)
        }

        // Non-offline URLError (e.g. badServerResponse) maps to .failed
        let (storeFailed, _, suiteFailed) = makeStore(tool: tool, result: .failure(URLError(.badServerResponse)))
        defer { cleanup(suite: suiteFailed) }

        await storeFailed.refresh(tool, force: true)
        guard case .failed = storeFailed.status(tool) else {
            Issue.record("Expected .failed for badServerResponse, got \(storeFailed.status(tool))")
            return
        }
        #expect(storeFailed.backoffAfterLastRead(tool) == 30)
    }

    @Test func calmStatesDoNotBackOffExceptNotServed() async {
        let tool: ToolID = .gemini

        // apiKeyOnly: calm state, no backoff
        let (storeAPIKey, _, suite1) = makeStore(tool: tool, result: .failure(ProviderError.apiKeyOnly("No plan to meter")))
        defer { cleanup(suite: suite1) }
        await storeAPIKey.refresh(tool, force: true)
        #expect(storeAPIKey.status(tool) == .idle("No plan to meter"))
        #expect(storeAPIKey.backoffAfterLastRead(tool) == 0)

        // nothingYet: calm state, no backoff
        let (storeNothing, _, suite2) = makeStore(tool: tool, result: .failure(ProviderError.nothingYet("Nothing yet")))
        defer { cleanup(suite: suite2) }
        await storeNothing.refresh(tool, force: true)
        #expect(storeNothing.status(tool) == .idle("Nothing yet"))
        #expect(storeNothing.backoffAfterLastRead(tool) == 0)

        // notServed: calm state, but hourly backoff
        let (storeNotServed, _, suite3) = makeStore(tool: tool, result: .failure(ProviderError.notServed("Not served")))
        defer { cleanup(suite: suite3) }
        await storeNotServed.refresh(tool, force: true)
        #expect(storeNotServed.status(tool) == .idle("Not served"))
        #expect(storeNotServed.backoffAfterLastRead(tool) == UsageStore.notServedBackoff)
    }
}
