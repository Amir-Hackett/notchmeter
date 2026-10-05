import Foundation
import SQLite3

/// A question Cursor is asking, as Cursor's own state database holds it.
///
/// Cursor's question card is read from its window (CursorAccessibility), and a window can be out of reach: a
/// minimised one, or a hidden Cursor, is not drawn, so its card is not there to read until the window comes back,
/// and nothing reaches the notch meanwhile (reported 2026-10-05). Cursor also keeps the question where its window
/// does not matter. Each chat has a row in `composerHeaders` whose `value` carries `hasBlockingPendingActions`,
/// and each step of a chat is a `bubbleId:<chat>:<bubble>` row of `cursorDiskKV`, listed in order by the chat's
/// `composerData:<chat>` row (`fullConversationHeadersOnly`). A question is a step whose `toolFormerData.name` is
/// `ask_question`: `params` is the question as the agent asked it (`questions`, each with its `prompt`, its
/// `options` of `id` and `label`, and `allowMultiple`), and `additionalData.status` is `pending` until it is
/// answered (`submitted`) or dropped (`cancelled`).
///
/// Checked against two Macs' databases on 2026-10-05 (Cursor 3.23.12): every unanswered question was `pending`
/// in a chat whose header had the flag, and no answered one was. The flag alone is not a wait: it stays set on
/// chats left days ago, with nothing of theirs asking, and Cursor sets it for other things it is blocked on. So
/// a question is a flagged chat with a question step since its last message from the user that is neither
/// `submitted` nor `cancelled`, which is Cursor's own rule for a question awaiting its answer (a step with no
/// status counts as waiting there too), and nothing else in the database is taken for one. A question can
/// outlive the turn that asked it: Cursor's question tool may return at once and leave the question standing, so
/// the chat's turn has ended, by its hooks, while it waits.
///
/// What is read: for the Cursor chats on this Mac that the app is showing and that have gone quiet (CursorQuestions.reads),
/// the header's one flag, and for a flagged chat the kind of each of its last `stepsRead` steps, each step's tool
/// name and status, and of a question step its `params`. Nothing else of any row, and no other chat's. The
/// question's words are the user's work in Cursor's words, so they are held like a card read from the window:
/// in memory, hidden with titles off or the screen shared, and written to no log, oracle fact or notification.
/// The read is of a private copy of the database, as every read of that file is (CursorProvider.withStateCopy),
/// so Cursor's live file is never opened.
///
/// A question read this way is shown and not answered here: there is nothing of Cursor's window in it to press.
/// Its row says the chat is waiting, the notch opens on it, and *Answer in Cursor* brings the window back. When
/// the window can be read again, the card read from it takes this one's place, with its choices to press.
struct CursorAsked: Hashable, Sendable {
    struct Question: Hashable, Sendable {
        var prompt: String
        /// Whether Cursor takes more than one of the choices. The window does not say; the database does.
        var allowsSeveral: Bool
        var options: [String]
    }

    var questions: [Question]
}

enum CursorQuestions {
    /// How many questions of a card and how many choices of a question are kept: Cursor letters a question's
    /// choices, and a card that asks more than this is one to read in Cursor.
    static let questionLimit = 8
    static let optionLimit = 26
    /// How many of a chat's last steps are looked at for its question, back to its last message from the user. A
    /// waiting question is among the last things a chat did; a chat that has done more than this since the user
    /// last wrote is not one to hold up for an old question.
    static let stepsRead = 40
    /// How recently a chat that is not in a turn must have been heard from to be looked up.
    static let followWindow: TimeInterval = 10 * 60
    /// How long a chat has to have been quiet before it is looked up: one that is asking sends no events, and one
    /// that is sending them is working.
    static let quietBefore: TimeInterval = 2
    /// The least time between two reads of the database, and between two that are only for chats long quiet.
    static let readEvery: TimeInterval = 2
    static let slowEvery: TimeInterval = 30
    /// What a question step's status reads once it is no longer waiting.
    static let settled: Set<String> = ["submitted", "cancelled"]

    /// Which chats a read is for, and whether it is due. A chat on this Mac with a conversation of Cursor's that
    /// has been quiet for `quietBefore`, and is either in a turn or was heard from inside `followWindow`; one
    /// whose question is already on its row, so its answer is seen however long it takes; and, on the first read
    /// after a spell when nothing could be read (`catchUp`: the screen locked, another user at the Mac, the app
    /// just started), every Cursor chat there is, since a question asked meanwhile is otherwise never looked for.
    /// A read is due `readEvery` after the last, or `slowEvery` when it is only for chats quiet past the window.
    static func reads(_ sessions: [AgentSession], shown: Set<String>, catchUp: Bool, last: Date, now: Date) -> [String: String] {
        var ids: [String: String] = [:]
        var fresh = catchUp
        for session in sessions {
            guard let id = CursorChatNames.conversationID(of: session) else { continue }
            let quiet = now.timeIntervalSince(session.lastEvent)
            if shown.contains(session.id) || catchUp {
                ids[session.id] = id
                fresh = true
            } else if quiet >= quietBefore, quiet < followWindow || session.isWorking || session.isWaiting {
                ids[session.id] = id
                if quiet < followWindow { fresh = true }
            }
        }
        return now.timeIntervalSince(last) >= (fresh ? readEvery : slowEvery) ? ids : [:]
    }

    /// The question in one step of a chat, when the step is a question still waiting for its answer: the tool's
    /// name, its `additionalData.status` and its `params` as the database holds them. Nil for any other step, an
    /// answered or dropped question, and params that are not a question's. A question step with no status is
    /// waiting, as Cursor takes it to be.
    static func asked(name: String?, status: String?, params: String?) -> CursorAsked? {
        guard name == "ask_question", !settled.contains(status ?? ""), let data = params?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let listed = object["questions"] as? [[String: Any]] else { return nil }
        let questions = listed.prefix(questionLimit).compactMap { question -> CursorAsked.Question? in
            guard let prompt = (question["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else { return nil }
            let options = ((question["options"] as? [[String: Any]]) ?? []).prefix(optionLimit).compactMap { option in
                (option["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            // The agent's own word for it is `allow_multiple`; Cursor stores it as `allowMultiple`.
            let several = question["allowMultiple"] as? Bool ?? question["allow_multiple"] as? Bool ?? false
            return CursorAsked.Question(prompt: prompt, allowsSeveral: several, options: Array(options))
        }
        return questions.isEmpty ? nil : CursorAsked(questions: questions)
    }

    /// The card a row shows for a question read from the database: each question with its choices lettered as
    /// Cursor's own card letters them, cut as a card read from the window is, and nothing to press.
    static func card(_ asked: CursorAsked, window: String) -> CursorCard {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var hasher = Hasher()
        hasher.combine(asked)
        let questions = asked.questions.map { question in
            CursorCard.Question(text: CursorCards.line(question.prompt), choices: question.options.enumerated().map { index, label in
                .init(label: CursorCards.choiceLabel("\(letters[index]) \(label)"), path: [], picked: false, typed: false)
            })
        }
        var card = CursorCard(kind: .question, window: window, heading: questions.first.flatMap(\.text), options: [], fingerprint: hasher.finalize())
        card.questions = questions
        card.choices = questions.flatMap { $0.choices.map(\.label) }
        card.fromDatabase = true
        return card
    }

    /// Whether a card read from Cursor's window and one read from its database are the same question: the same
    /// first question, and every choice the database has among the window's (which adds the one that is typed).
    /// Where they are, the database says which chat is asking, and the window's card goes on that chat's row
    /// whatever its window is called.
    static func same(window: CursorCard, database: CursorCard) -> Bool {
        guard window.kind == .question, !window.fromDatabase, database.fromDatabase, let heading = window.heading, heading == database.heading else { return false }
        return Set(database.choices).isSubset(of: Set(window.choices))
    }

    /// The kind of step that is a message from the user (`fullConversationHeadersOnly[].type`).
    static let userStep = "1"

    /// The question each of `ids` is waiting on, by conversation id; a chat with none is absent. Nil when the
    /// database could not be read at all (not there, not copied, not opened), which says nothing of any chat and
    /// is not taken for no question. A Cursor whose tables are not these, and a chat it does not hold, read as
    /// no question.
    static func read(ids: Set<String>, database: URL) -> [String: CursorAsked]? {
        let ids = ids.filter(CursorChatNames.isConversationID)
        guard !ids.isEmpty else { return [:] }
        guard FileManager.default.fileExists(atPath: database.path) else { return nil }
        return try? CursorProvider.withStateCopy(of: database) { db in
            var found: [String: CursorAsked] = [:]
            for id in ids {
                // The flag and nothing else of the header: the chat's name is in the same row.
                guard rows(db, "SELECT json_extract(value, '$.hasBlockingPendingActions') FROM composerHeaders WHERE composerId = ?1 LIMIT 1", id).first?.first == "1"
                else { continue }
                // The chat's last steps, latest first: each one's kind, its tool and status, and the words of a
                // question step alone.
                let steps = rows(db, """
                    SELECT json_extract(t.value, '$.type'), json_extract(b.value, '$.toolFormerData.name'),
                           json_extract(b.value, '$.toolFormerData.additionalData.status'),
                           CASE WHEN json_extract(b.value, '$.toolFormerData.name') = 'ask_question'
                                THEN json_extract(b.value, '$.toolFormerData.params') END
                    FROM (SELECT x.key AS place, x.value AS value
                          FROM cursorDiskKV d, json_each(json_extract(d.value, '$.fullConversationHeadersOnly')) x
                          WHERE d.key = 'composerData:' || ?1 ORDER BY x.key DESC LIMIT \(stepsRead)) t
                    LEFT JOIN cursorDiskKV b ON b.key = 'bubbleId:' || ?1 || ':' || json_extract(t.value, '$.bubbleId')
                    ORDER BY t.place DESC
                    """, id)
                // Back to the user's last message: a question from before it was answered by it, or dropped.
                for step in steps where step.count == 4 {
                    if step[0] == userStep { break }
                    if let asked = asked(name: step[1], status: step[2], params: step[3]) {
                        found[id] = asked
                        break
                    }
                }
            }
            return found
        }
    }

    /// Every row of a statement with one bound text parameter, each column as text or nil. No rows for a
    /// statement that does not prepare: a Cursor whose database has no such table or column.
    private static func rows(_ db: OpaquePointer, _ sql: String, _ parameter: String) -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, parameter, -1, transient)
        var found: [[String?]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            found.append((0..<sqlite3_column_count(statement)).map { CursorProvider.columnText(statement, $0) })
        }
        return found
    }
}
