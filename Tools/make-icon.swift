import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("AppIcon.svg")
guard let art = NSImage(contentsOf: source) else { fatalError("Cannot read \(source.path)") }
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let s = size / 1024
    art.draw(in: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! draw(size: CGFloat(base)).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(size: CGFloat(base * 2)).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
