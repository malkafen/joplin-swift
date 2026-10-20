import AppKit
import SwiftUI

/// Gives menu commands access to the active editor text view.
@MainActor
final class EditorBridge {
    weak var textView: NSTextView?

    func focus() {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
    }

    private func replace(_ range: NSRange, with text: String, select: NSRange?) {
        guard let tv = textView, tv.isEditable else { return }
        tv.window?.makeFirstResponder(tv)
        if tv.shouldChangeText(in: range, replacementString: text) {
            tv.textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: tv.typingAttributes))
            tv.didChangeText()
        }
        if let select { tv.setSelectedRange(select) }
        tv.scrollRangeToVisible(tv.selectedRange())
    }

    func insert(_ text: String) {
        guard let tv = textView else { return }
        let r = tv.selectedRange()
        replace(r, with: text, select: NSRange(location: r.location + (text as NSString).length, length: 0))
    }

    /// Wraps the selection (or a placeholder) in prefix/suffix; unwraps when already wrapped.
    func wrap(_ prefix: String, _ suffix: String? = nil, placeholder: String) {
        guard let tv = textView else { return }
        let suffix = suffix ?? prefix
        let r = tv.selectedRange()
        let selected = (tv.string as NSString).substring(with: r)
        let p = (prefix as NSString).length
        let s = (suffix as NSString).length
        if selected.hasPrefix(prefix), selected.hasSuffix(suffix), (selected as NSString).length >= p + s {
            let inner = (selected as NSString).substring(with: NSRange(location: p, length: (selected as NSString).length - p - s))
            replace(r, with: inner, select: NSRange(location: r.location, length: (inner as NSString).length))
            return
        }
        let inner = selected.isEmpty ? placeholder : selected
        replace(r, with: prefix + inner + suffix, select: NSRange(location: r.location + p, length: (inner as NSString).length))
    }

    /// Adds or removes a block prefix ("# ", "- ", "- [ ] ", "> ", "1. ") on every selected line.
    func toggleLinePrefix(_ prefix: String) {
        guard let tv = textView else { return }
        let ns = tv.string as NSString
        let lineRange = ns.lineRange(for: tv.selectedRange())
        var text = ns.substring(with: lineRange)
        let hadNewline = text.hasSuffix("\n")
        if hadNewline { text.removeLast() }
        var lines = text.components(separatedBy: "\n")
        let nonEmpty = lines.filter { !$0.isEmpty }
        let allHave = !nonEmpty.isEmpty && nonEmpty.allSatisfy { $0.hasPrefix(prefix) }
        let blockPrefix = try! NSRegularExpression(pattern: "^(#{1,6} |> |[-*+] \\[[ xX]\\] |[-*+] |\\d+\\. )")
        lines = lines.enumerated().map { index, line in
            if allHave { return String(line.dropFirst(prefix.count)) }
            if line.isEmpty && lines.count > 1 { return line }
            let stripped = blockPrefix.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length), withTemplate: "")
            let p = prefix == "1. " ? "\(index + 1). " : prefix
            return p + stripped
        }
        let result = lines.joined(separator: "\n") + (hadNewline ? "\n" : "")
        let caret = lineRange.location + (result as NSString).length - (hadNewline ? 1 : 0)
        replace(lineRange, with: result, select: NSRange(location: caret, length: 0))
    }

    func insertBlock(_ block: String) {
        guard let tv = textView else { return }
        let ns = tv.string as NSString
        let r = tv.selectedRange()
        let atLineStart = r.location == 0 || ns.character(at: r.location - 1) == 10
        insert((atLineStart ? "" : "\n") + block)
    }
}

/// NSTextView subclass that turns dropped/pasted files and images into Joplin resources.
final class MarkdownTextView: NSTextView, ReadableWidth {
    var onDropFiles: (([URL]) -> String?)?
    var onPasteImage: ((Data) -> String?)?
    var pasteboard = NSPasteboard.general
    var maxLineWidth: CGFloat? {
        didSet { if oldValue != maxLineWidth { updateReadableInset() } }
    }
    let minimumInset = NSSize(width: 24, height: 18)
    /// Vim key bindings, when enabled.
    var vim: VimEngine?

    override func keyDown(with event: NSEvent) {
        if let vim, vim.handle(event) { return }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        vim?.normalizeSelection()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        if changed { updateReadableInset() }
    }

    private func fileURLs(from pb: NSPasteboard) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender.draggingPasteboard)
        if !urls.isEmpty, let md = onDropFiles?(urls) {
            let point = convert(sender.draggingLocation, from: nil)
            let index = characterIndexForInsertion(at: point)
            setSelectedRange(NSRange(location: index, length: 0))
            insertText(md, replacementRange: selectedRange())
            return true
        }
        return super.performDragOperation(sender)
    }

    override func paste(_ sender: Any?) {
        let pb = pasteboard
        let urls = fileURLs(from: pb)
        if !urls.isEmpty, let md = onDropFiles?(urls) {
            insertText(md, replacementRange: selectedRange())
            return
        }
        let hasText = pb.availableType(from: [.string]) != nil
        if !hasText {
            let png = pb.data(forType: .png)
                ?? pb.data(forType: .tiff).flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
            if let png, let md = onPasteImage?(png) {
                insertText(md, replacementRange: selectedRange())
                return
            }
        }
        pasteAsPlainText(sender)
    }
}

/// Note text among a view's inputs. SwiftUI compares the inputs on every update, and comparing two copies of a huge
/// note with non-ASCII text takes most of a second; a reference is compared by identity.
final class TextBox {
    let string: String
    init(_ string: String) { self.string = string }
}

extension String {
    /// Same UTF-16 code units. `==` compares canonical equivalence, which takes most of a second on a huge note with
    /// non-ASCII text bridged from a text view.
    func isLiterally(_ other: String) -> Bool { (self as NSString).isEqual(to: other) }

    /// The size without reading the text: UTF-8 bytes of a native string, UTF-16 units of one bridged from a text
    /// view. Either way of counting converts the other kind of string as a whole.
    var quickLength: Int { utf8.withContiguousStorageIfAvailable(\.count) ?? (self as NSString).length }

    /// The first paragraphs, about `limit` long, cut before a blank line when there is one.
    func leadingParagraphs(limit: Int) -> String {
        guard quickLength > limit else { return self }
        if let head = utf8.withContiguousStorageIfAvailable({ bytes -> String in
            let end = limit
            var cut = end, line: Int?
            var i = end - 1
            while i > 0 {
                if bytes[i] == 10 {
                    if line == nil { line = i }
                    if bytes[i - 1] == 10 { cut = i - 1; break }
                }
                i -= 1
            }
            if i == 0 { cut = line ?? end }
            return String(decoding: UnsafeBufferPointer(rebasing: bytes[0..<cut]), as: UTF8.self)
        }) {
            return head
        }
        let ns = self as NSString
        let cut = ns.range(of: "\n\n", options: .backwards, range: NSRange(location: 0, length: limit)).location
        return ns.substring(to: cut == NSNotFound ? limit : cut)
    }
}

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
    var onChange: (String) -> Void
    var onDropFiles: ([URL]) -> String?
    var onPasteImage: (Data) -> String?

    init(text: String, noteId: String, typography: Typography, readableWidth: Bool, highlights: [String] = [],
         vimMode: Bool = false, onVimMode: @escaping (VimEngine.Mode) -> Void = { _ in }, isEditable: Bool,
         bridge: EditorBridge,
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

        // TextKit 1, laid out only where it is shown: TextKit 2 lays out a huge note far more slowly.
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
        if c.noteId != noteId {
            load(into: tv, context: context)
        } else if newTerms {
            c.revealFirstMatch()
        } else if c.typography != typography {
            c.typography = typography
            c.highlighter.configure(typography)
            tv.typingAttributes = c.highlighter.baseAttributes
            if let storage = tv.textStorage { c.highlighter.restyle(storage) }
        } else if !text.isLiterally(c.lastText) {
            // The text the editor reported comes back as the same string: only compare anything else.
            c.lastText = text
            guard !tv.string.isLiterally(text) else { return }
            // Changed outside the editor (e.g. checkbox toggled in the preview).
            c.setText(text, typography: typography, in: tv, selection: tv.selectedRange())
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
        var parent: MarkdownEditor
        weak var textView: NSTextView?
        var noteId = ""
        var typography = Typography()
        var isLoading = false
        /// The text last loaded or reported; when the model hands it back nothing needs comparing.
        var lastText = ""
        var highlighter = MarkdownHighlighter()
        /// Words of the active search, drawn over the text.
        var searchTerms: [String] {
            get { (textView?.layoutManager as? SearchMarkingLayoutManager)?.searchTerms ?? [] }
            set { (textView?.layoutManager as? SearchMarkingLayoutManager)?.searchTerms = newValue }
        }
        /// A huge note is being prepared off the main thread; meanwhile its start is shown, read-only.
        private(set) var isLoadingInBackground = false
        private var generation = 0
        private let loadQueue = DispatchQueue(label: "io.github.malkafen.JoplinNative.editor", qos: .userInitiated)
        /// Notes longer than this (`quickLength`) are put into a text storage and styled off the main thread: copying
        /// and scanning a note of hundreds of thousands of lines takes a noticeable part of a second.
        static let backgroundLength = 300_000

        init(_ parent: MarkdownEditor) {
            self.parent = parent
        }

        /// Shows `text`: a new note (selection nil: at the top, undo cleared) or a change made outside the editor.
        func setText(_ text: String, typography: Typography, in tv: NSTextView, selection: NSRange?) {
            generation += 1
            // The length in UTF-8 is known without reading a native string.
            guard text.quickLength > Self.backgroundLength, tv.layoutManager != nil else {
                isLoadingInBackground = false
                highlighter.configure(typography)
                tv.typingAttributes = highlighter.baseAttributes
                replaceText(text, in: tv, selection: selection)
                return
            }
            if selection == nil {
                // The start at once, in the old storage: a new one is laid out from scratch.
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

        /// Puts a storage prepared off the main thread into the editor.
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
                // Each change of the text is its own step of undo otherwise; replacing a huge note is not undoable.
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
            // Settings changed while the note was being prepared.
            if typography != loaded {
                fresh.configure(typography)
                tv.typingAttributes = fresh.baseAttributes
                fresh.restyle(storage)
            }
            viewportChanged()
        }

        /// Shows the first search match with the system find indicator.
        func revealFirstMatch() {
            guard let tv = textView, let storage = tv.textStorage,
                  let first = SearchHighlight.ranges(of: searchTerms, in: storage.mutableString, limit: 1).first else { return }
            tv.scrollRangeToVisible(first)
            if tv.window != nil { tv.showFindIndicator(for: first) }
        }

        /// Styles the text that has scrolled into view.
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

/// Lightweight regex-based Markdown syntax highlighting for the source editor. Markup characters are dimmed so
/// the text reads like the rendered note, and fenced code is coloured like in the preview.
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

    /// Kept for callers that only pick a size and monospacing.
    func configure(fontSize: Double, monospaced: Bool) {
        configure(Typography(family: monospaced ? .monospaced : .system, size: CGFloat(fontSize)))
    }

    init() {
        configure(Typography())
    }

    /// The note is styled within this many characters around the visible text and keeps the base style beyond:
    /// attribute runs across all of a huge note make every later change to it slow. Short notes fit entirely.
    var radius = 50_000
    /// Fenced code or display math longer than this is styled only where it overlaps what is being refreshed.
    var maxBlock = 100_000

    /// Fenced code and display math, the only constructs that span lines, as found in the current text.
    private var blocks: [NSRange] = []
    /// Where the delimiters of blocks are in the current text.
    private var marks = Marks()
    private var highlightedLength: Int?
    /// The styled part of the text, whole lines.
    private(set) var window = NSRange(location: 0, length: 0)
    /// What the editor shows; the window follows it.
    private var visible = NSRange(location: 0, length: 0)
    var visibleRange: NSRange { visible }

    /// Forgets the text: the next `highlight` styles a new document.
    func reset(keepingVisible: Bool = false) {
        highlightedLength = nil
        if !keepingVisible { visible = NSRange(location: 0, length: 0) }
    }

    /// Delimiters of fenced code and display math, found in one pass over the text: regular expressions and literal
    /// searches over a note of hundreds of thousands of lines take most of a second.
    struct Marks: Equatable {
        /// Starts of the lines ("\n" ends a line) that contain "```", "~~~" or "$": only an edit on such a line can
        /// move a block.
        var lines: [Int] = []
        /// Where a fence may open or close: a line start followed by blanks and three or more "`" or "~".
        var fences: [Int] = []
        /// Every "$".
        var dollars: [Int] = []
    }

    /// Line terminators for "^" and "$" of the patterns (multiline ICU).
    private static func isTerminator(_ c: unichar) -> Bool {
        c == 10 || c == 13 || c == 0x85 || c == 0x2028 || c == 0x2029
    }

    /// The marks within `range`, which starts at the start of a line.
    static func marks(in ns: NSString, range: NSRange) -> Marks {
        var m = Marks()
        var buffer = [unichar](repeating: 0, count: 65_536)
        var lineStart = range.location
        // Where the current line's leading blanks start, while only blanks follow a line terminator.
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
                case 96, 126: // ` ~
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
                case 36: // $
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

    /// Fenced code as the `fence` pattern finds it, from the fence marks.
    private static func fenceBlocks(_ ns: NSString, _ fences: [Int]) -> [NSRange] {
        let length = ns.length
        func skipBlanks(_ p: Int) -> Int {
            var p = p
            while p < length, ns.character(at: p) == 32 || ns.character(at: p) == 9 { p += 1 }
            return p
        }
        /// End of the closing line at `q` (before its terminator) if it closes a fence of `d`.
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

    /// Display math spanning lines as the `math` pattern finds it, tried only where a "$" is.
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

    /// The same blocks found with the patterns over the whole text, for tests.
    func referenceBlocks(in text: String) -> [NSRange] {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        let spanning = math.matches(in: text, range: all).map(\.range)
            .filter { ns.rangeOfCharacter(from: .newlines, range: $0).location != NSNotFound }
        return (fence.matches(in: text, range: all).map(\.range) + spanning).sorted { $0.location < $1.location }
    }

    /// Blocks found from the marks, for tests.
    func scannedBlocks(in text: String) -> [NSRange] {
        let ns = text as NSString
        marks = Self.marks(in: ns, range: NSRange(location: 0, length: ns.length))
        return multilineBlocks(in: text, ns)
    }

    /// Whole lines around `range`. Only "\n" ends a line, as in the patterns: `[^\n]` runs through "\r" and U+2028,
    /// which `paragraphRange(for:)` would split at.
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

    /// Updates the marks for an edit that replaced the old version of `lines` (whole lines, new coordinates).
    /// Returns whether a delimiter line was removed, added or changed.
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

    /// Where the blocks are after an edit that touched no delimiter line: none starts or ends in the edited lines.
    private func shifted(_ lines: NSRange, delta: Int, oldLength: Int, newLength: Int) -> [NSRange] {
        let oldEnd = NSMaxRange(lines) - delta
        return blocks.map { b in
            if b.location >= oldEnd { return NSRange(location: b.location + delta, length: b.length) }
            // An unclosed fence runs to the end of the text.
            if NSMaxRange(b) == oldLength { return NSRange(location: b.location, length: newLength - b.location) }
            if NSMaxRange(b) <= lines.location { return b }
            return NSRange(location: b.location, length: b.length + delta)
        }
    }

    /// Whether a block starts or ends within `lines`.
    private static func bounded(_ blocks: [NSRange], in lines: NSRange) -> Bool {
        blocks.contains { NSLocationInRange($0.location, lines) || NSLocationInRange(max($0.location, NSMaxRange($0) - 1), lines) }
    }

    /// `range` (whole lines) grown to the blocks it overlaps, except blocks too long to restyle at once.
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

    /// Whole lines around the visible text to style.
    private func target(_ ns: NSString) -> NSRange {
        let start = max(0, min(visible.location, ns.length) - radius)
        let end = min(ns.length, NSMaxRange(visible) + radius)
        return grown(Self.lines(around: NSRange(location: start, length: max(0, end - start)), in: ns), ns)
    }

    /// Where a range of the old text is after the edit.
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

    /// Styles a new document, or after an edit only the lines (and blocks) it touched.
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
        // One character more: an inserted line break starts a new line after the edit.
        let lines = Self.lines(around: NSRange(location: location, length: min(clamped.length + 1, length - location)), in: ns)
        let moved = shifted(lines, delta: delta, oldLength: previous, newLength: length)
        let changed = updateMarks(lines, delta: delta, ns)
        let found = changed ? multilineBlocks(in: storage.string, ns) : moved
        // A block that starts or ends on an edited line is another block, even where it lines up with an old one.
        let oldLines = NSRange(location: lines.location, length: max(0, lines.length - delta))
        let restructured = found != moved || changed && (Self.bounded(blocks, in: oldLines) || Self.bounded(found, in: lines))
        blocks = found
        highlightedLength = length
        window = Self.map(window, edited: clamped, delta: delta, length: length)
        visible = Self.map(visible, edited: clamped, delta: delta, length: length)
        let outside = NSMaxRange(lines) < window.location || lines.location > NSMaxRange(window)
        if restructured {
            // A block opened or closed: everything after it may have changed.
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

    /// Follows the visible text: styles around it and returns the rest to the base style.
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

    /// Applies new base attributes everywhere, e.g. after a font change.
    func restyle(_ storage: NSTextStorage) {
        guard highlightedLength == storage.length else { return highlight(storage) }
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: NSRange(location: 0, length: storage.length))
        apply(window, to: storage)
        storage.endEditing()
    }

    /// Styles `range` (whole lines; blocks inside it whole, except those longer than `maxBlock`).
    private func apply(_ range: NSRange, to storage: NSTextStorage) {
        guard range.length > 0 else { return }
        let text = storage.string
        let ns = storage.mutableString as NSString
        storage.setAttributes(baseAttributes, range: range)
        // Long blocks reaching out of the range are styled by hand; the patterns see the text around them.
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

    /// The part `visible` of a long fenced block or display math, styled like the whole block would be.
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
