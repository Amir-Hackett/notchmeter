// Writes the icon macOS itself draws for a bundle, at a size, as a PNG: the Liquid Glass one when the bundle carries
// the compiled Assets.car (scripts/build.sh, docs/release.md "The icon"), and the .icns otherwise. The site's brand
// mark comes from here, so the page shows the icon the Mac shows rather than a flat copy of it.
// Run: swift scripts/render-app-icon.swift build/Notchmeter.app site/img/icon.png 256
import AppKit

guard CommandLine.arguments.count > 2 else {
    FileHandle.standardError.write(Data("usage: render-app-icon.swift <app> <out.png> [size]\n".utf8))
    exit(2)
}
// Absolute, because LaunchServices answers a relative path with the generic document icon rather than the bundle's.
let app = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.path
let out = CommandLine.arguments[2]
let side = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3]) ?? 256 : 256

guard FileManager.default.fileExists(atPath: app) else {
    FileHandle.standardError.write(Data("no bundle at \(app)\n".utf8))
    exit(1)
}
let icon = NSWorkspace.shared.icon(forFile: app)
// A bundle LaunchServices does not know yet comes back as the generic document icon, which is not worth writing
// over the brand mark; the caller falls back to the iconset when this fails.
let generic = NSWorkspace.shared.icon(for: .data)
if icon.tiffRepresentation == generic.tiffRepresentation {
    FileHandle.standardError.write(Data("\(app) answered the generic icon; not writing it\n".utf8))
    exit(1)
}
icon.size = NSSize(width: side, height: side)
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out) at \(side) pt")
