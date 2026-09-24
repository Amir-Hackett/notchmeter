import Foundation

/// One part of the open panel, in the order `PanelLayout.parts` puts them. The panel is read top down at a glance,
/// so the order is the priority: whatever sits first is what the reader takes in before the pointer leaves.
enum PanelPart: Hashable, Sendable {
    /// The bar above the cards: the session count and the Dashboard, Settings and Options buttons.
    case header
    /// A request an assistant is holding a session for (PromptCard).
    case prompt
    /// The one card a glance opens on (NoticeCard). Never in `PanelLayout.parts`: a notice opening draws it alone,
    /// and the oracle names it so.
    case notice
    case spend
    case advice
    case sessions
    /// "Connect an assistant to get started", while no assistant is carried at all.
    case connect
    case tool(ToolID)
    /// "Add a tool", naming the assistants `Preferences.hideEmptyTools` keeps off the panel.
    case addTool
    /// The refresh line.
    case footer
    /// The Simple panel's one row for the advice that belongs to no other row (AdvicePlacement).
    case notes

    /// The part's name in the oracle's `panel` line and snapshot.
    var name: String {
        switch self {
        case .header: "header"
        case .prompt: "prompt"
        case .notice: "notice"
        case .spend: "cost"
        case .advice: "advice"
        case .sessions: "sessions"
        case .connect: "connect"
        case .tool(let tool): "tool:\(tool.rawValue)"
        case .addTool: "addTool"
        case .footer: "footer"
        case .notes: "notes"
        }
    }
}

/// The order of the open panel, apart from the view that draws it so the rule can be tested without one.
enum PanelLayout {
    /// Whether the Sessions card goes above the Cost card: while any session is working, waiting on the reader or
    /// holding a request. A session doing something is the one thing on the panel that changes minute to minute and
    /// may want an answer, so it is what the eye should land on; a list of idle and finished sessions says nothing
    /// that needs reading before the spend, and it goes back under the Advice strip where it always sat.
    ///
    /// A just-finished session does not lead: the ring's tick and the notification have already said it, and a
    /// card jumping to the top for ninety seconds after every turn would move the Cost card out from under a
    /// reader who opened the panel to read it.
    static func sessionsLead(_ sessions: [AgentSession]) -> Bool {
        sessions.contains { $0.isWorking || $0.isWaiting || $0.pending != nil }
    }

    /// The parts of the whole panel, top to bottom. The prompt-only and notice-only openings
    /// (UsageStore.panelOpenedForPrompt, UsageStore.attentionNotice) draw their one card and are not laid out here.
    static func parts(prompt: Bool, spend: Bool, advice: Bool, sessions: Bool, sessionsLead: Bool, connect: Bool,
                      tools: [ToolID], addTool: Bool) -> [PanelPart] {
        var parts: [PanelPart] = [.header]
        if prompt { parts.append(.prompt) }
        let leads = sessions && sessionsLead
        if leads { parts.append(.sessions) }
        if spend { parts.append(.spend) }
        if advice { parts.append(.advice) }
        if sessions, !leads { parts.append(.sessions) }
        if connect { parts.append(.connect) }
        parts += tools.map(PanelPart.tool)
        if addTool { parts.append(.addTool) }
        parts.append(.footer)
        return parts
    }
}

extension PanelLayout {
    /// The Simple panel's parts, top to bottom (PanelMode.simple): the header, a request, one row per assistant,
    /// the cost row, the sessions, the notes, and the quiet "Add a tool". No footer: its refresh line is in the
    /// header. The order is fixed rather than moving the sessions up while one works: every part above them is a
    /// row, not a card, so they are never more than a few lines down, and a panel whose order changes with what is
    /// running is one the eye has to find its place in again.
    static func simpleParts(prompt: Bool, spend: Bool, notes: Bool, sessions: Bool, connect: Bool,
                            tools: [ToolID], addTool: Bool) -> [PanelPart] {
        var parts: [PanelPart] = [.header]
        if prompt { parts.append(.prompt) }
        if connect { parts.append(.connect) }
        parts += tools.map(PanelPart.tool)
        if spend { parts.append(.spend) }
        if sessions { parts.append(.sessions) }
        if notes { parts.append(.notes) }
        if addTool { parts.append(.addTool) }
        return parts
    }

    /// What goes above a part on the Simple panel: nothing inside a section (its rows carry their own spacing), a
    /// hairline between two sections, and room alone under the header and the request card, which already stand
    /// apart. "Add a tool" takes room and no rule: it is a footnote to the rows above, not a section.
    enum SimpleBreak: Equatable { case none, space, divider }

    static func simpleBreak(before part: PanelPart, after previous: PanelPart?) -> SimpleBreak {
        guard let previous else { return .none }
        if part == .addTool { return .space }
        if previous == .header || previous == .prompt || part == .prompt { return .space }
        return section(part) == section(previous) ? .none : .divider
    }

    private static func section(_ part: PanelPart) -> Int {
        switch part {
        case .header: 0
        case .prompt, .notice: 1
        case .connect, .tool: 2
        case .spend: 3
        case .sessions: 4
        case .notes: 5
        case .addTool, .footer: 6
        case .advice: 7
        }
    }
}

/// The open and close timings of the panel, and the stagger its parts arrive with.
///
/// The open is two beats: the shape comes down out of the notch (DynamicNotchKit's 0.4 s spring), and once it has
/// landed the parts settle into it one after another, top first, so the eye is led down the panel instead of being
/// handed all of it in one frame. The close is one beat and quicker, about two thirds of the open: a panel being
/// dismissed has already been read, and a slow exit is time the reader spends waiting for it to get out of the way.
///
/// None of it holds up a click. A part starts at a sliver of opacity rather than none, so it is hit-testable from
/// the first frame. The stagger itself, from the first part starting to the last one settled, runs in under 300 ms
/// (about 270); counted from the panel appearing, which is when a reader starts waiting, every part has settled by
/// the time the shape's own spring is over, about 0.39 s against its 0.4. Under Reduce Motion there is no stagger
/// and no spring: the panel is simply there.
enum PanelMotion {
    /// DynamicNotchKit's own opening spring (DynamicNotchStyle.openingAnimation), which the notch layout keeps.
    static let open: TimeInterval = 0.4
    /// The close, as a share of the open.
    static let closeShare = 0.65
    static var close: TimeInterval { open * closeShare }

    /// How long after the panel appears the first part starts: the bouncy spring has covered most of its travel by
    /// then, so the parts arrive into a shape that is there rather than one still growing round them.
    static let landing: TimeInterval = 0.12
    /// The gap between one part starting and the next.
    static let step: TimeInterval = 0.055
    /// How long one part takes to fade and slide in.
    static let fade: TimeInterval = 0.16
    /// The stagger's whole run, from the first part starting to the last one settled, stays under this.
    static let budget: TimeInterval = 0.3
    /// Counted from the panel appearing, the last part has settled by this: the open itself, so the parts are done
    /// no later than the shape they arrive into.
    static var settleBudget: TimeInterval { open }
    /// How far above its place a part starts, in points.
    static let rise: CGFloat = 6
    /// A part's opacity before it arrives: low enough to read as absent, high enough that a click on it still lands.
    static let hiddenOpacity: Double = 0.02

    /// The last position that still gets a beat of its own; everything below it arrives with it. A tall panel has
    /// ten or more parts, and a beat for each would run past the budgets or shrink the step until no stagger could
    /// be seen. The top of the panel, where the eye starts, is where the stagger is felt. The beats fit both
    /// budgets: the run's own, and the settle counted from the panel appearing.
    static var lastStaggered: Int {
        let beats = min(budget - fade, settleBudget - landing - fade) / step
        return max(0, Int(beats.rounded(.down)))
    }

    /// When the last part has settled, counted from the panel appearing.
    static var settled: TimeInterval { delay(index: lastStaggered) + fade }

    /// When the part at `index` starts, counted from the panel appearing.
    static func delay(index: Int) -> TimeInterval {
        landing + step * Double(min(max(0, index), lastStaggered))
    }
}
