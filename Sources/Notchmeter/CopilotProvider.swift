import Foundation
import os

private let log = Logger(subsystem: "com.amirhackett.notchmeter", category: "copilot")

/// GitHub Copilot's premium-request quota, read the way Copilot's own editor plugin reads it: the OAuth token the
/// plugin saved in `~/.config/github-copilot/apps.json` (or `hosts.json`, or the `gh` CLI's `hosts.yml`), used for one
/// `GET https://api.github.com/copilot_internal/user` with the Copilot client headers. Every saved token is a
/// candidate, newest file first; one that GitHub refuses is passed over for the next, and the one that answered is
/// remembered for the next poll, so a stale entry left behind by an old login cannot shadow a live one. The token
/// is never refreshed or written. Organisation billing is a second read on the same token, opt-in.
actor CopilotProvider: UsageProvider {
    nonisolated let tool: ToolID = .copilot
    nonisolated let refreshInterval: TimeInterval = 300
    nonisolated let configRoot: URL
    nonisolated let ghHosts: URL

    static let userURL = URL(string: "https://api.github.com/copilot_internal/user")!
    static let orgsURL = URL(string: "https://api.github.com/user/orgs")!
    static let editorVersion = "vscode/1.104.0"
    static let pluginVersion = "copilot-chat/0.31.0"
    static let apiVersion = "2022-11-28"

    struct TokenCandidate: Equatable, Sendable {
        let token: String
        let file: URL
        let modified: Date
    }

    private let session: URLSession?
    private let readOrgBilling: @Sendable () -> Bool
    private var working: TokenCandidate?

    init(session: URLSession? = nil,
         configRoot: URL = Paths.home.appendingPathComponent(".config/github-copilot"),
         ghHosts: URL = Paths.home.appendingPathComponent(".config/gh/hosts.yml"),
         defaults: UserDefaults = .standard, readOrgBilling: (@Sendable () -> Bool)? = nil) {
        self.session = session
        self.configRoot = configRoot
        self.ghHosts = ghHosts
        self.readOrgBilling = readOrgBilling ?? ProviderOptIn.copilotOrgBilling.reader(defaults)
    }

    nonisolated func isInstalled() -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: configRoot.path) || fm.fileExists(atPath: Paths.home.appendingPathComponent(".vscode/extensions").path)
            && (try? fm.contentsOfDirectory(atPath: Paths.home.appendingPathComponent(".vscode/extensions").path))?.contains { $0.hasPrefix("github.copilot") } == true
    }

    func fetch() async throws -> UsageReading {
        var candidates = Self.tokenCandidates(configRoot: configRoot, ghHosts: ghHosts)
        guard !candidates.isEmpty else {
            throw ProviderError.notSignedIn(L("Sign in to GitHub Copilot in your editor (or run `gh auth login`) to read your usage"))
        }
        if let working, let index = candidates.firstIndex(of: working) {
            candidates.insert(candidates.remove(at: index), at: 0)
        }
        var refused: [URL] = []
        for candidate in candidates {
            let (data, response) = try await get(Self.userURL, token: candidate.token, copilotHeaders: true)
            switch response?.statusCode ?? 0 {
            case 200:
                working = candidate
                var reading = try Self.parseUser(data)
                if readOrgBilling() {
                    reading = reading.with(windows: reading.windows + (await orgWindows(token: candidate.token)))
                }
                return reading
            case 401, 403:
                refused.append(candidate.file)
                continue
            case 404:
                throw ProviderError.unavailable(L("This GitHub account has no Copilot subscription"))
            case 429:
                throw ProviderError.rateLimited(retryAfter: RetryAfter.seconds(from: response))
            case let code:
                throw ProviderError.http(code, L("GitHub's Copilot endpoint answered"))
            }
        }
        working = nil
        let files = refused.map { Self.shortPath($0) }.joined(separator: ", ")
        throw ProviderError.notSignedIn(L("GitHub Copilot's login was refused (the token in %@). Sign in again in your editor or run `gh auth login`", files))
    }

    private func get(_ url: URL, token: String, copilotHeaders: Bool) async throws -> (Data, HTTPURLResponse?) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(copilotHeaders ? "application/json" : "application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        if copilotHeaders {
            request.setValue(Self.editorVersion, forHTTPHeaderField: "Editor-Version")
            request.setValue(Self.pluginVersion, forHTTPHeaderField: "Editor-Plugin-Version")
        } else {
            request.setValue(Self.apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        }
        let (data, response) = try await (session ?? NetworkSession.shared).data(for: request)
        let http = response as? HTTPURLResponse
        DiagnosticLog.request(log, url.lastPathComponent, status: http?.statusCode ?? 0, bytes: data.count)
        return (data, http)
    }

    /// The organisations the token holder belongs to, and for each that answers, its Copilot billing for the month.
    private func orgWindows(token: String, now: Date = Date()) async -> [LimitWindow] {
        guard let (list, response) = try? await get(Self.orgsURL, token: token, copilotHeaders: false), response?.statusCode == 200 else { return [] }
        var windows: [LimitWindow] = []
        for org in Self.parseOrgs(list).prefix(10) {
            guard let url = Self.orgBillingURL(org: org, now: now),
                  let (data, answer) = try? await get(url, token: token, copilotHeaders: false), answer?.statusCode == 200
            else { continue }
            windows.append(contentsOf: Self.parseOrgBilling(data, org: org))
        }
        return windows
    }

    // MARK: - Token

    /// `apps.json` and `hosts.json` map "github.com:<client id>" to `{"user", "oauth_token"}`; gh's hosts.yml keeps
    /// `github.com:\n  oauth_token: …`. Every entry is a candidate, ordered by its file's modification date, newest
    /// first, then by file name; duplicates of one token are folded.
    static func tokenCandidates(configRoot: URL, ghHosts: URL) -> [TokenCandidate] {
        var candidates: [TokenCandidate] = []
        for name in ["apps.json", "hosts.json"] {
            let file = configRoot.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: file),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            for (host, value) in root.sorted(by: { $0.key < $1.key }) where host.hasPrefix("github.com") {
                if let token = (value as? [String: Any])?["oauth_token"] as? String, !token.isEmpty {
                    candidates.append(TokenCandidate(token: token, file: file, modified: modified))
                }
            }
        }
        if let text = try? String(contentsOf: ghHosts, encoding: .utf8), let token = token(inHostsYAML: text) {
            let modified = (try? ghHosts.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            candidates.append(TokenCandidate(token: token, file: ghHosts, modified: modified))
        }
        var seen: Set<String> = []
        return candidates.sorted { ($0.modified, $1.file.lastPathComponent) > ($1.modified, $0.file.lastPathComponent) }
            .filter { seen.insert($0.token).inserted }
    }

    /// The first candidate's token, for callers that want one; nil with none.
    static func token(configRoot: URL, ghHosts: URL) -> String? {
        tokenCandidates(configRoot: configRoot, ghHosts: ghHosts).first?.token
    }

    static func token(inHostsYAML text: String) -> String? {
        var inGitHub = false
        for rawLine in text.split(separator: "\n") {
            let line = String(rawLine)
            if !line.hasPrefix(" ") { inGitHub = line.trimmingCharacters(in: .whitespaces).hasPrefix("github.com:"); continue }
            guard inGitHub else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("oauth_token:") {
                let token = trimmed.dropFirst("oauth_token:".count).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return token.isEmpty ? nil : token
            }
        }
        return nil
    }

    static func shortPath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: Paths.home.path, with: "~")
    }

    // MARK: - Parsing

    /// `quota_snapshots.premium_interactions` carries the metered window: `entitlement`, `remaining`,
    /// `percent_remaining`, `unlimited`, `overage_permitted`, `overage_count`; `chat` and `completions` are usually
    /// unlimited; `quota_reset_date` (yyyy-MM-dd, UTC) is when the month's allowance returns; `copilot_plan` names it.
    static func parseUser(_ data: Data, now: Date = Date()) throws -> UsageReading {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.parse(L("GitHub Copilot's usage response unreadable"))
        }
        let plan = (root["copilot_plan"] as? String).map(Naming.plan)
        let resetsAt = (root["quota_reset_date"] as? String).flatMap(resetDate)
        let snapshots = root["quota_snapshots"] as? [String: Any] ?? [:]
        var windows: [LimitWindow] = []
        let specs: [(key: String, id: String, label: WindowLabel)] = [
            ("premium_interactions", "premium", .key("Premium requests")),
            ("chat", "chat", .key("Chat")),
            ("completions", "completions", .key("Completions")),
        ]
        for spec in specs {
            guard let snapshot = snapshots[spec.key] as? [String: Any] else { continue }
            let unlimited = (snapshot["unlimited"] as? Bool) ?? false
            let entitlement = JSON.number(snapshot["entitlement"])
            let remaining = JSON.number(snapshot["remaining"])
            let percentRemaining = JSON.number(snapshot["percent_remaining"])
            if unlimited {
                if spec.id == "premium" {
                    windows.append(LimitWindow(id: spec.id, label: spec.label, usedFraction: nil, resetsAt: resetsAt, note: L("Unlimited on the %@ plan", plan ?? L("current"))))
                }
                continue
            }
            var used: Double?
            if let percentRemaining { used = JSON.fraction(100 - percentRemaining) }
            else if let entitlement, entitlement > 0, let remaining { used = min(max(1 - remaining / entitlement, 0), 1) }
            var note: String?
            if let entitlement, let remaining {
                note = L("%1$ld of %2$ld left", Int(max(0, remaining)), Int(entitlement))
            }
            let overage = JSON.number(snapshot["overage_count"]) ?? 0
            if overage > 0 {
                let extra = L("%ld extra this month", Int(overage))
                note = note.map { "\($0) · \(extra)" } ?? extra
            } else if (snapshot["overage_permitted"] as? Bool) == true, used.map({ $0 >= 1 }) == true {
                note = note.map { "\($0) · \(L("extra usage on"))" } ?? L("extra usage on")
            }
            windows.append(LimitWindow(id: spec.id, label: spec.label, usedFraction: used, resetsAt: resetsAt, note: note,
                                       periodDuration: resetsAt.map { _ in Period.month }))
        }
        guard !windows.isEmpty else { throw ProviderError.parse(L("GitHub Copilot reported no quota")) }
        return UsageReading(tool: .copilot, windows: windows, plan: plan, fetchedAt: now, observedAt: nil)
    }

    /// "2026-10-01" is midnight UTC of that day.
    static func resetDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text) ?? DateParsing.iso8601(text)
    }

    // MARK: - Organisation billing

    /// `GET /user/orgs`: the `login` of each organisation.
    static func parseOrgs(_ data: Data) -> [String] {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap { $0["login"] as? String }.filter { !$0.isEmpty }
    }

    /// `GET /orgs/<org>/settings/billing/usage/summary?year=&month=`, this month, for orgs where the token holder is
    /// an owner or billing manager (anyone else gets 403, which is skipped).
    static func orgBillingURL(org: String, now: Date = Date(), calendar: Calendar = .current) -> URL? {
        let components = calendar.dateComponents(in: TimeZone(identifier: "UTC") ?? calendar.timeZone, from: now)
        guard let year = components.year, let month = components.month,
              var url = URLComponents(string: "https://api.github.com/orgs/\(org)/settings/billing/usage/summary") else { return nil }
        url.queryItems = [URLQueryItem(name: "year", value: String(year)), URLQueryItem(name: "month", value: String(month))]
        return url.url
    }

    /// The summary's `usageItems[]` for the Copilot product: the month's spend is the sum of `netAmount`, the
    /// credits consumed the sum of `discountAmount` (what the seat's allowance covered); both in dollars, neither
    /// with a limit, and both off the card until revealed.
    static func parseOrgBilling(_ data: Data, org: String) -> [LimitWindow] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["usageItems"] as? [[String: Any]]
        else { return [] }
        let copilot = items.filter { ($0["product"] as? String)?.lowercased().contains("copilot") ?? false }
        guard !copilot.isEmpty else { return [] }
        let spend = copilot.reduce(0.0) { $0 + (JSON.number($1["netAmount"]) ?? 0) }
        let credits = copilot.reduce(0.0) { $0 + (JSON.number($1["discountAmount"]) ?? 0) }
        let requests = copilot.reduce(0.0) { $0 + (JSON.number($1["quantity"]) ?? 0) }
        let slug = org.lowercased().replacingOccurrences(of: " ", with: "_")
        return [
            LimitWindow(id: "org_\(slug)_credits", label: .filled("%@ org credits", [.text(org)]), usedFraction: nil, resetsAt: nil,
                        note: L("%1$@ covered by the allowance · %2$ld requests this month", Money.dollars(credits), Int(requests)), hiddenByDefault: true, amountUSD: credits),
            LimitWindow(id: "org_\(slug)_spend", label: .filled("%@ org spend", [.text(org)]), usedFraction: nil, resetsAt: nil,
                        note: L("%@ billed this month", Money.dollars(spend)), hiddenByDefault: true, amountUSD: spend),
        ]
    }
}
