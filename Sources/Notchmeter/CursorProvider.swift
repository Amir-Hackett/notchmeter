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
            let reading = try Self.parseSummary(data)
            if readUsageEvents() { await recordUsageEvents(cookie: cookie) }
            return reading
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
    private func recordUsageEvents(cookie: String, now: Date = Date()) async {
        guard let history else { return }
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
                return
            }
            guard response?.statusCode == 200 else {
                // Silence here is what hid an empty Cost card: a refusal reads exactly like a month with no spend.
                let status = response?.statusCode ?? 0
                log.error("Cursor usage events: HTTP \(status) for team \(teamId)")
                CursorExportRead(readAt: now, problem: L("cursor.com refused its usage export (HTTP %ld)", status)).save(to: defaults)
                return
            }
            let batch = Self.parseUsageEvents(data)
            // A server that ignores `page` answers the same events forever; stopping is a short total, counting
            // them twice is a made-up one.
            guard !batch.isEmpty, batch != Array(events.suffix(batch.count)) else { break }
            events += batch
            if batch.count < Self.eventPageSize { break }
            page += 1
        }
        if page > Self.maxEventPages {
            log.error("Cursor usage events: stopped after \(Self.maxEventPages) pages; the total is short")
        }
        let total = events.reduce(0) { $0 + $1.costUSD }
        CursorExportRead(readAt: now, events: events.count, costUSD: total).save(to: defaults)
        guard !events.isEmpty else {
            log.notice("Cursor usage events: none in the last 30 days for team \(teamId)")
            return
        }
        let days = Self.dayRecords(events, calendar: calendar)
        history.record(days, existing: history.load(calendar: calendar), calendar: calendar)
        log.notice("Cursor usage events: \(events.count) over \(days.count) days worth \(Money.dollars(total), privacy: .public)")
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
    /// pooled usage (the main window under "team"), on-demand spend, and the split of the plan's usage between
    /// Cursor's own models and other models, which the switch-models advice can act on and which stay off the
    /// card until revealed in Settings.
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
        let plan = individual?["plan"] as? [String: Any]
        let onDemand = individual?["onDemand"] as? [String: Any]

        var windows: [LimitWindow] = []

        let planEnabled = (plan?["enabled"] as? Bool) ?? (plan != nil)
        let planLimit = number(plan?["limit"])
        let planUsed = number(plan?["used"])
        let planPercent = number(plan?["totalPercentUsed"])
        if unlimited {
            windows.append(LimitWindow(
                id: "included", label: .key("Included usage"), usedFraction: nil, resetsAt: cycleEnd,
                note: L("Unlimited on the %@ plan", planName ?? L("current"))
            ))
        } else if planEnabled, let planLimit, planLimit > 0 {
            let fraction = share(percent: planPercent, used: planUsed, limit: planLimit)
            windows.append(LimitWindow(
                id: "included", label: .key("Included usage"), usedFraction: fraction, resetsAt: cycleEnd,
                note: planUsed.map { L("%1$@ of %2$@", dollars($0), dollars(planLimit)) },
                periodDuration: cycle, amountUSD: planUsed.map { $0 / 100 }
            ))
        } else {
            windows.append(LimitWindow(
                id: "included", label: .key("Included usage"), usedFraction: nil, resetsAt: cycleEnd,
                note: L("%@ plan has nothing for Cursor to meter yet", planName ?? L("This"))
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

        let splits: [(key: String, id: String, label: WindowLabel)] = [
            ("autoPercentUsed", "cursor_models", .key("Cursor models")),
            ("apiPercentUsed", "other_models", .key("Other models")),
        ]
        for (key, id, label) in splits {
            guard let percent = number(plan?[key]) else { continue }
            windows.append(LimitWindow(id: id, label: label, usedFraction: JSON.fraction(percent), resetsAt: cycleEnd,
                                       note: L("Share of the plan's included usage"), periodDuration: cycle, model: label.text, hiddenByDefault: true))
        }

        if let onDemand, (onDemand["enabled"] as? Bool) == true, let limit = number(onDemand["limit"]), limit > 0 {
            let used = number(onDemand["used"]) ?? 0
            windows.append(LimitWindow(
                id: "on_demand", label: .key("On-demand"), usedFraction: min(max(used / limit, 0), 1), resetsAt: cycleEnd,
                note: L("%1$@ of %2$@", dollars(used), dollars(limit)),
                periodDuration: cycle, amountUSD: used / 100
            ))
        }
        if let teamOnDemand = team?["onDemand"] as? [String: Any], (teamOnDemand["enabled"] as? Bool) == true,
           let limit = number(teamOnDemand["limit"]), limit > 0 {
            let used = number(teamOnDemand["used"]) ?? 0
            windows.append(LimitWindow(
                id: "team_on_demand", label: .key("Team on-demand"), usedFraction: min(max(used / limit, 0), 1), resetsAt: cycleEnd,
                note: L("%1$@ of %2$@", dollars(used), dollars(limit)), periodDuration: cycle, hiddenByDefault: true, amountUSD: used / 100
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

    /// `usageEventsDisplay[]`: `timestamp` (epoch milliseconds, as a string or a number), `model`, and the cost as
    /// `tokenUsage.totalCents` when the call was token-based, else the `usageBasedCosts` dollar string ("$0.05";
    /// "-" and "Included" cost nothing). Token counts come from `tokenUsage` when present.
    static func parseUsageEvents(_ data: Data) -> [UsageEvent] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let list = (root["usageEventsDisplay"] ?? root["usageEvents"] ?? root["events"]) as? [Any] ?? []
        return list.compactMap { item -> UsageEvent? in
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
            throw ProviderError.unavailable(L("Cursor's state database could not be opened"))
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ?1 LIMIT 1", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ProviderError.unavailable(L("Cursor's state database has no ItemTable"))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, key, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        if let text = sqlite3_column_text(statement, 0) {
            return String(cString: text)
        }
        if let blob = sqlite3_column_blob(statement, 0) {
            let length = Int(sqlite3_column_bytes(statement, 0))
            return String(data: Data(bytes: blob, count: length), encoding: .utf8)
        }
        return nil
    }
}
