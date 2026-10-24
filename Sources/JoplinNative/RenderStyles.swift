import AppKit

struct InlineStyle {
    var size: CGFloat
    var color: NSColor = .labelColor
    var bold = false
    var weight: NSFont.Weight = .semibold
    var italic = false
    var code = false
    var strike = false
    var underline = false
    var mark = false
    var kbd = false
    var script = 0
    var link: URL?
}

struct BlockStyle {
    var indent: CGFloat = 0
    var textBlocks: [NSTextBlock] = []
    var color: NSColor = .labelColor
    var listDepth = 0
    var inQuote = false
}

let subtleFill = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(white: 1, alpha: 0.075)
        : NSColor(white: 0, alpha: 0.045)
}

let stripeFill = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(white: 1, alpha: 0.035)
        : NSColor(white: 0, alpha: 0.022)
}

final class DecoratedBlock: NSTextBlock {
    var fill: NSColor?
    var bar: NSColor?
    var barWidth: CGFloat = 3
    var radius: CGFloat = 6
    var caption: String?
    var captionFont = NSFont.systemFont(ofSize: 10, weight: .medium)

    override init() {
        super.init()
        setContentWidth(100, type: .percentageValueType)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView?, characterRange charRange: NSRange,
                                 layoutManager: NSLayoutManager) {
        let rect = NSRect(x: frameRect.minX + width(for: .margin, edge: .minX),
                          y: frameRect.minY + width(for: .margin, edge: .minY),
                          width: frameRect.width - width(for: .margin, edge: .minX) - width(for: .margin, edge: .maxX),
                          height: frameRect.height - width(for: .margin, edge: .minY) - width(for: .margin, edge: .maxY))
        if let fill {
            fill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }
        if let bar {
            bar.setFill()
            let barRect = NSRect(x: rect.minX, y: rect.minY, width: barWidth, height: rect.height)
            NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
        if let caption, !caption.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: captionFont, .foregroundColor: NSColor.tertiaryLabelColor, .kern: 0.6]
            let text = NSAttributedString(string: caption.uppercased(), attributes: attrs)
            let size = text.size()
            let padding = width(for: .padding, edge: .maxX)
            text.draw(at: NSPoint(x: rect.maxX - size.width - max(8, padding - 2), y: rect.minY + 6))
        }
    }
}
