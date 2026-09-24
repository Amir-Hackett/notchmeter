import Foundation

/// Where a tool's spend figure came from. It is printed beside the figure because a number priced here from local
/// files at published rates and a number the vendor itself billed are not the same kind of number.
enum CostSource: String, Codable, Equatable, Sendable {
    /// Priced here from the tool's own transcripts at published list rates (Claude Code).
    case localTranscripts
    /// Priced here from the tool's own session rollouts at published list rates (Codex).
    case localSessions
    /// The vendor's own per-request costs, read from its usage export (Cursor).
    case billingExport
    /// The vendor's own running count of credits, converted at the vendor's published rate and laid on the day
    /// each rise was observed (GitHub Copilot's AI credits, a cent each). The count is the vendor's; the day it
    /// lands on is this Mac's observation, so it stays an estimate rather than borrowing the export's standing.
    case vendorCredits

    var label: String {
        switch self {
        case .localTranscripts: L("local transcripts")
        case .localSessions: L("local sessions")
        case .billingExport: L("billing export")
        case .vendorCredits: L("AI credits")
        }
    }

    /// The same provenance in the width a legend row beside a donut has, where the line under the rows already
    /// says that local files are priced here and an export is the vendor's own figure.
    var shortLabel: String {
        switch self {
        case .localTranscripts: L("transcripts")
        case .localSessions: L("sessions")
        case .billingExport: L("export")
        case .vendorCredits: L("credits")
        }
    }

    /// True where the dollars are this Mac's arithmetic over published rates rather than a figure the vendor sent.
    var isEstimate: Bool { self != .billingExport }

    /// The full sentence under the card and the dashboard naming what kind of number a tool's figures are.
    func provenance(of tool: ToolID) -> String {
        switch self {
        case .localTranscripts, .localSessions: L("%@ priced here from local files at published list rates", tool.displayName)
        case .billingExport: L("%@ as the vendor's own usage export priced it", tool.displayName)
        case .vendorCredits: L("%@ from GitHub's own credit count at a cent a credit, on the day each rise was seen", tool.displayName)
        }
    }
}

/// One tool's spend: the ranges the Cost card offers, a daily series, the per-model shares of each range, the
/// source the figures came from, when they were read and what went wrong if anything did.
///
/// A tool whose spend cannot be derived from a source it publishes has no `ProviderCost` at all. Antigravity
/// (quota, no dollars) never builds one, and GitHub Copilot builds one only on a seat GitHub meters in AI credits,
/// so the card shows nothing for them otherwise rather than a zero that would read as "you spent nothing".
/// docs/accuracy.md says why.
struct ProviderCost: Equatable, Sendable, Identifiable {
    let tool: ToolID
    let source: CostSource
    let ranges: [CostRange: RangeTotals]
    /// One entry per calendar day for the last 30 days, oldest first.
    let daily: [DailySpend]
    /// Ninety days, where the durable history reaches back that far.
    let daily90: [DailySpend]
    /// Everything priced in the last 60 minutes; nil where the source is day-resolution and cannot say.
    let lastHour: Double?
    /// Mean cost of an active hour over the window; nil with the same limit.
    let typicalHourly: Double?
    /// lastHour / typicalHourly, on the same five-active-hours guard the Claude figure uses; nil until then.
    let burnMultiple: Double?
    /// Model ids the source named that this build has no published rate for; their tokens contribute nothing.
    let unpricedModels: Set<String>
    /// Where the list prices that priced the window's files came from (PriceSource): the build's table, the
    /// catalog, an override. Empty for a source whose dollars are the vendor's own, which has no list price.
    let priceSources: Set<PriceSource>
    /// When these figures were read from their source, which is not when the app last drew them.
    let scannedAt: Date
    /// Why the figures are missing or older than they should be; nil when the read was clean.
    let problem: String?

    var id: ToolID { tool }

    init(tool: ToolID, source: CostSource, ranges: [CostRange: RangeTotals], daily: [DailySpend], daily90: [DailySpend] = [],
         lastHour: Double? = nil, typicalHourly: Double? = nil, burnMultiple: Double? = nil, unpricedModels: Set<String> = [],
         priceSources: Set<PriceSource> = [], scannedAt: Date, problem: String? = nil) {
        self.tool = tool
        self.source = source
        self.ranges = ranges
        self.daily = daily
        self.daily90 = daily90.isEmpty ? daily : daily90
        self.lastHour = lastHour
        self.typicalHourly = typicalHourly
        self.burnMultiple = burnMultiple
        self.unpricedModels = unpricedModels
        self.priceSources = priceSources
        self.scannedAt = scannedAt
        self.problem = problem
    }

    func totals(_ range: CostRange) -> RangeTotals { ranges[range] ?? RangeTotals() }

    /// True once any range holds something worth showing; a tool with nothing to say is left off the card.
    var hasFigures: Bool {
        ranges.values.contains { $0.cost > 0 || $0.tokens.total > 0 }
    }

    /// Ranges and series from per-day records: the shape every tool's spend reduces to once it is on the day grid.
    /// nil when the records hold nothing, so an installed tool that has spent nothing shows no cost rather than $0.
    static func build(tool: ToolID, source: CostSource, days: [Date: CostHistory.Record], now: Date, daysBack: Int = 30,
                      weekStart: Date, calendar: Calendar = .current, hourly: HourlyBurn? = nil, unpricedModels: Set<String> = [],
                      priceSources: Set<PriceSource> = [], scannedAt: Date, problem: String? = nil) -> ProviderCost? {
        let today = calendar.startOfDay(for: now)
        guard let windowStart = calendar.date(byAdding: .day, value: -(daysBack - 1), to: today),
              let start90 = calendar.date(byAdding: .day, value: -89, to: today)
        else { return nil }
        let daily = RangeTotals.series(days: days, from: windowStart, count: daysBack, calendar: calendar)
        let daily90 = RangeTotals.series(days: days, from: start90, count: 90, calendar: calendar)
        let ranges = RangeTotals.ranges(days: days, daily: daily, daily90: daily90, weekStart: weekStart, now: now, calendar: calendar)
        let cost = ProviderCost(tool: tool, source: source, ranges: ranges, daily: daily, daily90: daily90, lastHour: hourly?.lastHour,
                                typicalHourly: hourly?.typicalHourly, burnMultiple: hourly?.multiple, unpricedModels: unpricedModels,
                                priceSources: priceSources, scannedAt: scannedAt, problem: problem)
        return cost.hasFigures ? cost : nil
    }
}

/// The name the Cost card groups spend under: the folder a turn ran in, whichever tool ran it, with a git worktree
/// folded onto the repository it was cut from. Agents run in worktrees, and until 0.6.0 each one showed up on the
/// card's "Top:" line as its own project ("wf_4213f04c-061-4 $4.73") beside the repository the work belonged to.
///
/// A worktree is recognised without forking git, because a scan meets a `cwd` on every transcript line: by its
/// `.git`, which in a worktree is a FILE whose one line reads `gitdir: <repo>/.git/worktrees/<name>`, or, once the
/// worktree has been removed and that file with it (the transcript outlives the checkout), by the path shape
/// `<repo>/.claude/worktrees/<name>` that Claude Code gives the worktrees it creates. A `cwd` inside a worktree's
/// subfolder walks up to the nearest `.git`. A `.git` DIRECTORY is a plain checkout and ends the walk with the
/// cwd's own folder name, so a plain repository's subfolders keep the names they always had; a `.git` file that
/// points anywhere else (a submodule's `../.git/modules/<name>`) is left alone the same way.
enum ProjectName {
    static func ofPath(_ path: String) -> String? { Resolver().name(ofPath: path) }

    /// One per scan: the walk costs a stat per ancestor, and a transcript names the same directory on every line,
    /// so each directory's answer is kept for the scan's lifetime and the filesystem is asked once.
    final class Resolver {
        /// The repository a directory belongs to, or nil when it is not a worktree; a key is present once asked.
        private var repositories: [String: URL?] = [:]

        init() {}

        func name(ofPath path: String) -> String? {
            let directory = URL(fileURLWithPath: path).standardizedFileURL
            let own = directory.lastPathComponent
            guard !own.isEmpty, own != "/" else { return nil }
            guard let repository = repository(containing: directory) else { return own }
            let name = repository.lastPathComponent
            return name.isEmpty || name == "/" ? own : name
        }

        /// The repository whose worktree holds `directory`, by the path shape first (no filesystem), then by the
        /// nearest `.git` walking up. Every ancestor visited is remembered, so a second cwd under the same worktree
        /// stops at the first directory already answered.
        func repository(containing directory: URL) -> URL? {
            if let known = repositories[directory.path] { return known }
            let answer = resolve(directory)
            repositories[directory.path] = answer
            return answer
        }

        private func resolve(_ directory: URL) -> URL? {
            if let repository = ProjectName.claudeWorktreeRepository(of: directory) { return repository }
            let dotGit = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                return isDirectory.boolValue ? nil : ProjectName.worktreeRepository(gitFile: dotGit)
            }
            guard directory.pathComponents.count > 1 else { return nil }
            return repository(containing: directory.deletingLastPathComponent())
        }
    }

    /// `<repo>/.claude/worktrees/<name>[/...]` → `<repo>`, from the path alone: Claude Code keeps the worktrees
    /// it cuts under the repository's own `.claude`, and the shape survives the worktree's removal.
    static func claudeWorktreeRepository(of directory: URL) -> URL? {
        let parts = directory.pathComponents
        guard let at = parts.indices.dropLast(2).first(where: { parts[$0] == ".claude" && parts[$0 + 1] == "worktrees" }),
              at >= 2
        else { return nil }
        return parts[1..<at].reduce(URL(fileURLWithPath: "/")) { $0.appendingPathComponent($1) }
    }

    /// The `<repo>` a worktree's `.git` file names, `gitdir: <repo>/.git/worktrees/<name>`, resolved against the
    /// file's folder when git wrote it relative; nil for any other pointer.
    static func worktreeRepository(gitFile: URL) -> URL? {
        guard let pointer = try? String(contentsOf: gitFile, encoding: .utf8), let line = pointer.split(separator: "\n").first,
              line.hasPrefix("gitdir:") else { return nil }
        let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        let gitdir = (target.hasPrefix("/") ? URL(fileURLWithPath: target) : gitFile.deletingLastPathComponent().appendingPathComponent(target))
            .standardizedFileURL
        let parts = gitdir.pathComponents
        guard parts.count >= 5, parts[parts.count - 3] == ".git", parts[parts.count - 2] == "worktrees" else { return nil }
        return gitdir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}

/// The last hour against a normal active hour, for a source whose entries carry a time of day.
struct HourlyBurn: Equatable, Sendable {
    let lastHour: Double
    let typicalHourly: Double
    /// Clock hours in the window with at least one entry; the multiple is withheld under five of them.
    let activeHours: Int

    static let minimumActiveHours = 5

    var multiple: Double? {
        activeHours >= Self.minimumActiveHours && typicalHourly > 0 ? lastHour / typicalHourly : nil
    }

    /// The mean priced cost of an active hour, an active hour being one with at least one entry.
    init(lastHour: Double, costByHour: [Int: Double]) {
        self.lastHour = lastHour
        self.activeHours = costByHour.count
        self.typicalHourly = costByHour.isEmpty ? 0 : costByHour.values.reduce(0, +) / Double(costByHour.count)
    }

    init(lastHour: Double, typicalHourly: Double, activeHours: Int) {
        self.lastHour = lastHour
        self.typicalHourly = typicalHourly
        self.activeHours = activeHours
    }
}

extension RangeTotals {
    init(_ record: CostHistory.Record) {
        self.init(cost: record.cost, tokens: record.tokens, byModel: record.byModel, byProject: record.byProject,
                  byModelTokens: record.byModelTokens, byProjectTokens: record.byProjectTokens)
    }

    /// A per-day series over `count` days from `first`, oldest first, with a zero day where nothing was recorded.
    static func series(days: [Date: CostHistory.Record], from first: Date, count: Int, calendar: Calendar) -> [DailySpend] {
        (0..<count).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: first) else { return nil }
            let record = days[day]
            return DailySpend(day: day, cost: record?.cost ?? 0, tokens: record?.tokens.total ?? 0, topModel: record?.topModel)
        }
    }

    /// Every range the Cost card offers, from day records. `week` is day-aligned from `weekStart`; a source that
    /// knows its own boundary to the minute (Claude's weekly window) replaces it with its own total afterwards.
    static func ranges(days: [Date: CostHistory.Record], daily: [DailySpend], daily90: [DailySpend], weekStart: Date,
                       now: Date, calendar: Calendar) -> [CostRange: RangeTotals] {
        let today = calendar.startOfDay(for: now)
        func total(_ chosen: [Date]) -> RangeTotals {
            var totals = RangeTotals()
            for day in chosen {
                guard let record = days[day] else { continue }
                totals.add(RangeTotals(record))
            }
            return totals
        }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? today
        let weekDay = calendar.startOfDay(for: weekStart)
        return [
            .today: total([today]),
            .yesterday: total([yesterday]),
            .last30Days: total(daily.map(\.day)),
            .last90Days: total(daily90.map(\.day)),
            .month: total(days.keys.filter { $0 >= monthStart && $0 <= today }),
            .week: total(days.keys.filter { $0 >= weekDay && $0 <= today }),
        ]
    }
}
