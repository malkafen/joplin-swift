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
}
