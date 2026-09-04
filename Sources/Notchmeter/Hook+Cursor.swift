import Foundation

extension Hook {
    /// Cursor's hooks (cursor.com/docs/agent/hooks) read onto the same Message the Claude Code hook fills. The
    /// event name is put onto Claude Code's vocabulary so the session tracker needs no second grammar; the session
    /// is the conversation; the project is the first workspace root's basename; the branch is read from that root.
    /// Cursor has no event that says "waiting for you", so needsInput is always false here — a hand lit on
    /// beforeShellExecution would claim a wait Cursor may never ask for.
    enum Cursor {
        /// Cursor name → canonical name. `stop` depends on `status` and is handled in canonicalEvent.
        static let events: [String: String] = [
            "sessionStart": "SessionStart", "sessionEnd": "SessionEnd", "beforeSubmitPrompt": "UserPromptSubmit",
            "subagentStart": "SubagentStart", "subagentStop": "SubagentStop",
        ]

        /// Every name the reference documents, for recognising a payload that arrived on a plain --hook.
        static let knownEvents: Set<String> = [
            "sessionStart", "sessionEnd", "beforeSubmitPrompt", "stop", "subagentStart", "subagentStop",
            "afterAgentResponse", "afterAgentThought", "beforeShellExecution", "afterShellExecution", "beforeMCPExecution", "afterMCPExecution",
            "preToolUse", "postToolUse", "postToolUseFailure", "beforeReadFile", "afterFileEdit", "preCompact", "beforeTabFileRead", "afterTabFileEdit", "workspaceOpen",
        ]

        /// True when the JSON is shaped the way only Cursor shapes it. Claude Code sends none of these: its ids are
        /// `session_id`, it names no version, and its event names are UpperCamel. This is also what tags Cursor's
        /// third-party replay of `~/.claude/settings.json`, which sends Claude's names with a `conversation_id`.
        static func recognises(event: String, object: [String: Any]) -> Bool {
            object["conversation_id"] != nil || object["cursor_version"] != nil || knownEvents.contains(event)
        }

        /// `stop` is a finish only when Cursor says the agent loop completed; aborted, error, an unknown status or
        /// no status at all end the turn without a tick. An UpperCamel `Stop` (the third-party replay) obeys the same
        /// rule, because inside this parser a stop whose status is not "completed" is not a finish. Every other
        /// name maps to Claude Code's, or passes through verbatim for the tracker to ignore.
        static func canonicalEvent(_ event: String, status: String?) -> String {
            if let canonical = events[event] { return canonical }
            guard event == "stop" || event == "Stop" else { return event }
            return status == "completed" ? "Stop" : "StopFailure"
        }

        /// The folder the conversation runs in: the first non-empty workspace root (a multi-root workspace names its
        /// first), else `cwd` (sent on tool events, not on session, prompt or stop events), else the environment
        /// Cursor gives its hook processes.
        static func root(of object: [String: Any], environment: [String: String]) -> String? {
            (object["workspace_roots"] as? [String])?.first(where: { !$0.isEmpty })
                ?? (object["cwd"] as? String)
                ?? environment["CURSOR_PROJECT_DIR"]
        }

        /// Only the event name, `status`, `parent_conversation_id` (or `conversation_id`, or `session_id`), the
        /// workspace root's basename and `subagent_id` are read; the prompt, attachments, transcript path, email,
        /// model and timings are not.
        ///
        /// The session is the conversation the user is in, so `subagentStart`'s `parent_conversation_id` outranks
        /// the common `conversation_id`: the reference sends both on that event without saying whether the common
        /// one is the parent's or the subagent's own, and keying on the parent is right either way, while keying on
        /// a subagent's own id would open a phantom session per subagent that the card counts and nothing ends.
        static func message(event: String, object: [String: Any], environment: [String: String], branch: (String) -> String?) -> Message {
            let status = object["status"] as? String
            let isStop = event == "stop" || event == "Stop"
            let root = root(of: object, environment: environment)
            let sessionID = nonEmpty(object["parent_conversation_id"]) ?? nonEmpty(object["conversation_id"]) ?? nonEmpty(object["session_id"])
            return Message(event: canonicalEvent(event, status: status), needsInput: false,
                           sessionID: sessionID,
                           project: root.flatMap(ProjectName.ofPath),
                           notificationType: nil,
                           branch: root.flatMap(branch),
                           permissionMode: nil,
                           agentID: nonEmpty(object["subagent_id"]),
                           failure: isStop && status != "completed" ? status : nil,
                           host: nil, tool: .cursor)
        }

        private static func nonEmpty(_ value: Any?) -> String? {
            (value as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
    }
}
