import CoreGraphics

/// What the readouts beside the notch are actually drawn as: which side of it, at which style, how much of each
/// readout's digits (`figures`), and how many of the ordered tools (Preferences.toolOrder) survive. `dropped` is
/// how many were left out, shown as a quiet "+2" after the last readout.
///
/// The menu bar squeezes from both ends — menu titles growing rightwards from the left, status items growing
/// leftwards from the right — so picking a side is not enough: the strip has to fit the gap that is actually free,
/// and shrink when neither gap can hold it.
///
/// Two things are always true of a fit: `style == .rings` means `figures == .all`, because bare rings have no
/// digits to thin; and `figures == .outer` means the style draws both a ring and its numbers, because the outer
/// figure is the one the ring is for and has nothing to stand beside otherwise.
struct CompactFit: Equatable {
    var side: CompactSide
    var style: CompactStyle
    /// How much of each readout's digits this fit keeps (Figures). Only a style that shows numbers beside a ring
    /// has any to thin; at plain rings and at digits alone it is `.all` and means nothing.
    var figures: Figures = .all
    /// How many tools are drawn. `.max` when the fit was never narrowed, so every visible tool is kept.
    var toolCount: Int
    var dropped: Int
    /// How many of the kept run go left of the notch under `.split`; nil outside Auto, and for a single side.
    var splitLeading: Int?

    /// Which of a readout's figures are drawn. `.outer` is a rung of Auto's ladder and nothing the user picks:
    /// every ring keeps the percentage of its outer window alone — the first of Preferences.ringWindows, which for
    /// Claude is the session unless the rings were reordered — with no separator, no second figure and no reset
    /// countdown, so a squeeze costs the weekly number first and the session number last. Two values rather than three: bare rings are already said
    /// by `style == .rings`, and a `.none` here would be a second way to spell the same drawing.
    enum Figures: String, Equatable {
        case all, outer
    }

    /// Every tool at the chosen style: a fixed side, or Auto with nothing measured.
    static func whole(side: CompactSide, style: CompactStyle) -> CompactFit {
        CompactFit(side: side, style: style, toolCount: .max, dropped: 0, splitLeading: nil)
    }

    /// How much clear room the strip asks for between the nearest menu bar item and its first readout. It is a
    /// safety margin, not a taste: the measurements it is applied to are floors, not exact edges.
    static let clearance: CGFloat = 8

    /// One rung of the ladder before it is dealt out across the sides: a style, how much of its digits, and how many
    /// tools survive at it.
    struct Step: Equatable {
        var style: CompactStyle
        var figures: Figures
        var count: Int
    }

    /// The order the reduction is felt in, before each step is tried on both sides, then the roomier one, then the
    /// other. The levels a style can be thinned through are the chosen style whole; the outer figure alone, where
    /// there is a ring for it to sit beside; then plain rings. Keeping the tools walks those levels with every tool
    /// intact and only at rings starts dropping tools from the end of the order. Keeping the numbers drops tools
    /// at each level first, fullest level first, so a figure is thinned only once a single readout at the fuller
    /// level would not fit — and the last thing to go is still one ring on the roomier side.
    ///
    /// Digits alone have no outer rung: a ring beside one figure is not a smaller version of a readout that had no
    /// ring, it is a different shape the user did not choose, and it is barely narrower.
    static func steps(style: CompactStyle, tools: Int, keep: CompactKeep) -> [Step] {
        guard tools > 0 else { return [] }
        var levels = [Step(style: style, figures: .all, count: tools)]
        if style.showsRings, style.showsNumbers { levels.append(Step(style: style, figures: .outer, count: tools)) }
        if style != .rings { levels.append(Step(style: .rings, figures: .all, count: tools)) }
        switch keep {
        case .tools:
            return levels + (1 ..< tools).reversed().map { Step(style: .rings, figures: .all, count: $0) }
        case .numbers:
            return levels.flatMap { level in (1 ... tools).reversed().map { Step(style: level.style, figures: level.figures, count: $0) } }
        }
    }

    /// The whole rule, kept pure so it can be tested without a menu bar.
    ///
    /// `menusEndX` is how far right the frontmost app's menu titles reach and `statusItemsStartX` how far left the
    /// leftmost menu bar extra reaches (MenuBarExtent); either is nil when it could not be measured, which leaves
    /// that side unconstrained rather than guessed at. Both nil is "nothing measured" — Accessibility not granted,
    /// or revoked — and leaves the strip centred on the notch with every tool intact.
    ///
    /// `width` sizes one side of the notch: the room a `Run` takes, drawn exactly as that side will draw it. It is
    /// asked once per half of every candidate considered, and never for a half that draws nothing. An empty half
    /// is exempted by asking the run whether it is empty rather than by measuring it, because a room can be
    /// negative — a menu bar whose titles run past the notch leaves −252 pt on the left — and `0 <= -252` is
    /// false, which would reject every fit that draws nothing on that side.
    ///
    /// Candidates are tried in the order the reduction should be felt (`steps`): both sides of the notch first,
    /// then the roomier single side, then the other, at every step of the ladder before the next step is tried.
    /// Keeping the tools, the default, thins the style with every tool intact — the chosen style, then each ring
    /// with its outer figure alone, then plain rings — and only then drops tools from the end of the order, so
    /// the tools the user put first are the ones that survive. Keeping the numbers drops tools from the end of the
    /// order at the chosen style first, and thins the style only once a single readout at the fuller level would
    /// not fit, so the tools that stay keep their figures. The outer-figure rung is there because the ladder used
    /// to go straight from the chosen style to bare rings, which threw away every number while keeping every tool
    /// — three mute rings where there was room for a couple of figures. The outer figure is the one the ring is
    /// for, so it is the one that stays; digits alone have no such rung, because a ring beside one figure is not a
    /// smaller version of a readout that had no ring, and it is barely narrower. Which side of the notch a readout
    /// is drawn on is not among the things a measurement is allowed to change: every split is the resting one,
    /// and a half that will not fit costs the strip a rung of this ladder rather than sending a readout across the
    /// notch. Never answers `.auto`, and never returns a fit that overlaps — when nothing fits, it answers with
    /// the smallest strip there is.
    static func resolve(notch: CGRect, menusEndX: CGFloat?, statusItemsStartX: CGFloat?, tools: Int,
                        style: CompactStyle, keep: CompactKeep, width: (Run) -> CGFloat) -> CompactFit {
        guard tools > 0, menusEndX != nil || statusItemsStartX != nil else { return .whole(side: .split, style: style) }

        let leadingRoom = menusEndX.map { notch.minX - clearance - $0 } ?? .greatestFiniteMagnitude
        let trailingRoom = statusItemsStartX.map { $0 - clearance - notch.maxX } ?? .greatestFiniteMagnitude
        let roomier: CompactSide = leadingRoom >= trailingRoom ? .leading : .trailing
        let other: CompactSide = roomier == .leading ? .trailing : .leading

        func holds(_ run: Run, in room: CGFloat) -> Bool { run.isEmpty || width(run) <= room }

        func fits(_ candidate: CompactFit) -> Bool {
            let halves = candidate.halves(visible: tools)
            return holds(halves.leading, in: leadingRoom) && holds(halves.trailing, in: trailingRoom)
        }

        func rung(_ side: CompactSide, _ step: Step) -> CompactFit {
            CompactFit(side: side, style: step.style, figures: step.figures, toolCount: step.count, dropped: tools - step.count,
                       splitLeading: side == .split ? splitLeadingCount(of: step.count) : nil)
        }

        let ladder = steps(style: style, tools: tools, keep: keep).flatMap { step in
            [rung(.split, step), rung(roomier, step), rung(other, step)]
        }
        return ladder.first(where: fits) ?? rung(roomier, Step(style: .rings, figures: .all, count: 1))
    }

    /// How many of a run go left of the notch when both ends allow it: half, and an odd run's extra readout to
    /// the right. NotchCompactView splits it the same way, so a centred layout — which has no menu bar
    /// measurement to work from at all — rests in the same shape Auto rests in.
    ///
    /// The extra goes right because the two ends are not alike. The left is where the frontmost app's menu titles
    /// grow, and they change length on every app switch; the right holds status items, which the user arranges
    /// and which then sit still. Keeping the lighter half on the moving end is what lets one arrangement stand
    /// for most of the day.
    static func splitLeadingCount(of count: Int) -> Int { count / 2 }
}


extension CompactFit {
    /// One side of the notch's worth of readouts, exactly as that side will draw them: which slice of the visible
    /// tools, at which style and how much of its digits, followed by how many the strip left out.
    ///
    /// `readouts` is a range and not a count because the two halves do not draw the same readouts. The half right
    /// of the notch draws the *last* of them, and readouts are not all one width — at rings with numbers the
    /// author's first tool measures 76 pt and the other two 58 each, so "two readouts" is three different widths
    /// depending on which two.
    struct Run: Equatable {
        var style: CompactStyle
        var figures: Figures = .all
        var readouts: Range<Int>
        var overflow: Int
        var isEmpty: Bool { readouts.isEmpty && overflow == 0 }
    }

    /// The two runs this fit draws: what goes left of the notch and what goes right of it. `visible` is how many
    /// readouts there are to divide, which is `UsageStore.compactTools(style:).count` where the strip is drawn.
    ///
    /// The view and the fitting rule both come through here, so a candidate is measured as the thing it would be
    /// drawn as. That is the point of it. The probe used to be handed a style and a tool count and left to invent
    /// the rest, and what it invented was a "+2" chip on every half of every split — 41 pt of readout that would
    /// never be drawn, charged against a right-hand gap of 136 pt, which is what made the resting split look
    /// impossible on a bar that had room for it.
    ///
    /// `resolve` passes the count at the *preferred* style rather than at each candidate's, because that is the
    /// one number the probe can offer without laying out a view per rung. The two diverge in a single case —
    /// `UsageStore.compactTools(style:)` drops Claude at plain rings while it is on an API key — and there the
    /// rings rungs are measured carrying an overflow chip they will not draw. That over-measures, so it can only
    /// send the ladder down a rung it would otherwise have skipped; it cannot let a fit overlap. The outer-figure
    /// rung adds no second case: its style is the chosen style, so its count is the count it was measured at.
    func halves(visible: Int) -> (leading: Run, trailing: Run) {
        let kept = max(0, min(toolCount, visible))
        let dropped = visible - kept
        let nothing = Run(style: style, figures: figures, readouts: 0 ..< 0, overflow: 0)
        switch side {
        case .leading:
            return (Run(style: style, figures: figures, readouts: 0 ..< kept, overflow: dropped), nothing)
        case .trailing:
            return (nothing, Run(style: style, figures: figures, readouts: 0 ..< kept, overflow: dropped))
        case .split, .auto:
            let leading = min(max(splitLeading ?? CompactFit.splitLeadingCount(of: kept), 0), kept)
            return (Run(style: style, figures: figures, readouts: 0 ..< leading, overflow: leading == kept ? dropped : 0),
                    Run(style: style, figures: figures, readouts: leading ..< kept, overflow: leading == kept ? 0 : dropped))
        }
    }
}
