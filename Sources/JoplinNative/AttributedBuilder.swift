import AppKit
import Markdown

final class AttributedBuilder {
    let renderer: MarkdownRenderer
    let maxImageWidth: CGFloat
    let formulas: [MathExtractor.Formula]
    let out = NSMutableAttributedString()
    private var pendingPrefix: NSAttributedString?
    private var pendingIndent: (first: CGFloat, head: CGFloat, tabs: [NSTextTab])?
    var html = HTMLState()
    private var headings: [(level: Int, title: String, slug: String)] = []
    private(set) var headingIndex = 0
    private(set) var headingBases: [String] = []
    var lineOffset = 0
    var symbols: [String: NSAttributedString] = [:]
    var sizedToWidth = false
    private(set) var hasTOC = false
    var headingSlugs: [String] { headings.map(\.slug) }
    var htmlIsOpen: Bool { !html.counts.isEmpty || !html.links.isEmpty }

    init(renderer: MarkdownRenderer, maxImageWidth: CGFloat, formulas: [MathExtractor.Formula]) {
        self.renderer = renderer
        self.maxImageWidth = maxImageWidth
        self.formulas = formulas
    }

    private var typography: Typography { renderer.typography }
    var base: CGFloat { typography.size }

    func collectHeadings(_ document: Document, before: [String: Int] = [:]) {
        var seen = before.compactMapValues { $0 > 0 ? $0 - 1 : nil }
        func walk(_ m: Markup) {
            if let h = m as? Heading {
                let title = restoreMath(Self.plainText(h))
                var slug = MarkdownRenderer.slug(title)
                headingBases.append(slug)
                if let n = seen[slug] {
                    seen[slug] = n + 1
                    slug += "-\(n + 1)"
                } else {
                    seen[slug] = 0
                }
                headings.append((h.level, title, slug))
                return
            }
            for c in m.children { walk(c) }
        }
        walk(document)
    }

    static func plainText(_ m: Markup) -> String {
        switch m {
        case let t as Markdown.Text: return t.string
        case let c as InlineCode: return c.code
        case is SoftBreak, is LineBreak: return " "
        default: return m.children.map(plainText).joined()
        }
    }

    func font(_ s: InlineStyle) -> NSFont {
        let size = s.script != 0 ? s.size * 0.75 : s.size
        let weight: NSFont.Weight = s.bold ? s.weight : .regular
        if s.code || s.kbd {
            let factor: CGFloat = typography.family.isMonospaced ? 1 : 0.9
            return typography.codeFamily.font(size: size * factor, weight: weight, italic: s.italic)
        }
        return typography.family.font(size: size, weight: weight, italic: s.italic)
    }

    func attrs(_ s: InlineStyle, codeBackground: Bool = true) -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [.font: font(s), .foregroundColor: s.color]
        if (s.code || s.kbd) && codeBackground {
            a[.backgroundColor] = subtleFill
        }
        if s.mark { a[.backgroundColor] = NSColor.systemYellow.withAlphaComponent(0.35) }
        if s.strike { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if s.underline { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if s.script != 0 { a[.baselineOffset] = s.script > 0 ? s.size * 0.35 : -s.size * 0.15 }
        if let link = s.link {
            a[.link] = link
            a[.foregroundColor] = NSColor.linkColor
        }
        return a
    }

    func paragraphStyle(_ b: BlockStyle, first: CGFloat? = nil, head: CGFloat? = nil, before: CGFloat = 0,
                                after: CGFloat? = nil, tabs: [NSTextTab]? = nil, align: NSTextAlignment = .natural,
                                lineHeight: CGFloat = 1.3) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = first ?? b.indent
        p.headIndent = head ?? b.indent
        p.paragraphSpacingBefore = before
        p.paragraphSpacing = after ?? (base * 0.8).rounded()
        p.lineHeightMultiple = lineHeight
        p.textBlocks = b.textBlocks
        p.alignment = align
        if let tabs {
            p.tabStops = tabs
            p.defaultTabInterval = tabs.last?.location ?? 28
        }
        return p
    }

    func append(_ string: String, _ s: InlineStyle) {
        out.append(NSAttributedString(string: string, attributes: attrs(html.style(s))))
    }

    func blocks<S: Sequence>(_ children: S, _ b: BlockStyle) where S.Element == Markup {
        for child in children { block(child, b) }
    }

    private func block(_ m: Markup, _ b: BlockStyle) {
        switch m {
        case let p as Paragraph:
            if isTOC(p) {
                tableOfContents(b)
            } else if let formula = soleDisplayFormula(p) {
                displayMath(formula.tex, b)
            } else {
                paragraph(p.children, b, style: InlineStyle(size: base, color: b.color))
            }
        case let h as Heading:
            heading(h, b)
        case let c as CodeBlock:
            let language = c.language?.lowercased()
            let code = restoreMath(c.code)
            if language == "math" || language == "latex" || language == "katex" || language == "tex" {
                displayMath(code, b)
            } else if language == "mermaid", let image = MarkdownRenderer.mermaid(code, fontSize: base * 0.9) {
                diagram(image, card: true, b)
            } else if language == "drawio", let image = Drawio.image(xml: code) {
                diagram(image, card: false, b)
            } else {
                codeBlock(code, language: c.language, b)
            }
        case let q as BlockQuote:
            blockQuote(q, b)
        case let l as UnorderedList:
            list(Array(l.listItems), ordered: false, start: 1, b)
        case let l as OrderedList:
            list(Array(l.listItems), ordered: true, start: Int(l.startIndex), b)
        case let t as Markdown.Table:
            table(t, b)
        case is ThematicBreak:
            rule(b)
        case let h as HTMLBlock:
            htmlBlock(h.rawHTML, b)
        default:
            let text = m.format()
            if !text.isEmpty { codeBlock(text, language: nil, b) }
        }
    }

    func beginParagraph(_ b: BlockStyle) -> (start: Int, first: CGFloat, head: CGFloat, tabs: [NSTextTab]?) {
        let start = out.length
        if let prefix = pendingPrefix, let indent = pendingIndent {
            out.append(prefix)
            pendingPrefix = nil
            pendingIndent = nil
            return (start, indent.first, indent.head, indent.tabs)
        }
        return (start, b.indent, b.indent, nil)
    }

    private func paragraph<S: Sequence>(_ inlines: S, _ b: BlockStyle, style: InlineStyle, before: CGFloat = 0,
                                        after: CGFloat? = nil, align: NSTextAlignment = .natural,
                                        lineHeight: CGFloat = 1.3) where S.Element == Markup {
        let p = beginParagraph(b)
        for inline in inlines { self.inline(inline, style) }
        html = HTMLState()
        out.append(NSAttributedString(string: "\n", attributes: attrs(style)))
        var hasLargeImage = false
        out.enumerateAttribute(.attachment, in: NSRange(location: p.start, length: out.length - p.start)) { value, _, stop in
            if let a = value as? NSTextAttachment, a.bounds.height > base * 2.5 {
                hasLargeImage = true
                stop.pointee = true
            }
        }
        out.addAttribute(.paragraphStyle,
                         value: paragraphStyle(b, first: p.first, head: p.head, before: before, after: after, tabs: p.tabs,
                                               align: align, lineHeight: hasLargeImage ? 1 : lineHeight),
                         range: NSRange(location: p.start, length: out.length - p.start))
    }

    private func heading(_ h: Heading, _ b: BlockStyle) {
        let level = min(max(h.level, 1), 6)
        let scales: [CGFloat] = [1.9, 1.5, 1.25, 1.1, 1.0, 0.9]
        var s = InlineStyle(size: base * scales[level - 1], color: level == 6 ? .secondaryLabelColor : b.color)
        s.bold = true
        s.weight = level <= 2 ? .bold : .semibold
        var bb = b
        if level <= 2 {
            let underline = NSTextBlock()
            underline.setContentWidth(100, type: .percentageValueType)
            underline.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
            underline.setWidth(level == 1 ? 6 : 4, type: .absoluteValueType, for: .padding, edge: .maxY)
            underline.setBorderColor(.separatorColor)
            bb.textBlocks.append(underline)
        }
        let start = out.length
        let first = out.length == 0
        paragraph(h.children, bb, style: s, before: first ? 0 : base * (level <= 2 ? 1.4 : 1.0),
                  after: base * (level <= 2 ? 0.7 : 0.45), lineHeight: 1.1)
        if headingIndex < headings.count {
            out.addAttribute(.jnAnchor, value: headings[headingIndex].slug, range: NSRange(location: start, length: out.length - start))
            headingIndex += 1
        }
    }

    private func codeBlock(_ code: String, language: String?, _ b: BlockStyle) {
        let box = DecoratedBlock()
        box.fill = subtleFill
        box.radius = 8
        let lang = language?.split(separator: " ").first.map(String.init)
        box.caption = lang
        box.setWidth(14, type: .absoluteValueType, for: .padding)
        box.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minY)
        box.setWidth(12, type: .absoluteValueType, for: .padding, edge: .maxY)
        if lang != nil { box.setWidth(22, type: .absoluteValueType, for: .padding, edge: .minY) }
        spaceBeforeBlock(box)
        var bb = b
        bb.textBlocks.append(box)
        var text = code
        while text.hasSuffix("\n") { text.removeLast() }
        text = text.replacingOccurrences(of: "\n", with: "\u{2028}")
        var s = InlineStyle(size: base, color: b.color)
        s.code = true
        let p = beginParagraph(bb)
        let codeStart = out.length
        out.append(NSAttributedString(string: text + "\n", attributes: attrs(s, codeBackground: false)))
        CodeHighlighter.apply(language: lang, to: out, range: NSRange(location: codeStart, length: (text as NSString).length))
        out.addAttribute(.paragraphStyle, value: paragraphStyle(bb, first: p.first, head: p.head, after: base, tabs: p.tabs, lineHeight: 1.2),
                         range: NSRange(location: p.start, length: out.length - p.start))
    }

    private func diagram(_ image: NSImage, card: Bool, _ b: BlockStyle) {
        sizedToWidth = true
        var bb = b
        var width = maxImageWidth
        if card {
            let box = DecoratedBlock()
            box.fill = subtleFill
            box.radius = 8
            box.setWidth(16, type: .absoluteValueType, for: .padding)
            spaceBeforeBlock(box)
            bb.textBlocks.append(box)
            width -= 32
        }
        let p = beginParagraph(bb)
        let size = image.size
        let scale = min(1, max(width, 40) / max(size.width, 1))
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
        out.append(NSAttributedString(attachment: attachment))
        out.append(NSAttributedString(string: "\n", attributes: attrs(InlineStyle(size: base))))
        out.addAttribute(.paragraphStyle,
                         value: paragraphStyle(bb, first: p.first, head: p.head, after: card ? base : base * 0.8, tabs: p.tabs,
                                               align: p.tabs == nil ? .center : .natural, lineHeight: 1),
                         range: NSRange(location: p.start, length: out.length - p.start))
        if card { spaceAfterBlock(b) }
    }

    private func displayMath(_ tex: String, _ b: BlockStyle) {
        let p = beginParagraph(b)
        out.append(MathRenderer(size: base * 1.15, color: b.color).render(tex))
        out.append(NSAttributedString(string: "\n", attributes: attrs(InlineStyle(size: base))))
        out.addAttribute(.paragraphStyle,
                         value: paragraphStyle(b, first: p.first, head: p.head, before: base * 0.3, after: base, tabs: p.tabs,
                                               align: p.tabs == nil ? .center : .natural),
                         range: NSRange(location: p.start, length: out.length - p.start))
    }

    private func soleDisplayFormula(_ p: Paragraph) -> MathExtractor.Formula? {
        guard p.childCount == 1, let t = p.child(at: 0) as? Markdown.Text,
              let m = MathExtractor.placeholder.firstMatch(in: t.string, range: NSRange(location: 0, length: (t.string as NSString).length)),
              m.range.length == (t.string as NSString).length,
              let index = Int((t.string as NSString).substring(with: m.range(at: 1))),
              formulas.indices.contains(index), formulas[index].display else { return nil }
        return formulas[index]
    }

    private static let alerts: [String: (title: String, symbol: String, color: NSColor)] = [
        "NOTE": ("Note", "info.circle", .systemBlue),
        "TIP": ("Tip", "lightbulb", .systemGreen),
        "IMPORTANT": ("Important", "exclamationmark.bubble", .systemPurple),
        "WARNING": ("Warning", "exclamationmark.triangle", .systemOrange),
        "CAUTION": ("Caution", "exclamationmark.octagon", .systemRed),
    ]

    private func alert(_ q: BlockQuote) -> (kind: String, rest: [Markup])? {
        guard let first = q.child(at: 0) as? Paragraph, let text = first.child(at: 0) as? Markdown.Text else { return nil }
        let s = text.string.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("[!"), let close = s.firstIndex(of: "]") else { return nil }
        let kind = s[s.index(s.startIndex, offsetBy: 2)..<close].uppercased()
        guard Self.alerts[kind] != nil else { return nil }
        var rest = Array(first.children.dropFirst())
        let after = s[s.index(after: close)...].trimmingCharacters(in: .whitespaces)
        if !after.isEmpty { rest.insert(Markdown.Text(after), at: 0) }
        while let head = rest.first, head is SoftBreak || head is LineBreak { rest.removeFirst() }
        return (kind, rest)
    }

    private func blockQuote(_ q: BlockQuote, _ b: BlockStyle) {
        let box = DecoratedBlock()
        spaceBeforeBlock(box)
        box.setWidth(14, type: .absoluteValueType, for: .padding, edge: .minX)
        var bb = b
        bb.inQuote = true
        if let (kind, rest) = alert(q), let info = Self.alerts[kind] {
            box.bar = info.color
            box.fill = info.color.withAlphaComponent(0.08)
            box.setWidth(9, type: .absoluteValueType, for: .padding, edge: .minY)
            box.setWidth(9, type: .absoluteValueType, for: .padding, edge: .maxY)
            box.setWidth(12, type: .absoluteValueType, for: .padding, edge: .maxX)
            bb.textBlocks.append(box)
            var title = InlineStyle(size: base, color: info.color)
            title.bold = true
            let p = beginParagraph(bb)
            if let icon = symbolAttachment(info.symbol, color: info.color, font: font(title)) { out.append(icon) }
            out.append(NSAttributedString(string: " " + info.title + "\n", attributes: attrs(title)))
            out.addAttribute(.paragraphStyle, value: paragraphStyle(bb, first: p.first, head: p.head, after: base * 0.35),
                             range: NSRange(location: p.start, length: out.length - p.start))
            if !rest.isEmpty { paragraph(rest, bb, style: InlineStyle(size: base, color: bb.color)) }
            blocks(q.children.dropFirst(), bb)
        } else {
            box.bar = .quaternaryLabelColor
            bb.textBlocks.append(box)
            bb.color = .secondaryLabelColor
            blocks(q.children, bb)
        }
        trimLastParagraphSpacing(to: 0)
        spaceAfterBlock(b)
    }

    private func spaceBeforeBlock(_ block: NSTextBlock) {
        guard out.length > 0, pendingPrefix == nil else { return }
        block.setWidth((base * 0.6).rounded(), type: .absoluteValueType, for: .margin, edge: .minY)
    }

    private func spaceAfterBlock(_ b: BlockStyle) {
        let start = out.length
        out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 2)]))
        out.addAttribute(.paragraphStyle, value: paragraphStyle(b, after: base * 0.6, lineHeight: 1),
                         range: NSRange(location: start, length: 1))
    }

    private func trimLastParagraphSpacing(to spacing: CGFloat) {
        guard out.length > 0 else { return }
        var effective = NSRange()
        guard let p = out.attribute(.paragraphStyle, at: out.length - 1, effectiveRange: &effective) as? NSParagraphStyle,
              let m = p.mutableCopy() as? NSMutableParagraphStyle else { return }
        m.paragraphSpacing = spacing
        out.addAttribute(.paragraphStyle, value: m, range: effective)
    }

    private func list(_ items: [ListItem], ordered: Bool, start: Int, _ b: BlockStyle) {
        let bullets = ["•", "◦", "▪︎"]
        let digits = String(start + items.count - 1).count
        let step: CGFloat = ordered ? base * (1.1 + 0.55 * CGFloat(max(digits, 2))) : base * 1.6
        let markerGap = base * 0.45
        let loose = items.contains { $0.childCount > 1 }
        var number = start
        for item in items {
            var markerStyle = InlineStyle(size: base, color: .secondaryLabelColor)
            var itemColor = b.color
            let prefix = NSMutableAttributedString(string: "\t", attributes: attrs(InlineStyle(size: base)))
            if let checkbox = item.checkbox {
                let checked = checkbox == .checked
                let symbol = checked ? "checkmark.circle.fill" : "circle"
                let colors: [NSColor] = checked ? [.white, .controlAccentColor] : [.secondaryLabelColor]
                if let icon = symbolAttachment(symbol, colors: colors, font: font(InlineStyle(size: base * 1.12))) {
                    let marker = NSMutableAttributedString(attributedString: icon)
                    var extra: [NSAttributedString.Key: Any] = [.cursor: NSCursor.pointingHand]
                    if let line = item.range?.lowerBound.line { extra[.jnCheckbox] = CheckboxLine(line + lineOffset) }
                    marker.addAttributes(extra, range: NSRange(location: 0, length: marker.length))
                    prefix.append(marker)
                }
                if checked { itemColor = .secondaryLabelColor }
            } else {
                if ordered {
                    markerStyle.color = .secondaryLabelColor
                    prefix.append(NSAttributedString(string: "\(number).", attributes: attrs(markerStyle)))
                } else {
                    markerStyle.color = .tertiaryLabelColor
                    if b.listDepth % bullets.count == 0 { markerStyle.size = base * 1.1 }
                    prefix.append(NSAttributedString(string: bullets[b.listDepth % bullets.count], attributes: attrs(markerStyle)))
                }
            }
            number += 1
            prefix.append(NSAttributedString(string: "\t", attributes: attrs(InlineStyle(size: base))))

            var inner = b
            inner.indent = b.indent + step
            inner.listDepth = b.listDepth + 1
            inner.color = itemColor
            let tabs = [NSTextTab(textAlignment: .right, location: b.indent + step - markerGap),
                        NSTextTab(textAlignment: .left, location: b.indent + step)]
            pendingPrefix = prefix
            pendingIndent = (b.indent, b.indent + step, tabs)
            let itemAfter = loose ? base * 0.6 : base * 0.25
            for child in item.children {
                if let p = child as? Paragraph {
                    paragraph(p.children, inner, style: InlineStyle(size: base, color: itemColor), after: itemAfter)
                } else {
                    if pendingPrefix != nil, !(child is HTMLBlock) {
                        paragraph([Markup](), inner, style: InlineStyle(size: base, color: itemColor), after: itemAfter)
                    }
                    block(child, inner)
                }
            }
            if pendingPrefix != nil {
                paragraph([Markup](), inner, style: InlineStyle(size: base, color: itemColor), after: itemAfter)
            }
        }
        if b.listDepth == 0 { trimLastParagraphSpacing(to: (base * 0.8).rounded()) }
    }

    private func table(_ t: Markdown.Table, _ b: BlockStyle) {
        let headCells = Array(t.head.cells)
        let bodyRows = Array(t.body.rows)
        let columns = max(headCells.count, bodyRows.map { Array($0.cells).count }.max() ?? 0)
        guard columns > 0 else { return }
        let table = NSTextTable()
        spaceBeforeBlock(table)
        table.numberOfColumns = columns
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setContentWidth(100, type: .percentageValueType)

        func alignment(_ col: Int) -> NSTextAlignment {
            guard col < t.columnAlignments.count, let a = t.columnAlignments[col] else { return .natural }
            switch a {
            case .left: return .left
            case .center: return .center
            case .right: return .right
            }
        }

        func row(_ cells: [Markdown.Table.Cell], index: Int, header: Bool) {
            for col in 0..<columns {
                let cell = col < cells.count ? cells[col] : nil
                if let cell, cell.colspan == 0 || cell.rowspan == 0 { continue }
                let colspan = Int(cell?.colspan ?? 1)
                let rowspan = Int(cell?.rowspan ?? 1)
                let cellBlock = NSTextTableBlock(table: table, startingRow: index, rowSpan: max(1, rowspan),
                                                 startingColumn: col, columnSpan: max(1, min(colspan, columns - col)))
                cellBlock.setWidth(1, type: .absoluteValueType, for: .border)
                cellBlock.setBorderColor(.separatorColor)
                cellBlock.setWidth(base * 0.6, type: .absoluteValueType, for: .padding)
                cellBlock.setWidth(base * 0.35, type: .absoluteValueType, for: .padding, edge: .minY)
                cellBlock.setWidth(base * 0.35, type: .absoluteValueType, for: .padding, edge: .maxY)
                if header {
                    cellBlock.backgroundColor = subtleFill
                } else if index % 2 == 0 {
                    cellBlock.backgroundColor = stripeFill
                }
                var bb = b
                bb.textBlocks = b.textBlocks + [cellBlock]
                var s = InlineStyle(size: base, color: b.color)
                s.bold = header
                let children: [Markup] = cell.map { Array($0.children) } ?? []
                paragraph(children, bb, style: s, after: 0, align: alignment(col), lineHeight: 1.2)
            }
        }

        row(headCells, index: 0, header: true)
        for (i, r) in bodyRows.enumerated() { row(Array(r.cells), index: i + 1, header: false) }
        spaceAfterBlock(b)
    }

    private func rule(_ b: BlockStyle) {
        let line = NSTextBlock()
        line.setContentWidth(100, type: .percentageValueType)
        line.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
        line.setBorderColor(.separatorColor)
        var bb = b
        bb.textBlocks.append(line)
        let start = out.length
        out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 4)]))
        out.addAttribute(.paragraphStyle, value: paragraphStyle(bb, before: base * 0.5, after: base * 1.1, lineHeight: 1),
                         range: NSRange(location: start, length: 1))
    }

    private func isTOC(_ p: Paragraph) -> Bool {
        let text = p.plainText.trimmingCharacters(in: .whitespaces).lowercased()
        return text == "[toc]" || text == "[[toc]]" || text == "${toc}"
    }

    private func tableOfContents(_ b: BlockStyle) {
        hasTOC = true
        guard !headings.isEmpty else { return }
        let top = headings.map(\.level).min() ?? 1
        let box = DecoratedBlock()
        spaceBeforeBlock(box)
        box.fill = subtleFill
        box.radius = 8
        box.setWidth(14, type: .absoluteValueType, for: .padding)
        var bb = b
        bb.textBlocks.append(box)
        for (i, h) in headings.enumerated() {
            var s = InlineStyle(size: base * 0.95, color: b.color)
            s.link = URL(string: "#" + (h.slug.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? h.slug))
            if h.level == top { s.bold = true }
            let start = out.length
            append(h.title.isEmpty ? "Untitled" : h.title, s)
            out.append(NSAttributedString(string: "\n", attributes: attrs(s)))
            let indent = b.indent + CGFloat(h.level - top) * base * 1.2
            out.addAttribute(.paragraphStyle,
                             value: paragraphStyle(bb, first: indent, head: indent, after: i == headings.count - 1 ? 0 : base * 0.25),
                             range: NSRange(location: start, length: out.length - start))
        }
        spaceAfterBlock(b)
    }
}
