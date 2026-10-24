import AppKit

class SearchMarkingLayoutManager: NSLayoutManager {
    var searchTerms: [String] = [] {
        didSet {
            guard oldValue != searchTerms else { return }
            forgetMatches()
            for container in textContainers {
                if let tv = container.textView { tv.setNeedsDisplay(tv.visibleRect) }
            }
        }
    }
    private(set) var currentMatch: NSRange?
    private var allMatches: [NSRange]?

    private func forgetMatches() {
        allMatches = nil
        if let old = currentMatch, let storage = textStorage, NSMaxRange(old) <= storage.length {
            invalidateDisplay(forCharacterRange: old)
        }
        currentMatch = nil
    }

    override func processEditing(for textStorage: NSTextStorage, edited editMask: NSTextStorageEditActions,
                                 range newCharRange: NSRange, changeInLength delta: Int, invalidatedRange invalidatedCharRange: NSRange) {
        super.processEditing(for: textStorage, edited: editMask, range: newCharRange, changeInLength: delta,
                             invalidatedRange: invalidatedCharRange)
        if editMask.contains(.editedCharacters) {
            allMatches = nil
            currentMatch = nil
        }
    }

    override func replaceTextStorage(_ newTextStorage: NSTextStorage) {
        allMatches = nil
        currentMatch = nil
        super.replaceTextStorage(newTextStorage)
    }

    func step(forward: Bool, from location: Int) -> (match: NSRange, index: Int, count: Int)? {
        guard !searchTerms.isEmpty, let storage = textStorage else { return nil }
        let all = allMatches ?? SearchHighlight.ranges(of: searchTerms, in: storage.mutableString)
        allMatches = all
        guard !all.isEmpty else { return nil }
        var lo = 0, hi = all.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if all[mid].location < location { lo = mid + 1 } else { hi = mid }
        }
        let index = forward ? (lo < all.count ? lo : 0) : (lo > 0 ? lo - 1 : all.count - 1)
        if let old = currentMatch { invalidateDisplay(forCharacterRange: old) }
        currentMatch = all[index]
        invalidateDisplay(forCharacterRange: all[index])
        return (all[index], index, all.count)
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard !searchTerms.isEmpty, let storage = textStorage, let container = textContainers.first else { return }
        for match in searchMatches(forGlyphRange: glyphsToShow) {
            (match == currentMatch ? SearchHighlight.currentColor : SearchHighlight.color).setFill()
            for pill in pills(forCharacterRange: match, in: container, storage: storage) {
                NSBezierPath(roundedRect: pill.offsetBy(dx: origin.x, dy: origin.y), xRadius: 4, yRadius: 4).fill()
            }
        }
    }

    func searchMatches(forGlyphRange glyphs: NSRange) -> [NSRange] {
        guard !searchTerms.isEmpty, let storage = textStorage else { return [] }
        let chars = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let reach = 2 * (searchTerms.map { ($0 as NSString).length }.max() ?? 0)
        let from = max(0, chars.location - reach), to = min(storage.length, NSMaxRange(chars) + reach)
        return SearchHighlight.ranges(of: searchTerms, in: storage.mutableString, range: NSRange(location: from, length: to - from))
            .filter { NSIntersectionRange($0, chars).length > 0 }
    }

    func pills(forCharacterRange range: NSRange, in container: NSTextContainer, storage: NSTextStorage) -> [NSRect] {
        let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var result: [NSRect] = []
        var g = glyphs.location
        while g < NSMaxRange(glyphs) {
            var line = NSRange()
            let fragment = lineFragmentRect(forGlyphAt: g, effectiveRange: &line)
            let part = NSIntersectionRange(line, glyphs)
            guard part.length > 0 else { break }
            let rect = boundingRect(forGlyphRange: part, in: container)
            let font = storage.attribute(.font, at: characterIndexForGlyph(at: part.location), effectiveRange: nil) as? NSFont
                ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let baseline = fragment.minY + location(forGlyphAt: line.location).y
            result.append(NSRect(x: rect.minX - 1, y: baseline - font.ascender - 1.5,
                                 width: rect.width + 2, height: font.ascender - font.descender + 3))
            g = NSMaxRange(part)
        }
        return result
    }
}

struct SearchPosition: Equatable {
    var index: Int
    var count: Int
}

@MainActor
final class SearchStepper {
    weak var editor: NSTextView?
    weak var preview: NSTextView?
    var onStep: ((SearchPosition) -> Void)?

    func isActive(in tv: NSTextView) -> Bool {
        guard let lm = tv.layoutManager as? SearchMarkingLayoutManager, !lm.searchTerms.isEmpty else { return false }
        return !(tv.enclosingScrollView?.isFindBarVisible ?? false)
    }

    static func direction(of sender: Any?) -> Bool? {
        guard let tag = (sender as? NSValidatedUserInterfaceItem)?.tag else { return nil }
        switch tag {
        case NSTextFinder.Action.nextMatch.rawValue: return true
        case NSTextFinder.Action.previousMatch.rawValue: return false
        default: return nil
        }
    }

    @discardableResult
    func step(forward: Bool, in tv: NSTextView) -> Bool {
        guard isActive(in: tv), let lm = tv.layoutManager as? SearchMarkingLayoutManager,
              let container = tv.textContainer else { return false }
        let isEditor = tv === editor
        var location: Int
        if isEditor {
            location = tv.selectedRange().location
            if let current = lm.currentMatch, location >= current.location, location <= NSMaxRange(current) {
                location = current.location
                if forward { location += 1 }
            }
        } else if let current = lm.currentMatch {
            location = current.location + (forward ? 1 : 0)
        } else {
            var rect = tv.visibleRect
            rect.origin.x -= tv.textContainerOrigin.x
            rect.origin.y -= tv.textContainerOrigin.y
            let glyphs = lm.glyphRange(forBoundingRect: rect, in: container)
            location = glyphs.length > 0 ? lm.characterIndexForGlyph(at: glyphs.location) : 0
        }
        guard let found = lm.step(forward: forward, from: location) else {
            onStep?(SearchPosition(index: 0, count: 0))
            return true
        }
        if isEditor {
            if let vim = (tv as? MarkdownTextView)?.vim { vim.jump(to: found.match.location) } else { tv.setSelectedRange(found.match) }
        }
        tv.scrollRangeToVisible(found.match)
        let glyphs = lm.glyphRange(forCharacterRange: found.match, actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: 0, dy: tv.textContainerOrigin.y)
        let visible = tv.visibleRect
        if rect.minY < visible.minY + visible.height * 0.2 || rect.maxY > visible.maxY - visible.height * 0.2 {
            tv.scroll(NSPoint(x: visible.minX, y: max(0, rect.midY - visible.height / 3)))
        }
        if tv.window != nil { tv.showFindIndicator(for: found.match) }
        onStep?(SearchPosition(index: found.index, count: found.count))
        return true
    }
}

@MainActor
protocol SearchSteppingTextView: NSTextView {
    var stepper: SearchStepper? { get }
}

@MainActor
extension SearchSteppingTextView {
    func stepSearch(_ sender: Any?) -> Bool {
        guard let forward = SearchStepper.direction(of: sender), let stepper else { return false }
        return stepper.step(forward: forward, in: self)
    }

    func validatesSearchStep(_ item: NSValidatedUserInterfaceItem) -> Bool {
        (item.action == #selector(NSTextView.performTextFinderAction(_:)) || item.action == #selector(NSTextView.performFindPanelAction(_:)))
            && SearchStepper.direction(of: item) != nil && stepper?.isActive(in: self) == true
    }
}

final class PillBackgroundLayoutManager: SearchMarkingLayoutManager {
    private var origin = NSPoint.zero

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        self.origin = origin
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        guard let storage = textStorage, charRange.location < storage.length,
              storage.attribute(.backgroundColor, at: charRange.location, effectiveRange: nil) as? NSColor == color,
              let font = storage.attribute(.font, at: charRange.location, effectiveRange: nil) as? NSFont else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }
        var lines: [(fragment: NSRect, baseline: CGFloat)] = []
        let glyphs = glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        var g = glyphs.location
        while g < NSMaxRange(glyphs) {
            var line = NSRange()
            let fragment = lineFragmentRect(forGlyphAt: g, effectiveRange: &line)
            lines.append((fragment, fragment.minY + location(forGlyphAt: line.location).y))
            g = max(g + 1, NSMaxRange(line))
        }
        color.setFill()
        for i in 0..<rectCount {
            let r = rectArray[i]
            let y = r.midY - origin.y
            guard let line = lines.first(where: { $0.fragment.minY <= y && y < $0.fragment.maxY }) ?? lines.first else { continue }
            let baseline = origin.y + line.baseline
            let pill = NSRect(x: r.minX - 2, y: baseline - font.ascender - 1.5,
                              width: r.width + 4, height: font.ascender - font.descender + 3)
            NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
        }
    }
}
