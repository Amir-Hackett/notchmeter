import Foundation

/// The lines under the Cost card's legend. They describe the assistant at the top of the card's order — the one
/// the user put first — rather than the blend, so every figure here belongs to one tool and a figure that tool's
/// source cannot produce is simply absent instead of being carried over from another (docs/accuracy.md).
///
/// Two figures are deliberately not built here, because a total is the only thing they mean: the headline in the
/// ring, which is what the carried assistants cost together, and the month against a monthly budget, which is set
/// against all of them at once and cannot be shared out.
struct CostDetail {
    let provider: ProviderCost
    let range: CostRange
    /// The Claude-window figures — the live weekly window, the 5-hour block, the day the history starts — which
    /// exist only while Claude itself leads. nil under any other leader, so they never describe someone else.
    let claude: CostSummary?
    let now: Date
    let calendar: Calendar
    /// For the block line's start, which is a clock time rather than a day.
    let timeFormat: TimeFormatPreference

    init(provider: ProviderCost, range: CostRange, claude: CostSummary? = nil, now: Date = Date(), calendar: Calendar = .current,
         timeFormat: TimeFormatPreference = .auto) {
        self.provider = provider
        self.range = range
        self.claude = provider.tool == .claude ? claude : nil
        self.now = now
        self.calendar = calendar
        self.timeFormat = timeFormat
    }

    private var name: String { provider.tool.displayName }
    private var totals: RangeTotals { provider.totals(range) }

    /// This assistant's last hour against its own 30-day average. A day-resolution source (a billing export)
    /// cannot say what an hour cost, so it has no burn line at all.
    var burn: String? {
        guard let lastHour = provider.lastHour, let multiple = provider.burnMultiple else { return nil }
        return L("%1$@ last hour %2$@ · %3$@ its 30-day average", name, Money.dollars(lastHour), Burn.multiple(multiple))
    }

    /// This assistant's tokens in the range, with the cache-read share where its own source counts cache reads.
    var tokens: String? {
        let counts = totals.tokens
        guard counts.total > 0 else { return nil }
        let figure = Money.tokens(counts.total)
        guard counts.cacheRead > 0, let share = counts.cacheReadShare else { return L("%1$@ used %2$@", name, figure) }
        return L("%1$@ used %2$@ · %3$ld%% cache reads", name, figure, Int((share * 100).rounded()))
    }

    /// The 1-hour cache tier against the 5-minute one. Only Claude Code's transcripts record which tier a write
    /// went to; the other sources have a single cache and one bucket standing in for it, and a split drawn from
    /// that would be a distinction the source never made.
    var cacheWrites: String? {
        guard provider.tool == .claude, let share = CacheTTL.oneHourShare(totals.tokens) else { return nil }
        return L("cache writes %1$ld%% 1-hour · %2$ld%% 5-minute", Int((share * 100).rounded()), Int(((1 - share) * 100).rounded()))
    }

    /// The folders this assistant's spend ran in. Cursor's export carries no folder, so Cursor has no such line.
    var projects: String? {
        let projects = totals.projects
        guard !projects.isEmpty else { return nil }
        let top = projects.prefix(2).map { "\($0.name == CostShare.other ? L("Other") : $0.name) \(Money.dollars($0.cost, cents: $0.cost < 10))" }
        return L("Top: %@", top.joined(separator: " · "))
    }

    /// The live Claude weekly window: its own spend since it opened, and what one per cent of it has cost.
    var week: String? {
        guard range == .week, let week = claude?.week else { return nil }
        let since = ResetText.dayPhrase(week.start, now: now, calendar: calendar)
        guard let perPercent = week.perPercent else { return L("Claude %1$@ since %2$@", Money.dollars(week.cost), since) }
        return L("Claude %1$@ since %2$@ · %3$@ per 1%% of weekly", Money.dollars(week.cost), since, Money.dollars(perPercent))
    }

    /// The live 5-hour session block, which only Claude Code meters. It names the hour it opened for the same
    /// reason the week line names its day: the figures above it cover a whole day and this one does not, and a
    /// block that has just reset otherwise reads as a contradiction of the day's total sitting beside it.
    var block: String? {
        guard let block = claude?.block, block.cost > 0 || block.tokens.total > 0 else { return nil }
        let since = ResetText.time(block.start, format: timeFormat, calendar: calendar)
        guard let rate = block.tokensPerMinute else { return L("This session block %1$@ since %2$@", Money.dollars(block.cost), since) }
        return L("This session block %1$@ since %2$@ · %3$@/min", Money.dollars(block.cost), since,
                 Money.tokens(Int(rate.rounded())).replacingOccurrences(of: " tokens", with: ""))
    }

    /// Everything Claude Code has cost since its history begins, against the 90-day range that asks the question.
    var since: String? {
        guard range == .last90Days, let claude, let first = claude.firstUse else { return nil }
        return L("Claude since %1$@: %2$@", ResetText.dayPhrase(first, now: now, calendar: calendar), Money.dollars(claude.sinceFirstUse))
    }

    /// What kind of number the block above is. The legend tags each row with its own source in a word; this says
    /// it in full for the leader, whose figures these are.
    var source: String {
        provider.source.isEstimate
            ? L("%@ priced here from local files at published list rates", name)
            : L("%@ as the vendor's own usage export priced it", name)
    }

    /// The leader's lines the card keeps behind Show details, in the order it draws them.
    var detailLines: [String] { [week, since, block].compactMap { $0 } }

    /// The same, in the card's quieter caption style.
    var detailCaptions: [String] { [tokens, cacheWrites, projects].compactMap { $0 } }
}
