import Foundation

struct AntigravityCredentials: Equatable {
    let accessToken: String
    let expiresAt: Date?
}

/// Gemini CLI and Antigravity meter against the same Google Code Assist backend, and Gemini CLI caches its Google
/// login in `~/.gemini/oauth_creds.json` (`Storage.getOAuthCredsPath` in gemini-cli packages/core/src/config/storage.ts),
/// a google-auth-library `Credentials` object: `access_token`, `refresh_token`, `scope`, `token_type`, `id_token` and
/// `expiry_date` in epoch milliseconds, written with mode 0600 by `cacheCredentials` in code_assist/oauth2.ts. That
/// token is used, never refreshed or written, for the two reads Gemini CLI itself makes against
/// `https://cloudcode-pa.googleapis.com/v1internal` (CODE_ASSIST_ENDPOINT and CODE_ASSIST_API_VERSION in
/// code_assist/server.ts), each a POST with `Content-Type: application/json` and the Bearer token:
///
/// 1. `:loadCodeAssist` with `{"metadata":{"ideType":"GEMINI_CLI","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}`
///    (LoadCodeAssistRequest in code_assist/types.ts; GEMINI_CLI is one of its ClientMetadataIdeType values). The
///    answer carries `cloudaicompanionProject`, the project the quota is metered on; `currentTier` with an `id` of
///    free-tier, legacy-tier or standard-tier and a `name`; an optional `paidTier.name`; and, since June 2026,
///    `ineligibleTiers[].reasonCode == "UNSUPPORTED_CLIENT"` for the personal accounts Google no longer serves here.
/// 2. `:retrieveUserQuota` with `{"project":"<cloudaicompanionProject>"}` (RetrieveUserQuotaRequest; Gemini CLI's
///    `Config.refreshUserQuota` in config/config.ts sends exactly this). The answer is `{"buckets":[BucketInfo]}` with
///    `modelId`, `remainingFraction` (0...1 of the quota left), `resetTime` (RFC 3339) and, optionally,
///    `remainingAmount` (a count, as a string) and `tokenType`. No window length is declared, so a window here has no
///    pace tick or projection until Google publishes one. A personal account gets HTTP 403 with the ErrorInfo reason
///    `SUBSCRIPTION_REQUIRED`, reported as the shutdown it is.
///
/// Buckets are grouped the way Gemini CLI's own /stats view groups them (ui/components/ModelQuotaDisplay.tsx): the
/// Gemini models of one tier (Pro, Flash, Flash Lite) share a pool, so a tier is one window at its lowest remaining
/// fraction; every other model is a window of its own; a bucket without a fraction is skipped, as it is there.
actor AntigravityProvider: UsageProvider {
    nonisolated let tool: ToolID = .antigravity
    nonisolated let refreshInterval: TimeInterval = 300
    nonisolated let credentialsFile: URL
    nonisolated let applicationBundle: URL
    nonisolated let antigravityHome: URL

    static let codeAssistURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    static let quotaURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
    static let codeAssistBody: [String: Any] = ["metadata": ["ideType": "GEMINI_CLI", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]]
    static var shutdownMessage: String {
        L("Google stopped serving Gemini CLI quota to personal accounts in June 2026; Code Assist Standard and Enterprise accounts still report it")
    }

    /// What loadCodeAssist says about the account: the project the quota is metered on and the tier it is on.
    struct Account: Equatable {
        let project: String?
        let plan: String?
        /// The consumer shutdown: no tier held, and a tier listed as ineligible because this client is unsupported.
        let unsupported: Bool
    }

    private let session: URLSession

    init(session: URLSession = NetworkSession.shared,
         geminiHome: URL = Paths.home.appendingPathComponent(".gemini"),
         applicationBundle: URL = URL(fileURLWithPath: "/Applications/Antigravity.app"),
         antigravityHome: URL = Paths.home.appendingPathComponent(".antigravity")) {
        self.session = session
        credentialsFile = geminiHome.appendingPathComponent("oauth_creds.json")
        self.applicationBundle = applicationBundle
        self.antigravityHome = antigravityHome
    }

    nonisolated func isInstalled() -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: credentialsFile.path)
            || fm.fileExists(atPath: applicationBundle.path)
            || fm.fileExists(atPath: antigravityHome.path)
    }

    func fetch() async throws -> UsageReading {
        guard let data = try? Data(contentsOf: credentialsFile) else {
            throw ProviderError.notSignedIn(L("Sign in to Gemini CLI (run `gemini` and choose Login with Google) to read your quota"))
        }
        let credentials = try Self.parseCredentials(data)
        if let expiresAt = credentials.expiresAt, expiresAt.timeIntervalSinceNow < 30 {
            throw ProviderError.tokenExpired(L("Antigravity's login has expired. Run Gemini CLI or Antigravity once so it signs back in"))
        }

        let account = try await loadAccount(token: credentials.accessToken)
        if account.unsupported { throw ProviderError.unavailable(Self.shutdownMessage) }

        let body: [String: Any] = account.project.map { ["project": $0] } ?? [:]
        let (quota, status) = try await post(Self.quotaURL, token: credentials.accessToken, body: body)
        switch status {
        case 200:
            return try Self.parseQuota(quota, plan: account.plan)
        case 401:
            throw ProviderError.notSignedIn(L("Antigravity's login was refused. Run Gemini CLI or Antigravity once so it signs back in"))
        case 403:
            guard Self.isSubscriptionRequired(quota) else { throw ProviderError.accessDenied(L("Google refused the quota read for this account")) }
            throw ProviderError.unavailable(Self.shutdownMessage)
        case 429:
            throw ProviderError.rateLimited(retryAfter: nil)
        default:
            throw ProviderError.http(status, L("Google's quota endpoint answered"))
        }
    }

    /// A refused account is final; any other trouble here leaves the project unknown and lets the quota call decide.
    private func loadAccount(token: String) async throws -> Account {
        let (data, status) = try await post(Self.codeAssistURL, token: token, body: Self.codeAssistBody)
        switch status {
        case 200:
            return try Self.parseAccount(data)
        case 401:
            throw ProviderError.notSignedIn(L("Antigravity's login was refused. Run Gemini CLI or Antigravity once so it signs back in"))
        case 429:
            throw ProviderError.rateLimited(retryAfter: nil)
        default:
            return Account(project: nil, plan: nil, unsupported: false)
        }
    }

    private func post(_ url: URL, token: String, body: [String: Any]) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            if let offline = ProviderError.offline(from: error) { throw offline }
            throw error
        }
    }

    // MARK: - Parsing

    static func parseCredentials(_ data: Data) throws -> AntigravityCredentials {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = root["access_token"] as? String, !token.isEmpty
        else {
            throw ProviderError.notSignedIn(L("Gemini CLI has not signed in with Google. Run `gemini` and choose Login with Google"))
        }
        return AntigravityCredentials(accessToken: token, expiresAt: JSON.number(root["expiry_date"]).map { Date(timeIntervalSince1970: $0 / 1000) })
    }

    static func parseAccount(_ data: Data) throws -> Account {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.parse(L("Google's Code Assist response unreadable"))
        }
        let project: String? = switch root["cloudaicompanionProject"] {
        case let id as String: id.isEmpty ? nil : id
        case let reference as [String: Any]: reference["id"] as? String
        default: nil
        }
        let tier = root["currentTier"] as? [String: Any]
        let paidTier = root["paidTier"] as? [String: Any]
        let ineligible = (root["ineligibleTiers"] as? [[String: Any]]) ?? []
        let unsupported = tier == nil && paidTier == nil && ineligible.contains { $0["reasonCode"] as? String == "UNSUPPORTED_CLIENT" }
        return Account(project: project, plan: planName(tier: tier, paidTier: paidTier), unsupported: unsupported)
    }

    /// The paid product's own name when Google gives one, else the tier: "Free", "Legacy", "Standard".
    static func planName(tier: [String: Any]?, paidTier: [String: Any]?) -> String? {
        if let paid = (paidTier?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !paid.isEmpty {
            let prefix = "Gemini Code Assist in "
            return paid.hasPrefix(prefix) ? String(paid.dropFirst(prefix.count)) : paid
        }
        guard let id = tier?["id"] as? String, !id.isEmpty else {
            return (tier?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        let base = id.hasSuffix("-tier") ? String(id.dropLast(5)) : id
        return Naming.plan(base.replacingOccurrences(of: "-", with: " "))
    }

    /// Google's `google.rpc.ErrorInfo` detail on the 403 a personal account gets since the June 2026 shutdown.
    static func isSubscriptionRequired(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any],
              let details = error["details"] as? [[String: Any]]
        else { return false }
        return details.contains { $0["reason"] as? String == "SUBSCRIPTION_REQUIRED" }
    }

    static func parseQuota(_ data: Data, plan: String?, now: Date = Date()) throws -> UsageReading {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.parse(L("Antigravity quota response unreadable"))
        }
        var pools: [Pool] = []
        for case let object as [String: Any] in (root["buckets"] as? [Any]) ?? [] {
            guard let modelID = object["modelId"] as? String, !modelID.isEmpty,
                  let remaining = JSON.number(object["remainingFraction"])
            else { continue }
            let bucket = Bucket(
                modelID: modelID,
                remaining: min(max(remaining, 0), 1),
                resetsAt: (object["resetTime"] as? String).flatMap(DateParsing.iso8601),
                remainingAmount: (object["remainingAmount"] as? String).flatMap { Int($0) } ?? JSON.number(object["remainingAmount"]).map { Int($0) }
            )
            let kind = pool(for: modelID)
            if let index = pools.firstIndex(where: { $0.id == kind.id }) {
                pools[index].buckets.append(bucket)
            } else {
                pools.append(Pool(id: kind.id, label: kind.label, rank: kind.rank, order: pools.count, buckets: [bucket]))
            }
        }
        let windows = pools.sorted { ($0.rank, $0.order) < ($1.rank, $1.order) }.map(\.window)
        guard !windows.isEmpty else { throw ProviderError.parse(L("Antigravity reported no quota buckets")) }
        return UsageReading(tool: .antigravity, windows: windows, plan: plan, fetchedAt: now, observedAt: nil)
    }

    /// Gemini models share their tier's pool; anything else is its own.
    static func pool(for modelID: String) -> (id: String, label: String, rank: Int) {
        let lower = modelID.lowercased()
        if lower.hasPrefix("gemini") {
            if lower.contains("flash-lite") || lower.contains("flash_lite") { return ("gemini_flash_lite", "Gemini Flash Lite", 2) }
            if lower.contains("flash") { return ("gemini_flash", "Gemini Flash", 1) }
            if lower.contains("pro") { return ("gemini_pro", "Gemini Pro", 0) }
        }
        return ("model_\(lower.replacingOccurrences(of: ".", with: "_"))", ModelNames.display(modelID), 3)
    }

    private struct Bucket {
        let modelID: String
        let remaining: Double
        let resetsAt: Date?
        let remainingAmount: Int?
    }

    private struct Pool {
        let id: String
        let label: String
        let rank: Int
        let order: Int
        var buckets: [Bucket]

        /// The tightest bucket sets the figure; the note names the models sharing it, or the count left when Google
        /// sends one.
        var window: LimitWindow {
            let tightest = buckets.min { $0.remaining < $1.remaining } ?? buckets[0]
            let note: String?
            if buckets.count > 1 {
                note = buckets.map { ModelNames.display($0.modelID) }.joined(separator: " · ")
            } else if let left = tightest.remainingAmount, tightest.remaining > 0 {
                note = L("%1$ld of %2$ld left", left, Int((Double(left) / tightest.remaining).rounded()))
            } else {
                note = nil
            }
            return LimitWindow(id: id, label: label, usedFraction: 1 - tightest.remaining, resetsAt: tightest.resetsAt, note: note, model: label)
        }
    }
}

/// "gemini-2.5-pro" → "Gemini 2.5 Pro", "gemini-3-pro-preview" → "Gemini 3 Pro Preview", "claude-sonnet-4-5" →
/// "Claude Sonnet 4.5", "gpt-oss-120b" → "GPT OSS 120B".
enum ModelNames {
    private static let acronyms = ["gpt": "GPT", "oss": "OSS"]

    static func display(_ modelID: String) -> String {
        var words: [String] = []
        for part in modelID.split(whereSeparator: { $0 == "-" || $0 == "_" }) {
            let token = String(part)
            if isVersion(token), token.count <= 2, let last = words.last, isVersion(last) {
                words[words.count - 1] = "\(last).\(token)"
            } else {
                words.append(word(token))
            }
        }
        return words.joined(separator: " ")
    }

    private static func isVersion(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy { $0.isNumber || $0 == "." }
    }

    private static func word(_ token: String) -> String {
        if let acronym = acronyms[token.lowercased()] { return acronym }
        if isVersion(token) { return token }
        if token.count <= 4, token.last == "b", token.dropLast().allSatisfy(\.isNumber) { return token.uppercased() }
        return token.prefix(1).uppercased() + token.dropFirst()
    }
}
