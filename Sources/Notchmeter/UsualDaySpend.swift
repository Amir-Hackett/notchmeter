import Foundation

/// A day's dollars against a usual day: the median of the days in the thirty before today that spent anything on
/// the same thing. It is what fills a ring for a seat or a login whose vendor publishes no limit: Cursor's
/// *Today's spend* and its dead model meters (CursorProvider.spendToday, withModelSpend), and Claude's on a login
/// Anthropic sends only uncapped extra usage for (ClaudeProvider.withSpendRings).
///
/// A usual day is the median of the active days, not the mean over every calendar day: weekends at $0 pulled a
/// mean down, so an ordinary workday read high against it, and one heavy day pulled it up for a month. The median
/// answers the question the ring asks, "is today a normal day of work?", and is moved by neither.
///
/// The window is a comparison, not a limit (`LimitWindow.isComparison`): it paces and never runs out, warns or
/// notifies, and it is marked as worked out here. The ring fills at a usual day's spend; the digits keep
/// counting past it. Nil until there is a usual day to compare with.
enum UsualDaySpend {
    static func window(id: String, label: WindowLabel, days: [Date: CostHistory.Record], model: String? = nil,
                       hiddenByDefault: Bool = false, now: Date = Date(), calendar: Calendar = .current,
                       spent: (CostHistory.Record) -> Double = { $0.cost }) -> LimitWindow? {
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -30, to: today),
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
              let usual = usualDay(days, from: start, before: today, spent: spent) else { return nil }
        let todaySpent = days[today].map(spent) ?? 0
        let percent = todaySpent / usual * 100
        return LimitWindow(id: id, label: label, usedFraction: min(max(todaySpent / usual, 0), 1), resetsAt: tomorrow,
                           note: L("%1$@ of a usual %2$@ day", Money.dollars(todaySpent), Money.dollars(usual, cents: false)),
                           periodDuration: tomorrow.timeIntervalSince(today), model: model, source: .localEstimate,
                           hiddenByDefault: hiddenByDefault, rawUsedPercent: percent > 100 ? percent : nil, amountUSD: todaySpent,
                           comparison: true)
    }

    /// The median of the days in `start..<end` that spent anything; nil when none did.
    static func usualDay(_ days: [Date: CostHistory.Record], from start: Date, before end: Date,
                         spent: (CostHistory.Record) -> Double = { $0.cost }) -> Double? {
        let active = days.filter { $0.key >= start && $0.key < end }.map { spent($0.value) }.filter { $0 > 0 }.sorted()
        guard !active.isEmpty else { return nil }
        let middle = active.count / 2
        return active.count % 2 == 1 ? active[middle] : (active[middle - 1] + active[middle]) / 2
    }
}
