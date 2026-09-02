import Foundation
import Testing
@testable import Notchmeter

/// The assistants' order and the compact style persist, and an order stored before a tool existed still shows it.
/// Each test's defaults suite is emptied before and after, so nothing is left under ~/Library/Preferences.
@MainActor @Suite struct ToolOrderAndCompactStyle {
    func withSuite(_ name: String, _ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "NotchmeterTests.ToolOrder.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func defaultsToEveryToolInDeclarationOrderAndRings() {
        withSuite("defaults") { defaults in
            let prefs = Preferences(defaults: defaults)
            #expect(prefs.toolOrder == ToolID.allCases)
            #expect(prefs.compactStyle == .rings)
        }
        #expect(CompactStyle.rings.showsRings && !CompactStyle.rings.showsNumbers)
        #expect(CompactStyle.ringsAndNumbers.showsRings && CompactStyle.ringsAndNumbers.showsNumbers)
        #expect(!CompactStyle.numbers.showsRings && CompactStyle.numbers.showsNumbers)
    }

    @Test func movesOneStepAndStopsAtTheEnds() {
        withSuite("moves") { defaults in
            let prefs = Preferences(defaults: defaults)
            prefs.move(.cursor, by: -1)
            #expect(prefs.toolOrder == [.claude, .cursor, .codex, .antigravity])
            prefs.move(.claude, by: -1)
            prefs.move(.antigravity, by: 1)
            #expect(prefs.toolOrder == [.claude, .cursor, .codex, .antigravity])
            prefs.move(.claude, by: 1)
            #expect(prefs.toolOrder == [.cursor, .claude, .codex, .antigravity])
        }
    }

    @Test func persistsAcrossLaunches() {
        withSuite("persist") { defaults in
            let prefs = Preferences(defaults: defaults)
            prefs.move(.antigravity, by: -1)
            prefs.compactStyle = .numbers
            let reloaded = Preferences(defaults: defaults)
            #expect(reloaded.toolOrder == [.claude, .codex, .antigravity, .cursor])
            #expect(reloaded.compactStyle == .numbers)
        }
    }

    @Test func aStoredOrderGainsNewToolsAtTheEndAndLosesStrangers() {
        #expect(ToolOrder.normalize(nil) == ToolID.allCases)
        #expect(ToolOrder.normalize(["cursor", "claude"]) == [.cursor, .claude, .codex, .antigravity])
        #expect(ToolOrder.normalize(["codex", "gemini", "codex"]) == [.codex, .claude, .cursor, .antigravity])
        withSuite("stale") { defaults in
            defaults.set(["antigravity", "claude"], forKey: "toolOrder")
            #expect(Preferences(defaults: defaults).toolOrder == [.antigravity, .claude, .codex, .cursor])
        }
    }

    @Test func theStoreShowsToolsInThatOrder() {
        withSuite("store") { defaults in
            let prefs = Preferences(defaults: defaults)
            let now = Date()
            let readings = DemoFixtures.readings(now: now)
            let store = UsageStore(prefs: prefs, providers: readings.map { FixtureProvider(reading: $0) },
                                   cache: ReadingCache(defaults: defaults), defaults: defaults)
            store.seed(readings: readings, cost: DemoFixtures.cost(now: now), nextUpdate: now.addingTimeInterval(60), now: now)
            #expect(store.visibleTools == [.claude, .codex, .cursor])
            prefs.move(.cursor, by: -1)
            #expect(store.visibleTools == [.claude, .cursor, .codex])
            #expect(store.readyReadings.map(\.tool) == [.claude, .cursor, .codex])
            #expect(store.adviceContext(now: now).toolOrder == [.claude, .cursor, .codex, .antigravity])
            prefs.move(.claude, by: 1)
            #expect(store.visibleTools == [.cursor, .claude, .codex])
        }
    }
}
