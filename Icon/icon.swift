// The app's icon, drawn rather than exported: the mark is twelve rectangles
// — the same shape wherever it appears, in code, and in Office Commun's
// logo.png — so it stays a crisp vector at every size instead of a raster
// scaled up to fit.
//
// Run by build.sh:  swift Icon/icon.swift <iconset folder>
// It writes every size macOS asks for; iconutil folds them into one .icns.

import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

/// The mark: twelve bars around a centre, read from Office Commun's
/// logo.png at 1000×1000 — top-left origin, the way an image reads. Kept
/// as plain numbers rather than a file so drawing it costs nothing to build
/// and nothing to bundle. See also Design.swift's `Logomark`, the same
/// shape drawn for SwiftUI, and search.html's `--mark` SVG for the web.
let bars: [(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat)] = [
    (254, 436, 284, 564), (299, 395, 329, 474), (299, 526, 329, 605),
    (382, 365, 412, 444), (382, 556, 412, 635), (487, 354, 517, 432),
    (487, 568, 517, 646), (588, 365, 618, 444), (588, 556, 618, 635),
    (671, 395, 701, 474), (671, 526, 701, 605), (716, 436, 746, 564),
]

/// The bars, filled into `plate` at `scale` — 1 unit of the 1000-wide source
/// per point of `scale`, centred on the plate regardless of its size.
func markPath(in plate: NSRect, scale: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    for bar in bars {
        let x = plate.midX + (bar.x0 - 500) * scale
        let bottom = plate.midY + (500 - bar.y1) * scale
        let width = (bar.x1 - bar.x0) * scale
        let height = (bar.y1 - bar.y0) * scale
        path.append(NSBezierPath(rect: NSRect(x: x, y: bottom, width: width, height: height)))
    }
    return path
}

func draw(_ size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    // Apple's grid: the shape takes 824 of 1024, and its corners are 22.37%.
    let s = size / 1024
    let plate = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let radius = 824 * 0.2237 * s
    let shape = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)

    // A soft shadow under the plate, the way every icon on the Dock has one.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    NSColor(red: 0.09, green: 0.09, blue: 0.09, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // The mark, white on the plate — scaled up from its own 1000-wide
    // drawing so it reads with the same confidence a single glyph did.
    NSColor.white.setFill()
    markPath(in: plate, scale: 1.35 * s).fill()
    return image
}

func write(_ image: NSImage, to url: URL, pixels: Int) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff)
    else { return }
    // The bitmap is asked for at the pixel size, whatever the screen thinks.
    let sized = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    sized.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sized)
    NSGraphicsContext.current?.imageInterpolation = .high
    rep.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = sized.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: url)
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let image = draw(CGFloat(pixels))
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        write(image, to: out.appendingPathComponent(name), pixels: pixels)
    }
}
print("drew: \(out.path)")
