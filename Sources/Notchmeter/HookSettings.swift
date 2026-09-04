import Foundation

/// The hooks entry Notchmeter asks each assistant for, the one-click merge into each assistant's file (HookVendor)
/// that keeps every hook already there, the status line entry beside Claude Code's, and the check that says
/// whether any of them points at the copy of Notchmeter that is running. Which file, which events, which flag and
/// which handler dictionary are the vendor's (HookVendor); the merge, repair and status rules below are the same
/// for all of them. This writes only on a Settings button or the launch repair, after a backup, and only JSON: a
/// file that is not strict JSON (Gemini CLI's settings.json may carry comments) is refused rather than flattened.
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

    /// Whether the hooks file carries the entry, and whether it names the executable that is running.
    enum Status: Equatable {
        case notInstalled
        case installed(path: String)
        /// Installed, but a command names another executable (the app moved, or a build/ copy installed it).
        case stale(path: String)
        /// Installed and naming this executable, but an event is missing or a command's flags are not the current
        /// ones: an older install that predates an event, or an entry still on an older flag (a Cursor entry on a
        /// plain `--hook`, a Copilot entry without `--event`).
        case partial(path: String)

        var text: String {
            switch self {
            case .notInstalled: L("Not installed")
            case .installed(let path): L("Installed · pointing at %@", Self.shorten(path))
            case .stale(let path): L("Installed but points at an old path: %@", Self.shorten(path))
            case .partial: L("Installed, but an entry is out of date: Repair updates it")
            }
        }

        /// Whether Repair (from Settings or at launch) has something to rewrite or add.
        var needsRepair: Bool {
            switch self {
            case .stale, .partial: true
            case .notInstalled, .installed: false
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
    static var settingsURL: URL { settingsURL(environment: ProcessInfo.processInfo.environment) }

    /// The same, against a given environment and home, so `HookVendor.claude.fileURL(environment:)` is testable.
    static func settingsURL(environment: [String: String], home: URL = Paths.home) -> URL {
        if let custom = environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom).appendingPathComponent("settings.json")
        }
        return home.appendingPathComponent(".claude/settings.json")
    }

    static var executablePath: String {
        Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
    }

    /// Claude Code runs the command through `sh -c` (Codex through `$SHELL -lc`, the others through a shell of
    /// their own), so the path is single-quoted, which sh, bash, zsh and fish all read alike. The flag is the
    /// vendor's for the event (HookVendor.flag(for:)): `--hook` for Claude Code, `--hook --tool codex` for Codex,
    /// `--hook --tool cursor` for Cursor, `--hook --tool antigravity` for Gemini CLI and
    /// `--hook --tool copilot --event <name>` for Copilot.
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

    /// A handler of ours: a command (Cursor's entries carry no `type`, so an absent one counts; a `prompt` entry is
    /// never ours) that names this app and its hook flag.
    static func isNotchmeterHook(_ handler: [String: Any]) -> Bool {
        guard (handler["type"] as? String ?? "command") == "command", let command = handler["command"] as? String else { return false }
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

    /// The exact text to paste into the vendor's file, in the shape that file wants, rendered from the same
    /// dictionaries the installer writes (HookVendor.handler(command:event:)) so the two can never disagree:
    /// Claude Code's, Codex's and Gemini CLI's nested groups, or Cursor's and Copilot's `"version": 1` and a bare
    /// handler per event. Cursor's carries no timeout (its default is an undocumented platform one and the command
    /// exits in under 50 ms), no failClosed (the command prints nothing, which failClosed would count as a
    /// failure), no loop_limit (no followup_message is ever emitted) and no matcher.
    static func snippet(vendor: HookVendor = .claude, executable: String = executablePath) -> String {
        let entries = vendor.events.map { event in
            let handler = render(handler: vendor.handler(command: command(executable: executable, flag: vendor.flag(for: event)), event: event))
            switch vendor.shape {
            case .nestedGroups:
                return """
                    "\(event)": [
                      { "hooks": [ \(handler) ] }
                    ]
                """
            case .flatCommands:
                return "    \"\(event)\": [ \(handler) ]"
            }
        }
        let rootKeys = vendor.shape.requiredRootKeys.sorted { $0.key < $1.key }.map { "  \"\($0.key)\": \(render(value: $0.value)),\n" }.joined()
        return "{\n" + rootKeys + "  \"hooks\": {\n" + entries.joined(separator: ",\n") + "\n  }\n}\n"
    }

    /// One handler on one line, its keys in a fixed order so the snippet reads the same for every vendor: `type`,
    /// `name`, `command`, `matcher`, `async`, `timeout`, `timeoutSec`, skipping the ones the vendor does not write.
    static func render(handler: [String: Any]) -> String {
        let fields = ["type", "name", "command", "matcher", "async", "timeout", "timeoutSec"].compactMap { key in
            handler[key].map { "\"\(key)\": \(render(value: $0))" }
        }
        return "{ " + fields.joined(separator: ", ") + " }"
    }

    private static func render(value: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\(value)\""
    }

    static func statuslineSnippet(executable: String = executablePath) -> String {
        let command = command(executable: executable, flag: "--statusline")
        let encoded = (try? JSONSerialization.data(withJSONObject: command, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\(command)\""
        return "{\n  \"statusLine\": { \"type\": \"command\", \"command\": \(encoded), \"padding\": 0 }\n}\n"
    }

    /// Appends a Notchmeter entry under each of the vendor's events that has none. Entries, matchers and hooks
    /// already present are kept as they are (so are a `prompt` entry, Cursor's `loop_limit` or `failClosed`,
    /// Codex's top-level `description`, Gemini CLI's `name` and `env`, and Copilot's `bash` or `exec` entries,
    /// which carry no `command` and so are never ours); an event whose value is not an array is left alone. A
    /// root key the file must carry (Cursor's and Copilot's `version`) is added only when absent, so a file that
    /// says version 2 keeps saying so. Idempotent.
    static func merge(into settings: [String: Any], vendor: HookVendor = .claude, executable: String) -> (settings: [String: Any], added: [String], present: [String]) {
        var result = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var added: [String] = []
        var present: [String] = []
        for event in vendor.events {
            if hooks[event] != nil, !(hooks[event] is [Any]) {
                present.append(event)
                continue
            }
            var elements = hooks[event] as? [Any] ?? []
            let installed = elements.contains { element in
                guard let element = element as? [String: Any] else { return false }
                return vendor.shape.handlers(in: element).contains(where: isNotchmeterHook)
            }
            if installed {
                present.append(event)
            } else {
                let expected = command(executable: executable, flag: vendor.flag(for: event))
                elements.append(vendor.shape.entry(handler: vendor.handler(command: expected, event: event)))
                hooks[event] = elements
                added.append(event)
            }
        }
        result["hooks"] = hooks
        for (key, value) in vendor.shape.requiredRootKeys where result[key] == nil {
            result[key] = value
        }
        return (result, added, present)
    }

    /// Rewrites every Notchmeter handler in the file, under any event, to the vendor's current command for the given
    /// executable and that event, then adds the events that lack one; every other hook is untouched, and so is
    /// every other key of a handler of ours (`async`, `timeout`, `timeoutSec`, `name`, `matcher` stay as they
    /// are). This is what re-points a moved app, what turns a Cursor entry still on a plain `--hook` into
    /// `--hook --tool cursor`, and what gives a Copilot entry lacking `--event`, or carrying another event's, its
    /// own. Returns the events whose command changed, in the vendor's order.
    static func repair(_ settings: [String: Any], vendor: HookVendor = .claude, executable: String) -> (settings: [String: Any], repaired: [String], added: [String]) {
        var repaired: [String] = []
        var result = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, value) in hooks {
            guard var elements = value as? [[String: Any]] else { continue }
            let expected = command(executable: executable, flag: vendor.flag(for: event))
            var changed = false
            for index in elements.indices {
                var handlers = vendor.shape.handlers(in: elements[index])
                var touched = false
                for position in handlers.indices where isNotchmeterHook(handlers[position]) && handlers[position]["command"] as? String != expected {
                    handlers[position]["command"] = expected
                    touched = true
                }
                if touched {
                    elements[index] = vendor.shape.settingHandlers(handlers, in: elements[index])
                    changed = true
                }
            }
            if changed {
                hooks[event] = elements
                repaired.append(event)
            }
        }
        result["hooks"] = hooks
        let merged = merge(into: result, vendor: vendor, executable: executable)
        let order = vendor.events
        let ordered = repaired.sorted { (order.firstIndex(of: $0) ?? order.count, $0) < (order.firstIndex(of: $1) ?? order.count, $1) }
        return (merged.settings, ordered, merged.added)
    }

    /// Where the hook stands: absent; naming another executable (stale); installed for every event with the
    /// vendor's flag; or naming this executable but missing an event or carrying older flags (partial).
    ///
    /// A command is judged on its path and its flag, not on being byte for byte what `snippet` writes: an entry
    /// the user wrote by hand (an unquoted path, a redirect after the flag) that names this executable and carries
    /// the vendor's flag is installed and is theirs to keep. This matters because `.partial` is what the launch
    /// repair rewrites, and a Claude Code entry that was `.installed` before Cursor's round must not turn into
    /// one the app rewrites at every launch. For Claude Code the flag is `--hook`, which `isNotchmeterHook`
    /// already demands, so its rule is what it has always been; for the others the flag names the tool, and for
    /// Copilot the event too, so the plain `--hook` an earlier install wrote, or a Copilot entry without its
    /// `--event` (which the hook command could not read, its payload naming no event), is what reads as out of date.
    static func status(settings: [String: Any], vendor: HookVendor = .claude, executable: String) -> Status {
        guard let hooks = settings["hooks"] as? [String: Any] else { return .notInstalled }
        var paths: [String] = []
        var commands: [(event: String, command: String)] = []
        var covered = 0
        for event in vendor.events {
            guard let elements = hooks[event] as? [[String: Any]] else { continue }
            let handlers = elements.flatMap(vendor.shape.handlers(in:)).filter(isNotchmeterHook)
            if !handlers.isEmpty { covered += 1 }
            let found = handlers.compactMap { $0["command"] as? String }
            commands.append(contentsOf: found.map { (event, $0) })
            paths.append(contentsOf: found.compactMap(self.executable(in:)))
        }
        guard covered > 0 else { return .notInstalled }
        if let other = paths.first(where: { $0 != executable }) { return .stale(path: other) }
        if covered == vendor.events.count, commands.allSatisfy({ $0.command.contains(vendor.flag(for: $0.event)) }) { return .installed(path: executable) }
        return .partial(path: executable)
    }

    static func statuslineStatus(settings: [String: Any], executable: String) -> Status {
        guard let entry = settings["statusLine"] as? [String: Any], let command = entry["command"] as? String, isNotchmeterStatusline(command) else {
            return .notInstalled
        }
        let path = self.executable(in: command) ?? command
        return path == executable ? .installed(path: path) : .stale(path: path)
    }

    /// The file as a JSON object; an absent file is empty. A file that is not strict JSON — a Gemini CLI
    /// settings.json with comments in it, say — is refused the same way as one whose root is not an object, so it
    /// is never parsed loosely and written back flattened: the row reads not installed and Add shows the error,
    /// and the row help says to paste the snippet instead.
    static func readSettings(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure.notAnObject(url)
        }
        return object
    }

    /// The vendor's file on disk, or another at `url` (tests and `--smoke`).
    static func status(vendor: HookVendor = .claude, at url: URL? = nil, executable: String = executablePath) -> Status {
        ((try? readSettings(at: url ?? vendor.fileURL)).map { status(settings: $0, vendor: vendor, executable: executable) }) ?? .notInstalled
    }

    static func statuslineStatus(at url: URL = settingsURL, executable: String = executablePath) -> Status {
        ((try? readSettings(at: url)).map { statuslineStatus(settings: $0, executable: executable) }) ?? .notInstalled
    }

    /// Backs the file up beside itself as `<name>.bak-<timestamp>`, then writes the merged settings with the
    /// file's own permissions. Nothing is written when every event already has the hook.
    static func install(vendor: HookVendor = .claude, at url: URL? = nil, executable: String = executablePath, now: Date = Date()) throws -> Installed {
        let url = url ?? vendor.fileURL
        let settings = try readSettings(at: url)
        let merged = merge(into: settings, vendor: vendor, executable: executable)
        guard !merged.added.isEmpty else { return Installed(backup: nil, added: [], present: merged.present) }
        let backup = try write(merged.settings, to: url, now: now)
        return Installed(backup: backup, added: merged.added, present: merged.present)
    }

    /// Points every Notchmeter entry at this executable with the vendor's current flags, adding any event that
    /// lacks one, after a backup.
    static func repairInstall(vendor: HookVendor = .claude, at url: URL? = nil, executable: String = executablePath, now: Date = Date()) throws -> Installed {
        let url = url ?? vendor.fileURL
        let settings = try readSettings(at: url)
        let result = repair(settings, vendor: vendor, executable: executable)
        guard !result.repaired.isEmpty || !result.added.isEmpty else { return Installed(backup: nil, added: [], present: vendor.events) }
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
