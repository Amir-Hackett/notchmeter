import Foundation
import Testing
@testable import Notchmeter

/// A reading kept on screen after its tool stopped answering says how old it is, and a reset it has already
/// passed is not announced as imminent.
@Suite struct StaleReadingCopy {
    init() { Localization.use(language: "en") }

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    func date(_ day: Int, _ hour: Int, _ minute: Int, month: Int = 9) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute)))
    }

    @Test func onlyAToolThatStoppedAnsweringKeepsAStaleReading() {
        let reading = UsageReading(tool: .claude, windows: [], plan: nil, fetchedAt: Date(), observedAt: nil)
        #expect(ToolStatus.needsAttention("login expired", cached: reading).staleReading == reading)
        #expect(ToolStatus.failed("timed out", cached: reading).staleReading == reading)
        #expect(ToolStatus.failed("timed out", cached: nil).staleReading == nil)
        #expect(ToolStatus.ready(reading).staleReading == nil)
        #expect(ToolStatus.waiting.staleReading == nil)
        #expect(ToolStatus.idle("nothing yet").staleReading == nil)
    }

    @Test func namesTheTimeInTheUsersFormat() throws {
        let now = try date(1, 23, 10)
        let fetched = try date(1, 22, 52)
        #expect(StaleReading.line(fetchedAt: fetched, timeFormat: .twelveHour, now: now, calendar: calendar) == "Last reading 10:52 PM · may be out of date")
        #expect(StaleReading.line(fetchedAt: fetched, timeFormat: .twentyFourHour, now: now, calendar: calendar) == "Last reading 22:52 · may be out of date")
    }

    @Test func namesTheDayOnceTheReadingIsNotFromToday() throws {
        let now = try date(1, 23, 10)
        #expect(StaleReading.line(fetchedAt: try date(1, 0, 5), timeFormat: .twentyFourHour, now: now, calendar: calendar) == "Last reading 00:05 · may be out of date")
        #expect(StaleReading.line(fetchedAt: try date(31, 22, 52, month: 8), timeFormat: .twelveHour, now: now, calendar: calendar) == "Last reading yesterday at 10:52 PM · may be out of date")
        #expect(StaleReading.line(fetchedAt: try date(29, 9, 0, month: 8), timeFormat: .twentyFourHour, now: now, calendar: calendar) == "Last reading Aug 29 at 09:00 · may be out of date")
    }

    @Test func aPassedResetReadsAsPassedOnlyWhenTheReadingIsStale() throws {
        let now = try date(1, 23, 10)
        let passed = try date(1, 23, 0)
        let ahead = try date(2, 0, 10)
        #expect(ResetText.line(resetsAt: passed, hasLimit: true, display: .countdown, timeFormat: .auto, stale: true, now: now, calendar: calendar) == "Reset passed")
        #expect(ResetText.line(resetsAt: passed, hasLimit: true, display: .exact, timeFormat: .auto, stale: true, now: now, calendar: calendar) == "Reset passed")
        #expect(ResetText.line(resetsAt: passed, hasLimit: true, display: .exact, timeFormat: .auto, now: now, calendar: calendar) == "Resets now")
        #expect(ResetText.line(resetsAt: ahead, hasLimit: true, display: .countdown, timeFormat: .auto, stale: true, now: now, calendar: calendar) == "Resets in 1h")
        #expect(ResetText.line(resetsAt: nil, hasLimit: false, display: .exact, timeFormat: .auto, stale: true, now: now, calendar: calendar) == "No limit published")
    }
}

/// A rate-limit answer names the wait the app will really take. A vendor that asks for no delay at all still gets
/// the minute the store backs off for, so the line on the card and the line in the log are the same minute.
@Suite struct RateLimitBackoff {
    init() { Localization.use(language: "en") }

    @Test func theWaitNamedIsTheWaitTaken() {
        #expect(ProviderError.rateLimitWait(retryAfter: 0) == 60)
        #expect(ProviderError.rateLimitWait(retryAfter: nil) == 60)
        #expect(ProviderError.rateLimitWait(retryAfter: 15) == 60)
        #expect(ProviderError.rateLimitWait(retryAfter: 300) == 300)
        #expect(ProviderError.rateLimited(retryAfter: 0).message == "Rate limited, retrying in 60s")
        #expect(ProviderError.rateLimited(retryAfter: 300).message == "Rate limited, retrying in 300s")
        #expect(ProviderError.rateLimited(retryAfter: nil).message == "Rate limited, backing off")
    }
}

/// A reading carries no language of its own: a window's name travels as the key it will be looked up under, so a
/// reading cached in one language reads in whichever language shows it, and the advice built from it is whole.
@Suite struct CachedReadingLanguage {
    init() { Localization.use(language: "en") }

    @Test func aCachedWindowKeepsItsKeyRatherThanItsTranslation() throws {
        let json = """
        {"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":40,"reset_at":1759352940,"limit_window_seconds":18000},
         "secondary_window":{"used_percent":10,"reset_at":1759852940,"limit_window_seconds":604800}}}
        """
        let reading = try CodexProvider.parseBackend(Data(json.utf8))
        let encoded = try JSONEncoder().encode(reading)
        let root = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let windows = try #require(root["windows"] as? [[String: Any]])
        #expect(windows.map { ($0["label"] as? [String: Any])?["key"] as? String } == ["Session", "Weekly"])
        for language in Localization.languages {
            let table = try #require(Localization.table(language: language))
            #expect(table["Session"]?.isEmpty == false, "\(language) cannot name a session window")
        }
        let restored = try JSONDecoder().decode(UsageReading.self, from: encoded)
        #expect(restored == reading)
        #expect(restored.windows.map(\.label) == ["Session", "Weekly"])
    }

    @Test func aReadingCachedAsPlainTextStillReads() throws {
        let window = LimitWindow(id: "included", label: .key("Included usage"), usedFraction: 0.5, resetsAt: nil)
        let reading = UsageReading(tool: .cursor, windows: [window], plan: nil, fetchedAt: Date(), observedAt: nil)
        let text = String(decoding: try JSONEncoder().encode(reading), as: UTF8.self)
            .replacingOccurrences(of: #"{"key":"Included usage"}"#, with: #""Included usage""#)
        let restored = try JSONDecoder().decode(UsageReading.self, from: Data(text.utf8))
        #expect(restored.windows[0].name == .vendor("Included usage"))
        #expect(restored.windows[0].label == "Included usage")
    }

    @Test func aSentenceLowercasesTheTranslationAndNotTheVendorsWords() {
        #expect(WindowLabel.key("Weekly").inSentence == "weekly")
        #expect(WindowLabel.key("Included usage").inSentence == "included usage")
        #expect(WindowLabel.vendor("Gemini Pro").inSentence == "Gemini Pro")
        #expect(WindowLabel.filled("%@ org spend", [.text("Acme")]).inSentence == "Acme org spend")
        #expect(WindowLabel.filled("%ld-day", [.number(14)]).text == "14-day")
        #expect(WindowLabel.scoped(model: "Spark", of: .key("Session")).text == "Spark Session")
        #expect(WindowLabel.scoped(model: "Spark", of: .key("Session")).inSentence == "Spark session")
        let org = LimitWindow(id: "org_acme_spend", label: .filled("%@ org spend", [.text("Acme")]), usedFraction: 0.5, resetsAt: nil)
        #expect(Advisor.name(org) == "Acme org spend")
    }
}
