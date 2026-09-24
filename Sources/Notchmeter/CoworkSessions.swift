import Foundation

/// Claude Cowork's tasks as sessions (0.9.0). Cowork runs inside the Claude desktop app and has no hook, so all the
/// Sessions card can know of a task is what the app writes for it, which it keeps per account and organisation
/// under `~/Library/Application Support/Claude/local-agent-mode-sessions/<account>/<organisation>/`:
///
/// - `local_<id>.json`, the task's own record: its title, the folders it was given, when it was made, whether it is
///   archived. The same file holds the full system prompt, the account's name and its email address, so it is
///   parsed in memory and only the keys `Metadata` names are kept; nothing else of it outlives the read.
/// - `local_<id>/audit.jsonl`, the task's Agent SDK log, one JSON line per event as it happens: the prompt (a
///   `user` line whose content is the user's words), the model's steps, the tool calls, a `permission_request` line
///   when the task asks the user something (a tool to allow, or an `AskUserQuestion`) and its `permission_response`,
///   and a `result` line when a turn ends, with the turn's own `duration_ms`. The cost scan already reads its
///   `usage` lines (ClaudeCostScanner); this reads only each line's type, its timestamp, a result's duration and
///   whether it failed, and a prompt's flags (`Turn`), and nothing of what anyone wrote.
///
/// What that proves, and what it does not, is the rule (docs/accuracy.md, *Claude Cowork's tasks*). A turn's end is
/// the log's own `result` line, so a finish is a fact the task wrote down, not an inference. That a turn is running
/// is inferred: the log has a turn open (a prompt with no `result` after it), is not stopped at a
/// `permission_request`, and was written in the last `busyWindow`. A turn that went quiet with no end line (the app
/// hung or was stopped mid-turn) or stopped at a request reads as idle, and is never claimed as finished. Nothing
/// here says a task is waiting for the user: the request line is very likely exactly that, but it has only been
/// read in logs after the fact and never watched while a dialog was up, and a hand on the ring has to be a wait
/// something said began (ToolSignal).
///
/// Every file is opened read-only, and only while the Claude app is running (`bundleID`); a task whose log has not
/// moved for `listedFor` is not read at all, so the dozens of old tasks a Mac accumulates cost one `stat` each.
enum CoworkSessions {
    /// Claude's desktop app, where Cowork runs: the watch reads nothing while it is not running.
    static let bundleID = "com.anthropic.claudefordesktop"
    /// The product's name, for a banner or an announcement; like the assistants' own names it is never translated.
    static let productName = "Claude Cowork"
    /// The row's chip, beside the assistants' short names.
    static let shortName = "Cowork"
    /// Where the Claude app keeps the tasks: the same root the cost scan reads Cowork's spend from.
    static var root: URL { ClaudeCostScanner.coworkRoot }
    /// A log written this recently, with a turn open in it, is a turn running. The log appears to write a model
    /// step once the step is complete, so a running turn still goes quiet while the model writes a long answer:
    /// measured on 2026-09-24 over the 38 task logs on the Mac this was written on (131 finished turns), leaving out
    /// the pauses at a `permission_request`, 141 gaps inside a turn were longer than 30 s, 20 longer than two
    /// minutes, 4 longer than three and one longer than four (six minutes, after a rate-limit event); most came
    /// after a status line or an answer's text. Thirty seconds, the figure a process-and-transcript watcher uses for
    /// Claude Code, dropped a running task to idle in most turns; four minutes keeps nearly every one working to its
    /// end line, at the price of a turn stopped with no end line reading as working for up to four minutes after.
    static let busyWindow: TimeInterval = 240
    /// A `permission_request` line the log has not answered for this long is the task stopped for the user; one
    /// answered faster than a poll (an "always" rule the app applies itself answers in well under a second) is not.
    static let askGrace: TimeInterval = 3
    /// A task whose log has not moved for this long is off the list, as an idle hook session is set aside after
    /// the same time (SessionTracker.idleAfter), and its files are not read again until it moves.
    static let listedFor: TimeInterval = SessionTracker.idleAfter
    /// A task's record is rewritten as it runs; it is read again at most this often, since what is kept of it (a
    /// title, a folder) seldom changes and the file is half a megabyte.
    static let recordSpacing: TimeInterval = 30
    /// How much of a log is read the first time a task is seen: enough for the current turn's prompt or the last
    /// turn's end in most logs, and the rest is read as it is appended.
    static let tailBytes = 256 * 1024
    /// How far back a first read widens when the tail holds neither a prompt nor an end (CoworkReader.readTail);
    /// and more appended than this between two polls starts the reader again from the tail, rather than read a
    /// burst of tool output it has no use for. Measured on 2026-09-24 over the 131 finished turns in the logs on the
    /// Mac this was written on: 56 wrote more than the 256 KB tail between their prompt and their end, 11 more than
    /// 2 MB, and one more than 8 MB (a 36 MB log that was one turn).
    static let catchUpLimit = 8 * 1024 * 1024
    /// A line longer than this is not parsed: it is a tool's output (a file read back, a screenshot), which says
    /// nothing about where a turn stands. A prompt, a model step and a result are all far shorter.
    static let lineLimit = 64 * 1024

    /// How often the watch reads while the Claude app is running: every five seconds on mains power, ten on
    /// battery or in Low Power Mode; fifteen while no task is on the list, since the Claude app is often open all
    /// day with Cowork unused and a new task's first turn may as well be noticed a few seconds late; and thirty
    /// while the screen is locked or the displays sleep, when nobody is looking but a turn's end still has to
    /// release the awake assertion (AwakeRule) it holds.
    static func pollInterval(onBattery: Bool, lowPower: Bool, unattended: Bool, listed: Bool) -> TimeInterval {
        if unattended { return 30 }
        if !listed { return 15 }
        return onBattery || lowPower ? 10 : 5
    }

    /// The tracker's key for a task: its own id with the product's name in front, as every assistant but Claude
    /// Code's is keyed (SessionTracker.key), so it can never share an entry with a Claude Code session.
    static func key(_ id: String) -> String { "cowork:\(id)" }

    // MARK: The task's record

    /// The keys kept from `local_<id>.json`, and nothing else of it.
    struct Metadata: Equatable, Sendable {
        /// The Claude app's own name for the task, one line (Hook.title(fromPrompt:)); it is made from the task's
        /// first message, so it is held and shown under the same setting as a prompt's first line.
        var title: String?
        /// The first folder the task was given (`userSelectedFolders`), whose name is the session's project. The
        /// record's `cwd` is the task's sandbox, which names nothing a reader would recognise.
        var folder: String?
        /// `lastActivityAt`, the stand-in for a log's modification time when a task has no log.
        var lastActivity: Date?
        var archived = false
    }

    static func metadata(from data: Data) -> Metadata? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func date(_ key: String) -> Date? {
            (object[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        }
        let folder = (object["userSelectedFolders"] as? [Any])?.lazy.compactMap { $0 as? String }.first { !$0.isEmpty }
        return Metadata(title: Hook.title(fromPrompt: object["title"]), folder: folder, lastActivity: date("lastActivityAt"),
                        archived: object["isArchived"] as? Bool ?? false)
    }

    // MARK: The task's log

    /// Where the log says the task's turns stand, read a line at a time in the order they were written.
    struct Turn: Equatable, Sendable {
        /// A turn's end, from its `result` line.
        struct End: Equatable, Sendable {
            /// The line's timestamp; nil for a line that carried none, which still ends the turn but cannot date a
            /// finish, so it is never announced as one.
            let at: Date?
            /// The line's own `duration_ms`, when it carried one.
            let duration: TimeInterval?
            /// The turn ended on an error (`is_error`, or a subtype other than `success`): an end, never a finish.
            let failed: Bool
        }

        /// When the newest turn began: its prompt's timestamp, or, for a turn whose prompt was not among the lines
        /// read, the first model step written after the turn before it ended (it began no later than that).
        var began: Date?
        /// The newest end read. Kept when the next turn begins, so a turn that ended and was followed by another
        /// between two reads is still seen to have ended.
        var end: End?
        /// A turn has begun since `end`, or no end has been read at all. A log read from the middle of a turn has
        /// neither a prompt nor an end in view, and is open: whether it is running is then the clock's to say.
        var open = true
        /// The last line read is a `permission_request`: the task has asked the user something (a tool to allow, or
        /// an `AskUserQuestion`) and nothing has been written since. In the logs read on 2026-09-24, 35 of 36
        /// requests were followed directly by their `permission_response`, and the 36th ended its log.
        var asking = false

        /// Reads one line. The type is told from the line's head, where every line the log writes puts it, so a
        /// line is parsed only when it may be a prompt, a result, or a step that reopens a turn.
        mutating func read(_ line: Data) {
            let head = line.prefix(64)
            asking = head.starts(with: Self.requestHead)
            if head.starts(with: Self.resultHead) {
                guard line.count <= lineLimit, let object = Self.object(line) else { return }
                let subtype = object["subtype"] as? String
                let failed = (object["is_error"] as? Bool ?? false) || (subtype.map { $0 != "success" } ?? false)
                end = End(at: Self.timestamp(object), duration: (object["duration_ms"] as? NSNumber).map { $0.doubleValue / 1000 }, failed: failed)
                open = false
            } else if head.starts(with: Self.userHead) {
                guard line.count <= lineLimit, line.range(of: Self.toolResultMark) == nil, let object = Self.object(line),
                      Self.isPrompt(object) else { return }
                began = Self.timestamp(object)
                open = true
            } else if !open, head.starts(with: Self.assistantHead) {
                guard line.count <= lineLimit, let object = Self.object(line) else { return }
                began = Self.timestamp(object)
                open = true
            }
        }

        /// Reads every whole line in `chunk`, with `partial` holding the bytes after its last newline for the next
        /// chunk. A partial line that outgrows the limit is dropped and the rest of it skipped: it is tool output.
        mutating func read(_ chunk: Data, partial: inout Data, skipping: inout Bool) {
            var start = chunk.startIndex
            while let newline = chunk[start...].firstIndex(of: 0x0A) {
                if skipping {
                    skipping = false
                } else if partial.isEmpty {
                    read(chunk[start..<newline])
                } else {
                    partial.append(chunk[start..<newline])
                    read(partial)
                    partial.removeAll(keepingCapacity: false)
                }
                start = chunk.index(after: newline)
            }
            guard !skipping else { return }
            partial.append(chunk[start...])
            if partial.count > CoworkSessions.lineLimit {
                // A line written after a request, so the request is no longer the last thing the log says.
                partial.removeAll(keepingCapacity: false)
                skipping = true
                asking = false
            }
        }

        static let resultHead = Data(#"{"type":"result""#.utf8)
        static let userHead = Data(#"{"type":"user""#.utf8)
        static let assistantHead = Data(#"{"type":"assistant""#.utf8)
        static let requestHead = Data(#"{"type":"system","subtype":"permission_request""#.utf8)
        /// A tool's result comes back as a `user` line; this key is in every one of them and in no prompt.
        static let toolResultMark = Data(#""tool_use_id""#.utf8)

        static func object(_ line: Data) -> [String: Any]? {
            try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        }

        /// `_audit_timestamp`, which every line the log writes carries, else the SDK's own `timestamp`.
        static func timestamp(_ object: [String: Any]) -> Date? {
            ((object["_audit_timestamp"] as? String) ?? (object["timestamp"] as? String)).flatMap(DateParsing.iso8601)
        }

        /// A prompt: the user's own words, not a turn replayed from earlier (`isReplay`), not something the app
        /// attached (`isSynthetic`), not a subagent's (`parent_tool_use_id`), and not a tool's result.
        static func isPrompt(_ object: [String: Any]) -> Bool {
            guard object["isReplay"] as? Bool != true, object["isSynthetic"] as? Bool != true else { return false }
            if let parent = object["parent_tool_use_id"], !(parent is NSNull) { return false }
            guard let message = object["message"] as? [String: Any] else { return false }
            if message["content"] is String { return true }
            guard let blocks = message["content"] as? [[String: Any]], !blocks.isEmpty else { return false }
            return !blocks.contains { $0["type"] as? String == "tool_result" }
        }
    }

    // MARK: What a read yields

    /// One task as the reader last saw it: the input to `SessionTracker.observeCowork`.
    struct Observation: Equatable, Sendable {
        /// `local_<uuid>`, the record's own file name.
        let id: String
        /// nil when the record has none, and always nil once the store has applied *Show what a session is working
        /// on* being off.
        var title: String?
        /// The folder's name (ProjectName), nil for a task given no folder.
        var project: String?
        /// The log's modification time (the record's `lastActivityAt` for a task with no log).
        var lastWrite: Date
        var turn: Turn
    }
}

/// The reader behind the watch: which tasks are live, and each one's record and log, read incrementally. An actor,
/// so the file work happens off the main actor and one poll at a time; it keeps, per task, how far into the log it
/// has read and what the lines so far said, so each poll reads only what was appended since the last.
actor CoworkReader {
    private struct Tracked {
        var record: CoworkSessions.Metadata?
        /// Whether `record` was parsed with titles allowed.
        var titles = true
        var project: String?
        var recordModified: Date?
        var recordReadAt: Date?
        var turn = CoworkSessions.Turn()
        /// Bytes of the log read so far; nil before the first read.
        var offset: UInt64?
        var partial = Data()
        var skipping = false
        /// What this poll makes of the task; nil for an archived one, which is remembered and not listed.
        var observation: CoworkSessions.Observation?
    }

    let root: URL
    private var tracked: [String: Tracked] = [:]

    init(root: URL = CoworkSessions.root) {
        self.root = root
    }

    /// Every task written to inside `CoworkSessions.listedFor`, and not archived, as it stands now. `titles` is
    /// *Show what a session is working on*: off, a task's title is dropped as its record is parsed and any title
    /// already held here goes, so nothing of it is kept even in the reader; on again, the records are read afresh.
    func poll(now: Date = Date(), titles: Bool = true) -> [CoworkSessions.Observation] {
        let fm = FileManager.default
        var observations: [CoworkSessions.Observation] = []
        var seen: Set<String> = []
        for account in Self.folders(in: root) {
            for organisation in Self.folders(in: account) {
                guard let names = try? fm.contentsOfDirectory(atPath: organisation.path) else { continue }
                for name in names where name.hasPrefix("local_") && name.hasSuffix(".json") {
                    let id = String(name.dropLast(".json".count))
                    let recordURL = organisation.appendingPathComponent(name)
                    let logURL = organisation.appendingPathComponent(id).appendingPathComponent("audit.jsonl")
                    guard observe(id: id, record: recordURL, log: logURL, titles: titles, now: now) else { continue }
                    seen.insert(id)
                    if let entry = tracked[id], let observation = entry.observation { observations.append(observation) }
                }
            }
        }
        tracked = tracked.filter { seen.contains($0.key) }
        return observations.sorted { $0.id < $1.id }
    }

    /// Brings one task's entry up to date. False for a task outside the window, which is forgotten; true for one
    /// still worth remembering, which includes an archived task that is recent, so that its half-megabyte record
    /// is not read again on every poll only to be refused again.
    private func observe(id: String, record: URL, log: URL, titles: Bool, now: Date) -> Bool {
        let logValues = try? log.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let logModified = logValues?.contentModificationDate
        let recordModified = (try? record.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        // The cheap refusals first, so an old task costs a `stat` or two and its record is never opened: a log
        // that has not moved inside the window, or, for a task with no log, a record that has not either (its
        // `lastActivityAt` is written into it, so it can be no newer than the file).
        if let logModified, now.timeIntervalSince(logModified) >= CoworkSessions.listedFor { return false }
        if logModified == nil, recordModified.map({ now.timeIntervalSince($0) >= CoworkSessions.listedFor }) ?? true { return false }
        var entry = tracked[id] ?? Tracked()
        if !titles { entry.record?.title = nil }
        let due = entry.recordReadAt.map { now.timeIntervalSince($0) >= CoworkSessions.recordSpacing } ?? true
        if entry.record == nil || ((recordModified != entry.recordModified || entry.titles != titles) && due) {
            // A record caught half written does not parse; the one read before it stands, and the next change is
            // read again once `recordSpacing` has passed. Read whole rather than mapped: the Claude app rewrites
            // it, and a mapped file cut short under the reader is a crash rather than a failed parse.
            if let data = try? Data(contentsOf: record), var parsed = CoworkSessions.metadata(from: data) {
                if !titles { parsed.title = nil }
                entry.record = parsed
                entry.project = parsed.folder.flatMap(ProjectName.ofPath)
                entry.recordModified = recordModified
                entry.titles = titles
            }
            entry.recordReadAt = now
        }
        guard let metadata = entry.record, let lastWrite = logModified ?? metadata.lastActivity,
              now.timeIntervalSince(lastWrite) < CoworkSessions.listedFor else { return false }
        if !metadata.archived, let size = logValues?.fileSize.map(UInt64.init) { readLog(log, size: size, into: &entry) }
        entry.observation = metadata.archived ? nil
            : CoworkSessions.Observation(id: id, title: metadata.title, project: entry.project, lastWrite: lastWrite, turn: entry.turn)
        tracked[id] = entry
        return true
    }

    /// Reads what was appended since the last poll. The first read, a log that shrank (it was replaced), and a
    /// burst past `catchUpLimit` start again from the tail (`readTail`).
    private func readLog(_ url: URL, size: UInt64, into entry: inout Tracked) {
        guard let offset = entry.offset, offset <= size, size - offset <= UInt64(CoworkSessions.catchUpLimit) else {
            readTail(url, size: size, into: &entry)
            return
        }
        guard offset < size else { return }
        guard let chunk = Self.read(url, from: offset, to: size) else {
            entry.offset = nil
            return
        }
        entry.turn.read(chunk, partial: &entry.partial, skipping: &entry.skipping)
        entry.offset = offset + UInt64(chunk.count)
    }

    /// Reads a log afresh from its last `tailBytes`, from the first whole line in them. A tail that holds neither a
    /// prompt nor an end (a turn whose tools wrote more than the tail since it began, which a few screenshots do)
    /// says nothing about the turn's start, so it is widened, once, to `catchUpLimit`: read once when a task is
    /// first seen, it is what lets a turn the app meets half-way clock from its real prompt.
    private func readTail(_ url: URL, size: UInt64, into entry: inout Tracked) {
        for window in [UInt64(CoworkSessions.tailBytes), UInt64(CoworkSessions.catchUpLimit)] {
            let start = size > window ? size - window : 0
            guard let chunk = Self.read(url, from: start, to: size) else {
                entry.offset = nil
                return
            }
            var turn = CoworkSessions.Turn()
            var partial = Data()
            // Read from the middle of a file, the first line is a piece of one and is skipped.
            var skipping = start > 0
            turn.read(chunk, partial: &partial, skipping: &skipping)
            (entry.turn, entry.partial, entry.skipping) = (turn, partial, skipping)
            entry.offset = start + UInt64(chunk.count)
            if start == 0 || turn.began != nil || turn.end != nil { return }
        }
    }

    /// The bytes of `url` between two offsets, read-only; nil when the file cannot be read.
    private static func read(_ url: URL, from start: UInt64, to end: UInt64) -> Data? {
        guard start < end else { return Data() }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: start)
            return try handle.read(upToCount: Int(end - start)) ?? Data()
        } catch {
            return nil
        }
    }

    private static func folders(in url: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }
        return entries.filter { (try? $0.resourceValues(forKeys: Set(keys)))?.isDirectory == true }
    }
}
