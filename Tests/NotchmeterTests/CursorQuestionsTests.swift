import Foundation
import SQLite3
import SwiftUI
import Testing
@testable import Notchmeter

/// A question Cursor is asking, read from Cursor's own database (CursorQuestions): the rows it is read from, laid
/// out as Cursor 3.23.12 lays its own (two Macs' databases, 2026-10-05), what is and is not a waiting question,
/// which chats are looked up and how often, and the card it makes.
@Suite struct CursorQuestionReading {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let fruit = #"{"title":"Fruit","questions":[{"id":"fruit","prompt":"Which fruit?","options":[{"id":"apple","label":"apple"},{"id":"banana","label":"banana"}]}]}"#

    @Test func aQuestionIsAStepStillWaitingForItsAnswer() throws {
        let asked = try #require(CursorQuestions.asked(name: "ask_question", status: "pending", params: fruit))
        #expect(asked.questions == [.init(prompt: "Which fruit?", allowsSeveral: false, options: ["apple", "banana"])])
        // A question step with no status is waiting, as Cursor itself takes it to be.
        #expect(CursorQuestions.asked(name: "ask_question", status: nil, params: fruit) == asked)
        // Answered or dropped: not asked again.
        #expect(CursorQuestions.asked(name: "ask_question", status: "submitted", params: fruit) == nil)
        #expect(CursorQuestions.asked(name: "ask_question", status: "cancelled", params: fruit) == nil)
        // Another step that happens to be pending is not a question.
        #expect(CursorQuestions.asked(name: "run_terminal_command_v2", status: "pending", params: fruit) == nil)
        #expect(CursorQuestions.asked(name: nil, status: "pending", params: fruit) == nil)
        #expect(CursorQuestions.asked(name: "ask_question", status: "pending", params: nil) == nil)
        #expect(CursorQuestions.asked(name: "ask_question", status: "pending", params: #"{"questions":"none"}"#) == nil)
        #expect(CursorQuestions.asked(name: "ask_question", status: "pending", params: #"{"questions":[{"prompt":"  ","options":[]}]}"#) == nil,
                "a question with no words is nothing to show")

        // Several questions, one of them taking several answers, under either of the names Cursor has for that.
        let two = #"{"questions":[{"id":"a","prompt":"Pick a fruit","allowMultiple":false,"options":[{"id":"1","label":"apple"}]},{"id":"b","prompt":"Pick colours","allowMultiple":true,"options":[{"id":"r","label":"red"},{"id":"g","label":" green "},{"id":"x","label":""}]}]}"#
        let both = try #require(CursorQuestions.asked(name: "ask_question", status: "pending", params: two))
        #expect(both.questions.map(\.prompt) == ["Pick a fruit", "Pick colours"])
        #expect(both.questions.map(\.allowsSeveral) == [false, true])
        #expect(both.questions[1].options == ["red", "green"], "trimmed, and a choice with no words is dropped")
        let agents = #"{"questions":[{"prompt":"Which?","allow_multiple":true,"options":[{"label":"one"},{"label":"two"}]}]}"#
        #expect(CursorQuestions.asked(name: "ask_question", status: "pending", params: agents)?.questions.first?.allowsSeveral == true)

        // A card that asks more than is kept is cut at the limits.
        let many = (0..<12).map { #"{"prompt":"q\#($0)","options":[\#((0..<30).map { #"{"label":"o\#($0)"}"# }.joined(separator: ","))]}"# }.joined(separator: ",")
        let cut = try #require(CursorQuestions.asked(name: "ask_question", status: "pending", params: #"{"questions":[\#(many)]}"#))
        #expect(cut.questions.count == CursorQuestions.questionLimit && cut.questions[0].options.count == CursorQuestions.optionLimit)
    }

    @Test func theCardItMakesIsAnsweredOnTheNotch() throws {
        let asked = CursorAsked(questions: [.init(prompt: "Which fruit?", allowsSeveral: false, options: ["apple", "A new kind of banana"]),
                                            .init(prompt: "Which colours?", allowsSeveral: true, options: ["red"])])
        let card = CursorQuestions.card(asked, window: "proj")
        #expect(card.kind == .question && card.fromDatabase && card.blocksTurn)
        #expect(card.heading == "Which fruit?")
        #expect(card.questions.map(\.text) == ["Which fruit?", "Which colours?"])
        #expect(card.questions.map { $0.choices.map(\.label) } == [["A apple", "B A new kind of banana", "C Other..."], ["A red", "B Other..."]],
                "lettered as Cursor's own card letters them, each question ended by the choice that is typed, as Cursor's is")
        #expect(card.questions.map { $0.choices.map(\.typed) } == [[false, false, true], [false, true]])
        #expect(card.questions.map(\.several) == [false, true], "the database says which question takes several answers")
        #expect(card.choices == ["A apple", "B A new kind of banana", "C Other...", "A red", "B Other..."])
        #expect(card.options.map(\.label) == ["Skip", "Continue"] && card.answerable, "Cursor's own two ways to end the card")
        #expect(card.questions.flatMap(\.choices).allSatisfy { !$0.picked && $0.path.isEmpty }, "nothing of it has a place in a window")
        #expect(card.shownOnly.fromDatabase && card.shownOnly.id == card.id && !card.shownOnly.answerable)
        // Without the permission to press Cursor's card with, it is the same card, shown.
        let shown = CursorQuestions.card(asked, window: "proj", answerable: false)
        #expect(shown.options.isEmpty && !shown.answerable && shown.id == card.id && shown.questions == card.questions)
        // The same question is the same card, and another is another.
        #expect(CursorQuestions.card(asked, window: "proj").id == card.id)
        var other = asked
        other.questions[0].options[0] = "pear"
        #expect(CursorQuestions.card(other, window: "proj").id != card.id)
        // Asked of two chats word for word, it is two cards that ask the same: what is picked on one, or given up
        // on, is not the other's.
        let one = CursorQuestions.card(asked, window: "proj", session: "cursor:c1"), two = CursorQuestions.card(asked, window: "proj", session: "cursor:c2")
        #expect(one.id != two.id && one.questions == two.questions)
        #expect(CursorQuestions.asksTheSame(one, two) && !CursorQuestions.asksTheSame(one, CursorQuestions.card(other, window: "proj", session: "cursor:c2")))
        #expect(CursorQuestions.card(asked, window: "proj", session: "cursor:c1").id == one.id)
        // A question that runs long is cut with a mark, as one read from the window is.
        let long = CursorQuestions.card(CursorAsked(questions: [.init(prompt: String(repeating: "word ", count: 80), allowsSeveral: false, options: ["a"])]), window: "p")
        #expect(long.heading?.hasSuffix("…") == true && (long.heading?.count ?? 0) <= CursorCards.headingLimit + 1)
        // Twenty-six choices leave no letter for the typed one.
        let full = CursorQuestions.card(CursorAsked(questions: [.init(prompt: "Which?", allowsSeveral: false, options: (0..<26).map { "o\($0)" })]), window: "p")
        #expect(full.questions[0].choices.count == 26 && full.questions[0].choices.allSatisfy { !$0.typed })
    }

    @Test func aChoiceCursorsCardLeavesOutIsLeftOutHere() throws {
        // The agent's own "Other" is dropped by Cursor's card for the typed choice it always adds, so the choices
        // after it are lettered one earlier there; lettered as the database lists them, they would not be Cursor's.
        let params = #"{"questions":[{"prompt":"Which typeface?","options":[{"label":"Menlo"},{"label":"Other (say which)"},{"label":"Monaco"},{"label":"other"},{"label":"Other: a serif"},{"label":"Other - none"},{"label":"Otherwise the system's"},{"label":"A wide\n  one"}]}]}"#
        let asked = try #require(CursorQuestions.asked(name: "ask_question", status: "pending", params: params))
        #expect(asked.questions[0].options == ["Menlo", "Monaco", "Otherwise the system's", "A wide one"],
                "and a choice's white space is one space, as Cursor draws running text")
        #expect(CursorQuestions.card(asked, window: "proj").questions[0].choices.map(\.label)
                == ["A Menlo", "B Monaco", "C Otherwise the system's", "D A wide one", "E Other..."])
        #expect(CursorQuestions.leftOut(" OTHER ") && !CursorQuestions.leftOut("Another") && !CursorQuestions.leftOut("Others"))
    }

    @Test func aPickIsMadeOnTheNotchsOwnCardAsCursorsTakesAPress() {
        let card = CursorQuestions.card(CursorAsked(questions: [.init(prompt: "Which fruit?", allowsSeveral: false, options: ["apple", "banana"]),
                                                                .init(prompt: "Which colours?", allowsSeveral: true, options: ["red", "green"])]), window: "proj")
        func picks(_ card: CursorCard) -> [[Bool]] { card.questions.map { $0.choices.map(\.picked) } }
        // One answer: the choice becomes the pick, another takes its place, and pressed again it is no pick.
        var one = CursorQuestions.picking(card, question: 0, choice: 0)
        #expect(picks(one) == [[true, false, false], [false, false, false]])
        one = CursorQuestions.picking(one, question: 0, choice: 1)
        #expect(picks(one)[0] == [false, true, false])
        #expect(picks(CursorQuestions.picking(one, question: 0, choice: 1))[0] == [false, false, false])
        // Several: each is turned over by itself.
        var several = CursorQuestions.picking(one, question: 1, choice: 0)
        several = CursorQuestions.picking(several, question: 1, choice: 1)
        #expect(picks(several) == [[false, true, false], [true, true, false]])
        #expect(picks(CursorQuestions.picking(several, question: 1, choice: 0))[1] == [false, true, false])
        // It is the same card whatever is picked on it, and it can be sent once every question has a pick.
        #expect(several.id == card.id)
        #expect(!card.complete && !one.complete && several.complete)
        // The typed choice is answered in Cursor, and a place the card has not got picks nothing.
        #expect(CursorQuestions.picking(card, question: 0, choice: 2) == card)
        #expect(CursorQuestions.picking(card, question: 2, choice: 0) == card && CursorQuestions.picking(card, question: 0, choice: 9) == card)
    }

    @Test @MainActor func itIsDrawnWithItsChoicesToPickAndCursorsOwnTwoButtons() {
        let asked = CursorAsked(questions: [.init(prompt: "Which fruit?", allowsSeveral: false, options: ["apple", "banana"])])
        var card = CursorQuestions.card(asked, window: "proj")
        #expect(CursorCardView.answersHere(card, hideDetails: false))
        #expect(CursorCardView.offered(card, hideDetails: false).map(\.label) == ["Skip", "Continue"])
        // Continue is held until the question has a pick, as Cursor's own does nothing before then; Skip is not.
        #expect(!CursorCardView.canSend(card) && CursorCardView.held(card.options[1], on: card) && !CursorCardView.held(card.options[0], on: card))
        card = CursorQuestions.picking(card, question: 0, choice: 1)
        #expect(CursorCardView.canSend(card) && !CursorCardView.held(card.options[1], on: card))
        // With its words hidden, or with nothing to press Cursor's card with, it is shown with Answer in Cursor alone.
        #expect(!CursorCardView.answersHere(card, hideDetails: true) && CursorCardView.offered(card, hideDetails: true).isEmpty)
        let shown = CursorQuestions.card(asked, window: "proj", answerable: false)
        #expect(!CursorCardView.answersHere(shown, hideDetails: false) && CursorCardView.offered(shown, hideDetails: false).isEmpty)
        #expect(!CursorCardView.canSend(shown))
        #expect(CursorCardView.listed(card.choices[1]) == "B. banana" && CursorCardView.listed(card.choices[2]) == "C. Other...")
    }

    @Test func aWindowsCardAndTheDatabasesAreOneQuestionWhenTheyOfferTheSame() {
        let database = CursorQuestions.card(CursorAsked(questions: [.init(prompt: "Which `fruit` should **it** be?", allowsSeveral: false, options: ["apple", "banana"])]), window: "proj")
        // Cursor draws the question from Markdown, so the window's words for it are not the database's.
        var window = CursorCard(kind: .question, window: "proj — plan.md", heading: "Which fruit should it be?",
                                options: [.init(label: "Skip", path: [1]), .init(label: "Continue", path: [2])])
        window.choices = ["A apple", "B banana", "C Other..."]
        #expect(CursorQuestions.same(window: window, database: database))
        #expect(CursorQuestions.same(window: window.shownOnly, database: database), "with nothing to press it is the same question still")
        // Lettered one on, as when Cursor's card leaves a choice out, it is the same by what the choices say.
        var shifted = window
        shifted.choices = ["A apple", "C banana", "D Other..."]
        #expect(CursorQuestions.same(window: shifted, database: database))
        var another = window
        another.choices = ["A apple", "B pear", "C Other..."]
        #expect(!CursorQuestions.same(window: another, database: database))
        let asksElse = CursorCard(kind: .question, window: "proj", heading: "Which fruit should it be?", options: [])
        #expect(!CursorQuestions.same(window: asksElse, database: database), "the same words over no choices are not the same question")
        var run = CursorCard(kind: .run, window: "proj", heading: "Which fruit?", options: [])
        run.choices = window.choices
        #expect(!CursorQuestions.same(window: run, database: database))
        #expect(!CursorQuestions.same(window: database, database: database), "two cards from the database are not a window's and a database's")
    }

    func session(_ id: String, tool: ToolID = .cursor, state: AgentSession.State, heard ago: TimeInterval, host: String? = nil) -> AgentSession {
        AgentSession(id: SessionTracker.key(tool: tool, session: id, host: host), tool: tool, project: "proj", state: state,
                     started: t0.addingTimeInterval(-3600), lastEvent: t0.addingTimeInterval(-ago), turnStarted: nil, host: host)
    }

    @Test func aReadIsForChatsThatHaveGoneQuietAndIsNotMadeTooOften() {
        let working = AgentSession.State.working(since: t0.addingTimeInterval(-900))
        let long = CursorQuestions.followWindow + 60
        let sessions = [session("busy", state: working, heard: 1),                 // still sending events
                        session("quiet", state: working, heard: 5),                // gone quiet in a turn
                        session("ended", state: .idle, heard: 30),                 // its turn ended half a minute ago
                        session("left", state: .idle, heard: long),                // ended, and not heard from since
                        session("stuck", state: working, heard: long),             // in a turn, long quiet
                        session("claude", tool: .claude, state: working, heard: 5),
                        session("remote", state: working, heard: 5, host: "other-mac")]
        func ids(shown: Set<String> = [], catchUp: Bool = false, since last: TimeInterval = 100) -> Set<String> {
            Set(CursorQuestions.reads(sessions, shown: shown, catchUp: catchUp, last: t0.addingTimeInterval(-last), now: t0).values)
        }
        #expect(ids() == ["quiet", "ended", "stuck"], "Cursor's own chats on this Mac that have gone quiet: in a turn, or heard from lately")
        // A chat whose question is on its row is asked about however long ago it was heard from, or however lately.
        #expect(ids(shown: [SessionTracker.key(tool: .cursor, session: "left", host: nil)]) == ["quiet", "ended", "stuck", "left"])
        #expect(ids(shown: [SessionTracker.key(tool: .cursor, session: "busy", host: nil)]).contains("busy"))
        // The first read after a spell when nothing could be read is for every chat of Cursor's here.
        #expect(ids(catchUp: true) == ["busy", "quiet", "ended", "left", "stuck"])
        // Not within `readEvery` of the last read.
        #expect(ids(since: CursorQuestions.readEvery - 0.5).isEmpty)
        #expect(!ids(since: CursorQuestions.readEvery).isEmpty)
        // Only for a chat long quiet, a read is made once in `slowEvery`.
        let old = [session("stuck", state: working, heard: long)]
        #expect(CursorQuestions.reads(old, shown: [], catchUp: false, last: t0.addingTimeInterval(-CursorQuestions.readEvery - 1), now: t0).isEmpty)
        #expect(CursorQuestions.reads(old, shown: [], catchUp: false, last: t0.addingTimeInterval(-CursorQuestions.slowEvery), now: t0).count == 1)
        #expect(CursorQuestions.reads([], shown: [], catchUp: true, last: .distantPast, now: t0).isEmpty)
    }

    /// A scratch database with Cursor's tables. Each chat is its header's flag and its steps in order: a message
    /// from the user (`nil` tool, `user: true`), or a step with its tool, its status and its params.
    struct Step {
        var tool: String?
        var status: String?
        var params: String?
        var user = false
        /// Whether the step has a row of its own; a header with none is still a step of the chat.
        var kept = true
    }

    func database(in directory: URL, chats: [(id: String, flag: String, steps: [Step]?)]) throws -> URL {
        let database = directory.appendingPathComponent("state.vscdb")
        var db: OpaquePointer?
        #expect(sqlite3_open(database.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var sql = [
            "CREATE TABLE composerHeaders (composerId TEXT PRIMARY KEY, workspaceId TEXT, createdAt INTEGER, lastUpdatedAt INTEGER, isArchived INTEGER, isSubagent INTEGER, recency INTEGER, checkpointAt INTEGER, value TEXT, subagentTypeName TEXT);",
            "CREATE TABLE cursorDiskKV (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);",
        ]
        func quoted(_ value: Any) -> String {
            String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
        }
        for chat in chats {
            sql.append("INSERT INTO composerHeaders (composerId, value) VALUES ('\(chat.id)', '{\"type\":\"head\",\"name\":\"a chat's name\",\"hasBlockingPendingActions\":\(chat.flag)}');"
                .replacingOccurrences(of: "chat's", with: "chat''s"))
            guard let steps = chat.steps else { continue }
            let headers = steps.enumerated().map { index, step in ["bubbleId": "b\(index)", "type": step.user ? 1 : 2] as [String: Any] }
            sql.append("INSERT INTO cursorDiskKV (key, value) VALUES ('composerData:\(chat.id)', '\(quoted(["composerId": chat.id, "fullConversationHeadersOnly": headers]))');")
            for (index, step) in steps.enumerated() where step.kept {
                var value: [String: Any] = ["type": step.user ? 1 : 2, "text": "words nobody reads"]
                if let tool = step.tool {
                    var former: [String: Any] = ["name": tool, "status": "completed", "params": step.params ?? #"{"command":"a command nobody reads"}"#]
                    if let status = step.status { former["additionalData"] = ["status": status] }
                    value["toolFormerData"] = former
                }
                sql.append("INSERT INTO cursorDiskKV (key, value) VALUES ('bubbleId:\(chat.id):b\(index)', '\(quoted(value))');")
            }
        }
        #expect(sqlite3_exec(db, sql.joined(separator: "\n"), nil, nil, nil) == SQLITE_OK)
        return database
    }

    @Test func theDatabaseIsReadForTheQuestionsThatAreWaiting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-questions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let colours = #"{"questions":[{"id":"c","prompt":"Which colour?","allowMultiple":true,"options":[{"id":"r","label":"red"},{"id":"g","label":"green"}]}]}"#
        let user = Step(user: true), read = Step(tool: "read_file_v2"), words = Step()
        func ask(_ status: String?, _ params: String? = nil) -> Step { Step(tool: "ask_question", status: status, params: params ?? fruit) }
        let database = try database(in: directory, chats: [
            ("asking-1", "true", [user, read, words, ask("pending")]),
            // Answered, with something else of Cursor's blocking the chat since.
            ("answered-2", "true", [user, ask("submitted"), Step(tool: "run_terminal_command_v2")]),
            ("unflagged-3", "false", [user, ask("pending")]),
            ("bare-4", "true", nil),
            // The one waiting now, not the one answered before it, with a step after it (a turn that was stopped).
            ("stopped-5", "true", [user, ask("submitted"), read, ask("pending", colours), words]),
            // Asked before the user's last message: that message answered it, or dropped it.
            ("moved-6", "true", [ask("pending"), user, read]),
            // No status at all on the step is waiting, as Cursor takes it.
            ("plain-7", "true", [user, ask(nil)]),
            // Many steps on from the question, and one of them with no row of its own.
            ("deep-8", "true", [user, ask("pending")] + Array(repeating: read, count: 9) + [Step(kept: false)]),
            // The word "true" is not the flag.
            ("word-9", "\"true\"", [user, ask("pending")]),
        ])
        let ids: Set<String> = ["asking-1", "answered-2", "unflagged-3", "bare-4", "stopped-5", "moved-6", "plain-7", "deep-8", "word-9", "nobody-0", "bad id;"]
        let found = try #require(CursorQuestions.read(ids: ids, database: database))
        #expect(Set(found.keys) == ["asking-1", "stopped-5", "plain-7", "deep-8"])
        #expect(found["asking-1"]?.questions.map(\.prompt) == ["Which fruit?"])
        #expect(found["asking-1"]?.questions.first?.options == ["apple", "banana"])
        #expect(found["stopped-5"]?.questions.map(\.prompt) == ["Which colour?"])
        #expect(found["stopped-5"]?.questions.first?.allowsSeveral == true)
        #expect(CursorQuestions.read(ids: [], database: database) == [:])

        // A database that is not there says nothing of any chat, which is not the same as no question.
        #expect(CursorQuestions.read(ids: ["asking-1"], database: directory.appendingPathComponent("missing.vscdb")) == nil)
        // A Cursor whose database is laid out some other way reads as no question.
        let other = directory.appendingPathComponent("other.vscdb")
        var db: OpaquePointer?
        #expect(sqlite3_open(other.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT, value BLOB);", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        #expect(CursorQuestions.read(ids: ["asking-1"], database: other) == [:])

        // The file itself is never opened: with it locked against every other reader, as Cursor may hold it for
        // a moment, the question is still read, from the copy.
        var holder: OpaquePointer?
        #expect(sqlite3_open(database.path, &holder) == SQLITE_OK)
        defer { sqlite3_close(holder) }
        #expect(sqlite3_exec(holder, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK)
        var direct: OpaquePointer?
        #expect(sqlite3_open_v2(database.path, &direct, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        #expect(sqlite3_exec(direct, "SELECT count(*) FROM composerHeaders", nil, nil, nil) == SQLITE_BUSY, "a reader of the file itself is shut out")
        sqlite3_close(direct)
        #expect(CursorQuestions.read(ids: ["asking-1"], database: database)?.count == 1)
        #expect(sqlite3_exec(holder, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
    }
}

/// The store's side: a question read from the database beside what Cursor's window shows.
@Suite struct CursorQuestionRows {
    let cards = CursorCardStore()
    var t0: Date { cards.t0 }
    let fruit = CursorAsked(questions: [.init(prompt: "Which fruit?", allowsSeveral: false, options: ["apple", "banana"])])

    /// What the stand-in for the database is asked for, and what it answers.
    final class Database: @unchecked Sendable {
        private let lock = NSLock()
        private var _asked: [Set<String>] = []
        private var _waiting: [String: CursorAsked] = [:]
        private var _failing = false
        var asked: [Set<String>] { lock.withLock { _asked } }
        var waiting: [String: CursorAsked] {
            get { lock.withLock { _waiting } }
            set { lock.withLock { _waiting = newValue } }
        }
        /// A database that cannot be read: not there, or not copied.
        var failing: Bool {
            get { lock.withLock { _failing } }
            set { lock.withLock { _failing = newValue } }
        }
        func read(_ ids: Set<String>) -> [String: CursorAsked]? {
            lock.withLock {
                _asked.append(ids)
                return _failing ? nil : _waiting.filter { ids.contains($0.key) }
            }
        }
    }

    /// A window's card for the same question, with its choices to press.
    func window(_ title: String = "proj") -> CursorCard {
        var card = CursorCard(kind: .question, window: title, heading: "Which fruit?",
                              options: [.init(label: "Skip", path: [8]), .init(label: "Continue", path: [9])])
        let labels = ["A apple", "B banana", "C Other..."]
        card.choices = labels
        card.questions = [.init(text: "Which fruit?", choices: labels.enumerated().map { index, label in
            .init(label: label, path: [index], picked: false, typed: index == 2)
        })]
        return card
    }

    @Test @MainActor func aQuestionInTheDatabaseGoesOnItsChatsRowWithTheWindowOutOfReach() async throws {
        let suite = "NotchmeterTests.CursorQuestionRows.row"
        let (store, ui, defaults) = cards.store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = Database()
        store.cursorQuestionReader = { database.read($0) }
        cards.prompt(store, "c1", project: "proj")
        cards.prompt(store, "c2", project: "other", at: 1)
        var opened: [String] = [], closed: [String] = []
        store.cursorCardsChanged = { started, ended in
            opened += started.map(\.id)
            closed += ended
        }

        await store.readCursorQuestions(now: t0.addingTimeInterval(5))
        #expect(database.asked == [["c1", "c2"]], "asked by conversation")
        #expect(store.cursorCards.isEmpty)

        // The window is minimised: nothing of it can be read, and the database says c1 is asking.
        database.waiting = ["c1": fruit]
        await store.readCursorQuestions(now: t0.addingTimeInterval(6))
        #expect(database.asked.count == 1 && store.cursorCards.isEmpty, "not read again within a moment of the last read")
        await store.readCursorQuestions(now: t0.addingTimeInterval(8))
        let shown = try #require(store.cursorCards[cards.key("c1")]?.first)
        #expect(shown.fromDatabase && shown.heading == "Which fruit?" && shown.choices == ["A apple", "B banana", "C Other..."])
        #expect(shown.answerable, "with its choices to pick, wherever the window is")
        #expect(store.cursorCards[cards.key("c2")] == nil)
        #expect(store.sessions.sessions[cards.key("c1")]?.isWaiting == true, "the chat is waiting, and its row says so")
        #expect(opened == [cards.key("c1")], "and the notch is opened on it")
        // Showing it touched nothing of Cursor's window.
        #expect(ui.picks.isEmpty && ui.pressed.isEmpty && ui.answers.isEmpty && store.cursorPressing.isEmpty)

        // Read again and still waiting, nothing changes. A read that fails says nothing, and changes nothing.
        await store.readCursorQuestions(now: t0.addingTimeInterval(11))
        database.failing = true
        await store.readCursorQuestions(now: t0.addingTimeInterval(14))
        #expect(store.cursorCards[cards.key("c1")] == [shown] && opened.count == 1 && closed.isEmpty)
        // Answered in Cursor, the row is let go.
        database.failing = false
        database.waiting = [:]
        await store.readCursorQuestions(now: t0.addingTimeInterval(17))
        #expect(store.cursorCards.isEmpty && closed == [cards.key("c1")])
        #expect(store.sessions.sessions[cards.key("c1")]?.isWorking == true)
    }

    @Test @MainActor func theWindowsCardAndTheDatabasesAreOneWaitAndTheDatabasesIsTheOneShown() async throws {
        let suite = "NotchmeterTests.CursorQuestionRows.window"
        let (store, ui, defaults) = cards.store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = Database()
        store.cursorQuestionReader = { database.read($0) }
        // A read of the window is timed by the clock, so everything here is: the chat's prompt two minutes ago,
        // and each look in the database told when it began.
        store.hookReceived(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "c1", project: "proj", tool: .cursor),
                           now: Date().addingTimeInterval(-120))
        var opened = 0, closed = 0
        store.cursorCardsChanged = { started, ended in
            opened += started.count
            closed += ended.count
        }
        // The window is read first, a moment before the database has the question: its card is what there is.
        let card = window()
        ui.cards = [card]
        await store.readCursorCards()
        #expect(store.cursorCards[cards.key("c1")] == [card])
        // The database has it: its card takes the window's place, as the same wait.
        database.waiting = ["c1": fruit]
        await store.readCursorQuestions(now: Date().addingTimeInterval(-60))
        let held = try #require(store.cursorCards[cards.key("c1")]?.first)
        #expect(held.fromDatabase && store.cursorCards[cards.key("c1")]?.count == 1, "one card for the one question")
        #expect(opened == 1 && closed == 0, "the same wait, not a second one")
        // Whatever the window does from here, the row does not change: read again, minimised, back.
        await store.readCursorCards()
        ui.cards = []
        await store.readCursorCards()
        ui.cards = [card]
        await store.readCursorCards()
        #expect(store.cursorCards[cards.key("c1")] == [held] && opened == 1 && closed == 0)
        #expect(store.sessions.sessions[cards.key("c1")]?.isWaiting == true)
        // A Run card in the same window is still the window's, beside it.
        ui.cards = [card, cards.run("proj")]
        await store.readCursorCards()
        #expect(store.cursorCards[cards.key("c1")]?.map(\.kind) == [.run, .question])
        #expect(store.cursorCards[cards.key("c1")]?.last?.fromDatabase == true)
    }

    @Test @MainActor func aWindowsQuestionThatLeavesIsLookedUpInTheDatabaseAtOnce() async {
        let suite = "NotchmeterTests.CursorQuestionRows.left"
        let (store, ui, defaults) = cards.store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = Database()
        store.cursorQuestionReader = { database.read($0) }
        store.hookReceived(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "c1", project: "proj", tool: .cursor),
                           now: Date().addingTimeInterval(-120))
        await store.readCursorQuestions(now: Date().addingTimeInterval(-60))
        ui.cards = [window()]
        await store.readCursorCards()
        #expect(store.cursorCards[cards.key("c1")]?.first?.fromDatabase == false)
        // Its card goes from the window: answered there, or the window put away. The database is asked which at
        // once, not when its next read would have come round.
        ui.cards = []
        await store.readCursorCards()
        let reads = database.asked.count
        await store.readCursorQuestions(now: Date().addingTimeInterval(-59.5))
        #expect(database.asked.count == reads + 1)
    }

    @Test @MainActor func theDatabaseSaysWhichOfTwoChatsInOneWorkspaceIsAsking() async {
        let suite = "NotchmeterTests.CursorQuestionRows.owner"
        let (store, ui, defaults) = cards.store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = Database()
        store.cursorQuestionReader = { database.read($0) }
        // Two chats in a turn in the same workspace; the one heard from last is not the one asking.
        cards.prompt(store, "c1", project: "proj")
        cards.prompt(store, "c2", project: "proj", at: 3)
        let card = window("plan.md — proj")
        ui.cards = [card]
        await store.readCursorCards()
        #expect(store.cursorCards[cards.key("c2")] == [card], "by its window alone, the card goes to the chat heard from last")

        database.waiting = ["c1": fruit]
        await store.readCursorQuestions(now: t0.addingTimeInterval(10))
        #expect(store.cursorCards[cards.key("c1")]?.map(\.fromDatabase) == [true], "the database names the chat, and the question is on its row")
        #expect(store.cursorCards[cards.key("c2")] == nil, "and on no other: the window's card for it is the same question")
        #expect(store.sessions.sessions[cards.key("c1")]?.isWaiting == true)
        #expect(store.sessions.sessions[cards.key("c2")]?.isWorking == true)
    }

    /// A store with one Cursor chat whose question the database holds, on its row.
    @MainActor
    func asking(_ suite: String, _ question: CursorAsked? = nil) async throws -> (UsageStore, CursorCardStore.FakeCursorUI, UserDefaults, Database, CursorCard) {
        let (store, ui, defaults) = cards.store(suite)
        let database = Database()
        store.cursorQuestionReader = { database.read($0) }
        store.hookReceived(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "c1", project: "proj", tool: .cursor),
                           now: Date().addingTimeInterval(-120))
        database.waiting = ["c1": question ?? fruit]
        await store.readCursorQuestions(now: Date().addingTimeInterval(-60))
        return (store, ui, defaults, database, try #require(store.cursorCards[cards.key("c1")]?.first))
    }

    @Test @MainActor func aChoiceIsPickedOnTheNotchAndNothingOfCursorIsTouchedUntilItIsSent() async throws {
        let suite = "NotchmeterTests.CursorQuestionRows.pick"
        let (store, ui, defaults, _, shown) = try await asking(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        var opened = 0
        store.cursorCardsChanged = { started, _ in opened += started.count }
        // Continue before anything is picked sends nothing: Cursor's own does nothing then.
        store.pressCursorCard(shown, option: "Continue", sessionID: cards.key("c1"))
        #expect(store.cursorPressing.isEmpty)
        store.pickCursorChoice(shown, question: 0, choice: 0, sessionID: cards.key("c1"))
        var card = try #require(store.cursorCards[cards.key("c1")]?.first)
        #expect(card.questions[0].choices.map(\.picked) == [true, false, false] && card.id == shown.id)
        // A question with one answer moves its pick, drawn from the card as it was or as it is.
        store.pickCursorChoice(shown, question: 0, choice: 1, sessionID: cards.key("c1"))
        card = try #require(store.cursorCards[cards.key("c1")]?.first)
        #expect(card.questions[0].choices.map(\.picked) == [false, true, false])
        // The typed choice is answered in Cursor, and is not a pick here.
        store.pickCursorChoice(card, question: 0, choice: 2, sessionID: cards.key("c1"))
        #expect(store.cursorCards[cards.key("c1")]?.first == card)
        // The database read again, the question still waiting: what was picked is kept.
        await store.readCursorQuestions(now: Date().addingTimeInterval(-50))
        #expect(store.cursorCards[cards.key("c1")]?.first == card)
        #expect(opened == 0, "the same card all along, and the notch is not opened on it again")
        try? await Task.sleep(for: .milliseconds(40))
        #expect(ui.picks.isEmpty && ui.pressed.isEmpty && ui.answers.isEmpty, "none of it was a press on Cursor")
        // A pick on another chat's row, or with the mirror off, is nothing.
        store.pickCursorChoice(card, question: 0, choice: 0, sessionID: cards.key("c9"))
        store.prefs.cursorControl = false
        store.pickCursorChoice(card, question: 0, choice: 0, sessionID: cards.key("c1"))
        #expect(store.cursorCards[cards.key("c1")]?.first == card)
    }

    @Test @MainActor func continueSendsWhatWasPickedToCursorsOwnCardAndTheCardLeaves() async throws {
        let suite = "NotchmeterTests.CursorQuestionRows.send"
        let (store, ui, defaults, database, shown) = try await asking(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        var closed = 0
        store.cursorCardsChanged = { _, ended in closed += ended.count }
        // Cursor's window shows the same question, as it does when it is in view.
        ui.cards = [window()]
        await store.readCursorCards()
        store.pickCursorChoice(shown, question: 0, choice: 1, sessionID: cards.key("c1"))
        let picked = try #require(store.cursorCards[cards.key("c1")]?.first)
        store.pressCursorCard(picked, option: "Continue", sessionID: cards.key("c1"))
        #expect(store.cursorPressing == [picked.id], "its buttons are held while Cursor's card is found and pressed")
        store.pressCursorCard(picked, option: "Continue", sessionID: cards.key("c1"))
        await cards.until { store.cursorActionNotes[cards.key("c1")] != nil }
        #expect(ui.answers.count == 1 && ui.answers.first?.skip == false, "sent once")
        #expect(ui.answers.first?.card.questions[0].choices.map(\.picked) == [false, true, false], "with what the notch's card had picked")
        #expect(ui.pressed.isEmpty && ui.picks.isEmpty, "by its words, and not as a button of a card read from the window")
        #expect(store.cursorCards[cards.key("c1")] == nil && closed == 1, "the card leaves with its note")
        #expect(store.cursorActionNotes[cards.key("c1")] == L("Pressed %@ in Cursor", "Continue"))
        #expect(store.cursorPressing.isEmpty)
        #expect(store.sessions.sessions[cards.key("c1")]?.isWorking == true)
        // The window's own card for it does not come back on the row either: not the one read a moment before
        // the answer went, and not one a window that is put away goes on showing after it.
        #expect(store.cursorCards.isEmpty)
        await store.readCursorCards()
        #expect(ui.cards.count == 1 && store.cursorCards.isEmpty)
        #expect(store.sessions.sessions[cards.key("c1")]?.isWorking == true)
        // A look in the database that began before the answer went, or in the moment after it, still says it is
        // waiting, and does not put it back: Cursor writes an answer as it takes it. One begun later, with the
        // question still there, is the truth.
        store.cursorQuestionsSeen([cards.key("c1"): fruit], readAt: Date().addingTimeInterval(-5))
        #expect(store.cursorCards[cards.key("c1")] == nil)
        store.cursorQuestionsSeen([cards.key("c1"): fruit], readAt: Date().addingTimeInterval(1))
        #expect(store.cursorCards[cards.key("c1")] == nil)
        ui.cards = []
        await store.readCursorCards()
        store.cursorQuestionsSeen([cards.key("c1"): fruit], readAt: Date().addingTimeInterval(UsageStore.cursorSentGrace + 2))
        let back = try #require(store.cursorCards[cards.key("c1")]?.first)
        #expect(back.fromDatabase && back.questions[0].choices.allSatisfy { !$0.picked }, "asked again, with nothing picked on it")
        _ = database
    }

    @Test @MainActor func twoChatsAskingTheSameQuestionAreNotAnsweredOnAGuess() async throws {
        let suite = "NotchmeterTests.CursorQuestionRows.twins"
        let (store, ui, defaults) = cards.store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = Database()
        store.cursorQuestionReader = { database.read($0) }
        // The same prompt run in three chats: two in one workspace (two worktrees of a repository are), one in another.
        for (id, project) in [("c1", "atlas"), ("c2", "atlas"), ("c3", "birch")] {
            store.hookReceived(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: id, project: project, tool: .cursor),
                               now: Date().addingTimeInterval(-120))
        }
        database.waiting = ["c1": fruit, "c2": fruit, "c3": fruit]
        await store.readCursorQuestions(now: Date().addingTimeInterval(-60))
        #expect(store.cursorCards.count == 3)

        // c3 has a twin in another workspace: its card is taken only from a window titled for its own.
        let third = try #require(store.cursorCards[cards.key("c3")]?.first)
        store.pressCursorCard(third, option: "Skip", sessionID: cards.key("c3"))
        await cards.until { store.cursorActionNotes[cards.key("c3")] != nil }
        #expect(ui.answers.count == 1 && ui.answers.first?.named == true && ui.answers.first?.card.window == "birch")
        #expect(store.cursorCards[cards.key("c3")] == nil)

        // c1's twin is in the same workspace: nothing in Cursor's windows tells the two cards apart, so nothing
        // is pressed, the row says why, and the question is answered in Cursor.
        let first = try #require(store.cursorCards[cards.key("c1")]?.first)
        store.pickCursorChoice(first, question: 0, choice: 0, sessionID: cards.key("c1"))
        let picked = try #require(store.cursorCards[cards.key("c1")]?.first)
        store.pressCursorCard(picked, option: "Continue", sessionID: cards.key("c1"))
        #expect(store.cursorActionNotes[cards.key("c1")] == L("Another chat is asking the same question; answer it in Cursor"))
        #expect(store.cursorPressing.isEmpty)
        try? await Task.sleep(for: .milliseconds(40))
        #expect(ui.answers.count == 1, "nothing was sent for it")
        #expect(store.cursorCards[cards.key("c1")]?.first?.answerable == false)
        #expect(store.cursorCards[cards.key("c2")]?.first?.answerable == true, "the other chat's is untouched")

        // A chat asking something else with the same choices is no twin: its question is told apart in the window.
        database.waiting = ["c1": fruit, "c2": CursorAsked(questions: [.init(prompt: "Which snack?", allowsSeveral: false, options: ["apple", "banana"])])]
        await store.readCursorQuestions(now: Date().addingTimeInterval(-50))
        let second = try #require(store.cursorCards[cards.key("c2")]?.first)
        store.pressCursorCard(second, option: "Skip", sessionID: cards.key("c2"))
        await cards.until { store.cursorActionNotes[cards.key("c2")] != nil }
        #expect(ui.answers.count == 2 && ui.answers.last?.named == false)
    }

    @Test @MainActor func skipNeedsNoPick() async throws {
        let suite = "NotchmeterTests.CursorQuestionRows.skip"
        let (store, ui, defaults, _, shown) = try await asking(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        store.pressCursorCard(shown, option: "Skip", sessionID: cards.key("c1"))
        await cards.until { store.cursorActionNotes[cards.key("c1")] != nil }
        #expect(ui.answers.count == 1 && ui.answers.first?.skip == true)
        #expect(store.cursorCards[cards.key("c1")] == nil)
        #expect(store.cursorActionNotes[cards.key("c1")] == L("Pressed %@ in Cursor", "Skip"))
    }

    @Test @MainActor func anAnswerThatCouldNotBePutOnCursorsCardSaysSoAndTheQuestionIsThenAnsweredInCursor() async throws {
        for (result, note) in [(CursorPressResult.gone, L("Could not reach this question in Cursor's window; answer it in Cursor")),
                               (.refused, L("Cursor would not take the press; answer it in Cursor")),
                               (.unavailable, L("Cursor or the Accessibility permission is unavailable; nothing was pressed"))] {
            let suite = "NotchmeterTests.CursorQuestionRows.unreached.\(result.rawValue)"
            let (store, ui, defaults, _, shown) = try await asking(suite)
            defer { defaults.removePersistentDomain(forName: suite) }
            var closed = 0
            store.cursorCardsChanged = { _, ended in closed += ended.count }
            ui.answerResult = result
            store.pickCursorChoice(shown, question: 0, choice: 0, sessionID: cards.key("c1"))
            let picked = try #require(store.cursorCards[cards.key("c1")]?.first)
            store.pressCursorCard(picked, option: "Continue", sessionID: cards.key("c1"))
            await cards.until { store.cursorActionNotes[cards.key("c1")] != nil }
            #expect(store.cursorActionNotes[cards.key("c1")] == note)
            // The question is still asked, and is from then on shown with Answer in Cursor: a second try would
            // be made knowing no more than the first.
            let left = try #require(store.cursorCards[cards.key("c1")]?.first)
            #expect(left.id == shown.id && !left.answerable && left.options.isEmpty && closed == 0)
            #expect(!CursorCardView.answersHere(left, hideDetails: false))
            #expect(store.sessions.sessions[cards.key("c1")]?.isWaiting == true)
            store.pressCursorCard(picked, option: "Continue", sessionID: cards.key("c1"))
            store.pickCursorChoice(picked, question: 0, choice: 1, sessionID: cards.key("c1"))
            try? await Task.sleep(for: .milliseconds(40))
            #expect(ui.answers.count == 1 && store.cursorPressing.isEmpty)
            // It stays so while the question does, through reads of the database and of a window with other cards.
            await store.readCursorQuestions(now: Date().addingTimeInterval(-50))
            ui.cards = [cards.run("proj")]
            await store.readCursorCards()
            #expect(store.cursorCards[cards.key("c1")]?.last?.answerable == false)
        }
    }

    @Test @MainActor func aQuestionThatLeftAndIsAskedAgainIsAnsweredFromTheNotchAgain() async throws {
        let suite = "NotchmeterTests.CursorQuestionRows.again"
        let (store, ui, defaults, database, shown) = try await asking(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        ui.answerResult = .gone
        store.pressCursorCard(shown, option: "Skip", sessionID: cards.key("c1"))
        await cards.until { store.cursorActionNotes[cards.key("c1")] != nil }
        #expect(store.cursorCards[cards.key("c1")]?.first?.answerable == false)
        // Answered in Cursor, and later the same question is asked once more: it is a new wait, to be answered here.
        database.waiting = [:]
        await store.readCursorQuestions(now: Date().addingTimeInterval(-40))
        #expect(store.cursorCards.isEmpty)
        database.waiting = ["c1": fruit]
        await store.readCursorQuestions(now: Date().addingTimeInterval(-30))
        #expect(store.cursorCards[cards.key("c1")]?.first?.answerable == true)
    }

    @Test @MainActor func aCardStillShowingAfterContinueIsLookedUpInTheDatabase() async throws {
        // A window that is put away may not show its card gone. The database is where the answer lands.
        let suite = "NotchmeterTests.CursorQuestionRows.settled"
        let (store, ui, defaults, database, shown) = try await asking(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        ui.answerResult = .stillShown
        store.pickCursorChoice(shown, question: 0, choice: 0, sessionID: cards.key("c1"))
        let picked = try #require(store.cursorCards[cards.key("c1")]?.first)
        // Still waiting in the database too: the row says so, and the card stays to be sent again.
        store.pressCursorCard(picked, option: "Continue", sessionID: cards.key("c1"))
        await cards.until { store.cursorActionNotes[cards.key("c1")] != nil }
        #expect(store.cursorActionNotes[cards.key("c1")] == L("Pressed %@, but Cursor's card is still showing", "Continue"))
        #expect(store.cursorCards[cards.key("c1")]?.first == picked && store.cursorPressing.isEmpty)
        // Taken, by the database: the card leaves as one that was seen to go.
        database.waiting = [:]
        store.pressCursorCard(picked, option: "Continue", sessionID: cards.key("c1"))
        await cards.until { store.cursorActionNotes[cards.key("c1")] == L("Pressed %@ in Cursor", "Continue") }
        #expect(store.cursorCards[cards.key("c1")] == nil && ui.answers.count == 2)
    }

    @Test @MainActor func withoutThePermissionAQuestionIsShownAndNotAnswered() async throws {
        let suite = "NotchmeterTests.CursorQuestionRows.untrusted"
        let (store, ui, defaults) = cards.store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        ui.trusted = false
        let database = Database()
        store.cursorQuestionReader = { database.read($0) }
        cards.prompt(store, "c1", project: "proj")
        database.waiting = ["c1": fruit]
        await store.readCursorQuestions(now: t0.addingTimeInterval(8))
        let shown = try #require(store.cursorCards[cards.key("c1")]?.first)
        #expect(shown.fromDatabase && !shown.answerable && shown.choices == ["A apple", "B banana", "C Other..."])
        store.pickCursorChoice(shown, question: 0, choice: 0, sessionID: cards.key("c1"))
        store.pressCursorCard(shown, option: "Skip", sessionID: cards.key("c1"))
        try? await Task.sleep(for: .milliseconds(40))
        #expect(ui.answers.isEmpty && store.cursorCards[cards.key("c1")]?.first == shown)
        // Granted, the next read of the database makes it one to answer here.
        ui.trusted = true
        await store.readCursorQuestions(now: t0.addingTimeInterval(11))
        #expect(store.cursorCards[cards.key("c1")]?.first?.answerable == true)
    }

    @Test @MainActor func aQuestionThatOutlivesItsTurnLeavesTheChatAsItWasWhenItIsAnswered() async {
        let suite = "NotchmeterTests.CursorQuestionRows.idle"
        let (store, _, defaults) = cards.store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = Database()
        store.cursorQuestionReader = { database.read($0) }
        cards.prompt(store, "c1", project: "proj")
        store.hookReceived(Hook.Message(event: "Stop", needsInput: false, sessionID: "c1", project: "proj", tool: .cursor), now: t0.addingTimeInterval(20))
        #expect(store.sessions.sessions[cards.key("c1")]?.state == .idle)

        database.waiting = ["c1": fruit]
        await store.readCursorQuestions(now: t0.addingTimeInterval(25))
        #expect(store.sessions.sessions[cards.key("c1")]?.isWaiting == true, "the turn has ended and the chat is asking all the same")
        database.waiting = [:]
        await store.readCursorQuestions(now: t0.addingTimeInterval(30))
        #expect(store.cursorCards.isEmpty)
        #expect(store.sessions.sessions[cards.key("c1")]?.state == .idle, "answered with no event to say what came next: not in a turn nobody started")
    }

    @Test @MainActor func aQuestionIsKeptThroughALockAndLookedForAfterIt() async {
        let suite = "NotchmeterTests.CursorQuestionRows.gates"
        let (store, _, defaults) = cards.store(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = Database()
        store.cursorQuestionReader = { database.read($0) }
        cards.prompt(store, "c1", project: "proj")
        cards.prompt(store, "c2", project: "other", at: 1)
        store.hookReceived(Hook.Message(event: "Stop", needsInput: false, sessionID: "c2", project: "other", tool: .cursor), now: t0.addingTimeInterval(2))
        // A Claude Code session has no conversation of Cursor's.
        store.hookReceived(Hook.Message(event: "UserPromptSubmit", needsInput: false, sessionID: "claude-1", project: "proj", tool: .claude), now: t0)
        database.waiting = ["c1": fruit]
        await store.readCursorQuestions(now: t0.addingTimeInterval(60))
        #expect(database.asked == [["c1", "c2"]] && store.cursorCards[cards.key("c1")] != nil)

        // Another user at the Mac: nothing is read, and the question that was asked is still asked.
        store.setSessionInactive(true)
        let long = CursorQuestions.followWindow * 3
        await store.readCursorQuestions(now: t0.addingTimeInterval(long))
        #expect(database.asked.count == 1)
        #expect(store.cursorCards[cards.key("c1")] != nil && store.sessions.sessions[cards.key("c1")]?.isWaiting == true)
        // Back, long after either chat was heard from: the first read is for every chat of Cursor's, so a question
        // asked meanwhile on a chat that had ended is found.
        store.setSessionInactive(false)
        database.waiting = ["c1": fruit, "c2": fruit]
        await store.readCursorQuestions(now: t0.addingTimeInterval(long + 5))
        #expect(database.asked.last == ["c1", "c2"])
        #expect(store.cursorCards[cards.key("c2")]?.first?.fromDatabase == true)
        // After it, a chat that ended long ago and is not asking is no longer looked up; one that is asking is.
        database.waiting = ["c1": fruit]
        await store.readCursorQuestions(now: t0.addingTimeInterval(long + 10))
        #expect(store.cursorCards[cards.key("c2")] == nil)
        await store.readCursorQuestions(now: t0.addingTimeInterval(long + 15))
        #expect(database.asked.last == ["c1"])

        // The mirror turned off: nothing is read, and what was shown is taken down.
        let reads = database.asked.count
        store.prefs.cursorControl = false
        await store.readCursorQuestions(now: t0.addingTimeInterval(long + 20))
        #expect(database.asked.count == reads && store.cursorCards.isEmpty)
    }

    @Test @MainActor func continueIsHeldUntilEveryQuestionHasAChoice() {
        var card = window()
        let send = card.options[1], skip = card.options[0]
        #expect(!CursorCardView.canSend(card) && CursorCardView.held(send, on: card))
        #expect(!CursorCardView.held(skip, on: card), "Skip needs no answer")
        card.questions[0].choices[1].picked = true
        #expect(CursorCardView.canSend(card) && !CursorCardView.held(send, on: card))
        // Two questions, one of them answered: Cursor's own Continue does nothing yet, and the notch's is held.
        card.questions.append(.init(text: "Which colour?", choices: [.init(label: "A red", path: [5], picked: false, typed: false)]))
        #expect(!CursorCardView.canSend(card) && CursorCardView.held(send, on: card))
        card.questions[1].choices[0].picked = true
        #expect(CursorCardView.canSend(card))
        // A Run card's buttons are never held this way.
        let run = cards.run("proj")
        #expect(!CursorCardView.held(run.options[1], on: run))
    }
}
