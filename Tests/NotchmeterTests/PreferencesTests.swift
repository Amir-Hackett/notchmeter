import Foundation
import Testing
@testable import Notchmeter

/// The two settings that clamp what they are given. They are stored properties of an `@Observable` class, whose
/// setter is what the macro generates, so a clamp that assigns the property from inside its own `didSet` re-enters
/// that setter — and re-enters `didSet`, without end. That is a stack overflow the moment the stepper is pressed,
/// which is how it was found; these pin that a write in range, out of range and already-rounded each settle.
@MainActor @Suite struct ClampedSettings {
    func withSuite(_ name: String, _ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "NotchmeterTests.Clamped.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func theFinishedTurnThresholdSettlesInsideOneToSixtyMinutes() {
        withSuite("finished") { defaults in
            let prefs = Preferences(defaults: defaults)
            #expect(prefs.finishedAfterMinutes == 2)
            prefs.finishedAfterMinutes = 1
            #expect(prefs.finishedAfterMinutes == 1)
            #expect(defaults.integer(forKey: "finishedAfterMinutes") == 1)
            prefs.finishedAfterMinutes = 0
            #expect(prefs.finishedAfterMinutes == 1)
            prefs.finishedAfterMinutes = 90
            #expect(prefs.finishedAfterMinutes == 60)
            #expect(defaults.integer(forKey: "finishedAfterMinutes") == 60)
        }
    }

    /// Anthropic's usage endpoint is polled unless switched off; off persists and is the status line alone.
    @Test func theClaudeEndpointIsPolledUnlessSwitchedOff() {
        withSuite("claude-endpoint") { defaults in
            let prefs = Preferences(defaults: defaults)
            #expect(prefs.pollClaudeEndpoint)
            prefs.pollClaudeEndpoint = false
            #expect(defaults.object(forKey: "pollClaudeEndpoint") as? Bool == false)
            #expect(!Preferences(defaults: defaults).pollClaudeEndpoint)
        }
    }

    @Test func theHoverDelaySettlesOnATwentiethOfASecond() {
        withSuite("hover") { defaults in
            let prefs = Preferences(defaults: defaults)
            prefs.hoverDelay = 0.33
            #expect(prefs.hoverDelay == 0.35)
            prefs.hoverDelay = 0.35
            #expect(prefs.hoverDelay == 0.35)
            prefs.hoverDelay = 5
            #expect(prefs.hoverDelay == 1)
            prefs.hoverDelay = 0
            #expect(prefs.hoverDelay == 0.1)
        }
    }
}

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
            #expect(prefs.compactKeep == .tools, "Auto sheds the figures before the tools unless told otherwise")
        }
        #expect(CompactStyle.rings.showsRings && !CompactStyle.rings.showsNumbers)
        #expect(CompactStyle.ringsAndNumbers.showsRings && CompactStyle.ringsAndNumbers.showsNumbers)
        #expect(!CompactStyle.numbers.showsRings && CompactStyle.numbers.showsNumbers)
    }

    @Test func movesOneStepAndStopsAtTheEnds() {
        withSuite("moves") { defaults in
            let prefs = Preferences(defaults: defaults)
            prefs.move(.cursor, by: -1)
            #expect(prefs.toolOrder == [.claude, .cursor, .codex, .gemini, .antigravity, .copilot, .kimi, .opencode])
            prefs.move(.claude, by: -1)
            prefs.move(.opencode, by: 1)
            #expect(prefs.toolOrder == [.claude, .cursor, .codex, .gemini, .antigravity, .copilot, .kimi, .opencode])
            prefs.move(.claude, by: 1)
            #expect(prefs.toolOrder == [.cursor, .claude, .codex, .gemini, .antigravity, .copilot, .kimi, .opencode])
        }
    }

    @Test func persistsAcrossLaunches() {
        withSuite("persist") { defaults in
            let prefs = Preferences(defaults: defaults)
            prefs.move(.antigravity, by: -1)
            prefs.compactStyle = .numbers
            prefs.compactKeep = .numbers
            let reloaded = Preferences(defaults: defaults)
            let antigravityThird: [ToolID] = [.claude, .codex, .cursor, .antigravity, .gemini, .copilot, .kimi, .opencode]
            #expect(reloaded.toolOrder == antigravityThird)
            #expect(reloaded.compactStyle == .numbers)
            #expect(reloaded.compactKeep == .numbers)
        }
    }

    @Test func aStoredOrderGainsNewToolsAtTheEndAndLosesStrangers() {
        #expect(ToolOrder.normalize(nil) == ToolID.allCases)
        let cursorFirst: [ToolID] = [.cursor, .claude, .codex, .gemini, .antigravity, .copilot, .kimi, .opencode]
        let codexFirst: [ToolID] = [.codex, .claude, .cursor, .gemini, .antigravity, .copilot, .kimi, .opencode]
        #expect(ToolOrder.normalize(["cursor", "claude"]) == cursorFirst)
        #expect(ToolOrder.normalize(["codex", "bard", "codex"]) == codexFirst)
        // An order stored before OpenCode existed gains it at the end, as every tool added later has.
        #expect(ToolOrder.normalize(["claude", "codex", "cursor", "antigravity", "copilot"]).last == .opencode)
        withSuite("stale") { defaults in
            // An order written before 0.9.0: Gemini CLI takes the place just before the Antigravity row it came out of
            // (ToolMigration), and Kimi Code and OpenCode, new, land at the end.
            defaults.set(["antigravity", "claude"], forKey: "toolOrder")
            let migrated: [ToolID] = [.gemini, .antigravity, .claude, .codex, .cursor, .copilot, .kimi, .opencode]
            #expect(Preferences(defaults: defaults).toolOrder == migrated)
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
            // Every expected list is named and typed first, so the solver resolves the members here rather than
            // inside the macro's expansion, where each operand is wrapped in a tree of callAsFunction overloads.
            let asShipped: [ToolID] = [.claude, .codex, .cursor]
            let cursorSecond: [ToolID] = [.claude, .cursor, .codex]
            let claudeSecond: [ToolID] = [.cursor, .claude, .codex]
            let wholeOrder: [ToolID] = [.claude, .cursor, .codex, .gemini, .antigravity, .copilot, .kimi, .opencode]
            let spending: [ToolID] = [.cursor, .claude]
            #expect(store.visibleTools == asShipped)
            prefs.move(.cursor, by: -1)
            #expect(store.visibleTools == cursorSecond)
            let ready = store.readyReadings.map(\.tool)
            #expect(ready == cursorSecond)
            let advised = store.adviceContext(now: now).toolOrder
            #expect(advised == wholeOrder)
            prefs.move(.claude, by: 1)
            #expect(store.visibleTools == claudeSecond)
            // The Cost card reads the same preference, so its donut, its legend and its detail block move with it;
            // an assistant that reported no spend is not in the selection to lead it (CostAbsence names it instead).
            let selection = store.costSelection
            let fromTheSamePreference = CostSelection(all: store.cost?.providers ?? [], order: prefs.toolOrder, carried: prefs.costCardTools)
            #expect(selection == fromTheSamePreference)
            let inTheSelection = selection.providers.map(\.tool)
            #expect(inTheSelection == spending)
            let segments = CostDonut.arcs(selection.weights(range: .today, mode: .cost)).map(\.tool)
            #expect(segments == spending)
            // Codex is carried and shown but reported no spend, so it is named under the legend rather than
            // drawn as a zero slice — and its reason is the one the app already knows.
            let named = store.costGaps.map(\.tool)
            let noSpendToShow: [ToolID] = [.codex]
            #expect(named == noSpendToShow)
            prefs.move(.claude, by: -1)
            // Typed, so the solver resolves the members here rather than inside the macro's expansion.
            let moved: [ToolID] = [.claude, .cursor]
            let afterTheMove = store.costSelection.providers.map(\.tool)
            #expect(afterTheMove == moved)
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
            prefs.language = "it"
            #expect(Preferences(defaults: defaults).language == nil)
            prefs.language = nil
            #expect(defaults.persistentDomain(forName: "NotchmeterTests.RoundTwo.language")?["AppleLanguages"] == nil)
            #expect(Localization.nativeNames.keys.sorted() == Localization.languages.sorted())
        }
    }

    /// A budget a build before 0.9.0 kept in dollars is read once into the currency shown, at the rate in use, so
    /// it goes on being the figure it was that day; the old key goes with it, so a budget cleared later stays
    /// cleared; and the command-line report, which builds no Preferences, reads the same dollar figure.
    @Test func aDollarBudgetFromBeforeIsReadOnceIntoTheCurrency() {
        withSuite("budget-migration") { defaults in
            defer { Money.configure(code: "USD", rate: 1) }
            defaults.set("EUR", forKey: "currencyCode")
            defaults.set(0.88, forKey: "currencyRate")
            defaults.set(227.27, forKey: "monthlyBudgetUSD")
            let prefs = Preferences(defaults: defaults)
            let inEuros = 227.27 * 0.88
            #expect(prefs.monthlyBudget == Budget(amount: inEuros, code: "EUR", rate: 0.88))
            let drift = abs((prefs.monthlyBudgetUSD ?? 0) - 227.27)
            #expect(drift < 1e-9)
            #expect(prefs.weeklyBudget == nil)
            #expect(defaults.object(forKey: "monthlyBudgetUSD") == nil)
            #expect(defaults.data(forKey: "monthlyBudget") != nil)
            #expect(Preferences.budgetsUSD(defaults: defaults).monthly == prefs.monthlyBudgetUSD)
            #expect(Preferences.budgetsUSD(defaults: defaults).weekly == nil)
            // Read again it is the kept budget, not a second migration; cleared, it stays cleared.
            #expect(Preferences(defaults: defaults).monthlyBudget == prefs.monthlyBudget)
            prefs.monthlyBudget = nil
            #expect(Preferences(defaults: defaults).monthlyBudget == nil)
            #expect(Preferences.budgetsUSD(defaults: defaults).monthly == nil)
        }
    }

    /// The budget field follows a change of code or rate made while Settings is open, the way the window's
    /// onChange moves it: 200 typed in euros reads back as its pound figure once pounds are shown, so the Apply
    /// that follows keeps the same dollar figure rather than reading "200" as £200.
    @Test func theBudgetFieldShowsTheConvertedFigureAfterTheCodeChanges() {
        withSuite("budget-code-change") { defaults in
            defer { Money.configure(code: "USD", rate: 1) }
            let prefs = Preferences(defaults: defaults)
            prefs.currencyCode = "EUR"
            prefs.currencyRate = 0.88
            prefs.monthlyBudget = Budget.parse("200", at: prefs.currencyConversion)
            let euros = prefs.currencyConversion
            var field = SettingsView.budgetText(prefs.monthlyBudget, at: euros)
            #expect(field == "200")
            let typedUSD = 200 / 0.88
            // The code and then the rate, each a change of the conversion the window hears once.
            prefs.currencyCode = "GBP"
            let poundsAtTheOldRate = prefs.currencyConversion
            field = SettingsView.budgetText(prefs.monthlyBudget, from: euros, to: poundsAtTheOldRate, draft: field)
            prefs.currencyRate = 0.76
            let pounds = prefs.currencyConversion
            field = SettingsView.budgetText(prefs.monthlyBudget, from: poundsAtTheOldRate, to: pounds, draft: field)
            let inPounds = String(format: "%.2f", typedUSD * 0.76)
            #expect(field == inPounds)
            #expect(field == SettingsView.budgetText(prefs.monthlyBudget, at: prefs.currencyConversion))
            // The budget itself is still the one typed, measured at the rate it was typed at.
            #expect(prefs.monthlyBudget == Budget(amount: 200, code: "EUR", rate: 0.88))
            let drift = abs((prefs.monthlyBudgetUSD ?? 0) - typedUSD)
            #expect(drift < 1e-9)
            // Applied from the field, it is the same dollar figure to the cent the field shows, and in pounds now.
            prefs.monthlyBudget = Budget.parse(field, at: prefs.currencyConversion)
            #expect(prefs.monthlyBudget?.code == "GBP")
            let reapplied = abs((prefs.monthlyBudgetUSD ?? 0) - typedUSD)
            #expect(reapplied < 0.01)
        }
    }

    @Test func keychainPolicyBudgetsAndProxyPersist() {
        withSuite("policy") { defaults in
            let prefs = Preferences(defaults: defaults)
            #expect(prefs.keychainPrompts == .refreshOnly)
            #expect(prefs.settingsExpandedTools.isEmpty, "assistants start collapsed")
            prefs.keychainPrompts = .never
            prefs.monthlyBudget = Budget(amount: 200, code: "USD", rate: 1)
            prefs.weeklyBudget = Budget.parse("0", at: prefs.currencyConversion)
            prefs.proxyURL = "socks5://127.0.0.1:1080"
            prefs.sessionAttention = .glance
            prefs.menuBarStyle = .bars
            prefs.menuBarPinnedTools = [.codex]
            prefs.peakHoursTools = [.claude, .codex]
            prefs.settingsExpandedTools = [.cursor]
            prefs.peakHours.startMinute = 6 * 60
            prefs.costCardMode = .perMillionTokens
            prefs.soundChoices[.question] = "system:Glass"
            prefs.setSilenced(true, .limit)
            let reloaded = Preferences(defaults: defaults)
            #expect(reloaded.keychainPrompts == .never)
            #expect(reloaded.monthlyBudget == Budget(amount: 200, code: "USD", rate: 1))
            #expect(reloaded.monthlyBudgetUSD == 200)
            #expect(reloaded.weeklyBudget == nil)
            #expect(reloaded.weeklyBudgetUSD == nil)
            #expect(reloaded.proxyURL == "socks5://127.0.0.1:1080")
            #expect(reloaded.sessionAttention == .glance)
            #expect(reloaded.menuBarStyle == .bars)
            #expect(reloaded.menuBarPinnedTools == [.codex])
            #expect(reloaded.peakHoursTools == [.claude, .codex])
            #expect(reloaded.settingsExpandedTools == [.cursor])
            #expect(reloaded.peakHours.startMinute == 6 * 60)
            #expect(reloaded.peakHours(for: .cursor) == nil)
            #expect(reloaded.peakHours(for: .claude)?.startMinute == 6 * 60)
            #expect(reloaded.costCardMode == .perMillionTokens)
            #expect(reloaded.sound(for: .question) == "system:Glass")
            #expect(reloaded.silencedSounds == [.limit])
            reloaded.notificationSound = false
            #expect(reloaded.sound(for: .question) == NotificationSound.none)
            prefs.keychainPrompts = .refreshOnly
            prefs.proxyURL = ""
        }
        let socksHost = ProxySettings.dictionary(for: "socks5://proxy.local:1080")?[kCFNetworkProxiesSOCKSProxy] as? String
        #expect(socksHost == "proxy.local")
        #expect(ProxySettings.dictionary(for: "http://proxy.local:3128")?[kCFNetworkProxiesHTTPSPort] as? Int == 3128)
        #expect(ProxySettings.dictionary(for: "") == nil)
        #expect(ProxySettings.dictionary(for: "ftp://x:1") == nil)
        #expect(ProxySettings.dictionary(for: "http://noport") == nil)
    }

    /// The usage card's choices (ShareCardWindow) persist, its theme follows the metric until one is chosen by
    /// hand, and the offer's bookkeeping survives a relaunch, which is what makes it once per version.
    @Test func theUsageCardsChoicesPersistAndItsThemeFollowsTheMetricUntilChosen() {
        withSuite("share-card") { defaults in
            let prefs = Preferences(defaults: defaults)
            #expect(prefs.shareCardMetric == .value)
            #expect(prefs.shareCardRange == .thirtyDays)
            #expect(prefs.shareCardFormat == .feed)
            #expect(prefs.shareCardTheme == nil)
            #expect(prefs.shareCardThemeShown == .black)
            #expect(prefs.shareCardSignature.isEmpty)
            #expect(prefs.shareCardHidden.isEmpty)
            #expect(prefs.offerShareCardAfterUpdate)
            #expect(prefs.shareCardOfferPending == nil)
            #expect(prefs.lastLaunchedVersion == nil)
            prefs.shareCardMetric = .tokens
            #expect(prefs.shareCardThemeShown == .blue, "money on black, tokens on blue")
            prefs.shareCardTheme = .white
            prefs.shareCardMetric = .value
            #expect(prefs.shareCardThemeShown == .white, "a theme chosen by hand stays")
            prefs.shareCardRange = .ninetyDays
            prefs.shareCardFormat = .story
            prefs.shareCardSignature = "@sample"
            prefs.shareCardHidden = [.cursor]
            prefs.offerShareCardAfterUpdate = false
            prefs.shareCardOfferPending = "0.9.0"
            prefs.lastLaunchedVersion = "0.9.0"
            let reloaded = Preferences(defaults: defaults)
            #expect(reloaded.shareCardMetric == .value)
            #expect(reloaded.shareCardRange == .ninetyDays)
            #expect(reloaded.shareCardFormat == .story)
            #expect(reloaded.shareCardTheme == .white)
            #expect(reloaded.shareCardSignature == "@sample")
            #expect(reloaded.shareCardHidden == [.cursor])
            #expect(!reloaded.offerShareCardAfterUpdate)
            #expect(reloaded.shareCardOfferPending == "0.9.0")
            #expect(reloaded.lastLaunchedVersion == "0.9.0")
            reloaded.shareCardTheme = nil
            #expect(defaults.object(forKey: "shareCardTheme") == nil)
            #expect(Preferences(defaults: defaults).shareCardThemeShown == .black)
            reloaded.shareCardOfferPending = nil
            #expect(Preferences(defaults: defaults).shareCardOfferPending == nil)
        }
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

    /// A single chosen ring stays a single ring: it is the user's choice, and filling it to two put a window back
    /// that the Inner ring picker had just been set to None for.
    @Test func anExplicitChoiceStillWinsAndIsNotToppedUp() {
        let reading = UsageReading(tool: .cursor, windows: [window("included", nil), window("cursorModels", 0)],
                                   plan: "Free", fetchedAt: Date(), observedAt: nil)
        #expect(RingSelection.windows(of: reading, chosen: ["included"], hidden: []).map(\.id) == ["included"])
        #expect(RingSelection.windows(of: reading, chosen: ["included", "cursorModels"], hidden: []).map(\.id) == ["included", "cursorModels"])
    }

    @Test func allWithoutFiguresKeepsTheReadingOrder() {
        let reading = UsageReading(tool: .cursor, windows: [window("a", nil), window("b", nil)],
                                   plan: "Free", fetchedAt: Date(), observedAt: nil)
        #expect(RingSelection.windows(of: reading, chosen: [], hidden: []).map(\.id) == ["a", "b"])
    }
}
