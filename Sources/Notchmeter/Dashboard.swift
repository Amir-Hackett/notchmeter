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
    /// The assistant behind each model row, for the row's colour: the one that spent most on the name in the
    /// range, since Cursor's export can name the same model Claude Code's transcripts do. "Other" belongs to none.
    let modelTools: [String: ToolID]
    let sources: [(tool: ToolID, source: CostSource)]
    /// The list prices behind the range's locally priced lines, for the footnote (PriceSource.line).
    let priceSources: Set<PriceSource>

    var bars: [Bar] {
        days.flatMap { day in day.byTool.map { Bar(day: day.day, tool: $0.tool, cost: $0.cost) } }
    }

    var isEmpty: Bool { total <= 0 && days.allSatisfy { $0.total <= 0 } }

    func tool(ofModel name: String) -> ToolID? { modelTools[name] }

    /// The day a selection names, matched by calendar day: a hover reports the bar's own date and a pin holds it.
    func day(_ date: Date?, calendar: Calendar = .current) -> Day? {
        guard let date else { return nil }
        return days.first { calendar.isDate($0.day, inSameDayAs: date) }
    }

    static func == (lhs: DashboardModel, rhs: DashboardModel) -> Bool {
        lhs.range == rhs.range && lhs.tools == rhs.tools && lhs.days == rhs.days && lhs.total == rhs.total && lhs.today == rhs.today
            && lhs.dailyAverage == rhs.dailyAverage && lhs.averageSince == rhs.averageSince && lhs.peak == rhs.peak && lhs.models == rhs.models && lhs.projects == rhs.projects
            && lhs.modelTools == rhs.modelTools
            && lhs.sources.map(\.tool) == rhs.sources.map(\.tool) && lhs.sources.map(\.source) == rhs.sources.map(\.source)
            && lhs.priceSources == rhs.priceSources
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
        var spenders: [String: (tool: ToolID, cost: Double)] = [:]
        for provider in providers {
            let inRange = provider.totals(range.costRange)
            totals.add(inRange)
            todayTotals.add(provider.totals(.today))
            for (name, cost) in inRange.byModel where cost > (spenders[name]?.cost ?? 0) {
                spenders[name] = (provider.tool, cost)
            }
        }
        total = totals.cost
        self.today = todayTotals.cost
        models = totals.models
        projects = totals.projects
        modelTools = spenders.mapValues(\.tool)
        priceSources = totals.priceSources

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
        Color(nsColor: .adaptive(light: chartInk(dark: false).hex, dark: chartInk(dark: true).hex))
    }

    /// The value `chartColor` takes under each appearance, which `DashboardPresentation` holds to 3:1 on its
    /// window: the bars are drawn at full strength whatever day is chosen, so this is the contrast they are read at.
    func chartInk(dark: Bool) -> RGB {
        guard dark else { return RGB(hex: identity.light) }
        return switch self {
        case .claude: RGB(hex: 0xCC7555)
        case .cursor: RGB(hex: 0x8C74EA)
        case .codex: RGB(hex: 0x34A874)
        case .gemini, .antigravity, .copilot, .kimi: RGB(hex: identity.dark)  // each above 5.8:1 on the dark window as it is
        // The notch's violet sits on top of Cursor's periwinkle once both are stepped for a window (1.6 under
        // deuteranopia), so OpenCode's window step leans to the orchid side of the same purple: 17.9 normal and 7.9
        // CVD from the dark set at 3.55:1 on its surface; the light window takes the identity's own light value, 5.5:1
        // on white. The Dashboard names every series in its legend, which is the secondary encoding the 6–8 CVD
        // band asks for.
        case .opencode: RGB(hex: 0xC818B8)
        }
    }
}

/// The panel's look, borrowed for the dashboard's window so what it shares with the panel (CardBackground, Meter,
/// the accent) draws here as it does there. The window follows the system appearance rather than the panel's
/// theme: under Dark it borrows the black panel's look, under Light the Paper one, whose measured inks and marks
/// are made for a light sheet; only the accent is the reader's own choice (Settings › Appearance › Theme), the one
/// the Cost card's range control and the panel's Clear are drawn in. Solid either way, since a window has no
/// desktop showing through it. The system's own accent is never used: it is the one colour on the Mac that says
/// nothing about this app.
enum DashboardLook {
    /// The window's own ground under each appearance (`NSColor.windowBackgroundColor`, measured from the renders:
    /// white under Light on macOS 26, #1E1E1E under Dark), which the audit holds the accent to: the panel's rules
    /// measure against the black panel and the paper sheet, and a window is neither. Older releases drew the light
    /// window a shade darker (#ECECEC), which `DashboardPresentation` holds the accent to as well.
    static let darkWindow = RGB(hex: 0x1E1E1E)
    static let lightWindow = RGB.white

    static func look(dark: Bool, accent: PanelAccent, contrast: Bool) -> PanelLook {
        PanelLook(theme: dark ? .black : .paper, material: .solid, accent: accent, contrast: contrast)
    }

    /// The accent's name on the look: the lifted or darkened one under Increase Contrast, as the panel's own views
    /// choose it (the Cost card's range control, the line that says a session is waiting).
    static func accentInk(contrast: Bool) -> PanelInk { contrast ? .accentContrast : .accent }

    /// The accent as a mark on the window: the project bars and the pin under the chart.
    static func accent(dark: Bool, accent: PanelAccent, contrast: Bool) -> RGB {
        look(dark: dark, accent: accent, contrast: contrast).rgb(accentInk(contrast: contrast), role: .mark)
    }

    /// The accent as text on the window: the pin beside the chosen day's figures.
    static func pin(dark: Bool, accent: PanelAccent, contrast: Bool) -> RGB {
        look(dark: dark, accent: accent, contrast: contrast).rgb(accentInk(contrast: contrast), role: .text)
    }

    static func window(dark: Bool) -> RGB { dark ? darkWindow : lightWindow }

    /// A card's box on the window: CardBackground's wash of the look's ink over the window's ground, at the
    /// opacity the card names (stronger under Increase Contrast), scaled as the look scales it (`PanelLook.box`
    /// is the same wash over the panel's own sheet). Measured from the dark render as #2E2E2E.
    static func box(dark: Bool, contrast: Bool) -> RGB {
        let look = look(dark: dark, accent: .terracotta, contrast: contrast)
        return look.ink.over(window(dark: dark), alpha: look.washOpacity(contrast ? 0.16 : 0.07))
    }

    /// A status colour on the window (the spent line and the behind-pace note as words, the meter's fill as a
    /// mark): the look's value for the role, moved in lightness by the least that reads on the window and on a
    /// card's box there, at 4.5:1 for words and 3:1 for a mark, as the panel's palette moves it for the panel's own
    /// grounds (`RGB.readable`). The black look's vermillion passes on black (5.4:1) and so comes back from the
    /// panel as it is, but the dark window is #1E1E1E, where it reads at 4.3:1, and its card box 3.5:1. The status
    /// colours are the same under every accent, so the look is taken for the default one.
    static func status(_ name: PanelInk, role: PanelLook.Role, dark: Bool, contrast: Bool) -> RGB {
        let grounds = [window(dark: dark), box(dark: dark, contrast: contrast)]
        return look(dark: dark, accent: .terracotta, contrast: contrast).rgb(name, role: role)
            .readable(against: grounds, target: role == .text ? 4.5 : 3, lighter: dark)
    }
}

/// Which day the line under the chart describes: the pinned day while there is one, else the day under the
/// pointer. A click pins, so the figures can be read with the pointer elsewhere or reached with no pointer at all;
/// a hover only previews, and never moves a pin.
struct DashboardSelection: Equatable {
    private(set) var pinned: Date?
    private(set) var hovered: Date?
    let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    var shown: Date? { pinned ?? hovered }
    var isPinned: Bool { pinned != nil }

    /// A click pins the day, or lets the pinned day go when it is the one clicked. Whether a day is pinned after.
    @discardableResult
    mutating func click(_ day: Date) -> Bool {
        if let pinned, calendar.isDate(pinned, inSameDayAs: day) {
            self.pinned = nil
            return false
        }
        pinned = day
        return true
    }

    /// The pointer entering or leaving a day's slot. Neighbouring slots report in either order as the pointer
    /// crosses from one to the next, so a leave clears the preview only while it is still that day's.
    mutating func hover(_ day: Date, inside: Bool) {
        if inside {
            hovered = day
        } else if let hovered, calendar.isDate(hovered, inSameDayAs: day) {
            self.hovered = nil
        }
    }

    /// Escape, the Unpin button, or a change of range.
    mutating func unpin() { pinned = nil }

    /// A change of range: the chart is rebuilt for it (DashboardView.chartSection) and the old range's slots go
    /// without reporting the pointer's leave, so the preview is let go with the pin rather than naming a day
    /// the pointer is no longer over.
    mutating func clearHover() { hovered = nil }
}

/// The hero and the three tiles as they are printed: the range's total, the value line under it, and the average,
/// the peak and today beside them. Pure, so the wording is pinned without a view.
struct DashboardHero: Equatable {
    struct Tile: Equatable {
        let title: String
        let value: String
        let caption: String
    }

    let total: String
    /// The range's name, the total's caption.
    let range: String
    /// The value framing (PlanValue): the range's API-equivalent dollars against what the plans behind them cost,
    /// said only where both sides are known, and marked as the estimate it is. The week has no fee of its own, so
    /// its line is the thirty days'.
    let value: String?
    let average: Tile
    let peak: Tile
    let today: Tile

    init(model: DashboardModel, valueLine: String?, now: Date = Date(), calendar: Calendar = .current) {
        total = Money.dollars(model.total, cents: false)
        range = model.range.title
        value = valueLine?.keepingHyphensWhole
        // Named by its first day where the history starts inside the range, so a 90-day average over 39 days of
        // history does not read as spread across all ninety.
        let averageCaption = model.averageSince.map { L("per day since %@", ResetText.dayPhrase($0, now: now, calendar: calendar)) } ?? L("per calendar day")
        average = Tile(title: L("Daily average"), value: model.dailyAverage.map { Money.dollars($0, cents: false) } ?? "—", caption: averageCaption)
        peak = Tile(title: L("Peak day"), value: model.peak.map { Money.dollars($0.total, cents: false) } ?? "—",
                    caption: model.peak.map { ResetText.dayPhrase($0.day, now: now, calendar: calendar) } ?? "")
        today = Tile(title: L("Today"), value: Money.dollars(model.today, cents: false), caption: "")
    }
}

struct DashboardView: View {
    let store: UsageStore
    @State private var range: DashboardRange
    @State private var selection: DashboardSelection
    @Environment(\.colorScheme) private var colorScheme

    /// Inside Settings, whose pane already carries the title: the header keeps its line, picker and refresh only.
    let embedded: Bool
    /// For the header's share button (NotchActions.openShareCard); nil in a render, which has no window to open.
    let actions: NotchActions?
    /// Whether the sections sit in a scroll view, as they do in the window. A render lays them out bare, so the
    /// hosting view's fitting size is the height of every section (AssetRenderer.dashboardImage).
    let scrolls: Bool

    /// `pinned` is a day held under the chart from the start, for a render: a picture cannot click.
    init(store: UsageStore, range: DashboardRange = .week, embedded: Bool = false, actions: NotchActions? = nil, scrolls: Bool = true,
         pinned: Date? = nil) {
        self.store = store
        self.embedded = embedded
        self.actions = actions
        self.scrolls = scrolls
        _range = State(initialValue: range)
        var selection = DashboardSelection()
        if let pinned { selection.click(pinned) }
        _selection = State(initialValue: selection)
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
        // The panel's look for this appearance, so CardBackground, Meter and the accent draw here as they do there.
        let dark = colorScheme == .dark
        let contrast = AccessibilityDisplay.shared.contrast
        let look = DashboardLook.look(dark: dark, accent: store.prefs.panelAccent, contrast: contrast)
        let accent = DashboardLook.accent(dark: dark, accent: store.prefs.panelAccent, contrast: contrast).color
        // A concrete colour for the chart's rule and grid: a hierarchical style inside a chart resolves against the
        // chart's own foreground, which is the system accent, and the average came out blue.
        let ink = look.inkColour(.secondary)
        let content = VStack(alignment: .leading, spacing: 20) {
            header
            if !spendShown {
                Text(L("Spend is hidden in Settings, so only limits are shown."))
                    .font(.caption).foregroundStyle(Caption.style)
            }
            if model.isEmpty && limits.isEmpty {
                // With spend hidden the account may well have some: the note above says so, the empty state
                // would claim nothing was ever used.
                if spendShown { empty }
            } else {
                if !model.isEmpty {
                    hero(DashboardHero(model: model, valueLine: store.planValueLine(for: range.costRange)))
                    chartSection(model, ink: ink, pinMark: DashboardLook.pin(dark: dark, accent: store.prefs.panelAccent, contrast: contrast).color)
                }
                if !limits.isEmpty { limitsSection(limits, dark: dark, contrast: contrast) }
                if !model.isEmpty { breakdownSection(model, accent: accent) }
                if !model.isEmpty { sourcesFootnote(model) }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.panelLook, look)
        .environment(\.density, store.prefs.density)
        .onChange(of: range) {
            // The chart is rebuilt for the new range: a pin on a day its bars may not hold goes with it, and so
            // does the preview, since the old range's slots are torn down without reporting the pointer's leave.
            if selection.isPinned { unpin() }
            selection.clearHover()
        }
        if scrolls {
            ScrollView { content }
        } else {
            content
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                if !embedded { Text(L("Usage")).font(.title2.weight(.semibold)) }
                Text(updatedLine).font(.caption).foregroundStyle(Caption.style)
                // The rate every figure below was converted at, and its day, while *Fetch today's rate* is on.
                if store.prefs.showSpend, let note = store.prefs.currencyConversion.note {
                    Text(note).font(.caption).foregroundStyle(Caption.style)
                }
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

    // MARK: Hero and tiles

    /// The total with the value line, and the three smaller figures beside it where the row fits (the window's own
    /// width, DashboardWindowController.contentSize) or under it where a narrow window or a longer language would
    /// cut a caption short (its minimum width).
    private func hero(_ figures: DashboardHero) -> some View {
        let total = heroCard(figures)
        let average = tile(figures.average)
        let peak = tile(figures.peak)
        let today = tile(figures.today)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                // First claim on the width: the tiles take what their captions need and the total the rest.
                total.layoutPriority(1)
                average
                peak
                today
            }
            VStack(alignment: .leading, spacing: 12) {
                total
                HStack(alignment: .top, spacing: 12) {
                    average
                    peak
                    today
                }
            }
        }
    }

    /// The range's total, the one figure the page is about, in the largest type on it; the range under it, and
    /// under that the value framing, in the same card because the two are one thought: what was spent, and what
    /// that spend is worth against the plan.
    private func heroCard(_ figures: DashboardHero) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("Total")).font(.caption).foregroundStyle(Caption.style)
            Text(figures.total).font(.largeTitle.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            // The caption under a figure, at the step the tiles' captions take; "Total" above is a title, like theirs.
            Text(figures.range).modifier(Caption())
            if let value = figures.value {
                Text(value)
                    .font(.subheadline).foregroundStyle(Caption.style)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        }
        .frame(minWidth: 200, idealWidth: 200, maxWidth: .infinity, alignment: .leading)
        .modifier(CardBackground())
        .accessibilityElement(children: .combine)
    }

    private func tile(_ tile: DashboardHero.Tile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tile.title).font(.caption).foregroundStyle(Caption.style)
            Text(tile.value).font(.title2.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(tile.caption.isEmpty ? " " : tile.caption).modifier(Caption()).lineLimit(1).fixedSize()
        }
        // As tall as the row: the hero's value line wraps to two lines in English at the window's width and three
        // in Russian, and a tile that kept its own height would leave the row's bottom ragged beside it.
        .frame(minWidth: 100, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(CardBackground())
        .accessibilityElement(children: .combine)
    }

    // MARK: Chart

    private func chartSection(_ model: DashboardModel, ink: Color, pinMark: Color) -> some View {
        let shown = model.day(selection.shown, calendar: selection.calendar)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle(L("Daily spend"))
                Spacer()
                // The average is named up here with its own dashed swatch rather than on the line, where a label
                // sits over whichever bars are tallest at that end of the chart.
                HStack(spacing: 12) {
                    if let average = model.dailyAverage {
                        HStack(spacing: 5) {
                            Line().stroke(ink, style: StrokeStyle(lineWidth: 1, dash: [3, 2])).frame(width: 14, height: 1)
                            Text(L("avg %@", Money.dollars(average, cents: false))).font(.caption).foregroundStyle(Caption.style)
                        }
                    }
                    if model.tools.count > 1 { legend(model.tools) }
                }
            }
            // Rebuilt per range: Swift Charts in this hosting view kept drawing the previous range's marks and scale
            // until the window was resized, while the tiles above had already moved on.
            DailySpendChart(model: model, shown: shown, pinned: selection.isPinned, ink: ink, calendar: selection.calendar,
                            hover: { day, inside in selection.hover(day, inside: inside) }, click: click)
                .id(range)
                .frame(height: 220)
            dayLine(shown, pinMark: pinMark)
        }
        .accessibilityElement(children: .contain)
    }

    /// The line under the chart: the pinned day's figures with a pin and the way out, the hovered day's while
    /// nothing is pinned, else how to get either. The pin is a symbol and a word, not a colour: the band over the
    /// bars is the same accent for a hover and a pin, only stronger.
    @ViewBuilder
    private func dayLine(_ day: DashboardModel.Day?, pinMark: Color) -> some View {
        if let day, selection.isPinned {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "pin.fill").foregroundStyle(pinMark)
                    Text(Self.dayLine(day))
                }
                .font(.caption).foregroundStyle(Caption.style)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L("Pinned"))
                .accessibilityValue(Spoken.phrase(Self.dayLine(day)))
                Button(L("Unpin"), action: unpin)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(day.map { Self.dayLine($0) } ?? L("Hover a bar for that day's figures; click it to keep them."))
                .font(.caption).foregroundStyle(Caption.style)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "yesterday · $609.12 · Claude $548.76 · Cursor $60.36": the day, then its figures.
    static func dayLine(_ day: DashboardModel.Day, now: Date = Date(), calendar: Calendar = .current) -> String {
        "\(ResetText.dayPhrase(day.day, now: now, calendar: calendar)) · \(dayFigures(day))"
    }

    /// The day's figures without the day: the total, whether the bar holds only part of the day, and the split by
    /// assistant where more than one spent. A slot's VoiceOver value, whose label is the day already, so a slot
    /// does not name its day twice.
    static func dayFigures(_ day: DashboardModel.Day) -> String {
        var parts = [Money.dollars(day.total)]
        // The Today tile counts the whole day; this bar only what came after the week reset.
        if day.partial { parts.append(L("since the week reset")) }
        if day.byTool.count > 1 {
            parts += day.byTool.map { "\($0.tool.displayName) \(Money.dollars($0.cost))" }
        }
        return parts.joined(separator: " · ")
    }

    private func click(_ day: Date) {
        let pinned = selection.click(day)
        Oracle.shared.emit("dashboard", ["action": pinned ? "pinned" : "unpinned", "day": CostHistory.key(day, calendar: selection.calendar)])
    }

    private func unpin() {
        guard let day = selection.pinned else { return }
        selection.unpin()
        Oracle.shared.emit("dashboard", ["action": "unpinned", "day": CostHistory.key(day, calendar: selection.calendar)])
    }

    private func legend(_ tools: [ToolID]) -> some View {
        HStack(spacing: 12) {
            ForEach(tools, id: \.self) { tool in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(tool.chartColor).frame(width: 10, height: 10)
                    Text(tool.displayName).font(.caption).foregroundStyle(Caption.style)
                }
            }
        }
    }

    // MARK: Limits

    private func limitsSection(_ limits: [DashboardLimit], dark: Bool, contrast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(L("Limits"))
            VStack(spacing: 0) {
                ForEach(Array(limits.enumerated()), id: \.element.id) { index, limit in
                    if index > 0 { Divider() }
                    LimitRow(limit: limit, timeFormat: store.prefs.timeFormat, dark: dark, contrast: contrast)
                        .padding(.vertical, 10)
                }
            }
            .modifier(CardBackground())
        }
    }

    // MARK: Breakdown

    private func breakdownSection(_ model: DashboardModel, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(L("Where it went"))
            HStack(alignment: .top, spacing: 16) {
                // A model's bar in its assistant's own colour, as the chart's bars and the legend are.
                ShareList(title: L("By model"), shares: model.models, total: model.total, name: ModelNames.display,
                          fill: { share in model.tool(ofModel: share.name).map { AnyShapeStyle($0.chartColor) } ?? AnyShapeStyle(Ink.secondary) })
                // A project is no assistant's, so its bar takes the app's own accent. Cursor's export names no
                // folder, so its spend has no project: said as a row, or the shares stop short of 100% with nothing
                // to say where the rest went.
                ShareList(title: L("By project"), shares: model.projects, total: model.total, name: { $0 },
                          fill: { _ in AnyShapeStyle(accent) }, remainder: L("No project"))
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
            if let prices = PriceSource.line(model.priceSources) {
                Text(prices)
            }
        }
        .modifier(Caption())
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

/// Stacked daily bars, one colour per assistant, a dashed line at the daily average, and a band in the secondary ink
/// over the day whose figures are under the chart, stronger while that day is pinned. The band is neutral on purpose:
/// in the accent it was the default terracotta, Claude's own series colour, so the part of a pinned day's column
/// above its bar read as another stacked segment of spend reaching the top of the chart. The band is the only mark
/// of the day: the other days' bars keep their colour, since dimming them (as a hover once did) put six of seven bars
/// under 3:1 on either window and off the legend's swatches for as long as a pin held. The bars, the band and the
/// rule say nothing to VoiceOver: an invisible element over each day's slot speaks for them (the day, the total,
/// the split) and takes the hover and the click, so what a pointer can pin a VoiceOver reader can pin too, and no
/// figure is hover-only.
private struct DailySpendChart: View {
    let model: DashboardModel
    let shown: DashboardModel.Day?
    let pinned: Bool
    /// The secondary ink as a colour, for the average's rule and, faintly, the grid.
    let ink: Color
    let calendar: Calendar
    let hover: (Date, Bool) -> Void
    let click: (Date) -> Void

    /// The whole span, the week included when only part of it has happened: seven slots whatever day it is, so a
    /// Monday's one bar is a seventh of the width and the empty days read as still to come.
    private var xDomain: ClosedRange<Date> {
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
            if let shown {
                // First, so it lies under the bars. Hidden from VoiceOver like the bars: the day's slot speaks for it.
                RectangleMark(x: .value(L("Day"), shown.day, unit: .day))
                    .foregroundStyle(ink.opacity(pinned ? 0.22 : 0.12))
                    .accessibilityHidden(true)
            }
            ForEach(model.bars) { bar in
                BarMark(x: .value(L("Day"), bar.day, unit: .day), y: .value(L("Spend"), bar.cost))
                    .foregroundStyle(by: .value(L("Assistant"), bar.tool.displayName))
                    .accessibilityHidden(true)
            }
            if let average = model.dailyAverage {
                // Its figure is in the legend above the chart ("avg $281"), so the rule itself says nothing.
                RuleMark(y: .value(L("Daily average"), average))
                    .foregroundStyle(ink)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .accessibilityHidden(true)
            }
        }
        .chartForegroundStyleScale(domain: model.tools.map(\.displayName), range: model.tools.map(\.chartColor))
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(ink.opacity(0.3))
                AxisValueLabel {
                    if let amount = value.as(Double.self) { Text(Money.dollars(amount, cents: false)) }
                }
            }
        }
        .chartXScale(domain: xDomain)
        .chartXAxis {
            if model.range == .week {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisGridLine().foregroundStyle(ink.opacity(0.3))
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated).day(), centered: true)
                }
            } else {
                AxisMarks(values: axisDays) { _ in
                    AxisGridLine().foregroundStyle(ink.opacity(0.3))
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let plot = geometry[anchor]
                    ForEach(model.days) { day in
                        if let start = proxy.position(forX: day.day), let next = calendar.date(byAdding: .day, value: 1, to: day.day),
                           let end = proxy.position(forX: next) {
                            daySlot(day, in: CGRect(x: plot.minX + start, y: plot.minY, width: max(1, end - start), height: plot.height))
                        }
                    }
                }
            }
        }
        .accessibilityLabel(L("Daily spend"))
        .accessibilityValue(model.days.filter { $0.total > 0 }.map {
            "\(ResetText.dayPhrase($0.day, now: Date(), calendar: calendar)) \(Money.dollars($0.total, cents: false))"
        }.joined(separator: ", "))
    }

    /// One day's slot, the plot's full height: the hover and click target, and the element VoiceOver reads and acts on.
    private func daySlot(_ day: DashboardModel.Day, in frame: CGRect) -> some View {
        let isPinned = pinned && shown?.id == day.id
        return Color.clear
            .contentShape(Rectangle())
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .onHover { inside in hover(day.day, inside) }
            .onTapGesture { click(day.day) }
            .accessibilityElement()
            .accessibilityAction { click(day.day) }
            .accessibilityLabel(ResetText.dayPhrase(day.day, now: Date(), calendar: calendar))
            // The figures alone: the label is the day, and the line under the chart is the one that repeats it.
            .accessibilityValue(Spoken.line(isPinned ? L("Pinned") : nil, DashboardView.dayFigures(day)))
            .accessibilityHint(L("Pins or unpins this day's figures under the chart"))
            .accessibilityAddTraits(.isButton)
    }
}

/// One limit: the meter, the reset and the allowance, and the pace note. The status colours are the window's own
/// (`DashboardLook.status`), resolved here rather than through `Themed`, whose look is derived against the panel's
/// grounds and not the window's.
private struct LimitRow: View {
    let limit: DashboardLimit
    let timeFormat: TimeFormatPreference
    let dark: Bool
    let contrast: Bool

    private func status(_ name: PanelInk, _ role: PanelLook.Role) -> Color {
        DashboardLook.status(name, role: role, dark: dark, contrast: contrast).color
    }

    private var fillColor: Color {
        switch limit.status {
        case .behind: status(.danger, .mark)
        case .onTrack: status(.warn, .mark)
        default: limit.used >= 1 ? status(.danger, .mark) : limit.tool.chartColor
        }
    }

    /// "The tick marks an even pace: 33% of the window has passed", the tick's figure in words.
    private var tickLine: String? {
        limit.elapsed.map { L("The tick marks an even pace: %ld%% of the window has passed", Int(($0 * 100).rounded())) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "\(limit.tool.displayName) · \(limit.window.label)").font(.subheadline.weight(.semibold))
                Spacer()
                Text(L("%ld%% used", Int((limit.used * 100).rounded()))).font(.subheadline).monospacedDigit()
            }
            // The panel's own meter (the bar under every window on the cards): the fill in the pace colour or the
            // tool's own, the tick where an even burn would be now, the track the look gives it. The tick's figure
            // is the tooltip for a pointer and the meter's own words for VoiceOver, which the row's combined
            // element reads with the rest, so the one number the tick encodes is never a hover's alone.
            Meter(fraction: limit.used, tick: limit.elapsed, color: fillColor)
                .help(tickLine ?? "")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(tickLine ?? "")
                .accessibilityHidden(tickLine == nil)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let reset = limit.window.resetsAt {
                    Text(ResetText.line(resetsAt: reset, hasLimit: true, display: .exact, timeFormat: timeFormat, stale: limit.staleLine != nil))
                        .foregroundStyle(Caption.style)
                }
                if let line = limit.allowanceLine {
                    Text(verbatim: "·").foregroundStyle(Ink.tertiary)
                    if limit.used >= 1 {
                        // The spent bar is vermillion; the words and a symbol say why, never the fill alone.
                        Label(line, systemImage: "exclamationmark.triangle.fill").foregroundStyle(status(.danger, .text))
                    } else {
                        Text(line).foregroundStyle(Caption.style)
                    }
                }
            }
            .font(.caption)
            // Orange and vermillion each come with words and a symbol, never the fill colour alone.
            if let note = limit.note, let status = limit.status, let symbol = status.symbolName {
                Label(note, systemImage: symbol)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(self.status(status == .behind ? .danger : .warn, .text))
            }
            if let stale = limit.staleLine {
                Text(stale).font(.caption).foregroundStyle(Caption.style)
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
    /// The colour of a named row's bar: the assistant's own for a model, the accent for a project. "Other" and the
    /// remainder are nobody's and draw in the caption's grey.
    let fill: (CostShare) -> AnyShapeStyle
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

    private func bar(_ share: CostShare) -> AnyShapeStyle {
        share.name == CostShare.other || share.name == remainder ? AnyShapeStyle(Ink.secondary) : fill(share)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(Caption.style)
            if rows.isEmpty {
                Text(verbatim: "—").font(.caption).foregroundStyle(Caption.style)
            }
            ForEach(rows) { share in
                let fraction = total > 0 ? share.cost / total : 0
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(label(share)).font(.caption).lineLimit(1).truncationMode(.middle).help(label(share))
                        Spacer(minLength: 8)
                        Text(verbatim: "\(Int((fraction * 100).rounded()))%").font(.caption).foregroundStyle(Caption.style).monospacedDigit()
                        Text(Money.dollars(share.cost, cents: false)).font(.caption).monospacedDigit().frame(minWidth: 56, alignment: .trailing)
                    }
                    GeometryReader { geometry in
                        Capsule().fill(bar(share))
                            .frame(width: max(2, geometry.size.width * CGFloat(fraction)))
                    }
                    .frame(height: 4)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CardBackground())
    }
}

/// The dashboard's window: the same non-activating panel as Settings, raised above the notch panel and placed the
/// same way (SettingsWindowController.frame), so it opens where Settings does and never under the panel.
@MainActor
final class DashboardWindowController: NSWindowController {
    nonisolated static let contentSize = NSSize(width: 720, height: 760)
    /// The narrowest the window goes: the width at which the hero's tiles move under the total (DashboardView.hero).
    nonisolated static let minSize = NSSize(width: 560, height: 480)

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
        panel.contentMinSize = Self.minSize
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
