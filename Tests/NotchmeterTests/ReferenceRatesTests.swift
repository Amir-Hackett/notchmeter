import Foundation
import os
import Testing
@testable import Notchmeter

/// *Fetch today's rate*: the ECB's daily file read, the rate crossed through the euro, when a held rate is too old
/// to use, when a request is due, and what stands in when there is no usable rate. The file below is the ECB's own,
/// as it answered on 2026-09-24.
@Suite struct ReferenceRateParsing {
    static let daily = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01" xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">
    \t<gesmes:subject>Reference rates</gesmes:subject>
    \t<gesmes:Sender>
    \t\t<gesmes:name>European Central Bank</gesmes:name>
    \t</gesmes:Sender>
    \t<Cube>
    \t\t<Cube time='2026-09-24'>
    \t\t\t<Cube currency='USD' rate='1.1367'/>
    \t\t\t<Cube currency='JPY' rate='180.57'/>
    \t\t\t<Cube currency='CZK' rate='24.399'/>
    \t\t\t<Cube currency='DKK' rate='7.4756'/>
    \t\t\t<Cube currency='GBP' rate='0.85986'/>
    \t\t\t<Cube currency='HUF' rate='366.15'/>
    \t\t\t<Cube currency='PLN' rate='4.3823'/>
    \t\t\t<Cube currency='RON' rate='5.2779'/>
    \t\t\t<Cube currency='SEK' rate='11.2645'/>
    \t\t\t<Cube currency='CHF' rate='0.9409'/>
    \t\t\t<Cube currency='ISK' rate='138.00'/>
    \t\t\t<Cube currency='NOK' rate='10.7895'/>
    \t\t\t<Cube currency='TRY' rate='55.5332'/>
    \t\t\t<Cube currency='AUD' rate='1.6177'/>
    \t\t\t<Cube currency='BRL' rate='5.8890'/>
    \t\t\t<Cube currency='CAD' rate='1.6047'/>
    \t\t\t<Cube currency='CNY' rate='7.6302'/>
    \t\t\t<Cube currency='HKD' rate='8.9148'/>
    \t\t\t<Cube currency='IDR' rate='20384.10'/>
    \t\t\t<Cube currency='ILS' rate='3.4649'/>
    \t\t\t<Cube currency='INR' rate='109.0775'/>
    \t\t\t<Cube currency='KRW' rate='1555.69'/>
    \t\t\t<Cube currency='MXN' rate='19.9878'/>
    \t\t\t<Cube currency='MYR' rate='4.6457'/>
    \t\t\t<Cube currency='NZD' rate='2.0049'/>
    \t\t\t<Cube currency='PHP' rate='71.328'/>
    \t\t\t<Cube currency='SGD' rate='1.4549'/>
    \t\t\t<Cube currency='THB' rate='38.057'/>
    \t\t\t<Cube currency='ZAR' rate='18.6836'/>
    \t\t</Cube>
    \t</Cube>
    </gesmes:Envelope>
    """

    static let fetchedAt = Date(timeIntervalSince1970: 1_790_000_000)

    static func rates() throws -> ReferenceRates {
        try #require(ECBRates.parse(Data(daily.utf8), fetchedAt: fetchedAt))
    }

    @Test func theDailyFileReadsAsItsDayAndEveryCurrency() throws {
        let rates = try Self.rates()
        #expect(rates.day == "2026-09-24")
        let count = rates.perEuro.count
        #expect(count == 29)
        #expect(rates.perEuro["USD"] == 1.1367)
        #expect(rates.perEuro["JPY"] == 180.57)
        #expect(rates.perEuro["EUR"] == nil)
        #expect(rates.fetchedAt == Self.fetchedAt)
    }

    /// Every rate is crossed through the euro: units per euro over dollars per euro.
    @Test func aRatePerDollarIsTheECBsTwoFiguresDivided() throws {
        let rates = try Self.rates()
        let euro = 1 / 1.1367
        let pound = 0.85986 / 1.1367
        let yen = 180.57 / 1.1367
        #expect(rates.perDollar("USD") == 1)
        #expect(rates.perDollar("EUR") == euro)
        #expect(rates.perDollar("GBP") == pound)
        #expect(rates.perDollar("JPY") == yen)
        // Currencies the app's own languages use that the ECB does not publish.
        #expect(rates.perDollar("VND") == nil)
        #expect(rates.perDollar("RUB") == nil)
        #expect(rates.perDollar("TWD") == nil)
    }

    @Test func aFileThatIsNotTheECBsReadsAsNothing() {
        #expect(ECBRates.parse(Data(), fetchedAt: Self.fetchedAt) == nil)
        #expect(ECBRates.parse(Data("<html><body>Maintenance</body></html>".utf8), fetchedAt: Self.fetchedAt) == nil)
        #expect(ECBRates.parse(Data("{\"rates\": {}}".utf8), fetchedAt: Self.fetchedAt) == nil)
        // No dollar: nothing else could be crossed.
        let noDollar = "<Envelope><Cube><Cube time='2026-09-24'><Cube currency='GBP' rate='0.85986'/></Cube></Cube></Envelope>"
        #expect(ECBRates.parse(Data(noDollar.utf8), fetchedAt: Self.fetchedAt) == nil)
        // No day, or one that is not a day.
        let noDay = "<Envelope><Cube><Cube><Cube currency='USD' rate='1.1'/></Cube></Cube></Envelope>"
        #expect(ECBRates.parse(Data(noDay.utf8), fetchedAt: Self.fetchedAt) == nil)
        let badDay = "<Envelope><Cube><Cube time='2026-13-45'><Cube currency='USD' rate='1.1'/></Cube></Cube></Envelope>"
        #expect(ECBRates.parse(Data(badDay.utf8), fetchedAt: Self.fetchedAt) == nil)
        // Cut off mid-file.
        #expect(ECBRates.parse(Data(Self.daily.prefix(400).utf8), fetchedAt: Self.fetchedAt) == nil)
        // Far larger than the file ever is.
        #expect(ECBRates.parse(Data(repeating: 0x20, count: ECBRates.largest + 1), fetchedAt: Self.fetchedAt) == nil)
    }

    /// An entry that does not read is dropped and the rest of the file kept; a second day (the ECB's history files
    /// list the newest first) is not mixed into the first.
    @Test func aBadEntryIsSkippedAndOnlyTheFirstDayIsRead() throws {
        let xml = """
        <Envelope><Cube>
        <Cube time='2026-09-24'>
        <Cube currency='USD' rate='1.1367'/><Cube currency='GBP' rate='abc'/><Cube currency='jpy' rate='180'/>
        <Cube currency='CHF' rate='-1'/><Cube currency='SEKX' rate='11'/><Cube currency='NOK' rate='10.7895'/>
        </Cube>
        <Cube time='2026-09-23'><Cube currency='USD' rate='1.2'/><Cube currency='GBP' rate='0.9'/></Cube>
        </Cube></Envelope>
        """
        let rates = try #require(ECBRates.parse(Data(xml.utf8), fetchedAt: Self.fetchedAt))
        #expect(rates.day == "2026-09-24")
        #expect(rates.perEuro == ["USD": 1.1367, "NOK": 10.7895])
    }

    /// No year while it is this one; a rate kept stale can be from last year, and then "Dec 30" would read as
    /// this year's.
    @Test func theDayIsNamedWithTheYearOnlyWhenItIsNotThisOne() {
        Localization.use(language: "en")
        let today = ReferenceRateStaleness.noon("2026-09-25")
        #expect(ReferenceRates.dayText("2026-09-24", now: today) == "Sep 24")
        #expect(ReferenceRates.dayText("2025-12-30", now: ReferenceRateStaleness.noon("2026-01-05")) == "Dec 30, 2025")
        #expect(ReferenceRates.dayText("not a day", now: today) == "not a day")
        // The same day named twice comes from one formatter, not one per call.
        #expect(ReferenceRates.dayText("2026-09-24", now: today) == ReferenceRates.dayText("2026-09-24", now: today))
    }

    /// The ECB publishes around 16:00 CET on TARGET working days: the next publication after a day's rates is
    /// 16:30 in Frankfurt on the next weekday, summer time included.
    @Test func theNextPublicationIsTheNextWeekdayAfternoonInFrankfurt() {
        func rates(_ day: String) -> ReferenceRates { ReferenceRateStaleness.rates(day: day) }
        // Thursday to Friday, in CEST (UTC+2): 16:30 is 14:30 UTC.
        let friday = ReferenceRates.date(of: "2026-09-25")!.addingTimeInterval(14.5 * 3600)
        #expect(rates("2026-09-24").nextPublication() == friday)
        // Friday to Monday over the weekend.
        let monday = ReferenceRates.date(of: "2026-09-21")!.addingTimeInterval(14.5 * 3600)
        #expect(rates("2026-09-18").nextPublication() == monday)
        // In winter (CET, UTC+1): 16:30 is 15:30 UTC.
        let februaryMonday = ReferenceRates.date(of: "2026-02-02")!.addingTimeInterval(15.5 * 3600)
        #expect(rates("2026-01-30").nextPublication() == februaryMonday)
        #expect(ReferenceRates(day: "never", perEuro: [:], fetchedAt: Self.fetchedAt).nextPublication() == nil)
    }
}

@Suite struct ReferenceRateStaleness {
    static func rates(day: String, fetchedAt: Date = Date(timeIntervalSince1970: 0)) -> ReferenceRates {
        ReferenceRates(day: day, perEuro: ["USD": 1.1367, "GBP": 0.85986], fetchedAt: fetchedAt)
    }

    static func noon(_ day: String) -> Date {
        ReferenceRates.date(of: day)!.addingTimeInterval(12 * 3600)
    }

    /// A week covers the longest regular closing (Easter: Thursday's rate is the newest until Tuesday), and the
    /// day after that week the rate gives way.
    @Test func aRateIsUsedForAWeekAfterItsDayAndNotAfter() {
        let rates = Self.rates(day: "2026-04-02")
        #expect(rates.daysOld(now: Self.noon("2026-04-02")) == 0)
        #expect(rates.daysOld(now: Self.noon("2026-04-07")) == 5)
        #expect(!rates.isTooOld(now: Self.noon("2026-04-07")))
        #expect(!rates.isTooOld(now: Self.noon("2026-04-09")))
        #expect(rates.isTooOld(now: Self.noon("2026-04-10")))
        // A day ahead of the clock is not negative days old.
        #expect(rates.daysOld(now: Self.noon("2026-04-01")) == 0)
    }

    @Test func aRequestIsDueDailyAfterOneThatReadAndSoonerAfterOneThatDidNot() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let hour: TimeInterval = 3600
        let never = ReferenceRateCache()
        // Nothing is asked with the switch off, or in dollars, which need no rate.
        #expect(!RateRefresh.isDue(fetch: false, code: "EUR", cache: never, now: now))
        #expect(!RateRefresh.isDue(fetch: true, code: "USD", cache: never, now: now))
        #expect(!RateRefresh.isDue(fetch: true, code: "", cache: never, now: now))
        #expect(RateRefresh.isDue(fetch: true, code: "EUR", cache: never, now: now))
        // A read is good for a day.
        let read = ReferenceRateCache(rates: Self.rates(day: "2026-09-24"), lastAttempt: now, failures: 0)
        #expect(!RateRefresh.isDue(fetch: true, code: "EUR", cache: read, now: now.addingTimeInterval(23 * hour)))
        #expect(RateRefresh.isDue(fetch: true, code: "EUR", cache: read, now: now.addingTimeInterval(24 * hour)))
        // A failure is tried again after an hour, doubling each time, never more than a day apart.
        let failed = ReferenceRateCache(rates: nil, lastAttempt: now, failures: 1)
        #expect(!RateRefresh.isDue(fetch: true, code: "EUR", cache: failed, now: now.addingTimeInterval(59 * 60)))
        #expect(RateRefresh.isDue(fetch: true, code: "EUR", cache: failed, now: now.addingTimeInterval(hour)))
        #expect(RateRefresh.wait(after: 0) == 24 * hour)
        #expect(RateRefresh.wait(after: 1) == hour)
        #expect(RateRefresh.wait(after: 3) == 4 * hour)
        #expect(RateRefresh.wait(after: 5) == 16 * hour)
        #expect(RateRefresh.wait(after: 6) == 24 * hour)
        #expect(RateRefresh.wait(after: 400) == 24 * hour)
        // A clock that went back is not waited out.
        let ahead = ReferenceRateCache(rates: nil, lastAttempt: now.addingTimeInterval(10 * hour), failures: 0)
        #expect(RateRefresh.isDue(fetch: true, code: "EUR", cache: ahead, now: now))
    }

    /// A request that was started and never answered (the app quit while it was in flight) has not failed, so a
    /// relaunch asks at once rather than treating it as one and waiting the hour; a request that came back empty
    /// is the failure and waits.
    @Test func aRequestNeverAnsweredIsAskedAgainAtOnce() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let unanswered = ReferenceRateCache(rates: nil, lastAttempt: now.addingTimeInterval(-5), failures: 0)
        #expect(unanswered.isUnanswered)
        #expect(RateRefresh.isDue(fetch: true, code: "EUR", cache: unanswered, now: now))
        let answeredEmpty = ReferenceRateCache(rates: nil, lastAttempt: now.addingTimeInterval(-5), failures: 1)
        #expect(!answeredEmpty.isUnanswered)
        #expect(!RateRefresh.isDue(fetch: true, code: "EUR", cache: answeredEmpty, now: now))
        // With rates held, a refresh that never came back is not an emergency: the held rate serves for the day.
        let refreshing = ReferenceRateCache(rates: Self.rates(day: "2026-09-24"), lastAttempt: now.addingTimeInterval(-5), failures: 0)
        #expect(!refreshing.isUnanswered)
        #expect(!RateRefresh.isDue(fetch: true, code: "EUR", cache: refreshing, now: now))
    }

    /// The day's wait alone would anchor every request to the hour the switch was turned on, and a Mac asking each
    /// morning would never see the day's rate on the day. So a request is also due once the ECB is expected to have
    /// published a newer file than the one held, unless one was made since; and that fires once per publication.
    @Test func aRequestIsDueOnceTheECBHasPublishedANewerDay() {
        func cest(_ day: String, _ hour: Double) -> Date { ReferenceRates.date(of: day)!.addingTimeInterval((hour - 2) * 3600) }
        func due(held: String, asked: Date, now: Date, failures: Int = 0) -> Bool {
            RateRefresh.isDue(fetch: true, code: "EUR", cache: ReferenceRateCache(rates: Self.rates(day: held), lastAttempt: asked, failures: failures), now: now)
        }
        // Monday's rate held, asked Tuesday 09:00 CEST: not due at 15:00, due at 16:45 once Tuesday's is out.
        #expect(!due(held: "2026-09-21", asked: cest("2026-09-22", 9), now: cest("2026-09-22", 15)))
        #expect(due(held: "2026-09-21", asked: cest("2026-09-22", 9), now: cest("2026-09-22", 16.75)))
        // Asked after the publication already (and got Monday's again, a holiday): not again that day.
        #expect(!due(held: "2026-09-21", asked: cest("2026-09-22", 16.6), now: cest("2026-09-22", 16.85)))
        // A failed answer since the publication is the backoff's to retry, not this rule's.
        #expect(!due(held: "2026-09-21", asked: cest("2026-09-22", 16.6), now: cest("2026-09-22", 16.85), failures: 1))
        #expect(due(held: "2026-09-21", asked: cest("2026-09-22", 16.6), now: cest("2026-09-22", 17.7), failures: 1))
        // Friday's rate held over the weekend: nothing is published on Sunday, so nothing is due before Monday.
        #expect(!due(held: "2026-09-18", asked: cest("2026-09-19", 17), now: cest("2026-09-20", 16.75)))
        #expect(due(held: "2026-09-18", asked: cest("2026-09-21", 9), now: cest("2026-09-21", 16.75)))
        // Nothing held: only the daily wait applies.
        let bare = ReferenceRateCache(rates: nil, lastAttempt: cest("2026-09-22", 9), failures: 1)
        #expect(!RateRefresh.isDue(fetch: true, code: "EUR", cache: bare, now: cest("2026-09-22", 9.5)))
    }
}

/// What converts the figures: the typed rate by default, the ECB's when it is on and usable, and the typed rate
/// again, with its reason, whenever the ECB's is not.
@Suite struct CurrencyFallback {
    static let now = ReferenceRateStaleness.noon("2026-09-25")
    static let fresh = ReferenceRateStaleness.rates(day: "2026-09-24", fetchedAt: now.addingTimeInterval(-7200))

    @Test func theTypedRateIsTheDefaultAndDollarsNeedNone() {
        let cache = ReferenceRateCache(rates: Self.fresh, lastAttempt: Self.now, failures: 0)
        #expect(CurrencyConversion.resolve(code: "usd", typed: 0.9, fetch: true, cache: cache, now: Self.now)
            == CurrencyConversion(code: "USD", rate: 1, source: .dollars))
        #expect(CurrencyConversion.resolve(code: "EUR", typed: 0.9, fetch: false, cache: cache, now: Self.now)
            == CurrencyConversion(code: "EUR", rate: 0.9, source: .typed))
        // A rate that cannot convert anything is one.
        #expect(CurrencyConversion.resolve(code: "EUR", typed: 0, fetch: false, cache: cache, now: Self.now).rate == 1)
        #expect(CurrencyConversion.resolve(code: "EUR", typed: .nan, fetch: false, cache: cache, now: Self.now).rate == 1)
    }

    @Test func theECBsRateConvertsWhileItIsOnAndUsable() {
        let cache = ReferenceRateCache(rates: Self.fresh, lastAttempt: Self.now, failures: 0)
        let euro = 1 / 1.1367
        let resolved = CurrencyConversion.resolve(code: " eur ", typed: 0.9, fetch: true, cache: cache, now: Self.now)
        #expect(resolved == CurrencyConversion(code: "EUR", rate: euro, source: .reference(day: "2026-09-24", fetchedAt: Self.fresh.fetchedAt)))
        // A failure since does not take away a rate that is still usable.
        let failedSince = ReferenceRateCache(rates: Self.fresh, lastAttempt: Self.now, failures: 3)
        #expect(CurrencyConversion.resolve(code: "EUR", typed: 0.9, fetch: true, cache: failedSince, now: Self.now).rate == euro)
    }

    @Test func theTypedRateStandsInWithItsReason() {
        func resolve(_ code: String, _ cache: ReferenceRateCache, now: Date = Self.now) -> CurrencyConversion {
            CurrencyConversion.resolve(code: code, typed: 0.9, fetch: true, cache: cache, now: now)
        }
        #expect(resolve("EUR", ReferenceRateCache()) == CurrencyConversion(code: "EUR", rate: 0.9, source: .fallback(.notYet)))
        #expect(resolve("EUR", ReferenceRateCache(rates: nil, lastAttempt: Self.now, failures: 2)).source == .fallback(.unreachable))
        let cache = ReferenceRateCache(rates: Self.fresh, lastAttempt: Self.now, failures: 0)
        #expect(resolve("VND", cache) == CurrencyConversion(code: "VND", rate: 0.9, source: .fallback(.unpublished)))
        let later = ReferenceRateStaleness.noon("2026-10-02")
        #expect(resolve("EUR", cache, now: later) == CurrencyConversion(code: "EUR", rate: 0.9, source: .fallback(.tooOld(day: "2026-09-24"))))
    }

    /// *Rate per dollar* starts at 1, which converts nothing, so it is no rate of the user's own. With none set, a
    /// held ECB rate past its week stays in use and is marked stale rather than giving way to 1:1; where there is
    /// no ECB rate at all, 1 stands in and the conversion says a rate is wanted.
    @Test func withNoRateOfTheirOwnAWeekOldECBRateStaysInUseAndIsMarkedStale() {
        #expect(CurrencyConversion.ownRate(0.9) == 0.9)
        #expect(CurrencyConversion.ownRate(1) == nil)
        #expect(CurrencyConversion.ownRate(0) == nil)
        #expect(CurrencyConversion.ownRate(-2) == nil)
        #expect(CurrencyConversion.ownRate(.infinity) == nil)
        let cache = ReferenceRateCache(rates: Self.fresh, lastAttempt: Self.now, failures: 0)
        let later = ReferenceRateStaleness.noon("2026-10-02")
        let euro = 1 / 1.1367
        let stale = CurrencyConversion.resolve(code: "EUR", typed: 1, fetch: true, cache: cache, now: later)
        #expect(stale == CurrencyConversion(code: "EUR", rate: euro, source: .stale(day: "2026-09-24", fetchedAt: Self.fresh.fetchedAt)))
        #expect(!stale.standsInWithoutOwnRate)
        // Months on it is still the ECB's rate, and still says so.
        let muchLater = ReferenceRateStaleness.noon("2026-12-24")
        #expect(CurrencyConversion.resolve(code: "EUR", typed: 1, fetch: true, cache: cache, now: muchLater).source == .stale(day: "2026-09-24", fetchedAt: Self.fresh.fetchedAt))
        // A rate of their own, and the week's rule holds as before.
        #expect(CurrencyConversion.resolve(code: "EUR", typed: 0.9, fetch: true, cache: cache, now: later).source == .fallback(.tooOld(day: "2026-09-24")))
        // Within the week the ECB's rate is simply the ECB's rate, whatever the typed one.
        #expect(CurrencyConversion.resolve(code: "EUR", typed: 1, fetch: true, cache: cache, now: Self.now).source == .reference(day: "2026-09-24", fetchedAt: Self.fresh.fetchedAt))
        // No ECB rate and none of their own: 1 stands in, and Settings is told to ask for one.
        let notYet = CurrencyConversion.resolve(code: "EUR", typed: 1, fetch: true, cache: ReferenceRateCache(), now: Self.now)
        #expect(notYet == CurrencyConversion(code: "EUR", rate: 1, source: .fallback(.notYet)))
        #expect(notYet.standsInWithoutOwnRate)
        let dong = CurrencyConversion.resolve(code: "VND", typed: 1, fetch: true, cache: cache, now: Self.now)
        #expect(dong.standsInWithoutOwnRate)
        #expect(!CurrencyConversion.resolve(code: "VND", typed: 25_000, fetch: true, cache: cache, now: Self.now).standsInWithoutOwnRate)
        #expect(!CurrencyConversion.resolve(code: "EUR", typed: 1, fetch: false, cache: cache, now: Self.now).standsInWithoutOwnRate)
        // What the figures and Settings say of a stale rate, and the oracle.
        Localization.use(language: "en")
        let rate = CurrencyConversion.rateText(euro)
        #expect(stale.note == "EUR at \(rate) per US dollar, the ECB reference rate of Sep 24, over a week old")
        #expect(stale.settingsLine(now: later) == "\(rate) per US dollar, the ECB reference rate of Sep 24, over a week old and still in use: no rate of your own is set to stand in.")
        #expect(stale.oracleFields["source"] as? String == "stale")
        #expect(stale.oracleFields["day"] as? String == "2026-09-24")
        #expect(Set(stale.oracleFields.keys) == ["code", "rate", "source", "day"])
    }

    /// The line beside converted figures names the rate and its day; with fetching off there is no line, which is
    /// the card as it was before the switch existed.
    @Test func theNoteNamesTheRateAndItsDay() {
        Localization.use(language: "en")
        let reference = CurrencyConversion(code: "EUR", rate: 1 / 1.1367, source: .reference(day: "2026-09-24", fetchedAt: Self.fresh.fetchedAt))
        let rate = CurrencyConversion.rateText(1 / 1.1367)
        #expect(reference.note == "EUR at \(rate) per US dollar, the ECB reference rate of Sep 24")
        #expect(reference.settingsLine(now: Self.now) == "\(rate) per US dollar, the ECB reference rate of Sep 24, fetched 2h ago.")
        let own = CurrencyConversion(code: "VND", rate: 25_000, source: .fallback(.unpublished))
        #expect(own.note == "VND at your own rate of \(CurrencyConversion.rateText(25_000)) per US dollar")
        #expect(own.settingsLine()?.hasPrefix("The ECB publishes no rate for VND") == true)
        #expect(CurrencyConversion(code: "EUR", rate: 0.9, source: .typed).note == nil)
        #expect(CurrencyConversion(code: "USD", rate: 1, source: .dollars).note == nil)
        #expect(CurrencyConversion(code: "EUR", rate: 0.9, source: .fallback(.notYet)).settingsLine() == "Not fetched yet; your own rate (\(CurrencyConversion.rateText(0.9))) stands in.")
        #expect(CurrencyConversion(code: "EUR", rate: 0.9, source: .fallback(.tooOld(day: "2026-09-10"))).settingsLine()?.contains("Sep 10") == true)
        #expect(CurrencyConversion(code: "EUR", rate: 0.9, source: .fallback(.unreachable)).settingsLine()?.contains("could not be reached") == true)
        // German, French, Portuguese and Russian abbreviate the month with a full stop of their own ("24. Sept.",
        // "24 sept.", "24 de set.", "24 сент."), and German its hours too ("vor 2 Std."), so no line may end on the
        // day or the time, or it ends "Sept.." on the screen. Every language, every line that names the day.
        defer { Localization.use(language: "en") }
        let stale = CurrencyConversion(code: "EUR", rate: 1 / 1.1367, source: .stale(day: "2025-12-30", fetchedAt: Self.fresh.fetchedAt))
        let tooOld = CurrencyConversion(code: "EUR", rate: 0.9, source: .fallback(.tooOld(day: "2026-09-10")))
        for language in Localization.languages {
            Localization.use(language: language)
            for line in [reference.note, reference.settingsLine(now: Self.now), stale.note, stale.settingsLine(now: Self.now), tooOld.settingsLine(now: Self.now)] {
                #expect(line?.contains("..") == false, "\(language): \(line ?? "nil")")
            }
        }
        Localization.use(language: "de")
        #expect(reference.settingsLine(now: Self.now) == "Referenzkurs der EZB vom 24. Sept., abgerufen vor 2 Std.: \(CurrencyConversion.rateText(1 / 1.1367)) pro US-Dollar.")
    }

    @Test func theOracleHearsTheSourceAndTheReasonNeverMore() {
        let reference = CurrencyConversion(code: "EUR", rate: 0.88, source: .reference(day: "2026-09-24", fetchedAt: Self.now))
        #expect(reference.oracleFields["source"] as? String == "reference")
        #expect(reference.oracleFields["day"] as? String == "2026-09-24")
        let stale = CurrencyConversion(code: "EUR", rate: 0.9, source: .fallback(.tooOld(day: "2026-09-10")))
        #expect(stale.oracleFields["reason"] as? String == "tooOld")
        #expect(Set(stale.oracleFields.keys) == ["code", "rate", "source", "reason", "day"])
    }
}

/// The switch, the cache and the fetcher against a defaults suite of their own, with the request replaced.
@MainActor @Suite struct CurrencyOptIn {
    func withSuite(_ name: String, _ body: (UserDefaults) async throws -> Void) async rethrows {
        let suite = "NotchmeterTests.CurrencyOptIn.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            Money.configure(code: "USD", rate: 1)
        }
        try await body(defaults)
    }

    @Test func fetchingIsOffUntilAskedForAndTheTypedRateConverts() async {
        await withSuite("default") { defaults in
            let prefs = Preferences(defaults: defaults)
            #expect(!prefs.fetchCurrencyRate)
            prefs.currencyCode = "EUR"
            prefs.currencyRate = 0.9
            #expect(prefs.currencyConversion.source == .typed)
            #expect(Money.rate == 0.9)
            // Off, the fetcher asks for nothing however long it waits.
            var asked = 0
            let fetcher = ReferenceRateFetcher(prefs: prefs) { asked += 1; return nil }
            #expect(await fetcher.refreshIfDue() == false)
            #expect(asked == 0)
            #expect(defaults.data(forKey: ReferenceRateCache.defaultsKey) == nil)
        }
    }

    @Test func aReadSwitchesToTheECBsRateAndIsKeptForTheDay() async throws {
        let rates = try ReferenceRateParsing.rates()
        await withSuite("read") { defaults in
            let prefs = Preferences(defaults: defaults)
            prefs.currencyCode = "GBP"
            prefs.currencyRate = 0.8
            prefs.fetchCurrencyRate = true
            #expect(prefs.currencyConversion.source == .fallback(.notYet))
            var asked = 0
            let fetcher = ReferenceRateFetcher(prefs: prefs) { asked += 1; return rates }
            let now = ReferenceRateStaleness.noon("2026-09-24")
            #expect(await fetcher.refreshIfDue(now: now))
            #expect(asked == 1)
            let pound = 0.85986 / 1.1367
            #expect(prefs.currencyConversion.rate == pound)
            #expect(Money.rate == pound)
            // Not again the same day, nor after a switch to another currency the file already holds.
            prefs.currencyCode = "EUR"
            #expect(await fetcher.refreshIfDue(now: now.addingTimeInterval(3600)) == false)
            #expect(asked == 1)
            #expect(prefs.currencyConversion.source == .reference(day: "2026-09-24", fetchedAt: rates.fetchedAt))
            // Kept across a relaunch.
            let relaunched = Preferences(defaults: defaults)
            #expect(relaunched.referenceRateCache.rates == rates)
            #expect(relaunched.fetchCurrencyRate)
            // Off again is the typed rate again, with the rates still held.
            prefs.fetchCurrencyRate = false
            #expect(prefs.currencyConversion == CurrencyConversion(code: "EUR", rate: 0.8, source: .typed))
        }
    }

    @Test func aFailureKeepsTheTypedRateAndIsTriedAgainLater() async throws {
        let rates = try ReferenceRateParsing.rates()
        await withSuite("failure") { defaults in
            let prefs = Preferences(defaults: defaults)
            prefs.currencyCode = "EUR"
            prefs.currencyRate = 0.9
            prefs.fetchCurrencyRate = true
            var answer: ReferenceRates?
            let fetcher = ReferenceRateFetcher(prefs: prefs) { answer }
            let now = ReferenceRateStaleness.noon("2026-09-24")
            #expect(await fetcher.refreshIfDue(now: now))
            #expect(prefs.currencyConversion == CurrencyConversion(code: "EUR", rate: 0.9, source: .fallback(.unreachable)))
            #expect(prefs.referenceRateCache.failures == 1)
            #expect(await fetcher.refreshIfDue(now: now.addingTimeInterval(30 * 60)) == false)
            answer = rates
            #expect(await fetcher.refreshIfDue(now: now.addingTimeInterval(3600)))
            #expect(prefs.referenceRateCache.failures == 0)
            #expect(prefs.currencyConversion.rate == 1 / 1.1367)
            // A later failure leaves the rate that read in use, until it is a week old.
            answer = nil
            let tomorrow = now.addingTimeInterval(25 * 3600)
            #expect(await fetcher.refreshIfDue(now: tomorrow))
            #expect(prefs.currencyConversion.source == .reference(day: "2026-09-24", fetchedAt: rates.fetchedAt))
            let tenDaysOn = ReferenceRateStaleness.noon("2026-10-04")
            await fetcher.refreshIfDue(now: tenDaysOn)
            #expect(prefs.currencyConversion == CurrencyConversion(code: "EUR", rate: 0.9, source: .fallback(.tooOld(day: "2026-09-24"))))
            #expect(Money.rate == 0.9)
        }
    }

    /// Holds the stubbed request open until the test lets it answer.
    @MainActor final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func open() { continuation?.resume(); continuation = nil }
    }

    /// Lets the main actor turn over until the condition holds, or a couple of seconds pass, whichever is first.
    func until(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// Lets whatever the last change queued on the main actor run.
    func settle() async {
        try? await Task.sleep(for: .milliseconds(100))
    }

    /// While the first request is in flight nothing has failed: a re-resolve meanwhile (the code changing) reads
    /// "not fetched yet", not "could not be reached"; a second look makes no second request; and the answer lands
    /// when it comes. A request the app quit during is the same cache with nobody in flight, and is asked again at
    /// once (`ReferenceRateStaleness`).
    @Test func aRequestInFlightHasNotFailed() async throws {
        let rates = try ReferenceRateParsing.rates()
        await withSuite("inflight") { defaults in
            let prefs = Preferences(defaults: defaults)
            prefs.currencyCode = "EUR"
            prefs.fetchCurrencyRate = true
            let gate = Gate()
            var asked = 0
            let fetcher = ReferenceRateFetcher(prefs: prefs) { asked += 1; await gate.wait(); return rates }
            let now = ReferenceRateStaleness.noon("2026-09-24")
            let request = Task { await fetcher.refreshIfDue(now: now) }
            await until { asked == 1 }
            #expect(asked == 1)
            #expect(prefs.referenceRateCache.isUnanswered)
            #expect(prefs.referenceRateCache.failures == 0)
            prefs.currencyCode = "GBP"
            #expect(prefs.currencyConversion == CurrencyConversion(code: "GBP", rate: 1, source: .fallback(.notYet)))
            #expect(prefs.currencyConversion.standsInWithoutOwnRate)
            #expect(await fetcher.refreshIfDue(now: now) == false)
            #expect(asked == 1)
            gate.open()
            #expect(await request.value)
            #expect(prefs.currencyConversion.source == .reference(day: "2026-09-24", fetchedAt: rates.fetchedAt))
            #expect(!prefs.referenceRateCache.isUnanswered)
        }
    }

    /// Started, the fetcher watches the switch and the code: turning the switch on asks at once rather than at the
    /// next quarter hour, and the watch re-arms, so a later change is looked at too.
    @Test func turningTheSwitchOnAsksAtOnce() async {
        await withSuite("observe") { defaults in
            let prefs = Preferences(defaults: defaults)
            prefs.currencyCode = "EUR"
            // Dated against the clock, since the fetcher looks at the real one here.
            let rates = DemoFixtures.referenceRates(now: Date())
            var asked = 0
            let fetcher = ReferenceRateFetcher(prefs: prefs) { asked += 1; return rates }
            fetcher.start()
            defer { fetcher.stop() }
            await settle()
            #expect(asked == 0)
            prefs.fetchCurrencyRate = true
            await until { asked == 1 }
            #expect(asked == 1)
            #expect(prefs.currencyConversion.source == .reference(day: rates.day, fetchedAt: rates.fetchedAt))
            // Still watched after the first change: a code the file holds is looked at and needs no request.
            prefs.currencyCode = "GBP"
            await settle()
            #expect(asked == 1)
            let pound = 0.85986 / 1.1367
            #expect(prefs.currencyConversion.rate == pound)
        }
    }
}

/// The request itself, against a session whose protocol is a stub of the ECB: the headers it carries and no
/// others, no cookie though one is held for the host, and nothing read from a wrong status or a body too large.
/// docs/privacy.md states each of these as fact.
@Suite struct ReferenceRateRequest {
    final class ECBStub: URLProtocol {
        struct Exchange {
            var status = 200
            var body = Data()
            var seen: [URLRequest] = []
        }
        static let exchange = OSAllocatedUnfairLock(initialState: Exchange())

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            let (status, body) = Self.exchange.withLock { state -> (Int, Data) in
                state.seen.append(request)
                return (state.status, state.body)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/xml"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    /// An ephemeral session like the app's, answered by the stub.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ECBStub.self]
        return URLSession(configuration: configuration)
    }

    func answer(status: Int, body: Data) async -> (rates: ReferenceRates?, request: URLRequest?) {
        ECBStub.exchange.withLock { $0 = ECBStub.Exchange(status: status, body: body) }
        let rates = await ECBRates.fetch(session: Self.session())
        return (rates, ECBStub.exchange.withLock { $0.seen.last })
    }

    @Test func theRequestIsOneGETWithThreeHeadersAndNoCookie() async throws {
        let answered = await answer(status: 200, body: Data(ReferenceRateParsing.daily.utf8))
        #expect(answered.rates?.day == "2026-09-24")
        #expect(answered.rates?.perEuro.count == 29)
        let request = try #require(answered.request)
        #expect(request.httpMethod == "GET")
        #expect(request.url == ECBRates.url)
        #expect(request.httpBody == nil)
        #expect(request.allHTTPHeaderFields?.keys.sorted() == ["Accept", "Accept-Language", "User-Agent"])
        #expect(request.value(forHTTPHeaderField: "User-Agent") == AppInfo.userAgent)
        #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/xml, text/xml")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.timeoutInterval == 20)
        // A protocol class sees the request as the app made it, before the loader's own cookie handling, so what
        // pins "no cookie sent or kept" is the flag that handling reads: off, the loader neither adds the jar's
        // cookies to the request nor keeps a Set-Cookie from the answer. And the jar the app's session would use
        // is an ephemeral one of its own, never the Mac's shared one.
        #expect(!request.httpShouldHandleCookies)
        #expect(NetworkSession.shared.configuration.httpCookieStorage !== HTTPCookieStorage.shared)
    }

    @Test func aWrongStatusOrAnOversizeBodyReadsAsNothing() async {
        let file = Data(ReferenceRateParsing.daily.utf8)
        #expect(await answer(status: 500, body: file).rates == nil)
        #expect(await answer(status: 304, body: Data()).rates == nil)
        #expect(await answer(status: 404, body: Data("<html>not here</html>".utf8)).rates == nil)
        let oversize = Data(repeating: 0x20, count: 300 * 1024)
        #expect(await answer(status: 200, body: oversize).rates == nil)
        #expect(await answer(status: 200, body: Data("<html>Maintenance</html>".utf8)).rates == nil)
    }
}
