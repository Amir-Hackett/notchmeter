import Foundation

/// Prices what OpenCode has already recorded. OpenCode keeps every assistant message in its own database under
/// `~/.local/share/opencode` (OpenCodeStore), each with its model, its provider, its tokens and the cost OpenCode
/// put on it; OpenCodePricing says which of those figures a turn is worth and on what authority, and
/// docs/accuracy.md writes the rules out. With no OpenCode data on the Mac the scan answers nil: OpenCode shows no
/// cost at all rather than $0.
actor OpenCodeCostScanner {
    nonisolated let reader: OpenCodeUsageReader
    nonisolated let history: CostHistory?

    init(reader: OpenCodeUsageReader = .shared, history: CostHistory? = CostHistory(tool: .opencode)) {
        self.reader = reader
        self.history = history
    }

    /// Prices every turn inside the window, folds the day totals into the durable history and answers with
    /// OpenCode's own ProviderCost. nil when there is nothing to price.
    func scan(now: Date = Date(), daysBack: Int = 30, weekStart: Date, calendar: Calendar = .current) async -> ProviderCost? {
        guard FileManager.default.fileExists(atPath: reader.data.path) else { return nil }
        let cutoff = calendar.date(byAdding: .day, value: -(daysBack - 1), to: calendar.startOfDay(for: now)) ?? .distantPast
        let read = await reader.usage(now: now, calendar: calendar)
        let digest = Self.digest(read.usage.filter { $0.timestamp >= cutoff && $0.timestamp <= now }, now: now, calendar: calendar)

        let stored = history?.load(calendar: calendar) ?? [:]
        // A day whose sessions OpenCode has since deleted keeps the larger total the history remembers for it.
        var merged = stored
        for (day, record) in digest.days where (stored[day]?.cost ?? 0) <= record.cost + 1e-9 {
            merged[day] = record
        }
        history?.record(digest.days, existing: stored, calendar: calendar)
        return ProviderCost.build(tool: .opencode, source: .localMessages, days: merged, now: now, daysBack: daysBack, weekStart: weekStart,
                                  calendar: calendar, hourly: HourlyBurn(lastHour: digest.lastHour, costByHour: digest.costByHour),
                                  unpricedModels: digest.unpriced, scannedAt: now, problem: read.problem)
    }

    struct Digest: Equatable, Sendable {
        var days: [Date: CostHistory.Record] = [:]
        /// Clock hours (UTC-aligned) with at least one turn, and what each cost.
        var costByHour: [Int: Double] = [:]
        var lastHour = 0.0
        /// Models whose turns carried tokens and no price this app could stand behind.
        var unpriced: Set<String> = []
    }

    /// Day records, hour buckets, the last hour and the unpriced models from a set of turns. A turn's project is the
    /// folder it ran in, with a git worktree folded onto its repository (ProjectName).
    static func digest(_ usage: [OpenCodeUsage], now: Date, calendar: Calendar) -> Digest {
        var digest = Digest()
        let projects = ProjectName.Resolver()
        for turn in usage {
            let priced = OpenCodePricing.price(turn)
            let cost = priced.cost ?? 0
            if priced.cost == nil { digest.unpriced.insert(turn.modelID ?? turn.providerID ?? CostShare.other) }
            let day = calendar.startOfDay(for: turn.timestamp)
            var record = digest.days[day] ?? CostHistory.Record(cost: 0, tokens: TokenBreakdown(), byModel: [:], byProject: [:])
            record.cost += cost
            record.tokens += turn.tokens
            // A turn priced at a list rate names its table (rule 3), so the Cost card's price line covers OpenCode's
            // lines as it does Claude Code's and Codex's; the Go page's and OpenCode's own figures are no table's.
            if let source = priced.source { record.priceSources.insert(source) }
            if let model = turn.modelID {
                record.byModel[model, default: 0] += cost
                record.byModelTokens[model, default: 0] += turn.tokens.total
            }
            let project = turn.directory.flatMap(projects.name(ofPath:)) ?? CostShare.other
            record.byProject[project, default: 0] += cost
            record.byProjectTokens[project, default: 0] += turn.tokens.total
            digest.days[day] = record
            digest.costByHour[Int(turn.timestamp.timeIntervalSince1970 / 3600), default: 0] += cost
            let age = now.timeIntervalSince(turn.timestamp)
            if age >= 0, age < 3600 { digest.lastHour += cost }
        }
        return digest
    }
}
