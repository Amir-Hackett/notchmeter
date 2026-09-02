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
            #expect(prefs.toolOrder == [.claude, .cursor, .codex, .antigravity, .copilot])
            prefs.move(.claude, by: -1)
            prefs.move(.copilot, by: 1)
            #expect(prefs.toolOrder == [.claude, .cursor, .codex, .antigravity, .copilot])
            prefs.move(.claude, by: 1)
            #expect(prefs.toolOrder == [.cursor, .claude, .codex, .antigravity, .copilot])
        }
    }

    @Test func persistsAcrossLaunches() {
        withSuite("persist") { defaults in
            let prefs = Preferences(defaults: defaults)
            prefs.move(.antigravity, by: -1)
            prefs.compactStyle = .numbers
            let reloaded = Preferences(defaults: defaults)
            #expect(reloaded.toolOrder == [.claude, .codex, .antigravity, .cursor, .copilot])
            #expect(reloaded.compactStyle == .numbers)
        }
    }

    @Test func aStoredOrderGainsNewToolsAtTheEndAndLosesStrangers() {
        #expect(ToolOrder.normalize(nil) == ToolID.allCases)
        #expect(ToolOrder.normalize(["cursor", "claude"]) == [.cursor, .claude, .codex, .antigravity, .copilot])
        #expect(ToolOrder.normalize(["codex", "gemini", "codex"]) == [.codex, .claude, .cursor, .antigravity, .copilot])
        withSuite("stale") { defaults in
            defaults.set(["antigravity", "claude"], forKey: "toolOrder")
            #expect(Preferences(defaults: defaults).toolOrder == [.antigravity, .claude, .codex, .cursor, .copilot])
        }
    }

    @Test func theStoreShowsToolsInThatOrder() {
        withSuite("store") { defaults in
            let prefs = Preferences(defaults: defaults)
            let now = Date()
            let readings = DemoFixtures.readings(now: now)
            let store = UsageStore(prefs: prefs, providers: readings.map { FixtureProvider(reading: $0) },
                                   cache: ReadingCache(defaults: defaults), defaults: defaults, drainLog: nil)
            store.seed(readings: readings, cost: DemoFixtures.cost(now: now), nextUpdate: now.addingTimeInterval(60), now: now)
            #expect(store.visibleTools == [.claude, .codex, .cursor])
            prefs.move(.cursor, by: -1)
            #expect(store.visibleTools == [.claude, .cursor, .codex])
            #expect(store.readyReadings.map(\.tool) == [.claude, .cursor, .codex])
            #expect(store.adviceContext(now: now).toolOrder == [.claude, .cursor, .codex, .antigravity, .copilot])
            prefs.move(.claude, by: 1)
            #expect(store.visibleTools == [.cursor, .claude, .codex])
        }
    }
}


/// The language picker, the Keychain policy, the budget and the proxy preference all persist and apply.
@MainActor @Suite struct PreferencesRoundTwo {
    func withSuite(_ name: String, _ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "NotchmeterTests.RoundTwo.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func theLanguagePickerWritesAppleLanguagesIntoTheAppsOwnDomain() {
        withSuite("language") { defaults in
            let prefs = Preferences(defaults: defaults)
            #expect(prefs.language == nil)
            prefs.language = "zh-Hans"
            #expect(defaults.persistentDomain(forName: "NotchmeterTests.RoundTwo.language")?["AppleLanguages"] as? [String] == ["zh-Hans"])
            #expect(Preferences(defaults: defaults).language == "zh-Hans")
            prefs.language = "fr"
            #expect(Preferences(defaults: defaults).language == nil)
            prefs.language = nil
            #expect(defaults.persistentDomain(forName: "NotchmeterTests.RoundTwo.language")?["AppleLanguages"] == nil)
            #expect(Localization.nativeNames.keys.sorted() == Localization.languages.sorted())
        }
    }

    @Test func keychainPolicyBudgetsAndProxyPersist() {
        withSuite("policy") { defaults in
            let prefs = Preferences(defaults: defaults)
            #expect(prefs.keychainPrompts == .refreshOnly)
            prefs.keychainPrompts = .never
            prefs.monthlyBudgetUSD = 200
            prefs.weeklyBudgetUSD = 0
            prefs.proxyURL = "socks5://127.0.0.1:1080"
            prefs.sessionAttention = .glance
            prefs.menuBarStyle = .bars
            prefs.menuBarPinnedTools = [.codex]
            prefs.peakHoursTools = [.claude, .codex]
            prefs.peakHours.startMinute = 6 * 60
            prefs.costCardMode = .perMillionTokens
            prefs.soundWaiting = "system:Glass"
            let reloaded = Preferences(defaults: defaults)
            #expect(reloaded.keychainPrompts == .never)
            #expect(reloaded.monthlyBudgetUSD == 200)
            #expect(reloaded.weeklyBudgetUSD == nil)
            #expect(reloaded.proxyURL == "socks5://127.0.0.1:1080")
            #expect(reloaded.sessionAttention == .glance)
            #expect(reloaded.menuBarStyle == .bars)
            #expect(reloaded.menuBarPinnedTools == [.codex])
            #expect(reloaded.peakHoursTools == [.claude, .codex])
            #expect(reloaded.peakHours.startMinute == 6 * 60)
            #expect(reloaded.peakHours(for: .cursor) == nil)
            #expect(reloaded.peakHours(for: .claude)?.startMinute == 6 * 60)
            #expect(reloaded.costCardMode == .perMillionTokens)
            #expect(reloaded.sound(for: .waiting) == "system:Glass")
            reloaded.notificationSound = false
            #expect(reloaded.sound(for: .waiting) == NotificationSound.none)
            prefs.keychainPrompts = .refreshOnly
            prefs.proxyURL = ""
        }
        #expect(ProxySettings.dictionary(for: "socks5://proxy.local:1080")?[kCFNetworkProxiesSOCKSProxy] as? String == "proxy.local")
        #expect(ProxySettings.dictionary(for: "http://proxy.local:3128")?[kCFNetworkProxiesHTTPSPort] as? Int == 3128)
        #expect(ProxySettings.dictionary(for: "") == nil)
        #expect(ProxySettings.dictionary(for: "ftp://x:1") == nil)
        #expect(ProxySettings.dictionary(for: "http://noport") == nil)
    }
}

/// A plan whose headline window publishes no limit — Cursor Free's "Included usage" — must not take the rings
/// and leave the tool showing nothing when other windows do report a figure.
@Suite struct RingsPreferWindowsWithFigures {
    private func window(_ id: String, _ used: Double?) -> LimitWindow {
        LimitWindow(id: id, label: .vendor(id), usedFraction: used, resetsAt: nil)
    }

    @Test func anUnlimitedHeadlineYieldsToWindowsThatReport() {
        let reading = UsageReading(tool: .cursor, windows: [window("included", nil), window("cursorModels", 0), window("other", 0)],
                                   plan: "Free", fetchedAt: Date(), observedAt: nil)
        let rings = RingSelection.windows(of: reading, chosen: [], hidden: [])
        #expect(rings.map(\.id) == ["cursorModels", "other"])
    }

    @Test func anExplicitChoiceStillWins() {
        let reading = UsageReading(tool: .cursor, windows: [window("included", nil), window("cursorModels", 0)],
                                   plan: "Free", fetchedAt: Date(), observedAt: nil)
        #expect(RingSelection.windows(of: reading, chosen: ["included"], hidden: []).map(\.id) == ["included", "cursorModels"])
    }

    @Test func allWithoutFiguresKeepsTheReadingOrder() {
        let reading = UsageReading(tool: .cursor, windows: [window("a", nil), window("b", nil)],
                                   plan: "Free", fetchedAt: Date(), observedAt: nil)
        #expect(RingSelection.windows(of: reading, chosen: [], hidden: []).map(\.id) == ["a", "b"])
    }
}
