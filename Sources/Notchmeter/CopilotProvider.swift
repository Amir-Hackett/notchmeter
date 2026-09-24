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
    /// The client identity the quota endpoint answers to, the one both live-validated trackers send since the
    /// June 2026 billing change (CodexBar PR #2613, openusage): the endpoint is undocumented and keyed on these.
    static let editorVersion = "vscode/1.96.2"
    static let pluginVersion = "copilot-chat/0.26.7"
    static let copilotUserAgent = "GitHubCopilotChat/0.26.7"
    static let copilotAPIVersion = "2025-04-01"
    /// The documented REST API version, for the organisation billing endpoints, which are public API.
    static let apiVersion = "2022-11-28"
    /// GitHub's published rate: one AI credit is one US cent (docs.github.com, billing for individuals, 2026-09-20).
    static let creditUSD = 0.01

    struct TokenCandidate: Equatable, Sendable {
        let token: String
        let file: URL
        let modified: Date
    }

    private let session: URLSession?
    private let readOrgBilling: @Sendable () -> Bool
    private var working: TokenCandidate?
    private let history: CostHistory?
    /// Where the last credits reading is written down (CopilotCreditsRead), for the delta and the Cost card.
    private let defaults: UserDefaults

    init(session: URLSession? = nil,
         configRoot: URL = Paths.home.appendingPathComponent(".config/github-copilot"),
         ghHosts: URL = Paths.home.appendingPathComponent(".config/gh/hosts.yml"),
         defaults: UserDefaults = .standard, readOrgBilling: (@Sendable () -> Bool)? = nil,
         history: CostHistory? = CostHistory(tool: .copilot)) {
        self.session = session
        self.configRoot = configRoot
        self.ghHosts = ghHosts
        self.defaults = defaults
        self.readOrgBilling = readOrgBilling ?? ProviderOptIn.copilotOrgBilling.reader(defaults)
        self.history = history
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
                recordCredits(Self.creditsUsed(data))
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
        if copilotHeaders {
            request.setValue(Self.copilotUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(Self.editorVersion, forHTTPHeaderField: "Editor-Version")
            request.setValue(Self.pluginVersion, forHTTPHeaderField: "Editor-Plugin-Version")
            request.setValue(Self.copilotAPIVersion, forHTTPHeaderField: "X-Github-Api-Version")
        } else {
            request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
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
    /// `percent_remaining`, `unlimited`, `overage_permitted`, `overage_count` and, since GitHub moved to usage-based
    /// billing on 2026-06-01, `credits_used`; `chat` and `completions` are usually unlimited; `quota_reset_date`
    /// (yyyy-MM-dd or an ISO instant, UTC; `quota_reset_date_utc` and the free tier's `limited_user_reset_date`
    /// are read too) is when the month's allowance returns; `copilot_plan` names it; `token_based_billing` says
    /// the seat is on AI credits.
    ///
    /// Three shapes have been seen since June and each is pinned in CopilotParsingTests: a metered seat with an
    /// entitlement and a remainder; an org-managed token-billed seat whose snapshots are `entitlement: 0,
    /// remaining: 0` placeholders beside a live `credits_used` count; and a free individual whose premium snapshot
    /// is the same placeholder under `percent_remaining: 0`. The rules: `unlimited`, or a `-1` in either count,
    /// means no limit; an entitlement of 0 is a placeholder and never a 0 % (or 100 %) bar, and only its
    /// `credits_used` survives, as a plain count; a count may arrive as a number or a string; without
    /// `percent_remaining` the fraction is `remaining / entitlement`. On a token-billed seat the counts are AI
    /// credits, a cent each at GitHub's published rate, so the window carries its dollars and the Cost card can
    /// show them (docs/accuracy.md).
    static func parseUser(_ data: Data, now: Date = Date()) throws -> UsageReading {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.parse(L("GitHub Copilot's usage response unreadable"))
        }
        // Copilot Free answers `copilot_plan` "individual" like a paid seat and says "free" only in its SKU
        // (`access_type_sku` "free_limited_copilot"), so the plan is named from the SKU where it says so: the
        // advice reads the name to know whether the seat is one worth routing work to (`UsageReading.isPaid`).
        let sku = (root["access_type_sku"] as? String)?.lowercased() ?? ""
        let plan = sku.hasPrefix("free") ? Naming.plan("free") : (root["copilot_plan"] as? String).map(Naming.plan)
        let tokenBilled = (root["token_based_billing"] as? Bool) ?? false
        let resetsAt = resetDate(root["quota_reset_date"]) ?? resetDate(root["quota_reset_date_utc"]) ?? resetDate(root["limited_user_reset_date"])
        let snapshots = root["quota_snapshots"] as? [String: Any] ?? [:]
        var windows: [LimitWindow] = []
        let specs: [(key: String, id: String, label: WindowLabel)] = [
            ("premium_interactions", "premium", .key("Premium requests")),
            ("chat", "chat", .key("Chat")),
            ("completions", "completions", .key("Completions")),
        ]
        for spec in specs {
            guard let snapshot = snapshots[spec.key] as? [String: Any] else { continue }
            let entitlement = count(snapshot["entitlement"])
            let remaining = count(snapshot["remaining"])
            let credits = count(snapshot["credits_used"])
            let percentRemaining = count(snapshot["percent_remaining"])
            // The sentinel is the entitlement's: a seat with `overage_permitted` counts `remaining` below zero
            // once it is into overage, and `-1` there on a metered entitlement is one request over, not no limit.
            let unlimited = (snapshot["unlimited"] as? Bool) ?? false || entitlement == -1 || (remaining == -1 && (entitlement ?? 0) <= 0)
            if unlimited {
                if spec.id == "premium" {
                    windows.append(LimitWindow(id: spec.id, label: spec.label, usedFraction: nil, resetsAt: resetsAt, note: plan.map { L("Unlimited on the %@ plan", $0) } ?? L("Unlimited on the current plan")))
                }
                continue
            }
            // The credits behind a premium snapshot are the seat's AI credits; on the other snapshots they are a
            // count of a quota that has no dollar meaning.
            let inCredits = tokenBilled && spec.id == "premium"
            let creditsNote = credits.flatMap { $0 > 0 ? L("%ld credits used", Int($0)) : nil }
            guard let entitlement, entitlement > 0 else {
                // A placeholder: nothing to fill a bar with, whatever `percent_remaining` says beside it.
                guard let creditsNote, let credits, inCredits else { continue }
                windows.append(LimitWindow(id: "credits", label: .key("AI credits"), usedFraction: nil, resetsAt: resetsAt, note: creditsNote,
                                           periodDuration: resetsAt.map { _ in Period.month }, amountUSD: credits * Self.creditUSD))
                continue
            }
            var used: Double?
            if let percentRemaining { used = JSON.fraction(100 - percentRemaining) }
            else if let remaining { used = min(max(1 - remaining / entitlement, 0), 1) }
            var note: String?
            if let remaining {
                note = inCredits ? L("%1$ld of %2$ld credits left", Int(max(0, remaining)), Int(entitlement))
                                 : L("%1$ld of %2$ld left", Int(max(0, remaining)), Int(entitlement))
            }
            let overage = count(snapshot["overage_count"]) ?? 0
            if overage > 0 {
                let extra = L("%ld extra this month", Int(overage))
                note = note.map { "\($0) · \(extra)" } ?? extra
            } else if (snapshot["overage_permitted"] as? Bool) == true, used.map({ $0 >= 1 }) == true {
                note = note.map { "\($0) · \(L("extra usage on"))" } ?? L("extra usage on")
            }
            if !inCredits, let creditsNote {
                note = note.map { "\($0) · \(creditsNote)" } ?? creditsNote
            }
            let spent = credits ?? remaining.map { max(0, entitlement - $0) }
            windows.append(LimitWindow(id: inCredits ? "credits" : spec.id, label: inCredits ? .key("AI credits") : spec.label, usedFraction: used,
                                       resetsAt: resetsAt, note: note, periodDuration: resetsAt.map { _ in Period.month },
                                       amountUSD: inCredits ? spent.map { $0 * Self.creditUSD } : nil))
        }
        // Copilot Free answers without snapshots: `monthly_quotas` is the allowance and `limited_user_quotas` what
        // is left of it, reset on `limited_user_reset_date`.
        if windows.isEmpty, let allowance = root["monthly_quotas"] as? [String: Any] {
            let left = root["limited_user_quotas"] as? [String: Any] ?? [:]
            let freeReset = resetDate(root["limited_user_reset_date"]) ?? resetsAt
            for (key, id, label) in [("chat", "chat", WindowLabel.key("Chat")), ("completions", "completions", WindowLabel.key("Completions"))] {
                guard let total = count(allowance[key]), total > 0 else { continue }
                let remaining = count(left[key]) ?? total
                windows.append(LimitWindow(id: id, label: label, usedFraction: min(max(1 - remaining / total, 0), 1), resetsAt: freeReset,
                                           note: L("%1$ld of %2$ld left", Int(max(0, remaining)), Int(total)),
                                           periodDuration: freeReset.map { _ in Period.month }))
            }
        }
        // An account that names its plan but no quota says so on the card; an error here kept the last figures up as
        // if current. A body with no plan either is not an account's answer at all.
        guard !windows.isEmpty || root["copilot_plan"] != nil else { throw ProviderError.parse(L("GitHub Copilot reported no quota")) }
        if windows.isEmpty {
            // A token-billed seat with every snapshot a placeholder and no credit spent yet is a seat on credits
            // that has used none, which is a figure of a kind; anything else reported no quota at all.
            windows.append(tokenBilled
                ? LimitWindow(id: "credits", label: .key("AI credits"), usedFraction: nil, resetsAt: resetsAt, note: L("No credits used this month yet"),
                              periodDuration: resetsAt.map { _ in Period.month }, amountUSD: 0)
                : LimitWindow(id: "premium", label: .key("Premium requests"), usedFraction: nil, resetsAt: resetsAt, note: L("GitHub Copilot reported no quota")))
        }
        return UsageReading(tool: .copilot, windows: windows, plan: plan, fetchedAt: now, observedAt: nil)
    }

    /// The AI credits the seat has used this month, every snapshot's `credits_used` added up; nil when no snapshot
    /// carries the field, which is a seat that is not metered in credits rather than one that used none.
    static func creditsUsed(_ data: Data) -> Double? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let snapshots = root["quota_snapshots"] as? [String: Any] else { return nil }
        let counts = snapshots.values.compactMap { count(($0 as? [String: Any])?["credits_used"]) }
        return counts.isEmpty ? nil : counts.reduce(0, +)
    }

    /// A count as GitHub sends it: a number, or the same digits as a string.
    static func count(_ value: Any?) -> Double? {
        JSON.number(value) ?? (value as? String).flatMap(Double.init)
    }

    /// "2026-10-01" is midnight UTC of that day; an ISO instant is read as it is.
    static func resetDate(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return resetDate(text)
    }

    static func resetDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text) ?? DateParsing.iso8601(text)
    }

    // MARK: - AI credits on the Cost card

    /// The month's credits, as GitHub counts them, folded into the daily-totals file as a Copilot series: each
    /// read's rise over the last is a cent a credit, on the day it was seen. The month's running total is the
    /// only figure GitHub publishes, so the day series is what this Mac observed between polls, and the first
    /// read of a month sets the baseline rather than charging the whole count to one day (docs/accuracy.md). A
    /// fall in the count is the month's reset and starts the count again. Nothing is priced: the rate is
    /// GitHub's own, the count is GitHub's own, and a seat whose snapshots carry no `credits_used` writes nothing.
    private func recordCredits(_ credits: Double?, now: Date = Date()) {
        let previous = CopilotCreditsRead.load(from: defaults)
        guard let credits else {
            CopilotCreditsRead(readAt: now, credits: nil).save(to: defaults)
            return
        }
        defer { CopilotCreditsRead(readAt: now, credits: credits).save(to: defaults) }
        guard let history, let last = previous?.credits else { return }
        let rise = credits >= last ? credits - last : credits
        guard rise > 0 else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let existing = history.load(calendar: calendar)
        var record = existing[today] ?? CostHistory.Record(cost: 0, tokens: TokenBreakdown(), byModel: [:], byProject: [:])
        record.cost += rise * Self.creditUSD
        history.record([today: record], existing: existing, calendar: calendar)
        log.notice("Copilot credits: \(Int(rise)) more since the last read, \(Int(credits)) this month")
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
