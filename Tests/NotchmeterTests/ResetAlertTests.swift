import Foundation
import Testing
@testable import Notchmeter

/// The timer-driven alerts: a reset once a nearly-gone window passes its reset, a reminder before it, each once
/// per period; the per-stage toggles; the measured drain rate ahead of the even-burn projection.
@Suite struct ResetAlerts {
    init() { Localization.use(language: "en") }

    let start = DateParsing.iso8601("2026-09-01T12:00:00Z")!

    func window(used: Double, resetsIn: TimeInterval, period: TimeInterval = Period.fiveHours, id: String = "five_hour") -> LimitWindow {
        LimitWindow(id: id, label: "Session", usedFraction: used, resetsAt: start.addingTimeInterval(resetsIn), periodDuration: period)
    }

    @Test func onlyNearlyGoneOrBehindWindowsAreWatched() {
        #expect(WatchedReset.watch(.claude, window(used: 0.85, resetsIn: 3600), now: start) != nil)
        #expect(WatchedReset.watch(.claude, window(used: 0.3, resetsIn: 3600), now: start) == nil)
        // 50 % an hour into a five-hour window is behind pace.
        #expect(WatchedReset.watch(.claude, window(used: 0.5, resetsIn: 4 * 3600), now: start) != nil)
        #expect(WatchedReset.watch(.claude, window(used: 0.9, resetsIn: -1), now: start) == nil)
        #expect(WatchedReset.watch(.claude, LimitWindow(id: "x", label: "X", usedFraction: 0.9, resetsAt: nil), now: start) == nil)
    }

    @Test func resetFiresOncePerPeriodAndReminderOncePerLead() throws {
        let watched = try #require(WatchedReset.watch(.claude, window(used: 0.9, resetsIn: 1800), now: start))
        let options = NotificationScheduler.Options(reminderLead: 600)
        let early = NotificationScheduler.planResets(memory: .empty, watched: [watched], now: start.addingTimeInterval(600), options: options)
        #expect(early.alerts.isEmpty)
        #expect(early.watched.count == 1)
        let lead = NotificationScheduler.planResets(memory: early.memory, watched: early.watched, now: start.addingTimeInterval(1200), options: options)
        #expect(lead.alerts.map(\.stage) == [.reminder])
        #expect(lead.watched.count == 1)
        let again = NotificationScheduler.planResets(memory: lead.memory, watched: lead.watched, now: start.addingTimeInterval(1500), options: options)
        #expect(again.alerts.isEmpty)
        let reset = NotificationScheduler.planResets(memory: again.memory, watched: again.watched, now: start.addingTimeInterval(1801), options: options)
        #expect(reset.alerts.map(\.stage) == [.reset])
        #expect(reset.watched.isEmpty)
        #expect(reset.memory.resets["claude/five_hour"] == watched.window.resetsAt)
        let repeat_ = NotificationScheduler.planResets(memory: reset.memory, watched: [watched], now: start.addingTimeInterval(1900), options: options)
        #expect(repeat_.alerts.isEmpty)
        let context = Advisor.Context(readings: [], timeFormat: .twentyFourHour, now: start.addingTimeInterval(1801))
        let body = Advisor.alertBody(PaceAlert(tool: .claude, window: watched.window, stage: .reset), context: context)
        #expect(body.hasPrefix("Claude session reset — 100% until it resets"))
        let reminder = Advisor.alertBody(PaceAlert(tool: .claude, window: watched.window, stage: .reminder), context: Advisor.Context(readings: [], now: start.addingTimeInterval(1200)))
        #expect(reminder == "Claude session resets in 10m.")
        #expect(PaceAlert.Stage.reset > PaceAlert.Stage.runningOut)
        #expect(!PaceAlert.Stage.reset.isEscalating)
    }

    @Test func togglesDropAlertsButStillRememberTheStage() {
        let behind = window(used: 0.5, resetsIn: 4 * 3600)
        let reading = UsageReading(tool: .claude, windows: [behind], plan: nil, fetchedAt: start, observedAt: nil)
        let off = NotificationScheduler.Options(onTrack: true, behind: false, runningOut: true, reset: true, reminderLead: nil)
        let planned = NotificationScheduler.plan(memory: .empty, readings: [reading], now: start, options: off)
        #expect(planned.alerts.isEmpty)
        #expect(planned.memory.entries["claude/five_hour"]?.stage == .behind)
        let on = NotificationScheduler.plan(memory: planned.memory, readings: [reading], now: start.addingTimeInterval(60), options: .all)
        #expect(on.alerts.isEmpty)
        let noReset = NotificationScheduler.planResets(memory: .empty, watched: [WatchedReset.watch(.claude, window(used: 0.9, resetsIn: 10), now: start)!],
                                                       now: start.addingTimeInterval(20), options: NotificationScheduler.Options(reset: false))
        #expect(noReset.alerts.isEmpty)
        #expect(noReset.watched.isEmpty)
        #expect(!NotificationScheduler.Options().wants(.reminder))
    }

    @Test func aMeasuredDrainRateSetsTheRunOutTime() throws {
        // 35 % used an hour into five hours is behind by projection (out in ~1h 51m); a measured 1.0/h drains it in 39 min.
        let behind = window(used: 0.35, resetsIn: 4 * 3600)
        #expect(NotificationScheduler.stage(for: behind, now: start) == .behind)
        #expect(NotificationScheduler.stage(for: behind, now: start, rate: 1.0) == .runningOut)
        let measured = try #require(Pace.secondsToRunOut(usedFraction: 0.35, rate: 1.0, resetsAt: behind.resetsAt!, now: start))
        #expect(abs(measured - 2340) < 1e-9)
        #expect(Pace.secondsToRunOut(usedFraction: 0.35, rate: 0.01, resetsAt: behind.resetsAt!, now: start) == nil)
        #expect(Pace.secondsToRunOut(usedFraction: 0.35, rate: nil, resetsAt: behind.resetsAt!, now: start) == nil)
        let reading = UsageReading(tool: .claude, windows: [behind], plan: nil, fetchedAt: start, observedAt: nil)
        var context = Advisor.Context(readings: [reading], timeFormat: .twentyFourHour, now: start)
        context.calendar = Calendar(identifier: .gregorian)
        context.calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(Advisor.runOut(context).first?.text == "At this rate you hit the Claude session cap today at 13:51, 2h 8m before reset.")
        context.drainRates = ["claude/five_hour": 1.0]
        #expect(Advisor.runOut(context).first?.text == "At this rate you hit the Claude session cap today at 12:39, 3h 21m before reset.")
    }
}

@Suite struct AdvisorExtras {
    init() { Localization.use(language: "en") }

    let now = DateParsing.iso8601("2026-09-01T12:00:00Z")!

    @Test func waitForAResetThatIsCloseWhenNothingElseHasRoom() {
        let out = LimitWindow(id: "five_hour", label: "Session", usedFraction: 1, resetsAt: now.addingTimeInterval(40 * 60), periodDuration: Period.fiveHours)
        let claude = UsageReading(tool: .claude, windows: [out], plan: nil, fetchedAt: now, observedAt: nil)
        let advice = Advisor.advise(Advisor.Context(readings: [claude], now: now))
        #expect(advice.map(\.text) == ["Claude session resets in 40m; wait rather than switch."])
        #expect(advice.first?.priority == .warn)
        let codex = UsageReading(tool: .codex, windows: [LimitWindow(id: "weekly", label: "Weekly", usedFraction: 0.2, resetsAt: now.addingTimeInterval(4 * 86400), periodDuration: Period.week)],
                                 plan: nil, fetchedAt: now, observedAt: nil)
        #expect(Advisor.waitForReset(Advisor.Context(readings: [claude, codex], now: now)).isEmpty)
        let far = LimitWindow(id: "five_hour", label: "Session", usedFraction: 1, resetsAt: now.addingTimeInterval(3 * 3600), periodDuration: Period.fiveHours)
        #expect(Advisor.waitForReset(Advisor.Context(readings: [UsageReading(tool: .claude, windows: [far], plan: nil, fetchedAt: now, observedAt: nil)], now: now)).isEmpty)
    }

    @Test func waitingNamesTheProjectWhenTheHookKnowsIt() {
        let a = AgentSession(id: "a", project: "notchmeter", state: .waiting(since: now), started: now, lastEvent: now, turnStarted: nil)
        let b = AgentSession(id: "b", project: "scout", state: .waiting(since: now), started: now, lastEvent: now, turnStarted: nil)
        let named = Advisor.waiting(Advisor.Context(readings: [], awaitingInput: [.claude], waitingSessions: [a, b], now: now))
        #expect(named.map(\.text) == ["Claude Code is waiting in notchmeter (and 1 more)."])
        let plain = Advisor.waiting(Advisor.Context(readings: [], awaitingInput: [.claude], now: now))
        #expect(plain.map(\.text) == ["Claude Code is waiting for your input."])
    }

    /// The frontmost-terminal rule holds a session notice back only where the user could actually be looking at
    /// the session it is about. Three cases say they could not be — a wait the session has stopped for, which the
    /// app cannot tell from a session sitting in another tab; a session on another Mac, which no window here can
    /// be showing; and a user who turned the rule off — and the quiet hours outrank all three. Claude Code's idle
    /// nudge is none of them: it fires whenever a turn ends and the user reads for a minute, so it stays quiet,
    /// which is the whole reason the rule cannot simply be dropped for waits.
    @Test func onlyAStoppedSessionIsWorthInterruptingATerminalFor() {
        let terminal = "com.googlecode.iterm2"
        #expect(Notifier.shouldSuppress(event: .waiting(blocking: false), frontmost: terminal, quiet: false))
        #expect(!Notifier.shouldSuppress(event: .waiting(blocking: true), frontmost: terminal, quiet: false))
        #expect(Notifier.shouldSuppress(event: .finished(turn: 600), frontmost: terminal, quiet: false))
        #expect(!Notifier.shouldSuppress(event: .waiting(blocking: false), frontmost: terminal, quiet: false, host: "mini"))
        #expect(!Notifier.shouldSuppress(event: .finished(turn: 600), frontmost: terminal, quiet: false, host: "mini"))
        #expect(!Notifier.shouldSuppress(event: .waiting(blocking: false), frontmost: terminal, quiet: false, terminalRule: false))
        #expect(!Notifier.shouldSuppress(event: .finished(turn: 600), frontmost: terminal, quiet: false, terminalRule: false))
        // Quiet hours are checked first and answer for every exemption above.
        #expect(Notifier.shouldSuppress(event: .waiting(blocking: true), frontmost: terminal, quiet: true))
        #expect(Notifier.shouldSuppress(event: .waiting(blocking: true), frontmost: nil, quiet: true, host: "mini", terminalRule: false))
        // A non-terminal in front never suppressed anything and still does not.
        #expect(!Notifier.shouldSuppress(event: .waiting(blocking: false), frontmost: "com.apple.Safari", quiet: false))
    }

    @Test func alertLevelsAndSuppression() {
        #expect(Notifier.level(for: .onTrack) == .passive)
        #expect(Notifier.level(for: .behind) == .active)
        #expect(Notifier.level(for: .runningOut) == .timeSensitive)
        #expect(Notifier.shouldSuppress(frontmost: "com.apple.Terminal", quiet: false))
        #expect(Notifier.shouldSuppress(frontmost: "com.googlecode.iterm2", quiet: false))
        #expect(!Notifier.shouldSuppress(frontmost: "com.apple.Safari", quiet: false))
        #expect(Notifier.shouldSuppress(frontmost: "com.apple.Safari", quiet: true))
        #expect(!Notifier.shouldSuppress(frontmost: nil, quiet: false))
        #expect(QuietHours.contains(minute: 23 * 60, start: 22 * 60, end: 8 * 60))
        #expect(QuietHours.contains(minute: 7 * 60, start: 22 * 60, end: 8 * 60))
        #expect(!QuietHours.contains(minute: 12 * 60, start: 22 * 60, end: 8 * 60))
        #expect(QuietHours.contains(minute: 13 * 60, start: 12 * 60, end: 14 * 60))
        #expect(!QuietHours.contains(minute: 13 * 60, start: 12 * 60, end: 12 * 60))
    }
}
