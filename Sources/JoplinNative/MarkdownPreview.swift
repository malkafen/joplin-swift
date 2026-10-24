import AppKit
import SwiftUI

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
