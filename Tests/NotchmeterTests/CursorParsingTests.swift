import Foundation
import SQLite3
import Testing
@testable import Notchmeter

@Suite struct CursorParsing {
    init() { Localization.use(language: "en") }

    @Test func decodesJWTAndUserID() throws {
        let payload = #"{"sub":"auth0|user_01ABC","exp":1900000000,"email":"a@b.c"}"#
        let encoded = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let claims = try CursorProvider.jwtClaims("eyJhbGciOiJIUzI1NiJ9.\(encoded).signature")
        #expect(try CursorProvider.userID(fromClaims: claims) == "user_01ABC")
        #expect(claims["exp"] as? Double == 1_900_000_000)
    }

    @Test func parsesUsageSummaryIntoIncludedAndOnDemand() throws {
        let json = """
        {"billingCycleStart":"2026-08-24T05:12:03.105Z","billingCycleEnd":"2026-09-24T05:12:03.105Z",
         "membershipType":"pro","limitType":"user","isUnlimited":false,
         "individualUsage":{"plan":{"enabled":true,"used":250,"limit":2000,"remaining":1750,"totalPercentUsed":12.5},
                            "onDemand":{"enabled":true,"used":300,"limit":5000,"remaining":4700}}}
        """
        let reading = try CursorProvider.parseSummary(Data(json.utf8), now: Date(timeIntervalSince1970: 1_756_700_000))
        #expect(reading.plan == "Pro")
        let ids = reading.windows.map(\.id)
        #expect(ids == ["included", "on_demand"])
        #expect(reading.windows[0].label == "Included usage")
        #expect(reading.windows[0].usedFraction == 0.125)
        #expect(reading.windows[0].resetsAt == DateParsing.iso8601("2026-09-24T05:12:03.105Z"))
        #expect(reading.windows[0].note?.hasPrefix("$2.50 of $20") == true)
        #expect(reading.windows[1].usedFraction == 0.06)
        #expect(reading.windows[1].note == "$3 of $50")
    }

    /// The summary publishes two answers for the same window and on Enterprise they disagree: `totalPercentUsed`
    /// 55 against a `used`/`limit` pair of $20 and $20, the whole allowance gone. The account's own billing export
    /// settled it — Cursor bills a request as On-Demand only once the included allowance is spent, and that account
    /// had 47 On-Demand events worth $116 in the very cycle the 55 % was reported for. A bar at 55 % claimed half an
    /// allowance remained while every third-party request was already being charged for. The window is as spent as
    /// its furthest-along figure says; the dollars stay printed underneath, so the disagreement stays visible.
    @Test func aWindowIsAsSpentAsItsFurthestFigureSays() throws {
        let json = """
        {"billingCycleStart":"2026-08-26T13:01:00.000Z","billingCycleEnd":"2026-09-26T13:01:00.000Z",
         "membershipType":"enterprise","limitType":"user","isUnlimited":false,
         "individualUsage":{"plan":{"enabled":true,"used":2000,"limit":2000,"totalPercentUsed":55,
                                    "autoPercentUsed":47,"apiPercentUsed":100}}}
        """
        let reading = try CursorProvider.parseSummary(Data(json.utf8))
        let included = try #require(reading.windows.first { $0.id == "included" })
        #expect(included.usedFraction == 1)
        #expect(included.note == "$20 of $20")
        // The two model figures are 47 % and 100 % of one cycle, so they are not two shares of one allowance and
        // the caption must not call them that. What they are shares of, Cursor does not say and nor does this.
        let auto = try #require(reading.windows.first { $0.id == "cursor_models" })
        let api = try #require(reading.windows.first { $0.id == "other_models" })
        #expect(auto.usedFraction == 0.47)
        #expect(api.usedFraction == 1)
        let bothShares = (auto.usedFraction ?? 0) + (api.usedFraction ?? 0)
        #expect(bothShares > 1)
        #expect(auto.note == "Metered apart from the included total")
        #expect(api.note == auto.note)
        // Reading as far along as the model windows it covers, it can now be adopted as their total.
        let combined = try #require(CombinedWindow.of(reading: reading))
        #expect(combined.usedFraction == 1)
        #expect(combined.source == .localEstimate)
        // Neither field is trusted over the other; the further-along one wins, whichever it happens to be.
        #expect(CursorProvider.share(percent: 55, used: 1100, limit: 2000) == 0.55)
        #expect(CursorProvider.share(percent: 25, used: 1000, limit: 2000) == 0.5)
        #expect(CursorProvider.share(percent: nil, used: 500, limit: 2000) == 0.25)
        #expect(CursorProvider.share(percent: 140, used: nil, limit: 2000) == 1)
        #expect(CursorProvider.share(percent: nil, used: nil, limit: 0) == 0)
    }

    @Test func unlimitedPlanPublishesNoLimit() throws {
        let json = """
        {"billingCycleEnd":"2026-09-24T05:12:03.105Z","membershipType":"ultra","isUnlimited":true,
         "individualUsage":{"plan":{"enabled":true,"used":0,"limit":0}}}
        """
        let reading = try CursorProvider.parseSummary(Data(json.utf8))
        #expect(reading.windows.count == 1)
        #expect(reading.windows[0].usedFraction == nil)
        #expect(reading.windows[0].note == "Unlimited on the Ultra plan")
    }

    @Test func emptyPlanExplainsItself() throws {
        let json = #"{"membershipType":"free","individualUsage":{"plan":{"enabled":false,"used":0,"limit":0}}}"#
        let reading = try CursorProvider.parseSummary(Data(json.utf8))
        #expect(reading.windows[0].usedFraction == nil)
        #expect(reading.windows[0].note == "Free plan has nothing for Cursor to meter yet")
    }

    /// An Enterprise seat's summary from 2026-09-18: `overall` in place of `plan`, no limits anywhere, and the two
    /// model percentages only inside the dashboard's sentences. Read as one empty window, it took the ring pickers
    /// out of Settings, which need more than one window to choose between.
    @Test func anEnterpriseSeatWithNoLimitsStillHasItsWindows() throws {
        let json = """
        {"billingCycleStart":"2026-09-18T00:00:00.000Z","billingCycleEnd":"2026-10-18T00:00:00.000Z",
         "membershipType":"enterprise","limitType":"team","isUnlimited":false,
         "autoModelSelectedDisplayMessage":"You've used 12% of your included total usage",
         "namedModelSelectedDisplayMessage":"You've used 0% of your included API usage",
         "individualUsage":{"overall":{"enabled":false,"used":0,"limit":null,"remaining":null}},
         "teamUsage":{"onDemand":{"enabled":true,"used":4250,"limit":null,"remaining":null}}}
        """
        let reading = try CursorProvider.parseSummary(Data(json.utf8))
        #expect(reading.windows.map(\.id) == ["included", "cursor_models", "other_models", "team_on_demand"])
        #expect(reading.windows[0].note == "Enterprise plan has nothing for Cursor to meter yet")
        #expect(reading.windows[1].usedFraction == 0.12)
        #expect(reading.windows[2].usedFraction == 0)
        #expect(!reading.windows[1].hiddenByDefault && !reading.windows[2].hiddenByDefault)
        #expect(reading.windows[3].usedFraction == nil)
        #expect(reading.windows[3].note == "$42.50 so far, no limit set")
        #expect(reading.windows[3].amountUSD == 42.5)
        #expect(CursorProvider.percent(in: "You've used 49.5% of it") == 49.5)
        #expect(CursorProvider.percent(in: "No figure here") == nil)
    }

    /// With no included allowance every summary figure stays at 0 %, so the export's dollars carry the ring:
    /// today against the average day of the history before it, filling at a usual day and counting on past it.
    @Test func anUnmeteredSeatGetsTodaysSpendAgainstAUsualDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = DateParsing.iso8601("2026-09-18T16:00:00Z")!
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int, _ cost: Double) -> (Date, CostHistory.Record) {
            (calendar.date(byAdding: .day, value: offset, to: today)!, CostHistory.Record(cost: cost, tokens: TokenBreakdown(), byModel: [:], byProject: [:]))
        }
        // Ten days of history at $1,000 in all: a usual day is $100.
        var days = Dictionary(uniqueKeysWithValues: [day(-10, 400), day(-5, 600), day(0, 60)])
        let window = try #require(CursorProvider.spendToday(days, now: now, calendar: calendar))
        #expect(window.id == "spend_today")
        #expect(window.label == "Today's spend")
        #expect(abs((window.usedFraction ?? 0) - 0.6) < 1e-9)
        #expect(window.note == "$60.00 of a usual $100 day")
        #expect(window.resetsAt == calendar.date(byAdding: .day, value: 1, to: today))
        days[today] = CostHistory.Record(cost: 250, tokens: TokenBreakdown(), byModel: [:], byProject: [:])
        let over = try #require(CursorProvider.spendToday(days, now: now, calendar: calendar))
        #expect(over.usedFraction == 1)
        #expect(over.rawUsedPercent == 250)
        // Past a usual day the note keeps going rather than falling silent at 100 %.
        #expect(Pace.note(for: over, now: calendar.date(byAdding: .hour, value: 12, to: today)!)?.text == "Heading for ~500% today")
        // A usual day is a comparison, not a limit: no "Runs out in", and never the window advice routes from.
        #expect(window.isComparison)
        let midday = calendar.date(byAdding: .hour, value: 12, to: today)!
        let note = try #require(Pace.note(for: window, now: midday))
        #expect(note.text == "Heading for ~120% today")
        #expect(note.status == .ahead)
        let reading = UsageReading(tool: .cursor, windows: [window], plan: nil, fetchedAt: now, observedAt: nil)
        #expect(Advisor.mainWindow(of: reading) == nil)
        #expect(Pace.status(for: window, now: midday) == .ahead)
        #expect(WatchedReset.watch(.cursor, window, now: midday) == nil)
        // Nothing before today, nothing to call usual.
        #expect(CursorProvider.spendToday([today: days[today]!], now: now, calendar: calendar) == nil)
    }

    @Test func parsesLegacyRequestUsage() throws {
        let json = #"{"gpt-4":{"numRequests":120,"numRequestsTotal":120,"numTokens":0,"maxRequestUsage":500,"maxTokenUsage":null},"startOfMonth":"2026-08-24T00:00:00.000Z"}"#
        let reading = try CursorProvider.parseLegacyUsage(Data(json.utf8))
        #expect(reading.windows[0].label == "Fast requests")
        #expect(reading.windows[0].usedFraction == 0.24)
        #expect(reading.windows[0].note == "120 of 500 requests")
    }

    @Test func readsStateDatabase() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-cursor-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("state.vscdb")
        var handle: OpaquePointer?
        #expect(sqlite3_open(db.path, &handle) == SQLITE_OK)
        sqlite3_exec(handle, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB); INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', 'tok.en.value');", nil, nil, nil)
        sqlite3_close(handle)
        #expect(try CursorProvider.stateValue(forKey: "cursorAuth/accessToken", database: db) == "tok.en.value")
        #expect(try CursorProvider.stateValue(forKey: "missing", database: db) == nil)
    }
}


/// The Cursor-models / other-models split, the team's pooled usage, `limitType`, and the usage-events export.
@Suite struct CursorRoundTwo {
    init() { Localization.use(language: "en") }

    let now = DateParsing.iso8601("2026-09-01T12:00:00Z")!

    @MainActor @Test func splitsThePlanByModelKindAndHidesTheSplitByDefault() throws {
        let json = """
        {"billingCycleStart":"2026-08-24T05:12:03.105Z","billingCycleEnd":"2026-09-24T05:12:03.105Z","membershipType":"pro","limitType":"user","isUnlimited":false,
         "individualUsage":{"plan":{"enabled":true,"used":250,"limit":2000,"remaining":1750,"totalPercentUsed":12.5,"autoPercentUsed":9.5,"apiPercentUsed":3},
                            "onDemand":{"enabled":false}}}
        """
        let reading = try CursorProvider.parseSummary(Data(json.utf8), now: now)
        let ids = reading.windows.map(\.id)
        #expect(ids == ["included", "cursor_models", "other_models"])
        #expect(reading.windows[1].label == "Cursor models")
        #expect(reading.windows[1].usedFraction == 0.095)
        #expect(reading.windows[1].model == "Cursor models")
        #expect(reading.windows[1].hiddenByDefault)
        #expect(reading.windows[2].usedFraction == 0.03)
        #expect(reading.windows[0].amountUSD == 2.5)
        #expect(!reading.windows[0].hiddenByDefault)
        let defaults = UserDefaults(suiteName: "NotchmeterTests.CursorHidden")!
        defaults.removePersistentDomain(forName: "NotchmeterTests.CursorHidden")
        defer { defaults.removePersistentDomain(forName: "NotchmeterTests.CursorHidden") }
        let prefs = Preferences(defaults: defaults)
        var shown = prefs.shownWindows(of: reading).map(\.id)
        #expect(shown == ["included"])
        prefs.setHidden(false, window: reading.windows[1], of: .cursor)
        shown = prefs.shownWindows(of: reading).map(\.id)
        #expect(shown == ["included", "cursor_models"])
        prefs.setHidden(true, window: reading.windows[1], of: .cursor)
        shown = prefs.shownWindows(of: reading).map(\.id)
        #expect(shown == ["included"])
        prefs.setHidden(true, window: reading.windows[0], of: .cursor)
        #expect(prefs.shownWindows(of: reading).isEmpty)
    }

    @Test func aTeamPlanPutsThePooledUsageFirst() throws {
        let json = """
        {"billingCycleStart":"2026-08-24T00:00:00Z","billingCycleEnd":"2026-09-24T00:00:00Z","membershipType":"team","limitType":"team",
         "individualUsage":{"plan":{"enabled":true,"used":100,"limit":2000,"totalPercentUsed":5}},
         "teamUsage":{"pooled":{"used":12000,"limit":40000,"totalPercentUsed":30},"onDemand":{"enabled":true,"used":500,"limit":10000}}}
        """
        let reading = try CursorProvider.parseSummary(Data(json.utf8), now: now)
        let ids = reading.windows.map(\.id)
        #expect(ids == ["team_pooled", "included", "team_on_demand"])
        #expect(reading.windows[0].label == "Team pooled")
        #expect(reading.windows[0].usedFraction == 0.3)
        #expect(reading.windows[0].note == "$120 of $400")
        #expect(reading.windows[2].hiddenByDefault)
        #expect(Advisor.mainWindow(of: reading)?.id == "team_pooled")
        let individual = try CursorProvider.parseSummary(Data(json.utf8.map { $0 }).replacingTeam(), now: now)
        let individualIds = individual.windows.map(\.id)
        #expect(individualIds == ["included", "team_pooled", "team_on_demand"])
        #expect(Advisor.mainWindow(of: individual)?.id == "included")
    }

    @Test func usageEventsAreParsedPricedAndFoldedIntoDays() throws {
        let json = """
        {"totalUsageEventsCount":3,"usageEventsDisplay":[
          {"timestamp":"1756728000000","model":"claude-4-sonnet","kind":"Included in Pro","usageBasedCosts":"-","isTokenBasedCall":true,
           "tokenUsage":{"inputTokens":1200,"outputTokens":300,"cacheWriteTokens":100,"cacheReadTokens":4000,"totalCents":12}},
          {"timestamp":1756731600000,"model":"gpt-5","usageBasedCosts":"$0.05","isTokenBasedCall":false},
          {"timestamp":"1756641600000","model":"claude-4-sonnet","tokenUsage":{"totalCents":30}},
          {"model":"missing-timestamp"}]}
        """
        let page = CursorProvider.parseUsageEvents(Data(json.utf8))
        #expect(page.recognised)
        #expect(page.rows == 4)
        let events = page.events
        #expect(events.count == 3)
        #expect(events[0].costUSD == 0.12)
        #expect(events[0].tokens.total == 5600)
        #expect(events[1].costUSD == 0.05)
        #expect(events[1].model == "gpt-5")
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let days = CursorProvider.dayRecords(events, calendar: utc)
        #expect(days.count == 2)
        let today = utc.startOfDay(for: Date(timeIntervalSince1970: 1_756_728_000))
        let todaysCost = days[today]?.cost ?? 0
        #expect(abs(todaysCost - 0.17) < 1e-9)
        let todaysModels = days[today]?.byModel.keys.sorted()
        #expect(todaysModels == ["claude-4-sonnet", "gpt-5"])
        #expect(days[today]?.tokens.cacheRead == 4000)
        let body = try #require(try JSONSerialization.jsonObject(with: CursorProvider.usageEventsRequestBody(start: now.addingTimeInterval(-86400), end: now)) as? [String: Any])
        let startDate = body["startDate"] as? String
        let aDayBeforeNow = String(Int(now.timeIntervalSince1970 * 1000) - 86_400_000)
        #expect(startDate == aDayBeforeNow)
        #expect(body["pageSize"] as? Int == 500)
        #expect(CursorProvider.parseUsageEvents(Data("nope".utf8)).events.isEmpty)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-cursor-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = CostHistory(url: dir.appendingPathComponent("daily.jsonl"), tool: .cursor)
        history.record(days, existing: [:], calendar: utc)
        // The export becomes Cursor's own first-class ProviderCost: ranges, a 30-day series and the per-model split.
        let now = Date(timeIntervalSince1970: 1_756_728_000)
        let reader = CursorCostReader(history: history)
        let cost = try #require(reader.read(now: now, daysBack: 30, weekStart: utc.startOfDay(for: now), calendar: utc,
                                            state: ProviderReadState(readAt: now.addingTimeInterval(-60))))
        #expect(cost.tool == .cursor)
        #expect(cost.source == .billingExport)
        #expect(cost.source.isEstimate == false)
        #expect(cost.daily.count == 30)
        let lastDay = cost.daily.last?.cost ?? 0
        #expect(abs(lastDay - 0.17) < 1e-9)
        #expect(abs(cost.totals(.today).cost - 0.17) < 1e-9)
        let models = cost.totals(.last30Days).models.map(\.name)
        #expect(models == ["claude-4-sonnet", "gpt-5"])
        // Cursor's export is day-resolution, so it reports no hour of its own.
        #expect(cost.lastHour == nil)
        #expect(cost.burnMultiple == nil)
        #expect(cost.scannedAt == now.addingTimeInterval(-60))
        #expect(CostHistory(url: dir.appendingPathComponent("daily.jsonl"), tool: .claude).load(calendar: utc).isEmpty)
        let nothingRecorded = CursorCostReader(history: CostHistory(url: dir.appendingPathComponent("nothing.jsonl"), tool: .cursor))
            .read(now: now, daysBack: 30, weekStart: now, calendar: utc, state: ProviderReadState())
        #expect(nothingRecorded == nil)
    }

    /// A body this build cannot read is not an empty month. Both drifts count: the list under a key with a new
    /// name, and the list still found but every row's timestamp renamed, which parses to no events at all.
    @Test func anExportInAShapeThisBuildCannotReadIsNotAnEmptyMonth() {
        #expect(CursorProvider.parseUsageEvents(Data("nope".utf8)).recognised == false)
        #expect(CursorProvider.parseUsageEvents(Data(#"{"rows":[{"ts":1}]}"#.utf8)).recognised == false)
        let renamedTimestamp = CursorProvider.parseUsageEvents(Data(#"{"usageEventsDisplay":[{"ts":1756728000000,"model":"gpt-5"}]}"#.utf8))
        #expect(renamedTimestamp.recognised == false)
        #expect(renamedTimestamp.rows == 1)
        let empty = CursorProvider.parseUsageEvents(Data(#"{"usageEventsDisplay":[]}"#.utf8))
        #expect(empty.recognised)
        #expect(empty.rows == 0)
        #expect(empty.events.isEmpty)
    }
}

private extension Data {
    /// The same summary as an individual account: `limitType` flipped to user.
    func replacingTeam() -> Data {
        Data(String(decoding: self, as: UTF8.self).replacingOccurrences(of: "\"limitType\":\"team\"", with: "\"limitType\":\"user\"").utf8)
    }
}

/// A seat on a team keeps its usage events under that team's id. Sending 0 for a team account is refused with
/// "Team ID is required", which arrives looking exactly like a month with no spend.
@Suite struct CursorTeamId {
    @Test func readsTheFirstRealTeam() {
        let json = #"{"teams":[{"id":1234,"name":"Acme","role":"member"},{"id":9,"name":"Other"}]}"#
        #expect(CursorProvider.parseTeamId(Data(json.utf8)) == 1234)
    }

    @Test func anIndividualAccountHasNone() {
        #expect(CursorProvider.parseTeamId(Data("{}".utf8)) == nil)
        #expect(CursorProvider.parseTeamId(Data(#"{"teams":[]}"#.utf8)) == nil)
        #expect(CursorProvider.parseTeamId(Data(#"{"teams":[{"id":0}]}"#.utf8)) == nil)
        #expect(CursorProvider.parseTeamId(Data("not json".utf8)) == nil)
    }

    @Test func theTeamGoesIntoTheRequest() throws {
        let start = Date(timeIntervalSince1970: 1_756_000_000)
        let end = Date(timeIntervalSince1970: 1_758_000_000)
        let body = CursorProvider.usageEventsRequestBody(start: start, end: end, teamId: 1234)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["teamId"] as? Int == 1234)
        #expect(object["startDate"] as? String == "1756000000000")
        // Individual accounts keep the documented 0.
        let solo = CursorProvider.usageEventsRequestBody(start: start, end: end)
        let soloObject = try #require(try JSONSerialization.jsonObject(with: solo) as? [String: Any])
        #expect(soloObject["teamId"] as? Int == 0)
    }
}

/// The store must build its providers through the registry that wires the opt-in second reads to preferences.
/// An unwired overload used to win resolution for a bare `all()`, leaving Cursor's usage-events read switched
/// off in the running app while the CLI path had it on — the Cost card showed no Cursor spend and logged nothing.
@Suite struct ProviderRegistryIsWired {
    @Test func theStoreGetsProvidersWiredToTheDefaults() {
        let defaults = UserDefaults(suiteName: "NotchmeterTests.RegistryWiring")!
        defaults.removePersistentDomain(forName: "NotchmeterTests.RegistryWiring")
        defaults.set(true, forKey: "cursorUsageEvents")
        let tools = ProviderRegistry.all(defaults: defaults).map(\.tool)
        #expect(Set(tools) == Set(ToolID.allCases))
        defaults.removePersistentDomain(forName: "NotchmeterTests.RegistryWiring")
    }
}
