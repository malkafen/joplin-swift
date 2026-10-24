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
        #expect(s.string == "\u{FFFC}\u{2009}Doc \u{FFFC}\u{2009}report.pdf Other note")
        #expect(s.attribute(.attachment, at: 0, effectiveRange: nil) is NSTextAttachment)
        #expect(attribute(.link, of: "Doc", in: s, as: URL.self) == URL(string: "joplinitem://\(file.id)"))
        #expect(s.attribute(.link, at: 0, effectiveRange: nil) as? URL == URL(string: "joplinitem://\(file.id)"))
        #expect(attribute(.link, of: "Other note", in: s, as: URL.self) == URL(string: "joplinitem://\(note)"))
    }

    @Test func images() throws {
        let s = render("![dot](:/\(image.id))", maxImageWidth: 0.5)
        let attachment = try #require(s.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        #expect(attachment.bounds.width == 0.5)
        #expect(s.attribute(.link, at: 0, effectiveRange: nil) as? URL == URL(string: "joplinitem://\(image.id)"))
        #expect(render("![](:/\(image.id))").attribute(.attachment, at: 0, effectiveRange: nil) != nil)

        #expect(render("![](:/\(brokenImage.id))").string == "📎 broken.png")
        #expect(render("![Report](:/\(file.id))").string == "📎 Report")
        let external = render("![logo](https://x.y/logo.png) ![](https://x.y/a.png) ![missing](:/\(fixtureId(404)))")
        #expect(external.string == "🖼 logo 🖼 https://x.y/a.png 🖼 missing")
        #expect(attribute(.link, of: "logo", in: external, as: URL.self) == URL(string: "https://x.y/logo.png"))
    }

    @Test func largeImagesAreScaledAndRounded() throws {
        let big = NSImage(size: NSSize(width: 400, height: 200))
        let store = self.store
        var requested: [URL] = []
        let renderer = MarkdownRenderer(typography: Typography(), resolveResource: { id in
            store.resource(id: id).map { ($0, store.url(for: $0)) }
        }, remoteImage: { url in
            requested.append(url)
            return url.lastPathComponent == "big.png" ? big : nil
        })
        let s = renderer.render("![big](https://x.y/big.png) ![later](https://x.y/later.png)", maxImageWidth: 200)
        let attachment = try #require(s.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        #expect(attachment.bounds.size == CGSize(width: 200, height: 100))
        #expect(attachment.image !== big)
        #expect(s.string.hasSuffix("🖼 later"))
        #expect(requested.map(\.lastPathComponent) == ["big.png", "later.png"])

        let local = temporaryDirectory().appendingPathComponent("local.png")
        try tinyPNG.write(to: local)
        #expect(render("![](\(local.absoluteString))").attribute(.attachment, at: 0, effectiveRange: nil) != nil)
    }

    @Test func codeBlocksStayInOneParagraph() throws {
        let s = render("```swift\nlet a = 1 // one\nlet b = \"x\"\n\n```\n\n    indented")
        #expect(s.string == "let a = 1 // one\u{2028}let b = \"x\"\nindented")
        #expect(font(of: "let a", in: s)?.isFixedPitch == true)
        let box = try #require(paragraph(of: "let a", in: s)?.textBlocks.first as? DecoratedBlock)
        #expect(box.fill != nil)
        #expect(box.caption == "swift")
        #expect(attribute(.foregroundColor, of: "let", in: s, as: NSColor.self) == .systemPink)
        #expect(attribute(.foregroundColor, of: "1", in: s, as: NSColor.self) == .systemPurple)
        #expect(attribute(.foregroundColor, of: "// one", in: s, as: NSColor.self) == .secondaryLabelColor)
        #expect(attribute(.foregroundColor, of: "\"x\"", in: s, as: NSColor.self) == .systemRed)
        #expect((paragraph(of: "indented", in: s)?.textBlocks.first as? DecoratedBlock)?.caption == nil)
    }

    @Test func blockQuotes() throws {
        let s = render("> quoted **text**\n>\n> > nested\n\nafter")
        #expect(s.string.hasPrefix("quoted text\nnested\n"))
        #expect(s.string.hasSuffix("\nafter"))
        #expect(attribute(.foregroundColor, of: "quoted", in: s, as: NSColor.self) == .secondaryLabelColor)
        #expect(paragraph(of: "nested", in: s)?.textBlocks.count == 2)
        #expect((paragraph(of: "quoted", in: s)?.textBlocks.first as? DecoratedBlock)?.bar != nil)
        #expect(paragraph(of: "after", in: s)?.textBlocks.isEmpty == true)
    }

    @Test func alerts() throws {
        let s = render("> [!WARNING]\n> Mind the **gap**\n\n> [!note] Inline title text\n\n> [!UNKNOWN]\n> plain")
        #expect(s.string.contains("\u{FFFC} Warning\nMind the gap\n"))
        #expect(s.string.contains("\u{FFFC} Note\nInline title text\n"))
        #expect(s.string.contains("[!UNKNOWN] plain"))
        let warning = try #require(paragraph(of: "Mind", in: s)?.textBlocks.first as? DecoratedBlock)
        #expect(warning.bar == .systemOrange)
        #expect(warning.fill != nil)
        #expect(attribute(.foregroundColor, of: "Warning", in: s, as: NSColor.self) == .systemOrange)
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
        #expect(s.string == "\t•\tone\n\t◦\tnested\n\t▪︎\tdeeper\n\t•\twrap\n\t•\ttwo\n\t3.\tthree\n\t4.\tfour")
        let one = try #require(paragraph(of: "one", in: s))
        let nested = try #require(paragraph(of: "nested", in: s))
        #expect(nested.headIndent > one.headIndent)
        #expect(one.tabStops.last?.location == one.headIndent)
        #expect(one.tabStops.first?.alignment == .right)
        #expect(paragraph(of: "four", in: s)?.paragraphSpacing == 11)
    }

    @Test func blocksMapSourceToRendering() {
        let md = "# Title\n\nSome text\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n- [ ] x\n"
        let doc = renderer.renderDocument(md)
        #expect(doc.blocks.count == 4)
        #expect(doc.blocks.first?.rendered.location == 0)
        #expect(doc.blocks.last?.rendered.upperBound == doc.text.length)
        for (a, b) in zip(doc.blocks, doc.blocks.dropFirst()) { #expect(a.rendered.upperBound == b.rendered.location) }
        #expect((md as NSString).substring(with: doc.blocks[1].source) == "Some text\n")
        #expect(doc.blocks.map(\.line) == [1, 3, 5, 9])
        #expect(doc.headings == ["title"])
    }

    @Test func checklists() throws {
        let s = render("intro\n\n- [ ] todo\n- [x] done")
        #expect(s.string == "intro\n\t\u{FFFC}\ttodo\n\t\u{FFFC}\tdone")
        let boxes = (s.string as NSString)
        let first = boxes.range(of: "\u{FFFC}")
        let second = boxes.range(of: "\u{FFFC}", options: .backwards)
        #expect((s.attribute(.jnCheckbox, at: first.location, effectiveRange: nil) as? CheckboxLine)?.line == 3)
        #expect((s.attribute(.jnCheckbox, at: second.location, effectiveRange: nil) as? CheckboxLine)?.line == 4)
        #expect(s.attribute(.attachment, at: first.location, effectiveRange: nil) is NSTextAttachment)
        #expect(attribute(.foregroundColor, of: "done", in: s, as: NSColor.self) == .secondaryLabelColor)
        #expect(attribute(.foregroundColor, of: "todo", in: s, as: NSColor.self) == .labelColor)
    }

    @Test func listItemsWithBlocksAndEmptyItems() throws {
        let s = render("- ```\n  code\n  ```\n-\n- after\n- <b>html</b>")
        #expect(s.string == "\t•\t\ncode\n\t•\t\n\t•\tafter\n\t•\thtml")
    }

    @Test func tables() throws {
        let s = render("""
        | Left | Center | Right | Plain |
        |:-----|:------:|------:|-------|
        | a | b | c | d |
        | short |
        | e | f | g | h |
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
        #expect(cell.backgroundColor != nil)
        #expect((paragraph(of: "d", in: s)?.textBlocks.last as? NSTextTableBlock)?.backgroundColor == nil)
        #expect(s.string.components(separatedBy: "\n").count == 16)
    }

    @Test func rulesAndHTML() throws {
        let s = render("above\n\n---\n\n<div>Hello<br/>world</div>\n\n<div></div>\n\nend <br> inline <span>x</span>")
        #expect(s.string == "above\n\nHello\u{2028}world\nend \u{2028} inline x")
        let rule = s.attribute(.paragraphStyle, at: ("above\n" as NSString).length, effectiveRange: nil) as? NSParagraphStyle
        #expect(rule?.textBlocks.count == 1)
    }

    @Test func inlineHTMLFormatting() throws {
        let s = render("<b>bold</b> <i>it</i> <u>under</u> <s>gone</s> <kbd>⌘K</kbd> <mark>hi</mark> x<sup>2</sup> H<sub>2</sub>O <a href=\"https://a.b\">site</a> <code>c</code> &amp; <!-- note -->")
        #expect(s.string == "bold it under gone ⌘K hi x2 H2O site c & ")
        #expect((font(of: "bold", in: s)).map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true)
        #expect((font(of: "it", in: s)).map { NSFontManager.shared.traits(of: $0).contains(.italicFontMask) } == true)
        #expect(attribute(.underlineStyle, of: "under", in: s, as: Int.self) == NSUnderlineStyle.single.rawValue)
        #expect(attribute(.strikethroughStyle, of: "gone", in: s, as: Int.self) == NSUnderlineStyle.single.rawValue)
        #expect(font(of: "⌘K", in: s)?.isFixedPitch == true)
        #expect(attribute(.backgroundColor, of: "hi", in: s, as: NSColor.self) != nil)
        let sup = (s.string as NSString).range(of: "x2")
        #expect((s.attribute(.baselineOffset, at: sup.location + 1, effectiveRange: nil) as? CGFloat ?? 0) > 0)
        let sub = (s.string as NSString).range(of: "H2O")
        #expect((s.attribute(.baselineOffset, at: sub.location + 1, effectiveRange: nil) as? CGFloat ?? 0) < 0)
        #expect(attribute(.link, of: "site", in: s, as: URL.self) == URL(string: "https://a.b"))
        #expect(font(of: "c &", in: s)?.isFixedPitch == true)
    }

    @Test func htmlBlocks() throws {
        let s = render("""
        <p align="center">
          <img src=":/\(image.id)" width="0.25" alt="dot">
          <b>Centered</b>&nbsp;text
        </p>

        <ul><li>one</li><li>two</li></ul>

        <table><tr><th>H</th><td>v</td></tr></table>

        <pre>a
          b</pre>
        """)
        let attachment = try #require(s.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        #expect(attachment.bounds.width == 0.25)
        #expect(paragraph(of: "Centered", in: s)?.alignment == .center)
        #expect(s.string.contains("Centered\u{00A0}text"))
        #expect(s.string.contains("•  one\u{2028}•  two"))
        #expect(s.string.contains("H  v"))
        #expect(font(of: "H  v", in: s).map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true)
        #expect(s.string.contains("a\u{2028}  b"))
        #expect(font(of: "a\u{2028}", in: s)?.isFixedPitch == true)
        #expect(HTMLTokens.decode("&lt;&#65;&#x42;&unknown;&") == "<AB&unknown;&")
        #expect(HTMLTokens.pieces("<img src='x' hidden>") == [.tag(name: "img", closing: false, attributes: ["src": "x", "hidden": ""])])
    }

    @Test func htmlBlockEdgesAndLineBreaks() throws {
        let s = render("- item\n\n  <div>in list<br>   spaced</div>\n\n<div>😀<br><br>  </div>\n\n<div><td>a</td><td>b</td><br><td>c</td></div>")
        #expect(s.string.contains("in list\u{2028}spaced\n"))
        #expect(s.string.contains("\n😀\n"))
        #expect(s.string.hasSuffix("a  b\u{2028}c"))
        let many = render((0..<500).map { "<div><b>b\($0)</b><br>line</div>" }.joined(separator: "\n\n"))
        #expect(many.string.components(separatedBy: "\n").count == 500)
        #expect(many.string.hasSuffix("b499\u{2028}line"))
    }

    @Test func highlightsAndBareLinks() throws {
        let s = render("a ==marked== text, see https://example.com/x and [l](https://l.ink) or mail me@example.com. `==no==`")
        #expect(s.string == "a marked text, see https://example.com/x and l or mail me@example.com. ==no==")
        #expect(attribute(.backgroundColor, of: "marked", in: s, as: NSColor.self) != nil)
        #expect(attribute(.link, of: "https://example.com/x", in: s, as: URL.self) == URL(string: "https://example.com/x"))
        #expect(attribute(.link, of: "me@example.com", in: s, as: URL.self)?.scheme == "mailto")
        #expect(attribute(.link, of: " and", in: s, as: URL.self) == nil)
    }

    @Test func headingAnchorsAndTOC() throws {
        let s = render("[toc]\n\n# Intro\n## Привет мир!\n## Intro\n### Deep `code`")
        #expect(s.string.hasPrefix("Intro\nПривет мир!\nIntro\nDeep code\n"))
        let anchors = NSMutableArray()
        s.enumerateAttribute(.jnAnchor, in: NSRange(location: 0, length: s.length)) { value, _, _ in
            if let value { anchors.add(value) }
        }
        #expect(anchors as? [String] == ["intro", "привет-мир", "intro-1", "deep-code"])
        let tocLink = try #require(s.attribute(.link, at: 0, effectiveRange: nil) as? URL)
        #expect(tocLink.fragment(percentEncoded: false) == "intro")
        #expect((paragraph(of: "Deep code\n", in: s)?.firstLineHeadIndent ?? 0) > (paragraph(of: "Intro", in: s)?.firstLineHeadIndent ?? 0))
        #expect(render("[toc]").string == "")
        for toc in ["*[TOC]*", "[[toc]]", "${toc}", " [toc] "] {
            #expect(renderer.renderDocument(toc + "\n\n# A").hasTOC, "\(toc)")
        }
        for text in ["[`toc`]", "[toc] and more", String(repeating: "word ", count: 80) + "[toc]", "[toc]\n[toc]"] {
            #expect(!renderer.renderDocument(text + "\n\n# A").hasTOC, "\(text)")
        }
        #expect(MarkdownRenderer.slug("Hello, World — 2!") == "hello-world--2")
    }

    @Test func math() throws {
        let s = render("Euler $e^{i\\pi} + 1 = 0$ costs $5 and $10, `$x$` stays.\n\n$$\n\\frac{a+b}{2} \\leq \\sqrt{x}\n$$\n\n- [ ] after")
        #expect(s.string.hasPrefix("Euler ei𝜋") || s.string.hasPrefix("Euler eiπ"))
        #expect(s.string.contains("costs $5 and $10, $x$ stays."))
        #expect(s.string.contains("(a\u{2005}+\u{2005}b)⁄2\u{2004}≤\u{2004}√x"))
        #expect(s.string.contains("ei𝜋\u{2005}+\u{2005}1\u{2004}=\u{2004}0") || s.string.contains("eiπ\u{2005}+\u{2005}1\u{2004}=\u{2004}0"))
        #expect(paragraph(of: "⁄2", in: s)?.alignment == .center)
        let box = (s.string as NSString).range(of: "\u{FFFC}", options: .backwards)
        #expect((s.attribute(.jnCheckbox, at: box.location, effectiveRange: nil) as? CheckboxLine)?.line == 7)
        let fenced = render("```math\nx_1^2\n```")
        #expect(fenced.string == "x12")
        #expect((fenced.attribute(.baselineOffset, at: 1, effectiveRange: nil) as? CGFloat ?? 0) < 0)
        #expect((fenced.attribute(.baselineOffset, at: 2, effectiveRange: nil) as? CGFloat ?? 0) > 0)
        #expect(render("```\n```swift\nlet a = $x$\n```").string.contains("let a = $x$"))
        let titled = MarkdownRenderer(baseSize: 14) { _ in nil }.renderDocument("$a$ and $b$\n\n# Area $b^2$")
        #expect(titled.headings == ["area-b2"])
        func openFence(_ text: String) -> String? {
            MathExtractor.openFence(in: text as NSString, range: NSRange(location: 0, length: (text as NSString).length))
        }
        #expect(openFence("text\n```swift\n$x$\n") == "```")
        #expect(openFence("~~~\n$$\n```\n$$\n") == "~~~")
        #expect(openFence("$$\n```\n$$\nx") == nil)
        #expect(openFence("```\n```\n") == nil)
        #expect(openFence("") == nil)
        #expect(MathExtractor.openFence(in: "x\n```\ny" as NSString, range: NSRange(location: 2, length: 4)) == "```")
    }

    @Test func respectsBaseSize() throws {
        let store = self.store
        let big = MarkdownRenderer(baseSize: 30) { id in store.resource(id: id).map { ($0, store.url(for: $0)) } }
        #expect(big.render("text").attribute(.font, at: 0, effectiveRange: nil).map { ($0 as! NSFont).pointSize } == 30)
        let serif = MarkdownRenderer(typography: Typography(family: .serif, size: 16), resolveResource: { _ in nil })
        let font = try #require(serif.render("text").attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.fontDescriptor.object(forKey: .family) as? String != NSFont.systemFont(ofSize: 16).familyName || font.pointSize == 16)
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
