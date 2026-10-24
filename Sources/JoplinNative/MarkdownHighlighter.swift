import AppKit

final class MarkdownHighlighter {
    private(set) var baseAttributes: [NSAttributedString.Key: Any] = [:]
    private var typography = Typography()
    private var baseFont = NSFont.systemFont(ofSize: 14)
    private var boldFont = NSFont.boldSystemFont(ofSize: 14)
    private var italicFont = NSFont.systemFont(ofSize: 14)
    private var codeFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var headingFonts: [NSFont] = []

    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.anchorsMatchLines]) }

    private let heading = re("^(#{1,6})[ \\t].*$")
    private let bold = re("(\\*\\*|__)(?=\\S)[^\\n]*?\\S\\1")
    private let italic = re("(?<![*\\w])\\*(?=[^\\s*])[^*\\n]*?[^\\s*]\\*(?!\\*)|(?<![_\\w])_(?=[^\\s_])[^_\\n]*?[^\\s_]_(?![_\\w])")
    private let strike = re("~~[^~\\n]+~~")
    private let mark = re("==(?=\\S)[^=\\n]+?(?<=\\S)==")
    private let inlineCode = re("`[^`\\n]+`")
    private let link = re("(!?\\[)([^\\]\\n]*)(\\]\\([^)\\n]*\\))|<https?://[^>\\s]+>|(?<![(<\\w])https?://[^\\s)>]+")
    private let listMarker = re("^[ \\t]*([-*+]|\\d+[.)])[ \\t]")
    private let checkbox = re("^[ \\t]*[-*+][ \\t]\\[[ xX]\\]")
    private let checkedItem = re("^[ \\t]*[-*+][ \\t]\\[[xX]\\][ \\t](.*)$")
    private let quote = re("^[ \\t]*>.*$")
    private let rule = re("^[ \\t]*([-*_])([ \\t]*\\1){2,}[ \\t]*$")
    private let fence = re("^[ \\t]*(```|~~~)([^\\n]*)\\n([\\s\\S]*?)(^[ \\t]*\\1[ \\t]*$|\\z)")
    private let math = re("\\$\\$[\\s\\S]+?\\$\\$|(?<![\\\\$\\w])\\$(?=[^\\s$])[^$\\n]*?[^\\s\\\\$]\\$(?![\\w$])")
    private let html = re("</?[a-zA-Z][^>\\n]*>")

    func configure(_ typography: Typography) {
        self.typography = typography
        let family = typography.family
        let size = typography.size
        baseFont = family.font(size: size)
        boldFont = family.font(size: size, weight: .bold)
        italicFont = family.font(size: size, italic: true)
        codeFont = typography.code()
        let scales: [CGFloat] = [1.5, 1.3, 1.15, 1.05, 1.0, 1.0]
        headingFonts = scales.map { family.font(size: size * $0, weight: .bold) }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.25
        baseAttributes = [.font: baseFont, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph]
    }

    func configure(fontSize: Double, monospaced: Bool) {
        configure(Typography(family: monospaced ? .monospaced : .system, size: CGFloat(fontSize)))
    }

    init() {
        configure(Typography())
    }

    var radius = 50_000
    var maxBlock = 100_000

    private var blocks: [NSRange] = []
    private var marks = Marks()
    private var highlightedLength: Int?
    private(set) var window = NSRange(location: 0, length: 0)
    private var visible = NSRange(location: 0, length: 0)
    var visibleRange: NSRange { visible }

    func reset(keepingVisible: Bool = false) {
        highlightedLength = nil
        if !keepingVisible { visible = NSRange(location: 0, length: 0) }
    }

    struct Marks: Equatable {
        var lines: [Int] = []
        var fences: [Int] = []
        var dollars: [Int] = []
    }

    private static func isTerminator(_ c: unichar) -> Bool {
        c == 10 || c == 13 || c == 0x85 || c == 0x2028 || c == 0x2029
    }

    static func marks(in ns: NSString, range: NSRange) -> Marks {
        var m = Marks()
        var buffer = [unichar](repeating: 0, count: 65_536)
        var lineStart = range.location
        var lead: Int? = range.location
        var run: unichar = 0, runLength = 0, runEnd = -1
        var runLead: Int?
        func addLine() { if m.lines.last != lineStart { m.lines.append(lineStart) } }
        var p = range.location
        let end = NSMaxRange(range)
        while p < end {
            let n = min(buffer.count, end - p)
            ns.getCharacters(&buffer, range: NSRange(location: p, length: n))
            for k in 0..<n {
                let c = buffer[k], i = p + k
                switch c {
                case 96, 126:
                    if c == run && i == runEnd {
                        runLength += 1
                    } else {
                        run = c
                        runLength = 1
                        runLead = lead
                    }
                    runEnd = i + 1
                    if runLength == 3 {
                        addLine()
                        if let runLead { m.fences.append(runLead) }
                    }
                    lead = nil
                case 36:
                    m.dollars.append(i)
                    addLine()
                    lead = nil
                case 10:
                    lineStart = i + 1
                    lead = i + 1
                case 32, 9:
                    break
                default:
                    lead = isTerminator(c) ? i + 1 : nil
                }
            }
            p += n
        }
        return m
    }

    private static func fenceBlocks(_ ns: NSString, _ fences: [Int]) -> [NSRange] {
        let length = ns.length
        func skipBlanks(_ p: Int) -> Int {
            var p = p
            while p < length, ns.character(at: p) == 32 || ns.character(at: p) == 9 { p += 1 }
            return p
        }
        func close(_ q: Int, _ d: unichar) -> Int? {
            let p = skipBlanks(q)
            guard p + 3 <= length, (0..<3).allSatisfy({ ns.character(at: p + $0) == d }) else { return nil }
            let e = skipBlanks(p + 3)
            return e == length || isTerminator(ns.character(at: e)) ? e : nil
        }
        var result: [NSRange] = []
        var cursor = 0
        var i = 0
        while i < fences.count {
            let s = fences[i]
            i += 1
            guard s >= cursor else { continue }
            let p = skipBlanks(s)
            let d = ns.character(at: p)
            let newline = ns.range(of: "\n", options: .literal, range: NSRange(location: p + 3, length: length - p - 3))
            guard newline.location != NSNotFound else { break }
            var end = length
            var j = lowerBound(fences, NSMaxRange(newline))
            while j < fences.count {
                if let e = close(fences[j], d) {
                    end = e
                    break
                }
                j += 1
            }
            result.append(NSRange(location: s, length: end - s))
            cursor = end
        }
        return result
    }

    private func mathBlocks(_ text: String, _ ns: NSString, _ dollars: [Int]) -> [NSRange] {
        let length = ns.length
        var result: [NSRange] = []
        var i = 0
        while i < dollars.count {
            let p = dollars[i]
            guard let m = math.firstMatch(in: text, options: [.anchored, .withTransparentBounds],
                                          range: NSRange(location: p, length: length - p)) else {
                i += 1
                continue
            }
            if ns.rangeOfCharacter(from: .newlines, range: m.range).location != NSNotFound { result.append(m.range) }
            i = Self.lowerBound(dollars, NSMaxRange(m.range))
        }
        return result
    }

    private func multilineBlocks(in text: String, _ ns: NSString) -> [NSRange] {
        (Self.fenceBlocks(ns, marks.fences) + mathBlocks(text, ns, marks.dollars)).sorted { $0.location < $1.location }
    }

    func referenceBlocks(in text: String) -> [NSRange] {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        let spanning = math.matches(in: text, range: all).map(\.range)
            .filter { ns.rangeOfCharacter(from: .newlines, range: $0).location != NSNotFound }
        return (fence.matches(in: text, range: all).map(\.range) + spanning).sorted { $0.location < $1.location }
    }

    func scannedBlocks(in text: String) -> [NSRange] {
        let ns = text as NSString
        marks = Self.marks(in: ns, range: NSRange(location: 0, length: ns.length))
        return multilineBlocks(in: text, ns)
    }

    private static func lines(around range: NSRange, in ns: NSString) -> NSRange {
        let before = ns.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: range.location))
        let start = before.location == NSNotFound ? 0 : NSMaxRange(before)
        let tail = NSMaxRange(range)
        if range.length > 0 && ns.character(at: tail - 1) == 10 { return NSRange(location: start, length: tail - start) }
        let after = ns.range(of: "\n", range: NSRange(location: tail, length: ns.length - tail))
        let end = after.location == NSNotFound ? ns.length : NSMaxRange(after)
        return NSRange(location: start, length: end - start)
    }

    private static func lowerBound(_ a: [Int], _ value: Int) -> Int {
        var lo = 0, hi = a.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if a[mid] < value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func updateMarks(_ lines: NSRange, delta: Int, _ ns: NSString) -> Bool {
        let fresh = Self.marks(in: ns, range: lines)
        let oldEnd = NSMaxRange(lines) - delta
        func update(_ a: inout [Int], _ new: [Int]) -> Bool {
            let lo = Self.lowerBound(a, lines.location)
            let hi = max(lo, Self.lowerBound(a, oldEnd))
            for i in hi..<a.count { a[i] += delta }
            a.replaceSubrange(lo..<hi, with: new)
            return hi > lo || !new.isEmpty
        }
        _ = update(&marks.fences, fresh.fences)
        _ = update(&marks.dollars, fresh.dollars)
        return update(&marks.lines, fresh.lines)
    }

    private func shifted(_ lines: NSRange, delta: Int, oldLength: Int, newLength: Int) -> [NSRange] {
        let oldEnd = NSMaxRange(lines) - delta
        return blocks.map { b in
            if b.location >= oldEnd { return NSRange(location: b.location + delta, length: b.length) }
            if NSMaxRange(b) == oldLength { return NSRange(location: b.location, length: newLength - b.location) }
            if NSMaxRange(b) <= lines.location { return b }
            return NSRange(location: b.location, length: b.length + delta)
        }
    }

    private static func bounded(_ blocks: [NSRange], in lines: NSRange) -> Bool {
        blocks.contains { NSLocationInRange($0.location, lines) || NSLocationInRange(max($0.location, NSMaxRange($0) - 1), lines) }
    }

    private func grown(_ range: NSRange, _ ns: NSString) -> NSRange {
        var range = range
        var grew = true
        while grew {
            grew = false
            for b in blocks where b.length <= maxBlock && (NSIntersectionRange(b, range).length > 0 || NSLocationInRange(range.location, b)) {
                let union = Self.lines(around: NSUnionRange(range, b), in: ns)
                if union != range {
                    range = union
                    grew = true
                }
            }
        }
        return range
    }

    private func target(_ ns: NSString) -> NSRange {
        let start = max(0, min(visible.location, ns.length) - radius)
        let end = min(ns.length, NSMaxRange(visible) + radius)
        return grown(Self.lines(around: NSRange(location: start, length: max(0, end - start)), in: ns), ns)
    }

    private static func map(_ r: NSRange, edited: NSRange, delta: Int, length: Int) -> NSRange {
        let oldEnd = NSMaxRange(edited) - delta
        func pos(_ p: Int, end: Bool) -> Int {
            if p <= edited.location { return p }
            if p >= oldEnd { return p + delta }
            return end ? NSMaxRange(edited) : edited.location
        }
        let s = min(pos(r.location, end: false), length)
        let e = min(max(pos(NSMaxRange(r), end: true), s), length)
        return NSRange(location: s, length: e - s)
    }

    func highlight(_ storage: NSTextStorage, edited: NSRange? = nil) {
        let ns = storage.mutableString as NSString
        let length = ns.length
        let all = NSRange(location: 0, length: length)
        guard let edited, let previous = highlightedLength else {
            marks = Self.marks(in: ns, range: all)
            blocks = multilineBlocks(in: storage.string, ns)
            highlightedLength = length
            window = target(ns)
            if NSMaxRange(window) < length || window.location > 0 { storage.setAttributes(baseAttributes, range: all) }
            apply(window, to: storage)
            return
        }
        let delta = length - previous
        let location = min(edited.location, length)
        let clamped = NSRange(location: location, length: min(edited.length, length - location))
        let lines = Self.lines(around: NSRange(location: location, length: min(clamped.length + 1, length - location)), in: ns)
        let moved = shifted(lines, delta: delta, oldLength: previous, newLength: length)
        let changed = updateMarks(lines, delta: delta, ns)
        let found = changed ? multilineBlocks(in: storage.string, ns) : moved
        let oldLines = NSRange(location: lines.location, length: max(0, lines.length - delta))
        let restructured = found != moved || changed && (Self.bounded(blocks, in: oldLines) || Self.bounded(found, in: lines))
        blocks = found
        highlightedLength = length
        window = Self.map(window, edited: clamped, delta: delta, length: length)
        visible = Self.map(visible, edited: clamped, delta: delta, length: length)
        let outside = NSMaxRange(lines) < window.location || lines.location > NSMaxRange(window)
        if restructured {
            if outside { storage.setAttributes(baseAttributes, range: lines) }
            let redo = grown(outside ? window : Self.lines(around: NSUnionRange(window, lines), in: ns), ns)
            apply(redo, to: storage)
            window = redo
            return
        }
        let range = grown(lines, ns)
        if NSMaxRange(range) < window.location || range.location > NSMaxRange(window) {
            storage.setAttributes(baseAttributes, range: range)
        } else {
            apply(range, to: storage)
            window = NSUnionRange(window, range)
        }
    }

    func show(_ range: NSRange, in storage: NSTextStorage) {
        let ns = storage.mutableString as NSString
        let location = min(range.location, ns.length)
        visible = NSRange(location: location, length: min(range.length, ns.length - location))
        guard highlightedLength == ns.length else { return }
        let margin = radius / 2
        let start = max(0, location - margin), end = min(ns.length, NSMaxRange(visible) + margin)
        guard start < window.location || end > NSMaxRange(window) else { return }
        let next = target(ns)
        storage.beginEditing()
        if window.location < next.location {
            storage.setAttributes(baseAttributes, range: NSRange(location: window.location, length: min(NSMaxRange(window), next.location) - window.location))
        }
        if NSMaxRange(window) > NSMaxRange(next) {
            let from = max(window.location, NSMaxRange(next))
            storage.setAttributes(baseAttributes, range: NSRange(location: from, length: NSMaxRange(window) - from))
        }
        apply(next, to: storage)
        storage.endEditing()
        window = next
    }

    func restyle(_ storage: NSTextStorage) {
        guard highlightedLength == storage.length else { return highlight(storage) }
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: NSRange(location: 0, length: storage.length))
        apply(window, to: storage)
        storage.endEditing()
    }

    private func apply(_ range: NSRange, to storage: NSTextStorage) {
        guard range.length > 0 else { return }
        let text = storage.string
        let ns = storage.mutableString as NSString
        storage.setAttributes(baseAttributes, range: range)
        let partial = blocks.filter {
            $0.length > maxBlock && NSIntersectionRange($0, range).length > 0 && NSIntersectionRange($0, range) != $0
        }
        var segments: [NSRange] = []
        var from = range.location
        for b in partial {
            if b.location > from { segments.append(NSRange(location: from, length: b.location - from)) }
            from = max(from, NSMaxRange(b))
        }
        if from < NSMaxRange(range) { segments.append(NSRange(location: from, length: NSMaxRange(range) - from)) }
        for segment in segments { applyPatterns(segment, storage, text) }
        for b in partial { applyPartialBlock(b, NSIntersectionRange(b, range), storage, ns) }
    }

    private func applyPatterns(_ range: NSRange, _ storage: NSTextStorage, _ text: String) {
        let syntax = NSColor.tertiaryLabelColor

        func each(_ re: NSRegularExpression, _ body: (NSTextCheckingResult) -> Void) {
            re.enumerateMatches(in: text, range: range) { m, _, _ in if let m { body(m) } }
        }
        func dim(_ r: NSRange, length: Int) {
            guard r.length >= 2 * length else { return }
            storage.addAttribute(.foregroundColor, value: syntax, range: NSRange(location: r.location, length: length))
            storage.addAttribute(.foregroundColor, value: syntax, range: NSRange(location: NSMaxRange(r) - length, length: length))
        }

        each(heading) { m in
            let level = m.range(at: 1).length
            storage.addAttribute(.font, value: self.headingFonts[level - 1], range: m.range)
            storage.addAttribute(.foregroundColor, value: syntax, range: m.range(at: 1))
        }
        each(bold) { m in
            storage.addAttribute(.font, value: self.boldFont, range: m.range)
            dim(m.range, length: 2)
        }
        each(italic) { m in
            storage.addAttribute(.font, value: self.italicFont, range: m.range)
            dim(m.range, length: 1)
        }
        each(strike) { m in
            storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.secondaryLabelColor], range: m.range)
            dim(m.range, length: 2)
        }
        each(mark) { m in
            storage.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.3), range: m.range)
            dim(m.range, length: 2)
        }
        each(html) { storage.addAttribute(.foregroundColor, value: NSColor.systemTeal, range: $0.range) }
        each(link) { m in
            if m.range(at: 1).location != NSNotFound {
                storage.addAttribute(.foregroundColor, value: syntax, range: m.range(at: 1))
                storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: m.range(at: 2))
                storage.addAttribute(.foregroundColor, value: syntax, range: m.range(at: 3))
            } else {
                storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: m.range)
            }
        }
        each(listMarker) { storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: $0.range(at: 1)) }
        each(checkbox) { storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: $0.range) }
        each(checkedItem) { storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: $0.range(at: 1)) }
        each(quote) { storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: $0.range) }
        each(rule) { storage.addAttribute(.foregroundColor, value: syntax, range: $0.range) }
        each(math) { m in
            storage.addAttributes([.font: self.codeFont, .foregroundColor: NSColor.systemIndigo], range: m.range)
        }
        each(inlineCode) { m in
            storage.addAttributes([.font: self.codeFont, .foregroundColor: NSColor.systemPink], range: m.range)
            dim(m.range, length: 1)
        }
        each(fence) { m in
            storage.addAttributes([.font: self.codeFont, .foregroundColor: NSColor.labelColor], range: m.range)
            storage.removeAttribute(.backgroundColor, range: m.range)
            storage.removeAttribute(.strikethroughStyle, range: m.range)
            let info = (text as NSString).substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            let open = NSRange(location: m.range.location, length: m.range(at: 2).location + m.range(at: 2).length - m.range.location)
            storage.addAttribute(.foregroundColor, value: syntax, range: open)
            if m.range(at: 4).length > 0 { storage.addAttribute(.foregroundColor, value: syntax, range: m.range(at: 4)) }
            CodeHighlighter.apply(language: info, to: storage, range: m.range(at: 3))
        }
    }

    private func applyPartialBlock(_ block: NSRange, _ part: NSRange, _ storage: NSTextStorage, _ ns: NSString) {
        guard part.length > 0 else { return }
        let opener = ns.range(of: "\n", range: block)
        let isMath = ns.substring(with: NSRange(location: block.location, length: min(2, block.length))) == "$$"
        if isMath {
            storage.addAttributes([.font: codeFont, .foregroundColor: NSColor.systemIndigo], range: part)
            return
        }
        let syntax = NSColor.tertiaryLabelColor
        storage.addAttributes([.font: codeFont, .foregroundColor: NSColor.labelColor], range: part)
        let openEnd = opener.location == NSNotFound ? NSMaxRange(block) : opener.location
        let open = NSRange(location: block.location, length: openEnd - block.location)
        let delimiter = ns.substring(with: open).trimmingCharacters(in: .whitespaces)
        let info = String(delimiter.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        var bodyEnd = NSMaxRange(block)
        let lastLine = Self.lines(around: NSRange(location: max(openEnd, NSMaxRange(block) - 1), length: 0), in: ns)
        let last = ns.substring(with: lastLine).trimmingCharacters(in: .whitespacesAndNewlines)
        if lastLine.location > openEnd, last == String(delimiter.prefix(3)) {
            bodyEnd = lastLine.location
            storage.addAttribute(.foregroundColor, value: syntax, range: NSIntersectionRange(NSRange(location: lastLine.location, length: NSMaxRange(block) - lastLine.location), part))
        }
        storage.addAttribute(.foregroundColor, value: syntax, range: NSIntersectionRange(open, part))
        let bodyStart = min(openEnd + 1, bodyEnd)
        let body = NSIntersectionRange(NSRange(location: bodyStart, length: bodyEnd - bodyStart), part)
        CodeHighlighter.apply(language: info, to: storage, range: body)
    }
}
