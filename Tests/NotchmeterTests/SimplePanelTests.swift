import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Notchmeter

/// The Simple panel (SimplePanel.swift): every advice line lands on a row the panel has (AdvicePlacement), each
/// tool row stands for its most urgent window (SimpleFigure), the parts and the rules between them
/// (PanelLayout.simpleParts, simpleBreak), and the setting that chooses it (PanelMode).
@Suite struct SimplePanelTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// One line of every kind the Advisor writes, by id shape, with and without a tool.
    var everyKind: [Advice] {
        [
            Advice(id: "waiting/claude", tool: .claude, priority: .attention, symbol: "hand.raised.fill", text: "Claude Code is waiting."),
            Advice(id: "run-out/codex/weekly", tool: .codex, priority: .danger, symbol: "exclamationmark.triangle.fill", text: "Codex runs out."),
            Advice(id: "extra/room", tool: .claude, priority: .danger, symbol: "creditcard", text: "Extra usage rose."),
            Advice(id: "budget/month/over", tool: .cursor, priority: .danger, symbol: "dollarsign.circle.fill", text: "Over budget."),
            Advice(id: "budget/week", tool: nil, priority: .warn, symbol: "dollarsign.circle", text: "On pace to cross the budget."),
            Advice(id: "burn", tool: nil, priority: .warn, symbol: "flame.fill", text: "Every tool together burned."),
            Advice(id: "burn/codex", tool: .codex, priority: .warn, symbol: "flame.fill", text: "Codex burned."),
            Advice(id: "limit/antigravity", tool: .antigravity, priority: .warn, symbol: "clock.arrow.circlepath", text: "Antigravity hit its limit."),
            Advice(id: "route/claude/codex", tool: .claude, priority: .info, symbol: "arrow.triangle.branch", text: "Codex has room."),
            Advice(id: "status/cursor", tool: .cursor, priority: .info, symbol: "antenna.radiowaves.left.and.right.slash", text: "Cursor is degraded."),
            Advice(id: "peak/claude", tool: .claude, priority: .info, symbol: "sun.max", text: "Peak hours."),
            Advice(id: "general", tool: nil, priority: .info, symbol: "lightbulb", text: "Something about nothing on the panel."),
        ]
    }

    /// The guarantee the Simple panel rests on: whatever rows the panel has, every line is on exactly one of them,
    /// in the Advisor's order, and never on a row the panel is not drawing.
    @Test func everyLineLandsOnExactlyOneRowThePanelHas() {
        let toolSets: [[ToolID]] = [[], [.claude], [.claude, .codex], [.codex, .cursor, .antigravity], ToolID.allCases]
        for tools in toolSets {
            for cost in [false, true] {
                for sessions in [false, true] {
                    let placed = AdvicePlacement.assign(everyKind, tools: tools, cost: cost, sessions: sessions)
                    let landed = placed.values.flatMap { $0 }.map(\.id)
                    #expect(landed.count == everyKind.count)
                    #expect(Set(landed) == Set(everyKind.map(\.id)))
                    for (slot, lines) in placed {
                        switch slot {
                        case .tool(let tool): #expect(tools.contains(tool))
                        case .cost: #expect(cost)
                        case .sessions: #expect(sessions)
                        case .notes: break
                        }
                        let order = everyKind.map(\.id).filter { id in lines.contains { $0.id == id } }
                        #expect(lines.map(\.id) == order)
                    }
                }
            }
        }
    }

    @Test func moneyGoesToCostWaitingToSessionsAndTheRestToItsTool() {
        let placed = AdvicePlacement.assign(everyKind, tools: [.claude, .codex, .cursor], cost: true, sessions: true)
        #expect(placed[.cost]?.map(\.id) == ["extra/room", "budget/month/over", "budget/week", "burn", "burn/codex"])
        #expect(placed[.sessions]?.map(\.id) == ["waiting/claude"])
        #expect(placed[.tool(.claude)]?.map(\.id) == ["route/claude/codex", "peak/claude"])
        #expect(placed[.tool(.codex)]?.map(\.id) == ["run-out/codex/weekly"])
        #expect(placed[.tool(.cursor)]?.map(\.id) == ["status/cursor"])
        // Antigravity is not on the panel, and the general line is about nothing on it.
        #expect(placed[.notes]?.map(\.id) == ["limit/antigravity", "general"])
    }

    /// With no cost row the money lines fall back to their tool, and with no tool either to Notes; with no
    /// sessions section the waiting line goes to its tool.
    @Test func aLineWhoseRowIsMissingFallsBackToItsToolThenNotes() {
        let placed = AdvicePlacement.assign(everyKind, tools: [.claude], cost: false, sessions: false)
        #expect(placed[.cost] == nil)
        #expect(placed[.sessions] == nil)
        #expect(placed[.tool(.claude)]?.map(\.id) == ["waiting/claude", "extra/room", "route/claude/codex", "peak/claude"])
        #expect(placed[.notes]?.map(\.id) == ["run-out/codex/weekly", "budget/month/over", "budget/week", "burn", "burn/codex",
                                              "limit/antigravity", "status/cursor", "general"])
    }

    /// The Sessions section draws a waiting line only where the rows under it do not already say it; a line it
    /// leaves off goes on the first row it is about, for VoiceOver. Either way every line is reachable exactly once.
    @Test func aWaitingLineTheRowsAlreadyShowGoesOnTheRow() {
        let waiting = everyKind[0]
        let other = Advice(id: "general", tool: nil, priority: .info, symbol: "lightbulb", text: "Something.")
        let lines = [waiting, other]

        // Every waiting Claude session is a visible row that needs the reader: the line moves onto the first.
        let shown = AdvicePlacement.sessionLines(lines, needsYou: [("a", .claude), ("b", .claude)],
                                                 waiting: [("a", .claude), ("b", .claude)], titlesShown: true)
        #expect(shown.drawn.map(\.id) == ["general"])
        #expect(shown.onRow == ["a": [waiting]])

        // One of them is past the "+N more" cap: the line stays, since no row on the sheet says so for it.
        let capped = AdvicePlacement.sessionLines(lines, needsYou: [("a", .claude)],
                                                  waiting: [("a", .claude), ("z", .claude)], titlesShown: true)
        #expect(capped.drawn.map(\.id) == ["waiting/claude", "general"])
        #expect(capped.onRow.isEmpty)

        // Titles hidden: the line names what the row cannot, so it stays.
        let untitled = AdvicePlacement.sessionLines(lines, needsYou: [("a", .claude)], waiting: [("a", .claude)], titlesShown: false)
        #expect(untitled.drawn.map(\.id) == ["waiting/claude", "general"])

        // A tool waiting with no session the hooks reported, or a row of another tool: the line stays.
        let noSession = AdvicePlacement.sessionLines(lines, needsYou: [("c", .codex)], waiting: [("c", .codex)], titlesShown: true)
        #expect(noSession.drawn.map(\.id) == ["waiting/claude", "general"])

        // Whatever the case, each line is drawn or on exactly one row that needs the reader.
        for split in [shown, capped, untitled, noSession] {
            let reached = split.drawn.map(\.id) + split.onRow.values.flatMap { $0 }.map(\.id)
            #expect(reached.sorted() == lines.map(\.id).sorted())
        }
    }

    /// An attention line keeps its blue on the symbol and reads in the text colour: Palette.calm text is under 4.5:1.
    @MainActor @Test func anAttentionLineIsBlueOnlyOnItsSymbol() {
        let line = SimpleLine.advice(everyKind[0])
        #expect(line.color == .primary)
        #expect(line.symbolColor == Palette.calm)
        #expect(SimpleLine.advice(everyKind[1]).color == Palette.danger)
        #expect(SimpleLine.advice(everyKind[8]).color == nil)
    }

    func window(_ id: String, used: Double?, hoursLeft: Double = 24, period: TimeInterval = Period.week) -> LimitWindow {
        LimitWindow(id: id, label: WindowLabel(stringLiteral: id), usedFraction: used, resetsAt: now.addingTimeInterval(hoursLeft * 3600), periodDuration: period)
    }

    /// The row's figure is the most urgent window, and the most used among equally urgent ones; a comparison and a
    /// window with no figure are never it.
    @Test func theFigureIsTheMostUrgentWindow() {
        // Half the week gone: 30% used is ahead, 55% used is behind pace.
        let calm = window("weekly", used: 0.3, hoursLeft: 84)
        let behind = window("fable", used: 0.55, hoursLeft: 84)
        let fuller = window("session", used: 0.8, hoursLeft: 4, period: Period.fiveHours)
        #expect(SimpleFigure.window(of: [calm, behind], now: now)?.id == "fable")
        #expect(SimpleUrgency.of(behind, now: now) == .danger)
        #expect(SimpleUrgency.of(calm, now: now) == .calm)
        // Ahead of pace but four fifths used, beside a calmer window: the most used wins the tie.
        #expect(SimpleFigure.window(of: [calm, fuller], now: now)?.id == "session")
        let comparison = LimitWindow(id: "spend_today", label: "Today", usedFraction: 1.4, resetsAt: now.addingTimeInterval(3600),
                                     periodDuration: 86_400)
        #expect(SimpleFigure.window(of: [comparison, window("none", used: nil)], now: now) == nil)
        #expect(SimpleUrgency.of(window("spent", used: 1), now: now) == .danger)
        #expect(SimpleUrgency.of(window("near", used: 0.92, hoursLeft: 1), now: now) == .warn)
    }

    @Test func theFigureFollowsUsedOrLeft() {
        let weekly = window("Weekly", used: 0.62)
        #expect(SimpleFigure.text(weekly, display: .used)?.figure == "62%")
        #expect(SimpleFigure.text(weekly, display: .left)?.figure == "38%")
        #expect(SimpleFigure.text(weekly, display: .left)?.caption == L("%@ left", weekly.label))
        #expect(SimpleFigure.text(window("x", used: nil), display: .used) == nil)
    }

    /// Every urgent state carries a symbol as well as its colour.
    @Test func noUrgentStateIsToldByColourAlone() {
        for urgency in [SimpleUrgency.warn, .danger] {
            #expect(urgency.symbolName != nil)
            #expect(urgency.color != nil)
        }
        #expect(SimpleUrgency.calm.symbolName == nil)
    }

    @Test func theSimplePanelHasNoFooterAndNotesSitLast() {
        let parts = PanelLayout.simpleParts(prompt: true, spend: true, notes: true, sessions: true, connect: false,
                                            tools: [.claude, .codex], addTool: true).map(\.name)
        #expect(parts == ["header", "prompt", "tool:claude", "tool:codex", "cost", "sessions", "notes", "addTool"])
        let bare = PanelLayout.simpleParts(prompt: false, spend: false, notes: false, sessions: false, connect: true,
                                           tools: [], addTool: false).map(\.name)
        #expect(bare == ["header", "connect"])
    }

    @Test func rulesSitBetweenSectionsAndNeverInsideOne() {
        #expect(PanelLayout.simpleBreak(before: .header, after: nil) == .none)
        #expect(PanelLayout.simpleBreak(before: .tool(.claude), after: .header) == .space)
        #expect(PanelLayout.simpleBreak(before: .tool(.codex), after: .tool(.claude)) == .none)
        #expect(PanelLayout.simpleBreak(before: .spend, after: .tool(.codex)) == .divider)
        #expect(PanelLayout.simpleBreak(before: .sessions, after: .spend) == .divider)
        #expect(PanelLayout.simpleBreak(before: .addTool, after: .notes) == .space)
    }

    /// Simple is the default, for a new install and for everyone who never chose, and the choice is kept.
    @MainActor @Test func simpleIsTheDefaultAndTheChoiceIsKept() {
        let suite = "NotchmeterTests.PanelMode"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = UserDefaults(suiteName: suite)!
        #expect(Preferences(defaults: defaults).panelMode == .simple)
        Preferences(defaults: defaults).panelMode = .detailed
        #expect(Preferences(defaults: defaults).panelMode == .detailed)
    }

    /// A tool row whose tool is signed out asks for the reader, and its line says why with a symbol.
    @MainActor @Test func aProblemLeadsTheRowWithItsSymbol() {
        let status = ToolStatus.needsAttention("Sign in again", cached: nil)
        #expect(SimpleToolRow.needsYou(status: status, advice: []))
        let line = SimpleToolRow.line(status: status, advice: everyKind, window: nil, signal: nil, hideFigures: false, format: .auto)
        #expect(line?.text == "Sign in again")
        #expect(line?.symbol != nil)
        let advised = SimpleToolRow.line(status: .ready(UsageReading(tool: .claude, windows: [], plan: nil, fetchedAt: now, observedAt: nil)), advice: [everyKind[1]],
                                         window: nil, signal: nil, hideFigures: false, format: .auto)
        #expect(advised?.id == "run-out/codex/weekly")
    }

    /// Both layouts size to their content and are capped like the panel always was (ExpandedPanelHeight), and a
    /// row opened in place grows the measured panel, which is what makes the window grow with it.
    @MainActor @Test func theSimplePanelSizesAndAnOpenRowGrowsIt() {
        let (store, prefs) = DemoFixtures.store(now: Date())
        let actions = NotchActions()
        #expect(prefs.panelMode == .simple)
        let simple = fittingHeight(NotchExpandedView(store: store, prefs: prefs, actions: actions, maxHeight: 10_000))
        #expect(simple > 100)
        #expect(fittingHeight(NotchExpandedView(store: store, prefs: prefs, actions: actions, maxHeight: 80)) == 80)
        store.openPanelRows.insert(AdvicePlacement.Slot.tool(.claude).key)
        let opened = fittingHeight(NotchExpandedView(store: store, prefs: prefs, actions: actions, maxHeight: 10_000))
        #expect(opened > simple)
        store.openPanelRows = []
        prefs.panelMode = .detailed
        let detailed = fittingHeight(NotchExpandedView(store: store, prefs: prefs, actions: actions, maxHeight: 10_000))
        #expect(detailed > simple)
        prefs.panelMode = .simple
    }

    @MainActor private func fittingHeight(_ view: NotchExpandedView) -> CGFloat {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }
}
