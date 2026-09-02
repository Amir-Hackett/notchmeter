import Foundation
import os
import UserNotifications

private let log = Logger(subsystem: "com.amirhackett.notchmeter", category: "notify")

/// Pace alerts through Notification Center. Everything here is a no-op when the process is not a bundle
/// (`swift run`, where UNUserNotificationCenter aborts for want of a bundle identifier) or is a `--probe` or
/// `--smoke` run, which must never raise the permission dialog.
@MainActor
final class Notifier {
    let isAvailable: Bool
    private let center: UNUserNotificationCenter?
    private let presenter = NotificationPresenter()
    private var authorizationRequested = false

    nonisolated static func isAvailable(arguments: [String] = CommandLine.arguments, bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> Bool {
        bundleIdentifier != nil && !arguments.contains("--probe") && !arguments.contains("--smoke")
    }

    init(available: Bool = Notifier.isAvailable()) {
        isAvailable = available
        center = available ? UNUserNotificationCenter.current() : nil
        center?.delegate = presenter
    }

    /// Asked once per launch, and only while the setting is on; macOS shows its dialog the first time only.
    func requestAuthorization() {
        guard let center, !authorizationRequested else { return }
        authorizationRequested = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                log.error("authorization failed: \(error.localizedDescription, privacy: .public)")
            } else {
                log.info("authorization \(granted ? "granted" : "declined", privacy: .public)")
            }
        }
    }

    func send(_ alerts: [PaceAlert], context: Advisor.Context) {
        guard center != nil else { return }
        requestAuthorization()
        for alert in alerts {
            deliver(identifier: alert.identifier, thread: alert.tool.rawValue,
                    title: Advisor.alertTitle(alert), body: Advisor.alertBody(alert, context: context))
        }
    }

    /// A sample alert in the user's own time format; returns the line Settings shows beneath the button.
    func sendTest(timeFormat: TimeFormatPreference) async -> String {
        guard let center else { return "Not available: \(AppInfo.name) is running unbundled." }
        authorizationRequested = true
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .denied:
            return "Notifications are off for \(AppInfo.name) in System Settings › Notifications."
        case .notDetermined:
            return "Waiting for permission."
        default:
            deliver(identifier: "test", thread: "test", title: "\(AppInfo.name) test", body: Self.sampleBody(timeFormat: timeFormat))
            return "Sent."
        }
    }

    /// The run-out line for a Claude weekly window at 60 % with three of seven days gone, beside a Codex week at 22 %.
    nonisolated static func sampleBody(timeFormat: TimeFormatPreference, now: Date = Date()) -> String {
        let claude = LimitWindow(id: "seven_day", label: "Weekly", usedFraction: 0.6, resetsAt: now.addingTimeInterval(4 * 86400), periodDuration: Period.week)
        let codex = LimitWindow(id: "weekly", label: "Weekly", usedFraction: 0.22, resetsAt: now.addingTimeInterval(4 * 86400), periodDuration: Period.week)
        let context = Advisor.Context(readings: [
            UsageReading(tool: .claude, windows: [claude], plan: nil, fetchedAt: now, observedAt: nil),
            UsageReading(tool: .codex, windows: [codex], plan: nil, fetchedAt: now, observedAt: nil),
        ], timeFormat: timeFormat, now: now)
        return Advisor.runOutText(tool: .claude, window: claude, context: context) ?? ""
    }

    private func deliver(identifier: String, thread: String, title: String, body: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = thread
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
            if let error {
                log.error("\(identifier, privacy: .public) not delivered: \(error.localizedDescription, privacy: .public)")
            } else {
                log.info("notified \(identifier, privacy: .public)")
            }
        }
    }
}

/// Shows the banner even while a Notchmeter window is frontmost, which is where the Test button is pressed.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
