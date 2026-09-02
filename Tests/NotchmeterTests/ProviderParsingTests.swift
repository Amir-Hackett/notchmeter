import Foundation
import Testing
@testable import Notchmeter

@Suite struct ClaudeParsing {
    @Test func parsesSessionWeeklyAndScopedLimits() throws {
        let json = """
        {"five_hour":{"utilization":9.0,"resets_at":"2026-09-02T02:50:00.313Z"},
         "seven_day":{"utilization":3,"resets_at":"2026-09-03T21:00:00.313Z"},
         "seven_day_opus":null,"seven_day_sonnet":null,
         "nimbus_quill":{"utilization":0,"resets_at":"2026-09-03T21:00:00.313Z"},
         "limits":[{"kind":"weekly_scoped","percent":4,"resets_at":"2026-09-03T21:00:00.313Z","scope":{"model":{"display_name":"Fable"}}},
                   {"kind":"other","percent":50}],
         "extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null,"utilization":null}}
        """
        let reading = try ClaudeProvider.parseUsage(Data(json.utf8), plan: "Max 5x", now: Date(timeIntervalSince1970: 0))
        #expect(reading.windows.map(\.label) == ["Session", "Weekly", "Fable"])
        #expect(reading.windows.map(\.model) == [nil, nil, "Fable"])
        #expect(reading.windows[0].usedFraction == 0.09)
        #expect(reading.windows[0].periodDuration == Period.fiveHours)
        #expect(reading.windows[1].periodDuration == Period.week)
        #expect(reading.windows[2].usedFraction == 0.04)
        #expect(reading.windows[2].resetsAt == DateParsing.iso8601("2026-09-03T21:00:00.313Z"))
        #expect(reading.plan == "Max 5x")
    }

    @Test func legacyModelKeysAndExtraUsage() throws {
        let json = """
        {"five_hour":{"utilization":50,"resets_at":"2026-09-01T23:00:00Z"},
         "seven_day_sonnet":{"utilization":10,"resets_at":"2026-09-01T23:00:00Z"},
         "extra_usage":{"is_enabled":true,"monthly_limit":4000,"used_credits":1000,"utilization":25}}
        """
        let reading = try ClaudeProvider.parseUsage(Data(json.utf8), plan: nil)
        #expect(reading.windows.map(\.label) == ["Session", "Sonnet", "Extra usage"])
        #expect(reading.windows[2].usedFraction == 0.25)
        #expect(reading.windows[2].note == "$10.00 of $40")
    }

    @Test func rejectsEmptyResponse() {
        #expect(throws: ProviderError.self) {
            try ClaudeProvider.parseUsage(Data("{}".utf8), plan: nil)
        }
    }

    @Test func buildsWindowsFromUnifiedRateLimitHeaders() throws {
        let response = try #require(HTTPURLResponse(url: ClaudeProvider.usageURL, statusCode: 200, httpVersion: nil, headerFields: [
            "Anthropic-Ratelimit-Unified-5h-Utilization": "0.22",
            "anthropic-ratelimit-unified-5h-reset": "1786518600",
            "anthropic-ratelimit-unified-7d-utilization": " 0.03",
            "anthropic-ratelimit-unified-7d-reset": "1787058000",
            "anthropic-ratelimit-unified-overage-utilization": "0.0",
        ]))
        let windows = ClaudeProvider.rateLimitWindows(from: response)
        #expect(windows.map(\.label) == ["Session", "Weekly"])
        #expect(windows[0].id == "five_hour")
        #expect(windows[0].usedFraction == 0.22)
        #expect(windows[0].resetsAt == Date(timeIntervalSince1970: 1_786_518_600))
        #expect(windows[0].periodDuration == Period.fiveHours)
        #expect(windows[0].note == "From rate-limit headers")
        #expect(windows[1].usedFraction == 0.03)
        #expect(windows[1].resetsAt == Date(timeIntervalSince1970: 1_787_058_000))
        #expect(windows[1].periodDuration == Period.week)

        #expect(ClaudeProvider.rateLimitWindows { _ in nil }.isEmpty)
        let partial = ClaudeProvider.rateLimitWindows { $0 == "anthropic-ratelimit-unified-7d-utilization" ? "1.4" : nil }
        #expect(partial.map(\.usedFraction) == [1])
        #expect(partial[0].resetsAt == nil)
        #expect(ClaudeProvider.rateLimitWindows { _ in "n/a" }.isEmpty)
    }

    @Test func parsesCredentialsAndPlanTier() throws {
        let json = """
        {"claudeAiOauth":{"accessToken":"sk-ant-oat01-test","refreshToken":"x","expiresAt":1756771200000,"scopes":["user:inference"],"subscriptionType":"max","rateLimitTier":"default_claude_max_5x"}}
        """
        let credentials = try ClaudeProvider.parseCredentials(Data(json.utf8))
        #expect(credentials.accessToken == "sk-ant-oat01-test")
        #expect(credentials.expiresAt == Date(timeIntervalSince1970: 1_756_771_200))
        #expect(Naming.plan(subscriptionType: credentials.subscriptionType, rateLimitTier: credentials.rateLimitTier) == "Max 5x")
        #expect(Naming.plan(subscriptionType: "pro", rateLimitTier: nil) == "Pro")
        #expect(Naming.plan(subscriptionType: nil, rateLimitTier: "x") == nil)
    }
}

@Suite struct CodexParsing {
    @Test func parsesBackendWindows() throws {
        let json = """
        {"plan_type":"free","rate_limit":{"primary_window":{"used_percent":12,"reset_at":1759352940,"limit_window_seconds":18000},
                                          "secondary_window":null},
         "credits":{"has_credits":false,"unlimited":false,"balance":null}}
        """
        let reading = try CodexProvider.parseBackend(Data(json.utf8), now: Date(timeIntervalSince1970: 1_759_000_000))
        #expect(reading.plan == "Free")
        #expect(reading.windows.map(\.label) == ["Session", "Weekly"])
        #expect(reading.windows[0].usedFraction == 0.12)
        #expect(reading.windows[0].resetsAt == Date(timeIntervalSince1970: 1_759_352_940))
        #expect(reading.windows[0].periodDuration == 18000)
        #expect(reading.windows[1].usedFraction == nil)
        #expect(reading.windows[1].note == "No data")
    }

    @Test func classifiesWindowsByDuration() throws {
        let json = """
        {"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":40,"reset_at":1759352940,"limit_window_seconds":604800}}}
        """
        let reading = try CodexProvider.parseBackend(Data(json.utf8))
        #expect(reading.windows[0].note == "No data")
        #expect(reading.windows[1].label == "Weekly")
        #expect(reading.windows[1].usedFraction == 0.4)

        let monthly = """
        {"plan_type":"free","rate_limit":{"primary_window":{"used_percent":0,"reset_at":1759352940,"limit_window_seconds":2592000},"secondary_window":null}}
        """
        let free = try CodexProvider.parseBackend(Data(monthly.utf8))
        #expect(free.windows.map(\.label) == ["Session", "Monthly"])
        #expect(free.windows[1].periodDuration == 2_592_000)
        #expect(CodexProvider.windowKind(seconds: 14 * 86400, fallbackIsWeekly: false).label == "14-day")
    }

    @Test func parsesAuthWithAccountFromIdToken() throws {
        let payload = #"{"https://api.openai.com/auth":{"chatgpt_account_id":"acct_123"},"exp":1900000000}"#
        let encoded = Data(payload.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let json = """
        {"auth_mode":"chatgpt","tokens":{"access_token":"h.\(encoded).s","refresh_token":"r","id_token":"h.\(encoded).s"},"last_refresh":"2026-08-31T04:34:00Z"}
        """
        let auth = try CodexProvider.parseAuth(Data(json.utf8))
        #expect(auth.accountID == "acct_123")
        #expect(auth.expiresAt == Date(timeIntervalSince1970: 1_900_000_000))
        #expect(throws: ProviderError.self) {
            try CodexProvider.parseAuth(Data(#"{"OPENAI_API_KEY":"sk-x","tokens":null}"#.utf8))
        }
    }

    @Test func readsRolloutTailAndWindows() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-codex-\(UUID().uuidString)")
        let day = dir.appendingPathComponent("sessions/2026/09/01")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let rollout = day.appendingPathComponent("rollout-2026-09-01T10-00-00-abc.jsonl")
        let lines = [
            #"{"timestamp":"2026-09-01T10:00:00.000Z","type":"session_meta","payload":{"id":"abc"}}"#,
            #"{"timestamp":"2026-09-01T10:00:05.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":12.5,"window_minutes":300,"resets_at":1756725000},"secondary":{"used_percent":3,"window_minutes":10080,"resets_at":1757200000},"plan_type":"plus"}}}"#,
            #"{"timestamp":"2026-09-01T10:00:09.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":14,"window_minutes":300,"resets_at":1756725000},"secondary":{"used_percent":3.5,"window_minutes":10080,"resets_at":1757200000},"plan_type":"plus"}}}"#,
        ]
        try lines.joined(separator: "\n").write(to: rollout, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        let found = try #require(CodexProvider.latestRateLimits(in: rollout))
        #expect(found.observedAt == DateParsing.iso8601("2026-09-01T10:00:09.000Z"))
        let reading = try CodexProvider.reading(from: found.limits, observedAt: found.observedAt, now: Date(timeIntervalSince1970: 1_756_720_000))
        #expect(reading.windows.map(\.label) == ["Session", "Weekly"])
        #expect(reading.windows[0].usedFraction == 0.14)
        #expect(reading.windows[0].periodDuration == 18000)
        #expect(reading.plan == "Plus")
        let listed = CodexProvider.recentRollouts(in: dir.appendingPathComponent("sessions"), limit: 8)
        #expect(listed.map { $0.resolvingSymlinksInPath().path } == [rollout.resolvingSymlinksInPath().path])
    }

    @Test func labelsWindows() {
        #expect(CodexProvider.label(forMinutes: 300) == "Session")
        #expect(CodexProvider.label(forMinutes: 10080) == "Weekly")
        #expect(CodexProvider.label(forMinutes: 1440) == "1-day")
        #expect(CodexProvider.label(forMinutes: 90) == "90-minute")
    }
}

@Suite struct PaceProjection {
    let resetsAt = Date(timeIntervalSince1970: 100_000)

    @Test func projectsAtCurrentRate() throws {
        // 27% through a 5-hour window with 9% used → 33% projected → ~67% left.
        let period = Period.fiveHours
        let now = resetsAt.addingTimeInterval(-period * 0.73)
        let result = try #require(Pace.evaluate(usedFraction: 0.09, resetsAt: resetsAt, period: period, now: now))
        #expect(result.status == .ahead)
        #expect(abs(result.projectedFraction - 0.333) < 0.01)
        let window = LimitWindow(id: "s", label: "Session", usedFraction: 0.09, resetsAt: resetsAt, periodDuration: period)
        #expect(Pace.note(for: window, now: now)?.text == "~67% left at reset")
        #expect(abs((Pace.elapsedFraction(resetsAt: resetsAt, period: period, now: now) ?? 0) - 0.27) < 0.001)
    }

    @Test func flagsRunningOut() throws {
        let period = Period.fiveHours
        let now = resetsAt.addingTimeInterval(-period * 0.5)
        let result = try #require(Pace.evaluate(usedFraction: 0.8, resetsAt: resetsAt, period: period, now: now))
        #expect(result.status == .behind)
        let eta = try #require(Pace.secondsToRunOut(usedFraction: 0.8, resetsAt: resetsAt, period: period, now: now))
        #expect(abs(eta - period * 0.125) < 1)
    }

    @Test func tooEarlyOrExpiredGivesNothing() {
        #expect(Pace.evaluate(usedFraction: 0.5, resetsAt: resetsAt, period: Period.fiveHours, now: resetsAt.addingTimeInterval(-Period.fiveHours + 10)) == nil)
        #expect(Pace.evaluate(usedFraction: 0.5, resetsAt: resetsAt, period: Period.fiveHours, now: resetsAt.addingTimeInterval(5)) == nil)
    }
}

@Suite struct ResetFormatting {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }

    @Test func countdownAndExactTimes() throws {
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 19, minute: 10)))
        let tonight = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 22, minute: 50)))
        let thursday = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 3, hour: 17, minute: 0)))
        #expect(ResetText.line(resetsAt: tonight, hasLimit: true, display: .countdown, timeFormat: .auto, now: now, calendar: calendar) == "Resets in 3h 40m")
        #expect(ResetText.line(resetsAt: tonight, hasLimit: true, display: .exact, timeFormat: .twelveHour, now: now, calendar: calendar) == "Resets today at 10:50 PM")
        #expect(ResetText.line(resetsAt: thursday, hasLimit: true, display: .exact, timeFormat: .twentyFourHour, now: now, calendar: calendar) == "Resets Sep 3 at 17:00")
        #expect(ResetText.line(resetsAt: thursday, hasLimit: true, display: .countdown, timeFormat: .auto, now: now, calendar: calendar) == "Resets in 1d 21h")
        #expect(ResetText.line(resetsAt: nil, hasLimit: false, display: .exact, timeFormat: .auto, now: now, calendar: calendar) == "No limit published")
        #expect(ResetText.duration(45) == "45s")
    }
}

@Suite struct CostScanning {
    @Test func pricesAndDedupesTranscriptLines() throws {
        let line = #"{"type":"assistant","timestamp":"2026-09-01T15:00:00.000Z","requestId":"req_1","message":{"id":"msg_1","model":"claude-opus-4-1-20250805","usage":{"input_tokens":1000,"output_tokens":100,"cache_creation_input_tokens":200,"cache_read_input_tokens":50000}}}"#
        let entry = try #require(ClaudeCostScanner.parseLine(Data(line.utf8)))
        #expect(entry.tokens == TokenBreakdown(input: 1000, cacheWrite5m: 200, cacheWrite1h: 0, cacheRead: 50000, output: 100))
        #expect(entry.dedupeKey == "msg_1:req_1")
        let cost = try #require(ModelPricing.cost(of: entry.tokens, model: entry.model))
        // 1000 × $15 + 100 × $75 + 200 × $18.75 + 50000 × $1.50, all per million.
        #expect(abs(cost - (0.015 + 0.0075 + 0.00375 + 0.075)) < 1e-9)

        let file = Data("\(line)\n\(line)\n{\"type\":\"user\"}\n".utf8)
        let entries = ClaudeCostScanner.parseFile(file)
        #expect(entries.count == 2)
        #expect(ClaudeCostScanner.dedupe(entries).count == 1)
    }

    @Test func breaksDownCacheTiersAndSyntheticModels() throws {
        let line = #"{"timestamp":"2026-09-01T15:00:00Z","message":{"id":"m","model":"<synthetic>","usage":{"input_tokens":1,"output_tokens":2,"cache_creation":{"ephemeral_5m_input_tokens":10,"ephemeral_1h_input_tokens":20}}}}"#
        let entry = try #require(ClaudeCostScanner.parseLine(Data(line.utf8)))
        #expect(entry.model == nil)
        #expect(entry.tokens.cacheWrite5m == 10)
        #expect(entry.tokens.cacheWrite1h == 20)
        #expect(entry.dedupeKey == nil)
    }

    @Test func summarizesByLocalDay() {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 12))!
        let entries = [
            UsageEntry(timestamp: now.addingTimeInterval(-3600), model: "claude-sonnet-5", tokens: TokenBreakdown(input: 1_000_000), costUSD: nil, dedupeKey: nil),
            UsageEntry(timestamp: now.addingTimeInterval(-86400), model: nil, tokens: TokenBreakdown(output: 10), costUSD: 1.5, dedupeKey: nil),
            UsageEntry(timestamp: now.addingTimeInterval(-40 * 86400), model: "claude-sonnet-5", tokens: TokenBreakdown(input: 1_000_000), costUSD: nil, dedupeKey: nil),
            UsageEntry(timestamp: now, model: "claude-unknown-9", tokens: TokenBreakdown(input: 5), costUSD: nil, dedupeKey: nil),
        ]
        let summary = ClaudeCostScanner.summarize(entries, now: now, daysBack: 30)
        #expect(summary.today == 2.0)
        #expect(summary.yesterday == 1.5)
        #expect(summary.last30Days == 3.5)
        #expect(summary.daily.count == 30)
        #expect(summary.daily.last?.cost == 2.0)
        #expect(summary.unpricedModels == ["claude-unknown-9"])
    }

    @Test func normalizesModelIds() {
        #expect(ModelPricing.rates(for: "anthropic.claude-opus-4-5-20251101") == ModelPricing.opus5)
        #expect(ModelPricing.rates(for: "claude-fable-5-1") == ModelPricing.fable51)
        #expect(ModelPricing.rates(for: "claude-sonnet-4-5@20250929") == ModelPricing.sonnetLegacy)
        #expect(ModelPricing.rates(for: "claude-haiku-9") == ModelPricing.haiku45)
        #expect(ModelPricing.rates(for: "gpt-5") == nil)
    }
}
