import AppKit
import Foundation
@testable import JoplinCore
import Testing
@testable import JoplinNative

@MainActor
@Suite struct MarkdownRendererTests {
    private let store: Store
    private let image: Resource
    private let brokenImage: Resource
    private let file: Resource

    init() throws {
        store = try Store(directory: temporaryDirectory())
        image = try store.addResource(data: tinyPNG, filename: "dot.png", mime: "image/png", fileExtension: "png")
        brokenImage = try store.addResource(data: Data("not an image".utf8), filename: "broken.png", mime: "image/png", fileExtension: "png")
        file = try store.addResource(data: Data("pdf".utf8), filename: "report.pdf", mime: "application/pdf", fileExtension: "pdf")
    }

    private var renderer: MarkdownRenderer {
        let store = self.store
        return MarkdownRenderer(baseSize: 14) { id in store.resource(id: id).map { ($0, store.url(for: $0)) } }
    }

    private func render(_ md: String, maxImageWidth: CGFloat = 640) -> NSAttributedString {
        renderer.render(md, maxImageWidth: maxImageWidth)
    }

    private func attribute<T>(_ key: NSAttributedString.Key, of text: String, in s: NSAttributedString, as: T.Type = T.self) -> T? {
        let r = (s.string as NSString).range(of: text)
        guard r.location != NSNotFound else { return nil }
        return s.attribute(key, at: r.location, effectiveRange: nil) as? T
    }

    private func paragraph(of text: String, in s: NSAttributedString) -> NSParagraphStyle? {
        attribute(.paragraphStyle, of: text, in: s)
    }

    private func font(of text: String, in s: NSAttributedString) -> NSFont? {
        attribute(.font, of: text, in: s)
    }

    @Test func emptyDocument() {
        #expect(render("").string == "")
    }

    @Test func paragraphsAndTrailingNewline() {
        let s = render("first\nsoft\n\nsecond  \nhard")
        #expect(s.string == "first soft\nsecond\u{2028}hard")
    }

    @Test func headingsGetSizesAndUnderlines() throws {
        let s = render("# One\n## Two\n### Three\n###### Six")
        let one = try #require(font(of: "One", in: s))
        let three = try #require(font(of: "Three", in: s))
        let six = try #require(font(of: "Six", in: s))
        #expect(one.pointSize > three.pointSize)
        #expect(three.pointSize > six.pointSize)
        #expect(NSFontManager.shared.weight(of: one) > NSFontManager.shared.weight(of: NSFont.systemFont(ofSize: 14)))
        #expect(paragraph(of: "One", in: s)?.textBlocks.count == 1)
        #expect(paragraph(of: "Two", in: s)?.textBlocks.count == 1)
        #expect(paragraph(of: "Three", in: s)?.textBlocks.isEmpty == true)
    }

    @Test func inlineStyles() throws {
        let s = render("*it* **bold** ~~gone~~ `code` ***both***")
        #expect(s.string == "it bold gone code both")
        let italic = try #require(font(of: "it", in: s))
        #expect(NSFontManager.shared.traits(of: italic).contains(.italicFontMask))
        #expect(attribute(.strikethroughStyle, of: "gone", in: s, as: Int.self) == NSUnderlineStyle.single.rawValue)
        #expect(font(of: "code", in: s)?.isFixedPitch == true)
        #expect(attribute(.backgroundColor, of: "code", in: s, as: NSColor.self) != nil)
        let both = try #require(font(of: "both", in: s))
        #expect(NSFontManager.shared.traits(of: both).contains(.italicFontMask))
    }

    @Test func links() throws {
        let s = render("[site](https://example.com) <https://auto.link> [spaced](<a b>) [empty]() [](https://bare.example)")
        #expect(attribute(.link, of: "site", in: s, as: URL.self) == URL(string: "https://example.com"))
        #expect(attribute(.link, of: "https://auto.link", in: s, as: URL.self) == URL(string: "https://auto.link"))
        #expect(attribute(.link, of: "spaced", in: s, as: URL.self) == URL(string: "a%20b"))
        #expect(attribute(.link, of: "empty", in: s, as: URL.self) == nil)
        #expect(s.string.hasSuffix("https://bare.example"))
    }

    @Test func internalLinks() throws {
        let note = fixtureId(404)
        let s = render("[Doc](:/\(file.id)) [](:/\(file.id)) [Other note](:/\(note))")
        #expect(s.string == "📎 Doc 📎 report.pdf Other note")
        #expect(attribute(.link, of: "Doc", in: s, as: URL.self) == URL(string: "joplinitem://\(file.id)"))
        #expect(attribute(.link, of: "Other note", in: s, as: URL.self) == URL(string: "joplinitem://\(note)"))
    }

    @Test func images() throws {
        let s = render("![dot](:/\(image.id))", maxImageWidth: 0.5)
        let attachment = try #require(s.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        #expect(attachment.bounds.width == 0.5)
        #expect(s.attribute(.link, at: 0, effectiveRange: nil) as? URL == URL(string: "joplinitem://\(image.id)"))
        // Served from the cache the second time.
        #expect(render("![](:/\(image.id))").attribute(.attachment, at: 0, effectiveRange: nil) != nil)

        #expect(render("![](:/\(brokenImage.id))").string == "📎 broken.png")
        #expect(render("![Report](:/\(file.id))").string == "📎 Report")
        let external = render("![logo](https://x.y/logo.png) ![](https://x.y/a.png) ![missing](:/\(fixtureId(404)))")
        #expect(external.string == "🖼 logo 🖼 https://x.y/a.png 🖼 missing")
        #expect(attribute(.link, of: "logo", in: external, as: URL.self) == URL(string: "https://x.y/logo.png"))
    }

    @Test func codeBlocksStayInOneParagraph() throws {
        let s = render("```swift\nlet a = 1\nlet b = 2\n\n```\n\n    indented")
        #expect(s.string == "let a = 1\u{2028}let b = 2\nindented")
        #expect(font(of: "let a", in: s)?.isFixedPitch == true)
        #expect(paragraph(of: "let a", in: s)?.textBlocks.first?.backgroundColor != nil)
    }

    @Test func blockQuotes() throws {
        let s = render("> quoted **text**\n>\n> > nested")
        #expect(s.string == "quoted text\nnested")
        #expect(attribute(.foregroundColor, of: "quoted", in: s, as: NSColor.self) == .secondaryLabelColor)
        #expect(paragraph(of: "nested", in: s)?.textBlocks.count == 2)
    }

    @Test func lists() throws {
        let s = render("""
        - one
          - nested
            - deeper
              - wrap
        - two

        3. three
        4. four
        """)
        #expect(s.string == "•\tone\n◦\tnested\n▪︎\tdeeper\n•\twrap\n•\ttwo\n3.\tthree\n4.\tfour")
        let one = try #require(paragraph(of: "one", in: s))
        let nested = try #require(paragraph(of: "nested", in: s))
        #expect(nested.headIndent > one.headIndent)
        #expect(one.tabStops.first?.location == one.headIndent)
        #expect(paragraph(of: "four", in: s)?.paragraphSpacing == 10)
    }

    @Test func checklists() throws {
        let s = render("intro\n\n- [ ] todo\n- [x] done")
        #expect(s.string == "intro\n☐\ttodo\n☑︎\tdone")
        #expect(attribute(.link, of: "☐", in: s, as: URL.self) == URL(string: "joplincheckbox://3"))
        #expect(attribute(.link, of: "☑︎", in: s, as: URL.self) == URL(string: "joplincheckbox://4"))
        #expect(attribute(.foregroundColor, of: "done", in: s, as: NSColor.self) == .secondaryLabelColor)
        #expect(attribute(.foregroundColor, of: "todo", in: s, as: NSColor.self) == .labelColor)
    }

    @Test func listItemsWithBlocksAndEmptyItems() throws {
        let s = render("- ```\n  code\n  ```\n-\n- after")
        #expect(s.string == "•\t\ncode\n•\t\n•\tafter")
    }

    @Test func tables() throws {
        let s = render("""
        | Left | Center | Right | Plain |
        |:-----|:------:|------:|-------|
        | a | b | c | d |
        | short |
        """)
        let header = try #require(paragraph(of: "Left", in: s))
        let block = try #require(header.textBlocks.last as? NSTextTableBlock)
        #expect(block.table.numberOfColumns == 4)
        #expect(block.backgroundColor != nil)
        #expect(header.alignment == .left)
        #expect(paragraph(of: "Center", in: s)?.alignment == .center)
        #expect(paragraph(of: "Right", in: s)?.alignment == .right)
        #expect(paragraph(of: "Plain", in: s)?.alignment == .natural)
        let bodyWeight = NSFontManager.shared.weight(of: try #require(font(of: "short", in: s)))
        #expect(bodyWeight < NSFontManager.shared.weight(of: try #require(font(of: "Left", in: s))))
        let cell = try #require(paragraph(of: "short", in: s)?.textBlocks.last as? NSTextTableBlock)
        #expect(cell.startingRow == 2)
        #expect(cell.backgroundColor == nil)
        // 4 header cells + 2 rows of 4 cells + the gap paragraph.
        #expect(s.string.components(separatedBy: "\n").count == 13)
    }

    @Test func rulesAndHTML() throws {
        let s = render("above\n\n---\n\n<div>Hello<br/>world</div>\n\n<div></div>\n\nend <br> inline <span>x</span>")
        #expect(s.string == "above\n\nHello\u{2028}world\nend \u{2028} inline x")
        let rule = s.attribute(.paragraphStyle, at: ("above\n" as NSString).length, effectiveRange: nil) as? NSParagraphStyle
        #expect(rule?.textBlocks.count == 1)
    }

    @Test func respectsBaseSize() throws {
        let store = self.store
        let big = MarkdownRenderer(baseSize: 30) { id in store.resource(id: id).map { ($0, store.url(for: $0)) } }
        #expect(big.render("text").attribute(.font, at: 0, effectiveRange: nil).map { ($0 as! NSFont).pointSize } == 30)
    }

    @Test func imageCache() {
        let url = store.url(for: image)
        let first = MarkdownRenderer.loadImage(url)
        #expect(first != nil)
        #expect(MarkdownRenderer.loadImage(url) === first)
        #expect(MarkdownRenderer.loadImage(temporaryDirectory().appendingPathComponent("none.png")) == nil)
    }
}

@MainActor
@Suite struct MarkdownRendererFallbackTests {
    @Test func unknownInlineMarkupKeepsItsText() {
        let renderer = MarkdownRenderer(baseSize: 14) { _ in nil }
        #expect(renderer.render("^[styled](rainbow: 'extreme') text").string == "styled text")
    }
}
