import AppKit

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
