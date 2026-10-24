import Foundation

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
            guard m.range(at: 2).location != NSNotFound else { continue }
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

struct HTMLState {
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
