import SwiftUI

/// The Simple panel (PanelMode.simple): one sheet with no card boxes, a row per assistant carrying its most urgent
/// figure, a row for the cost, the sessions grouped by project, and a quiet Notes row. Every row opens in place onto
/// what the Detailed panel shows for it (the tool's card, the Cost card, the advice lines), drawn without their box,
/// so nothing the Detailed panel says is more than one click away. The rows' open state is the store's
/// (UsageStore.openPanelRows), so the measuring copy of the panel sizes the window for a row that is open.

// MARK: - Where the advice goes

/// Which row each advice line is drawn on. The Detailed panel has one strip for all of them; the Simple panel has
/// none, so a line goes to the row it is about, and a line about nothing on the panel goes to Notes. Pure, and
/// total: every line lands on exactly one row, which is what AdvicePlacementTests holds it to, because a line that
/// fell between the rows would be advice the reader was never shown.
enum AdvicePlacement {
    enum Slot: Hashable, Sendable {
        case tool(ToolID)
        case cost
        case sessions
        case notes

        /// The row's key in UsageStore.openPanelRows and the oracle.
        var key: String {
            switch self {
            case .tool(let tool): "tool:\(tool.rawValue)"
            case .cost: "cost"
            case .sessions: "sessions"
            case .notes: "notes"
            }
        }
    }

    /// Money lines: a budget crossed or on pace to be, an hour that burned several times the usual, extra usage
    /// starting to flow. They are about the spend before they are about any one tool.
    static func isMoney(_ line: Advice) -> Bool {
        line.id.hasPrefix("budget/") || line.id == "burn" || line.id.hasPrefix("burn/") || line.id.hasPrefix("extra/")
    }

    /// "Claude Code is waiting in notchmeter": about sessions, which the Sessions section lists.
    static func isWaiting(_ line: Advice) -> Bool { line.id.hasPrefix("waiting/") }

    /// The row one line goes to, given which rows the panel has: a money line on the cost row, a waiting line on the
    /// sessions, anything else on its tool's row; each falls back to its tool's row and then to Notes when the row
    /// it wants is not on the panel.
    static func slot(for line: Advice, tools: [ToolID], cost: Bool, sessions: Bool) -> Slot {
        if isMoney(line), cost { return .cost }
        if isWaiting(line), sessions { return .sessions }
        if let tool = line.tool, tools.contains(tool) { return .tool(tool) }
        return .notes
    }

    /// Every line on its row, in the order the Advisor put them (priority first), so a row's first line is its
    /// most pressing one.
    static func assign(_ advice: [Advice], tools: [ToolID], cost: Bool, sessions: Bool) -> [Slot: [Advice]] {
        var slots: [Slot: [Advice]] = [:]
        for line in advice {
            slots[slot(for: line, tools: tools, cost: cost, sessions: sessions), default: []].append(line)
        }
        return slots
    }

    /// The Sessions section's lines, split into the ones drawn as a line over the rows and the ones a row carries in
    /// its VoiceOver value instead. A waiting line is the third telling of a fact the row already draws (the wash,
    /// the hand, "Waiting for your answer"), so it is left off the sheet when every session it is about is a row
    /// on it that needs the reader, and goes on the first of them. It stays a line when one of its sessions is past
    /// the "+N more" cap, when the titles are hidden (the line names the project the row cannot), or when it is
    /// about no session the hooks reported. Total like `assign`: every line is drawn or on exactly one row.
    static func sessionLines(_ advice: [Advice], needsYou rows: [(id: String, tool: ToolID)], waiting: [(id: String, tool: ToolID)],
                             titlesShown: Bool) -> (drawn: [Advice], onRow: [String: [Advice]]) {
        var drawn: [Advice] = []
        var onRow: [String: [Advice]] = [:]
        for line in advice {
            guard isWaiting(line), titlesShown, let tool = line.tool else { drawn.append(line); continue }
            let sessions = waiting.filter { $0.tool == tool }.map(\.id)
            let shown = Set(rows.filter { $0.tool == tool }.map(\.id))
            if !sessions.isEmpty, sessions.allSatisfy(shown.contains), let row = rows.first(where: { $0.tool == tool }) {
                onRow[row.id, default: []].append(line)
            } else {
                drawn.append(line)
            }
        }
        return (drawn, onRow)
    }
}

// MARK: - The one figure a tool row shows

/// How loud a row's figure is: in the text colour, or in the pace colours the Detailed meters use, each with its
/// symbol so the state is never told by colour alone.
enum SimpleUrgency: Int, Comparable, Sendable {
    case calm, warn, danger

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Spent or behind pace is danger; on track to land inside the last tenth, or nine tenths used, is a warning.
    static func of(_ window: LimitWindow, now: Date = Date()) -> SimpleUrgency {
        guard let used = window.usedFraction, !window.isComparison else { return .calm }
        if used >= 1 { return .danger }
        switch Pace.status(for: window, now: now) {
        case .behind?: return .danger
        case .onTrack?: return .warn
        default: return used >= 0.9 ? .warn : .calm
        }
    }

    var color: Color? {
        switch self {
        case .calm: nil
        case .warn: Palette.warn
        case .danger: Palette.danger
        }
    }

    var symbolName: String? {
        switch self {
        case .calm: nil
        case .warn: "arrow.up.right"
        case .danger: "exclamationmark.triangle.fill"
        }
    }
}

enum SimpleFigure {
    /// The window a tool's row stands for: of the windows the card shows with a figure, the most urgent, and among
    /// equally urgent ones the most used. A comparison ("of a usual day") is never it: nothing runs out on one.
    /// Nil when no shown window has a figure, and the row then shows none.
    static func window(of windows: [LimitWindow], now: Date = Date()) -> LimitWindow? {
        windows
            .filter { $0.usedFraction != nil && !$0.isComparison }
            .max { lhs, rhs in
                let (left, right) = (SimpleUrgency.of(lhs, now: now), SimpleUrgency.of(rhs, now: now))
                return left != right ? left < right : (lhs.usedFraction ?? 0) < (rhs.usedFraction ?? 0)
            }
    }

    /// "62%", in the Used or Left sense the reader chose, and the window's name under that sense: "Weekly" for
    /// used, "Weekly left" for left, so the bare figure is never ambiguous.
    static func text(_ window: LimitWindow, display: UsageDisplay) -> (figure: String, caption: String)? {
        guard let used = window.usedFraction else { return nil }
        switch display {
        case .used: return ("\(Int((used * 100).rounded()))%", window.label)
        case .left: return ("\(Int(((1 - used) * 100).rounded()))%", L("%@ left", window.label))
        }
    }
}

// MARK: - Rows

/// One line under a row's title: a symbol and a sentence, in a state colour only where the symbol says the same.
struct SimpleLine: Identifiable {
    let id: String
    let symbol: String?
    let text: String
    /// The text's colour; nil is the caption's.
    var color: Color? = nil
    /// The symbol's colour where it differs from the text's: an attention line keeps its blue on the symbol only.
    var symbolColor: Color? = nil

    /// An advice line as a row's line: warnings and dangers in their colour, with their symbol; an attention line
    /// in the text colour with only its symbol blue (Palette.calm text is about 4:1 on black and under 4:1 on the
    /// row's wash); an info line in the caption's.
    @MainActor static func advice(_ item: Advice) -> SimpleLine {
        switch item.priority {
        case .info: SimpleLine(id: item.id, symbol: item.symbol, text: item.text)
        case .attention: SimpleLine(id: item.id, symbol: item.symbol, text: item.text, color: .primary, symbolColor: item.priority.mark)
        case .warn, .danger: SimpleLine(id: item.id, symbol: item.symbol, text: item.text, color: item.priority.color)
        }
    }
}

/// The row every part of the Simple panel is built from: a glyph, a title and at most one line under it on the
/// left, one figure on the right, and a chevron. The whole row is the button (first mouse comes from the panel's
/// hosting view), and what it opens is drawn under it, outside the button, so the controls in the detail keep
/// their own clicks.
struct SimpleRow<Glyph: View, Detail: View>: View {
    let title: String
    var line: SimpleLine? = nil
    var figure: String? = nil
    var caption: String? = nil
    var urgency: SimpleUrgency = .calm
    /// The row asks something of the reader: the calm wash and the bar down its leading edge (SessionsCard's).
    var needsYou = false
    /// What VoiceOver reads after the title, in words rather than the drawn abbreviations.
    var spoken: String? = nil
    /// Drawn before the caption, beside the figure: the Cost row's week of bars (WeekSpendStrip).
    var accessory: AnyView? = nil
    /// The row's tooltip, where resting on it says more than the row draws (the Cost row's week, day by day). The
    /// same words are in the detail the row opens onto and in its VoiceOver value, so nothing is hover-only.
    var help: String? = nil
    let open: Bool
    let toggle: () -> Void
    @ViewBuilder let glyph: () -> Glyph
    @ViewBuilder let detail: () -> Detail
    @Environment(\.density) private var density

    /// Where a row's title starts, from the row's own edge: the glyph's column and the gap after it. The line under
    /// the title starts here too.
    static var textInset: CGFloat { 26 }

    var body: some View {
        let contrast = AccessibilityDisplay.shared.contrast
        VStack(alignment: .leading, spacing: density.lineSpacing) {
            Button(action: toggle) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        glyph()
                            .font(.body.weight(.semibold))
                            .frame(width: 18)
                        Text(title).font(.body.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 8)
                        if let accessory {
                            accessory
                        }
                        if let caption {
                            Text(caption).font(.caption).foregroundStyle(Caption.style).lineLimit(1).fixedSize()
                        }
                        if let figure {
                            HStack(spacing: 3) {
                                if let symbol = urgency.symbolName {
                                    Image(systemName: symbol).font(.caption2.weight(.bold))
                                }
                                Text(figure).font(.body.weight(.bold)).monospacedDigit()
                            }
                            .foregroundStyle(urgency.color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
                            .fixedSize()
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            // Secondary in both modes: tertiary is 2:1 on the black panel, under the 3:1 a control's
                            // only affordance needs, and the chevron is the only sign the row opens.
                            .foregroundStyle(Caption.style)
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                    // The line runs the row's whole width under the title, so a long sentence wraps rather than
                    // squeezing the figure beside it.
                    if let line {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            if let symbol = line.symbol {
                                Image(systemName: symbol).font(.caption2.weight(.semibold))
                                    .foregroundStyle(line.symbolColor.map(AnyShapeStyle.init) ?? line.color.map(AnyShapeStyle.init) ?? AnyShapeStyle(Caption.style))
                            }
                            // A non-breaking hyphen keeps "30-day" whole when the line wraps, as on the Cost card.
                            Text(line.text.keepingHyphensWhole)
                                .monospacedDigit().fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.caption)
                        .foregroundStyle(line.color.map(AnyShapeStyle.init) ?? AnyShapeStyle(Caption.style))
                        .padding(.leading, Self.textInset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(RowHelp(text: help))
            .background {
                if needsYou {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Palette.calm.opacity(contrast ? 0.32 : 0.15))
                        .overlay(alignment: .leading) {
                            Rectangle().fill(contrast ? .white : Palette.calm).frame(width: 3)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(Spoken.line(spoken, open ? L("Expanded") : L("Collapsed")))
            .accessibilityHint(L("Opens or closes the detail"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { toggle() }
            if open {
                // The row's full width, which is the width a Detailed card gives its content: the Cost card's legend
                // truncated its sources when the detail was indented under the title.
                detail()
                    .padding(.horizontal, 6)
                    .padding(.top, 2)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        // The wash reaches into the sheet's margin, so every row's glyph sits on the header's edge.
        .padding(.horizontal, density.cardPadding - 6)
    }
}

/// A row's tooltip where it has one, and no tooltip region at all where it does not.
private struct RowHelp: ViewModifier {
    let text: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let text { content.help(text) } else { content }
    }
}

extension NotchExpandedView {
    /// Opens or closes one Simple row, animated unless motion is reduced, and tells the oracle.
    static func toggleRow(_ key: String, store: UsageStore) {
        let opening = !store.openPanelRows.contains(key)
        let change = {
            if opening { store.openPanelRows.insert(key) } else { store.openPanelRows.remove(key) }
        }
        if AccessibilityDisplay.shared.motionReduced { change() } else { withAnimation(.easeOut(duration: 0.18), change) }
        Oracle.shared.emit("panelRow", ["row": key, "expanded": opening])
    }
}

/// One assistant on the Simple panel: its glyph and name, its most urgent window as one figure, and the one line
/// worth reading under the name: what is wrong with it, else the advice about it, else its pace when behind, else
/// what its sessions are doing. Opens onto its card without the box, with every advice line about it.
struct SimpleToolRow: View {
    let tool: ToolID
    let store: UsageStore
    let prefs: Preferences
    let actions: NotchActions
    let advice: [Advice]

    private var key: String { AdvicePlacement.Slot.tool(tool).key }

    var body: some View {
        let status = store.status(tool)
        let open = store.openPanelRows.contains(key)
        let window = status.reading.flatMap { SimpleFigure.window(of: prefs.shownWindows(of: $0)) }
        let text = store.hidesFigures ? nil : window.flatMap { SimpleFigure.text($0, display: prefs.usageDisplay) }
        let urgency = window.map { SimpleUrgency.of($0) } ?? .calm
        let line = Self.line(status: status, advice: open ? [] : advice, window: window, signal: store.signal(tool),
                             hideFigures: store.hidesFigures, format: prefs.timeFormat)
        SimpleRow(title: tool.displayName, line: line, figure: text?.figure, caption: text?.caption,
                  urgency: store.hidesFigures ? .calm : urgency,
                  needsYou: Self.needsYou(status: status, advice: advice),
                  spoken: Spoken.line(window.flatMap { w in prefs.usageLine(for: w).map { "\(w.label) \($0)" } }.flatMap { store.hidesFigures ? nil : $0 },
                                      line.map { Spoken.phrase($0.text) }),
                  open: open, toggle: { NotchExpandedView.toggleRow(key, store: store) }) {
            Image(systemName: tool.symbolName).foregroundStyle(tool.color)
        } detail: {
            VStack(alignment: .leading, spacing: 8) {
                ToolCard(tool: tool, status: status, store: store, prefs: prefs, actions: actions, embedded: true)
                if !advice.isEmpty {
                    AdviceLines(advice: advice, open: actions.open)
                }
            }
        }
    }

    /// The row wants the reader: signed out, or an advice line about it that is waiting on them.
    static func needsYou(status: ToolStatus, advice: [Advice]) -> Bool {
        if case .needsAttention = status { return true }
        return advice.contains { $0.priority == .attention }
    }

    /// The one line under the name, or nil when there is nothing worth a line.
    @MainActor
    static func line(status: ToolStatus, advice: [Advice], window: LimitWindow?, signal: ToolSignal?, hideFigures: Bool,
                     format: TimeFormatPreference) -> SimpleLine? {
        if let problem = status.problem {
            return SimpleLine(id: "problem", symbol: "exclamationmark.triangle.fill", text: problem, color: Palette.warn)
        }
        switch status {
        case .waiting: return SimpleLine(id: "status", symbol: "hourglass", text: L("Waiting for the first reading"))
        case .idle(let message): return SimpleLine(id: "status", symbol: nil, text: message)
        case .offline: return SimpleLine(id: "status", symbol: "wifi.slash", text: L("Offline, retrying"))
        case .rateLimited(let message, _): return SimpleLine(id: "status", symbol: "clock.badge.exclamationmark", text: message)
        default: break
        }
        if let first = advice.first {
            return SimpleLine.advice(first)
        }
        if !hideFigures, let window, let pace = MeterRow.paceNote(window: window, runOut: nil, format: format), pace.status != .ahead {
            return SimpleLine(id: "pace", symbol: pace.status.symbolName, text: pace.text, color: pace.status.noteColor)
        }
        if let signal {
            return SimpleLine(id: "signal", symbol: signal.symbolName, text: signal.cardText)
        }
        // No window with a figure: what the card says under its meter instead ("Free plan has nothing to meter yet").
        if window == nil, let note = status.reading?.windows.lazy.compactMap(\.note).first {
            return SimpleLine(id: "note", symbol: nil, text: note)
        }
        return nil
    }
}

/// The cost as one row: what the Cost card's range comes to, in its unit, with the money advice under it, and the
/// last seven days as a strip of bars beside the figure (WeekSpend): today and the six days before it, named day by
/// day when the pointer rests on the row, and drawn as a chart split by assistant at the top of what the row opens
/// onto. Opens onto the Cost card without its box or title. Only built while the Cost card would be
/// (NotchExpandedView.spendCard), so it is gone under the same privacy and settings the card is.
struct SimpleCostRow: View {
    let store: UsageStore
    let actions: NotchActions
    let advice: [Advice]

    private static let key = AdvicePlacement.Slot.cost.key

    var body: some View {
        let open = store.openPanelRows.contains(Self.key)
        let range = store.spendRange
        let selection = store.costSelection
        let totals = selection.isEmpty ? nil : selection.totals(range.costRange)
        let mode = store.prefs.costCardMode
        let figure = SpendCard.headline(mode: mode, amount: totals?.cost, totals: totals)
        let first = open ? nil : advice.first
        let now = Date()
        let week = WeekSpend.of(selection, now: now)
        SimpleRow(title: L("Cost"),
                  line: first.map(SimpleLine.advice),
                  figure: figure, caption: range.title,
                  needsYou: advice.contains { $0.priority == .attention },
                  // The week's headline only: the row is read every time it is reached, and the days one by one
                  // are the opened chart's to read.
                  spoken: Spoken.line(range.title, Spoken.phrase(figure), SpendCard.unit(mode: mode), first.map { Spoken.phrase($0.text) },
                                      week.map { $0.headline(mode: mode) }),
                  accessory: week.map { AnyView(WeekSpendStrip(week: $0, mode: mode)) },
                  help: week?.tooltip(mode: mode, now: now),
                  open: open, toggle: { NotchExpandedView.toggleRow(Self.key, store: store) }) {
            Image(systemName: "dollarsign.circle").foregroundStyle(Caption.style)
        } detail: {
            VStack(alignment: .leading, spacing: 8) {
                SpendCard(store: store, embedded: true)
                if !advice.isEmpty {
                    AdviceLines(advice: advice, open: actions.open)
                }
            }
        }
    }
}

/// The advice about nothing else on the panel, as one quiet row counting it, which opens onto the lines.
struct SimpleNotesRow: View {
    let store: UsageStore
    let actions: NotchActions
    let advice: [Advice]

    private static let key = AdvicePlacement.Slot.notes.key

    var body: some View {
        let open = store.openPanelRows.contains(Self.key)
        let top = advice.map(\.priority).min() ?? .info
        SimpleRow(title: L("Notes"), figure: "\(advice.count)",
                  spoken: Spoken.line("\(advice.count)", open ? nil : advice.map { Spoken.phrase($0.text) }.joined(separator: " ")),
                  open: open, toggle: { NotchExpandedView.toggleRow(Self.key, store: store) }) {
            Image(systemName: advice.first?.symbol ?? "lightbulb")
                .foregroundStyle(top == .info ? AnyShapeStyle(Caption.style) : AnyShapeStyle(top.color))
        } detail: {
            AdviceLines(advice: advice, open: actions.open)
        }
    }
}

/// The small grey name over a section of the Simple panel, on the rows' text edge.
struct SimpleSectionLabel<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.density) private var density

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Caption.style)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            trailing()
        }
        .padding(.horizontal, density.cardPadding)
    }
}

extension SimpleSectionLabel where Trailing == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// The hairline between two sections of the Simple panel; stronger under Increase Contrast.
struct SimpleDivider: View {
    @Environment(\.density) private var density

    var body: some View {
        Rectangle()
            .fill(.white.opacity(AccessibilityDisplay.shared.contrast ? 0.3 : 0.12))
            .frame(height: 1)
            .padding(.horizontal, density.cardPadding)
            .accessibilityHidden(true)
    }
}
