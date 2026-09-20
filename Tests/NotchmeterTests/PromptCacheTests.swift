import Foundation
import Testing
@testable import Notchmeter

/// The prompt-cache diagnostic: Claude Code's own figures priced and added up, the caption, the advice line and
/// its thresholds, the report object, the session it lands on. Nothing here infers a miss from a transcript.
@Suite struct PromptCacheDiagnostic {
    init() { Localization.use(language: "en") }

    let t0 = DateParsing.iso8601("2026-09-01T12:00:00Z")!

    func cache(misses: Int, requests: Int = 20, rewritten: Int, ttl: String? = "5m", cause: String? = nil, lastMissAt: Date? = nil) -> Statusline.PromptCache {
        var cache = Statusline.PromptCache()
        cache.misses = misses
        cache.requests = requests
        cache.missRecacheTokens = rewritten
        cache.ttl = ttl
        cache.lastMissCauses = cause.map { [$0] } ?? []
        cache.lastMissAt = lastMissAt
        return cache
    }

    func session(_ id: String, lastEvent: Date, tool: ToolID = .claude, stats: PromptCacheStats?) -> AgentSession {
        var session = AgentSession(id: id, tool: tool, project: "proj", state: .idle, started: lastEvent, lastEvent: lastEvent, turnStarted: nil)
        session.promptCache = stats
        return session
    }

    /// The rewrite is priced at the session model's cache-write rate for the tier the cache is on, and not at all
    /// for a model the table does not know: an unpriced figure is absent, never a guess.
    @Test func theRewriteIsPricedAtTheModelsCacheWriteRateForItsTier() throws {
        let opus = try #require(ModelPricing.rates(for: "Opus"))
        let fiveMinute = PromptCacheStats(cache(misses: 2, rewritten: 400_000, ttl: "5m"), model: "Opus")
        let expectedFiveMinute = 0.4 * opus.cacheWrite5m
        #expect(abs((fiveMinute.rewrittenUSD ?? 0) - expectedFiveMinute) < 1e-9)
        let oneHour = PromptCacheStats(cache(misses: 2, rewritten: 400_000, ttl: "1h"), model: "Opus")
        let expectedOneHour = 0.4 * opus.cacheWrite1h
        #expect(abs((oneHour.rewrittenUSD ?? 0) - expectedOneHour) < 1e-9)
        #expect(PromptCacheStats(cache(misses: 2, rewritten: 400_000), model: "mystery-9").rewrittenUSD == nil)
        #expect(PromptCacheStats(cache(misses: 2, rewritten: 400_000), model: nil).rewrittenUSD == nil)
        #expect(PromptCacheStats(cache(misses: 0, rewritten: 0), model: "Opus").rewrittenUSD == nil)
        #expect(fiveMinute.misses == 2)
        #expect(fiveMinute.rewrittenTokens == 400_000)
        #expect(fiveMinute.missShare == 0.1)
        #expect(PromptCacheStats(cache(misses: 1, requests: 0, rewritten: 10), model: "Opus").missShare == nil)
        let withCause = PromptCacheStats(cache(misses: 3, rewritten: 1000, cause: "tools_changed", lastMissAt: t0), model: "Opus")
        #expect(withCause.lastCause == "tools_changed")
        #expect(withCause.lastMissAt == t0)
    }

    /// The summary adds up the Claude sessions heard from in the span: another tool's session and one silent
    /// since before the span are left out, the price is the priced sessions' sum, and the cause is the newest miss's.
    @Test func theSummaryAddsUpTheClaudeSessionsHeardFromInTheSpan() {
        let recent = PromptCacheStats(misses: 2, requests: 10, rewrittenTokens: 100_000, rewrittenUSD: 0.5, lastCause: "ttl_expired_5m", lastMissAt: t0.addingTimeInterval(-60))
        let older = PromptCacheStats(misses: 1, requests: 5, rewrittenTokens: 50_000, rewrittenUSD: nil, lastCause: "tools_changed", lastMissAt: t0.addingTimeInterval(-3600))
        let stale = PromptCacheStats(misses: 9, requests: 9, rewrittenTokens: 900_000, rewrittenUSD: 9)
        let sessions = [
            session("a", lastEvent: t0, stats: recent),
            session("b", lastEvent: t0.addingTimeInterval(-1800), stats: older),
            session("c", lastEvent: t0.addingTimeInterval(-7200), stats: stale),
            session("d", lastEvent: t0, tool: .codex, stats: stale),
            session("e", lastEvent: t0, stats: nil),
        ]
        let summary = PromptCache.summary(sessions: sessions, since: t0.addingTimeInterval(-3600))
        #expect(summary?.misses == 3)
        #expect(summary?.requests == 15)
        #expect(summary?.rewrittenTokens == 150_000)
        #expect(summary?.rewrittenUSD == 0.5)
        #expect(summary?.lastCause == "ttl_expired_5m")
        #expect(summary?.sessions == 2)
        #expect(summary?.missShare == 0.2)
        #expect(PromptCache.summary(sessions: sessions, since: t0.addingTimeInterval(1)) == nil)
        #expect(PromptCache.summary(sessions: [session("e", lastEvent: t0, stats: nil)], since: t0.addingTimeInterval(-3600)) == nil)
        // A session without a miss timestamp dates its cause by its last event.
        let undated = PromptCacheStats(misses: 1, requests: 1, rewrittenTokens: 1, lastCause: "likely_server_side")
        let whole = PromptCache.summary(sessions: [session("a", lastEvent: t0, stats: recent), session("f", lastEvent: t0.addingTimeInterval(1), stats: undated)],
                                        since: t0.addingTimeInterval(-3600))
        #expect(whole?.lastCause == "likely_server_side")
    }

    @Test func theCaptionAndTheCausesReadAsWords() {
        let summary = PromptCacheSummary(misses: 4, requests: 31, rewrittenTokens: 310_400, rewrittenUSD: 0.93, lastCause: "tools_changed", sessions: 2)
        #expect(PromptCache.caption(summary) == "Prompt cache: 4 misses today · 310K tokens (~$0.93) rewritten · cause: tools changed")
        let one = PromptCacheSummary(misses: 1, requests: 3, rewrittenTokens: 812, rewrittenUSD: nil, lastCause: nil, sessions: 1)
        #expect(PromptCache.caption(one) == "Prompt cache: 1 miss today · 812 tokens rewritten")
        #expect(PromptCache.causeText("system_prompt_changed") == "system prompt changed")
        #expect(PromptCache.causeText("ttl_expired_5m") == "5-minute cache expired")
        #expect(PromptCache.causeText("likely_server_side") == "likely server-side")
        #expect(PromptCache.causeText("something_new") == "something_new")
        #expect(PromptCache.hint(for: "tools_changed") == "Your MCP server list is changing mid-session.")
        #expect(PromptCache.hint(for: "ttl_expired_5m") == nil)
    }

    /// Three misses in the block, or 200K tokens rewritten, earn the line; less earns nothing. The cause and, for a
    /// changing tool list, the hint follow the figures.
    @Test func theAdviceLineFiresOnThreeMissesOrTwoHundredThousandTokens() throws {
        var context = Advisor.Context(readings: [], now: t0)
        context.promptCache = PromptCacheSummary(misses: 3, requests: 12, rewrittenTokens: 120_000, rewrittenUSD: 0.42, lastCause: "tools_changed", sessions: 1)
        let line = try #require(Advisor.promptCache(context))
        #expect(line.id == "prompt-cache")
        #expect(line.tool == .claude)
        #expect(line.priority == .warn)
        #expect(line.text == "Your prompt cache missed 3 times — 120K tokens (~$0.42) rewritten. Cause: tools changed. Your MCP server list is changing mid-session.")
        #expect(Advisor.advise(context).map(\.id) == ["prompt-cache"])
        context.promptCache = PromptCacheSummary(misses: 2, requests: 12, rewrittenTokens: 199_999, rewrittenUSD: nil, lastCause: "ttl_expired_5m", sessions: 1)
        #expect(Advisor.promptCache(context) == nil)
        context.promptCache = PromptCacheSummary(misses: 2, requests: 12, rewrittenTokens: 200_000, rewrittenUSD: nil, lastCause: "ttl_expired_5m", sessions: 1)
        #expect(Advisor.promptCache(context)?.text == "Your prompt cache missed 2 times — 200K tokens rewritten. Cause: 5-minute cache expired.")
        context.promptCache = PromptCacheSummary(misses: 5, requests: 12, rewrittenTokens: 10_000, rewrittenUSD: nil, lastCause: nil, sessions: 1)
        #expect(Advisor.promptCache(context)?.text == "Your prompt cache missed 5 times — 10K tokens rewritten.")
        context.promptCache = nil
        #expect(Advisor.promptCache(context) == nil)
        // The banner's stand-in while the screen is shared carries no figure, like every other advice line's.
        let hidden = Notifier.body(for: line, hidingFigures: true)
        #expect(!hidden.contains { $0.isNumber })
        #expect(Notifier.body(for: line, hidingFigures: false) == line.text)
    }

    /// The tracker takes the status line's model, name, line counts and cache figures onto the session, pricing
    /// the rewrite at the session's model, and keeps what it held when a later line leaves a field out.
    @Test func theTrackerStoresTheStatusLinesFiguresOnTheSession() throws {
        var tracker = SessionTracker()
        tracker.statusline(sessionID: "s1", project: "proj", model: "Opus", sessionName: "fix the notch", linesAdded: 156, linesRemoved: 23,
                           promptCache: cache(misses: 2, rewritten: 400_000, ttl: "5m", cause: "tools_changed", lastMissAt: t0), now: t0)
        let session = try #require(tracker.all.first)
        #expect(session.model == "Opus")
        #expect(session.sessionName == "fix the notch")
        #expect(session.linesAdded == 156)
        #expect(session.linesRemoved == 23)
        let stats = try #require(session.promptCache)
        #expect(stats.misses == 2)
        #expect(stats.rewrittenTokens == 400_000)
        #expect(stats.lastCause == "tools_changed")
        let opus = try #require(ModelPricing.rates(for: "Opus"))
        let expected = 0.4 * opus.cacheWrite5m
        #expect(abs((stats.rewrittenUSD ?? 0) - expected) < 1e-9)
        tracker.statusline(sessionID: "s1", project: "proj", promptCache: cache(misses: 3, rewritten: 500_000), now: t0.addingTimeInterval(60))
        let later = try #require(tracker.all.first)
        #expect(later.model == "Opus")
        #expect(later.sessionName == "fix the notch")
        #expect(later.promptCache?.misses == 3)
        // Priced at the model the session already carried when the line names none.
        let expectedLater = 0.5 * opus.cacheWrite5m
        #expect(abs((later.promptCache?.rewrittenUSD ?? 0) - expectedLater) < 1e-9)
        #expect(PromptCache.summary(sessions: tracker.all, since: t0)?.misses == 3)
    }

    /// The store's own route: a status line lands on the tracker with its figures, and the session's name goes to
    /// no oracle fact.
    @MainActor @Test func theStoreHandsTheStatusLineToTheTracker() throws {
        let suite = "NotchmeterTests.promptCache.store"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(prefs: Preferences(defaults: defaults), providers: [], cache: ReadingCache(defaults: defaults), defaults: defaults,
                               drainLog: nil, reportFile: nil)
        var message = Statusline.Message(sessionID: "s2", project: "proj", model: "Opus", receivedAt: t0)
        message.sessionName = "a private title"
        message.promptCache = cache(misses: 4, rewritten: 1000, cause: "system_prompt_changed")
        store.statuslineReceived(message, now: t0)
        let session = try #require(store.sessions.all.first)
        #expect(session.id == "s2")
        #expect(session.sessionName == "a private title")
        #expect(session.promptCache?.misses == 4)
        #expect(session.promptCache?.lastCause == "system_prompt_changed")
        #expect(Preferences(defaults: defaults).notifyPromptCache)
    }

    /// The report's `promptCache` object, for the command-line tool, the MCP server and the status line's extras.
    @Test func theReportCarriesThePromptCacheObject() throws {
        let summary = PromptCacheSummary(misses: 4, requests: 32, rewrittenTokens: 310_400, rewrittenUSD: 0.93, lastCause: "tools_changed", sessions: 2)
        let report = UsageReport(tools: [:], cost: nil, advice: [], promptCache: summary, now: t0)
        let object = try #require(report.object["promptCache"] as? [String: Any])
        #expect(object["misses"] as? Int == 4)
        #expect(object["requests"] as? Int == 32)
        #expect(JSON.number(object["missShare"]) == 0.125)
        #expect(object["rewrittenTokens"] as? Int == 310_400)
        #expect(JSON.number(object["rewrittenUSD"]) == 0.93)
        #expect(object["lastCause"] as? String == "tools_changed")
        #expect(object["sessions"] as? Int == 2)
        #expect(UsageReport(tools: [:], cost: nil, advice: [], now: t0).object["promptCache"] == nil)
        #expect(Probe.describe(summary) == "prompt cache today: 4 misses of 32 requests (13%), 310K tokens rewritten (~$0.93), last cause tools_changed, 2 sessions")
        // Written by the app, read back by the status line's extras within the gate.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-cache-report-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("report-v1.json")
        try report.json.write(to: file)
        let extras = Statusline.Extras.read(reportFile: file, history: nil, now: t0.addingTimeInterval(60))
        #expect(extras.cacheMissShare == 0.125)
        #expect(Statusline.Extras.read(reportFile: file, history: nil, now: t0.addingTimeInterval(16 * 60)).cacheMissShare == nil)
    }
}
