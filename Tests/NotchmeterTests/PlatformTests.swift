import AppKit
import Testing
@testable import Notchmeter

/// The display choice over a fake screen list, the edge placement with a hidden Dock, the menu bar default, the
/// translocation check, the ring selection, the key names and the machine-readable report.
@Suite struct DisplaySelection {
    let builtIn = ScreenInfo(name: "Built-in Retina Display", hasNotch: true, isMain: false, frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
    let external = ScreenInfo(name: "DELL U2723QE", hasNotch: false, isMain: true, frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440))

    @Test func eachChoiceWithItsFallbacks() {
        let screens = [builtIn, external]
        #expect(ScreenSelection.indices(for: .builtIn, screens: screens, pointer: .zero) == [0])
        #expect(ScreenSelection.indices(for: .main, screens: screens, pointer: .zero) == [1])
        #expect(ScreenSelection.indices(for: .pointer, screens: screens, pointer: CGPoint(x: 2000, y: 100)) == [1])
        #expect(ScreenSelection.indices(for: .pointer, screens: screens, pointer: CGPoint(x: 100, y: 100)) == [0])
        #expect(ScreenSelection.indices(for: .pointer, screens: screens, pointer: CGPoint(x: -100, y: -100)) == [1])
        #expect(ScreenSelection.indices(for: .all, screens: screens, pointer: .zero) == [0, 1])
        #expect(ScreenSelection.indices(for: .named("DELL U2723QE"), screens: screens, pointer: .zero) == [1])
        #expect(ScreenSelection.indices(for: .named("Gone"), screens: screens, pointer: .zero) == [0])
        #expect(ScreenSelection.indices(for: .builtIn, screens: [external], pointer: .zero) == [0])
        #expect(ScreenSelection.indices(for: .named("Gone"), screens: [external], pointer: .zero) == [0])
        #expect(ScreenSelection.indices(for: .all, screens: [], pointer: .zero) == [])
        #expect(DisplayChoice(rawValue: "named:DELL U2723QE") == .named("DELL U2723QE"))
        #expect(DisplayChoice(rawValue: "named:") == nil)
        #expect(DisplayChoice(rawValue: DisplayChoice.pointer.rawValue) == .pointer)
    }

    @Test func edgePlacementKeepsClearOfADockThatHides() {
        let area = NSRect(x: 0, y: 0, width: 1512, height: 950)
        let size = NSSize(width: 200, height: 40)
        #expect(EdgePanelController.placement(for: size, edge: .bottom, area: area, dockHides: false).minY == 6)
        #expect(EdgePanelController.placement(for: size, edge: .bottom, area: area, dockHides: true).minY == 6 + SystemChrome.dockRevealStrip)
        #expect(EdgePanelController.placement(for: size, edge: .top, area: area, dockHides: false).maxY == 944)
        #expect(EdgePanelController.placement(for: size, edge: .left, area: area, dockHides: false).minX == 6)
        #expect(EdgePanelController.placement(for: size, edge: .right, area: area, dockHides: false).maxX == 1506)
        #expect(EdgePanelController.placement(for: NSSize(width: 200, height: 2000), edge: .left, area: area, dockHides: false).maxY == 950)
    }

    @MainActor @Test func menuBarItemDefaultsOnOnlyWithoutANotchInTheTopLayout() {
        #expect(MenuBarPolicy.defaultShown(edge: .top, screens: []) == true)
        #expect(MenuBarPolicy.defaultShown(edge: .left, screens: []) == false)
        let hasNotch = NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
        #expect(MenuBarPolicy.defaultShown(edge: .top) == !hasNotch)
    }

    @Test func translocationAndApplicationsFolder() {
        #expect(Translocation.isTranslocated("/private/var/folders/yp/x/T/AppTranslocation/ABC/d/Notchmeter.app"))
        #expect(Translocation.shouldOffer(bundlePath: "/private/var/folders/yp/x/T/AppTranslocation/ABC/d/Notchmeter.app", home: "/Users/me"))
        #expect(!Translocation.shouldOffer(bundlePath: "/Applications/Notchmeter.app", home: "/Users/me"))
        #expect(!Translocation.shouldOffer(bundlePath: "/Users/me/Applications/Notchmeter.app", home: "/Users/me"))
        #expect(!Translocation.shouldOffer(bundlePath: "/Users/me/Developer/notchmeter/build/Notchmeter.app", home: "/Users/me"))
        #expect(Translocation.shouldOffer(bundlePath: "/Users/me/Downloads/Notchmeter.app", home: "/Users/me"))
        #expect(!Translocation.shouldOffer(bundlePath: "/Users/me/.build/debug/Notchmeter", home: "/Users/me"))
    }

    @Test func ringSelectionHonoursTheChoiceAndTheHiddenSet() {
        let now = Date()
        let reading = UsageReading(tool: .claude, windows: [
            LimitWindow(id: "five_hour", label: "Session", usedFraction: 0.1, resetsAt: now),
            LimitWindow(id: "seven_day", label: "Weekly", usedFraction: 0.2, resetsAt: now),
            LimitWindow(id: "scoped_fable", label: "Fable", usedFraction: 0.3, resetsAt: now, model: "Fable"),
            LimitWindow(id: "extra_usage", label: "Extra", usedFraction: 0.4, resetsAt: nil),
        ], plan: nil, fetchedAt: now, observedAt: nil)
        #expect(RingSelection.windows(of: reading, chosen: [], hidden: []).map(\.id) == ["five_hour", "seven_day"])
        #expect(RingSelection.windows(of: reading, chosen: ["scoped_fable", "extra_usage"], hidden: []).map(\.id) == ["scoped_fable", "extra_usage"])
        #expect(RingSelection.windows(of: reading, chosen: ["scoped_fable"], hidden: []).map(\.id) == ["scoped_fable", "five_hour"])
        #expect(RingSelection.windows(of: reading, chosen: ["gone", "seven_day"], hidden: []).map(\.id) == ["seven_day", "five_hour"])
        #expect(RingSelection.windows(of: reading, chosen: ["five_hour"], hidden: ["five_hour", "seven_day"]).map(\.id) == ["scoped_fable", "extra_usage"])
        #expect(RingSelection.windows(of: reading, chosen: ["seven_day", "seven_day"], hidden: []).map(\.id) == ["seven_day", "five_hour"])
    }

    @Test func hotkeyDescriptionsAndKeyNames() {
        #expect(Hotkey(keyCode: 45, modifiers: Hotkey.commandKey | Hotkey.shiftKey).description == "⇧⌘N")
        #expect(Hotkey(keyCode: 49, modifiers: Hotkey.controlKey | Hotkey.optionKey).description == "⌃⌥Space")
        #expect(KeyNames.name(for: 999) == "Key 999")
        #expect(KeyNames.name(for: 122) == "F1")
    }

    @Test func compactLabelCarriesTheCountdownOnTheMainWindow() {
        let now = DateParsing.iso8601("2026-09-01T12:00:00Z")!
        let windows = [LimitWindow(id: "five_hour", label: "Session", usedFraction: 0.9, resetsAt: now.addingTimeInterval(32 * 60), periodDuration: Period.fiveHours),
                       LimitWindow(id: "seven_day", label: "Weekly", usedFraction: 0.04, resetsAt: now.addingTimeInterval(4 * 86400), periodDuration: Period.week)]
        #expect(CompactLabel.text(for: windows, display: .used, countdown: true, now: now) == "90% 32m · 4%")
        #expect(CompactLabel.text(for: windows, display: .used, now: now) == "90% · 4%")
        #expect(CompactLabel.text(for: windows, display: .left, countdown: true, now: now) == "10% 32m · 96%")
        let past = [LimitWindow(id: "five_hour", label: "Session", usedFraction: 0.9, resetsAt: now.addingTimeInterval(-60), periodDuration: Period.fiveHours)]
        #expect(CompactLabel.text(for: past, display: .used, countdown: true, now: now) == "90%")
        #expect(ResetText.compactDuration(6 * 86400 + 3600) == "6d")
        #expect(ResetText.compactDuration(4 * 3600 + 59 * 60) == "4h")
        #expect(ResetText.compactDuration(20) == "1m")
    }

    @Test func moneyFollowsTheUsersCurrencyAndCountsTokens() {
        Localization.use(language: "en")
        #expect(Money.format(8.4, rate: 1, symbol: "$") == "$8.40")
        #expect(Money.format(10, rate: 0.9, symbol: "€") == "€9.00")
        #expect(Money.format(2000, rate: 0.9, symbol: "€") == "€1800")
        #expect(Money.format(1.5, cents: false, rate: 1, symbol: "$") == "$2")
        #expect(Money.symbol(for: "USD") == "$")
        #expect(!Money.symbol(for: "EUR").isEmpty)
        #expect(Money.symbol(for: "EUR") != "¤")
        #expect(Money.tokens(4_200_000) == "4.2M tokens")
        #expect(Money.tokens(12_000_000) == "12M tokens")
        #expect(Money.tokens(310_400) == "310K tokens")
        #expect(Money.tokens(812) == "812 tokens")
        #expect(TokenBreakdown(input: 10, cacheRead: 30).cacheReadShare == 0.75)
        #expect(TokenBreakdown().cacheReadShare == nil)
    }
}

@Suite struct MachineReadableReport {
    init() { Localization.use(language: "en") }

    let now = DateParsing.iso8601("2026-09-01T12:00:00Z")!

    func reading(_ used: Double) -> UsageReading {
        UsageReading(tool: .claude, windows: [LimitWindow(id: "five_hour", label: "Session", usedFraction: used, resetsAt: now.addingTimeInterval(4 * 3600), periodDuration: Period.fiveHours)],
                     plan: "Max 5x", fetchedAt: now, observedAt: nil)
    }

    @Test func exitCodesMirrorTheMonitor() {
        #expect(UsageReport(tools: [:], cost: nil, advice: [], now: now).exitCode == .noData)
        #expect(UsageReport(tools: [.claude: .failed("x", cached: nil)], cost: nil, advice: [], now: now).exitCode == .noData)
        #expect(UsageReport(tools: [.claude: .ready(reading(0))], cost: nil, advice: [], now: now).exitCode == .noSession)
        #expect(UsageReport(tools: [.claude: .ready(reading(0.1))], cost: nil, advice: [], now: now).exitCode == .ok)
        #expect(UsageReport(tools: [.claude: .ready(reading(0.85))], cost: nil, advice: [], now: now).exitCode == .nearLimit)
        #expect(UsageReport(tools: [.claude: .ready(reading(0.5))], cost: nil, advice: [], now: now).exitCode == .nearLimit)
        #expect(UsageReport(tools: [.claude: .ready(reading(1))], cost: nil, advice: [], now: now).exitCode == .limitHit)
    }

    @Test func jsonHasTheSchemaSortedKeysAndNoToken() throws {
        let cost = DemoFixtures.cost(now: now)
        let drain = Drain(from: 0.12, to: 0.61, over: 3600)
        let report = UsageReport(tools: [.claude: .ready(reading(0.61)), .codex: .notInstalled], order: [.claude, .codex], cost: cost,
                                 advice: [Advice(id: "x", tool: .claude, priority: .warn, symbol: "flame.fill", text: "This hour burned $31.20")],
                                 drains: [DrainLog.Key(tool: .claude, window: "five_hour"): drain], now: now)
        let object = try #require(try JSONSerialization.jsonObject(with: report.json) as? [String: Any])
        #expect(object["schema"] as? String == UsageReport.schema)
        #expect(object["exitCode"] as? Int == 10)
        #expect(object["generatedAt"] as? String == "2026-09-01T12:00:00.000Z")
        let tools = try #require(object["tools"] as? [[String: Any]])
        #expect(tools.map { $0["tool"] as? String } == ["claude", "codex"])
        let windows = try #require(tools[0]["windows"] as? [[String: Any]])
        #expect((windows[0]["usedFraction"] as? NSNumber)?.doubleValue == 0.61)
        #expect(windows[0]["pace"] as? String == "behind")
        #expect(((windows[0]["drainLastHour"] as? [String: Any])?["from"] as? NSNumber)?.doubleValue == 0.12)
        #expect(tools[1]["status"] as? String == "notInstalled")
        let costObject = try #require(object["cost"] as? [String: Any])
        // The headline figures are the total across the tools that can report spend; each tool is under "providers".
        let providers = try #require(costObject["providers"] as? [[String: Any]])
        #expect(providers.map { $0["tool"] as? String } == ["claude", "cursor"])
        #expect(providers.map { $0["source"] as? String } == ["localTranscripts", "billingExport"])
        #expect((providers[0]["today"] as? NSNumber)?.doubleValue == 118.31)
        #expect((costObject["today"] as? NSNumber)?.doubleValue
            == providers.reduce(0.0) { $0 + (($1["today"] as? NSNumber)?.doubleValue ?? 0) })
        #expect(providers[1]["burnMultiple"] == nil)
        #expect((costObject["ranges"] as? [String: Any])?.keys.sorted() == ["last30Days", "last90Days", "month", "today", "week", "yesterday"])
        let text = String(decoding: report.json, as: UTF8.self)
        #expect(!text.contains("token\":"))
        #expect(!text.contains(Paths.home.path))
        let keys = text.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\"") else { return nil }
            return String(trimmed.dropFirst().prefix { $0 != "\"" })
        }
        #expect(keys.prefix(4) == ["advice", "cost", "currency", "today"] || keys.first == "advice")
    }

    @MainActor @Test func localAPIParsesGetPathsOnly() {
        #expect(LocalAPI.path(of: "GET /v1/limits HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n") == "/v1/limits")
        #expect(LocalAPI.path(of: "GET /v1/limits/claude HTTP/1.1\r\n") == "/v1/limits/claude")
        #expect(LocalAPI.path(of: "POST /v1/limits HTTP/1.1\r\n") == nil)
        #expect(LocalAPI.path(of: "") == nil)
        let response = String(decoding: LocalAPI.response(status: 404, body: Data("{}".utf8)), as: UTF8.self)
        #expect(response.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
        #expect(!response.contains("Access-Control-Allow-Origin"))
        #expect(response.hasSuffix("\r\n\r\n{}"))
    }
}
