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
final class MarkdownTextView: NSTextView {
    var onDropFiles: (([URL]) -> String?)?
    var onPasteImage: ((Data) -> String?)?
    var pasteboard = NSPasteboard.general

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
    var fontSize: Double
    var monospaced: Bool
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
        tv.textContainerInset = NSSize(width: 18, height: 14)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 2
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
        c.highlighter.configure(fontSize: fontSize, monospaced: monospaced)
        tv.typingAttributes = c.highlighter.baseAttributes
        c.isLoading = true
        tv.string = text
        c.isLoading = false
        tv.undoManager?.removeAllActions()
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.scrollToBeginningOfDocument(nil)
        c.noteId = noteId
        c.fontKey = "\(fontSize)-\(monospaced)"
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let tv = c.textView else { return }
        bridge.textView = tv
        tv.isEditable = isEditable
        let fontKey = "\(fontSize)-\(monospaced)"
        if c.noteId != noteId {
            load(into: tv, context: context)
        } else if c.fontKey != fontKey {
            c.fontKey = fontKey
            c.highlighter.configure(fontSize: fontSize, monospaced: monospaced)
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
        var fontKey = ""
        var isLoading = false
        let highlighter = MarkdownHighlighter()

        init(_ parent: MarkdownEditor) {
            self.parent = parent
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

/// Lightweight regex-based Markdown syntax highlighting for the source editor.
final class MarkdownHighlighter {
    private(set) var baseAttributes: [NSAttributedString.Key: Any] = [:]
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
    private let inlineCode = re("`[^`\\n]+`")
    private let link = re("!?\\[[^\\]\\n]*\\]\\([^)\\n]*\\)|<https?://[^>\\s]+>|(?<![(<\\w])https?://[^\\s)>]+")
    private let listMarker = re("^[ \\t]*([-*+]|\\d+[.)])[ \\t]")
    private let checkbox = re("^[ \\t]*[-*+][ \\t]\\[[ xX]\\]")
    private let quote = re("^[ \\t]*>.*$")
    private let rule = re("^[ \\t]*([-*_])([ \\t]*\\1){2,}[ \\t]*$")
    private let fence = re("^[ \\t]*(```|~~~)[^\\n]*\\n[\\s\\S]*?(^[ \\t]*\\1[ \\t]*$|\\z)")
    private let html = re("</?[a-zA-Z][^>\\n]*>")

    func configure(fontSize: Double, monospaced: Bool) {
        let size = CGFloat(fontSize)
        baseFont = monospaced ? .monospacedSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size)
        boldFont = monospaced ? .monospacedSystemFont(ofSize: size, weight: .bold) : .boldSystemFont(ofSize: size)
        italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
        codeFont = .monospacedSystemFont(ofSize: size * 0.93, weight: .regular)
        let scales: [CGFloat] = [1.5, 1.3, 1.15, 1.05, 1.0, 1.0]
        headingFonts = scales.map { monospaced ? .monospacedSystemFont(ofSize: size * $0, weight: .bold) : .systemFont(ofSize: size * $0, weight: .bold) }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.2
        baseAttributes = [.font: baseFont, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph]
    }

    init() {
        configure(fontSize: 14, monospaced: false)
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

        storage.setAttributes(baseAttributes, range: range)

        func each(_ re: NSRegularExpression, _ body: (NSTextCheckingResult) -> Void) {
            re.enumerateMatches(in: text, range: range) { m, _, _ in if let m { body(m) } }
        }

        each(heading) { m in
            let level = m.range(at: 1).length
            storage.addAttribute(.font, value: self.headingFonts[level - 1], range: m.range)
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: m.range(at: 1))
        }
        each(bold) { storage.addAttribute(.font, value: self.boldFont, range: $0.range) }
        each(italic) { storage.addAttribute(.font, value: self.italicFont, range: $0.range) }
        each(strike) { m in
            storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.secondaryLabelColor], range: m.range)
        }
        each(html) { storage.addAttribute(.foregroundColor, value: NSColor.systemTeal, range: $0.range) }
        each(link) { storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: $0.range) }
        each(listMarker) { storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: $0.range(at: 1)) }
        each(checkbox) { storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: $0.range) }
        each(quote) { storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: $0.range) }
        each(rule) { storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: $0.range) }
        each(inlineCode) { m in
            storage.addAttributes([.font: self.codeFont, .foregroundColor: NSColor.systemPink], range: m.range)
        }
        each(fence) { m in
            storage.addAttributes([.font: self.codeFont, .foregroundColor: NSColor.secondaryLabelColor,
                                   .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.12)], range: m.range)
        }
    }
}
