import Foundation

/// One read of OpenCode's recorded turns, shared by the Go meter and the Cost card's scan so that the database is
/// read once per change rather than once per consumer: the answer is kept against the files' fingerprint
/// (OpenCodePaths.fingerprint) and the day the window starts on, and read again only when either moves.
actor OpenCodeUsageReader {
    static let shared = OpenCodeUsageReader()

    nonisolated let data: URL
    nonisolated let environment: [String: String]
    private var cached: (key: String, usage: [OpenCodeUsage], problem: String?)?

    /// Thirty-one days: the Go meter's longest window, and more than the Cost card's thirty.
    static let horizon: TimeInterval = 31 * Period.day

    init(data: URL = OpenCodePaths.dataDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.data = data
        self.environment = environment
    }

    /// Every turn since the start of the day `horizon` before `now`.
    func usage(now: Date = Date(), calendar: Calendar = .current) -> (usage: [OpenCodeUsage], problem: String?) {
        let since = calendar.startOfDay(for: now.addingTimeInterval(-Self.horizon))
        let key = "\(OpenCodePaths.fingerprint(data: data, environment: environment))|\(since.timeIntervalSince1970)"
        if let cached, cached.key == key { return (cached.usage, cached.problem) }
        let read = OpenCodeStore.usage(data: data, environment: environment, since: since)
        cached = (key, read.usage, read.problem)
        return read
    }
}

/// OpenCode Go's three limits, worked out on this Mac from its own turns (docs/accuracy.md, *OpenCode Go*).
///
/// Go publishes its limits as dollar amounts per model — a monthly limit, a 5-hour limit of 20 % of it and a weekly
/// limit of 50 % — and its prices per model, and nothing an app can read for the running total: the page sends the
/// reader to the web console. So each limit is metered here: every turn this Mac's OpenCode recorded on the plan
/// (`providerID` `opencode-go`) is priced at the page's rates (OpenCodePricing), summed per model over the window,
/// and set against that model's share of its monthly limit. The windows are trailing (the last 5 hours, 7 days and
/// 31 days) because the page does not say when its windows start, and a trailing window contains whichever window Go
/// is actually counting, so the figure can read high but never low. It counts only this Mac: a turn on another
/// machine, or through another tool on the same key, is not in OpenCode's database here. A model the page gives no
/// limit is shown by its spend with no bar, never against a limit made up for it.
enum GoMeter {
    enum Kind: CaseIterable, Sendable {
        case fiveHour, weekly, monthly

        var id: String {
            switch self {
            case .fiveHour: "go_5h"
            case .weekly: "go_weekly"
            case .monthly: "go_monthly"
            }
        }

        var duration: TimeInterval {
            switch self {
            case .fiveHour: Period.fiveHours
            case .weekly: Period.week
            case .monthly: 31 * Period.day
            }
        }

        var share: Double {
            switch self {
            case .fiveHour: GoPlan.fiveHourShare
            case .weekly: GoPlan.weeklyShare
            case .monthly: 1
            }
        }

        /// Go's own names for its limits; "%ld-hour" and the other two are keys the app already speaks.
        var label: WindowLabel {
            switch self {
            case .fiveHour: .filled("%ld-hour", [.number(5)])
            case .weekly: .key("Weekly")
            case .monthly: .key("Monthly")
            }
        }
    }

    /// One model's spend in one window, and the limit it is measured against; nil for a model with no published limit.
    struct Spend: Equatable, Sendable {
        let modelID: String
        let name: String
        let spentUSD: Double
        let limitUSD: Double?

        var fraction: Double? { limitUSD.flatMap { $0 > 0 ? spentUSD / $0 : nil } }
    }

    /// Each Go model's spend inside `kind`'s window ending at `now`, priced by OpenCodePricing (the page's rates for
    /// a model it lists, else OpenCode's own recorded cost). A turn that cannot be priced adds nothing. A free model
    /// with no limit is left out: there is nothing to meter.
    static func spend(_ usage: [OpenCodeUsage], kind: Kind, now: Date) -> [Spend] {
        let since = now.addingTimeInterval(-kind.duration)
        var totals: [String: Double] = [:]
        for turn in usage where turn.providerID?.lowercased() == GoPlan.providerID && turn.timestamp > since && turn.timestamp <= now {
            // A limit is a model's, so a turn that names no model has none to count against.
            guard let id = turn.modelID?.lowercased(), !id.isEmpty, let cost = OpenCodePricing.price(turn).cost else { continue }
            totals[id, default: 0] += cost
        }
        return totals.compactMap { id, spent in
            let model = GoPlan.model(id)
            let limit = model?.monthlyLimit(at: now).map { $0 * kind.share }
            if model != nil, limit == nil, spent <= 0 { return nil }
            return Spend(modelID: id, name: model?.name ?? id, spentUSD: spent, limitUSD: limit)
        }
        .sorted { ($0.fraction ?? -1, $1.name) > ($1.fraction ?? -1, $0.name) }
    }

    /// The reading: per window, the model closest to its limit leads, and with two or more models each one also has
    /// a window of its own, hidden until revealed in Settings. nil when this Mac has no Go turn in the last 31 days.
    static func reading(_ usage: [OpenCodeUsage], now: Date = Date()) -> UsageReading? {
        let go = usage.filter { $0.providerID?.lowercased() == GoPlan.providerID }
        guard let newest = go.map(\.timestamp).max(), now.timeIntervalSince(newest) < Kind.monthly.duration else { return nil }
        var windows: [LimitWindow] = []
        var scoped: [LimitWindow] = []
        for kind in Kind.allCases {
            let spends = spend(go, kind: kind, now: now)
            let lead = spends.first { $0.limitUSD != nil } ?? spends.first
            windows.append(window(kind: kind, spend: lead, id: kind.id, label: kind.label, model: nil))
            guard spends.count > 1 else { continue }
            for spend in spends {
                scoped.append(window(kind: kind, spend: spend, id: "\(kind.id):\(spend.modelID)", label: .scoped(model: spend.name, of: kind.label),
                                     model: spend.name, hidden: true))
            }
        }
        // No `observedAt`: a trailing window read now holds every turn up to now, so the figure is as fresh as the read,
        // however long ago the newest turn was; the card's "As of" would call a quiet afternoon stale.
        return UsageReading(tool: .opencode, windows: windows + scoped, plan: "Go", fetchedAt: now, observedAt: nil)
    }

    /// One window: the model's fraction of its share of the limit, or with no limit its spend and no bar. A window
    /// with nothing spent in it reads untouched against the limit of the model that leads the month.
    static func window(kind: Kind, spend: Spend?, id: String, label: WindowLabel, model: String?, hidden: Bool = false) -> LimitWindow {
        guard let spend else {
            return LimitWindow(id: id, label: label, usedFraction: 0, resetsAt: nil, periodDuration: kind.duration, model: model,
                               source: .computedLocally, hiddenByDefault: hidden, amountUSD: 0)
        }
        guard let limit = spend.limitUSD, let fraction = spend.fraction else {
            return LimitWindow(id: id, label: label, usedFraction: nil, resetsAt: nil,
                               note: L("%1$@ · %2$@ spent, no published limit", spend.name, Money.dollars(spend.spentUSD)),
                               periodDuration: kind.duration, model: model, source: .computedLocally, hiddenByDefault: hidden, amountUSD: spend.spentUSD)
        }
        let percent = fraction * 100
        return LimitWindow(id: id, label: label, usedFraction: min(max(fraction, 0), 1), resetsAt: nil,
                           note: L("%1$@ · %2$@ of %3$@", spend.name, Money.dollars(spend.spentUSD), Money.dollars(limit)),
                           periodDuration: kind.duration, model: model, source: .computedLocally, hiddenByDefault: hidden,
                           rawUsedPercent: percent > 100 ? percent : nil, amountUSD: spend.spentUSD)
    }
}

/// OpenCode's card: the Go plan's limits as GoMeter works them out from this Mac's own turns. There is no network
/// read at all: the database is local, opened read-only (OpenCodeStore), and the provider only ever reads it.
/// OpenCode run on the user's own provider keys has no plan to meter, which is not a fault; its spend is on the Cost
/// card either way.
struct OpenCodeProvider: UsageProvider {
    let tool: ToolID = .opencode
    /// A local read, so it can be frequent; the store's polling policy still slows it when nothing is happening.
    let refreshInterval: TimeInterval = 120
    let reader: OpenCodeUsageReader
    let home: URL

    init(reader: OpenCodeUsageReader = .shared, home: URL = Paths.home) {
        self.reader = reader
        self.home = home
    }

    /// OpenCode is on this Mac when its data folder exists: it makes the folder on its first start, before any
    /// session, so a fresh install reads as installed with nothing yet to show.
    func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: reader.data.path)
    }

    func fetch() async throws -> UsageReading {
        let now = Date()
        let read = await reader.usage(now: now)
        if let reading = GoMeter.reading(read.usage, now: now) { return reading }
        if read.usage.isEmpty, let problem = read.problem { throw ProviderError.unavailable(problem) }
        throw ProviderError.nothingYet(L("No OpenCode Go turns on this Mac in the last 31 days; its spend is on the Cost card"))
    }
}
