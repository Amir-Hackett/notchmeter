import Foundation
import os

/// `notchmeter [tool] [--force] [--json]`: the same report the panel shows, from the running app's cache rather than
/// a fresh read of every vendor. The cache is the local API when it is on, else the report file the app writes
/// beside its drain log while it runs; a live probe (one request per signed-in tool and a transcript scan) happens
/// only with `--force` or when the app is not running. "Install command line tool…" in Settings symlinks this
/// executable to ~/.local/bin/notchmeter (or /usr/local/bin when writable), so an update carries it along.
enum CommandLineTool {
    static let linkName = "notchmeter"
    /// A report older than this counts as the app not running.
    static let reportFreshFor: TimeInterval = 15 * 60

    enum Source: String {
        case localAPI = "local API"
        case reportFile = "report file"
        case probe = "live probe"
    }

    static func isInvokedAsTool(arguments: [String]) -> Bool {
        arguments.contains("--cli") || URL(fileURLWithPath: arguments[0]).lastPathComponent == linkName
    }

    /// The cached report and where it came from, or nil when the app is not running (or `force`).
    static func cachedReport(force: Bool, reportFile: URL = Paths.reportFile, now: Date = Date()) -> (data: Data, source: Source)? {
        guard !force else { return nil }
        if let data = LocalAPIClient.get("/v1/limits") { return (data, .localAPI) }
        guard let data = try? Data(contentsOf: reportFile), Self.isFresh(data, now: now) else { return nil }
        return (data, .reportFile)
    }

    /// The report file is the running app's when its `generatedAt` is recent and the `pid` it names is alive.
    static func isFresh(_ data: Data, now: Date, alive: (Int32) -> Bool = { kill($0, 0) == 0 }) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let generated = (root["generatedAt"] as? String).flatMap(DateParsing.iso8601), now.timeIntervalSince(generated) < reportFreshFor
        else { return false }
        if let pid = JSON.number(root["pid"]).map({ Int32($0) }) { return alive(pid) }
        return true
    }

    /// The tool named on the command line, when one is.
    static func tool(in arguments: [String]) -> ToolID? {
        arguments.dropFirst().lazy.filter { !$0.hasPrefix("-") }.compactMap { ToolID(rawValue: $0.lowercased()) }.first
    }

    static func run(arguments: [String]) -> Never {
        if arguments.contains("--help") || arguments.contains("-h") {
            Probe.emit("usage: notchmeter [claude|codex|cursor|antigravity|copilot] [--force] [--json]")
            Probe.emit("  reads the running app's cached report; --force reads every vendor afresh")
            Probe.emit("  exit codes: 0 fine, 10 near a limit, 11 limit hit, 20 nothing used, 30 no data")
            exit(0)
        }
        let json = arguments.contains("--json")
        let force = arguments.contains("--force")
        let tool = tool(in: arguments)
        if let (data, source) = cachedReport(force: force) {
            let report = Self.parsed(data, tool: tool)
            if json {
                FileHandle.standardOutput.write(report.data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else {
                Probe.emit("\(AppInfo.name) (from the app's \(source.rawValue))")
                Probe.emit(report.text)
            }
            exit(report.exitCode)
        }
        Task.detached {
            let report = await Probe.gather()
            let limited = tool.map { report.limited(to: $0) } ?? report
            if json {
                FileHandle.standardOutput.write(limited.json)
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else {
                Probe.emit("\(AppInfo.name) (live probe; the app is not running or --force was given)")
                Probe.emit(Probe.describe(limited))
            }
            exit(limited.exitCode.rawValue)
        }
        RunLoop.main.run()
        exit(0)
    }

    /// A cached report, optionally narrowed to one tool, with its text rendering and exit code.
    static func parsed(_ data: Data, tool: ToolID?) -> (data: Data, text: String, exitCode: Int32) {
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (data, String(decoding: data, as: UTF8.self), 30) }
        if let tool, let tools = root["tools"] as? [[String: Any]] {
            root["tools"] = tools.filter { $0["tool"] as? String == tool.rawValue }
            root["advice"] = (root["advice"] as? [[String: Any]])?.filter { $0["tool"] as? String == tool.rawValue } ?? []
            if tool != .claude { root["cost"] = nil }
        }
        let encoded = (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])) ?? data
        return (encoded, describe(root), Int32(JSON.number(root["exitCode"]) ?? 30))
    }

    static func describe(_ root: [String: Any]) -> String {
        var lines: [String] = []
        for tool in root["tools"] as? [[String: Any]] ?? [] {
            let name = tool["name"] as? String ?? "?"
            let status = tool["status"] as? String ?? "?"
            let plan = (tool["plan"] as? String).map { " (\($0))" } ?? ""
            var line = "\(name)\(plan): \(status)"
            if let problem = tool["problem"] as? String { line += " · \(problem)" }
            lines.append(line)
            for window in tool["windows"] as? [[String: Any]] ?? [] {
                let label = window["label"] as? String ?? window["id"] as? String ?? "?"
                if let used = JSON.number(window["usedFraction"]) {
                    var part = "  \(label): \(Int((used * 100).rounded()))%"
                    if let pace = window["pace"] as? String { part += " (\(pace))" }
                    if let source = window["source"] as? String, source != WindowSource.vendorEndpoint.rawValue { part += " [\(source)]" }
                    lines.append(part)
                } else {
                    lines.append("  \(label): no limit published")
                }
            }
        }
        if let cost = root["cost"] as? [String: Any], let today = JSON.number(cost["today"]) {
            lines.append("cost: today \(Money.dollars(today)) 30d \(Money.dollars(JSON.number(cost["last30Days"]) ?? 0))")
        }
        for advice in root["advice"] as? [[String: Any]] ?? [] {
            if let text = advice["text"] as? String { lines.append("advice: \(text)") }
        }
        if let code = JSON.number(root["exitCode"]) { lines.append("exit code \(Int(code))") }
        return lines.joined(separator: "\n")
    }

    // MARK: - Installing the link

    /// ~/.local/bin when it exists or can be made, else /usr/local/bin when writable; nil when neither.
    static func linkDirectory(home: URL = Paths.home, fm: FileManager = .default) -> URL? {
        let local = home.appendingPathComponent(".local/bin")
        if fm.isWritableFile(atPath: local.path) || (try? fm.createDirectory(at: local, withIntermediateDirectories: true)) != nil { return local }
        let usr = URL(fileURLWithPath: "/usr/local/bin")
        return fm.isWritableFile(atPath: usr.path) ? usr : nil
    }

    /// Replaces any link of that name with one to `executable`; returns the link's path.
    @discardableResult
    static func install(executable: String, directory: URL? = linkDirectory()) throws -> URL {
        guard let directory else { throw CocoaError(.fileWriteNoPermission) }
        let link = directory.appendingPathComponent(linkName)
        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil || fm.fileExists(atPath: link.path) {
            try fm.removeItem(at: link)
        }
        try fm.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: executable))
        return link
    }

    /// Where the link points now, when one exists in either directory.
    static func installedLink(home: URL = Paths.home) -> (link: URL, destination: String)? {
        for directory in [home.appendingPathComponent(".local/bin"), URL(fileURLWithPath: "/usr/local/bin")] {
            let link = directory.appendingPathComponent(linkName)
            if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) { return (link, destination) }
        }
        return nil
    }

    /// True when the directory is on the shell's PATH (the login shell's, via launchd, when the app was launched from the Finder).
    static func isOnPath(_ directory: URL, path: String? = ProcessEnvironment.value("PATH")) -> Bool {
        (path ?? "").split(separator: ":").map { ($0 as NSString).expandingTildeInPath }.contains(directory.path)
    }
}

/// A blocking GET against the loopback API, for the command-line tool and the status line: a quarter-second
/// connect budget, so an app without the API on costs nothing noticeable.
enum LocalAPIClient {
    static func get(_ path: String, port: UInt16 = LocalAPI.port, timeout: TimeInterval = 0.25) -> Data? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("127.0.0.1:\(port)", forHTTPHeaderField: "Host")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 4
        let session = URLSession(configuration: configuration)
        let done = DispatchSemaphore(value: 0)
        let box = OSAllocatedUnfairLock<Data?>(initialState: nil)
        let task = session.dataTask(with: request) { data, response, _ in
            if let data, (response as? HTTPURLResponse)?.statusCode == 200 { box.withLock { $0 = data } }
            done.signal()
        }
        task.resume()
        _ = done.wait(timeout: .now() + timeout * 4)
        return box.withLock { $0 }
    }
}
