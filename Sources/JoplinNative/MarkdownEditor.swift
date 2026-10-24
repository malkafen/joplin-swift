import AppKit
import SwiftUI

struct MarkdownEditor: NSViewRepresentable {
    private let box: TextBox
    var text: String { box.string }
    var noteId: String
    var typography: Typography
    var readableWidth: Bool
    var highlights: [String] = []
    var vimMode = false
    var onVimMode: (VimEngine.Mode) -> Void = { _ in }
    var isEditable: Bool
    var bridge: EditorBridge
    var stepper: SearchStepper?
    var onChange: (String) -> Void
    var onDropFiles: ([URL]) -> String?
    var onPasteImage: (Data) -> String?

    init(text: String, noteId: String, typography: Typography, readableWidth: Bool, highlights: [String] = [],
         vimMode: Bool = false, onVimMode: @escaping (VimEngine.Mode) -> Void = { _ in }, isEditable: Bool,
         bridge: EditorBridge, stepper: SearchStepper? = nil,
         onChange: @escaping (String) -> Void, onDropFiles: @escaping ([URL]) -> String?,
         onPasteImage: @escaping (Data) -> String?) {
        box = TextBox(text)
        self.noteId = noteId
        self.typography = typography
        self.readableWidth = readableWidth
        self.highlights = highlights
        self.vimMode = vimMode
        self.onVimMode = onVimMode
        self.isEditable = isEditable
        self.bridge = bridge
        self.stepper = stepper
        self.onChange = onChange
        self.onDropFiles = onDropFiles
        self.onPasteImage = onPasteImage
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false

        let tv = MarkdownTextView(usingTextLayoutManager: false)
        tv.textContainer?.replaceLayoutManager(SearchMarkingLayoutManager())
        tv.frame = NSRect(origin: .zero, size: scroll.contentSize)
        tv.layoutManager?.allowsNonContiguousLayout = true
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = true
        tv.smartInsertDeleteEnabled = false
        tv.drawsBackground = false
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 2
        tv.updateReadableInset()
        tv.delegate = context.coordinator
        tv.textStorage?.delegate = context.coordinator
        tv.onDropFiles = { context.coordinator.parent.onDropFiles($0) }
        tv.onPasteImage = { context.coordinator.parent.onPasteImage($0) }

        scroll.documentView = tv
        context.coordinator.textView = tv
        bridge.textView = tv
        tv.stepper = stepper
        stepper?.editor = tv
        configureVim(tv)
        load(into: tv, context: context)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.viewportChanged),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.viewportChanged),
                                               name: NSView.frameDidChangeNotification, object: scroll.contentView)
        return scroll
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    private func configureVim(_ tv: MarkdownTextView) {
        if vimMode, tv.vim == nil {
            let engine = VimEngine(textView: tv)
            let report = onVimMode
            engine.onModeChange = { report($0) }
            tv.vim = engine
            engine.reset()
            report(engine.mode)
        } else if !vimMode, let engine = tv.vim {
            tv.vim = nil
            if engine.mode != .insert { tv.setSelectedRange(NSRange(location: tv.selectedRange().location, length: 0)) }
        }
    }

    private func load(into tv: NSTextView, context: Context) {
        let c = context.coordinator
        c.noteId = noteId
        c.typography = typography
        c.lastText = text
        c.setText(text, typography: typography, in: tv, selection: nil)
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let tv = c.textView as? MarkdownTextView else { return }
        bridge.textView = tv
        tv.isEditable = isEditable && !c.isLoadingInBackground
        tv.maxLineWidth = readableWidth ? typography.readableWidth : nil
        configureVim(tv)
        let newTerms = c.searchTerms != highlights
        c.searchTerms = highlights
        guard c.noteId == noteId else {
            load(into: tv, context: context)
            return
        }
        if c.typography != typography {
            c.typography = typography
            c.highlighter.configure(typography)
            tv.typingAttributes = c.highlighter.baseAttributes
            if let storage = tv.textStorage { c.highlighter.restyle(storage) }
        }
        if !text.isLiterally(c.lastText) {
            c.lastText = text
            if tv.textStorage?.mutableString.isEqual(to: text) != true {
                c.setText(text, typography: typography, in: tv, selection: tv.selectedRange())
            }
        }
        if newTerms { c.revealFirstMatch() }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
        var parent: MarkdownEditor
        weak var textView: NSTextView?
        var noteId = ""
        var typography = Typography()
        var isLoading = false
        var lastText = ""
        var highlighter = MarkdownHighlighter()
        var searchTerms: [String] {
            get { (textView?.layoutManager as? SearchMarkingLayoutManager)?.searchTerms ?? [] }
            set { (textView?.layoutManager as? SearchMarkingLayoutManager)?.searchTerms = newValue }
        }
        private(set) var isLoadingInBackground = false
        private var generation = 0
        private let loadQueue = DispatchQueue(label: "io.github.malkafen.JoplinNative.editor", qos: .userInitiated)
        static let backgroundLength = 300_000

        init(_ parent: MarkdownEditor) {
            self.parent = parent
        }

        func setText(_ text: String, typography: Typography, in tv: NSTextView, selection: NSRange?) {
            generation += 1
            guard text.quickLength > Self.backgroundLength, tv.layoutManager != nil else {
                isLoadingInBackground = false
                highlighter.configure(typography)
                tv.typingAttributes = highlighter.baseAttributes
                replaceText(text, in: tv, selection: selection)
                return
            }
            if selection == nil {
                highlighter.configure(typography)
                tv.typingAttributes = highlighter.baseAttributes
                replaceText(text.leadingParagraphs(limit: 20_000), in: tv, selection: nil)
            }
            isLoadingInBackground = true
            tv.isEditable = false
            let token = generation
            let visible = selection.map { _ in highlighter.visibleRange } ?? NSRange(location: 0, length: 0)
            nonisolated(unsafe) let fresh = MarkdownHighlighter()
            fresh.configure(typography)
            loadQueue.async { [weak self] in
                let storage = NSTextStorage(string: text, attributes: fresh.baseAttributes)
                fresh.show(visible, in: storage)
                fresh.highlight(storage)
                nonisolated(unsafe) let ready = storage
                RunLoop.main.perform(inModes: [.common]) {
                    MainActor.assumeIsolated {
                        guard let self, self.generation == token, let tv = self.textView, let lm = tv.layoutManager else { return }
                        self.install(ready, highlighter: fresh, typography: typography, in: tv, layoutManager: lm, selection: selection)
                    }
                }
            }
        }

        private func replaceText(_ text: String, in tv: NSTextView, selection: NSRange?) {
            if let selection {
                guard tv.shouldChangeText(in: NSRange(location: 0, length: tv.textStorage?.length ?? 0), replacementString: text)
                else { return }
                highlighter.reset(keepingVisible: true)
                isLoading = true
                tv.string = text
                isLoading = false
                tv.didChangeText()
                let length = tv.textStorage?.length ?? 0
                tv.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
                return
            }
            highlighter.reset()
            isLoading = true
            tv.string = text
            isLoading = false
            tv.undoManager?.removeAllActions()
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            tv.scrollToBeginningOfDocument(nil)
            (tv as? MarkdownTextView)?.vim?.reset()
            revealFirstMatch()
        }

        private func install(_ storage: NSTextStorage, highlighter fresh: MarkdownHighlighter, typography loaded: Typography,
                             in tv: NSTextView, layoutManager lm: NSLayoutManager, selection: NSRange?) {
            isLoadingInBackground = false
            let origin = tv.enclosingScrollView?.contentView.bounds.origin
            tv.textStorage?.delegate = nil
            lm.replaceTextStorage(storage)
            storage.delegate = self
            highlighter = fresh
            tv.typingAttributes = fresh.baseAttributes
            tv.undoManager?.removeAllActions()
            tv.isEditable = parent.isEditable
            if let selection {
                tv.setSelectedRange(NSRange(location: min(selection.location, storage.length), length: 0))
                if let origin, let scroll = tv.enclosingScrollView {
                    scroll.contentView.scroll(to: origin)
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            } else {
                tv.setSelectedRange(NSRange(location: 0, length: 0))
                tv.scrollToBeginningOfDocument(nil)
                (tv as? MarkdownTextView)?.vim?.reset()
                revealFirstMatch()
            }
            if typography != loaded {
                fresh.configure(typography)
                tv.typingAttributes = fresh.baseAttributes
                fresh.restyle(storage)
            }
            viewportChanged()
        }

        func revealFirstMatch() {
            guard let tv = textView, let storage = tv.textStorage,
                  let first = SearchHighlight.ranges(of: searchTerms, in: storage.mutableString, limit: 1).first else { return }
            tv.scrollRangeToVisible(first)
            if tv.window != nil { tv.showFindIndicator(for: first) }
        }

        @objc func viewportChanged() {
            guard let tv = textView, let storage = tv.textStorage, let lm = tv.layoutManager, let container = tv.textContainer else { return }
            var rect = tv.visibleRect
            rect.origin.x -= tv.textContainerOrigin.x
            rect.origin.y -= tv.textContainerOrigin.y
            let glyphs = lm.glyphRange(forBoundingRect: rect, in: container)
            highlighter.show(lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil), in: storage)
        }

        func textDidChange(_ notification: Notification) {
            guard !isLoading, let tv = textView else { return }
            let text = tv.string
            lastText = text
            parent.onChange(text)
        }

        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            highlighter.highlight(textStorage, edited: editedRange)
        }
    }
}
