// Draws the app icon into an .iconset directory: swift Tools/make-icon.swift <out.iconset>
// A sheet of music with a folded corner on a dark squircle: a staff with a gold note above piano keys, for the
// composer Joplin is named after.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let gold = rgb(0xD9A84A), goldDark = rgb(0xA87A2A)

func draw(size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    // Small sizes keep only what still reads: the sheet and the keys.
    let detailed = size >= 64

    // Squircle background (macOS icon grid: 824pt body inside 1024 canvas).
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let bg = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 24 * s
    shadow.set()
    rgb(0x16171B).setFill()
    bg.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGradient(starting: rgb(0x34363D), ending: rgb(0x111215))!.draw(in: bg, angle: -90)
    // A faint rim of light along the top edge.
    NSGraphicsContext.current?.saveGraphicsState()
    bg.addClip()
    let rim = NSBezierPath(roundedRect: body.insetBy(dx: 2 * s, dy: 2 * s), xRadius: 183 * s, yRadius: 183 * s)
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)])!
        .draw(in: rim.withStroke(width: max(1, 3 * s)), angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // The sheet, with its top right corner folded.
    let page = NSRect(x: 252 * s, y: 196 * s, width: 520 * s, height: 620 * s)
    let fold: CGFloat = 118 * s, r: CGFloat = 26 * s
    let sheet = NSBezierPath()
    sheet.move(to: NSPoint(x: page.minX + r, y: page.minY))
    sheet.line(to: NSPoint(x: page.maxX - r, y: page.minY))
    sheet.curve(to: NSPoint(x: page.maxX, y: page.minY + r), controlPoint1: NSPoint(x: page.maxX, y: page.minY),
                controlPoint2: NSPoint(x: page.maxX, y: page.minY))
    sheet.line(to: NSPoint(x: page.maxX, y: page.maxY - fold))
    sheet.line(to: NSPoint(x: page.maxX - fold, y: page.maxY))
    sheet.line(to: NSPoint(x: page.minX + r, y: page.maxY))
    sheet.curve(to: NSPoint(x: page.minX, y: page.maxY - r), controlPoint1: NSPoint(x: page.minX, y: page.maxY),
                controlPoint2: NSPoint(x: page.minX, y: page.maxY))
    sheet.line(to: NSPoint(x: page.minX, y: page.minY + r))
    sheet.curve(to: NSPoint(x: page.minX + r, y: page.minY), controlPoint1: NSPoint(x: page.minX, y: page.minY),
                controlPoint2: NSPoint(x: page.minX, y: page.minY))
    sheet.close()
    NSGraphicsContext.current?.saveGraphicsState()
    let paperShadow = NSShadow()
    paperShadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
    paperShadow.shadowOffset = NSSize(width: 0, height: -12 * s)
    paperShadow.shadowBlurRadius = 30 * s
    paperShadow.set()
    rgb(0xEFE8DA).setFill()
    sheet.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGradient(starting: rgb(0xF7F2E8), ending: rgb(0xE3DACA))!.draw(in: sheet, angle: -90)

    // Piano keys across the lower part of the sheet.
    NSGraphicsContext.current?.saveGraphicsState()
    sheet.addClip()
    let keys = NSRect(x: page.minX, y: page.minY, width: page.width, height: 330 * s)
    let whiteCount = 7
    let keyWidth = keys.width / CGFloat(whiteCount)
    rgb(0x2A2B30).setFill()
    NSRect(x: keys.minX, y: keys.maxY - 10 * s, width: keys.width, height: 10 * s).fill()  // the keyboard's lid edge
    rgb(0xB8AE9B).setFill()
    for i in 1..<whiteCount {
        NSRect(x: keys.minX + CGFloat(i) * keyWidth - max(0.5, 3 * s), y: keys.minY, width: max(1, 6 * s), height: keys.height - 10 * s).fill()
    }
    // Black keys sit between C–D, D–E, F–G, G–A, A–B.
    for i in [1, 2, 4, 5, 6] {
        let w = keyWidth * 0.58, h = keys.height * 0.58
        let key = NSRect(x: keys.minX + CGFloat(i) * keyWidth - w / 2, y: keys.maxY - 10 * s - h, width: w, height: h)
        let shape = NSBezierPath(roundedRect: key, xRadius: 9 * s, yRadius: 9 * s)
        NSGradient(starting: rgb(0x3A3B42), ending: rgb(0x121317))!.draw(in: shape, angle: -90)
    }
    NSGraphicsContext.current?.restoreGraphicsState()

    // The folded corner.
    let corner = NSBezierPath()
    corner.move(to: NSPoint(x: page.maxX - fold, y: page.maxY))
    corner.line(to: NSPoint(x: page.maxX - fold + 10 * s, y: page.maxY - fold + 10 * s))
    corner.line(to: NSPoint(x: page.maxX, y: page.maxY - fold))
    corner.close()
    NSGradient(starting: rgb(0xCFC4B0), ending: rgb(0xA99E8A))!.draw(in: corner, angle: -45)

    // A staff with a gold note above the keys.
    if detailed {
        let staffTop = page.maxY - 150 * s, gap: CGFloat = 30 * s
        rgb(0x8F8676).setFill()
        for i in 0..<5 {
            NSRect(x: page.minX + 50 * s, y: staffTop - CGFloat(i) * gap, width: page.width - 100 * s - fold * 0.35,
                   height: max(1, 5 * s)).fill()
        }
        // Two beamed eighth notes, the first on the lowest line and the second a step higher.
        let heads = [NSPoint(x: page.minX + 200 * s, y: staffTop - 4 * gap + 2 * s),
                     NSPoint(x: page.minX + 330 * s, y: staffTop - 3 * gap + 2 * s)]
        // Stems end on the beam, which rises a little to the right.
        let tops = [staffTop + 40 * s, staffTop + 58 * s]
        for (h, top) in zip(heads, tops) {
            let head = NSBezierPath(ovalIn: NSRect(x: -30 * s, y: -21 * s, width: 60 * s, height: 42 * s))
            var t = AffineTransform(translationByX: h.x, byY: h.y)
            t.rotate(byDegrees: 22)
            head.transform(using: t)
            NSGradient(starting: gold, ending: goldDark)!.draw(in: head, angle: -90)
            gold.setFill()
            NSRect(x: h.x + 22 * s, y: h.y + 6 * s, width: 10 * s, height: top - h.y - 6 * s).fill()
        }
        let beam = NSBezierPath()
        beam.move(to: NSPoint(x: heads[0].x + 22 * s, y: tops[0] + 4 * s))
        beam.line(to: NSPoint(x: heads[1].x + 32 * s, y: tops[1] + 4 * s))
        beam.line(to: NSPoint(x: heads[1].x + 32 * s, y: tops[1] - 26 * s))
        beam.line(to: NSPoint(x: heads[0].x + 22 * s, y: tops[0] - 26 * s))
        beam.close()
        gold.setFill()
        beam.fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

extension NSBezierPath {
    /// The area the stroke of the path covers.
    func withStroke(width: CGFloat) -> NSBezierPath {
        NSBezierPath(cgPath: cgPath.copy(strokingWithWidth: width, lineCap: .butt, lineJoin: .round, miterLimit: 10))
    }
}

for base in [16, 32, 128, 256, 512] {
    try! draw(size: CGFloat(base)).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(size: CGFloat(base * 2)).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
