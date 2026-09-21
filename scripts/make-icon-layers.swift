// Renders the layers of the Icon Composer document (packaging/AppIcon.icon) from the same geometry as make-icon.swift:
// the notch, the ring's track and the ring's arc, each as a 1024-pixel PNG with alpha and nothing else on it, so
// Liquid Glass can light, tint and shade them as separate layers over the document's fill. Run:
//   swift scripts/make-icon-layers.swift packaging/AppIcon.icon/Assets
// The tile itself (the dark rounded square) is the document's fill and is not a layer; macOS draws the shape.
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/icon-layers"
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let terracotta = NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
let s: CGFloat = 1024

func layer(_ name: String, _ draw: () -> Void) throws {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(s), pixelsHigh: Int(s), bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}

// The notch: the same proportions as make-icon.swift, clipped by the tile there and by the icon shape here.
try layer("notch") {
    let notchWidth = s * 0.44
    let notchHeight = s * 0.115
    NSColor.black.setFill()
    NSBezierPath(roundedRect: NSRect(x: (s - notchWidth) / 2, y: s - notchHeight, width: notchWidth, height: notchHeight * 2),
                 xRadius: s * 0.045, yRadius: s * 0.045).fill()
}

let center = NSPoint(x: s / 2, y: s * 0.44)
let radius = s * 0.24
let width = s * 0.07

// The track: the full ring, drawn solid so the layer's own opacity (0.22 in icon.json) sets how faint it is.
// The arc: 252° from the top, clockwise, round caps — the reading the icon has always shown.
// Each comes twice: in the terracotta for the default and dark appearances, and in white for the tinted (mono
// and clear) appearances, where the system tints a near-white shape and would only grey a coloured one.
for (suffix, colour) in [("", terracotta), ("-mono", NSColor.white)] {
    try layer("track\(suffix)") {
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = width
        colour.setStroke()
        track.stroke()
    }
    try layer("arc\(suffix)") {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 252, clockwise: true)
        arc.lineWidth = width
        arc.lineCapStyle = .round
        colour.setStroke()
        arc.stroke()
    }
}
print("wrote layers to \(outDir)")
