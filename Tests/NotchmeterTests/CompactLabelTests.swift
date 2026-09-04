import Foundation
import Testing
@testable import Notchmeter

/// The digits beside a ring: the main window, a thin dot, the second window; one figure alone at Auto's outer
/// rung; "–" wherever there is no limit.
@Suite struct CompactLabels {
    let now = DateParsing.iso8601("2026-09-01T12:00:00Z")!

    func reading(_ windows: [LimitWindow]) -> UsageReading {
        UsageReading(tool: .claude, windows: windows, plan: nil, fetchedAt: now, observedAt: nil)
    }

    /// A five-hour window one hour in, so used × 5 is the projection: 0.1 lands ahead, 0.21 behind.
    func session(_ id: String, used: Double?) -> LimitWindow {
        LimitWindow(id: id, label: .key(id), usedFraction: used, resetsAt: now.addingTimeInterval(4 * 3600), periodDuration: Period.fiveHours)
    }

    @Test func mainAndSecondWindowInTheChosenSense() {
        let claude = reading([session("session", used: 0.14), session("weekly", used: 0.04), session("fable", used: 0.5)])
        #expect(CompactLabel.text(for: claude, display: .used, now: now) == "14% · 4%")
        #expect(CompactLabel.text(for: claude, display: .left, now: now) == "86% · 96%")
        #expect(CompactLabel.text(for: reading([session("session", used: 0.125)]), display: .used, now: now) == "13%")
        #expect(CompactLabel.text(for: reading([session("session", used: 0.125)]), display: .left, now: now) == "88%")
    }

    @Test func aDashForNoLimitAndForNoReading() {
        #expect(CompactLabel.text(for: nil, display: .used, now: now) == "–")
        #expect(CompactLabel.text(for: reading([]), display: .left, now: now) == "–")
        let codex = reading([LimitWindow(id: "session", label: "Session", usedFraction: nil, resetsAt: nil, note: "No data"),
                             LimitWindow(id: "monthly", label: "Monthly", usedFraction: 0, resetsAt: now.addingTimeInterval(10 * 86400), periodDuration: 30 * Period.day)])
        #expect(CompactLabel.text(for: codex, display: .used, now: now) == "– · 0%")
        #expect(CompactLabel.text(for: codex, display: .left, now: now) == "– · 100%")
        let unlimited = reading([LimitWindow(id: "included", label: "Included usage", usedFraction: nil, resetsAt: nil, note: "Unlimited")])
        #expect(CompactLabel.segments(for: unlimited, display: .used, now: now) == [CompactLabel.Segment(text: "–", pace: nil)])
    }

    @Test func eachFigureCarriesItsOwnPace() {
        let segments = CompactLabel.segments(for: reading([session("session", used: 0.1), session("weekly", used: 0.21)]), display: .used, now: now)
        #expect(segments.map(\.text) == ["10%", "21%"])
        #expect(segments.map(\.pace) == [.ahead, .behind])
        let left = CompactLabel.segments(for: reading([session("session", used: 0.19)]), display: .left, now: now)
        #expect(left == [CompactLabel.Segment(text: "81%", pace: .onTrack)])
    }

    /// Auto's outer-figure rung: the first window's figure alone — no dot, no second figure, and no countdown,
    /// which is most of the width the second figure was.
    @Test func theOuterFigureStandsAlone() {
        let windows = [session("session", used: 0.14), session("weekly", used: 0.04), session("fable", used: 0.5)]
        #expect(CompactLabel.text(for: windows, display: .used, figures: .outer, countdown: true, now: now) == "14%")
        #expect(CompactLabel.text(for: windows, display: .left, figures: .outer, now: now) == "86%")
        #expect(CompactLabel.segments(for: windows, display: .used, figures: .outer, now: now) == [CompactLabel.Segment(text: "14%", pace: .ahead)])
        // The countdown's home at `.all` is unchanged, and three windows draw three figures.
        #expect(CompactLabel.text(for: windows, display: .used, countdown: true, now: now) == "14% 4h · 4% · 50%")
        // An outer window without a limit still answers the dash, as does no window at all.
        #expect(CompactLabel.text(for: [], display: .used, figures: .outer, now: now) == "–")
        let codex = [LimitWindow(id: "session", label: "Session", usedFraction: nil, resetsAt: nil, note: "No data"),
                     LimitWindow(id: "monthly", label: "Monthly", usedFraction: 0, resetsAt: now.addingTimeInterval(10 * 86400), periodDuration: 30 * Period.day)]
        #expect(CompactLabel.text(for: codex, display: .used, figures: .outer, now: now) == "–")
        // The outer figure is whichever window is first, not always the session: the rings' order decides.
        #expect(CompactLabel.text(for: Array(windows.dropFirst()), display: .used, figures: .outer, now: now) == "4%")
    }
}
