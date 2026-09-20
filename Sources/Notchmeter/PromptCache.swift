import Foundation

/// What Claude Code's status line says about a session's prompt cache (`prompt_cache`, Claude Code 2.1.251+; the
/// causes from 2.1.260): the misses it diagnosed, the tokens those misses wrote back, and why the last one
/// happened. Nothing here is inferred from a transcript: Claude Code counts a miss as a request that
/// re-processed content the cache already held (more than 5 % and at least 2,000 tokens of what could have been
/// read from cache, with no compaction or tool-result clearing to explain it) and names the cause it
/// diagnosed; Notchmeter carries the figures, prices the rewritten tokens at the session model's cache-write
/// rate, and adds nothing of its own (docs/accuracy.md, "The prompt cache").
struct PromptCacheStats: Equatable, Sendable {
    /// Requests that re-processed content the cache already held, this session.
    var misses: Int
    /// API requests recorded for the main conversation this session.
    var requests: Int?
    /// Tokens written to the cache by the requests counted as misses (`miss_recache_tokens`).
    var rewrittenTokens: Int
    /// Those tokens at the session model's cache-write rate for the cache's TTL; nil when the model is unpriced.
    var rewrittenUSD: Double?
    /// Cache read tokens over all input tokens this session, 0...1.
    var hitRatio: Double?
    /// The cause Claude Code diagnosed for the last miss: `tools_changed`, `system_prompt_changed`,
    /// `ttl_expired_5m`, `likely_server_side`; nil until the first miss or on a Claude Code before 2.1.260.
    var lastCause: String?
    var lastMissAt: Date?
    /// "5m" or "1h": which tier the cached prefix is on, and so which write rate the rewrite is priced at.
    var ttl: String?

    init(misses: Int, requests: Int? = nil, rewrittenTokens: Int, rewrittenUSD: Double? = nil, hitRatio: Double? = nil,
         lastCause: String? = nil, lastMissAt: Date? = nil, ttl: String? = nil) {
        self.misses = misses
        self.requests = requests
        self.rewrittenTokens = rewrittenTokens
        self.rewrittenUSD = rewrittenUSD
        self.hitRatio = hitRatio
        self.lastCause = lastCause
        self.lastMissAt = lastMissAt
        self.ttl = ttl
    }

    /// The status line's figures priced for the session's model.
    init(_ cache: Statusline.PromptCache, model: String?) {
        self.init(misses: cache.misses ?? 0, requests: cache.requests, rewrittenTokens: cache.missRecacheTokens ?? 0,
                  rewrittenUSD: PromptCache.price(tokens: cache.missRecacheTokens ?? 0, model: model, ttl: cache.ttl),
                  hitRatio: cache.hitRatio, lastCause: cache.lastMissCauses.first, lastMissAt: cache.lastMissAt, ttl: cache.ttl)
    }

    /// Misses over requests, 0...1; nil until a request has been counted.
    var missShare: Double? {
        guard let requests, requests > 0 else { return nil }
        return min(1, Double(misses) / Double(requests))
    }
}

/// The sessions' figures added up over a span: today for the Cost card and the report, the current 5-hour block
/// for the advice line.
struct PromptCacheSummary: Equatable, Sendable {
    var misses: Int
    var requests: Int
    var rewrittenTokens: Int
    /// The priced sessions' rewrites added up; nil when none of them could be priced.
    var rewrittenUSD: Double?
    /// The cause of the newest miss across the sessions.
    var lastCause: String?
    var sessions: Int

    var missShare: Double? {
        guard requests > 0 else { return nil }
        return min(1, Double(misses) / Double(requests))
    }
}

enum PromptCache {
    /// The rewritten tokens at the model's cache-write rate for the TTL the cache is on: the 1-hour write rate on
    /// the 1-hour tier, the 5-minute one otherwise (ModelPricing; the same multipliers the transcripts are priced
    /// with). nil when the model is unknown to the table, never a guess.
    static func price(tokens: Int, model: String?, ttl: String?) -> Double? {
        guard tokens > 0, let model, let rates = ModelPricing.rates(for: model) else { return nil }
        let perMillion = ttl == "1h" ? rates.cacheWrite1h : rates.cacheWrite5m
        return Double(tokens) * perMillion / 1_000_000
    }

    /// The Claude sessions heard from since `since`, added up. A session's figures are Claude Code's own running
    /// totals for that session, so a session that began before the span carries misses from before it; the
    /// summary is "the sessions active in the span", which is what both readers ask. nil when no session reports.
    static func summary(sessions: [AgentSession], since: Date) -> PromptCacheSummary? {
        var summary = PromptCacheSummary(misses: 0, requests: 0, rewrittenTokens: 0, rewrittenUSD: nil, lastCause: nil, sessions: 0)
        var newestMiss: Date?
        for session in sessions where session.tool == .claude && session.lastEvent >= since {
            guard let stats = session.promptCache else { continue }
            summary.sessions += 1
            summary.misses += stats.misses
            summary.requests += stats.requests ?? 0
            summary.rewrittenTokens += stats.rewrittenTokens
            if let usd = stats.rewrittenUSD { summary.rewrittenUSD = (summary.rewrittenUSD ?? 0) + usd }
            if let cause = stats.lastCause {
                let at = stats.lastMissAt ?? session.lastEvent
                if newestMiss.map({ at >= $0 }) ?? true {
                    newestMiss = at
                    summary.lastCause = cause
                }
            }
        }
        return summary.sessions > 0 ? summary : nil
    }

    /// The cause in words; an unlisted cause is shown as Claude Code names it rather than dropped.
    static func causeText(_ cause: String) -> String {
        switch cause {
        case "tools_changed": L("tools changed")
        case "system_prompt_changed": L("system prompt changed")
        case "ttl_expired_5m": L("5-minute cache expired")
        case "likely_server_side": L("likely server-side")
        default: cause
        }
    }

    /// What the user can do about the cause, where there is something.
    static func hint(for cause: String) -> String? {
        cause == "tools_changed" ? L("Your MCP server list is changing mid-session.") : nil
    }

    /// "310K tokens", or "310K tokens (~$0.93)" when the model priced.
    static func rewrittenText(tokens: Int, usd: Double?) -> String {
        let figure = Money.tokens(tokens)
        guard let usd else { return figure }
        return L("%1$@ (~%2$@)", figure, Money.dollars(usd))
    }

    /// "Prompt cache: 4 misses today · 310K tokens (~$0.93) rewritten · cause: tools changed".
    static func caption(_ summary: PromptCacheSummary) -> String {
        let misses = summary.misses == 1 ? L("1 miss") : L("%ld misses", summary.misses)
        var line = L("Prompt cache: %1$@ today · %2$@ rewritten", misses, rewrittenText(tokens: summary.rewrittenTokens, usd: summary.rewrittenUSD))
        if let cause = summary.lastCause { line += " · " + L("cause: %@", causeText(cause)) }
        return line
    }
}
