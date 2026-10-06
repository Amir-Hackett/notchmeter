import Foundation

/// A Cursor subagent's own chat, put on the row of the chat it works for.
///
/// Cursor runs a subagent (its Task tool) as a chat of its own: a conversation with a fresh id that its windows
/// list nowhere, created with a note of the chat that started it (`subagentInfo.parentComposerId`) and saved
/// before the subagent's first step (Cursor 3.23.23, read from its bundle on 2026-10-06). The chat that started
/// it sends `subagentStart` and `subagentStop` under its own id, and those count the subagent on its row
/// (Hook+Cursor.swift). Everything the subagent does in between, a command, a thought, the `stop` that ends its
/// loop, arrives under the subagent's id with nothing of the parent in it. Until 0.9.21 that opened a session per
/// subagent: a second row for the one conversation, named after the task, counted as a session and finished as a
/// turn, while the chat it worked for went quiet and was shown as one that may be waiting.
///
/// Whose chat a conversation is comes from Cursor's state database (the file CursorProvider reads the session
/// token from), through the private copy every read of it takes (CursorProvider.withStateCopy): the chat's row
/// in `composerHeaders`, and for a chat too new to have one, its `composerData:<id>` row in `cursorDiskKV`. Of
/// either, two fields are read and nothing a person wrote: `$.subagentInfo.parentComposerId` and
/// `$.isBestOfNSubcomposer`. The read is for a conversation the hook has just named and the app has not placed,
/// once; that conversation's events wait for it, in order, so a subagent is never given a row to take away
/// again. `subagentStop` names the subagent's chat as well (`child_conversation_id`), which places one the
/// database could not.
enum CursorSubagents {
    /// Where a conversation stands.
    enum Place: Equatable, Sendable {
        /// A chat of its own: one the user opened, or one Cursor's database names no parent for.
        case own
        /// A subagent's, and the conversation it works for.
        case child(of: String)
    }

    /// How far up a subagent's subagents the chat at the top is looked for.
    static let depth = 4
    /// The waits before the database is read again for a conversation it holds nothing of, while a Cursor chat
    /// has a subagent running: Cursor saves a subagent's chat as it creates it, and a read that lands between the
    /// two finds nothing yet. A conversation the database still holds nothing of after them is a chat of its own.
    static let retries: [Duration] = [.milliseconds(250), .milliseconds(500), .seconds(1)]
    /// How many conversations' places are kept before the ones no row needs are let go (`pruned`).
    static let kept = 512
    /// What an event of a subagent's own chat is called on the row of the chat it works for when it says nothing
    /// of that chat's turn: the subagent's loop ending or failing, its chat starting or closing, its own context
    /// being compacted. It counts as activity there and as nothing else.
    static let chatEvent = "SubagentChat"

    /// The chat a record's chat works for, as Cursor itself decides it (the `isSubagent` it keeps beside each
    /// header): the parent its `subagentInfo` names, unless the chat is one of several answers to one prompt,
    /// which Cursor lists as chats.
    private static let worksFor = """
        CASE WHEN json_valid(value) AND json_extract(value, '$.isBestOfNSubcomposer') IS NOT 1 \
        THEN json_extract(value, '$.subagentInfo.parentComposerId') END
        """

    /// The place of each of `ids` the database holds a chat for; one it holds nothing of is absent. Nil when the
    /// database could not be read at all (not there, not copied, not opened), which says nothing of any chat. A
    /// subagent's subagent is placed under the chat at the top, where its row is.
    static func read(ids: Set<String>, database: URL) -> [String: Place]? {
        let ids = ids.filter(CursorChatNames.isConversationID)
        guard !ids.isEmpty else { return [:] }
        guard FileManager.default.fileExists(atPath: database.path) else { return nil }
        return try? CursorProvider.withStateCopy(of: database) { db in
            var places: [String: Place] = [:]
            for id in ids {
                guard var place = record(db, id) else { continue }
                var seen: Set<String> = [id]
                while case .child(let parent) = place, seen.count <= depth, seen.insert(parent).inserted,
                      case .child(let above)? = record(db, parent), !seen.contains(above) {
                    place = .child(of: above)
                }
                places[id] = place
            }
            return places
        }
    }

    /// What the database says of one chat by itself; nil for a chat it holds nothing of. The header where there
    /// is one, a small row, and the chat's whole record only for a chat with no header yet: Cursor writes the
    /// record as it creates the chat and the header a moment later.
    private static func record(_ db: OpaquePointer, _ id: String) -> Place? {
        let found = CursorQuestions.rows(db, "SELECT \(worksFor) FROM composerHeaders WHERE composerId = ?1 LIMIT 1", id).first
            ?? CursorQuestions.rows(db, "SELECT \(worksFor) FROM cursorDiskKV WHERE key = ?1 LIMIT 1", "composerData:" + id).first
        guard let found else { return nil }
        guard let parent = found.first ?? nil, CursorChatNames.isConversationID(parent), parent != id else { return .own }
        return .child(of: parent)
    }

    /// The chat at the top for `id` among the places settled so far: itself for a chat of its own, or for one
    /// not placed.
    static func top(of id: String, in places: [String: Place]) -> String {
        var top = id
        var seen: Set<String> = [id]
        while case .child(let parent)? = places[top], seen.insert(parent).inserted { top = parent }
        return top
    }

    /// `places` less the ones no row needs: kept are the chats in `live` (the conversations on the panel) and
    /// the subagents working for one of them. A conversation let go is asked about again if it speaks.
    static func pruned(_ places: [String: Place], live: Set<String>) -> [String: Place] {
        places.filter { id, place in
            if case .child(let parent) = place { return live.contains(parent) }
            return live.contains(id)
        }
    }

    /// `message`, sent by the subagent's chat `child`, as an event on the row of `parent`. The conversation is
    /// the parent's and the event is the subagent's (`agentID`), so the tracker keeps it off the parent's task
    /// list and counts its failures apart. What describes the subagent's own chat does not cross: its model, its
    /// mode, its prompt's first line, its transcript, a plan and how full its context is. Its lifecycle crosses
    /// as activity only (`chatEvent`, and Codex's name for a subagent's prompt), since the parent's turn neither
    /// starts nor ends with it. A command it runs, a call held for the notch and a failed tool cross as they
    /// are: they are what the conversation is doing. A subagent it starts in turn, or the end of one, is counted
    /// on the same row under that subagent's own id.
    static func folded(_ message: Hook.Message, from child: String, into parent: String) -> Hook.Message {
        let counted = message.event == "SubagentStart" || message.event == "SubagentStop"
        let event: String
        switch message.event {
        case "UserPromptSubmit": event = Hook.Codex.subagentPromptEvent
        case "SessionStart", "SessionEnd", "Stop", "StopFailure", "PreCompact": event = chatEvent
        default: event = message.event
        }
        var folded = Hook.Message(event: event, needsInput: message.needsInput, sessionID: parent, project: message.project,
                                  notificationType: message.notificationType, branch: message.branch,
                                  agentID: counted ? message.agentID : child, host: message.host, tool: message.tool)
        folded.request = message.request
        folded.terminal = message.terminal
        folded.toolFailure = message.toolFailure
        folded.source = message.source
        folded.truncated = message.truncated
        return folded
    }
}
