import Foundation

extension Hook {
    /// Kimi Code's hooks (kimi-cli docs/en/customization/hooks.md and `hooks/events.py`, read 2026-09-24) read onto
    /// the Message Claude Code's hook fills. Kimi borrowed Claude Code's vocabulary: every payload carries
    /// `hook_event_name`, `session_id` and `cwd`, and the seven events registered (HookVendor.kimi.events) keep
    /// Claude Code's names and meanings, so no name is mapped.
    ///
    /// Nothing here lights the waiting hand. Kimi Code has no permission event, and its `Notification` is the
    /// background-task notice it hands the model (`sink: "llm"`, a task or agent `notification_type`), not a wait
    /// on the user, so it is not registered; a Kimi session is working or idle and never shown as waiting on you.
    /// `StopFailure` carries `error_type`, which is the Python exception's class name rather than a documented kind,
    /// so it ends the turn without the finished tick and never claims a rate limit.
    ///
    /// The payload is shaped like Claude Code's, so nothing recognises it by shape: it reaches this parser only
    /// through `--hook --tool kimi` on the command line or a `"tool": "kimi"` key in a remote post, as Codex's does.
    enum Kimi {
        /// The tool Kimi Code keeps its plan with, the whole list per call (kimi-cli `tools/todo/__init__.py`, read at
        /// 1.52.0): `{todos?: [{title, status}]}`, status `pending`, `in_progress` or `done`; called without `todos` it
        /// only reads the list back. The `PostToolUse` table is matched to this name (HookVendor.matcher(for:)),
        /// which Kimi reads as a regular expression on `tool_name`, so no other tool call launches the command.
        static let planTool = "SetTodoList"
        static let planStatuses: [String: TodoPlan.Status] = ["pending": .pending, "in_progress": .inProgress, "done": .completed]

        /// Only the event name, `session_id`, the project name of `cwd` (its folder's, or the repository's for a git
        /// worktree: ProjectName) and, on `UserPromptSubmit`, `prompt` kept as its first line for the session's
        /// title are read; the branch is read from `cwd`'s `.git`. Not read: `source`, `reason`, `stop_hook_active`,
        /// `error_type`, `error_message`, `agent_name`, a subagent's `prompt` and `response`, and every tool field.
        /// `agent_name` is a subagent's type rather than an id, so two agents of one kind would share it; left
        /// unread, the tracker counts each start and drops the oldest at each stop, as it does for Cursor's.
        static func message(event: String, object: [String: Any], branch: (String) -> String?) -> Message {
            let cwd = nonEmpty(object["cwd"])
            var message = Message(event: event, needsInput: false,
                                  sessionID: nonEmpty(object["session_id"]),
                                  project: cwd.flatMap(ProjectName.ofPath),
                                  branch: cwd.flatMap(branch),
                                  tool: .kimi)
            message.title = event == "UserPromptSubmit" ? Hook.title(fromPrompt: object["prompt"]) : nil
            // Since 0.9.13 a compaction's trigger (`manual-with-prompt` is the user's own `/compact` with words), and
            // the plan, on a PostToolUse for SetTodoList that set one; a call without `todos` only read it.
            if event == "PreCompact" || event == "PostCompact" {
                message.compaction = Hook.compactionTrigger((object["trigger"] as? String).map { $0.hasPrefix("manual") ? "manual" : $0 })
            }
            if event == "PostToolUse", object["tool_name"] as? String == planTool {
                message.todos = Hook.plan(from: (object["tool_input"] as? [String: Any])?["todos"], text: "title", statuses: planStatuses)
            }
            return message
        }

        private static func nonEmpty(_ value: Any?) -> String? {
            (value as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
    }
}
