import AppKit
import ImageIO
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

/// `--render-assets <dir>`: the README's pictures from the real views over DemoFixtures. Screen capture needs a
/// permission a build machine does not have, so each view is laid out in a window that never reaches the screen
/// and drawn into a bitmap; the notch, menu bar and desktop around it are painted with Core Graphics to the
/// measurements DynamicNotchKit lays the panel out with (Vendor/DynamicNotchKit/Views/NotchView.swift).
enum AssetRenderer {
    static let scale: CGFloat = 2
    /// A 14-inch MacBook Pro's notch. DynamicNotchKit rounds the compact shape 6 pt at the top and 14 at the
    /// bottom, the open panel 15 and 20, keeps 8 pt beside the rings and 15 pt around the content.
    static let notch = CGSize(width: 185, height: 32)
    static let compactRadii = (top: CGFloat(6), bottom: CGFloat(14))
    static let expandedRadii = (top: CGFloat(15), bottom: CGFloat(20))
    static let ringInset: CGFloat = 8
    static let panelInset: CGFloat = 15

    enum Failure: Error, CustomStringConvertible {
        case snapshot(String)
        case encoding(String)

        var description: String {
            switch self {
            case .snapshot(let what): "could not draw \(what)"
            case .encoding(let what): "could not encode \(what)"
            }
        }
    }

    @MainActor
    static func render(into directory: URL, now: Date = Date()) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            stillEveryAnimation()
            let (store, prefs) = DemoFixtures.store(now: now)
            let actions = NotchActions()
            let stage = try Stage(store: store, prefs: prefs, actions: actions)
            try write(stage.image(.expanded, canvas: stage.panelCanvas, pixelScale: scale), png: directory.appendingPathComponent("expanded.png"))
            try write(stage.image(.compact, canvas: CGSize(width: 1200, height: 80), pixelScale: scale), png: directory.appendingPathComponent("compact-top.png"))
            try write(edgeNotch(store: store), png: directory.appendingPathComponent("edge-left.png"))
            try write(edgeNotchWithPanel(panel: stage.content, store: store), png: directory.appendingPathComponent("edge-right-panel.png"))
            let (finished, finishedPrefs) = DemoFixtures.store(now: now, moment: .justFinished)
            try write(signalRings(waiting: stage, finished: Stage(store: finished, prefs: finishedPrefs, actions: actions)),
                      png: directory.appendingPathComponent("signal-rings.png"))
            try write(sheet(settings(store: store, prefs: prefs, actions: actions)), png: directory.appendingPathComponent("settings.png"))
            try write(stage.demo(), gif: directory.appendingPathComponent("demo.gif"))
            // The same panel under Increase Contrast, for review: brighter tracks and fills, secondary captions.
            AccessibilityDisplay.shared.force(contrast: true)
            defer { AccessibilityDisplay.shared.force(contrast: nil) }
            let contrast = try Stage(store: store, prefs: prefs, actions: actions)
            try write(contrast.image(.expanded, canvas: contrast.panelCanvas, pixelScale: scale), png: directory.appendingPathComponent("expanded-contrast.png"))
            return true
        } catch {
            Probe.emit("render-assets: \(error)")
            return false
        }
    }

    /// A still has no time axis, and one of these views moves on its own: `CompactReadout` fades to 40 % three
    /// times over on entering the urgent presence, which is the level a waiting assistant puts it in. From the
    /// moment the fixtures grew a permission prompt, what opacity the compact strip is at when `cacheDisplay`
    /// runs stopped being a question about the app and became one about SwiftUI's commit timing.
    ///
    /// Measured, the answer today is "full opacity": every file `--render-assets` writes is byte-identical with
    /// this line and without it, because the snapshot is taken before the pulse's first frame is committed. That
    /// is a fact about one SwiftUI release rather than a property of this renderer, which is why the line stays.
    /// A picture committed to the repository that is right because of when a frame happened to land is right by
    /// luck, and the next release gets to change its mind without anything failing. Reduce animations is the
    /// app's own answer to a readout that moves, and stills the pulse at full opacity.
    ///
    /// It is set on `AccessibilityDisplay` rather than on `Preferences` because the views read it there, and it
    /// is never restored: `--render-assets` and `--render-gallery` both exit the process when they are done, and
    /// neither ever builds a panel.
    @MainActor
    private static func stillEveryAnimation() {
        AccessibilityDisplay.shared.reduceAnimations = true
    }

    /// `--render-gallery <dir>`: Product Hunt's eight 1270×760 frames and the 240×240 thumbnail, each one centred
    /// on a #1c1c1e canvas with its caption drawn into the image (the gallery strips captions on mobile).
    ///
    /// Seven are stills and the first is the animated GIF the gallery spec always asked for. It was shipped as a
    /// still of the open panel, which made frame 1 pixel-for-pixel the same picture as frame 4 above the caption
    /// band, and pointed "Hover the rings" at a frame with no rings in it: the app's expanded state has no
    /// compact readouts, so no still of the open panel can show the thing the caption names. The loop can, and
    /// Product Hunt accepts a GIF in the gallery.
    ///
    /// Frames 1, 3 and 4 are crops rather than the whole picture, because 1270×760 with a caption band leaves 568
    /// points of height and the picture of the open panel is 1039 tall: fitted whole it lands at 0.55 px a point,
    /// which is what made the old frames 3 and 4 unreadable — "legible at 2×" delivered as two-pixel bars. Each
    /// crop is laid out again from the same store rather than cut out of `expanded.png` by pixel coordinate, so
    /// a frame cannot go on pointing at a rectangle the card inside it has moved out of, and each is drawn at
    /// 2 px a point, so a crop the frame still has to shrink is a Retina render coming down rather than a coarse
    /// one going up.
    @MainActor
    static func gallery(into directory: URL, now: Date = Date()) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            stillEveryAnimation()
            let (store, prefs) = DemoFixtures.store(now: now)
            let actions = NotchActions()
            let stage = try Stage(store: store, prefs: prefs, actions: actions)
            let canvas = CGSize(width: 1270, height: 760)
            // Cropped to the notch and the readouts beside it, and drawn at 4 px a point, because this frame carries
            // the launch's pitch line and the whole 1200 pt bar fitted into 1270 put the notch at 280 px and a
            // signal mark at three pixels by two. The README's own picture of the strip stays wide (compact-top.png):
            // there the point is how little of the bar it takes, and here it is what the readouts actually say.
            let compact = try stage.image(.compact, canvas: CGSize(width: 300, height: 74), pixelScale: 4)
            let notchShape = try edgeNotch(store: store, edge: .left)
            let rightNotchShape = try edgeNotch(store: store, edge: .right)
            let settingsImage = try sheet(settings(store: store, prefs: prefs, actions: actions))
            let costAndAdvice = try panelCrop(VStack(alignment: .leading, spacing: prefs.density.cardSpacing) {
                SpendCard(store: store)
                AdviceStrip(advice: store.advice)
            }, prefs: prefs)
            let claudeCard = try panelCrop(ToolCard(tool: .claude, status: store.status(.claude), store: store, prefs: prefs), prefs: prefs)

            // The hover, animated: the rings at rest, the shape springing open, the Cost card, and back. The loop
            // is drawn again into a canvas cropped around the notch rather than scaled down from the README's
            // 900×1027 one, because at 760 high the whole panel would be at 0.55 px a point.
            let hoverCaption = L("Hover the rings. The panel opens.")
            var hover: [Frame] = []
            for frame in try stage.demo(canvas: CGSize(width: 580, height: 280), pixelScale: 2) {
                hover.append(Frame(image: try composite(frame.image, caption: hoverCaption, lines: [], canvas: canvas),
                                   delay: frame.delay))
            }
            try write(hover, gif: directory.appendingPathComponent("01-hover.gif"))

            let frames: [(name: String, image: CGImage?, caption: String, lines: [String])] = [
                ("02-compact", compact, L("Lives in the notch. Takes no menu bar room."), []),
                // The lines beside the picture used to be three example advice lines lifted from the README's
                // rules table — "Opus weekly is 91%", "Codex has 78% of its weekly left" — beside a panel showing
                // no Opus row at all and a Codex card reading "No data". A reader saw the product claim 78% of
                // something the picture said it could not read. The strip in the frame now carries the examples,
                // which are the ones these fixtures really produce, and the lines beside it describe the rules
                // that produced them and assert no figure of their own. Nor do they call every line an
                // instruction: the two the fixtures produce report a state and an hour's spend, and a line of
                // copy that the picture beside it disproves is the whole fault being corrected here.
                ("03-advice", costAndAdvice.image, L("Tells you what to do, not just how much."), [
                    "Seven rules over the live readings and the cost summary, pinned by unit tests.",
                    "At most three lines, highest priority first, and nothing at all when there is nothing to say.",
                    "The same words arrive as a notification when a window's pace crosses.",
                ]),
                ("04-pace", claudeCard.image, L("Warns you at pace, not at 90% — while you can still do something about it."), []),
                ("05-accuracy", nil, L("Every number shows its work."), [
                    "Five token buckets: input, output, 5-minute and 1-hour cache writes, cache reads.",
                    "1.1× on inference_geo \"us\". Web search at $10 per 1,000. Fast mode at its own rate.",
                    "The output_tokens placeholder: the last line is the real count, 35% more here.",
                    "Golden-transcript tests pin every rule. docs/accuracy.md",
                ]),
                ("06-energy", nil, L("0.02% of one core on a quiet day, 1.4% under load."), [
                    "Quiet day: 0.01 CPU-s / 61 s = 0.02%; 0.86 / 182 s = 0.47% with a cost scan",
                    "Heavy day (10 MB+ transcripts): 0.84 / 61 s = 1.4%; 2.99 / 182 s = 1.6%",
                    "63 MB physical footprint, 77 MB peak (vmmap). ps RSS 99 to 105 MB, flat.",
                    "Nothing while the screen is locked, the displays are asleep or the Mac is asleep.",
                ]),
                // The frame draws one notch and its mirror, so the caption names two edges. It said three while
                // the bottom bar was nowhere in it, which is the kind of small untruth a reader checks once.
                ("07-edges", notchShape, L("A notch cut into the left or the right edge of any Mac."), []),
                ("08-settings", settingsImage, L("Position, hover or always open, hook install with a backup."), []),
            ]
            for frame in frames {
                let image = try composite(frame.image, caption: frame.caption, lines: frame.lines, canvas: canvas,
                                          beside: frame.name == "07-edges" ? rightNotchShape : nil)
                try write(image, png: directory.appendingPathComponent("\(frame.name).png"))
            }
            let icon = URL(fileURLWithPath: "build/AppIcon.icns")
            if let source = NSImage(contentsOf: icon), let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let thumbnail = try bitmap(CGSize(width: 240, height: 240), pixelScale: 1) { ctx in
                    draw(cg, in: CGRect(x: 0, y: 0, width: 240, height: 240), alpha: 1, into: ctx)
                }
                try write(thumbnail, png: directory.deletingLastPathComponent().appendingPathComponent("thumbnail.png"))
            } else {
                Probe.emit("render-gallery: build/AppIcon.icns not found; run scripts/build.sh first for the thumbnail")
            }
            return true
        } catch {
            Probe.emit("render-gallery: \(error)")
            return false
        }
    }

    /// One gallery frame: the image scaled to fit above the caption, text lines beside or below it.
    ///
    /// `beside` puts a second picture next to the first, which one frame wants and which took two goes to get
    /// right. It was a flip of the same bitmap drawn at the first copy's own x — right where text sits beside the
    /// picture, and silently wrong where it does not, because with no lines the picture is centred and
    /// `canvas.width - x - size.width` for a centred x is that same x, so the opaque copy landed exactly over the
    /// original and the frame showed one shape where it promised a pair. Fitting the pair rather than trusting it
    /// to fit — the first tile's x worked from the whole spread, the scale worked against the room two tiles and
    /// the gap between them need — separated them. What it could not fix is that a flip mirrors the readouts too,
    /// so the second tile showed every signal mark in a corner the app never draws it in. So the caller renders
    /// the second picture for itself and this only has to place it.
    static func composite(_ image: CGImage?, caption: String, lines: [String], canvas: CGSize, beside: CGImage? = nil) throws -> CGImage {
        try bitmap(canvas, pixelScale: 1) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 0x1c / 255, green: 0x1c / 255, blue: 0x1e / 255, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: canvas))
            let captionHeight: CGFloat = 96
            let margin: CGFloat = 48
            var textTop: CGFloat = margin
            if let image {
                let width = CGFloat(image.width), height = CGFloat(image.height)
                // Half the canvas less the margin, where lines sit beside the picture: the picture starts at the
                // margin, so half the canvas would let it run under the first character of every line.
                let available = CGSize(width: lines.isEmpty ? canvas.width - 2 * margin : canvas.width * 0.5 - margin,
                                       height: canvas.height - captionHeight - 2 * margin)
                let tiles: CGFloat = beside == nil ? 1 : 2
                let gap: CGFloat = beside == nil ? 0 : margin
                let scale = min((available.width - (tiles - 1) * gap) / (width * tiles), available.height / height, 1)
                let size = CGSize(width: width * scale, height: height * scale)
                let spread = size.width * tiles + (tiles - 1) * gap
                let x = lines.isEmpty ? (canvas.width - spread) / 2 : margin
                let rect = CGRect(x: x, y: margin + (available.height - size.height) / 2, width: size.width, height: size.height)
                draw(image, in: rect, alpha: 1, into: ctx)
                if let beside {
                    draw(beside, in: rect.offsetBy(dx: size.width + gap, dy: 0), alpha: 1, into: ctx)
                }
                textTop = rect.minY + 40
            }
            let graphics = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 24, weight: .regular), .foregroundColor: NSColor(white: 0.85, alpha: 1)]
            let x = image == nil || lines.isEmpty ? margin : canvas.width * 0.5 + margin / 2
            var y = image == nil ? margin + 40 : textTop
            for line in lines {
                (line as NSString).draw(in: CGRect(x: x, y: y, width: canvas.width - x - margin, height: 80), withAttributes: body)
                y += 76
            }
            let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 34, weight: .semibold), .foregroundColor: NSColor.white]
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            var centred = title
            centred[.paragraphStyle] = paragraph
            (caption as NSString).draw(in: CGRect(x: margin, y: canvas.height - captionHeight + 8, width: canvas.width - 2 * margin, height: captionHeight), withAttributes: centred)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    // MARK: - Pictures

    /// The left-hand side notch on a strip of desktop, as it looks before Liquid Glass: the glass material samples
    /// what is behind the window, which an off-screen bitmap has none of. The shape is not drawn by hand here —
    /// the path comes from `SideNotchShape`, so the README's picture cannot drift away from what the app puts on
    /// the screen, which is exactly how the old capsule came to be a picture of something the app had stopped
    /// drawing.
    ///
    /// Each edge is drawn for itself. The gallery's pair used to be one bitmap laid out twice, the second copy
    /// flipped about the canvas — which mirrors the *readouts* along with the shape, so the right-hand tile showed
    /// every ring's signal mark on its top left, a corner the app never puts it in: `EdgeCompactView` draws the
    /// same way round on both edges and only the notch is handed. Rendering the edge that is asked for costs one
    /// more snapshot and cannot say anything about the app that is not true of it.
    @MainActor
    static func edgeNotch(store: UsageStore, edge: PanelEdge = .left) throws -> CGImage {
        let canvas = CGSize(width: 240, height: 240)
        let rings = try snapshot(EdgeCompactView(store: store, edge: edge), what: "the edge rings")
        let run = rings.size.height + 2 * SideNotchShape.flareCap
        return try bitmap(canvas, pixelScale: scale) { ctx in
            wallpaper(in: ctx, canvas: canvas)
            let x = edge == .right ? canvas.width - rings.size.width : 0
            drawSideNotch(rings, edge: edge, in: CGRect(x: x, y: (canvas.height - run) / 2, width: rings.size.width, height: run), into: ctx)
        }
    }

    /// The right-hand notch with the panel open beside it, which is what a side layout is for and the one thing no
    /// picture in `docs/media` showed: the readings stay on the glass while the detail is read inboard of them.
    ///
    /// The card is painted with Core Graphics rather than snapshotted through `PanelSurface`, for the reason
    /// `edgeNotch` gives about the notch: from macOS 26 that modifier puts the card on Liquid Glass, and glass
    /// off-screen has nothing behind it to sample, so a snapshot of the real modifier would come out as a pale
    /// slab rather than as what a user sees. What is *not* re-derived here is anything about where the two shapes
    /// sit: the gap is `EdgePanelController.besideGap` plus the four points `EdgePanelCard` pads itself by, which
    /// is the same arithmetic `EdgePanelController.arrangement` does, so the picture cannot promise a spacing the
    /// app does not lay out.
    @MainActor
    static func edgeNotchWithPanel(panel: Snapshot, store: UsageStore) throws -> CGImage {
        let rings = try snapshot(EdgeCompactView(store: store, edge: .right), what: "the edge rings")
        let run = rings.size.height + 2 * SideNotchShape.flareCap
        // EdgePanelCard: the panel's own content padded 6 pt top and bottom inside a 22 pt rounded rectangle, then
        // 4 pt of window slack outside it, which shows as desktop between the card and the notch.
        let card = CGSize(width: panel.size.width, height: panel.size.height + 12)
        let gap = EdgePanelController.besideGap + 4
        let desktop: CGFloat = 40
        let margin: CGFloat = 28
        let canvas = CGSize(width: desktop + card.width + gap + rings.size.width,
                            height: max(card.height, run) + 2 * margin)
        return try bitmap(canvas, pixelScale: scale) { ctx in
            wallpaper(in: ctx, canvas: canvas)
            let cardRect = CGRect(x: desktop, y: (canvas.height - card.height) / 2, width: card.width, height: card.height)
            let rounded = CGPath(roundedRect: cardRect, cornerWidth: 22, cornerHeight: 22, transform: nil)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 36 * scale, color: CGColor(gray: 0, alpha: 0.55))
            ctx.addPath(rounded)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fillPath()
            ctx.restoreGState()
            ctx.addPath(rounded)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12))
            ctx.setLineWidth(1)
            ctx.strokePath()
            draw(panel.image, in: CGRect(x: cardRect.minX, y: cardRect.minY + 6, width: panel.size.width, height: panel.size.height), alpha: 1, into: ctx)
            drawSideNotch(rings, edge: .right, in: CGRect(x: canvas.width - rings.size.width, y: (canvas.height - run) / 2,
                                                          width: rings.size.width, height: run), into: ctx)
        }
    }

    /// One side notch wherever it is told to go: the shadow, the fill, the hairline and the readouts inside it.
    /// Both pictures that draw this shape come through here rather than each laying out its own, because two
    /// workings of one outline is how a picture ends up showing a shape the app never draws — the thing this whole
    /// round of assets exists to correct.
    ///
    /// `bitmap(_:pixelScale:_:)` already flips its context so the origin is at the top left, the way SwiftUI
    /// counts, so the path goes in exactly as the app draws it and no second flip is needed. The shadow is thrown
    /// sideways rather than down, and away from the flush face: the half that would fall outboard is off the
    /// display altogether, so a shape against the left edge casts to the right and one against the right casts to
    /// the left.
    private static func drawSideNotch(_ rings: Snapshot, edge: PanelEdge, in notch: CGRect, into ctx: CGContext) {
        let shape = SideNotchShape(edge: edge).path(in: notch).cgPath
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: (edge == .right ? -4 : 4) * scale, height: 0), blur: 16 * scale, color: CGColor(gray: 0, alpha: 0.5))
        ctx.addPath(shape)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.addPath(shape)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12))
        ctx.setLineWidth(1)
        ctx.strokePath()
        ctx.restoreGState()
        draw(rings.image, in: CGRect(x: notch.minX, y: notch.minY + SideNotchShape.flareCap,
                                     width: notch.width, height: rings.size.height), alpha: 1, into: ctx)
    }

    /// The two states a ring can be in while an assistant is asking something of the user, one above the other:
    /// a permission prompt open on top, a turn just ended below.
    ///
    /// It is two rows and not one frame because it cannot be one. A tool has a single ring and `ToolSignal.resolve`
    /// gives a wait the better claim on it, so no honest instant shows both marks; each row is the same strip at a
    /// different moment (`DemoFixtures.Moment`), drawn from its own store. The rows are cropped to the strip and
    /// eighty points of menu bar either side of it, because the point of the picture is the 9 pt mark and the
    /// colour the nest takes, and at the 1200 pt width `compact-top.png` uses both are a speck in a field of
    /// desktop.
    static func signalRings(waiting: Stage, finished: Stage) throws -> CGImage {
        let width = max(waiting.compactSize.width, finished.compactSize.width) + 160
        let row = CGSize(width: width, height: 52)
        let gap: CGFloat = 14
        let rows = [try waiting.image(.compact, canvas: row, pixelScale: scale),
                    try finished.image(.compact, canvas: row, pixelScale: scale)]
        return try bitmap(CGSize(width: width, height: 2 * row.height + gap), pixelScale: scale) { ctx in
            wallpaper(in: ctx, canvas: CGSize(width: width, height: 2 * row.height + gap))
            for (index, image) in rows.enumerated() {
                draw(image, in: CGRect(x: 0, y: CGFloat(index) * (row.height + gap), width: row.width, height: row.height), alpha: 1, into: ctx)
            }
        }
    }

    /// One or two of the panel's cards in the panel's own container: its width, its horizontal padding, and the
    /// black it is drawn on, at 2 px a point.
    ///
    /// A gallery frame that has to be legible cannot be the whole panel — 1039 points of it in 568 points of
    /// room is half a pixel a point — and it must not be a rectangle cut blindly out of `expanded.png` either,
    /// because a crop by pixel coordinate keeps pointing at the same rectangle after the card inside it has
    /// moved. The cards are laid out again instead, from the same store, in the same container
    /// `NotchExpandedView.content` puts them in, so what comes out is the panel cropped rather than a card
    /// re-staged on a background of the renderer's own invention.
    @MainActor
    static func panelCrop<Content: View>(_ content: Content, prefs: Preferences) throws -> Snapshot {
        try snapshot(
            content
                .padding(.horizontal, 14)
                .padding(.vertical, NotchExpandedView.contentTopPadding)
                .frame(width: prefs.panelWidth.points, alignment: .leading)
                .background(Color.black)
                .foregroundStyle(.white)
                .environment(\.colorScheme, .dark)
                .environment(\.density, prefs.density)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1),
            what: "a panel crop")
    }

    /// The Settings window, title bar included, in the dark appearance the notch panel always has.
    ///
    /// The form is laid out in a 9000 pt scratch window first because a grouped `Form` scrolls and has no
    /// intrinsic height, so the only way to have the rows below the fold exist at all is to give the window more
    /// room than they can possibly need. The picture is then taken at the height the form actually came out at,
    /// not at that scratch height. Capturing the scratch height wrote a 920×18064 PNG where the form measures
    /// 920×7986 — two and a quarter times as tall as it needed to be, the rest empty backing — and the gallery's
    /// `08-settings` frame scaled that ribbon into a 1270×760 canvas, which left the whole window a few pixels
    /// wide. It was also not a stable number: 9000 is only what the window is asked for, and a machine that clamps
    /// the ask writes a different, silently cropped file.
    @MainActor
    static func settings(store: UsageStore, prefs: Preferences, actions: NotchActions) throws -> CGImage {
        let requests = SettingsRequests()
        // The Mac this is rendered on is not the Mac in the picture. `/Applications/Notchmeter.app` is where the
        // DMG puts it and what `HookSettings.Status.shorten` prints for it, so the hook rows and the status-line
        // row read as a machine with every integration in place, which is what the fixture sessions and the
        // status-line arc elsewhere in these pictures already assume.
        let installed = "/Applications/\(AppInfo.name).app/Contents/MacOS/\(AppInfo.name)"
        requests.renderedHookStatus = (hook: Dictionary(uniqueKeysWithValues: HookVendor.allCases.map { ($0, HookSettings.Status.installed(path: installed)) }),
                                       statusline: .installed(path: installed))
        let controller = SettingsWindowController(store: store, prefs: prefs, actions: actions, notifier: Notifier(available: false), requests: requests)
        guard let window = controller.window, let frame = window.contentView?.superview else { throw Failure.snapshot("the Settings window") }
        window.appearance = NSAppearance(named: .darkAqua)
        // The window opens at 640 pt and scrolls; the picture shows the whole form.
        window.setContentSize(NSSize(width: 460, height: 9000))
        window.contentView?.layoutSubtreeIfNeeded()
        if let height = window.contentView.flatMap(formHeight(in:)) {
            window.setContentSize(NSSize(width: 460, height: height))
            window.contentView?.layoutSubtreeIfNeeded()
        }
        windows.append(window)
        return try bitmap(of: frame, size: frame.bounds.size, what: "the Settings window")
    }

    /// The Settings capture cut into columns and laid out left to right, like a printed spread.
    ///
    /// The window is 460 pt wide and the form inside it is nearly four thousand tall, so the honest whole-form
    /// capture is a ribbon of about one to nine. That shape has no good home: in the README's screenshot table a
    /// cell is around 290 px wide, and a ribbon scaled to it is two and a half thousand px tall, which sets the
    /// height of the whole row and pushes the pictures beside it off the screen; in the gallery's
    /// 1270×760 frame the same ribbon is height-limited to sixty-odd points of width, which is the "nearly
    /// unreadable" 08-settings frame the last pass measured and could not fix from inside the capture.
    ///
    /// The column count is derived rather than chosen, so a form that grows another twenty rows re-balances
    /// itself instead of drifting back towards a ribbon: `n` columns make a sheet `n` capture-widths across and a
    /// capture-height over `n` tall, and the `n` that lands nearest a 16:9 landscape is the square root of the
    /// capture's own aspect over that target. At the height the form measures today that is four.
    ///
    /// The ground behind the gutters is the same #1c1c1e the gallery lays every frame on, so a sheet dropped into
    /// a gallery frame shows no seam and one dropped into a README is a sheet rather than columns striped with
    /// whatever colour that page happens to be.
    ///
    /// Where the columns break is the form's business rather than arithmetic's. An even `height / columns` lands
    /// wherever it lands, and at the height the form measures today it landed inside a row three times over:
    /// *Will run out (behind pace)* was cut through the letters at the foot of the second column and cut through
    /// them again at the head of the third, and the first column ended with the switch beside *Show over
    /// full-screen apps* sheared in half — in `settings.png` and in the gallery's `08-settings` alike, which is
    /// the most detailed picture the README has. `columnCuts` moves each seam onto the nearest gap the form
    /// leaves between two rows, so a column ends where a row ends. The columns then differ in height by a row or
    /// two and the sheet is as tall as the tallest of them.
    static func sheet(_ image: CGImage, gutter: CGFloat = 24, targetAspect: CGFloat = 9.0 / 16) throws -> CGImage {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let columns = max(1, Int((height / (width * targetAspect)).squareRoot().rounded()))
        guard columns > 1 else { return image }
        let cuts = columnCuts(of: image, columns: columns)
        let tallest = zip(cuts, cuts.dropFirst()).map { $1 - $0 }.max() ?? image.height
        let canvas = CGSize(width: CGFloat(columns) * width + CGFloat(columns - 1) * gutter, height: CGFloat(tallest))
        return try bitmap(canvas, pixelScale: 1) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 0x1c / 255, green: 0x1c / 255, blue: 0x1e / 255, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: canvas))
            for index in 0 ..< columns {
                let slice = CGRect(x: 0, y: CGFloat(cuts[index]), width: width, height: CGFloat(cuts[index + 1] - cuts[index]))
                guard slice.height > 0, let cut = image.cropping(to: slice) else { continue }
                draw(cut, in: CGRect(x: CGFloat(index) * (width + gutter), y: 0, width: slice.width, height: slice.height), alpha: 1, into: ctx)
            }
        }
    }

    /// The `columns + 1` scanlines a capture is cut on, from 0 to its full height, each interior one moved from
    /// the even division onto the nearest gap between two form rows.
    ///
    /// A seam is allowed to travel an eighth of a column and no further. Beyond that it would be reaching past
    /// the row it belongs beside for some other row's gap, and buying a clean break with a column visibly short
    /// of its neighbours; a capture with no gap in reach keeps the even cut it would have had.
    static func columnCuts(of image: CGImage, columns: Int) -> [Int] {
        let height = image.height
        let bands = quietBands(in: image, minimumHeight: 6)
        let reach = max(1, height / (columns * 8))
        func middle(_ band: ClosedRange<Int>) -> Int { (band.lowerBound + band.upperBound) / 2 }
        var cuts = [0]
        for index in 1 ..< columns {
            let target = Int((Double(index) * Double(height) / Double(columns)).rounded())
            let nearest = bands
                .filter { abs(middle($0) - target) <= reach && $0.lowerBound > cuts[index - 1] }
                .min { abs(middle($0) - target) < abs(middle($1) - target) }
            cuts.append(max(nearest.map(middle) ?? target, cuts[index - 1] + 1))
        }
        cuts.append(height)
        return cuts
    }

    /// The horizontal bands a capture can be cut on: runs of scanlines carrying no text and no control, only the
    /// flat grounds a form leaves between its rows and the hairline that divides them.
    ///
    /// The test is how many colours a scanline holds, not how bright it is, because brightness cannot tell a gap
    /// from the pale track of a switch. Sampled every second pixel and quantised to five bits a channel, a line
    /// between two rows holds at most four: the window's ground, the group's, the divider, and the blend where
    /// the group's rounded corner meets the window. A line crossing a glyph, a switch or a picker holds many
    /// more, and the count is abandoned as soon as it passes four rather than finished.
    static func quietBands(in image: CGImage, minimumHeight: Int) -> [ClosedRange<Int>] {
        let width = image.width, height = image.height
        let bytesPerRow = width * 4
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return [] }
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            // A bitmap context stores its rows top down, so row 0 of the buffer is the top of the image and the
            // indices below are the same ones `CGImage.cropping(to:)` counts in.
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        guard drawn else { return [] }
        var bands: [ClosedRange<Int>] = []
        var start: Int?
        for y in 0 ..< height {
            var colours = Set<UInt32>()
            var x = 0
            while x < width {
                let pixel = y * bytesPerRow + x * 4
                colours.insert(UInt32(pixels[pixel] >> 3) << 10 | UInt32(pixels[pixel + 1] >> 3) << 5 | UInt32(pixels[pixel + 2] >> 3))
                if colours.count > 4 { break }
                x += 2
            }
            if colours.count <= 4 {
                if start == nil { start = y }
            } else if let from = start {
                if y - from >= minimumHeight { bands.append(from ... y - 1) }
                start = nil
            }
        }
        if let from = start, height - from >= minimumHeight { bands.append(from ... height - 1) }
        return bands
    }

    /// How tall the scrolling form inside a hosting view actually came out. SwiftUI lays a `Form` out inside a
    /// scroll view, and that scroll view's document view is the one place the whole form's extent is written
    /// down — the hosting view itself reports the frame it was given, and `fittingSize` answers for the width
    /// SwiftUI would rather have had (744 pt) rather than the 460 pt the window is. Pre-order, so the form's own
    /// scroll view wins over any nested one. `nil` when no scroll view is found, which leaves the caller with the
    /// scratch height it already had: an OS that lays a `Form` out some other way then gives the oversized
    /// picture that shipped rather than a cropped one.
    @MainActor
    private static func formHeight(in view: NSView) -> CGFloat? {
        if let scroll = view as? NSScrollView, let document = scroll.documentView, document.bounds.height > 0 {
            return ceil(document.bounds.height)
        }
        for subview in view.subviews {
            if let height = formHeight(in: subview) { return height }
        }
        return nil
    }

    // MARK: - The notch

    /// Where the compact rings and the open panel are between one another: 0 is the compact shape, 1 the panel.
    struct Pose {
        var shape: Double
        var contentAlpha: Double
        var contentScaleY: Double
        var ringsAlpha: Double
        var ringsScaleX: Double

        static let compact = Pose(shape: 0, contentAlpha: 0, contentScaleY: 0.6, ringsAlpha: 1, ringsScaleX: 1)
        static let expanded = Pose(shape: 1, contentAlpha: 1, contentScaleY: 1, ringsAlpha: 0, ringsScaleX: 0)

        /// DynamicNotchKit's `.bouncy(duration: 0.4)` open: the shape and the content spring in together while the
        /// rings scale away toward the notch.
        static func opening(_ t: Double) -> Pose {
            let e = bounce(t)
            let settled = min(1, max(0, e))
            return Pose(shape: e, contentAlpha: settled, contentScaleY: 0.6 + 0.4 * settled, ringsAlpha: 1 - settled, ringsScaleX: 1 - settled)
        }

        /// NotchController's 0.25 s smooth shrink, the content fading as the shape closes over it.
        static func closing(_ t: Double) -> Pose {
            let e = 1 - smooth(t)
            return Pose(shape: e, contentAlpha: e, contentScaleY: 0.6 + 0.4 * e, ringsAlpha: 1 - e, ringsScaleX: 1 - e)
        }
    }

    /// The real views, drawn once, and the geometry every picture of the top layout shares.
    struct Stage {
        let content: Snapshot
        let leading: Snapshot
        let trailing: Snapshot

        @MainActor
        init(store: UsageStore, prefs: Preferences, actions: NotchActions) throws {
            content = try snapshot(NotchExpandedView(store: store, prefs: prefs, actions: actions, maxHeight: 10_000), what: "the panel")
            leading = try snapshot(NotchCompactView(store: store, side: .leading), what: "the leading rings")
            trailing = try snapshot(NotchCompactView(store: store, side: .trailing), what: "the trailing rings")
        }

        var panelSize: CGSize {
            CGSize(width: content.size.width + 2 * panelInset + 2 * expandedRadii.top, height: notch.height + content.size.height + panelInset)
        }

        var compactSize: CGSize {
            CGSize(width: leading.size.width + trailing.size.width + notch.width + 2 * ringInset + 2 * compactRadii.top, height: notch.height)
        }

        /// The open panel with enough desktop around it to read as a screenshot.
        var panelCanvas: CGSize {
            CGSize(width: panelSize.width + 200, height: panelSize.height + 48)
        }

        func image(_ pose: Pose, canvas: CGSize, pixelScale: CGFloat) throws -> CGImage {
            try bitmap(canvas, pixelScale: pixelScale) { ctx in paint(pose, in: ctx, canvas: canvas, pixelScale: pixelScale) }
        }

        /// The loop: the rings at rest, the open, a pause on the panel, the close, and back.
        ///
        /// The canvas is a parameter because the two GIFs want different framings of the same loop. The README's
        /// has room beside it for the whole panel and takes the default. The gallery's is a 1270×760 frame with
        /// a caption band across the foot, which leaves 568 points for a 1039-point panel; it asks instead for a
        /// canvas cropped around the notch and the Cost card, at 2 px a point, so the loop arrives at the frame
        /// already the size it will be drawn and nothing about it is resampled.
        func demo(canvas: CGSize? = nil, pixelScale: CGFloat = 1) throws -> [Frame] {
            let canvas = canvas ?? CGSize(width: 900, height: panelSize.height + 36)
            var frames: [Frame] = []
            func add(_ pose: Pose, delay: Double) throws {
                frames.append(Frame(image: try image(pose, canvas: canvas, pixelScale: pixelScale), delay: delay))
            }
            for _ in 0..<10 { try add(.compact, delay: 0.06) }
            for step in 0..<24 { try add(.opening(Double(step) / 23), delay: 0.04) }
            for _ in 0..<30 { try add(.expanded, delay: 0.06) }
            for step in 1...12 { try add(.closing(Double(step) / 12), delay: 0.04) }
            for _ in 0..<6 { try add(.compact, delay: 0.06) }
            return frames
        }

        private func paint(_ pose: Pose, in ctx: CGContext, canvas: CGSize, pixelScale: CGFloat) {
            let centerX = canvas.width / 2
            wallpaper(in: ctx, canvas: canvas)
            ctx.setFillColor(CGColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: canvas.width, height: notch.height))
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.06))
            ctx.fill(CGRect(x: 0, y: notch.height - 0.5, width: canvas.width, height: 0.5))
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.addPath(notchPath(CGRect(x: centerX - notch.width / 2, y: 0, width: notch.width, height: notch.height), top: 0, bottom: 10))
            ctx.fillPath()

            let width = lerp(compactSize.width, panelSize.width, pose.shape)
            let height = lerp(compactSize.height, panelSize.height, pose.shape)
            let shape = notchPath(CGRect(x: centerX - width / 2, y: 0, width: width, height: height),
                                  top: lerp(compactRadii.top, expandedRadii.top, pose.shape), bottom: lerp(compactRadii.bottom, expandedRadii.bottom, pose.shape))
            ctx.saveGState()
            let lift = min(1, max(0, pose.shape))
            ctx.setShadow(offset: CGSize(width: 0, height: -10 * pixelScale * lift), blur: 36 * pixelScale * lift, color: CGColor(gray: 0, alpha: 0.55 * lift))
            ctx.addPath(shape)
            ctx.fillPath()
            ctx.restoreGState()

            ctx.saveGState()
            ctx.addPath(shape)
            ctx.clip()
            if pose.contentAlpha > 0 {
                let rect = CGRect(x: centerX - content.size.width / 2, y: notch.height, width: content.size.width, height: content.size.height * pose.contentScaleY)
                draw(content.image, in: rect, alpha: pose.contentAlpha, into: ctx)
            }
            if pose.ringsAlpha > 0 {
                let y = ringInset / 2 + (notch.height - ringInset / 2 - ringInset - leading.size.height) / 2
                let leadingRect = CGRect(x: centerX - notch.width / 2 - leading.size.width * pose.ringsScaleX, y: y,
                                         width: leading.size.width * pose.ringsScaleX, height: leading.size.height)
                let trailingRect = CGRect(x: centerX + notch.width / 2, y: y, width: trailing.size.width * pose.ringsScaleX, height: trailing.size.height)
                draw(leading.image, in: leadingRect, alpha: pose.ringsAlpha, into: ctx)
                draw(trailing.image, in: trailingRect, alpha: pose.ringsAlpha, into: ctx)
            }
            ctx.restoreGState()
        }
    }

    /// DynamicNotchKit's NotchShape: the top corners flare outward into the menu bar, the bottom ones round in.
    static func notchPath(_ rect: CGRect, top: CGFloat, bottom: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top, y: rect.minY + top), control: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY), control: CGPoint(x: rect.minX + top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom), control: CGPoint(x: rect.maxX - top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.closeSubpath()
        return path
    }

    /// A spring with a 0.4 s response and 0.7 damping, sampled so the whole settle fits the morph.
    static func bounce(_ t: Double) -> Double {
        let damping = 0.7
        let omega = 2 * Double.pi / 0.4
        let damped = omega * (1 - damping * damping).squareRoot()
        let time = t * 0.5
        return 1 - exp(-damping * omega * time) * (cos(damped * time) + damping * omega / damped * sin(damped * time))
    }

    static func smooth(_ t: Double) -> Double {
        t * t * (3 - 2 * t)
    }

    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat {
        a + (b - a) * CGFloat(t)
    }

    // MARK: - Drawing

    struct Snapshot {
        let image: CGImage
        let size: CGSize
    }

    struct Frame {
        let image: CGImage
        let delay: Double
    }

    @MainActor private static var windows: [NSWindow] = []

    /// A view at its fitting size, laid out in a window that is never shown. Going through the window rather
    /// than ImageRenderer draws the AppKit-backed controls too: the segmented picker, the buttons, the toggles.
    @MainActor
    static func snapshot<Content: View>(_ content: Content, what: String) throws -> Snapshot {
        let host = NSHostingView(rootView: content)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        windows.append(window)
        return Snapshot(image: try bitmap(of: host, size: size, what: what), size: size)
    }

    @MainActor
    static func bitmap(of view: NSView, size: CGSize, what: String) throws -> CGImage {
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw Failure.snapshot(what) }
        rep.size = size
        view.displayIfNeeded()
        CATransaction.flush()
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.cgImage else { throw Failure.snapshot(what) }
        return image
    }

    /// A bitmap in points with the origin at the top left, like SwiftUI's.
    static func bitmap(_ canvas: CGSize, pixelScale: CGFloat, _ body: (CGContext) -> Void) throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: Int(canvas.width * pixelScale), height: Int(canvas.height * pixelScale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw Failure.snapshot("a \(Int(canvas.width))×\(Int(canvas.height)) canvas") }
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: pixelScale, y: pixelScale)
        ctx.translateBy(x: 0, y: canvas.height)
        ctx.scaleBy(x: 1, y: -1)
        body(ctx)
        guard let image = ctx.makeImage() else { throw Failure.snapshot("a \(Int(canvas.width))×\(Int(canvas.height)) canvas") }
        return image
    }

    /// One flat tone: a gradient bands once the GIF is down to 256 colours.
    static func wallpaper(in ctx: CGContext, canvas: CGSize) {
        ctx.setFillColor(CGColor(srgbRed: 0.13, green: 0.14, blue: 0.17, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: canvas))
    }

    /// Images are drawn upright in the flipped context by flipping back over the rectangle they land in.
    static func draw(_ image: CGImage, in rect: CGRect, alpha: Double, into ctx: CGContext) {
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    // MARK: - Files

    static func write(_ image: CGImage, png url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.encoding(url.lastPathComponent)
        }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encoding(url.lastPathComponent) }
        report(url, "\(image.width)×\(image.height)")
    }

    static func write(_ frames: [Frame], gif url: URL) throws {
        guard let first = frames.first,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil)
        else { throw Failure.encoding(url.lastPathComponent) }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in frames {
            let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: frame.delay, kCGImagePropertyGIFUnclampedDelayTime: frame.delay]]
            CGImageDestinationAddImage(destination, frame.image, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw Failure.encoding(url.lastPathComponent) }
        report(url, "\(first.image.width)×\(first.image.height), \(frames.count) frames, \(String(format: "%.1f", frames.reduce(0) { $0 + $1.delay })) s loop")
    }

    private static func report(_ url: URL, _ detail: String) {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        Probe.emit("\(url.lastPathComponent): \(detail), \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))")
    }
}
