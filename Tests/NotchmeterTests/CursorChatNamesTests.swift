import Foundation
import SQLite3
import Testing
@testable import Notchmeter

/// Cursor's own names for its chats (CursorChatNames): the JSON they are read from, which sessions a read is for
/// and when, the privacy gate, the precedence a prompt title keeps over them, the rows that would otherwise read
/// alike, and a read against a scratch database laid out as Cursor lays its own.
@Suite struct CursorChatNaming {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    let id = "f3cbe275-42c2-49c0-a13d-8edb29a28cd9"

    func cursorSession(_ conversation: String, title: String? = nil, name: String? = nil, host: String? = nil,
                       lastEvent: Date? = nil, started: Date? = nil) -> AgentSession {
        var session = AgentSession(id: SessionTracker.key(tool: .cursor, session: conversation, host: host), tool: .cursor,
                                   project: "enrollhere-admin-support-tools", state: .idle, started: started ?? t0,
                                   lastEvent: lastEvent ?? t0, turnStarted: nil, branch: "dev", host: host)
        session.title = title
        session.sessionName = name
        return session
    }

    // MARK: - The JSON

    /// A header as Cursor 3 writes it once the chat is named, trimmed to the fields around the name.
    @Test func theNameIsReadFromAHeaderOrAComposerRow() {
        let header = #"{"type":"head","composerId":"f3cbe275","name":"Upgrade process inquiry","lastUpdatedAt":1782256270807,"subtitle":"Read .gitignore"}"#
        #expect(CursorChatNames.name(fromJSON: header) == "Upgrade process inquiry")
        let composer = #"{"_v":3,"composerId":"f3cbe275","name":"Settings.json update","conversation":[{"text":"the whole prompt"}]}"#
        #expect(CursorChatNames.name(fromJSON: composer) == "Settings.json update")
    }

    @Test func anUnnamedOrUnreadableRowHasNoName() {
        #expect(CursorChatNames.name(fromJSON: #"{"type":"head","composerId":"x","isDraft":false}"#) == nil, "not named yet")
        #expect(CursorChatNames.name(fromJSON: #"{"name":""}"#) == nil)
        #expect(CursorChatNames.name(fromJSON: #"{"name":"   "}"#) == nil)
        #expect(CursorChatNames.name(fromJSON: #"{"name":42}"#) == nil)
        #expect(CursorChatNames.name(fromJSON: #"["name"]"#) == nil)
        #expect(CursorChatNames.name(fromJSON: "not json") == nil)
    }

    @Test func aNameIsCleanedLikeAPromptTitle() {
        #expect(CursorChatNames.name(fromJSON: #"{"name":"Fix   the\tqueue\nand more"}"#) == "Fix the queue")
        let long = String(repeating: "word ", count: 40)
        let name = CursorChatNames.name(fromJSON: "{\"name\":\"\(long)\"}")
        #expect(name?.hasSuffix("…") == true)
        #expect((name?.count ?? 0) <= Hook.titleLimit + 1)
    }

    // MARK: - Which sessions, and when

    @Test func theConversationIsTheSessionKeyLessItsTool() {
        #expect(CursorChatNames.conversationID(of: cursorSession(id)) == id)
        #expect(CursorChatNames.conversationID(of: cursorSession(id, host: "devbox")) == nil, "a remote chat's Cursor is on another Mac")
        let claude = AgentSession(id: id, tool: .claude, project: "p", state: .idle, started: t0, lastEvent: t0, turnStarted: nil)
        #expect(CursorChatNames.conversationID(of: claude) == nil)
        #expect(CursorChatNames.conversationID(of: cursorSession("a'; DROP TABLE x;--")) == nil, "not shaped like Cursor's ids")
        #expect(CursorChatNames.conversationID(of: cursorSession("")) == nil)
    }

    @Test func onlyUntitledChatsAreLookedUpAndEachAtMostEveryThirtySeconds() {
        let sessions = [cursorSession(id), cursorSession("b-1", title: "Prompt title"), cursorSession("c-1", name: "Named already")]
        let due = CursorChatNames.due(sessions, tried: [:], titles: true, hidesFigures: false, now: t0)
        #expect(due == ["cursor:\(id)": id])
        let soon = t0.addingTimeInterval(CursorChatNames.retryAfter - 1)
        #expect(CursorChatNames.due(sessions, tried: [id: t0], titles: true, hidesFigures: false, now: soon).isEmpty)
        let later = t0.addingTimeInterval(CursorChatNames.retryAfter)
        #expect(CursorChatNames.due(sessions, tried: [id: t0], titles: true, hidesFigures: false, now: later) == ["cursor:\(id)": id],
                "still unnamed, and Cursor may have named it since")
    }

    /// The name is the user's work in Cursor's words: nothing is read with titles off or the screen shared.
    @Test func nothingIsLookedUpWithTitlesOffOrTheScreenShared() {
        let sessions = [cursorSession(id)]
        #expect(CursorChatNames.due(sessions, tried: [:], titles: false, hidesFigures: false, now: t0).isEmpty)
        #expect(CursorChatNames.due(sessions, tried: [:], titles: true, hidesFigures: true, now: t0).isEmpty)
        #expect(!CursorChatNames.wantsFollowUp(sessions, titles: false, hidesFigures: false, now: t0))
        #expect(!CursorChatNames.wantsFollowUp(sessions, titles: true, hidesFigures: true, now: t0))
        #expect(!CursorChatNames.allowed(titles: true, hidesFigures: true))
        #expect(CursorChatNames.allowed(titles: true, hidesFigures: false))
    }

    @Test func aFollowUpIsArmedOnlyForAChatHeardFromLately() {
        #expect(CursorChatNames.wantsFollowUp([cursorSession(id)], titles: true, hidesFigures: false, now: t0.addingTimeInterval(60)))
        let quiet = t0.addingTimeInterval(CursorChatNames.followUpWindow)
        #expect(!CursorChatNames.wantsFollowUp([cursorSession(id)], titles: true, hidesFigures: false, now: quiet))
        #expect(!CursorChatNames.wantsFollowUp([cursorSession(id, name: "n")], titles: true, hidesFigures: false, now: t0))
    }

    // MARK: - Precedence and the rows

    @Test func aPromptTitleComesBeforeCursorsNameWhichComesBeforeTheFolder() {
        #expect(cursorSession(id, title: "Take a screenshot", name: "Screenshot tooling").displayTitle == "Take a screenshot")
        #expect(cursorSession(id, name: "Screenshot tooling").displayTitle == "Screenshot tooling")
        #expect(SessionsCard.title(of: cursorSession(id, name: "Screenshot tooling"), hideTitles: false) == "Screenshot tooling")
        #expect(SessionsCard.title(of: cursorSession(id), hideTitles: false) == "enrollhere-admin-support-tools")
        #expect(SessionsCard.title(of: cursorSession(id, name: "Screenshot tooling"), hideTitles: true) == "enrollhere-admin-support-tools",
                "hidden like a prompt title while the screen is shared")
    }

    @Test func theTrackerHoldsTheNameAndClearsItWithTheTitles() {
        var tracker = SessionTracker()
        var message = Hook.Message(event: "SessionStart", needsInput: false, sessionID: id, project: "p", notificationType: nil, tool: .cursor)
        message.title = nil
        tracker.apply(message, now: t0)
        tracker.name("cursor:\(id)", "Upgrade process inquiry")
        #expect(tracker.sessions["cursor:\(id)"]?.displayTitle == "Upgrade process inquiry")
        tracker.name("cursor:gone", "Nobody")
        #expect(tracker.sessions["cursor:gone"] == nil, "a name never brings back a session")
        tracker.clearTitles()
        #expect(tracker.sessions["cursor:\(id)"]?.displayTitle == nil)
    }

    /// Two chats in one folder that neither the hook nor Cursor has named read the same; they are told apart by
    /// when the app first heard of each. A named one keeps its name, and a lone untitled one keeps the folder.
    @Test func twoUntitledChatsInOneProjectAreToldApartByWhenTheyWereFirstSeen() {
        let first = cursorSession("a-1", started: t0)
        let second = cursorSession("b-2", started: t0.addingTimeInterval(600))
        let named = cursorSession("c-3", title: "Take a screenshot")
        let rows = SessionsCard.rows([named, first, second], hideTitles: false, jump: false, now: t0.addingTimeInterval(700)).rows
        let titles = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.title) })
        #expect(titles["cursor:c-3"] == "Take a screenshot")
        #expect(titles["cursor:a-1"] == SessionsCard.firstSeen(t0))
        #expect(titles["cursor:b-2"] == SessionsCard.firstSeen(t0.addingTimeInterval(600)))
        #expect(titles["cursor:a-1"] != titles["cursor:b-2"])
        #expect(rows.first { $0.id == "cursor:a-1" }?.branch == "dev", "the branch stays on the second line")
        let lone = SessionsCard.rows([named, first], hideTitles: false, jump: false, now: t0).rows
        #expect(lone.first { $0.id == "cursor:a-1" }?.title == "enrollhere-admin-support-tools")
    }

    // MARK: - The database

    /// A scratch database with Cursor's two tables: one chat named in its header, one named only in its
    /// composer row (an older Cursor), one not named at all.
    @Test func theDatabaseIsReadForTheNamesItHolds() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-chatnames-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("state.vscdb")
        var db: OpaquePointer?
        #expect(sqlite3_open(database.path, &db) == SQLITE_OK)
        let sql = """
        CREATE TABLE composerHeaders (composerId TEXT PRIMARY KEY, workspaceId TEXT, createdAt INTEGER, lastUpdatedAt INTEGER, isArchived INTEGER, isSubagent INTEGER, recency INTEGER, checkpointAt INTEGER, value TEXT, subagentTypeName TEXT);
        CREATE TABLE cursorDiskKV (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
        INSERT INTO composerHeaders (composerId, value) VALUES ('aaaa-1', '{"type":"head","composerId":"aaaa-1","name":"Queue sheet fix"}');
        INSERT INTO composerHeaders (composerId, value) VALUES ('bbbb-2', '{"type":"head","composerId":"bbbb-2"}');
        INSERT INTO cursorDiskKV (key, value) VALUES ('composerData:bbbb-2', '{"composerId":"bbbb-2","name":"Older Cursor name"}');
        INSERT INTO composerHeaders (composerId, value) VALUES ('cccc-3', '{"type":"head","composerId":"cccc-3"}');
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let names = CursorChatNames.read(ids: ["aaaa-1", "bbbb-2", "cccc-3", "dddd-4", "bad id;"], database: database)
        #expect(names == ["aaaa-1": "Queue sheet fix", "bbbb-2": "Older Cursor name"])
        #expect(CursorChatNames.read(ids: ["aaaa-1"], database: directory.appendingPathComponent("missing.vscdb")).isEmpty)
    }
}
