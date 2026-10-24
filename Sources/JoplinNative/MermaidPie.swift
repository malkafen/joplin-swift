import AppKit

struct Pie {
    var title = ""
    var showData = false
    var slices: [(label: String, value: Double)] = []

    private static let slice = try! NSRegularExpression(pattern: #"^"([^"]*)"\s*:\s*([0-9.]+)\s*$"#)

    static func parse(header: String, lines: [String]) -> Pie {
        var pie = Pie()
        pie.showData = header.lowercased().contains("showdata")
        if let r = header.range(of: "title ", options: .caseInsensitive) {
            pie.title = String(header[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        for line in lines {
            if line.lowercased().hasPrefix("title ") {
                pie.title = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                continue
            }
            let ns = line as NSString
            if let m = slice.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
               let value = Double(ns.substring(with: m.range(at: 2))), value > 0 {
                pie.slices.append((ns.substring(with: m.range(at: 1)), value))
            }
        }
        return pie
    }

    func image(font: NSFont) -> NSImage {
        let radius: CGFloat = 90
        let titleHeight: CGFloat = title.isEmpty ? 0 : DiagramStyle.measure(title, font: font).height + 12
        let total = slices.map(\.value).reduce(0, +)
        let legend = slices.map { s -> String in
            let pct = String(format: "%.1f%%", s.value / total * 100)
            return showData ? "\(s.label) — \(s.value.formatted()) (\(pct))" : "\(s.label) — \(pct)"
        }
        let legendWidth = (legend.map { DiagramStyle.measure($0, font: font, maxWidth: 260).width }.max() ?? 0) + 24
        let rowHeight = DiagramStyle.measure("Xy", font: font).height + 6
        let height = max(radius * 2, CGFloat(slices.count) * rowHeight) + titleHeight + 32
        let size = CGSize(width: radius * 2 + legendWidth + 56, height: height)
        let slices = self.slices, title = self.title
        return DiagramStyle.image(size: size) { _ in
            DiagramStyle.draw(title, in: CGRect(x: 16, y: 12, width: size.width - 32, height: titleHeight - 8),
                              font: NSFont.systemFont(ofSize: font.pointSize * 1.1, weight: .semibold))
            let center = CGPoint(x: 16 + radius, y: titleHeight + 16 + radius)
            var angle: CGFloat = -90
            for (i, s) in slices.enumerated() {
                let sweep = CGFloat(s.value / total) * 360
                let p = NSBezierPath()
                p.move(to: center)
                p.appendArc(withCenter: center, radius: radius, startAngle: angle, endAngle: angle + sweep)
                p.close()
                DiagramStyle.palette[i % DiagramStyle.palette.count].withAlphaComponent(0.85).setFill()
                p.fill()
                NSColor.textBackgroundColor.setStroke()
                p.lineWidth = 1.5
                p.stroke()
                angle += sweep
            }
            for (i, text) in legend.enumerated() {
                let y = titleHeight + 16 + CGFloat(i) * rowHeight
                let x = 16 + radius * 2 + 28
                DiagramStyle.palette[i % DiagramStyle.palette.count].withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: CGRect(x: x, y: y + rowHeight / 2 - 6, width: 12, height: 12), xRadius: 3, yRadius: 3).fill()
                DiagramStyle.draw(text, in: CGRect(x: x + 20, y: y, width: legendWidth, height: rowHeight), font: font,
                                  align: .left)
            }
        }
    }
}
