import Foundation
import Testing
@testable import Notchmeter

/// Windows are five hours long with one hour elapsed unless stated, so used × 5 is the projected fraction:
/// 0.18 projects to 0.9 (ahead), 0.19 to 0.95 (on track), 0.21 to 1.05 (behind).
@Suite struct PresenceRules {
    let now = DateParsing.iso8601("2026-09-01T12:00:00Z")!

    func window(_ id: String = "session", used: Double?, elapsed: TimeInterval = 3600, period: TimeInterval = Period.fiveHours) -> LimitWindow {
        LimitWindow(id: id, label: id.capitalized, usedFraction: used, resetsAt: now.addingTimeInterval(period - elapsed), periodDuration: period)
    }

    func level(_ windows: [LimitWindow], awaiting: Bool = false) -> PresenceLevel {
        Presence.level(windows: windows, awaitingInput: awaiting, now: now)
    }

    @Test func quietWhileEverythingIsLowAndAhead() {
        #expect(level([]) == .quiet)
        #expect(level([window(used: nil)]) == .quiet)
        #expect(level([window(used: 0.1)]) == .quiet)
        #expect(level([window(used: 0.18)]) == .quiet)
        #expect(level([window(used: 0.39, elapsed: 4 * 3600), window("weekly", used: 0.2, elapsed: 3 * 86400, period: Period.week)]) == .quiet)
    }

    @Test func legibleFromFortyPercentOrOnTrack() {
        #expect(level([window(used: 0.4, elapsed: 3 * 3600)]) == .legible)
        #expect(level([window(used: 0.19)]) == .legible)
        #expect(level([window(used: 0.1), window("weekly", used: 0.55, elapsed: 5 * 86400, period: Period.week)]) == .legible)
        #expect(level([LimitWindow(id: "extra", label: "Extra usage", usedFraction: 0.99, resetsAt: nil)]) == .legible)
    }

    @Test func urgentWhenBehindOutOrWaitingOnTheUser() {
        #expect(level([window(used: 0.21)]) == .urgent)
        #expect(level([window(used: 1)]) == .urgent)
        #expect(level([window(used: 0.05), window("weekly", used: 0.3, elapsed: 86400, period: Period.week)]) == .urgent)
        #expect(level([window(used: 0.1)], awaiting: true) == .urgent)
        #expect(level([], awaiting: true) == .urgent)
    }

    @Test func tooEarlyForAPaceReadingFallsBackToUsage() {
        #expect(level([window(used: 0.3, elapsed: 30)]) == .quiet)
        #expect(level([window(used: 0.5, elapsed: 30)]) == .legible)
    }
}

@Suite struct SpokenCopy {
    let now = DateParsing.iso8601("2026-09-01T12:00:00Z")!

    @Test func expandsTheAbbreviations() {
        #expect(Spoken.phrase("~58% left at reset") == "about 58 percent left at reset")
        #expect(Spoken.phrase("Resets in 4d 17h") == "Resets in 4 days 17 hours")
        #expect(Spoken.phrase("Runs out in 1h 1m") == "Runs out in 1 hour 1 minute")
        #expect(Spoken.phrase("Next update in 45s · on battery") == "Next update in 45 seconds, on battery")
        #expect(Spoken.phrase("Last hour $8.40 · 6x your usual") == "Last hour $8.40, 6 times your usual")
        #expect(Spoken.phrase("Resets today at 10:49 PM") == "Resets today at 10:49 PM")
    }

    @Test func lineDropsEmptyParts() {
        #expect(Spoken.line("14% used", "", nil, "~58% left at reset") == "14 percent used, about 58 percent left at reset")
    }

    @Test func statusReadsEachWindowWithItsPace() {
        let reading = UsageReading(tool: .claude, windows: [
            LimitWindow(id: "session", label: "Session", usedFraction: 0.19, resetsAt: now.addingTimeInterval(4 * 3600), periodDuration: Period.fiveHours),
            LimitWindow(id: "weekly", label: "Weekly", usedFraction: 0.05, resetsAt: now.addingTimeInterval(6 * 86400), periodDuration: Period.week),
            LimitWindow(id: "extra", label: "Extra usage", usedFraction: nil, resetsAt: nil),
        ], plan: nil, fetchedAt: now, observedAt: nil)
        #expect(Spoken.status(.ready(reading), awaitingInput: false, now: now) == "Session 19 percent used, close to pace; Weekly 5 percent used")
        #expect(Spoken.status(.ready(reading), awaitingInput: true, now: now).hasPrefix("waiting for your input; Session"))
        #expect(Spoken.status(.needsAttention("Needs your permission", cached: nil), awaitingInput: false, now: now) == "Needs your permission")
        #expect(Spoken.status(.waiting, awaitingInput: false, now: now) == "waiting for the first reading")
    }
}
