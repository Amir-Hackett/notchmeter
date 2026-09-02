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
        #expect(NotificationScheduler.stage(for: out, now: t4) == .behind)
        #expect(NotificationScheduler.stage(for: LimitWindow(id: "x", label: "X", usedFraction: 0.9, resetsAt: nil), now: t4) == nil)
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

    @Test func memoryRoundTripsThroughDefaults() throws {
        let suite = "notchmeter-alerts-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
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
