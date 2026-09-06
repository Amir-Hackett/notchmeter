import AppKit
import Foundation
import os
import UserNotifications

private let log = Logger(subsystem: "com.amirhackett.notchmeter", category: "notify")

/// When each session last raised a banner for a wait it had stopped for, so the exemption in
/// `Notifier.shouldSuppress` has a ceiling. In memory only and never persisted: a relaunch that forgets errs
/// towards one more banner, which is the safe direction, and the ceiling is about a working hour, not a working
/// week. A value type because `notify` is unreachable under `swift test` — `center` is nil in an unbundled run —
/// so the ceiling is pinned here with an injected clock rather than by answering a real permission prompt.
struct WaitBannerMemory: Equatable, Sendable {
    /// What the ceiling made of one banner. `capped` is held for this reason and no other, so the oracle line
    /// counts the ceiling rather than every quiet hour.
    enum Verdict: Equatable {
        case send, held
        case capped(sinceLast: TimeInterval)
    }

    /// Read by the tests, which is the only way to prove this does not grow across a long uptime.
    private(set) var stamps: [String: Date] = [:]

    /// The stamp that can still hold a banner back, or nil.
    func last(_ session: String, now: Date) -> Date? {
        guard let stamp = stamps[session], Notifier.within(stamp, of: now) else { return nil }
        return stamp
    }

    /// The whole rule in one step — look the stamp up, ask `shouldSuppress`, stamp only what goes out — because
    /// the order of those three is the part that can be got wrong and `notify` cannot be reached from a test.
    /// Only a blocking wait stamps: an idle nudge that a non-terminal let through is not the interruption this
    /// rations, and letting it stamp would spend an allowance it can never itself be held by. A held banner never
    /// stamps either — a ceiling that restamped itself would be one that never let go.
    mutating func verdict(for event: Notifier.SessionEvent, session: String, frontmost: String?, quiet: Bool,
                          host: String?, terminalRule: Bool, now: Date) -> Verdict {
        let stamp = last(session, now: now)
        guard Notifier.shouldSuppress(event: event, frontmost: frontmost, quiet: quiet, host: host, terminalRule: terminalRule,
                                      lastBlockingBanner: stamp, now: now)
        else {
            if case .waiting(let blocking) = event, blocking { record(session, at: now) }
            return .send
        }
        // The second question is what the answer would have been with no allowance at all, so a quiet hour or the
        // idle nudge is never counted as a cap.
        guard let stamp, !Notifier.shouldSuppress(event: event, frontmost: frontmost, quiet: quiet, host: host, terminalRule: terminalRule,
                                                  now: now)
        else { return .held }
        return .capped(sinceLast: now.timeIntervalSince(stamp))
    }

    /// Stamps that can no longer hold anything back are dropped as they are written, which is what bounds this to
    /// the sessions that bannered inside the last interval. Nothing else prunes it and nothing else has to.
    private mutating func record(_ session: String, at now: Date) {
        stamps[session] = now
        stamps = stamps.filter { Notifier.within($0.value, of: now) }
    }
}

/// Pace alerts, resets, advice worth a banner, and Claude Code session events through Notification Center.
/// Everything here is a no-op when the process is not a bundle (`swift run`, where UNUserNotificationCenter aborts
/// for want of a bundle identifier) or is a `--probe` or `--smoke` run, which must never raise the permission
/// dialog. Permission is never asked at launch: the first alert asks provisionally (it lands quietly in
/// Notification Center), and the toggle or the Test button asks properly. Identifiers are stable per session and
/// state, so a repeat replaces its predecessor, and a notice is withdrawn once the state it announced has passed.
@MainActor
final class Notifier {
    enum SessionEvent {
        /// `blocking` is a wait the session has stopped for — a permission prompt, an elicitation, an agent
        /// asking — as against Claude Code's idle nudge, which only says the user has gone quiet (Hook.swift).
        case waiting(blocking: Bool)
        case finished(turn: TimeInterval)
    }

    /// The three classes a sound is chosen for in Settings.
    enum SoundEvent {
        case pace, waiting, finished
    }

    /// Terminal and editor apps: a notice about a session is usually pointless while one of them is in front.
    /// Usually, not always — see `shouldSuppress`, which is where the exceptions live.
    nonisolated static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp", "com.github.wez.wezterm",
        "net.kovidgoyal.kitty", "io.alacritty", "org.alacritty", "com.mitchellh.ghostty", "co.zeit.hyper", "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "com.jetbrains.intellij", "com.jetbrains.pycharm",
        "com.jetbrains.WebStorm", "com.apple.dt.Xcode", "com.anthropic.claudefordesktop", "com.tabby.terminal", "com.zed.Zed", "dev.zed.Zed",
    ]

    /// One banner per session per ten minutes for a wait the session has stopped for. Nothing bounded that
    /// exemption when it was written: the app is never told a permission prompt was answered (docs/hooks.md), the
    /// owner runs the default permission mode, and a repo with no allow rules stops a session as often as the work
    /// needs — every stop a banner over the terminal being worked in. Ten minutes because a wait itself expires
    /// then (`SessionTracker.waitingTimeout`), so a session can never hold two banners' worth of live wait inside
    /// one interval: at most six an hour per session — 11-17 an hour was the measured `idle_prompt` rate for one.
    /// Its own number rather than an alias of that one — how patient the state machine is and how loud the app is
    /// are different questions, and a change to the first must not silently move the second.
    nonisolated static let blockingWaitInterval: TimeInterval = 600

    let isAvailable: Bool
    private let center: UNUserNotificationCenter?
    private let presenter = NotificationPresenter()
    private var authorizationRequested = false
    /// Here, and not in UsageStore or the app delegate, because "how often have I bannered this session" is a fact
    /// about what this object has sent: nothing upstream can see whether `deliver` was reached. Read below the
    /// `center` guard in `notify`, so a `--probe` or unbundled run records nothing.
    private var waitBanners = WaitBannerMemory()
    /// The panel or Settings to open when a banner is clicked; wired by the app delegate.
    var onOpen: (ToolID?) -> Void = { _ in }
    /// The sound choice per event class (NotificationSound), quiet hours and the frontmost-app check, read from
    /// Preferences by the app delegate.
    var sound: (SoundEvent) -> String = { _ in NotificationSound.defaultChoice }
    var quiet: () -> Bool = { false }
    /// Whether the frontmost-terminal rule is on at all (Preferences.quietWhileTerminalFrontmost).
    var terminalRule: () -> Bool = { true }

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

    /// A quiet hour hushes these rather than dropping them: UsageStore commits a plan to `alertMemory` before it
    /// hands the alerts over (UsageStore.swift, `remember` then `send`) and a stage never repeats within its
    /// period, so an alert dropped here would be one the user is never told about at all. Passive and silent, it
    /// waits in Notification Center for the morning instead.
    func send(_ alerts: [PaceAlert], context: Advisor.Context) {
        guard center != nil else { return }
        requestProvisionalAuthorization()
        let hushed = quiet()
        for alert in alerts {
            let loud = alert.stage == .runningOut || alert.stage == .limitHit
            deliver(identifier: alert.identifier, thread: alert.tool.rawValue, tool: alert.tool,
                    title: Advisor.alertTitle(alert), body: Advisor.alertBody(alert, context: context),
                    level: hushed ? .passive : Self.level(for: alert.stage),
                    sound: loud && !hushed ? NotificationSound.unSound(for: sound(.pace)) : nil)
        }
    }

    /// An advice line as a banner: extra usage, a cache-tier shift, heavy metering. Time-sensitive when the line is
    /// about money already flowing.
    func send(advice: [Advice]) {
        guard center != nil else { return }
        requestProvisionalAuthorization()
        let hushed = quiet()
        for line in advice {
            deliver(identifier: "advice/\(line.id)", thread: line.tool?.rawValue ?? "advice", tool: line.tool, title: L("%@ advice", AppInfo.name),
                    body: line.text, level: hushed ? .passive : (line.priority == .danger ? .timeSensitive : .active),
                    sound: line.priority == .danger && !hushed ? NotificationSound.unSound(for: sound(.pace)) : nil)
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

    /// "Claude Code is waiting in notchmeter" or "Cursor finished a 12m turn in notchmeter", unless `shouldSuppress`
    /// says the user is already looking at it, it is a quiet hour, or this session has already been bannered for a
    /// wait inside `blockingWaitInterval`; the banner is threaded under the session's tool, so each assistant's
    /// notices stack together. Returns whether it was sent, and only a banner that was sent spends the allowance.
    @discardableResult
    func notify(_ event: SessionEvent, session: AgentSession,
                frontmost: String? = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, now: Date = Date()) -> Bool {
        guard center != nil else { return false }
        switch waitBanners.verdict(for: event, session: session.id, frontmost: frontmost, quiet: quiet(), host: session.host,
                                   terminalRule: terminalRule(), now: now) {
        case .send: break
        case .held: return false
        case .capped(let sinceLast):
            // The one suppression worth counting: the rate this ceiling exists to bound, and the only way to learn
            // in the field whether ten minutes is the right number.
            Oracle.shared.emit("notification", ["action": "capped", "identifier": Self.identifier(session: session.id, kind: "waiting"),
                                                "sinceLast": sinceLast])
            return false
        }
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

    /// Quiet hours silence everything. Past them, the frontmost-terminal rule holds a notice back only where the
    /// user could plausibly be looking at the session it is about, which is not the case three times over: a
    /// session on another machine, which no window on this one can be showing; a wait the session has stopped
    /// for, which costs the user real time wherever they are looking, and which frontmost-app granularity cannot
    /// tell from a session in some other tab; and a user who has turned the rule off. Claude Code's idle nudge is
    /// none of those — it fires whenever a turn ends and the user reads for a minute, so it stays suppressed, and
    /// it is the reason this rule cannot simply be dropped for waits.
    ///
    /// The stopped session's exemption has a ceiling. `lastBlockingBanner` is when this session last raised one,
    /// and inside `blockingWaitInterval` of it the terminal rule holds after all: this session interrupted the user
    /// minutes ago, with the terminal in front of them. It has to be a comparison against the clock rather than
    /// anything cleverer — Claude Code reports a permission prompt and never its answer (docs/hooks.md), so nothing
    /// here can know a prompt was dealt with, and a second wait is as likely to be the same block still standing as
    /// a new one. The allowance outlives the banner deliberately: `UsageStore.withdrawWaiting` takes the notice down
    /// at the next clearing event, so a held banner usually leaves nothing standing in Notification Center either —
    /// and handing the allowance back there would restore the unbounded rate exactly, because a clearing event is
    /// what lets the next prompt raise a banner at all. `WaitBannerCeiling` pins that. Passing nil is no allowance,
    /// which is the rule exactly as it read before the ceiling and what the panel's own call passes (App.swift). The
    /// ceiling is only ever reached with a terminal in front, so anywhere else a wait banners as it always did.
    nonisolated static func shouldSuppress(event: SessionEvent? = nil, frontmost: String?, quiet: Bool,
                                           host: String? = nil, terminalRule: Bool = true,
                                           lastBlockingBanner: Date? = nil, now: Date = Date()) -> Bool {
        if quiet { return true }
        guard terminalRule, host == nil else { return false }
        guard let frontmost, isTerminal(frontmost) else { return false }
        if case .waiting(let blocking)? = event, blocking {
            guard let lastBlockingBanner else { return false }
            return within(lastBlockingBanner, of: now)
        }
        return true
    }

    /// Whether a banner sent at `stamp` still holds the ceiling closed. A stamp in the future is a clock stepped
    /// backwards, not a banner a moment ago, and holds nothing — otherwise an NTP correction would mute a session
    /// until the clock caught up.
    nonisolated static func within(_ stamp: Date, of now: Date) -> Bool {
        (0 ..< blockingWaitInterval).contains(now.timeIntervalSince(stamp))
    }

    /// A terminal or an editor: the apps a session is looked at through.
    nonisolated static func isTerminal(_ bundleID: String) -> Bool {
        terminalBundleIDs.contains(bundleID) || bundleID.lowercased().contains("terminal") || bundleID.lowercased().contains("iterm")
    }

    /// Time-sensitive is reserved for the two notices that need the user now: running out (or out) and waiting for
    /// them; a finished turn is active. Time-sensitive would break through Focus only in a build signed with the
    /// `com.apple.developer.usernotifications.time-sensitive` entitlement, which no build claims: it is restricted,
    /// and an app outside the App Store claiming one without a provisioning profile in the bundle is refused at
    /// launch (docs/release.md). macOS accepts the level and delivers these behind Focus like active ones.
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
    ///
    /// The line has to account for provisional permission, which is what the app has until someone answers a
    /// dialog: under it a notice is delivered, and delivered silently, straight into Notification Center with no
    /// banner and no sound. Reporting that as "Sent." is how a working Test button reads as a broken one — the
    /// notice did arrive, in the one place the user was not looking. The flag is set only once the request has
    /// actually come back, so a request that threw does not leave the app believing it has asked.
    func sendTest(timeFormat: TimeFormatPreference) async -> String {
        guard let center else { return L("Not available: %@ is running unbundled.", AppInfo.name) }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
            authorizationRequested = true
        } catch {
            log.error("authorization failed: \(error.localizedDescription, privacy: .public)")
            return L("Asking for permission failed: %@", error.localizedDescription)
        }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .denied:
            return L("Notifications are off for %@ in System Settings › Notifications.", AppInfo.name)
        case .notDetermined:
            return L("Waiting for permission.")
        case .provisional:
            deliver(identifier: "test", thread: "test", tool: nil, title: L("%@ test", AppInfo.name), body: Self.sampleBody(timeFormat: timeFormat),
                    level: .active, sound: NotificationSound.unSound(for: sound(.pace)))
            return L("Sent, but quietly: %@ has provisional permission, so notices go straight to Notification Center with no banner. Allow them under Notifications in System Settings.", AppInfo.name)
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
