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
/// A question read this way is the one a row shows, and it is answered there (0.9.20). What is asked is known
/// here whatever Cursor's window is doing, so the choices are picked on the notch's own card, as Cursor's card
/// takes a press, and nothing of Cursor is touched until Continue or Skip. Then Cursor's own card is found in
/// its window by the choices' words and pressed where it is (CursorCards.place, CursorUIControlling.answer):
/// Cursor is not brought forward, since having to look at Cursor is what the notch is for sparing. That takes
/// the Accessibility permission, as every press on one of Cursor's cards does; without it the question is shown
/// with *Answer in Cursor*, as it is once an answer could not be put on Cursor's card.
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
    /// What Cursor's card reads on the choice it ends every question with, whose answer is typed.
    static let typedChoice = "Other..."

    /// Whether Cursor's card leaves a choice out. The agent sometimes offers an "Other" of its own, and the card
    /// drops it for the typed choice it always adds, so the choices after it are lettered one earlier there
    /// (Cursor 3.23.23's own rule: the label is "other", or opens with "other:", "other -" or "other (").
    static func leftOut(_ label: String) -> Bool {
        let label = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return label == "other" || ["other:", "other -", "other ("].contains { label.hasPrefix($0) }
    }

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
            // A choice is running text on Cursor's card, so its white space is one space there and here.
            let options = ((question["options"] as? [[String: Any]]) ?? []).compactMap { option in
                (option["label"] as? String)?.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            }.filter { !$0.isEmpty && !leftOut($0) }.prefix(optionLimit)
            // The agent's own word for it is `allow_multiple`; Cursor stores it as `allowMultiple`.
            let several = question["allowMultiple"] as? Bool ?? question["allow_multiple"] as? Bool ?? false
            return CursorAsked.Question(prompt: prompt, allowsSeveral: several, options: Array(options))
        }
        return questions.isEmpty ? nil : CursorAsked(questions: questions)
    }

    /// The card a row shows for a question read from the database: each question with its choices lettered as
    /// Cursor's own card letters them and cut as a card read from the window is, then the choice Cursor's card
    /// ends every question with, whose answer is typed and so given in Cursor; and Cursor's own Skip and
    /// Continue where the card can be answered from the notch (`answerable`: the Accessibility permission is
    /// there to press Cursor's card with). No choice or button of it has a place in a window: a choice is picked
    /// on this card (`picking`), and Cursor's is found when the answers are sent. `session` is the chat it is
    /// on, and part of what makes it this card: two chats can ask the same thing word for word (the same prompt
    /// run in two worktrees does), and what is picked, pressed or given up on one is not the other's.
    static func card(_ asked: CursorAsked, window: String, session: String = "", answerable: Bool = true) -> CursorCard {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var hasher = Hasher()
        hasher.combine(asked)
        hasher.combine(session)
        let questions = asked.questions.map { question in
            var choices = question.options.prefix(letters.count).enumerated().map { index, label in
                CursorCard.Choice(label: CursorCards.choiceLabel("\(letters[index]) \(label)"), path: [], picked: false, typed: false)
            }
            if choices.count < letters.count {
                choices.append(.init(label: "\(letters[choices.count]) \(typedChoice)", path: [], picked: false, typed: true))
            }
            return CursorCard.Question(text: CursorCards.line(question.prompt), choices: choices, several: question.allowsSeveral)
        }
        let ends = answerable ? ["Skip", "Continue"].map { CursorCard.Option(label: $0, path: []) } : []
        var card = CursorCard(kind: .question, window: window, heading: questions.first.flatMap(\.text), options: ends, fingerprint: hasher.finalize())
        card.questions = questions
        card.choices = questions.flatMap { $0.choices.map(\.label) }
        card.fromDatabase = true
        return card
    }

    /// The card with one of its choices turned over, as Cursor's own card takes a press: on a question with one
    /// answer the choice becomes the pick, or stops being it when it was; on one with several it is added to the
    /// picks or taken from them. The choice that is typed is not picked here.
    static func picking(_ card: CursorCard, question: Int, choice: Int) -> CursorCard {
        guard card.questions.indices.contains(question), card.questions[question].choices.indices.contains(choice),
              !card.questions[question].choices[choice].typed else { return card }
        var card = card
        let was = card.questions[question].choices[choice].picked
        if !card.questions[question].several {
            for index in card.questions[question].choices.indices { card.questions[question].choices[index].picked = false }
        }
        card.questions[question].choices[choice].picked = !was
        return card
    }

    /// Whether two questions read from the database could be taken for one another in Cursor's window: the same
    /// choices, under questions whose words mostly agree, either way round (CursorCards.share, the measure a
    /// window's card is held to). That is the same thing asked word for word, as the same prompt run in two
    /// worktrees asks it; and it is two questions a step apart ("Proceed with step 1?", "Proceed with step 2?"),
    /// which the words drawn in a window would not tell apart either.
    static func alike(_ one: CursorCard, _ other: CursorCard) -> Bool {
        guard one.fromDatabase, other.fromDatabase, one.questions.count == other.questions.count,
              one.choices.map(CursorCards.words(ofChoice:)) == other.choices.map(CursorCards.words(ofChoice:)) else { return false }
        return zip(one.questions, other.questions).allSatisfy { mine, theirs in
            guard let mine = mine.text, let theirs = theirs.text else { return true }
            return max(CursorCards.share(of: mine, in: theirs), CursorCards.share(of: theirs, in: mine)) >= CursorCards.questionShare
        }
    }

    /// Whether a card read from Cursor's window and one read from its database are the same question: every
    /// choice the database's question offers is among the window's, by its words (CursorCards.words), and where
    /// the window's card says what it asks, its words hold the database's question (CursorCards.share), so
    /// another chat's question over the same choices is another question. The choice that is typed is on every
    /// question card there is and is evidence of nothing, so it is not counted, and a question that offers no
    /// other is not matched to any window's. Not that the question reads the same: Cursor draws it from
    /// Markdown, so what the window reads is not what the database holds, and 0.9.19, which asked that they be
    /// equal, took the two for different questions. Where they are the same the database's card is the one a
    /// row shows, on the chat the database names.
    static func same(window: CursorCard, database: CursorCard) -> Bool {
        let offered = database.questions.flatMap { $0.choices.filter { !$0.typed }.map { CursorCards.words(ofChoice: $0.label) } }
        guard window.kind == .question, !window.fromDatabase, database.fromDatabase, !offered.isEmpty,
              Set(offered).isSubset(of: Set(window.choices.map(CursorCards.words(ofChoice:)))) else { return false }
        guard let drawn = window.heading, let asked = database.heading else { return true }
        return CursorCards.share(of: asked, in: drawn) >= CursorCards.questionShare
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
