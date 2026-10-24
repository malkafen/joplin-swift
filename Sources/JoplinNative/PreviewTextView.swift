import AppKit

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
