import AppKit
import Testing
@testable import Notchmeter

/// Displays by hardware identity, the main display as the menu bar's, the pointer's presenter, the edge placement
/// around a hidden menu bar, a side Dock and Stage Manager, the menu bar pin's composition, the awake rule and the
/// launch-time repair gate.
@Suite struct DisplayIdentityRules {
    init() { Localization.use(language: "en") }

    @Test func twoIdenticalMonitorsGetDistinctKeysAndTitles() {
        #expect(DisplayIdentity.key(vendor: 4268, model: 16752, serial: 1234, unit: 2, duplicateIndex: 0) == "4268-16752-1234")
        #expect(DisplayIdentity.key(vendor: 4268, model: 16752, serial: 0, unit: 2, duplicateIndex: 0) == "4268-16752-u2")
        #expect(DisplayIdentity.key(vendor: 4268, model: 16752, serial: 1234, unit: 2, duplicateIndex: 1) == "4268-16752-1234#1")
        #expect(DisplayIdentity.titles(for: ["DELL U2723QE", "DELL U2723QE", "Built-in Retina Display"]) == ["DELL U2723QE", "DELL U2723QE (2)", "Built-in Retina Display"])
        let keys = DisplayIdentity.keys(for: NSScreen.screens)
        #expect(Set(keys).count == NSScreen.screens.count)
    }

    @Test func aNamedChoiceMatchesTheKeyThenTheOldNameAndTellsTwinsApart() {
        let builtIn = ScreenInfo(name: "Built-in Retina Display", key: "1552-41000-0", hasNotch: true, isMain: true, frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        let first = ScreenInfo(name: "DELL U2723QE", key: "4268-16752-1", hasNotch: false, isMain: false, frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440))
        let second = ScreenInfo(name: "DELL U2723QE", key: "4268-16752-2", hasNotch: false, isMain: false, frame: CGRect(x: 4072, y: 0, width: 2560, height: 1440))
        let screens = [builtIn, first, second]
        #expect(ScreenSelection.indices(for: .named("4268-16752-2"), screens: screens, pointer: .zero) == [2])
        #expect(ScreenSelection.indices(for: .named("4268-16752-1"), screens: screens, pointer: .zero) == [1])
        // A preference written by an older version holds the localizedName: the first twin, as before.
        #expect(ScreenSelection.indices(for: .named("DELL U2723QE"), screens: screens, pointer: .zero) == [1])
        #expect(ScreenSelection.indices(for: .named("gone"), screens: screens, pointer: .zero) == [0])
    }

    @Test func mainIsTheMenuBarsScreenNotTheKeyWindows() {
        // The key window sits on the external display; the menu bar is on the built-in one.
        let builtIn = ScreenInfo(name: "Built-in Retina Display", hasNotch: true, isMain: true, frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        let external = ScreenInfo(name: "DELL U2723QE", hasNotch: false, isMain: false, frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440))
        #expect(ScreenSelection.indices(for: .main, screens: [builtIn, external], pointer: CGPoint(x: 2000, y: 100)) == [0])
        #expect(ScreenSelection.indices(for: .builtIn, screens: [external, builtIn], pointer: .zero) == [1])
        #expect(NSScreen.screens.first.map { $0.info.isMain } ?? true)
        #expect(DisplayChoice.main.title == "Main display (the one with the menu bar)")
    }

    @MainActor @Test func theShortcutActsOnThePresenterUnderThePointer() {
        final class Stub: PanelPresenting {
            let edge: PanelEdge = .top
            let screen: NSScreen
            var isVisible: Bool { true }
            var window: NSWindow? { nil }
            var expandedContentSize: CGSize { .zero }
            var expandedIntrinsicContentSize: CGSize { .zero }
            let hover = HoverDriver(mode: .onHover)
            var scroll: PanelScrollReader { PanelScrollReader(window: nil, notch: nil, titleInset: 0) }
            init(screen: NSScreen) { self.screen = screen }
            func show() {}
            func hide() async {}
            func showOptions() {}
            func holdCompact(_ held: Bool) {}
            func remeasure() {}
            func applyWindowBehaviour() {}
            func toggle(cause: PanelCause) {}
            func expandNow(cause: PanelCause) {}
            func glance() {}
        }
        let screens = NSScreen.screens
        let presenters: [any PanelPresenting] = screens.map { Stub(screen: $0) }
        let inside = CGPoint(x: screens[0].frame.midX, y: screens[0].frame.midY)
        #expect(AppDelegate.presenter(for: inside, among: presenters)?.screen == screens[0])
        #expect(AppDelegate.presenter(for: CGPoint(x: -100_000, y: -100_000), among: presenters) == nil)
    }

    @Test func edgePlacementKeepsClearOfTheChrome() {
        let area = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let size = NSSize(width: 200, height: 40)
        var chrome = EdgePanelController.Chrome()
        #expect(EdgePanelController.placement(for: size, edge: .top, area: area, chrome: chrome).maxY == 976)
        chrome.menuBarHides = true
        chrome.menuBarThickness = 24
        #expect(EdgePanelController.placement(for: size, edge: .top, area: area, chrome: chrome).maxY == 952)
        chrome = EdgePanelController.Chrome(dockHides: true, dockOrientation: "left")
        #expect(EdgePanelController.placement(for: size, edge: .left, area: area, chrome: chrome).minX == 6 + SystemChrome.dockRevealStrip)
        #expect(EdgePanelController.placement(for: size, edge: .right, area: area, chrome: chrome).maxX == 1506)
        #expect(EdgePanelController.placement(for: size, edge: .bottom, area: area, chrome: chrome).minY == 6)
        chrome = EdgePanelController.Chrome(dockHides: true, dockOrientation: "right")
        #expect(EdgePanelController.placement(for: size, edge: .right, area: area, chrome: chrome).maxX == 1506 - SystemChrome.dockRevealStrip)
        chrome = EdgePanelController.Chrome(stageManager: true)
        #expect(EdgePanelController.placement(for: size, edge: .left, area: area, chrome: chrome).minX == 6 + SystemChrome.stageManagerStripWidth)
        chrome.stageManagerStripHides = true
        #expect(EdgePanelController.placement(for: size, edge: .left, area: area, chrome: chrome).minX == 6 + SystemChrome.dockRevealStrip)
        #expect(["bottom", "left", "right"].contains(SystemChrome.dockOrientation))
    }

    @Test func theMenuBarPinComposesThePinnedToolsFigures() {
        let now = DateParsing.iso8601("2026-09-01T12:00:00Z")!
        let claude = [LimitWindow(id: "five_hour", label: "Session", usedFraction: 0.14, resetsAt: now.addingTimeInterval(3600), periodDuration: Period.fiveHours),
                      LimitWindow(id: "seven_day", label: "Weekly", usedFraction: 0.04, resetsAt: now.addingTimeInterval(86400), periodDuration: Period.week)]
        let codex = [LimitWindow(id: "session", label: "Session", usedFraction: 0.61, resetsAt: now.addingTimeInterval(3600), periodDuration: Period.fiveHours)]
        #expect(MenuBarItem.label(readings: [(claude, .used), (codex, .used)], countdown: false, now: now) == "14% · 4% | 61%")
        #expect(MenuBarItem.label(readings: [(claude, .left)], countdown: true, now: now) == "86% 1h · 96%")
        #expect(MenuBarItem.pinnedTools(visible: [.claude, .codex, .cursor], chosen: [.cursor, .codex]) == [.codex, .cursor])
        #expect(MenuBarItem.pinnedTools(visible: [.claude, .codex], chosen: [.copilot]) == [.claude])
        #expect(MenuBarItem.pinnedTools(visible: [], chosen: []) == [])
        let bars = MenuBarBars.image(windows: claude, now: now)
        #expect(bars.size == MenuBarBars.size)
        #expect(bars.isTemplate)
        let behind = [LimitWindow(id: "session", label: "Session", usedFraction: 0.9, resetsAt: now.addingTimeInterval(4 * 3600), periodDuration: Period.fiveHours)]
        #expect(!MenuBarBars.image(windows: behind, now: now).isTemplate)
    }

    @Test func theAwakeRuleHoldsOnlyWhileWorkingOnPower() {
        #expect(AwakeRule.shouldHold(working: 1, enabled: true, onBattery: false, allowOnBattery: false))
        #expect(!AwakeRule.shouldHold(working: 0, enabled: true, onBattery: false, allowOnBattery: false))
        #expect(!AwakeRule.shouldHold(working: 1, enabled: false, onBattery: false, allowOnBattery: false))
        #expect(!AwakeRule.shouldHold(working: 2, enabled: true, onBattery: true, allowOnBattery: false))
        #expect(AwakeRule.shouldHold(working: 2, enabled: true, onBattery: true, allowOnBattery: true))
        #expect(AwakeRule.footer(working: 2) == "Keeping awake · 2 sessions")
        #expect(AwakeRule.footer(working: 1) == "Keeping awake · 1 session")
    }

    @Test func launchRepairNeverRunsFromABuildFolderOrUnderSmoke() {
        #expect(HookRepair.mayRepair(executable: "/Applications/Notchmeter.app/Contents/MacOS/Notchmeter", arguments: ["Notchmeter"]))
        #expect(!HookRepair.mayRepair(executable: "/Users/me/Developer/notchmeter/build/Notchmeter.app/Contents/MacOS/Notchmeter", arguments: ["Notchmeter"]))
        #expect(!HookRepair.mayRepair(executable: "/Users/me/Developer/notchmeter/.build/debug/Notchmeter", arguments: ["Notchmeter"]))
        #expect(!HookRepair.mayRepair(executable: "/Applications/Notchmeter.app/Contents/MacOS/Notchmeter", arguments: ["Notchmeter", "--smoke"]))
        let paths = LegacyCaches.paths(home: URL(fileURLWithPath: "/Users/me"), bundleIdentifier: "com.amirhackett.notchmeter")
        #expect(paths.map(\.path) == ["/Users/me/Library/Caches/com.amirhackett.notchmeter", "/Users/me/Library/HTTPStorages/com.amirhackett.notchmeter",
                                      "/Users/me/Library/HTTPStorages/com.amirhackett.notchmeter.binarycookies"])
    }

    @Test func providerLinksParseAndTheSparklineSpeaks() {
        for tool in ToolID.allCases {
            #expect(ProviderLinks.usage(tool).scheme == "https")
            #expect(ProviderLinks.usage(tool).host != nil)
            if let status = ProviderLinks.status(tool) { #expect(status.scheme == "https") }
        }
        #expect(ProviderLinks.status(.antigravity) == nil)
        #expect(ProviderLinks.status(.claude)?.host == "status.anthropic.com")
        let now = DateParsing.iso8601("2026-09-01T12:00:00Z")!
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let series = [DailySpend(day: now.addingTimeInterval(-86400), cost: 212, tokens: 1, topModel: "claude-opus-5"),
                      DailySpend(day: now, cost: 118, tokens: 1, topModel: "claude-fable-5-1")]
        #expect(Sparkline.summary(series, now: now, calendar: utc) == "2 days, $118 today, peak $212 on yesterday, top model Claude Fable 5.1")
        #expect(Sparkline.summary([]) == "")
        #expect(Meter.tickOffset(width: 100, tick: 0.5) == 49)
        #expect(Meter.tickOffset(width: 100, tick: 1.2) == 98)
        #expect(Meter.tickOffset(width: 100, tick: 0) == 0)
    }
}

/// The retry helper every provider shares.
@Suite struct RetryAfterRules {
    let now = DateParsing.iso8601("2026-09-01T12:00:00Z")!

    @Test func secondsDatesAndGitHubResets() {
        #expect(RetryAfter.seconds(retryAfter: "120", rateLimitReset: nil, now: now) == 120)
        #expect(RetryAfter.seconds(retryAfter: " 30 ", rateLimitReset: nil, now: now) == 30)
        #expect(RetryAfter.seconds(retryAfter: "Tue, 01 Sep 2026 12:05:00 GMT", rateLimitReset: nil, now: now) == 300)
        let reset = String(Int(now.timeIntervalSince1970) + 600)
        #expect(RetryAfter.seconds(retryAfter: nil, rateLimitReset: reset, now: now) == 600)
        #expect(RetryAfter.seconds(retryAfter: "soon", rateLimitReset: reset, now: now) == 600)
        #expect(RetryAfter.seconds(retryAfter: nil, rateLimitReset: nil, now: now) == nil)
        #expect(RetryAfter.seconds(retryAfter: "Tue, 01 Sep 2026 11:00:00 GMT", rateLimitReset: nil, now: now) == 0)
        let response = HTTPURLResponse(url: URL(string: "https://api.github.com/x")!, statusCode: 429, httpVersion: nil, headerFields: ["retry-after": "45"])
        #expect(RetryAfter.seconds(from: response, now: now) == 45)
        #expect(RetryAfter.seconds(from: nil) == nil)
    }
}
