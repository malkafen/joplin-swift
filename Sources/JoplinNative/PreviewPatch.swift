import AppKit

extension MarkdownPreview.Coordinator {
    struct Rendered: @unchecked Sendable {
        var text: NSTextStorage
        var sizedToWidth: Bool
        var markdown: String
        var blocks: [RenderedBlock]
        var headings: [String]
        var hasTOC: Bool
        var width: CGFloat
        var headingBases: [String] = []
        var htmlCarries = false
        var hasReferenceDefinitions = false
        var hasDollar = false
    }

    nonisolated static func rendered(_ markdown: String, _ renderer: MarkdownRenderer, width: CGFloat) -> Rendered {
        let document = renderer.renderDocument(markdown, maxImageWidth: width)
        return Rendered(text: NSTextStorage(attributedString: document.text), sizedToWidth: document.sizedToWidth, markdown: markdown,
                        blocks: document.blocks, headings: document.headings, hasTOC: document.hasTOC, width: width,
                        headingBases: document.headingBases, htmlCarries: document.htmlCarries,
                        hasReferenceDefinitions: hasReferenceDefinition(markdown),
                        hasDollar: markdown.quickContains("$"))
    }

    struct Patch: @unchecked Sendable {
        var range: NSRange
        var replacement: NSAttributedString
        var lineDelta: Int
        var length: Int
        var result: Rendered
    }

    nonisolated static func difference(_ a: String, _ b: String) -> (start: Int, oldEnd: Int, newEnd: Int, newLength: Int)? {
        let x = a as NSString, y = b as NSString
        let xl = x.length, yl = y.length, n = min(xl, yl)
        let chunk = 16_384
        var p = [unichar](repeating: 0, count: chunk), q = [unichar](repeating: 0, count: chunk)
        func same(fromEnd: Bool) -> Int {
            var done = 0
            while done < n {
                let count = min(chunk, n - done)
                x.getCharacters(&p, range: NSRange(location: fromEnd ? xl - done - count : done, length: count))
                y.getCharacters(&q, range: NSRange(location: fromEnd ? yl - done - count : done, length: count))
                if memcmp(p, q, count * 2) == 0 {
                    done += count
                    continue
                }
                var i = 0
                if fromEnd {
                    while p[count - 1 - i] == q[count - 1 - i] { i += 1 }
                } else {
                    while p[i] == q[i] { i += 1 }
                }
                return done + i
            }
            return n
        }
        var start = same(fromEnd: false)
        guard start < xl || start < yl else { return nil }
        if start > 0, start < xl, UTF16.isTrailSurrogate(x.character(at: start)) { start -= 1 }
        var tail = min(same(fromEnd: true), n - start)
        if tail > 0, UTF16.isTrailSurrogate(x.character(at: xl - tail)) { tail -= 1 }
        return (start, xl - tail, yl - tail, yl)
    }

    nonisolated static func patch(_ old: Rendered, to markdown: String, _ renderer: MarkdownRenderer, width: CGFloat) -> Patch? {
        let o = old.blocks
        guard !o.isEmpty, !old.hasTOC, !old.htmlCarries, !old.hasReferenceDefinitions,
              old.width == width || !old.sizedToWidth, old.headingBases.count == old.headings.count,
              old.headings.count == o.reduce(0, { $0 + $1.headings }) else { return nil }
        guard let change = difference(old.markdown, markdown) else {
            var result = old
            result.markdown = markdown
            return Patch(range: NSRange(location: 0, length: 0), replacement: NSAttributedString(), lineDelta: 0,
                         length: o[o.count - 1].rendered.upperBound, result: result)
        }
        let delta = change.newEnd - change.oldEnd
        let first = o.firstIndex { $0.source.upperBound >= change.start } ?? o.count
        let a = max(0, min(first, o.count - 1) - 1)
        let b = max(a, min(o.firstIndex { $0.source.location > change.oldEnd } ?? o.count, o.count - 1))
        let before = a > 0 ? a - 1 : nil, after = b + 1 < o.count ? b + 1 : nil
        let start = before.map { o[$0].source.location } ?? 0
        let end = after.map { o[$0].source.upperBound + delta } ?? change.newLength
        guard end - start <= backgroundLength else { return nil }
        func part(_ text: String, _ from: Int, _ to: Int) -> String {
            let i = text.utf16.index(text.startIndex, offsetBy: from)
            return String(text[i..<text.utf16.index(i, offsetBy: to - from)])
        }
        let source = part(markdown, start, end), removed = part(old.markdown, change.start, change.oldEnd)
        let hasDollar = old.hasDollar || source.utf8.contains(36)
        guard !source.contains("$$"), !removed.contains("$$"), !source.contains(MathExtractor.open),
              !hasReferenceDefinition(source) else { return nil }
        if hasDollar {
            let replaced = part(old.markdown, start, after.map { o[$0].source.upperBound } ?? (old.markdown as NSString).length)
            guard MathExtractor.openFence(after: part(markdown, 0, start)) == nil,
                  MathExtractor.openFence(after: source) == MathExtractor.openFence(after: replaced) else { return nil }
        }
        var counts: [String: Int] = [:]
        for base in old.headingBases[..<o[..<(before ?? 0)].reduce(0, { $0 + $1.headings })] { counts[base, default: 0] += 1 }
        let doc = renderer.renderDocument(source, maxImageWidth: width, firstLine: before.map { o[$0].line } ?? 1,
                                          headingsBefore: counts, endsNote: after == nil)
        let s = doc.blocks
        guard !doc.hasTOC, !doc.htmlCarries,
              doc.headings.count == s.reduce(0, { $0 + $1.headings }) else { return nil }
        if let before, s.first?.source != NSRange(location: 0, length: o[before].source.length) { return nil }
        if let after, s.last?.source != NSRange(location: o[after].source.location + delta - start, length: o[after].source.length) {
            return nil
        }
        let lo = before == nil ? 0 : 1, hi = after == nil ? s.count : s.count - 1
        guard lo <= hi else { return nil }
        let from = o[a].rendered.location, to = after.map { o[$0].rendered.location } ?? o[o.count - 1].rendered.upperBound
        let partFrom = lo < s.count ? s[lo].rendered.location : doc.text.length
        let partTo = hi < s.count ? s[hi].rendered.location : doc.text.length
        let shift = from - partFrom, grow = (partTo - partFrom) - (to - from)
        let lineDelta = after.map { s[s.count - 1].line - o[$0].line } ?? 0

        var blocks = Array(o[..<a])
        blocks += s[lo..<hi].map {
            var block = $0
            block.source.location += start
            block.rendered.location += shift
            return block
        }
        let headingsBefore = o[..<a].reduce(0) { $0 + $1.headings }
        let headingsAfter = after.map { o[$0...].reduce(0) { $0 + $1.headings } } ?? 0
        let skipped = s[..<lo].reduce(0) { $0 + $1.headings }
        let kept = skipped..<(skipped + s[lo..<hi].reduce(0) { $0 + $1.headings })
        if after != nil, doc.headingBases[kept].sorted() != old.headingBases[headingsBefore..<(old.headings.count - headingsAfter)].sorted() {
            return nil
        }
        var headings = Array(old.headings[..<headingsBefore]) + doc.headings[kept]
        var bases = Array(old.headingBases[..<headingsBefore]) + doc.headingBases[kept]
        if let after {
            blocks += o[after...].map {
                var block = $0
                block.source.location += delta
                block.line += lineDelta
                block.rendered.location += grow
                return block
            }
            headings += old.headings[(old.headings.count - headingsAfter)...]
            bases += old.headingBases[(old.headings.count - headingsAfter)...]
        }
        var result = old
        result.markdown = markdown
        result.blocks = blocks
        result.headings = headings
        result.headingBases = bases
        result.sizedToWidth = old.sizedToWidth || doc.sizedToWidth
        result.width = width
        result.hasDollar = hasDollar
        return Patch(range: NSRange(location: from, length: to - from),
                     replacement: doc.text.attributedSubstring(from: NSRange(location: partFrom, length: partTo - partFrom)),
                     lineDelta: lineDelta, length: o[o.count - 1].rendered.upperBound, result: result)
    }

    static func splice(_ storage: NSTextStorage, showing old: Rendered, into new: Rendered) -> Bool {
        let o = old.blocks, n = new.blocks
        guard !o.isEmpty, !n.isEmpty, o.last?.rendered.upperBound == storage.length,
              old.width == new.width || !old.sizedToWidth && !new.sizedToWidth else { return false }
        if old.headings != new.headings,
           old.hasTOC || new.hasTOC || Set(old.headings).count != old.headings.count || Set(new.headings).count != new.headings.count {
            return false
        }
        let om = old.markdown as NSString, nm = new.markdown as NSString
        func same(_ i: Int, _ j: Int) -> Bool {
            o[i].source.length == n[j].source.length && om.substring(with: o[i].source) == nm.substring(with: n[j].source)
        }
        let common = min(o.count, n.count)
        var head = 0
        while head < common, same(head, head) { head += 1 }
        var tail = 0
        while tail < common - head, same(o.count - 1 - tail, n.count - 1 - tail) { tail += 1 }
        head = max(0, head - 1)
        tail = max(0, tail - 1)
        let oldStart = o[head].rendered.location, newStart = n[head].rendered.location
        let oldEnd = tail == 0 ? storage.length : o[o.count - tail].rendered.location
        let newEnd = tail == 0 ? new.text.length : n[n.count - tail].rendered.location
        guard oldStart == newStart, storage.length - oldEnd == new.text.length - newEnd,
              newEnd - newStart <= backgroundLength else { return false }
        let oldSource = om.substring(with: NSRange(location: o[head].source.location,
                                                   length: (tail == 0 ? om.length : o[o.count - tail].source.location) - o[head].source.location))
        let newSource = nm.substring(with: NSRange(location: n[head].source.location,
                                                   length: (tail == 0 ? nm.length : n[n.count - tail].source.location) - n[head].source.location))
        if referenceDefinition.firstMatch(in: oldSource, range: NSRange(location: 0, length: (oldSource as NSString).length)) != nil
            || referenceDefinition.firstMatch(in: newSource, range: NSRange(location: 0, length: (newSource as NSString).length)) != nil {
            return false
        }
        if tail > 0 {
            let delta = n[n.count - tail].line - o[o.count - tail].line
            if delta != 0 {
                storage.enumerateAttribute(.jnCheckbox, in: NSRange(location: oldEnd, length: storage.length - oldEnd)) { value, _, _ in
                    (value as? CheckboxLine)?.line += delta
                }
            }
        }
        let replacement = new.text.attributedSubstring(from: NSRange(location: newStart, length: newEnd - newStart))
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: oldStart, length: oldEnd - oldStart), with: replacement)
        storage.endEditing()
        return true
    }

    nonisolated private static let referenceDefinition = try! NSRegularExpression(pattern: #"(?m)^ {0,3}\[[^\]]+\]:"#)

    nonisolated static func hasReferenceDefinition(_ markdown: String) -> Bool {
        guard markdown.quickContains("]:") else { return false }
        let text = markdown as NSString
        var from = 0
        while true {
            let hit = text.range(of: "]:", options: .literal, range: NSRange(location: from, length: text.length - from))
            guard hit.location != NSNotFound else { return false }
            let line = text.lineRange(for: hit)
            if referenceDefinition.firstMatch(in: markdown, range: NSRange(location: line.location, length: hit.upperBound - line.location)) != nil {
                return true
            }
            from = hit.upperBound
        }
    }
}
