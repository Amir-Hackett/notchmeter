import Foundation
import SQLite3

/// Cursor keeps its web session token in the editor's state database. The token doubles as the dashboard
/// cookie, which is how cursor.com's own usage page reads the billing-cycle numbers.
actor CursorProvider: UsageProvider {
    nonisolated let tool: ToolID = .cursor
    nonisolated let refreshInterval: TimeInterval = 300
    nonisolated let stateDatabase: URL

    static let summaryURL = URL(string: "https://cursor.com/api/usage-summary")!
    static let legacyUsageURL = URL(string: "https://cursor.com/api/usage")!

    private let session: URLSession

    init(session: URLSession = .shared,
         stateDatabase: URL = Paths.home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")) {
        self.session = session
        self.stateDatabase = stateDatabase
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

        let (data, status) = try await get(Self.summaryURL, cookie: cookie)
        switch status {
        case 200:
            return try Self.parseSummary(data)
        case 401, 403:
            throw ProviderError.notSignedIn(L("Cursor's login was refused. Sign in to Cursor in the editor again"))
        case 404:
            var components = URLComponents(url: Self.legacyUsageURL, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "user", value: userID)]
            let (legacy, legacyStatus) = try await get(components.url!, cookie: cookie)
            guard legacyStatus == 200 else { throw ProviderError.http(legacyStatus, L("Cursor usage endpoint answered")) }
            return try Self.parseLegacyUsage(legacy)
        case 429:
            throw ProviderError.rateLimited(retryAfter: nil)
        default:
            throw ProviderError.http(status, L("Cursor usage endpoint answered"))
        }
    }

    private func get(_ url: URL, cookie: String) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    // MARK: - Parsing

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
        let individual = root["individualUsage"] as? [String: Any]
        let plan = individual?["plan"] as? [String: Any]
        let onDemand = individual?["onDemand"] as? [String: Any]

        var windows: [LimitWindow] = []

        let planEnabled = (plan?["enabled"] as? Bool) ?? (plan != nil)
        let planLimit = number(plan?["limit"])
        let planUsed = number(plan?["used"])
        let planPercent = number(plan?["totalPercentUsed"])
        if unlimited {
            windows.append(LimitWindow(
                id: "included", label: L("Included usage"), usedFraction: nil, resetsAt: cycleEnd,
                note: L("Unlimited on the %@ plan", planName ?? L("current"))
            ))
        } else if planEnabled, let planLimit, planLimit > 0 {
            let fraction = planPercent.map { $0 / 100 } ?? (planUsed.map { $0 / planLimit } ?? 0)
            windows.append(LimitWindow(
                id: "included", label: L("Included usage"), usedFraction: min(max(fraction, 0), 1), resetsAt: cycleEnd,
                note: planUsed.map { L("%1$@ of %2$@", dollars($0), dollars(planLimit)) },
                periodDuration: cycle
            ))
        } else {
            windows.append(LimitWindow(
                id: "included", label: L("Included usage"), usedFraction: nil, resetsAt: cycleEnd,
                note: L("%@ plan has nothing for Cursor to meter yet", planName ?? L("This"))
            ))
        }

        if let onDemand, (onDemand["enabled"] as? Bool) == true, let limit = number(onDemand["limit"]), limit > 0 {
            let used = number(onDemand["used"]) ?? 0
            windows.append(LimitWindow(
                id: "on_demand", label: L("On-demand"), usedFraction: min(max(used / limit, 0), 1), resetsAt: cycleEnd,
                note: L("%1$@ of %2$@", dollars(used), dollars(limit)),
                periodDuration: cycle
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
            label: L("Fast requests"),
            usedFraction: limit.flatMap { $0 > 0 ? min(max(used / $0, 0), 1) : nil },
            resetsAt: resets,
            note: limit.map { L("%1$ld of %2$ld requests", Int(used), Int($0)) }
        )
        return UsageReading(tool: .cursor, windows: [window], plan: nil, fetchedAt: now, observedAt: nil)
    }

    private static func number(_ value: Any?) -> Double? { JSON.number(value) }

    /// Cursor reports plan amounts in cents.
    private static func dollars(_ cents: Double) -> String {
        let value = cents / 100
        return value == value.rounded() ? "$\(Int(value))" : String(format: "$%.2f", value)
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
