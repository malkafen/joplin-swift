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

struct MarkdownEditor: NSViewRepresentable {
    var text: String
    var noteId: String
    var typography: Typography
    var readableWidth: Bool
    var highlights: [String] = []
    var isEditable: Bool
    var bridge: EditorBridge
    var onChange: (String) -> Void
    var onDropFiles: ([URL]) -> String?
    var onPasteImage: (Data) -> String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false

        let tv = MarkdownTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
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
        load(into: tv, context: context)
        return scroll
    }

    private func load(into tv: NSTextView, context: Context) {
        let c = context.coordinator
        c.highlighter.configure(typography)
        c.highlighter.searchTerms = highlights
        tv.typingAttributes = c.highlighter.baseAttributes
        c.isLoading = true
        tv.string = text
        c.isLoading = false
        tv.undoManager?.removeAllActions()
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.scrollToBeginningOfDocument(nil)
        c.noteId = noteId
        c.typography = typography
        c.revealFirstMatch()
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let tv = c.textView as? MarkdownTextView else { return }
        bridge.textView = tv
        tv.isEditable = isEditable
        tv.maxLineWidth = readableWidth ? typography.readableWidth : nil
        if c.noteId != noteId {
            load(into: tv, context: context)
        } else if c.highlighter.searchTerms != highlights {
            c.highlighter.searchTerms = highlights
            if let storage = tv.textStorage { c.highlighter.highlight(storage) }
            c.revealFirstMatch()
        } else if c.typography != typography {
            c.typography = typography
            c.highlighter.configure(typography)
            tv.typingAttributes = c.highlighter.baseAttributes
            if let storage = tv.textStorage { c.highlighter.highlight(storage) }
        } else if tv.string != text {
            // Changed outside the editor (e.g. checkbox toggled in the preview).
            let selection = tv.selectedRange()
            if tv.shouldChangeText(in: NSRange(location: 0, length: (tv.string as NSString).length), replacementString: text) {
                c.isLoading = true
                tv.string = text
                c.isLoading = false
                tv.didChangeText()
            }
            let length = (text as NSString).length
            tv.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: MarkdownEditor
        weak var textView: NSTextView?
        var noteId = ""
        var typography = Typography()
        var isLoading = false
        let highlighter = MarkdownHighlighter()

        init(_ parent: MarkdownEditor) {
            self.parent = parent
        }

        /// Shows the first search match with the system find indicator.
        func revealFirstMatch() {
            guard let tv = textView,
                  let first = SearchHighlight.ranges(of: highlighter.searchTerms, in: tv.string).first else { return }
            tv.scrollRangeToVisible(first)
            if tv.window != nil { tv.showFindIndicator(for: first) }
        }

        func textDidChange(_ notification: Notification) {
            guard !isLoading, let tv = textView else { return }
            parent.onChange(tv.string)
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
    /// Words of the active search, marked like find results.
    var searchTerms: [String] = []
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

    /// Re-highlights the whole document; small documents are cheap enough, large ones only refresh the edited paragraphs.
    func highlight(_ storage: NSTextStorage, edited: NSRange? = nil) {
        let ns = storage.string as NSString
        var range = NSRange(location: 0, length: ns.length)
        if let edited, ns.length > 60_000 {
            range = ns.paragraphRange(for: NSRange(location: min(edited.location, ns.length), length: min(edited.length, ns.length - min(edited.location, ns.length))))
        }
        guard range.length > 0 else { return }
        let text = storage.string
        let syntax = NSColor.tertiaryLabelColor

        storage.setAttributes(baseAttributes, range: range)

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
        for r in SearchHighlight.ranges(of: searchTerms, in: text) where NSIntersectionRange(r, range).length > 0 {
            storage.addAttribute(.backgroundColor, value: SearchHighlight.color, range: r)
        }
    }
}
