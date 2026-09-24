import SwiftUI

/// Today's spend and the six days before it, across the assistants the Cost card carries (CostSelection), for the
/// Simple panel's Cost row: a strip of seven bars beside its figure, the days in words when the pointer rests on the
/// row, and the chart with each day split by assistant when the row is opened, so nothing about the week is only
/// on hover.
///
/// It is the Cost card's own data and nothing new: each carried assistant's per-day series (ProviderCost.daily),
/// which is what the card's Today and Yesterday ranges are built from, priced the way the card prices them and
/// named by the same sources (docs/accuracy.md, *The last seven days*). Seven calendar days ending today, which is
/// not the card's Week: that range starts when Claude Code's weekly window opened, so the two totals differ and
/// each says which it is.
struct WeekSpend: Equatable, Sendable {
    /// One assistant's part of a day.
    struct Part: Equatable, Sendable {
        let tool: ToolID
        let cost: Double
        let tokens: Int
    }

    struct Day: Equatable, Sendable, Identifiable {
        let day: Date
        /// In the carried assistants' order, the ones with nothing that day left out.
        let parts: [Part]
        var id: Date { day }

        var cost: Double { parts.reduce(0) { $0 + $1.cost } }
        var tokens: Int { parts.reduce(0) { $0 + $1.tokens } }
    }

    static let length = 7

    /// Oldest first, the last one today.
    let days: [Day]

    var today: Day? { days.last }
    var cost: Double { days.reduce(0) { $0 + $1.cost } }
    var tokens: Int { days.reduce(0) { $0 + $1.tokens } }

    /// The week for the carried assistants, or nil when there are none or none of them spent anything in it: a
    /// row of seven empty bars would say "nothing" in a way the row's own figure already does. Days are matched by
    /// their "2026-09-14" key rather than by Date, as the dashboard matches them, so a zone whose daylight saving
    /// starts at midnight still lines each day up with its record.
    static func of(_ selection: CostSelection, now: Date, calendar: Calendar = .current) -> WeekSpend? {
        guard !selection.isEmpty else { return nil }
        let today = calendar.startOfDay(for: now)
        let dates = (0..<length).reversed().map { calendar.startOfDay(for: calendar.date(byAdding: .day, value: -$0, to: today) ?? today) }
        let series = selection.providers.map { provider in
            (tool: provider.tool, byKey: Dictionary(provider.daily.map { (CostHistory.key($0.day, calendar: calendar), $0) }, uniquingKeysWith: { first, _ in first }))
        }
        let days = dates.map { date -> Day in
            let key = CostHistory.key(date, calendar: calendar)
            let parts = series.compactMap { entry -> Part? in
                guard let spend = entry.byKey[key], spend.cost > 0 || spend.tokens > 0 else { return nil }
                return Part(tool: entry.tool, cost: spend.cost, tokens: spend.tokens)
            }
            return Day(day: date, parts: parts)
        }
        guard days.contains(where: { $0.cost > 0 || $0.tokens > 0 }) else { return nil }
        return WeekSpend(days: days)
    }

    /// The quantity the bars stand for in the card's unit: tokens under Tokens, dollars otherwise, since a rate
    /// per million tokens has no height to give a day (it does not add up across days).
    static func value(_ cost: Double, _ tokens: Int, mode: CostCardMode) -> Double {
        mode == .tokens ? Double(tokens) : cost
    }

    func value(_ day: Day, mode: CostCardMode) -> Double { Self.value(day.cost, day.tokens, mode: mode) }

    /// The tallest day, the height the others are drawn against; never zero, so an empty day is a baseline.
    func peak(mode: CostCardMode) -> Double {
        max(days.map { value($0, mode: mode) }.max() ?? 0, 0.0001)
    }

    /// A figure in the bars' unit: "$118" or "7.4M".
    static func figure(cost: Double, tokens: Int, mode: CostCardMode) -> String {
        mode == .tokens ? Money.tokens(tokens).replacingOccurrences(of: " tokens", with: "") : Money.dollars(cost, cents: false)
    }

    /// "Today $118 · 7 days $1,420", the line over the chart and the first line of the tooltip.
    func headline(mode: CostCardMode) -> String {
        L("Today %1$@ · 7 days %2$@", Self.figure(cost: today?.cost ?? 0, tokens: today?.tokens ?? 0, mode: mode),
          Self.figure(cost: cost, tokens: tokens, mode: mode))
    }

    /// One day in words: "Sep 22 · $548 · Claude Code $494, Cursor $54", the split only where two or more
    /// assistants spent that day, since one would repeat the total.
    func line(_ day: Day, mode: CostCardMode, now: Date, calendar: Calendar = .current) -> String {
        var parts = [ResetText.dayPhrase(day.day, now: now, calendar: calendar), Self.figure(cost: day.cost, tokens: day.tokens, mode: mode)]
        if day.parts.count > 1 {
            parts.append(day.parts.map { "\($0.tool.productName) \(Self.figure(cost: $0.cost, tokens: $0.tokens, mode: mode))" }.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    /// The week in words, newest first, for the row's tooltip.
    func tooltip(mode: CostCardMode, now: Date, calendar: Calendar = .current) -> String {
        ([L("Last 7 days"), headline(mode: mode)] + days.reversed().map { line($0, mode: mode, now: now, calendar: calendar) })
            .joined(separator: "\n")
    }

    /// The week as VoiceOver reads it: the headline, then each day, oldest first as the bars run.
    func spoken(mode: CostCardMode, now: Date, calendar: Calendar = .current) -> String {
        Spoken.line(headline(mode: mode), days.map { line($0, mode: mode, now: now, calendar: calendar) }.joined(separator: "; "))
    }
}

/// The seven bars beside the Cost row's figure: one per day, oldest on the left, today's brightest. Drawn in the
/// caption's grey rather than the assistants' colours, which at this size would be a smear; the split is in the
/// opened chart. An empty day is a one-point baseline, so the strip always shows seven days rather than fewer.
/// Pinned left to right like every other time axis on the panel.
struct WeekSpendStrip: View {
    let week: WeekSpend
    let mode: CostCardMode

    static let size = CGSize(width: 34, height: 14)

    var body: some View {
        let peak = week.peak(mode: mode)
        let contrast = AccessibilityDisplay.shared.contrast
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(week.days) { day in
                let isToday = day.id == week.today?.id
                RoundedRectangle(cornerRadius: 1)
                    .fill(.white.opacity(isToday ? 0.95 : contrast ? 0.75 : 0.5))
                    .frame(width: 3, height: max(1, Self.size.height * CGFloat(week.value(day, mode: mode) / peak)))
            }
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .bottomLeading)
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityHidden(true)
    }
}

/// The week opened under the Cost row: the headline, then seven columns, each a bar stacked by assistant in the
/// assistants' own colours with the day's initial under it, today's in the text colour and the rest in the
/// caption's. Hovering a bar names its day, its total and its split; VoiceOver reads the whole week as one element.
struct WeekSpendChart: View {
    let week: WeekSpend
    let mode: CostCardMode
    var now = Date()

    static let height: CGFloat = 40

    var body: some View {
        let peak = week.peak(mode: mode)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("Last 7 days")).font(.caption.weight(.semibold))
                Spacer(minLength: 8)
                Text(week.headline(mode: mode)).font(.caption).foregroundStyle(Caption.style).monospacedDigit().lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(week.days) { day in
                    let isToday = day.id == week.today?.id
                    VStack(spacing: 3) {
                        column(day, peak: peak)
                            .frame(height: Self.height, alignment: .bottom)
                        Text(verbatim: day.day.formatted(.dateTime.weekday(.narrow)))
                            .font(.caption2.weight(isToday ? .bold : .regular))
                            .foregroundStyle(isToday ? AnyShapeStyle(.primary) : Caption.style)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .help(week.line(day, mode: mode, now: now))
                }
            }
            .environment(\.layoutDirection, .leftToRight)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Last 7 days"))
        .accessibilityValue(week.spoken(mode: mode, now: now))
    }

    /// One day's bar, its assistants stacked in the card's order from the bottom, with a hairline between two so
    /// neighbouring colours stay apart; an empty day is a baseline, grey enough to clear 3:1 on the black panel
    /// (white at 0.4 is about 3.6:1), since it is the day's only mark.
    private func column(_ day: WeekSpend.Day, peak: Double) -> some View {
        let total = week.value(day, mode: mode)
        let height = Self.height * CGFloat(total / peak)
        return VStack(spacing: 1) {
            if total <= 0 {
                Capsule().fill(.white.opacity(AccessibilityDisplay.shared.contrast ? 0.6 : 0.4)).frame(height: 2)
            } else {
                ForEach(Array(day.parts.reversed().enumerated()), id: \.offset) { _, part in
                    Rectangle()
                        .fill(part.tool.color)
                        .frame(height: max(1.5, height * CGFloat(WeekSpend.value(part.cost, part.tokens, mode: mode) / total)))
                }
            }
        }
        .frame(maxWidth: 18)
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
    }
}
