import Foundation

extension Hook {
    /// Gemini CLI's hooks (geminicli.com/docs/hooks/reference) read onto the Message Claude Code's hook fills, and
    /// light the Antigravity ring: the case is HookVendor.antigravity, because the two meter against the same
    /// Google backend and the Antigravity IDE's own hooks file documents no session, prompt or wait event that the
    /// notch could act on, so Gemini CLI's is the hook that ring gets. The names are put onto Claude Code's
    /// vocabulary so the session tracker needs no second grammar: BeforeAgent is documented as "after a user
    /// submits a prompt", so it is the prompt; AfterAgent as "once per turn after the model generates its final
    /// response", so it is the stop; and Notification with notification_type ToolPermission is the CLI's
    /// tool-permission alert, which a hook cannot grant ("Observability Only") — that alert is the one documented
    /// wait, and the only thing that lights the hand. Nothing documents a subagent, a rate limit or a cancelled
    /// turn, so no agent is counted, no limit is planned and no StopFailure is ever emitted for Gemini: a turn
    /// the user cancels ends without the tick when the next signal or the tracker's expiry says so.
    enum Gemini {
        /// Gemini name → canonical name. The three that share Claude Code's spelling map to themselves; the other
        /// two are Gemini's own words for the prompt and the stop.
        static let events: [String: String] = [
            "SessionStart": "SessionStart", "BeforeAgent": "UserPromptSubmit", "AfterAgent": "Stop",
            "Notification": "Notification", "SessionEnd": "SessionEnd",
        ]

        /// The one documented notification type, and the one that lights the hand. Empty this set to turn the wait off.
        static let waitingNotificationTypes: Set<String> = ["ToolPermission"]

        /// Names only Gemini CLI sends; Claude Code and Codex send none of them. SessionStart, SessionEnd and
        /// Notification are left out on purpose: those three are Claude Code's spellings too.
        static let geminiOnlyEvents: Set<String> = [
            "BeforeAgent", "AfterAgent", "BeforeModel", "AfterModel", "BeforeToolSelection", "BeforeTool", "AfterTool", "PreCompress",
        ]

        /// True for a payload only Gemini CLI produces: one of its own event names, the hook environment it
        /// documents giving its hook processes (GEMINI_SESSION_ID), or its documented notification type, which is
        /// UpperCamel where Claude Code's are snake_case. A bare SessionStart or SessionEnd with none of these
        /// reads as Claude's — its payload is byte for byte the shape Claude Code sends — and the installed flag
        /// is what makes those right; this only rescues a payload that arrived on a plain `--hook`.
        static func recognises(event: String, object: [String: Any], environment: [String: String]) -> Bool {
            geminiOnlyEvents.contains(event)
                || environment["GEMINI_SESSION_ID"].map { !$0.isEmpty } == true
                || (event == "Notification" && (object["notification_type"] as? String).map(waitingNotificationTypes.contains) == true)
        }

        /// The five registered names land on Claude Code's; every other name (a tool, model or compression event
        /// that reached us anyway) passes through verbatim for the tracker to ignore.
        static func canonicalEvent(_ event: String) -> String { events[event] ?? event }

        /// The folder the session runs in: `cwd`, which every Gemini event carries, else the environment Gemini
        /// gives its hook processes — never CLAUDE_PROJECT_DIR, which Gemini also sets as a compatibility alias
        /// and Claude Code sets for real, so reading it here would let one assistant's folder name another's.
        static func root(of object: [String: Any], environment: [String: String]) -> String? {
            nonEmpty(object["cwd"]) ?? nonEmpty(environment["GEMINI_CWD"]) ?? nonEmpty(environment["GEMINI_PROJECT_DIR"])
        }

        /// Only the event name, `session_id` (else the GEMINI_SESSION_ID the hook process is given), the root's
        /// basename and `notification_type` are read; the transcript path, timestamp, prompt, response, message,
        /// details, reason, trigger and source are not.
        ///
        /// The notification type rides along only when it is a documented waiting type. `Message.clearsWaiting`
        /// is tool-agnostic and would read a Notification carrying one of Claude Code's completion types as the
        /// end of a wait; keeping every other type nil means no Gemini notice can ever end a permission wait it
        /// does not answer, and a Gemini type is never mistaken for a Claude one. Gemini documents no answer to
        /// the alert, so an approved permission keeps the hand up until the turn ends, the next prompt is sent,
        /// the session ends or the tracker's ten minutes pass — the same exposure Claude Code's hook has.
        static func message(event: String, object: [String: Any], environment: [String: String], branch: (String) -> String?) -> Message {
            let root = root(of: object, environment: environment)
            let waitingType = event == "Notification" ? nonEmpty(object["notification_type"]).flatMap { waitingNotificationTypes.contains($0) ? $0 : nil } : nil
            return Message(event: canonicalEvent(event), needsInput: waitingType != nil,
                           sessionID: nonEmpty(object["session_id"]) ?? nonEmpty(environment["GEMINI_SESSION_ID"]),
                           project: root.flatMap(ProjectName.ofPath),
                           notificationType: waitingType,
                           branch: root.flatMap(branch),
                           permissionMode: nil,
                           agentID: nil,
                           failure: nil,
                           host: nil, tool: .antigravity)
        }

        private static func nonEmpty(_ value: Any?) -> String? {
            (value as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
    }
}
