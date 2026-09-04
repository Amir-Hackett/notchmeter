import AppKit
import Foundation
import os
import UserNotifications

private let log = Logger(subsystem: "com.amirhackett.notchmeter", category: "notify")

/// Pace alerts, resets, advice worth a banner, and Claude Code session events through Notification Center.
/// Everything here is a no-op when the process is not a bundle (`swift run`, where UNUserNotificationCenter aborts
/// for want of a bundle identifier) or is a `--probe` or `--smoke` run, which must never raise the permission
/// dialog. Permission is never asked at launch: the first alert asks provisionally (it lands quietly in
/// Notification Center), and the toggle or the Test button asks properly. Identifiers are stable per session and
/// state, so a repeat replaces its predecessor, and a notice is withdrawn once the state it announced has passed.
@MainActor
final class Notifier {
    enum SessionEvent {
        case waiting
        case finished(turn: TimeInterval)
    }

    /// The three classes a sound is chosen for in Settings.
    enum SoundEvent {
        case pace, waiting, finished
    }

    /// Terminal and editor apps: an alert is pointless while the user is looking at the session.
    nonisolated static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp", "com.github.wez.wezterm",
        "net.kovidgoyal.kitty", "io.alacritty", "org.alacritty", "com.mitchellh.ghostty", "co.zeit.hyper", "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "com.jetbrains.intellij", "com.jetbrains.pycharm",
        "com.jetbrains.WebStorm", "com.apple.dt.Xcode", "com.anthropic.claudefordesktop", "com.tabby.terminal", "com.zed.Zed", "dev.zed.Zed",
    ]

    let isAvailable: Bool
    private let center: UNUserNotificationCenter?
    private let presenter = NotificationPresenter()
    private var authorizationRequested = false
    /// The panel or Settings to open when a banner is clicked; wired by the app delegate.
    var onOpen: (ToolID?) -> Void = { _ in }
    /// The sound choice per event class (NotificationSound), quiet hours and the frontmost-app check, read from
    /// Preferences by the app delegate.
    var sound: (SoundEvent) -> String = { _ in NotificationSound.defaultChoice }
    var quiet: () -> Bool = { false }

    nonisolated static func isAvailable(arguments: [String] = CommandLine.arguments, bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> Bool {
        bundleIdentifier != nil && !arguments.contains("--probe") && !arguments.contains("--smoke") && !arguments.contains("--render-assets")
            && !arguments.contains("--render-gallery") && !arguments.contains("--mcp") && !arguments.contains("--cli")
    }

    init(available: Bool = Notifier.isAvailable()) {
        isAvailable = available
        center = available ? UNUserNotificationCenter.current() : nil
        center?.delegate = presenter
        presenter.opened = { [weak self] tool in self?.onOpen(tool) }
        let open = UNNotificationAction(identifier: "open", title: L("Open"), options: [.foreground])
        center?.setNotificationCategories([UNNotificationCategory(identifier: NotificationPresenter.category, actions: [open], intentIdentifiers: [], options: [])])
    }

    /// Asked when the user turns the setting on or presses Test; macOS shows its dialog the first time only.
    func requestAuthorization() {
        guard let center else { return }
        authorizationRequested = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                log.error("authorization failed: \(error.localizedDescription, privacy: .public)")
            } else {
                log.info("authorization \(granted ? "granted" : "declined", privacy: .public)")
            }
        }
    }

    /// The first alert of a launch asks provisionally: no dialog, the notice lands in Notification Center with the
    /// system's Keep / Turn off buttons.
    private func requestProvisionalAuthorization() {
        guard let center, !authorizationRequested else { return }
        authorizationRequested = true
        center.requestAuthorization(options: [.alert, .sound, .provisional]) { _, error in
            if let error { log.error("provisional authorization failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    func send(_ alerts: [PaceAlert], context: Advisor.Context) {
        guard center != nil else { return }
        requestProvisionalAuthorization()
        for alert in alerts {
            let loud = alert.stage == .runningOut || alert.stage == .limitHit
            deliver(identifier: alert.identifier, thread: alert.tool.rawValue, tool: alert.tool,
                    title: Advisor.alertTitle(alert), body: Advisor.alertBody(alert, context: context),
                    level: Self.level(for: alert.stage), sound: loud ? NotificationSound.unSound(for: sound(.pace)) : nil)
        }
    }

    /// An advice line as a banner: extra usage, a cache-tier shift, heavy metering. Time-sensitive when the line is
    /// about money already flowing.
    func send(advice: [Advice]) {
        guard center != nil else { return }
        requestProvisionalAuthorization()
        for line in advice {
            deliver(identifier: "advice/\(line.id)", thread: line.tool?.rawValue ?? "advice", tool: line.tool, title: L("%@ advice", AppInfo.name),
                    body: line.text, level: line.priority == .danger ? .timeSensitive : .active,
                    sound: line.priority == .danger ? NotificationSound.unSound(for: sound(.pace)) : nil)
        }
    }

    /// The title and body for a session event, named after the session's tool: "Cursor finished" / "Cursor finished
    /// a 12m turn in notchmeter." Pure, so the copy is pinned. The waiting body is the same key Advisor's waiting
    /// line uses, so the banner and the advice read alike.
    nonisolated static func copy(for event: SessionEvent, session: AgentSession) -> (title: String, body: String) {
        let name = session.tool.productName
        let project = session.displayName ?? L("a session")
        return switch event {
        case .waiting:
            (L("%@ is waiting", name), L("%1$@ is waiting in %2$@.", name, project))
        case .finished(let turn):
            (L("%@ finished", name), L("%1$@ finished a %2$@ turn in %3$@.", name, ResetText.duration(turn), project))
        }
    }

    /// "Claude Code is waiting in notchmeter" or "Cursor finished a 12m turn in notchmeter", unless a terminal is
    /// frontmost or it is a quiet hour; the banner is threaded under the session's tool, so each assistant's notices
    /// stack together. Returns whether it was sent.
    @discardableResult
    func notify(_ event: SessionEvent, session: AgentSession, frontmost: String? = NSWorkspace.shared.frontmostApplication?.bundleIdentifier) -> Bool {
        guard center != nil, !Self.shouldSuppress(frontmost: frontmost, quiet: quiet()) else { return false }
        requestProvisionalAuthorization()
        let (title, body) = Self.copy(for: event, session: session)
        let (identifier, choice): (String, String) = switch event {
        case .waiting: (Self.identifier(session: session.id, kind: "waiting"), sound(.waiting))
        case .finished: (Self.identifier(session: session.id, kind: "finished"), sound(.finished))
        }
        deliver(identifier: identifier, thread: session.tool.rawValue, tool: session.tool, title: title, body: body, level: Self.level(for: event),
                sound: NotificationSound.unSound(for: choice))
        return true
    }

    /// `session/<id>/waiting`: one per session and state, so a repeat replaces rather than piles up.
    nonisolated static func identifier(session: String, kind: String) -> String {
        "session/\(session)/\(kind)"
    }

    /// Withdraws delivered notices whose state has passed (a session resumed, a window reset).
    func remove(identifiers: [String]) {
        guard let center, !identifiers.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        for identifier in identifiers {
            Oracle.shared.emit("notification", ["action": "removed", "identifier": identifier])
        }
    }

    /// No banner while the user is looking at a terminal or an editor, and none inside the quiet hours.
    nonisolated static func shouldSuppress(frontmost: String?, quiet: Bool) -> Bool {
        if quiet { return true }
        guard let frontmost else { return false }
        return terminalBundleIDs.contains(frontmost) || frontmost.lowercased().contains("terminal") || frontmost.lowercased().contains("iterm")
    }

    /// Time-sensitive is reserved for the two notices that need the user now: running out (or out) and waiting for
    /// them; a finished turn is active. Time-sensitive breaks through Focus only in a build signed with the
    /// `com.apple.developer.usernotifications.time-sensitive` entitlement (scripts/Notchmeter.entitlements); an
    /// unsigned build's notices stay behind Focus like active ones.
    nonisolated static func level(for stage: PaceAlert.Stage) -> UNNotificationInterruptionLevel {
        switch stage {
        case .onTrack: .passive
        case .behind, .reset, .reminder: .active
        case .runningOut, .limitHit: .timeSensitive
        }
    }

    nonisolated static func level(for event: SessionEvent) -> UNNotificationInterruptionLevel {
        switch event {
        case .waiting: .timeSensitive
        case .finished: .active
        }
    }

    /// A sample alert in the user's own time format; returns the line Settings shows beneath the button.
    func sendTest(timeFormat: TimeFormatPreference) async -> String {
        guard let center else { return L("Not available: %@ is running unbundled.", AppInfo.name) }
        authorizationRequested = true
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .denied:
            return L("Notifications are off for %@ in System Settings › Notifications.", AppInfo.name)
        case .notDetermined:
            return L("Waiting for permission.")
        default:
            deliver(identifier: "test", thread: "test", tool: nil, title: L("%@ test", AppInfo.name), body: Self.sampleBody(timeFormat: timeFormat),
                    level: .active, sound: NotificationSound.unSound(for: sound(.pace)))
            return L("Sent.")
        }
    }

    /// The run-out line for a Claude weekly window at 60 % with three of seven days gone, beside a Codex week at 22 %.
    nonisolated static func sampleBody(timeFormat: TimeFormatPreference, now: Date = Date()) -> String {
        let claude = LimitWindow(id: "seven_day", label: .key("Weekly"), usedFraction: 0.6, resetsAt: now.addingTimeInterval(4 * 86400), periodDuration: Period.week)
        let codex = LimitWindow(id: "weekly", label: .key("Weekly"), usedFraction: 0.22, resetsAt: now.addingTimeInterval(4 * 86400), periodDuration: Period.week)
        let context = Advisor.Context(readings: [
            UsageReading(tool: .claude, windows: [claude], plan: nil, fetchedAt: now, observedAt: nil),
            UsageReading(tool: .codex, windows: [codex], plan: nil, fetchedAt: now, observedAt: nil),
        ], timeFormat: timeFormat, now: now)
        return Advisor.runOutText(tool: .claude, window: claude, context: context) ?? ""
    }

    private func deliver(identifier: String, thread: String, tool: ToolID?, title: String, body: String,
                         level: UNNotificationInterruptionLevel, sound: UNNotificationSound?) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound
        content.threadIdentifier = thread
        content.interruptionLevel = level
        content.categoryIdentifier = NotificationPresenter.category
        content.userInfo = ["tool": tool?.rawValue ?? "", "settings": tool == nil]
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
            if let error {
                log.error("\(identifier, privacy: .public) not delivered: \(error.localizedDescription, privacy: .public)")
            } else {
                log.info("notified \(identifier, privacy: .public)")
                Oracle.shared.emit("notification", ["action": "sent", "title": title, "level": String(describing: level), "identifier": identifier])
            }
        }
    }
}

/// Shows the banner even while a Notchmeter window is frontmost, which is where the Test button is pressed, and
/// opens the panel on the tool's card (Settings for the test alert) when a banner is clicked.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let category = "notchmeter.alert"
    nonisolated(unsafe) var opened: (ToolID?) -> Void = { _ in }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(notification.request.content.sound == nil ? [.banner, .list] : [.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let tool = (info["tool"] as? String).flatMap(ToolID.init(rawValue:))
        let opened = self.opened
        Oracle.shared.emit("notification", ["action": "clicked", "tool": tool?.rawValue as Any, "identifier": response.notification.request.identifier])
        Task { @MainActor in opened(tool) }
        completionHandler()
    }
}
