import AppKit

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
