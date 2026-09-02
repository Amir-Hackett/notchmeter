import AppKit
import Foundation
import os
import UserNotifications

private let log = Logger(subsystem: "com.amirhackett.notchmeter", category: "notify")

/// Pace alerts, resets, and Claude Code session events through Notification Center. Everything here is a no-op
/// when the process is not a bundle (`swift run`, where UNUserNotificationCenter aborts for want of a bundle
/// identifier) or is a `--probe` or `--smoke` run, which must never raise the permission dialog. Permission is never
/// asked at launch: the first alert asks provisionally (it lands quietly in Notification Center), and the toggle or
/// the Test button asks properly.
@MainActor
final class Notifier {
    enum SessionEvent {
        case waiting
        case finished(turn: TimeInterval)
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
    /// Sound, quiet hours and the frontmost-app check, read from Preferences by the app delegate.
    var sound: () -> Bool = { true }
    var quiet: () -> Bool = { false }

    nonisolated static func isAvailable(arguments: [String] = CommandLine.arguments, bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> Bool {
        bundleIdentifier != nil && !arguments.contains("--probe") && !arguments.contains("--smoke") && !arguments.contains("--render-assets")
            && !arguments.contains("--render-gallery")
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
            deliver(identifier: alert.identifier, thread: alert.tool.rawValue, tool: alert.tool,
                    title: Advisor.alertTitle(alert), body: Advisor.alertBody(alert, context: context),
                    level: Self.level(for: alert.stage), sound: alert.stage == .runningOut && sound())
        }
    }

    /// "Claude Code is waiting in notchmeter" or "Claude Code finished a 12m turn in notchmeter", unless a terminal
    /// is frontmost or it is a quiet hour.
    func notify(_ event: SessionEvent, session: AgentSession, frontmost: String? = NSWorkspace.shared.frontmostApplication?.bundleIdentifier) {
        guard center != nil, !Self.shouldSuppress(frontmost: frontmost, quiet: quiet()) else { return }
        requestProvisionalAuthorization()
        let project = session.project ?? L("a session")
        let (identifier, title, body): (String, String, String) = switch event {
        case .waiting:
            ("session/\(session.id)/waiting/\(Int(Date().timeIntervalSince1970))", L("Claude Code is waiting"), L("Claude Code is waiting in %@.", project))
        case .finished(let turn):
            ("session/\(session.id)/finished/\(Int(Date().timeIntervalSince1970))", L("Claude Code finished"),
             L("Claude Code finished a %1$@ turn in %2$@.", ResetText.duration(turn), project))
        }
        deliver(identifier: identifier, thread: ToolID.claude.rawValue, tool: .claude, title: title, body: body, level: .timeSensitive, sound: sound())
    }

    /// No banner while the user is looking at a terminal or an editor, and none inside the quiet hours.
    nonisolated static func shouldSuppress(frontmost: String?, quiet: Bool) -> Bool {
        if quiet { return true }
        guard let frontmost else { return false }
        return terminalBundleIDs.contains(frontmost) || frontmost.lowercased().contains("terminal") || frontmost.lowercased().contains("iterm")
    }

    nonisolated static func level(for stage: PaceAlert.Stage) -> UNNotificationInterruptionLevel {
        switch stage {
        case .onTrack: .passive
        case .behind, .reset, .reminder: .active
        case .runningOut: .timeSensitive
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
                    level: .active, sound: sound())
            return L("Sent.")
        }
    }

    /// The run-out line for a Claude weekly window at 60 % with three of seven days gone, beside a Codex week at 22 %.
    nonisolated static func sampleBody(timeFormat: TimeFormatPreference, now: Date = Date()) -> String {
        let claude = LimitWindow(id: "seven_day", label: L("Weekly"), usedFraction: 0.6, resetsAt: now.addingTimeInterval(4 * 86400), periodDuration: Period.week)
        let codex = LimitWindow(id: "weekly", label: L("Weekly"), usedFraction: 0.22, resetsAt: now.addingTimeInterval(4 * 86400), periodDuration: Period.week)
        let context = Advisor.Context(readings: [
            UsageReading(tool: .claude, windows: [claude], plan: nil, fetchedAt: now, observedAt: nil),
            UsageReading(tool: .codex, windows: [codex], plan: nil, fetchedAt: now, observedAt: nil),
        ], timeFormat: timeFormat, now: now)
        return Advisor.runOutText(tool: .claude, window: claude, context: context) ?? ""
    }

    private func deliver(identifier: String, thread: String, tool: ToolID?, title: String, body: String,
                         level: UNNotificationInterruptionLevel, sound: Bool) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        content.threadIdentifier = thread
        content.interruptionLevel = level
        content.categoryIdentifier = NotificationPresenter.category
        content.userInfo = ["tool": tool?.rawValue ?? "", "settings": tool == nil]
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
            if let error {
                log.error("\(identifier, privacy: .public) not delivered: \(error.localizedDescription, privacy: .public)")
            } else {
                log.info("notified \(identifier, privacy: .public)")
                Oracle.shared.emit("notification", ["action": "sent", "title": title, "level": String(describing: level)])
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
