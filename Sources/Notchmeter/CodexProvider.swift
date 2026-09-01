import Foundation

/// Codex CLI writes a rate-limit snapshot into every session's rollout file each time the server reports one,
/// so the freshest numbers on disk are the usage. Nothing is fetched and the auth file is never opened.
actor CodexProvider: UsageProvider {
    nonisolated let tool: ToolID = .codex
    nonisolated let refreshInterval: TimeInterval = 60
    nonisolated let root: URL

    init(root: URL = Paths.home.appendingPathComponent(".codex")) {
        self.root = root
    }

    nonisolated func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: root.path)
    }

    func fetch() async throws -> UsageReading {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("auth.json").path) else {
            throw ProviderError.notSignedIn("Sign in to Codex to read your usage")
        }
        let rollouts = Self.recentRollouts(in: root.appendingPathComponent("sessions"), limit: 8)
        guard !rollouts.isEmpty else {
            throw ProviderError.nothingYet("No Codex sessions on this Mac yet. Run Codex once and its limits appear here")
        }

        var newest: (observedAt: Date, limits: [String: Any])?
        for url in rollouts {
            guard let found = Self.latestRateLimits(in: url) else { continue }
            if newest == nil || found.observedAt > newest!.observedAt { newest = found }
        }
        guard let newest else { throw ProviderError.nothingYet("Codex has not recorded a usage snapshot yet") }
        return try Self.reading(from: newest.limits, observedAt: newest.observedAt, now: Date())
    }

    /// Newest rollout files by modification date, wherever Codex nests them under sessions/.
    static func recentRollouts(in sessions: URL, limit: Int) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }
        var files: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            files.append((url, values?.contentModificationDate ?? .distantPast))
        }
        return files.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// The last rate_limits payload in a rollout, read from the tail first because rollouts grow large.
    static func latestRateLimits(in url: URL) -> (observedAt: Date, limits: [String: Any])? {
        let tailBytes = 2_000_000
        guard let tail = read(url, lastBytes: tailBytes) else { return nil }
        if let found = scan(tail, fileURL: url) { return found }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > tailBytes, let whole = try? Data(contentsOf: url) else { return nil }
        return scan(whole, fileURL: url)
    }

    private static func scan(_ data: Data, fileURL: URL) -> (observedAt: Date, limits: [String: Any])? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() where line.contains("\"rate_limits\"") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let payload = object["payload"] as? [String: Any]
            guard let limits = (payload?["rate_limits"] ?? object["rate_limits"]) as? [String: Any] else { continue }
            let stamp = (object["timestamp"] as? String).flatMap(DateParsing.iso8601)
                ?? (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                ?? Date()
            return (stamp, limits)
        }
        return nil
    }

    private static func read(_ url: URL, lastBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(lastBytes) ? size - UInt64(lastBytes) : 0
        try? handle.seek(toOffset: start)
        return try? handle.readToEnd()
    }

    static func reading(from limits: [String: Any], observedAt: Date, now: Date) throws -> UsageReading {
        var windows: [LimitWindow] = []
        for (key, fallbackLabel) in [("primary", "Current session"), ("secondary", "Weekly")] {
            guard let window = limits[key] as? [String: Any], let usedPercent = window["used_percent"] as? Double else { continue }
            var resetsAt: Date?
            if let epoch = window["resets_at"] as? Double {
                resetsAt = Date(timeIntervalSince1970: epoch)
            } else if let seconds = window["resets_in_seconds"] as? Double {
                resetsAt = observedAt.addingTimeInterval(seconds)
            }
            let minutes = (window["window_minutes"] as? Double).map(Int.init)
            var fraction = min(max(usedPercent / 100, 0), 1)
            var note: String?
            if let resetsAt, resetsAt < now {
                fraction = 0
                note = "reset since Codex last reported"
            }
            windows.append(LimitWindow(
                id: key,
                label: minutes.map(label(forMinutes:)) ?? fallbackLabel,
                usedFraction: fraction,
                resetsAt: resetsAt,
                note: note
            ))
        }
        guard !windows.isEmpty else { throw ProviderError.unavailable("Codex reported no usage windows") }
        let plan = (limits["plan_type"] as? String).map(Naming.plan)
        return UsageReading(tool: .codex, windows: windows, plan: plan, fetchedAt: now, observedAt: observedAt)
    }

    static func label(forMinutes minutes: Int) -> String {
        switch minutes {
        case ..<60: "\(minutes)-minute"
        case 60..<1440: minutes % 60 == 0 ? "\(minutes / 60)-hour" : "\(minutes)-minute"
        case 10080: "Weekly"
        default: "\(minutes / 1440)-day"
        }
    }
}
