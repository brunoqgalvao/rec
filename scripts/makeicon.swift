// Generates AppIcon.iconset PNGs for rec.app: a record glyph (ring + dot)
// with a red glow on the same dark gradient squircle as talk's icon — the
// two apps read as siblings. Run via `make app`; iconutil builds the icns.

import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build"
let iconsetPath = "\(outDir)/AppIcon.iconset"
try! FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

func pngData(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(pixels)
    let margin = s * 0.098
    let plate = NSRect(x: margin, y: margin, width: s - 2 * margin, height: s - 2 * margin)
    let squircle = NSBezierPath(roundedRect: plate, xRadius: s * 0.185, yRadius: s * 0.185)

    NSGradient(colors: [
        NSColor(calibratedRed: 0.075, green: 0.075, blue: 0.09, alpha: 1),
        NSColor(calibratedRed: 0.135, green: 0.135, blue: 0.155, alpha: 1),
    ])!.draw(in: squircle, angle: 90)

    NSGraphicsContext.current?.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [
        NSColor(calibratedWhite: 1, alpha: 0),
        NSColor(calibratedWhite: 1, alpha: 0.10),
    ])!.draw(in: NSRect(x: plate.minX, y: plate.maxY - s * 0.05, width: plate.width, height: s * 0.05),
             angle: 90)
    NSGraphicsContext.current?.restoreGraphicsState()

    let redTop = NSColor(calibratedRed: 1.0, green: 0.42, blue: 0.34, alpha: 1)
    let redBottom = NSColor(calibratedRed: 0.95, green: 0.19, blue: 0.16, alpha: 1)

    // record glyph: outer ring + inner dot, centered
    let ringOuter = s * 0.56
    let ringWidth = s * 0.055
    let dotSize = s * 0.30
    let ringRect = NSRect(x: (s - ringOuter) / 2, y: (s - ringOuter) / 2,
                          width: ringOuter, height: ringOuter)
    let dotRect = NSRect(x: (s - dotSize) / 2, y: (s - dotSize) / 2,
                         width: dotSize, height: dotSize)
    let ring = NSBezierPath(ovalIn: ringRect)
    ring.lineWidth = ringWidth
    let dot = NSBezierPath(ovalIn: dotRect)

    // glow pass
    NSGraphicsContext.current?.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = NSColor(calibratedRed: 1.0, green: 0.27, blue: 0.23, alpha: 0.45)
    glow.shadowBlurRadius = s * 0.05
    glow.set()
    redBottom.setStroke()
    ring.stroke()
    redBottom.setFill()
    dot.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // gradient pass: clip to the ring stroke (as a filled donut) and the dot
    NSGraphicsContext.current?.saveGraphicsState()
    let donut = NSBezierPath(ovalIn: ringRect.insetBy(dx: -ringWidth / 2, dy: -ringWidth / 2))
    donut.appendOval(in: ringRect.insetBy(dx: ringWidth / 2, dy: ringWidth / 2))
    donut.windingRule = .evenOdd
    donut.addClip()
    NSGradient(colors: [redBottom, redTop])!.draw(in: ringRect.insetBy(dx: -ringWidth, dy: -ringWidth), angle: 90)
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGraphicsContext.current?.saveGraphicsState()
    dot.addClip()
    NSGradient(colors: [redBottom, redTop])!.draw(in: dotRect, angle: 90)
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, pixels) in variants {
    try! pngData(pixels: pixels).write(to: URL(fileURLWithPath: "\(iconsetPath)/\(name)"))
}
print("wrote \(iconsetPath)")
