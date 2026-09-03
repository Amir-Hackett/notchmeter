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
    /// `width` sizes the strip: the room a run of the first *n* tools needs at a style, padding included. It is
    /// asked for the halves under `.split` and the whole run under a single side, and it is asked only for the
    /// candidates actually considered.
    ///
    /// Candidates are tried in the order the reduction should be felt: both sides of the notch first, then the
    /// roomier single side; the chosen style first, then rings; and only then tools dropped from the end of the
    /// order, so the tools the user put first are the ones that survive. Never answers `.auto`, and never returns
    /// a fit that overlaps — when nothing fits, it answers with the smallest strip there is.
    static func resolve(notch: CGRect, menusEndX: CGFloat?, statusItemsStartX: CGFloat?, tools: Int,
                        style: CompactStyle, width: (CompactStyle, Int) -> CGFloat) -> CompactFit {
        guard tools > 0, menusEndX != nil || statusItemsStartX != nil else { return .whole(side: .split, style: style) }

        let leadingRoom = menusEndX.map { notch.minX - clearance - $0 } ?? .greatestFiniteMagnitude
        let trailingRoom = statusItemsStartX.map { $0 - clearance - notch.maxX } ?? .greatestFiniteMagnitude
        let roomier: CompactSide = leadingRoom >= trailingRoom ? .leading : .trailing
        let sides: [CompactSide] = [.split, roomier, roomier == .leading ? .trailing : .leading]

        func fits(_ side: CompactSide, _ style: CompactStyle, _ count: Int) -> Bool {
            switch side {
            case .leading: width(style, count) <= leadingRoom
            case .trailing: width(style, count) <= trailingRoom
            case .split, .auto: leadingCount(style, count) != nil
            }
        }

        /// How many go left under `.split`, or nil when neither arrangement fits between the ends.
        ///
        /// The resting split is tried first and its mirror only if the resting one will not fit, so the strip
        /// holds one shape until an end genuinely stops it. Comparing the two gaps instead and handing the extra
        /// readout to whichever measured larger is what made the arrangement restless: a difference of a few
        /// points — one status item appearing, one app's menus being a word shorter — flipped a readout across
        /// the notch while both halves still fitted perfectly well where they were.
        func leadingCount(_ style: CompactStyle, _ count: Int) -> Int? {
            func holds(_ leading: Int) -> Bool {
                width(style, leading) <= leadingRoom && width(style, count - leading) <= trailingRoom
            }
            let resting = splitLeadingCount(of: count)
            if holds(resting) { return resting }
            let mirrored = count - resting
            return mirrored != resting && holds(mirrored) ? mirrored : nil
        }

        let smallest: CompactStyle = .rings
        var ladder = style == smallest ? [(style, tools)] : [(style, tools), (smallest, tools)]
        ladder += stride(from: tools - 1, through: 1, by: -1).map { (smallest, $0) }
        for (candidate, count) in ladder {
            for side in sides where fits(side, candidate, count) {
                return CompactFit(side: side, style: candidate, toolCount: count, dropped: tools - count,
                                  splitLeading: side == .split ? leadingCount(candidate, count) : nil)
            }
        }
        return CompactFit(side: roomier, style: smallest, toolCount: 1, dropped: tools - 1, splitLeading: nil)
    }

    /// How many of a run go left of the notch when both ends allow it: half, and an odd run's extra readout to
    /// the right. NotchCompactView splits it the same way, so a centred layout — which has no menu bar
    /// measurement to work from at all — rests in the same shape Auto rests in.
    ///
    /// The extra goes right because the two ends are not alike. The left is where the frontmost app's menu titles
    /// grow, and they change length on every app switch; the right holds status items, which the user arranges
    /// and which then sit still. Keeping the lighter half on the moving end is what lets one arrangement stand
    /// for most of the day. `CompactFit.resolve` mirrors it when the right will not hold its half, and only then.
    static func splitLeadingCount(of count: Int) -> Int { count / 2 }
}
