import AppKit

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

    static func attributes(_ text: Substring) -> ([String: String], Int)? {
        var attributes: [String: String] = [:]
        var key = "", value = "", inKey = true, quote: Character?
        var length = 0
        func flush() {
            let k = key.trimmingCharacters(in: .whitespaces).lowercased()
            if !k.isEmpty { attributes[k] = value.trimmingCharacters(in: .whitespaces) }
            key = ""
            value = ""
            inKey = true
        }
        for c in text {
            length += 1
            if let q = quote {
                if c == q { quote = nil } else { value.append(c) }
                continue
            }
            switch c {
            case "}":
                flush()
                return (attributes, length)
            case "\"" where !inKey, "'" where !inKey:
                quote = c
            case ":" where inKey:
                inKey = false
            case ",":
                flush()
            default:
                if inKey { key.append(c) } else { value.append(c) }
            }
        }
        return nil
    }

    static func shape(named name: String) -> Shape {
        switch name.lowercased() {
        case "rounded", "event": return .round
        case "stadium", "terminal", "pill": return .stadium
        case "circle", "circ", "dbl-circ", "double-circle": return .circle
        case "diam", "diamond", "decision", "question": return .diamond
        case "hex", "hexagon", "prepare": return .hexagon
        case "cyl", "cylinder", "database", "db": return .cylinder
        case "subproc", "subprocess", "subroutine", "fr-rect", "framed-rectangle": return .subroutine
        case "lean-r", "lean-l", "lean-right", "lean-left", "in-out", "out-in": return .parallelogram
        case "flag", "odd": return .asymmetric
        case "sm-circ", "small-circle", "start": return .start
        case "fr-circ", "framed-circle", "stop": return .end
        default: return .rect
        }
    }

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
            if rest.hasPrefix("@{"), let (attributes, length) = Self.attributes(rest.dropFirst(2)) {
                node(id, label: attributes["label"].map(Mermaid.cleanLabel), shape: attributes["shape"].map(Self.shape(named:)))
                i += 2 + length
            }
            for s in Self.shapes where rest.hasPrefix(s.open) {
                let after = rest.dropFirst(s.open.count)
                if let close = after.range(of: s.close) {
                    let text = String(after[..<close.lowerBound])
                    node(id, label: Mermaid.cleanLabel(text), shape: s.shape)
                    i += s.open.count + after.distance(from: after.startIndex, to: close.upperBound)
                    break
                }
            }
            if node(id: id) == nil { node(id) }
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
