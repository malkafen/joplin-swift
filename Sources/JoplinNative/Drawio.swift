import AppKit
import Compression

enum Drawio {
    struct Cell {
        var id: String
        var parent: String
        var value: String
        var style: [String: String]
        var shape: String
        var isVertex: Bool
        var isEdge: Bool
        var source: String?
        var target: String?
        var rect: CGRect = .zero
        var relative = false
        var points: [CGPoint] = []
        var sourcePoint: CGPoint?
        var targetPoint: CGPoint?
    }

    struct Diagram {
        var cells: [Cell]
        var background: NSColor?
    }

    static func diagram(svg data: Data) -> Diagram? {
        guard let doc = try? XMLDocument(data: data, options: []),
              let content = doc.rootElement()?.attribute(forName: "content")?.stringValue,
              content.contains("mxfile") || content.contains("mxGraphModel") else { return nil }
        return diagram(xml: content)
    }

    static func diagram(xml: String) -> Diagram? {
        guard let doc = try? XMLDocument(xmlString: xml, options: []), let root = doc.rootElement() else { return nil }
        var model: XMLElement?
        if root.name == "mxGraphModel" {
            model = root
        } else if let page = root.elements(forName: "diagram").first {
            if let m = page.elements(forName: "mxGraphModel").first {
                model = m
            } else if let text = page.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                      let inflated = decompress(text),
                      let inner = try? XMLDocument(xmlString: inflated, options: []) {
                model = inner.rootElement()
            }
        }
        guard let model, let rootCell = model.elements(forName: "root").first else { return nil }
        var cells: [Cell] = []
        for element in rootCell.children?.compactMap({ $0 as? XMLElement }) ?? [] {
            var cellElement = element
            var label = element.attribute(forName: "value")?.stringValue ?? ""
            var id = element.attribute(forName: "id")?.stringValue ?? ""
            if element.name == "UserObject" || element.name == "object" {
                guard let inner = element.elements(forName: "mxCell").first else { continue }
                cellElement = inner
                label = element.attribute(forName: "label")?.stringValue ?? ""
                id = element.attribute(forName: "id")?.stringValue ?? id
            }
            guard cellElement.name == "mxCell" else { continue }
            let styleString = cellElement.attribute(forName: "style")?.stringValue ?? ""
            let (shape, style) = parseStyle(styleString)
            var cell = Cell(id: id, parent: cellElement.attribute(forName: "parent")?.stringValue ?? "",
                            value: plainLabel(label, html: style["html"] == "1"), style: style, shape: shape,
                            isVertex: cellElement.attribute(forName: "vertex")?.stringValue == "1",
                            isEdge: cellElement.attribute(forName: "edge")?.stringValue == "1",
                            source: cellElement.attribute(forName: "source")?.stringValue,
                            target: cellElement.attribute(forName: "target")?.stringValue)
            if let g = cellElement.elements(forName: "mxGeometry").first {
                func num(_ name: String) -> CGFloat { CGFloat(Double(g.attribute(forName: name)?.stringValue ?? "") ?? 0) }
                cell.rect = CGRect(x: num("x"), y: num("y"), width: num("width"), height: num("height"))
                cell.relative = g.attribute(forName: "relative")?.stringValue == "1"
                for child in g.children?.compactMap({ $0 as? XMLElement }) ?? [] {
                    func point(_ e: XMLElement) -> CGPoint {
                        CGPoint(x: Double(e.attribute(forName: "x")?.stringValue ?? "") ?? 0,
                                y: Double(e.attribute(forName: "y")?.stringValue ?? "") ?? 0)
                    }
                    switch (child.name, child.attribute(forName: "as")?.stringValue) {
                    case ("mxPoint", "sourcePoint"): cell.sourcePoint = point(child)
                    case ("mxPoint", "targetPoint"): cell.targetPoint = point(child)
                    case ("Array", "points"): cell.points = child.elements(forName: "mxPoint").map(point)
                    default: break
                    }
                }
            }
            cells.append(cell)
        }
        let background = model.attribute(forName: "background")?.stringValue.flatMap(color)
        return cells.contains { $0.isVertex || $0.isEdge } ? Diagram(cells: cells, background: background) : nil
    }

    static func decompress(_ text: String) -> String? {
        guard let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters), !data.isEmpty else { return nil }
        var capacity = max(data.count * 8, 4096)
        while capacity <= 64 << 20 {
            var out = [UInt8](repeating: 0, count: capacity)
            let written = data.withUnsafeBytes { src -> Int in
                compression_decode_buffer(&out, capacity, src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil,
                                          COMPRESSION_ZLIB)
            }
            if written == 0 { return nil }
            if written < capacity {
                let decoded = String(decoding: out[0..<written], as: UTF8.self)
                return decoded.removingPercentEncoding ?? decoded
            }
            capacity *= 4
        }
        return nil
    }

    static func parseStyle(_ s: String) -> (shape: String, style: [String: String]) {
        var style: [String: String] = [:]
        var shape = ""
        for part in s.split(separator: ";") {
            if let eq = part.firstIndex(of: "=") {
                style[String(part[..<eq])] = String(part[part.index(after: eq)...])
            } else if shape.isEmpty {
                shape = String(part)
            }
        }
        if let explicit = style["shape"] { shape = explicit }
        return (shape, style)
    }

    static func plainLabel(_ value: String, html: Bool) -> String {
        guard html || value.contains("<") else { return value }
        let text = value
            .replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<(div|p|li|h[1-6])(\\s[^>]*)?>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return HTMLTokens.decode(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func color(_ value: String) -> NSColor? {
        if value == "none" || value.isEmpty { return nil }
        if value == "default" { return nil }
        return Mermaid.color(value)
    }

    struct Placed {
        var cells: [String: Cell]
        var order: [String]
        var bounds: CGRect
    }

    static func place(_ d: Diagram) -> Placed {
        var byId: [String: Cell] = [:]
        for c in d.cells { byId[c.id] = c }
        func origin(_ id: String, depth: Int = 0) -> CGPoint {
            guard depth < 32, let c = byId[id], c.isVertex else { return .zero }
            let p = origin(c.parent, depth: depth + 1)
            return CGPoint(x: p.x + c.rect.minX, y: p.y + c.rect.minY)
        }
        var placed: [String: Cell] = [:]
        var bounds: CGRect?
        for var c in d.cells {
            let o = origin(c.parent)
            if c.isVertex && !c.relative {
                c.rect = c.rect.offsetBy(dx: o.x, dy: o.y)
                bounds = bounds.map { $0.union(c.rect) } ?? c.rect
            }
            if c.isEdge {
                c.points = c.points.map { CGPoint(x: $0.x + o.x, y: $0.y + o.y) }
                c.sourcePoint = c.sourcePoint.map { CGPoint(x: $0.x + o.x, y: $0.y + o.y) }
                c.targetPoint = c.targetPoint.map { CGPoint(x: $0.x + o.x, y: $0.y + o.y) }
                for p in c.points + [c.sourcePoint, c.targetPoint].compactMap({ $0 }) {
                    let r = CGRect(origin: p, size: .zero)
                    bounds = bounds.map { $0.union(r) } ?? r
                }
            }
            placed[c.id] = c
        }
        return Placed(cells: placed, order: d.cells.map(\.id), bounds: bounds ?? .zero)
    }

    static func route(_ edge: Cell, in placed: Placed) -> [CGPoint] {
        let source = edge.source.flatMap { placed.cells[$0] }.map(\.rect)
        let target = edge.target.flatMap { placed.cells[$0] }.map(\.rect)
        var middle = edge.points
        let first = middle.first ?? target.map { CGPoint(x: $0.midX, y: $0.midY) } ?? edge.targetPoint ?? .zero
        let last = middle.last ?? source.map { CGPoint(x: $0.midX, y: $0.midY) } ?? edge.sourcePoint ?? .zero
        let orthogonal = edge.style["edgeStyle"]?.lowercased().contains("orthogonal") == true
            || edge.style["edgeStyle"] == "elbowEdgeStyle"
        if orthogonal, middle.isEmpty, let s = source, let t = target {
            let dx = t.midX - s.midX, dy = t.midY - s.midY
            if abs(dx) >= abs(dy) {
                let midX = (dx > 0 ? (s.maxX + t.minX) : (s.minX + t.maxX)) / 2
                middle = [CGPoint(x: midX, y: s.midY), CGPoint(x: midX, y: t.midY)]
            } else {
                let midY = (dy > 0 ? (s.maxY + t.minY) : (s.minY + t.maxY)) / 2
                middle = [CGPoint(x: s.midX, y: midY), CGPoint(x: t.midX, y: midY)]
            }
            let start = clip(s, toward: middle[0], straight: true)
            let end = clip(t, toward: middle[1], straight: true)
            return [start] + middle + [end]
        }
        let start = source.map { clip($0, toward: first, straight: orthogonal) } ?? edge.sourcePoint ?? first
        let end = target.map { clip($0, toward: last, straight: orthogonal) } ?? edge.targetPoint ?? last
        return [start] + middle + [end]
    }

    static func clip(_ r: CGRect, toward p: CGPoint, straight: Bool = false) -> CGPoint {
        let c = CGPoint(x: r.midX, y: r.midY)
        if straight {
            if p.x >= r.minX && p.x <= r.maxX { return CGPoint(x: p.x, y: p.y < c.y ? r.minY : r.maxY) }
            if p.y >= r.minY && p.y <= r.maxY { return CGPoint(x: p.x < c.x ? r.minX : r.maxX, y: p.y) }
        }
        let dx = p.x - c.x, dy = p.y - c.y
        guard dx != 0 || dy != 0 else { return c }
        let tx = dx == 0 ? CGFloat.greatestFiniteMagnitude : (r.width / 2) / abs(dx)
        let ty = dy == 0 ? CGFloat.greatestFiniteMagnitude : (r.height / 2) / abs(dy)
        let t = min(tx, ty)
        return CGPoint(x: c.x + dx * t, y: c.y + dy * t)
    }

    static func image(_ d: Diagram) -> NSImage? {
        let placed = place(d)
        guard placed.bounds.width > 0 || placed.bounds.height > 0 else { return nil }
        let margin: CGFloat = 12
        let size = CGSize(width: ceil(placed.bounds.width + 2 * margin), height: ceil(placed.bounds.height + 2 * margin))
        let shift = CGPoint(x: margin - placed.bounds.minX, y: margin - placed.bounds.minY)
        let background = d.background ?? .white
        let image = NSImage(size: size, flipped: true) { rect in
            let card = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            background.setFill()
            card.fill()
            NSColor.separatorColor.setStroke()
            card.stroke()
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            context.translateBy(x: shift.x, y: shift.y)
            draw(placed)
            return true
        }
        return image
    }

    static func image(svg data: Data) -> NSImage? { diagram(svg: data).flatMap(image) }
    static func image(xml: String) -> NSImage? { diagram(xml: xml).flatMap(image) }

    private static func font(_ style: [String: String]) -> NSFont {
        let size = CGFloat(Double(style["fontSize"] ?? "") ?? 12)
        let flags = Int(style["fontStyle"] ?? "") ?? 0
        var f = NSFont.systemFont(ofSize: size, weight: flags & 1 != 0 ? .bold : .regular)
        if flags & 2 != 0 { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
        return f
    }

    private static func drawText(_ text: String, in r: CGRect, style: [String: String]) {
        guard !text.isEmpty else { return }
        let f = font(style)
        let p = NSMutableParagraphStyle()
        switch style["align"] {
        case "left": p.alignment = .left
        case "right": p.alignment = .right
        default: p.alignment = .center
        }
        let color = style["fontColor"].flatMap(Drawio.color) ?? .black
        var attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: color, .paragraphStyle: p]
        if (Int(style["fontStyle"] ?? "") ?? 0) & 4 != 0 { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        let string = NSAttributedString(string: text, attributes: attrs)
        let width = max(r.width - 4, 10)
        let wrap = style["whiteSpace"] == "wrap"
        let measured = string.boundingRect(with: NSSize(width: wrap ? width : 10_000, height: .greatestFiniteMagnitude),
                                           options: [.usesLineFragmentOrigin, .usesFontLeading])
        let w = wrap ? width : max(width, ceil(measured.width))
        let h = ceil(measured.height)
        let y: CGFloat
        switch style["verticalAlign"] {
        case "top": y = r.minY + 2
        case "bottom": y = r.maxY - h - 2
        default: y = r.midY - h / 2
        }
        string.draw(with: CGRect(x: r.midX - w / 2, y: y, width: w, height: h), options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    private static func path(for c: Cell) -> NSBezierPath? {
        let r = c.rect
        switch c.shape {
        case "text", "edgeLabel", "label": return nil
        case "ellipse", "doubleEllipse":
            return NSBezierPath(ovalIn: r)
        case "rhombus":
            let p = NSBezierPath()
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.line(to: CGPoint(x: r.maxX, y: r.midY))
            p.line(to: CGPoint(x: r.midX, y: r.maxY))
            p.line(to: CGPoint(x: r.minX, y: r.midY))
            p.close()
            return p
        case "triangle":
            let p = NSBezierPath()
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.line(to: CGPoint(x: r.maxX, y: r.midY))
            p.line(to: CGPoint(x: r.minX, y: r.maxY))
            p.close()
            return p
        case "hexagon":
            let i = r.width / 4
            let p = NSBezierPath()
            p.move(to: CGPoint(x: r.minX + i, y: r.minY))
            p.line(to: CGPoint(x: r.maxX - i, y: r.minY))
            p.line(to: CGPoint(x: r.maxX, y: r.midY))
            p.line(to: CGPoint(x: r.maxX - i, y: r.maxY))
            p.line(to: CGPoint(x: r.minX + i, y: r.maxY))
            p.line(to: CGPoint(x: r.minX, y: r.midY))
            p.close()
            return p
        case "parallelogram":
            let i = r.width / 5
            let p = NSBezierPath()
            p.move(to: CGPoint(x: r.minX + i, y: r.minY))
            p.line(to: CGPoint(x: r.maxX, y: r.minY))
            p.line(to: CGPoint(x: r.maxX - i, y: r.maxY))
            p.line(to: CGPoint(x: r.minX, y: r.maxY))
            p.close()
            return p
        case "cloud":
            return NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        default:
            if c.style["rounded"] == "1" {
                let radius = min(r.width, r.height) * 0.15
                return NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
            }
            return NSBezierPath(rect: r)
        }
    }

    static func draw(_ placed: Placed) {
        for id in placed.order {
            guard let c = placed.cells[id], c.isVertex, !c.relative else { continue }
            drawVertex(c)
        }
        for id in placed.order {
            guard let c = placed.cells[id], c.isEdge else { continue }
            drawEdge(c, placed: placed)
        }
        for id in placed.order {
            guard let c = placed.cells[id], c.isVertex, c.relative, let edge = placed.cells[c.parent], edge.isEdge else { continue }
            let points = route(edge, in: placed)
            let at = point(along: points, fraction: (c.rect.minX + 1) / 2)
            drawEdgeLabel(c.value, at: at, style: c.style)
        }
    }

    private static func drawVertex(_ c: Cell) {
        let s = c.style
        let fill = s["fillColor"].map(Drawio.color) ?? (c.shape == "text" ? nil : .white)
        let stroke = s["strokeColor"].map(Drawio.color) ?? (c.shape == "text" ? nil : .black)
        let opacity = CGFloat(Double(s["opacity"] ?? "") ?? 100) / 100
        let r = c.rect
        if c.shape == "swimlane" {
            let header = CGFloat(Double(s["startSize"] ?? "") ?? 23)
            let outline = NSBezierPath(rect: r)
            if let fill {
                fill.withAlphaComponent(opacity).setFill()
                NSBezierPath(rect: CGRect(x: r.minX, y: r.minY, width: r.width, height: header)).fill()
            }
            if let swimFill = s["swimlaneFillColor"].flatMap(Drawio.color) {
                swimFill.setFill()
                NSBezierPath(rect: CGRect(x: r.minX, y: r.minY + header, width: r.width, height: r.height - header)).fill()
            }
            (stroke ?? .black).setStroke()
            outline.lineWidth = CGFloat(Double(s["strokeWidth"] ?? "") ?? 1)
            outline.stroke()
            let line = NSBezierPath()
            line.move(to: CGPoint(x: r.minX, y: r.minY + header))
            line.line(to: CGPoint(x: r.maxX, y: r.minY + header))
            line.stroke()
            var titleStyle = s
            titleStyle["fontStyle"] = titleStyle["fontStyle"] ?? "1"
            drawText(c.value, in: CGRect(x: r.minX, y: r.minY, width: r.width, height: header), style: titleStyle)
            return
        }
        if c.shape.contains("cylinder") {
            let cap = min(15, r.height / 4)
            let bottom = NSBezierPath(ovalIn: CGRect(x: r.minX, y: r.maxY - cap, width: r.width, height: cap))
            let top = NSBezierPath(ovalIn: CGRect(x: r.minX, y: r.minY, width: r.width, height: cap))
            let side = NSBezierPath(rect: CGRect(x: r.minX, y: r.minY + cap / 2, width: r.width, height: r.height - cap))
            if let fill {
                fill.withAlphaComponent(opacity).setFill()
                bottom.fill()
                side.fill()
                top.fill()
            }
            if let stroke {
                stroke.setStroke()
                bottom.stroke()
                top.stroke()
                let edges = NSBezierPath()
                edges.move(to: CGPoint(x: r.minX, y: r.minY + cap / 2))
                edges.line(to: CGPoint(x: r.minX, y: r.maxY - cap / 2))
                edges.move(to: CGPoint(x: r.maxX, y: r.minY + cap / 2))
                edges.line(to: CGPoint(x: r.maxX, y: r.maxY - cap / 2))
                edges.stroke()
            }
            drawText(c.value, in: r.insetBy(dx: 4, dy: 0).offsetBy(dx: 0, dy: cap / 2), style: s)
            return
        }
        if let p = path(for: c) {
            if let fill {
                fill.withAlphaComponent(opacity).setFill()
                p.fill()
            }
            if let stroke {
                stroke.withAlphaComponent(opacity).setStroke()
                p.lineWidth = CGFloat(Double(s["strokeWidth"] ?? "") ?? 1)
                if s["dashed"] == "1" { p.setLineDash([6, 4], count: 2, phase: 0) }
                p.stroke()
            }
            if c.shape == "doubleEllipse" { NSBezierPath(ovalIn: r.insetBy(dx: 4, dy: 4)).stroke() }
        }
        let spacing = CGFloat(Double(s["spacing"] ?? "") ?? 2)
        drawText(c.value, in: r.insetBy(dx: spacing + 2, dy: spacing), style: s)
    }

    private static func point(along points: [CGPoint], fraction: CGFloat) -> CGPoint {
        guard points.count > 1 else { return points.first ?? .zero }
        var lengths: [CGFloat] = []
        for (a, b) in zip(points, points.dropFirst()) { lengths.append(hypot(b.x - a.x, b.y - a.y)) }
        var remaining = lengths.reduce(0, +) * min(max(fraction, 0), 1)
        for (i, l) in lengths.enumerated() {
            if remaining <= l || i == lengths.count - 1 {
                let t = l == 0 ? 0 : remaining / l
                let a = points[i], b = points[i + 1]
                return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
            remaining -= l
        }
        return points.last!
    }

    private static func drawEdgeLabel(_ text: String, at p: CGPoint, style: [String: String]) {
        guard !text.isEmpty else { return }
        let f = font(style)
        let size = DiagramStyle.measure(text, font: f, maxWidth: 200)
        let r = CGRect(x: p.x - size.width / 2 - 3, y: p.y - size.height / 2 - 1, width: size.width + 6, height: size.height + 2)
        (style["labelBackgroundColor"].flatMap(Drawio.color) ?? .white).setFill()
        NSBezierPath(rect: r).fill()
        var s = style
        s["whiteSpace"] = "wrap"
        drawText(text, in: r, style: s)
    }

    private static func drawEdge(_ e: Cell, placed: Placed) {
        let s = e.style
        let points = route(e, in: placed)
        guard points.count > 1 else { return }
        let stroke = s["strokeColor"].map(Drawio.color) ?? .black
        guard let stroke else { return }
        let p = NSBezierPath()
        p.move(to: points[0])
        for q in points.dropFirst() { p.line(to: q) }
        p.lineWidth = CGFloat(Double(s["strokeWidth"] ?? "") ?? 1)
        if s["dashed"] == "1" { p.setLineDash([6, 4], count: 2, phase: 0) }
        if s["rounded"] == "1" { p.lineJoinStyle = .round }
        stroke.setStroke()
        stroke.setFill()
        p.stroke()
        let end = s["endArrow"] ?? "classic"
        if end != "none", end != "" {
            DiagramStyle.arrowHead(at: points[points.count - 1], from: points[points.count - 2], size: 8,
                                   open: end == "open" || s["endFill"] == "0")
        }
        if let start = s["startArrow"], start != "none", start != "" {
            DiagramStyle.arrowHead(at: points[0], from: points[1], size: 8, open: start == "open" || s["startFill"] == "0")
        }
        drawEdgeLabel(e.value, at: point(along: points, fraction: 0.5), style: s)
    }
}
