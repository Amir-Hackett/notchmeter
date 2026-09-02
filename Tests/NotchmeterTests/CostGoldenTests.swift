import Foundation
import Testing
@testable import Notchmeter

/// Golden transcripts: each fixture is a Claude Code JSONL excerpt and the dollar total it must price to.
/// Timestamps sit an hour or two before `now` so the local day boundary never moves a line between days.
@Suite struct GoldenTranscripts {
    let now = DateParsing.iso8601("2026-09-01T15:00:00Z")!

    func total(_ jsonl: String) -> CostSummary {
        ClaudeCostScanner.summarize(ClaudeCostScanner.dedupe(ClaudeCostScanner.parseFile(Data(jsonl.utf8))), now: now, daysBack: 30)
    }

    @Test func lineWithItsOwnCostIsTakenAsIs() {
        let jsonl = """
        {"type":"assistant","timestamp":"2026-09-01T14:40:00.000Z","requestId":"req_a","costUSD":0.42,"message":{"id":"msg_a","model":"claude-opus-4-6","usage":{"input_tokens":1000,"output_tokens":100,"inference_geo":"us"}}}
        """
        #expect(abs(total(jsonl).last30Days - 0.42) < 1e-9)
    }

    @Test func tokensOnlyLineWithBothCacheTiers() {
        // Sonnet 5: 1000 × $2 + 200 × $10 + 3000 × $2.50 + 2000 × $4 + 40000 × $0.20, per million = $0.0275.
        let jsonl = """
        {"type":"assistant","timestamp":"2026-09-01T13:30:00.000Z","requestId":"req_b","message":{"id":"msg_b","model":"claude-sonnet-5","usage":{"input_tokens":1000,"output_tokens":200,"cache_read_input_tokens":40000,"cache_creation":{"ephemeral_5m_input_tokens":3000,"ephemeral_1h_input_tokens":2000},"inference_geo":"global"}}}
        """
        #expect(abs(total(jsonl).last30Days - 0.0275) < 1e-9)
    }

    @Test func usResidencyLineIsMultipliedByOnePointOne() {
        // Opus 4.6: 2000 × $5 + 400 × $25 + 10000 × $6.25 + 100000 × $0.50 = $0.1325, × 1.1 = $0.14575.
        let jsonl = """
        {"type":"assistant","timestamp":"2026-09-01T14:20:00.000Z","requestId":"req_c","message":{"id":"msg_c","model":"claude-opus-4-6-20260215","usage":{"input_tokens":2000,"output_tokens":400,"cache_creation_input_tokens":10000,"cache_read_input_tokens":100000,"inference_geo":"us"}}}
        """
        #expect(abs(total(jsonl).last30Days - 0.14575) < 1e-9)
    }

    @Test func streamedDuplicatesCollapseToTheLineWithTheRealOutputCount() {
        // Fable 5.1: 500 × $10 + 1090 × $50 + 200000 × $0.25 = $0.1095; keeping the first line would give $0.05515.
        let jsonl = """
        {"type":"assistant","timestamp":"2026-09-01T14:55:00.000Z","requestId":"req_d","message":{"id":"msg_d","model":"claude-fable-5-1","usage":{"input_tokens":500,"output_tokens":3,"cache_read_input_tokens":200000,"cache_creation_input_tokens":0,"inference_geo":"not_available"}}}
        {"type":"assistant","timestamp":"2026-09-01T14:55:01.000Z","requestId":"req_d","message":{"id":"msg_d","model":"claude-fable-5-1","usage":{"input_tokens":500,"output_tokens":3,"cache_read_input_tokens":200000,"cache_creation_input_tokens":0,"inference_geo":"not_available"}}}
        {"type":"assistant","timestamp":"2026-09-01T14:55:09.000Z","requestId":"req_d","message":{"id":"msg_d","model":"claude-fable-5-1","usage":{"input_tokens":500,"output_tokens":1090,"cache_read_input_tokens":200000,"cache_creation_input_tokens":0,"inference_geo":"not_available"}}}
        """
        #expect(abs(total(jsonl).last30Days - 0.1095) < 1e-9)
    }

    @Test func syntheticModelLineCostsNothingAndIsNotReportedAsUnpriced() {
        let jsonl = """
        {"type":"assistant","timestamp":"2026-09-01T14:30:00.000Z","message":{"id":"msg_e","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}
        """
        let summary = total(jsonl)
        #expect(summary.last30Days == 0)
        #expect(summary.unpricedModels.isEmpty)
    }

    @Test func unknownModelLineCostsNothingAndIsListed() {
        let jsonl = """
        {"type":"assistant","timestamp":"2026-09-01T14:45:00.000Z","requestId":"req_f","message":{"id":"msg_f","model":"claude-nimbus-1","usage":{"input_tokens":1000000,"output_tokens":1000}}}
        """
        let summary = total(jsonl)
        #expect(summary.last30Days == 0)
        #expect(summary.unpricedModels == ["claude-nimbus-1"])
    }

    @Test func lineOutsideTheWindowIsIgnored() {
        let jsonl = """
        {"type":"assistant","timestamp":"2026-07-10T15:00:00.000Z","requestId":"req_g","message":{"id":"msg_g","model":"claude-sonnet-5","usage":{"input_tokens":1000000,"output_tokens":0}}}
        """
        #expect(total(jsonl).last30Days == 0)
    }

    @Test func wholeTranscriptPinsToTheSumOfItsLines() {
        let jsonl = """
        {"type":"user","timestamp":"2026-09-01T13:29:00.000Z","message":{"role":"user","content":"price this"}}
        {"type":"assistant","timestamp":"2026-09-01T14:40:00.000Z","requestId":"req_a","costUSD":0.42,"message":{"id":"msg_a","model":"claude-opus-4-6","usage":{"input_tokens":1000,"output_tokens":100,"inference_geo":"us"}}}
        {"type":"assistant","timestamp":"2026-09-01T13:30:00.000Z","requestId":"req_b","message":{"id":"msg_b","model":"claude-sonnet-5","usage":{"input_tokens":1000,"output_tokens":200,"cache_read_input_tokens":40000,"cache_creation":{"ephemeral_5m_input_tokens":3000,"ephemeral_1h_input_tokens":2000},"inference_geo":"global"}}}
        {"type":"assistant","timestamp":"2026-09-01T14:20:00.000Z","requestId":"req_c","message":{"id":"msg_c","model":"claude-opus-4-6-20260215","usage":{"input_tokens":2000,"output_tokens":400,"cache_creation_input_tokens":10000,"cache_read_input_tokens":100000,"inference_geo":"us"}}}
        {"type":"assistant","timestamp":"2026-09-01T14:55:00.000Z","requestId":"req_d","message":{"id":"msg_d","model":"claude-fable-5-1","usage":{"input_tokens":500,"output_tokens":3,"cache_read_input_tokens":200000,"cache_creation_input_tokens":0,"inference_geo":"not_available"}}}
        {"type":"assistant","timestamp":"2026-09-01T14:55:01.000Z","requestId":"req_d","message":{"id":"msg_d","model":"claude-fable-5-1","usage":{"input_tokens":500,"output_tokens":3,"cache_read_input_tokens":200000,"cache_creation_input_tokens":0,"inference_geo":"not_available"}}}
        {"type":"assistant","timestamp":"2026-09-01T14:55:09.000Z","requestId":"req_d","message":{"id":"msg_d","model":"claude-fable-5-1","usage":{"input_tokens":500,"output_tokens":1090,"cache_read_input_tokens":200000,"cache_creation_input_tokens":0,"inference_geo":"not_available"}}}
        {"type":"assistant","timestamp":"2026-09-01T14:30:00.000Z","message":{"id":"msg_e","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}
        {"type":"assistant","timestamp":"2026-09-01T14:45:00.000Z","requestId":"req_f","message":{"id":"msg_f","model":"claude-nimbus-1","usage":{"input_tokens":1000000,"output_tokens":1000}}}
        {"type":"assistant","timestamp":"2026-07-10T15:00:00.000Z","requestId":"req_g","message":{"id":"msg_g","model":"claude-sonnet-5","usage":{"input_tokens":1000000,"output_tokens":0}}}
        """
        let summary = total(jsonl)
        #expect(abs(summary.last30Days - 0.70275) < 1e-9)
        #expect(abs(summary.daily.reduce(0) { $0 + $1.cost } - 0.70275) < 1e-9)
        // The Sonnet line at 13:30 is the only one older than an hour.
        #expect(abs(summary.lastHour - 0.67525) < 1e-9)
        #expect(summary.unpricedModels == ["claude-nimbus-1"])
        // Two active hours are not enough history for a burn multiple.
        #expect(summary.burnMultiple == nil)
    }
}

@Suite struct CostRules {
    @Test func readsInferenceGeography() throws {
        let us = #"{"timestamp":"2026-09-01T15:00:00Z","message":{"model":"claude-opus-4-6","usage":{"input_tokens":1,"output_tokens":1,"inference_geo":"us"}}}"#
        #expect(try #require(ClaudeCostScanner.parseLine(Data(us.utf8))).inferenceGeo == "us")
        let plain = #"{"timestamp":"2026-09-01T15:00:00Z","message":{"model":"claude-opus-4-6","usage":{"input_tokens":1,"output_tokens":1}}}"#
        #expect(try #require(ClaudeCostScanner.parseLine(Data(plain.utf8))).inferenceGeo == nil)
    }

    @Test func residencyMultiplierOnlyForUS() {
        #expect(ModelPricing.residencyMultiplier(inferenceGeo: "us") == 1.1)
        #expect(ModelPricing.residencyMultiplier(inferenceGeo: "global") == 1)
        #expect(ModelPricing.residencyMultiplier(inferenceGeo: "not_available") == 1)
        #expect(ModelPricing.residencyMultiplier(inferenceGeo: nil) == 1)
        let tokens = TokenBreakdown(input: 1_000_000)
        #expect(ModelPricing.cost(of: tokens, model: "claude-sonnet-5", inferenceGeo: "us") == 2.2)
        #expect(ModelPricing.cost(of: tokens, model: "claude-sonnet-5") == 2)
    }

    @Test func dedupeKeepsTheLineWithTheMostOutput() {
        func entry(_ key: String?, output: Int) -> UsageEntry {
            UsageEntry(timestamp: Date(timeIntervalSince1970: 0), model: "claude-sonnet-5", tokens: TokenBreakdown(output: output), costUSD: nil, dedupeKey: key)
        }
        let kept = ClaudeCostScanner.dedupe([entry("a", output: 3), entry("a", output: 3), entry("a", output: 1090), entry("b", output: 7), entry(nil, output: 1), entry(nil, output: 1)])
        #expect(kept.map(\.tokens.output) == [1090, 7, 1, 1])
    }
}

@Suite struct BurnRate {
    let now = DateParsing.iso8601("2026-09-01T15:30:00Z")!

    func entry(_ stamp: String, _ cost: Double) -> UsageEntry {
        UsageEntry(timestamp: DateParsing.iso8601(stamp)!, model: nil, tokens: TokenBreakdown(), costUSD: cost, dedupeKey: nil)
    }

    func summarize(_ entries: [UsageEntry]) -> CostSummary {
        ClaudeCostScanner.summarize(entries, now: now, daysBack: 30)
    }

    @Test func lastHourAgainstTheAverageActiveHour() throws {
        let entries = [
            entry("2026-09-01T10:15:00Z", 1), entry("2026-09-01T11:15:00Z", 2), entry("2026-09-01T12:15:00Z", 3),
            entry("2026-09-01T13:15:00Z", 4), entry("2026-09-01T14:45:00Z", 4), entry("2026-09-01T14:50:00Z", 6),
        ]
        let summary = summarize(entries)
        // Five active hours costing 1, 2, 3, 4 and 10: $20 over five hours; the last hour holds the 10.
        #expect(summary.lastHour == 10)
        #expect(summary.typicalHourly == 4)
        #expect(summary.burnMultiple == 2.5)

        // A sixth active hour at 15:10 costing 4: $24 over six hours, and the last hour now holds 14.
        let straddling = entries + [entry("2026-09-01T15:10:00Z", 4)]
        let more = summarize(straddling)
        #expect(more.lastHour == 14)
        #expect(more.typicalHourly == 4)
        #expect(abs(try #require(more.burnMultiple) - 3.5) < 1e-9)
    }

    /// The bursty case a median gets wrong: twenty cheap hours and one big one is an ordinary agent month, and
    /// the big hour is measured against the average of all of them, not against the cheap ones.
    @Test func aBurstIsMeasuredAgainstTheAverageNotTheMedian() throws {
        var entries = (0..<20).map { entry(String(format: "2026-08-%02dT10:15:00Z", 10 + $0), 0.5) }
        entries.append(entry("2026-09-01T14:50:00Z", 50.95))
        let summary = summarize(entries)
        let average = 60.95 / 21
        #expect(abs(summary.typicalHourly - average) < 1e-9)
        #expect(abs(try #require(summary.burnMultiple) - 50.95 / average) < 1e-9)
        #expect(Burn.multiple(try #require(summary.burnMultiple)) == "18x")
    }

    @Test func needsFiveActiveHoursAndANonZeroAverage() {
        let four = [
            entry("2026-09-01T11:15:00Z", 2), entry("2026-09-01T12:15:00Z", 3),
            entry("2026-09-01T13:15:00Z", 4), entry("2026-09-01T14:45:00Z", 12),
        ]
        let summary = summarize(four)
        #expect(summary.lastHour == 12)
        #expect(summary.typicalHourly == 5.25)
        #expect(summary.burnMultiple == nil)

        let free = (10...14).map { entry("2026-09-01T\($0):15:00Z", 0) }
        let zero = summarize(free)
        #expect(zero.typicalHourly == 0)
        #expect(zero.burnMultiple == nil)
        #expect(CostSummary.empty.burnMultiple == nil)
    }

    @Test func formatsMultiples() {
        #expect(Burn.multiple(6) == "6x")
        #expect(Burn.multiple(1.5) == "1.5x")
        #expect(Burn.multiple(2.34) == "2.3x")
        #expect(Burn.multiple(0.34) == "0.3x")
        #expect(Burn.multiple(12.4) == "12x")
        #expect(Burn.multiple(9.97) == "10x")
    }
}
