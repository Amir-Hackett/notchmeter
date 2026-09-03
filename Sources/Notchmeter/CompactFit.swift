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

    /// Every tool at the chosen style: a fixed side, or Auto with nothing measured.
    static func whole(side: CompactSide, style: CompactStyle) -> CompactFit {
        CompactFit(side: side, style: style, toolCount: .max, dropped: 0)
    }

    /// How much clear room the strip asks for between the nearest menu bar item and its first readout. It is a
    /// safety margin, not a taste: the measurements it is applied to are floors, not exact edges.
    static let clearance: CGFloat = 8

    /// The whole rule, kept pure so it can be tested without a menu bar.
    ///
    /// `menusEndX` is how far right the frontmost app's menu titles reach and `statusItemsStartX` how far left the
    /// leftmost menu bar extra reaches (MenuBarExtent); either is nil when it could not be measured, which leaves
    /// that side unconstrained rather than guessed at. Both nil is "nothing measured" — Accessibility not granted,
    /// or revoked — and keeps the fixed side chosen before Auto with every tool intact.
    ///
    /// `width` sizes the strip: the room a run of the first *n* tools needs at a style, padding included. It is
    /// asked for the halves under `.split` and the whole run under a single side, and it is asked only for the
    /// candidates actually considered.
    ///
    /// Candidates are tried in the order the reduction should be felt: both sides of the notch first, then the
    /// roomier single side; the chosen style first, then rings; and only then tools dropped from the end of the
    /// order, so the tools the user put first are the ones that survive. Never answers `.auto`, and never returns
    /// a fit that overlaps — when nothing fits, it answers with the smallest strip there is.
    static func resolve(notch: CGRect, menusEndX: CGFloat?, statusItemsStartX: CGFloat?, tools: Int,
                        style: CompactStyle, fallback: CompactSide,
                        width: (CompactStyle, Int) -> CGFloat) -> CompactFit {
        let fixed: CompactSide = fallback == .auto ? .split : fallback
        guard tools > 0, menusEndX != nil || statusItemsStartX != nil else { return .whole(side: fixed, style: style) }

        let leadingRoom = menusEndX.map { notch.minX - clearance - $0 } ?? .greatestFiniteMagnitude
        let trailingRoom = statusItemsStartX.map { $0 - clearance - notch.maxX } ?? .greatestFiniteMagnitude
        let roomier: CompactSide = leadingRoom >= trailingRoom ? .leading : .trailing
        let sides: [CompactSide] = [.split, roomier, roomier == .leading ? .trailing : .leading]

        func fits(_ side: CompactSide, _ style: CompactStyle, _ count: Int) -> Bool {
            switch side {
            case .leading: width(style, count) <= leadingRoom
            case .trailing: width(style, count) <= trailingRoom
            case .split, .auto:
                width(style, splitLeadingCount(of: count)) <= leadingRoom
                    && width(style, count - splitLeadingCount(of: count)) <= trailingRoom
            }
        }

        let smallest: CompactStyle = .rings
        var ladder = style == smallest ? [(style, tools)] : [(style, tools), (smallest, tools)]
        ladder += stride(from: tools - 1, through: 1, by: -1).map { (smallest, $0) }
        for (candidate, count) in ladder {
            for side in sides where fits(side, candidate, count) {
                return CompactFit(side: side, style: candidate, toolCount: count, dropped: tools - count)
            }
        }
        return CompactFit(side: roomier, style: smallest, toolCount: 1, dropped: tools - 1)
    }

    /// How many of a run go left of the notch under `.split`; NotchCompactView splits it the same way.
    static func splitLeadingCount(of count: Int) -> Int {
        Int((Double(count) / 2).rounded())
    }
}
