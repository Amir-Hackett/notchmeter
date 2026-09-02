import Foundation

/// The hooks entry Notchmeter asks Claude Code for, and the one-click merge into settings.json that keeps every
/// hook already there. Nothing here runs unless the user presses the button in Settings.
enum HookSettings {
    static let events = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Notification", "Stop", "SessionEnd"]

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
    static func command(executable: String) -> String {
        "'\(executable.replacingOccurrences(of: "'", with: "'\\''"))' --hook"
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

    /// Backs the file up beside itself as `settings.json.bak-<timestamp>`, then writes the merged settings with
    /// the file's own permissions. Nothing is written when every event already has the hook.
    static func install(at url: URL = settingsURL, executable: String = executablePath, now: Date = Date()) throws -> Installed {
        let fm = FileManager.default
        var settings: [String: Any] = [:]
        let exists = fm.fileExists(atPath: url.path)
        if exists {
            guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                throw Failure.notAnObject(url)
            }
            settings = object
        }
        let merged = merge(into: settings, executable: executable)
        guard !merged.added.isEmpty else { return Installed(backup: nil, added: [], present: merged.present) }

        var backup: URL?
        if exists {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let target = URL(fileURLWithPath: url.path + ".bak-" + formatter.string(from: now))
            try fm.copyItem(at: url, to: target)
            backup = target
        }
        let permissions = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions]
        let data = try JSONSerialization.data(withJSONObject: merged.settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        if let permissions {
            try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
        return Installed(backup: backup, added: merged.added, present: merged.present)
    }
}
