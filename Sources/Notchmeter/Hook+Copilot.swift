import Foundation

extension Hook {
    /// GitHub Copilot CLI's hooks (docs.github.com/en/copilot/reference/hooks-reference) read onto the Message
    /// Claude Code's hook fills. Copilot's camelCase payloads carry no event name — the hook is expected to know
    /// which event it was registered under — so the installer's entries say `--event <name>` and the parser
    /// accepts both the camelCase names it registers and the PascalCase aliases Copilot documents for its "VS Code
    /// compatible" payloads, which do carry `hook_event_name`. The `notification` event with notification_type
    /// permission_prompt ("The agent requests permission to execute a tool") or elicitation_dialog ("The agent
    /// requests additional information from the user") is the wait: both are documented as the agent asking the
    /// user, and permission_prompt fires "only when a prompt is actually shown". permissionRequest is not one — it
    /// fires "before the permission service runs (rules engine, session approvals, auto-allow/auto-deny, and user
    /// prompting)", so it fires for calls that never prompt. Nothing documents a rate limit or a failing stop
    /// (`stopReason` is always end_turn); subagentStart carries no id, so agents are counted, not named.
    enum Copilot {
        /// Copilot name → canonical name, in both spellings the reference documents. subagentStart and
        /// notification exist only in camelCase; the PascalCase aliases are what VS Code's replay would send.
        static let events: [String: String] = [
            "sessionStart": "SessionStart", "SessionStart": "SessionStart",
            "userPromptSubmitted": "UserPromptSubmit", "UserPromptSubmit": "UserPromptSubmit",
            "agentStop": "Stop", "Stop": "Stop",
            "subagentStart": "SubagentStart", "SubagentStart": "SubagentStart",
            "subagentStop": "SubagentStop", "SubagentStop": "SubagentStop",
            "notification": "Notification", "Notification": "Notification",
            "sessionEnd": "SessionEnd", "SessionEnd": "SessionEnd",
        ]

        /// The two notification types the reference documents as the agent asking the user, and the only ones that
        /// light the hand. The other four (shell_completed, shell_detached_completed, agent_completed, agent_idle)
        /// are about background shells and subagents, which the installer's matcher keeps from launching at all.
        static let waitingNotificationTypes: Set<String> = ["permission_prompt", "elicitation_dialog"]

        /// Copilot's camelCase names, every one the reference documents. Six are Copilot's alone (userPromptSubmitted,
        /// userPromptTransformed, agentStop, permissionRequest, errorOccurred, notification) and settle the sender on a
        /// plain `--hook` by themselves; the other eight are Cursor's names too, and Cursor is asked first by name in
        /// Hook.message(from:), so under one of those the sender is settled by the `sessionId` key or not at all.
        static let camelEvents: Set<String> = [
            "sessionStart", "sessionEnd", "userPromptSubmitted", "userPromptTransformed", "preToolUse", "postToolUse", "postToolUseFailure",
            "preCompact", "agentStop", "subagentStart", "subagentStop", "permissionRequest", "errorOccurred", "notification",
        ]

        /// True for the one key that is Copilot's alone: a camelCase `sessionId`, which Claude Code, Codex and Gemini
        /// CLI (`session_id`) and Cursor (`conversation_id`) never send. Hook.message(from:) asks this before it asks
        /// Cursor by name, because a Copilot `sessionStart` or `subagentStart` posted without the `tool` key would
        /// otherwise go to Cursor's parser under Cursor's identical name, which reads none of Copilot's fields and
        /// would key the session `cursor:unknown`.
        static func recognises(object: [String: Any]) -> Bool { object["sessionId"] != nil }

        /// The key, or one of the camelCase names. Asked after Cursor and Gemini CLI, so a name shared with Cursor has
        /// gone to Cursor by the time this runs and only Copilot's own six can still arrive; a shared name without the
        /// key is Cursor's, not Copilot's, and docs/hooks.md says so.
        static func recognises(event: String, object: [String: Any]) -> Bool {
            recognises(object: object) || camelEvents.contains(event)
        }

        /// Maps a documented name in either spelling to Claude Code's vocabulary; anything else (permissionRequest,
        /// errorOccurred, the tool events) passes through verbatim for the tracker to ignore.
        static func canonicalEvent(_ event: String) -> String { events[event] ?? event }

        /// Only the event name, `sessionId` (or `session_id`), the basename of `cwd` and — on a notification that
        /// documents a wait — `notification_type` are read; the timestamp, transcript path, prompt, stop reason,
        /// response, agent name and type, title, message, trace headers, reason and source are not.
        ///
        /// The notification type rides along only when it is one of the two waiting types. `Message.clearsWaiting`
        /// is tool-agnostic and reads Claude Code's completion types (`agent_completed` among them) as the end of a
        /// wait; Copilot's `agent_completed` means a background subagent finished, which answers no permission
        /// prompt, so carrying it would let a subagent end a wait it did not cause. The subagent events use the
        /// common `sessionId`, which the reference gives no parent field beside, so it is read as the parent's;
        /// subagentStop's `agentId` is not read because subagentStart documents none, and an id on the stop with
        /// none on the start would never match — the tracker drops its oldest agent instead, which keeps the count.
        static func message(event: String, object: [String: Any], branch: (String) -> String?) -> Message {
            let canonical = canonicalEvent(event)
            let type = canonical == "Notification" ? nonEmpty(object["notification_type"]).flatMap { waitingNotificationTypes.contains($0) ? $0 : nil } : nil
            let cwd = nonEmpty(object["cwd"])
            return Message(event: canonical, needsInput: type != nil,
                           sessionID: nonEmpty(object["sessionId"]) ?? nonEmpty(object["session_id"]),
                           project: cwd.flatMap(ProjectName.ofPath),
                           notificationType: type,
                           branch: cwd.flatMap(branch),
                           permissionMode: nil,
                           agentID: nil,
                           failure: nil,
                           host: nil, tool: .copilot)
        }

        private static func nonEmpty(_ value: Any?) -> String? {
            (value as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
    }
}
