import Foundation

/// The hooks entry Notchmeter asks Claude Code for, the one-click merge into settings.json that keeps every hook
/// already there, the status line entry beside it, and the check that says whether either points at the copy of
/// Notchmeter that is running. Nothing here writes unless the user presses a button in Settings.
enum HookSettings {
    /// SubagentStart, SubagentStop and StopFailure joined in round 2; Repair adds them to an older install.
    static let events = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Notification", "Stop", "StopFailure", "SubagentStart", "SubagentStop", "SessionEnd"]

    struct Installed: Equatable {
        let backup: URL?
        let added: [String]
        let present: [String]

        var summary: String {
            var parts: [String] = []
            if !added.isEmpty { parts.append(L("Added %@", added.joined(separator: ", "))) }
            if !present.isEmpty {
                let list = present.joined(separator: ", ")
                parts.append(added.isEmpty ? L("Already present for %@", list) : L("already present for %@", list))
            }
            if let backup { parts.append(L("backup at %@", backup.lastPathComponent)) }
            return parts.joined(separator: "; ") + "."
        }
    }

    /// Whether settings.json carries the entry, and whether it names the executable that is running.
    enum Status: Equatable {
        case notInstalled
        case installed(path: String)
        /// Installed, but the command names another path (the app moved, or was installed after a build/ run).
        case stale(path: String)

        var text: String {
            switch self {
            case .notInstalled: L("Not installed")
            case .installed(let path): L("Installed · pointing at %@", Self.shorten(path))
            case .stale(let path): L("Installed but points at an old path: %@", Self.shorten(path))
            }
        }

        static func shorten(_ path: String) -> String {
            let app = path.range(of: ".app/Contents/MacOS/").map { String(path[..<$0.lowerBound]) + ".app" } ?? path
            return app.replacingOccurrences(of: Paths.home.path, with: "~")
        }
    }

    enum Failure: LocalizedError {
        case notAnObject(URL)

        var errorDescription: String? {
            switch self {
            case .notAnObject(let url): L("%@ is not a JSON object, so it was left untouched", url.path)
            }
        }
    }

    /// Claude Code's user settings, honouring CLAUDE_CONFIG_DIR the way Claude Code does.
    static var settingsURL: URL {
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom).appendingPathComponent("settings.json")
        }
        return Paths.home.appendingPathComponent(".claude/settings.json")
    }

    static var executablePath: String {
        Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
    }

    /// Claude Code runs the command through `sh -c`, so the path is single-quoted.
    static func command(executable: String, flag: String = "--hook") -> String {
        "\(quote(executable)) \(flag)"
    }

    static func quote(_ path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func handler(command: String) -> [String: Any] {
        ["type": "command", "command": command, "async": true, "timeout": 5]
    }

    static func group(command: String) -> [String: Any] {
        ["hooks": [handler(command: command)]]
    }

    static func isNotchmeterHook(_ handler: [String: Any]) -> Bool {
        guard handler["type"] as? String == "command", let command = handler["command"] as? String else { return false }
        return command.contains("--hook") && command.lowercased().contains("notchmeter")
    }

    static func isNotchmeterStatusline(_ command: String) -> Bool {
        command.contains("--statusline") && command.lowercased().contains("notchmeter")
    }

    /// The executable a Notchmeter command names: the single-quoted path before the flag.
    static func executable(in command: String) -> String? {
        guard command.hasPrefix("'"), let end = command.dropFirst().range(of: "' --") else { return nil }
        return String(command[command.index(after: command.startIndex)..<end.lowerBound]).replacingOccurrences(of: "'\\''", with: "'")
    }

    /// The exact text to paste into settings.json.
    static func snippet(executable: String = executablePath) -> String {
        let command = command(executable: executable)
        let encoded = (try? JSONSerialization.data(withJSONObject: command, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\(command)\""
        let entries = events.map { event in
            """
                "\(event)": [
                  { "hooks": [ { "type": "command", "command": \(encoded), "async": true, "timeout": 5 } ] }
                ]
            """
        }
        return "{\n  \"hooks\": {\n" + entries.joined(separator: ",\n") + "\n  }\n}\n"
    }

    static func statuslineSnippet(executable: String = executablePath) -> String {
        let command = command(executable: executable, flag: "--statusline")
        let encoded = (try? JSONSerialization.data(withJSONObject: command, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\(command)\""
        return "{\n  \"statusLine\": { \"type\": \"command\", \"command\": \(encoded), \"padding\": 0 }\n}\n"
    }

    /// Appends a Notchmeter group under each event that has none. Groups, matchers and hooks already present are
    /// kept as they are; an event whose entry is not an array is left alone.
    static func merge(into settings: [String: Any], executable: String) -> (settings: [String: Any], added: [String], present: [String]) {
        var result = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var added: [String] = []
        var present: [String] = []
        let command = command(executable: executable)
        for event in events {
            if hooks[event] != nil, !(hooks[event] is [Any]) {
                present.append(event)
                continue
            }
            var groups = hooks[event] as? [Any] ?? []
            let installed = groups.contains { group in
                guard let group = group as? [String: Any], let handlers = group["hooks"] as? [Any] else { return false }
                return handlers.contains { ($0 as? [String: Any]).map(isNotchmeterHook) ?? false }
            }
            if installed {
                present.append(event)
            } else {
                groups.append(self.group(command: command))
                hooks[event] = groups
                added.append(event)
            }
        }
        result["hooks"] = hooks
        return (result, added, present)
    }

    /// Rewrites every Notchmeter handler to the given executable and adds the events that lack one; every other
    /// hook is untouched. Returns the events whose command changed.
    static func repair(_ settings: [String: Any], executable: String) -> (settings: [String: Any], repaired: [String], added: [String]) {
        var repaired: [String] = []
        var result = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        let command = command(executable: executable)
        for (event, value) in hooks {
            guard var groups = value as? [[String: Any]] else { continue }
            var changed = false
            for index in groups.indices {
                guard var handlers = groups[index]["hooks"] as? [[String: Any]] else { continue }
                for position in handlers.indices where isNotchmeterHook(handlers[position]) && handlers[position]["command"] as? String != command {
                    handlers[position]["command"] = command
                    changed = true
                }
                groups[index]["hooks"] = handlers
            }
            if changed {
                hooks[event] = groups
                repaired.append(event)
            }
        }
        result["hooks"] = hooks
        let merged = merge(into: result, executable: executable)
        let ordered = repaired.sorted { (events.firstIndex(of: $0) ?? events.count, $0) < (events.firstIndex(of: $1) ?? events.count, $1) }
        return (merged.settings, ordered, merged.added)
    }

    /// Where the hook stands: installed for every event and naming this executable, naming another, or absent.
    static func status(settings: [String: Any], executable: String) -> Status {
        guard let hooks = settings["hooks"] as? [String: Any] else { return .notInstalled }
        var paths: [String] = []
        var covered = 0
        for event in events {
            guard let groups = hooks[event] as? [[String: Any]] else { continue }
            let handlers = groups.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.filter(isNotchmeterHook)
            if !handlers.isEmpty { covered += 1 }
            paths.append(contentsOf: handlers.compactMap { ($0["command"] as? String).flatMap(self.executable(in:)) })
        }
        guard covered > 0 else { return .notInstalled }
        if covered == events.count, paths.allSatisfy({ $0 == executable }) { return .installed(path: executable) }
        return .stale(path: paths.first(where: { $0 != executable }) ?? executable)
    }

    static func statuslineStatus(settings: [String: Any], executable: String) -> Status {
        guard let entry = settings["statusLine"] as? [String: Any], let command = entry["command"] as? String, isNotchmeterStatusline(command) else {
            return .notInstalled
        }
        let path = self.executable(in: command) ?? command
        return path == executable ? .installed(path: path) : .stale(path: path)
    }

    static func readSettings(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw Failure.notAnObject(url)
        }
        return object
    }

    static func status(at url: URL = settingsURL, executable: String = executablePath) -> Status {
        ((try? readSettings(at: url)).map { status(settings: $0, executable: executable) }) ?? .notInstalled
    }

    static func statuslineStatus(at url: URL = settingsURL, executable: String = executablePath) -> Status {
        ((try? readSettings(at: url)).map { statuslineStatus(settings: $0, executable: executable) }) ?? .notInstalled
    }

    /// Backs the file up beside itself as `settings.json.bak-<timestamp>`, then writes the merged settings with
    /// the file's own permissions. Nothing is written when every event already has the hook.
    static func install(at url: URL = settingsURL, executable: String = executablePath, now: Date = Date()) throws -> Installed {
        let settings = try readSettings(at: url)
        let merged = merge(into: settings, executable: executable)
        guard !merged.added.isEmpty else { return Installed(backup: nil, added: [], present: merged.present) }
        let backup = try write(merged.settings, to: url, now: now)
        return Installed(backup: backup, added: merged.added, present: merged.present)
    }

    /// Points every Notchmeter entry at this executable, adding any event that lacks one, after a backup.
    static func repairInstall(at url: URL = settingsURL, executable: String = executablePath, now: Date = Date()) throws -> Installed {
        let settings = try readSettings(at: url)
        let result = repair(settings, executable: executable)
        guard !result.repaired.isEmpty || !result.added.isEmpty else { return Installed(backup: nil, added: [], present: events) }
        let backup = try write(result.settings, to: url, now: now)
        return Installed(backup: backup, added: result.added + result.repaired, present: [])
    }

    struct StatuslineInstalled: Equatable {
        let backup: URL?
        /// The command that was there before, now chained after Notchmeter's with `--then`.
        let previous: String?
    }

    /// Sets `statusLine` to Notchmeter's command. A status line already configured is kept: it is chained with
    /// `--then` so Claude Code's bar shows its output and Notchmeter still sees the JSON.
    static func installStatusline(at url: URL = settingsURL, executable: String = executablePath, now: Date = Date()) throws -> StatuslineInstalled {
        var settings = try readSettings(at: url)
        let existing = (settings["statusLine"] as? [String: Any])?["command"] as? String
        let previous = existing.flatMap { isNotchmeterStatusline($0) ? previousCommand(in: $0) : $0 }
        var command = self.command(executable: executable, flag: "--statusline")
        if let previous, !previous.isEmpty { command += " --then \(quote(previous))" }
        if existing == command { return StatuslineInstalled(backup: nil, previous: previous) }
        var entry = settings["statusLine"] as? [String: Any] ?? ["padding": 0]
        entry["type"] = "command"
        entry["command"] = command
        settings["statusLine"] = entry
        let backup = try write(settings, to: url, now: now)
        return StatuslineInstalled(backup: backup, previous: previous)
    }

    /// The `--then '<command>'` argument of a Notchmeter status-line command, unquoted.
    static func previousCommand(in command: String) -> String? {
        guard let range = command.range(of: " --then '") else { return nil }
        var rest = String(command[range.upperBound...])
        guard rest.hasSuffix("'") else { return nil }
        rest.removeLast()
        return rest.replacingOccurrences(of: "'\\''", with: "'")
    }

    @discardableResult
    private static func write(_ settings: [String: Any], to url: URL, now: Date) throws -> URL? {
        let fm = FileManager.default
        var backup: URL?
        if fm.fileExists(atPath: url.path) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let target = URL(fileURLWithPath: url.path + ".bak-" + formatter.string(from: now))
            if !fm.fileExists(atPath: target.path) { try fm.copyItem(at: url, to: target) }
            backup = target
        }
        let permissions = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions]
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        if let permissions {
            try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
        return backup
    }
}
