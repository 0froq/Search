// The app's icon, drawn rather than exported: the mark is Drice's logo.svg,
// reproduced as the same fourteen rectangles rather than loaded from a file,
// so it stays a crisp vector at every size instead of a raster scaled up.
// Unlike everywhere else the mark appears, the icon puts it on a plate —
// a Dock icon has to be an opaque square whether the logo itself wants a
// background or not.
//
// Run by build.sh:  swift Icon/icon.swift <iconset folder>
// It writes every size macOS asks for; iconutil folds them into one .icns.

import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

/// The source's own canvas, top-left origin, the way an image reads: 493
/// wide, 293 tall, nothing outside it. See also Design.swift's `Logomark`,
/// the same shape for SwiftUI, and search.html's `--mark` SVG for the web —
/// all three read from the same fourteen numbers.
let canvas = (width: 493.0, height: 293.0)
let bars: [(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat)] = [
    (462, 82.635, 492.049, 161.513), (462, 131.464, 492.049, 210.342),
    (416.927, 41.317, 446.976, 120.195), (416.927, 172.781, 446.976, 251.659),
    (334.293, 11.269, 364.342, 90.147), (334.293, 202.83, 364.342, 281.708),
    (232.878, 0, 262.927, 78.878), (232.878, 214.098, 262.927, 292.976),
    (0, 131.464, 30.049, 210.342), (0, 82.635, 30.049, 161.513),
    (45.073, 172.781, 75.122, 251.659), (45.073, 41.317, 75.122, 120.195),
    (127.707, 202.83, 157.756, 281.708), (127.707, 11.269, 157.756, 90.147),
]

/// The mark, fit to `fraction` of `plate`'s width and centred on it —
/// AppKit's y grows upward, the source's grows downward, so each bar's y is
/// flipped on the way in.
func markPath(in plate: NSRect, fraction: CGFloat) -> NSBezierPath {
    let scale = plate.width * fraction / canvas.width
    let markSize = NSSize(width: canvas.width * scale, height: canvas.height * scale)
    let ox = plate.midX - markSize.width / 2
    let oy = plate.midY - markSize.height / 2
    let path = NSBezierPath()
    for bar in bars {
        let x = ox + bar.x0 * scale
        let bottom = oy + (canvas.height - bar.y1) * scale
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
    NSColor.white.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // The mark, black on the plate, at the size it actually is in Drice's
    // own file rather than blown up for "Dock presence" — that was a choice
    // this file made on its own, not one the logo asked for.
    NSColor(red: 0.09, green: 0.09, blue: 0.09, alpha: 1).setFill()
    markPath(in: plate, fraction: 0.46).fill()
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
