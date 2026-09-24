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
    static func copy(_ text: String, kind: String = "diagnostics") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Oracle.shared.emit("clipboard", ["kind": kind, "length": text.count])
    }
}

/// The newest crash report macOS wrote for this app, shown under Settings › Advanced › Diagnostics with a copy and
/// a Show in Finder.
///
/// Local only, and on purpose: the app has no crash reporter and sends nothing anywhere. macOS already writes a
/// report to `~/Library/Logs/DiagnosticReports` when a process dies, and the only thing missing was a way to find
/// it without knowing that folder exists; a bug report that says "it crashed" is answered far faster with the
/// report pasted in. The folder is read when the Diagnostics disclosure opens, never at launch or at layout, and
/// off the main thread, since it holds every app's reports and can be slow to list on a cold disk.
enum CrashReports {
    struct Report: Equatable, Sendable {
        let url: URL
        let modified: Date
    }

    /// The most a copy reads. An `.ips` with a full thread dump runs to a few hundred kilobytes at most, and the
    /// part a reader needs (the exception, the crashed thread) sits at the top; a report the size of a runaway
    /// recursion's is cut here rather than put on the clipboard whole.
    static let readLimit = 256 * 1024

    static var folder: URL { Paths.home.appendingPathComponent("Library/Logs/DiagnosticReports") }

    /// Whether a file name is one of this app's reports: `Notchmeter-2026-09-24-101010.ips` from macOS 12 on,
    /// `Notchmeter_2026-09-24-101010_Mac.crash` before. A separator after the name is required, so another app
    /// whose name merely starts with this one's is not taken for it.
    static func isReport(_ name: String, app: String = AppInfo.name) -> Bool {
        guard name.hasPrefix(app), let separator = name.dropFirst(app.count).first, "-_.".contains(separator) else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return ext == "ips" || ext == "crash"
    }

    /// The newest of this app's reports among a folder's entries, by modification date; nil when there is none.
    /// The pure half of `newest(in:)`, so the choice is testable without a folder of real crashes.
    static func newest(_ entries: [Report], app: String = AppInfo.name) -> Report? {
        entries.filter { isReport($0.url.lastPathComponent, app: app) }.max { $0.modified < $1.modified }
    }

    /// The newest report in the folder or its `Retired` subfolder, or nil when there is none or neither can be
    /// listed. macOS moves a report into `Retired` within a day or so of writing it, so the top level alone was
    /// usually empty by the time anyone went looking. Blocking disk IO: call it off the main thread.
    static func newest(in folder: URL = folder) -> Report? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let urls = [folder, folder.appendingPathComponent("Retired")].flatMap { directory in
            (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        }
        let entries = urls.compactMap { url -> Report? in
            guard isReport(url.lastPathComponent), let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true, let modified = values.contentModificationDate else { return nil }
            return Report(url: url, modified: modified)
        }
        return newest(entries)
    }

    /// The report's first `limit` bytes as text, scrubbed of the home folder the way Copy diagnostics is, with a
    /// last line saying so when it was cut. The scrub runs before the cut, over enough extra bytes to hold a path
    /// in its longer escaped spelling, so a cut can never leave half a home folder behind for the scrub to miss.
    /// Nil when the file cannot be read. Blocking disk IO: call it off the main thread.
    static func text(of url: URL, limit: Int = readLimit, home: String = Paths.home.path) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let margin = home.utf8.count * 2
        guard let data = try? handle.read(upToCount: limit + margin + 1) else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        // An `.ips` body is JSON, which may write the path with escaped slashes; scrub that spelling too.
        if !home.isEmpty {
            text = text.replacingOccurrences(of: home, with: "~")
                .replacingOccurrences(of: home.replacingOccurrences(of: "/", with: "\\/"), with: "~")
        }
        let scrubbed = Data(text.utf8)
        guard scrubbed.count > limit || data.count > limit + margin else { return text }
        return String(decoding: scrubbed.prefix(limit), as: UTF8.self) + "\n[cut at \(limit / 1024) KB]"
    }
}
