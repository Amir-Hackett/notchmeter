import Foundation

/// The `--statusline` command: Claude Code hands its status-line script a JSON object after every turn, carrying
/// the context window's fill, the official five-hour and seven-day rate limits (Pro and Max plans), the session's
/// cost and the model. The command forwards those numbers to the running app over the same distributed
/// notification path as the hook, then prints one line for Claude Code's own bar, or runs the status-line command
/// that was configured before (`--then '<command>'`) with the same JSON so nothing the user had is lost.
/// Never forwarded: the transcript path, the working directory beyond its basename, the prompt.
enum Statusline {
    static let notificationName = Notification.Name("com.amirhackett.notchmeter.statusline")
    static let readBudget: TimeInterval = 0.2

    struct Message: Equatable, Sendable {
        let sessionID: String?
        let project: String?
        let model: String?
        /// Context window fill, 0...1; nil early in a session.
        let contextUsed: Double?
        let contextTokens: Int?
        let contextSize: Int?
        let sessionCost: Double?
        /// The five-hour and seven-day windows, in that order, when the payload carries them.
        let windows: [LimitWindow]
        let receivedAt: Date

        init(sessionID: String? = nil, project: String? = nil, model: String? = nil, contextUsed: Double? = nil, contextTokens: Int? = nil,
             contextSize: Int? = nil, sessionCost: Double? = nil, windows: [LimitWindow] = [], receivedAt: Date) {
            self.sessionID = sessionID
            self.project = project
            self.model = model
            self.contextUsed = contextUsed
            self.contextTokens = contextTokens
            self.contextSize = contextSize
            self.sessionCost = sessionCost
            self.windows = windows
            self.receivedAt = receivedAt
        }

        /// The distributed notification's payload: flat, property-list values only.
        var userInfo: [String: Any] {
            var info: [String: Any] = ["receivedAt": receivedAt.timeIntervalSince1970]
            if let sessionID { info["session_id"] = sessionID }
            if let project { info["project"] = project }
            if let model { info["model"] = model }
            if let contextUsed { info["context_used"] = contextUsed }
            if let contextTokens { info["context_tokens"] = contextTokens }
            if let contextSize { info["context_size"] = contextSize }
            if let sessionCost { info["session_cost"] = sessionCost }
            for window in windows {
                if let used = window.usedFraction { info["\(window.id)_used"] = used }
                if let resetsAt = window.resetsAt { info["\(window.id)_reset"] = resetsAt.timeIntervalSince1970 }
            }
            return info
        }

        init?(userInfo: [AnyHashable: Any]?) {
            guard let userInfo, let received = JSON.number(userInfo["receivedAt"]) else { return nil }
            var windows: [LimitWindow] = []
            for spec in Statusline.windowSpecs {
                guard let used = JSON.number(userInfo["\(spec.id)_used"]) else { continue }
                windows.append(LimitWindow(id: spec.id, label: spec.label, usedFraction: min(max(used, 0), 1),
                                           resetsAt: JSON.number(userInfo["\(spec.id)_reset"]).map { Date(timeIntervalSince1970: $0) },
                                           note: L("From Claude Code's status line"), periodDuration: spec.period))
            }
            self.init(sessionID: userInfo["session_id"] as? String, project: userInfo["project"] as? String, model: userInfo["model"] as? String,
                      contextUsed: JSON.number(userInfo["context_used"]), contextTokens: JSON.number(userInfo["context_tokens"]).map(Int.init),
                      contextSize: JSON.number(userInfo["context_size"]).map(Int.init), sessionCost: JSON.number(userInfo["session_cost"]),
                      windows: windows, receivedAt: Date(timeIntervalSince1970: received))
        }
    }

    static let windowSpecs: [(id: String, label: String, period: TimeInterval)] = [
        ("five_hour", L("Session"), Period.fiveHours),
        ("seven_day", L("Weekly"), Period.week),
    ]

    /// The fields read from Claude Code's JSON: `session_id`, the basename of `cwd`, `model.display_name`,
    /// `context_window.used_percentage` (or its token counts), `cost.total_cost_usd`, and `rate_limits.<window>`'s
    /// `used_percentage` and `resets_at` (epoch seconds). Any of them may be missing.
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
                windows.append(LimitWindow(id: spec.id, label: spec.label, usedFraction: JSON.fraction(percent),
                                           resetsAt: JSON.number(window["resets_at"]).map { Date(timeIntervalSince1970: $0) },
                                           note: L("From Claude Code's status line"), periodDuration: spec.period))
            }
        }
        let model = object["model"] as? [String: Any]
        let cost = object["cost"] as? [String: Any]
        return Message(sessionID: (object["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                       project: (object["cwd"] as? String).flatMap(ClaudeCostScanner.projectName(fromPath:)),
                       model: (model?["display_name"] as? String) ?? (model?["id"] as? String),
                       contextUsed: used, contextTokens: tokens, contextSize: size,
                       sessionCost: JSON.number(cost?["total_cost_usd"]), windows: windows, receivedAt: now)
    }

    /// "Opus · ctx 62% · 5h 45% · 7d 13% · $1.23": only what the payload carried, in Claude Code's own bar.
    static func line(_ message: Message) -> String {
        var parts: [String] = []
        if let model = message.model { parts.append(model) }
        if let used = message.contextUsed { parts.append("ctx \(Int((used * 100).rounded()))%") }
        for window in message.windows {
            guard let used = window.usedFraction else { continue }
            let name = window.id == "five_hour" ? "5h" : "7d"
            var part = "\(name) \(Int((used * 100).rounded()))%"
            if let resetsAt = window.resetsAt, resetsAt > message.receivedAt {
                part += " ↻" + ResetText.compactDuration(resetsAt.timeIntervalSince(message.receivedAt))
            }
            parts.append(part)
        }
        if let cost = message.sessionCost { parts.append(Money.dollars(cost)) }
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
                if let message { Probe.emit(line(message)) }
            }
            exit(0)
        }
        if let message { Probe.emit(line(message)) }
        exit(0)
    }
}
