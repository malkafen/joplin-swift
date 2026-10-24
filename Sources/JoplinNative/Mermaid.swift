import AppKit

enum Mermaid {
    static func image(_ source: String, fontSize: CGFloat = 13) -> NSImage? {
        let lines = source.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("%%") }
        guard let header = lines.first?.lowercased() else { return nil }
        let body = Array(lines.dropFirst())
        let font = NSFont.systemFont(ofSize: fontSize)
        if header.hasPrefix("graph") || header.hasPrefix("flowchart") {
            let chart = Flowchart.parse(header: header, lines: body)
            return chart.nodes.isEmpty ? nil : FlowLayout(chart, font: font).image()
        }
        if header.hasPrefix("statediagram") {
            let chart = Flowchart.parseState(lines: body)
            return chart.nodes.isEmpty ? nil : FlowLayout(chart, font: font).image()
        }
        if header.hasPrefix("sequencediagram") {
            let diagram = SequenceDiagram.parse(body)
            return diagram.participants.isEmpty ? nil : SequenceLayout(diagram, font: font).image()
        }
        if header.hasPrefix("pie") {
            let pie = Pie.parse(header: lines[0], lines: body)
            return pie.slices.isEmpty ? nil : pie.image(font: font)
        }
        return nil
    }

    static func cleanLabel(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") { s = String(s.dropFirst().dropLast()) }
        if s.count >= 2, s.hasPrefix("`"), s.hasSuffix("`") { s = String(s.dropFirst().dropLast()) }
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "#quot;", with: "\"")
            .replacingOccurrences(of: "#amp;", with: "&")
            .replacingOccurrences(of: "#lt;", with: "<")
            .replacingOccurrences(of: "#gt;", with: ">")
            .replacingOccurrences(of: "fa:fa-[a-z-]+\\s*", with: "", options: .regularExpression)
        return HTMLTokens.decode(s)
    }

    static func color(_ css: String) -> NSColor? {
        var hex = css.trimmingCharacters(in: .whitespaces).lowercased()
        guard hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

enum DiagramStyle {
    static var nodeFill: NSColor { NSColor.controlAccentColor.withAlphaComponent(0.12) }
    static var nodeStroke: NSColor { NSColor.controlAccentColor.withAlphaComponent(0.75) }
    static var line: NSColor { .secondaryLabelColor }
    static var text: NSColor { .labelColor }
    static var groupFill: NSColor { subtleFill }
    static let palette: [NSColor] = [
        .systemBlue, .systemOrange, .systemGreen, .systemPink, .systemPurple, .systemTeal, .systemYellow, .systemRed,
        .systemIndigo, .systemBrown, .systemMint, .systemCyan,
    ]

    static func measure(_ text: String, font: NSFont, maxWidth: CGFloat = 220) -> CGSize {
        guard !text.isEmpty else { return .zero }
        let r = NSAttributedString(string: text, attributes: [.font: font])
            .boundingRect(with: NSSize(width: maxWidth, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: ceil(r.width), height: ceil(r.height))
    }

    static func draw(_ text: String, in rect: CGRect, font: NSFont, color: NSColor = text,
                     align: NSTextAlignment = .center) {
        guard !text.isEmpty else { return }
        let p = NSMutableParagraphStyle()
        p.alignment = align
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: p]
        let size = measure(text, font: font, maxWidth: max(rect.width, 1))
        let r = CGRect(x: rect.minX, y: rect.midY - size.height / 2, width: rect.width, height: size.height)
        NSAttributedString(string: text, attributes: attrs)
            .draw(with: r, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    static func arrowHead(at tip: CGPoint, from: CGPoint, size: CGFloat = 9, open: Bool = false) {
        let angle = atan2(tip.y - from.y, tip.x - from.x)
        let p = NSBezierPath()
        p.move(to: tip)
        p.line(to: CGPoint(x: tip.x - size * cos(angle - 0.4), y: tip.y - size * sin(angle - 0.4)))
        if open {
            p.move(to: tip)
        } else {
            p.line(to: CGPoint(x: tip.x - size * cos(angle + 0.4), y: tip.y - size * sin(angle + 0.4)))
            p.close()
            p.fill()
            return
        }
        p.line(to: CGPoint(x: tip.x - size * cos(angle + 0.4), y: tip.y - size * sin(angle + 0.4)))
        p.stroke()
    }

    static func plate(_ text: String, at center: CGPoint, font: NSFont) {
        guard !text.isEmpty else { return }
        let size = measure(text, font: font, maxWidth: 180)
        let r = CGRect(x: center.x - size.width / 2 - 5, y: center.y - size.height / 2 - 2,
                       width: size.width + 10, height: size.height + 4)
        NSColor.textBackgroundColor.setFill()
        NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        draw(text, in: r, font: font, color: .secondaryLabelColor)
    }

    static func image(size: CGSize, draw: @escaping (CGRect) -> Void) -> NSImage {
        let image = NSImage(size: size, flipped: true) { rect in
            draw(rect)
            return true
        }
        image.cacheMode = .never
        return image
    }
}
