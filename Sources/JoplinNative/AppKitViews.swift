import AppKit
import SwiftUI

/// Read-only rendered note (TextKit 1, needed for NSTextTable / NSTextBlock).
struct MarkdownPreview: NSViewRepresentable {
    var markdown: String
    var noteId: String
    var fontSize: Double
    var renderer: MarkdownRenderer
    var onLink: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onLink: onLink) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let tv = NSTextView(usingTextLayoutManager: false)
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 22, height: 16)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        tv.delegate = context.coordinator
        scroll.documentView = tv
        context.coordinator.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.onLink = onLink
        guard let tv = c.textView else { return }
        let key = "\(fontSize)|\(markdown)"
        guard c.renderedKey != key || c.noteId != noteId else { return }
        let sameNote = c.noteId == noteId
        let origin = scroll.contentView.bounds.origin
        let width = max(200, scroll.contentSize.width - 60)
        tv.textStorage?.setAttributedString(renderer.render(markdown, maxImageWidth: min(width, 900)))
        c.renderedKey = key
        c.noteId = noteId
        if sameNote {
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        } else {
            tv.scrollToBeginningOfDocument(nil)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onLink: (URL) -> Void
        weak var textView: NSTextView?
        var renderedKey = ""
        var noteId = ""

        init(onLink: @escaping (URL) -> Void) {
            self.onLink = onLink
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL {
                onLink(url)
                return true
            }
            if let s = link as? String, let url = URL(string: s) {
                onLink(url)
                return true
            }
            return false
        }
    }
}

/// Native token field for note tags with completion of existing tags.
struct TagField: NSViewRepresentable {
    var tags: [String]
    var allTags: [String]
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
