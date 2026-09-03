import Foundation
import SQLite3
import Testing
@testable import Notchmeter

/// Cursor's spend from the export to the Cost card, through the provider the app actually builds.
///
/// The app used to build `CursorProvider` with its usage-events read hard-wired off: a second, argument-free
/// `ProviderRegistry.all` shadowed the wired one, and the init defaulted the switch to `{ false }`. The export
/// never ran, Cursor never had a `ProviderCost`, and no ordering of the assistants could make the Cost card lead
/// with Cursor. These tests build the provider the way every caller in the app does — no switch passed in — so a
/// construction path that forgets to wire one up fails here.
@Suite(.serialized) struct CursorSpendReachesTheCard {
    init() { Localization.use(language: "en") }

    /// The stub's answers, and every request it was asked, so the Origin header and the paging can be checked.
    final class Exchange: @unchecked Sendable {
        struct Ask: Sendable {
            let url: URL
            let origin: String?
            let page: Int?
        }

        var answer: @Sendable (URL, Int) -> (Int, Data) = { _, _ in (200, Data("{}".utf8)) }
        private(set) var asks: [Ask] = []
        private let lock = NSLock()

        func record(_ ask: Ask) {
            lock.lock()
            asks.append(ask)
            lock.unlock()
        }

        var pages: [Int] { asks.compactMap { $0.url == CursorProvider.usageEventsURL ? $0.page : nil } }
        func ask(_ url: URL) -> Ask? { asks.first { $0.url == url } }
    }

    final class StubProtocol: URLProtocol {
        nonisolated(unsafe) static var exchange = Exchange()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        /// URLSession hands a POST body to a URLProtocol as a stream, so the page is read back from there.
        static func body(of request: URLRequest) -> Data {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(contentsOf: buffer[0..<read])
            }
            return data
        }

        override func startLoading() {
            let object = try? JSONSerialization.jsonObject(with: Self.body(of: request)) as? [String: Any]
            let page = (object?["page"] as? Int) ?? 1
            Self.exchange.record(Exchange.Ask(url: request.url!, origin: request.value(forHTTPHeaderField: "Origin"), page: page))
            let (status, data) = Self.exchange.answer(request.url!, page)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    static let summary = Data(#"""
    {"membershipType":"pro","limitType":"user","isUnlimited":false,
     "individualUsage":{"plan":{"enabled":true,"used":250,"limit":2000,"totalPercentUsed":12.5}}}
    """#.utf8)

    /// A session token the provider will accept: an unexpired JWT whose subject carries the user id.
    static var token: String {
        let payload = #"{"sub":"auth0|user_01ABC","exp":4102444800}"#
        let encoded = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJIUzI1NiJ9.\(encoded).signature"
    }

    /// Anchored to midday, not to the moment the suite runs: events an hour or two "ago" have to stay on the
    /// same day as `now`, and just after midnight they did not, so the totals moved with the clock.
    static var midday: Date {
        Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
    }

    static func events(_ items: [(offset: TimeInterval, cents: Double, model: String)]) -> Data {
        let list = items.map { item -> [String: Any] in
            ["timestamp": String(Int(midday.addingTimeInterval(item.offset).timeIntervalSince1970 * 1000)),
             "model": item.model, "tokenUsage": ["inputTokens": 1000, "outputTokens": 100, "totalCents": item.cents]]
        }
        return try! JSONSerialization.data(withJSONObject: ["usageEventsDisplay": list])
    }

    /// The provider as the app builds it: a session and a state database of our own, and no usage-events switch
    /// passed in, so it has to find the setting itself.
    func withCursor(_ name: String, usageEvents: Bool? = nil,
                    answer: @escaping @Sendable (URL, Int) -> (Int, Data),
                    _ body: (CursorProvider, CostHistory, UserDefaults, Exchange) async throws -> Void) async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("notchmeter-cursor-spend-\(name)-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let database = dir.appendingPathComponent("state.vscdb")
        var handle: OpaquePointer?
        #expect(sqlite3_open(database.path, &handle) == SQLITE_OK)
        sqlite3_exec(handle, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB); INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', '\(Self.token)');", nil, nil, nil)
        sqlite3_close(handle)

        let suite = "NotchmeterTests.CursorSpend.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        if let usageEvents { defaults.set(usageEvents, forKey: ProviderOptIn.cursorUsageEvents.key) }

        let exchange = Exchange()
        exchange.answer = answer
        StubProtocol.exchange = exchange
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let history = CostHistory(url: dir.appendingPathComponent("daily-history-v1.jsonl"), tool: .cursor)
        let provider = CursorProvider(session: URLSession(configuration: configuration), stateDatabase: database,
                                      defaults: defaults, history: history)
        try await body(provider, history, defaults, exchange)
    }

    static func answering(_ eventPages: @escaping @Sendable (Int) -> (Int, Data)) -> @Sendable (URL, Int) -> (Int, Data) {
        { url, page in
            switch url {
            case CursorProvider.summaryURL: (200, summary)
            case CursorProvider.teamsURL: (200, Data("{}".utf8))
            case CursorProvider.usageEventsURL: eventPages(page)
            default: (404, Data())
            }
        }
    }

    /// The regression: with nothing passed in, the provider reads the setting, fetches the export, writes Cursor's
    /// days, and the Cost card leads with whichever assistant the user put first. Against the old build the export
    /// is never fetched, `CursorCostReader` answers nil, and the `#require` below fails.
    @Test func theExportIsReadAndItsSpendLeadsTheCardInTheUsersOrder() async throws {
        let export = Self.events([(offset: -3600, cents: 250, model: "claude-4-sonnet"), (offset: -7200, cents: 100, model: "gpt-5")])
        try await withCursor("order", answer: Self.answering { _ in (200, export) }) { provider, history, defaults, exchange in
            let reading = try await provider.fetch()
            #expect(reading.tool == .cursor)
            // Cursor's dashboard POSTs are CSRF-checked; without this header the export answers 403.
            #expect(exchange.ask(CursorProvider.usageEventsURL)?.origin == CursorProvider.origin)
            #expect(exchange.ask(CursorProvider.summaryURL)?.origin == nil)

            let now = Self.midday
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: now)
            let cursor = try #require(CursorCostReader(history: history)
                .read(now: now, daysBack: 30, weekStart: today, calendar: calendar, state: ProviderReadState(readAt: now)))
            #expect(cursor.source == .billingExport)
            #expect(abs(cursor.totals(.today).cost - 3.5) < 1e-9)
            #expect(CursorExportRead.load(from: defaults)?.events == 2)

            let claude = try #require(ProviderCost.build(tool: .claude, source: .localTranscripts,
                                                         days: [today: CostHistory.Record(cost: 6, tokens: TokenBreakdown(input: 900), byModel: [:], byProject: [:])],
                                                         now: now, weekStart: today, calendar: calendar, scannedAt: now))
            let carried: Set<ToolID> = [.claude, .cursor]
            let cursorFirst = CostSelection(all: [claude, cursor], order: [.cursor, .claude, .codex], carried: carried)
            #expect(cursorFirst.providers.map(\.tool) == [.cursor, .claude])
            // The donut's arcs, the legend's rows and the detail block all come off this one list.
            #expect(CostDonut.arcs(cursorFirst.weights(range: .today, mode: .cost)).map(\.tool) == [.cursor, .claude])
            #expect(cursorFirst.providers.first?.tool == .cursor)
            let claudeFirst = CostSelection(all: [claude, cursor], order: [.claude, .cursor, .codex], carried: carried)
            #expect(claudeFirst.providers.map(\.tool) == [.claude, .cursor])
            #expect(CostDonut.arcs(claudeFirst.weights(range: .today, mode: .cost)).map(\.tool) == [.claude, .cursor])
            // The same assistants either way round, so only the order moved.
            #expect(abs(cursorFirst.totals(.today).cost - claudeFirst.totals(.today).cost) < 1e-9)
        }
    }

    /// An account that was read and billed nothing is not an account nobody read.
    @Test func anEmptyExportSaysSoRatherThanClaimingNothingWasRead() async throws {
        try await withCursor("empty", answer: Self.answering { _ in (200, Data(#"{"usageEventsDisplay":[]}"#.utf8)) }) { provider, history, defaults, _ in
            _ = try await provider.fetch()
            let read = try #require(CursorExportRead.load(from: defaults))
            #expect(read.events == 0)
            #expect(read.problem == nil)
            #expect(history.load().isEmpty)
            let gaps = CostAbsence.gaps(carried: [.cursor], reporting: [], cursorUsageEvents: true, cursorExport: read,
                                        problems: [:], nothingLocal: [])
            #expect(gaps.map(\.text) == ["Cursor: nothing used in the last 30 days"])
            let included = CursorExportRead(readAt: Date(), events: 12, costUSD: 0)
            #expect(CostAbsence.reason(for: .cursor, cursorUsageEvents: true, cursorExport: included, problem: nil, nothingLocal: false)
                == .nothingBilled(events: 12))
            #expect(CostAbsence.nothingBilled(events: 12).text == "12 usage events in the last 30 days, none of them billed")
        }
    }

    /// A refusal used to reach the log and nowhere else, and the card said "no spend read yet" for it.
    @Test func aRefusedExportReachesTheCardAndNotJustTheLog() async throws {
        try await withCursor("refused", answer: Self.answering { _ in (403, Data()) }) { provider, history, defaults, _ in
            // The refusal is the second read's alone: the reading itself still stands.
            let reading = try await provider.fetch()
            #expect(reading.windows.first?.usedFraction == 0.125)
            #expect(history.load().isEmpty)
            let read = try #require(CursorExportRead.load(from: defaults))
            #expect(read.events == 0)
            let gaps = CostAbsence.gaps(carried: [.cursor], reporting: [], cursorUsageEvents: true, cursorExport: read,
                                        problems: [:], nothingLocal: [])
            #expect(gaps.map(\.text) == ["Cursor: cursor.com refused its usage export (HTTP 403)"])
        }
    }

    /// The switch still switches it off, and off means no request at all.
    @Test func theSettingStillTurnsTheSecondReadOff() async throws {
        try await withCursor("off", usageEvents: false, answer: Self.answering { _ in (200, Self.events([(offset: -3600, cents: 250, model: "gpt-5")])) }) { provider, history, defaults, exchange in
            _ = try await provider.fetch()
            #expect(exchange.ask(CursorProvider.usageEventsURL) == nil)
            #expect(history.load().isEmpty)
            #expect(CursorExportRead.load(from: defaults) == nil)
            #expect(CostAbsence.reason(for: .cursor, cursorUsageEvents: false, cursorExport: nil, problem: nil, nothingLocal: false)
                == .settingOff("Also read Cursor's usage events"))
        }
    }

    /// A full page means there is more to come: an account busier than one page used to be quietly understated.
    @Test func everyPageOfTheExportIsRead() async throws {
        let full = Self.events((0..<CursorProvider.eventPageSize).map { _ in (offset: -3600, cents: 1, model: "gpt-5") })
        let tail = Self.events([(offset: -7200, cents: 50, model: "gpt-5")])
        try await withCursor("pages", answer: Self.answering { page in (200, page == 1 ? full : tail) }) { provider, _, defaults, exchange in
            _ = try await provider.fetch()
            #expect(exchange.pages == [1, 2])
            #expect(CursorExportRead.load(from: defaults)?.events == CursorProvider.eventPageSize + 1)
            #expect(abs((CursorExportRead.load(from: defaults)?.costUSD ?? 0) - 5.5) < 1e-9)
        }
    }

    /// A server that ignores `page` answers the same events forever. Stopping is a short total; carrying on would
    /// be an invented one.
    @Test func aServerThatIgnoresThePageIsNotCountedTwice() async throws {
        let full = Self.events((0..<CursorProvider.eventPageSize).map { _ in (offset: -3600, cents: 1, model: "gpt-5") })
        try await withCursor("repeats", answer: Self.answering { _ in (200, full) }) { provider, _, defaults, exchange in
            _ = try await provider.fetch()
            #expect(exchange.pages == [1, 2])
            #expect(CursorExportRead.load(from: defaults)?.events == CursorProvider.eventPageSize)
        }
    }
}

/// The daily-totals file is shared: Claude's transcripts and Cursor's export both write their own series into it.
/// Compaction used to rewrite the whole file from the calling tool's records, so the first compacted Cursor write
/// would have deleted every Claude day (and the other way round). Nothing reached it while the Cursor export never
/// ran; making the export work arms it.
@Suite struct SharedDailyHistory {
    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func days(_ count: Int, from: Date, cost: Double) -> [Date: CostHistory.Record] {
        (0..<count).reduce(into: [:]) { days, offset in
            guard let day = utc.date(byAdding: .day, value: -offset, to: from) else { return }
            days[day] = CostHistory.Record(cost: cost + Double(offset) / 100, tokens: TokenBreakdown(input: 10), byModel: [:], byProject: [:])
        }
    }

    @Test func compactingOneToolsDaysKeepsEveryOtherTools() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("notchmeter-shared-history-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("daily-history-v1.jsonl")
        let today = utc.startOfDay(for: Date())
        let claude = CostHistory(url: url, tool: .claude)
        let cursor = CostHistory(url: url, tool: .cursor)

        let claudeDays = days(10, from: today, cost: 1)
        claude.record(claudeDays, existing: [:], calendar: utc)
        #expect(claude.load(calendar: utc).count == 10)

        // Past the compaction threshold, which rewrites the whole file rather than appending to it.
        let cursorDays = days(CostHistory.compactAbove + 1, from: today, cost: 0.5)
        cursor.record(cursorDays, existing: [:], calendar: utc)
        #expect(cursor.load(calendar: utc).count == CostHistory.compactAbove + 1)
        #expect(claude.load(calendar: utc).count == 10)
        #expect(abs((claude.load(calendar: utc)[today]?.cost ?? 0) - 1) < 1e-9)
        // And the file is compacted: one line per tool and day, not a line per write.
        let lines = try Data(contentsOf: url).split(separator: 0x0A).count
        #expect(lines == CostHistory.compactAbove + 11)
    }
}
