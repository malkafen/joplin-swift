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

struct Flowchart {
    enum Direction: String { case TB, BT, LR, RL }

    enum Shape: Equatable {
        case rect, round, stadium, circle, diamond, hexagon, cylinder, subroutine, asymmetric, parallelogram
        case start, end, bar
    }

    struct Node {
        var id: String
        var label: String
        var shape: Shape = .rect
        var fill: NSColor?
        var stroke: NSColor?
    }

    struct Edge {
        enum Line { case solid, dotted, thick, invisible }
        var from: String
        var to: String
        var label = ""
        var line: Line = .solid
        var arrowStart = false
        var arrowEnd = true
    }

    struct Group {
        var title: String
        var members: [String]
    }

    var direction: Direction = .TB
    var nodes: [Node] = []
    var edges: [Edge] = []
    var groups: [Group] = []
    private var index: [String: Int] = [:]

    mutating func node(_ id: String, label: String? = nil, shape: Shape? = nil) {
        if let i = index[id] {
            if let label { nodes[i].label = label }
            if let shape { nodes[i].shape = shape }
        } else {
            index[id] = nodes.count
            nodes.append(Node(id: id, label: label ?? id, shape: shape ?? .rect))
        }
    }

    func node(id: String) -> Node? { index[id].map { nodes[$0] } }

    mutating func style(_ id: String, fill: NSColor?, stroke: NSColor?) {
        guard let i = index[id] else { return }
        if let fill { nodes[i].fill = fill }
        if let stroke { nodes[i].stroke = stroke }
    }

    static func parse(header: String, lines: [String]) -> Flowchart {
        var chart = Flowchart()
        let parts = header.split(separator: " ")
        if parts.count > 1, let d = Direction(rawValue: parts[1].uppercased().replacingOccurrences(of: "TD", with: "TB")) {
            chart.direction = d
        }
        var classes: [String: (NSColor?, NSColor?)] = [:]
        var groupStack: [Group] = []
        let statements = lines.flatMap { $0.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) } }
        for line in statements where !line.isEmpty {
            let lower = line.lowercased()
            if lower.hasPrefix("subgraph") {
                var title = String(line.dropFirst("subgraph".count)).trimmingCharacters(in: .whitespaces)
                if let open = title.firstIndex(of: "["), title.hasSuffix("]") {
                    title = String(title[title.index(after: open)..<title.index(before: title.endIndex)])
                }
                groupStack.append(Group(title: Mermaid.cleanLabel(title), members: []))
                continue
            }
            if lower == "end" {
                if let g = groupStack.popLast() {
                    chart.groups.append(g)
                    if !groupStack.isEmpty { groupStack[groupStack.count - 1].members += g.members }
                }
                continue
            }
            if lower.hasPrefix("direction ") || lower.hasPrefix("click ") || lower.hasPrefix("linkstyle ") { continue }
            if lower.hasPrefix("classdef ") {
                let p = line.split(separator: " ", maxSplits: 2)
                if p.count == 3 {
                    let (fill, stroke) = styleColors(String(p[2]))
                    for name in p[1].split(separator: ",") { classes[String(name)] = (fill, stroke) }
                }
                continue
            }
            if lower.hasPrefix("class ") {
                let p = line.split(separator: " ")
                if p.count >= 3, let c = classes[String(p[2])] {
                    for id in p[1].split(separator: ",") { chart.style(String(id), fill: c.0, stroke: c.1) }
                }
                continue
            }
            if lower.hasPrefix("style ") {
                let p = line.split(separator: " ", maxSplits: 2)
                if p.count == 3 {
                    let (fill, stroke) = styleColors(String(p[2]))
                    chart.style(String(p[1]), fill: fill, stroke: stroke)
                }
                continue
            }
            let ids = chart.parseStatement(line)
            if !groupStack.isEmpty {
                for id in ids where !groupStack[groupStack.count - 1].members.contains(id) {
                    groupStack[groupStack.count - 1].members.append(id)
                }
            }
        }
        while let g = groupStack.popLast() { chart.groups.append(g) }
        return chart
    }

    private static func styleColors(_ css: String) -> (NSColor?, NSColor?) {
        var fill: NSColor?
        var stroke: NSColor?
        for part in css.split(separator: ",") {
            let kv = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            if kv[0] == "fill" { fill = Mermaid.color(kv[1]) }
            if kv[0] == "stroke" { stroke = Mermaid.color(kv[1]) }
        }
        return (fill, stroke)
    }

    private static let shapes: [(open: String, close: String, shape: Shape)] = [
        ("(((", ")))", .circle), ("([", "])", .stadium), ("((", "))", .circle), ("[[", "]]", .subroutine),
        ("[(", ")]", .cylinder), ("[/", "/]", .parallelogram), ("[\\", "\\]", .parallelogram), ("[/", "\\]", .parallelogram),
        ("{{", "}}", .hexagon), ("(", ")", .round), ("[", "]", .rect), ("{", "}", .diamond), (">", "]", .asymmetric),
    ]

    private static let edgeWithText = try! NSRegularExpression(
        pattern: #"^\s*([<xo]?)(--|==|-\.)(?![->.=])\s*(.+?)\s*(-{2,}|={2,}|\.+-)([>xo]?)(?=[\s\w"(\[{]|$)"#)
    private static let edgePlain = try! NSRegularExpression(pattern: #"^\s*([<xo]?)(-{2,}|={2,}|-\.+-|~{3,})([>xo]?)"#)
    private static let pipeText = try! NSRegularExpression(pattern: #"^\s*\|([^|]*)\|"#)

    mutating func parseStatement(_ line: String) -> [String] {
        let chars = Array(line)
        var i = 0
        var mentioned: [String] = []

        func skipSpaces() { while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 } }

        func parseNode() -> String? {
            skipSpaces()
            var id = ""
            while i < chars.count, chars[i].isLetter || chars[i].isNumber || "_-.$".contains(chars[i]) {
                if chars[i] == "-" || chars[i] == "." || chars[i] == "=" {
                    let rest = String(chars[i...])
                    if rest.hasPrefix("--") || rest.hasPrefix("-.") || rest.hasPrefix("==") || rest.hasPrefix(".-") { break }
                }
                id.append(chars[i])
                i += 1
            }
            guard !id.isEmpty else { return nil }
            let rest = String(chars[i...])
            for s in Self.shapes where rest.hasPrefix(s.open) {
                let after = rest.dropFirst(s.open.count)
                if let close = after.range(of: s.close) {
                    let text = String(after[..<close.lowerBound])
                    node(id, label: Mermaid.cleanLabel(text), shape: s.shape)
                    i += s.open.count + after.distance(from: after.startIndex, to: close.upperBound)
                    break
                }
            }
            if !nodes.contains(where: { $0.id == id }) { node(id) }
            if String(chars[i...]).hasPrefix(":::") {
                i += 3
                while i < chars.count, chars[i] != " " { i += 1 }
            }
            mentioned.append(id)
            return id
        }

        func parseGroup() -> [String] {
            var ids: [String] = []
            while let id = parseNode() {
                ids.append(id)
                skipSpaces()
                if i < chars.count, chars[i] == "&" { i += 1 } else { break }
            }
            return ids
        }

        var left = parseGroup()
        while i < chars.count {
            let rest = String(chars[i...])
            let ns = rest as NSString
            var edge = Edge(from: "", to: "")
            var consumed = 0
            if let m = Self.edgeWithText.firstMatch(in: rest, range: NSRange(location: 0, length: ns.length)) {
                edge.label = Mermaid.cleanLabel(ns.substring(with: m.range(at: 3)))
                edge.arrowStart = m.range(at: 1).length > 0
                edge.arrowEnd = m.range(at: 5).length > 0
                let op = ns.substring(with: m.range(at: 2)) + ns.substring(with: m.range(at: 4))
                edge.line = op.contains("=") ? .thick : op.contains(".") ? .dotted : .solid
                consumed = m.range.length
            } else if let m = Self.edgePlain.firstMatch(in: rest, range: NSRange(location: 0, length: ns.length)) {
                let op = ns.substring(with: m.range(at: 2))
                edge.arrowStart = m.range(at: 1).length > 0
                edge.arrowEnd = m.range(at: 3).length > 0
                edge.line = op.hasPrefix("~") ? .invisible : op.contains("=") ? .thick : op.contains(".") ? .dotted : .solid
                consumed = m.range.length
                let after = ns.substring(from: consumed) as NSString
                if let p = Self.pipeText.firstMatch(in: after as String, range: NSRange(location: 0, length: after.length)) {
                    edge.label = Mermaid.cleanLabel(after.substring(with: p.range(at: 1)))
                    consumed += p.range.length
                }
            } else {
                break
            }
            i += (String(rest.utf16.prefix(consumed)) ?? "").count
            let right = parseGroup()
            guard !right.isEmpty else { break }
            for a in left {
                for b in right {
                    var e = edge
                    e.from = a
                    e.to = b
                    edges.append(e)
                }
            }
            left = right
        }
        return mentioned
    }

    static func parseState(lines: [String]) -> Flowchart {
        var chart = Flowchart()
        var groupStack: [Group] = []
        let transition = try! NSRegularExpression(pattern: #"^(\[\*\]|[\w.-]+)\s*-->\s*(\[\*\]|[\w.-]+)\s*(?::\s*(.*))?$"#)
        func id(_ raw: String, start: Bool) -> String {
            guard raw == "[*]" else {
                chart.node(raw)
                return raw
            }
            let scope = groupStack.count
            let key = start ? "__start\(scope)" : "__end\(scope)"
            chart.node(key, label: "", shape: start ? .start : .end)
            return key
        }
        func member(_ ids: [String]) {
            guard !groupStack.isEmpty else { return }
            for i in ids where !groupStack[groupStack.count - 1].members.contains(i) {
                groupStack[groupStack.count - 1].members.append(i)
            }
        }
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            if lower.hasPrefix("direction ") {
                if let d = Direction(rawValue: String(line.dropFirst(10)).uppercased()) { chart.direction = d }
                continue
            }
            if lower.hasPrefix("note ") || lower == "end note" || lower.hasPrefix("classdef") || lower.hasPrefix("class ") {
                continue
            }
            if line == "}" {
                if let g = groupStack.popLast() {
                    chart.groups.append(g)
                    member(g.members)
                }
                continue
            }
            if lower.hasPrefix("state ") {
                var rest = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                let opens = rest.hasSuffix("{")
                if opens { rest = String(rest.dropLast()).trimmingCharacters(in: .whitespaces) }
                var name = rest
                var label: String?
                if rest.hasPrefix("\""), let asRange = rest.range(of: " as ") {
                    label = Mermaid.cleanLabel(String(rest[..<asRange.lowerBound]))
                    name = String(rest[asRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                }
                var shape: Shape?
                if name.hasSuffix("<<choice>>") { shape = .diamond }
                if name.hasSuffix("<<fork>>") || name.hasSuffix("<<join>>") { shape = .bar }
                name = name.replacingOccurrences(of: "<<[a-z]+>>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                if opens {
                    groupStack.append(Group(title: label ?? name, members: []))
                } else {
                    chart.node(name, label: shape == nil ? label : "", shape: shape ?? .round)
                    member([name])
                }
                continue
            }
            let ns = line as NSString
            if let m = transition.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let a = id(ns.substring(with: m.range(at: 1)), start: true)
                let b = id(ns.substring(with: m.range(at: 2)), start: false)
                var e = Edge(from: a, to: b)
                if m.range(at: 3).location != NSNotFound { e.label = Mermaid.cleanLabel(ns.substring(with: m.range(at: 3))) }
                chart.edges.append(e)
                member([a, b])
                continue
            }
            if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].trimmingCharacters(in: .whitespaces)
                let text = Mermaid.cleanLabel(String(line[line.index(after: colon)...]))
                chart.node(name, label: text)
                member([name])
            }
        }
        for i in chart.nodes.indices where chart.nodes[i].shape == .rect { chart.nodes[i].shape = .round }
        return chart
    }
}

struct FlowLayout {
    let chart: Flowchart
    let font: NSFont
    var frames: [String: CGRect] = [:]
    var size: CGSize = .zero
    var backEdges: Set<Int> = []

    private var horizontal: Bool { chart.direction == .LR || chart.direction == .RL }

    init(_ chart: Flowchart, font: NSFont) {
        self.chart = chart
        self.font = font
        layout()
    }

    func nodeSize(_ n: Flowchart.Node) -> CGSize {
        let text = DiagramStyle.measure(n.label, font: font, maxWidth: 180)
        switch n.shape {
        case .start: return CGSize(width: 18, height: 18)
        case .end: return CGSize(width: 22, height: 22)
        case .bar: return horizontal ? CGSize(width: 8, height: 60) : CGSize(width: 60, height: 8)
        case .circle:
            let d = max(text.width, text.height) + 24
            return CGSize(width: d, height: d)
        case .diamond:
            if n.label.isEmpty { return CGSize(width: 26, height: 26) }
            return CGSize(width: text.width * 1.5 + 28, height: text.height * 1.6 + 22)
        case .hexagon: return CGSize(width: text.width + 44, height: text.height + 20)
        case .cylinder: return CGSize(width: text.width + 28, height: text.height + 30)
        default: return CGSize(width: max(text.width + 28, 50), height: text.height + 20)
        }
    }

    private mutating func layout() {
        let ids = chart.nodes.map(\.id)
        let pos = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        let edges = chart.edges.filter { pos[$0.from] != nil && pos[$0.to] != nil }

        var state = [Int](repeating: 0, count: ids.count)
        var outgoing = [[Int]](repeating: [], count: ids.count)
        for (k, e) in edges.enumerated() { outgoing[pos[e.from]!].append(k) }
        var back: Set<Int> = []
        func dfs(_ v: Int) {
            state[v] = 1
            for k in outgoing[v] {
                let w = pos[edges[k].to]!
                if w == v || state[w] == 1 { back.insert(k) } else if state[w] == 0 { dfs(w) }
            }
            state[v] = 2
        }
        for v in ids.indices where state[v] == 0 { dfs(v) }
        backEdges = back

        var rank = [Int](repeating: 0, count: ids.count)
        var changed = true
        var guardCount = 0
        while changed && guardCount < ids.count + 2 {
            changed = false
            guardCount += 1
            for (k, e) in edges.enumerated() where !back.contains(k) {
                let a = pos[e.from]!, b = pos[e.to]!
                if rank[b] < rank[a] + 1 {
                    rank[b] = rank[a] + 1
                    changed = true
                }
            }
        }
        let maxRank = rank.max() ?? 0
        var layers = [[Int]](repeating: [], count: maxRank + 1)
        for v in ids.indices { layers[rank[v]].append(v) }

        var preds = [[Int]](repeating: [], count: ids.count)
        var succs = [[Int]](repeating: [], count: ids.count)
        for (k, e) in edges.enumerated() {
            var a = pos[e.from]!, b = pos[e.to]!
            if back.contains(k) { swap(&a, &b) }
            preds[b].append(a)
            succs[a].append(b)
        }
        var order = [Int](repeating: 0, count: ids.count)
        func renumber() { for layer in layers { for (i, v) in layer.enumerated() { order[v] = i } } }
        renumber()
        for sweep in 0..<6 {
            let down = sweep % 2 == 0
            let range = down ? Array(layers.indices.dropFirst()) : Array(layers.indices.dropLast().reversed())
            for r in range {
                let neighbours = down ? preds : succs
                layers[r].sort { a, b in
                    func bary(_ v: Int) -> Double {
                        let n = neighbours[v]
                        return n.isEmpty ? Double(order[v]) : Double(n.map { order[$0] }.reduce(0, +)) / Double(n.count)
                    }
                    return bary(a) < bary(b)
                }
                renumber()
            }
        }

        let sizes = chart.nodes.map { n -> CGSize in
            let s = nodeSize(n)
            return horizontal ? CGSize(width: s.height, height: s.width) : s
        }
        let gapX: CGFloat = 28, gapY: CGFloat = 46
        var x = [CGFloat](repeating: 0, count: ids.count)
        var y = [CGFloat](repeating: 0, count: ids.count)
        var top: CGFloat = 0
        for layer in layers {
            let height = layer.map { sizes[$0].height }.max() ?? 0
            for v in layer { y[v] = top + height / 2 }
            top += height + gapY
        }
        for (r, layer) in layers.enumerated() {
            var desired: [(Int, CGFloat)] = []
            var cursor: CGFloat = 0
            for v in layer {
                let p = preds[v].filter { rank[$0] < r }
                let want = p.isEmpty ? cursor + sizes[v].width / 2 : p.map { x[$0] }.reduce(0, +) / CGFloat(p.count)
                desired.append((v, want))
                cursor = want + sizes[v].width / 2 + gapX
            }
            var right = -CGFloat.greatestFiniteMagnitude
            for (v, want) in desired {
                let left = max(want - sizes[v].width / 2, right)
                x[v] = left + sizes[v].width / 2
                right = left + sizes[v].width + gapX
            }
            if let first = desired.first, let last = desired.last {
                let wantCenter = (first.1 + last.1) / 2
                let haveCenter = (x[first.0] + x[last.0]) / 2
                let shift = (haveCenter - wantCenter) / 2
                for v in layer { x[v] -= shift }
            }
        }
        let minX = ids.indices.map { x[$0] - sizes[$0].width / 2 }.min() ?? 0
        let margin: CGFloat = 16
        var maxX: CGFloat = 0, maxY: CGFloat = 0
        for v in ids.indices {
            var rect = CGRect(x: x[v] - sizes[v].width / 2 - minX + margin, y: y[v] - sizes[v].height / 2 + margin,
                              width: sizes[v].width, height: sizes[v].height)
            if horizontal { rect = CGRect(x: rect.minY, y: rect.minX, width: rect.height, height: rect.width) }
            frames[ids[v]] = rect
            maxX = max(maxX, rect.maxX)
            maxY = max(maxY, rect.maxY)
        }
        if chart.direction == .BT || chart.direction == .RL {
            for (id, r) in frames {
                frames[id] = chart.direction == .BT
                    ? CGRect(x: r.minX, y: maxY + margin - r.maxY, width: r.width, height: r.height)
                    : CGRect(x: maxX + margin - r.maxX, y: r.minY, width: r.width, height: r.height)
            }
        }
        size = CGSize(width: maxX + margin, height: maxY + margin)
        for (k, e) in edges.enumerated() where back.contains(k) || e.from == e.to {
            guard let a = frames[e.from], let b = frames[e.to] else { continue }
            let c = curve(e, from: a, to: b, back: true)
            let far = [c.control1, c.control2].map { p -> CGPoint in
                CGPoint(x: c.start.x + (p.x - c.start.x) * 0.75, y: c.start.y + (p.y - c.start.y) * 0.75)
            }
            for p in far {
                size.width = max(size.width, p.x + margin)
                size.height = max(size.height, p.y + margin)
            }
        }
        if !chart.groups.isEmpty {
            let shifted = frames.mapValues { $0.offsetBy(dx: 12, dy: 26) }
            frames = shifted
            size.width += 24
            size.height += 34
        }
    }

    func groupFrame(_ g: Flowchart.Group) -> CGRect? {
        let rects = g.members.compactMap { frames[$0] }
        guard var r = rects.first else { return nil }
        for x in rects.dropFirst() { r = r.union(x) }
        return r.insetBy(dx: -12, dy: -12).offsetBy(dx: 0, dy: -8).insetBy(dx: 0, dy: -4)
    }

    func boundaryPoint(_ id: String, toward p: CGPoint) -> CGPoint {
        guard let r = frames[id], let n = chart.node(id: id) else { return p }
        let c = CGPoint(x: r.midX, y: r.midY)
        let dx = p.x - c.x, dy = p.y - c.y
        guard dx != 0 || dy != 0 else { return c }
        switch n.shape {
        case .circle, .start, .end:
            let radius = min(r.width, r.height) / 2
            let len = (dx * dx + dy * dy).squareRoot()
            return CGPoint(x: c.x + dx / len * radius, y: c.y + dy / len * radius)
        case .diamond:
            let t = 1 / (abs(dx) / (r.width / 2) + abs(dy) / (r.height / 2))
            return CGPoint(x: c.x + dx * t, y: c.y + dy * t)
        default:
            let tx = dx == 0 ? CGFloat.greatestFiniteMagnitude : (r.width / 2) / abs(dx)
            let ty = dy == 0 ? CGFloat.greatestFiniteMagnitude : (r.height / 2) / abs(dy)
            let t = min(tx, ty)
            return CGPoint(x: c.x + dx * t, y: c.y + dy * t)
        }
    }

    func image() -> NSImage {
        let layout = self
        return DiagramStyle.image(size: size) { _ in layout.draw() }
    }

    func draw() {
        let small = NSFont.systemFont(ofSize: font.pointSize * 0.9)
        for g in chart.groups {
            guard let r = groupFrame(g) else { continue }
            DiagramStyle.groupFill.setFill()
            NSColor.separatorColor.setStroke()
            let path = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
            path.fill()
            path.lineWidth = 1
            path.stroke()
            DiagramStyle.draw(g.title, in: CGRect(x: r.minX + 8, y: r.minY + 4, width: r.width - 16, height: 16),
                              font: NSFont.systemFont(ofSize: small.pointSize, weight: .semibold),
                              color: .secondaryLabelColor, align: .left)
        }
        for (k, e) in chart.edges.enumerated() {
            guard e.line != .invisible, let a = frames[e.from], let b = frames[e.to] else { continue }
            drawEdge(e, from: a, to: b, back: backEdges.contains(k), font: small)
        }
        for n in chart.nodes {
            guard let r = frames[n.id] else { continue }
            drawNode(n, in: r)
        }
    }

    func curve(_ e: Flowchart.Edge, from a: CGRect, to b: CGRect, back: Bool)
        -> (start: CGPoint, control1: CGPoint, control2: CGPoint, end: CGPoint) {
        let ca = CGPoint(x: a.midX, y: a.midY), cb = CGPoint(x: b.midX, y: b.midY)
        if e.from == e.to {
            return (CGPoint(x: a.maxX, y: a.midY - 6), CGPoint(x: a.maxX + 34, y: a.midY - 26),
                    CGPoint(x: a.maxX + 34, y: a.midY + 26), CGPoint(x: a.maxX, y: a.midY + 6))
        }
        if back {
            let side: CGFloat = horizontal ? 0 : max(a.width, b.width) / 2 + 30
            let lift: CGFloat = horizontal ? max(a.height, b.height) / 2 + 30 : 0
            let start = boundaryPoint(e.from, toward: CGPoint(x: ca.x + side, y: ca.y + lift))
            let end = boundaryPoint(e.to, toward: CGPoint(x: cb.x + side, y: cb.y + lift))
            return (start, CGPoint(x: start.x + side, y: start.y + lift), CGPoint(x: end.x + side, y: end.y + lift), end)
        }
        let start = boundaryPoint(e.from, toward: cb)
        let end = boundaryPoint(e.to, toward: ca)
        if horizontal {
            let mid = (start.x + end.x) / 2
            return (start, CGPoint(x: mid, y: start.y), CGPoint(x: mid, y: end.y), end)
        }
        let mid = (start.y + end.y) / 2
        return (start, CGPoint(x: start.x, y: mid), CGPoint(x: end.x, y: mid), end)
    }

    private func drawEdge(_ e: Flowchart.Edge, from a: CGRect, to b: CGRect, back: Bool, font: NSFont) {
        let path = NSBezierPath()
        let (start, control1, control2, end) = curve(e, from: a, to: b, back: back)
        path.move(to: start)
        path.curve(to: end, controlPoint1: control1, controlPoint2: control2)
        path.lineWidth = e.line == .thick ? 2.5 : 1.3
        if e.line == .dotted { path.setLineDash([4, 3], count: 2, phase: 0) }
        DiagramStyle.line.setStroke()
        DiagramStyle.line.setFill()
        path.stroke()
        if e.arrowEnd { DiagramStyle.arrowHead(at: end, from: control2) }
        if e.arrowStart { DiagramStyle.arrowHead(at: start, from: control1) }
        if !e.label.isEmpty {
            let m = CGPoint(x: (start.x + 3 * control1.x + 3 * control2.x + end.x) / 8,
                            y: (start.y + 3 * control1.y + 3 * control2.y + end.y) / 8)
            DiagramStyle.plate(e.label, at: m, font: font)
        }
    }

    private func drawNode(_ n: Flowchart.Node, in r: CGRect) {
        let fill = n.fill ?? DiagramStyle.nodeFill
        let stroke = n.stroke ?? DiagramStyle.nodeStroke
        let path: NSBezierPath
        switch n.shape {
        case .start:
            NSColor.labelColor.setFill()
            NSBezierPath(ovalIn: r).fill()
            return
        case .end:
            NSColor.labelColor.setStroke()
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 1.5
            ring.stroke()
            NSColor.labelColor.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 5, dy: 5)).fill()
            return
        case .bar:
            NSColor.labelColor.setFill()
            NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
            return
        case .round: path = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        case .stadium: path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        case .circle: path = NSBezierPath(ovalIn: r)
        case .diamond:
            path = NSBezierPath()
            path.move(to: CGPoint(x: r.midX, y: r.minY))
            path.line(to: CGPoint(x: r.maxX, y: r.midY))
            path.line(to: CGPoint(x: r.midX, y: r.maxY))
            path.line(to: CGPoint(x: r.minX, y: r.midY))
            path.close()
        case .hexagon:
            let inset = min(16, r.width / 4)
            path = NSBezierPath()
            path.move(to: CGPoint(x: r.minX + inset, y: r.minY))
            path.line(to: CGPoint(x: r.maxX - inset, y: r.minY))
            path.line(to: CGPoint(x: r.maxX, y: r.midY))
            path.line(to: CGPoint(x: r.maxX - inset, y: r.maxY))
            path.line(to: CGPoint(x: r.minX + inset, y: r.maxY))
            path.line(to: CGPoint(x: r.minX, y: r.midY))
            path.close()
        case .parallelogram:
            let inset = min(14, r.width / 5)
            path = NSBezierPath()
            path.move(to: CGPoint(x: r.minX + inset, y: r.minY))
            path.line(to: CGPoint(x: r.maxX, y: r.minY))
            path.line(to: CGPoint(x: r.maxX - inset, y: r.maxY))
            path.line(to: CGPoint(x: r.minX, y: r.maxY))
            path.close()
        case .asymmetric:
            path = NSBezierPath()
            path.move(to: CGPoint(x: r.minX, y: r.minY))
            path.line(to: CGPoint(x: r.maxX, y: r.minY))
            path.line(to: CGPoint(x: r.maxX, y: r.maxY))
            path.line(to: CGPoint(x: r.minX, y: r.maxY))
            path.line(to: CGPoint(x: r.minX + 12, y: r.midY))
            path.close()
        case .cylinder:
            let cap: CGFloat = 8
            let body = NSBezierPath(rect: CGRect(x: r.minX, y: r.minY + cap, width: r.width, height: r.height - 2 * cap))
            let bottom = NSBezierPath(ovalIn: CGRect(x: r.minX, y: r.maxY - 2 * cap, width: r.width, height: 2 * cap))
            let topOval = NSBezierPath(ovalIn: CGRect(x: r.minX, y: r.minY, width: r.width, height: 2 * cap))
            fill.setFill()
            stroke.setStroke()
            bottom.fill()
            bottom.stroke()
            body.fill()
            let sides = NSBezierPath()
            sides.move(to: CGPoint(x: r.minX, y: r.minY + cap))
            sides.line(to: CGPoint(x: r.minX, y: r.maxY - cap))
            sides.move(to: CGPoint(x: r.maxX, y: r.minY + cap))
            sides.line(to: CGPoint(x: r.maxX, y: r.maxY - cap))
            sides.stroke()
            NSColor.textBackgroundColor.setFill()
            topOval.fill()
            fill.setFill()
            topOval.fill()
            topOval.stroke()
            DiagramStyle.draw(n.label, in: r.offsetBy(dx: 0, dy: cap / 2).insetBy(dx: 8, dy: 0), font: font)
            return
        default: path = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
        }
        NSColor.textBackgroundColor.setFill()
        path.fill()
        fill.setFill()
        path.fill()
        stroke.setStroke()
        path.lineWidth = 1.2
        path.stroke()
        if n.shape == .subroutine {
            let s = NSBezierPath()
            s.move(to: CGPoint(x: r.minX + 7, y: r.minY))
            s.line(to: CGPoint(x: r.minX + 7, y: r.maxY))
            s.move(to: CGPoint(x: r.maxX - 7, y: r.minY))
            s.line(to: CGPoint(x: r.maxX - 7, y: r.maxY))
            s.stroke()
        }
        DiagramStyle.draw(n.label, in: r.insetBy(dx: 10, dy: 0), font: font)
    }
}

struct SequenceDiagram {
    struct Participant {
        var id: String
        var label: String
        var actor = false
    }

    enum Item {
        case message(from: String, to: String, text: String, dashed: Bool, arrow: Arrow)
        case note(over: [String], side: NoteSide, text: String)
        case blockStart(kind: String, text: String)
        case blockElse(text: String)
        case blockEnd
    }

    enum Arrow { case filled, open, cross, none }
    enum NoteSide { case left, right, over }

    var participants: [Participant] = []
    var items: [Item] = []
    var autonumber = false

    mutating func participant(_ id: String, label: String? = nil, actor: Bool = false) {
        if let i = participants.firstIndex(where: { $0.id == id }) {
            if let label { participants[i].label = label }
            if actor { participants[i].actor = true }
        } else {
            participants.append(Participant(id: id, label: label ?? id, actor: actor))
        }
    }

    private static let message = try! NSRegularExpression(
        pattern: #"^(.+?)\s*(-->>|->>|-->|->|--x|-x|--\)|-\))\s*[+-]?\s*(.+?)\s*:\s*(.*)$"#)
    private static let note = try! NSRegularExpression(
        pattern: #"^note\s+(left of|right of|over)\s+([^:]+?)\s*:\s*(.*)$"#, options: .caseInsensitive)

    static func parse(_ lines: [String]) -> SequenceDiagram {
        var s = SequenceDiagram()
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            let ns = line as NSString
            let all = NSRange(location: 0, length: ns.length)
            if lower == "autonumber" || lower.hasPrefix("autonumber ") { s.autonumber = true; continue }
            if lower.hasPrefix("participant ") || lower.hasPrefix("actor ") {
                let actor = lower.hasPrefix("actor ")
                let rest = String(line.dropFirst(actor ? 6 : 12)).trimmingCharacters(in: .whitespaces)
                if let r = rest.range(of: " as ") {
                    s.participant(String(rest[..<r.lowerBound]).trimmingCharacters(in: .whitespaces),
                                  label: Mermaid.cleanLabel(String(rest[r.upperBound...])), actor: actor)
                } else {
                    s.participant(rest, actor: actor)
                }
                continue
            }
            if lower.hasPrefix("activate ") || lower.hasPrefix("deactivate ") || lower.hasPrefix("title ")
                || lower.hasPrefix("box ") || lower.hasPrefix("create ") || lower.hasPrefix("destroy ") {
                continue
            }
            if let m = note.firstMatch(in: line, range: all) {
                let where_ = ns.substring(with: m.range(at: 1)).lowercased()
                let ids = ns.substring(with: m.range(at: 2)).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                for id in ids { s.participant(id) }
                let side: NoteSide = where_ == "left of" ? .left : where_ == "right of" ? .right : .over
                s.items.append(.note(over: ids, side: side, text: Mermaid.cleanLabel(ns.substring(with: m.range(at: 3)))))
                continue
            }
            if let m = message.firstMatch(in: line, range: all) {
                let from = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let to = ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespaces)
                let op = ns.substring(with: m.range(at: 2))
                s.participant(from)
                s.participant(to)
                let arrow: Arrow = op.hasSuffix(">>") ? .filled : op.hasSuffix("x") ? .cross : op.hasSuffix(")") ? .open : .none
                s.items.append(.message(from: from, to: to, text: Mermaid.cleanLabel(ns.substring(with: m.range(at: 4))),
                                        dashed: op.hasPrefix("--"), arrow: arrow))
                continue
            }
            let word = lower.split(separator: " ").first.map(String.init) ?? ""
            let text = Mermaid.cleanLabel(String(line.dropFirst(word.count)))
            switch word {
            case "loop", "alt", "opt", "par", "critical", "break", "rect":
                s.items.append(.blockStart(kind: word == "rect" ? "" : word, text: word == "rect" ? "" : text))
            case "else", "and", "option":
                s.items.append(.blockElse(text: text))
            case "end":
                s.items.append(.blockEnd)
            default:
                break
            }
        }
        return s
    }
}

struct SequenceLayout {
    let diagram: SequenceDiagram
    let font: NSFont
    var columns: [String: CGFloat] = [:]
    var boxWidth: [String: CGFloat] = [:]
    var size: CGSize = .zero
    let headerHeight: CGFloat
    var rows: [CGFloat] = []

    init(_ diagram: SequenceDiagram, font: NSFont) {
        self.diagram = diagram
        self.font = font
        headerHeight = DiagramStyle.measure("Xy", font: font).height + 20
        layout()
    }

    private mutating func layout() {
        let margin: CGFloat = 16
        for p in diagram.participants {
            boxWidth[p.id] = max(80, DiagramStyle.measure(p.label, font: font, maxWidth: 160).width + 24)
        }
        var gaps = [CGFloat](repeating: 60, count: max(diagram.participants.count, 1))
        let index = Dictionary(uniqueKeysWithValues: diagram.participants.enumerated().map { ($1.id, $0) })
        for item in diagram.items {
            guard case .message(let from, let to, let text, _, _) = item, let a = index[from], let b = index[to] else { continue }
            let width = DiagramStyle.measure(text, font: font, maxWidth: 260).width + 30
            let lo = min(a, b), hi = max(a, b)
            if lo == hi {
                gaps[min(lo, gaps.count - 1)] = max(gaps[min(lo, gaps.count - 1)], width + 30)
            } else {
                let per = width / CGFloat(hi - lo)
                for g in lo..<hi { gaps[g] = max(gaps[g], per) }
            }
        }
        var x = margin
        for (i, p) in diagram.participants.enumerated() {
            let w = boxWidth[p.id]!
            if i > 0 {
                let prev = diagram.participants[i - 1]
                x += max(boxWidth[prev.id]! / 2 + w / 2 + 20, gaps[i - 1])
            } else {
                x += w / 2
            }
            columns[p.id] = x
        }
        let lastWidth = diagram.participants.last.map { boxWidth[$0.id]! / 2 } ?? 0
        var y = margin + headerHeight + 16
        for item in diagram.items {
            rows.append(y)
            switch item {
            case .message(let from, let to, let text, _, _):
                let h = DiagramStyle.measure(text, font: font, maxWidth: 260).height
                y += h + (from == to ? 40 : 26)
            case .note(_, _, let text):
                y += DiagramStyle.measure(text, font: font, maxWidth: 200).height + 26
            case .blockStart, .blockElse:
                y += 30
            case .blockEnd:
                y += 12
            }
        }
        size = CGSize(width: x + lastWidth + margin + 40, height: y + 10)
    }

    func image() -> NSImage {
        let layout = self
        return DiagramStyle.image(size: size) { _ in layout.draw() }
    }

    func draw() {
        let small = NSFont.systemFont(ofSize: font.pointSize * 0.9)
        let bottom = size.height - 10
        for p in diagram.participants {
            guard let x = columns[p.id], let w = boxWidth[p.id] else { continue }
            let line = NSBezierPath()
            line.move(to: CGPoint(x: x, y: 16 + headerHeight))
            line.line(to: CGPoint(x: x, y: bottom))
            line.setLineDash([3, 3], count: 2, phase: 0)
            NSColor.separatorColor.setStroke()
            line.stroke()
            let box = CGRect(x: x - w / 2, y: 16, width: w, height: headerHeight)
            let path = NSBezierPath(roundedRect: box, xRadius: p.actor ? box.height / 2 : 6, yRadius: p.actor ? box.height / 2 : 6)
            NSColor.textBackgroundColor.setFill()
            path.fill()
            DiagramStyle.nodeFill.setFill()
            path.fill()
            DiagramStyle.nodeStroke.setStroke()
            path.lineWidth = 1.2
            path.stroke()
            DiagramStyle.draw(p.label, in: box.insetBy(dx: 8, dy: 0),
                              font: NSFont.systemFont(ofSize: font.pointSize, weight: .medium))
        }
        var stack: [(kind: String, text: String, y: CGFloat)] = []
        let left = (columns.values.min() ?? 0) - 60
        let right = (columns.values.max() ?? 0) + 60
        var number = 1
        for (item, y) in zip(diagram.items, rows) {
            switch item {
            case .message(let from, let to, let text, let dashed, let arrow):
                guard let x1 = columns[from], let x2 = columns[to] else { continue }
                let label = diagram.autonumber ? "\(number). \(text)" : text
                number += 1
                let textHeight = DiagramStyle.measure(label, font: small, maxWidth: 260).height
                let lineY = y + textHeight + 8
                let path = NSBezierPath()
                var tip: CGPoint, tail: CGPoint
                if from == to {
                    path.move(to: CGPoint(x: x1, y: lineY))
                    path.line(to: CGPoint(x: x1 + 34, y: lineY))
                    path.line(to: CGPoint(x: x1 + 34, y: lineY + 16))
                    path.line(to: CGPoint(x: x1 + 2, y: lineY + 16))
                    tip = CGPoint(x: x1 + 2, y: lineY + 16)
                    tail = CGPoint(x: x1 + 34, y: lineY + 16)
                    DiagramStyle.draw(label, in: CGRect(x: x1 + 8, y: y, width: 260, height: textHeight), font: small,
                                      color: .labelColor, align: .left)
                } else {
                    let dir: CGFloat = x2 > x1 ? 1 : -1
                    path.move(to: CGPoint(x: x1, y: lineY))
                    tip = CGPoint(x: x2 - dir * 2, y: lineY)
                    path.line(to: tip)
                    tail = CGPoint(x: x1, y: lineY)
                    DiagramStyle.draw(label, in: CGRect(x: min(x1, x2), y: y, width: abs(x2 - x1), height: textHeight),
                                      font: small)
                }
                if dashed { path.setLineDash([5, 3], count: 2, phase: 0) }
                path.lineWidth = 1.3
                DiagramStyle.line.setStroke()
                DiagramStyle.line.setFill()
                path.stroke()
                switch arrow {
                case .filled: DiagramStyle.arrowHead(at: tip, from: tail)
                case .open: DiagramStyle.arrowHead(at: tip, from: tail, open: true)
                case .cross:
                    let c = NSBezierPath()
                    c.move(to: CGPoint(x: tip.x - 5, y: tip.y - 5))
                    c.line(to: CGPoint(x: tip.x + 5, y: tip.y + 5))
                    c.move(to: CGPoint(x: tip.x - 5, y: tip.y + 5))
                    c.line(to: CGPoint(x: tip.x + 5, y: tip.y - 5))
                    c.lineWidth = 1.5
                    c.stroke()
                case .none: break
                }
            case .note(let over, let side, let text):
                let xs = over.compactMap { columns[$0] }
                guard let first = xs.min(), let last = xs.max() else { continue }
                let textSize = DiagramStyle.measure(text, font: small, maxWidth: 200)
                let width = max(textSize.width + 20, last - first + 40)
                let x: CGFloat
                switch side {
                case .left: x = first - 12 - width
                case .right: x = first + 12
                case .over: x = (first + last) / 2 - width / 2
                }
                let r = CGRect(x: x, y: y, width: width, height: textSize.height + 12)
                NSColor.systemYellow.withAlphaComponent(0.22).setFill()
                NSColor.systemYellow.withAlphaComponent(0.7).setStroke()
                let p = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
                p.fill()
                p.stroke()
                DiagramStyle.draw(text, in: r.insetBy(dx: 8, dy: 0), font: small)
            case .blockStart(let kind, let text):
                stack.append((kind, text, y))
            case .blockElse(let text):
                let divider = NSBezierPath()
                divider.move(to: CGPoint(x: left, y: y + 4))
                divider.line(to: CGPoint(x: right, y: y + 4))
                divider.setLineDash([4, 3], count: 2, phase: 0)
                NSColor.tertiaryLabelColor.setStroke()
                divider.stroke()
                if !text.isEmpty {
                    DiagramStyle.draw("[\(text)]", in: CGRect(x: left, y: y + 8, width: right - left, height: 16), font: small,
                                      color: .secondaryLabelColor)
                }
            case .blockEnd:
                guard let block = stack.popLast() else { continue }
                let inset = CGFloat(stack.count) * 6
                let r = CGRect(x: left + inset, y: block.y, width: right - left - 2 * inset, height: y - block.y)
                let frame = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
                NSColor.tertiaryLabelColor.setStroke()
                frame.lineWidth = 1
                frame.stroke()
                if !block.kind.isEmpty {
                    let tag = block.kind
                    let tagSize = DiagramStyle.measure(tag, font: small)
                    let tagRect = CGRect(x: r.minX, y: r.minY, width: tagSize.width + 14, height: tagSize.height + 6)
                    NSColor.quaternaryLabelColor.setFill()
                    NSBezierPath(roundedRect: tagRect, xRadius: 6, yRadius: 6).fill()
                    DiagramStyle.draw(tag, in: tagRect, font: NSFont.systemFont(ofSize: small.pointSize, weight: .semibold))
                    if !block.text.isEmpty {
                        DiagramStyle.draw("[\(block.text)]", in: CGRect(x: tagRect.maxX + 6, y: r.minY, width: r.width - tagRect.width - 12,
                                                                     height: tagRect.height),
                                          font: small, color: .secondaryLabelColor, align: .left)
                    }
                }
            }
        }
    }
}

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
