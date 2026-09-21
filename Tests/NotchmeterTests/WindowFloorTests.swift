import Foundation
import Testing
@testable import Notchmeter

/// A tool's last shown window cannot be hidden (WindowFloor, 0.6.0). Until then the Hide checkboxes in Settings
/// had no floor: hiding every window of a tool emptied its card and its rings, and until 0.5.0 blanked its menu
/// bar item. The pure rules are pinned first, then the Preferences layer against a preference written the way an
/// older build would have left it, so a stale "everything hidden" reads as "show the first" whatever put it there.
@MainActor @Suite struct WindowFloorRules {
    static func window(_ id: String, hiddenByDefault: Bool = false) -> LimitWindow {
        LimitWindow(id: id, label: .vendor(id), usedFraction: 0.4, resetsAt: nil, hiddenByDefault: hiddenByDefault)
    }
    static let session = window("session")
    static let weekly = window("weekly")
    static let split = window("split", hiddenByDefault: true)
    static let reading = UsageReading(tool: .claude, windows: [session, weekly, split], plan: nil, fetchedAt: Date(), observedAt: nil)

    func withSuite(_ name: String, _ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "NotchmeterTests.WindowFloor.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func everyWindowHiddenShowsTheFirstOneMeantToBeSeen() {
        let windows = [Self.split, Self.session, Self.weekly]
        let expected = ["session"]
        let shown = WindowFloor.shown(windows) { _ in true }.map(\.id)
        #expect(shown == expected)
    }

    @Test func onlyDefaultHiddenWindowsFallBackToTheFirstOfAll() {
        let windows = [Self.split, Self.window("other", hiddenByDefault: true)]
        let expected = ["split"]
        let shown = WindowFloor.shown(windows) { _ in true }.map(\.id)
        #expect(shown == expected)
    }

    @Test func aPreferenceThatLeavesSomethingShownIsHonouredAsIs() {
        let windows = [Self.session, Self.weekly, Self.split]
        let expected = ["weekly"]
        let shown = WindowFloor.shown(windows) { $0.id != "weekly" }.map(\.id)
        #expect(shown == expected)
        #expect(WindowFloor.shown([]) { _ in true }.isEmpty)
    }

    @Test func theOneWindowShownCannotBeHiddenAndTheOthersCan() {
        let shown = [Self.session]
        #expect(!WindowFloor.canHide(Self.session, shown: shown))
        // A hidden window's checkbox stays live so it can be revealed.
        #expect(WindowFloor.canHide(Self.weekly, shown: shown))
        // With two shown, either may go.
        #expect(WindowFloor.canHide(Self.session, shown: [Self.session, Self.weekly]))
    }

    /// The dictionary an older build stored with every window of the tool hidden: the card and the rings show the
    /// first window rather than nothing.
    @Test func aStalePreferenceHidingEveryWindowReadsAsShowTheFirst() {
        withSuite("stale") { defaults in
            defaults.set(["claude": ["session", "weekly"]], forKey: "hiddenWindows")
            let prefs = Preferences(defaults: defaults)
            let expectedShown = ["session"]
            let shown = prefs.shownWindows(of: Self.reading).map(\.id)
            #expect(shown == expectedShown)
            let rings = prefs.ringWindows(of: Self.reading).map(\.id)
            #expect(rings == expectedShown)
        }
    }

    /// Revealing a second window while the floor is showing the first must not make the first vanish: the write
    /// through the reading settles the floored window into the preference before it applies.
    @Test func revealingAnotherWindowKeepsTheFlooredOneOnTheCard() {
        withSuite("settle") { defaults in
            defaults.set(["claude": ["session", "weekly"]], forKey: "hiddenWindows")
            let prefs = Preferences(defaults: defaults)
            prefs.setHidden(false, window: Self.weekly, in: Self.reading)
            let expected = ["session", "weekly"]
            let shown = prefs.shownWindows(of: Self.reading).map(\.id)
            #expect(shown == expected)
            let stored = defaults.dictionary(forKey: "hiddenWindows") as? [String: [String]] ?? [:]
            #expect(stored.isEmpty)
        }
    }

    /// The ring pickers reveal a hidden pick the same way: choosing the second window for the inner ring while
    /// the floor is showing the first keeps the first on the card and in the outer ring, rather than revealing
    /// the pick alone and letting the stored "hidden" take the floored window with it.
    @Test func choosingAHiddenWindowForARingKeepsTheFlooredOne() {
        withSuite("ring") { defaults in
            defaults.set(["claude": ["session", "weekly"]], forKey: "hiddenWindows")
            let prefs = Preferences(defaults: defaults)
            prefs.setRingWindow(at: 1, to: "weekly", in: Self.reading)
            let expected = ["session", "weekly"]
            let shown = prefs.shownWindows(of: Self.reading).map(\.id)
            #expect(shown == expected)
            let rings = prefs.ringWindows(of: Self.reading).map(\.id)
            #expect(rings == expected)
            let stored = defaults.dictionary(forKey: "hiddenWindows") as? [String: [String]] ?? [:]
            #expect(stored.isEmpty)
        }
    }

    /// Cursor with its included total metered hides both model meters by default. "All models" is still a ring
    /// choice, and choosing it shows the two windows it combines, so the ring and the card agree.
    @Test func allModelsIsOfferedOverHiddenModelWindowsAndShowsThemWhenChosen() {
        withSuite("allModels") { defaults in
            let reset = Date().addingTimeInterval(86_400 * 10)
            let included = LimitWindow(id: "included", label: .key("Included usage"), usedFraction: 0.6, resetsAt: reset, periodDuration: 86_400 * 30)
            func split(_ id: String, _ used: Double) -> LimitWindow {
                LimitWindow(id: id, label: .vendor(id), usedFraction: used, resetsAt: reset, periodDuration: 86_400 * 30, model: id, hiddenByDefault: true)
            }
            let reading = UsageReading(tool: .cursor, windows: [included, split("cursor_models", 0.44), split("other_models", 0.18)],
                                       plan: nil, fetchedAt: Date(), observedAt: nil)
            let prefs = Preferences(defaults: defaults)
            #expect(prefs.shownWindows(of: reading).map(\.id) == ["included"])
            #expect(prefs.combinedWindow(of: reading) == nil, "the card still combines only what it shows")
            #expect(prefs.ringChoices(of: reading).map(\.id).contains(CombinedWindow.id))
            prefs.setRingWindow(at: 0, to: CombinedWindow.id, in: reading)
            #expect(prefs.shownWindows(of: reading).map(\.id) == ["included", "cursor_models", "other_models"])
            #expect(prefs.ringWindows(of: reading).first?.id == CombinedWindow.id)
        }
    }

    /// Two dead meters (no figure) combine into nothing, so the picker offers no "All models" over them.
    @Test func deadModelMetersOfferNoAllModels() {
        let dead = ["cursor_models", "other_models"].map {
            LimitWindow(id: $0, label: .vendor($0), usedFraction: nil, resetsAt: nil, model: $0, hiddenByDefault: true)
        }
        let reading = UsageReading(tool: .cursor, windows: [Self.session] + dead, plan: nil, fetchedAt: Date(), observedAt: nil)
        withSuite("deadModels") { defaults in
            #expect(!Preferences(defaults: defaults).ringChoices(of: reading).map(\.id).contains(CombinedWindow.id))
        }
    }

    /// The dashboard lists the same windows the card shows: with every window of the tool hidden in the
    /// preference, its floored first window has a row rather than the tool having no limits at all.
    @Test func theDashboardListsTheFlooredWindow() {
        withSuite("dashboard") { defaults in
            defaults.set(["claude": ["session", "weekly"]], forKey: "hiddenWindows")
            let prefs = Preferences(defaults: defaults)
            let store = UsageStore(prefs: prefs, providers: [FixtureProvider(reading: Self.reading)],
                                   cache: ReadingCache(defaults: defaults), defaults: defaults, drainLog: nil)
            let now = Date()
            store.seed(readings: [Self.reading], cost: DemoFixtures.cost(now: now), nextUpdate: now.addingTimeInterval(60), now: now)
            let expected = ["session"]
            let listed = DashboardLimit.all(store: store, now: now).map(\.window.id)
            #expect(listed == expected)
        }
    }

    @Test func hidingAllButOneThroughTheReadingLeavesThatOne() {
        withSuite("last") { defaults in
            let prefs = Preferences(defaults: defaults)
            prefs.setHidden(true, window: Self.session, in: Self.reading)
            let expected = ["weekly"]
            let shown = prefs.shownWindows(of: Self.reading).map(\.id)
            #expect(shown == expected)
            #expect(!WindowFloor.canHide(Self.weekly, shown: prefs.shownWindows(of: Self.reading)))
        }
    }
}
