import Foundation
import Testing
@testable import Notchmeter

/// The catalog is read strictly: one bad field refuses the whole file, and every rule below is one a typo in a
/// pull request could otherwise carry into a user's Cost card.
@Suite struct PricingCatalogValidation {
    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func catalog(anthropic: [[String: Any]] = [], openai: [[String: Any]] = [], schema: Any = 1, published: Any = "2026-09-24") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schema": schema, "published": published, "anthropic": anthropic, "openai": openai])
    }

    static func anthropic(_ prefix: String = "claude-nimbus-1", effective: String = "2026-09-10", input: Double = 3, output: Double = 12,
                          extra: [String: Any] = [:]) -> [String: Any] {
        var row: [String: Any] = ["prefix": prefix, "effective": effective, "input": input, "output": output]
        row.merge(extra) { _, new in new }
        return row
    }

    static func openai(_ id: String = "gpt-6", effective: String = "2026-09-10", input: Double = 3, output: Double = 12,
                       extra: [String: Any] = [:]) -> [String: Any] {
        var row: [String: Any] = ["id": id, "effective": effective, "input": input, "output": output]
        row.merge(extra) { _, new in new }
        return row
    }

    static func refused(_ data: Data) -> PricingCatalog.Failure? {
        do {
            _ = try PricingCatalog.parse(data)
            return nil
        } catch let failure as PricingCatalog.Failure {
            return failure
        } catch {
            return nil
        }
    }

    /// The catalog published with this build passes the build's own checks and, applied to it, changes nothing:
    /// every entry repeats a row the build already has, which is what a catalog written the day the tables were
    /// read should do. A row that drifts from ModelPricing or OpenAIPricing fails here before it is published.
    @Test func theCommittedCatalogRepeatsTheBuildsTables() throws {
        let data = try Data(contentsOf: Self.repository.appendingPathComponent("pricing/catalog.json"))
        let document = try PricingCatalog.parse(data)
        #expect(document.anthropic.count == ModelPricing.table.count)
        #expect(document.openai.count == OpenAIPricing.table.count)
        #expect(Set(document.anthropic.map(\.prefix)) == Set(ModelPricing.table.map(\.prefix)))
        #expect(Set(document.openai.map(\.id)) == Set(OpenAIPricing.table.keys))
        for entry in document.anthropic {
            let row = try #require(ModelPricing.table.first { $0.prefix == entry.prefix }, Comment(rawValue: entry.prefix))
            #expect(entry.rates == row.rates, Comment(rawValue: entry.prefix))
            #expect(entry.fast == ModelPricing.fastTable.first { $0.prefix == entry.prefix }?.rates, Comment(rawValue: entry.prefix))
        }
        for entry in document.openai {
            #expect(entry.rates == OpenAIPricing.table[entry.id], Comment(rawValue: entry.id))
        }
        let anthropicBefore = ModelPricing.fingerprint
        let openaiBefore = OpenAIPricing.fingerprint
        defer { PricingCatalog.apply(nil) }
        #expect(PricingCatalog.apply(document) == false)
        #expect(ModelPricing.book.isBuiltIn)
        #expect(OpenAIPricing.book.isBuiltIn)
        #expect(ModelPricing.fingerprint == anthropicBefore)
        #expect(OpenAIPricing.fingerprint == openaiBefore)
        #expect(ModelPricing.resolve("claude-opus-5-5")?.source == .builtIn(ModelPricing.snapshotDate))
        #expect(OpenAIPricing.resolve("gpt-5.5")?.source == .builtIn(OpenAIPricing.snapshotDate))
    }

    @Test func theSchemaThePublishedDayAndTheListsAreRequired() throws {
        #expect(Self.refused(Data()) == .notJSON)
        #expect(Self.refused(Data("[]".utf8)) == .notJSON)
        #expect(Self.refused(Data("not json".utf8)) == .notJSON)
        #expect(Self.refused(try Self.catalog(schema: 2)) == .schema("schema 2: this build reads schema 1"))
        #expect(Self.refused(try Self.catalog(schema: "1")) == .schema("schema: not a whole number"))
        #expect(Self.refused(try Self.catalog(published: "24 Sep 2026")) == .schema("published: not a YYYY-MM-DD day"))
        #expect(Self.refused(try JSONSerialization.data(withJSONObject: ["schema": 1, "published": "2026-09-24", "openai": []]))
                == .schema("anthropic: not a list of entries"))
        #expect(Self.refused(try JSONSerialization.data(withJSONObject: ["schema": 1, "published": "2026-09-24", "anthropic": [], "openai": "none"]))
                == .schema("openai: not a list of entries"))
        #expect(Self.refused(Data(repeating: 0x20, count: PricingCatalog.largest + 1)) == .tooLarge)
        let empty = try PricingCatalog.parse(try Self.catalog())
        #expect(empty.count == 0)
        #expect(empty.published == "2026-09-24")
    }

    @Test func aRateMustBeAboveZeroAndUnderTheCap() throws {
        #expect(Self.refused(try Self.catalog(anthropic: [Self.anthropic(input: 0)])) != nil)
        #expect(Self.refused(try Self.catalog(anthropic: [Self.anthropic(output: -5)])) != nil)
        #expect(Self.refused(try Self.catalog(anthropic: [Self.anthropic(input: 1_000.5)])) != nil)
        #expect(Self.refused(try Self.catalog(anthropic: [Self.anthropic(extra: ["cacheRead": 0])])) != nil)
        #expect(Self.refused(try Self.catalog(anthropic: [Self.anthropic(extra: ["cacheWrite1h": 5_000])])) != nil)
        #expect(Self.refused(try Self.catalog(anthropic: [Self.anthropic(extra: ["input": "3"])])) != nil)
        #expect(Self.refused(try Self.catalog(anthropic: [["prefix": "claude-nimbus-1", "effective": "2026-09-10", "input": 3]])) != nil)
        #expect(Self.refused(try Self.catalog(openai: [Self.openai(input: 0)])) != nil)
        #expect(Self.refused(try Self.catalog(openai: [Self.openai(extra: ["cacheWrite": -1])])) != nil)
        // A cache write of nothing is a published fact for OpenAI's older rows, and reads.
        let free = try PricingCatalog.parse(try Self.catalog(openai: [Self.openai(extra: ["cacheWrite": 0])]))
        #expect(free.openai.first?.rates.cacheWrite == 0)
        // A rate exactly at the cap is inside it.
        let dear = try PricingCatalog.parse(try Self.catalog(openai: [Self.openai(input: 1_000, output: 1_000)]))
        #expect(dear.openai.first?.rates.output == 1_000)
    }

    @Test func aCacheReadNeverCostsMoreThanTheInputItStandsInFor() throws {
        #expect(Self.refused(try Self.catalog(anthropic: [Self.anthropic(input: 3, extra: ["cacheRead": 3.5])])) != nil)
        #expect(Self.refused(try Self.catalog(openai: [Self.openai(input: 3, extra: ["cachedInput": 4])])) != nil)
        let equal = try PricingCatalog.parse(try Self.catalog(openai: [Self.openai(input: 3, extra: ["cachedInput": 3])]))
        #expect(equal.openai.first?.rates.cachedInput == 3)
    }

    @Test func modelIdsAreLowerCaseAndAnthropicsStartWithClaude() throws {
        #expect(Self.refused(try Self.catalog(anthropic: [Self.anthropic("Claude-Nimbus-1")])) != nil)
        #expect(Self.refused(try Self.catalog(anthropic: [Self.anthropic("nimbus-1")])) != nil)
        #expect(Self.refused(try Self.catalog(anthropic: [Self.anthropic("claude nimbus")])) != nil)
        #expect(Self.refused(try Self.catalog(openai: [Self.openai("GPT-6")])) != nil)
        #expect(Self.refused(try Self.catalog(openai: [Self.openai("-gpt")])) != nil)
        #expect(Self.refused(try Self.catalog(openai: [Self.openai("openai/gpt-6")])) != nil)
        #expect(Self.refused(try Self.catalog(openai: [Self.openai(String(repeating: "g", count: 65))])) != nil)
        #expect(PricingCatalog.isModelID("gpt-5.6-sol"))
        #expect(PricingCatalog.isModelID("o3"))
        #expect(!PricingCatalog.isModelID("o"))
    }

    @Test func theEffectiveDayIsARealDayFromThisDecade() throws {
        #expect(Self.refused(try Self.catalog(anthropic: [Self.anthropic(effective: "2026-13-01")])) != nil)
        #expect(Self.refused(try Self.catalog(anthropic: [Self.anthropic(effective: "2026-02-30")])) != nil)
        #expect(Self.refused(try Self.catalog(anthropic: [Self.anthropic(effective: "2026-9-1")])) != nil)
        #expect(Self.refused(try Self.catalog(anthropic: [Self.anthropic(effective: "2019-12-31")])) != nil)
        #expect(Self.refused(try Self.catalog(openai: [Self.openai(effective: "tomorrow")])) != nil)
        let leap = try PricingCatalog.parse(try Self.catalog(anthropic: [Self.anthropic(effective: "2028-02-29")]))
        #expect(leap.anthropic.first?.start == PricingCatalog.day("2028-02-29"))
        #expect(PricingCatalog.day("2026-09-24") == DateParsing.iso8601("2026-09-24T00:00:00Z"))
    }

    @Test func aFastRowNeedsBothItsRatesAndTwoEntriesCannotShareADay() throws {
        #expect(Self.refused(try Self.catalog(anthropic: [Self.anthropic(extra: ["fastInput": 6])])) != nil)
        #expect(Self.refused(try Self.catalog(anthropic: [Self.anthropic(extra: ["fastOutput": 24])])) != nil)
        #expect(Self.refused(try Self.catalog(anthropic: [Self.anthropic(extra: ["fastInput": 6, "fastOutput": 24, "fastCacheRead": 7])])) != nil)
        let fast = try PricingCatalog.parse(try Self.catalog(anthropic: [Self.anthropic(extra: ["fastInput": 6, "fastOutput": 24])]))
        #expect(fast.anthropic.first?.fast == ModelRates(input: 6, output: 24))
        #expect(Self.refused(try Self.catalog(anthropic: [Self.anthropic(), Self.anthropic(output: 13)])) != nil)
        #expect(Self.refused(try Self.catalog(openai: [Self.openai(), Self.openai(output: 13)])) != nil)
        // The same model on two days is the history the catalog exists to carry.
        let history = try PricingCatalog.parse(try Self.catalog(anthropic: [Self.anthropic(), Self.anthropic(effective: "2026-10-01", output: 13)]))
        #expect(history.anthropic.count == 2)
    }

    @Test func aLongContextThresholdIsATokenCount() throws {
        #expect(Self.refused(try Self.catalog(openai: [Self.openai(extra: ["longContext": 10])])) != nil)
        #expect(Self.refused(try Self.catalog(openai: [Self.openai(extra: ["longContext": 272_000.5])])) != nil)
        let tiered = try PricingCatalog.parse(try Self.catalog(openai: [Self.openai(extra: ["longContext": 272_000])]))
        #expect(tiered.openai.first?.rates.longContextThreshold == 272_000)
    }

    /// One bad row among good ones refuses the file: nothing of it is applied.
    @Test func oneBadRowRefusesTheWholeCatalog() throws {
        let mixed = try Self.catalog(anthropic: [Self.anthropic(), Self.anthropic("claude-nimbus-2", input: 0)])
        #expect(Self.refused(mixed) == .entry("anthropic[1] claude-nimbus-2: input must be above 0 and at most 1000 dollars per million tokens"))
        let before = ModelPricing.fingerprint
        defer { PricingCatalog.apply(nil) }
        if let document = try? PricingCatalog.parse(mixed) { PricingCatalog.apply(document) }
        #expect(ModelPricing.fingerprint == before)
        #expect(ModelPricing.rates(for: "claude-nimbus-1") == nil)
    }

    @Test func theDigestIsStableAndOrderFree() {
        #expect(PricingCatalog.digest([]) == "")
        #expect(PricingCatalog.digest(["b", "a"]) == PricingCatalog.digest(["a", "b"]))
        #expect(PricingCatalog.digest(["a"]) != PricingCatalog.digest(["b"]))
    }
}

/// Where a rate comes from: the user's file, Claude Code's table, the catalog, the build, the family guess, in that
/// order, and the catalog only from an entry's effective day.
@Suite struct PricingCatalogPrecedence {
    let sept1 = DateParsing.iso8601("2026-09-01T12:00:00Z")!
    let sept20 = DateParsing.iso8601("2026-09-20T12:00:00Z")!
    let oct5 = DateParsing.iso8601("2026-10-05T12:00:00Z")!

    func apply(anthropic: [[String: Any]] = [], openai: [[String: Any]] = []) throws -> Bool {
        PricingCatalog.apply(try PricingCatalog.parse(try PricingCatalogValidation.catalog(anthropic: anthropic, openai: openai)))
    }

    @Test func aModelTheBuildLacksIsPricedFromItsEffectiveDay() throws {
        defer { PricingCatalog.apply(nil) }
        let before = ModelPricing.fingerprint
        #expect(ModelPricing.rates(for: "claude-nimbus-1-20260901") == nil)
        #expect(try apply(anthropic: [PricingCatalogValidation.anthropic("claude-nimbus-1", effective: "2026-09-10", input: 3, output: 12)]))
        #expect(ModelPricing.fingerprint != before)
        #expect(ModelPricing.fingerprint.contains("catalog="))
        // Before its day the model is what it was without the catalog: unpriced.
        #expect(ModelPricing.resolve("claude-nimbus-1-20260901", at: sept1) == nil)
        let priced = try #require(ModelPricing.resolve("claude-nimbus-1-20260901", at: sept20))
        #expect(priced.rates == ModelRates(input: 3, output: 12))
        #expect(priced.source == .catalog("2026-09-10"))
        #expect(ModelPricing.cost(of: TokenBreakdown(input: 1_000_000), model: "claude-nimbus-1", at: sept20) == 3)
        // Taking the catalog out restores the build alone.
        PricingCatalog.apply(nil)
        #expect(ModelPricing.fingerprint == before)
        #expect(ModelPricing.rates(for: "claude-nimbus-1") == nil)
    }

    @Test func anUpdateToABuildRowDatesFromItsDayAndEarlierLinesKeepTheBuildsRate() throws {
        defer { PricingCatalog.apply(nil) }
        #expect(try apply(anthropic: [PricingCatalogValidation.anthropic("claude-sonnet-5", effective: "2026-09-15", input: 3, output: 12)]))
        let early = try #require(ModelPricing.resolve("claude-sonnet-5", at: sept1))
        #expect(early.rates == ModelPricing.sonnet5)
        #expect(early.source == .builtIn(ModelPricing.snapshotDate))
        let late = try #require(ModelPricing.resolve("claude-sonnet-5-20260901", at: sept20))
        #expect(late.rates == ModelRates(input: 3, output: 12))
        #expect(late.source == .catalog("2026-09-15"))
        // The longest-prefix rule still holds across the merged table: the new row does not shadow a longer one.
        #expect(ModelPricing.resolve("claude-sonnet-4-6", at: sept20)?.rates == ModelPricing.sonnetLegacy)
        // Every source that priced the model over a span that straddles the day, and one that does not.
        #expect(ModelPricing.sources(for: "claude-sonnet-5", from: sept1, to: sept20) == [.builtIn(ModelPricing.snapshotDate), .catalog("2026-09-15")])
        #expect(ModelPricing.sources(for: "claude-sonnet-5", from: sept20, to: oct5) == [.catalog("2026-09-15")])
        #expect(ModelPricing.sources(for: "claude-opus-4-6", from: sept1, to: oct5) == [.builtIn(ModelPricing.snapshotDate)])
    }

    /// The golden Sonnet 5 line of CostGoldenTests, dated 2026-09-01, prices the same with an update dated later
    /// in force; a line after the update's day takes the new rate.
    @Test func theGoldenLineIsUntouchedByALaterUpdate() throws {
        defer { PricingCatalog.apply(nil) }
        #expect(try apply(anthropic: [PricingCatalogValidation.anthropic("claude-sonnet-5", effective: "2026-09-15", input: 3, output: 12)]))
        func line(_ stamp: String) -> UsageEntry {
            let json = """
            {"type":"assistant","timestamp":"\(stamp)","requestId":"req_b","message":{"id":"msg_b","model":"claude-sonnet-5","usage":{"input_tokens":1000,"output_tokens":200,"cache_read_input_tokens":40000,"cache_creation":{"ephemeral_5m_input_tokens":3000,"ephemeral_1h_input_tokens":2000},"inference_geo":"global"}}}
            """
            return ClaudeCostScanner.parseLine(Data(json.utf8))!
        }
        var unpriced: Set<String> = []
        #expect(abs(ClaudeCostScanner.price(line("2026-09-01T13:30:00.000Z"), unpriced: &unpriced) - 0.0275) < 1e-9)
        // 1000 × $3 + 200 × $12 + 3000 × $3.75 + 2000 × $6 + 40000 × $0.30, per million = $0.04065.
        #expect(abs(ClaudeCostScanner.price(line("2026-09-20T13:30:00.000Z"), unpriced: &unpriced) - 0.04065) < 1e-9)
        #expect(unpriced.isEmpty)
    }

    @Test func anEntryThatRepeatsTheBuildChangesNothingAndIsLabelledAsTheBuilds() throws {
        defer { PricingCatalog.apply(nil) }
        let before = ModelPricing.fingerprint
        #expect(try apply(anthropic: [PricingCatalogValidation.anthropic("claude-sonnet-5", effective: "2026-09-15", input: 2, output: 10),
                                     PricingCatalogValidation.anthropic("claude-opus-5", effective: "2026-09-15", input: 5, output: 25,
                                                                        extra: ["fastInput": 10, "fastOutput": 50])]) == false)
        #expect(ModelPricing.fingerprint == before)
        #expect(ModelPricing.book.isBuiltIn)
        #expect(ModelPricing.resolve("claude-sonnet-5", at: sept20)?.source == .builtIn(ModelPricing.snapshotDate))
        #expect(ModelPricing.resolve("claude-opus-5", speed: "fast", at: sept20)?.source == .builtIn(ModelPricing.snapshotDate))
        #expect(ModelPricing.resolve("claude-opus-5", speed: "fast", at: sept20)?.rates == ModelPricing.opusFast)
    }

    /// After an update, an entry that returns a row to the build's rate ends the update, so it counts even
    /// though it repeats the build.
    @Test func aReturnToTheBuildsRateEndsAnUpdate() throws {
        defer { PricingCatalog.apply(nil) }
        #expect(try apply(anthropic: [PricingCatalogValidation.anthropic("claude-sonnet-5", effective: "2026-09-15", input: 3, output: 12),
                                     PricingCatalogValidation.anthropic("claude-sonnet-5", effective: "2026-10-01", input: 2, output: 10)]))
        #expect(ModelPricing.resolve("claude-sonnet-5", at: sept20)?.source == .catalog("2026-09-15"))
        let after = try #require(ModelPricing.resolve("claude-sonnet-5", at: oct5))
        #expect(after.rates == ModelPricing.sonnet5)
        #expect(after.source == .builtIn(ModelPricing.snapshotDate))
        let withoutReturn = try apply(anthropic: [PricingCatalogValidation.anthropic("claude-sonnet-5", effective: "2026-09-15", input: 3, output: 12)])
        #expect(withoutReturn)
        #expect(ModelPricing.resolve("claude-sonnet-5", at: oct5)?.source == .catalog("2026-09-15"))
    }

    @Test func fastModeTakesTheEntrysFastRowOrTheBuildsWhenTheEntryHasNone() throws {
        defer { PricingCatalog.apply(nil) }
        #expect(try apply(anthropic: [PricingCatalogValidation.anthropic("claude-opus-5", effective: "2026-09-15", input: 4, output: 20)]))
        // The standard rate is the catalog's; fast lines keep the build's own fast row, and say so.
        #expect(ModelPricing.resolve("claude-opus-5", at: sept20)?.source == .catalog("2026-09-15"))
        let fast = try #require(ModelPricing.resolve("claude-opus-5", speed: "fast", at: sept20))
        #expect(fast.rates == ModelPricing.opusFast)
        #expect(fast.source == .builtIn(ModelPricing.snapshotDate))
        #expect(try apply(anthropic: [PricingCatalogValidation.anthropic("claude-opus-5", effective: "2026-09-15", input: 4, output: 20,
                                                                        extra: ["fastInput": 8, "fastOutput": 40])]))
        let updatedFast = try #require(ModelPricing.resolve("claude-opus-5", speed: "fast", at: sept20))
        #expect(updatedFast.rates == ModelRates(input: 8, output: 40))
        #expect(updatedFast.source == .catalog("2026-09-15"))
        // A row the build has no fast rate for ignores the marker, catalog or not.
        #expect(try apply(anthropic: [PricingCatalogValidation.anthropic("claude-opus-4-6", effective: "2026-09-15", input: 4, output: 20)]))
        #expect(ModelPricing.resolve("claude-opus-4-6", speed: "fast", at: sept20)?.rates == ModelRates(input: 4, output: 20))
    }

    @Test func overridesOutrankTheCatalogAndNameWhoseTheyAre() throws {
        defer { PricingCatalog.apply(nil); ModelPricing.overrides = [:] }
        #expect(try apply(anthropic: [PricingCatalogValidation.anthropic("claude-sonnet-5", effective: "2026-09-01", input: 3, output: 12)]))
        ModelPricing.overrides = ModelPricing.parseOverrides(["claude-sonnet-5": ["input": 1, "output": 5]])
        let own = try #require(ModelPricing.resolve("claude-sonnet-5", at: oct5))
        #expect(own.rates.input == 1)
        #expect(own.source == .overrides)
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("notchmeter-catalog-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let claude = dir.appendingPathComponent("settings.json")
        try Data(#"{"modelPricing":{"claude-sonnet-5":{"inputTokens":1.5,"outputTokens":7},"claude-haiku-4-5":{"input":0.5,"output":2}}}"#.utf8).write(to: claude)
        let mine = dir.appendingPathComponent("pricing-overrides.json")
        try Data(#"{"claude-haiku-4-5":{"input":0.75,"output":3}}"#.utf8).write(to: mine)
        ModelPricing.loadOverrides(claudeSettings: claude, own: mine)
        #expect(ModelPricing.resolve("claude-sonnet-5", at: oct5)?.source == .claudeCode)
        #expect(ModelPricing.resolve("claude-sonnet-5", at: oct5)?.rates.input == 1.5)
        #expect(ModelPricing.resolve("claude-haiku-4-5", at: oct5)?.source == .overrides)
        #expect(ModelPricing.resolve("claude-haiku-4-5", at: oct5)?.rates.input == 0.75)
        #expect(ModelPricing.resolve("claude-opus-4-6", at: oct5)?.source == .builtIn(ModelPricing.snapshotDate))
        #expect(ModelPricing.resolve("claude-opus-9", at: oct5)?.source == .family)
    }

    @Test func openAIEntriesAddExactIdsAndDateUpdatesTheSameWay() throws {
        defer { PricingCatalog.apply(nil) }
        let before = OpenAIPricing.fingerprint
        #expect(OpenAIPricing.rates(for: "gpt-6") == nil)
        #expect(try apply(openai: [PricingCatalogValidation.openai("gpt-6", effective: "2026-09-10", input: 3, output: 12, extra: ["cachedInput": 0.3]),
                                  PricingCatalogValidation.openai("gpt-5.5", effective: "2026-09-15", input: 4, output: 24, extra: ["cachedInput": 0.4, "longContext": 272_000])]))
        #expect(OpenAIPricing.fingerprint != before)
        #expect(OpenAIPricing.resolve("gpt-6", at: sept1) == nil)
        let added = try #require(OpenAIPricing.resolve("gpt-6-2026-10-01", at: sept20))
        #expect(added.rates == OpenAIRates(input: 3, cachedInput: 0.3, output: 12))
        #expect(added.source == .catalog("2026-09-10"))
        // An exact match still: a longer id the catalog does not name stays unpriced rather than collapsing onto gpt-6.
        #expect(OpenAIPricing.resolve("gpt-6-mini", at: sept20) == nil)
        #expect(OpenAIPricing.resolve("gpt-5.5", at: sept1)?.source == .builtIn(OpenAIPricing.snapshotDate))
        let updated = try #require(OpenAIPricing.resolve("gpt-5.5", at: sept20))
        #expect(updated.rates.output == 24)
        #expect(updated.source == .catalog("2026-09-15"))
        #expect(OpenAIPricing.sources(for: "gpt-5.5", from: sept1, to: sept20) == [.builtIn(OpenAIPricing.snapshotDate), .catalog("2026-09-15")])
        #expect(OpenAIPricing.cost(of: TokenBreakdown(input: 1_000_000), model: "openai/GPT-6", at: sept20) == 3)
        // Repeating the build's row is the build's number, and from the build's tables alone it changes nothing.
        PricingCatalog.apply(nil)
        #expect(try apply(openai: [PricingCatalogValidation.openai("gpt-5", effective: "2026-09-15", input: 1.25, output: 10, extra: ["cachedInput": 0.125])]) == false)
        #expect(OpenAIPricing.fingerprint == before)
        #expect(OpenAIPricing.resolve("gpt-5", at: sept20)?.source == .builtIn(OpenAIPricing.snapshotDate))
    }

    @Test func theCardsPriceLineNamesEverySourceInPrecedenceOrder() {
        #expect(PriceSource.line([]) == nil)
        let line = PriceSource.line([.builtIn("2026-09-24"), .catalog("2026-10-01"), .overrides, .family])
        #expect(line == "Prices: your pricing-overrides.json, Notchmeter's catalog of Oct 1, 2026, this build's table of Sep 24, 2026, a family guess")
        #expect(PriceSource.catalog("2026-10-01").key == "catalog:2026-10-01")
        #expect(PriceSource.builtIn("2026-09-24").key == "builtIn:2026-09-24")
        #expect(PriceSource.dayText("not a day") == "not a day")
    }
}

/// The cache on disk, the refresh cadence and the fetcher's handling of each outcome, with the network stubbed.
@Suite struct PricingCatalogCaching {
    static func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notchmeter-catalog-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func body(anthropic: [[String: Any]] = [PricingCatalogValidation.anthropic("claude-nimbus-1", effective: "2026-09-10", input: 3, output: 12)],
                     published: String = "2026-09-24") throws -> Data {
        try PricingCatalogValidation.catalog(anthropic: anthropic, published: published)
    }

    @Test func theCacheRoundTripsAndDropsAFileThatNoLongerPasses() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("catalog.json")
        let fetchedAt = DateParsing.iso8601("2026-09-24T08:00:00Z")!
        let cache = PricingCatalog.Cache(body: try Self.body(), fetchedAt: fetchedAt, etag: "\"abc\"", lastModified: "Thu, 24 Sep 2026 07:00:00 GMT")
        try cache.save(to: file)
        let (loaded, document) = try #require(PricingCatalog.Cache.load(from: file))
        #expect(loaded.fetchedAt == fetchedAt)
        #expect(loaded.etag == "\"abc\"")
        #expect(loaded.lastModified == "Thu, 24 Sep 2026 07:00:00 GMT")
        #expect(document.anthropic.first?.prefix == "claude-nimbus-1")
        #expect(try PricingCatalog.parse(loaded.body) == document)
        #expect(PricingCatalog.Cache.load(from: dir.appendingPathComponent("missing.json")) == nil)
        // A body written by a build with another schema, or damaged, reads as nothing.
        let stale = PricingCatalog.Cache(body: try PricingCatalogValidation.catalog(schema: 2), fetchedAt: fetchedAt, etag: nil, lastModified: nil)
        try stale.save(to: file)
        #expect(PricingCatalog.Cache.load(from: file) == nil)
        try Data("{not json".utf8).write(to: file)
        #expect(PricingCatalog.Cache.load(from: file) == nil)
    }

    @Test func applyingTheCacheFollowsTheSwitch() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir); PricingCatalog.apply(nil) }
        let file = dir.appendingPathComponent("catalog.json")
        try PricingCatalog.Cache(body: try Self.body(), fetchedAt: Date(), etag: nil, lastModified: nil).save(to: file)
        #expect(PricingCatalog.applyCached(enabled: false, from: file) == nil)
        #expect(ModelPricing.rates(for: "claude-nimbus-1") == nil)
        #expect(PricingCatalog.applyCached(enabled: true, from: file)?.published == "2026-09-24")
        #expect(ModelPricing.rates(for: "claude-nimbus-1")?.input == 3)
        #expect(PricingCatalog.applied)
        #expect(PricingCatalog.applyCached(enabled: true, from: dir.appendingPathComponent("none.json")) == nil)
        #expect(ModelPricing.rates(for: "claude-nimbus-1") == nil)
        #expect(!PricingCatalog.applied)
    }

    @Test func aRequestIsDueOnceADayAndSoonerAfterAFailure() {
        let now = DateParsing.iso8601("2026-09-24T12:00:00Z")!
        typealias Refresh = PricingCatalog.Refresh
        #expect(Refresh.wait(after: 0) == 24 * 3600)
        #expect(Refresh.wait(after: 1) == 3600)
        #expect(Refresh.wait(after: 2) == 2 * 3600)
        #expect(Refresh.wait(after: 5) == 16 * 3600)
        #expect(Refresh.wait(after: 6) == 24 * 3600)
        #expect(Refresh.wait(after: 40) == 24 * 3600)
        #expect(!Refresh.isDue(enabled: false, confirmedAt: nil, attemptedAt: nil, failures: 0, now: now))
        #expect(Refresh.isDue(enabled: true, confirmedAt: nil, attemptedAt: nil, failures: 0, now: now))
        #expect(!Refresh.isDue(enabled: true, confirmedAt: now.addingTimeInterval(-3600), attemptedAt: nil, failures: 0, now: now))
        #expect(Refresh.isDue(enabled: true, confirmedAt: now.addingTimeInterval(-25 * 3600), attemptedAt: nil, failures: 0, now: now))
        // A failed attempt half an hour ago holds the next one off until the hour is up; two failures, two hours.
        #expect(!Refresh.isDue(enabled: true, confirmedAt: nil, attemptedAt: now.addingTimeInterval(-1800), failures: 1, now: now))
        #expect(Refresh.isDue(enabled: true, confirmedAt: nil, attemptedAt: now.addingTimeInterval(-3601), failures: 1, now: now))
        #expect(!Refresh.isDue(enabled: true, confirmedAt: nil, attemptedAt: now.addingTimeInterval(-3601), failures: 2, now: now))
        // A confirmation dated after now (the clock went back) is not waited out.
        #expect(Refresh.isDue(enabled: true, confirmedAt: now.addingTimeInterval(3600), attemptedAt: nil, failures: 0, now: now))
    }
}

@MainActor
@Suite struct PricingCatalogFetching {
    static let suite = "NotchmeterTests.PricingCatalog"

    static func prefs() -> Preferences {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        return Preferences(defaults: UserDefaults(suiteName: suite) ?? .standard)
    }

    static func cleanUp(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
        UserDefaults.standard.removePersistentDomain(forName: suite)
        PricingCatalog.apply(nil)
    }

    @Test func aFetchedCatalogIsAppliedWrittenAndRescanned() async throws {
        let dir = try PricingCatalogCaching.directory()
        defer { Self.cleanUp(dir) }
        let file = dir.appendingPathComponent("catalog.json")
        let prefs = Self.prefs()
        #expect(prefs.pricingCatalog)
        var rescans = 0
        var requests: [PricingCatalog.Cache?] = []
        let body = try PricingCatalogCaching.body()
        let fetcher = PricingCatalogFetcher(prefs: prefs, cacheFile: file, rescan: { rescans += 1 }, load: { held in
            requests.append(held)
            let document = try! PricingCatalog.parse(body)
            return .updated(PricingCatalog.Cache(body: body, fetchedAt: Date(), etag: "\"v1\"", lastModified: nil), document)
        })
        let now = Date()
        #expect(await fetcher.refreshIfDue(now: now))
        #expect(requests == [nil])
        #expect(fetcher.status.published == "2026-09-24")
        #expect(fetcher.status.entries == 1)
        #expect(fetcher.status.lastOutcome == .applied)
        #expect(ModelPricing.rates(for: "claude-nimbus-1")?.input == 3)
        #expect(rescans == 1)
        #expect(PricingCatalog.Cache.load(from: file)?.cache.etag == "\"v1\"")
        // Confirmed just now: not asked again within the day, and the request that would be made carries the held one.
        #expect(await fetcher.refreshIfDue(now: now.addingTimeInterval(3600)) == false)
        #expect(await fetcher.refreshIfDue(now: now.addingTimeInterval(25 * 3600)))
        #expect(requests.count == 2)
        #expect(requests[1]?.etag == "\"v1\"")
        // The same body again changes no rate, so nothing is rescanned for it.
        #expect(rescans == 1)
    }

    @Test func aFailureOrARefusalLeavesTheBuildsTablesAndWritesNothing() async throws {
        let dir = try PricingCatalogCaching.directory()
        defer { Self.cleanUp(dir) }
        let file = dir.appendingPathComponent("catalog.json")
        let prefs = Self.prefs()
        var answer: PricingCatalog.Fetched = .failed("no answer")
        var rescans = 0
        let fetcher = PricingCatalogFetcher(prefs: prefs, cacheFile: file, rescan: { rescans += 1 }, load: { _ in answer })
        let before = ModelPricing.fingerprint
        let now = Date()
        #expect(await fetcher.refreshIfDue(now: now))
        #expect(fetcher.status.lastOutcome == .failed)
        #expect(fetcher.status.published == nil)
        #expect(ModelPricing.fingerprint == before)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(rescans == 0)
        // An hour's backoff after the failure, then the retry; a refused body is treated the same way.
        #expect(await fetcher.refreshIfDue(now: now.addingTimeInterval(1800)) == false)
        answer = .refused("schema 2")
        #expect(await fetcher.refreshIfDue(now: now.addingTimeInterval(3601)))
        #expect(fetcher.status.lastOutcome == .refused)
        #expect(ModelPricing.fingerprint == before)
        #expect(fetcher.status.settingsLine(enabled: true) == "The catalog could not be used; this build's prices (\(PriceSource.dayText(ModelPricing.snapshotDate))) stand until it can be.")
    }

    @Test func aHeldCatalogIsAppliedAtStartAndConfirmedByA304() async throws {
        let dir = try PricingCatalogCaching.directory()
        defer { Self.cleanUp(dir) }
        let file = dir.appendingPathComponent("catalog.json")
        let prefs = Self.prefs()
        // Whole seconds: the cache file writes the moment to the millisecond, and the test reads it back equal.
        let twoDaysAgo = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 48 * 3600)
        try PricingCatalog.Cache(body: try PricingCatalogCaching.body(), fetchedAt: twoDaysAgo, etag: "\"held\"", lastModified: "then").save(to: file)
        var rescans = 0
        var requests: [PricingCatalog.Cache?] = []
        let fetcher = PricingCatalogFetcher(prefs: prefs, cacheFile: file, rescan: { rescans += 1 }, load: { held in
            requests.append(held)
            return .unchanged
        })
        fetcher.start()
        defer { fetcher.stop() }
        #expect(fetcher.status.published == "2026-09-24")
        #expect(fetcher.status.confirmedAt == twoDaysAgo)
        #expect(ModelPricing.rates(for: "claude-nimbus-1")?.input == 3)
        #expect(rescans == 1)
        let now = Date()
        // start() looks at once; that request, or this one, carries the held validators and is answered 304.
        _ = await fetcher.refreshIfDue(now: now)
        #expect(requests.count >= 1)
        #expect(requests.last??.etag == "\"held\"")
        #expect(fetcher.status.lastOutcome == .unchanged)
        let confirmed = try #require(fetcher.status.confirmedAt)
        #expect(confirmed > twoDaysAgo)
        #expect(try #require(PricingCatalog.Cache.load(from: file)).cache.fetchedAt > twoDaysAgo)
        #expect(rescans == 1)
        #expect(fetcher.status.settingsLine(enabled: true, now: now).hasPrefix("Catalog of Sep 24, 2026 in use, last confirmed"))
    }

    @Test func theSwitchTakesTheCatalogOutAndStopsTheRequests() async throws {
        let dir = try PricingCatalogCaching.directory()
        defer { Self.cleanUp(dir) }
        let file = dir.appendingPathComponent("catalog.json")
        let prefs = Self.prefs()
        try PricingCatalog.Cache(body: try PricingCatalogCaching.body(), fetchedAt: Date(), etag: nil, lastModified: nil).save(to: file)
        var requests = 0
        var rescans = 0
        let fetcher = PricingCatalogFetcher(prefs: prefs, cacheFile: file, rescan: { rescans += 1 }, load: { _ in requests += 1; return .unchanged })
        fetcher.start()
        defer { fetcher.stop() }
        #expect(ModelPricing.rates(for: "claude-nimbus-1")?.input == 3)
        #expect(rescans == 1)
        prefs.pricingCatalog = false
        // The observation lands on the main actor after this turn; yield to it.
        for _ in 0..<20 where ModelPricing.rates(for: "claude-nimbus-1") != nil { await Task.yield() }
        #expect(ModelPricing.rates(for: "claude-nimbus-1") == nil)
        #expect(fetcher.status.published == nil)
        #expect(rescans == 2)
        #expect(await fetcher.refreshIfDue(now: Date().addingTimeInterval(48 * 3600)) == false)
        #expect(requests == 0)
        #expect(fetcher.status.settingsLine(enabled: false) == "Off. Prices come from this build (\(PriceSource.dayText(ModelPricing.snapshotDate))) and your own overrides.")
        // The file is still there: switching back on applies it without a request.
        prefs.pricingCatalog = true
        for _ in 0..<20 where ModelPricing.rates(for: "claude-nimbus-1") == nil { await Task.yield() }
        #expect(ModelPricing.rates(for: "claude-nimbus-1")?.input == 3)
        #expect(fetcher.status.published == "2026-09-24")
    }
}

/// The request itself, against a stubbed transport: a plain conditional GET with the app's own headers and
/// nothing about the user, and each answer's outcome.
@Suite struct PricingCatalogNetwork {
    final class Exchange: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [URLRequest] = []
        var status = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body = Data()

        var requests: [URLRequest] { lock.withLock { _requests } }
        func record(_ request: URLRequest) { lock.withLock { _requests.append(request) } }
    }

    final class StubProtocol: URLProtocol {
        nonisolated(unsafe) static var exchange = Exchange()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            Self.exchange.record(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: Self.exchange.status, httpVersion: nil, headerFields: Self.exchange.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.exchange.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    static let held = PricingCatalog.Cache(body: Data(), fetchedAt: Date(), etag: "\"v1\"", lastModified: "Thu, 24 Sep 2026 07:00:00 GMT")

    @Test func theRequestIsAPlainConditionalGETWithNothingAboutTheUser() async throws {
        let exchange = Exchange()
        exchange.status = 304
        StubProtocol.exchange = exchange
        let answer = await PricingCatalog.fetch(cache: Self.held, session: Self.session())
        #expect(answer == .unchanged)
        let request = try #require(exchange.requests.first)
        #expect(request.url == PricingCatalog.url)
        #expect(request.url?.host == "raw.githubusercontent.com")
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
        #expect(request.value(forHTTPHeaderField: "If-Modified-Since") == "Thu, 24 Sep 2026 07:00:00 GMT")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == AppInfo.userAgent)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        // With nothing held there is nothing to make the request conditional on, and a 304 is then a failure.
        let bare = Exchange()
        bare.status = 304
        StubProtocol.exchange = bare
        #expect(await PricingCatalog.fetch(cache: nil, session: Self.session()) == .failed("304 with nothing held"))
        let request2 = try #require(bare.requests.first)
        #expect(request2.value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(request2.value(forHTTPHeaderField: "If-Modified-Since") == nil)
    }

    @Test func aBodyIsParsedAndItsValidatorsKeptAndABadOneRefused() async throws {
        let exchange = Exchange()
        exchange.headers = ["Content-Type": "application/json", "ETag": "\"v2\"", "Last-Modified": "Fri, 25 Sep 2026 07:00:00 GMT"]
        exchange.body = try PricingCatalogCaching.body(published: "2026-09-25")
        StubProtocol.exchange = exchange
        let now = DateParsing.iso8601("2026-09-25T09:00:00Z")!
        guard case .updated(let cache, let document) = await PricingCatalog.fetch(cache: Self.held, session: Self.session(), now: now) else {
            Issue.record("a fresh body was not applied")
            return
        }
        #expect(document.published == "2026-09-25")
        #expect(cache.etag == "\"v2\"")
        #expect(cache.lastModified == "Fri, 25 Sep 2026 07:00:00 GMT")
        #expect(cache.fetchedAt == now)
        #expect(cache.body == exchange.body)
        let refused = Exchange()
        refused.body = try PricingCatalogValidation.catalog(schema: 2)
        StubProtocol.exchange = refused
        #expect(await PricingCatalog.fetch(cache: Self.held, session: Self.session()) == .refused("schema 2: this build reads schema 1"))
        let down = Exchange()
        down.status = 503
        StubProtocol.exchange = down
        #expect(await PricingCatalog.fetch(cache: Self.held, session: Self.session()) == .failed("HTTP 503"))
    }
}
