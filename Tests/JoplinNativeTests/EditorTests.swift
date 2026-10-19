import AppKit
import Foundation
import Testing
@testable import JoplinNative

@MainActor
@Suite struct EditorBridgeTests {
    private func bridge(_ text: String, selection: NSRange? = nil) -> (EditorBridge, NSTextView) {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        tv.allowsUndo = true
        tv.string = text
        tv.setSelectedRange(selection ?? NSRange(location: (text as NSString).length, length: 0))
        let bridge = EditorBridge()
        bridge.textView = tv
        return (bridge, tv)
    }

    @Test func withoutTextViewEverythingIsANoOp() {
        let bridge = EditorBridge()
        bridge.focus()
        bridge.insert("x")
        bridge.wrap("**", placeholder: "p")
        bridge.toggleLinePrefix("# ")
        bridge.insertBlock("---")
        #expect(bridge.textView == nil)
    }

    @Test func insertMovesTheCaret() {
        let (bridge, tv) = bridge("ab", selection: NSRange(location: 1, length: 0))
        bridge.focus()
        bridge.insert("XY")
        #expect(tv.string == "aXYb")
        #expect(tv.selectedRange() == NSRange(location: 3, length: 0))
    }

    @Test func readOnlyEditorIsNotChanged() {
        let (bridge, tv) = bridge("ab")
        tv.isEditable = false
        bridge.insert("x")
        #expect(tv.string == "ab")
    }

    @Test func wrapSelectionOrPlaceholder() {
        let (bridge, tv) = bridge("say hello", selection: NSRange(location: 4, length: 5))
        bridge.wrap("**", placeholder: "bold")
        #expect(tv.string == "say **hello**")
        #expect(tv.selectedRange() == NSRange(location: 6, length: 5))

        tv.setSelectedRange(NSRange(location: 4, length: 9))
        bridge.wrap("**", placeholder: "bold")
        #expect(tv.string == "say hello")
        #expect(tv.selectedRange() == NSRange(location: 4, length: 5))

        tv.setSelectedRange(NSRange(location: 0, length: 0))
        bridge.wrap("[", "](https://)", placeholder: "link")
        #expect(tv.string == "[link](https://)say hello")
        #expect(tv.selectedRange() == NSRange(location: 1, length: 4))
    }

    @Test func wrapTooShortToUnwrap() {
        // "**" starts and ends with the marker but has nothing inside, so it gets wrapped, not unwrapped.
        let (bridge, tv) = bridge("**", selection: NSRange(location: 0, length: 2))
        bridge.wrap("**", placeholder: "p")
        #expect(tv.string == "******")
    }

    @Test func togglesLinePrefixesOnSelectedLines() {
        let (bridge, tv) = bridge("one\ntwo\n\nthree\n", selection: NSRange(location: 0, length: 13))
        bridge.toggleLinePrefix("- ")
        #expect(tv.string == "- one\n- two\n\n- three\n")

        tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
        bridge.toggleLinePrefix("- ")
        #expect(tv.string == "one\ntwo\n\nthree\n")

        tv.setSelectedRange(NSRange(location: 0, length: 7))
        bridge.toggleLinePrefix("1. ")
        #expect(tv.string == "1. one\n2. two\n\nthree\n")

        // Switching block type replaces the old marker.
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        bridge.toggleLinePrefix("# ")
        #expect(tv.string.hasPrefix("# one\n"))
        bridge.toggleLinePrefix("- [ ] ")
        #expect(tv.string.hasPrefix("- [ ] one\n"))
    }

    @Test func togglePrefixOnEmptyLine() {
        let (bridge, tv) = bridge("")
        bridge.toggleLinePrefix("> ")
        #expect(tv.string == "> ")
        #expect(tv.selectedRange().location == 2)
    }

    @Test func insertBlockStartsOnANewLine() {
        let (bridge, tv) = bridge("text")
        bridge.insertBlock("---\n")
        #expect(tv.string == "text\n---\n")
        bridge.insertBlock("***")
        #expect(tv.string == "text\n---\n***")

        let (empty, etv) = self.bridge("")
        empty.insertBlock("x")
        #expect(etv.string == "x")
    }
}

@MainActor
@Suite struct MarkdownHighlighterTests {
    private func highlighted(_ text: String, monospaced: Bool = false, edited: NSRange? = nil) -> (NSTextStorage, MarkdownHighlighter) {
        let h = MarkdownHighlighter()
        h.configure(fontSize: 14, monospaced: monospaced)
        let storage = NSTextStorage(string: text)
        h.highlight(storage, edited: edited)
        return (storage, h)
    }

    private func attr(_ s: NSTextStorage, _ key: NSAttributedString.Key, at needle: String) -> Any? {
        let r = (s.string as NSString).range(of: needle)
        return s.attribute(key, at: r.location, effectiveRange: nil)
    }

    @Test func highlightsMarkdownSyntax() throws {
        let text = """
        # Title
        **bold** *it* _under_ ~~strike~~ `code` <b>tag</b>
        [link](https://x.y) https://bare.example
        - item
        - [ ] box
        > quote
        ---
        ```
        fenced
        ```
        """
        let (s, h) = highlighted(text)
        let title = try #require(attr(s, .font, at: "Title") as? NSFont)
        #expect(title.pointSize == 21)
        #expect(attr(s, .foregroundColor, at: "#") as? NSColor == .tertiaryLabelColor)
        #expect((attr(s, .font, at: "bold") as? NSFont).map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true)
        #expect((attr(s, .font, at: "it*") as? NSFont).map { NSFontManager.shared.traits(of: $0).contains(.italicFontMask) } == true)
        #expect((attr(s, .font, at: "under") as? NSFont).map { NSFontManager.shared.traits(of: $0).contains(.italicFontMask) } == true)
        #expect(attr(s, .strikethroughStyle, at: "strike") as? Int == NSUnderlineStyle.single.rawValue)
        #expect(attr(s, .foregroundColor, at: "code") as? NSColor == .systemPink)
        #expect(attr(s, .foregroundColor, at: "<b>") as? NSColor == .systemTeal)
        #expect(attr(s, .foregroundColor, at: "link]") as? NSColor == .linkColor)
        #expect(attr(s, .foregroundColor, at: "[link]") as? NSColor == .tertiaryLabelColor)
        #expect(attr(s, .foregroundColor, at: "](https") as? NSColor == .tertiaryLabelColor)
        #expect(attr(s, .foregroundColor, at: "**bold") as? NSColor == .tertiaryLabelColor)
        #expect(attr(s, .foregroundColor, at: "https://bare") as? NSColor == .linkColor)
        #expect(attr(s, .foregroundColor, at: "- item") as? NSColor == .controlAccentColor)
        #expect(attr(s, .foregroundColor, at: "[ ]") as? NSColor == .controlAccentColor)
        #expect(attr(s, .foregroundColor, at: "> quote") as? NSColor == .secondaryLabelColor)
        #expect(attr(s, .foregroundColor, at: "---") as? NSColor == .tertiaryLabelColor)
        #expect((attr(s, .font, at: "fenced") as? NSFont)?.isFixedPitch == true)
        #expect(h.baseAttributes[.font] as? NSFont == NSFont.systemFont(ofSize: 14))
    }

    @Test func markHighlightMathAndFencedCode() throws {
        let text = "==mark== $x^2$\n```swift\nlet a = \"s\" // c\n```\n```\nplain\n"
        let (s, _) = highlighted(text)
        #expect(attr(s, .backgroundColor, at: "mark") != nil)
        #expect(attr(s, .foregroundColor, at: "x^2") as? NSColor == .systemIndigo)
        #expect(attr(s, .foregroundColor, at: "let") as? NSColor == .systemPink)
        #expect(attr(s, .foregroundColor, at: "\"s\"") as? NSColor == .systemRed)
        #expect(attr(s, .foregroundColor, at: "// c") as? NSColor == .secondaryLabelColor)
        #expect(attr(s, .foregroundColor, at: "```swift") as? NSColor == .tertiaryLabelColor)
        #expect(attr(s, .foregroundColor, at: "plain") as? NSColor == .labelColor)
    }

    @Test func fontFamilies() throws {
        let h = MarkdownHighlighter()
        h.configure(Typography(family: .serif, size: 16))
        let font = try #require(h.baseAttributes[.font] as? NSFont)
        #expect(font.pointSize == 16)
        #expect(font.fontDescriptor.symbolicTraits.contains(.monoSpace) == false)
    }

    @Test func monospacedConfiguration() {
        let (s, h) = highlighted("# Mono\ntext", monospaced: true)
        #expect((h.baseAttributes[.font] as? NSFont)?.isFixedPitch == true)
        #expect((attr(s, .font, at: "Mono") as? NSFont)?.isFixedPitch == true)
    }

    @Test func emptyTextIsIgnored() {
        let (s, _) = highlighted("")
        #expect(s.length == 0)
    }

    @Test func largeDocumentsOnlyRefreshTheEditedParagraph() {
        let filler = String(repeating: "plain line of text\n", count: 4_000)
        let text = "**first**\n" + filler + "**last**"
        let storage = NSTextStorage(string: text)
        let h = MarkdownHighlighter()
        let editedLocation = (text as NSString).length - 3
        h.highlight(storage, edited: NSRange(location: editedLocation, length: 1))
        let first = storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        let last = storage.attribute(.font, at: editedLocation, effectiveRange: nil) as? NSFont
        #expect(first.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } != true)
        #expect(last.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true)

        // An edit range past the end is clamped instead of crashing.
        h.highlight(storage, edited: NSRange(location: 1_000_000, length: 5))
    }
}

@MainActor
@Suite struct MarkdownTextViewTests {
    private func textView() -> (MarkdownTextView, NSPasteboard) {
        let tv = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        tv.isRichText = false
        let pb = NSPasteboard(name: NSPasteboard.Name("jn-paste-\(UUID().uuidString)"))
        tv.pasteboard = pb
        return (tv, pb)
    }

    @Test func pastingFilesCreatesAttachments() throws {
        let (tv, pb) = textView()
        let file = temporaryDirectory().appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: file)
        var received: [URL] = []
        tv.onDropFiles = { urls in received = urls; return "[a.txt](:/x)" }
        pb.clearContents()
        pb.writeObjects([file as NSURL])
        tv.paste(nil)
        #expect(received.map(\.lastPathComponent) == ["a.txt"])
        #expect(tv.string == "[a.txt](:/x)")
        pb.releaseGlobally()
    }

    @Test func pastingImagesCreatesResources() throws {
        let (tv, pb) = textView()
        var pasted: [Data] = []
        tv.onPasteImage = { data in pasted.append(data); return "![img](:/\(pasted.count))" }

        pb.clearContents()
        pb.setData(tinyPNG, forType: .png)
        tv.paste(nil)
        #expect(pasted.first == tinyPNG)

        let tiff = try #require(NSImage(data: tinyPNG)?.tiffRepresentation)
        pb.clearContents()
        pb.setData(tiff, forType: .tiff)
        tv.paste(nil)
        #expect(pasted.count == 2)
        #expect(NSImage(data: pasted[1]) != nil)
        #expect(tv.string == "![img](:/1)![img](:/2)")
        pb.releaseGlobally()
    }

    @Test func declinedPasteFallsBackToPlainText() {
        let (tv, pb) = textView()
        tv.onPasteImage = { _ in nil }
        tv.onDropFiles = { _ in nil }
        pb.clearContents()
        pb.setData(tinyPNG, forType: .png)
        tv.paste(nil)
        pb.clearContents()
        pb.setString("text", forType: .string)
        tv.paste(nil)
        #expect(!tv.string.contains("img"))
        pb.releaseGlobally()
    }
}
