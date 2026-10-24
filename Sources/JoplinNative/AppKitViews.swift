import AppKit
import SwiftUI

@MainActor
final class RemoteImageLoader {
    static let shared = RemoteImageLoader()
    static let didLoad = Notification.Name("JNRemoteImageLoaded")

    nonisolated(unsafe) private let cache = NSCache<NSURL, NSImage>()
    private var inFlight: Set<URL> = []
    private var failed: Set<URL> = []
    var session: URLSession = .shared

    nonisolated func imageOffMain(for url: URL) -> NSImage? {
        if let image = cache.object(forKey: url as NSURL) { return image }
        DispatchQueue.main.async { MainActor.assumeIsolated { _ = self.image(for: url) } }
        return nil
    }

    func image(for url: URL) -> NSImage? {
        if let image = cache.object(forKey: url as NSURL) { return image }
        guard url.scheme == "http" || url.scheme == "https", !inFlight.contains(url), !failed.contains(url) else { return nil }
        inFlight.insert(url)
        let session = self.session
        Task {
            self.finish(url, await Self.fetch(url, session: session))
        }
        return nil
    }

    private nonisolated static func fetch(_ url: URL, session: URLSession) async -> NSImage? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return nil }
        return NSImage(data: data)
    }

    func finish(_ url: URL, _ image: NSImage?) {
        inFlight.remove(url)
        if let image, image.isValid {
            cache.setObject(image, forKey: url as NSURL)
            NotificationCenter.default.post(name: Self.didLoad, object: url)
        } else {
            failed.insert(url)
        }
    }
}

@MainActor
protocol ReadableWidth: NSTextView {
    var maxLineWidth: CGFloat? { get }
    var minimumInset: NSSize { get }
}

extension ReadableWidth {
    func updateReadableInset() {
        let padding = textContainer?.lineFragmentPadding ?? 0
        var horizontal = minimumInset.width
        if let maxLineWidth {
            horizontal = max(horizontal, ((frame.width - maxLineWidth) / 2 - padding).rounded(.down))
        }
        let inset = NSSize(width: horizontal, height: minimumInset.height)
        if textContainerInset != inset { textContainerInset = inset }
    }

    var textWidth: CGFloat {
        frame.width - 2 * textContainerInset.width - 2 * (textContainer?.lineFragmentPadding ?? 0)
    }
}

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

final class PreviewTextView: NSTextView, ReadableWidth, SearchSteppingTextView {
    var maxLineWidth: CGFloat? {
        didSet { if oldValue != maxLineWidth { updateReadableInset() } }
    }
    weak var stepper: SearchStepper?

    override func performTextFinderAction(_ sender: Any?) {
        if !stepSearch(sender) { super.performTextFinderAction(sender) }
    }

    override func performFindPanelAction(_ sender: Any?) {
        if !stepSearch(sender) { super.performFindPanelAction(sender) }
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        validatesSearchStep(item) || super.validateUserInterfaceItem(item)
    }
    let minimumInset = NSSize(width: 28, height: 22)
    var onCheckbox: ((Int) -> Void)?
    var onResize: (() -> Void)?
    var onShow: (() -> Void)?
    var blocks: [RenderedBlock] = []

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        if changed {
            updateReadableInset()
            onResize?()
        }
    }

    func checkboxLine(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: p, in: textContainer)
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard rect.insetBy(dx: -3, dy: -3).contains(p) else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        return (storage.attribute(.jnCheckbox, at: index, effectiveRange: nil) as? CheckboxLine)?.line
    }

    override func mouseDown(with event: NSEvent) {
        if let line = checkboxLine(at: convert(event.locationInWindow, from: nil)) {
            onCheckbox?(line)
            return
        }
        super.mouseDown(with: event)
    }

    static let exactScrollLimit = 300_000

    func scroll(toSource location: Int, offset: CGFloat) {
        guard let layoutManager, let textContainer, let storage = textStorage, let scroll = enclosingScrollView,
              !blocks.isEmpty, blocks.last?.rendered.upperBound == storage.length else { return }
        var lo = 0, hi = blocks.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if blocks[mid].source.location <= location { lo = mid } else { hi = mid - 1 }
        }
        let block = blocks[lo]
        let fraction = block.source.length > 0
            ? min(1, max(0, CGFloat(location - block.source.location) / CGFloat(block.source.length))) : 0
        func top(of character: Int) -> CGFloat {
            guard character < storage.length else {
                return layoutManager.usedRect(for: textContainer).maxY + textContainerOrigin.y
            }
            let glyph = layoutManager.glyphIndexForCharacter(at: character)
            return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + textContainerOrigin.y
        }
        let from = storage.length > PreviewTextView.exactScrollLimit ? block.rendered.location : 0
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: from, length: min(storage.length, block.rendered.upperBound + 1) - from))
        let start = top(of: block.rendered.location)
        let end = fraction > 0 ? top(of: block.rendered.upperBound) : start
        let maxY = max(0, frame.height - scroll.contentView.bounds.height)
        let y = min(maxY, max(0, start + fraction * (end - start) - offset))
        guard abs(scroll.contentView.bounds.origin.y - y) > 0.5 else { return }
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    @discardableResult
    func scrollToAnchor(_ slug: String) -> Bool {
        guard let storage = textStorage, let layoutManager, let textContainer else { return false }
        var found: NSRange?
        storage.enumerateAttribute(.jnAnchor, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if let value = value as? String, value == slug || value == slug.lowercased() {
                found = range
                stop.pointee = true
            }
        }
        guard let range = found else { return false }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        scroll(NSPoint(x: 0, y: max(0, rect.minY + textContainerOrigin.y - 12)))
        return true
    }
}

struct MarkdownPreview: NSViewRepresentable {
    private let box: TextBox
    var markdown: String { box.string }
    var noteId: String
    var renderer: MarkdownRenderer
    var isShown = true
    var readableWidth: Bool
    var highlights: [String] = []
    var stepper: SearchStepper?
    var onLink: (URL) -> Void

    init(markdown: String, noteId: String, renderer: MarkdownRenderer, isShown: Bool = true, readableWidth: Bool,
         highlights: [String] = [], stepper: SearchStepper? = nil, onLink: @escaping (URL) -> Void) {
        box = TextBox(markdown)
        self.noteId = noteId
        self.renderer = renderer
        self.isShown = isShown
        self.readableWidth = readableWidth
        self.highlights = highlights
        self.stepper = stepper
        self.onLink = onLink
    }

    func makeCoordinator() -> Coordinator { Coordinator(onLink: onLink) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let tv = PreviewTextView(usingTextLayoutManager: false)
        tv.textContainer?.replaceLayoutManager(PillBackgroundLayoutManager())
        tv.layoutManager?.allowsNonContiguousLayout = true
        tv.isEditable = false
        tv.isSelectable = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 4
        tv.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        tv.delegate = context.coordinator
        tv.updateReadableInset()
        let coordinator = context.coordinator
        tv.onCheckbox = { [weak coordinator] line in
            coordinator?.onLink(URL(string: "joplincheckbox://\(line)")!)
        }
        tv.onResize = { [weak coordinator] in coordinator?.widthChanged() }
        scroll.documentView = tv
        coordinator.textView = tv
        tv.stepper = stepper
        stepper?.preview = tv
        coordinator.observeRemoteImages()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.onLink = onLink
        c.renderer = renderer
        guard let tv = c.textView else { return }
        tv.maxLineWidth = readableWidth ? renderer.typography.readableWidth : nil
        guard isShown else { return }
        let newTerms = c.highlights != highlights
        c.highlights = highlights
        (tv.layoutManager as? SearchMarkingLayoutManager)?.searchTerms = highlights
        let style = "\(renderer.typography)|\(renderer.loadsRemoteImages)"
        guard c.renderedStyle != style || !c.markdown.isLiterally(markdown) || c.noteId != noteId else {
            if newTerms { c.revealFirstMatch() }
            return
        }
        let sameNote = c.noteId == noteId
        let typing = sameNote && c.renderedStyle == style
        c.markdown = markdown
        c.renderedStyle = style
        c.noteId = noteId
        if typing {
            c.renderSoon()
            if newTerms { c.revealFirstMatch() }
            return
        }
        c.render(keepScroll: sameNote, reveal: !sameNote || newTerms)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var onLink: (URL) -> Void
        weak var textView: PreviewTextView?
        var renderer: MarkdownRenderer?
        var markdown = ""
        var highlights: [String] = []
        var renderedStyle = ""
        var noteId = ""
        private var renderedWidth: CGFloat = 0
        private var lastRender = Date.distantPast
        private var pendingRender: DispatchWorkItem?
        static let typingInterval: TimeInterval = 0.25

        init(onLink: @escaping (URL) -> Void) {
            self.onLink = onLink
        }

        func observeRemoteImages() {
            NotificationCenter.default.addObserver(self, selector: #selector(remoteImageLoaded(_:)),
                                                   name: RemoteImageLoader.didLoad, object: nil)
        }

        @objc func remoteImageLoaded(_ note: Notification) {
            guard let url = note.object as? URL, markdown.contains(url.absoluteString) else { return }
            render(keepScroll: true)
        }

        private var imageWidth: CGFloat {
            guard let tv = textView else { return 640 }
            return max(120, tv.textWidth)
        }

        func widthChanged() {
            guard renderer != nil, sizedToWidth, abs(imageWidth - renderedWidth) > 24 else { return }
            DispatchQueue.main.async { [weak self] in self?.render(keepScroll: true) }
        }

        func renderSoon() {
            pendingRender?.cancel()
            let wait = Self.typingInterval - Date().timeIntervalSince(lastRender)
            guard wait > 0 else {
                render(keepScroll: true, incremental: true)
                return
            }
            let item = DispatchWorkItem { [weak self] in self?.render(keepScroll: true, incremental: true) }
            pendingRender = item
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: item)
        }

        nonisolated static let backgroundLength = 200_000
        private var sizedToWidth = true
        private var generation = 0
        private var rendering = false
        private var renderAgain: (reveal: Bool, incremental: Bool)?
        private var shown: Rendered?
        private var shownVersion = 0
        private let renderQueue = DispatchQueue(label: "io.github.malkafen.JoplinNative.preview", qos: .userInitiated)

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

        static func start(of markdown: String) -> String { markdown.leadingParagraphs(limit: 20_000) }

        func render(keepScroll: Bool, reveal: Bool = false, incremental: Bool = false) {
            pendingRender?.cancel()
            pendingRender = nil
            guard textView != nil, var renderer else { return }
            generation += 1
            renderedWidth = imageWidth
            let markdown = self.markdown, width = renderedWidth
            let base = incremental && keepScroll ? shown : nil, version = shownVersion
            guard markdown.quickLength > Self.backgroundLength else {
                if let base, let patch = Self.patch(base, to: markdown, renderer, width: width) {
                    apply(patch, reveal: reveal)
                } else {
                    show(Self.rendered(markdown, renderer, width: width), keepScroll: keepScroll, reveal: reveal,
                         incremental: incremental)
                }
                return
            }
            if !keepScroll {
                show(Self.rendered(Self.start(of: markdown), renderer, width: width), keepScroll: false, reveal: false)
            }
            guard !rendering else {
                renderAgain = ((renderAgain?.reveal ?? false) || reveal, (renderAgain?.incremental ?? true) && incremental)
                return
            }
            rendering = true
            if renderer.remoteImage != nil {
                let loader = RemoteImageLoader.shared
                renderer.remoteImage = { loader.imageOffMain(for: $0) }
            }
            let background = renderer
            let token = generation
            renderQueue.async { [weak self] in
                let patch = base.flatMap { Self.patch($0, to: markdown, background, width: width) }
                let result = patch == nil ? Self.rendered(markdown, background, width: width) : nil
                RunLoop.main.perform(inModes: [.common]) {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.rendering = false
                        if self.generation == token {
                            if let result {
                                self.show(result, keepScroll: true, reveal: reveal, incremental: incremental)
                            } else if let patch, self.shownVersion == version {
                                self.apply(patch, reveal: reveal)
                            } else if self.renderAgain == nil {
                                self.renderAgain = (reveal, true)
                            }
                        }
                        if let again = self.renderAgain {
                            self.renderAgain = nil
                            self.render(keepScroll: true, reveal: again.reveal, incremental: again.incremental)
                        }
                    }
                }
            }
        }

        private func show(_ result: Rendered, keepScroll: Bool, reveal: Bool, incremental: Bool = false) {
            defer { lastRender = Date() }
            guard let tv = textView, let lm = tv.layoutManager else { return }
            sizedToWidth = result.sizedToWidth
            defer {
                shown = result
                shownVersion += 1
                tv.blocks = result.blocks
                tv.onShow?()
            }
            if incremental, keepScroll, let old = shown, let storage = tv.textStorage, Self.splice(storage, showing: old, into: result) {
                if reveal { revealFirstMatch() }
                return
            }
            let scroll = tv.enclosingScrollView
            let origin = scroll?.contentView.bounds.origin ?? .zero
            lm.replaceTextStorage(result.text)
            if keepScroll, let scroll {
                scroll.contentView.scroll(to: origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            } else if !keepScroll {
                tv.scrollToBeginningOfDocument(nil)
            }
            if reveal { revealFirstMatch() }
        }

        private func apply(_ patch: Patch, reveal: Bool) {
            guard let tv = textView, let storage = tv.textStorage else { return }
            guard storage.length == patch.length else {
                render(keepScroll: true, reveal: reveal)
                return
            }
            defer { lastRender = Date() }
            if patch.lineDelta != 0 {
                let rest = NSRange(location: patch.range.upperBound, length: storage.length - patch.range.upperBound)
                storage.enumerateAttribute(.jnCheckbox, in: rest) { value, _, _ in (value as? CheckboxLine)?.line += patch.lineDelta }
            }
            if patch.range.length > 0 || patch.replacement.length > 0 {
                storage.beginEditing()
                storage.replaceCharacters(in: patch.range, with: patch.replacement)
                storage.endEditing()
            }
            var result = patch.result
            result.text = storage
            sizedToWidth = result.sizedToWidth
            shown = result
            shownVersion += 1
            tv.blocks = result.blocks
            tv.onShow?()
            if reveal { revealFirstMatch() }
        }

        func revealFirstMatch() {
            guard let tv = textView, let storage = tv.textStorage, let layoutManager = tv.layoutManager,
                  let container = tv.textContainer, let scroll = tv.enclosingScrollView,
                  let match = SearchHighlight.ranges(of: highlights, in: storage.mutableString, limit: 1).first else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: match, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            let y = rect.midY + tv.textContainerOrigin.y - scroll.contentView.bounds.height / 3
            tv.scroll(NSPoint(x: 0, y: max(0, y)))
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url else { return false }
            if url.scheme == nil, let fragment = url.fragment(percentEncoded: false), !fragment.isEmpty {
                (textView as? PreviewTextView)?.scrollToAnchor(fragment)
                return true
            }
            onLink(url)
            return true
        }
    }
}

final class NoteSplitNSView: NSSplitView {
    var showsDivider = true {
        didSet { if oldValue != showsDivider { needsDisplay = true } }
    }
    override var dividerThickness: CGFloat { showsDivider ? super.dividerThickness : 0 }
    override func drawDivider(in rect: NSRect) {
        if showsDivider { super.drawDivider(in: rect) }
    }
}

struct NoteSplitView<Editor: View, Preview: View>: NSViewRepresentable {
    var layout: EditorLayout
    var editor: Editor
    var preview: Preview

    func makeCoordinator() -> Coordinator { Coordinator(editor: editor, preview: preview) }

    func makeNSView(context: Context) -> NoteSplitNSView {
        let split = NoteSplitNSView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = context.coordinator
        split.addArrangedSubview(context.coordinator.editor)
        split.addArrangedSubview(context.coordinator.preview)
        context.coordinator.split = split
        context.coordinator.apply(layout)
        return split
    }

    func updateNSView(_ split: NoteSplitNSView, context: Context) {
        let c = context.coordinator
        c.editor.rootView = editor
        c.preview.rootView = preview
        c.apply(layout)
        DispatchQueue.main.async { c.followEditor() }
    }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
        let editor: NSHostingView<Editor>
        let preview: NSHostingView<Preview>
        weak var split: NoteSplitNSView?
        private var layout: EditorLayout?
        private var fraction: CGFloat = 0.5
        static var minimumWidth: CGFloat { 220 }

        init(editor: Editor, preview: Preview) {
            self.editor = NSHostingView(rootView: editor)
            self.preview = NSHostingView(rootView: preview)
            self.editor.sizingOptions = []
            self.preview.sizingOptions = []
        }

        private weak var editorText: NSTextView?
        private weak var previewText: PreviewTextView?

        func followEditor() {
            if editorText == nil, let tv = textView(in: editor), let clip = tv.enclosingScrollView?.contentView {
                editorText = tv
                clip.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(editorScrolled(_:)),
                                                       name: NSView.boundsDidChangeNotification, object: clip)
            }
            if previewText == nil, let tv = textView(in: preview) as? PreviewTextView {
                previewText = tv
                tv.onShow = { [weak self] in self?.syncPreview() }
            }
        }

        private var syncQueued = false

        @objc private func editorScrolled(_ notification: Notification) {
            syncPreview()
            guard !syncQueued else { return }
            syncQueued = true
            DispatchQueue.main.async { [weak self] in
                self?.syncQueued = false
                self?.syncPreview()
            }
        }

        func syncPreview() {
            guard layout == .split, let tv = editorText, let preview = previewText, let clip = tv.enclosingScrollView?.contentView,
                  let lm = tv.layoutManager, let container = tv.textContainer else { return }
            let visible = clip.bounds
            let length = (tv.string as NSString).length
            let caret = tv.selectedRange().location
            if length > 0, caret <= length {
                let glyph = lm.glyphIndexForCharacter(at: min(caret, length - 1))
                let y = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + tv.textContainerOrigin.y
                if y >= visible.minY, y < visible.maxY {
                    preview.scroll(toSource: caret, offset: y - visible.minY)
                    return
                }
            }
            if visible.minY <= 0 {
                preview.scroll(toSource: 0, offset: 0)
                return
            }
            if visible.maxY >= tv.frame.height - 1 {
                preview.scroll(toSource: Int.max, offset: -.greatestFiniteMagnitude)
                return
            }
            let line = NSRect(x: 0, y: visible.minY - tv.textContainerOrigin.y, width: container.size.width, height: 1)
            let glyphs = lm.glyphRange(forBoundingRect: line, in: container)
            guard glyphs.location < lm.numberOfGlyphs else { return }
            let character = lm.characterIndexForGlyph(at: glyphs.location)
            let fragment = lm.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            preview.scroll(toSource: character, offset: fragment.minY + tv.textContainerOrigin.y - visible.minY)
        }

        func apply(_ new: EditorLayout) {
            guard new != layout, let split else { return }
            let old = layout
            layout = new
            let window = split.window
            let focused = (window?.firstResponder as? NSView).map { $0.isDescendant(of: split) } ?? false
            editor.isHidden = new == .preview
            preview.isHidden = new == .editor
            split.showsDivider = new == .split
            split.adjustSubviews()
            if new == .split {
                place()
                DispatchQueue.main.async { [weak self] in self?.syncPreview() }
            }
            guard focused || old == nil, let window else { return }
            if let tv = textView(in: new == .preview ? preview : editor) {
                window.makeFirstResponder(tv)
            }
        }

        private func place() {
            guard let split, split.bounds.width > 0 else { return }
            split.setPosition((split.bounds.width * fraction).rounded(), ofDividerAt: 0)
        }

        private func textView(in view: NSView) -> NSTextView? {
            if let tv = view as? NSTextView { return tv }
            for sub in view.subviews { if let tv = textView(in: sub) { return tv } }
            return nil
        }

        func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
            layout != .split
        }

        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                       ofSubviewAt dividerIndex: Int) -> CGFloat {
            max(proposedMinimumPosition, Self.minimumWidth)
        }

        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                       ofSubviewAt dividerIndex: Int) -> CGFloat {
            min(proposedMaximumPosition, splitView.bounds.width - Self.minimumWidth)
        }

        func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard layout == .split, let split, split.bounds.width > 0, !editor.isHidden, !preview.isHidden else { return }
            fraction = editor.frame.width / split.bounds.width
        }
    }
}

struct TagField: NSViewRepresentable {
    var tags: [String]
    var allTags: [String]
    var onCreate: (NSTokenField) -> Void = { _ in }
    var onCommit: ([String]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTokenField {
        let field = NSTokenField()
        field.delegate = context.coordinator
        field.placeholderString = "Add tags"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.tokenStyle = .rounded
        field.tokenizingCharacterSet = CharacterSet(charactersIn: ",")
        field.completionDelay = 0.1
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.objectValue = tags
        onCreate(field)
        return field
    }

    func updateNSView(_ field: NSTokenField, context: Context) {
        context.coordinator.parent = self
        let current = (field.objectValue as? [String]) ?? []
        if field.currentEditor() == nil, current != tags {
            field.objectValue = tags
        }
    }

    final class Coordinator: NSObject, NSTokenFieldDelegate {
        var parent: TagField

        init(_ parent: TagField) {
            self.parent = parent
        }

        private func commit(_ field: NSTokenField) {
            parent.onCommit((field.objectValue as? [String]) ?? [])
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            if let field = obj.object as? NSTokenField { commit(field) }
        }

        func tokenField(_ tokenField: NSTokenField, shouldAdd tokens: [Any], at index: Int) -> [Any] {
            DispatchQueue.main.async { self.commit(tokenField) }
            return tokens
        }

        func tokenField(_ tokenField: NSTokenField, completionsForSubstring substring: String,
                        indexOfToken tokenIndex: Int, indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?) -> [Any]? {
            let lower = substring.lowercased()
            let existing = Set((tokenField.objectValue as? [String]) ?? [])
            return parent.allTags.filter { $0.hasPrefix(lower) && !existing.contains($0) }
        }
    }
}
