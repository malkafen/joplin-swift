import AppKit
import JoplinCore
import Markdown

extension NSAttributedString.Key {
    /// Slug of a heading, the target of `#slug` links and the table of contents.
    static let jnAnchor = NSAttributedString.Key("JNAnchor")
    /// 1-based source line of a task list checkbox; clicking it toggles the box in the note.
    static let jnCheckbox = NSAttributedString.Key("JNCheckbox")
}

/// Renders Markdown into an NSAttributedString using AppKit text blocks and tables (no web view).
///
/// Beyond CommonMark and GFM (tables, task lists, strikethrough) it supports what Joplin notes use: `$…$` and
/// `$$…$$` math, `==highlight==`, inline and block HTML (`<img width>`, `<kbd>`, `<mark>`, `<sup>`…), GitHub
/// alerts (`> [!NOTE]`), `[toc]`, heading anchors, bare URLs and syntax highlighting in fenced code.
struct MarkdownRenderer {
    var typography: Typography
    var resolveResource: (String) -> (Resource, URL)?
    /// Returns a downloaded remote image, or nil (the renderer then shows a placeholder).
    var remoteImage: ((URL) -> NSImage?)?
    var loadsRemoteImages: Bool { remoteImage != nil }

    var baseSize: CGFloat { typography.size }

    init(typography: Typography, resolveResource: @escaping (String) -> (Resource, URL)?,
         remoteImage: ((URL) -> NSImage?)? = nil) {
        self.typography = typography
        self.resolveResource = resolveResource
        self.remoteImage = remoteImage
    }

    init(baseSize: CGFloat, resolveResource: @escaping (String) -> (Resource, URL)?) {
        self.init(typography: Typography(size: baseSize), resolveResource: resolveResource)
    }

    private static let imageCache = NSCache<NSURL, NSImage>()

    static func loadImage(_ url: URL) -> NSImage? {
        if let cached = imageCache.object(forKey: url as NSURL) { return cached }
        guard let image = NSImage(contentsOf: url), image.isValid else { return nil }
        imageCache.setObject(image, forKey: url as NSURL)
        return image
    }

    private static let diagramCache = NSCache<NSString, NSImage>()

    /// Mermaid diagram for `source`, cached: the preview re-renders on every keystroke in split view.
    static func mermaid(_ source: String, fontSize: CGFloat) -> NSImage? {
        let key = "\(fontSize)|\(source)" as NSString
        if let cached = diagramCache.object(forKey: key) { return cached }
        guard let image = Mermaid.image(source, fontSize: fontSize) else { return nil }
        diagramCache.setObject(image, forKey: key)
        return image
    }

    /// draw.io diagram stored in a resource: an SVG exported by draw.io (with the diagram embedded) or a
    /// `.drawio` file. PNG exports render as ordinary images.
    static func drawio(_ res: Resource, url: URL) -> NSImage? {
        let ext = res.fileExtension.lowercased()
        let isSVG = res.mime == "image/svg+xml" || ext == "svg"
        let isFile = ext == "drawio" || ext == "dio" || res.mime.contains("drawio") || res.mime.contains("jgraph")
        guard isSVG || isFile else { return nil }
        let key = "drawio|\(url.path)" as NSString
        if let cached = diagramCache.object(forKey: key) { return cached }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let image = isSVG ? Drawio.image(svg: data) : Drawio.image(xml: String(decoding: data, as: UTF8.self))
        if let image { diagramCache.setObject(image, forKey: key) }
        return image
    }

    func render(_ markdown: String, maxImageWidth: CGFloat = 640) -> NSAttributedString {
        let (source, formulas) = MathExtractor.extract(markdown)
        let document = Document(parsing: source)
        let builder = AttributedBuilder(renderer: self, maxImageWidth: maxImageWidth, formulas: formulas)
        builder.collectHeadings(document)
        builder.blocks(document.children, BlockStyle())
        // Drop the trailing paragraph break and spacers.
        while builder.out.string.hasSuffix("\n") {
            builder.out.deleteCharacters(in: NSRange(location: builder.out.length - 1, length: 1))
        }
        return builder.out
    }

    /// GitHub-style heading anchor: lowercase, punctuation removed, spaces as dashes.
    static func slug(_ title: String) -> String {
        let lowered = title.lowercased()
        var s = ""
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                s.unicodeScalars.append(scalar)
            } else if scalar == " " {
                s.append("-")
            }
        }
        return s
    }
}

// MARK: - Styles

private struct InlineStyle {
    var size: CGFloat
    var color: NSColor = .labelColor
    var bold = false
    var weight: NSFont.Weight = .semibold
    var italic = false
    var code = false
    var strike = false
    var underline = false
    var mark = false
    var kbd = false
    var script = 0 // 1 superscript, -1 subscript
    var link: URL?
}

private struct BlockStyle {
    var indent: CGFloat = 0
    var textBlocks: [NSTextBlock] = []
    var color: NSColor = .labelColor
    var listDepth = 0
    var inQuote = false
}

let subtleFill = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(white: 1, alpha: 0.075)
        : NSColor(white: 0, alpha: 0.045)
}

private let stripeFill = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(white: 1, alpha: 0.035)
        : NSColor(white: 0, alpha: 0.022)
}

/// A text block that draws a rounded background, an optional bar on its leading edge and an optional caption in
/// the top trailing corner (the language of a code block). The caption is drawn, not part of the text, so it is
/// never selected or copied.
final class DecoratedBlock: NSTextBlock {
    var fill: NSColor?
    var bar: NSColor?
    var barWidth: CGFloat = 3
    var radius: CGFloat = 6
    var caption: String?
    var captionFont = NSFont.systemFont(ofSize: 10, weight: .medium)

    override init() {
        super.init()
        setContentWidth(100, type: .percentageValueType)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView?, characterRange charRange: NSRange,
                                 layoutManager: NSLayoutManager) {
        // The frame includes the margins; the decoration covers only padding and content.
        let rect = NSRect(x: frameRect.minX + width(for: .margin, edge: .minX),
                          y: frameRect.minY + width(for: .margin, edge: .minY),
                          width: frameRect.width - width(for: .margin, edge: .minX) - width(for: .margin, edge: .maxX),
                          height: frameRect.height - width(for: .margin, edge: .minY) - width(for: .margin, edge: .maxY))
        if let fill {
            fill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }
        if let bar {
            bar.setFill()
            let barRect = NSRect(x: rect.minX, y: rect.minY, width: barWidth, height: rect.height)
            NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
        if let caption, !caption.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: captionFont, .foregroundColor: NSColor.tertiaryLabelColor, .kern: 0.6]
            let text = NSAttributedString(string: caption.uppercased(), attributes: attrs)
            let size = text.size()
            let padding = width(for: .padding, edge: .maxX)
            text.draw(at: NSPoint(x: rect.maxX - size.width - max(8, padding - 2), y: rect.minY + 6))
        }
    }
}

// MARK: - HTML

/// A forgiving tokenizer for the HTML that turns up in notes (Joplin itself writes `<img width>` for resized
/// images). It is not a full parser: unknown tags are dropped and their text kept.
enum HTMLTokens {
    enum Piece: Equatable {
        case text(String)
        case tag(name: String, closing: Bool, attributes: [String: String])
    }

    private static let tag = try! NSRegularExpression(
        pattern: #"<!--[\s\S]*?-->|<(/?)([a-zA-Z][a-zA-Z0-9]*)((?:\s+[^\s>/=]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'>]+))?)*)\s*/?>"#)
    private static let attribute = try! NSRegularExpression(
        pattern: #"([^\s>/=]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?"#)

    static func pieces(_ html: String) -> [Piece] {
        let ns = html as NSString
        var out: [Piece] = []
        var last = 0
        for m in tag.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last {
                out.append(.text(decode(ns.substring(with: NSRange(location: last, length: m.range.location - last)))))
            }
            last = m.range.location + m.range.length
            guard m.range(at: 2).location != NSNotFound else { continue } // comment
            let name = ns.substring(with: m.range(at: 2)).lowercased()
            let closing = m.range(at: 1).length > 0
            var attributes: [String: String] = [:]
            if m.range(at: 3).length > 0 {
                let attrText = ns.substring(with: m.range(at: 3))
                let a = attrText as NSString
                for am in attribute.matches(in: attrText, range: NSRange(location: 0, length: a.length)) {
                    let key = a.substring(with: am.range(at: 1)).lowercased()
                    let value = (2...4).lazy.map { am.range(at: $0) }.first { $0.location != NSNotFound }
                        .map { a.substring(with: $0) } ?? ""
                    attributes[key] = decode(value)
                }
            }
            out.append(.tag(name: name, closing: closing, attributes: attributes))
        }
        if last < ns.length { out.append(.text(decode(ns.substring(from: last)))) }
        return out
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "copy": "©", "reg": "®",
        "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–", "laquo": "«", "raquo": "»", "middot": "·",
        "times": "×", "rarr": "→", "larr": "←", "bull": "•", "deg": "°", "euro": "€",
    ]
    private static let entity = try! NSRegularExpression(pattern: "&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z]+);")

    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in entity.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let name = ns.substring(with: m.range(at: 1))
            var replacement: String?
            if name.hasPrefix("#") {
                let digits = name.dropFirst()
                let value = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                replacement = value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = named[name.lowercased()]
            }
            out += replacement ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    static let blockTags: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "ul", "ol", "tr", "table", "blockquote", "pre",
        "details", "summary", "section", "article", "header", "footer", "figure", "figcaption", "dl", "dt", "dd", "hr",
        "center", "thead", "tbody",
    ]
}

/// Inline formatting opened by HTML tags, applied on top of the Markdown style.
private struct HTMLState {
    var counts: [String: Int] = [:]
    var links: [URL?] = []

    mutating func apply(_ name: String, closing: Bool, attributes: [String: String], link: (String?) -> URL?) {
        let key: String
        switch name {
        case "b", "strong": key = "b"
        case "i", "em", "cite", "var", "dfn": key = "i"
        case "u", "ins": key = "u"
        case "s", "del", "strike": key = "s"
        case "code", "tt", "samp": key = "code"
        case "kbd": key = "kbd"
        case "mark": key = "mark"
        case "sup": key = "sup"
        case "sub": key = "sub"
        case "small": key = "small"
        case "a":
            if closing { _ = links.popLast() } else { links.append(link(attributes["href"])) }
            return
        default: return
        }
        counts[key, default: 0] += closing ? -1 : 1
        if counts[key]! <= 0 { counts[key] = nil }
    }

    func style(_ s: InlineStyle) -> InlineStyle {
        guard !counts.isEmpty || !links.isEmpty else { return s }
        var r = s
        if counts["b"] != nil { r.bold = true }
        if counts["i"] != nil { r.italic = true }
        if counts["u"] != nil { r.underline = true }
        if counts["s"] != nil { r.strike = true }
        if counts["code"] != nil { r.code = true }
        if counts["kbd"] != nil { r.kbd = true }
        if counts["mark"] != nil { r.mark = true }
        if counts["sup"] != nil { r.script = 1 }
        if counts["sub"] != nil { r.script = -1 }
        if counts["small"] != nil { r.size *= 0.85 }
        if let link = links.last, let link { r.link = link }
        return r
    }
}

// MARK: - Builder

private final class AttributedBuilder {
    let renderer: MarkdownRenderer
    let maxImageWidth: CGFloat
    let formulas: [MathExtractor.Formula]
    let out = NSMutableAttributedString()
    private var pendingPrefix: NSAttributedString?
    private var pendingIndent: (first: CGFloat, head: CGFloat, tabs: [NSTextTab])?
    private var html = HTMLState()
    private var headings: [(level: Int, title: String, slug: String)] = []
    private var headingIndex = 0

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let highlight = try! NSRegularExpression(pattern: "==(?=\\S)(.+?)(?<=\\S)==")

    init(renderer: MarkdownRenderer, maxImageWidth: CGFloat, formulas: [MathExtractor.Formula]) {
        self.renderer = renderer
        self.maxImageWidth = maxImageWidth
        self.formulas = formulas
    }

    private var typography: Typography { renderer.typography }
    private var base: CGFloat { typography.size }

    /// Headings in document order with unique slugs, for anchors and `[toc]`.
    func collectHeadings(_ document: Document) {
        var seen: [String: Int] = [:]
        func walk(_ m: Markup) {
            if let h = m as? Heading {
                let title = Self.plainText(h)
                var slug = MarkdownRenderer.slug(title)
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

    /// Text of inline markup without Markdown syntax (`plainText` keeps the backticks of code spans).
    static func plainText(_ m: Markup) -> String {
        switch m {
        case let t as Markdown.Text: return t.string
        case let c as InlineCode: return c.code
        case is SoftBreak, is LineBreak: return " "
        default: return m.children.map(plainText).joined()
        }
    }

    // MARK: Attributes

    private func font(_ s: InlineStyle) -> NSFont {
        let size = s.script != 0 ? s.size * 0.75 : s.size
        let weight: NSFont.Weight = s.bold ? s.weight : .regular
        if s.code || s.kbd {
            let factor: CGFloat = typography.family.isMonospaced ? 1 : 0.9
            return typography.codeFamily.font(size: size * factor, weight: weight, italic: s.italic)
        }
        return typography.family.font(size: size, weight: weight, italic: s.italic)
    }

    private func attrs(_ s: InlineStyle, codeBackground: Bool = true) -> [NSAttributedString.Key: Any] {
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

    private func paragraphStyle(_ b: BlockStyle, first: CGFloat? = nil, head: CGFloat? = nil, before: CGFloat = 0,
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

    private func append(_ string: String, _ s: InlineStyle) {
        out.append(NSAttributedString(string: string, attributes: attrs(html.style(s))))
    }

    // MARK: Blocks

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
            if language == "math" || language == "latex" || language == "katex" || language == "tex" {
                displayMath(c.code, b)
            } else if language == "mermaid", let image = MarkdownRenderer.mermaid(c.code, fontSize: base * 0.9) {
                diagram(image, card: true, b)
            } else if language == "drawio", let image = Drawio.image(xml: c.code) {
                diagram(image, card: false, b)
            } else {
                codeBlock(c.code, language: c.language, b)
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

    private func beginParagraph(_ b: BlockStyle) -> (start: Int, first: CGFloat, head: CGFloat, tabs: [NSTextTab]?) {
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
        // Line spacing is a multiple of the line height: lines with large images would get huge gaps.
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
        // Line separators keep the whole block in one paragraph (one box).
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

    /// A diagram centred in its own paragraph, optionally on a card like code blocks.
    private func diagram(_ image: NSImage, card: Bool, _ b: BlockStyle) {
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

    // MARK: Quotes and alerts

    private static let alerts: [String: (title: String, symbol: String, color: NSColor)] = [
        "NOTE": ("Note", "info.circle", .systemBlue),
        "TIP": ("Tip", "lightbulb", .systemGreen),
        "IMPORTANT": ("Important", "exclamationmark.bubble", .systemPurple),
        "WARNING": ("Warning", "exclamationmark.triangle", .systemOrange),
        "CAUTION": ("Caution", "exclamationmark.octagon", .systemRed),
    ]

    /// The alert kind of a `> [!NOTE]` quote and the remaining inlines of its first paragraph.
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
            // Title line: symbol and name in the alert colour.
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
        // Content of the quote ends with its last paragraph's spacing inside the box; trim it so the bar ends
        // with the text.
        trimLastParagraphSpacing(to: 0)
        spaceAfterBlock(b)
    }

    /// Space above a boxed block (code, quote, table): TextKit ignores the spacing of the paragraph before a text
    /// block, so the box gets a top margin unless it starts the note or a list item.
    private func spaceBeforeBlock(_ block: NSTextBlock) {
        guard out.length > 0, pendingPrefix == nil else { return }
        block.setWidth((base * 0.6).rounded(), type: .absoluteValueType, for: .margin, edge: .minY)
    }

    /// Adds a spacer paragraph after a boxed block so the next paragraph does not touch it.
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

    // MARK: Lists

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
                    if let line = item.range?.lowerBound.line { extra[.jnCheckbox] = line }
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
                    // Blocks such as code cannot carry the marker inline: put it on its own line first.
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
        // Space after the outermost list.
        if b.listDepth == 0 { trimLastParagraphSpacing(to: (base * 0.8).rounded()) }
    }

    // MARK: Tables

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
                if let cell, cell.colspan == 0 || cell.rowspan == 0 { continue } // covered by a spanning cell
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

    // MARK: Table of contents

    private func isTOC(_ p: Paragraph) -> Bool {
        let text = p.plainText.trimmingCharacters(in: .whitespaces).lowercased()
        return text == "[toc]" || text == "[[toc]]" || text == "${toc}"
    }

    private func tableOfContents(_ b: BlockStyle) {
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

    // MARK: HTML

    private func htmlBlock(_ rawHTML: String, _ b: BlockStyle) {
        let pieces = HTMLTokens.pieces(rawHTML)
        var preDepth = 0
        let p = beginParagraph(b)
        let style = InlineStyle(size: base, color: b.color)
        var align: NSTextAlignment = .natural
        func lineBreak() {
            guard out.length > p.start, !out.string.hasSuffix("\u{2028}") else { return }
            append("\u{2028}", style)
        }
        for piece in pieces {
            switch piece {
            case .text(var text):
                if preDepth == 0 {
                    text = text.replacingOccurrences(of: "[ \\t\\r\\n]+", with: " ", options: .regularExpression)
                    if out.length == p.start || out.string.hasSuffix("\u{2028}") {
                        text = String(text.drop { $0 == " " })
                    }
                } else {
                    text = text.replacingOccurrences(of: "\n", with: "\u{2028}")
                }
                if !text.isEmpty {
                    var s = style
                    if preDepth > 0 { s.code = true }
                    append(text, s)
                }
            case .tag(let name, let closing, let attributes):
                switch name {
                case "br":
                    append("\u{2028}", style)
                case "img":
                    if !closing { htmlImage(attributes, style) }
                case "pre":
                    preDepth += closing ? -1 : 1
                    lineBreak()
                case "hr":
                    lineBreak()
                case "li" where !closing:
                    lineBreak()
                    append("•  ", InlineStyle(size: base, color: .tertiaryLabelColor))
                case "td", "th":
                    if !closing, out.length > p.start, !out.string.hasSuffix("\u{2028}") { append("  ", style) }
                    if name == "th" { html.apply("b", closing: closing, attributes: [:]) { _ in nil } }
                default:
                    if !closing, name == "center" || attributes["align"]?.lowercased() == "center" { align = .center }
                    if HTMLTokens.blockTags.contains(name) {
                        lineBreak()
                    } else {
                        html.apply(name, closing: closing, attributes: attributes) { [unowned self] in self.linkURL($0) }
                    }
                }
            }
        }
        html = HTMLState()
        // Trim trailing breaks and whitespace.
        while out.length > p.start, let last = out.string.unicodeScalars.last,
              last == "\u{2028}" || last == " " {
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }
        guard out.length > p.start else { return }
        out.append(NSAttributedString(string: "\n", attributes: attrs(style)))
        out.addAttribute(.paragraphStyle, value: paragraphStyle(b, first: p.first, head: p.head, tabs: p.tabs, align: align),
                         range: NSRange(location: p.start, length: out.length - p.start))
    }

    private func htmlImage(_ attributes: [String: String], _ s: InlineStyle) {
        let src = attributes["src"] ?? ""
        let alt = attributes["alt"] ?? ""
        let width = attributes["width"].flatMap { Double($0.replacingOccurrences(of: "px", with: "")) }.map { CGFloat($0) }
        image(source: src, alt: alt, width: width, s)
    }

    // MARK: Inlines

    private func inline(_ m: Markup, _ s: InlineStyle) {
        switch m {
        case let t as Markdown.Text:
            text(t.string, s)
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
            append(restoreMath(c.code), s2)
        case let l as Markdown.Link:
            var s2 = s
            s2.link = linkURL(l.destination)
            if let dest = l.destination, dest.hasPrefix(":/"), let (res, _) = resource(dest) {
                if let icon = symbolAttachment("paperclip", color: .linkColor, font: font(s2)) {
                    let a = NSMutableAttributedString(attributedString: icon)
                    if let link = s2.link { a.addAttribute(.link, value: link, range: NSRange(location: 0, length: a.length)) }
                    out.append(a)
                    append("\u{2009}", s2)
                }
                if l.childCount == 0 { append(res.displayName, s2) }
            }
            for c in l.children { inline(c, s2) }
            if l.childCount == 0, l.destination?.hasPrefix(":/") != true { append(l.destination ?? "", s2) }
        case let img as Markdown.Image:
            image(source: img.source ?? "", alt: img.plainText, width: nil, s)
        case is SoftBreak:
            append(" ", s)
        case is LineBreak:
            append("\u{2028}", s)
        case let h as InlineHTML:
            inlineHTML(h.rawHTML, s)
        default:
            if m.childCount > 0 {
                for c in m.children { inline(c, s) }
            } else {
                append(m.format(), s)
            }
        }
    }

    private func inlineHTML(_ raw: String, _ s: InlineStyle) {
        for piece in HTMLTokens.pieces(raw) {
            switch piece {
            case .text(let t):
                append(t, s)
            case .tag(let name, let closing, let attributes):
                if name == "br" {
                    append("\u{2028}", s)
                } else if name == "img" {
                    if !closing { htmlImage(attributes, s) }
                } else {
                    html.apply(name, closing: closing, attributes: attributes) { [unowned self] in self.linkURL($0) }
                }
            }
        }
    }

    /// Text with math placeholders, `==highlights==` and bare links.
    private func text(_ string: String, _ s: InlineStyle) {
        guard string.contains(MathExtractor.open) else {
            highlighted(string, s)
            return
        }
        let ns = string as NSString
        var last = 0
        for m in MathExtractor.placeholder.matches(in: string, range: NSRange(location: 0, length: ns.length)) {
            highlighted(ns.substring(with: NSRange(location: last, length: m.range.location - last)), s)
            if let index = Int(ns.substring(with: m.range(at: 1))), formulas.indices.contains(index) {
                let f = formulas[index]
                out.append(MathRenderer(size: s.size, color: s.color).render(f.tex))
            }
            last = m.range.location + m.range.length
        }
        highlighted(ns.substring(from: last), s)
    }

    private func highlighted(_ string: String, _ s: InlineStyle) {
        guard !string.isEmpty else { return }
        guard string.contains("==") else {
            linkified(string, s)
            return
        }
        let ns = string as NSString
        var last = 0
        for m in Self.highlight.matches(in: string, range: NSRange(location: 0, length: ns.length)) {
            linkified(ns.substring(with: NSRange(location: last, length: m.range.location - last)), s)
            var s2 = s
            s2.mark = true
            linkified(ns.substring(with: m.range(at: 1)), s2)
            last = m.range.location + m.range.length
        }
        linkified(ns.substring(from: last), s)
    }

    private func linkified(_ string: String, _ s: InlineStyle) {
        guard !string.isEmpty else { return }
        guard s.link == nil, html.links.isEmpty, let detector = Self.linkDetector,
              string.contains(".") || string.contains(":") else {
            append(string, s)
            return
        }
        let ns = string as NSString
        var last = 0
        for m in detector.matches(in: string, range: NSRange(location: 0, length: ns.length)) {
            guard let url = m.url, url.scheme == "http" || url.scheme == "https" || url.scheme == "mailto" else { continue }
            // Only what reads as a link: not bare names such as "Draw.io" or "file.md".
            let found = ns.substring(with: m.range).lowercased()
            guard found.hasPrefix("http://") || found.hasPrefix("https://") || found.hasPrefix("www.") || url.scheme == "mailto"
            else { continue }
            append(ns.substring(with: NSRange(location: last, length: m.range.location - last)), s)
            var s2 = s
            s2.link = url
            append(ns.substring(with: m.range), s2)
            last = m.range.location + m.range.length
        }
        append(ns.substring(from: last), s)
    }

    /// Puts formulas back into code spans, where they must stay literal.
    private func restoreMath(_ code: String) -> String {
        guard code.contains(MathExtractor.open) else { return code }
        let ns = code as NSString
        var outString = ""
        var last = 0
        for m in MathExtractor.placeholder.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
            outString += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            if let index = Int(ns.substring(with: m.range(at: 1))), formulas.indices.contains(index) {
                let f = formulas[index]
                outString += f.display ? "$$\(f.tex)$$" : "$\(f.tex)$"
            }
            last = m.range.location + m.range.length
        }
        return outString + ns.substring(from: last)
    }

    private func resource(_ dest: String) -> (Resource, URL)? {
        let id = String(dest.dropFirst(2).prefix(32))
        return renderer.resolveResource(id)
    }

    func linkURL(_ dest: String?) -> URL? {
        guard let d = dest?.trimmingCharacters(in: .whitespaces), !d.isEmpty else { return nil }
        if d.hasPrefix(":/") { return URL(string: "joplinitem://\(d.dropFirst(2).prefix(32))") }
        return URL(string: d) ?? d.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).flatMap(URL.init(string:))
    }

    // MARK: Images and symbols

    /// An SF Symbol sized and centred on the text of `font`.
    private func symbolAttachment(_ name: String, color: NSColor, font: NSFont) -> NSAttributedString? {
        symbolAttachment(name, colors: [color], font: font)
    }

    private func symbolAttachment(_ name: String, colors: [NSColor], font: NSFont) -> NSAttributedString? {
        let config = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
            .applying(.init(paletteColors: colors))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
            return nil
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        let size = image.size
        attachment.bounds = CGRect(x: 0, y: ((font.capHeight - size.height) / 2).rounded(), width: size.width, height: size.height)
        return NSAttributedString(attachment: attachment)
    }

    private func imageAttachment(_ image: NSImage, width requested: CGFloat?, link: URL?, rounded: Bool = true) {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        let target = min(requested ?? size.width, maxImageWidth)
        let scale = target / size.width
        let bounds = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
        let attachment = NSTextAttachment()
        attachment.image = rounded ? Self.rounded(image, size: bounds.size) : image
        attachment.bounds = bounds
        let a = NSMutableAttributedString(attachment: attachment)
        if let link { a.addAttribute(.link, value: link, range: NSRange(location: 0, length: a.length)) }
        out.append(a)
    }

    /// Draws `image` with softly rounded corners, lazily at the resolution of the screen.
    private static func rounded(_ image: NSImage, size: CGSize) -> NSImage {
        guard size.width >= 24, size.height >= 24 else { return image }
        let radius = min(6, size.width / 8, size.height / 8)
        return NSImage(size: size, flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
            image.draw(in: rect)
            return true
        }
    }

    private func image(source src: String, alt: String, width: CGFloat?, _ s: InlineStyle) {
        if src.hasPrefix(":/"), let (res, url) = resource(src) {
            let itemURL = URL(string: "joplinitem://\(res.id)")
            if let diagram = MarkdownRenderer.drawio(res, url: url) {
                imageAttachment(diagram, width: width, link: itemURL, rounded: false)
                return
            }
            if res.isImage, let image = MarkdownRenderer.loadImage(url) {
                imageAttachment(image, width: width, link: itemURL)
                return
            }
            var s2 = s
            s2.link = itemURL
            append("📎 \(alt.isEmpty ? res.displayName : alt)", s2)
            return
        }
        let url = linkURL(src)
        if let url, let image = url.isFileURL ? MarkdownRenderer.loadImage(url) : renderer.remoteImage?(url) {
            imageAttachment(image, width: width, link: url)
            return
        }
        var s2 = s
        s2.link = url
        s2.color = .secondaryLabelColor
        append("🖼 \(alt.isEmpty ? (src.isEmpty ? "image" : src) : alt)", s2)
    }
}
