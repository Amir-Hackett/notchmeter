import Foundation

extension Hook {
    /// Codex's hooks (learn.chatgpt.com/docs/hooks) read onto the Message Claude Code's hook fills. The names are
    /// Claude Code's already — Codex borrowed the vocabulary wholesale, down to `session_id`, `cwd` and
    /// `permission_mode` — so the map below is the identity everywhere but two places. `Interrupt`, which Claude
    /// Code has no word for, is documented as "when you interrupt an active turn on the main thread" and lands
    /// on `StopFailure` with the failure `interrupted`, so the turn ends without the finished tick and without a
    /// rate-limit alert. And a `UserPromptSubmit` carrying an `agent_id` is a subagent's submission on the parent's
    /// `session_id`, so it goes through under `subagentPromptEvent` rather than restarting the parent's turn.
    ///
    /// `PermissionRequest` is documented as "runs when Codex is about to ask for approval" and "doesn't run for
    /// commands that don't need approval", and is the one wait. Nothing else is: Codex has no `Notification`, no
    /// event for a question, an idle prompt, an elicitation, a rate limit or an errored turn, so none of those is
    /// ever lit or ticked here — a ring asserts only what a documented signal proves. Nothing reports the answer to
    /// the approval either; the hand comes down on the next documented signal (a prompt, a stop, a subagent start,
    /// the session's end) or the tracker's ten-minute timeout, exactly as it does for Claude Code.
    ///
    /// Because the payload is shaped like Claude Code's, nothing recognises it by shape: a Codex payload reaches
    /// this parser only through `--hook --tool codex` on the command line or a `"tool": "codex"` key in a remote
    /// post. One that arrives on a plain `--hook` (Codex's importer can copy the Claude Code entry across) reads as
    /// Claude's, and Repair is what fixes that file.
    enum Codex {
        /// Codex name → canonical name. Everything Codex sends that the tracker acts on keeps its name; `Interrupt`
        /// alone is renamed here (a subagent's `UserPromptSubmit` is renamed in `message`, on its `agent_id`). A name
        /// absent here passes through verbatim for the tracker to ignore.
        static let events: [String: String] = [
            "SessionStart": "SessionStart", "UserPromptSubmit": "UserPromptSubmit", "PermissionRequest": "PermissionRequest",
            "Stop": "Stop", "Interrupt": "StopFailure", "SubagentStart": "SubagentStart", "SubagentStop": "SubagentStop", "SessionEnd": "SessionEnd",
        ]

        static func canonicalEvent(_ event: String) -> String { events[event] ?? event }

        /// The name a subagent's prompt submission passes through under. Codex's `UserPromptSubmit` schema declares an
        /// optional `agent_id`, present when a subagent submits, and `session_id` on every subagent event is the
        /// parent's; read as the parent's `UserPromptSubmit` it would restart the parent's turn clock and wipe a
        /// finished mark mid-turn. The tracker has no case for this name, so the event counts as activity for the
        /// parent and nothing more — the subagent itself is already counted from `SubagentStart`.
        static let subagentPromptEvent = "SubagentPromptSubmit"

        /// Only the event name, `session_id`, the basename of `cwd`, `permission_mode` and `agent_id` are read; the
        /// branch is read from `cwd`'s `.git`. `agent_id` is read on every event, both to name the subagent on
        /// SubagentStart and SubagentStop and to tell a subagent's `UserPromptSubmit` from the user's own. Not read:
        /// `transcript_path`, `model`, `turn_id`, `prompt`, `last_assistant_message`, `stop_hook_active`, `tool_name`,
        /// `tool_input`, `source` and `reason`.
        ///
        /// `source` is left unread on purpose: a `SessionStart` with `source: "compact"` is the same session after
        /// compaction, and the tracker's SessionStart only touches the session's last event, so passing it through
        /// as a SessionStart is right and reading it would only invite a second grammar. `session_id` on a
        /// subagent event is documented as the parent's, so the subagent's start and stop land on the session that
        /// spawned it and `agent_id` names which one — SubagentStop carries it too, unlike Cursor's, so the exact
        /// agent is dropped rather than the oldest. `permission_mode` uses the vocabulary `permissionBadge`
        /// already renders (`default`, `acceptEdits`, `plan`, `dontAsk`, `bypassPermissions`); SessionEnd's
        /// payload does not carry it, and the field is simply nil there.
        static func message(event: String, object: [String: Any], branch: (String) -> String?) -> Message {
            let cwd = nonEmpty(object["cwd"])
            let agentID = nonEmpty(object["agent_id"])
            return Message(event: event == "UserPromptSubmit" && agentID != nil ? subagentPromptEvent : canonicalEvent(event),
                           needsInput: event == "PermissionRequest",
                           sessionID: nonEmpty(object["session_id"]),
                           project: cwd.flatMap(ProjectName.ofPath),
                           notificationType: nil,
                           branch: cwd.flatMap(branch),
                           permissionMode: nonEmpty(object["permission_mode"]),
                           agentID: agentID,
                           failure: event == "Interrupt" ? "interrupted" : nil,
                           host: nil, tool: .codex)
        }

        private static func nonEmpty(_ value: Any?) -> String? {
            (value as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
    }
}
