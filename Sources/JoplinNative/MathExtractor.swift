import Foundation

enum MathExtractor {
    static let open: Character = "\u{E000}"
    static let close: Character = "\u{E001}"
    static let openMark = String(open)
    static let placeholder = try! NSRegularExpression(pattern: "\u{E000}(\\d+)\u{E001}")

    struct Formula: Equatable {
        var tex: String
        var display: Bool
    }

    private static let inline = try! NSRegularExpression(
        pattern: #"(?<![\\$\w])\$\$(?=\S)(.+?)(?<=\S)\$\$|(?<![\\$\w])\$(?=[^\s$])([^$\n]*?[^\s\\$])\$(?![\w$])"#)

    static func extract(_ markdown: String) -> (String, [Formula]) {
        guard markdown.quickContains("$") else { return (markdown, []) }
        var formulas: [Formula] = []
        let original = markdown.components(separatedBy: "\n")
        var lines = original
        func token(_ tex: String, display: Bool) -> String {
            formulas.append(Formula(tex: tex, display: display))
            return "\(open)\(formulas.count - 1)\(close)"
        }
        scan(original, display: { i, end in
            let tex = original[(i + 1)..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let indent = String(original[i].prefix { $0 == " " || $0 == "\t" })
            lines[i] = indent + token(tex, display: true)
            for j in (i + 1)...end { lines[j] = "" }
        }, inline: { i in
            lines[i] = replaceInline(lines[i], token: token)
        })
        return (lines.joined(separator: "\n"), formulas)
    }

    static func openFence(after text: String, from fence: String? = nil) -> String? {
        scan(text.utf8.split(separator: 10, omittingEmptySubsequences: false).map { Substring($0) }, from: fence)
    }

    @discardableResult
    private static func scan<Line: StringProtocol>(_ lines: [Line], from fence: String? = nil, display: (Int, Int) -> Void = { _, _ in },
                                                   inline: (Int) -> Void = { _ in }) -> String? {
        var fence = fence
        var i = 0
        while i < lines.count {
            let line = head(lines[i])
            if let f = fence {
                if line.fence == f { fence = nil }
                i += 1
                continue
            }
            if let f = line.fence {
                fence = f
                i += 1
                continue
            }
            if line.display, let end = lines[(i + 1)...].firstIndex(where: { head($0).display }) {
                display(i, end)
                i = end + 1
                continue
            }
            inline(i)
            i += 1
        }
        return fence
    }

    static func head<Line: StringProtocol>(_ line: Line) -> (fence: String?, display: Bool) {
        var bytes = line.utf8.makeIterator()
        var b = bytes.next()
        while b == 32 || b == 9 { b = bytes.next() }
        guard let first = b, first == 96 || first == 126 || first == 36 || first >= 0x80 else { return (nil, false) }
        guard first < 0x80 else { return slowHead(line) }
        let second = bytes.next(), third = bytes.next()
        if first != 36 {
            guard second == first, third == first else { return (nil, false) }
            if let next = bytes.next(), next >= 0x80 { return slowHead(line) }
            return (first == 96 ? "```" : "~~~", false)
        }
        guard second == 36 else { return (nil, false) }
        var rest = third
        while let c = rest {
            if c >= 0x80 { return slowHead(line) }
            if c != 32, c != 9 { return (nil, false) }
            rest = bytes.next()
        }
        return (nil, true)
    }

    private static func slowHead<Line: StringProtocol>(_ line: Line) -> (fence: String?, display: Bool) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let fence = trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") ? String(trimmed.prefix(3)) : nil
        return (fence, trimmed == "$$")
    }

    private static func replaceInline(_ line: String, token: (String, Bool) -> String) -> String {
        guard line.quickContains("$") else { return line }
        var out = ""
        var rest = Substring(line)
        while let tick = rest.firstIndex(of: "`") {
            out += replaceOutsideCode(String(rest[..<tick]), token: token)
            let run = rest[tick...].prefix { $0 == "`" }
            let afterRun = rest.index(tick, offsetBy: run.count)
            if let close = rest[afterRun...].range(of: String(run)) {
                out += rest[tick..<close.upperBound]
                rest = rest[close.upperBound...]
            } else {
                out += rest[tick...]
                rest = ""
            }
        }
        return out + replaceOutsideCode(String(rest), token: token)
    }

    private static func replaceOutsideCode(_ s: String, token: (String, Bool) -> String) -> String {
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in inline.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let display = m.range(at: 1).location != NSNotFound
            out += token(ns.substring(with: m.range(at: display ? 1 : 2)), display)
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }
}
