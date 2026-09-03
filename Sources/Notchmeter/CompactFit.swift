import CoreGraphics

/// What the readouts beside the notch are actually drawn as: which side of it, at which style, and how many of the
/// ordered tools (Preferences.toolOrder) survive. `dropped` is how many were left out, shown as a quiet "+2" after
/// the last readout.
///
/// The menu bar squeezes from both ends — menu titles growing rightwards from the left, status items growing
/// leftwards from the right — so picking a side is not enough: the strip has to fit the gap that is actually free,
/// and shrink when neither gap can hold it.
struct CompactFit: Equatable {
    var side: CompactSide
    var style: CompactStyle
    /// How many tools are drawn. `.max` when the fit was never narrowed, so every visible tool is kept.
    var toolCount: Int
    var dropped: Int
    /// How many of the kept run go left of the notch under `.split`; nil outside Auto, and for a single side.
    var splitLeading: Int?

    /// Every tool at the chosen style: a fixed side, or Auto with nothing measured.
    static func whole(side: CompactSide, style: CompactStyle) -> CompactFit {
        CompactFit(side: side, style: style, toolCount: .max, dropped: 0, splitLeading: nil)
    }

    /// How much clear room the strip asks for between the nearest menu bar item and its first readout. It is a
    /// safety margin, not a taste: the measurements it is applied to are floors, not exact edges.
    static let clearance: CGFloat = 8

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
    /// Candidates are tried in the order the reduction should be felt: both sides of the notch first, then the
    /// roomier single side; the chosen style first, then rings; and only then tools dropped from the end of the
    /// order, so the tools the user put first are the ones that survive. Which side of the notch a readout is
    /// drawn on is not among the things a measurement is allowed to change: every split is the resting one, and a
    /// half that will not fit costs the strip a rung of this ladder rather than sending a readout across the
    /// notch. Never answers `.auto`, and never returns a fit that overlaps — when nothing fits, it answers with
    /// the smallest strip there is.
    static func resolve(notch: CGRect, menusEndX: CGFloat?, statusItemsStartX: CGFloat?, tools: Int,
                        style: CompactStyle, width: (Run) -> CGFloat) -> CompactFit {
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

        func rung(_ side: CompactSide, _ style: CompactStyle, _ count: Int) -> CompactFit {
            CompactFit(side: side, style: style, toolCount: count, dropped: tools - count,
                       splitLeading: side == .split ? splitLeadingCount(of: count) : nil)
        }

        let smallest: CompactStyle = .rings
        var steps = style == smallest ? [(style, tools)] : [(style, tools), (smallest, tools)]
        steps += stride(from: tools - 1, through: 1, by: -1).map { (smallest, $0) }
        let ladder = steps.flatMap { candidate, count in
            [rung(.split, candidate, count), rung(roomier, candidate, count), rung(other, candidate, count)]
        }
        return ladder.first(where: fits) ?? rung(roomier, smallest, 1)
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
    /// tools, at which style, followed by how many the strip left out.
    ///
    /// `readouts` is a range and not a count because the two halves do not draw the same readouts. The half right
    /// of the notch draws the *last* of them, and readouts are not all one width — at rings with numbers the
    /// author's first tool measures 76 pt and the other two 58 each, so "two readouts" is three different widths
    /// depending on which two.
    struct Run: Equatable {
        var style: CompactStyle
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
    /// send the ladder down a rung it would otherwise have skipped; it cannot let a fit overlap.
    func halves(visible: Int) -> (leading: Run, trailing: Run) {
        let kept = max(0, min(toolCount, visible))
        let dropped = visible - kept
        let nothing = Run(style: style, readouts: 0 ..< 0, overflow: 0)
        switch side {
        case .leading:
            return (Run(style: style, readouts: 0 ..< kept, overflow: dropped), nothing)
        case .trailing:
            return (nothing, Run(style: style, readouts: 0 ..< kept, overflow: dropped))
        case .split, .auto:
            let leading = min(max(splitLeading ?? CompactFit.splitLeadingCount(of: kept), 0), kept)
            return (Run(style: style, readouts: 0 ..< leading, overflow: leading == kept ? dropped : 0),
                    Run(style: style, readouts: leading ..< kept, overflow: leading == kept ? 0 : dropped))
        }
    }
}
