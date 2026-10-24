import AppKit
import SwiftUI

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
                preview.scroll(toSource: 0, offset: preview.textContainerOrigin.y)
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
