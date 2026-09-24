import Foundation
import os

private let log = Logger(subsystem: "com.amirhackett.notchmeter", category: "codeassist")

struct CodeAssistCredentials: Equatable {
    let accessToken: String
    let expiresAt: Date?
}

/// One actor type serves two rows since 0.9.0: Gemini CLI's (`tool: .gemini`) and Antigravity's
/// (`tool: .antigravity`). Until then they were one Antigravity row whose identity was picked from what was
/// installed; now each row reads under its own product's identity, so each shows its own figures, and a Mac with
/// both reads both. Gemini CLI's row is installed wherever its login is (`oauth_creds.json`), and asks with Gemini
/// CLI's identity on the two hosts in turn; Antigravity's row is installed wherever the app, its home folder or its
/// CLI's folder is, and asks with Antigravity's identity on the host its CLI logged. Both use the one login on
/// disk, Gemini CLI's, because the Antigravity app and `agy` keep theirs in the Keychain; the backend picks the
/// licence it checks from the identity, so the two rows can rightly disagree.
///
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
///    `SUBSCRIPTION_REQUIRED`: the shutdown, which is documented as permanent, so it is reported as a calm state
///    (`ProviderError.notServed`) rather than a fault. The row reads idle with the sentence as its note, hides under
///    *Hide assistants with nothing to show*, and is asked again about once an hour rather than every five minutes.
///    That matters most for the Antigravity user base, personal Google AI Pro accounts, whose Gemini CLI row would
///    otherwise fail on both hosts at every poll for an answer that is not going to change.
///
/// Buckets are grouped the way Gemini CLI's own /stats view groups them (ui/components/ModelQuotaDisplay.tsx): the
/// Gemini models of one tier (Pro, Flash, Flash Lite) share a pool, so a tier is one window at its lowest remaining
/// fraction; every other model is a window of its own.
///
/// Since September 2026 (docs/accuracy.md, *Antigravity*) three more things are true of these two calls:
///
/// - An Antigravity licence is held by the user, not a project. The project-scoped quota call answers 403 "You do
///   not have a valid license of this product" for an Antigravity-only account while the same call with `{}`
///   answers, and the backend picks which product's licence to check from the caller's identity, so the
///   Antigravity row's calls carry `User-Agent: antigravity`, a `Client-Metadata` naming the IDE, and
///   `ideType: ANTIGRAVITY`; the Gemini CLI row keeps Gemini CLI's own identity, above.
/// - `:retrieveUserQuotaSummary` (`{}`) is the richer answer, the session and weekly groups Antigravity's own
///   panel shows, with a declared window length; it is asked first and the per-model buckets are the fallback.
/// - The quota is metered on one of two deployments, `cloudcode-pa.googleapis.com` and
///   `daily-cloudcode-pa.googleapis.com`, and the other one answers every bucket untouched with a reset five hours
///   from the moment it was asked, whatever has been used (antigravity-cli #387). The Antigravity row prefers the
///   host Antigravity's own CLI logged; failing that, and always for the Gemini CLI row, whose calls that log says
///   nothing about, both are tried and the first with a live figure is believed. A payload
///   whose every bucket reads untouched with one identical reset is written down as unmetered rather than as a
///   100 % ring, a bucket with no fraction is a window with no figure rather than a skipped one, and a fraction of
///   exactly 0 is exhausted.
actor CodeAssistProvider: UsageProvider {
    /// `.gemini` or `.antigravity`: the row this actor reads for, and so the identity its calls carry.
    nonisolated let tool: ToolID
    nonisolated let refreshInterval: TimeInterval = 300
    nonisolated let credentialsFile: URL
    nonisolated let applicationBundle: URL
    nonisolated let antigravityHome: URL
    /// `~/.gemini/antigravity-cli`: the Antigravity CLI's own folder, whose presence marks the login as Antigravity's
    /// and whose `cli.log` names the deployment the account is metered on.
    nonisolated let antigravityCLIHome: URL

    static let productionHost = "cloudcode-pa.googleapis.com"
    static let dailyHost = "daily-cloudcode-pa.googleapis.com"
    /// The order tried when no log names a host: the daily deployment first, because it is the one a production
    /// read misreports for, and the production one answers a daily-metered account with untouched buckets that
    /// the liveness test below then declines.
    static let hostsToTry = [dailyHost, productionHost]
    static func url(host: String, method: String) -> URL { URL(string: "https://\(host)/v1internal:\(method)")! }
    static let codeAssistURL = url(host: productionHost, method: "loadCodeAssist")
    static let quotaURL = url(host: productionHost, method: "retrieveUserQuota")
    static let quotaSummaryURL = url(host: productionHost, method: "retrieveUserQuotaSummary")
    static let codeAssistBody: [String: Any] = codeAssistBody(antigravity: false)
    static func codeAssistBody(antigravity: Bool) -> [String: Any] {
        ["metadata": ["ideType": antigravity ? "ANTIGRAVITY" : "GEMINI_CLI", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]]
    }
    static let antigravityUserAgent = "antigravity"
    static let antigravityClientMetadata = #"{"ideType":"ANTIGRAVITY","platform":"MACOS","pluginType":"GEMINI"}"#
    /// How far a reset may sit from "now plus five hours" and still count as the placeholder an unmetering host
    /// answers with; a real five-hour window that happened to open this very minute reads the same, and is caught
    /// on the next poll when its reset stops moving with the clock.
    static let placeholderResetTolerance: TimeInterval = 120
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

    private let session: URLSession?

    init(tool: ToolID,
         session: URLSession? = nil,
         geminiHome: URL = Paths.home.appendingPathComponent(".gemini"),
         applicationBundle: URL = URL(fileURLWithPath: "/Applications/Antigravity.app"),
         antigravityHome: URL = Paths.home.appendingPathComponent(".antigravity")) {
        self.tool = tool
        self.session = session
        credentialsFile = geminiHome.appendingPathComponent("oauth_creds.json")
        antigravityCLIHome = geminiHome.appendingPathComponent("antigravity-cli")
        self.applicationBundle = applicationBundle
        self.antigravityHome = antigravityHome
    }

    /// Gemini CLI's row: its Google login is on this Mac. Antigravity's row: the app, its home folder or its CLI's
    /// folder is here (`antigravityPresent`); with no Gemini CLI login beside it the row says how to give it one.
    nonisolated func isInstalled() -> Bool {
        switch tool {
        case .antigravity: antigravityPresent
        default: FileManager.default.fileExists(atPath: credentialsFile.path)
        }
    }

    /// Whether Antigravity is set up on this Mac: the app, its home folder or its CLI's folder.
    nonisolated var antigravityPresent: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: antigravityCLIHome.path)
            || fm.fileExists(atPath: applicationBundle.path)
            || fm.fileExists(atPath: antigravityHome.path)
    }

    /// Whether the calls carry Antigravity's identity: the Antigravity row's do, the Gemini CLI row's never.
    nonisolated var identifiesAsAntigravity: Bool { tool == .antigravity }

    /// The deployments to ask, in turn: for the Antigravity row the one its CLI logged, when it logged one; else, and
    /// for the Gemini CLI row always, both.
    nonisolated var hosts: [String] {
        guard tool == .antigravity else { return Self.hostsToTry }
        return Self.loggedHost(in: antigravityCLIHome.appendingPathComponent("cli.log")).map { [$0] } ?? Self.hostsToTry
    }

    /// The login refused or out of date, in the words of the row it is read for: Gemini CLI's row names its own CLI;
    /// Antigravity's names both, since the login it reads is Gemini CLI's and either one refreshes it.
    private var expiredMessage: String {
        tool == .antigravity ? L("Antigravity's login has expired. Run Gemini CLI or Antigravity once so it signs back in")
            : L("Gemini CLI's login has expired. Run Gemini CLI once so it signs back in")
    }

    private var refusedMessage: String {
        tool == .antigravity ? L("Antigravity's login was refused. Run Gemini CLI or Antigravity once so it signs back in")
            : L("Gemini CLI's login was refused. Run Gemini CLI once so it signs back in")
    }

    func fetch() async throws -> UsageReading {
        guard let data = try? Data(contentsOf: credentialsFile) else {
            throw ProviderError.notSignedIn(tool == .antigravity
                ? L("Antigravity keeps its own login in the Keychain; sign in to Gemini CLI with the same Google account (run `gemini` and choose Login with Google) to read its quota")
                : L("Sign in to Gemini CLI (run `gemini` and choose Login with Google) to read your quota"))
        }
        let credentials = try Self.parseCredentials(data)
        if let expiresAt = credentials.expiresAt, expiresAt.timeIntervalSinceNow < 30 {
            throw ProviderError.tokenExpired(expiredMessage)
        }
        let antigravity = identifiesAsAntigravity
        let hosts = self.hosts
        let now = Date()
        var unmetered: UsageReading?
        var shutdown = false
        var lastError: ProviderError?
        var transportError: Error?
        // Every host is tried before anything is given up on: the account load is inside the catch with the
        // quota call, so a host the network cannot reach (the daily alias resolving nowhere, a timeout) is a host
        // passed over, not a failed reading, and the production host still gets its turn.
        for host in hosts {
            do {
                let account = try await loadAccount(host: host, token: credentials.accessToken, antigravity: antigravity)
                if account.unsupported {
                    shutdown = true
                    continue
                }
                let reading = try await quota(host: host, token: credentials.accessToken, account: account, antigravity: antigravity, now: now)
                if Self.looksMetered(reading, now: now) { return reading }
                unmetered = unmetered ?? reading
            } catch let error as ProviderError {
                if case .notServed = error { shutdown = true } else { lastError = error }
            } catch {
                transportError = error
            }
        }
        if let unmetered { return unmetered }
        if shutdown { throw ProviderError.notServed(Self.shutdownMessage) }
        if let lastError { throw lastError }
        if let transportError { throw transportError }
        throw ProviderError.notServed(Self.shutdownMessage)
    }

    /// The reading from one host: the summary's groups first, else the per-model buckets, with a project-scoped
    /// refusal retried project-less before it is taken as a refusal. The retry keeps the first refusal's body for
    /// the shutdown diagnosis, which reads the `SUBSCRIPTION_REQUIRED` reason out of it.
    private func quota(host: String, token: String, account: Account, antigravity: Bool, now: Date) async throws -> UsageReading {
        if let (summary, summaryResponse) = try? await post(Self.url(host: host, method: "retrieveUserQuotaSummary"), token: token, body: [:], antigravity: antigravity),
           summaryResponse?.statusCode == 200, let reading = try? Self.parseQuotaSummary(summary, plan: account.plan, tool: tool, now: now) {
            return reading
        }
        let quotaURL = Self.url(host: host, method: "retrieveUserQuota")
        let body: [String: Any] = account.project.map { ["project": $0] } ?? [:]
        let (quota, response) = try await post(quotaURL, token: token, body: body, antigravity: antigravity)
        if response?.statusCode == 403, account.project != nil {
            let (retry, retryResponse) = try await post(quotaURL, token: token, body: [:], antigravity: antigravity)
            if retryResponse?.statusCode == 200 { return try Self.parseQuota(retry, plan: account.plan, tool: tool, now: now) }
        }
        switch response?.statusCode ?? 0 {
        case 200:
            return try Self.parseQuota(quota, plan: account.plan, tool: tool, now: now)
        case 401:
            throw ProviderError.notSignedIn(refusedMessage)
        case 403:
            guard Self.isSubscriptionRequired(quota) else { throw ProviderError.accessDenied(L("Google refused the quota read for this account")) }
            throw ProviderError.notServed(Self.shutdownMessage)
        case 429:
            throw ProviderError.rateLimited(retryAfter: RetryAfter.seconds(from: response))
        case let status:
            throw ProviderError.http(status, L("Google's quota endpoint answered"))
        }
    }

    /// A refused account is final; any other trouble here leaves the project unknown and lets the quota call decide.
    private func loadAccount(host: String, token: String, antigravity: Bool) async throws -> Account {
        let (data, response) = try await post(Self.url(host: host, method: "loadCodeAssist"), token: token,
                                              body: Self.codeAssistBody(antigravity: antigravity), antigravity: antigravity)
        switch response?.statusCode ?? 0 {
        case 200:
            return try Self.parseAccount(data)
        case 401:
            throw ProviderError.notSignedIn(refusedMessage)
        case 429:
            throw ProviderError.rateLimited(retryAfter: RetryAfter.seconds(from: response))
        default:
            return Account(project: nil, plan: nil, unsupported: false)
        }
    }

    private func post(_ url: URL, token: String, body: [String: Any], antigravity: Bool) async throws -> (Data, HTTPURLResponse?) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if antigravity {
            request.setValue(Self.antigravityUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(Self.antigravityClientMetadata, forHTTPHeaderField: "Client-Metadata")
        } else {
            request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
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

    static func parseCredentials(_ data: Data) throws -> CodeAssistCredentials {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = root["access_token"] as? String, !token.isEmpty
        else {
            throw ProviderError.notSignedIn(L("Gemini CLI has not signed in with Google. Run `gemini` and choose Login with Google"))
        }
        return CodeAssistCredentials(accessToken: token, expiresAt: JSON.number(root["expiry_date"]).map { Date(timeIntervalSince1970: $0 / 1000) })
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

    /// The per-model buckets. A bucket with no `remainingFraction` is a window with no figure (its reset is kept),
    /// never one at 100 % remaining; a fraction of exactly 0 is exhausted; and a payload whose every bucket reads
    /// untouched with the same reset is the shape a host that is not metering this account answers with, so it is
    /// written down as unmetered rather than drawn as untouched.
    static func parseQuota(_ data: Data, plan: String?, tool: ToolID = .antigravity, now: Date = Date()) throws -> UsageReading {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.parse(L("Google's quota response unreadable"))
        }
        var pools: [Pool] = []
        for case let object as [String: Any] in (root["buckets"] as? [Any]) ?? [] {
            guard let modelID = object["modelId"] as? String, !modelID.isEmpty else { continue }
            let remaining = JSON.number(object["remainingFraction"]).map { min(max($0, 0), 1) }
            let resetsAt = (object["resetTime"] as? String).flatMap(DateParsing.iso8601)
            guard remaining != nil || resetsAt != nil else { continue }
            let bucket = Bucket(
                modelID: modelID,
                remaining: remaining,
                resetsAt: resetsAt,
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
        guard !windows.isEmpty else { throw ProviderError.parse(L("Google reported no quota buckets")) }
        return UsageReading(tool: tool, windows: unmeteredIfUntouched(windows), plan: plan, fetchedAt: now, observedAt: nil)
    }

    /// `:retrieveUserQuotaSummary`: `groups[]` (Gemini models; Claude and GPT models), each with `buckets[]` carrying
    /// a `window` of `5h`, `weekly` or `daily`, a `resetTime` and a `remainingFraction`, which the proto-JSON
    /// variant nests as `remaining.remainingFraction` or `remaining.value`. The window length is declared here, so
    /// these windows pace from the first read and need no inference. An unknown window keeps the vendor's own
    /// bucket name.
    static func parseQuotaSummary(_ data: Data, plan: String?, tool: ToolID = .antigravity, now: Date = Date()) throws -> UsageReading {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = root["groups"] as? [[String: Any]], !groups.isEmpty
        else { throw ProviderError.parse(L("Google's quota response unreadable")) }
        var windows: [LimitWindow] = []
        for group in groups {
            let name = groupName(group["displayName"] as? String)
            let slug = name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "_")
            for bucket in (group["buckets"] as? [[String: Any]]) ?? [] {
                let kind = (bucket["window"] as? String)?.lowercased() ?? ""
                let spec: (id: String, label: WindowLabel, period: TimeInterval?) = switch kind {
                case "5h", "5hr", "session": ("session", .key("Session"), Period.fiveHours)
                case "weekly", "week", "7d": ("weekly", .key("Weekly"), Period.week)
                case "daily", "day", "24h": ("daily", .key("Daily"), Period.day)
                default: ((bucket["bucketId"] as? String) ?? kind, .vendor((bucket["displayName"] as? String) ?? kind), nil)
                }
                guard !spec.id.isEmpty else { continue }
                let remaining = remainingFraction(of: bucket).map { min(max($0, 0), 1) }
                windows.append(LimitWindow(id: "\(slug)_\(spec.id)", label: .scoped(model: name, of: spec.label), usedFraction: remaining.map { 1 - $0 },
                                           resetsAt: (bucket["resetTime"] as? String).flatMap(DateParsing.iso8601), periodDuration: spec.period, model: name))
            }
        }
        guard !windows.isEmpty else { throw ProviderError.parse(L("Google reported no quota buckets")) }
        return UsageReading(tool: tool, windows: unmeteredIfUntouched(windows), plan: plan, fetchedAt: now, observedAt: nil)
    }

    /// "Gemini Models" → "Gemini", "Claude and GPT models" → "Claude and GPT": the group's name without the word
    /// every group carries, so the window reads "Gemini Session" rather than "Gemini Models Session".
    static func groupName(_ displayName: String?) -> String {
        let trimmed = (displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Models" }
        for suffix in [" models", " Models"] where trimmed.hasSuffix(suffix) && trimmed.count > suffix.count {
            return String(trimmed.dropLast(suffix.count))
        }
        return trimmed
    }

    /// `remainingFraction` where the bucket carries it, else under `remaining` as the proto-JSON forms nest it.
    static func remainingFraction(of bucket: [String: Any]) -> Double? {
        if let direct = JSON.number(bucket["remainingFraction"]) { return direct }
        guard let nested = bucket["remaining"] as? [String: Any] else { return nil }
        if let fraction = JSON.number(nested["remainingFraction"]) { return fraction }
        if (nested["case"] as? String) == "remainingFraction" { return JSON.number(nested["value"]) }
        return nil
    }

    /// Every window with a figure reads untouched and they all reset at one instant: the answer a host gives for
    /// an account it is not metering, indistinguishable by value from a quota nobody has used. Two or more such
    /// windows lose their figure and say why; a lone untouched window is left as it is.
    static func unmeteredIfUntouched(_ windows: [LimitWindow]) -> [LimitWindow] {
        let figured = windows.filter { $0.usedFraction != nil }
        guard figured.count >= 2, figured.allSatisfy({ ($0.usedFraction ?? 1) <= 0.001 }) else { return windows }
        let resets = figured.compactMap(\.resetsAt)
        guard resets.count == figured.count, let first = resets.first,
              resets.allSatisfy({ abs($0.timeIntervalSince(first)) < 60 }) else { return windows }
        let note = L("Reads untouched on every model, which this host also answers when it is not the one metering you")
        return windows.map { window in
            guard window.usedFraction != nil else { return window }
            return LimitWindow(id: window.id, label: window.name, usedFraction: nil, resetsAt: window.resetsAt, note: note,
                               periodDuration: window.periodDuration, model: window.model, source: window.source, hiddenByDefault: window.hiddenByDefault)
        }
    }

    /// Whether a reading carries a figure worth believing over the other host's: any window with something used,
    /// or any reset that is not the placeholder "five hours from now" an unmetering host answers with.
    static func looksMetered(_ reading: UsageReading, now: Date) -> Bool {
        if reading.windows.contains(where: { ($0.usedFraction ?? 0) > 0.001 }) { return true }
        let placeholder = now.addingTimeInterval(Period.fiveHours)
        return reading.windows.contains { window in
            guard window.usedFraction != nil, let resetsAt = window.resetsAt else { return false }
            return abs(resetsAt.timeIntervalSince(placeholder)) > placeholderResetTolerance
        }
    }

    /// The Code Assist host Antigravity's own CLI last logged (`~/.gemini/antigravity-cli/cli.log` names the
    /// deployment every call went to), which is the deployment the account is metered on; nil without a log or a
    /// host in it. Only a `cloudcode-pa.googleapis.com` host is accepted, so a stray URL in a log line cannot
    /// redirect the token anywhere else.
    static func loggedHost(in log: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return nil }
        defer { try? handle.close() }
        // The last 64 KiB is enough: the log is appended to and the newest lines name the host in use now.
        let size = (try? handle.seekToEnd()) ?? 0
        let tail: UInt64 = 65_536
        try? handle.seek(toOffset: size > tail ? size - tail : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        return loggedHost(inText: text)
    }

    static func loggedHost(inText text: String) -> String? {
        let pattern = #"https://([a-z0-9.-]*cloudcode-pa\.googleapis\.com)(?=[/:\s"']|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.matches(in: text, range: range).last, let hostRange = Range(match.range(at: 1), in: text) else { return nil }
        return text[hostRange].lowercased()
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
        /// nil when Google sent no fraction: unknown, not untouched.
        let remaining: Double?
        let resetsAt: Date?
        let remainingAmount: Int?
    }

    private struct Pool {
        let id: String
        let label: String
        let rank: Int
        let order: Int
        var buckets: [Bucket]

        /// The tightest bucket with a figure sets the figure; the note names the models sharing it, or the count
        /// left when Google sends one. A pool whose buckets carry no fraction is a window with no figure.
        var window: LimitWindow {
            let figured = buckets.filter { $0.remaining != nil }
            let tightest = figured.min { ($0.remaining ?? 1) < ($1.remaining ?? 1) } ?? buckets[0]
            let note: String?
            if buckets.count > 1 {
                note = buckets.map { ModelNames.display($0.modelID) }.joined(separator: " · ")
            } else if let left = tightest.remainingAmount, let remaining = tightest.remaining, remaining > 0 {
                note = L("%1$ld of %2$ld left", left, Int((Double(left) / remaining).rounded()))
            } else {
                note = nil
            }
            return LimitWindow(id: id, label: .vendor(label), usedFraction: tightest.remaining.map { 1 - $0 }, resetsAt: tightest.resetsAt, note: note, model: label)
        }
    }
}

/// A host that is not the one metering an account answers every bucket untouched, and the whole-payload test in
/// `unmeteredIfUntouched` catches that only when every bucket agrees. One window pinned at untouched across poll
/// after poll while the tool was demonstrably in use is the same fault one window at a time, and it cannot be told
/// from a fresh quota by value, so it is told by history: after three consecutive reads at exactly 0 % used, with
/// the row's own tool seen at work since the first of them (Gemini CLI's hook for its row; Antigravity's files for
/// its), the window loses its figure and says it is unverified. The count restarts the moment the figure moves, so
/// a meter that starts counting comes straight back. The store keeps the counts in memory only, per row; a relaunch
/// starts them again, which is the cautious direction.
enum CodeAssistStaleness {
    /// The rows read from Google's Code Assist backend, the two the two-host fault can reach.
    static let tools: Set<ToolID> = [.gemini, .antigravity]
    /// How many consecutive reads at untouched it takes, with activity in between, to stop believing the figure.
    static let readsBeforeUnverified = 3

    /// One window's run of untouched reads: how many, and when the run began.
    struct Run: Equatable, Sendable {
        var count: Int
        var since: Date
    }

    /// The runs after this reading: a window read at exactly 0 % extends its run or starts one; any other figure,
    /// or none, ends it.
    static func runs(after reading: UsageReading, previous: [String: Run], now: Date) -> [String: Run] {
        guard tools.contains(reading.tool) else { return previous }
        var runs: [String: Run] = [:]
        for window in reading.windows {
            guard let used = window.usedFraction, used <= 0.001 else { continue }
            if let run = previous[window.id] {
                runs[window.id] = Run(count: run.count + 1, since: run.since)
            } else {
                runs[window.id] = Run(count: 1, since: now)
            }
        }
        return runs
    }

    /// The reading with every window whose run has reached the threshold, while the tool was seen working after
    /// the run began, marked unverified: no figure, a note saying so, and the local-estimate tag.
    static func unverified(_ reading: UsageReading, runs: [String: Run], activeSince: Date?) -> UsageReading {
        guard tools.contains(reading.tool), let activeSince else { return reading }
        let windows = reading.windows.map { window -> LimitWindow in
            guard let run = runs[window.id], run.count >= readsBeforeUnverified, activeSince > run.since,
                  let used = window.usedFraction, used <= 0.001 else { return window }
            let note = L("Unverified: read untouched across %ld polls while the tool was in use", run.count)
            return LimitWindow(id: window.id, label: window.name, usedFraction: nil, resetsAt: window.resetsAt,
                               note: window.note.map { "\($0) · \(note)" } ?? note, periodDuration: window.periodDuration, model: window.model,
                               source: .localEstimate, hiddenByDefault: window.hiddenByDefault)
        }
        return reading.with(windows: windows)
    }
}

/// Google declares no window length for its quota buckets, only a reset time, so the length is inferred here and
/// said to be: two consecutive resets a window has been seen to count to, about five hours, a day or a week apart,
/// confirm a rolling window of that length and give the meter its pace tick; a first read can only guess from how
/// far off the reset is, which is written as a note and drives nothing. Low confidence by design: Google's own
/// documentation calls these per-day request limits, so a confirmed length is still labelled "inferred". Kimi's
/// answer can carry a window with no declared length too (a named entry, a pool key of another shape), and it gets
/// the same treatment; a window whose length is declared is never inferred over.
enum InferredPeriods {
    /// The rows whose windows may arrive without a length.
    static let tools: Set<ToolID> = [.gemini, .antigravity, .kimi]
    static let candidates: [TimeInterval] = [Period.fiveHours, Period.day, Period.week]
    static let tolerance = 0.2

    /// The window length two resets `apart` imply, when they sit within the tolerance of a candidate.
    static func period(betweenResets apart: TimeInterval) -> TimeInterval? {
        candidates.first { abs(apart - $0) <= $0 * tolerance }
    }

    /// The length a window has been seen to count to: the newest pair of consecutive distinct resets that agree
    /// with one candidate.
    static func confirmedPeriod(resets: [Date]) -> TimeInterval? {
        let distinct = resets.sorted().reduce(into: [Date]()) { list, date in
            if let last = list.last, abs(date.timeIntervalSince(last)) < 60 { return }
            list.append(date)
        }
        guard distinct.count >= 2 else { return nil }
        for (earlier, later) in zip(distinct, distinct.dropFirst()).reversed() {
            if let period = period(betweenResets: later.timeIntervalSince(earlier)) { return period }
        }
        return nil
    }

    /// On a first read, the candidate the time to the reset fits inside.
    static func provisionalPeriod(resetsAt: Date, now: Date) -> TimeInterval? {
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        return candidates.first { remaining <= $0 * (1 + tolerance) }
    }

    /// The reading with each window's length filled in where the reset history confirms one (tagged as an
    /// estimate), and a note naming the likely length where it does not.
    static func apply(_ reading: UsageReading, resets: [String: [Date]], now: Date = Date()) -> UsageReading {
        guard tools.contains(reading.tool) else { return reading }
        let windows = reading.windows.map { window -> LimitWindow in
            guard window.periodDuration == nil, let resetsAt = window.resetsAt else { return window }
            let history = (resets[window.id] ?? []) + [resetsAt]
            if let confirmed = confirmedPeriod(resets: history) {
                let note = L("%@ window inferred from its resets", ResetText.windowName(period: confirmed))
                return window.with(source: .localEstimate, note: window.note.map { "\($0) · \(note)" } ?? note, periodDuration: .some(confirmed))
            }
            if let likely = provisionalPeriod(resetsAt: resetsAt, now: now) {
                let note = L("likely a %@ window", ResetText.windowName(period: likely))
                return window.with(source: window.source, note: window.note.map { "\($0) · \(note)" } ?? note)
            }
            return window
        }
        return reading.with(windows: windows)
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
