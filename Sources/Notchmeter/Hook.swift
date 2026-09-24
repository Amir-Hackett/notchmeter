import Foundation

/// The `--hook` half of the assistant integrations: a hook command that turns one Claude Code, Codex, Cursor,
/// Gemini CLI or GitHub Copilot event into one line on the running app's socket carrying the event name, whether the
/// assistant is waiting on the user, the session id, the folder name of the working directory (or of the
/// repository, when the working directory is a git worktree: ProjectName in ProviderCost.swift), the git branch
/// checked out there, the permission mode, the subagent id, a stop failure's kind and — only when it is not
/// Claude Code — which assistant sent it. Since 0.7.0 three more things ride along, each documented in
/// docs/hooks.md and each bounded here: on a prompt, the prompt's first line as a title for the session; on a
/// permission request or a question, a display summary of what the assistant wants (never the raw tool input:
/// Hook+Decision.swift), with a nonce the app's answer is addressed to; and on every event, where the hook's own
/// terminal is, read from the hook process's environment and ancestry (TerminalIdentity.swift). Nothing else.
/// Claude Code's command sends no tool; every other installer sends `--tool <id>` and each ToolID has a parser of
/// its own (Hook+Codex.swift, Hook+Cursor.swift, Hook+Gemini.swift, Hook+Copilot.swift); failing the flag, a
/// payload whose shape only one vendor produces is recognised by it. The running app listens in UsageStore, over
/// the socket HookSocket.swift describes (until 0.6.0 it was a distributed notification, which any local process
/// could read or forge); a remote host's hook posts the same fields to the local API instead (docs/hooks.md).
///
/// A request that awaits a decision is the one case where the command does not fire and forget: it holds the
/// socket open until the app writes its answer back (or hangs up without one), and prints the vendor's decision
/// JSON when there is one (`Hook.Answer`). Everything else about the command is unchanged, and so is its
/// fail-open guarantee: no app, a refusal, a hold that ran out or any error prints nothing and exits 0, and the
/// terminal asks as it always has.
enum Hook {
    static let eventKey = "hook_event_name"
    static let needsInputKey = "needsInput"
    static let sessionKey = "session_id"
    static let projectKey = "project"
    static let typeKey = "notification_type"
    static let branchKey = "branch"
    static let permissionKey = "permission_mode"
    static let agentKey = "agent_id"
    static let failureKey = "failure"
    static let hostKey = "host"
    /// Which assistant sent the event. Claude Code's hook does not send it and does not need to — the fallback is
    /// Claude — but every other installer's command carries `--tool <id>` and a remote post may name one, and
    /// this is the field that lets the app tell them apart.
    static let toolKey = "tool"
    /// The prompt's first line, on `UserPromptSubmit` only (`title(fromPrompt:)`).
    static let titleKey = "title"
    /// The request keys, present together on a deciding event and absent otherwise.
    static let awaitsDecisionKey = "awaitsDecision"
    static let requestIDKey = "requestID"
    static let toolNameKey = "toolName"
    static let toolSummaryKey = "toolSummary"
    static let toolDetailKey = "toolDetail"
    static let suggestionsKey = "suggestions"
    static let questionsKey = "questions"
    /// The terminal keys, each written only when the hook could read it (TerminalIdentity.swift).
    static let terminalProgramKey = "terminal_program"
    static let terminalBundleKey = "terminal_bundle"
    static let terminalTTYKey = "terminal_tty"
    static let terminalSessionKey = "terminal_session"
    static let terminalFocusURLKey = "terminal_focus_url"
    static let terminalTmuxKey = "terminal_tmux"
    static let terminalTmuxPaneKey = "terminal_tmux_pane"
    static let terminalKittySocketKey = "terminal_kitty_socket"
    static let terminalGhosttyKey = "terminal_ghostty"
    static let terminalWorkspaceKey = "terminal_workspace"

    /// How long the command waits for the app's answer to a deciding event. The app's own hold
    /// (Preferences.promptHoldSeconds, two minutes by default) is what ends the wait in practice; this is the
    /// socket's ceiling, matched by the `timeout` the deciding entries carry, so the vendor never cancels the
    /// command before the socket gives up on its own.
    static let decisionWait: TimeInterval = 600

    /// What the hook carries for an event the assistant is holding the session on. `id` is a nonce the command
    /// generates per request; the app answers only a request it is showing under that id, and only from its own
    /// UI, so a line forged onto the socket can start a request but never settle one.
    struct Request: Equatable, Sendable {
        let id: String
        let kind: PendingRequest.Kind

        init(id: String, kind: PendingRequest.Kind) {
            self.id = id
            self.kind = kind
        }
    }

    struct Message: Equatable, Sendable {
        let event: String
        let needsInput: Bool
        let sessionID: String?
        /// The folder name of `cwd`, or of the repository when `cwd` is a git worktree (ProjectName); never the path.
        let project: String?
        let notificationType: String?
        /// Whether a wait this message begins has stopped the session, as against merely reporting that the user
        /// has gone quiet. Anything without a type counts as blocking: no vendor but Claude Code reports an idle
        /// nudge at all, so a wait with nothing to say for itself is one that is holding.
        var blocksSession: Bool { notificationType != Hook.idleNotificationType }
        /// What a wait this message begins is asking for (`Hook.waitKind`). Read before the store drops a request
        /// the notch will not answer, since the request is where a plan tells itself apart from a permission.
        var waitKind: Hook.WaitKind { Hook.waitKind(event: event, notificationType: notificationType, request: request) }

        /// The branch checked out in `cwd`, when it is a git checkout.
        let branch: String?
        /// `permission_mode`: default, plan, acceptEdits, auto, dontAsk, bypassPermissions.
        let permissionMode: String?
        /// `agent_id` on SubagentStart and SubagentStop.
        let agentID: String?
        /// A StopFailure's kind: rate_limit, overloaded, billing_error, account_on_hold. For Cursor, a `stop`'s
        /// status when it is not completed: aborted, error. For Codex, `interrupted` when the user interrupted
        /// the turn.
        let failure: String?
        /// A label for the machine a remote hook posted from; nil for this Mac.
        let host: String?
        /// Which assistant the event came from. Claude Code's hook sends nothing here and is read as Claude, which
        /// is why adding this field changes nothing about the events the app receives today; Cursor's names itself
        /// on the command line, or is recognised by the shape of its payload.
        let tool: ToolID
        /// The prompt's first line on `UserPromptSubmit` (`Hook.title(fromPrompt:)`); nil on every other event, and
        /// dropped by the store when *Show what a session is working on* is off.
        var title: String?
        /// A decision the assistant is holding the session for; the command waits on the socket while it is set.
        var request: Request?
        /// Where the hook process's terminal is; absent for a remote post, whose terminal is on another machine.
        var terminal: TerminalRef?

        /// Whether the command holds the socket for the app's answer.
        var awaitsDecision: Bool { request != nil }

        init(event: String, needsInput: Bool, sessionID: String? = nil, project: String? = nil, notificationType: String? = nil, branch: String? = nil,
             permissionMode: String? = nil, agentID: String? = nil, failure: String? = nil, host: String? = nil, tool: ToolID = .claude) {
            self.event = event
            self.needsInput = needsInput
            self.sessionID = sessionID
            self.project = project
            self.notificationType = notificationType
            self.branch = branch
            self.permissionMode = permissionMode
            self.agentID = agentID
            self.failure = failure
            self.host = host
            self.tool = tool
        }

        init?(userInfo: [AnyHashable: Any]?) {
            guard let event = userInfo?[Hook.eventKey] as? String, !event.isEmpty else { return nil }
            self.event = event
            needsInput = (userInfo?[Hook.needsInputKey] as? Bool) ?? false
            sessionID = userInfo?[Hook.sessionKey] as? String
            project = userInfo?[Hook.projectKey] as? String
            notificationType = userInfo?[Hook.typeKey] as? String
            branch = userInfo?[Hook.branchKey] as? String
            permissionMode = userInfo?[Hook.permissionKey] as? String
            agentID = userInfo?[Hook.agentKey] as? String
            failure = userInfo?[Hook.failureKey] as? String
            host = userInfo?[Hook.hostKey] as? String
            tool = (userInfo?[Hook.toolKey] as? String).flatMap(ToolID.init(rawValue:)) ?? .claude
            title = (userInfo?[Hook.titleKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
            request = Hook.request(userInfo: userInfo)
            terminal = Hook.terminal(userInfo: userInfo)
        }

        var userInfo: [String: Any] {
            var info: [String: Any] = [Hook.eventKey: event, Hook.needsInputKey: needsInput]
            if let sessionID { info[Hook.sessionKey] = sessionID }
            if let project { info[Hook.projectKey] = project }
            if let notificationType { info[Hook.typeKey] = notificationType }
            if let branch { info[Hook.branchKey] = branch }
            if let permissionMode { info[Hook.permissionKey] = permissionMode }
            if let agentID { info[Hook.agentKey] = agentID }
            if let failure { info[Hook.failureKey] = failure }
            if let host { info[Hook.hostKey] = host }
            // Claude Code's own hook sends no tool and is read back as Claude, so the key is written only when it
            // would say something: Claude Code's payload stays exactly what it has always been, and Cursor's says
            // `cursor`.
            if tool != .claude { info[Hook.toolKey] = tool.rawValue }
            // The same rule for everything 0.7.0 added: an absent field writes no key, so an event that carries
            // none of them is byte for byte the line it was.
            if let title { info[Hook.titleKey] = title }
            if let request { info.merge(Hook.userInfo(request: request)) { _, new in new } }
            if let terminal { info.merge(Hook.userInfo(terminal: terminal)) { _, new in new } }
            return info
        }

        /// A notification that says the agent no longer needs the user: it finished, or the elicitation was answered.
        var clearsWaiting: Bool {
            Hook.clearingEvents.contains(event) || (event == "Notification" && notificationType.map(Hook.completionNotificationTypes.contains) == true)
        }

        /// Claude Code's own wait for quota: it is holding the session until the window resets.
        var waitsOnQuota: Bool {
            event == "Notification" && notificationType.map(Hook.quotaWaitNotificationTypes.contains) == true
        }

        /// Claude Code resumed by itself after its quota wait.
        var resumesFromQuota: Bool {
            event == "Notification" && notificationType == "quota_auto_resume_fired"
        }

        /// The session stopped because the limit was hit.
        var hitRateLimit: Bool {
            event == "StopFailure" && failure == "rate_limit"
        }
    }

    /// Events after which Claude is no longer waiting on the user.
    static let clearingEvents: Set<String> = ["Stop", "SessionEnd", "UserPromptSubmit", "StopFailure"]

    /// Notification types that mean Claude Code is waiting for the user, per the hooks reference.
    static let waitingNotificationTypes: Set<String> = ["permission_prompt", "idle_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"]

    /// The one waiting type that does not block: `idle_prompt` says the user has gone quiet, not that Claude
    /// cannot go on without them. Every other waiting type any vendor reports — a permission prompt, an
    /// elicitation, an agent asking — means the session has stopped until it is answered. The difference decides
    /// whether a wait is worth a banner over a frontmost terminal, because only a stopped session costs anything
    /// by going unseen.
    static let idleNotificationType = "idle_prompt"

    /// Notification types that end a wait without a Stop: a subagent finished, the elicitation was answered, or
    /// Claude Code's own quota wait ended.
    static let completionNotificationTypes: Set<String> = ["agent_completed", "elicitation_complete", "elicitation_response", "quota_auto_resume_fired"]

    /// Claude Code is holding the session for a quota reset it will not resume from on its own.
    static let quotaWaitNotificationTypes: Set<String> = ["quota_auto_resume_stale", "quota_auto_resume_disabled"]

    /// The permission modes worth a badge; `default` and `acceptEdits` are the ordinary ones and get none.
    static func permissionBadge(_ mode: String?) -> String? {
        switch mode {
        case "bypassPermissions": L("bypass")
        case "auto": L("auto")
        case "plan": L("plan")
        case "dontAsk": L("don't ask")
        default: nil
        }
    }

    /// `--tool <id>` on the hook command line; nil when absent or not a ToolID (an unknown value is ignored, not an
    /// error, so a mistyped entry still posts the event as Claude's rather than dropping it).
    static func tool(in arguments: [String]) -> ToolID? {
        guard let index = arguments.firstIndex(of: "--tool"), index + 1 < arguments.count else { return nil }
        return ToolID(rawValue: arguments[index + 1])
    }

    /// `--event <name>` on the hook command line: the event a Copilot entry was registered under, because Copilot's
    /// camelCase payload does not say. nil when absent or dangling.
    static func event(in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--event"), index + 1 < arguments.count, !arguments[index + 1].isEmpty else { return nil }
        return arguments[index + 1]
    }

    /// Reads one hook payload onto a Message. The sender is settled before any field is read: the `--tool` flag
    /// first, then a `"tool"` key in the JSON (what a remote post carries), then the shape of the payload, and
    /// Claude Code otherwise. The shape is asked in a fixed order: Copilot's camelCase `sessionId` first, a key no
    /// other assistant sends, because eight of Copilot's camelCase names (`sessionStart`, `sessionEnd`,
    /// `subagentStart`, `subagentStop`, `preToolUse`, `postToolUse`, `postToolUseFailure`, `preCompact`) are Cursor's
    /// too; then Cursor's `conversation_id`, `cursor_version` or one of its own event names; then Gemini CLI's own
    /// names, its hook environment or its documented notification type; then a name only Copilot documents. So a
    /// shared camelCase name with no `sessionId` reads as Cursor's, and docs/hooks.md says so. Codex's payload is
    /// shaped like Claude Code's, so nothing recognises it without the flag or the key. The payload's `hook_event_name`
    /// outranks the `--event` argument (the vendor's own word over ours); the argument only fills a payload that
    /// has none. Each parser reads only the fields docs/hooks.md lists; the branch is read from the working
    /// directory's `.git`.
    static func message(from payload: Data, tool: ToolID? = nil, event argumentEvent: String? = nil,
                        environment: [String: String] = ProcessInfo.processInfo.environment,
                        branch: (String) -> String? = gitBranch(cwd:), requestID: String = UUID().uuidString) -> Message? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let event = (object[eventKey] as? String).flatMap({ $0.isEmpty ? nil : $0 }) ?? argumentEvent
        else { return nil }
        let claimed = tool ?? (object[toolKey] as? String).flatMap(ToolID.init(rawValue:))
        let vendor: HookVendor = claimed.flatMap(HookVendor.vendor(for:))
            ?? (Copilot.recognises(object: object) ? .copilot
                : Cursor.recognises(event: event, object: object) ? .cursor
                : Gemini.recognises(event: event, object: object, environment: environment) ? .antigravity
                : Copilot.recognises(event: event, object: object) ? .copilot
                : .claude)
        return switch vendor {
        case .claude: Claude.message(event: event, object: object, tool: claimed ?? .claude, branch: branch, requestID: requestID)
        case .codex: Codex.message(event: event, object: object, branch: branch, requestID: requestID)
        case .cursor: Cursor.message(event: event, object: object, environment: environment, branch: branch)
        case .antigravity: Gemini.message(event: event, object: object, environment: environment, branch: branch)
        case .copilot: Copilot.message(event: event, object: object, branch: branch, requestID: requestID)
        }
    }

    /// Claude Code's payload (docs/hooks.md). `needsInput(event:notificationType:)` is Claude Code's vocabulary
    /// and is called only from here; the other parsers derive the wait from their own documented signal.
    enum Claude {
        /// Only the event name, the notification type, the session id, the folder name of `cwd` (or of the repository
        /// when `cwd` is a git worktree: ProjectName), the permission mode, the agent id and a stop failure's kind
        /// are read from the payload; the branch is read from `cwd`'s `.git`. Since 0.7.0 also: `prompt` on
        /// `UserPromptSubmit`, kept as its first line; and on `PermissionRequest` `tool_name`, `tool_input` and
        /// `permission_suggestions`, and on a `PreToolUse` for `AskUserQuestion` the `questions`, each reduced to
        /// the display summary Hook+Decision.swift describes before it leaves the process.
        /// Claude Code names no tool, so its events read as Claude's, which is what they have always been.
        static func message(event: String, object: [String: Any], tool: ToolID, branch: (String) -> String?, requestID: String) -> Message {
            let type = object["notification_type"] as? String
            let cwd = object["cwd"] as? String
            let failure = (object["error"] as? String) ?? (object["error_type"] as? String) ?? ((object["error"] as? [String: Any])?["type"] as? String)
            let request = Hook.request(event: event, object: object, id: requestID)
            var message = Message(event: event, needsInput: needsInput(event: event, notificationType: type) || request != nil,
                                  sessionID: (object["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                  project: cwd.flatMap(ClaudeCostScanner.projectName(fromPath:)),
                                  notificationType: type,
                                  branch: cwd.flatMap(branch),
                                  permissionMode: (object["permission_mode"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                  agentID: (object["agent_id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                  failure: event == "StopFailure" ? failure : nil,
                                  tool: tool)
            message.title = event == "UserPromptSubmit" ? Hook.title(fromPrompt: object["prompt"]) : nil
            message.request = request
            return message
        }
    }

    static func needsInput(event: String, notificationType: String?) -> Bool {
        switch event {
        case "PermissionRequest", "Elicitation": true
        case "Notification": notificationType.map(waitingNotificationTypes.contains) ?? false
        default: false
        }
    }

    /// What `git symbolic-ref --short HEAD` would print for `cwd`, read from `.git/HEAD` (following a worktree's
    /// `gitdir:` file) rather than by forking git, so it costs a file read and not a process launch inside a command
    /// that is back in milliseconds; nil when `cwd` is not a checkout or HEAD is detached.
    static func gitBranch(cwd: String) -> String? {
        let fm = FileManager.default
        var dotGit = URL(fileURLWithPath: cwd).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return nil }
        if !isDirectory.boolValue {
            guard let pointer = try? String(contentsOf: dotGit, encoding: .utf8), let line = pointer.split(separator: "\n").first,
                  line.hasPrefix("gitdir:") else { return nil }
            let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            dotGit = target.hasPrefix("/") ? URL(fileURLWithPath: target) : URL(fileURLWithPath: cwd).appendingPathComponent(target)
        }
        guard let head = try? String(contentsOf: dotGit.appendingPathComponent("HEAD"), encoding: .utf8),
              let first = head.split(separator: "\n").first, first.hasPrefix("ref: refs/heads/") else { return nil }
        let name = first.dropFirst("ref: refs/heads/".count).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// `Notchmeter --hook [--tool <id>] [--event <name>]`: read what the assistant pipes in, hand it to the running
    /// app, exit 0. The whole run is milliseconds in the ordinary case and one second at most when the app is
    /// stopped or starved (`HookSocket.send`'s timeout; docs/hooks.md gives the figures), so the read gives up after
    /// 25 ms and an empty or unreadable payload is not an error. The tool flag names the sender before a byte of payload is read;
    /// without it the payload's shape decides. The event flag names the event for a payload that does not
    /// (Copilot's). The hand-over is one line on the app's socket (HookSocket.send). For every event but one kind
    /// its answer is not looked at: no app listening is the everyday case of Notchmeter not running, and a refusal
    /// is the app's to log, so the command has nothing to say to the assistant and exits 0 silently. The one kind
    /// is a request awaiting a decision (`Message.request`), for which the command holds the socket for the app's
    /// reply, up to `decisionWait`, and prints the vendor's decision JSON when the reply carries one (`Answer`).
    /// No reply, an empty one, no app, or any error prints nothing, so the terminal asks as it always has.
    static func runCommand(arguments: [String] = CommandLine.arguments) -> Never {
        let payload = readPayload()
        guard var message = message(from: payload, tool: tool(in: arguments), event: event(in: arguments)) else { exit(0) }
        message.terminal = TerminalIdentity.capture()
        if TerminalJump.opensFolders(message.terminal?.bundleID) { message.terminal?.workspace = folder(in: payload) }
        if message.request != nil {
            if case .sent(let reply?) = HookSocket.send(.hook, message.userInfo, timeout: decisionWait),
               let output = Answer.output(event: message.event, reply: reply, payload: payload) {
                print(output)
            }
        } else {
            HookSocket.send(.hook, message.userInfo)
        }
        exit(0)
    }

    /// The folder the session runs in, for a jump back to the editor window showing it (`TerminalRef.workspace`):
    /// Cursor's first workspace root, else the `cwd` every other assistant sends. Read only when the terminal is
    /// such an editor, and sent only as that field.
    static func folder(in payload: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        let root = (object["workspace_roots"] as? [String])?.first { !$0.isEmpty } ?? (object["cwd"] as? String)
        return TerminalJump.validWorkspace(root)
    }

    /// The payload, read within the 25 ms and 64 KB the command has always allowed itself; a payload that filled
    /// that and looks like a deciding event (a permission request's `tool_input` can carry a whole file for
    /// `Write`) is read on to `decidingPayloadLimit`, since it is the one kind whose input the command echoes back
    /// (`Answer.output`) and whose summary has to see the whole of it.
    static func readPayload() -> Data {
        var payload = readStandardInput(within: 0.025)
        if payload.count >= quickPayloadLimit, looksDeciding(payload) {
            payload.append(readStandardInput(within: 0.1, limit: decidingPayloadLimit - payload.count))
        }
        return payload
    }

    static let quickPayloadLimit = 64 * 1024
    static let decidingPayloadLimit = 256 * 1024

    /// Whether the head of a payload names a deciding event, judged on bytes because the whole of it is not in yet.
    static func looksDeciding(_ head: Data) -> Bool {
        let text = String(decoding: head.prefix(4096), as: UTF8.self)
        return text.contains("\"PermissionRequest\"") || text.contains("\"AskUserQuestion\"")
    }

    /// Reads standard input without ever blocking on it: a closed pipe or a file returns at once, a terminal
    /// or an idle pipe returns empty when the budget runs out.
    static func readStandardInput(within budget: TimeInterval, limit: Int = quickPayloadLimit) -> Data {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(budget)
        while buffer.count < limit {
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let remaining = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
            guard poll(&descriptor, 1, remaining) > 0, descriptor.revents & Int16(POLLNVAL) == 0 else { break }
            let count = read(STDIN_FILENO, &chunk, min(chunk.count, limit - buffer.count))
            guard count > 0 else { break }
            buffer.append(chunk, count: count)
        }
        return buffer
    }
}
