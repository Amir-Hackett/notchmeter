import Foundation
import IOKit.ps

enum PowerSource {
    static func onBattery() -> Bool {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        guard let type = IOPSGetProvidingPowerSourceType(info)?.takeRetainedValue() as String? else { return false }
        return type == kIOPSBatteryPowerValue
    }

    static func lowPowerMode() -> Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// Calls `handler` on the main run loop each time the Mac moves between mains and battery. `onBattery()` is a
    /// snapshot, and for a long time the only thing taking one was the store's minute tick, which the polling
    /// policy parks while the display sleeps or the screen is locked. Those are exactly the states an unattended
    /// run sits in, so the charger came out and nothing noticed until somebody woke the display, and the awake
    /// assertion the store holds from that snapshot held the Mac out of idle sleep on battery against the user's
    /// own setting (and symmetrically let it sleep mid-run once plugged back in). IOKit's limited-power
    /// notification fires only on the mains/battery transition, not on every percent the battery gains or loses
    /// as `IOPSNotificationCreateRunLoopSource` does, so the handler runs a handful of times a day. The source is
    /// scheduled on the main run loop for the life of the process, like the workspace observers beside it, and the
    /// handler box is retained for the same span; nil means IOKit refused, which leaves the tick as the only reader.
    static func observeTransitions(_ handler: @escaping () -> Void) -> CFRunLoopSource? {
        let box = Unmanaged.passRetained(Handler(handler)).toOpaque()
        guard let source = IOPSCreateLimitedPowerNotification({ context in
            guard let context else { return }
            Unmanaged<Handler>.fromOpaque(context).takeUnretainedValue().run()
        }, box)?.takeRetainedValue() else {
            Unmanaged<Handler>.fromOpaque(box).release()
            return nil
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        return source
    }

    private final class Handler {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }
}

/// When each tool last touched its files, sampled with a few directory listings rather than a scan: Claude Code's
/// three most recently changed project folders (in every transcript root, Cowork's and the user's extra ones
/// included), Codex's rollouts for today and yesterday, the modification time of Cursor's state database, Gemini
/// CLI's login file and per-project folders, Copilot's config folder, and OpenCode's databases.
struct AgentActivity: Sendable {
    var claudeRoots: [URL] = ClaudeCostScanner.defaultRoots()
    var codexSessions: URL = Paths.home.appendingPathComponent(".codex/sessions")
    var cursorState: URL = Paths.home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    var geminiRoot: URL = Paths.home.appendingPathComponent(".gemini")
    var copilotRoot: URL = Paths.home.appendingPathComponent(".config/github-copilot")
    var opencodeData: URL = OpenCodePaths.dataDirectory()

    func sample(now: Date = Date()) -> [ToolID: Date] {
        var result: [ToolID: Date] = [:]
        result[.claude] = claudeRoots.compactMap { Self.newestClaude(projects: ClaudeCostScanner.transcriptFolder(of: $0)) }.max()
        result[.codex] = Self.newestCodex(sessions: codexSessions, now: now)
        result[.cursor] = Self.newestCursor(database: cursorState)
        result[.antigravity] = Self.newestGemini(root: geminiRoot)
        result[.copilot] = Self.newestCopilot(root: copilotRoot)
        result[.opencode] = Self.newestOpenCode(data: opencodeData)
        return result
    }

    /// OpenCode writes every turn to its database, so the database and its write-ahead log are its activity.
    static func newestOpenCode(data: URL) -> Date? {
        OpenCodePaths.databases(in: data).flatMap { database in
            ["", "-wal"].compactMap { modified(URL(fileURLWithPath: database.path + $0)) }
        }.max()
    }

    /// Gemini CLI rewrites its login file on every token refresh and keeps a folder per project under `tmp`;
    /// Antigravity's CLI keeps its conversations under `antigravity-cli`. Each folder is one listing, not a walk.
    static func newestGemini(root: URL) -> Date? {
        var candidates = [modified(root.appendingPathComponent("oauth_creds.json"))]
        for folder in ["tmp", "antigravity", "antigravity-cli/conversations"] {
            let url = root.appendingPathComponent(folder)
            guard let entries = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            candidates.append(contentsOf: entries.map(modified))
        }
        return candidates.compactMap { $0 }.max()
    }

    /// Copilot's plugin rewrites its token files on refresh; that is the only trace it leaves on disk.
    static func newestCopilot(root: URL) -> Date? {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return nil }
        return entries.compactMap(modified).max()
    }

    /// The newest entry inside the `folders` most recently changed project folders. A folder's own date moves
    /// when a session file is created in it, so an active session's folder is among the newest; the walk inside
    /// it is capped so a huge folder cannot turn the check into a scan.
    static func newestClaude(projects: URL, folders: Int = 3, fileLimit: Int = 3000) -> Date? {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey]
        guard let entries = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else {
            return nil
        }
        let recent = entries
            .compactMap { url -> (URL, Date)? in
                let values = try? url.resourceValues(forKeys: keys)
                guard values?.isDirectory == true, let modified = values?.contentModificationDate else { return nil }
                return (url, modified)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(folders)
        var newest = recent.map(\.1).max()
        var budget = fileLimit
        for (folder, _) in recent {
            guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator {
                guard budget > 0 else { return newest }
                budget -= 1
                if let modified = modified(url), newest.map({ modified > $0 }) ?? true { newest = modified }
            }
        }
        return newest
    }

    /// Codex files rollouts under `sessions/yyyy/MM/dd`; only today's and yesterday's folders are listed.
    static func newestCodex(sessions: URL, now: Date, calendar: Calendar = .current) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy/MM/dd"
        var newest: Date?
        for offset in 0...1 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let folder = sessions.appendingPathComponent(formatter.string(from: day))
            guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            for file in files {
                if let modified = modified(file), newest.map({ modified > $0 }) ?? true { newest = modified }
            }
        }
        return newest
    }

    static func newestCursor(database: URL) -> Date? {
        ["", "-wal", "-shm"].compactMap { modified(URL(fileURLWithPath: database.path + $0)) }.max()
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
