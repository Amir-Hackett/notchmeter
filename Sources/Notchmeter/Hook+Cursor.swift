import Foundation

extension Hook {
    /// Cursor's hooks (cursor.com/docs/agent/hooks) read onto the same Message the Claude Code hook fills. The
    /// event name is put onto Claude Code's vocabulary so the session tracker needs no second grammar; the session
    /// is the conversation; the project is the first workspace root's name (the repository's when the root is a git
    /// worktree: ProjectName); the branch is read from that root.
    /// Cursor has no event that says "waiting for you", so needsInput is false here — a hand lit on
    /// beforeShellExecution would claim a wait Cursor may never ask for — except on a shell or MCP call held for
    /// the notch under *Require notch approval*, which is waiting on the user by construction.
    enum Cursor {
        /// Cursor name → canonical name. `stop` depends on `status` and is handled in canonicalEvent.
        static let events: [String: String] = [
            "sessionStart": "SessionStart", "sessionEnd": "SessionEnd", "beforeSubmitPrompt": "UserPromptSubmit",
            "subagentStart": "SubagentStart", "subagentStop": "SubagentStop", "preCompact": "PreCompact",
            "postToolUseFailure": "PostToolUseFailure",
        ]

        /// The opening of the prompt Cursor submits when Build is pressed on a plan; nobody types it. Long enough
        /// that a prompt someone did type ("Implement the plan as specified in docs/PLAN.md") is not taken for it.
        static let buildPrompt = "Implement the plan as specified, it is attached for your reference"
        /// `composer_mode` is the chat's own mode id (Cursor 3.23.12 sends its `unifiedMode`): "chat" is the mode
        /// Cursor calls Ask, "background" a cloud agent, "project" and "multitask" a plan built across agents. The
        /// names its documentation has used are kept beside them.
        static let composerModes: Set<String> = ["agent", "chat", "ask", "edit", "plan", "debug", "manual", "background",
                                                 "project", "multitask", "spec", "triage"]
        static let composerModeNames = ["chat": "ask"]

        /// Whether `prompt` is the one Build submits, and the plan's title when the prompt opens with it. Cursor
        /// writes the sentence alone for some builds and "<title>", a blank line, then the sentence for others
        /// (its `_buildPlanExecutionPrompt`, 3.23.12; the second is what its transcript held on 2026-10-03).
        static func build(in prompt: String) -> (isBuild: Bool, title: String?) {
            let lines = prompt.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if lines.first?.hasPrefix(buildPrompt) == true { return (true, nil) }
            if lines.count > 1, lines[1].hasPrefix(buildPrompt) { return (true, lines[0]) }
            return (false, nil)
        }

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
        /// first), else a non-empty `cwd` (sent on tool events, not on session, prompt or stop events), else the environment
        /// Cursor gives its hook processes.
        static func root(of object: [String: Any], environment: [String: String]) -> String? {
            (object["workspace_roots"] as? [String])?.first(where: { !$0.isEmpty })
                ?? (object["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? environment["CURSOR_PROJECT_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        }

        /// Only the event name, `status`, `parent_conversation_id` (or `conversation_id`, or `session_id`), the
        /// workspace root's project name (ProjectName) and `subagent_id` are read, with the prompt's first line, the
        /// model, the transcript path, `composer_mode`, `is_background_agent`, a compaction's trigger and fill, a
        /// failed tool's name, `is_interrupt` and whether its `failure_type` is a denial, the plan file a Build
        /// attaches, `child_conversation_id` on `subagentStop`, and `tool_call_id` and `subagent_model` on
        /// `subagentStart`. Email, timings, a failure's error text, a subagent's task and every tool's input and
        /// output are not.
        ///
        /// The session is the conversation the user is in, so `subagentStart`'s `parent_conversation_id` outranks
        /// the common `conversation_id`: the reference sends both on that event without saying whether the common
        /// one is the parent's or the subagent's own, and keying on the parent is right either way, while keying on
        /// a subagent's own id would open a phantom session per subagent that the card counts and nothing ends.
        /// The subagent's own events are another matter. Cursor runs a subagent as a chat of its own (3.23.23),
        /// and what that chat sends carries its own id and nothing of the chat it works for, so nothing here can
        /// tell it from a chat the user opened: the app does, from Cursor's own record of the chat (CursorSubagents).
        static func message(event: String, object: [String: Any], environment: [String: String], branch: (String) -> String?,
                            requestID: String? = nil, approval: Bool = false) -> Message {
            let status = object["status"] as? String
            let isStop = event == "stop" || event == "Stop"
            let root = root(of: object, environment: environment)
            let sessionID = nonEmpty(object["parent_conversation_id"]) ?? nonEmpty(object["conversation_id"]) ?? nonEmpty(object["session_id"])
            let canonical = canonicalEvent(event, status: status)
            // Only with *Require notch approval* on does a shell or MCP call wait for the notch, and then it does
            // wait on the user: the one case a Cursor event needs input.
            let held: Request? = approval ? requestID.flatMap { Cursor.request(event: event, object: object, id: $0) } : nil
            var message = Message(event: canonical, needsInput: held != nil,
                                  sessionID: sessionID,
                                  project: root.flatMap(ProjectName.ofPath),
                                  notificationType: nil,
                                  branch: root.flatMap(branch),
                                  permissionMode: nil,
                                  agentID: nonEmpty(object["subagent_id"]),
                                  failure: isStop && status != "completed" ? status : nil,
                                  host: nil, tool: .cursor)
            // Since 0.7.0 the prompt's first line rides along on beforeSubmitPrompt as the session's title
            // (Hook.title(fromPrompt:)); the attachments and the rest of the prompt stay unread.
            message.title = canonical == "UserPromptSubmit" ? Hook.title(fromPrompt: object["prompt"]) : nil
            // A Build: the turn is titled with the plan's name, and the plan file is the task list's source. Where
            // the payload attaches no plan file the title the prompt opens with stands in; with neither, the app
            // names the turn from the plan it follows for this chat (UsageStore.hookReceived).
            if canonical == "UserPromptSubmit", let prompt = object["prompt"] as? String, case let build = Cursor.build(in: prompt), build.isBuild {
                message.planBuild = true
                message.planFile = planFile(attachments: object["attachments"], prompt: prompt)
                if let title = buildTitle(planFile: message.planFile) ?? build.title.flatMap({ Hook.title(fromPrompt: "Build: " + $0) }) {
                    message.title = title
                } else {
                    message.title = nil
                    message.harnessTurn = true
                }
            }
            message.background = object["is_background_agent"] as? Bool == true
            // The mode rides on `sessionStart` and on every prompt, and a chat changes it between turns (a plan is
            // made in Plan and built in Agent), so each prompt's is taken.
            if canonical == "SessionStart" || canonical == "UserPromptSubmit" { message.composerMode = Hook.composerMode(object["composer_mode"]) }
            if canonical == "PostToolUseFailure" {
                // A call that was denied, from the notch or in Cursor, comes back as a failure of type
                // `permission_denied` (Cursor 3.23.12). It is an answer, not a try that failed, so it is no step
                // towards "may be stuck", the same as a call the user interrupted.
                let denied = object["failure_type"] as? String == "permission_denied"
                message.toolFailure = Hook.toolName(object["tool_name"]).map {
                    ToolFailure(tool: $0, interrupt: denied || object["is_interrupt"] as? Bool == true)
                }
            }
            // Since 0.9.13: the model, on whichever event names one (cursor.com/docs/agent/hooks shows `model` on the
            // tool events), and a compaction's trigger, its start alone (ToolID.reportsCompactionEnd). Not on the
            // two subagent events: their `model` is the subagent's own where it has one (Cursor 3.23.23), and the
            // chat's row would wear it until the chat's next event said otherwise.
            let ofSubagent = canonical == "SubagentStart" || canonical == "SubagentStop"
            message.reportedModel = ofSubagent ? nil : Hook.reportedModel(object["model"])
            // The chat the subagent ran as, which only the event that ends it names.
            if canonical == "SubagentStop" {
                message.childSessionID = nonEmpty(object["child_conversation_id"]).flatMap { CursorChatNames.isConversationID($0) ? $0 : nil }
            }
            // Since 0.9.22, for the subagent's line on the row: the tool call that started it, which Cursor records
            // the subagent's own chat under, and the model it was given, where the call named one.
            if canonical == "SubagentStart" {
                message.agentCall = Hook.callID(object["tool_call_id"])
                message.agentModel = Hook.reportedModel(object["subagent_model"])
            }
            // The task list's source: Cursor's hooks never fire for its to-do tool, but its transcript records it.
            message.transcriptPath = CursorPlans.transcript(object["transcript_path"] as? String)?.path
            message.request = held
            if canonical == "PreCompact" {
                message.compaction = Hook.compactionTrigger(object["trigger"])
                message.context = (object["context_usage_percent"] as? NSNumber).flatMap { Hook.contextFraction($0.doubleValue / 100) }
            }
            return message
        }

        /// The events whose hook Cursor waits on before it runs the call, and whose flat `permission` it obeys.
        /// They fire for every call, after Cursor's own allowlist, so they are never a sign Cursor itself asked.
        static let decisionEvents: Set<String> = ["beforeShellExecution", "beforeMCPExecution"]
        /// The tool a command runs under, in a request held for the notch and in the failure Cursor reports for a
        /// command that exited with an error, which is the one failure of Cursor's that counts towards a run of
        /// them (SessionTracker.apply, AgentSession.mayBeStuck).
        static let shellTool = "Shell"

        /// *Require notch approval*, read by the hook process from the app's own defaults (Preferences), with the
        /// switches it sits under: *Answer from the notch*, app-wide and on Cursor's page, and Cursor's sessions
        /// being read at all. With any of those off the app would show no card, and a hook that held the call
        /// anyway would hand every command to Cursor's own prompt while the setting looked off.
        static func approvalEnabled(defaults: UserDefaults = .standard) -> Bool {
            func offForCursor(_ key: String) -> Bool { (defaults.array(forKey: key) as? [String] ?? []).contains(ToolID.cursor.rawValue) }
            return defaults.bool(forKey: "cursorRequireApproval")
                && defaults.object(forKey: "answerFromNotch") as? Bool ?? true
                && !offForCursor("answerFromNotchOffTools") && !offForCursor("sessionReadingOffTools")
        }

        /// Whether a payload is one of the two events *Require notch approval* answers, told from its bytes so a
        /// payload that will not parse (cut short at the read limit, late on its pipe) is still known for what it
        /// is. Both names are Cursor's own and appear nowhere else in a payload's keys.
        static func isDecisionEvent(_ payload: Data) -> Bool {
            decisionEvents.contains { payload.range(of: Data("\"\($0)\"".utf8)) != nil }
        }

        /// The Run/Deny request a shell command or MCP call becomes, reduced to a summary and a bounded detail
        /// here in the hook process; the raw command and arguments never reach the app.
        static func request(event: String, object: [String: Any], id: String) -> Request? {
            let cwd = (object["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            switch event {
            case "beforeShellExecution":
                guard let command = object["command"] as? String, !command.isEmpty else { return nil }
                let (summary, detail) = ToolSummary.describe(tool: "Bash", input: ["command": command], cwd: cwd)
                return Request(id: id, kind: .permission(tool: shellTool, summary: summary, detail: detail, suggestions: []))
            case "beforeMCPExecution":
                guard let tool = Hook.toolName(object["tool_name"]) else { return nil }
                let input = (object["tool_input"] as? [String: Any])
                    ?? (object["tool_input"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                    ?? [:]
                let (summary, detail) = ToolSummary.describe(tool: tool, input: input, cwd: cwd)
                return Request(id: id, kind: .permission(tool: tool, summary: summary, detail: detail, suggestions: []))
            default:
                return nil
            }
        }

        /// The plan file a Build attaches, or names in its prompt; only one of Cursor's own (CursorPlanFiles.allowed).
        static func planFile(attachments: Any?, prompt: String, home: URL = Paths.home) -> String? {
            let attached = (attachments as? [[String: Any]] ?? []).compactMap { ($0["file_path"] ?? $0["filePath"] ?? $0["path"]) as? String }
            let named = prompt.split(whereSeparator: { $0.isWhitespace || $0 == "(" || $0 == ")" || $0 == "`" })
                .map(String.init).filter { $0.hasSuffix(".plan.md") }
                .map { $0.hasPrefix("~/") ? home.appendingPathComponent(String($0.dropFirst(2))).path : $0 }
            return (attached + named).lazy.compactMap { CursorPlanFiles.allowed($0, home: home)?.path }.first
        }

        /// "Build: <plan name>", from the plan file's frontmatter; nil when it names none.
        static func buildTitle(planFile: String?) -> String? {
            guard let name = planFile.flatMap({ CursorPlanFiles.call(in: URL(fileURLWithPath: $0))?.name }) else { return nil }
            return Hook.title(fromPrompt: "Build: " + name)
        }

        private static func nonEmpty(_ value: Any?) -> String? {
            (value as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    /// One of Cursor's composer modes, lowercased and under the name Cursor shows for it ("chat" is Ask); nil for
    /// anything else.
    static func composerMode(_ value: Any?) -> String? {
        (value as? String).map { $0.lowercased() }.flatMap { Cursor.composerModes.contains($0) ? Cursor.composerModeNames[$0] ?? $0 : nil }
    }

    /// A fill between 0 and 1; nil for anything outside it or not a number.
    static func contextFraction(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber ?? (value as? Double).map(NSNumber.init(value:)) else { return nil }
        let fraction = number.doubleValue
        return fraction.isFinite && fraction >= 0 && fraction <= 1 ? fraction : nil
    }
}
