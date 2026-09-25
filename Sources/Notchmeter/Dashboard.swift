import AppKit
import Charts
import SwiftUI

/// The spans the dashboard offers. The week is the live Claude weekly window's (CostEngine.weekStart), so the bars
/// and the limit beneath them describe the same seven days.
enum DashboardRange: String, CaseIterable, Identifiable, Sendable {
    case week, thirtyDays, ninetyDays

    var id: Self { self }

    var title: String {
        switch self {
        case .week: L("This week")
        case .thirtyDays: L("30 days")
        case .ninetyDays: L("90 days")
        }
    }

    var costRange: CostRange {
        switch self {
        case .week: .week
        case .thirtyDays: .last30Days
        case .ninetyDays: .last90Days
        }
    }
}

/// Everything the dashboard draws, built from what the store already holds: the carried assistants' daily spend
/// (ProviderCost), their range totals, and the live limit windows. Nothing is fetched or priced here, and nothing
/// leaves this account; the model only rearranges figures the Cost card and the meters already show.
///
/// Totals, models and projects are each provider's own range figures, so they agree with the Cost card to the
/// cent. The bars are day-aligned, so the first bar of the week can hold spend from before the window opened.
struct DashboardModel: Equatable {
    struct Bar: Identifiable, Equatable {
        let day: Date
        let tool: ToolID
        let cost: Double
        var id: String { "\(tool.rawValue)/\(Int(day.timeIntervalSince1970))" }
    }

    struct Day: Identifiable, Equatable {
        let day: Date
        let total: Double
        /// The week's first day, cut at the moment the window opened: its bar is part of that day, not all of it.
        var partial = false
        /// In the carried assistants' order, zero-cost entries left out.
        let byTool: [(tool: ToolID, cost: Double)]
        var id: Date { day }

        static func == (lhs: Day, rhs: Day) -> Bool {
            lhs.day == rhs.day && lhs.total == rhs.total && lhs.partial == rhs.partial && lhs.byTool.map(\.tool) == rhs.byTool.map(\.tool) && lhs.byTool.map(\.cost) == rhs.byTool.map(\.cost)
        }
    }

    let range: DashboardRange
    let tools: [ToolID]
    let days: [Day]
    let total: Double
    let today: Double
    /// The range's spend over its calendar days, counted from the first day with any spend so a history that
    /// starts part-way through ninety days is not averaged against days before it existed. nil with no spend.
    let dailyAverage: Double?
    /// The day the average is counted from when that is later than the range's first day (the history starts
    /// inside the range); nil when the average spans the whole range.
    let averageSince: Date?
    /// The costliest day in the range; nil when nothing was spent.
    let peak: Day?
    let models: [CostShare]
    let projects: [CostShare]
    let sources: [(tool: ToolID, source: CostSource)]

    var bars: [Bar] {
        days.flatMap { day in day.byTool.map { Bar(day: day.day, tool: $0.tool, cost: $0.cost) } }
    }

    var isEmpty: Bool { total <= 0 && days.allSatisfy { $0.total <= 0 } }

    static func == (lhs: DashboardModel, rhs: DashboardModel) -> Bool {
        lhs.range == rhs.range && lhs.tools == rhs.tools && lhs.days == rhs.days && lhs.total == rhs.total && lhs.today == rhs.today
            && lhs.dailyAverage == rhs.dailyAverage && lhs.averageSince == rhs.averageSince && lhs.peak == rhs.peak && lhs.models == rhs.models && lhs.projects == rhs.projects
            && lhs.sources.map(\.tool) == rhs.sources.map(\.tool) && lhs.sources.map(\.source) == rhs.sources.map(\.source)
    }

    /// `firstRecorded` is the earliest day the durable history holds spend for (CostSummary.firstUse), which can lie
    /// before the ninety days the series carry: without it a return from a long break averages over the days since.
    init(providers: [ProviderCost], range: DashboardRange, weekStart: Date, firstRecorded: Date? = nil, now: Date = Date(),
         calendar: Calendar = .current) {
        self.range = range
        tools = providers.map(\.tool)
        sources = providers.map { (tool: $0.tool, source: $0.source) }

        let today = calendar.startOfDay(for: now)
        let first: Date
        switch range {
        case .week: first = calendar.startOfDay(for: weekStart)
        case .thirtyDays: first = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        case .ninetyDays: first = calendar.date(byAdding: .day, value: -89, to: today) ?? today
        }
        let count = max(1, (calendar.dateComponents([.day], from: first, to: today).day ?? 0) + 1)
        // Days are matched by their "2026-09-14" key, never by Date: in a zone whose DST starts at midnight the
        // day begins at 01:00, and a date stepped from it no longer equals the series' own key for later days.
        let dates = (0..<count).map { calendar.startOfDay(for: calendar.date(byAdding: .day, value: $0, to: first) ?? first) }
        let keys = dates.map { CostHistory.key($0, calendar: calendar) }
        var grid: [String: [ToolID: Double]] = [:]
        var historyStart = firstRecorded.map { CostHistory.key($0, calendar: calendar) }
        for provider in providers {
            for spend in provider.daily90 where spend.cost > 0 {
                let key = CostHistory.key(spend.day, calendar: calendar)
                grid[key, default: [:]][provider.tool, default: 0] += spend.cost
                historyStart = min(historyStart ?? key, key)
            }
        }
        var clipped = false
        if range == .week, let firstKey = keys.first {
            // The week's first day is cut at the moment the window opened, so the bars add up to the Total tile and
            // no day can be larger than the week: what a provider spent in the window, less its later whole days.
            for provider in providers {
                let later = keys.dropFirst().reduce(0) { $0 + (grid[$1]?[provider.tool] ?? 0) }
                let inWindow = max(0, provider.totals(.week).cost - later)
                if let dayAligned = grid[firstKey]?[provider.tool] {
                    grid[firstKey]?[provider.tool] = min(dayAligned, inWindow)
                    clipped = clipped || inWindow < dayAligned - 0.005
                }
            }
        }
        days = zip(dates, keys).enumerated().map { index, pair in
            let (date, key) = pair
            let costs = grid[key] ?? [:]
            let byTool = providers.compactMap { provider -> (tool: ToolID, cost: Double)? in
                guard let cost = costs[provider.tool], cost > 0 else { return nil }
                return (tool: provider.tool, cost: cost)
            }
            return Day(day: date, total: byTool.reduce(0) { $0 + $1.cost }, partial: index == 0 && clipped, byTool: byTool)
        }

        var totals = RangeTotals()
        var todayTotals = RangeTotals()
        for provider in providers {
            totals.add(provider.totals(range.costRange))
            todayTotals.add(provider.totals(.today))
        }
        total = totals.cost
        self.today = todayTotals.cost
        models = totals.models
        projects = totals.projects

        peak = days.filter { $0.total > 0 }.max { ($0.total, $1.day) < ($1.total, $0.day) }
        // Every calendar day of the range counts, quiet ones included; only days before the history's first spend
        // anywhere in the last ninety are left out, because nothing was being recorded then.
        if let historyStart, total > 0 {
            let span = keys.filter { $0 >= historyStart }.count
            dailyAverage = span > 0 ? total / Double(span) : nil
            averageSince = span > 0 && span < keys.count ? dates[keys.count - span] : nil
        } else {
            dailyAverage = nil
            averageSince = nil
        }
    }
}

/// One live limit as the dashboard states it: how much is gone, how much of the window is, and what is left to
/// spend per day (or per hour, for a window shorter than two days) if it is to last to the reset.
struct DashboardLimit: Identifiable, Equatable {
    enum Unit: Equatable { case day, hour }

    let tool: ToolID
    let window: LimitWindow
    let used: Double
    /// Where an even burn would sit now; nil without a period.
    let elapsed: Double?
    let status: Pace.Status?
    /// The share of the window left to spend per unit of time until the reset; nil once used up or without a reset.
    let allowance: Double?
    let unit: Unit
    /// Less than one day (or hour) is left: the remainder is stated as what is left, not as a rate per unit that
    /// the window will not last to see.
    let lastUnit: Bool
    /// The pace note the meter row shows, the run-out interval in place of a point when the drain log has one; nil
    /// for an unhurried or spent window, where a projection past 100% says nothing a hard limit can do.
    let note: String?
    /// "Last reading 10:52 PM · may be out of date", when the tool has stopped answering and this is its cached reading.
    let staleLine: String?

    var id: String { "\(tool.rawValue)/\(window.id)" }

    init?(tool: ToolID, window: LimitWindow, runOut: RunOutInterval?, format: TimeFormatPreference, staleSince: Date? = nil, now: Date = Date()) {
        guard let used = window.usedFraction else { return nil }
        // A reset that has already passed means the figure describes a window that is over.
        if let resetsAt = window.resetsAt, resetsAt <= now { return nil }
        self.tool = tool
        self.window = window
        self.used = used
        let period = window.periodDuration
        unit = (period ?? Period.week) >= 2 * 86400 ? .day : .hour
        if let resetsAt = window.resetsAt, let period {
            elapsed = Pace.elapsedFraction(resetsAt: resetsAt, period: period, now: now)
            status = Pace.evaluate(usedFraction: used, resetsAt: resetsAt, period: period, now: now)?.status
        } else {
            elapsed = nil
            status = nil
        }
        if let resetsAt = window.resetsAt, used < 1, resetsAt > now {
            let units = resetsAt.timeIntervalSince(now) / (unit == .day ? 86400 : 3600)
            allowance = (1 - used) / max(units, 1)
            lastUnit = units < 1
        } else {
            allowance = nil
            lastUnit = false
        }
        note = used < 1 && status != .ahead ? MeterRow.paceNote(window: window, runOut: runOut, format: format, now: now)?.text : nil
        staleLine = staleSince.map { StaleReading.line(fetchedAt: $0, timeFormat: format, now: now) }
    }

    /// "About 4% a day keeps it to the reset", the sentence under the bar.
    var allowanceLine: String? {
        guard used < 1 else { return L("Used up until the reset") }
        // An untouched window has nothing to ration: "20% a day" over a window at 0% says nothing.
        guard used > 0, let allowance else { return nil }
        let percent = allowance * 100
        let figure = percent >= 10 || percent == 0 ? "\(Int(percent.rounded()))" : String(format: "%.1f", percent)
        if lastUnit { return L("%@%% left to the reset", figure) }
        return unit == .day ? L("About %@%% a day lasts to the reset", figure) : L("About %@%% an hour lasts to the reset", figure)
    }

    /// Every window with a published fraction on the tools shown, in their order, less the ones hidden in Settings,
    /// floor included (WindowFloor): the set is `Preferences.shownWindows(of:)`, the same one the card, the rings
    /// and the menu bar draw from, so a preference that hides every window of a tool lists its first window here
    /// as it does there, rather than a tool with no limits at all.
    @MainActor
    static func all(store: UsageStore, now: Date = Date()) -> [DashboardLimit] {
        store.visibleTools.flatMap { tool -> [DashboardLimit] in
            let status = store.status(tool)
            guard let reading = status.reading else { return [] }
            return store.prefs.shownWindows(of: reading).compactMap { window in
                DashboardLimit(tool: tool, window: window, runOut: store.runOut(for: tool, window: window),
                               format: store.prefs.timeFormat, staleSince: status.staleReading?.fetchedAt, now: now)
            }
        }
    }
}

extension ToolID {
    /// The identity colours stepped for a window's own surface rather than the black notch. The light window
    /// takes the identity's own light value (`ToolID.identity`, 4.5:1 or better on white, which also clears the
    /// 3:1 a chart mark needs); the dark window, at #1E1E1E rather than black, takes a step of its own for the
    /// three older hues, whose notch values fall short of it. Both sets pass the dataviz validator (lightness band,
    /// chroma, CVD and normal-vision separation, contrast) against their surface.
    var chartColor: Color {
        let dark: UInt32 = switch self {
        case .claude: 0xCC7555
        case .cursor: 0x8C74EA
        case .codex: 0x34A874
        case .gemini, .antigravity, .copilot, .kimi: identity.dark  // each above 5.8:1 on the dark window as it is
        // The notch's violet sits on top of Cursor's periwinkle once both are stepped for a window (1.6 under
        // deuteranopia), so OpenCode's window step leans to the orchid side of the same purple: 17.9 normal and 7.9
        // CVD from the dark set at 3.55:1 on its surface; the light window takes the identity's own light value, 5.5:1
        // on white. The Dashboard names every series in its legend, which is the secondary encoding the 6–8 CVD
        // band asks for.
        case .opencode: 0xC818B8
        }
        return Color(nsColor: .adaptive(light: identity.light, dark: dark))
    }
}

struct DashboardView: View {
    let store: UsageStore
    @State private var range: DashboardRange
    @State private var selectedDay: Date?

    /// Inside Settings, whose pane already carries the title: the header keeps its line, picker and refresh only.
    let embedded: Bool
    /// For the header's share button (NotchActions.openShareCard); nil in a render, which has no window to open.
    let actions: NotchActions?

    init(store: UsageStore, range: DashboardRange = .week, embedded: Bool = false, actions: NotchActions? = nil) {
        self.store = store
        self.embedded = embedded
        self.actions = actions
        _range = State(initialValue: range)
    }

    private var weekStart: Date {
        store.cost?.week?.start ?? Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start ?? Calendar.current.startOfDay(for: Date())
    }

    var body: some View {
        // Show spend off in Settings hides every dollar, here as on the panel; the store keeps its last scan either way.
        let spendShown = store.prefs.showSpend
        let model = DashboardModel(providers: spendShown ? store.costSelection.providers : [], range: range, weekStart: weekStart,
                                   firstRecorded: store.cost?.firstUse)
        let limits = DashboardLimit.all(store: store)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if !spendShown {
                    Text(L("Spend is hidden in Settings, so only limits are shown."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.isEmpty && limits.isEmpty {
                    // With spend hidden the account may well have some: the note above says so, the empty state
                    // would claim nothing was ever used.
                    if spendShown { empty }
                } else {
                    if !model.isEmpty {
                        tiles(model)
                        // The value framing under the tiles (PlanValue): the range's API-equivalent dollars against
                        // what the plans behind them cost, said only where both sides are known, and marked as the
                        // estimate it is. The week has no fee of its own, so its line is the thirty days'.
                        if let value = store.planValueLine(for: range.costRange) {
                            Text(value.keepingHyphensWhole)
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        chartSection(model)
                    }
                    if !limits.isEmpty { limitsSection(limits) }
                    if !model.isEmpty { breakdownSection(model) }
                    if !model.isEmpty { sourcesFootnote(model) }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                if !embedded { Text(L("Usage")).font(.title2.weight(.semibold)) }
                Text(updatedLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker(L("Range"), selection: $range) {
                ForEach(DashboardRange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button {
                store.refreshAll(interactive: true)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(L("Refresh now"))
            .accessibilityLabel(L("Refresh now"))
            .disabled(store.costScanning)
            if let actions {
                Button {
                    actions.openShareCard(.dashboard)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .help(L("Share usage card…"))
                .accessibilityLabel(L("Share usage card…"))
            }
        }
    }

    private var updatedLine: String {
        let scan = store.prefs.showSpend ? store.cost?.scannedAt : store.lastUpdated
        guard let scanned = scan else { return L("Reading this account's usage…") }
        return L("This account only · updated %@", ResetText.time(scanned, format: store.prefs.timeFormat))
    }

    private var empty: some View {
        ContentUnavailableView(L("No usage recorded yet"), systemImage: "chart.bar",
                               description: Text(L("Spend and limits appear here once an assistant on this account has been used.")))
            .frame(maxWidth: .infinity, minHeight: 280)
    }

    // MARK: Tiles

    private func tiles(_ model: DashboardModel) -> some View {
        let peakValue = model.peak.map { Money.dollars($0.total, cents: false) } ?? "—"
        let peakCaption = model.peak.map { ResetText.dayPhrase($0.day, now: Date(), calendar: .current) } ?? ""
        let total = tile(L("Total"), Money.dollars(model.total, cents: false), caption: range.title)
        // Named by its first day where the history starts inside the range, so a 90-day average over 39 days of
        // history does not read as spread across all ninety.
        let averageCaption = model.averageSince.map { L("per day since %@", ResetText.dayPhrase($0, now: Date(), calendar: .current)) } ?? L("per calendar day")
        let average = tile(L("Daily average"), model.dailyAverage.map { Money.dollars($0, cents: false) } ?? "—", caption: averageCaption)
        let peak = tile(L("Peak day"), peakValue, caption: peakCaption)
        let today = tile(L("Today"), Money.dollars(model.today, cents: false), caption: "")
        // One row where the captions fit on a line, two rows of two where a narrow window or a longer language
        // would cut them short.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { total; average; peak; today }
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow { total; average }
                GridRow { peak; today }
            }
        }
    }

    private func tile(_ title: String, _ value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(caption.isEmpty ? " " : caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1).fixedSize()
        }
        .frame(minWidth: 110, maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
        .accessibilityElement(children: .combine)
    }

    // MARK: Chart

    private func chartSection(_ model: DashboardModel) -> some View {
        let selected = selectedDay.flatMap { day in model.days.first { Calendar.current.isDate($0.day, inSameDayAs: day) } }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle(L("Daily spend"))
                Spacer()
                // The average is named up here with its own dashed swatch rather than on the line, where a label
                // sits over whichever bars are tallest at that end of the chart.
                HStack(spacing: 12) {
                    if let average = model.dailyAverage {
                        HStack(spacing: 5) {
                            Line().stroke(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 2])).frame(width: 14, height: 1)
                            Text(L("avg %@", Money.dollars(average, cents: false))).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if model.tools.count > 1 { legend(model.tools) }
                }
            }
            // Rebuilt per range: Swift Charts in this hosting view kept drawing the previous range's marks and scale
            // until the window was resized, while the tiles above had already moved on.
            DailySpendChart(model: model, selected: selected, selection: $selectedDay)
                .id(range)
                .frame(height: 220)
            Text(selected.map(Self.dayLine) ?? L("Hover a bar for that day's figures."))
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    private static func dayLine(_ day: DashboardModel.Day) -> String {
        var parts = [ResetText.dayPhrase(day.day, now: Date(), calendar: .current), Money.dollars(day.total)]
        // The Today tile counts the whole day; this bar only what came after the week reset.
        if day.partial { parts.append(L("since the week reset")) }
        if day.byTool.count > 1 {
            parts += day.byTool.map { "\($0.tool.displayName) \(Money.dollars($0.cost))" }
        }
        return parts.joined(separator: " · ")
    }

    private func legend(_ tools: [ToolID]) -> some View {
        HStack(spacing: 12) {
            ForEach(tools, id: \.self) { tool in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(tool.chartColor).frame(width: 10, height: 10)
                    Text(tool.displayName).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Limits

    private func limitsSection(_ limits: [DashboardLimit]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(L("Limits"))
            VStack(spacing: 0) {
                ForEach(Array(limits.enumerated()), id: \.element.id) { index, limit in
                    if index > 0 { Divider() }
                    LimitRow(limit: limit, timeFormat: store.prefs.timeFormat)
                        .padding(.vertical, 10)
                }
            }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
        }
    }

    // MARK: Breakdown

    private func breakdownSection(_ model: DashboardModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(L("Where it went"))
            HStack(alignment: .top, spacing: 16) {
                ShareList(title: L("By model"), shares: model.models, total: model.total, name: ModelNames.display)
                // Cursor's export names no folder, so its spend has no project: said as a row, or the shares stop
                // short of 100% with nothing to say where the rest went.
                ShareList(title: L("By project"), shares: model.projects, total: model.total, name: { $0 }, remainder: L("No project"))
            }
        }
    }

    private func sourcesFootnote(_ model: DashboardModel) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(model.sources, id: \.tool) { entry in
                Text(entry.source == .billingExport
                     ? L("%@ as billed, from its usage export", entry.tool.displayName)
                     : entry.source.provenance(of: entry.tool))
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.headline)
    }
}

/// A horizontal line through the middle of its frame, for the average's legend swatch.
private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}

/// Stacked daily bars, one colour per assistant, with a dashed line at the daily average and a hover rule.
private struct DailySpendChart: View {
    let model: DashboardModel
    let selected: DashboardModel.Day?
    @Binding var selection: Date?

    /// The whole span, the week included when only part of it has happened: seven slots whatever day it is, so a
    /// Monday's one bar is a seventh of the width and the empty days read as still to come.
    private var xDomain: ClosedRange<Date> {
        let calendar = Calendar.current
        guard let first = model.days.first?.day, let last = model.days.last?.day else { return Date()...Date() }
        let end = model.range == .week ? max(last, calendar.date(byAdding: .day, value: 6, to: first) ?? last) : last
        return first...(calendar.date(byAdding: .day, value: 1, to: end) ?? end)
    }

    /// Every seventh day (thirty days) or fourteenth (ninety) counted back from today, so the last label is
    /// today's rather than one that lands clipped against the right edge.
    private var axisDays: [Date] {
        let step = model.range == .thirtyDays ? 7 : 14
        // Today itself is left unlabelled: its slot is the chart's last, and a label there is cut by the edge.
        return model.days.reversed().enumerated().compactMap { $0.offset % step == 0 && $0.offset > 0 ? $0.element.day : nil }.reversed()
    }

    var body: some View {
        Chart {
            ForEach(model.bars) { bar in
                BarMark(x: .value(L("Day"), bar.day, unit: .day), y: .value(L("Spend"), bar.cost))
                    .foregroundStyle(by: .value(L("Assistant"), bar.tool.displayName))
                    .opacity(selected.map { Calendar.current.isDate(bar.day, inSameDayAs: $0.day) } ?? true ? 1 : 0.45)
                    .accessibilityLabel(ResetText.dayPhrase(bar.day, now: Date(), calendar: .current))
                    .accessibilityValue("\(bar.tool.displayName) \(Money.dollars(bar.cost))")
            }
            if let average = model.dailyAverage {
                RuleMark(y: .value(L("Daily average"), average))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartForegroundStyleScale(domain: model.tools.map(\.displayName), range: model.tools.map(\.chartColor))
        .chartLegend(.hidden)
        .chartXSelection(value: $selection)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let amount = value.as(Double.self) { Text(Money.dollars(amount, cents: false)) }
                }
            }
        }
        .chartXScale(domain: xDomain)
        .chartXAxis {
            if model.range == .week {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated).day(), centered: true)
                }
            } else {
                AxisMarks(values: axisDays) { _ in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
        }
        .accessibilityLabel(L("Daily spend"))
        .accessibilityValue(model.days.filter { $0.total > 0 }.map {
            "\(ResetText.dayPhrase($0.day, now: Date(), calendar: .current)) \(Money.dollars($0.total, cents: false))"
        }.joined(separator: ", "))
    }
}

private struct LimitRow: View {
    let limit: DashboardLimit
    let timeFormat: TimeFormatPreference

    private var fillColor: Color {
        switch limit.status {
        case .behind: Palette.danger
        case .onTrack: Palette.warn
        default: limit.used >= 1 ? Palette.danger : limit.tool.chartColor
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "\(limit.tool.displayName) · \(limit.window.label)").font(.subheadline.weight(.semibold))
                Spacer()
                Text(L("%ld%% used", Int((limit.used * 100).rounded()))).font(.subheadline).monospacedDigit()
            }
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(height: 8)
                    Capsule().fill(fillColor).frame(width: limit.used > 0 ? max(6, width * CGFloat(min(1, limit.used))) : 0, height: 8)
                    if let elapsed = limit.elapsed {
                        Rectangle().fill(.primary.opacity(0.75)).frame(width: 2, height: 14)
                            .offset(x: Meter.tickOffset(width: width, tick: elapsed))
                    }
                }
                .frame(height: 14)
            }
            .frame(height: 14)
            .environment(\.layoutDirection, .leftToRight)
            .help(limit.elapsed.map { L("The tick marks an even pace: %ld%% of the window has passed", Int(($0 * 100).rounded())) } ?? "")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let reset = limit.window.resetsAt {
                    Text(ResetText.line(resetsAt: reset, hasLimit: true, display: .exact, timeFormat: timeFormat, stale: limit.staleLine != nil))
                        .foregroundStyle(.secondary)
                }
                if let line = limit.allowanceLine {
                    Text(verbatim: "·").foregroundStyle(.tertiary)
                    if limit.used >= 1 {
                        // The spent bar is vermillion; the words and a symbol say why, never the fill alone.
                        Label(line, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.danger)
                    } else {
                        Text(line).foregroundStyle(.secondary)
                    }
                }
            }
            .font(.caption)
            // Orange and vermillion each come with words and a symbol, never the fill colour alone.
            if let note = limit.note, let status = limit.status, let symbol = status.symbolName {
                Label(note, systemImage: symbol)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(status == .behind ? Palette.danger : Palette.warn)
            }
            if let stale = limit.staleLine {
                Text(stale).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ShareList: View {
    let title: String
    let shares: [CostShare]
    let total: Double
    let name: (String) -> String
    /// The label for spend none of the shares account for; nil where the shares always add up to the total.
    var remainder: String? = nil

    /// The shares, plus a row for whatever of the total they leave unaccounted (more than half a per cent of it).
    private var rows: [CostShare] {
        guard let remainder, total > 0 else { return shares }
        let rest = total - shares.reduce(0) { $0 + $1.cost }
        return rest > total * 0.005 ? shares + [CostShare(name: remainder, cost: rest)] : shares
    }

    private func label(_ share: CostShare) -> String {
        share.name == CostShare.other ? L("Other") : share.name == remainder ? share.name : name(share.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            if rows.isEmpty {
                Text(verbatim: "—").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(rows) { share in
                let fraction = total > 0 ? share.cost / total : 0
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(label(share)).font(.caption).lineLimit(1).truncationMode(.middle).help(label(share))
                        Spacer(minLength: 8)
                        Text(verbatim: "\(Int((fraction * 100).rounded()))%").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        Text(Money.dollars(share.cost, cents: false)).font(.caption).monospacedDigit().frame(minWidth: 56, alignment: .trailing)
                    }
                    GeometryReader { geometry in
                        Capsule().fill(Color.accentColor.opacity(0.7))
                            .frame(width: max(2, geometry.size.width * CGFloat(fraction)))
                    }
                    .frame(height: 4)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }
}

/// The dashboard's window: the same non-activating panel as Settings, raised above the notch panel and placed the
/// same way (SettingsWindowController.frame), so it opens where Settings does and never under the panel.
@MainActor
final class DashboardWindowController: NSWindowController {
    nonisolated static let contentSize = NSSize(width: 720, height: 760)

    private let prefs: Preferences
    private var panelLevel: NSWindow.Level?
    private var aside = false

    init(store: UsageStore, prefs: Preferences, actions: NotchActions? = nil) {
        self.prefs = prefs
        let panel = SettingsPanel(contentRect: NSRect(origin: .zero, size: Self.contentSize),
                                  styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        let host = FirstMouseHostingView(rootView: DashboardView(store: store, actions: actions))
        host.sizingOptions = []
        panel.title = L("%@ Usage", AppInfo.name)
        panel.contentView = host
        panel.setContentSize(Self.contentSize)
        // Content, not frame: the frame's minimum includes the title bar and left the view 28 pt short of its own.
        panel.contentMinSize = NSSize(width: 560, height: 480)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.wearCloseOnly()
        super.init(window: panel)
        followAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    /// The Appearance picker in Settings applies to Settings' own window at once; this one follows the same choice
    /// while it is open rather than waiting to be presented again.
    private func followAppearance() {
        withObservationTracking {
            window?.appearance = prefs.appearance.nsAppearance
        } onChange: { [weak self] in
            Task { @MainActor in self?.followAppearance() }
        }
    }

    /// `aside` is whether an update session or an alert is up as the window opens: a controller made during one
    /// never heard its standAside(true), and would otherwise rise over the very window it should give way to.
    func present(on screen: NSScreen, below readouts: CGRect? = nil, above panelLevel: NSWindow.Level? = nil, aside: Bool? = nil) {
        guard let window else { return }
        if let aside { self.aside = aside }
        if let panelLevel {
            self.panelLevel = panelLevel
        }
        window.level = self.aside ? .normal : (self.panelLevel.map(SettingsWindowController.level(above:)) ?? .floating)
        if !window.isVisible {
            window.setFrame(SettingsWindowController.frame(for: window.frame.size, screen: screen.frame, safeAreaTop: screen.safeAreaInsets.top,
                                                           visible: screen.visibleFrame, readouts: readouts), display: false)
        }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func standAside(_ aside: Bool) {
        self.aside = aside
        guard let window else { return }
        window.level = aside ? .normal : (panelLevel.map(SettingsWindowController.level(above:)) ?? .floating)
    }
}
