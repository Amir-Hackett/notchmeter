import CoreGraphics
import Foundation

// MARK: - The card's choices

/// What the card's headline counts: the API-equivalent dollars, or the tokens behind them.
enum ShareCardMetric: String, CaseIterable, Codable, Sendable {
    case value, tokens

    var title: String {
        switch self {
        case .value: L("API value")
        case .tokens: L("Tokens")
        }
    }

    /// The theme a card of this metric opens in until the reader picks one: money on black, counts on blue.
    var defaultTheme: ShareCardTheme {
        switch self {
        case .value: .black
        case .tokens: .blue
        }
    }
}

/// The spans a card can cover, each ending today.
enum ShareCardRange: String, CaseIterable, Codable, Sendable {
    case today, sevenDays, thirtyDays, month, ninetyDays

    var title: String {
        switch self {
        case .today: L("Today")
        case .sevenDays: L("7 days")
        case .thirtyDays: L("30 days")
        case .month: L("This month")
        case .ninetyDays: L("90 days")
        }
    }

    /// The span in a file name, in English whatever the app speaks: a file is named once and read by a file system.
    var fileWord: String {
        switch self {
        case .today: "today"
        case .sevenDays: "7-days"
        case .thirtyDays: "30-days"
        case .month: "this-month"
        case .ninetyDays: "90-days"
        }
    }

    /// The months of plan fees the span stands against (PlanValue.months); nil for a span under a month, which has
    /// no fee of its own to set against it and so carries no ratio.
    var months: Int? {
        switch self {
        case .thirtyDays, .month: 1
        case .ninetyDays: 3
        case .today, .sevenDays: nil
        }
    }

    /// The calendar days of the span, oldest first, today last.
    func days(now: Date, calendar: Calendar) -> [Date] {
        let today = calendar.startOfDay(for: now)
        let count: Int
        switch self {
        case .today: count = 1
        case .sevenDays: count = 7
        case .thirtyDays: count = 30
        case .ninetyDays: count = 90
        case .month:
            let first = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? today
            count = max(1, (calendar.dateComponents([.day], from: calendar.startOfDay(for: first), to: today).day ?? 0) + 1)
        }
        return (0..<count).reversed().map { back in
            calendar.startOfDay(for: calendar.date(byAdding: .day, value: -back, to: today) ?? today)
        }
    }
}

/// The picture's shape, in pixels: the feed's 4:5 portrait, the square, and the full-height story.
enum ShareCardFormat: String, CaseIterable, Codable, Sendable {
    case feed, square, story

    var title: String {
        switch self {
        case .feed: L("Feed")
        case .square: L("Square")
        case .story: L("Story")
        }
    }

    var pixels: (width: Int, height: Int) {
        switch self {
        case .feed: (1200, 1500)
        case .square: (1080, 1080)
        case .story: (1080, 1920)
        }
    }

    var size: CGSize { CGSize(width: pixels.width, height: pixels.height) }
}

/// Three grounds, each with its own text and chart colours, held to the same bar the rest of the app is: text at
/// 4.5:1 or better against the ground, and every mark of the chart (an assistant's area, the ratio's badge) at 3:1
/// (ShareCardThemeContrast pins both). The assistants keep their identity hues on every theme, stepped for the
/// ground they sit on the way `ToolID.chartColor` steps them for a light or a dark window.
enum ShareCardTheme: String, CaseIterable, Codable, Sendable {
    case white, black, blue

    var title: String {
        switch self {
        case .white: L("White")
        case .black: L("Black")
        case .blue: L("Blue")
        }
    }

    var background: UInt32 {
        switch self {
        case .white: 0xFFFFFF
        case .black: 0x000000
        case .blue: 0x0B3A8C
        }
    }

    var primary: UInt32 {
        switch self {
        case .white: 0x16161A
        case .black, .blue: 0xFFFFFF
        }
    }

    /// Captions, the range and the footnote: quieter than the text, still over 4.5:1.
    var secondary: UInt32 {
        switch self {
        case .white: 0x5C5C66
        case .black: 0xA8A8B0
        case .blue: 0xC5D5F5
        }
    }

    /// Hairlines and the chart's baseline; decoration that carries nothing on its own.
    var rule: UInt32 {
        switch self {
        case .white: 0xE3E3E8
        case .black: 0x2A2A30
        case .blue: 0x2C56A8
        }
    }

    /// The ratio's badge, with the ground's own colour for its text.
    var badge: UInt32 {
        switch self {
        case .white: 0xB4532F
        case .black: 0xD97857
        case .blue: 0xFFD27A
        }
    }

    /// The text on the badge.
    var onBadge: UInt32 {
        switch self {
        case .white: 0xFFFFFF
        case .black: 0x000000
        case .blue: 0x0B3A8C
        }
    }

    /// Each assistant in the hue its ring wears (PanelInk.tool): on White the Paper tones, on Black the panel's
    /// own, and on Blue a tint of each light enough to clear 3:1 over the ground. Gemini CLI, Kimi Code and
    /// OpenCode take the hues 0.9.0 gave their rings, so a card's legend matches the notch.
    func tool(_ tool: ToolID) -> UInt32 {
        switch (self, tool) {
        case (.white, .claude): 0xC0603F
        case (.white, .codex): 0x23A06F
        case (.white, .cursor): 0x7F62E6
        case (.white, .gemini): 0xB8378F
        case (.white, .antigravity): 0x2F7FB8
        case (.white, .copilot): 0x9A8A00
        case (.white, .kimi): 0x367D24
        case (.white, .opencode): 0xA52ACB
        case (.black, .claude): 0xCC7555
        case (.black, .codex): 0x34A874
        case (.black, .cursor): 0x8C74EA
        case (.black, .gemini): 0xE36FC0
        case (.black, .antigravity): 0x56B4E9
        case (.black, .copilot): 0xF0E442
        case (.black, .kimi): 0x7ED957
        case (.black, .opencode): 0xBE3CE6
        case (.blue, .claude): 0xF4A582
        case (.blue, .codex): 0x6EE7A8
        case (.blue, .cursor): 0xC3B3FF
        case (.blue, .gemini): 0xF5A3DC
        case (.blue, .antigravity): 0x9ED8FF
        case (.blue, .copilot): 0xF0E442
        case (.blue, .kimi): 0xA6EB86
        case (.blue, .opencode): 0xDDA6F2
        }
    }

    /// WCAG's contrast ratio between two sRGB colours, for the tests that hold every theme to its bar.
    static func contrast(_ one: UInt32, _ other: UInt32) -> Double {
        func luminance(_ hex: UInt32) -> Double {
            func channel(_ value: UInt32) -> Double {
                let c = Double(value) / 255
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel((hex >> 16) & 0xFF) + 0.7152 * channel((hex >> 8) & 0xFF) + 0.0722 * channel(hex & 0xFF)
        }
        let (a, b) = (luminance(one), luminance(other))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

// MARK: - What the card says

/// Everything one card carries, assembled from figures the app already holds (ShareCard.content) and nothing
/// else: the headline, the plan comparison where it can honestly be made, a stacked cumulative series and a total
/// per assistant, one line drawn from something that really happened in the span, and the reader's signature.
/// Never a project, a prompt, a session title or a branch: the inputs carry none, so the card cannot either.
struct ShareCardContent: Equatable {
    struct Row: Equatable, Identifiable {
        let tool: ToolID
        let amount: Double
        /// Its part of the total, 0...1; nil while it is the only row.
        let share: Double?
        var id: ToolID { tool }
    }

    let metric: ShareCardMetric
    let range: ShareCardRange
    /// The span's calendar days, oldest first.
    let days: [Date]
    /// The assistants with something in the span, in the reader's order.
    let rows: [Row]
    /// Per row, in the rows' order, the running total at the end of each day of `days`.
    let cumulative: [[Double]]
    let total: Double
    /// The value against the plans' fees; nil for tokens, for a span under a month, or where a plan is unpriced.
    let plan: PlanValue?
    let advice: String?
    let signature: String?
    /// Every assistant with a figure left unticked: the card is empty by the reader's choice rather than by the
    /// span, and the studio says so in the card's place instead of drawing the empty card's line, which would
    /// send them to the range picker when the checkboxes are the cause.
    let nothingTicked: Bool

    var isEmpty: Bool { total <= 0 }

    /// "$7,326", or "18M tokens".
    var headline: String { Self.amount(total, metric: metric, cents: false) }

    /// What the headline is: "of API-equivalent value on the $100 Claude Max 5x plan"; nil for tokens, whose
    /// headline names its own unit.
    var headlineCaption: String? {
        guard metric == .value else { return nil }
        guard let plan else { return L("of API-equivalent value") }
        return L("of API-equivalent value %@", plan.phrase)
    }

    /// The words beside the ratio's badge, counting the plans the way `PlanValue.phrase` does: a free plan beside
    /// a paid one adds nothing to the fee, so the caption above names the one paid plan and the badge says "the
    /// plan's price" to match, rather than "the plans" over a line that named only one.
    var ratioCaption: String? {
        guard let plan else { return nil }
        return plan.plans.filter { $0.monthlyUSD > 0 }.count == 1 ? L("the plan's price") : L("what the plans cost")
    }

    /// The kind of number the card is, in the words the card must carry.
    var footnote: String {
        metric == .value ? L("API-equivalent estimate, not a bill") : L("Token counts from this Mac's own records")
    }

    /// "Aug 26 – Sep 24", or the one day.
    func span(calendar: Calendar) -> String {
        guard let first = days.first, let last = days.last else { return "" }
        let locale = Locale(identifier: Localization.current)
        if first == last {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = locale
            formatter.setLocalizedDateFormatFromTemplate("EEEE MMM d")
            return formatter.string(from: first)
        }
        let formatter = DateIntervalFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateTemplate = "MMMd"
        return formatter.string(from: first, to: last)
    }

    /// The text Copy caption puts on the pasteboard: the headline sentence, the assistants' totals, the line, what
    /// kind of number it is and where it came from. The same figures as the picture and nothing the picture does
    /// not carry, the signature aside, which the person posting it has no need to repeat.
    func caption(calendar: Calendar) -> String {
        let sentence: String
        switch metric {
        case .value: sentence = plan?.sentence ?? L("%@ of API-equivalent value", headline)
        case .tokens: sentence = headline
        }
        var lines = [L("%1$@ (%2$@): %3$@", range.title, span(calendar: calendar), sentence)]
        if rows.count > 1 {
            lines.append(rows.map { "\($0.tool.displayName) \(Self.amount($0.amount, metric: metric, cents: false))" }.joined(separator: " · "))
        }
        if let advice { lines.append(advice) }
        lines.append(footnote)
        lines.append(L("Measured with %@", AppInfo.name) + " · " + ShareCard.siteURL)
        return lines.joined(separator: "\n")
    }

    /// One amount in the metric's own unit.
    static func amount(_ value: Double, metric: ShareCardMetric, cents: Bool = true) -> String {
        switch metric {
        case .value: Money.dollars(value, cents: cents)
        case .tokens: Money.tokens(Int(value.rounded()))
        }
    }
}

/// Where the card was asked for, for the oracle: the Options menu, the Cost card's menu, the dashboard's button,
/// or the app itself after an update (ShareCardOffer).
enum ShareCardCause: String, Sendable {
    case menu, costCard, dashboard, offer
}

enum ShareCard {
    /// The site the card and its caption point at; the card is the advertisement, so it always carries it.
    static let site = "notchmeter.com"
    static let siteURL = "https://notchmeter.com"
    /// The signature is a line, not a paragraph.
    static let signatureLimit = 40

    /// What a card is built from: the spend every assistant reported (`CostSummary.providers`, whose daily series
    /// reach ninety days back), the plans the readings name, the windows they carry and the drain log's samples of
    /// them (seven days), and the reader's choices. All of it is already on this Mac; nothing is fetched for a card.
    struct Input {
        var providers: [ProviderCost]
        var order: [ToolID] = ToolID.allCases
        /// The assistants the reader chose; nil is every one with a figure.
        var tools: Set<ToolID>? = nil
        var plans: [ToolID: String] = [:]
        var windows: [ToolID: [LimitWindow]] = [:]
        var samples: [DrainLog.Key: [DrainSample]] = [:]
        /// Where Claude Code's durable history begins (CostSummary.firstUse), for the ninety-day card's coverage
        /// test (PlanValue.covers): three months of plan fees are set against three months of records or not at all.
        var firstUse: Date? = nil
        var metric: ShareCardMetric = .value
        var range: ShareCardRange = .thirtyDays
        var signature: String = ""
        var now: Date = Date()
        var calendar: Calendar = .current
    }

    /// "notchmeter-usage-30-days-feed.png": what Save PNG offers, from the card's own choices rather than a date,
    /// so two saves of the same card land on the same name.
    static func fileName(range: ShareCardRange, format: ShareCardFormat) -> String {
        "notchmeter-usage-\(range.fileWord)-\(format.rawValue).png"
    }

    /// The assistants a card can carry: every one whose spend or tokens the app holds, in the reader's order.
    static func available(providers: [ProviderCost], order: [ToolID]) -> [ToolID] {
        order.filter { tool in providers.contains { $0.tool == tool && $0.hasFigures } }
    }

    static func content(_ input: Input) -> ShareCardContent {
        let days = input.range.days(now: input.now, calendar: input.calendar)
        let keys = days.map { CostHistory.key($0, calendar: input.calendar) }
        let available = available(providers: input.providers, order: input.order)
        let chosen = available.filter { input.tools?.contains($0) ?? true }
        var perDay: [(tool: ToolID, values: [Double])] = []
        for tool in chosen {
            guard let provider = input.providers.first(where: { $0.tool == tool }) else { continue }
            // Matched by the day's key rather than by Date, as the dashboard does: a day that begins at 01:00 in a
            // zone whose clocks change at midnight must still find its own row.
            var byKey: [String: Double] = [:]
            for spend in provider.daily90 {
                byKey[CostHistory.key(spend.day, calendar: input.calendar), default: 0] += input.metric == .value ? spend.cost : Double(spend.tokens)
            }
            let values = keys.map { byKey[$0] ?? 0 }
            if values.reduce(0, +) > 0 { perDay.append((tool, values)) }
        }
        let total = perDay.reduce(0) { $0 + $1.values.reduce(0, +) }
        let rows = perDay.map { entry -> ShareCardContent.Row in
            let amount = entry.values.reduce(0, +)
            return ShareCardContent.Row(tool: entry.tool, amount: amount, share: perDay.count > 1 && total > 0 ? amount / total : nil)
        }
        let cumulative = perDay.map { entry in
            entry.values.reduce(into: [Double]()) { running, value in running.append((running.last ?? 0) + value) }
        }
        // A span of several months is set against several months of fees only where every spending assistant's
        // records reach its start (PlanValue.covers); a month's records under three months of fees would read a
        // third of the true ratio, so that card carries none.
        let start = days.first ?? input.now
        let covered = perDay.allSatisfy { entry in
            guard let provider = input.providers.first(where: { $0.tool == entry.tool }) else { return false }
            return PlanValue.covers(provider, from: start, firstUse: input.firstUse, calendar: input.calendar)
        }
        let plan = input.metric == .value
            ? PlanValue.make(values: rows.map { (tool: $0.tool, value: $0.amount) }, plans: input.plans, months: input.range.months, covered: covered)
            : nil
        let advice = ShareCardAdvice.line(tools: rows.map(\.tool), perDay: perDay, days: days, input: input)
        return ShareCardContent(metric: input.metric, range: input.range, days: days, rows: rows, cumulative: cumulative, total: total,
                                plan: plan, advice: advice, signature: signature(input.signature),
                                nothingTicked: !available.isEmpty && chosen.isEmpty)
    }

    /// The signature as the card prints it: one line, trimmed, at most `signatureLimit` characters; nil when empty.
    static func signature(_ raw: String) -> String? {
        let line = raw.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        return String(line.prefix(signatureLimit))
    }
}

// MARK: - The one line

/// The single line under a card's figures: something that really happened in the span, or a plain fact about it,
/// and never a sentence the data does not support.
///
/// In order: a limit window of an assistant on the card that reached 85 % (Advisor.modelNearlyOut) inside the
/// span, read from the drain log, with "switched to …" added only when the assistant's own daily top model was the
/// window's model up to that day and a different one on every day after it; otherwise the busiest day of the
/// span; otherwise, for a single day, the leading assistant's share of it. The drain log keeps seven days, so a
/// peak older than that is simply not known and the line falls through to the plain fact; a window the current
/// reading no longer carries has no name to give and is skipped the same way.
enum ShareCardAdvice {
    static let peakThreshold = Advisor.modelNearlyOut

    static func line(tools: [ToolID], perDay: [(tool: ToolID, values: [Double])], days: [Date], input: ShareCard.Input) -> String? {
        if let peak = peak(tools: tools, days: days, input: input) { return peak }
        return plainFact(perDay: perDay, days: days, input: input)
    }

    /// The fullest window of the card's assistants inside the span, as a sentence; nil when none reached the mark.
    static func peak(tools: [ToolID], days: [Date], input: ShareCard.Input) -> String? {
        guard let start = days.first else { return nil }
        var best: (tool: ToolID, window: LimitWindow, sample: DrainSample)?
        for tool in tools {
            for window in input.windows[tool] ?? [] where window.usedFraction != nil && !window.isComparison {
                let inSpan = (input.samples[DrainLog.Key(tool: tool, window: window.id)] ?? []).filter { $0.t >= start && $0.t <= input.now }
                guard let top = inSpan.map(\.used).max(), top >= peakThreshold,
                      let first = inSpan.first(where: { $0.used >= top - 0.0005 })
                else { continue }
                // The fullest wins; between equals a model's own window, whose story can say more, then the first.
                if let current = best {
                    let better = top > current.sample.used + 0.0005
                        || (abs(top - current.sample.used) <= 0.0005 && window.model != nil && current.window.model == nil)
                    if !better { continue }
                }
                best = (tool, window, first)
            }
        }
        guard let best else { return nil }
        let name = Advisor.name(best.window, of: best.tool)
        let percent = Int((min(1, best.sample.used) * 100).rounded())
        let day = dayName(best.sample.t, now: input.now, calendar: input.calendar)
        if let model = best.window.model, let to = switched(from: model, tool: best.tool, at: best.sample.t, days: days, input: input) {
            return L("%1$@ %2$@ hit %3$ld%% on %4$@; switched to %5$@ after.", best.tool.displayName, name, percent, day, to)
        }
        return L("%1$@ %2$@ peaked at %3$ld%% on %4$@.", best.tool.displayName, name, percent, day)
    }

    /// The model the assistant's spend moved to after `moment`, or nil unless the days say so plainly: its top
    /// model on the last day with spend up to and including that day was `model`, it spent on at least one day of
    /// the span after it, and no such day's top model was `model`. The name returned is the one most of those
    /// days led with.
    static func switched(from model: String, tool: ToolID, at moment: Date, days: [Date], input: ShareCard.Input) -> String? {
        guard let provider = input.providers.first(where: { $0.tool == tool }) else { return nil }
        let peakDay = input.calendar.startOfDay(for: moment)
        let inSpan = Set(days.map { CostHistory.key($0, calendar: input.calendar) })
        let spent = provider.daily90.filter { $0.cost > 0 && $0.topModel != nil && inSpan.contains(CostHistory.key($0.day, calendar: input.calendar)) }
        guard let before = spent.last(where: { $0.day <= peakDay }), let beforeModel = before.topModel, matches(beforeModel, model) else { return nil }
        let after = spent.filter { $0.day > peakDay }.compactMap(\.topModel)
        guard !after.isEmpty, !after.contains(where: { matches($0, model) }) else { return nil }
        var counts: [String: Int] = [:]
        for id in after { counts[id, default: 0] += 1 }
        guard let leader = after.first(where: { counts[$0] == counts.values.max() }), leader != CostShare.other else { return nil }
        let display = ModelNames.display(leader)
        let prefix = tool.displayName + " "
        return display.hasPrefix(prefix) && display.count > prefix.count ? String(display.dropFirst(prefix.count)) : display
    }

    /// Whether a model id names the window's model ("claude-opus-5" and "Opus").
    static func matches(_ id: String, _ model: String) -> Bool {
        ModelNames.display(id).range(of: model, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            || id.range(of: model, options: .caseInsensitive) != nil
    }

    /// The busiest day of a span longer than one, or for a single day the leading assistant's part of it.
    static func plainFact(perDay: [(tool: ToolID, values: [Double])], days: [Date], input: ShareCard.Input) -> String? {
        let totals = days.indices.map { index in perDay.reduce(0) { $0 + $1.values[index] } }
        guard totals.contains(where: { $0 > 0 }) else { return nil }
        if days.count > 1, let busiest = totals.indices.max(by: { (totals[$0], $1) < (totals[$1], $0) }) {
            return L("Busiest day: %1$@, %2$@.", dayName(days[busiest], now: input.now, calendar: input.calendar),
                     ShareCardContent.amount(totals[busiest], metric: input.metric, cents: false))
        }
        let whole = totals.reduce(0, +)
        guard perDay.count > 1, whole > 0,
              let leader = perDay.max(by: { $0.values.reduce(0, +) < $1.values.reduce(0, +) })
        else { return nil }
        return L("%1$@ was %2$ld%% of it.", leader.tool.displayName, Int((leader.values.reduce(0, +) / whole * 100).rounded()))
    }

    /// A weekday inside the last week ("Thursday"), else the date ("Sep 18"): a card is read days after it is
    /// posted, so it never says "today".
    static func dayName(_ date: Date, now: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: Localization.current)
        let age = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        formatter.setLocalizedDateFormatFromTemplate(age < 7 ? "EEEE" : "MMMd")
        return formatter.string(from: date)
    }
}

// MARK: - The offer after an update

/// When the app offers the card by itself: once per version, after an update rather than a first install, to
/// someone who has used their assistants on at least `minimumActiveDays` of the last thirty, and never while the
/// figures are hidden for a screen share, while a full-screen app has the display, or while another of the app's
/// own windows or a request is up. Pure, so the rule is pinned without a window (ShareCardOfferRule).
enum ShareCardOffer {
    /// A week of use: fewer days make a card of a quiet month, which is not one anybody wants to post.
    static let minimumActiveDays = 7

    enum Decision: Equatable {
        /// Open the card now.
        case show
        /// Not now; ask again shortly.
        case wait
        /// Not for this version: nothing pending, switched off, spend hidden, or not enough use to show.
        case drop
    }

    /// Whether this launch is the first of a new version on a Mac that ran an earlier one. `previous` is the
    /// version the last launch recorded; builds before 0.9.0 recorded none, so an install that has already been
    /// through the Welcome (or the hook offer before it) counts as updated from one of those.
    static func updated(previous: String?, current: String, existingInstall: Bool) -> Bool {
        guard let previous else { return existingInstall }
        return previous != current
    }

    static func decide(pending: String?, current: String, enabled: Bool, showSpend: Bool, costReady: Bool, activeDays: Int,
                       hidesFigures: Bool, fullScreen: Bool, busy: Bool) -> Decision {
        guard pending == current, enabled, showSpend else { return .drop }
        guard costReady else { return .wait }
        guard activeDays >= minimumActiveDays else { return .drop }
        return hidesFigures || fullScreen || busy ? .wait : .show
    }

    /// What stays pending once the card has opened, whichever way it was asked for: nothing, when it was this
    /// version's. The offer exists to put the card in front of the reader once, and a card they opened by hand
    /// before it fired has done that; left pending, the loop would wait out the window and open the card again
    /// half a minute after they closed it. An offer left over from another version is not this launch's to
    /// spend, and `decide` drops it.
    static func afterOpening(pending: String?, current: String) -> String? {
        pending == current ? nil : pending
    }

    /// Days in the series with anything spent.
    static func activeDays(_ daily: [DailySpend]) -> Int {
        daily.filter { $0.cost > 0 || $0.tokens > 0 }.count
    }
}
