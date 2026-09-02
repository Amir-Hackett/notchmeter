import Foundation
import Testing
@testable import Notchmeter

@Suite struct UnusedWindowCopy {
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
