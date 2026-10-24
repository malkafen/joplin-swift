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

    enum Head: UInt8 {
        case none, backticks, tildes, display

        var fence: String? {
            switch self {
            case .backticks: return "```"
            case .tildes: return "~~~"
            default: return nil
            }
        }
    }

    static func extract(_ markdown: String) -> (String, [Formula]) {
        guard markdown.quickContains("$") else { return (markdown, []) }
        var formulas: [Formula] = []
        let original = markdown.components(separatedBy: "\n")
        var lines = original
        func token(_ tex: String, display: Bool) -> String {
            formulas.append(Formula(tex: tex, display: display))
            return "\(open)\(formulas.count - 1)\(close)"
        }
        scan(original.map(head), display: { i, end in
            let tex = original[(i + 1)..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let indent = String(original[i].prefix { $0 == " " || $0 == "\t" })
            lines[i] = indent + token(tex, display: true)
            for j in (i + 1)...end { lines[j] = "" }
        }, inline: { i in
            lines[i] = replaceInline(lines[i], token: token)
        })
        return (lines.joined(separator: "\n"), formulas)
    }

    static func openFence(in text: NSString, range: NSRange) -> String? {
        guard range.length > 0 else { return nil }
        var units = [unichar](repeating: 0, count: range.length)
        text.getCharacters(&units, range: range)
        var heads: [Head] = []
        var start = 0
        while start <= units.count {
            var end = start
            while end < units.count, units[end] != 10 { end += 1 }
            heads.append(head(units, start, end) ?? head(text.substring(with: NSRange(location: range.location + start, length: end - start))))
            start = end + 1
        }
        return scan(heads)
    }

    @discardableResult
    private static func scan(_ heads: [Head], display: (Int, Int) -> Void = { _, _ in }, inline: (Int) -> Void = { _ in }) -> String? {
        var fence: String?
        var i = 0
        while i < heads.count {
            let line = heads[i]
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
            if line == .display, let end = heads[(i + 1)...].firstIndex(of: .display) {
                display(i, end)
                i = end + 1
                continue
            }
            inline(i)
            i += 1
        }
        return fence
    }

    static func head<Line: StringProtocol>(_ line: Line) -> Head {
        var bytes = line.utf8.makeIterator()
        var b = bytes.next()
        while b == 32 || b == 9 { b = bytes.next() }
        guard let first = b, first == 96 || first == 126 || first == 36 || first >= 0x80 else { return .none }
        guard first < 0x80 else { return slowHead(line) }
        let second = bytes.next(), third = bytes.next()
        if first != 36 {
            guard second == first, third == first else { return .none }
            if let next = bytes.next(), next >= 0x80 { return slowHead(line) }
            return first == 96 ? .backticks : .tildes
        }
        guard second == 36 else { return .none }
        var rest = third
        while let c = rest {
            if c >= 0x80 { return slowHead(line) }
            if c != 32, c != 9 { return .none }
            rest = bytes.next()
        }
        return .display
    }

    private static func head(_ units: [unichar], _ start: Int, _ end: Int) -> Head? {
        var i = start
        while i < end, units[i] == 32 || units[i] == 9 { i += 1 }
        guard i < end else { return Head.none }
        let first = units[i]
        guard first == 96 || first == 126 || first == 36 || first >= 0x80 else { return Head.none }
        guard first < 0x80 else { return nil }
        let second = i + 1 < end ? units[i + 1] : nil, third = i + 2 < end ? units[i + 2] : nil
        if first != 36 {
            guard second == first, third == first else { return Head.none }
            if i + 3 < end, units[i + 3] >= 0x80 { return nil }
            return first == 96 ? .backticks : .tildes
        }
        guard second == 36 else { return Head.none }
        var j = i + 2
        while j < end {
            if units[j] >= 0x80 { return nil }
            if units[j] != 32, units[j] != 9 { return Head.none }
            j += 1
        }
        return .display
    }

    private static func slowHead<Line: StringProtocol>(_ line: Line) -> Head {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") { return .backticks }
        if trimmed.hasPrefix("~~~") { return .tildes }
        return trimmed == "$$" ? .display : .none
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
