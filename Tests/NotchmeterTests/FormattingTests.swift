import Foundation
import Testing
@testable import Notchmeter

@Suite struct UnusedWindowCopy {
    init() { Localization.use(language: "en") }

    @Test func namesThePeriodInsteadOfASlidingReset() {
        #expect(ResetText.unusedLine(period: 30 * 86400) == "Nothing used · 30-day window")
        #expect(ResetText.unusedLine(period: Period.week) == "Nothing used · 7-day window")
        #expect(ResetText.unusedLine(period: Period.fiveHours) == "Nothing used · 5-hour window")
    }

    @Test func windowNamesRoundToTheLargestWholeUnit() {
        #expect(ResetText.windowName(period: 86400) == "1-day")
        #expect(ResetText.windowName(period: 36 * 3600) == "36-hour")
        #expect(ResetText.windowName(period: 90 * 60) == "90-minute")
        #expect(ResetText.windowName(period: 30) == "1-minute")
        #expect(ResetText.windowName(period: 2_592_000.4) == "30-day")
    }
}

/// The note beside a meter projects the window to its reset; an untouched window gets none, its tick alone.
@Suite struct PaceNotes {
    init() { Localization.use(language: "en") }

    let now = DateParsing.iso8601("2026-09-01T12:00:00Z")!

    func monthly(used: Double) -> LimitWindow {
        LimitWindow(id: "monthly", label: "Monthly", usedFraction: used, resetsAt: now.addingTimeInterval(18 * 86400), periodDuration: 30 * Period.day)
    }

    @Test func nothingUsedMeansNoNote() {
        #expect(Pace.note(for: monthly(used: 0), now: now) == nil)
        #expect(Pace.status(for: monthly(used: 0), now: now) == .ahead)
        #expect(Pace.elapsedFraction(resetsAt: now.addingTimeInterval(18 * 86400), period: 30 * Period.day, now: now) == 0.4)
    }

    @Test func anyUseProjectsToTheReset() {
        // 10 % in 12 of 30 days projects to 25 %.
        #expect(Pace.note(for: monthly(used: 0.1), now: now)?.text == "~75% left at reset")
        #expect(Pace.note(for: monthly(used: 0.1), now: now)?.status == .ahead)
    }
}
