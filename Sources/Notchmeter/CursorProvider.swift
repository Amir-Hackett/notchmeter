import Foundation
import os
import SQLite3

private let log = Logger(subsystem: "com.amirhackett.notchmeter", category: "cursor")

/// Cursor keeps its web session token in the editor's state database. The token doubles as the dashboard
/// cookie, which is how cursor.com's own usage page reads the billing-cycle numbers. The usage-events export
/// is a second read on the same cookie, opt-in, and feeds the daily-totals file with a Cursor series.
actor CursorProvider: UsageProvider {
    nonisolated let tool: ToolID = .cursor
    nonisolated let refreshInterval: TimeInterval = 300
    nonisolated let stateDatabase: URL

    static let summaryURL = URL(string: "https://cursor.com/api/usage-summary")!
    static let legacyUsageURL = URL(string: "https://cursor.com/api/usage")!
    static let usageEventsURL = URL(string: "https://cursor.com/api/dashboard/get-filtered-usage-events")!
    static let teamsURL = URL(string: "https://cursor.com/api/dashboard/teams")!
    /// The dashboard's own cycle figures in cents (`planUsage`), read when the summary meters nothing so an
    /// Enterprise on-demand seat gets its included figure from the endpoint that still carries one.
    static let periodUsageURL = URL(string: "https://cursor.com/api/dashboard/get-current-period-usage")!
    /// The Grok Bot weekly allowance ("Sand" internally), an optional window a seat may not have.
    static let sandUsageURL = URL(string: "https://cursor.com/api/dashboard/get-sand-usage-status")!
    static let origin = "https://cursor.com"
    /// One page of the export, and the most pages one read will ask for: an account with more than these events
    /// in the window would be understated, so the cap is loud rather than silent.
    static let eventPageSize = 500
    static let maxEventPages = 20

    /// One priced request from the account's usage-events export.
    struct UsageEvent: Equatable, Sendable {
        let timestamp: Date
        let model: String?
        let tokens: TokenBreakdown
        let costUSD: Double
    }

    private let session: URLSession?
    private let readUsageEvents: @Sendable () -> Bool
    private let history: CostHistory?
    /// Where the last export read is written down for the Cost card; the switch above is read from it too.
    private let defaults: UserDefaults

    init(session: URLSession? = nil,
         stateDatabase: URL = Paths.home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb"),
         defaults: UserDefaults = .standard, readUsageEvents: (@Sendable () -> Bool)? = nil,
         history: CostHistory? = CostHistory(tool: .cursor)) {
        self.session = session
        self.stateDatabase = stateDatabase
        self.defaults = defaults
        self.readUsageEvents = readUsageEvents ?? ProviderOptIn.cursorUsageEvents.reader(defaults)
        self.history = history
    }

    nonisolated func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: stateDatabase.path)
            || FileManager.default.fileExists(atPath: "/Applications/Cursor.app")
    }

    func fetch() async throws -> UsageReading {
        guard let token = try Self.stateValue(forKey: "cursorAuth/accessToken", database: stateDatabase),
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ProviderError.notSignedIn(L("Sign in to Cursor in the editor to read your usage"))
        }
        let claims = try Self.jwtClaims(token)
        if let expiry = claims["exp"] as? Double, Date(timeIntervalSince1970: expiry).timeIntervalSinceNow < 30 {
            throw ProviderError.tokenExpired(L("Cursor's login has expired. Open Cursor once so it signs back in"))
        }
        let userID = try Self.userID(fromClaims: claims)
        let cookie = "WorkosCursorSessionToken=\(userID)%3A%3A\(token)"

        let (data, response) = try await send(Self.summaryURL, cookie: cookie)
        switch response?.statusCode ?? 0 {
        case 200:
            var reading = try Self.parseSummary(data)
            // Two more dashboard reads on the same cookie, each fail-soft: whatever they answer, the summary's
            // windows stand. The cycle figures are asked for only where the summary meters nothing, which is the
            // seat they exist for (Enterprise billed on-demand, 2026-09-18); the Grok Bot window is asked for on
            // every seat and simply absent where the seat has none.
            if !Self.headlineMetered(reading.windows),
               let (periodData, periodResponse) = try? await send(Self.periodUsageURL, cookie: cookie, body: Data("{}".utf8)),
               periodResponse?.statusCode == 200, let period = Self.parsePeriodUsage(periodData) {
                reading = reading.with(windows: Self.applying(period, to: reading.windows))
            }
            if let (sandData, sandResponse) = try? await send(Self.sandUsageURL, cookie: cookie, body: Data("{}".utf8)),
               sandResponse?.statusCode == 200, let sand = Self.parseSandUsage(sandData) {
                reading = reading.with(windows: reading.windows + [sand])
            }
            guard readUsageEvents() else { return reading }
            // A seat with no included allowance (Enterprise billed on-demand, 2026-09-18) reads 0 % on every
            // window however much it spends, so the export's own dollars become the ring: today against a usual day.
            // Only after today's export was actually read: a refused or failed read leaves today's line unwritten
            // or stale, and the ring would read $0 against a usual day. A seat whose cycle figures carried a real
            // included fraction fails the second test by itself, so the vendor's figure leads and the usual-day
            // heuristic stays for seats nothing else meters (pinned in CursorSpendTests).
            guard await recordUsageEvents(cookie: cookie), !Self.headlineMetered(reading.windows),
                  let history, let spend = Self.spendToday(history.load(calendar: .current))
            else { return reading }
            return UsageReading(tool: .cursor, windows: [spend] + Self.withoutDeadSplits(reading.windows), plan: reading.plan,
                                fetchedAt: reading.fetchedAt, observedAt: reading.observedAt)
        case 401, 403:
            throw ProviderError.notSignedIn(L("Cursor's login was refused. Sign in to Cursor in the editor again"))
        case 404:
            var components = URLComponents(url: Self.legacyUsageURL, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "user", value: userID)]
            let (legacy, legacyResponse) = try await send(components.url!, cookie: cookie)
            guard legacyResponse?.statusCode == 200 else { throw ProviderError.http(legacyResponse?.statusCode ?? 0, L("Cursor usage endpoint answered")) }
            return try Self.parseLegacyUsage(legacy)
        case 429:
            throw ProviderError.rateLimited(retryAfter: RetryAfter.seconds(from: response))
        case let status:
            throw ProviderError.http(status, L("Cursor usage endpoint answered"))
        }
    }

    /// The last 30 days of usage events, folded into per-day records of the daily-totals file; a failure here
    /// never fails the reading. Every outcome is written down (CursorExportRead) as well as logged, because a
    /// refusal, an empty export and an export nobody ever fetched all reach the Cost card as the same silence.
    /// True when the export was read, empty or not, so today's line in the daily-totals file is current.
    private func recordUsageEvents(cookie: String, now: Date = Date()) async -> Bool {
        guard let history else { return false }
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)) ?? now
        var teamId = 0
        if let (teamData, teamResponse) = try? await send(Self.teamsURL, cookie: cookie, body: Data("{}".utf8)),
           teamResponse?.statusCode == 200, let found = Self.parseTeamId(teamData) {
            teamId = found
        }
        var events: [UsageEvent] = []
        var page = 1
        while page <= Self.maxEventPages {
            let body = Self.usageEventsRequestBody(start: start, end: now, teamId: teamId, page: page)
            guard let (data, response) = try? await send(Self.usageEventsURL, cookie: cookie, body: body) else {
                log.error("Cursor usage events: the request failed on page \(page)")
                CursorExportRead(readAt: now, problem: L("its usage export could not be fetched")).save(to: defaults)
                return false
            }
            guard response?.statusCode == 200 else {
                // Silence here is what hid an empty Cost card: a refusal reads exactly like a month with no spend.
                let status = response?.statusCode ?? 0
                log.error("Cursor usage events: HTTP \(status) for team \(teamId)")
                CursorExportRead(readAt: now, problem: L("cursor.com refused its usage export (HTTP %ld)", status)).save(to: defaults)
                return false
            }
            let parsed = Self.parseUsageEvents(data)
            // On any page, not just the first: a partial fold would write an understated today row, which is the
            // same confident-low ring by another route. `fetch()` falls back to the summary windows and the Cost
            // card prints the problem, as it does for a refusal.
            guard parsed.recognised else {
                log.error("Cursor usage events: page \(page) came back in a shape this build cannot read (\(data.count) bytes) for team \(teamId)")
                CursorExportRead(readAt: now, problem: L("its usage export came back in a shape Notchmeter could not read")).save(to: defaults)
                return false
            }
            let batch = parsed.events
            // A server that ignores `page` answers the same events forever; stopping is a short total, counting
            // them twice is a made-up one.
            guard parsed.rows > 0, batch != Array(events.suffix(batch.count)) else { break }
            events += batch
            // The last page is the one the server sent short, counted in the rows it returned rather than the
            // events that parsed: one row with an unreadable timestamp on a full page used to end the export there.
            if parsed.rows < Self.eventPageSize { break }
            page += 1
        }
        if page > Self.maxEventPages {
            log.error("Cursor usage events: stopped after \(Self.maxEventPages) pages; the total is short")
        }
        let total = events.reduce(0) { $0 + $1.costUSD }
        CursorExportRead(readAt: now, events: events.count, costUSD: total).save(to: defaults)
        guard !events.isEmpty else {
            log.notice("Cursor usage events: none in the last 30 days for team \(teamId)")
            return true
        }
        let days = Self.dayRecords(events, calendar: calendar)
        history.record(days, existing: history.load(calendar: calendar), calendar: calendar)
        log.notice("Cursor usage events: \(events.count) over \(days.count) days worth \(Money.dollars(total), privacy: .public)")
        return true
    }

    private func send(_ url: URL, cookie: String, body: Data? = nil) async throws -> (Data, HTTPURLResponse?) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // Cursor's dashboard POSTs are CSRF-checked: without a matching Origin they answer 403, whatever the
            // cookie says. The GETs the usage summary uses are not, which is why only the exports were refused.
            request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        }
        do {
            let (data, response) = try await (session ?? NetworkSession.shared).data(for: request)
            let http = response as? HTTPURLResponse
            DiagnosticLog.request(log, url.lastPathComponent, status: http?.statusCode ?? 0, bytes: data.count)
            return (data, http)
        } catch {
            if let offline = ProviderError.offline(from: error) { throw offline }
            throw error
        }
    }

    // MARK: - Parsing

    /// The dashboard's summary: the plan's included usage (the main window under `limitType` "user"), the team's
    /// pooled usage (the main window under "team"), on-demand spend, and Cursor's own two model percentages,
    /// which the switch-models advice can act on and which stay off the card until revealed in Settings.
    ///
    /// `autoPercentUsed` and `apiPercentUsed` are not two shares of the included allowance, whatever they look
    /// like. An Enterprise account reported 49 % and 100 % of the same cycle, which cannot be two parts of one
    /// pool, and its usage-events export for those days shows Cursor's own models still billed as Included while
    /// a third-party model had already gone On-Demand. Separate meters, then, and the caption says so rather than
    /// calling them shares of a total they demonstrably do not add up to. What each is a percentage *of* Cursor
    /// does not publish, so nothing here claims to know.
    static func parseSummary(_ data: Data, now: Date = Date()) throws -> UsageReading {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.parse(L("Cursor usage summary unreadable"))
        }
        let membership = root["membershipType"] as? String
        let planName = membership.map(Naming.plan)
        let cycleEnd = (root["billingCycleEnd"] as? String).flatMap(DateParsing.iso8601)
        let cycleStart = (root["billingCycleStart"] as? String).flatMap(DateParsing.iso8601)
        let cycle: TimeInterval? = if let cycleStart, let cycleEnd, cycleEnd > cycleStart { cycleEnd.timeIntervalSince(cycleStart) } else { nil }
        let unlimited = (root["isUnlimited"] as? Bool) ?? false
        let teamScoped = (root["limitType"] as? String)?.lowercased() == "team"
        let individual = root["individualUsage"] as? [String: Any]
        let team = root["teamUsage"] as? [String: Any]
        // Some Enterprise seats answer `overall` where others answer `plan`, same fields; seen 2026-09-18.
        let plan = (individual?["plan"] ?? individual?["overall"]) as? [String: Any]
        let onDemand = individual?["onDemand"] as? [String: Any]

        var windows: [LimitWindow] = []

        let planEnabled = (plan?["enabled"] as? Bool) ?? (plan != nil)
        let planLimit = number(plan?["limit"])
        let planUsed = number(plan?["used"])
        let planPercent = number(plan?["totalPercentUsed"])
        if unlimited {
            windows.append(LimitWindow(
                id: "included", label: .key("Included usage"), usedFraction: nil, resetsAt: cycleEnd,
                note: planName.map { L("Unlimited on the %@ plan", $0) } ?? L("Unlimited on the current plan")
            ))
        } else if planEnabled, let planLimit, planLimit > 0 {
            let fraction = share(percent: planPercent, used: planUsed, limit: planLimit)
            windows.append(LimitWindow(
                id: "included", label: .key("Included usage"), usedFraction: fraction, resetsAt: cycleEnd,
                note: planUsed.map { L("%1$@ of %2$@", dollars($0), dollars(planLimit)) },
                periodDuration: cycle, amountUSD: planUsed.map { $0 / 100 }
            ))
        } else {
            // The cycle is known even with nothing metered, and travels with the window so that a figure the cycle
            // endpoint fills in afterwards (`applying`) paces against the summary's own cycle.
            windows.append(LimitWindow(
                id: "included", label: .key("Included usage"), usedFraction: nil, resetsAt: cycleEnd,
                note: planName.map { L("%@ plan has nothing for Cursor to meter yet", $0) } ?? L("This plan has nothing for Cursor to meter yet"), periodDuration: cycle
            ))
        }

        if let pooled = team?["pooled"] as? [String: Any], let limit = number(pooled["limit"]), limit > 0 {
            let used = number(pooled["used"]) ?? 0
            let fraction = share(percent: number(pooled["totalPercentUsed"]), used: used, limit: limit)
            let window = LimitWindow(
                id: "team_pooled", label: .key("Team pooled"), usedFraction: fraction, resetsAt: cycleEnd,
                note: L("%1$@ of %2$@", dollars(used), dollars(limit)), periodDuration: cycle, amountUSD: used / 100
            )
            if teamScoped { windows.insert(window, at: 0) } else { windows.append(window) }
        }

        // The same two figures, on seats whose summary drops the numeric fields, survive only in the dashboard's
        // own sentences ("You've used 0% of your included total usage"), so the percentage is read out of those.
        let splits: [(key: String, message: String, id: String, label: WindowLabel)] = [
            ("autoPercentUsed", "autoModelSelectedDisplayMessage", "cursor_models", .key("Cursor models")),
            ("apiPercentUsed", "namedModelSelectedDisplayMessage", "other_models", .key("Other models")),
        ]
        // They stay off the card while an included or pooled window carries a figure; on a seat where none does,
        // they are the only figures there are, and hiding them left a card and rings with nothing in them.
        let headlineMetered = windows.contains { $0.usedFraction != nil }
        for (key, message, id, label) in splits {
            guard let percent = number(plan?[key]) ?? percent(in: root[message] as? String) else { continue }
            windows.append(LimitWindow(id: id, label: label, usedFraction: JSON.fraction(percent), resetsAt: cycleEnd,
                                       note: L("Metered apart from the included total"), periodDuration: cycle, model: label.text, hiddenByDefault: headlineMetered))
        }

        // On-demand with no limit is still spend worth showing: the dollars, with no fraction to fill a ring with.
        if let onDemand, (onDemand["enabled"] as? Bool) == true {
            let used = number(onDemand["used"]) ?? 0
            let limit = number(onDemand["limit"]).flatMap { $0 > 0 ? $0 : nil }
            windows.append(LimitWindow(
                id: "on_demand", label: .key("On-demand"), usedFraction: limit.map { min(max(used / $0, 0), 1) }, resetsAt: cycleEnd,
                note: limit.map { L("%1$@ of %2$@", dollars(used), dollars($0)) } ?? L("%@ so far, no limit set", dollars(used)),
                periodDuration: cycle, amountUSD: used / 100
            ))
        }
        if let teamOnDemand = team?["onDemand"] as? [String: Any], (teamOnDemand["enabled"] as? Bool) == true {
            let used = number(teamOnDemand["used"]) ?? 0
            let limit = number(teamOnDemand["limit"]).flatMap { $0 > 0 ? $0 : nil }
            windows.append(LimitWindow(
                id: "team_on_demand", label: .key("Team on-demand"), usedFraction: limit.map { min(max(used / $0, 0), 1) }, resetsAt: cycleEnd,
                note: limit.map { L("%1$@ of %2$@", dollars(used), dollars($0)) } ?? L("%@ so far, no limit set", dollars(used)),
                periodDuration: cycle, hiddenByDefault: true, amountUSD: used / 100
            ))
        }

        return UsageReading(tool: .cursor, windows: windows, plan: planName, fetchedAt: now, observedAt: nil)
    }

    /// `/api/usage?user=` for request-metered plans: fast requests used against the monthly cap.
    static func parseLegacyUsage(_ data: Data, now: Date = Date()) throws -> UsageReading {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let premium = root["gpt-4"] as? [String: Any]
        else {
            throw ProviderError.parse(L("Cursor usage response unreadable"))
        }
        let used = number(premium["numRequests"]) ?? 0
        let limit = number(premium["maxRequestUsage"])
        let start = (root["startOfMonth"] as? String).flatMap(DateParsing.iso8601)
        let resets = start.flatMap { Calendar.current.date(byAdding: .month, value: 1, to: $0) }
        let window = LimitWindow(
            id: "requests",
            label: .key("Fast requests"),
            usedFraction: limit.flatMap { $0 > 0 ? min(max(used / $0, 0), 1) : nil },
            resetsAt: resets,
            note: limit.map { L("%1$ld of %2$ld requests", Int(used), Int($0)) }
        )
        return UsageReading(tool: .cursor, windows: [window], plan: nil, fetchedAt: now, observedAt: nil)
    }

    // MARK: - Current period usage

    /// Whether an included or team-pooled window carries a figure: the test that decides whether the cycle
    /// endpoint is asked and whether *Today's spend* leads.
    static func headlineMetered(_ windows: [LimitWindow]) -> Bool {
        windows.contains { ["included", "team_pooled"].contains($0.id) && $0.usedFraction != nil }
    }

    /// `POST /api/dashboard/get-current-period-usage` (`{}`): the dashboard's cycle figures, every amount in
    /// cents. `planUsage.includedSpend` is what counts against `limit`; `bonusSpend` is provider-granted usage
    /// that is never charged to the allowance, and `totalSpend` is the two added up (an Ultra seat read $642 of
    /// total against a $400 limit, which is not 160 % of anything). `totalPercentUsed`, `autoPercentUsed` and
    /// `apiPercentUsed` are deliberately not read as spend fractions: Cursor staff said they "reflect a different
    /// internal metric" (forum 168210, 2026-08-13), and the same fields froze backend-side for a week that August
    /// while the cents kept counting. The cycle bounds arrive as epoch milliseconds, as a number or a string.
    struct PeriodUsage: Equatable, Sendable {
        var includedSpendCents: Double?
        var bonusSpendCents: Double?
        var totalSpendCents: Double?
        var remainingCents: Double?
        var limitCents: Double?
        var cycleStart: Date?
        var cycleEnd: Date?
        /// `spendLimitUsage.individualUsed` / `individualLimit`: the seat's own spend limit where the team sets one.
        var individualUsedCents: Double?
        var individualLimitCents: Double?

        /// The cents that count against the allowance: `includedSpend`, else the total less the bonus.
        var chargedCents: Double? {
            includedSpendCents ?? totalSpendCents.map { $0 - (bonusSpendCents ?? 0) }
        }
    }

    /// nil for a body that is not the endpoint's answer (no `planUsage` and no `spendLimitUsage`), so a login page
    /// or an error object never becomes a reading of nothing.
    static func parsePeriodUsage(_ data: Data) -> PeriodUsage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let plan = root["planUsage"] as? [String: Any]
        let spendLimit = root["spendLimitUsage"] as? [String: Any]
        guard plan != nil || spendLimit != nil else { return nil }
        var usage = PeriodUsage()
        usage.includedSpendCents = number(plan?["includedSpend"])
        usage.bonusSpendCents = number(plan?["bonusSpend"])
        usage.totalSpendCents = number(plan?["totalSpend"])
        usage.remainingCents = number(plan?["remaining"])
        usage.limitCents = number(plan?["limit"])
        usage.cycleStart = epochMillis(root["billingCycleStart"])
        usage.cycleEnd = epochMillis(root["billingCycleEnd"])
        usage.individualUsedCents = number(spendLimit?["individualUsed"])
        usage.individualLimitCents = number(spendLimit?["individualLimit"])
        return usage
    }

    /// The summary's windows with the cycle figures filled in where the summary had none: an `included` window
    /// with no figure takes `includedSpend / limit`, and one whose figure reads lower than the cycle's takes the
    /// cycle's, by the same rule `share` applies (the furthest-along vendor figure wins, because under-reporting
    /// hides a meter that is charging). A seat with no `limit` is left exactly as it was.
    static func applying(_ period: PeriodUsage, to windows: [LimitWindow]) -> [LimitWindow] {
        guard let limit = period.limitCents, limit > 0, let charged = period.chargedCents else { return windows }
        let fraction = share(percent: nil, used: charged, limit: limit)
        let cycle: TimeInterval? = if let start = period.cycleStart, let end = period.cycleEnd, end > start { end.timeIntervalSince(start) } else { nil }
        return windows.map { window in
            guard window.id == "included", (window.usedFraction ?? -1) < fraction else { return window }
            return LimitWindow(id: window.id, label: window.name, usedFraction: fraction, resetsAt: window.resetsAt ?? period.cycleEnd,
                               note: L("%1$@ of %2$@", dollars(charged), dollars(limit)), periodDuration: window.periodDuration ?? cycle,
                               model: window.model, source: window.source, hiddenByDefault: window.hiddenByDefault, amountUSD: charged / 100)
        }
    }

    /// `POST /api/dashboard/get-sand-usage-status` (`{}`): the Grok Bot weekly allowance. A window only where the
    /// seat has one — `includedLimitZero` false (or the older `hasNonZeroIncludedLimit`), or a trial that has not
    /// expired; nil otherwise, and nil for anything unreadable, so a seat without it is not a seat with an empty
    /// bar. `usagePercent` is a percentage; the period is `nextResetTimestampUtc` less `currentPeriodStart` (seven
    /// days on a paid seat), and a trial with no recurring reset carries neither.
    static func parseSandUsage(_ data: Data, now: Date = Date()) -> LimitWindow? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let percent = number(root["usagePercent"]) else { return nil }
        let trialEnds = (root["sandTrialExpiresAt"] as? String).flatMap(DateParsing.iso8601)
        let onTrial = trialEnds.map { $0 > now } ?? false
        let included: Bool = if let zero = root["includedLimitZero"] as? Bool { !zero } else { (root["hasNonZeroIncludedLimit"] as? Bool) ?? false }
        guard included || onTrial else { return nil }
        let resets = (root["nextResetTimestampUtc"] as? String).flatMap(DateParsing.iso8601)
        let start = (root["currentPeriodStart"] as? String).flatMap(DateParsing.iso8601)
        let period: TimeInterval? = if included, let start, let resets, resets > start { resets.timeIntervalSince(start) } else { nil }
        return LimitWindow(id: "grok_bot", label: .key("Grok Bot"), usedFraction: JSON.fraction(percent), resetsAt: included ? resets : nil,
                           note: included ? nil : L("On a trial"), periodDuration: period)
    }

    /// Epoch milliseconds as the dashboard sends them, a number or a string of digits; seconds are accepted too.
    static func epochMillis(_ value: Any?) -> Date? {
        guard let stamp = (value as? String).flatMap(Double.init) ?? number(value), stamp > 0 else { return nil }
        return Date(timeIntervalSince1970: stamp > 1e11 ? stamp / 1000 : stamp)
    }

    // MARK: - Usage events

    /// The dashboard's own query: a 30-day range in epoch milliseconds, one page of up to 500 events.
    /// A seat on a team keeps its events under that team's id; an individual account has none and uses 0. Sending
    /// the wrong one is not an empty answer but a refusal ("Team ID is required"), so the id is looked up first.
    static func usageEventsRequestBody(start: Date, end: Date, teamId: Int = 0, page: Int = 1, pageSize: Int = eventPageSize) -> Data {
        let object: [String: Any] = ["teamId": teamId, "startDate": String(Int(start.timeIntervalSince1970 * 1000)),
                                     "endDate": String(Int(end.timeIntervalSince1970 * 1000)), "page": page, "pageSize": pageSize]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// The first team the account sits on, or nil for an individual account, which is 0's meaning.
    static func parseTeamId(_ data: Data) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let list = (root["teams"] ?? root["teamsList"]) as? [Any] ?? []
        for case let team as [String: Any] in list {
            if let id = JSON.number(team["id"] ?? team["teamId"]), id > 0 { return Int(id) }
        }
        return nil
    }

    /// One page of the export: the events it held, how many rows the server sent, and whether the body was a shape
    /// this build recognises. An unrecognised body is not an empty month — "nothing billed" is a claim about the
    /// account, and making it from a body that could not be read is the silent zero the refusal paths above exist
    /// to avoid. Until 2026-09-19 an unreadable 200 parsed to `[]`, was written down as a clean read of $0, and the
    /// Cost card said "nothing used in the last 30 days" for a seat that was spending.
    struct UsageEventPage: Equatable, Sendable {
        var events: [UsageEvent] = []
        var rows = 0
        var recognised = false
    }

    /// `usageEventsDisplay[]`: `timestamp` (epoch milliseconds, as a string or a number), `model`, and the cost as
    /// `tokenUsage.totalCents` when the call was token-based, else the `usageBasedCosts` dollar string ("$0.05";
    /// "-" and "Included" cost nothing). Token counts come from `tokenUsage` when present.
    static func parseUsageEvents(_ data: Data) -> UsageEventPage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return UsageEventPage() }
        guard let list = (root["usageEventsDisplay"] ?? root["usageEvents"] ?? root["events"]) as? [Any] else {
            // An empty range comes back as `{}`, or as a count of zero alone: the service writes its JSON the
            // protobuf way, leaving out an empty list rather than sending `[]` (seen 2026-09-24 on a seat with no
            // events in the last 30 days). That is a month with nothing in it, read correctly; anything else
            // without the list is still a shape this build does not know.
            // The count may come as a number or, protobuf's way for 64-bit integers, as a string.
            // The count may come as a number or, protobuf's way for 64-bit integers, as a string.
            let count = JSON.number(root["totalUsageEventsCount"]) ?? (root["totalUsageEventsCount"] as? String).flatMap(Double.init) ?? (root["totalUsageEventsCount"] as? String).flatMap(Double.init)
            let empty = root.keys.allSatisfy { $0 == "totalUsageEventsCount" } && (count ?? 0) == 0
            return UsageEventPage(events: [], rows: 0, recognised: empty)
        }
        let events = list.compactMap { item -> UsageEvent? in
            guard let object = item as? [String: Any] else { return nil }
            let stamp: Double? = (object["timestamp"] as? String).flatMap(Double.init) ?? JSON.number(object["timestamp"])
            guard let stamp else { return nil }
            let timestamp = Date(timeIntervalSince1970: stamp > 1e11 ? stamp / 1000 : stamp)
            let usage = object["tokenUsage"] as? [String: Any]
            var tokens = TokenBreakdown()
            tokens.input = Int(JSON.number(usage?["inputTokens"]) ?? 0)
            tokens.output = Int(JSON.number(usage?["outputTokens"]) ?? 0)
            tokens.cacheWrite5m = Int(JSON.number(usage?["cacheWriteTokens"]) ?? 0)
            tokens.cacheRead = Int(JSON.number(usage?["cacheReadTokens"]) ?? 0)
            var cost = (JSON.number(usage?["totalCents"]) ?? 0) / 100
            if cost == 0, let text = object["usageBasedCosts"] as? String {
                cost = Double(text.filter { $0.isNumber || $0 == "." }) ?? 0
            }
            return UsageEvent(timestamp: timestamp, model: object["model"] as? String, tokens: tokens, costUSD: cost)
        }
        // A list with rows in it that yielded no events is a renamed per-event field (the likelier drift, since
        // the list key has three spellings already), not an empty month. A partial parse still counts as read:
        // the fixture's timestamp-less row is skipped and the rest of the page stands.
        return UsageEventPage(events: events, rows: list.count, recognised: events.isEmpty == list.isEmpty)
    }

    /// Per local day: cost, tokens and the per-model split; projects are not part of the export.
    static func dayRecords(_ events: [UsageEvent], calendar: Calendar = .current) -> [Date: CostHistory.Record] {
        var days: [Date: CostHistory.Record] = [:]
        for event in events {
            let day = calendar.startOfDay(for: event.timestamp)
            var record = days[day] ?? CostHistory.Record(cost: 0, tokens: TokenBreakdown(), byModel: [:], byProject: [:])
            record.cost += event.costUSD
            record.tokens += event.tokens
            if let model = event.model {
                record.byModel[model, default: 0] += event.costUSD
                record.byModelTokens[model, default: 0] += event.tokens.total
            }
            days[day] = record
        }
        return days
    }

    /// Today's spend from the usage export against the average day of the thirty before it (or of as many as the
    /// history reaches back), for a seat whose summary meters nothing. Nil until there is a usual day to compare
    /// with. The ring fills at a usual day's spend; the digits keep counting past it.
    static func spendToday(_ days: [Date: CostHistory.Record], now: Date = Date(), calendar: Calendar = .current) -> LimitWindow? {
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -30, to: today),
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
        let prior = days.filter { $0.key >= start && $0.key < today }
        guard let earliest = prior.keys.min() else { return nil }
        let span = max(1, calendar.dateComponents([.day], from: earliest, to: today).day ?? 1)
        let usual = prior.values.reduce(0) { $0 + $1.cost } / Double(span)
        guard usual > 0 else { return nil }
        let spent = days[today]?.cost ?? 0
        let percent = spent / usual * 100
        return LimitWindow(
            id: "spend_today", label: .key("Today's spend"), usedFraction: min(max(spent / usual, 0), 1), resetsAt: tomorrow,
            note: L("%1$@ of a usual %2$@ day", Money.dollars(spent), Money.dollars(usual, cents: false)),
            periodDuration: tomorrow.timeIntervalSince(today), source: .localEstimate, rawUsedPercent: percent > 100 ? percent : nil, amountUSD: spent
        )
    }

    /// The two model meters on a seat whose summary meters nothing. Cursor keeps answering them for such a seat,
    /// and they read 0 % all cycle however much the export shows it spending (an Enterprise seat on 2026-09-20:
    /// $8.76 of export that day against "Cursor models 0 %"). A 0 that money is flowing past is not a figure, so
    /// once the spend window exists (thirty days of export dollars with nothing metered) a split that still reads
    /// exactly 0 loses its fraction and says why. One that reads anything above 0 is alive and is left alone, so a
    /// meter that starts counting comes straight back. The choice in Settings is never rewritten to follow this:
    /// RingSelection yields a choice with no figure to the windows that have one and returns to it by itself.
    static func withoutDeadSplits(_ windows: [LimitWindow]) -> [LimitWindow] {
        windows.map { window in
            guard ["cursor_models", "other_models"].contains(window.id), window.usedFraction == 0 else { return window }
            return LimitWindow(id: window.id, label: window.name, usedFraction: nil, resetsAt: window.resetsAt,
                               note: L("Reads 0% on this seat however much it spends; Today's spend carries the reading"),
                               periodDuration: window.periodDuration, model: window.model, source: window.source,
                               hiddenByDefault: window.hiddenByDefault)
        }
    }

    /// How much of a window is spent, 0...1: whichever of Cursor's two answers reads further along.
    ///
    /// Cursor answers the same question twice for its plan and pooled windows — `totalPercentUsed`, and the
    /// `used`/`limit` pair the note under the bar is written from — and on Enterprise they disagree. One account
    /// read `totalPercentUsed` 55 while `used` and `limit` were both $20, the whole allowance gone.
    ///
    /// The account's own billing export settles which is telling the truth, and it is the dollars. Cursor bills a
    /// request as `On-Demand` only once the included allowance is gone, and that account had 47 On-Demand events
    /// worth $116 in the billing cycle the 55 % was reported for (and $2,306 in the cycle before it). Included was
    /// spent. A bar reading 55 % said there was half an allowance left while every third-party request was already
    /// costing real money, which is the one thing this window must never get wrong.
    ///
    /// So the window is as spent as its furthest-along figure says. Neither field can be shown to be the wrong one
    /// from inside a single reading, but the failures are not symmetric: under-reporting a spent window hides a
    /// meter that is actively charging, while over-reporting one only warns early.
    ///
    /// What `totalPercentUsed` is a percentage *of* remains unknown, and the model splits beside it do not resolve
    /// it — `autoPercentUsed` 47 and `apiPercentUsed` 100 sum to 147, so they are not shares of one total and this
    /// window is not their parent, whatever the caption they carry says. Both open questions are written down in
    /// docs/accuracy.md rather than guessed at, and the dollars stay printed under the bar unaltered, so a
    /// disagreement stays visible on the card.
    static func share(percent: Double?, used: Double?, limit: Double) -> Double {
        let candidates = [percent.map { $0 / 100 }, limit > 0 ? used.map { $0 / limit } : nil].compactMap { $0 }
        return min(max(candidates.max() ?? 0, 0), 1)
    }

    private static func number(_ value: Any?) -> Double? { JSON.number(value) }

    /// The first "NN%" in one of the dashboard's sentences.
    static func percent(in message: String?) -> Double? {
        guard let message, let range = message.range(of: #"\d+(\.\d+)?(?=\s*%)"#, options: .regularExpression) else { return nil }
        return Double(message[range])
    }

    /// Cursor reports plan amounts in cents.
    private static func dollars(_ cents: Double) -> String {
        let value = cents / 100
        return Money.dollars(value, cents: value != value.rounded())
    }

    // MARK: - Session token

    static func jwtClaims(_ token: String) throws -> [String: Any] {
        guard let claims = JWT.claims(token) else { throw ProviderError.parse(L("Cursor session token could not be decoded")) }
        return claims
    }

    static func userID(fromClaims claims: [String: Any]) throws -> String {
        guard let subject = claims["sub"] as? String,
              let id = subject.split(separator: "|", omittingEmptySubsequences: true).last.map(String.init),
              !id.isEmpty
        else { throw ProviderError.parse(L("Cursor session token has no user id")) }
        return id
    }

    // MARK: - State database

    /// Reads one ItemTable value from a private copy of Cursor's state database, so the editor's open
    /// write-ahead log is never touched and a mid-write never trips the read.
    static func stateValue(forKey key: String, database: URL) throws -> String? {
        try withStateCopy(of: database) { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ?1 LIMIT 1", -1, &statement, nil) == SQLITE_OK, let statement else {
                throw ProviderError.unavailable(L("Cursor's state database has no ItemTable"))
            }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, key, -1, transient)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return columnText(statement, 0)
        }
    }

    /// Runs `body` against a read-only connection to a private copy of the state database and its write-ahead
    /// log, deleted afterwards. Cursor holds the live file open and writes it at any moment; a copy is never
    /// locked, never checkpointed under it, and cannot be written by a mistake here. Every reader of the file goes
    /// through this (the session token here, the chats' names in CursorChatNames).
    static func withStateCopy<T>(of database: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("notchmeter-cursor-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        let copy = scratch.appendingPathComponent("state.vscdb")
        try fm.copyItem(at: database, to: copy)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: database.path + suffix)
            if fm.fileExists(atPath: sidecar.path) {
                try? fm.copyItem(at: sidecar, to: URL(fileURLWithPath: copy.path + suffix))
            }
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw ProviderError.unavailable(L("Cursor's state database could not be opened"))
        }
        defer { sqlite3_close(db) }
        return try body(db)
    }

    /// A text or blob column as UTF-8, or nil.
    static func columnText(_ statement: OpaquePointer, _ column: Int32) -> String? {
        if let text = sqlite3_column_text(statement, column) {
            return String(cString: text)
        }
        if let blob = sqlite3_column_blob(statement, column) {
            let length = Int(sqlite3_column_bytes(statement, column))
            return String(data: Data(bytes: blob, count: length), encoding: .utf8)
        }
        return nil
    }
}
