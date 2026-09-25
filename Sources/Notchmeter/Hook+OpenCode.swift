import Foundation

extension Hook {
    /// OpenCode's plugin (OpenCodePlugin.swift) read onto the Message Claude Code's hook fills. The plugin forwards
    /// OpenCode's own bus events under their own dotted names (opencode.ai/docs/plugins, and the event schemas in
    /// anomalyco/opencode `packages/schema`, read 2026-09-24), with the parent's session id and the child's as
    /// `agent_id` for a subagent's session, and the names are put onto Claude Code's vocabulary here:
    ///
    /// - `session.created` is a SessionStart, or a SubagentStart on the parent for a subagent's session;
    /// - `chat.message`, the plugin hook OpenCode runs as a prompt arrives, is the prompt, with its first line as the
    ///   session's title; `session.status` busy, which the plugin sends only when no prompt started the turn, is too;
    /// - `session.idle` (or `session.status` idle) is the stop, a SubagentStop for a subagent's session;
    /// - `session.error` ends the turn without a finish, as `aborted` when the user stopped it and `rate_limit` on a
    ///   429, so a limit hit is planned as Claude Code's is;
    /// - `permission.asked` is the one wait: OpenCode is holding the tool call for the user;
    /// - `permission.replied` ends that wait, which OpenCode, unlike Claude Code, reports, so the hand comes down
    ///   the moment the user answers in the terminal rather than at the turn's end;
    /// - `session.deleted` ends the session.
    ///
    /// Nothing is answered from here: the plugin observes permissions and never replies to them, so OpenCode's
    /// entry has no deciding events (HookVendor.decidingEvents).
    enum OpenCode {
        /// The notification type the tracker ends a wait on for `permission.replied` (Hook.completionNotificationTypes).
        static let permissionReplied = "permission_replied"

        /// Every name the plugin sends is dotted, which no other assistant's event name is, so a payload that reached
        /// a plain `--hook` is still recognised.
        static func recognises(event: String) -> Bool {
            event.contains(".") && OpenCodePlugin.events.contains(event)
        }

        /// Only the event name, `session_id`, `agent_id`, the project name of `cwd` (its folder's, or the
        /// repository's for a git worktree: ProjectName), `status`, `error` and `status_code` on a failure, and
        /// `prompt` on `chat.message` (kept as its first line, Hook.title(fromPrompt:)) are read. The plugin sends
        /// nothing else: not the permission's patterns or metadata, not the model, not the reply.
        static func message(event: String, object: [String: Any], branch: (String) -> String?) -> Message {
            let cwd = nonEmpty(object["cwd"])
            let agent = nonEmpty(object["agent_id"])
            let status = nonEmpty(object["status"])
            var failure: String?
            var type: String?
            var needsInput = false
            let canonical: String
            switch event {
            case "session.created":
                canonical = agent == nil ? "SessionStart" : "SubagentStart"
            case "chat.message":
                canonical = agent == nil ? "UserPromptSubmit" : event
            case "session.status" where status == "busy":
                canonical = agent == nil ? "UserPromptSubmit" : event
            case "session.status" where status == "idle":
                canonical = agent == nil ? "Stop" : "SubagentStop"
            case "session.idle":
                canonical = agent == nil ? "Stop" : "SubagentStop"
            case "session.error":
                canonical = agent == nil ? "StopFailure" : "SubagentStop"
                failure = agent == nil ? self.failure(name: nonEmpty(object["error"]), status: JSON.number(object["status_code"])) : nil
            case "session.deleted":
                canonical = agent == nil ? "SessionEnd" : "SubagentStop"
            case "permission.asked":
                canonical = "Notification"
                type = "permission_prompt"
                needsInput = true
            case "permission.replied":
                canonical = "Notification"
                type = permissionReplied
            default:
                canonical = event
            }
            var message = Message(event: canonical, needsInput: needsInput,
                                  sessionID: nonEmpty(object["session_id"]),
                                  project: cwd.flatMap(ProjectName.ofPath),
                                  notificationType: type,
                                  branch: cwd.flatMap(branch),
                                  permissionMode: nil,
                                  agentID: agent,
                                  failure: failure,
                                  host: nil, tool: .opencode)
            message.title = canonical == "UserPromptSubmit" ? Hook.title(fromPrompt: object["prompt"]) : nil
            return message
        }

        /// A failed turn's kind: `MessageAbortedError` is the user's own stop, a 429 is the limit, anything else an
        /// error.
        static func failure(name: String?, status: Double?) -> String {
            if name == "MessageAbortedError" { return "aborted" }
            if status == 429 { return "rate_limit" }
            return "error"
        }

        private static func nonEmpty(_ value: Any?) -> String? {
            (value as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
    }
}
