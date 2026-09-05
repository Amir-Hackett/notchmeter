import AppKit
import SwiftUI
import Testing
@testable import Notchmeter

/// The shape a side edge draws: its radii, its outline, and the way it mirrors between the two sides. The first
/// `Path` in this suite to be pinned, so the walk below is written out rather than assumed.
@Suite struct SideNotchGeometry {

    /// A path's points in the order it visits them, control points included, so an outline can be read as a list
    /// of the places it goes rather than compared as an opaque `CGPath` that says nothing when it fails.
    private static func points(of path: Path) -> [CGPoint] {
        var points: [CGPoint] = []
        path.forEach { element in
            switch element {
            case .move(let to): points.append(to)
            case .line(let to): points.append(to)
            case .quadCurve(let to, let control): points.append(control); points.append(to)
            case .curve(let to, let c1, let c2): points.append(c1); points.append(c2); points.append(to)
            case .closeSubpath: break
            }
        }
        return points
    }

    /// The claim the whole shape rests on is that it is the hardware notch turned ninety degrees, and the radii
    /// are where that claim is either true or decoration. Both are fractions of the depth against a 38 pt
    /// reference, so the shape at the hardware notch's own depth has to draw the hardware notch's own numbers.
    @Test func theSideShapeAtTheHardwareNotchsDepthDrawsItsRadii() {
        // 38 × 6/38 = 6 and 38 × 14/38 = 14, which is NotchView.compactNotchCornerRadii exactly.
        let radii = SideNotchShape.radii(depth: 38, run: 200)
        #expect(radii.flare == 6)
        #expect(radii.nose == 14)
    }

    /// The notch the app actually draws. A fixed 6 pt flare on a shape deeper than the hardware notch would read
    /// as a nick in a rounded rectangle rather than as the same cut.
    @Test func theShippedDepthScalesBothRadiiWithIt() {
        // The side pill measures 35 pt deep at rings and numbers and 54 with the reset countdown on, which is the
        // deepest a user can make it: 54 × 6/38 = 8.526…, 54 × 14/38 = 19.894…, and the flare is still under its
        // cap, which is what lets EdgeNotch pad by the cap without ever clipping a ring.
        let radii = SideNotchShape.radii(depth: 54, run: 234)
        #expect(abs(radii.flare - 54 * 6 / 38) < 0.001)
        #expect(abs(radii.nose - 54 * 14 / 38) < 0.001)
        #expect(radii.flare < SideNotchShape.flareCap,
                "the padding EdgeNotch adds is the cap, so a flare at or past it would start clipping the rings")
    }

    /// The no-room fallback never draws this shape, but a wide density or a future readout could still deepen it,
    /// and the ratios alone would flare a panel-deep shape sixty points and turn a notch into a leaf.
    @Test func theRadiiAreCappedSoADeepShapeIsStillANotch() {
        // 200 × 6/38 = 31.6 and 200 × 14/38 = 73.7, both far past the caps of 10 and 36.
        let radii = SideNotchShape.radii(depth: 200, run: 800)
        #expect(radii.flare == SideNotchShape.flareCap)
        #expect(radii.nose == SideNotchShape.noseCap)
    }

    /// Hide when idle shrinks the readouts to a dot after thirty quiet minutes and the notch shrinks with them, so
    /// a run shorter than two fillets and two noses is reachable rather than hypothetical; the outline would
    /// otherwise fold back through itself and fill as a bow tie.
    @Test func aShortRunHoldsBothRadiiInsideItselfAndKeepsTheirProportion() {
        // Depth 38 wants 6 + 14 = 20, but a 30 pt run leaves 15, and 15 split in the shape's own 6 : 14 ratio is
        // 4.5 : 10.5.
        let radii = SideNotchShape.radii(depth: 38, run: 30)
        #expect(abs(radii.flare - 4.5) < 0.001)
        #expect(abs(radii.nose - 10.5) < 0.001)
    }

    /// The outline itself, at the one depth whose radii are whole numbers. What has to be true of a notch cut into
    /// an edge is that it reaches both ends of that edge and that the corners where it meets the edge have been
    /// taken away by a curve whose control sits on the edge — a control anywhere else turns the corner inward and
    /// the shape becomes a card pushed too far, which is the whole difference this feature is about.
    @Test func theOutlineFlaresOutwardWhereItMeetsTheEdge() {
        let rect = CGRect(x: 0, y: 0, width: 38, height: 200)
        let points = Self.points(of: SideNotchShape(edge: .left).path(in: rect))
        #expect(points == [CGPoint(x: 0, y: 0),
                           CGPoint(x: 0, y: 6), CGPoint(x: 6, y: 6),
                           CGPoint(x: 24, y: 6),
                           CGPoint(x: 38, y: 6), CGPoint(x: 38, y: 20),
                           CGPoint(x: 38, y: 180),
                           CGPoint(x: 38, y: 194), CGPoint(x: 24, y: 194),
                           CGPoint(x: 6, y: 194),
                           CGPoint(x: 0, y: 194), CGPoint(x: 0, y: 200)],
                "the fillet's control has to sit on the flush face at (0, 6) and (0, 194); moved off it, the corner turns inward and the shape stops reading as cut into the edge")
    }

    /// The two sides are one shape and its mirror, which is what lets the rendered asset be flipped rather than
    /// drawn twice, and what would break first if the path were written out separately for each side.
    @Test func theLeftShapeIsTheRightShapeMirrored() {
        let rect = CGRect(x: 0, y: 0, width: 38, height: 200)
        let left = Self.points(of: SideNotchShape(edge: .left).path(in: rect))
        let right = Self.points(of: SideNotchShape(edge: .right).path(in: rect))
        #expect(left.count == right.count)
        for (one, other) in zip(left, right) {
            // 38 − x, y unchanged.
            #expect(other == CGPoint(x: 38 - one.x, y: one.y))
        }
    }
}

/// Where the notch and the panel go once a side is flush and the panel opens beside it. The arithmetic is worked
/// against a 388 × 855 pt panel on a 1512 × 982 display and an 82 × 202 pt pill, which is
/// deliberately deeper than the one that ships: the shape measures 35 × 188 at rings and numbers since the figures
/// were stacked, and 54 at its widest with the reset countdown on. A stand-in half again as deep as the widest
/// real one keeps the placement under more pressure than a user can put it under, which is what these tests are
/// for — the no-room fallback fires on width, and a pill that cannot fill the margin would never reach it.
@Suite struct EdgeArrangementTests {
    private let notch = NSSize(width: 82, height: 202)
    private let panel = NSSize(width: 388, height: 855)
    private let area = NSRect(x: 0, y: 0, width: 1512, height: 950)
    private let bounds = NSRect(x: 0, y: 0, width: 1512, height: 982)

    /// The arithmetic, not the drawn result: what this pins is that the two arrangements name the same notch
    /// rectangle. That the shape on screen actually stays in it is `layout(animated:)`'s job, which refuses to
    /// animate a frame whose content is an island in a box that is moving and growing at once.
    @Test func thePanelOpensBesideTheSideNotchAndLeavesItWhereItWas() {
        let chrome = EdgePanelController.Chrome()
        let closed = EdgePanelController.arrangement(notch: notch, panel: panel, expanded: false, edge: .left,
                                                     area: area, chrome: chrome, bounds: bounds)
        let open = EdgePanelController.arrangement(notch: notch, panel: panel, expanded: true, edge: .left,
                                                   area: area, chrome: chrome, bounds: bounds)
        #expect(open.kind == .beside)
        #expect(closed.notch == open.notch,
                "the notch must not move when the panel opens beside it, or the pointer resting on the shape that opened the panel is left standing outside it and the panel closes again under it")
        // Flush at x = 0 and 82 wide, so the panel starts at 82 + 8 = 90 and ends at 90 + 388 = 478.
        #expect(open.notch.minX == 0)
        #expect(open.panel.minX == 90)
        #expect(open.panel.maxX == 478)
        #expect(open.frame == NSRect(x: 0, y: 47.5, width: 478, height: 855))
        #expect(open.frame.contains(open.notch) && open.frame.contains(open.panel),
                "the one window has to hold both shapes, because there is only one window")
        #expect(EdgePanelController.besideGap == HoverIntent.expandedMargin,
                "a wider gap is a column the pointer can stand in while it is outside both shapes, and the collapse dwell starts under a pointer on its way in")
    }

    @Test func theRightHandArrangementIsTheLeftHandOneMirrored() {
        let open = EdgePanelController.arrangement(notch: notch, panel: panel, expanded: true, edge: .right,
                                                   area: area, chrome: EdgePanelController.Chrome(), bounds: bounds)
        #expect(open.kind == .beside)
        // Flush at 1512, so the notch runs 1430…1512 and the panel 1430 − 8 − 388 = 1034 to 1422.
        #expect(open.notch.maxX == 1512)
        #expect(open.panel.minX == 1034)
        #expect(open.panel.maxX == 1422)
        #expect(open.frame.maxX == 1512)
        #expect(open.frame.width == 478)
    }

    @Test func aScreenWithNoRoomBesideTheNotchPutsThePanelWhereTheNotchWas() {
        // 82 + 8 + 388 + 120 = 598, which does not fit in 400.
        let narrow = NSRect(x: 0, y: 0, width: 400, height: 950)
        let open = EdgePanelController.arrangement(notch: notch, panel: panel, expanded: true, edge: .left,
                                                   area: narrow, chrome: EdgePanelController.Chrome(),
                                                   bounds: NSRect(x: 0, y: 0, width: 400, height: 982))
        #expect(open.kind == .instead)
        #expect(open.notch.isNull,
                "the fallback is the layout as it shipped, where opening the panel took the readings off screen")
        #expect(open.panel.minX == 6,
                "and where the panel stood six points clear of the edge rather than being cut into it, because a panel cut into the glass on a screen too narrow for both has nothing left to be flush against")
        #expect(open.frame == open.panel)
    }

    @Test func aHiddenDocksRevealStripIsStillANotchAndStageManagersStripIsNot() {
        var chrome = EdgePanelController.Chrome(dockHides: true, dockOrientation: "left")
        #expect(EdgePanelController.reachesTheGlass(edge: .left, area: area, chrome: chrome, bounds: bounds),
                "four points is a bevel; a notch that swallowed the strip would stop the Dock coming back")
        let revealed = EdgePanelController.arrangement(notch: notch, panel: panel, expanded: false, edge: .left,
                                                       area: area, chrome: chrome, bounds: bounds)
        #expect(revealed.flush)
        #expect(revealed.notch.minX == SystemChrome.dockRevealStrip)
        chrome = EdgePanelController.Chrome(stageManager: true)
        #expect(!EdgePanelController.reachesTheGlass(edge: .left, area: area, chrome: chrome, bounds: bounds))
        let staged = EdgePanelController.arrangement(notch: notch, panel: panel, expanded: false, edge: .left,
                                                     area: area, chrome: chrome, bounds: bounds)
        #expect(!staged.flush, "a notch flush with nothing is a rectangle with odd corners standing on the desktop")
        // The pill that shipped, exactly where it shipped: 152 + 6.
        #expect(staged.notch.minX == SystemChrome.stageManagerStripWidth + EdgePanelController.margin)
    }

    /// The rim's weight is a claim about the display's boundary, not about the notch verdict, and the two part
    /// company at exactly one place: a hidden Dock. `reachesTheGlass` tolerates its four-point reveal strip so the
    /// shape is still drawn as a notch, but at four points of stand-off the whole centred stroke is on screen and
    /// there is nothing for the doubling to make up for — drawn double anyway, that one face reads at twice the
    /// weight of the other three, on the very face the shape is supposed to be indistinguishable from the edge.
    @Test func aRevealStripIsANotchButItsRimIsNotOnTheBoundaryAndIsNotDoubled() {
        let clear = EdgePanelController.Chrome()
        for edge in [PanelEdge.left, .right] {
            #expect(EdgePanelController.standOff(edge: edge, area: area, chrome: clear, bounds: bounds) == 0)
            let arrangement = EdgePanelController.arrangement(notch: notch, panel: panel, expanded: false, edge: edge,
                                                              area: area, chrome: clear, bounds: bounds)
            #expect(arrangement.flush && arrangement.onTheBoundary,
                    "nothing at all between the shape and the glass, so half its rim really would fall off the display")
        }
        for side in ["left", "right"] {
            let edge: PanelEdge = side == "left" ? .left : .right
            let hidden = EdgePanelController.Chrome(dockHides: true, dockOrientation: side)
            #expect(EdgePanelController.standOff(edge: edge, area: area, chrome: hidden, bounds: bounds) == SystemChrome.dockRevealStrip)
            let arrangement = EdgePanelController.arrangement(notch: notch, panel: panel, expanded: false, edge: edge,
                                                              area: area, chrome: hidden, bounds: bounds)
            #expect(arrangement.flush, "four points is a bevel; the shape still reads as cut in")
            #expect(!arrangement.onTheBoundary,
                    "the whole stroke is on screen at four points of stand-off, so doubling it would make one face twice the weight of the other three")
        }
        // Stage Manager's strip is neither, and the top and the bottom never stand off a side at all.
        let staged = EdgePanelController.Chrome(stageManager: true)
        let stagedArrangement = EdgePanelController.arrangement(notch: notch, panel: panel, expanded: false, edge: .left,
                                                                area: area, chrome: staged, bounds: bounds)
        #expect(!stagedArrangement.flush && !stagedArrangement.onTheBoundary)
        for edge in [PanelEdge.top, .bottom] {
            #expect(EdgePanelController.standOff(edge: edge, area: area, chrome: clear, bounds: bounds) == .infinity)
        }
    }

    /// The flag above is worth nothing if it stops at the arrangement, so this renders the shape both ways and
    /// counts what each one covers. An ordinary centred stroke paints half its width outboard of the fill, which
    /// is exactly the half that falls off the display on a face lying on the boundary; the doubled one is clipped
    /// to the shape and paints none. So the standing-off shape has to cover *more* than the one on the boundary,
    /// and the difference is the rim that was being drawn twice as heavily as the other three faces.
    ///
    /// It is also the one guard on the fill. `PanelSurface` draws the flush notch opaque black on every OS; on a
    /// macOS 26 machine it used to take the glass branch, and a live screen capture showed the wallpaper reading
    /// straight through a shape whose whole claim is to be a hole in the screen. Rendered over nothing, glass
    /// leaves no fully opaque pixel at all: this measured 0 % against the 66 % below.
    @MainActor @Test func theBoundaryRimIsDrawnAndTheFlushNotchIsOpaqueOnEveryOS() {
        let (store, _) = DemoFixtures.store(now: DateParsing.iso8601("2026-09-01T12:00:00Z")!)
        for edge in [PanelEdge.left, .right] {
            let onBoundary = Self.coverage(EdgeNotch(store: store, edge: edge, flush: true, onTheBoundary: true))
            let standingOff = Self.coverage(EdgeNotch(store: store, edge: edge, flush: true, onTheBoundary: false))
            #expect(onBoundary.total > 0, "a shape that rendered as nothing would make every comparison below meaningless")
            #expect(standingOff.covered > onBoundary.covered,
                    "the clipped rim has to reach the drawn shape, or the flag is arithmetic nobody looks at (\(edge))")
            #expect(Double(onBoundary.opaqueBlack) / Double(onBoundary.total) > 0.5,
                    "more than half the shape's own box has to be fully opaque black: a notch you can see the desktop through is not a notch (\(edge))")
        }
    }

    /// How much of the rendered box a view paints, and how much of it is fully opaque black. Rendered over nothing,
    /// so anything the fill does not reach comes back transparent and anything glass would let through comes back
    /// short of opaque. Counts rather than a bitmap comparison: the readings inside the shape carry a pace tick
    /// that moves with the clock, and a raw pixel diff would call that a change to the shape.
    @MainActor private static func coverage(_ view: some View) -> (covered: Int, opaqueBlack: Int, total: Int) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage, image.width > 0, image.height > 0 else { return (0, 0, 0) }
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let ctx = CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (0, 0, 0) }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var covered = 0, black = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            if pixels[index + 3] > 0 { covered += 1 }
            if pixels[index + 3] == 255, pixels[index] < 16, pixels[index + 1] < 16, pixels[index + 2] < 16 { black += 1 }
        }
        return (covered, black, image.width * image.height)
    }

    @Test func aDockPinnedToTheEdgeOwnsItAndTheNotchGivesWay() {
        // A Dock pinned to the left is already out of visibleFrame, so the usable area starts at 80.
        let docked = NSRect(x: 80, y: 0, width: 1432, height: 950)
        let chrome = EdgePanelController.Chrome()
        #expect(!EdgePanelController.reachesTheGlass(edge: .left, area: docked, chrome: chrome, bounds: bounds))
        let closed = EdgePanelController.arrangement(notch: notch, panel: panel, expanded: false, edge: .left,
                                                     area: docked, chrome: chrome, bounds: bounds)
        #expect(!closed.flush)
        #expect(closed.notch.minX == 86, "80 + 6: the pill that shipped, resting clear of the Dock rather than under it")
    }

    @Test func theTopAndBottomLayoutsAreUnchanged() {
        let bar = NSSize(width: 200, height: 40)
        let chrome = EdgePanelController.Chrome()
        for edge in [PanelEdge.top, .bottom] {
            let closed = EdgePanelController.arrangement(notch: bar, panel: panel, expanded: false, edge: edge,
                                                         area: area, chrome: chrome, bounds: bounds)
            #expect(!closed.flush)
            #expect(closed.notch == closed.frame)
            #expect(closed.panel.isNull)
            let open = EdgePanelController.arrangement(notch: bar, panel: panel, expanded: true, edge: edge,
                                                       area: area, chrome: chrome, bounds: bounds)
            #expect(open.kind == .instead,
                    "the user asked for the left and right edges; nothing about the top or the bottom changes")
            #expect(open.notch.isNull)
            #expect(open.frame == EdgePanelController.placement(for: panel, edge: edge, area: area, chrome: chrome),
                    "and the panel lands exactly where placement has always put it, six points and all")
        }
    }

    /// A swipe up over the readouts closes the panel (HoverIntent.swipe), and the rule is `inCompact` without
    /// `inExpanded`. The side notch has never been on screen beside its own panel before, so the gesture reaches
    /// it here for the first time — and only while there is room beside it. Where the panel opens in the notch's
    /// place instead, the widened panel covers the whole compact rectangle and the swipe correctly does nothing,
    /// because there is no notch on screen to swipe over.
    @Test func aSwipeUpOverTheSideNotchClosesThePanelOnlyWhileItStandsBesideIt() {
        let chrome = EdgePanelController.Chrome()
        let beside = EdgePanelController.arrangement(notch: notch, panel: panel, expanded: true, edge: .left,
                                                     area: area, chrome: chrome, bounds: bounds)
        var regions = HoverRegions(compact: beside.notch, expanded: beside.panel)
        // The notch runs to x = 82; the panel widened by the 8 pt hover margin starts at 82. A point at the
        // notch's own middle is in the one and not the other.
        var hit = regions.hit(CGPoint(x: 40, y: beside.notch.midY))
        #expect(hit.inCompact && !hit.inExpanded)
        let narrow = NSRect(x: 0, y: 0, width: 400, height: 950)
        let narrowBounds = NSRect(x: 0, y: 0, width: 400, height: 982)
        let instead = EdgePanelController.arrangement(notch: notch, panel: panel, expanded: true, edge: .left,
                                                      area: narrow, chrome: chrome, bounds: narrowBounds)
        let shut = EdgePanelController.arrangement(notch: notch, panel: panel, expanded: false, edge: .left,
                                                   area: narrow, chrome: chrome, bounds: narrowBounds)
        regions = HoverRegions(compact: shut.notch, expanded: instead.panel)
        hit = regions.hit(CGPoint(x: 40, y: 475))
        #expect(hit.inExpanded, "with the panel standing where the notch was, there is nothing left to swipe over")
    }
}
