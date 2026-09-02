import Foundation

/// The `--hook` half of the Claude Code integration: a hook command that turns one Claude Code event into one
/// distributed notification carrying the event name and whether Claude is waiting on the user, nothing else.
/// The running app listens in UsageStore.
enum Hook {
    static let notificationName = Notification.Name("com.amirhackett.notchmeter.hook")
    static let eventKey = "hook_event_name"
    static let needsInputKey = "needsInput"

    struct Message: Equatable, Sendable {
        let event: String
        let needsInput: Bool

        init(event: String, needsInput: Bool) {
            self.event = event
            self.needsInput = needsInput
        }

        init?(userInfo: [AnyHashable: Any]?) {
            guard let event = userInfo?[Hook.eventKey] as? String, !event.isEmpty else { return nil }
            self.event = event
            needsInput = (userInfo?[Hook.needsInputKey] as? Bool) ?? false
        }

        var userInfo: [String: Any] { [Hook.eventKey: event, Hook.needsInputKey: needsInput] }
    }

    /// Events after which Claude is no longer waiting on the user.
    static let clearingEvents: Set<String> = ["Stop", "SessionEnd", "UserPromptSubmit"]

    /// Notification types that mean Claude Code is waiting for the user, per the hooks reference.
    static let waitingNotificationTypes: Set<String> = ["permission_prompt", "idle_prompt", "elicitation_dialog", "agent_needs_input"]

    /// Only the event name and the notification type are read from the payload.
    static func message(from payload: Data) -> Message? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let event = object[eventKey] as? String, !event.isEmpty
        else { return nil }
        return Message(event: event, needsInput: needsInput(event: event, notificationType: object["notification_type"] as? String))
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
