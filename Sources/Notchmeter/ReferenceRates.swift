import Foundation
import os

private let log = Logger(subsystem: "com.amirhackett.notchmeter", category: "rates")

/// The European Central Bank's euro foreign exchange reference rates for one day, as its daily file publishes them
/// (docs/accuracy.md, *Currency*): units of each currency per euro, around thirty currencies, set at the central
/// banks' 14:10 CET concertation and published around 16:00 CET on every TARGET working day. The ECB says they are
/// "published for information purposes only", which is the use made of them here: a label on an estimate.
///
/// Every figure the app computes is in US dollars, so a rate for another currency is crossed through the euro:
/// units of it per euro over dollars per euro. That is the ECB's own two figures divided, not a rate of ours.
struct ReferenceRates: Codable, Equatable, Sendable {
    /// The day the rates are for, as the ECB writes it ("2026-09-24"): a calendar day in Frankfurt, not an instant.
    let day: String
    /// Units of each currency per euro, as published; the euro is the base and is not listed.
    let perEuro: [String: Double]
    /// When this Mac read them.
    let fetchedAt: Date

    /// A cached rate is used for this many days after the day it is for, and then no longer: the ECB's longest
    /// regular silence is the Easter and Christmas closings of TARGET, five days with the weekend, and a rate
    /// fetched once a day is up to a day behind the one published. Past a week the rate is stale enough that the
    /// user's own rate is the more honest of the two.
    static let usableForDays = 7

    /// Units of `code` per US dollar, crossed through the euro; nil for a currency the ECB does not publish, and
    /// for a file without the dollar, which could not be crossed at all.
    func perDollar(_ code: String) -> Double? {
        guard let dollars = perEuro["USD"], dollars > 0 else { return nil }
        switch code {
        case "USD": return 1
        case "EUR": return 1 / dollars
        default: return perEuro[code].map { $0 / dollars }
        }
    }

    /// Whole days from the day the rates are for to today, both read in UTC so the answer does not move with the
    /// Mac's time zone; nil for a day that does not read as one.
    func daysOld(now: Date) -> Int? {
        guard let date = Self.date(of: day) else { return nil }
        let today = Self.calendar.startOfDay(for: now)
        return max(0, Self.calendar.dateComponents([.day], from: date, to: today).day ?? 0)
    }

    func isTooOld(now: Date) -> Bool {
        (daysOld(now: now) ?? .max) > Self.usableForDays
    }

    /// The ECB's day as a date at midnight UTC.
    static func date(of day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, day.count == 10 else { return nil }
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard components.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: components)
    }

    /// "Sep 24" in the app's own language, the way the day is named beside a converted figure. The year only when
    /// it is not this one: a rate in use is at most a week old unless no rate of the user's own is set to stand in
    /// (`CurrencyConversion.Source.stale`), and only then can the day be so far back that "Sep 24" would be read
    /// as this year's.
    static func dayText(_ day: String, now: Date = Date()) -> String {
        guard let date = date(of: day) else { return day }
        let thisYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return dayFormatter(template: thisYear ? "MMM d" : "yMMMd").string(from: date)
    }

    /// One formatter per language and template, made on first use: the day is named on every pass of the Cost
    /// card's body and the dashboard's header while a rate is on, and a DateFormatter is dear to make and safe to
    /// share once made (Apple documents the class as thread-safe since 10.9, so long as it is not mutated).
    private static func dayFormatter(template: String) -> DateFormatter {
        let language = Localization.current
        return dayFormatters.withLock { formatters in
            if let formatter = formatters["\(language)|\(template)"] { return formatter }
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: language)
            formatter.setLocalizedDateFormatFromTemplate(template)
            formatters["\(language)|\(template)"] = formatter
            return formatter
        }
    }

    private static let dayFormatters = OSAllocatedUnfairLock<[String: DateFormatter]>(uncheckedState: [:])

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// When the ECB is next expected to have published after this day's rates: `publicationHour` in Frankfurt on
    /// the next weekday. The ECB says the rates are "usually updated at around 16:00 CET"; the half hour past it
    /// is slack for a late file. TARGET's holidays are not modelled: on one the request at 16:30 reads the same
    /// day's file again, which costs one request and changes nothing shown. Nil for a day that does not read.
    func nextPublication() -> Date? {
        guard let date = Self.date(of: day) else { return nil }
        var frankfurt = Calendar(identifier: .gregorian)
        frankfurt.timeZone = Self.frankfurt
        // The day is a calendar day in Frankfurt; it was parsed as midnight UTC, which is the same day there.
        var components = Self.calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = Self.publicationHour
        components.minute = Self.publicationMinute
        guard var next = frankfurt.date(from: components) else { return nil }
        repeat {
            guard let following = frankfurt.date(byAdding: .day, value: 1, to: next) else { return nil }
            next = following
        } while frankfurt.isDateInWeekend(next)
        return next
    }

    /// The hour and minute in Frankfurt after which the day's file is expected (docs/accuracy.md, *Currency*).
    static let publicationHour = 16
    static let publicationMinute = 30
    /// The ECB's clock: Frankfurt keeps CET and CEST, which Europe/Berlin names.
    static let frankfurt = TimeZone(identifier: "Europe/Berlin")!
}

/// The ECB's daily reference-rate file: where it is, how it is asked for, and how it is read.
enum ECBRates {
    /// The ECB's own daily file (https://www.ecb.europa.eu/stats/policy_and_exchange_rates/euro_reference_exchange_rates/html/index.en.html,
    /// read 2026-09-24): public, free, no key, about 1.5 KB.
    static let url = URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")!
    /// The file is 1.5 KB; anything past this is not the file.
    static let largest = 256 * 1024

    /// One plain GET, with the app's own User-Agent and nothing that says anything about the user: no cookie is
    /// sent or kept, and the language is fixed at English rather than left to the system, which would otherwise
    /// name the Mac's preferred languages in `Accept-Language`. Follows the proxy the vendor requests follow.
    /// Nil on any failure: no network, a non-200 answer, or a file that does not read as the ECB's.
    static func fetch(session: URLSession = NetworkSession.shared) async -> ReferenceRates? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.httpShouldHandleCookies = false
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/xml, text/xml", forHTTPHeaderField: "Accept")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        guard let (data, response) = try? await session.data(for: request) else {
            log.info("reference rates: no answer")
            return nil
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        DiagnosticLog.request(log, "reference rates", status: status, bytes: data.count)
        guard status == 200 else { return nil }
        return parse(data, fetchedAt: Date())
    }

    /// The rates in the file: the first `Cube` with a `time` (the daily file has one; the ECB's history files list
    /// the newest first), and each `Cube` inside it with a three-letter `currency` and a positive `rate`. An entry
    /// that does not read is skipped rather than failing the file; a file with no day, or without the dollar the
    /// rest are crossed through, is not the ECB's file and reads as nil.
    static func parse(_ data: Data, fetchedAt: Date) -> ReferenceRates? {
        guard !data.isEmpty, data.count <= largest else { return nil }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        let reader = CubeReader()
        parser.delegate = reader
        guard parser.parse(), let day = reader.day, ReferenceRates.date(of: day) != nil,
              let dollars = reader.rates["USD"], dollars > 0
        else { return nil }
        return ReferenceRates(day: day, perEuro: reader.rates, fetchedAt: fetchedAt)
    }

    private final class CubeReader: NSObject, XMLParserDelegate {
        var day: String?
        var rates: [String: Double] = [:]
        /// A second day's `Cube` ends the first; its rates are not this day's.
        private var finished = false

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String] = [:]) {
            guard elementName == "Cube", !finished else { return }
            if let time = attributes["time"] {
                if day == nil { day = time } else { finished = true }
                return
            }
            guard day != nil, let code = attributes["currency"], Self.isCode(code),
                  let rate = attributes["rate"].flatMap(Double.init), rate.isFinite, rate > 0
            else { return }
            rates[code] = rate
        }

        static func isCode(_ text: String) -> Bool {
            text.count == 3 && text.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) }
        }
    }
}

/// What the app keeps between launches while *Fetch today's rate* is on: the last rates that read, when a request
/// was last made, and how many in a row have failed. In the app's own preferences, beside the setting.
struct ReferenceRateCache: Codable, Equatable, Sendable {
    var rates: ReferenceRates?
    /// When a request was last started, written before it is made, so one the app never came back from (a quit,
    /// a crash) still leaves its mark.
    var lastAttempt: Date?
    /// Answers in a row that brought no rates, counted when an answer comes back empty and back to zero when one
    /// reads. Not counted before the request: while one is in flight nothing has failed, and Settings would
    /// otherwise say the ECB could not be reached before it had been asked.
    var failures = 0

    /// A request was started and no answer to it recorded: it is in flight, or the app quit while it was. Nothing
    /// has failed, so nothing is waited out.
    var isUnanswered: Bool { lastAttempt != nil && rates == nil && failures == 0 }

    static let defaultsKey = "referenceRates"

    static func load(_ defaults: UserDefaults) -> ReferenceRateCache {
        guard let data = defaults.data(forKey: defaultsKey),
              let cache = try? JSONDecoder().decode(ReferenceRateCache.self, from: data)
        else { return ReferenceRateCache() }
        return cache
    }

    func save(_ defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// When the next request is due: once a day after one that read, and after one that did not, an hour later,
/// doubling with each failure in a row up to the same day. So a Mac that was offline at the moment has the rate
/// within the hour, and an ECB that has moved its file is asked no more than once a day either.
///
/// The day's wait alone would keep asking at whatever hour the switch was first turned on, and a Mac asking each
/// morning would read the previous day's file every day and never show today's rate on the day. So a request is
/// also due once the ECB is expected to have published a newer file than the one held (`ReferenceRates
/// .nextPublication`), unless one was made since that moment. That fires at most once per publication, after
/// which the daily wait and the publication coincide at the same afternoon hour.
enum RateRefresh {
    static let interval: TimeInterval = 24 * 3600
    static let firstRetry: TimeInterval = 3600

    static func wait(after failures: Int) -> TimeInterval {
        guard failures > 0 else { return interval }
        return min(interval, firstRetry * pow(2, Double(min(failures, 16) - 1)))
    }

    /// Nothing is asked for while the switch is off or the costs are in dollars, which need no rate. A last
    /// request dated after `now` means the clock went back, and is not waited out; nor is one that was never
    /// answered, since nothing failed (the fetcher keeps one request at a time on its own).
    static func isDue(fetch: Bool, code: String, cache: ReferenceRateCache, now: Date) -> Bool {
        guard fetch, CurrencyConversion.normalized(code) != "USD" else { return false }
        guard let last = cache.lastAttempt, last <= now else { return true }
        if cache.isUnanswered { return true }
        if now.timeIntervalSince(last) >= wait(after: cache.failures) { return true }
        guard let publication = cache.rates?.nextPublication() else { return false }
        return now >= publication && last < publication
    }
}

/// The rate every amount on screen is converted at, and where it came from. Resolved from the preferences and the
/// cache (`Preferences.currencyConversion`) and handed to `Money`; the Cost card, the dashboard and Settings say
/// which it is, so a converted figure is never shown without its rate's provenance while fetching is on.
struct CurrencyConversion: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// Costs in US dollars: nothing to convert.
        case dollars
        /// The rate the user typed, with fetching off: the default, and the behaviour of every build before it.
        case typed
        /// The ECB's rate for `day`, read at `fetchedAt`.
        case reference(day: String, fetchedAt: Date)
        /// The ECB's rate for `day`, past the week it would otherwise be used for, kept because no rate of the
        /// user's own is set to stand in: a week-old rate is nearer the truth than the 1 that would otherwise
        /// convert, and the figures say how old it is.
        case stale(day: String, fetchedAt: Date)
        /// Fetching is on, but the user's own rate stands in, for the reason given.
        case fallback(Fallback)
    }

    enum Fallback: Equatable, Sendable {
        /// No request has been made yet.
        case notYet
        /// Requests have been made and none has read.
        case unreachable
        /// The ECB does not publish this currency (VND, RUB and TWD among the ones the app's languages use).
        case unpublished
        /// The newest rate held is for this day, more than `ReferenceRates.usableForDays` ago.
        case tooOld(day: String)
    }

    let code: String
    let rate: Double
    let source: Source

    /// A three-letter code in capitals, or USD for anything else: the same rule `Money.configure` applies.
    static func normalized(_ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return trimmed.count == 3 ? trimmed : "USD"
    }

    /// The rate the user typed, when one was: *Rate per dollar* starts at 1, which converts nothing, and a rate
    /// that is not a positive number cannot convert anything, so neither counts as a rate of their own. Where a
    /// rate is needed and none is set, 1 stands in and the figures say so.
    static func ownRate(_ typed: Double) -> Double? {
        typed.isFinite && typed > 0 && typed != 1 ? typed : nil
    }

    static func resolve(code: String, typed: Double, fetch: Bool, cache: ReferenceRateCache, now: Date) -> CurrencyConversion {
        let code = normalized(code)
        guard code != "USD" else { return CurrencyConversion(code: code, rate: 1, source: .dollars) }
        let own = ownRate(typed)
        guard fetch else { return CurrencyConversion(code: code, rate: own ?? 1, source: .typed) }
        func standIn(_ why: Fallback) -> CurrencyConversion { CurrencyConversion(code: code, rate: own ?? 1, source: .fallback(why)) }
        guard let rates = cache.rates else { return standIn(cache.failures > 0 ? .unreachable : .notYet) }
        guard let rate = rates.perDollar(code), rate.isFinite, rate > 0 else { return standIn(.unpublished) }
        if rates.isTooOld(now: now) {
            guard own == nil else { return standIn(.tooOld(day: rates.day)) }
            return CurrencyConversion(code: code, rate: rate, source: .stale(day: rates.day, fetchedAt: rates.fetchedAt))
        }
        return CurrencyConversion(code: code, rate: rate, source: .reference(day: rates.day, fetchedAt: rates.fetchedAt))
    }

    /// A rate to five significant figures in the reader's own locale: "0.87974", "158.86", "17,933".
    static func rateText(_ rate: Double) -> String {
        rateFormatter.string(from: NSNumber(value: rate)) ?? String(rate)
    }

    private static let rateFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesSignificantDigits = true
        formatter.maximumSignificantDigits = 5
        return formatter
    }()

    /// The line beside converted figures (the Cost card's notes, the dashboard's header) while fetching is on:
    /// which rate, and for the ECB's, which day it is for. Nil with fetching off, which keeps the card as it has
    /// always been, and in dollars, where nothing was converted.
    var note: String? {
        switch source {
        case .dollars, .typed: nil
        case .reference(let day, _):
            L("%1$@ at %2$@ per US dollar, the ECB reference rate of %3$@", code, Self.rateText(rate), ReferenceRates.dayText(day))
        case .stale(let day, _):
            L("%1$@ at %2$@ per US dollar, the ECB reference rate of %3$@, over a week old", code, Self.rateText(rate), ReferenceRates.dayText(day))
        case .fallback:
            L("%1$@ at your own rate of %2$@ per US dollar", code, Self.rateText(rate))
        }
    }

    /// Settings' line under *Fetch today's rate*: the rate in use and its day, or why the user's own stands in.
    func settingsLine(now: Date = Date()) -> String? {
        let own = Self.rateText(rate)
        switch source {
        case .dollars, .typed: return nil
        case .reference(let day, let fetchedAt):
            return L("%1$@ per US dollar, the ECB reference rate of %2$@, fetched %3$@.", own, ReferenceRates.dayText(day, now: now), RelativeTime.ago(fetchedAt, now: now))
        case .stale(let day, _):
            return L("%1$@ per US dollar, the ECB reference rate of %2$@, over a week old and still in use: no rate of your own is set to stand in.", own, ReferenceRates.dayText(day, now: now))
        case .fallback(.notYet): return L("Not fetched yet; your own rate (%@) stands in.", own)
        case .fallback(.unreachable): return L("The ECB could not be reached; your own rate (%@) stands in until it can.", own)
        case .fallback(.unpublished): return L("The ECB publishes no rate for %1$@; your own rate (%2$@) stands in.", code, own)
        case .fallback(.tooOld(let day)):
            return L("The ECB's latest rate is from %1$@, over a week ago; your own rate (%2$@) stands in.", ReferenceRates.dayText(day, now: now), own)
        }
    }

    /// The user's own rate stands in and there is none: the 1 that converts nothing is what the figures are at,
    /// and Settings asks for a rate under the line that says so.
    var standsInWithoutOwnRate: Bool {
        if case .fallback = source { return rate == 1 }
        return false
    }

    /// For the oracle's `currency` event and the snapshot: the code, the rate, the source and, where there is one,
    /// the ECB's day or the reason the user's rate stands in.
    var oracleFields: [String: Any] {
        var fields: [String: Any] = ["code": code, "rate": rate]
        switch source {
        case .dollars: fields["source"] = "dollars"
        case .typed: fields["source"] = "typed"
        case .reference(let day, _): fields["source"] = "reference"; fields["day"] = day
        case .stale(let day, _): fields["source"] = "stale"; fields["day"] = day
        case .fallback(let why):
            fields["source"] = "fallback"
            switch why {
            case .notYet: fields["reason"] = "notYet"
            case .unreachable: fields["reason"] = "unreachable"
            case .unpublished: fields["reason"] = "unpublished"
            case .tooOld(let day): fields["reason"] = "tooOld"; fields["day"] = day
            }
        }
        return fields
    }
}

/// Asks for the ECB's rates when `RateRefresh` says a request is due: at launch, when *Fetch today's rate* or the
/// currency changes, and on a quarter-hour check that also lets a held rate age out of use past a week. Never while
/// the switch is off or the costs are in dollars. One request at a time; the outcome goes to the preferences,
/// which keep it and re-resolve the rate `Money` converts at.
@MainActor
final class ReferenceRateFetcher {
    typealias Load = @MainActor () async -> ReferenceRates?

    private let prefs: Preferences
    private let load: Load
    private var loop: Task<Void, Never>?
    private var inFlight = false

    /// How often the clock looks. Looking is free (a comparison of dates); only a due check makes a request.
    static let checkEvery: Duration = .seconds(15 * 60)

    init(prefs: Preferences, load: @escaping Load = { await ECBRates.fetch() }) {
        self.prefs = prefs
        self.load = load
    }

    func start() {
        observe()
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshIfDue()
                try? await Task.sleep(for: Self.checkEvery)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// The switch or the code changed: look now rather than at the next quarter hour. The tracking is one-shot,
    /// and its handler runs before the new value lands, so the look is made from a task that runs after it.
    private func observe() {
        withObservationTracking {
            _ = prefs.fetchCurrencyRate
            _ = prefs.currencyCode
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observe()
                await self?.refreshIfDue()
            }
        }
    }

    /// Re-resolves the rate (a held one may have aged out) and, when a request is due, makes it. Returns whether
    /// a request was made, for the tests.
    @discardableResult
    func refreshIfDue(now: Date = Date()) async -> Bool {
        prefs.applyCurrency(now: now)
        guard !inFlight, RateRefresh.isDue(fetch: prefs.fetchCurrencyRate, code: prefs.currencyCode, cache: prefs.referenceRateCache, now: now) else {
            return false
        }
        inFlight = true
        defer { inFlight = false }
        prefs.recordRateRequest(at: now)
        let rates = await load()
        prefs.recordRates(rates, now: now)
        if let rates {
            Oracle.shared.emit("rate", ["action": "fetched", "day": rates.day, "currencies": rates.perEuro.count])
        } else {
            Oracle.shared.emit("rate", ["action": "failed", "failures": prefs.referenceRateCache.failures])
        }
        return true
    }
}
