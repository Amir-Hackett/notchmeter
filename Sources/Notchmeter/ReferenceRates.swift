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

    /// "Sep 24" in the app's own language, the way the day is named beside a converted figure. No year: a rate
    /// more than a week old is never used, so the year is always this one or, in the first week of January, the
    /// one that has just ended.
    static func dayText(_ day: String) -> String {
        guard let date = date(of: day) else { return day }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: Localization.current)
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter.string(from: date)
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
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
    var lastAttempt: Date?
    /// Requests in a row that brought no rates. Counted up before each request and back to zero when one reads,
    /// so a request the app never came back from (a crash, a quit) counts as a failure rather than a success.
    var failures = 0

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
enum RateRefresh {
    static let interval: TimeInterval = 24 * 3600
    static let firstRetry: TimeInterval = 3600

    static func wait(after failures: Int) -> TimeInterval {
        guard failures > 0 else { return interval }
        return min(interval, firstRetry * pow(2, Double(min(failures, 16) - 1)))
    }

    /// Nothing is asked for while the switch is off or the costs are in dollars, which need no rate. A last
    /// request dated after `now` means the clock went back, and is not waited out.
    static func isDue(fetch: Bool, code: String, cache: ReferenceRateCache, now: Date) -> Bool {
        guard fetch, CurrencyConversion.normalized(code) != "USD" else { return false }
        guard let last = cache.lastAttempt, last <= now else { return true }
        return now.timeIntervalSince(last) >= wait(after: cache.failures)
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

    static func resolve(code: String, typed: Double, fetch: Bool, cache: ReferenceRateCache, now: Date) -> CurrencyConversion {
        let code = normalized(code)
        guard code != "USD" else { return CurrencyConversion(code: code, rate: 1, source: .dollars) }
        let own = typed.isFinite && typed > 0 ? typed : 1
        guard fetch else { return CurrencyConversion(code: code, rate: own, source: .typed) }
        func standIn(_ why: Fallback) -> CurrencyConversion { CurrencyConversion(code: code, rate: own, source: .fallback(why)) }
        guard let rates = cache.rates else { return standIn(cache.failures > 0 ? .unreachable : .notYet) }
        guard let rate = rates.perDollar(code), rate.isFinite, rate > 0 else { return standIn(.unpublished) }
        if rates.isTooOld(now: now) { return standIn(.tooOld(day: rates.day)) }
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
            return L("%1$@ per US dollar, the ECB reference rate of %2$@, fetched %3$@.", own, ReferenceRates.dayText(day), RelativeTime.ago(fetchedAt, now: now))
        case .fallback(.notYet): return L("Not fetched yet; your own rate (%@) stands in.", own)
        case .fallback(.unreachable): return L("The ECB could not be reached; your own rate (%@) stands in until it can.", own)
        case .fallback(.unpublished): return L("The ECB publishes no rate for %1$@; your own rate (%2$@) stands in.", code, own)
        case .fallback(.tooOld(let day)):
            return L("The ECB's latest rate is from %1$@, over a week ago; your own rate (%2$@) stands in.", ReferenceRates.dayText(day), own)
        }
    }

    /// For the oracle's `currency` event and the snapshot: the code, the rate, the source and, where there is one,
    /// the ECB's day or the reason the user's rate stands in.
    var oracleFields: [String: Any] {
        var fields: [String: Any] = ["code": code, "rate": rate]
        switch source {
        case .dollars: fields["source"] = "dollars"
        case .typed: fields["source"] = "typed"
        case .reference(let day, _): fields["source"] = "reference"; fields["day"] = day
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
