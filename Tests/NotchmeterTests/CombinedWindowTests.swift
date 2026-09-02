import Foundation
import Testing
@testable import Notchmeter

/// The derived "All models" window (CombinedWindow, docs/accuracy.md): what it combines, what it refuses to
/// combine, and the figure it is allowed to publish.
@MainActor @Suite struct CombinedWindows {
    init() { Localization.use(language: "en") }

    let reset = DateParsing.iso8601("2026-09-30T00:00:00Z")!
    let sooner = DateParsing.iso8601("2026-09-10T00:00:00Z")!

    func window(_ id: String, _ used: Double?, model: String? = nil, resetsAt: Date? = nil, period: TimeInterval? = Period.month) -> LimitWindow {
        LimitWindow(id: id, label: .vendor(id), usedFraction: used, resetsAt: resetsAt, periodDuration: period, model: model)
    }

    /// Cursor's Enterprise shape: "Included usage" is the plan total and the two model splits are shares of it.
    var cursor: [LimitWindow] {
        [window("included", 0.62, resetsAt: reset),
         window("cursor_models", 0.44, model: "Cursor models", resetsAt: reset),
         window("other_models", 0.18, model: "Other models", resetsAt: reset)]
    }

    @Test func theVendorsOwnTotalIsAdoptedRatherThanRecomputed() throws {
        let combined = try #require(CombinedWindow.of(windows: cursor))
        #expect(combined.id == "combined")
        #expect(combined.label == "All models")
        // 0.62, not 0.44 + 0.18: the shares are rounded figures and their sum is not Cursor's arithmetic.
        #expect(combined.usedFraction == 0.62)
        #expect(combined.source == .localEstimate)
        #expect(combined.note == "Combined from the windows below")
        #expect(combined.model == nil)
        // No money: a share of a total and a dollar figure are not the same arithmetic.
        #expect(combined.amountUSD == nil)
    }

    @Test func oneModelWindowIsNotSomethingToCombine() {
        #expect(CombinedWindow.of(windows: Array(cursor.prefix(2))) == nil)
        #expect(CombinedWindow.of(windows: []) == nil)
    }

    /// A window with no limit says nothing, so it neither counts towards the two nor reads as a zero.
    @Test func windowsWithoutAFigureAreNeverCombined() {
        let unlimited = [window("included", nil, resetsAt: reset),
                         window("cursor_models", 0.44, model: "Cursor models", resetsAt: reset),
                         window("other_models", nil, model: "Other models", resetsAt: reset)]
        #expect(CombinedWindow.of(windows: unlimited) == nil)
    }

    /// With no published total the figure is the highest model window, never a mean that would read below one.
    @Test func withoutATotalTheHighestModelWins() throws {
        let noTotal = [window("cursor_models", 1, model: "Cursor models", resetsAt: reset),
                       window("other_models", 0, model: "Other models", resetsAt: reset)]
        let combined = try #require(CombinedWindow.of(windows: noTotal))
        #expect(combined.usedFraction == 1)
    }

    /// A tool-wide window from another period is not the parent of the model windows and is left alone.
    @Test func aTotalFromAnotherPeriodIsNotATotal() throws {
        let claude = [window("five_hour", 0.9, resetsAt: sooner, period: Period.fiveHours),
                      window("seven_day", 0.3, resetsAt: reset, period: Period.week),
                      window("scoped_fable", 0.5, model: "Fable", resetsAt: reset, period: Period.week),
                      window("scoped_opus", 0.4, model: "Opus", resetsAt: reset, period: Period.week)]
        let combined = try #require(CombinedWindow.of(windows: claude))
        // Not the 0.9 session and not the 0.3 weekly, which reads below a window it would have to contain.
        #expect(combined.usedFraction == 0.5)
        #expect(combined.periodDuration == Period.week)
    }

    /// The soonest reset among the windows covered: a countdown must not run past the first cap to bite.
    @Test func theResetIsTheSoonestItCovers() throws {
        let staggered = [window("cursor_models", 0.44, model: "Cursor models", resetsAt: reset),
                         window("other_models", 0.18, model: "Other models", resetsAt: sooner)]
        #expect(try #require(CombinedWindow.of(windows: staggered)).resetsAt == sooner)
    }

    /// It never combines itself: a reading that already carries one still derives from the vendor's windows.
    @Test func itIsNeverDerivedFromItself() throws {
        let once = try #require(CombinedWindow.of(windows: cursor))
        let twice = try #require(CombinedWindow.of(windows: cursor + [once]))
        #expect(twice.usedFraction == 0.62)
        #expect(twice.resetsAt == once.resetsAt)
    }

    /// The rings can be pointed at it, and the panel lists it above the windows its caption names.
    @Test func itIsSelectableAndListed() {
        let defaults = UserDefaults(suiteName: "NotchmeterTests.Combined")!
        defaults.removePersistentDomain(forName: "NotchmeterTests.Combined")
        defer { defaults.removePersistentDomain(forName: "NotchmeterTests.Combined") }
        let prefs = Preferences(defaults: defaults)
        let reading = UsageReading(tool: .cursor, windows: cursor, plan: "Enterprise", fetchedAt: Date(), observedAt: nil)
        #expect(prefs.panelWindows(of: reading).map(\.id) == ["combined", "included", "cursor_models", "other_models"])
        prefs.ringWindows[.cursor] = ["cursor_models", "other_models", "combined"]
        #expect(prefs.ringWindows(of: reading).map(\.id) == ["cursor_models", "other_models", "combined"])
        // Nothing chosen still falls back to two, so no existing layout gains a ring.
        prefs.ringWindows[.cursor] = []
        #expect(prefs.ringWindows(of: reading).map(\.id) == ["included", "cursor_models"])
    }
}
