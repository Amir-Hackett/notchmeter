import Foundation
import SQLite3

/// Cursor's own name for a conversation ("Upgrade process inquiry"), for a Cursor row whose prompt the app never
/// saw: it launched after the chat began, or the chat is between prompts. Without it such a row fell back to the
/// project's folder name, and two chats in one project read the same.
///
/// Cursor names a chat after its first reply and keeps the name in its state database (the file CursorProvider
/// reads the session token from): `composerHeaders.value` (`$.name`, present once the chat has one), and before
/// that table existed, the `composerData:<id>` row of `cursorDiskKV` (`$.name` again). The conversation id is the
/// one Cursor's hooks send (`conversation_id`, Hook+Cursor.swift), which is the session's key less its `cursor:`.
///
/// The name is the user's work described in Cursor's words, so it is treated as a prompt title is: held only
/// while Preferences.sessionTitles is on, never looked up or shown while the screen is shared
/// (UsageStore.hidesFigures), dropped by SessionTracker.clearTitles with the rest, and never logged or sent to the
/// oracle. It lands in `AgentSession.sessionName`, so a prompt title the hook sent still comes first
/// (`AgentSession.displayTitle`).
///
/// The read is a private copy of the database (CursorProvider.withStateCopy), off the main thread, batched over
/// every id due, and at most once per `retryAfter` per id; an id that has a name is not read again.
enum CursorChatNames {
    /// How long an id that had no name waits before the database is read for it again. Cursor names a chat a few
    /// seconds after its first reply, so a row that missed it catches up within this.
    static let retryAfter: TimeInterval = 30
    /// How recently a session must have been heard from to be worth a follow-up read with no hook event to prompt
    /// it: long enough to cover a chat named just after its turn ended, short enough that an abandoned chat stops
    /// costing reads.
    static let followUpWindow: TimeInterval = 10 * 60

    /// The conversation id behind a session key (`cursor:<id>`, SessionTracker.key), or nil for any other tool's
    /// session, a remote one (whose Cursor is on another Mac), or an id that is not shaped like Cursor's.
    static func conversationID(of session: AgentSession) -> String? {
        // A detected row is keyed by its process (SessionDetection.processKey), which names no conversation.
        guard session.tool == .cursor, session.host == nil, session.source == .hook else { return nil }
        let prefix = ToolID.cursor.rawValue + ":"
        guard session.id.hasPrefix(prefix) else { return nil }
        let id = String(session.id.dropFirst(prefix.count))
        return isConversationID(id) ? id : nil
    }

    /// Letters, digits and dashes, as Cursor's UUIDs are: the id is bound as a parameter, never spliced into SQL,
    /// but anything else did not come from Cursor and is not worth a read.
    static func isConversationID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" }
    }

    /// Whether a lookup may run at all: titles on and the screen not shared.
    static func allowed(titles: Bool, hidesFigures: Bool) -> Bool { titles && !hidesFigures }

    /// The sessions a read is for, by session key, with each one's conversation id: Cursor sessions on this Mac
    /// with no title of any kind yet whose id was not tried inside `retryAfter`. Nothing at all when the lookup is
    /// not allowed.
    static func due(_ sessions: [AgentSession], tried: [String: Date], titles: Bool, hidesFigures: Bool, now: Date) -> [String: String] {
        guard allowed(titles: titles, hidesFigures: hidesFigures) else { return [:] }
        var due: [String: String] = [:]
        for session in sessions where session.displayTitle == nil {
            guard let id = conversationID(of: session) else { continue }
            if let last = tried[id], now.timeIntervalSince(last) < retryAfter { continue }
            due[session.id] = id
        }
        return due
    }

    /// Whether a follow-up read is worth arming: an unnamed Cursor session heard from inside `followUpWindow`.
    static func wantsFollowUp(_ sessions: [AgentSession], titles: Bool, hidesFigures: Bool, now: Date) -> Bool {
        guard allowed(titles: titles, hidesFigures: hidesFigures) else { return false }
        return sessions.contains {
            $0.displayTitle == nil && conversationID(of: $0) != nil && now.timeIntervalSince($0.lastEvent) < followUpWindow
        }
    }

    /// The name in one `composerHeaders.value` or `composerData` JSON, cleaned the way a prompt title is
    /// (Hook.title(fromPrompt:): one line, collapsed spaces, at most `Hook.titleLimit` characters); nil for no
    /// name, an empty one, or JSON that is not an object.
    static func name(fromJSON json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Hook.title(fromPrompt: object["name"])
    }

    /// The names the database holds for `ids`, by conversation id; an id with no name is absent. The headers are
    /// read first (one small row each); `composerData` only for the ids they did not name, since those rows hold
    /// the whole conversation. A database that cannot be copied or opened reads as no names.
    static func read(ids: Set<String>, database: URL) -> [String: String] {
        let ids = ids.filter(isConversationID)
        guard !ids.isEmpty, FileManager.default.fileExists(atPath: database.path) else { return [:] }
        return (try? CursorProvider.withStateCopy(of: database) { db in
            var names: [String: String] = [:]
            for id in ids {
                if let json = value(db, "SELECT value FROM composerHeaders WHERE composerId = ?1 LIMIT 1", id), let name = name(fromJSON: json) {
                    names[id] = name
                } else if let json = value(db, "SELECT value FROM cursorDiskKV WHERE key = ?1 LIMIT 1", "composerData:" + id),
                          let name = name(fromJSON: json) {
                    names[id] = name
                }
            }
            return names
        }) ?? [:]
    }

    /// One text value for one bound parameter, or nil: no row, or no such table in this Cursor's database.
    private static func value(_ db: OpaquePointer, _ sql: String, _ parameter: String) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, parameter, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return CursorProvider.columnText(statement, 0)
    }
}
