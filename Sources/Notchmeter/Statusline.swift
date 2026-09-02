import Foundation

/// The `--statusline` command: Claude Code hands its status-line script a JSON object after every turn, carrying
/// the context window's fill, the official five-hour and seven-day rate limits (Pro and Max plans) and, behind a
/// Claude apps gateway, a spend limit; the session's cost, the model and its effort level; the git branch and the
/// open pull request. The command forwards those to the running app over the same distributed notification path
/// as the hook, then prints one line for Claude Code's own bar, or runs the status-line command that was configured
/// before (`--then '<command>'`) with the same JSON so nothing the user had is lost.
/// Never forwarded: the transcript path, the working directory beyond its basename, the prompt.
enum Statusline {
    static let notificationName = Notification.Name("com.amirhackett.notchmeter.statusline")
    static let readBudget: TimeInterval = 0.2

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

        /// The distributed notification's payload: flat, property-list values only.
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
        }
    }

    struct WindowSpec {
        let id: String
        let label: String
        let period: TimeInterval?
        let short: String
    }

    /// The spend limit declares no period: Claude Code reports its reset but not its length.
    static let windowSpecs: [WindowSpec] = [
        WindowSpec(id: "five_hour", label: L("Session"), period: Period.fiveHours, short: "5h"),
        WindowSpec(id: "seven_day", label: L("Weekly"), period: Period.week, short: "7d"),
        WindowSpec(id: "spend_limit", label: L("Spend limit"), period: nil, short: "spend"),
    ]

    /// A window from a `used_percentage`, which for the spend limit may exceed 100: the fraction is capped and the
    /// overrun becomes the note.
    static func window(_ spec: WindowSpec, used percent: Double, resetsAt: Date?) -> LimitWindow {
        var note = L("From Claude Code's status line")
        if percent > 100 { note += " · " + L("over by %ld%%", Int((percent - 100).rounded())) }
        return LimitWindow(id: spec.id, label: spec.label, usedFraction: JSON.fraction(percent), resetsAt: resetsAt, note: note,
                           periodDuration: spec.period, source: .statusline, rawUsedPercent: percent > 100 ? percent : nil)
    }

    /// The fields read from Claude Code's JSON: `session_id`, the basename of `cwd`, `model.display_name`,
    /// `effort.level`, `context_window.used_percentage` (or its token counts), `cost.total_cost_usd`,
    /// `rate_limits.<window>`'s `used_percentage` and `resets_at` (epoch seconds), `worktree.branch` (else the
    /// basename of `workspace.git_worktree`) and `pr.url`. Any of them may be missing.
    static func message(from payload: Data, now: Date = Date()) -> Message? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        let context = object["context_window"] as? [String: Any]
        let size = JSON.number(context?["context_window_size"]).map(Int.init)
        let usage = context?["current_usage"] as? [String: Any]
        var tokens: Int?
        if let usage {
            let counted = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].compactMap { JSON.number(usage[$0]) }
            if !counted.isEmpty { tokens = Int(counted.reduce(0, +)) }
        }
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
        return Message(sessionID: (object["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                       project: (object["cwd"] as? String).flatMap(ClaudeCostScanner.projectName(fromPath:)),
                       model: (model?["display_name"] as? String) ?? (model?["id"] as? String),
                       effort: effort.flatMap { $0.isEmpty ? nil : $0 },
                       contextUsed: used, contextTokens: tokens, contextSize: size,
                       sessionCost: JSON.number(cost?["total_cost_usd"]), windows: windows, branch: branch,
                       prURL: (pr?["url"] as? String).flatMap { $0.isEmpty ? nil : $0 }, receivedAt: now)
    }

    /// Figures the app already has, read from its report file so the command never re-prices a transcript.
    struct Extras: Equatable, Sendable {
        var today: Double?
        var blockCost: Double?
        var blockResetsAt: Date?

        /// The report the running app wrote beside its drain log, when under fifteen minutes old; failing that,
        /// today's total from the daily-totals file. Both are a few kilobytes and read in well under a millisecond.
        static func read(reportFile: URL = Paths.reportFile, history: CostHistory? = CostHistory(), now: Date = Date()) -> Extras {
            var extras = Extras()
            if let data = try? Data(contentsOf: reportFile), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let generated = (root["generatedAt"] as? String).flatMap(DateParsing.iso8601), now.timeIntervalSince(generated) < 15 * 60,
               let cost = root["cost"] as? [String: Any] {
                extras.today = JSON.number(cost["today"])
                if let block = cost["block"] as? [String: Any] {
                    extras.blockCost = JSON.number(block["cost"])
                    extras.blockResetsAt = (block["end"] as? String).flatMap(DateParsing.iso8601)
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

    /// "Opus high · ctx 62% · 5h 45% ↻2h · 7d 13% ↻5d · $1.23 · today $12 · block $3.10 ↻2h": only what the payload
    /// and the app's report carried, in Claude Code's own bar, with the ring colours as ANSI codes when asked.
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
        return parts.joined(separator: " · ")
    }

    /// `Notchmeter --statusline [--then '<command>']`: read the JSON, post it, print the line (or run the previous
    /// command with the same JSON on its standard input and pass its output through), exit 0.
    static func runCommand(arguments: [String]) -> Never {
        let payload = Hook.readStandardInput(within: readBudget, limit: 256 * 1024)
        let message = message(from: payload)
        if let message {
            DistributedNotificationCenter.default().postNotificationName(notificationName, object: nil, userInfo: message.userInfo, deliverImmediately: true)
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
