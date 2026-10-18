import AppKit
import JoplinCore
import Markdown

/// Renders Markdown into an NSAttributedString using AppKit text blocks and tables (no web view).
struct MarkdownRenderer {
    var baseSize: CGFloat
    var resolveResource: (String) -> (Resource, URL)?

    private static let imageCache = NSCache<NSURL, NSImage>()

    static func loadImage(_ url: URL) -> NSImage? {
        if let cached = imageCache.object(forKey: url as NSURL) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        imageCache.setObject(image, forKey: url as NSURL)
        return image
    }

    func render(_ markdown: String, maxImageWidth: CGFloat = 640) -> NSAttributedString {
        let builder = AttributedBuilder(renderer: self, maxImageWidth: maxImageWidth)
        builder.blocks(Document(parsing: markdown).children, BlockStyle())
        // Drop the trailing paragraph break.
        if builder.out.string.hasSuffix("\n") {
            builder.out.deleteCharacters(in: NSRange(location: builder.out.length - 1, length: 1))
        }
        return builder.out
    }
}

private struct InlineStyle {
    var size: CGFloat
    var color: NSColor = .labelColor
    var bold = false
    var italic = false
    var code = false
    var strike = false
    var link: URL?
}

private struct BlockStyle {
    var indent: CGFloat = 0
    var textBlocks: [NSTextBlock] = []
    var color: NSColor = .labelColor
    var listDepth = 0
}

private let subtleFill = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(white: 1, alpha: 0.07)
        : NSColor(white: 0, alpha: 0.045)
}

private final class AttributedBuilder {
    let renderer: MarkdownRenderer
    let maxImageWidth: CGFloat
    let out = NSMutableAttributedString()
    private var pendingPrefix: NSAttributedString?
    private var pendingIndent: (first: CGFloat, head: CGFloat)?

    init(renderer: MarkdownRenderer, maxImageWidth: CGFloat) {
        self.renderer = renderer
        self.maxImageWidth = maxImageWidth
    }

    private var base: CGFloat { renderer.baseSize }

    // MARK: Attributes

    private func font(_ s: InlineStyle) -> NSFont {
        var f: NSFont = s.code
            ? .monospacedSystemFont(ofSize: s.size * 0.9, weight: s.bold ? .semibold : .regular)
            : .systemFont(ofSize: s.size, weight: s.bold ? .semibold : .regular)
        if s.italic { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
        return f
    }

    private func attrs(_ s: InlineStyle, codeBackground: Bool = true) -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [.font: font(s), .foregroundColor: s.color]
        if s.code && codeBackground {
            a[.backgroundColor] = subtleFill
            a[.foregroundColor] = NSColor.systemPink
        }
        if s.strike { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let link = s.link { a[.link] = link }
        return a
    }

    private func paragraphStyle(_ b: BlockStyle, first: CGFloat? = nil, head: CGFloat? = nil, before: CGFloat = 0,
                                after: CGFloat = 10, tab: CGFloat? = nil, align: NSTextAlignment = .natural) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = first ?? b.indent
        p.headIndent = head ?? b.indent
        p.paragraphSpacingBefore = before
        p.paragraphSpacing = after
        p.lineHeightMultiple = 1.2
        p.textBlocks = b.textBlocks
        p.alignment = align
        if let tab {
            p.tabStops = [NSTextTab(textAlignment: .left, location: tab)]
            p.defaultTabInterval = tab
        }
        return p
    }

    private func append(_ string: String, _ s: InlineStyle) {
        out.append(NSAttributedString(string: string, attributes: attrs(s)))
    }

    // MARK: Blocks

    func blocks<S: Sequence>(_ children: S, _ b: BlockStyle) where S.Element == Markup {
        for child in children { block(child, b) }
    }

    private func block(_ m: Markup, _ b: BlockStyle) {
        switch m {
        case let p as Paragraph:
            paragraph(p.children, b, style: InlineStyle(size: base, color: b.color))
        case let h as Heading:
            heading(h, b)
        case let c as CodeBlock:
            codeBlock(c.code, b)
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
            if !text.isEmpty { codeBlock(text, b) }
        }
    }

    private func paragraph<S: Sequence>(_ inlines: S, _ b: BlockStyle, style: InlineStyle, before: CGFloat = 0,
                                        after: CGFloat = 10, align: NSTextAlignment = .natural) where S.Element == Markup {
        let start = out.length
        var first = b.indent
        var head = b.indent
        var tab: CGFloat?
        if let prefix = pendingPrefix, let indent = pendingIndent {
            out.append(prefix)
            first = indent.first
            head = indent.head
            tab = indent.head
            pendingPrefix = nil
            pendingIndent = nil
        }
        for inline in inlines { self.inline(inline, style) }
        out.append(NSAttributedString(string: "\n", attributes: attrs(style)))
        out.addAttribute(.paragraphStyle,
                         value: paragraphStyle(b, first: first, head: head, before: before, after: after, tab: tab, align: align),
                         range: NSRange(location: start, length: out.length - start))
    }

    private func heading(_ h: Heading, _ b: BlockStyle) {
        let scales: [CGFloat] = [1.85, 1.5, 1.25, 1.1, 1.0, 0.9]
        var s = InlineStyle(size: base * scales[min(max(h.level, 1), 6) - 1], color: b.color)
        s.bold = true
        var bb = b
        if h.level <= 2 {
            let underline = NSTextBlock()
            underline.setContentWidth(100, type: .percentageValueType)
            underline.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
            underline.setWidth(4, type: .absoluteValueType, for: .padding, edge: .maxY)
            underline.setBorderColor(.separatorColor)
            bb.textBlocks.append(underline)
        }
        paragraph(h.children, bb, style: s, before: h.level <= 2 ? 14 : 10, after: 8)
    }

    private func codeBlock(_ code: String, _ b: BlockStyle) {
        let box = NSTextBlock()
        box.backgroundColor = subtleFill
        box.setContentWidth(100, type: .percentageValueType)
        box.setWidth(10, type: .absoluteValueType, for: .padding)
        var bb = b
        bb.textBlocks.append(box)
        var text = code
        while text.hasSuffix("\n") { text.removeLast() }
        // Line separators keep the whole block in one paragraph (one box).
        text = text.replacingOccurrences(of: "\n", with: "\u{2028}")
        var s = InlineStyle(size: base, color: b.color)
        s.code = true
        let start = out.length
        out.append(NSAttributedString(string: text + "\n", attributes: attrs(s, codeBackground: false)))
        out.addAttribute(.paragraphStyle, value: paragraphStyle(bb, after: 12), range: NSRange(location: start, length: out.length - start))
    }

    private func blockQuote(_ q: BlockQuote, _ b: BlockStyle) {
        let bar = NSTextBlock()
        bar.setContentWidth(100, type: .percentageValueType)
        bar.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
        bar.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
        bar.setBorderColor(.tertiaryLabelColor)
        var bb = b
        bb.textBlocks.append(bar)
        bb.color = .secondaryLabelColor
        blocks(q.children, bb)
    }

    private func list(_ items: [ListItem], ordered: Bool, start: Int, _ b: BlockStyle) {
        let bullets = ["•", "◦", "▪︎"]
        let step: CGFloat = base * 1.6
        var number = start
        for item in items {
            var markerStyle = InlineStyle(size: base, color: .secondaryLabelColor)
            var marker: String
            var itemColor = b.color
            if let checkbox = item.checkbox {
                marker = checkbox == .checked ? "☑︎" : "☐"
                markerStyle.size = base * 1.1
                markerStyle.color = .controlAccentColor
                if let line = item.range?.lowerBound.line {
                    markerStyle.link = URL(string: "joplincheckbox://\(line)")
                }
                if checkbox == .checked { itemColor = .secondaryLabelColor }
            } else if ordered {
                marker = "\(number)."
            } else {
                marker = bullets[b.listDepth % bullets.count]
            }
            number += 1

            let prefix = NSMutableAttributedString(string: marker, attributes: attrs(markerStyle))
            prefix.append(NSAttributedString(string: "\t", attributes: attrs(InlineStyle(size: base))))
            var inner = b
            inner.indent = b.indent + step
            inner.listDepth = b.listDepth + 1
            inner.color = itemColor
            pendingPrefix = prefix
            pendingIndent = (b.indent, b.indent + step)
            for child in item.children {
                if let p = child as? Paragraph {
                    paragraph(p.children, inner, style: InlineStyle(size: base, color: itemColor), after: 3)
                } else {
                    // Blocks such as code cannot carry the marker inline: put it on its own line first.
                    if pendingPrefix != nil {
                        paragraph([Markup](), inner, style: InlineStyle(size: base, color: itemColor), after: 3)
                    }
                    block(child, inner)
                }
            }
            if pendingPrefix != nil {
                paragraph([Markup](), inner, style: InlineStyle(size: base, color: itemColor), after: 3)
            }
        }
        // Space after the outermost list.
        if b.listDepth == 0, out.length > 0 {
            let r = NSRange(location: out.length - 1, length: 1)
            if let p = out.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle,
               let m = p.mutableCopy() as? NSMutableParagraphStyle {
                m.paragraphSpacing = 10
                var effective = NSRange()
                _ = out.attribute(.paragraphStyle, at: r.location, effectiveRange: &effective)
                out.addAttribute(.paragraphStyle, value: m, range: effective)
            }
        }
    }

    private func table(_ t: Markdown.Table, _ b: BlockStyle) {
        let headCells = Array(t.head.cells)
        let bodyRows = Array(t.body.rows)
        let columns = max(headCells.count, bodyRows.map { Array($0.cells).count }.max() ?? 0)
        guard columns > 0 else { return }
        let table = NSTextTable()
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
                let cellBlock = NSTextTableBlock(table: table, startingRow: index, rowSpan: 1, startingColumn: col, columnSpan: 1)
                cellBlock.setWidth(1, type: .absoluteValueType, for: .border)
                cellBlock.setBorderColor(.separatorColor)
                cellBlock.setWidth(6, type: .absoluteValueType, for: .padding)
                if header { cellBlock.backgroundColor = subtleFill }
                var bb = b
                bb.textBlocks = b.textBlocks + [cellBlock]
                var s = InlineStyle(size: base, color: b.color)
                s.bold = header
                let children: [Markup] = col < cells.count ? Array(cells[col].children) : []
                paragraph(children, bb, style: s, after: 0, align: alignment(col))
            }
        }

        row(headCells, index: 0, header: true)
        for (i, r) in bodyRows.enumerated() { row(Array(r.cells), index: i + 1, header: false) }
        // Gap after the table.
        let start = out.length
        out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 4)]))
        out.addAttribute(.paragraphStyle, value: paragraphStyle(b, after: 6), range: NSRange(location: start, length: 1))
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
        out.addAttribute(.paragraphStyle, value: paragraphStyle(bb, before: 6, after: 14), range: NSRange(location: start, length: 1))
    }

    private func htmlBlock(_ html: String, _ b: BlockStyle) {
        // Joplin notes often contain small HTML fragments; show their text content rather than markup.
        let stripped = html.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return }
        let start = out.length
        append(stripped.replacingOccurrences(of: "\n", with: "\u{2028}") + "\n", InlineStyle(size: base, color: b.color))
        out.addAttribute(.paragraphStyle, value: paragraphStyle(b), range: NSRange(location: start, length: out.length - start))
    }

    // MARK: Inlines

    private func inline(_ m: Markup, _ s: InlineStyle) {
        switch m {
        case let t as Markdown.Text:
            append(t.string, s)
        case let e as Emphasis:
            var s2 = s
            s2.italic = true
            for c in e.children { inline(c, s2) }
        case let e as Strong:
            var s2 = s
            s2.bold = true
            for c in e.children { inline(c, s2) }
        case let e as Strikethrough:
            var s2 = s
            s2.strike = true
            for c in e.children { inline(c, s2) }
        case let c as InlineCode:
            var s2 = s
            s2.code = true
            append(c.code, s2)
        case let l as Markdown.Link:
            var s2 = s
            s2.link = linkURL(l.destination)
            if let dest = l.destination, dest.hasPrefix(":/"), let (res, _) = resource(dest) {
                append("📎 ", s2)
                if l.childCount == 0 { append(res.displayName, s2) }
            }
            for c in l.children { inline(c, s2) }
            if l.childCount == 0, l.destination?.hasPrefix(":/") != true { append(l.destination ?? "", s2) }
        case let img as Markdown.Image:
            image(img, s)
        case is SoftBreak:
            append(" ", s)
        case is LineBreak:
            append("\u{2028}", s)
        case let h as InlineHTML:
            if h.rawHTML.lowercased().hasPrefix("<br") { append("\u{2028}", s) }
        default:
            if m.childCount > 0 {
                for c in m.children { inline(c, s) }
            } else {
                append(m.format(), s)
            }
        }
    }

    private func resource(_ dest: String) -> (Resource, URL)? {
        let id = String(dest.dropFirst(2).prefix(32))
        return renderer.resolveResource(id)
    }

    private func linkURL(_ dest: String?) -> URL? {
        guard let d = dest?.trimmingCharacters(in: .whitespaces), !d.isEmpty else { return nil }
        if d.hasPrefix(":/") { return URL(string: "joplinitem://\(d.dropFirst(2).prefix(32))") }
        return URL(string: d) ?? d.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).flatMap(URL.init(string:))
    }

    private func image(_ img: Markdown.Image, _ s: InlineStyle) {
        let alt = img.plainText
        if let src = img.source, src.hasPrefix(":/"), let (res, url) = resource(src) {
            let itemURL = URL(string: "joplinitem://\(res.id)")
            if res.isImage, let image = MarkdownRenderer.loadImage(url) {
                let attachment = NSTextAttachment()
                attachment.image = image
                let size = image.size
                let scale = min(1, maxImageWidth / max(size.width, 1))
                attachment.bounds = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
                let a = NSMutableAttributedString(attachment: attachment)
                if let itemURL { a.addAttribute(.link, value: itemURL, range: NSRange(location: 0, length: a.length)) }
                out.append(a)
                return
            }
            var s2 = s
            s2.link = itemURL
            append("📎 \(alt.isEmpty ? res.displayName : alt)", s2)
            return
        }
        var s2 = s
        s2.link = linkURL(img.source)
        s2.color = .secondaryLabelColor
        append("🖼 \(alt.isEmpty ? (img.source ?? "image") : alt)", s2)
    }
}
