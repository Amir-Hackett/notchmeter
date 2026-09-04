import Foundation

/// The `--hook` half of the Claude Code integration: a hook command that turns one Claude Code event into one
/// distributed notification carrying the event name, whether Claude is waiting on the user, the session id, the
/// last path component of the working directory, the git branch checked out there, the permission mode, the
/// subagent id, a stop failure's kind and — only when it is not Claude Code — which assistant sent it, nothing
/// else. The running app listens in UsageStore; a remote host's hook posts the same fields to the local API
/// instead (docs/hooks.md).
enum Hook {
    static let notificationName = Notification.Name("com.amirhackett.notchmeter.hook")
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
    /// Claude — but a Codex or Cursor installer will, and this is the field that lets the app tell them apart.
    static let toolKey = "tool"

    struct Message: Equatable, Sendable {
        let event: String
        let needsInput: Bool
        let sessionID: String?
        /// The basename of `cwd`, never the path.
        let project: String?
        let notificationType: String?
        /// The branch checked out in `cwd`, when it is a git checkout.
        let branch: String?
        /// `permission_mode`: default, plan, acceptEdits, auto, dontAsk, bypassPermissions.
        let permissionMode: String?
        /// `agent_id` on SubagentStart and SubagentStop.
        let agentID: String?
        /// A StopFailure's kind: rate_limit, overloaded, billing_error, account_on_hold.
        let failure: String?
        /// A label for the machine a remote hook posted from; nil for this Mac.
        let host: String?
        /// Which assistant the event came from. Claude Code's hook sends nothing here and is read as Claude, which
        /// is why adding this field changes nothing about the events the app receives today.
        let tool: ToolID

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
            // would say something: the payload stays exactly what it has always been for the one hook that ships.
            if tool != .claude { info[Hook.toolKey] = tool.rawValue }
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

    /// Only the event name, the notification type, the session id, the basename of `cwd`, the permission mode, the
    /// agent id, a stop failure's kind and the sending tool are read from the payload; the branch is read from
    /// `cwd`'s `.git`. Claude Code names no tool, so its events read as Claude's, which is what they have always
    /// been.
    static func message(from payload: Data, branch: (String) -> String? = gitBranch(cwd:)) -> Message? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let event = object[eventKey] as? String, !event.isEmpty
        else { return nil }
        let type = object["notification_type"] as? String
        let cwd = object["cwd"] as? String
        let failure = (object["error"] as? String) ?? (object["error_type"] as? String) ?? ((object["error"] as? [String: Any])?["type"] as? String)
        return Message(event: event, needsInput: needsInput(event: event, notificationType: type),
                       sessionID: (object["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                       project: cwd.flatMap(ClaudeCostScanner.projectName(fromPath:)),
                       notificationType: type,
                       branch: cwd.flatMap(branch),
                       permissionMode: (object["permission_mode"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                       agentID: (object["agent_id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                       failure: event == "StopFailure" ? failure : nil,
                       tool: (object[toolKey] as? String).flatMap(ToolID.init(rawValue:)) ?? .claude)
    }

    static func needsInput(event: String, notificationType: String?) -> Bool {
        switch event {
        case "PermissionRequest", "Elicitation": true
        case "Notification": notificationType.map(waitingNotificationTypes.contains) ?? false
        default: false
        }
    }

    /// What `git symbolic-ref --short HEAD` would print for `cwd`, read from `.git/HEAD` (following a worktree's
    /// `gitdir:` file) rather than by forking git, so it costs a file read inside the 50 ms budget; nil when `cwd` is
    /// not a checkout or HEAD is detached.
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

    /// `Notchmeter --hook`: read what Claude Code pipes in, post it, exit 0. The whole run must fit in 50 ms
    /// including launch, so the read gives up after 25 ms and an empty or unreadable payload is not an error.
    static func runCommand() -> Never {
        if let message = message(from: readStandardInput(within: 0.025)) {
            DistributedNotificationCenter.default().postNotificationName(
                notificationName, object: nil, userInfo: message.userInfo, deliverImmediately: true
            )
        }
        exit(0)
    }

    /// Reads standard input without ever blocking on it: a closed pipe or a file returns at once, a terminal
    /// or an idle pipe returns empty when the budget runs out.
    static func readStandardInput(within budget: TimeInterval, limit: Int = 64 * 1024) -> Data {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(budget)
        while buffer.count < limit {
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let remaining = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
            guard poll(&descriptor, 1, remaining) > 0, descriptor.revents & Int16(POLLNVAL) == 0 else { break }
            let count = read(STDIN_FILENO, &chunk, chunk.count)
            guard count > 0 else { break }
            buffer.append(chunk, count: count)
        }
        return buffer
    }
}
