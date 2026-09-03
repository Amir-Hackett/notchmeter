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
            let (store, prefs) = DemoFixtures.store(now: now)
            let actions = NotchActions()
            let stage = try Stage(store: store, prefs: prefs, actions: actions)
            try write(stage.image(.expanded, canvas: stage.panelCanvas, pixelScale: scale), png: directory.appendingPathComponent("expanded.png"))
            try write(stage.image(.compact, canvas: CGSize(width: 1200, height: 80), pixelScale: scale), png: directory.appendingPathComponent("compact-top.png"))
            try write(edgePill(store: store), png: directory.appendingPathComponent("edge-left.png"))
            try write(settings(store: store, prefs: prefs, actions: actions), png: directory.appendingPathComponent("settings.png"))
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

    /// `--render-gallery <dir>`: Product Hunt's eight 1270×760 composites and the 240×240 thumbnail, each frame
    /// centred on a #1c1c1e canvas with its caption drawn into the image (the gallery strips captions on mobile).
    @MainActor
    static func gallery(into directory: URL, now: Date = Date()) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let (store, prefs) = DemoFixtures.store(now: now)
            let actions = NotchActions()
            let stage = try Stage(store: store, prefs: prefs, actions: actions)
            let canvas = CGSize(width: 1270, height: 760)
            let panel = try stage.image(.expanded, canvas: stage.panelCanvas, pixelScale: 1)
            let compact = try stage.image(.compact, canvas: CGSize(width: 1200, height: 80), pixelScale: 1)
            let pill = try edgePill(store: store)
            let settingsImage = try settings(store: store, prefs: prefs, actions: actions)
            let frames: [(name: String, image: CGImage?, caption: String, lines: [String])] = [
                ("01-hover", panel, L("Hover the rings. The panel opens."), []),
                ("02-compact", compact, L("Your menu bar ran out of room three apps ago. This one doesn't take any."), []),
                ("03-advice", panel, L("Tells you what to do, not just how much."), [
                    "Opus weekly is 91%. Sonnet is 34%. Switch models, not tools.",
                    "At this rate you hit the Claude weekly cap Thursday at 2:00 PM.",
                    "Codex has 78% of its weekly left.",
                ]),
                ("04-pace", panel, L("Pace tick, projection, reset time. Notifications at pace crossings."), []),
                ("05-accuracy", nil, L("Every number shows its work."), [
                    "Five token buckets: input, output, 5-minute and 1-hour cache writes, cache reads.",
                    "1.1× on inference_geo \"us\". Web search at $10 per 1,000. Fast mode at its own rate.",
                    "The output_tokens placeholder: the last line of a streamed response is the real count (35% more on this Mac).",
                    "Golden-transcript tests pin every rule. docs/accuracy.md",
                ]),
                ("06-energy", nil, L("0.02% of one core when idle. Nothing while the screen is locked."), [
                    "60 s, no cost scan: 0.01 CPU-seconds / 61 s = 0.02% of one core",
                    "180 s with one cached cost scan: 0.86 CPU-seconds / 182 s = 0.47%",
                    "37 to 69 MB resident. ps and top on an M5 Pro; powermetrics next.",
                ]),
                ("07-edges", pill, L("Left, right or bottom edge on any Mac."), []),
                ("08-settings", settingsImage, L("Position, hover or always open, hook install with a backup."), []),
            ]
            for frame in frames {
                let image = try composite(frame.image, caption: frame.caption, lines: frame.lines, canvas: canvas, mirrorPill: frame.name == "07-edges")
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
    static func composite(_ image: CGImage?, caption: String, lines: [String], canvas: CGSize, mirrorPill: Bool) throws -> CGImage {
        try bitmap(canvas, pixelScale: 1) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 0x1c / 255, green: 0x1c / 255, blue: 0x1e / 255, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: canvas))
            let captionHeight: CGFloat = 96
            let margin: CGFloat = 48
            var textTop: CGFloat = margin
            if let image {
                let width = CGFloat(image.width), height = CGFloat(image.height)
                let available = CGSize(width: lines.isEmpty ? canvas.width - 2 * margin : canvas.width * 0.5, height: canvas.height - captionHeight - 2 * margin)
                let scale = min(available.width / width, available.height / height, 1)
                let size = CGSize(width: width * scale, height: height * scale)
                let x = lines.isEmpty ? (canvas.width - size.width) / 2 : margin
                let rect = CGRect(x: x, y: margin + (available.height - size.height) / 2, width: size.width, height: size.height)
                draw(image, in: rect, alpha: 1, into: ctx)
                if mirrorPill {
                    ctx.saveGState()
                    ctx.translateBy(x: canvas.width, y: 0)
                    ctx.scaleBy(x: -1, y: 1)
                    draw(image, in: CGRect(x: x, y: rect.minY, width: size.width, height: size.height), alpha: 1, into: ctx)
                    ctx.restoreGState()
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

    /// The left-edge pill on a strip of desktop, as it looks before Liquid Glass: the glass material samples what
    /// is behind the window, which an off-screen bitmap has none of.
    @MainActor
    static func edgePill(store: UsageStore) throws -> CGImage {
        let canvas = CGSize(width: 240, height: 240)
        let rings = try snapshot(EdgeCompactView(store: store, edge: .left), what: "the edge rings")
        return try bitmap(canvas, pixelScale: scale) { ctx in
            wallpaper(in: ctx, canvas: canvas)
            let pill = CGRect(x: 6 + 4, y: (canvas.height - rings.size.height) / 2, width: rings.size.width, height: rings.size.height)
            let capsule = CGPath(roundedRect: pill, cornerWidth: pill.width / 2, cornerHeight: pill.width / 2, transform: nil)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -4 * scale), blur: 16 * scale, color: CGColor(gray: 0, alpha: 0.5))
            ctx.addPath(capsule)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fillPath()
            ctx.restoreGState()
            ctx.addPath(capsule)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12))
            ctx.setLineWidth(0.5)
            ctx.strokePath()
            draw(rings.image, in: pill, alpha: 1, into: ctx)
        }
    }

    /// The Settings window, title bar included, in the dark appearance the notch panel always has.
    @MainActor
    static func settings(store: UsageStore, prefs: Preferences, actions: NotchActions) throws -> CGImage {
        let controller = SettingsWindowController(store: store, prefs: prefs, actions: actions, notifier: Notifier(available: false), requests: SettingsRequests())
        guard let window = controller.window, let frame = window.contentView?.superview else { throw Failure.snapshot("the Settings window") }
        window.appearance = NSAppearance(named: .darkAqua)
        // The window opens at 640 pt and scrolls; the picture shows the whole form.
        window.setContentSize(NSSize(width: 460, height: 9000))
        window.contentView?.layoutSubtreeIfNeeded()
        windows.append(window)
        return try bitmap(of: frame, size: frame.bounds.size, what: "the Settings window")
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

        /// The README's loop: the rings at rest, the open, a pause on the panel, the close, and back.
        func demo() throws -> [Frame] {
            let canvas = CGSize(width: 900, height: panelSize.height + 36)
            var frames: [Frame] = []
            func add(_ pose: Pose, delay: Double) throws {
                frames.append(Frame(image: try image(pose, canvas: canvas, pixelScale: 1), delay: delay))
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
