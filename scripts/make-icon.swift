// Renders the app icon (black tile, notch, usage ring) into an .iconset directory.
// Run: swift scripts/make-icon.swift build/AppIcon.iconset
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset"
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let terracotta = NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)

func draw(_ s: CGFloat) {
    let tile = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s), xRadius: s * 0.225, yRadius: s * 0.225)
    NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
    tile.fill()
    tile.addClip()

    let notchWidth = s * 0.44
    let notchHeight = s * 0.115
    let notch = NSBezierPath(
        roundedRect: NSRect(x: (s - notchWidth) / 2, y: s - notchHeight, width: notchWidth, height: notchHeight * 2),
        xRadius: s * 0.045, yRadius: s * 0.045
    )
    NSColor.black.setFill()
    notch.fill()

    let center = NSPoint(x: s / 2, y: s * 0.44)
    let radius = s * 0.24
    let width = s * 0.07

    let track = NSBezierPath()
    track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
    track.lineWidth = width
    terracotta.withAlphaComponent(0.22).setStroke()
    track.stroke()

    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 252, clockwise: true)
    arc.lineWidth = width
    arc.lineCapStyle = .round
    terracotta.setStroke()
    arc.stroke()
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try png(pixels: size).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(size)x\(size).png"))
    try png(pixels: size * 2).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(size)x\(size)@2x.png"))
}
print("wrote iconset to \(outDir)")
