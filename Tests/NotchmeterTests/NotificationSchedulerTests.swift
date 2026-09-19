import Foundation
import Testing
@testable import Notchmeter

/// A five-hour session window unless stated; an hour in at 50 % it is behind with an hour to run out, and at
/// 70 % an hour and a half in it is under an hour from running out.
@Suite struct PaceAlertScheduling {
    let start = DateParsing.iso8601("2026-09-01T12:00:00Z")!

    func session(used: Double, elapsed: TimeInterval, resetsAt: Date? = nil, period: TimeInterval = Period.fiveHours, id: String = "five_hour") -> (LimitWindow, Date) {
        let reset = resetsAt ?? start.addingTimeInterval(period)
        let now = reset.addingTimeInterval(elapsed - period)
        return (LimitWindow(id: id, label: "Session", usedFraction: used, resetsAt: reset, periodDuration: period), now)
    }

    func plan(_ memory: AlertMemory, _ windows: [LimitWindow], now: Date, tool: ToolID = .claude) -> (alerts: [PaceAlert], memory: AlertMemory) {
        NotificationScheduler.plan(memory: memory, readings: [UsageReading(tool: tool, windows: windows, plan: nil, fetchedAt: now, observedAt: nil)], now: now)
    }

    @Test func stagesFollowThePaceAndTheHourBoundary() {
        let (ahead, t0) = session(used: 0.1, elapsed: 3600)
        #expect(NotificationScheduler.stage(for: ahead, now: t0) == nil)
        let (onTrack, t1) = session(used: 0.19, elapsed: 3600)
        #expect(NotificationScheduler.stage(for: onTrack, now: t1) == .onTrack)
        let (behind, t2) = session(used: 0.5, elapsed: 3600)
        #expect(NotificationScheduler.stage(for: behind, now: t2) == .behind)
        let (soon, t3) = session(used: 0.7, elapsed: 5400)
        #expect(NotificationScheduler.stage(for: soon, now: t3) == .runningOut)
        let (out, t4) = session(used: 1, elapsed: 5400)
        #expect(NotificationScheduler.stage(for: out, now: t4) == .limitHit)
        #expect(NotificationScheduler.stage(for: LimitWindow(id: "x", label: "X", usedFraction: 0.9, resetsAt: nil), now: t4) == nil)
    }

    /// Used up is measured, not projected, so it is not held behind the tenth-of-the-period guard the projections
    /// wait for: a $50 budget spent by the 2nd used to go unreported until the 4th. It still waits on a reset
    /// that is ahead, so a stale snapshot at 100 % after its reset reports nothing.
    @Test func aUsedUpWindowIsReportedBeforeTheProjectionGuard() {
        let (out, t0) = session(used: 1, elapsed: 300)
        #expect(NotificationScheduler.stage(for: out, now: t0) == .limitHit)
        let (early, t1) = session(used: 0.9, elapsed: 300)
        #expect(NotificationScheduler.stage(for: early, now: t1) == nil)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let month = NotificationScheduler.budgetWindow(id: "budget_month", label: .key("Monthly budget"), spentUSD: 62, budgetUSD: 50,
                                                       period: BudgetPeriod.month(now: start, calendar: utc))
        #expect(NotificationScheduler.stage(for: month, now: start) == .limitHit)
        let stalePeriod = Period.fiveHours + 60
        let (stale, t2) = session(used: 1, elapsed: stalePeriod)
        #expect(NotificationScheduler.stage(for: stale, now: t2) == nil)
    }

    @Test func eachStageFiresOncePerPeriodAndOnlyAsAnEscalation() {
        let (behind, t0) = session(used: 0.5, elapsed: 3600)
        let first = plan(.empty, [behind], now: t0)
        #expect(first.alerts.map(\.stage) == [.behind])
        #expect(first.alerts.first?.tool == .claude)
        #expect(first.memory.entries["claude/five_hour"]?.stage == .behind)

        let again = plan(first.memory, [behind], now: t0.addingTimeInterval(180))
        #expect(again.alerts.isEmpty)
        #expect(again.memory == first.memory)

        let (calmer, t1) = session(used: 0.19, elapsed: 3600 + 900)
        let eased = plan(again.memory, [calmer], now: t1)
        #expect(eased.alerts.isEmpty)
        #expect(eased.memory.entries["claude/five_hour"]?.stage == .behind)

        let (back, t2) = session(used: 0.6, elapsed: 3600 + 1800)
        #expect(plan(eased.memory, [back], now: t2).alerts.isEmpty)

        let (soon, t3) = session(used: 0.7, elapsed: 5400)
        let escalated = plan(eased.memory, [soon], now: t3)
        #expect(escalated.alerts.map(\.stage) == [.runningOut])
        #expect(plan(escalated.memory, [soon], now: t3.addingTimeInterval(60)).alerts.isEmpty)
    }

    @Test func onTrackThenBehindAreTwoAlerts() {
        let (onTrack, t0) = session(used: 0.19, elapsed: 3600)
        let first = plan(.empty, [onTrack], now: t0)
        #expect(first.alerts.map(\.stage) == [.onTrack])
        let (behind, t1) = session(used: 0.5, elapsed: 3600 + 600)
        let second = plan(first.memory, [behind], now: t1)
        #expect(second.alerts.map(\.stage) == [.behind])
    }

    @Test func aNewPeriodFiresAgain() {
        let (behind, t0) = session(used: 0.5, elapsed: 3600)
        let first = plan(.empty, [behind], now: t0)
        let nextReset = start.addingTimeInterval(2 * Period.fiveHours)
        let (next, t1) = session(used: 0.5, elapsed: 3600, resetsAt: nextReset)
        let second = plan(first.memory, [next], now: t1)
        #expect(second.alerts.map(\.stage) == [.behind])
        #expect(second.memory.entries["claude/five_hour"]?.resetsAt == nextReset)
        #expect(second.memory.entries.count == 1)
    }

    @Test func aResetReportedAFewSecondsApartIsTheSamePeriod() {
        let (behind, t0) = session(used: 0.5, elapsed: 3600)
        let first = plan(.empty, [behind], now: t0)
        let (drifted, t1) = session(used: 0.5, elapsed: 3600 + 120, resetsAt: start.addingTimeInterval(Period.fiveHours + 45))
        #expect(plan(first.memory, [drifted], now: t1).alerts.isEmpty)
    }

    /// Every notice of a period carries the same instant, whatever the wire said on the read that raised it. 0.5.0
    /// pinned the watched reset, so the reminder and the reset notice held steady, but a pace notice planned from
    /// a reading whose reset had moved by seven seconds embedded the moved instant, and the withdrawal at the
    /// reset, built from the pinned window, never matched it: the "running out" stayed in Notification Center
    /// after the window had reset. Both halves are exercised here as the store runs them: the reading is pinned
    /// before `plan`, and `plan` pins against its own memory besides, so the two agree.
    @Test func aPaceNoticeSentAfterTheResetDriftedIsStillWithdrawnAtTheReset() throws {
        let (behind, t0) = session(used: 0.5, elapsed: 3600)
        let first = plan(.empty, [behind], now: t0)
        #expect(first.alerts.map(\.stage) == [.behind])
        let firstReset = try #require(behind.resetsAt)
        let key = AlertMemory.key(.claude, behind)
        let watched = [key: try #require(WatchedReset.watch(.claude, behind, now: t0))]

        let drift: TimeInterval = 7
        let (drifted, t1) = session(used: 0.7, elapsed: 5400 + drift, resetsAt: firstReset.addingTimeInterval(drift))
        let reading = UsageReading(tool: .claude, windows: [drifted], plan: nil, fetchedAt: t1, observedAt: nil)
        let pinned = NotificationScheduler.pinned(reading, memory: first.memory, watched: watched)
        #expect(pinned.windows.first?.resetsAt == firstReset)
        #expect(pinned.windows.first?.usedFraction == drifted.usedFraction)
        let second = NotificationScheduler.plan(memory: first.memory, readings: [pinned], now: t1)
        #expect(second.alerts.map(\.stage) == [.runningOut])
        #expect(second.memory.entries[key]?.resetsAt == firstReset)
        let asItCame = NotificationScheduler.plan(memory: first.memory, readings: [reading], now: t1)
        #expect(asItCame.alerts.map(\.identifier) == second.alerts.map(\.identifier))
        #expect(asItCame.memory == second.memory)

        let reset = NotificationScheduler.planResets(memory: second.memory, watched: Array(watched.values), now: firstReset.addingTimeInterval(1), options: .all)
        #expect(reset.alerts.map(\.stage) == [.reset])
        let passed = try #require(reset.alerts.first)
        let withdrawn = PaceAlert.identifiers(tool: passed.tool, window: passed.window)
        let sent = (first.alerts + second.alerts).map(\.identifier)
        let sentCount = 2
        #expect(Set(sent).count == sentCount)
        #expect(sent.allSatisfy(withdrawn.contains), "\(sent) are not all among \(withdrawn)")
    }

    /// The instant can live in the memory alone: an on-track window watches nothing (`WatchedReset.watch`), so
    /// when it falls behind on a read whose reset has moved, the watch made then must take the memory's instant,
    /// or the reset notice and the withdrawal would be built from a different one than the on-track notice. A
    /// reset outside the period is genuinely new and stays the reading's own.
    @Test func theMemoryAlonePinsAWindowNotYetWatched() throws {
        let (onTrack, t0) = session(used: 0.19, elapsed: 3600)
        let first = plan(.empty, [onTrack], now: t0)
        #expect(first.alerts.map(\.stage) == [.onTrack])
        #expect(WatchedReset.watch(.claude, onTrack, now: t0) == nil)
        let firstReset = try #require(onTrack.resetsAt)

        let (behind, t1) = session(used: 0.5, elapsed: 3600 + 600 + 7, resetsAt: firstReset.addingTimeInterval(7))
        let reading = UsageReading(tool: .claude, windows: [behind], plan: nil, fetchedAt: t1, observedAt: nil)
        let pinned = NotificationScheduler.pinned(reading, memory: first.memory, watched: [:])
        let pinnedWindow = try #require(pinned.windows.first)
        let watch = try #require(WatchedReset.watch(.claude, pinnedWindow, now: t1))
        #expect(watch.window.resetsAt == firstReset)
        let second = NotificationScheduler.plan(memory: first.memory, readings: [pinned], now: t1)
        #expect(second.alerts.map(\.stage) == [.behind])
        #expect(PaceAlert.identifiers(tool: .claude, window: watch.window).contains(try #require(first.alerts.first).identifier))

        let nextReset = firstReset.addingTimeInterval(Period.fiveHours)
        let (next, t2) = session(used: 0.5, elapsed: 3600, resetsAt: nextReset)
        let nextReading = UsageReading(tool: .claude, windows: [next], plan: nil, fetchedAt: t2, observedAt: nil)
        #expect(NotificationScheduler.pinned(nextReading, memory: second.memory, watched: [AlertMemory.key(.claude, behind): watch]).windows.first?.resetsAt == nextReset)
        #expect(NotificationScheduler.canonicalReset(tool: .claude, window: LimitWindow(id: "x", label: "X", usedFraction: 0.9, resetsAt: nil), memory: second.memory, watched: [:]) == nil)
    }

    @Test func theFirstTenthOfAWindowNeverInterrupts() {
        let (early, t0) = session(used: 0.2, elapsed: 600)
        #expect(Pace.status(for: early, now: t0) == .behind)
        #expect(NotificationScheduler.stage(for: early, now: t0) == nil)
        #expect(plan(.empty, [early], now: t0).alerts.isEmpty)
        let (later, t1) = session(used: 0.2, elapsed: 1800)
        #expect(plan(.empty, [later], now: t1).alerts.map(\.stage) == [.behind])
    }

    @Test func windowsWithoutAPaceAreLeftAloneAndEndedPeriodsAreForgotten() {
        let unlimited = LimitWindow(id: "included", label: "Included usage", usedFraction: nil, resetsAt: nil)
        let noPeriod = LimitWindow(id: "requests", label: "Fast requests", usedFraction: 0.9, resetsAt: start.addingTimeInterval(86400))
        let result = plan(.empty, [unlimited, noPeriod], now: start, tool: .cursor)
        #expect(result.alerts.isEmpty)
        #expect(result.memory == .empty)

        let (behind, t0) = session(used: 0.5, elapsed: 3600)
        let fired = plan(.empty, [behind], now: t0)
        let afterReset = plan(fired.memory, [], now: start.addingTimeInterval(Period.fiveHours + 60))
        #expect(afterReset.memory.entries.isEmpty)
    }

    @Test func toolsAreKeptApart() {
        let (behind, t0) = session(used: 0.5, elapsed: 3600)
        let claude = UsageReading(tool: .claude, windows: [behind], plan: nil, fetchedAt: t0, observedAt: nil)
        let codex = UsageReading(tool: .codex, windows: [LimitWindow(id: "session", label: "Session", usedFraction: 0.5, resetsAt: behind.resetsAt, periodDuration: Period.fiveHours)],
                                 plan: nil, fetchedAt: t0, observedAt: nil)
        let result = NotificationScheduler.plan(memory: .empty, readings: [claude, codex], now: t0)
        #expect(result.alerts.map(\.tool) == [.claude, .codex])
        #expect(Set(result.alerts.map(\.identifier)).count == 2)
    }

    /// A fixed suite name, emptied before and after, so cfprefsd leaves no plist per run under ~/Library/Preferences.
    @Test func memoryRoundTripsThroughDefaults() throws {
        let suite = "NotchmeterTests.Alerts.memoryRoundTrips"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AlertMemory.load(from: defaults) == .empty)
        let (behind, t0) = session(used: 0.5, elapsed: 3600)
        let memory = plan(.empty, [behind], now: t0).memory
        memory.save(to: defaults)
        #expect(AlertMemory.load(from: defaults) == memory)
    }

    @Test func notificationsAreNeverAvailableUnbundledOrInCommandLineRuns() {
        #expect(!Notifier.isAvailable(arguments: ["Notchmeter"], bundleIdentifier: nil))
        #expect(!Notifier.isAvailable(arguments: ["Notchmeter", "--smoke"], bundleIdentifier: "com.amirhackett.notchmeter"))
        #expect(!Notifier.isAvailable(arguments: ["Notchmeter", "--probe", "--no-prompt"], bundleIdentifier: "com.amirhackett.notchmeter"))
        #expect(Notifier.isAvailable(arguments: ["Notchmeter"], bundleIdentifier: "com.amirhackett.notchmeter"))
    }
}


/// Interruption levels per stage and event, the notices withdrawn at a reset, the limit-hit stage from the hook,
/// and the sound choices.
@Suite struct NotificationRoundTwo {
    init() { Localization.use(language: "en") }

    let now = DateParsing.iso8601("2026-09-01T12:00:00Z")!

    @Test func timeSensitiveIsReservedForRunningOutAndWaiting() {
        #expect(Notifier.level(for: .onTrack) == .passive)
        #expect(Notifier.level(for: .behind) == .active)
        #expect(Notifier.level(for: .runningOut) == .timeSensitive)
        #expect(Notifier.level(for: .limitHit) == .timeSensitive)
        #expect(Notifier.level(for: .reset) == .active)
        #expect(Notifier.level(for: .reminder) == .active)
        #expect(Notifier.level(for: .waiting(blocking: true)) == .timeSensitive)
        #expect(Notifier.level(for: .waiting(blocking: false)) == .timeSensitive, "an idle nudge that does get through is still the one notice that needs an answer")
        #expect(Notifier.level(for: .finished(turn: 600)) == .active)
        #expect(NotificationScheduler.Options(runningOut: false).wants(.limitHit) == false)
        #expect(NotificationScheduler.Options().wants(.limitHit))
    }

    @Test func aWindowsNoticesAreWithdrawnWhenItResets() {
        let window = LimitWindow(id: "five_hour", label: "Session", usedFraction: 0.9, resetsAt: now.addingTimeInterval(600), periodDuration: Period.fiveHours)
        let identifiers = PaceAlert.identifiers(tool: .claude, window: window)
        #expect(identifiers.count == 5)
        #expect(identifiers.contains(PaceAlert(tool: .claude, window: window, stage: .behind).identifier))
        #expect(identifiers.contains(PaceAlert(tool: .claude, window: window, stage: .limitHit).identifier))
        #expect(!identifiers.contains(PaceAlert(tool: .claude, window: window, stage: .reset).identifier))
        #expect(PaceAlert(tool: .claude, window: window, stage: .behind).identifier == "claude/five_hour/2/\(Int(window.resetsAt!.timeIntervalSince1970))")
    }

    @Test func theHookLimitHitFiresOncePerPeriodOnTheFullestWindow() throws {
        let reading = UsageReading(tool: .claude, windows: [
            LimitWindow(id: "five_hour", label: "Session", usedFraction: 0.97, resetsAt: now.addingTimeInterval(3600), periodDuration: Period.fiveHours),
            LimitWindow(id: "seven_day", label: "Weekly", usedFraction: 0.4, resetsAt: now.addingTimeInterval(3 * 86400), periodDuration: Period.week),
        ], plan: nil, fetchedAt: now, observedAt: nil)
        let first = NotificationScheduler.planLimitHit(memory: .empty, tool: .claude, reading: reading, now: now, options: .all)
        #expect(first.alerts.map(\.stage) == [.limitHit])
        #expect(first.alerts.first?.window.id == "five_hour")
        #expect(first.memory.entries["claude/five_hour"]?.stage == .limitHit)
        #expect(NotificationScheduler.planLimitHit(memory: first.memory, tool: .claude, reading: reading, now: now.addingTimeInterval(60), options: .all).alerts.isEmpty)
        // A later pace plan in the same period never repeats a lower stage.
        #expect(NotificationScheduler.plan(memory: first.memory, readings: [reading], now: now.addingTimeInterval(120)).alerts.isEmpty)
        #expect(NotificationScheduler.planLimitHit(memory: .empty, tool: .claude, reading: nil, now: now, options: .all).alerts.isEmpty)
        #expect(NotificationScheduler.planLimitHit(memory: .empty, tool: .claude, reading: reading, now: now, options: NotificationScheduler.Options(runningOut: false)).alerts.isEmpty)
        let body = Advisor.alertBody(first.alerts[0], context: Advisor.Context(readings: [], timeFormat: .twentyFourHour, now: now))
        #expect(body.hasPrefix("Claude session has run out.") || body.hasPrefix("At this rate"))
    }

    /// The hook's limit hit is identified by the period's instant like every other stage: raised after a behind
    /// notice, from a reading whose reset has moved by seven seconds, it carries the behind notice's instant, so the
    /// one withdrawal at the reset takes both down.
    @Test func theHookLimitHitCarriesThePeriodsInstant() throws {
        let firstReset = now.addingTimeInterval(4 * 3600)
        let behind = LimitWindow(id: "five_hour", label: "Session", usedFraction: 0.5, resetsAt: firstReset, periodDuration: Period.fiveHours)
        let paced = NotificationScheduler.plan(memory: .empty, readings: [UsageReading(tool: .claude, windows: [behind], plan: nil, fetchedAt: now, observedAt: nil)], now: now)
        #expect(paced.alerts.map(\.stage) == [.behind])
        let drifted = LimitWindow(id: "five_hour", label: "Session", usedFraction: 0.97, resetsAt: firstReset.addingTimeInterval(7), periodDuration: Period.fiveHours)
        let reading = UsageReading(tool: .claude, windows: [drifted], plan: nil, fetchedAt: now, observedAt: nil)
        let hit = NotificationScheduler.planLimitHit(memory: paced.memory, tool: .claude, reading: reading, now: now.addingTimeInterval(60), options: .all)
        #expect(hit.alerts.map(\.stage) == [.limitHit])
        #expect(hit.alerts.first?.window.resetsAt == firstReset)
        #expect(hit.memory.entries["claude/five_hour"]?.resetsAt == firstReset)
        let withdrawn = PaceAlert.identifiers(tool: .claude, window: behind)
        #expect(withdrawn.contains(try #require(hit.alerts.first).identifier))
    }

    @Test func soundChoicesMapToNotificationSounds() {
        #expect(NotificationSound.unSound(for: NotificationSound.none) == nil)
        #expect(NotificationSound.unSound(for: NotificationSound.defaultChoice) == .default)
        #expect(NotificationSound.unSound(for: "") == .default)
        #expect(NotificationSound.unSound(for: "system:Glass") != nil)
        #expect(NotificationSound.unSound(for: "custom:My Chime.aiff") != nil)
        #expect(NotificationSound.title(for: "system:Glass") == "Glass")
        #expect(NotificationSound.title(for: "custom:My Chime.aiff") == "My Chime")
        #expect(NotificationSound.title(for: NotificationSound.none) == "None")
        #expect(NotificationSound.systemSounds().contains("Glass"))
        #expect(NotificationSound.customSounds(folder: URL(fileURLWithPath: "/nonexistent")).isEmpty)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-sounds-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("src/chime.aiff")
        try? FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data([0, 1, 2]).write(to: source)
        let folder = dir.appendingPathComponent("Sounds")
        #expect((try? NotificationSound.importCustom(source, folder: folder)) == "custom:chime.aiff")
        #expect((try? NotificationSound.importCustom(source, folder: folder)) == "custom:chime 2.aiff")
        #expect(NotificationSound.customSounds(folder: folder) == ["chime 2.aiff", "chime.aiff"])
    }
}

/// The timer half of the scheduler answers to the Assistants switch: a tool that is off has no resets to announce.
@Suite struct WatchedResetsFollowTheSwitch {
    init() { Localization.use(language: "en") }

    /// Switching a tool off never touched its watched resets until 0.6.0, and `checkResets` did not ask whether a
    /// watch's tool was still shown, so a tool switched off at 90 % had its reset announced from the thirty-second
    /// timer all the same, and one switched back on after the reset announced a period that had ended while it
    /// was off. The reading's reset sits in the real future because `adopt` stamps the watch with the wall clock;
    /// the store left on is the control that says the watch was made at all. Each store gets a suite of its own,
    /// because the two would otherwise share one persisted memory and the control's reset would silence the other.
    @MainActor @Test func aToolSwitchedOffAnnouncesNoReset() async throws {
        let now = Date()
        let window = LimitWindow(id: "session", label: "Session", usedFraction: 0.9, resetsAt: now.addingTimeInterval(600), periodDuration: Period.fiveHours)
        let reading = UsageReading(tool: .codex, windows: [window], plan: nil, fetchedAt: now, observedAt: nil)
        let afterReset = now.addingTimeInterval(1200)

        func announced(suite: String, switchedOff: Bool) async throws -> [PaceAlert.Stage] {
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = UsageStore(prefs: Preferences(defaults: defaults), providers: [FixedProvider(tool: .codex, reading: reading)],
                                   cache: ReadingCache(defaults: defaults), defaults: defaults, drainLog: nil, reportFile: nil)
            let delivered = Delivered()
            store.deliverAlerts = { delivered.alerts += $0 }
            await store.refresh(.codex, force: true)
            #expect(store.status(.codex) == .ready(reading))
            if switchedOff {
                store.setEnabled(.codex, false)
                #expect(store.status(.codex) == .off)
            }
            delivered.alerts = []
            store.checkResets(now: afterReset)
            return delivered.alerts.map(\.stage)
        }

        let control = try await announced(suite: "NotchmeterTests.Alerts.resetWhileOn", switchedOff: false)
        #expect(control == [.reset])
        let off = try await announced(suite: "NotchmeterTests.Alerts.resetWhileOff", switchedOff: true)
        #expect(off.isEmpty, "a tool switched off announced \(off)")
    }
}

/// The alerts a store handed to `deliverAlerts`, in a box the closure can write to.
@MainActor private final class Delivered {
    var alerts: [PaceAlert] = []
}

/// Installed, and answers every read with the one reading it was given.
private struct FixedProvider: UsageProvider {
    let tool: ToolID
    let reading: UsageReading
    var refreshInterval: TimeInterval { 300 }
    func isInstalled() -> Bool { true }
    func fetch() async throws -> UsageReading { reading }
}
