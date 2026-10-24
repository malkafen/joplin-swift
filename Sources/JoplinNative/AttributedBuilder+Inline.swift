import AppKit
import JoplinCore
import Markdown

extension AttributedBuilder {
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let highlight = try! NSRegularExpression(pattern: "==(?=\\S)(.+?)(?<=\\S)==")

    func inline(_ m: Markup, _ s: InlineStyle) {
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

    func text(_ string: String, _ s: InlineStyle) {
        guard string.quickContains(MathExtractor.openMark) else {
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
        guard string.quickContains("==") else {
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
        guard s.link == nil, html.links.isEmpty, let detector = Self.linkDetector, Self.mayHoldLink(string) else {
            append(string, s)
            return
        }
        let ns = string as NSString
        var last = 0
        for m in detector.matches(in: string, range: NSRange(location: 0, length: ns.length)) {
            guard let url = m.url, url.scheme == "http" || url.scheme == "https" || url.scheme == "mailto" else { continue }
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

    private static func mayHoldLink(_ string: String) -> Bool {
        var string = string
        return string.withUTF8 { b in
            for i in b.indices {
                let c = b[i] | 0x20
                if b[i] == UInt8(ascii: "@") { return true }
                guard i + 3 < b.count else { continue }
                if c == UInt8(ascii: "h"), b[i + 1] | 0x20 == UInt8(ascii: "t"), b[i + 2] | 0x20 == UInt8(ascii: "t"),
                   b[i + 3] | 0x20 == UInt8(ascii: "p") { return true }
                if c == UInt8(ascii: "w"), b[i + 1] | 0x20 == UInt8(ascii: "w"), b[i + 2] | 0x20 == UInt8(ascii: "w"),
                   b[i + 3] == UInt8(ascii: ".") { return true }
            }
            return false
        }
    }

    func restoreMath(_ code: String) -> String {
        guard code.quickContains(MathExtractor.openMark) else { return code }
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

    func symbolAttachment(_ name: String, color: NSColor, font: NSFont) -> NSAttributedString? {
        symbolAttachment(name, colors: [color], font: font)
    }

    func symbolAttachment(_ name: String, colors: [NSColor], font: NSFont) -> NSAttributedString? {
        let key = "\(name)|\(colors)|\(font.fontName)|\(font.pointSize)"
        if let cached = symbols[key] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
            .applying(.init(paletteColors: colors))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
            return nil
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        let size = image.size
        attachment.bounds = CGRect(x: 0, y: ((font.capHeight - size.height) / 2).rounded(), width: size.width, height: size.height)
        let symbol = NSAttributedString(attachment: attachment)
        symbols[key] = symbol
        return symbol
    }

    private func imageAttachment(_ image: NSImage, width requested: CGFloat?, link: URL?, rounded: Bool = true) {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        sizedToWidth = true
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

    private static func rounded(_ image: NSImage, size: CGSize) -> NSImage {
        guard size.width >= 24, size.height >= 24 else { return image }
        let radius = min(6, size.width / 8, size.height / 8)
        return NSImage(size: size, flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
            image.draw(in: rect)
            return true
        }
    }

    func image(source src: String, alt: String, width: CGFloat?, _ s: InlineStyle) {
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
