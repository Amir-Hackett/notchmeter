import Foundation

/// The `--statusline` command: Claude Code hands its status-line script a JSON object after every turn, carrying
/// the context window's fill, the official five-hour and seven-day rate limits (Pro and Max plans) and, behind a
/// Claude apps gateway, a spend limit; the session's cost, the model and its effort level; the git branch and the
/// open pull request. The command forwards those to the running app over the same socket as the hook
/// (HookSocket.swift; a distributed notification until 0.6.0), then prints one line for Claude Code's own bar, or
/// runs the status-line command that was configured before (`--then '<command>'`) with the same JSON so nothing
/// the user had is lost.
/// Since 0.7.0 it also carries the prompt-cache diagnostics (`prompt_cache`), fast mode, extended thinking, the
/// agent's and the session's names, the lines added and removed, the time spent waiting on the API and the
/// repository's host, owner and name, and keeps the three context-usage counts apart.
/// Never forwarded: the transcript path, the working directory beyond its project name (ProjectName.ofPath: the
/// repository a worktree was cut from, else the basename), the prompt.
enum Statusline {
    static let readBudget: TimeInterval = 0.2

    /// Claude Code's own account of the session's prompt cache (2.1.251+; the causes from 2.1.260), field for
    /// field as the status line documents it. Every one is optional; `null` on the wire reads as absent.
    struct PromptCache: Equatable, Sendable {
        /// Whether the cached prefix is still within its TTL.
        var warm: Bool?
        /// Whether any response this session reported cache tokens.
        var cachingObserved: Bool?
        /// "5m" or "1h".
        var ttl: String?
        var expiresAt: Date?
        var requests: Int?
        /// Requests that re-processed content the cache already held.
        var misses: Int?
        /// Rebuilds that followed a compaction or a clearing of old tool results, not counted as misses.
        var expectedRebuilds: Int?
        var hitRatio: Double?
        var cacheWriteTokens: Int?
        /// Tokens written to the cache by the requests counted as misses.
        var missRecacheTokens: Int?
        var lastMissAt: Date?
        /// `last_miss_cause.causes`: `tools_changed`, `system_prompt_changed`, `ttl_expired_5m`, `likely_server_side`.
        var lastMissCauses: [String] = []
        var toolsAdded: Int?
        var toolsRemoved: Int?
        var systemCharDelta: Int?
        /// `miss_causes`: how many diagnosed misses had each cause.
        var missCauses: [String: Int] = [:]
        var recacheTokensIfCold: Int?

        var isEmpty: Bool { self == PromptCache() }
    }

    struct Message: Equatable, Sendable {
        let sessionID: String?
        let project: String?
        let model: String?
        /// `effort.level`: "low", "medium", "high", "max".
        let effort: String?
        /// Context window fill, 0...1; nil early in a session.
        let contextUsed: Double?
        let contextTokens: Int?
        let contextSize: Int?
        let sessionCost: Double?
        /// The five-hour, seven-day and spend-limit windows, in that order, when the payload carries them.
        let windows: [LimitWindow]
        /// `worktree.branch`, else the basename of `workspace.git_worktree`.
        let branch: String?
        /// `pr.url` of the branch's open pull request.
        let prURL: String?
        let receivedAt: Date
        /// The context's three usage counts kept apart (`contextTokens` is their sum): fresh input, cache writes
        /// and cache reads at the last response.
        var inputTokens: Int? = nil
        var cacheCreationTokens: Int? = nil
        var cacheReadTokens: Int? = nil
        var promptCache: PromptCache? = nil
        var fastMode: Bool? = nil
        /// `thinking.enabled`.
        var thinking: Bool? = nil
        /// `agent.name`, when the session runs under `--agent` or agent settings.
        var agentName: String? = nil
        /// `session_name`: the name set with `--name` or `/rename`, else the AI-generated title; never the default
        /// `my-app-3f` display name, which Claude Code leaves out.
        var sessionName: String? = nil
        var linesAdded: Int? = nil
        var linesRemoved: Int? = nil
        /// `cost.total_api_duration_ms`.
        var apiDurationMs: Int? = nil
        /// `workspace.repo`: the origin remote's host, owner and name.
        var repoHost: String? = nil
        var repoOwner: String? = nil
        var repoName: String? = nil

        /// Whether it can stand in for the endpoint at `now`: under three minutes old and not describing a window
        /// that has since reset. A line from just before a reset still says 100 %, and adopting it again in place of
        /// the reset refresh held the old ring up for the rest of those three minutes.
        func standsIn(at now: Date) -> Bool {
            !windows.isEmpty && now.timeIntervalSince(receivedAt) < PollingPolicy.statuslineFreshFor
                && !windows.contains { $0.resetsAt.map { $0 <= now } ?? false }
        }

        init(sessionID: String? = nil, project: String? = nil, model: String? = nil, effort: String? = nil, contextUsed: Double? = nil,
             contextTokens: Int? = nil, contextSize: Int? = nil, sessionCost: Double? = nil, windows: [LimitWindow] = [], branch: String? = nil,
             prURL: String? = nil, receivedAt: Date) {
            self.sessionID = sessionID
            self.project = project
            self.model = model
            self.effort = effort
            self.contextUsed = contextUsed
            self.contextTokens = contextTokens
            self.contextSize = contextSize
            self.sessionCost = sessionCost
            self.windows = windows
            self.branch = branch
            self.prURL = prURL
            self.receivedAt = receivedAt
        }

        /// The payload as it crosses to the app: flat, property-list values only, which is also what one JSON line
        /// can carry. The shape has not changed with the transport.
        var userInfo: [String: Any] {
            var info: [String: Any] = ["receivedAt": receivedAt.timeIntervalSince1970]
            if let sessionID { info["session_id"] = sessionID }
            if let project { info["project"] = project }
            if let model { info["model"] = model }
            if let effort { info["effort"] = effort }
            if let contextUsed { info["context_used"] = contextUsed }
            if let contextTokens { info["context_tokens"] = contextTokens }
            if let contextSize { info["context_size"] = contextSize }
            if let sessionCost { info["session_cost"] = sessionCost }
            if let branch { info["branch"] = branch }
            if let prURL { info["pr_url"] = prURL }
            for window in windows {
                if let used = window.usedFraction { info["\(window.id)_used"] = used }
                if let resetsAt = window.resetsAt { info["\(window.id)_reset"] = resetsAt.timeIntervalSince1970 }
                if let raw = window.rawUsedPercent { info["\(window.id)_raw"] = raw }
            }
            if let inputTokens { info["input_tokens"] = inputTokens }
            if let cacheCreationTokens { info["cache_creation_tokens"] = cacheCreationTokens }
            if let cacheReadTokens { info["cache_read_tokens"] = cacheReadTokens }
            if let fastMode { info["fast_mode"] = fastMode }
            if let thinking { info["thinking"] = thinking }
            if let agentName { info["agent_name"] = agentName }
            if let sessionName { info["session_name"] = sessionName }
            if let linesAdded { info["lines_added"] = linesAdded }
            if let linesRemoved { info["lines_removed"] = linesRemoved }
            if let apiDurationMs { info["api_duration_ms"] = apiDurationMs }
            if let repoHost { info["repo_host"] = repoHost }
            if let repoOwner { info["repo_owner"] = repoOwner }
            if let repoName { info["repo_name"] = repoName }
            if let cache = promptCache {
                // The object is flattened under a `cache_` prefix: the wire carries property-list scalars only, so
                // the causes join on a comma and the per-cause counts travel as one JSON string.
                info["prompt_cache"] = true
                if let warm = cache.warm { info["cache_warm"] = warm }
                if let observed = cache.cachingObserved { info["cache_observed"] = observed }
                if let ttl = cache.ttl { info["cache_ttl"] = ttl }
                if let expiresAt = cache.expiresAt { info["cache_expires_at"] = expiresAt.timeIntervalSince1970 }
                if let requests = cache.requests { info["cache_requests"] = requests }
                if let misses = cache.misses { info["cache_misses"] = misses }
                if let rebuilds = cache.expectedRebuilds { info["cache_expected_rebuilds"] = rebuilds }
                if let ratio = cache.hitRatio { info["cache_hit_ratio"] = ratio }
                if let writes = cache.cacheWriteTokens { info["cache_write_tokens"] = writes }
                if let recache = cache.missRecacheTokens { info["cache_miss_recache_tokens"] = recache }
                if let lastMissAt = cache.lastMissAt { info["cache_last_miss_at"] = lastMissAt.timeIntervalSince1970 }
                if !cache.lastMissCauses.isEmpty { info["cache_last_miss_causes"] = cache.lastMissCauses.joined(separator: ",") }
                if let added = cache.toolsAdded { info["cache_tools_added"] = added }
                if let removed = cache.toolsRemoved { info["cache_tools_removed"] = removed }
                if let delta = cache.systemCharDelta { info["cache_system_char_delta"] = delta }
                if !cache.missCauses.isEmpty, let data = try? JSONSerialization.data(withJSONObject: cache.missCauses, options: [.sortedKeys]),
                   let text = String(data: data, encoding: .utf8) {
                    info["cache_miss_causes"] = text
                }
                if let cold = cache.recacheTokensIfCold { info["cache_recache_if_cold"] = cold }
            }
            return info
        }

        init?(userInfo: [AnyHashable: Any]?) {
            guard let userInfo, let received = JSON.number(userInfo["receivedAt"]) else { return nil }
            var windows: [LimitWindow] = []
            for spec in Statusline.windowSpecs {
                guard let used = JSON.number(userInfo["\(spec.id)_used"]) else { continue }
                windows.append(Statusline.window(spec, used: JSON.number(userInfo["\(spec.id)_raw"]) ?? used * 100,
                                                 resetsAt: JSON.number(userInfo["\(spec.id)_reset"]).map { Date(timeIntervalSince1970: $0) }))
            }
            self.init(sessionID: userInfo["session_id"] as? String, project: userInfo["project"] as? String, model: userInfo["model"] as? String,
                      effort: userInfo["effort"] as? String, contextUsed: JSON.number(userInfo["context_used"]),
                      contextTokens: JSON.number(userInfo["context_tokens"]).map(Int.init), contextSize: JSON.number(userInfo["context_size"]).map(Int.init),
                      sessionCost: JSON.number(userInfo["session_cost"]), windows: windows, branch: userInfo["branch"] as? String,
                      prURL: userInfo["pr_url"] as? String, receivedAt: Date(timeIntervalSince1970: received))
            func int(_ key: String) -> Int? { JSON.number(userInfo[key]).map(Int.init) }
            func date(_ key: String) -> Date? { JSON.number(userInfo[key]).map { Date(timeIntervalSince1970: $0) } }
            inputTokens = int("input_tokens")
            cacheCreationTokens = int("cache_creation_tokens")
            cacheReadTokens = int("cache_read_tokens")
            fastMode = userInfo["fast_mode"] as? Bool
            thinking = userInfo["thinking"] as? Bool
            agentName = userInfo["agent_name"] as? String
            sessionName = userInfo["session_name"] as? String
            linesAdded = int("lines_added")
            linesRemoved = int("lines_removed")
            apiDurationMs = int("api_duration_ms")
            repoHost = userInfo["repo_host"] as? String
            repoOwner = userInfo["repo_owner"] as? String
            repoName = userInfo["repo_name"] as? String
            if userInfo["prompt_cache"] as? Bool == true {
                var cache = PromptCache()
                cache.warm = userInfo["cache_warm"] as? Bool
                cache.cachingObserved = userInfo["cache_observed"] as? Bool
                cache.ttl = userInfo["cache_ttl"] as? String
                cache.expiresAt = date("cache_expires_at")
                cache.requests = int("cache_requests")
                cache.misses = int("cache_misses")
                cache.expectedRebuilds = int("cache_expected_rebuilds")
                cache.hitRatio = JSON.number(userInfo["cache_hit_ratio"])
                cache.cacheWriteTokens = int("cache_write_tokens")
                cache.missRecacheTokens = int("cache_miss_recache_tokens")
                cache.lastMissAt = date("cache_last_miss_at")
                cache.lastMissCauses = (userInfo["cache_last_miss_causes"] as? String)?.split(separator: ",").map(String.init) ?? []
                cache.toolsAdded = int("cache_tools_added")
                cache.toolsRemoved = int("cache_tools_removed")
                cache.systemCharDelta = int("cache_system_char_delta")
                if let text = userInfo["cache_miss_causes"] as? String, let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                    cache.missCauses = object.reduce(into: [:]) { if let count = JSON.number($1.value) { $0[$1.key] = Int(count) } }
                }
                cache.recacheTokensIfCold = int("cache_recache_if_cold")
                promptCache = cache
            }
        }
    }

    struct WindowSpec {
        let id: String
        let label: WindowLabel
        let period: TimeInterval?
        let short: String
    }

    /// The spend limit declares no period: Claude Code reports its reset but not its length.
    static let windowSpecs: [WindowSpec] = [
        WindowSpec(id: "five_hour", label: .key("Session"), period: Period.fiveHours, short: "5h"),
        WindowSpec(id: "seven_day", label: .key("Weekly"), period: Period.week, short: "7d"),
        WindowSpec(id: "spend_limit", label: .key("Spend limit"), period: nil, short: "spend"),
    ]

    /// A window from a `used_percentage`, which for the spend limit may exceed 100: the fraction is capped and the
    /// overrun becomes the note.
    static func window(_ spec: WindowSpec, used percent: Double, resetsAt: Date?) -> LimitWindow {
        var note = L("From Claude Code's status line")
        if percent > 100 { note += " · " + L("over by %ld%%", Int((percent - 100).rounded())) }
        return LimitWindow(id: spec.id, label: spec.label, usedFraction: JSON.fraction(percent), resetsAt: resetsAt, note: note,
                           periodDuration: spec.period, source: .statusline, rawUsedPercent: percent > 100 ? percent : nil)
    }

    /// The fields read from Claude Code's JSON: `session_id`, the project name of `cwd` (ProjectName.ofPath: the
    /// repository a worktree was cut from, else the basename), `model.display_name`,
    /// `effort.level`, `context_window.used_percentage` (or its token counts), `cost.total_cost_usd`,
    /// `rate_limits.<window>`'s `used_percentage` and `resets_at` (epoch seconds), `worktree.branch` (else the
    /// basename of `workspace.git_worktree`) and `pr.url`. Any of them may be missing.
    static func message(from payload: Data, now: Date = Date()) -> Message? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        let context = object["context_window"] as? [String: Any]
        let size = JSON.number(context?["context_window_size"]).map(Int.init)
        let usage = context?["current_usage"] as? [String: Any]
        var tokens: Int?
        let inputTokens = JSON.number(usage?["input_tokens"]).map(Int.init)
        let cacheCreationTokens = JSON.number(usage?["cache_creation_input_tokens"]).map(Int.init)
        let cacheReadTokens = JSON.number(usage?["cache_read_input_tokens"]).map(Int.init)
        let counted = [inputTokens, cacheCreationTokens, cacheReadTokens].compactMap { $0 }
        if !counted.isEmpty { tokens = counted.reduce(0, +) }
        var used = JSON.number(context?["used_percentage"]).map { JSON.fraction($0) }
        if used == nil, let tokens, let size, size > 0 { used = min(1, Double(tokens) / Double(size)) }
        var windows: [LimitWindow] = []
        if let limits = object["rate_limits"] as? [String: Any] {
            for spec in windowSpecs {
                guard let window = limits[spec.id] as? [String: Any], let percent = JSON.number(window["used_percentage"]) else { continue }
                windows.append(self.window(spec, used: percent, resetsAt: JSON.number(window["resets_at"]).map { Date(timeIntervalSince1970: $0) }))
            }
        }
        let model = object["model"] as? [String: Any]
        let cost = object["cost"] as? [String: Any]
        let effort = (object["effort"] as? [String: Any])?["level"] as? String
        let worktree = object["worktree"] as? [String: Any]
        let workspace = object["workspace"] as? [String: Any]
        var branch = (worktree?["branch"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if branch == nil, let path = workspace?["git_worktree"] as? String, !path.isEmpty {
            branch = URL(fileURLWithPath: path).lastPathComponent
        }
        let pr = object["pr"] as? [String: Any]
        var message = Message(sessionID: (object["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                              project: (object["cwd"] as? String).flatMap(ClaudeCostScanner.projectName(fromPath:)),
                              model: (model?["display_name"] as? String) ?? (model?["id"] as? String),
                              effort: effort.flatMap { $0.isEmpty ? nil : $0 },
                              contextUsed: used, contextTokens: tokens, contextSize: size,
                              sessionCost: JSON.number(cost?["total_cost_usd"]), windows: windows, branch: branch,
                              prURL: (pr?["url"] as? String).flatMap { $0.isEmpty ? nil : $0 }, receivedAt: now)
        func text(_ value: Any?) -> String? { (value as? String).flatMap { $0.isEmpty ? nil : $0 } }
        message.inputTokens = inputTokens
        message.cacheCreationTokens = cacheCreationTokens
        message.cacheReadTokens = cacheReadTokens
        message.fastMode = object["fast_mode"] as? Bool
        message.thinking = (object["thinking"] as? [String: Any])?["enabled"] as? Bool
        message.agentName = text((object["agent"] as? [String: Any])?["name"])
        message.sessionName = text(object["session_name"])
        message.linesAdded = JSON.number(cost?["total_lines_added"]).map(Int.init)
        message.linesRemoved = JSON.number(cost?["total_lines_removed"]).map(Int.init)
        message.apiDurationMs = JSON.number(cost?["total_api_duration_ms"]).map(Int.init)
        if let repo = workspace?["repo"] as? [String: Any] {
            message.repoHost = text(repo["host"])
            message.repoOwner = text(repo["owner"])
            message.repoName = text(repo["name"])
        }
        if let cache = object["prompt_cache"] as? [String: Any] {
            message.promptCache = promptCache(from: cache)
        }
        return message
    }

    /// `prompt_cache` as documented: every field optional, `null` read as absent, the causes as Claude Code names them.
    static func promptCache(from object: [String: Any]) -> PromptCache {
        func int(_ key: String) -> Int? { JSON.number(object[key]).map(Int.init) }
        func date(_ key: String) -> Date? { JSON.number(object[key]).map { Date(timeIntervalSince1970: $0) } }
        var cache = PromptCache()
        cache.warm = object["warm"] as? Bool
        cache.cachingObserved = object["caching_observed"] as? Bool
        cache.ttl = (object["ttl"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        cache.expiresAt = date("expires_at")
        cache.requests = int("requests")
        cache.misses = int("misses")
        cache.expectedRebuilds = int("expected_rebuilds")
        cache.hitRatio = JSON.number(object["hit_ratio"])
        cache.cacheWriteTokens = int("cache_write_tokens")
        cache.missRecacheTokens = int("miss_recache_tokens")
        cache.lastMissAt = date("last_miss_at")
        if let last = object["last_miss_cause"] as? [String: Any] {
            cache.lastMissCauses = (last["causes"] as? [Any])?.compactMap { $0 as? String } ?? []
            cache.toolsAdded = JSON.number(last["tools_added"]).map(Int.init)
            cache.toolsRemoved = JSON.number(last["tools_removed"]).map(Int.init)
            cache.systemCharDelta = JSON.number(last["system_char_delta"]).map(Int.init)
        }
        if let causes = object["miss_causes"] as? [String: Any] {
            cache.missCauses = causes.reduce(into: [:]) { if let count = JSON.number($1.value) { $0[$1.key] = Int(count) } }
        }
        cache.recacheTokensIfCold = int("recache_tokens_if_cold")
        return cache
    }

    /// Figures the app already has, read from its report file so the command never re-prices a transcript.
    struct Extras: Equatable, Sendable {
        var today: Double?
        var blockCost: Double?
        var blockResetsAt: Date?
        /// Today's prompt-cache miss share over the sessions the app has heard from (`promptCache.missShare` in
        /// the report), behind the same fifteen-minute gate; the payload's own figure wins over it in `line`.
        var cacheMissShare: Double?

        /// The report the running app wrote beside its drain log, when under fifteen minutes old; failing that,
        /// today's total from the daily-totals file. Both are a few kilobytes and read in well under a millisecond.
        static func read(reportFile: URL = Paths.reportFile, history: CostHistory? = CostHistory(), now: Date = Date()) -> Extras {
            var extras = Extras()
            if let data = try? Data(contentsOf: reportFile), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let generated = (root["generatedAt"] as? String).flatMap(DateParsing.iso8601), now.timeIntervalSince(generated) < 15 * 60 {
                if let cost = root["cost"] as? [String: Any] {
                    extras.today = JSON.number(cost["today"])
                    if let block = cost["block"] as? [String: Any] {
                        extras.blockCost = JSON.number(block["cost"])
                        extras.blockResetsAt = (block["end"] as? String).flatMap(DateParsing.iso8601)
                    }
                }
                if let cache = root["promptCache"] as? [String: Any] {
                    extras.cacheMissShare = JSON.number(cache["missShare"])
                }
            }
            if extras.today == nil, let history {
                let today = Calendar.current.startOfDay(for: now)
                extras.today = history.load()[today]?.cost
            }
            return extras
        }
    }

    enum Tint {
        case none, warn, danger

        var code: String {
            switch self {
            case .none: ""
            case .warn: "\u{1B}[33m"
            case .danger: "\u{1B}[31m"
            }
        }
    }

    /// The ring thresholds: orange from 80 %, red from 95 % or once the window is behind pace.
    static func tint(for window: LimitWindow, now: Date) -> Tint {
        let used = window.usedFraction ?? 0
        if used >= 0.95 || Pace.status(for: window, now: now) == .behind { return .danger }
        if used >= 0.8 || Pace.status(for: window, now: now) == .onTrack { return .warn }
        return .none
    }

    static func tint(context used: Double) -> Tint {
        used >= 0.95 ? .danger : used >= 0.8 ? .warn : .none
    }

    /// A miss in one request of ten is worth a colour; one in four, the alarm colour.
    static let cacheMissWarn = 0.1
    static let cacheMissDanger = 0.25

    static func tint(cacheMiss share: Double) -> Tint {
        share >= cacheMissDanger ? .danger : share >= cacheMissWarn ? .warn : .none
    }

    /// "Opus high · ctx 62% · 5h 45% ↻2h · 7d 13% ↻5d · $1.23 · today $12 · block $3.10 ↻2h · cache 14% miss": only
    /// what the payload and the app's report carried, in Claude Code's own bar, with the ring colours as ANSI codes
    /// when asked. The cache part is the session's own miss share from the payload when Claude Code sends one;
    /// otherwise today's from the app's report, behind its fifteen-minute gate; absent before the first request.
    static func line(_ message: Message, extras: Extras = Extras(), colors: Bool = false) -> String {
        func paint(_ text: String, _ tint: Tint) -> String {
            colors && tint != .none ? "\(tint.code)\(text)\u{1B}[0m" : text
        }
        var parts: [String] = []
        if let model = message.model {
            parts.append(message.effort.map { "\(model) \($0)" } ?? model)
        }
        if let used = message.contextUsed { parts.append(paint("ctx \(Int((used * 100).rounded()))%", tint(context: used))) }
        for window in message.windows {
            guard let used = window.usedFraction else { continue }
            let name = windowSpecs.first { $0.id == window.id }?.short ?? window.id
            let percent = Int(((window.rawUsedPercent.map { $0 / 100 } ?? used) * 100).rounded())
            var part = "\(name) \(percent)%"
            if let resetsAt = window.resetsAt, resetsAt > message.receivedAt {
                part += " ↻" + ResetText.compactDuration(resetsAt.timeIntervalSince(message.receivedAt))
            }
            parts.append(paint(part, tint(for: window, now: message.receivedAt)))
        }
        if let cost = message.sessionCost { parts.append(Money.dollars(cost)) }
        if let today = extras.today { parts.append("today " + Money.dollars(today, cents: today < 10)) }
        if let block = extras.blockCost {
            var part = "block " + Money.dollars(block)
            if let resetsAt = extras.blockResetsAt, resetsAt > message.receivedAt {
                part += " ↻" + ResetText.compactDuration(resetsAt.timeIntervalSince(message.receivedAt))
            }
            parts.append(part)
        }
        let ownShare = message.promptCache.flatMap { cache -> Double? in
            guard let requests = cache.requests, requests > 0 else { return nil }
            return min(1, Double(cache.misses ?? 0) / Double(requests))
        }
        if let share = ownShare ?? extras.cacheMissShare {
            parts.append(paint("cache \(Int((share * 100).rounded()))% miss", tint(cacheMiss: share)))
        }
        return parts.joined(separator: " · ")
    }

    /// `Notchmeter --statusline [--then '<command>']`: read the JSON, hand it to the running app over its socket,
    /// print the line (or run the previous command with the same JSON on its standard input and pass its output
    /// through), exit 0. As with the hook, the socket's answer is not looked at: the line is printed whether or
    /// not an app was there to take the payload.
    static func runCommand(arguments: [String]) -> Never {
        let payload = Hook.readStandardInput(within: readBudget, limit: 256 * 1024)
        let message = message(from: payload)
        if let message {
            HookSocket.send(.statusline, message.userInfo)
        }
        if let index = arguments.firstIndex(of: "--then"), index + 1 < arguments.count {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", arguments[index + 1]]
            let input = Pipe()
            process.standardInput = input
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
            do {
                try process.run()
                input.fileHandleForWriting.write(payload)
                try? input.fileHandleForWriting.close()
                process.waitUntilExit()
            } catch {
                if let message { Probe.emit(line(message, extras: Extras.read(), colors: true)) }
            }
            exit(0)
        }
        if let message { Probe.emit(line(message, extras: Extras.read(), colors: true)) }
        exit(0)
    }
}
