// Draws the app icon into an .iconset directory: swift Tools/make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // Squircle background (macOS icon grid: 824pt body inside 1024 canvas).
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let bg = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 24 * s
    shadow.set()
    NSColor(calibratedRed: 0.12, green: 0.35, blue: 0.78, alpha: 1).setFill()
    bg.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.52, blue: 0.96, alpha: 1),
               ending: NSColor(calibratedRed: 0.08, green: 0.27, blue: 0.66, alpha: 1))!.draw(in: bg, angle: -90)

    // Paper sheet with folded corner.
    let page = NSRect(x: 300 * s, y: 230 * s, width: 424 * s, height: 540 * s)
    let fold: CGFloat = 110 * s
    let sheet = NSBezierPath()
    sheet.move(to: NSPoint(x: page.minX, y: page.minY))
    sheet.line(to: NSPoint(x: page.maxX, y: page.minY))
    sheet.line(to: NSPoint(x: page.maxX, y: page.maxY - fold))
    sheet.line(to: NSPoint(x: page.maxX - fold, y: page.maxY))
    sheet.line(to: NSPoint(x: page.minX, y: page.maxY))
    sheet.close()
    NSGraphicsContext.current?.saveGraphicsState()
    let paperShadow = NSShadow()
    paperShadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    paperShadow.shadowOffset = NSSize(width: 0, height: -8 * s)
    paperShadow.shadowBlurRadius = 20 * s
    paperShadow.set()
    NSColor.white.setFill()
    sheet.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    let corner = NSBezierPath()
    corner.move(to: NSPoint(x: page.maxX - fold, y: page.maxY))
    corner.line(to: NSPoint(x: page.maxX - fold, y: page.maxY - fold))
    corner.line(to: NSPoint(x: page.maxX, y: page.maxY - fold))
    corner.close()
    NSColor(calibratedWhite: 0.82, alpha: 1).setFill()
    corner.fill()

    // Text lines and a checked box.
    let blue = NSColor(calibratedRed: 0.15, green: 0.42, blue: 0.88, alpha: 1)
    let gray = NSColor(calibratedWhite: 0.78, alpha: 1)
    blue.setFill()
    NSBezierPath(roundedRect: NSRect(x: 350 * s, y: 620 * s, width: 230 * s, height: 34 * s), xRadius: 17 * s, yRadius: 17 * s).fill()
    gray.setFill()
    for (i, w) in [324.0, 290.0, 324.0].enumerated() {
        let y = (540 - Double(i) * 70) * Double(s)
        NSBezierPath(roundedRect: NSRect(x: 350 * s, y: CGFloat(y), width: CGFloat(w) * s, height: 24 * s), xRadius: 12 * s, yRadius: 12 * s).fill()
    }
    let box = NSRect(x: 350 * s, y: 290 * s, width: 56 * s, height: 56 * s)
    blue.setFill()
    NSBezierPath(roundedRect: box, xRadius: 12 * s, yRadius: 12 * s).fill()
    let check = NSBezierPath()
    check.lineWidth = 9 * s
    check.lineCapStyle = .round
    check.lineJoinStyle = .round
    check.move(to: NSPoint(x: box.minX + 13 * s, y: box.midY))
    check.line(to: NSPoint(x: box.minX + 24 * s, y: box.minY + 15 * s))
    check.line(to: NSPoint(x: box.maxX - 12 * s, y: box.maxY - 14 * s))
    NSColor.white.setStroke()
    check.stroke()
    gray.setFill()
    NSBezierPath(roundedRect: NSRect(x: 430 * s, y: 306 * s, width: 230 * s, height: 24 * s), xRadius: 12 * s, yRadius: 12 * s).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! draw(size: CGFloat(base)).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(size: CGFloat(base * 2)).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
