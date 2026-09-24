import CoreGraphics
import Foundation
import Testing
@testable import Notchmeter

/// The Welcome tour's step logic: where each key and button takes it, and where it refuses to go.
@Suite struct WelcomeTourSteps {
    @Test func theTourHasFourStepsInOrderAndStartsOnTheRings() {
        let steps = WelcomeStep.allCases
        #expect(steps == [.rings, .panel, .sessions, .connect])
        #expect(WelcomeTour.count == 4)
        #expect(WelcomeView.steps == 4)
        let tour = WelcomeTour()
        #expect(tour.step == .rings)
        #expect(tour.isFirst)
        #expect(!tour.isLast)
        let numbers = steps.map(\.number)
        #expect(numbers == [1, 2, 3, 4])
    }

    @Test func backOnTheFirstStepStaysPut() {
        var tour = WelcomeTour()
        #expect(tour.back() == .stayed)
        #expect(tour.press(.left) == .stayed)
        #expect(tour.step == .rings)
    }

    @Test func theRightArrowWalksToTheLastStepAndStopsThere() {
        var tour = WelcomeTour()
        #expect(tour.press(.right) == .moved(.panel))
        #expect(tour.press(.right) == .moved(.sessions))
        #expect(tour.press(.right) == .moved(.connect))
        #expect(tour.isLast)
        // A flick past the end must not close the window on someone looking for a fifth page.
        #expect(tour.press(.right) == .stayed)
        #expect(tour.step == .connect)
    }

    @Test func returnMovesOnAndFinishesOnlyOnTheLastStep() {
        var tour = WelcomeTour()
        for expected in [WelcomeStep.panel, .sessions, .connect] {
            #expect(tour.press(.enter) == .moved(expected))
        }
        #expect(tour.press(.enter) == .finished)
        #expect(tour.step == .connect, "finishing leaves the step where it was, for the oracle's closing line")
    }

    @Test func escapeFinishesFromAnyStep() {
        for step in WelcomeStep.allCases {
            var tour = WelcomeTour(step: step)
            #expect(tour.press(.escape) == .finished)
        }
    }

    @Test func theLeftArrowWalksBackAndRecordsTheDirection() {
        var tour = WelcomeTour(step: .connect)
        #expect(tour.press(.left) == .moved(.sessions))
        #expect(!tour.forward)
        #expect(tour.press(.right) == .moved(.connect))
        #expect(tour.forward)
    }

    @Test func aDotGoesStraightToItsStepAndTheCurrentDotDoesNothing() {
        var tour = WelcomeTour()
        #expect(tour.go(to: .connect) == .moved(.connect))
        #expect(tour.forward)
        #expect(tour.go(to: .connect) == .stayed)
        #expect(tour.go(to: .rings) == .moved(.rings))
        #expect(!tour.forward)
        #expect(tour.go(to: nil) == .stayed)
    }

    @Test func oracleNamesAreStableAndDistinct() {
        let names = WelcomeStep.allCases.map(\.name)
        #expect(names == ["rings", "panel", "sessions", "connect"])
        let fields = WelcomeTour.oracleFields("step", step: .sessions)
        let line = Oracle.line(event: "welcome", fields: fields, at: Date(timeIntervalSince1970: 0), home: "")
        #expect(line == #"{"action":"step","count":4,"event":"welcome","index":3,"step":"sessions","t":"1970-01-01T00:00:00.000Z"}"#)
        let closed = Oracle.line(event: "welcome", fields: WelcomeTour.oracleFields("closed", step: nil), at: Date(timeIntervalSince1970: 0), home: "")
        #expect(closed == #"{"action":"closed","count":4,"event":"welcome","index":null,"step":null,"t":"1970-01-01T00:00:00.000Z"}"#)
    }
}

/// How a preview is scaled into its stage.
@Suite struct WelcomePreviewScale {
    let room = CGSize(width: 552, height: 210)

    @Test func nothingIsScaledBeforeItIsMeasured() {
        let unmeasured = PreviewScale.fit(.zero, in: room, largest: 2)
        #expect(unmeasured == 1)
    }

    @Test func aTallPreviewComesDownToFitTheHeight() {
        let scale = PreviewScale.fit(CGSize(width: 352, height: 420), in: room, largest: 1)
        let expected: CGFloat = 0.5
        #expect(scale == expected)
    }

    @Test func aWidePreviewComesDownToFitTheWidth() {
        let scale = PreviewScale.fit(CGSize(width: 1104, height: 100), in: room, largest: 1)
        let expected: CGFloat = 0.5
        #expect(scale == expected)
    }

    @Test func aShortPreviewGrowsNoFurtherThanItsCeiling() {
        let strip = CGSize(width: 200, height: 32)
        let grown = PreviewScale.fit(strip, in: room, largest: 2)
        let ceiling: CGFloat = 2
        #expect(grown == ceiling)
        let card = PreviewScale.fit(strip, in: room, largest: 1)
        let unchanged: CGFloat = 1
        #expect(card == unchanged, "a card is never drawn larger than the panel draws it")
    }
}

/// The moment the tour's first two steps draw: a turn running, nothing asked, no mark on any ring.
@Suite struct DemoFixtureWorkingMoment {
    let now = DateParsing.iso8601("2026-09-01T15:00:00Z")!

    @Test func theWorkingMomentHasATurnRunningAndNothingAsked() {
        let sessions = DemoFixtures.sessions(now: now, moment: .working)
        #expect(sessions.pending(now: now).isEmpty)
        #expect(sessions.waiting.isEmpty)
        #expect(sessions.working.count == 1)
        #expect(sessions.isWorking(.claude))
        let signal = ToolSignal.resolve(waiting: sessions.waiting(of: .claude).count, finish: sessions.finish(of: .claude, now: now),
                                        working: sessions.isWorking(.claude), attended: nil, now: now)
        #expect(signal == nil)
    }
}
