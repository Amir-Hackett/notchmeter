import Foundation

/// GitHub Copilot's premium-request quota, read the way Copilot's own editor plugin reads it: the OAuth token the
/// plugin saved in `~/.config/github-copilot/apps.json` (or `hosts.json`, or the `gh` CLI's `hosts.yml`), used for one
/// `GET https://api.github.com/copilot_internal/user` with the Copilot client headers. The token is never refreshed
/// or written; nothing but this request is made.
actor CopilotProvider: UsageProvider {
    nonisolated let tool: ToolID = .copilot
    nonisolated let refreshInterval: TimeInterval = 300
    nonisolated let configRoot: URL
    nonisolated let ghHosts: URL

    static let userURL = URL(string: "https://api.github.com/copilot_internal/user")!
    static let editorVersion = "vscode/1.104.0"
    static let pluginVersion = "copilot-chat/0.31.0"

    private let session: URLSession

    init(session: URLSession = NetworkSession.shared,
         configRoot: URL = Paths.home.appendingPathComponent(".config/github-copilot"),
         ghHosts: URL = Paths.home.appendingPathComponent(".config/gh/hosts.yml")) {
        self.session = session
        self.configRoot = configRoot
        self.ghHosts = ghHosts
    }

    nonisolated func isInstalled() -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: configRoot.path) || fm.fileExists(atPath: Paths.home.appendingPathComponent(".vscode/extensions").path)
            && (try? fm.contentsOfDirectory(atPath: Paths.home.appendingPathComponent(".vscode/extensions").path))?.contains { $0.hasPrefix("github.copilot") } == true
    }

    func fetch() async throws -> UsageReading {
        guard let token = Self.token(configRoot: configRoot, ghHosts: ghHosts) else {
            throw ProviderError.notSignedIn(L("Sign in to GitHub Copilot in your editor (or run `gh auth login`) to read your usage"))
        }
        var request = URLRequest(url: Self.userURL)
        request.timeoutInterval = 20
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.editorVersion, forHTTPHeaderField: "Editor-Version")
        request.setValue(Self.pluginVersion, forHTTPHeaderField: "Editor-Plugin-Version")
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200:
            return try Self.parseUser(data)
        case 401, 403:
            throw ProviderError.notSignedIn(L("GitHub Copilot's login was refused. Sign in again in your editor"))
        case 404:
            throw ProviderError.unavailable(L("This GitHub account has no Copilot subscription"))
        case 429:
            throw ProviderError.rateLimited(retryAfter: nil)
        case let code:
            throw ProviderError.http(code, L("GitHub's Copilot endpoint answered"))
        }
    }

    // MARK: - Token

    /// `apps.json` and `hosts.json` map "github.com:<client id>" to `{"user", "oauth_token"}`; gh's hosts.yml keeps
    /// `github.com:\n  oauth_token: …`. The first token found wins, in that order.
    static func token(configRoot: URL, ghHosts: URL) -> String? {
        for name in ["apps.json", "hosts.json"] {
            guard let data = try? Data(contentsOf: configRoot.appendingPathComponent(name)),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            for (host, value) in root.sorted(by: { $0.key < $1.key }) where host.hasPrefix("github.com") {
                if let token = (value as? [String: Any])?["oauth_token"] as? String, !token.isEmpty { return token }
            }
        }
        if let text = try? String(contentsOf: ghHosts, encoding: .utf8) { return token(inHostsYAML: text) }
        return nil
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
        let specs: [(key: String, id: String, label: String)] = [
            ("premium_interactions", "premium", L("Premium requests")),
            ("chat", "chat", L("Chat")),
            ("completions", "completions", L("Completions")),
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
}
