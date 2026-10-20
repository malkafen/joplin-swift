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
        return storage.attribute(.jnCheckbox, at: index, effectiveRange: nil) as? Int
    }

    override func mouseDown(with event: NSEvent) {
        if let line = checkboxLine(at: convert(event.locationInWindow, from: nil)) {
            onCheckbox?(line)
            return
        }
        super.mouseDown(with: event)
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
                render(keepScroll: true)
                return
            }
            let item = DispatchWorkItem { [weak self] in self?.render(keepScroll: true) }
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
        private var renderAgain: Bool?
        private let renderQueue = DispatchQueue(label: "io.github.malkafen.JoplinNative.preview", qos: .userInitiated)

        private struct Rendered: @unchecked Sendable {
            /// Made where the note is rendered: copying a huge rendering takes a while.
            var text: NSTextStorage
            var firstMatch: NSRange?
            var sizedToWidth: Bool
        }

        nonisolated private static func rendered(_ markdown: String, _ renderer: MarkdownRenderer, width: CGFloat, highlights: [String]) -> Rendered {
            let document = renderer.renderDocument(markdown, maxImageWidth: width)
            let text = NSTextStorage(attributedString: document.text)
            let match = SearchHighlight.apply(highlights, to: text)
            return Rendered(text: text, firstMatch: match, sizedToWidth: document.sizedToWidth)
        }

        /// The first paragraphs of a long note.
        static func start(of markdown: String) -> String { markdown.leadingParagraphs(limit: 20_000) }

        func render(keepScroll: Bool, reveal: Bool = false) {
            pendingRender?.cancel()
            pendingRender = nil
            guard textView != nil, var renderer else { return }
            generation += 1
            renderedWidth = imageWidth
            let markdown = self.markdown, highlights = self.highlights, width = renderedWidth
            guard markdown.quickLength > Self.backgroundLength else {
                show(Self.rendered(markdown, renderer, width: width, highlights: highlights), keepScroll: keepScroll, reveal: reveal)
                return
            }
            if !keepScroll {
                show(Self.rendered(Self.start(of: markdown), renderer, width: width, highlights: highlights), keepScroll: false, reveal: false)
            }
            guard !rendering else {
                renderAgain = (renderAgain ?? false) || reveal
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
                        if self.generation == token { self.show(result, keepScroll: true, reveal: reveal) }
                        if let again = self.renderAgain {
                            self.renderAgain = nil
                            self.render(keepScroll: true, reveal: again)
                        }
                    }
                }
            }
        }

        private func show(_ result: Rendered, keepScroll: Bool, reveal: Bool) {
            defer { lastRender = Date() }
            guard let tv = textView, let lm = tv.layoutManager else { return }
            let scroll = tv.enclosingScrollView
            let origin = scroll?.contentView.bounds.origin ?? .zero
            firstMatch = result.firstMatch
            sizedToWidth = result.sizedToWidth
            // A new storage: replacing the text of the current one copies the attribute runs one by one, which takes
            // minutes for a huge note. Laid out only where shown, for the same reason.
            lm.allowsNonContiguousLayout = result.text.length > Self.backgroundLength
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

/// Editor and preview in a native split view. Changing the layout collapses a pane instead of replacing the views:
/// loading a huge note into a new editor or preview takes a noticeable time, switching should not.
struct NoteSplitView<Editor: View, Preview: View>: NSViewRepresentable {
    var layout: EditorLayout
    var editor: Editor
    var preview: Preview

    func makeCoordinator() -> Coordinator { Coordinator(editor: editor, preview: preview) }

    func makeNSView(context: Context) -> NSSplitView {
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = context.coordinator
        split.addArrangedSubview(context.coordinator.editor)
        split.addArrangedSubview(context.coordinator.preview)
        context.coordinator.split = split
        context.coordinator.apply(layout)
        return split
    }

    func updateNSView(_ split: NSSplitView, context: Context) {
        let c = context.coordinator
        c.editor.rootView = editor
        c.preview.rootView = preview
        c.apply(layout)
    }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
        let editor: NSHostingView<Editor>
        let preview: NSHostingView<Preview>
        weak var split: NSSplitView?
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

        func apply(_ new: EditorLayout) {
            guard new != layout, let split else { return }
            let old = layout
            layout = new
            let window = split.window
            // Keys go to the pane that stays visible, not to a hidden text view.
            let focused = (window?.firstResponder as? NSView).map { $0.isDescendant(of: split) } ?? false
            editor.isHidden = new == .preview
            preview.isHidden = new == .editor
            split.adjustSubviews()
            if new == .split { place() }
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
