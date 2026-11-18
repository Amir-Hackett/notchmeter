import Foundation
import Testing
@testable import Notchmeter

/// The ring pickers in Settings on a seat Cursor meters nothing for (an Enterprise seat billed on-demand), where
/// until 0.9.27 every pick but Today's spend snapped back to it. A pick is now what the rings show; two rings
/// picked for one window change places; *Monthly usage* has something to fill a ring with; and a pick saved under
/// the old rule is cleared once, so an upgrade does not turn rings that showed Today's spend into empty ones.
@MainActor @Suite struct RingPicks {
    static let now = DateParsing.iso8601("2026-11-18T16:00:00Z")!
    static let cycleEnd = DateParsing.iso8601("2026-12-01T00:00:00Z")!

    static let spend = LimitWindow(id: "spend_today", label: .key("Today's spend"), usedFraction: 0.22, resetsAt: now.addingTimeInterval(8 * 3600),
                                   periodDuration: Period.day, source: .localEstimate, amountUSD: 15.19)
    static let monthly = LimitWindow(id: "included", label: .key("Monthly usage"), usedFraction: nil, resetsAt: cycleEnd,
                                     note: "$412.00 so far, no limit set", periodDuration: 30 * Period.day, amountUSD: 412)
    static let cursorModels = LimitWindow(id: "cursor_models", label: "Cursor models", usedFraction: nil, resetsAt: cycleEnd, model: "Cursor models")
    static let otherModels = LimitWindow(id: "other_models", label: "Other models", usedFraction: nil, resetsAt: cycleEnd, model: "Other models")
    static let team = LimitWindow(id: "team_on_demand", label: .key("Team on-demand"), usedFraction: nil, resetsAt: cycleEnd,
                                  note: "$1,204.00 so far, no limit set", hiddenByDefault: true, amountUSD: 1204)
    static let seat = UsageReading(tool: .cursor, windows: [spend, monthly, cursorModels, otherModels, team], plan: nil, fetchedAt: now, observedAt: nil)

    func withSuite(_ name: String, _ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "NotchmeterTests.RingPicks.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    // MARK: - A pick sticks

    /// Every option in all three pickers, on the seat where none of them stuck.
    @Test func everyChoiceSticksOnEveryRing() {
        for index in 0..<RingSelection.maximum {
            for choice in Self.seat.windows {
                withSuite("sticks") { defaults in
                    let prefs = Preferences(defaults: defaults)
                    // The rings start from the default, Today's spend and the cycle line, with a third chosen so that
                    // the third picker has a ring to write to.
                    prefs.ringWindows[.cursor] = ["spend_today", "included", "cursor_models"]
                    prefs.setRingWindow(at: index, to: choice.id, in: Self.seat)
                    let rings = prefs.ringWindows(of: Self.seat).map(\.id)
                    #expect(rings.count == 3, "picking \(choice.id) for ring \(index) kept three rings")
                    #expect(rings[index] == choice.id, "ring \(index) shows \(choice.id) once it is picked")
                    #expect(Set(rings).count == 3, "no window is drawn twice")
                }
            }
        }
    }

    /// Picking a window another ring already shows swaps the two. Written as picked, [A, A], the rings dropped the
    /// duplicate and filled the gap from the data, and the picker just set jumped to a window nobody chose.
    @Test func aWindowAlreadyOnAnotherRingChangesPlacesWithIt() {
        #expect(RingSelection.picking("b", at: 0, drawn: ["a", "b"]) == ["b", "a"])
        #expect(RingSelection.picking("a", at: 1, drawn: ["a", "b"]) == ["b", "a"])
        #expect(RingSelection.picking("a", at: 2, drawn: ["a", "b", "c"]) == ["c", "b", "a"])
        // A window on no ring replaces the one it is picked for.
        #expect(RingSelection.picking("c", at: 1, drawn: ["a", "b"]) == ["a", "c"])
        #expect(RingSelection.picking("c", at: 2, drawn: ["a", "b"]) == ["a", "b", "c"])
        // Picking what the ring already shows changes nothing.
        #expect(RingSelection.picking("a", at: 0, drawn: ["a", "b"]) == ["a", "b"])
        // None empties the ring and closes the gap; the rings are drawn outermost first.
        #expect(RingSelection.picking("", at: 1, drawn: ["a", "b", "c"]) == ["a", "c"])
        #expect(RingSelection.picking("", at: 0, drawn: ["a", "b"]) == ["b"])
        // The outer window picked for an empty third ring moves there, and the gap it leaves closes.
        #expect(RingSelection.picking("a", at: 2, drawn: ["a", "b"]) == ["b", "a"])
        // A ring that does not exist is not written.
        #expect(RingSelection.picking("c", at: 3, drawn: ["a", "b"]) == ["a", "b"])

        withSuite("swap") { defaults in
            let prefs = Preferences(defaults: defaults)
            prefs.ringWindows[.cursor] = ["spend_today", "included"]
            prefs.setRingWindow(at: 1, to: "spend_today", in: Self.seat)
            let expected = ["included", "spend_today"]
            #expect(prefs.ringWindows(of: Self.seat).map(\.id) == expected)
        }
    }

    /// The picker names the choices that have nothing to fill a ring with, so picking one is not a surprise.
    @Test func thePickerSaysWhichChoicesDrawAnEmptyRing() {
        #expect(Preferences.ringChoiceTitle(Self.spend) == "Today's spend")
        #expect(Preferences.ringChoiceTitle(Self.monthly) == "Monthly usage — draws an empty ring")
        #expect(Preferences.ringChoiceTitle(Self.otherModels) == "Other models — draws an empty ring")
        #expect(Preferences.ringChoiceTitle(Self.team) == "Team on-demand — draws an empty ring")
    }

    // MARK: - What a pick does to the Hide boxes

    /// Picking a hidden window for a ring shows it on the card, since a ring over a window the card hides would
    /// describe a figure the card does not. Emptying the ring leaves it shown: Hide is the user's, and a pick does
    /// not take back what it revealed. Nothing else on the card moves either way.
    @Test func aPickRevealsItsWindowAndClearingTheRingLeavesTheCardAlone() {
        withSuite("hide") { defaults in
            let prefs = Preferences(defaults: defaults)
            #expect(!prefs.shownWindows(of: Self.seat).contains { $0.id == "team_on_demand" })
            let before = prefs.shownWindows(of: Self.seat).map(\.id)
            prefs.setRingWindow(at: 1, to: "team_on_demand", in: Self.seat)
            #expect(prefs.ringWindows(of: Self.seat).map(\.id) == ["spend_today", "team_on_demand"])
            #expect(prefs.shownWindows(of: Self.seat).map(\.id) == before + ["team_on_demand"])
            prefs.setRingWindow(at: 1, to: "", in: Self.seat)
            #expect(prefs.ringWindows(of: Self.seat).map(\.id) == ["spend_today"])
            #expect(prefs.shownWindows(of: Self.seat).map(\.id) == before + ["team_on_demand"])
            // Hidden again by hand, it leaves the card and stays off the rings.
            prefs.setHidden(true, window: Self.team, in: Self.seat)
            #expect(prefs.shownWindows(of: Self.seat).map(\.id) == before)
        }
    }

    // MARK: - Picks saved before 0.9.27

    /// Rings saved for the model meters drew Today's spend under the old rule. Honoured as saved they would draw
    /// empty at the upgrade, so that pick is cleared, once, and the rings go on showing what they showed.
    @Test func aPickTheOldRuleSetAsideIsClearedOnce() {
        withSuite("legacy") { defaults in
            defaults.set(["cursor": ["cursor_models", "other_models"]], forKey: "ringWindows")
            let prefs = Preferences(defaults: defaults)
            #expect(prefs.legacyRingPicksSettled.isEmpty)
            prefs.settleLegacyRingPicks(with: Self.seat)
            #expect(prefs.ringWindows[.cursor] == nil)
            #expect(prefs.ringWindows(of: Self.seat).map(\.id) == ["spend_today", "included"])
            #expect(prefs.legacyRingPicksSettled == [.cursor])
            // Picked again after the upgrade it is deliberate, and a later reading does not clear it.
            prefs.setRingWindow(at: 0, to: "other_models", in: Self.seat)
            prefs.settleLegacyRingPicks(with: Self.seat)
            #expect(prefs.ringWindows(of: Self.seat).first?.id == "other_models")
            // And the answer survives a relaunch.
            #expect(Preferences(defaults: defaults).legacyRingPicksSettled == [.cursor])
        }
    }

    @Test func aPickTheOldRuleHonouredIsLeftAsItIs() {
        withSuite("kept") { defaults in
            defaults.set(["cursor": ["included", "spend_today"], "claude": ["weekly"]], forKey: "ringWindows")
            let prefs = Preferences(defaults: defaults)
            prefs.settleLegacyRingPicks(with: Self.seat)
            #expect(prefs.ringWindows[.cursor] == ["included", "spend_today"])
            #expect(prefs.ringWindows[.claude] == ["weekly"])
            #expect(prefs.legacyRingPicksSettled == [.cursor])
        }
    }

    /// A reading with no comparison window says nothing about the old rule, which only ever applied beside one:
    /// the pick stays and the question stays open for the seat that has one.
    @Test func aReadingWithNoComparisonWindowSettlesNothing() {
        withSuite("open") { defaults in
            defaults.set(["cursor": ["cursor_models", "other_models"]], forKey: "ringWindows")
            let prefs = Preferences(defaults: defaults)
            let metered = UsageReading(tool: .cursor, windows: [Self.monthly, Self.cursorModels, Self.otherModels], plan: nil, fetchedAt: Self.now, observedAt: nil)
            prefs.settleLegacyRingPicks(with: metered)
            #expect(prefs.ringWindows[.cursor] == ["cursor_models", "other_models"])
            #expect(prefs.legacyRingPicksSettled.isEmpty)
            // A pick made in Settings closes the question for its tool without a reading.
            prefs.setRingWindow(at: 0, to: "included", in: metered)
            #expect(prefs.legacyRingPicksSettled == [.cursor])
        }
    }

    /// A ring picked for another assistant settles nothing for Cursor: its saved picks are still looked at when its
    /// own reading comes (CodeRabbit, #165). One flag for every tool had a Claude pick close Cursor's question.
    @Test func aPickForAnotherAssistantLeavesCursorsQuestionOpen() {
        withSuite("other-tool") { defaults in
            defaults.set(["cursor": ["cursor_models", "other_models"]], forKey: "ringWindows")
            let prefs = Preferences(defaults: defaults)
            let session = LimitWindow(id: "session", label: "Session", usedFraction: 0.3, resetsAt: Self.cycleEnd, periodDuration: Period.fiveHours)
            let weekly = LimitWindow(id: "weekly", label: "Weekly", usedFraction: 0.1, resetsAt: Self.cycleEnd, periodDuration: Period.week)
            let claude = UsageReading(tool: .claude, windows: [session, weekly], plan: nil, fetchedAt: Self.now, observedAt: nil)
            prefs.setRingWindow(at: 0, to: "weekly", in: claude)
            #expect(prefs.legacyRingPicksSettled == [.claude])
            prefs.settleLegacyRingPicks(with: Self.seat)
            #expect(prefs.ringWindows[.cursor] == nil)
            #expect(prefs.ringWindows[.claude] == ["weekly", "session"])
            #expect(prefs.legacyRingPicksSettled == [.claude, .cursor])
        }
    }

    /// A saved pick with "All models" in it was honoured by the old rule wherever the combined ring had a figure,
    /// so it is not one that rule set aside, whatever else was picked beside it (CodeRabbit, #165).
    @Test func aPickWithACombinedRingThatHadAFigureWasNotSetAside() {
        let counting = [Self.spend, Self.monthly,
                        LimitWindow(id: "cursor_models", label: "Cursor models", usedFraction: 0.1, resetsAt: Self.cycleEnd, model: "Cursor models"),
                        LimitWindow(id: "other_models", label: "Other models", usedFraction: 0.2, resetsAt: Self.cycleEnd, model: "Other models")]
        #expect(CombinedWindow.of(windows: counting)?.usedFraction != nil)
        #expect(!RingSelection.wasSetAside(chosen: [CombinedWindow.id, "included"], shown: counting))
        #expect(RingSelection.wasSetAside(chosen: ["included"], shown: counting))
        // With the meters dead there is nothing to combine, and the same pick is one the rule set aside.
        #expect(RingSelection.wasSetAside(chosen: [CombinedWindow.id, "included"], shown: Self.seat.windows))
    }

    // MARK: - Monthly usage against the cycle before

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func days(_ costs: [(String, Double)]) -> [Date: CostHistory.Record] {
        Dictionary(uniqueKeysWithValues: costs.map {
            (calendar.startOfDay(for: DateParsing.iso8601($0.0 + "T12:00:00Z")!), CostHistory.Record(cost: $0.1, tokens: TokenBreakdown(), byModel: [:], byProject: [:]))
        })
    }

    /// The cycle's dollars have no limit to fill a ring against, so they fill against last cycle's total, as a
    /// comparison worked out here: it paces, reads in dollars beside its ring, and never runs out or warns.
    @Test func monthlyUsageFillsAgainstTheCycleBefore() throws {
        let cycleStart = DateParsing.iso8601("2026-11-01T00:00:00Z")!
        // Last cycle, 1 October to 1 November: $1,000 over three days. One day before it and this cycle's own days
        // are outside the sum.
        let history = days([("2026-09-30", 500), ("2026-10-01", 400), ("2026-10-15", 350), ("2026-10-31", 250), ("2026-11-03", 300), ("2026-11-17", 112)])
        let windows = CursorProvider.withCycleComparison(Self.seat.windows, days: history, cycleStart: cycleStart, now: Self.now, calendar: calendar)
        #expect(windows.map(\.id) == Self.seat.windows.map(\.id))
        let monthly = try #require(windows.first { $0.id == "included" })
        #expect(abs((monthly.usedFraction ?? 0) - 0.412) < 1e-9)
        #expect(monthly.note == "$412.00 so far, $1,000 last cycle")
        #expect(monthly.label == "Monthly usage")
        #expect(monthly.isComparison)
        #expect(monthly.source == .localEstimate)
        #expect(monthly.amountUSD == 412)
        #expect(monthly.resetsAt == Self.cycleEnd)
        // Nothing else on the seat is touched: the team's spend is not this seat's history, and has no cycle before.
        #expect(windows.filter { $0.id != "included" } == Self.seat.windows.filter { $0.id != "included" })
        #expect(Preferences.ringChoiceTitle(monthly) == "Monthly usage")

        // A comparison: dollars beside the ring with no countdown, a calm pace, a note that names the cycle, and
        // nothing that treats it as a limit.
        #expect(CompactLabel.text(for: [monthly], display: .used, countdown: true, now: Self.now) == "$412")
        #expect(CompactLabel.text(for: [Self.spend, monthly], display: .left, countdown: true, now: Self.now) == "$15 · $412")
        #expect(Pace.status(for: monthly, now: Self.now) == .ahead)
        let note = try #require(Pace.note(for: monthly, now: Self.now))
        #expect(note.text.hasPrefix("Heading for ~") && note.text.hasSuffix("% of last cycle"))
        #expect(Pace.note(for: Self.spend, now: Self.now)?.text.hasSuffix("% today") == true)
        let reading = UsageReading(tool: .cursor, windows: windows, plan: nil, fetchedAt: Self.now, observedAt: nil)
        #expect(Advisor.mainWindow(of: reading) == nil)
        #expect(WatchedReset.watch(.cursor, monthly, now: Self.now) == nil)

        // Past last cycle's total the ring is full and the figure keeps counting.
        let more = Self.seat.windows.map { $0.id == "included" ? LimitWindow(id: "included", label: .key("Monthly usage"), usedFraction: nil, resetsAt: Self.cycleEnd, periodDuration: 30 * Period.day, amountUSD: 1500) : $0 }
        let over = try #require(CursorProvider.withCycleComparison(more, days: history, cycleStart: cycleStart, now: Self.now, calendar: calendar).first { $0.id == "included" })
        #expect(over.usedFraction == 1)
        #expect(over.rawUsedPercent == 150)
    }

    /// A monthly cycle turns over on the same day of each month, so the cycle before the one from 18 September
    /// began on 18 August, thirty-one days back, though the cycle from 18 September is thirty days long. Its first
    /// day is in the sum (CodeRabbit, #165). A cycle that is not a month long goes back by its own length.
    @Test func theCycleBeforeBeganACalendarMonthEarlier() throws {
        let cycleStart = DateParsing.iso8601("2026-09-18T00:00:00Z")!
        let september = LimitWindow(id: "included", label: .key("Monthly usage"), usedFraction: nil, resetsAt: DateParsing.iso8601("2026-10-18T00:00:00Z")!,
                                    periodDuration: 30 * Period.day, amountUSD: 100)
        let history = days([("2026-08-17", 900), ("2026-08-18", 300), ("2026-09-17", 200), ("2026-09-20", 100)])
        let now = DateParsing.iso8601("2026-09-25T12:00:00Z")!
        let compared = try #require(CursorProvider.withCycleComparison([september], days: history, cycleStart: cycleStart, now: now, calendar: calendar).first)
        #expect(compared.note == "$100.00 so far, $500 last cycle")
        #expect(compared.usedFraction == 0.2)
        // A fortnightly cycle: fourteen days back, 4 to 18 September.
        let fortnight = LimitWindow(id: "included", label: .key("Monthly usage"), usedFraction: nil, resetsAt: DateParsing.iso8601("2026-10-02T00:00:00Z")!,
                                    periodDuration: 14 * Period.day, amountUSD: 100)
        let short = days([("2026-09-03", 900), ("2026-09-04", 150), ("2026-09-17", 250), ("2026-09-20", 100)])
        let two = try #require(CursorProvider.withCycleComparison([fortnight], days: short, cycleStart: cycleStart, now: now, calendar: calendar).first)
        #expect(two.note == "$100.00 so far, $400 last cycle")
    }

    /// Left as it was wherever last cycle's total is not known in full, or there is nothing to compare.
    @Test func monthlyUsageIsLeftAloneWithoutAWholeCycleBehindIt() {
        let cycleStart = DateParsing.iso8601("2026-11-01T00:00:00Z")!
        func compared(_ history: [Date: CostHistory.Record], _ windows: [LimitWindow] = Self.seat.windows, start: Date? = cycleStart) -> LimitWindow? {
            CursorProvider.withCycleComparison(windows, days: history, cycleStart: start, now: Self.now, calendar: calendar).first { $0.id == "included" }
        }
        // The history begins inside last cycle: its sum would be short, and a short sum reads this cycle high.
        #expect(compared(days([("2026-10-15", 350), ("2026-10-31", 250)])) == Self.monthly)
        // It begins on the day last cycle began: whole. That day is a calendar month back, 1 October, and not this
        // cycle's thirty days back, 2 October: a history that begins on the 2nd is a day short.
        #expect(compared(days([("2026-10-01", 400), ("2026-10-31", 250)]))?.usedFraction != nil)
        #expect(compared(days([("2026-10-02", 400), ("2026-10-31", 250)])) == Self.monthly)
        // Nothing was spent last cycle.
        #expect(compared(days([("2026-09-30", 500), ("2026-11-03", 300)])) == Self.monthly)
        // No history at all, and no cycle start.
        #expect(compared([:]) == Self.monthly)
        #expect(compared(days([("2026-09-30", 500), ("2026-10-15", 350)]), start: nil) == Self.monthly)
        // A window Cursor gave a figure is the vendor's, and one with no dollars has nothing to compare.
        let metered = LimitWindow(id: "included", label: .key("Included usage"), usedFraction: 0.3, resetsAt: Self.cycleEnd, periodDuration: 30 * Period.day, amountUSD: 6)
        let whole = days([("2026-09-30", 500), ("2026-10-15", 350)])
        #expect(compared(whole, [metered]) == metered)
        let bare = LimitWindow(id: "included", label: .key("Included usage"), usedFraction: nil, resetsAt: Self.cycleEnd, periodDuration: 30 * Period.day)
        #expect(compared(whole, [bare]) == bare)
    }

    // MARK: - The flag

    /// A comparison is stored on the window since 0.9.27. A window built or cached without the flag is still one
    /// by the id that was the only one, so a reading cached by 0.9.26 reads the way it did.
    @Test func aComparisonSurvivesTheCacheAndAnOlderCacheStillReads() throws {
        #expect(Self.spend.isComparison)
        #expect(!Self.monthly.isComparison)
        let compared = LimitWindow(id: "included", label: .key("Monthly usage"), usedFraction: 0.4, resetsAt: Self.cycleEnd, comparison: true)
        let decoded = try JSONDecoder().decode([LimitWindow].self, from: JSONEncoder().encode([Self.spend, Self.monthly, compared]))
        #expect(decoded.map(\.isComparison) == [true, false, true])
        #expect(compared.pinningReset(to: Self.now).isComparison)
        #expect(compared.pacing(at: 0.01).isComparison)
        #expect(compared.with(source: .localEstimate).isComparison)
        // As 0.9.26 wrote them: no flag at all.
        let old = Data(#"[{"id":"spend_today","label":{"key":"Today's spend"},"usedFraction":0.2,"source":"localEstimate","hiddenByDefault":false},{"id":"included","label":{"key":"Monthly usage"},"source":"vendorEndpoint","hiddenByDefault":false}]"#.utf8)
        #expect(try JSONDecoder().decode([LimitWindow].self, from: old).map(\.isComparison) == [true, false])
    }
}
