import Foundation
import SQLite3
import os

private let log = Logger(subsystem: "com.amirhackett.notchmeter", category: "opencode")

/// Where OpenCode keeps its files, as its own `Global.Path` and `Database.path()` resolve them (anomalyco/opencode,
/// `packages/core/src/global.ts` and `database/database.ts`, read 2026-09-24): data under `$XDG_DATA_HOME/opencode`,
/// else `~/.local/share/opencode`; configuration under `$XDG_CONFIG_HOME/opencode`, else `~/.config/opencode`. The
/// database is `$OPENCODE_DB` when set (absolute, or relative to the data folder), else `opencode.db` for a release
/// build and `opencode-<channel>.db` for any other channel, which a channel switch has been known to leave behind
/// unmigrated (anomalyco/opencode#21790), so every `opencode*.db` in the folder is read. Only the process's own
/// environment is consulted: a Finder launch that inherited no `XDG_*` finds the default folders, which is where an
/// OpenCode started from a login shell without them keeps its files too.
enum OpenCodePaths {
    static func dataDirectory(environment: [String: String] = ProcessInfo.processInfo.environment, home: URL = Paths.home) -> URL {
        (xdg("XDG_DATA_HOME", environment: environment) ?? home.appendingPathComponent(".local/share")).appendingPathComponent("opencode")
    }

    static func configDirectory(environment: [String: String] = ProcessInfo.processInfo.environment, home: URL = Paths.home) -> URL {
        (xdg("XDG_CONFIG_HOME", environment: environment) ?? home.appendingPathComponent(".config")).appendingPathComponent("opencode")
    }

    /// An XDG variable is honoured only as an absolute path, which is what the XDG specification allows.
    private static func xdg(_ name: String, environment: [String: String]) -> URL? {
        guard let value = environment[name], value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value)
    }

    /// The databases to read, `opencode.db` first so that a message stored twice is taken from it.
    static func databases(in data: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        if let named = environment["OPENCODE_DB"], !named.isEmpty, named != ":memory:" {
            let url = named.hasPrefix("/") ? URL(fileURLWithPath: named) : data.appendingPathComponent(named)
            return FileManager.default.fileExists(atPath: url.path) ? [url] : []
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: data.path)) ?? []
        return names.filter { $0.hasPrefix("opencode") && $0.hasSuffix(".db") }
            .sorted { ($0 == "opencode.db" ? 0 : 1, $0) < ($1 == "opencode.db" ? 0 : 1, $1) }
            .map { data.appendingPathComponent($0) }
    }

    /// Builds before 1.2 kept one JSON file per message under `storage/message/<session>/<message>.json`.
    static func legacyMessages(in data: URL) -> URL { data.appendingPathComponent("storage/message") }

    /// What changes whenever OpenCode writes: each database and its write-ahead log, by size and modification time,
    /// and the legacy message folder's own date. Equal fingerprints mean nothing new has been written.
    static func fingerprint(data: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        var parts: [String] = []
        for url in databases(in: data, environment: environment) {
            for suffix in ["", "-wal"] {
                let values = try? URL(fileURLWithPath: url.path + suffix).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                parts.append("\(url.lastPathComponent)\(suffix):\(values?.fileSize ?? -1):\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)")
            }
        }
        let legacy = try? legacyMessages(in: data).resourceValues(forKeys: [.contentModificationDateKey])
        parts.append("legacy:\(legacy?.contentModificationDate?.timeIntervalSince1970 ?? 0)")
        return parts.joined(separator: ";")
    }
}

/// One OpenCode assistant turn as OpenCode recorded it: its time, its model, its folder, its tokens in this app's
/// buckets and the cost OpenCode itself put on it. Never the prompt, the reply or a tool's output: those live in
/// other rows and tables, which are never read.
struct OpenCodeUsage: Equatable, Sendable {
    let id: String
    let sessionID: String
    let timestamp: Date
    let providerID: String?
    let modelID: String?
    /// The folder the turn ran in (`path.cwd`, or the session's directory); reduced to a project name when priced.
    let directory: String?
    /// OpenCode's `input` is already net of the cache (its `getUsage` subtracts both cache buckets), `cache.read` and
    /// `cache.write` are the cache, and its `output` is net of `reasoning`, which OpenCode itself prices at the output
    /// rate, so the output bucket here is the two added back together.
    let tokens: TokenBreakdown
    /// What the provider was sent, cache included: the figure a long-context price row is decided on.
    let contextTokens: Int
    /// OpenCode's own `cost`; nil when the record carries none.
    let recordedCost: Double?
}

/// One session as OpenCode's database last recorded it, for the sessions read without the plugin
/// (OpenCodeSessions). The turn is read from the newest messages of the session; nothing of their text is read.
struct OpenCodeSessionState: Equatable, Sendable {
    enum Turn: Equatable, Sendable {
        /// A prompt is being answered: the user's message is the newest, or the assistant's is still open or only
        /// paused between tool calls.
        case working(since: Date)
        /// The last answer finished, when, and why it stopped if it failed (`aborted`, `rate_limit`, `error`).
        case idle(finishedAt: Date?, turnStarted: Date?, failure: String?)
    }

    let id: String
    /// A subagent's session names the session it works for.
    let parentID: String?
    let directory: String?
    /// OpenCode's own title for the session, only when the caller allowed titles, and never its placeholder.
    let title: String?
    /// The newest write to the session or its messages.
    let updated: Date
    let archived: Bool
    let turn: Turn
}

/// Read-only access to OpenCode's local storage. Every database is opened with SQLite's read-only flag and
/// `query_only` on, so nothing here can write, and never through a private copy, which for a database this size would
/// cost a copy per read: while OpenCode runs its write-ahead log exists and a read-only connection shares it like
/// any other reader, and while it does not the file is opened `immutable`, which neither locks nor creates a
/// sidecar. Only the `message`, `session_message` and `session` tables are asked for, and only for the columns
/// named in the queries below; the same file's credential, account and prompt-input tables are never touched.
enum OpenCodeStore {
    enum Failure: LocalizedError, Equatable {
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): L("OpenCode's database %@ could not be read", name)
            }
        }
    }

    /// A statement SQLite would not prepare or would not run to its end, with what SQLite said. `sqlite3_open_v2`
    /// reads no header, so a file that is no database, a corrupt one, or one held past the busy timeout while
    /// OpenCode migrates or checkpoints is first met here; `withDatabase` turns it into `Failure.unreadable`, since
    /// to the reader a database it cannot query is one it cannot read, and an empty answer would read as no turns
    /// and no sessions rather than as a problem.
    struct QueryFailure: Error, Equatable {
        let message: String
    }

    // MARK: - Parsing, pure

    /// A `message.data` object (OpenCode 1.2 onwards) or a legacy `storage/message` file: only an assistant's, and
    /// only one with something recorded (tokens or a cost), since a turn still streaming has neither yet.
    static func usage(v1 object: [String: Any], id fallbackID: String?, session fallbackSession: String?, directory fallbackDirectory: String?) -> OpenCodeUsage? {
        guard object["role"] as? String == "assistant" else { return nil }
        let time = object["time"] as? [String: Any]
        let path = object["path"] as? [String: Any]
        return usage(id: text(object["id"]) ?? fallbackID, session: text(object["sessionID"]) ?? fallbackSession,
                     created: date(time?["created"]), provider: text(object["providerID"]), model: text(object["modelID"]),
                     directory: text(path?["cwd"]) ?? fallbackDirectory, tokens: object["tokens"], cost: JSON.number(object["cost"]))
    }

    /// A `session_message.data` object of type `assistant` (the event-sourced session store 2026 builds added
    /// beside `message`), whose model is `{id, providerID}` and whose tokens and cost are optional.
    static func usage(v2 object: [String: Any], id fallbackID: String?, session: String?, directory: String?) -> OpenCodeUsage? {
        guard object["type"] as? String == "assistant" else { return nil }
        let model = object["model"] as? [String: Any]
        let time = object["time"] as? [String: Any]
        return usage(id: text(object["id"]) ?? fallbackID, session: session, created: date(time?["created"]),
                     provider: text(model?["providerID"]), model: text(model?["id"]), directory: directory,
                     tokens: object["tokens"], cost: JSON.number(object["cost"]))
    }

    private static func usage(id: String?, session: String?, created: Date?, provider: String?, model: String?, directory: String?,
                              tokens value: Any?, cost: Double?) -> OpenCodeUsage? {
        guard let id, let session, let created else { return nil }
        let tokens = value as? [String: Any]
        let cache = tokens?["cache"] as? [String: Any]
        func count(_ number: Any?) -> Int { max(0, Int(JSON.number(number) ?? 0)) }
        let input = count(tokens?["input"])
        let output = count(tokens?["output"]) + count(tokens?["reasoning"])
        let read = count(cache?["read"])
        let write = count(cache?["write"])
        let breakdown = TokenBreakdown(input: input, cacheWrite5m: write, cacheRead: read, output: output)
        guard breakdown.total > 0 || (cost ?? 0) > 0 else { return nil }
        return OpenCodeUsage(id: id, sessionID: session, timestamp: created, providerID: provider, modelID: model, directory: directory,
                             tokens: breakdown, contextTokens: input + read + write, recordedCost: cost)
    }

    /// Epoch milliseconds, as a number or an ISO 8601 string.
    static func date(_ value: Any?) -> Date? {
        if let millis = JSON.number(value), millis > 0 { return Date(timeIntervalSince1970: millis / 1000) }
        return (value as? String).flatMap(DateParsing.iso8601)
    }

    private static func text(_ value: Any?) -> String? {
        (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func object(_ json: String?) -> [String: Any]? {
        guard let data = json?.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The titles OpenCode gives a session before it has written one of its own ("New session - 2026-09-24T…",
    /// "Child session - …"), which say nothing about the work.
    static func isPlaceholderTitle(_ title: String) -> Bool {
        title.hasPrefix("New session - ") || title.hasPrefix("Child session - ")
    }

    /// The turn a session's newest messages describe, newest first: the user's message is the newest, or the
    /// newest assistant message is open, or it closed on a tool call and the next step has not begun, and the
    /// turn is working; otherwise it is idle, finished when the assistant's message closed. A working turn with
    /// no write for `abandonedAfter` is idle with no finish: OpenCode was closed mid-turn, and nothing else says so.
    ///
    /// The turn's clock is the prompt's: `prompted` is the newest user message's own time, read on its own by the
    /// caller, because OpenCode writes one assistant message per step of a turn and a turn of more than a few
    /// steps has no user message among its newest few. Taken from the window alone, a long turn's clock would
    /// restart at every step and each step would read as a new prompt.
    static func turn(newestFirst messages: [[String: Any]], prompted: Date? = nil, updated: Date, now: Date) -> OpenCodeSessionState.Turn {
        let userStarted = prompted ?? messages.first { ($0["role"] as? String ?? $0["type"] as? String) == "user" }
            .flatMap { promptTime($0) }
        guard let newest = messages.first else { return .idle(finishedAt: nil, turnStarted: nil, failure: nil) }
        let kind = newest["role"] as? String ?? newest["type"] as? String
        let time = newest["time"] as? [String: Any]
        let created = date(time?["created"]) ?? updated
        let completed = date(time?["completed"])
        let finish = newest["finish"] as? String
        let error = newest["error"] as? [String: Any]
        let working: Bool
        switch kind {
        case "user": working = true
        case "assistant": working = error == nil && (completed == nil || finish.map(Self.continuingFinishes.contains) == true)
        default: working = false
        }
        if working {
            guard now.timeIntervalSince(updated) < abandonedAfter else { return .idle(finishedAt: nil, turnStarted: userStarted, failure: nil) }
            return .working(since: userStarted ?? created)
        }
        return .idle(finishedAt: kind == "assistant" ? completed ?? updated : nil, turnStarted: userStarted, failure: error.map(failure(of:)))
    }

    /// When a message was created, which for a user's message is when its prompt was sent.
    static func promptTime(_ message: [String: Any]) -> Date? {
        date((message["time"] as? [String: Any])?["created"])
    }

    /// The finish reasons an assistant message closes on while its turn goes on: the model asked for a tool, and
    /// OpenCode opens the next message once the tool has answered.
    static let continuingFinishes: Set<String> = ["tool-calls", "tool_calls", "tool_use"]

    /// How long a turn may go without a write before it is taken to have been abandoned.
    static let abandonedAfter: TimeInterval = 30 * 60

    /// An assistant error's kind in the tracker's vocabulary: the user stopped it, a 429, or anything else.
    static func failure(of error: [String: Any]) -> String {
        let name = error["name"] as? String
        let data = error["data"] as? [String: Any]
        if name == "MessageAbortedError" { return "aborted" }
        if JSON.number(data?["statusCode"]) == 429 { return "rate_limit" }
        return "error"
    }

    // MARK: - Reading

    /// Every assistant turn recorded since `since`, from every database and the legacy files, each once: a message
    /// id met again (a database a channel switch left behind, legacy files a later build imported) is skipped, and
    /// a session whose turns the `message` table holds is not read again from `session_message`. The problem is the
    /// first database that could not be read, with whatever the others held.
    static func usage(data: URL, environment: [String: String] = ProcessInfo.processInfo.environment, since: Date) -> (usage: [OpenCodeUsage], problem: String?) {
        var seen: Set<String> = []
        var found: [OpenCodeUsage] = []
        var problem: String?
        func keep(_ usage: OpenCodeUsage?) {
            guard let usage, usage.timestamp >= since, seen.insert(usage.id).inserted else { return }
            found.append(usage)
        }
        // A row's own time_created is when it was written, a moment after the turn began; a day's margin keeps a
        // turn the SQL filter would cut at the edge, and the parsed time decides.
        let floor = Int64((since.timeIntervalSince1970 - Period.day) * 1000)
        for url in OpenCodePaths.databases(in: data, environment: environment) {
            do {
                try withDatabase(url) { db in
                    let tables = try tableNames(db)
                    let directories = tables.contains("session") ? try pairs(db, "SELECT id, directory FROM session") : [:]
                    var v1Sessions: Set<String> = []
                    if tables.contains("message") {
                        for row in try rows(db, "SELECT id, session_id, data FROM message WHERE time_created >= ?1", floor) {
                            guard let object = object(row[2]) else { continue }
                            let session = row[1]
                            let usage = usage(v1: object, id: row[0], session: session, directory: session.flatMap { directories[$0] })
                            if let usage { v1Sessions.insert(usage.sessionID) }
                            keep(usage)
                        }
                    }
                    if tables.contains("session_message") {
                        let query = "SELECT id, session_id, data FROM session_message WHERE type = 'assistant' AND time_created >= ?1"
                        for row in try rows(db, query, floor) {
                            guard let session = row[1], !v1Sessions.contains(session), let object = object(row[2]) else { continue }
                            keep(usage(v2: object, id: row[0], session: session, directory: directories[session]))
                        }
                    }
                }
            } catch {
                problem = problem ?? error.localizedDescription
            }
        }
        for usage in legacyUsage(folder: OpenCodePaths.legacyMessages(in: data), since: since) { keep(usage) }
        return (found, problem)
    }

    /// Legacy message files modified since `since`: one folder per session, one file per message.
    static func legacyUsage(folder: URL, since: Date) -> [OpenCodeUsage] {
        let fm = FileManager.default
        guard let sessions = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        else { return [] }
        var found: [OpenCodeUsage] = []
        for session in sessions {
            let modified = (try? session.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            guard modified >= since,
                  let files = try? fm.contentsOfDirectory(at: session, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
            else { continue }
            for file in files where file.pathExtension == "json" {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                guard date >= since, let data = try? Data(contentsOf: file),
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                if let usage = usage(v1: object, id: file.deletingPathExtension().lastPathComponent, session: session.lastPathComponent, directory: nil) {
                    found.append(usage)
                }
            }
        }
        return found
    }

    /// The sessions written since `since`, each with the turn its newest messages describe. `titles` decides whether
    /// OpenCode's own title for each is read at all. Sessions from every database; a session id met twice is taken
    /// from the first. Legacy JSON storage is not read here: a build that old predates everything the sessions
    /// need, and the plugin covers it. A database that could not be read is the problem, and the sessions are
    /// whatever the others held; the caller decides what a read with a problem is worth.
    static func sessions(data: URL, environment: [String: String] = ProcessInfo.processInfo.environment, since: Date, titles: Bool,
                         now: Date = Date()) -> (sessions: [OpenCodeSessionState], problem: String?) {
        var found: [String: OpenCodeSessionState] = [:]
        var order: [String] = []
        var problem: String?
        let floor = Int64(since.timeIntervalSince1970 * 1000)
        for url in OpenCodePaths.databases(in: data, environment: environment) {
            do {
                try withDatabase(url) { db in
                    let tables = try tableNames(db)
                    guard tables.contains("session") else { return }
                    let columns = try columnNames(db, "session")
                    let archived = columns.contains("time_archived") ? "time_archived" : "NULL"
                    let title = titles ? "title" : "NULL"
                    // A session row's own time_updated moves at the prompt (OpenCode's `touch` in
                    // packages/opencode/src/session/prompt.ts, read 2026-09-24) and not as the turn's messages are
                    // written, so a turn longer than the window would leave it mid-turn and read as vanished. A
                    // session is inside the window when it, or any message of its, was written inside it. The
                    // message tables are each scanned once for the ids rather than once per session row.
                    var recent = ["time_updated >= ?1"]
                    if tables.contains("message") { recent.append("id IN (SELECT session_id FROM message WHERE time_updated >= ?1)") }
                    if tables.contains("session_message") { recent.append("id IN (SELECT session_id FROM session_message WHERE time_updated >= ?1)") }
                    let query = "SELECT id, parent_id, directory, \(title), time_updated, \(archived) FROM session WHERE \(recent.joined(separator: " OR "))"
                    for row in try rows(db, query, floor) {
                        guard let id = row[0], found[id] == nil else { continue }
                        var messages: [[String: Any]] = []
                        var newestWrite = 0.0
                        var prompted: Date?
                        if tables.contains("message") {
                            for message in try rows(db, "SELECT data, time_updated FROM message WHERE session_id = ?1 ORDER BY time_created DESC, id DESC LIMIT 8", id) {
                                if let object = object(message[0]) { messages.append(object) }
                                newestWrite = max(newestWrite, Double(message[1] ?? "") ?? 0)
                            }
                            // The newest prompt on its own (see `turn`): the message's own record names its role.
                            let newest = "SELECT data FROM message WHERE session_id = ?1 AND json_extract(data, '$.role') = 'user' ORDER BY time_created DESC, id DESC LIMIT 1"
                            prompted = try rows(db, newest, id).first.flatMap { object($0[0]) }.flatMap(promptTime)
                        }
                        if messages.isEmpty, tables.contains("session_message") {
                            let query = "SELECT data, time_updated FROM session_message WHERE session_id = ?1 AND type IN ('user', 'assistant') ORDER BY seq DESC LIMIT 8"
                            for message in try rows(db, query, id) {
                                if let object = object(message[0]) { messages.append(object) }
                                newestWrite = max(newestWrite, Double(message[1] ?? "") ?? 0)
                            }
                            let newest = "SELECT data FROM session_message WHERE session_id = ?1 AND type = 'user' ORDER BY seq DESC LIMIT 1"
                            prompted = try rows(db, newest, id).first.flatMap { object($0[0]) }.flatMap(promptTime)
                        }
                        let updated = Date(timeIntervalSince1970: max(Double(row[4] ?? "") ?? 0, newestWrite) / 1000)
                        let name = row[3].flatMap { $0.isEmpty || isPlaceholderTitle($0) ? nil : Hook.title(fromPrompt: $0) }
                        found[id] = OpenCodeSessionState(id: id, parentID: row[1].flatMap { $0.isEmpty ? nil : $0 },
                                                         directory: row[2].flatMap { $0.isEmpty ? nil : $0 }, title: name, updated: updated,
                                                         archived: (Double(row[5] ?? "") ?? 0) > 0,
                                                         turn: turn(newestFirst: messages, prompted: prompted, updated: updated, now: now))
                        order.append(id)
                    }
                }
            } catch {
                problem = problem ?? error.localizedDescription
            }
        }
        return (order.compactMap { found[$0] }, problem)
    }

    // MARK: - SQLite, read-only

    /// Runs `body` on a read-only connection to `url`, closed afterwards.
    static func withDatabase<T>(_ url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        let live = FileManager.default.fileExists(atPath: url.path + "-wal")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: live ? "mode" : "immutable", value: live ? "ro" : "1")]
        var db: OpaquePointer?
        guard let uri = components?.string,
              sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw Failure.unreadable(url.lastPathComponent)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        sqlite3_exec(db, "PRAGMA query_only = 1", nil, nil, nil)
        do {
            return try body(db)
        } catch let failure as QueryFailure {
            log.warning("OpenCode's \(url.lastPathComponent, privacy: .public) could not be queried: \(failure.message, privacy: .public)")
            throw Failure.unreadable(url.lastPathComponent)
        }
    }

    static func tableNames(_ db: OpaquePointer) throws -> Set<String> {
        Set(try rows(db, "SELECT name FROM sqlite_master WHERE type = 'table'").compactMap { $0[0] })
    }

    static func columnNames(_ db: OpaquePointer, _ table: String) throws -> Set<String> {
        // A table name cannot be bound; this one is always a constant of this file.
        Set(try rows(db, "PRAGMA table_info(\(table))").compactMap { $0.count > 1 ? $0[1] : nil })
    }

    private static func pairs(_ db: OpaquePointer, _ sql: String) throws -> [String: String] {
        try rows(db, sql).reduce(into: [:]) { result, row in
            if let key = row[0], let value = row[1] { result[key] = value }
        }
    }

    /// Every row of `sql` as text columns, with one parameter bound as an integer or as text. A statement that
    /// cannot be prepared, or that stops on anything but its end (busy past the timeout, not a database, corrupt),
    /// is a `QueryFailure` rather than the rows so far: a partial answer would read as fewer turns and fewer
    /// sessions than there are.
    static func rows(_ db: OpaquePointer, _ sql: String, _ parameter: Any? = nil) throws -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw QueryFailure(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        if let number = parameter as? Int64 {
            sqlite3_bind_int64(statement, 1, number)
        } else if let text = parameter as? String {
            sqlite3_bind_text(statement, 1, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        var result: [[String?]] = []
        let columns = sqlite3_column_count(statement)
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            result.append((0..<columns).map { column in
                sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : CursorProvider.columnText(statement, column)
            })
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw QueryFailure(message: String(cString: sqlite3_errmsg(db))) }
        return result
    }
}
