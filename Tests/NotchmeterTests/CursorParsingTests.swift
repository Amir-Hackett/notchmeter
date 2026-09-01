import Foundation
import SQLite3
import Testing
@testable import Notchmeter

@Suite struct CursorParsing {
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
