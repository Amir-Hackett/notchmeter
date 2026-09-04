import SwiftUI

/// The notch cut into the left or right edge of the screen: straight against the glass, rounded on the face the
/// desktop sees, and flaring *outward* into the edge at both ends where the two meet. It is DynamicNotchKit's
/// `NotchShape` turned ninety degrees, point for point — its move, its four quad curves and its four lines, with
/// the top notch's run axis read as this shape's `along` and its depth axis as this shape's `inward`.
///
/// It is transcribed rather than reused. `Package.swift` builds `Vendor/DynamicNotchKit` as its own target and
/// `NotchShape` carries no access modifier, so it is invisible from here; and its path runs along the top only,
/// where the flare eats width and is paid for by `NotchView`'s `.padding(.horizontal, topCornerRadius)`, whereas
/// here it eats height and is paid for by `EdgeNotch`'s vertical padding.
///
/// The fillets are the whole point. A rounded rectangle pushed against an edge always reads as a card that has
/// been shoved too far; an outline that flares outward as it approaches the edge reads as the edge itself coming
/// inward, which is the trick the hardware notch plays and the only reason this layout exists.
///
/// Both radii are fractions of how deep the shape is rather than fixed numbers, so the same shape at the top
/// notch's own depth draws the top notch's own radii, and a shallower one draws proportionally shallower fillets
/// instead of the same 6 pt flare at every size — which at the depths a side pill actually reaches would read as
/// a nick in a rounded rectangle rather than as the same cut, and the two layouts would stop looking like one
/// object.
///
/// Depth is the whole argument for this shape and it is worth writing down what it costs. The side pill first
/// shipped laying each tool's two figures on one line, the way the strip beside the top notch lays them out, and
/// that made it 72 pt deep against a 189 pt run: a ratio of 0.38 where the hardware notch is 38 over 185, or
/// 0.21. It read as a slab bolted to the edge. Stacking the figures (`CompactNumbers.stacked`) took it to 35 by
/// 203 — 0.17, shallower than the notch it imitates — and the run came back with a tighter cap here and less
/// padding in `EdgeCompactView`.
struct SideNotchShape: Shape {
    /// Which screen edge the straight face lies against. Only `.left` and `.right` draw this shape.
    let edge: PanelEdge

    /// The top notch is 38 pt deep with a 6 pt flare and a 14 pt nose (`NotchView.compactNotchCornerRadii`).
    nonisolated static let referenceDepth: CGFloat = 38
    nonisolated static let flareRatio: CGFloat = 6 / SideNotchShape.referenceDepth
    nonisolated static let noseRatio: CGFloat = 14 / SideNotchShape.referenceDepth
    /// Past these the ratios stop flattering the shape: a panel-deep version would flare sixty points and read as
    /// a leaf. The flare's cap is also what `EdgeNotch` pads by, so the cap is what makes that padding provable —
    /// and that second job is why it is 10 and not the 16 it started at. The padding is spent twice, once at each
    /// end of the run, on a shape whose whole point is to be shallow: at the deepest a side pill actually gets
    /// (54 pt, rings and numbers with the reset countdown on) the flare is 8.5, so a cap of 10 clips nothing a
    /// user can reach and hands twelve points of run back to a shape that was reading too tall.
    nonisolated static let flareCap: CGFloat = 10
    nonisolated static let noseCap: CGFloat = 36

    /// The radii for a shape of this depth and run, capped and then held inside the run. Exposed rather than
    /// private so a test can pin the arithmetic without reading a path, and because `EdgeNotch` has no other way
    /// to know how much of the run the fillets will take.
    ///
    /// The clamp is not hypothetical: *Hide when idle* shrinks the readouts to a dot after thirty quiet minutes
    /// and the notch shrinks with them, and a run shorter than two fillets and two noses would fold the outline
    /// back through itself and fill as a bow tie. Both radii are scaled by the same factor so the shape's
    /// proportion survives the clamp rather than the nose being eaten first.
    nonisolated static func radii(depth: CGFloat, run: CGFloat) -> (flare: CGFloat, nose: CGFloat) {
        var flare = min(max(depth, 0) * flareRatio, flareCap)
        var nose = min(max(depth, 0) * noseRatio, noseCap)
        let room = max(min(max(depth, 0), run / 2), 0)
        if flare + nose > room, flare + nose > 0 {
            let scale = room / (flare + nose)
            flare *= scale
            nose *= scale
        }
        return (flare, nose)
    }

    /// There is no `animatableData`, and its absence is deliberate. The radii are read from the rect the shape is
    /// handed, so while SwiftUI interpolates a frame the radii follow it for nothing; and the one transition this
    /// shape lives through — the panel opening beside it — must leave the notch exactly where and as it was, or
    /// the pointer resting on the shape that opened the panel finds the shape has moved out from under it.
    func path(in rect: CGRect) -> Path {
        let (flare, nose) = Self.radii(depth: rect.width, run: rect.height)
        // `inward` is the distance from the flush face and `along` the distance from the top of the run. The flush
        // face is the left on a left-hand notch and the right on a right-hand one, and nothing else in the outline
        // below knows which: writing the path once and letting one function carry the handedness is what keeps the
        // two edges exact mirrors. Nothing depends on that mirror for a picture any more — the gallery's paired
        // frame used to flip the left-hand bitmap for its right-hand shape, which mirrored the readouts along with
        // it and put every signal mark on a corner the app never draws it in, so each edge is now rendered for
        // itself (`AssetRenderer.edgeNotch(store:edge:)`).
        func point(inward: CGFloat, along: CGFloat) -> CGPoint {
            CGPoint(x: edge == .right ? rect.maxX - inward : rect.minX + inward, y: rect.minY + along)
        }
        var path = Path()
        path.move(to: point(inward: 0, along: 0))
        path.addQuadCurve(to: point(inward: flare, along: flare), control: point(inward: 0, along: flare))
        path.addLine(to: point(inward: rect.width - nose, along: flare))
        path.addQuadCurve(to: point(inward: rect.width, along: flare + nose), control: point(inward: rect.width, along: flare))
        path.addLine(to: point(inward: rect.width, along: rect.height - flare - nose))
        path.addQuadCurve(to: point(inward: rect.width - nose, along: rect.height - flare), control: point(inward: rect.width, along: rect.height - flare))
        path.addLine(to: point(inward: flare, along: rect.height - flare))
        path.addQuadCurve(to: point(inward: 0, along: rect.height), control: point(inward: 0, along: rect.height - flare))
        path.closeSubpath()
        return path
    }
}

/// The closed shape on an edge. On the left and the right, where nothing else holds that edge, it is the notch
/// cut into the screen; everywhere else — the top, the bottom, and a side whose edge belongs to a pinned Dock or
/// to Stage Manager's strip — it is the capsule that shipped.
///
/// The colour scheme is forced dark inside the shape whatever *Appearance* says. `PanelSurface` fills the flush
/// notch solid black on every OS — glass there let the wallpaper read straight through a shape whose whole claim
/// is that it is a hole in the screen — and light-scheme `.secondary` text on black cannot be read; the shape is
/// also claiming to be screen the Mac does not have, and screen the Mac does not have is dark. The capsule on the
/// branch below is a floating shape and keeps its glass, so this rule is applied on the flush branch alone. That
/// leaves one combination unhandled and worth fixing on its own: before macOS 26 the capsule has no glass either,
/// so a user on macOS 15 with Appearance set to Light gets the light scheme's own text colours — near-black
/// primary, dark grey `.secondary` — on the capsule's black fill. Dark text on black, that is, not light text
/// on it.
///
/// The layout direction is forced too, because the clearance here is deliberately lopsided — no padding at all on
/// the side against the glass — and `EdgeInsets`' leading and trailing are flipped by the locale, which would pad
/// the shape away from the very edge it has to touch. `EdgeCompactView` already forces the same direction.
struct EdgeNotch: View {
    let store: UsageStore
    let edge: PanelEdge
    /// False when something else holds this edge and the shape would be flush with nothing. See
    /// `EdgePanelController.reachesTheGlass`.
    let flush: Bool
    /// Whether the flush face has the display's own boundary against it rather than a hidden Dock's four-point
    /// reveal strip; it decides the rim's weight and nothing else (`PanelSurface`). It defaults to false because
    /// the rim is an overlay on a fill and cannot move `fittingSize`, so the controller's measuring probe has no
    /// need to know the answer and is built without one.
    var onTheBoundary = false

    var body: some View {
        if flush {
            EdgeCompactView(store: store, edge: edge)
                // The flare eats the run at both ends exactly as it eats the width on the hardware notch, where
                // NotchView pays for it with .padding(.horizontal, topCornerRadius). Without it the first and
                // last rings sit inside the curve and the top one loses its cap. It pads by the flare's cap
                // rather than by the flare, because the flare is a function of the depth and the depth is not
                // known until this view has been measured; the cap is what makes the slack provable instead of
                // hoped for.
                .padding(.vertical, SideNotchShape.flareCap)
                .modifier(PanelSurface(shape: SideNotchShape(edge: edge), flush: true, onTheBoundary: onTheBoundary))
                .padding(clearance)
                .fixedSize()
                .environment(\.colorScheme, .dark)
                .environment(\.layoutDirection, .leftToRight)
        } else {
            EdgeCompactView(store: store, edge: edge)
                .modifier(PanelSurface(shape: Capsule()))
                .padding(4)
                .fixedSize()
        }
    }

    /// Four points of clearance on every side but the one against the glass, which takes none: padding the shape
    /// away from the edge is precisely what made it a capsule floating near one.
    private var clearance: EdgeInsets {
        switch edge {
        case .left: EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 4)
        case .right: EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 0)
        case .top, .bottom: EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
        }
    }
}
