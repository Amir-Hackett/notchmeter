import Foundation

/// The `--hook` half of the Claude Code integration: a hook command that turns one Claude Code event into one
/// distributed notification carrying the event name, whether Claude is waiting on the user, the session id and the
/// last path component of the working directory, nothing else. The running app listens in UsageStore.
enum Hook {
    static let notificationName = Notification.Name("com.amirhackett.notchmeter.hook")
    static let eventKey = "hook_event_name"
    static let needsInputKey = "needsInput"
    static let sessionKey = "session_id"
    static let projectKey = "project"
    static let typeKey = "notification_type"

    struct Message: Equatable, Sendable {
        let event: String
        let needsInput: Bool
        let sessionID: String?
        /// The basename of `cwd`, never the path.
        let project: String?
        let notificationType: String?

        init(event: String, needsInput: Bool, sessionID: String? = nil, project: String? = nil, notificationType: String? = nil) {
            self.event = event
            self.needsInput = needsInput
            self.sessionID = sessionID
            self.project = project
            self.notificationType = notificationType
        }

        init?(userInfo: [AnyHashable: Any]?) {
            guard let event = userInfo?[Hook.eventKey] as? String, !event.isEmpty else { return nil }
            self.event = event
            needsInput = (userInfo?[Hook.needsInputKey] as? Bool) ?? false
            sessionID = userInfo?[Hook.sessionKey] as? String
            project = userInfo?[Hook.projectKey] as? String
            notificationType = userInfo?[Hook.typeKey] as? String
        }

        var userInfo: [String: Any] {
            var info: [String: Any] = [Hook.eventKey: event, Hook.needsInputKey: needsInput]
            if let sessionID { info[Hook.sessionKey] = sessionID }
            if let project { info[Hook.projectKey] = project }
            if let notificationType { info[Hook.typeKey] = notificationType }
            return info
        }

        /// A notification that says the agent no longer needs the user: it finished, or the elicitation was answered.
        var clearsWaiting: Bool {
            Hook.clearingEvents.contains(event) || (event == "Notification" && notificationType.map(Hook.completionNotificationTypes.contains) == true)
        }
    }

    /// Events after which Claude is no longer waiting on the user.
    static let clearingEvents: Set<String> = ["Stop", "SessionEnd", "UserPromptSubmit"]

    /// Notification types that mean Claude Code is waiting for the user, per the hooks reference.
    static let waitingNotificationTypes: Set<String> = ["permission_prompt", "idle_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"]

    /// Notification types that end a wait without a Stop: a subagent finished, or the elicitation was answered.
    static let completionNotificationTypes: Set<String> = ["agent_completed", "elicitation_complete", "elicitation_response"]

    /// Only the event name, the notification type, the session id and the basename of `cwd` are read from the payload.
    static func message(from payload: Data) -> Message? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let event = object[eventKey] as? String, !event.isEmpty
        else { return nil }
        let type = object["notification_type"] as? String
        return Message(event: event, needsInput: needsInput(event: event, notificationType: type),
                       sessionID: (object["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                       project: (object["cwd"] as? String).flatMap(ClaudeCostScanner.projectName(fromPath:)),
                       notificationType: type)
    }

    static func needsInput(event: String, notificationType: String?) -> Bool {
        switch event {
        case "PermissionRequest", "Elicitation": true
        case "Notification": notificationType.map(waitingNotificationTypes.contains) ?? false
        default: false
        }
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
