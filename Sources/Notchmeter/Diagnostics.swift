import AppKit
import OSLog

/// "Copy diagnostics": the last ten minutes of the app's own subsystem from the unified log, each tool's status
/// and problem, each hook's and the status line's state, the layout and the machine, scrubbed of the home directory and
/// put on the clipboard for a bug report. Never a token: the providers never log one, and readings appear as
/// labels and fractions.
enum Diagnostics {
    static let subsystem = "com.amirhackett.notchmeter"

    struct Facts {
        var version = AppInfo.versionWithBuild
        var macOS = ProcessInfo.processInfo.operatingSystemVersionString
        var edge = ""
        var display = ""
        var visibility = ""
        var screens: [String] = []
        var tools: [(name: String, status: String)] = []
        var hook = ""
        var statusline = ""
        var localAPI = false
        var debugLogging = false
    }

    /// The report as text, with the log lines last.
    static func report(_ facts: Facts, log lines: [String], now: Date = Date(), home: String = Paths.home.path) -> String {
        var out: [String] = []
        out.append("\(AppInfo.name) \(facts.version) diagnostics, \(Oracle.timestamp(now))")
        out.append("macOS \(facts.macOS); edge \(facts.edge); display \(facts.display); show \(facts.visibility)")
        for screen in facts.screens { out.append("screen \(screen)") }
        for tool in facts.tools { out.append("\(tool.name): \(tool.status)") }
        out.append("hook: \(facts.hook)")
        out.append("status line: \(facts.statusline)")
        out.append("local API: \(facts.localAPI ? "on" : "off"); debug logging: \(facts.debugLogging ? "on" : "off")")
        out.append("")
        out.append("unified log, last 10 minutes (\(lines.count) lines):")
        out.append(contentsOf: lines)
        let text = out.joined(separator: "\n")
        return (Oracle.scrub(text, home: home) as? String) ?? text
    }

    /// The app's own log lines from the last `minutes`, oldest first; empty when the store cannot be opened
    /// (a sandbox, or a very old macOS).
    static func recentLog(minutes: Int = 10, now: Date = Date()) -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return [] }
        let position = store.position(date: now.addingTimeInterval(-TimeInterval(minutes) * 60))
        let predicate = NSPredicate(format: "subsystem == %@", subsystem)
        guard let entries = try? store.getEntries(at: position, matching: predicate) else { return [] }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return entries.compactMap { entry -> String? in
            guard let logEntry = entry as? OSLogEntryLog else { return nil }
            return "\(formatter.string(from: logEntry.date)) [\(logEntry.category)] \(logEntry.composedMessage)"
        }
    }

    @MainActor
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Oracle.shared.emit("clipboard", ["kind": "diagnostics", "length": text.count])
    }
}
