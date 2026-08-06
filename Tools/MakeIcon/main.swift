// Generates Resources/AppIcon.icns from Resources/claude-mark.png.
//
// Run through `make icon`, not by hand: this is a throwaway CLI, so it is top-level code
// in a file that has to be named main.swift and is compiled on its own (Sources/ is
// -parse-as-library and already has an @main).
//
// The plate follows Apple's macOS grid: a 1024 canvas with an 824 rounded square inset
// in it, corner radius 185.4 (22.5% of the plate), which is what makes the icon line up
// with every stock app in the Dock. The mark is the same white silhouette the menu bar
// draws, so the two read as one app.

import AppKit

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // MakeIcon
    .deletingLastPathComponent()   // Tools
    .deletingLastPathComponent()   // repo root
let resources = root.appendingPathComponent("Resources")

guard let mark = NSImage(contentsOf: resources.appendingPathComponent("claude-mark.png")) else {
    FileHandle.standardError.write(Data("error: Resources/claude-mark.png not found\n".utf8))
    exit(1)
}

// Deep indigo, deliberately not Claude's terracotta: the app is unofficial, and an icon in
// Anthropic's own brand color would read as a first-party app in the Dock.
let top = NSColor(srgbRed: 0.42, green: 0.40, blue: 0.85, alpha: 1)     // #6B66D9
let bottom = NSColor(srgbRed: 0.15, green: 0.14, blue: 0.33, alpha: 1)  // #262454

/// Draws the full 1024x1024 icon into a bitmap at `size` and returns its PNG data.
func renderPNG(size: CGFloat) -> Data {
    let px = Int(size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("could not allocate \(px)x\(px) bitmap") }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    let s = size / 1024                      // everything below is in 1024-space
    let plate = NSRect(x: 100 * s, y: 90 * s, width: 824 * s, height: 824 * s)
    let radius = 185.4 * s
    let shape = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)

    // Contact shadow, so the plate sits on the desktop instead of floating flat on it.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s,
                  color: NSColor(white: 0, alpha: 0.35).cgColor)
    NSColor.black.setFill()
    shape.fill()
    ctx.restoreGState()

    NSGradient(starting: top, ending: bottom)?.draw(in: shape, angle: -90)

    // A soft highlight across the top third and a hairline rim: both are what keep a flat
    // gradient from reading as a rectangle of paint at 512pt in Finder.
    ctx.saveGState()
    shape.addClip()
    NSGradient(colors: [NSColor(white: 1, alpha: 0.18), NSColor(white: 1, alpha: 0)])?
        .draw(in: NSRect(x: plate.minX, y: plate.midY, width: plate.width, height: plate.height / 2),
              angle: -90)
    ctx.restoreGState()

    let rim = NSBezierPath(roundedRect: plate.insetBy(dx: 1.5 * s, dy: 1.5 * s),
                           xRadius: radius, yRadius: radius)
    rim.lineWidth = 3 * s
    NSColor(white: 1, alpha: 0.16).setStroke()
    rim.stroke()

    // The mark is white with alpha, so it composites as-is; 46% of the plate keeps it
    // inside Apple's optical margins rather than crowding the corners.
    let markSide = plate.width * 0.46
    let markRect = NSRect(x: plate.midX - markSide / 2,
                          y: plate.midY - markSide / 2,
                          width: markSide, height: markSide)
    mark.draw(in: markRect, from: .zero, operation: .sourceOver, fraction: 1,
              respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])

    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode PNG")
    }
    return png
}

// iconutil wants this exact set of names; anything missing makes it fail outright.
let sizes: [(name: String, px: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

let iconset = URL(fileURLWithPath: CommandLine.arguments.count > 1
                  ? CommandLine.arguments[1]
                  : NSTemporaryDirectory() + "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for (name, px) in sizes {
    try renderPNG(size: px).write(to: iconset.appendingPathComponent("\(name).png"))
}

// Also drop a 1024 PNG next to the iconset for the README.
try renderPNG(size: 1024).write(to: iconset.deletingLastPathComponent()
    .appendingPathComponent("AppIcon-1024.png"))

print("==> wrote \(iconset.path)")
