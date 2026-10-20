import AppKit
import SwiftUI

/// Downloads images referenced by URL in notes, once, and announces when one arrives so previews re-render.
@MainActor
final class RemoteImageLoader {
    static let shared = RemoteImageLoader()
    static let didLoad = Notification.Name("JNRemoteImageLoaded")

    nonisolated(unsafe) private let cache = NSCache<NSURL, NSImage>()
    private var inFlight: Set<URL> = []
    private var failed: Set<URL> = []
    var session: URLSession = .shared

    /// `image(for:)` for renders off the main thread: the download, if needed, starts on the main thread.
    nonisolated func imageOffMain(for url: URL) -> NSImage? {
        if let image = cache.object(forKey: url as NSURL) { return image }
        DispatchQueue.main.async { MainActor.assumeIsolated { _ = self.image(for: url) } }
        return nil
    }

    /// The image when it has been downloaded; otherwise starts the download and returns nil.
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

/// Insets a text view's container so that lines never get longer than a comfortable reading measure.
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

    /// Width available to text, images included.
    var textWidth: CGFloat {
        frame.width - 2 * textContainerInset.width - 2 * (textContainer?.lineFragmentPadding ?? 0)
    }
}

/// Draws text backgrounds (inline code, keys, highlights) as rounded pills around the glyphs instead of filling
/// the whole line height, which looks heavy with generous line spacing.
final class PillBackgroundLayoutManager: NSLayoutManager {
    private var origin = NSPoint.zero

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        self.origin = origin
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        guard let storage = textStorage, let container = textContainers.first, charRange.location < storage.length,
              storage.attribute(.backgroundColor, at: charRange.location, effectiveRange: nil) as? NSColor == color,
              let font = storage.attribute(.font, at: charRange.location, effectiveRange: nil) as? NSFont else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }
        color.setFill()
        for i in 0..<rectCount {
            let r = rectArray[i]
            // Baseline of the line this rect is on, in view coordinates.
            let point = NSPoint(x: r.midX - origin.x, y: r.midY - origin.y)
            let glyph = glyphIndex(for: point, in: container)
            var fragmentGlyphs = NSRange()
            let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: &fragmentGlyphs)
            let baseline = origin.y + fragment.minY + location(forGlyphAt: fragmentGlyphs.location).y
            let pill = NSRect(x: r.minX - 2, y: baseline - font.ascender - 1.5,
                              width: r.width + 4, height: font.ascender - font.descender + 3)
            NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
        }
    }
}

/// Text view of the preview: readable width, clickable task list checkboxes and heading anchors.
final class PreviewTextView: NSTextView, ReadableWidth {
    var maxLineWidth: CGFloat? {
        didSet { if oldValue != maxLineWidth { updateReadableInset() } }
    }
    let minimumInset = NSSize(width: 28, height: 22)
    var onCheckbox: ((Int) -> Void)?
    var onResize: (() -> Void)?
    /// Called after the text changed.
    var onShow: (() -> Void)?
    /// Top-level blocks of the shown note, for following the editor.
    var blocks: [RenderedBlock] = []

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        if changed {
            updateReadableInset()
            onResize?()
        }
    }

    /// Source line of the checkbox drawn at `point` (view coordinates).
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

    /// Scrolls so that the rendering of the Markdown at `location` (UTF-16) is `offset` points below the top of the
    /// visible area. Within a block the position is interpolated, so a long table or list follows smoothly.
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
        // Positions are estimates until the text above is laid out. Done once: typing keeps the layout.
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(storage.length, block.rendered.upperBound + 1)))
        let start = top(of: block.rendered.location)
        let end = fraction > 0 ? top(of: block.rendered.upperBound) : start
        let maxY = max(0, frame.height - scroll.contentView.bounds.height)
        let y = min(maxY, max(0, start + fraction * (end - start) - offset))
        guard abs(scroll.contentView.bounds.origin.y - y) > 0.5 else { return }
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Scrolls so that the heading with `slug` is at the top.
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

/// Read-only rendered note (TextKit 1, needed for NSTextTable / NSTextBlock).
struct MarkdownPreview: NSViewRepresentable {
    private let box: TextBox
    var markdown: String { box.string }
    var noteId: String
    var renderer: MarkdownRenderer
    /// A collapsed preview renders when it is shown again, not on every change.
    var isShown = true
    var readableWidth: Bool
    var highlights: [String] = []
    var onLink: (URL) -> Void

    init(markdown: String, noteId: String, renderer: MarkdownRenderer, isShown: Bool = true, readableWidth: Bool,
         highlights: [String] = [], onLink: @escaping (URL) -> Void) {
        box = TextBox(markdown)
        self.noteId = noteId
        self.renderer = renderer
        self.isShown = isShown
        self.readableWidth = readableWidth
        self.highlights = highlights
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
        // Laid out only where shown: a contiguous layout redoes the whole note whenever the width changes (switching
        // the layout), which froze the app for seconds on notes below the huge-note threshold.
        tv.layoutManager?.allowsNonContiguousLayout = true
        tv.isEditable = false
        tv.isSelectable = true
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
        let style = "\(renderer.typography)|\(renderer.loadsRemoteImages)|\(highlights)"
        guard c.renderedStyle != style || !c.markdown.isLiterally(markdown) || c.noteId != noteId else { return }
        let sameNote = c.noteId == noteId
        let newTerms = c.highlights != highlights
        let typing = sameNote && c.renderedStyle == style
        c.markdown = markdown
        c.highlights = highlights
        c.renderedStyle = style
        c.noteId = noteId
        if typing {
            c.renderSoon()
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
        private var firstMatch: NSRange?
        var renderedStyle = ""
        var noteId = ""
        private var renderedWidth: CGFloat = 0
        private var lastRender = Date.distantPast
        private var pendingRender: DispatchWorkItem?
        /// While typing in the split layout the preview follows at most this often; a large note takes tens of
        /// milliseconds to render.
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

        /// Images are sized to the text width: re-render when it changes noticeably.
        func widthChanged() {
            guard renderer != nil, sizedToWidth, abs(imageWidth - renderedWidth) > 24 else { return }
            DispatchQueue.main.async { [weak self] in self?.render(keepScroll: true) }
        }

        /// Renders now when the preview has been idle, otherwise once the typing interval has passed.
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

        /// Notes longer than this (`quickLength`) render off the main thread, their start shown meanwhile:
        /// rendering a huge note takes seconds.
        static let backgroundLength = 200_000
        private var sizedToWidth = true
        private var generation = 0
        /// A render off the main thread is running; asked again meanwhile, the latest text renders when it is done
        /// (revealing the first match if any request wanted that).
        private var rendering = false
        private var renderAgain: (reveal: Bool, incremental: Bool)?
        /// What the text view shows.
        private var shown: Rendered?
        private let renderQueue = DispatchQueue(label: "io.github.malkafen.JoplinNative.preview", qos: .userInitiated)

        struct Rendered: @unchecked Sendable {
            /// Made where the note is rendered: copying a huge rendering takes a while.
            var text: NSTextStorage
            var firstMatch: NSRange?
            var sizedToWidth: Bool
            var markdown: String
            var blocks: [RenderedBlock]
            var headings: [String]
            var hasTOC: Bool
            var width: CGFloat
        }

        nonisolated static func rendered(_ markdown: String, _ renderer: MarkdownRenderer, width: CGFloat, highlights: [String]) -> Rendered {
            let document = renderer.renderDocument(markdown, maxImageWidth: width)
            let text = NSTextStorage(attributedString: document.text)
            let match = SearchHighlight.apply(highlights, to: text)
            return Rendered(text: text, firstMatch: match, sizedToWidth: document.sizedToWidth, markdown: markdown,
                            blocks: document.blocks, headings: document.headings, hasTOC: document.hasTOC, width: width)
        }

        /// Turns `storage`, which shows `old`, into `new` by replacing only the blocks whose source changed, so the
        /// rest keeps its layout: replacing everything re-lays out the note up to the visible part and blinks.
        /// False when blocks kept could render differently in `new`; the caller then shows `new` whole.
        static func splice(_ storage: NSTextStorage, showing old: Rendered, into new: Rendered) -> Bool {
            let o = old.blocks, n = new.blocks
            guard !o.isEmpty, !n.isEmpty, o.last?.rendered.upperBound == storage.length,
                  old.width == new.width || !old.sizedToWidth && !new.sizedToWidth else { return false }
            // Kept blocks must not depend on the changed ones: `[toc]`, numbered duplicate headings.
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
            // A block can change the spacing of its neighbours: those are replaced too.
            head = max(0, head - 1)
            tail = max(0, tail - 1)
            let oldStart = o[head].rendered.location, newStart = n[head].rendered.location
            let oldEnd = tail == 0 ? storage.length : o[o.count - tail].rendered.location
            let newEnd = tail == 0 ? new.text.length : n[n.count - tail].rendered.location
            guard oldStart == newStart, storage.length - oldEnd == new.text.length - newEnd,
                  newEnd - newStart <= backgroundLength else { return false }
            // Reference definitions change links in other blocks.
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

        private static let referenceDefinition = try! NSRegularExpression(pattern: #"(?m)^ {0,3}\[[^\]]+\]:"#)

        /// The first paragraphs of a long note.
        static func start(of markdown: String) -> String { markdown.leadingParagraphs(limit: 20_000) }

        /// `incremental`: only the text changed (typing), so unchanged blocks are kept.
        func render(keepScroll: Bool, reveal: Bool = false, incremental: Bool = false) {
            pendingRender?.cancel()
            pendingRender = nil
            guard textView != nil, var renderer else { return }
            generation += 1
            renderedWidth = imageWidth
            let markdown = self.markdown, highlights = self.highlights, width = renderedWidth
            guard markdown.quickLength > Self.backgroundLength else {
                show(Self.rendered(markdown, renderer, width: width, highlights: highlights), keepScroll: keepScroll, reveal: reveal,
                     incremental: incremental)
                return
            }
            if !keepScroll {
                show(Self.rendered(Self.start(of: markdown), renderer, width: width, highlights: highlights), keepScroll: false, reveal: false)
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
                let result = Self.rendered(markdown, background, width: width, highlights: highlights)
                RunLoop.main.perform(inModes: [.common]) {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.rendering = false
                        if self.generation == token { self.show(result, keepScroll: true, reveal: reveal, incremental: incremental) }
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
            firstMatch = result.firstMatch
            sizedToWidth = result.sizedToWidth
            defer {
                shown = result
                tv.blocks = result.blocks
                tv.onShow?()
            }
            if incremental, keepScroll, let old = shown, let storage = tv.textStorage, Self.splice(storage, showing: old, into: result) {
                if reveal { revealFirstMatch() }
                return
            }
            let scroll = tv.enclosingScrollView
            let origin = scroll?.contentView.bounds.origin ?? .zero
            // A new storage: replacing the text of the current one copies the attribute runs one by one, which takes
            // minutes for a huge note.
            lm.replaceTextStorage(result.text)
            if keepScroll, let scroll {
                scroll.contentView.scroll(to: origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            } else if !keepScroll {
                tv.scrollToBeginningOfDocument(nil)
            }
            if reveal { revealFirstMatch() }
        }

        /// Scrolls the first search match into the middle of the view.
        func revealFirstMatch() {
            guard let tv = textView, let match = firstMatch, let layoutManager = tv.layoutManager,
                  let container = tv.textContainer, let scroll = tv.enclosingScrollView else { return }
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

/// Split view whose divider can be taken away: a hidden pane still leaves the divider (and its last drawing) behind.
final class NoteSplitNSView: NSSplitView {
    var showsDivider = true {
        didSet { if oldValue != showsDivider { needsDisplay = true } }
    }
    override var dividerThickness: CGFloat { showsDivider ? super.dividerThickness : 0 }
    override func drawDivider(in rect: NSRect) {
        if showsDivider { super.drawDivider(in: rect) }
    }
}

/// Editor and preview in a native split view. Changing the layout collapses a pane instead of replacing the views:
/// loading a huge note into a new editor or preview takes a noticeable time, switching should not.
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
        /// Share of the width the editor takes in the split layout, as last dragged.
        private var fraction: CGFloat = 0.5
        static var minimumWidth: CGFloat { 220 }

        init(editor: Editor, preview: Preview) {
            self.editor = NSHostingView(rootView: editor)
            self.preview = NSHostingView(rootView: preview)
            // The panes take the size the split view gives them.
            self.editor.sizingOptions = []
            self.preview.sizingOptions = []
        }

        private weak var editorText: NSTextView?
        private weak var previewText: PreviewTextView?

        /// In the split layout the preview follows the editor's scrolling, so the edited text stays in view in both.
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

        /// Synced at once and again after the display: a far jump settles the editor's layout only while drawing.
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
            // The caret's line when it is in view, at the same height in both panes: blocks render taller or shorter
            // than their source (tables), so lining up the top lines can leave the edited line out of the preview.
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
            // The first line in view. After a jump (Vim `G`) it is not laid out yet: the scroll comes before the display.
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
            // Keys go to the pane that stays visible, not to a hidden text view.
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

/// Native token field for note tags with completion of existing tags.
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
