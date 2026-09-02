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
        #expect(reading.windows.map(\.id) == ["included", "on_demand"])
        #expect(reading.windows[0].label == "Included usage")
        #expect(reading.windows[0].usedFraction == 0.125)
        #expect(reading.windows[0].resetsAt == DateParsing.iso8601("2026-09-24T05:12:03.105Z"))
        #expect(reading.windows[0].note?.hasPrefix("$2.50 of $20") == true)
        #expect(reading.windows[1].usedFraction == 0.06)
        #expect(reading.windows[1].note == "$3 of $50")
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

    @Test func splitsThePlanByModelKindAndHidesTheSplitByDefault() throws {
        let json = """
        {"billingCycleStart":"2026-08-24T05:12:03.105Z","billingCycleEnd":"2026-09-24T05:12:03.105Z","membershipType":"pro","limitType":"user","isUnlimited":false,
         "individualUsage":{"plan":{"enabled":true,"used":250,"limit":2000,"remaining":1750,"totalPercentUsed":12.5,"autoPercentUsed":9.5,"apiPercentUsed":3},
                            "onDemand":{"enabled":false}}}
        """
        let reading = try CursorProvider.parseSummary(Data(json.utf8), now: now)
        #expect(reading.windows.map(\.id) == ["included", "cursor_models", "other_models"])
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
        Task { @MainActor in
            let prefs = Preferences(defaults: defaults)
            #expect(prefs.shownWindows(of: reading).map(\.id) == ["included"])
            prefs.setHidden(false, window: reading.windows[1], of: .cursor)
            #expect(prefs.shownWindows(of: reading).map(\.id) == ["included", "cursor_models"])
            prefs.setHidden(true, window: reading.windows[1], of: .cursor)
            #expect(prefs.shownWindows(of: reading).map(\.id) == ["included"])
            prefs.setHidden(true, window: reading.windows[0], of: .cursor)
            #expect(prefs.shownWindows(of: reading).isEmpty)
        }
    }

    @Test func aTeamPlanPutsThePooledUsageFirst() throws {
        let json = """
        {"billingCycleStart":"2026-08-24T00:00:00Z","billingCycleEnd":"2026-09-24T00:00:00Z","membershipType":"team","limitType":"team",
         "individualUsage":{"plan":{"enabled":true,"used":100,"limit":2000,"totalPercentUsed":5}},
         "teamUsage":{"pooled":{"used":12000,"limit":40000,"totalPercentUsed":30},"onDemand":{"enabled":true,"used":500,"limit":10000}}}
        """
        let reading = try CursorProvider.parseSummary(Data(json.utf8), now: now)
        #expect(reading.windows.map(\.id) == ["team_pooled", "included", "team_on_demand"])
        #expect(reading.windows[0].label == "Team pooled")
        #expect(reading.windows[0].usedFraction == 0.3)
        #expect(reading.windows[0].note == "$120 of $400")
        #expect(reading.windows[2].hiddenByDefault)
        #expect(Advisor.mainWindow(of: reading)?.id == "team_pooled")
        let individual = try CursorProvider.parseSummary(Data(json.utf8.map { $0 }).replacingTeam(), now: now)
        #expect(individual.windows.map(\.id) == ["included", "team_pooled", "team_on_demand"])
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
        let events = CursorProvider.parseUsageEvents(Data(json.utf8))
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
        #expect(abs((days[today]?.cost ?? 0) - 0.17) < 1e-9)
        #expect(days[today]?.byModel.keys.sorted() == ["claude-4-sonnet", "gpt-5"])
        #expect(days[today]?.tokens.cacheRead == 4000)
        let body = try #require(try JSONSerialization.jsonObject(with: CursorProvider.usageEventsRequestBody(start: now.addingTimeInterval(-86400), end: now)) as? [String: Any])
        #expect(body["startDate"] as? String == String(Int(now.timeIntervalSince1970 * 1000) - 86_400_000))
        #expect(body["pageSize"] as? Int == 500)
        #expect(CursorProvider.parseUsageEvents(Data("nope".utf8)).isEmpty)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-cursor-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = CostHistory(url: dir.appendingPathComponent("daily.jsonl"), tool: .cursor)
        history.record(days, existing: [:], calendar: utc)
        let series = ClaudeCostScanner.series(from: history.load(calendar: utc), days: 30, now: Date(timeIntervalSince1970: 1_756_728_000), calendar: utc)
        #expect(series.count == 30)
        #expect(abs((series.last?.cost ?? 0) - 0.17) < 1e-9)
        #expect(CostHistory(url: dir.appendingPathComponent("daily.jsonl"), tool: .claude).load(calendar: utc).isEmpty)
    }
}

private extension Data {
    /// The same summary as an individual account: `limitType` flipped to user.
    func replacingTeam() -> Data {
        Data(String(decoding: self, as: UTF8.self).replacingOccurrences(of: "\"limitType\":\"team\"", with: "\"limitType\":\"user\"").utf8)
    }
}
