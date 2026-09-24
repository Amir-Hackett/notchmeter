import Foundation

/// OpenCode's integration: not an entry in a JSON hooks file but a plugin of Notchmeter's own, one JavaScript file
/// in OpenCode's global plugin folder (`~/.config/opencode/plugins/notchmeter.js`), which OpenCode loads when it
/// starts (opencode.ai/docs/plugins, read 2026-09-24: "Files in these directories are automatically loaded at
/// startup", and a plain `.js` file needs no package.json). The plugin subscribes to OpenCode's own bus events and
/// runs `Notchmeter --hook --tool opencode` for the handful the notch acts on, piping a small JSON object to it,
/// exactly as every other assistant's hook command does; Hook+OpenCode.swift reads that object.
///
/// It is written the way every other hook is: only from Settings › Integrations (Add, after the confirming sheet,
/// or Repair) or the launch repair of an entry pointing at an old copy of the app, and a file already at the path is
/// copied to `notchmeter.js.bak-<date>` first — a name OpenCode does not load, since it is not a `.js` file. Nothing
/// else in OpenCode's configuration is touched, so removing the integration is deleting the file. Its status is
/// judged the way HookSettings judges a command: on the executable it names and the version line it carries, not on
/// being byte for byte what `source` writes, so a file the user edited is theirs to keep until a new version of the
/// plugin is released.
enum OpenCodePlugin {
    /// Raised when the plugin's source changes in a way an installed copy should be upgraded for; the launch repair
    /// and Repair rewrite a copy that carries an older one.
    static let version = 1
    static let versionMarker = "notchmeter-plugin-version:"
    static let fileName = "notchmeter.js"

    /// The events the plugin forwards, as OpenCode names them (Hook+OpenCode.swift maps each one).
    static let events = ["session.created", "chat.message", "session.status", "session.idle", "session.error", "session.deleted",
                         "permission.asked", "permission.replied"]

    static func fileURL(environment: [String: String] = ProcessInfo.processInfo.environment, home: URL = Paths.home) -> URL {
        OpenCodePaths.configDirectory(environment: environment, home: home).appendingPathComponent("plugins/\(fileName)")
    }

    /// The whole module. The executable is written as a JSON string literal, which JavaScript reads as it is, so a
    /// path with a quote or a backslash in it cannot break out of the string.
    static func source(executable: String = HookSettings.executablePath) -> String {
        let path = (try? JSONSerialization.data(withJSONObject: executable, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\(executable)\""
        return """
        // Notchmeter plugin for OpenCode (\(versionMarker) \(version)).
        // Written by Notchmeter's Settings › Integrations, which backed up any file it replaced here. It tells the
        // Notchmeter app on this Mac when a session starts, a prompt is sent, a turn ends or fails, a subagent runs,
        // and OpenCode stops to ask your permission, by running the app's own hook command with a small JSON object.
        // It sends nothing anywhere else, and never the prompt beyond its first 500 characters, which the app cuts to
        // one line and keeps only while "Show what a session is working on" is on. Delete this file to remove it.
        import { spawn } from "node:child_process"

        const NOTCHMETER = \(path)

        // A subagent's session, to the session the user is in; and whether each session was last reported busy.
        const parents = new Map()
        const state = new Map()

        function send(payload) {
          try {
            const child = spawn(NOTCHMETER, ["--hook", "--tool", "opencode"], { stdio: ["pipe", "ignore", "ignore"] })
            child.on("error", () => {})
            child.stdin.on("error", () => {})
            child.stdin.end(JSON.stringify(payload))
            child.unref()
          } catch {}
        }

        function firstText(parts) {
          for (const part of parts ?? []) {
            if (part?.type === "text" && typeof part.text === "string" && part.text.trim()) return part.text.slice(0, 500)
          }
          return undefined
        }

        export const NotchmeterPlugin = async ({ directory }) => {
          const report = (name, sessionID, extra = {}) => {
            if (typeof sessionID !== "string" || !sessionID) return
            const parent = parents.get(sessionID)
            send({ hook_event_name: name, session_id: parent ?? sessionID, agent_id: parent ? sessionID : undefined, cwd: directory, ...extra })
          }
          const busy = (name, sessionID, extra) => {
            if (state.get(sessionID) === "busy" && name !== "chat.message") return
            state.set(sessionID, "busy")
            report(name, sessionID, extra)
          }
          const idle = (sessionID) => {
            if (state.get(sessionID) === "idle") return
            state.set(sessionID, "idle")
            report("session.idle", sessionID)
          }
          return {
            "chat.message": async (input, output) => {
              if (parents.has(input?.sessionID)) return
              busy("chat.message", input?.sessionID, { prompt: firstText(output?.parts) })
            },
            event: async ({ event }) => {
              const p = event?.properties ?? {}
              switch (event?.type) {
                case "session.created": {
                  const id = p.sessionID ?? p.info?.id
                  if (p.info?.parentID) parents.set(id, p.info.parentID)
                  report("session.created", id)
                  break
                }
                case "session.status":
                  if (p.status?.type === "busy" && !parents.has(p.sessionID)) busy("session.status", p.sessionID, { status: "busy" })
                  else if (p.status?.type === "idle") idle(p.sessionID)
                  break
                case "session.idle":
                  idle(p.sessionID)
                  break
                case "session.error":
                  report("session.error", p.sessionID, { error: p.error?.name, status_code: p.error?.data?.statusCode })
                  break
                case "session.deleted": {
                  const id = p.sessionID ?? p.info?.id
                  report("session.deleted", id)
                  parents.delete(id)
                  state.delete(id)
                  break
                }
                case "permission.asked":
                case "permission.updated":
                  report("permission.asked", p.sessionID, { permission: p.permission ?? p.type })
                  break
                case "permission.replied":
                  report("permission.replied", p.sessionID)
                  break
              }
            },
          }
        }

        """
    }

    /// The executable an installed plugin names, read back from its `const NOTCHMETER = "…"` line.
    static func executable(in text: String) -> String? {
        guard let line = text.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("const NOTCHMETER = ") }),
              let start = line.range(of: "= ") else { return nil }
        let literal = line[start.upperBound...].trimmingCharacters(in: .whitespaces)
        return (try? JSONSerialization.jsonObject(with: Data(literal.utf8), options: .fragmentsAllowed)) as? String
    }

    /// The plugin version a file says it is, or nil for a file that is not Notchmeter's plugin at all.
    static func installedVersion(in text: String) -> Int? {
        guard let marker = text.range(of: versionMarker) else { return nil }
        let digits = text[marker.upperBound...].drop { $0 == " " }.prefix { $0.isNumber }
        return Int(digits)
    }

    /// Where the plugin stands: no file, or a file that is not ours (which Add replaces after its backup); ours but
    /// naming another executable; ours from an older version; or current.
    static func status(text: String?, executable: String) -> HookSettings.Status {
        guard let text, let installed = installedVersion(in: text) else { return .notInstalled }
        let path = self.executable(in: text) ?? ""
        if path != executable { return .stale(path: path) }
        return installed < version ? .partial(path: executable) : .installed(path: executable)
    }

    static func status(at url: URL? = nil, executable: String = HookSettings.executablePath) -> HookSettings.Status {
        status(text: try? String(contentsOf: url ?? fileURL(), encoding: .utf8), executable: executable)
    }

    /// Writes the plugin for this executable, after copying any file already at the path beside it. Nothing is
    /// written when the file is already the current plugin for this executable. The file takes the permissions of
    /// the one it replaces, or the folder's default.
    static func install(at url: URL? = nil, executable: String = HookSettings.executablePath, now: Date = Date()) throws -> HookSettings.Installed {
        let url = url ?? fileURL()
        let fm = FileManager.default
        let text = source(executable: executable)
        let existing = try? String(contentsOf: url, encoding: .utf8)
        if existing == text { return HookSettings.Installed(backup: nil, added: [], present: [fileName]) }
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
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
        if let permissions { try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
        return HookSettings.Installed(backup: backup, added: [fileName], present: [])
    }
}
