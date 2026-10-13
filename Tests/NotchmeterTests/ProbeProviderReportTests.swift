import Foundation
import Testing
@testable import Notchmeter

/// What `--probe --json` writes for the five tools that meter a plan by windows (Codex, Cursor, Antigravity, Gemini,
/// Copilot), and which errors the app asks the user to fix (`ProviderError.needsAttention`) rather than retry.
@Suite struct ProbeProviderReport {
    init() { Localization.use(language: "en") }

    let now = DateParsing.iso8601("2026-10-07T12:00:00Z")!

    func window(_ id: String, _ label: WindowLabel, used: Double?, resetsIn: TimeInterval? = 3600, period: TimeInterval? = nil, model: String? = nil,
                source: WindowSource = .vendorEndpoint) -> LimitWindow {
        LimitWindow(id: id, label: label, usedFraction: used, resetsAt: resetsIn.map { now.addingTimeInterval($0) }, periodDuration: period, model: model, source: source)
    }

    func reading(_ tool: ToolID, plan: String?, _ windows: [LimitWindow]) -> UsageReading {
        UsageReading(tool: tool, windows: windows, plan: plan, fetchedAt: now, observedAt: nil)
    }

    func tools(_ report: UsageReport) throws -> [[String: Any]] {
        let object = try #require(try JSONSerialization.jsonObject(with: report.json) as? [String: Any])
        return try #require(object["tools"] as? [[String: Any]])
    }

    func entry(_ list: [[String: Any]], _ tool: ToolID) throws -> [String: Any] {
        try #require(list.first { $0["tool"] as? String == tool.rawValue })
    }

    var fiveTools: [ToolID: ToolStatus] {
        [
            .codex: .ready(reading(.codex, plan: "Plus", [window("five_hour", "Session", used: 0.42, resetsIn: 7200, period: 5 * 3600),
                                                        window("weekly", "Weekly", used: 0.1, resetsIn: 6 * 86400, period: 7 * 86400)])),
            .cursor: .ready(reading(.cursor, plan: "Pro", [window("included", "Included", used: 0.25, resetsIn: 20 * 86400, period: 30 * 86400)])),
            .antigravity: .ready(reading(.antigravity, plan: "AI Pro", [window("session", "Session", used: 0.9, resetsIn: 3600, period: 5 * 3600, model: "Gemini 3 Pro")])),
            .gemini: .ready(reading(.gemini, plan: nil, [window("pro", .vendor("Pro"), used: 0, resetsIn: 86400, model: "gemini-3-pro")])),
            .copilot: .ready(reading(.copilot, plan: "Pro+", [window("premium", "Premium requests", used: 0.5, resetsIn: 10 * 86400, period: 30 * 86400)])),
        ]
    }

    @Test func everyToolGetsOneEntryInTheOrderGiven() throws {
        let order: [ToolID] = [.codex, .cursor, .antigravity, .gemini, .copilot]
        let report = UsageReport(tools: fiveTools, order: order, cost: nil, advice: [], now: now)
        let list = try tools(report)
        #expect(list.compactMap { $0["tool"] as? String } == order.map(\.rawValue))
        #expect(list.allSatisfy { $0["status"] as? String == "ready" })
        #expect(list.allSatisfy { $0["stale"] as? Bool == false })
        #expect(try entry(list, .antigravity)["name"] as? String == "Antigravity")
    }

    @Test func aToolMissingFromTheStatusesIsLeftOutRatherThanInvented() throws {
        var statuses = fiveTools
        statuses[.gemini] = nil
        let list = try tools(UsageReport(tools: statuses, order: [.codex, .gemini, .copilot], cost: nil, advice: [], now: now))
        #expect(list.compactMap { $0["tool"] as? String } == ["codex", "copilot"])
    }

    @Test func eachWindowCarriesItsIdLabelFractionAndReset() throws {
        let list = try tools(UsageReport(tools: fiveTools, order: [.codex], cost: nil, advice: [], now: now))
        let codex = try entry(list, .codex)
        #expect(codex["plan"] as? String == "Plus")
        let windows = try #require(codex["windows"] as? [[String: Any]])
        #expect(windows.compactMap { $0["id"] as? String } == ["five_hour", "weekly"])
        #expect(windows.compactMap { $0["label"] as? String } == ["Session", "Weekly"])
        #expect(JSON.number(windows[0]["usedFraction"]) == 0.42)
        #expect(windows[0]["resetsAt"] as? String == "2026-10-07T14:00:00.000Z")
        #expect(windows[0]["periodDuration"] as? Int == 5 * 3600)
        #expect(windows[0]["source"] as? String == "vendorEndpoint")
        #expect(windows[0]["hiddenByDefault"] as? Bool == false)
    }

    @Test func aVendorsModelAndLabelPassThroughUntranslated() throws {
        let list = try tools(UsageReport(tools: fiveTools, order: [.gemini, .antigravity], cost: nil, advice: [], now: now))
        let gemini = try #require((try entry(list, .gemini)["windows"] as? [[String: Any]])?.first)
        #expect(gemini["label"] as? String == "Pro")
        #expect(gemini["model"] as? String == "gemini-3-pro")
        #expect(JSON.number(gemini["usedFraction"]) == 0, "an exhausted-to-untouched zero is a number, not a missing figure")
        let antigravity = try #require((try entry(list, .antigravity)["windows"] as? [[String: Any]])?.first)
        #expect(antigravity["model"] as? String == "Gemini 3 Pro")
    }

    @Test func aWindowWithNoFigureIsNullNotZero() throws {
        let status = ToolStatus.ready(reading(.cursor, plan: "Business", [window("spend", "Spend", used: nil, resetsIn: nil)]))
        let list = try tools(UsageReport(tools: [.cursor: status], order: [.cursor], cost: nil, advice: [], now: now))
        let only = try #require((try entry(list, .cursor)["windows"] as? [[String: Any]])?.first)
        #expect(only["usedFraction"] is NSNull)
        #expect(only["resetsAt"] is NSNull)
    }

    @Test func fractionsAreWrittenAsShortDecimalsNotBinaryDoubles() throws {
        let status = ToolStatus.ready(reading(.copilot, plan: nil, [window("premium", "Premium requests", used: 0.1 + 0.2)]))
        let text = String(decoding: UsageReport(tools: [.copilot: status], order: [.copilot], cost: nil, advice: [], now: now).json, as: UTF8.self)
        #expect(text.contains("\"usedFraction\" : 0.3"))
        #expect(!text.contains("0.30000000000000004"))
    }

    @Test func theJSONIsSchemaVersionedAndSortedSoItDiffs() throws {
        let report = UsageReport(tools: fiveTools, order: [.codex, .copilot], cost: nil, advice: [], now: now)
        let object = try #require(try JSONSerialization.jsonObject(with: report.json) as? [String: Any])
        #expect(object["schema"] as? String == "notchmeter.limits.v1")
        #expect(object["generatedAt"] as? String == "2026-10-07T12:00:00.000Z")
        #expect(report.json == report.json)
        let text = String(decoding: report.json, as: UTF8.self)
        let keys = ["\"advice\"", "\"exitCode\"", "\"generatedAt\"", "\"schema\"", "\"sessions\"", "\"tools\""]
        let positions = try keys.map { try #require(text.range(of: $0)?.lowerBound) }
        #expect(positions == positions.sorted())
    }

    // MARK: - Exit codes

    @Test func theExitCodeFollowsTheTightestWindowAcrossTools() {
        func code(_ statuses: [ToolID: ToolStatus]) -> UsageReport.ExitCode {
            UsageReport(tools: statuses, order: Array(statuses.keys), cost: nil, advice: [], now: now).exitCode
        }
        #expect(code([:]) == .noData)
        #expect(code([.codex: .needsAttention("Sign in", cached: nil), .gemini: .notInstalled]) == .noData)
        #expect(code([.codex: .ready(reading(.codex, plan: nil, [window("w", "Weekly", used: 0, resetsIn: 86400)])),
                      .cursor: .ready(reading(.cursor, plan: nil, [window("m", "Monthly", used: 0, resetsIn: 86400)]))]) == .noSession)
        #expect(code([.copilot: .ready(reading(.copilot, plan: nil, [window("m", "Monthly", used: 0.3, resetsIn: 86400 * 20)]))]) != .noData)
        #expect(code([.antigravity: .ready(reading(.antigravity, plan: nil, [window("s", "Session", used: 0.85, resetsIn: 3600)]))]) == .nearLimit)
        #expect(code([.codex: .ready(reading(.codex, plan: nil, [window("s", "Session", used: 0.2, resetsIn: 3600)])),
                      .gemini: .ready(reading(.gemini, plan: nil, [window("p", "Pro", used: 1, resetsIn: 3600)]))]) == .limitHit)
    }

    @Test func aWindowWithoutAFigureNeverCountsTowardTheExitCode() {
        let status = ToolStatus.ready(reading(.cursor, plan: nil, [window("spend", "Spend", used: nil)]))
        #expect(UsageReport(tools: [.cursor: status], order: [.cursor], cost: nil, advice: [], now: now).exitCode == .noData)
    }

    // MARK: - Needs attention

    @Test func aRefusedLoginReadsNeedsAttentionWithItsStaleReadingKept() throws {
        let cached = reading(.antigravity, plan: "AI Pro", [window("session", "Session", used: 0.4)])
        let status = ToolStatus(.tokenExpired("Antigravity's login has expired"), cached: cached)
        let list = try tools(UsageReport(tools: [.antigravity: status], order: [.antigravity], cost: nil, advice: [], now: now))
        let entry = try entry(list, .antigravity)
        #expect(entry["status"] as? String == "needsAttention")
        #expect(entry["problem"] as? String == "Antigravity's login has expired")
        #expect(entry["stale"] as? Bool == true)
        #expect((entry["windows"] as? [[String: Any]])?.count == 1)
    }

    @Test func aColdNeedsAttentionHasAProblemAndNoWindows() throws {
        let status = ToolStatus(.notSignedIn("Sign in to Codex (run `codex login`) to read your usage"), cached: nil)
        let entry = try entry(try tools(UsageReport(tools: [.codex: status], order: [.codex], cost: nil, advice: [], now: now)), .codex)
        #expect(entry["status"] as? String == "needsAttention")
        #expect(entry["problem"] as? String == "Sign in to Codex (run `codex login`) to read your usage")
        #expect(entry["windows"] == nil)
        #expect(entry["stale"] == nil)
    }

    @Test func aCalmStateIsIdleWithANoteAndNoProblem() throws {
        let status = ToolStatus(.notServed("Google no longer serves Gemini CLI quota for personal accounts"), cached: nil)
        let entry = try entry(try tools(UsageReport(tools: [.gemini: status], order: [.gemini], cost: nil, advice: [], now: now)), .gemini)
        #expect(entry["status"] as? String == "idle")
        #expect(entry["note"] as? String == "Google no longer serves Gemini CLI quota for personal accounts")
        #expect(entry["problem"] is NSNull)
    }

    @Test func everyProviderErrorIsClassifiedAsExactlyOneKind() {
        let errors: [(ProviderError, attention: Bool, calm: Bool)] = [
            (.notSignedIn("x"), true, false), (.tokenExpired("x"), true, false), (.accessDenied("x"), true, false),
            (.parse("x"), false, false), (.unavailable("x"), false, false), (.offline("x"), false, false),
            (.rateLimited(retryAfter: nil), false, false), (.rateLimited(retryAfter: 90), false, false),
            (.http(401, "x"), true, false), (.http(403, "x"), true, false),
            (.http(400, "x"), false, false), (.http(404, "x"), false, false), (.http(500, "x"), false, false), (.http(0, "x"), false, false),
            (.nothingYet("x"), false, true), (.apiKeyOnly("x"), false, true), (.notServed("x"), false, true),
        ]
        for (error, attention, calm) in errors {
            #expect(error.needsAttention == attention, "\(error)")
            #expect(error.isCalm == calm, "\(error)")
            #expect(!(error.needsAttention && error.isCalm), "a state is a fault to fix or a calm one, never both: \(error)")
        }
    }

    @Test func anUnclassifiedRefusalStillAsksForASignInRatherThanRetrying() {
        let cached = reading(.copilot, plan: nil, [window("m", "Monthly", used: 0.3)])
        #expect(ToolStatus(.http(401, "GitHub's Copilot endpoint answered"), cached: cached)
                == .needsAttention("GitHub's Copilot endpoint answered (HTTP 401)", cached: cached))
        #expect(ToolStatus(.http(403, "Codex usage endpoint answered"), cached: nil) == .needsAttention("Codex usage endpoint answered (HTTP 403)", cached: nil))
        #expect(ToolStatus(.http(503, "Cursor usage endpoint answered"), cached: nil) == .failed("Cursor usage endpoint answered (HTTP 503)", cached: nil))
    }

    @Test func aTransportFailureIsOfflineNeverNeedsAttention() {
        for code in [URLError.Code.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed, .timedOut] {
            let error = ProviderError.offline(from: URLError(code))
            #expect(error?.needsAttention == false)
            #expect(error.map { ToolStatus($0, cached: nil) } == .offline(cached: nil))
        }
        #expect(ProviderError.offline(from: URLError(.badServerResponse)) == nil)
        #expect(ProviderError.offline(from: URLError(.userAuthenticationRequired)) == nil)
    }

    @Test func narrowingReportToSingleToolPreservesOnlyThatTool() throws {
        let order: [ToolID] = [.codex, .cursor, .antigravity, .gemini, .copilot]
        let report = UsageReport(tools: fiveTools, order: order, cost: nil, advice: [], now: now)
        let codexReport = report.limited(to: .codex)
        let list = try tools(codexReport)
        #expect(list.count == 1)
        #expect(list[0]["tool"] as? String == "codex")
        #expect(list[0]["name"] as? String == "Codex")

        let geminiReport = report.limited(to: .gemini)
        let geminiList = try tools(geminiReport)
        #expect(geminiList.count == 1)
        #expect(geminiList[0]["tool"] as? String == "gemini")
    }

    @Test func probeReportIncludesPaceWhenBehind() throws {
        let behindWindow = window("session", "Session", used: 0.9, resetsIn: 3600, period: 5 * 3600)
        let reading = reading(.antigravity, plan: "Pro", [behindWindow])
        let report = UsageReport(tools: [.antigravity: .ready(reading)], order: [.antigravity], cost: nil, advice: [], now: now)
        let list = try tools(report)
        let entry = try entry(list, .antigravity)
        let windows = try #require(entry["windows"] as? [[String: Any]])
        #expect(windows[0]["pace"] as? String == "behind")
        #expect(windows[0]["projectedFraction"] != nil)
    }

    @Test func probeReportIncludesDrainsAndRunOutIntervals() throws {
        let key = DrainLog.Key(tool: .codex, window: "five_hour")
        let drain = Drain(from: 0.15, to: 0.42, over: 3600)
        let runOut = RunOutInterval(earliest: 1800, latest: 5400, sampleCount: 12)
        let report = UsageReport(
            tools: fiveTools,
            order: [.codex],
            cost: nil,
            advice: [],
            drains: [key: drain],
            runOuts: [key: runOut],
            now: now
        )
        let list = try tools(report)
        let codex = try entry(list, .codex)
        let windows = try #require(codex["windows"] as? [[String: Any]])
        let sessionWindow = try #require(windows.first { $0["id"] as? String == "five_hour" })

        let drainObject = try #require(sessionWindow["drainLastHour"] as? [String: Any])
        #expect(JSON.number(drainObject["from"]) == 0.15)
        #expect(JSON.number(drainObject["to"]) == 0.42)
        #expect(JSON.number(drainObject["perHour"]) == 0.27)

        let runOutObject = try #require(sessionWindow["runOut"] as? [String: Any])
        #expect(runOutObject["earliestAt"] as? String == "2026-10-07T12:30:00.000Z")
        #expect(runOutObject["latestAt"] as? String == "2026-10-07T13:30:00.000Z")
        #expect(runOutObject["samples"] as? Int == 12)
    }

    @Test func probeReportIncludesSessionsAndTheirMetadata() throws {
        var session = AgentSession(
            id: "ses_abc123",
            tool: .claude,
            project: "notchmeter",
            state: .working(since: now.addingTimeInterval(-120)),
            started: now.addingTimeInterval(-300),
            lastEvent: now,
            turnStarted: now.addingTimeInterval(-120),
            branch: "feat/probe-tests",
            prURL: "https://github.com/ascendmaui/notchmeter/pull/7",
            permissionMode: "plan"
        )
        session.source = .hook
        let report = UsageReport(
            tools: fiveTools,
            order: [.codex],
            cost: nil,
            advice: [],
            sessions: [session],
            now: now
        )
        let object = try #require(JSONSerialization.jsonObject(with: report.json) as? [String: Any])
        let sessions = try #require(object["sessions"] as? [[String: Any]])
        #expect(sessions.count == 1)
        #expect(sessions[0]["id"] as? String == "ses_abc123")
        #expect(sessions[0]["tool"] as? String == "claude")
        #expect(sessions[0]["project"] as? String == "notchmeter")
        #expect(sessions[0]["state"] as? String == "working")
        #expect(sessions[0]["stateSeconds"] as? Int == 120)
        #expect(sessions[0]["branch"] as? String == "feat/probe-tests")
        #expect(sessions[0]["pr"] as? String == "https://github.com/ascendmaui/notchmeter/pull/7")
        #expect(sessions[0]["permissionMode"] as? String == "plan")
        #expect(sessions[0]["source"] as? String == "hook")
    }

    @Test func probeReportIncludesCostAdviceAndPromptCache() throws {
        let todayTotals = RangeTotals(cost: 4.50, tokens: TokenBreakdown(input: 10_000, output: 500), priceSources: [.builtIn("2026-10-07")])
        let monthTotals = RangeTotals(cost: 85.00, tokens: TokenBreakdown(input: 200_000, output: 10_000), priceSources: [.builtIn("2026-10-07")])
        let claudeCost = ProviderCost(
            tool: .claude,
            source: .localTranscripts,
            ranges: [.today: todayTotals, .last30Days: monthTotals],
            daily: [],
            scannedAt: now
        )
        let cost = CostSummary(
            today: 4.50,
            yesterday: 3.20,
            last30Days: 85.00,
            daily: [],
            lastHour: 0.50,
            typicalHourly: 0.40,
            burnMultiple: 1.25,
            unpricedModels: [],
            scannedAt: now,
            ranges: [.today: todayTotals, .last30Days: monthTotals],
            providers: [claudeCost]
        )
        let advice = [
            Advice(id: "adv_1", tool: .antigravity, priority: .warn, symbol: "clock", text: "Approaching 5h reset", url: URL(string: "https://antigravity.google/limits"))
        ]
        let promptCache = PromptCacheSummary(
            misses: 4,
            requests: 20,
            rewrittenTokens: 1200,
            rewrittenUSD: 0.03,
            lastCause: "tools_changed",
            sessions: 3
        )
        let report = UsageReport(
            tools: fiveTools,
            order: [.antigravity],
            cost: cost,
            advice: advice,
            promptCache: promptCache,
            now: now
        )
        let object = try #require(JSONSerialization.jsonObject(with: report.json) as? [String: Any])

        let costObject = try #require(object["cost"] as? [String: Any])
        #expect(costObject["today"] as? Double == 4.5)
        #expect(costObject["last30Days"] as? Double == 85.0)
        #expect(costObject["priceSources"] as? [String] == ["builtIn:2026-10-07"])

        let adviceList = try #require(object["advice"] as? [[String: Any]])
        #expect(adviceList.count == 1)
        #expect(adviceList[0]["id"] as? String == "adv_1")
        #expect(adviceList[0]["tool"] as? String == "antigravity")
        #expect(adviceList[0]["text"] as? String == "Approaching 5h reset")

        let cacheObject = try #require(object["promptCache"] as? [String: Any])
        #expect(cacheObject["misses"] as? Int == 4)
        #expect(cacheObject["requests"] as? Int == 20)
        #expect(JSON.number(cacheObject["missShare"]) == 0.2)
        #expect(cacheObject["rewrittenTokens"] as? Int == 1200)
        #expect(cacheObject["lastCause"] as? String == "tools_changed")
        #expect(cacheObject["sessions"] as? Int == 3)
    }

    @Test func probeReportDecodesRoundTripVerbatim() throws {
        let report = UsageReport(tools: fiveTools, order: [.codex, .copilot], cost: nil, advice: [], now: now)
        let decoded = try #require(UsageReport.decode(report.json))
        #expect(decoded.exitCode == report.exitCode)
        let originalObject = try #require(try JSONSerialization.jsonObject(with: report.json) as? [String: Any])
        let decodedObject = try #require(try JSONSerialization.jsonObject(with: decoded.json) as? [String: Any])
        #expect(originalObject["schema"] as? String == decodedObject["schema"] as? String)
        #expect(originalObject["exitCode"] as? Int == decodedObject["exitCode"] as? Int)

        let limited = decoded.limited(to: .codex)
        let limitedObject = try #require(try JSONSerialization.jsonObject(with: limited.json) as? [String: Any])
        let limitedTools = try #require(limitedObject["tools"] as? [[String: Any]])
        #expect(limitedTools.count == 1)
        #expect(limitedTools[0]["tool"] as? String == "codex")
    }

    @Test func withTimeoutReturnsResultWhenOperationCompletesInTime() async throws {
        let result = try await Probe.withTimeout(seconds: 1.0) {
            return 42
        }
        #expect(result == 42)
    }

    @Test func withTimeoutThrowsTimedOutWhenOperationTakesTooLong() async throws {
        await #expect(throws: Probe.TimeoutError.self) {
            try await Probe.withTimeout(seconds: 0.05) {
                try await Task.sleep(nanoseconds: 200_000_000)
                return "never"
            }
        }
    }

    @Test func probeReportWithNeedsAttentionToolsShowsCorrectProblemAndExitCode() throws {
        let geminiProblem = "Gemini CLI's login has expired. Run Gemini CLI once so it signs back in"
        let antigravityProblem = "Antigravity's login has expired. Run Gemini CLI or Antigravity once so it signs back in"
        let copilotProblem = "Sign in to GitHub Copilot in your editor (or run `gh auth login`) to read your usage"

        let statuses: [ToolID: ToolStatus] = [
            .gemini: .needsAttention(geminiProblem, cached: nil),
            .antigravity: .needsAttention(antigravityProblem, cached: nil),
            .copilot: .needsAttention(copilotProblem, cached: nil)
        ]
        let order: [ToolID] = [.gemini, .antigravity, .copilot]
        let report = UsageReport(tools: statuses, order: order, cost: nil, advice: [], now: now)

        let list = try tools(report)
        let geminiEntry = try entry(list, .gemini)
        #expect(geminiEntry["status"] as? String == "needsAttention")
        #expect(geminiEntry["problem"] as? String == geminiProblem)

        let agyEntry = try entry(list, .antigravity)
        #expect(agyEntry["status"] as? String == "needsAttention")
        #expect(agyEntry["problem"] as? String == antigravityProblem)

        let copilotEntry = try entry(list, .copilot)
        #expect(copilotEntry["status"] as? String == "needsAttention")
        #expect(copilotEntry["problem"] as? String == copilotProblem)

        // When only needsAttention tools exist, exitCode is noData (30)
        #expect(report.exitCode == .noData)
    }

    @Test func probeReportWithTimedOutProviderShowsFailedAndExitCode30() throws {
        let statuses: [ToolID: ToolStatus] = [
            .claude: .failed("Probe timed out", cached: nil),
            .codex: .notInstalled
        ]
        let report = UsageReport(tools: statuses, order: [.claude, .codex], cost: nil, advice: [], now: now)
        let list = try tools(report)
        let claudeEntry = try entry(list, .claude)
        #expect(claudeEntry["status"] as? String == "failed")
        #expect(claudeEntry["problem"] as? String == "Probe timed out")
        #expect(report.exitCode == .noData)
    }

    // MARK: - All Eight Tools and Mixed Statuses

    @Test func allEightToolsReportInOrderWithCorrectSchemas() throws {
        let allEightStatuses: [ToolID: ToolStatus] = [
            .claude: .ready(reading(.claude, plan: "Max 5x", [
                window("five_hour", "Session", used: 0.15, resetsIn: 7200, period: 5 * 3600),
                window("seven_day", "Weekly", used: 0.05, resetsIn: 5 * 86400, period: 7 * 86400)
            ])),
            .codex: .ready(reading(.codex, plan: "Plus", [
                window("five_hour", "Session", used: 0.25, resetsIn: 10800, period: 5 * 3600),
                window("weekly", "Weekly", used: 0.10, resetsIn: 4 * 86400, period: 7 * 86400)
            ])),
            .cursor: .ready(reading(.cursor, plan: "Pro", [
                window("included", "Included", used: 0.40, resetsIn: 15 * 86400, period: 30 * 86400)
            ])),
            .gemini: .ready(reading(.gemini, plan: "Standard", [
                window("pro", .vendor("Pro"), used: 0.10, resetsIn: 86400, model: "gemini-2.5-pro")
            ])),
            .antigravity: .ready(reading(.antigravity, plan: "AI Pro", [
                window("session", "Session", used: 0.25, resetsIn: 3600, period: 5 * 3600, model: "Gemini 3 Pro")
            ])),
            .copilot: .ready(reading(.copilot, plan: "Pro+", [
                window("premium", "Premium requests", used: 0.30, resetsIn: 20 * 86400, period: 30 * 86400)
            ])),
            .kimi: .ready(reading(.kimi, plan: nil, [
                window("session", "Session", used: 0.50, resetsIn: 1800, period: 5 * 3600),
                window("weekly", "Weekly", used: 0.10, resetsIn: 4 * 86400, period: 7 * 86400)
            ])),
            .opencode: .ready(reading(.opencode, plan: "Go", [
                window("go_5h", "5-hour", used: 0.05, resetsIn: 14400, period: 5 * 3600),
                window("go_weekly", "Weekly", used: 0.02, resetsIn: 3 * 86400, period: 7 * 86400)
            ]))
        ]
        let order: [ToolID] = ToolID.allCases
        let report = UsageReport(tools: allEightStatuses, order: order, cost: nil, advice: [], now: now)
        let list = try tools(report)
        #expect(list.count == 8)
        #expect(list.compactMap { $0["tool"] as? String } == order.map(\.rawValue))
        #expect(list.allSatisfy { $0["status"] as? String == "ready" })
        #expect(list.allSatisfy { $0["stale"] as? Bool == false })
        #expect(report.exitCode == .ok)
    }

    @Test func mixedStatusesProbeReportSerializesCorrectlyAcrossAllStatusKinds() throws {
        let cachedAntigravity = reading(.antigravity, plan: "AI Pro", [
            window("session", "Session", used: 0.85, resetsIn: 3600, period: 5 * 3600, model: "Gemini 3 Pro")
        ])
        let cachedCopilot = reading(.copilot, plan: "Pro", [
            window("premium", "Premium requests", used: 0.20, resetsIn: 86400, period: 30 * 86400)
        ])

        let mixedStatuses: [ToolID: ToolStatus] = [
            .codex: .ready(reading(.codex, plan: "Plus", [window("five_hour", "Session", used: 0.30, resetsIn: 3600)])),
            .antigravity: .needsAttention("Antigravity's login has expired. Run Gemini CLI or Antigravity once so it signs back in", cached: cachedAntigravity),
            .gemini: .needsAttention("Sign in to Gemini CLI (run `gemini` and choose Login with Google) to read your quota", cached: nil),
            .opencode: .idle("No OpenCode Go turns on this Mac in the last 31 days; its spend is on the Cost card"),
            .claude: .failed("Probe timed out", cached: nil),
            .cursor: .offline(cached: nil),
            .kimi: .notInstalled,
            .copilot: .rateLimited("GitHub Copilot rate limited", cached: cachedCopilot)
        ]

        let order: [ToolID] = [.codex, .antigravity, .gemini, .opencode, .claude, .cursor, .kimi, .copilot]
        let report = UsageReport(tools: mixedStatuses, order: order, cost: nil, advice: [], now: now)
        let list = try tools(report)
        #expect(list.count == 8)

        // Codex: ready
        let codexEntry = try entry(list, .codex)
        #expect(codexEntry["status"] as? String == "ready")
        #expect(codexEntry["stale"] as? Bool == false)
        #expect(codexEntry["problem"] is NSNull)

        // Antigravity: needsAttention with stale reading
        let agyEntry = try entry(list, .antigravity)
        #expect(agyEntry["status"] as? String == "needsAttention")
        #expect(agyEntry["stale"] as? Bool == true)
        #expect(agyEntry["problem"] as? String == "Antigravity's login has expired. Run Gemini CLI or Antigravity once so it signs back in")
        let agyWindows = try #require(agyEntry["windows"] as? [[String: Any]])
        #expect(agyWindows.count == 1)
        #expect(JSON.number(agyWindows[0]["usedFraction"]) == 0.85)

        // Gemini: needsAttention cold (no cached reading)
        let geminiEntry = try entry(list, .gemini)
        #expect(geminiEntry["status"] as? String == "needsAttention")
        #expect(geminiEntry["stale"] == nil)
        #expect(geminiEntry["windows"] == nil)
        #expect((geminiEntry["problem"] as? String)?.contains("Sign in to Gemini CLI") == true)

        // OpenCode: idle
        let opencodeEntry = try entry(list, .opencode)
        #expect(opencodeEntry["status"] as? String == "idle")
        #expect(opencodeEntry["note"] as? String == "No OpenCode Go turns on this Mac in the last 31 days; its spend is on the Cost card")
        #expect(opencodeEntry["problem"] is NSNull)

        // Claude: failed
        let claudeEntry = try entry(list, .claude)
        #expect(claudeEntry["status"] as? String == "failed")
        #expect(claudeEntry["problem"] as? String == "Probe timed out")

        // Cursor: offline
        let cursorEntry = try entry(list, .cursor)
        #expect(cursorEntry["status"] as? String == "offline")
        #expect(cursorEntry["problem"] is NSNull)

        // Kimi: notInstalled
        let kimiEntry = try entry(list, .kimi)
        #expect(kimiEntry["status"] as? String == "notInstalled")
        #expect(kimiEntry["problem"] is NSNull)

        // Copilot: rateLimited with stale reading
        let copilotEntry = try entry(list, .copilot)
        #expect(copilotEntry["status"] as? String == "rateLimited")
        #expect(copilotEntry["stale"] as? Bool == true)
        #expect((copilotEntry["windows"] as? [[String: Any]])?.count == 1)

        // ExitCode: Antigravity has cached window at 0.85, so exit code is nearLimit (10)
        #expect(report.exitCode == .nearLimit)
    }

    @Test func staleReadingsPreservedForGeminiAntigravityAndCopilotOnNeedsAttention() throws {
        // Test Gemini with stale reading
        let geminiCached = reading(.gemini, plan: "Advanced", [window("gemini-pro", "Gemini Pro", used: 0.65, resetsIn: 3600)])
        let geminiStatus = ToolStatus(.tokenExpired("Gemini CLI's login has expired. Run Gemini CLI once so it signs back in"), cached: geminiCached)

        // Test Antigravity with stale reading at limitHit
        let agyCached = reading(.antigravity, plan: "AI Pro", [window("session", "Session", used: 1.0, resetsIn: 1800)])
        let agyStatus = ToolStatus(.tokenExpired("Antigravity's login has expired. Run Gemini CLI or Antigravity once so it signs back in"), cached: agyCached)

        // Test Copilot with stale reading
        let copilotCached = reading(.copilot, plan: "Business", [window("premium", "Premium", used: 0.30, resetsIn: 86400 * 5)])
        let copilotStatus = ToolStatus(.notSignedIn("Sign in to GitHub Copilot in your editor (or run `gh auth login`) to read your usage"), cached: copilotCached)

        let report = UsageReport(
            tools: [.gemini: geminiStatus, .antigravity: agyStatus, .copilot: copilotStatus],
            order: [.gemini, .antigravity, .copilot],
            cost: nil,
            advice: [],
            now: now
        )
        let list = try tools(report)

        let gemini = try entry(list, .gemini)
        #expect(gemini["status"] as? String == "needsAttention")
        #expect(gemini["stale"] as? Bool == true)
        #expect(gemini["plan"] as? String == "Advanced")
        let geminiWindows = try #require(gemini["windows"] as? [[String: Any]])
        #expect(JSON.number(geminiWindows[0]["usedFraction"]) == 0.65)

        let agy = try entry(list, .antigravity)
        #expect(agy["status"] as? String == "needsAttention")
        #expect(agy["stale"] as? Bool == true)
        #expect(agy["plan"] as? String == "AI Pro")
        let agyWindows = try #require(agy["windows"] as? [[String: Any]])
        #expect(JSON.number(agyWindows[0]["usedFraction"]) == 1.0)

        let copilot = try entry(list, .copilot)
        #expect(copilot["status"] as? String == "needsAttention")
        #expect(copilot["stale"] as? Bool == true)
        #expect(copilot["plan"] as? String == "Business")
        let copilotWindows = try #require(copilot["windows"] as? [[String: Any]])
        #expect(JSON.number(copilotWindows[0]["usedFraction"]) == 0.30)

        // Because Antigravity's stale reading has a window at 1.0, the exit code is limitHit (11)
        #expect(report.exitCode == .limitHit)
    }

    @Test func exitCodeMatrixValidatesAllTransitions() {
        func eval(_ statuses: [ToolID: ToolStatus]) -> UsageReport.ExitCode {
            UsageReport(tools: statuses, order: Array(statuses.keys), cost: nil, advice: [], now: now).exitCode
        }

        // 1. All tools absent or unmetered -> noData (30)
        #expect(eval([:]) == .noData)
        #expect(eval([.codex: .notInstalled, .cursor: .offline(cached: nil), .claude: .failed("err", cached: nil)]) == .noData)
        #expect(eval([.gemini: .idle("not served"), .opencode: .idle("no turns")]) == .noData)

        // 2. All active tools have 0.0 usage -> noSession (20)
        #expect(eval([.codex: .ready(reading(.codex, plan: nil, [window("s", "Session", used: 0.0)]))]) == .noSession)
        #expect(eval([
            .codex: .ready(reading(.codex, plan: nil, [window("s", "Session", used: 0.0)])),
            .gemini: .idle("calm"),
            .copilot: .notInstalled
        ]) == .noSession)

        // 3. Normal usage < 0.80 -> ok (0)
        #expect(eval([.codex: .ready(reading(.codex, plan: nil, [window("s", "Session", used: 0.50)]))]) == .ok)
        #expect(eval([
            .codex: .ready(reading(.codex, plan: nil, [window("s", "Session", used: 0.79)])),
            .cursor: .ready(reading(.cursor, plan: nil, [window("i", "Included", used: 0.10)]))
        ]) == .ok)

        // 4. Usage >= 0.80 -> nearLimit (10)
        #expect(eval([.codex: .ready(reading(.codex, plan: nil, [window("s", "Session", used: 0.80)]))]) == .nearLimit)
        #expect(eval([
            .codex: .ready(reading(.codex, plan: nil, [window("s", "Session", used: 0.20)])),
            .antigravity: .ready(reading(.antigravity, plan: nil, [window("s", "Session", used: 0.95)]))
        ]) == .nearLimit)

        // 5. Usage >= 1.0 -> limitHit (11)
        #expect(eval([.codex: .ready(reading(.codex, plan: nil, [window("s", "Session", used: 1.0)]))]) == .limitHit)
        #expect(eval([
            .antigravity: .ready(reading(.antigravity, plan: nil, [window("s", "Session", used: 0.85)])),
            .copilot: .ready(reading(.copilot, plan: nil, [window("m", "Monthly", used: 1.05)]))
        ]) == .limitHit)
    }

    @Test func withTimeoutPassesUnderlyingErrorThroughWhenNotTimedOut() async {
        struct CustomError: Error, Equatable {
            let message: String
        }
        await #expect(throws: CustomError(message: "network issue")) {
            try await Probe.withTimeout(seconds: 1.0) {
                throw CustomError(message: "network issue")
            }
        }
    }

    @Test func probeReportWithOfflineProviderShowsOfflineAndExitCode30() throws {
        let statuses: [ToolID: ToolStatus] = [
            .claude: .offline(cached: nil),
            .kimi: .offline(cached: nil)
        ]
        let report = UsageReport(tools: statuses, cost: nil, advice: [], now: Date())
        let json = try JSONSerialization.jsonObject(with: report.json) as? [String: Any]
        let tools = try #require(json?["tools"] as? [[String: Any]])
        #expect(tools.count == 2)
        for tool in tools {
            #expect(tool["status"] as? String == "offline")
        }
        #expect(report.exitCode == .noData)
    }

    @Test func probeReportIncludesAllEightToolsWithStatusFields() throws {
        let allTools: [ToolID: ToolStatus] = [
            .claude: .ready(reading(.claude, plan: "Pro", [window("s", "Session", used: 0.1)])),
            .codex: .ready(reading(.codex, plan: "Plus", [window("w", "Weekly", used: 0.2)])),
            .cursor: .ready(reading(.cursor, plan: "Pro", [window("i", "Included", used: 0.3)])),
            .gemini: .idle("Personal account"),
            .antigravity: .ready(reading(.antigravity, plan: "Standard", [window("s", "Session", used: 0.4)])),
            .copilot: .ready(reading(.copilot, plan: "Individual", [window("m", "Monthly", used: 0.5)])),
            .kimi: .ready(reading(.kimi, plan: nil, [window("s", "Session", used: 0.6)])),
            .opencode: .idle("No Go turns")
        ]
        let report = UsageReport(tools: allTools, cost: nil, advice: [], now: Date())
        let json = try JSONSerialization.jsonObject(with: report.json) as? [String: Any]
        let tools = try #require(json?["tools"] as? [[String: Any]])
        #expect(tools.count == 8)

        let toolIDs = Set(tools.compactMap { $0["tool"] as? String })
        #expect(toolIDs == Set(ToolID.allCases.map(\.rawValue)))

        for entry in tools {
            let id = try #require((entry["tool"] as? String).flatMap(ToolID.init(rawValue:)))
            #expect(entry["name"] as? String == id.displayName)
            #expect(entry["status"] as? String != nil)
        }
    }

    @Test func probeReportIncludesHistoryRecordsSortedOldestFirst() throws {
        let calendar = Calendar(identifier: .gregorian)
        let day1 = DateParsing.iso8601("2026-10-06T00:00:00Z")!
        let day2 = DateParsing.iso8601("2026-10-07T00:00:00Z")!

        let record1 = CostHistory.Record(
            cost: 1.25,
            tokens: TokenBreakdown(input: 1000, cacheWrite5m: 50, cacheWrite1h: 0, cacheRead: 500, output: 200),
            byModel: ["claude-3-5-sonnet": 1.25],
            byProject: ["notchmeter": 1.25],
            sessionTokensPerPercent: 250.0
        )
        let record2 = CostHistory.Record(
            cost: 3.50,
            tokens: TokenBreakdown(input: 2000, cacheWrite5m: 100, cacheWrite1h: 50, cacheRead: 1000, output: 400),
            byModel: ["claude-3-7-sonnet": 3.50],
            byProject: ["notchmeter": 3.50],
            sessionTokensPerPercent: 300.0
        )

        let history: [Date: CostHistory.Record] = [
            day2: record2,
            day1: record1
        ]

        let report = UsageReport(tools: fiveTools, order: [.claude], cost: nil, advice: [], history: history, now: now)
        let json = try #require(try JSONSerialization.jsonObject(with: report.json) as? [String: Any])
        let rows = try #require(json["history"] as? [[String: Any]])
        #expect(rows.count == 2)

        #expect(rows[0]["day"] as? String == CostHistory.key(day1, calendar: calendar))
        #expect(rows[0]["cost"] as? Double == 1.25)
        #expect(rows[0]["tokens"] as? Int == record1.tokens.total)
        #expect(rows[0]["topModel"] as? String == "claude-3-5-sonnet")
        #expect(rows[0]["sessionTokensPerPercent"] as? Int == 250)

        let buckets1 = try #require(rows[0]["tokenBuckets"] as? [String: Any])
        #expect(buckets1["input"] as? Int == 1000)
        #expect(buckets1["output"] as? Int == 200)
        #expect(buckets1["cacheRead"] as? Int == 500)

        #expect(rows[1]["day"] as? String == CostHistory.key(day2, calendar: calendar))
        #expect(rows[1]["cost"] as? Double == 3.50)
        #expect(rows[1]["topModel"] as? String == "claude-3-7-sonnet")

        let claudeReport = report.limited(to: .claude)
        let claudeJson = try #require(try JSONSerialization.jsonObject(with: claudeReport.json) as? [String: Any])
        #expect(claudeJson["history"] != nil)

        let codexReport = report.limited(to: .codex)
        let codexJson = try #require(try JSONSerialization.jsonObject(with: codexReport.json) as? [String: Any])
        #expect(codexJson["history"] == nil)
    }

    @Test func probeReportPromptCacheHandlesNilMissShareAndFormatting() throws {
        let promptCache = PromptCacheSummary(
            misses: 0,
            requests: 0,
            rewrittenTokens: 0,
            rewrittenUSD: nil,
            lastCause: nil,
            sessions: 0
        )
        let report = UsageReport(tools: fiveTools, order: [.claude], cost: nil, advice: [], promptCache: promptCache, now: now)
        let json = try #require(try JSONSerialization.jsonObject(with: report.json) as? [String: Any])
        let cacheObj = try #require(json["promptCache"] as? [String: Any])
        #expect(cacheObj["misses"] as? Int == 0)
        #expect(cacheObj["requests"] as? Int == 0)
        #expect(cacheObj["missShare"] is NSNull)
        #expect(cacheObj["rewrittenUSD"] is NSNull)
        #expect(cacheObj["lastCause"] is NSNull)
    }

    @Test func probeReportRunOutHandlesZeroSamplesAndNilExtremes() throws {
        let key = DrainLog.Key(tool: .cursor, window: "included")
        let runOut = RunOutInterval(earliest: 0, latest: 0, sampleCount: 0)
        let report = UsageReport(
            tools: fiveTools,
            order: [.cursor],
            cost: nil,
            advice: [],
            runOuts: [key: runOut],
            now: now
        )
        let list = try tools(report)
        let cursor = try entry(list, .cursor)
        let windows = try #require(cursor["windows"] as? [[String: Any]])
        let included = try #require(windows.first { $0["id"] as? String == "included" })
        let runOutObj = try #require(included["runOut"] as? [String: Any])
        #expect(runOutObj["samples"] as? Int == 0)
        #expect(runOutObj["earliestAt"] as? String == Oracle.timestamp(now))
        #expect(runOutObj["latestAt"] as? String == Oracle.timestamp(now))
    }

    @Test func probeGatherWithZeroTimeoutTimesOutCleanlyWithoutHanging() async {
        let report = await Probe.gather(verbose: false, timeout: 0)
        #expect(report.exitCode == .noData)
        #expect(report.cost?.providers.isEmpty ?? true)
    }
}
