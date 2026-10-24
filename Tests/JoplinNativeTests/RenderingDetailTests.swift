import AppKit
import Compression
@testable import JoplinCore
import Testing
@testable import JoplinNative

@MainActor
@Suite struct RenderingDetailTests {
    private let renderer = MarkdownRenderer(baseSize: 14) { _ in nil }

    private func draw(_ text: NSAttributedString, width: CGFloat = 600, appearance: NSAppearance.Name) throws -> NSBitmapImageRep {
        let tv = PreviewTextView(usingTextLayoutManager: false)
        tv.textContainer?.replaceLayoutManager(PillBackgroundLayoutManager())
        tv.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        tv.appearance = NSAppearance(named: appearance)
        tv.textStorage?.setAttributedString(text)
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        tv.sizeToFit()
        let rep = try #require(tv.bitmapImageRepForCachingDisplay(in: tv.bounds))
        tv.cacheDisplay(in: tv.bounds, to: rep)
        return rep
    }

    @Test func blocksDrawInBothAppearances() throws {
        let md = "```swift\nlet a = 1\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n| 5 | 6 |\n\n> quote\n\n> [!TIP]\n> tip"
        let text = renderer.render(md)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let rep = try draw(text, appearance: name)
            #expect(rep.pixelsHigh > 50)
        }
        let box = try #require((text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.last as? DecoratedBlock)
        #expect(box.caption == "swift")
        let archived = try NSKeyedArchiver.archivedData(withRootObject: box, requiringSecureCoding: false)
        #expect(try NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(archived) is DecoratedBlock)
    }

    @Test func flowchartShapesDraw() throws {
        let chart = """
        graph LR
        A{{hex}} --> B[/para/]
        B --> C>flag]
        C --> D[(db)]
        D --> E[[sub]]
        E --> F((circle))
        F --> G([stadium])
        G --> H{diamond}
        """
        let image = try #require(Mermaid.image(chart))
        #expect(image.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil)
        let parsed = Flowchart.parse(header: "graph lr", lines: chart.components(separatedBy: "\n").dropFirst().map { $0 })
        #expect(parsed.nodes.map(\.shape) == [.hexagon, .parallelogram, .asymmetric, .cylinder, .subroutine, .circle, .stadium, .diamond])
    }

    @Test func tasksInsideQuotesAreCheckboxes() throws {
        let doc = renderer.renderDocument("> intro\n>\n> - [ ] open *task*\n> - [x] done\n> - [link](https://a.b)\n> - [y] not a task")
        var lines: [Int] = []
        doc.text.enumerateAttribute(.jnCheckbox, in: NSRange(location: 0, length: doc.text.length)) { value, _, _ in
            if let box = value as? CheckboxLine { lines.append(box.line) }
        }
        #expect(lines == [3, 4])
        #expect(doc.text.string.contains("open task"))
        #expect(!doc.text.string.contains("[ ]") && !doc.text.string.contains("[x]"))
        #expect(doc.text.string.contains("[y] not a task"))
        let done = (doc.text.string as NSString).range(of: "done")
        #expect(doc.text.attribute(.foregroundColor, at: done.location, effectiveRange: nil) as? NSColor == .secondaryLabelColor)
        #expect(!renderer.render("- \\[ ] escaped").string.contains("\u{FFFC}"))
    }

    @Test func imageCachesAreBounded() {
        #expect(MarkdownRenderer.imageCache.countLimit == 256)
        #expect(MarkdownRenderer.diagramCache.countLimit == 128)
        #expect(RemoteImageLoader().cache.countLimit == 256)
    }

    @Test func hardLineBreaksStayLineBreaks() {
        #expect(renderer.render("one\\\ntwo").string == "one\u{2028}two")
        #expect(renderer.render("one  \ntwo").string == "one\u{2028}two")
        #expect(renderer.render("one\ntwo").string == "one two")
    }

    @Test func mermaidFrontMatterAndNodeAttributes() throws {
        let flow = try #require(Mermaid.image("---\ntitle: Flow\nconfig:\n  theme: dark\n---\nflowchart LR\nA --> B"))
        #expect(flow.size.width > 50)
        #expect(Mermaid.image("---\ntitle: Broken\n") == nil)
        let pie = try #require(Mermaid.image("---\ntitle: \"Pets\"\n---\npie\n\"Dogs\" : 3\n\"Cats\" : 2"))
        let untitled = try #require(Mermaid.image("pie\n\"Dogs\" : 3\n\"Cats\" : 2"))
        #expect(pie.size.height > untitled.size.height)
        var chart = Flowchart()
        _ = chart.parseStatement("A@{ shape: diam, label: \"Is it, really?\" } --> B@{shape: cyl} --> C@{ label: 'Done' }")
        #expect(chart.nodes.map(\.label) == ["Is it, really?", "B", "Done"])
        #expect(chart.nodes.map(\.shape) == [.diamond, .cylinder, .rect])
        #expect(chart.edges.map { "\($0.from)\($0.to)" } == ["AB", "BC"])
        _ = chart.parseStatement("D@{ shape: hex")
        #expect(chart.node(id: "D")?.shape == .rect)
        let names = ["rounded", "stadium", "circle", "diamond", "hex", "cyl", "subproc", "lean-r", "flag", "sm-circ", "fr-circ", "rect", "unknown"]
        #expect(names.map(Flowchart.shape(named:)) == [.round, .stadium, .circle, .diamond, .hexagon, .cylinder, .subroutine, .parallelogram,
                                                      .asymmetric, .start, .end, .rect, .rect])
        let image = try #require(Mermaid.image("flowchart TD\nS@{ shape: start } --> A@{ shape: lean-r, label: In } --> E@{ shape: stop }"))
        #expect(image.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil)
    }

    @Test func mathCommandsAndAlphabets() {
        func math(_ tex: String) -> String { MathRenderer(size: 14).render(tex).string }
        #expect(math("\\text x") == "x")
        #expect(math("a \\qquad b") == "a\u{2003}\u{2003}b")
        #expect(math("a\\ b") == "a b")
        #expect(math("\\mathbb{1R}") == "1ℝ")
        #expect(MathRenderer.styled("Az9", .bold) == "𝐀𝐳9")
    }

    @Test func largeCompressedDrawioPayloadsInflate() throws {
        let xml = "<mxGraphModel><root><mxCell id=\"0\"/>" + (1...400).map {
            "<mxCell id=\"c\($0)\" value=\"cell\" vertex=\"1\" parent=\"0\"><mxGeometry x=\"\($0)\" y=\"0\" width=\"10\" height=\"10\" as=\"geometry\"/></mxCell>"
        }.joined() + "</root></mxGraphModel>"
        let source = Array(xml.utf8)
        var packed = [UInt8](repeating: 0, count: source.count)
        let size = compression_encode_buffer(&packed, packed.count, source, source.count, nil, COMPRESSION_ZLIB)
        #expect(size > 0 && size * 8 < source.count)
        let encoded = Data(packed[0..<size]).base64EncodedString()
        #expect(Drawio.decompress(encoded) == xml)
        let file = "<mxfile><diagram>\(encoded)</diagram></mxfile>"
        #expect(Drawio.diagram(xml: file)?.cells.count == 401)
        #expect(Drawio.decompress("") == nil)
    }

    @Test func inlineHTMLImagesAndRules() throws {
        let store = try Store(directory: temporaryDirectory())
        let image = try store.addResource(data: tinyPNG, filename: "dot.png", mime: "image/png", fileExtension: "png")
        let r = MarkdownRenderer(baseSize: 14) { id in store.resource(id: id).map { ($0, store.url(for: $0)) } }
        let s = r.render("text <img src=\":/\(image.id)\" width=\"5\"> more")
        let attachment = try #require(s.attribute(.attachment, at: 5, effectiveRange: nil) as? NSTextAttachment)
        #expect(attachment.bounds.width == 5)
        #expect(r.render("<div>above<hr>below</div>").string == "above\u{2028}below")
    }

    @Test func leadingParagraphsCutWholeCharacters() {
        func bridged(_ s: String) -> String { NSMutableString(string: s).copy() as! NSString as String }
        let words = String(repeating: "слово ", count: 10)
        #expect(bridged(words + "\n\n" + String(repeating: "ж", count: 100)).leadingParagraphs(limit: 70) == words)
        let emoji = bridged(String(repeating: "😀", count: 50))
        #expect(emoji.leadingParagraphs(limit: 31) == String(repeating: "😀", count: 15))
        let native = String(repeating: "ж", count: 100)
        #expect(native.leadingParagraphs(limit: 31) == String(repeating: "ж", count: 15))
        #expect(!native.leadingParagraphs(limit: 31).contains("\u{FFFD}"))
        #expect(String(repeating: "😀", count: 20).leadingParagraphs(limit: 9) == "😀😀")
    }
}
