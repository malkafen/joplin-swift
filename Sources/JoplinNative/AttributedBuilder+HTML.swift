import AppKit

extension AttributedBuilder {
    func htmlBlock(_ rawHTML: String, _ b: BlockStyle) {
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

    func inlineHTML(_ raw: String, _ s: InlineStyle) {
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
}
