import AppKit
import Compression
import Foundation
@testable import JoplinCore
import Testing
@testable import JoplinNative

@MainActor
func rasterize(_ image: NSImage) -> NSBitmapImageRep? {
    let size = NSSize(width: max(1, image.size.width), height: max(1, image.size.height))
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

@MainActor
@Suite struct MermaidTests {
    @Test func flowchartParsing() throws {
        let chart = Flowchart.parse(header: "graph LR", lines: [
            "A[Square] --> B(Round)",
            "B --> C{Rhombus}; C -->|Yes| D([Stadium])",
            "C -- No --> E((Circle))",
            "E -.-> F[(DB)] & G{{Hex}}",
            "F ==> H[[Sub]]",
            "H --- I>Flag] <--> J[/Para/]",
            "J ~~~ K",
            "K-->L:::warn",
            "L --x M --o N",
            "classDef warn fill:#f96,stroke:#333",
            "class L,M warn",
            "style N fill:#abc",
            "click A callback",
            "subgraph one [Group One]",
            "  P --> Q",
            "  subgraph two",
            "    R",
            "  end",
            "end",
            "subgraph open",
            "  S",
        ])
        #expect(chart.direction == .LR)
        let shapes = Dictionary(uniqueKeysWithValues: chart.nodes.map { ($0.id, $0.shape) })
        #expect(shapes["A"] == .rect)
        #expect(shapes["B"] == .round)
        #expect(shapes["C"] == .diamond)
        #expect(shapes["D"] == .stadium)
        #expect(shapes["E"] == .circle)
        #expect(shapes["F"] == .cylinder)
        #expect(shapes["G"] == .hexagon)
        #expect(shapes["H"] == .subroutine)
        #expect(shapes["I"] == .asymmetric)
        #expect(shapes["J"] == .parallelogram)
        #expect(chart.node(id: "A")?.label == "Square")
        let edges = chart.edges.map { "\($0.from)>\($0.to)" }
        #expect(edges.contains("C>D") && edges.contains("C>E") && edges.contains("E>F") && edges.contains("E>G"))
        #expect(chart.edges.first { $0.from == "C" && $0.to == "D" }?.label == "Yes")
        #expect(chart.edges.first { $0.from == "C" && $0.to == "E" }?.label == "No")
        #expect(chart.edges.first { $0.from == "E" }?.line == .dotted)
        #expect(chart.edges.first { $0.from == "F" }?.line == .thick)
        #expect(chart.edges.first { $0.from == "H" }?.arrowEnd == false)
        let both = try #require(chart.edges.first { $0.from == "I" })
        #expect(both.arrowStart && both.arrowEnd)
        #expect(chart.edges.first { $0.from == "J" }?.line == .invisible)
        #expect(chart.node(id: "L")?.fill != nil)
        #expect(chart.node(id: "N")?.fill != nil)
        #expect(chart.groups.map(\.title).sorted() == ["Group One", "open", "two"])
        #expect(chart.groups.first { $0.title == "Group One" }?.members.contains("R") == true)
        #expect(Mermaid.color("#abc") != nil)
        #expect(Mermaid.color("red") == nil)
        #expect(Mermaid.color("#12345") == nil)
    }

    @Test func labels() {
        #expect(Mermaid.cleanLabel("\"Two<br/>lines\"") == "Two\nlines")
        #expect(Mermaid.cleanLabel("`**bold** #quot;q#quot; #amp; #lt;#gt; fa:fa-car car`") == "bold \"q\" & <> car")
    }

    @Test func layoutDirectionsAndCycles() throws {
        for header in ["graph TD", "graph BT", "flowchart LR", "flowchart RL", "graph"] {
            let chart = Flowchart.parse(header: header, lines: ["A --> B", "B --> C", "C --> A", "A --> A", "B --> D", "D"])
            let layout = FlowLayout(chart, font: .systemFont(ofSize: 13))
            #expect(layout.frames.count == 4)
            #expect(!layout.backEdges.isEmpty)
            let a = try #require(layout.frames["A"]), b = try #require(layout.frames["B"])
            switch chart.direction {
            case .TB: #expect(a.midY < b.midY)
            case .BT: #expect(a.midY > b.midY)
            case .LR: #expect(a.midX < b.midX)
            case .RL: #expect(a.midX > b.midX)
            }
            for (x, y) in zip(layout.frames.values, layout.frames.values.dropFirst()) {
                #expect(!x.intersects(y) || x == y)
            }
            #expect(layout.frames.values.allSatisfy { $0.maxX <= layout.size.width && $0.maxY <= layout.size.height })
            let image = layout.image()
            #expect(rasterize(image) != nil)
        }
    }

    @Test func boundaryPoints() throws {
        let chart = Flowchart.parse(header: "graph TD", lines: ["A((c)) --> B{d}", "B --> C[r]"])
        let layout = FlowLayout(chart, font: .systemFont(ofSize: 13))
        for id in ["A", "B", "C"] {
            let r = try #require(layout.frames[id])
            let center = CGPoint(x: r.midX, y: r.midY)
            #expect(layout.boundaryPoint(id, toward: center) == center)
            let p = layout.boundaryPoint(id, toward: CGPoint(x: r.midX + 500, y: r.midY + 1))
            #expect(abs(p.x - r.maxX) < 2)
        }
        #expect(layout.boundaryPoint("missing", toward: .zero) == .zero)
    }

    @Test func stateDiagrams() throws {
        let chart = Flowchart.parseState(lines: [
            "direction LR",
            "[*] --> Idle",
            "Idle --> Busy : start",
            "state \"Waiting for input\" as Wait",
            "state check <<choice>>",
            "state fork <<fork>>",
            "Busy --> check",
            "check --> Wait",
            "Wait : press a key",
            "state Composite {",
            "  [*] --> Inner",
            "  Inner --> [*]",
            "}",
            "note right of Idle : hello",
            "Busy --> [*]",
        ])
        #expect(chart.direction == .LR)
        #expect(chart.node(id: "__start0")?.shape == .start)
        #expect(chart.node(id: "__end0")?.shape == .end)
        #expect(chart.node(id: "__start1") != nil)
        #expect(chart.node(id: "check")?.shape == .diamond)
        #expect(chart.node(id: "fork")?.shape == .bar)
        #expect(chart.node(id: "Wait")?.label == "press a key")
        #expect(chart.node(id: "Idle")?.shape == .round)
        #expect(chart.edges.first { $0.from == "Idle" }?.label == "start")
        #expect(chart.groups.first?.title == "Composite")
        #expect(rasterize(try #require(Mermaid.image("stateDiagram-v2\n" + "[*] --> A\nA --> [*]\nstate F <<fork>>\nA --> F"))) != nil)
    }

    @Test func sequenceDiagrams() throws {
        let lines = [
            "autonumber", "participant A as Alice", "actor B", "title ignored", "activate A",
            "A->>B: Hello", "B-->>A: Hi", "A->A: Think", "A-xB: Lost", "A-)B: Async", "A->B: Plain",
            "Note left of A: left", "Note right of B: right", "Note over A,B: both",
            "loop Every minute", "A->>B: Ping", "end", "alt ok", "B->>A: yes", "else fail", "B->>A: no", "end",
            "rect rgb(0,0,0)", "A->>B: x", "end", "end", "par a", "and b", "end", "C->>A: new participant",
        ]
        let s = SequenceDiagram.parse(lines)
        #expect(s.autonumber)
        #expect(s.participants.map(\.id) == ["A", "B", "C"])
        #expect(s.participants[0].label == "Alice")
        #expect(s.participants[1].actor)
        let messages = s.items.compactMap { item -> SequenceDiagram.Arrow? in
            if case .message(_, _, _, _, let arrow) = item { return arrow }
            return nil
        }
        #expect(messages.prefix(6) == [.filled, .filled, .none, .cross, .open, .none])
        let layout = SequenceLayout(s, font: .systemFont(ofSize: 13))
        #expect(layout.size.width > 200)
        #expect(rasterize(layout.image()) != nil)
    }

    @Test func pieCharts() throws {
        let pie = Pie.parse(header: "pie showData title Pets", lines: ["\"Dogs\" : 386", "\"Cats\" : 85.5", "\"Zero\" : 0", "bad line"])
        #expect(pie.title == "Pets")
        #expect(pie.showData)
        #expect(pie.slices.map(\.label) == ["Dogs", "Cats"])
        let other = Pie.parse(header: "pie", lines: ["title From body", "\"A\" : 1"])
        #expect(other.title == "From body")
        #expect(rasterize(pie.image(font: .systemFont(ofSize: 13))) != nil)
    }

    @Test func entryPoint() {
        #expect(Mermaid.image("") == nil)
        #expect(Mermaid.image("classDiagram\nA <|-- B") == nil)
        #expect(Mermaid.image("graph TD") == nil)
        #expect(Mermaid.image("sequenceDiagram") == nil)
        #expect(Mermaid.image("pie") == nil)
        #expect(Mermaid.image("stateDiagram") == nil)
        #expect(Mermaid.image("%% comment\ngraph TD\nA-->B") != nil)
    }
}

@MainActor
@Suite struct DrawioTests {
    static let model = """
    <mxGraphModel background="#FFFFEE"><root><mxCell id="0"/><mxCell id="1" parent="0"/>
    <mxCell id="g" value="Lane" style="swimlane;startSize=20;fillColor=#eee;swimlaneFillColor=#fafafa;" vertex="1" parent="1">
      <mxGeometry x="200" y="200" width="200" height="120" as="geometry"/></mxCell>
    <mxCell id="in" value="Inside" style="rounded=1;" vertex="1" parent="g"><mxGeometry x="20" y="40" width="80" height="40" as="geometry"/></mxCell>
    <UserObject label="&lt;b&gt;User&lt;/b&gt;&lt;br&gt;object" id="u"><mxCell style="ellipse;html=1;fontStyle=3;fontColor=#ff0000;" vertex="1" parent="1">
      <mxGeometry x="0" y="0" width="100" height="50" as="geometry"/></mxCell></UserObject>
    <mxCell id="r" value="R" style="rhombus;dashed=1;strokeWidth=2;" vertex="1" parent="1"><mxGeometry x="0" y="200" width="60" height="60" as="geometry"/></mxCell>
    <mxCell id="t" value="Title" style="text;fontSize=18;align=left;verticalAlign=top;" vertex="1" parent="1"><mxGeometry x="0" y="100" width="60" height="20" as="geometry"/></mxCell>
    <mxCell id="c" value="DB" style="shape=cylinder3;" vertex="1" parent="1"><mxGeometry x="450" y="0" width="60" height="80" as="geometry"/></mxCell>
    <mxCell id="s1" style="triangle;opacity=50;" vertex="1" parent="1"><mxGeometry x="100" y="400" width="30" height="30" as="geometry"/></mxCell>
    <mxCell id="s2" style="hexagon;fillColor=none;" vertex="1" parent="1"><mxGeometry x="150" y="400" width="30" height="30" as="geometry"/></mxCell>
    <mxCell id="s3" style="shape=parallelogram;strokeColor=none;" vertex="1" parent="1"><mxGeometry x="200" y="400" width="30" height="30" as="geometry"/></mxCell>
    <mxCell id="s4" style="doubleEllipse;" vertex="1" parent="1"><mxGeometry x="250" y="400" width="30" height="30" as="geometry"/></mxCell>
    <mxCell id="s5" style="cloud;" vertex="1" parent="1"><mxGeometry x="300" y="400" width="30" height="30" as="geometry"/></mxCell>
    <mxCell id="e1" value="go" style="edgeStyle=orthogonalEdgeStyle;" edge="1" parent="1" source="u" target="r"><mxGeometry relative="1" as="geometry"/></mxCell>
    <mxCell id="e2" style="endArrow=open;startArrow=classic;dashed=1;rounded=1;" edge="1" parent="1" source="u" target="c">
      <mxGeometry relative="1" as="geometry"><Array as="points"><mxPoint x="300" y="20"/></Array></mxGeometry></mxCell>
    <mxCell id="e3" style="endArrow=none;" edge="1" parent="1"><mxGeometry relative="1" as="geometry">
      <mxPoint x="0" y="500" as="sourcePoint"/><mxPoint x="100" y="520" as="targetPoint"/></mxGeometry></mxCell>
    <mxCell id="e4" style="edgeStyle=elbowEdgeStyle;strokeColor=none;" edge="1" parent="1" source="r" target="in"><mxGeometry relative="1" as="geometry"/></mxCell>
    <mxCell id="e5" style="edgeStyle=orthogonalEdgeStyle;" edge="1" parent="1" source="t" target="r"><mxGeometry relative="1" as="geometry"/></mxCell>
    <mxCell id="lbl" value="label" style="edgeLabel;labelBackgroundColor=#ffffff;" vertex="1" connectable="0" parent="e1"><mxGeometry x="-0.5" relative="1" as="geometry"/></mxCell>
    <mxCell id="junk" parent="1"/>
    </root></mxGraphModel>
    """

    static func compressed(_ xml: String) -> String {
        let encoded = Array((xml.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? xml).utf8)
        var out = [UInt8](repeating: 0, count: encoded.count + 1024)
        let n = compression_encode_buffer(&out, out.count, encoded, encoded.count, nil, COMPRESSION_ZLIB)
        return Data(out[0..<n]).base64EncodedString()
    }

    @Test func parsesPlainAndCompressedFiles() throws {
        let plain = try #require(Drawio.diagram(xml: Self.model))
        #expect(plain.background != nil)
        #expect(plain.cells.first { $0.id == "u" }?.value == "User\nobject")
        #expect(plain.cells.first { $0.id == "c" }?.shape == "cylinder3")
        let page = "<mxfile><diagram name=\"p\">\(Self.model)</diagram></mxfile>"
        #expect(Drawio.diagram(xml: page)?.cells.count == plain.cells.count)
        let packed = "<mxfile><diagram name=\"p\">\(Self.compressed(Self.model))</diagram></mxfile>"
        #expect(Drawio.diagram(xml: packed)?.cells.count == plain.cells.count)
        #expect(Drawio.diagram(xml: "<mxfile><diagram>!!notbase64</diagram></mxfile>") == nil)
        #expect(Drawio.diagram(xml: "not xml") == nil)
        #expect(Drawio.diagram(xml: "<mxGraphModel><root><mxCell id=\"0\"/></root></mxGraphModel>") == nil)
        #expect(Drawio.decompress("") == nil)
    }

    @Test func svgWithEmbeddedDiagram() throws {
        let escaped = Self.model.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" content=\"\(escaped)\"><g/></svg>"
        let image = try #require(Drawio.image(svg: Data(svg.utf8)))
        #expect(image.size.width > 400)
        #expect(rasterize(image) != nil)
        #expect(Drawio.image(svg: Data("<svg/>".utf8)) == nil)
        #expect(Drawio.image(svg: Data("<svg content=\"plain\"/>".utf8)) == nil)
    }

    @Test func geometry() throws {
        let placed = Drawio.place(try #require(Drawio.diagram(xml: Self.model)))
        #expect(placed.cells["in"]?.rect.origin == CGPoint(x: 220, y: 240))
        let route = Drawio.route(try #require(placed.cells["e1"]), in: placed)
        #expect(route.count == 4)
        let free = Drawio.route(try #require(placed.cells["e3"]), in: placed)
        #expect(free.first == CGPoint(x: 0, y: 500))
        let r = CGRect(x: 0, y: 0, width: 100, height: 50)
        #expect(Drawio.clip(r, toward: CGPoint(x: 50, y: 25)) == CGPoint(x: 50, y: 25))
        #expect(Drawio.clip(r, toward: CGPoint(x: 50, y: 300), straight: true) == CGPoint(x: 50, y: 50))
        #expect(Drawio.clip(r, toward: CGPoint(x: 300, y: 25), straight: true) == CGPoint(x: 100, y: 25))
        #expect(Drawio.parseStyle("rounded=1;ellipse;fillColor=#fff").shape == "ellipse")
        #expect(Drawio.plainLabel("a<div>b</div>", html: true) == "a\nb")
        #expect(Drawio.plainLabel("plain", html: false) == "plain")
        #expect(Drawio.color("none") == nil)
        #expect(Drawio.color("default") == nil)
    }

    @Test func rendererUsesDiagramResources() throws {
        let store = try Store(directory: temporaryDirectory())
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" content=\"\(Self.model.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;"))\"/>"
        let svgRes = try store.addResource(data: Data(svg.utf8), filename: "drawio-1.svg", mime: "image/svg+xml", fileExtension: "svg")
        let fileRes = try store.addResource(data: Data(Self.model.utf8), filename: "d.drawio", mime: "application/octet-stream",
                                            fileExtension: "drawio")
        let renderer = MarkdownRenderer(baseSize: 14) { id in store.resource(id: id).map { ($0, store.url(for: $0)) } }
        for id in [svgRes.id, fileRes.id] {
            let s = renderer.render("![drawio](:/\(id))")
            #expect(s.attribute(.attachment, at: 0, effectiveRange: nil) is NSTextAttachment)
            #expect((s.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.lineHeightMultiple == 1)
        }
        let mermaid = renderer.render("```mermaid\ngraph TD\nA-->B\n```\n\n```mermaid\nclassDiagram\nA<|--B\n```\n\n```drawio\n\(Self.model)\n```")
        #expect(mermaid.string.hasPrefix("\u{FFFC}\n"))
        #expect(mermaid.string.contains("classDiagram"))
        #expect(mermaid.string.hasSuffix("\u{FFFC}"))
        #expect(MarkdownRenderer.mermaid("graph TD\nA-->B", fontSize: 12) === MarkdownRenderer.mermaid("graph TD\nA-->B", fontSize: 12))
    }
}

@MainActor
@Suite struct SearchHighlightTests {
    @Test func termsAndRanges() {
        #expect(SearchHighlight.terms("  \"Meet\"  notes* meet ") == ["Meet", "notes"])
        #expect(SearchHighlight.terms("   ").isEmpty)
        let text = "Meeting about café; MEETING again"
        let ranges = SearchHighlight.ranges(of: ["meet", "cafe"], in: text)
        #expect(ranges.map { (text as NSString).substring(with: $0) } == ["Meet", "café", "MEET"])
        #expect(SearchHighlight.ranges(of: [], in: text).isEmpty)
        #expect(SearchHighlight.ranges(of: ["again"], in: text, limit: 1).first?.location == 28)
    }

    @Test func storeSnippetsAroundTheMatch() throws {
        let store = try Store(directory: temporaryDirectory())
        let filler = String(repeating: "lorem ipsum dolor ", count: 60)
        try store.createNote(parentId: "", title: "Long", body: filler + "the needle is here " + filler)
        try store.createNote(parentId: "", title: "needle in title", body: "body")
        let found = store.notes(filter: .search("needle"), sort: .title)
        #expect(found.count == 2)
        #expect(found.first { $0.title == "Long" }?.snippet.contains("needle") == true)
        #expect(found.first { $0.title == "needle in title" }?.snippet == "body")
        #expect(store.notes(filter: .search("ne"), sort: .title).first { $0.title == "Long" }?.snippet.hasPrefix("lorem ipsum") == true)
    }

    @Test func onlyTheFirstSearchResultsGetSnippets() throws {
        let store = try Store(directory: temporaryDirectory())
        let body = String(repeating: "lorem ipsum dolor ", count: 20) + "the needle"
        for i in 0..<(Store.snippetRows + 5) {
            try store.createNote(parentId: "", title: String(format: "%04d", i), body: body)
        }
        let found = store.notes(filter: .search("needle"), sort: .title)
        #expect(found.count == Store.snippetRows + 5)
        #expect(found.prefix(Store.snippetRows).allSatisfy { $0.snippet.hasPrefix("…") && $0.snippet.hasSuffix("the needle") })
        #expect(found.last?.snippet.hasPrefix("lorem ipsum") == true)
    }

    @Test func longNotesAreExcerptedAroundTheMatch() throws {
        let store = try Store(directory: temporaryDirectory())
        let filler = String(repeating: "lorem ipsum dolor sit amet\n", count: 3_000)
        try store.createNote(parentId: "", title: "Case", body: filler + "The Needle is here " + filler)
        try store.createNote(parentId: "", title: "Accent", body: filler + "un café noir " + filler)
        try store.createNote(parentId: "", title: "Start", body: "needle first " + filler)
        func snippet(_ search: String, _ title: String) -> String? {
            store.notes(filter: .search(search), sort: .title).first { $0.title == title }?.snippet
        }
        let found = try #require(snippet("needle", "Case"))
        #expect(found.hasPrefix("…") && found.hasSuffix("…") && found.contains("The Needle is here"))
        #expect(found.count < 500)
        #expect(snippet("NEEDLE", "Case")?.contains("The Needle") == true)
        #expect(snippet("cafe", "Accent")?.contains("café noir") == true)
        #expect(snippet("needle", "Start")?.hasPrefix("needle first") == true)
    }

    @Test func modelHighlightsAndFindPasteboard() throws {
        let h = try ModelHarness()
        let model = h.model
        model.searchText = "checkbox"
        #expect(model.searchTerms == ["checkbox"])
        #expect(!model.notes.isEmpty)
        #expect(h.findPasteboard.string(forType: .string) == "checkbox")
    }

    @Test func listFollowsWhenTypingPauses() throws {
        let h = try ModelHarness()
        let model = h.model
        let all = model.notes.map(\.id)
        model.searchDelay = 60
        model.searchText = "zzzz"
        #expect(model.searchTerms == ["zzzz"])
        #expect(model.notes.map(\.id) == all)
        model.searchNow()
        #expect(model.notes.isEmpty)
        model.searchText = ""
        #expect(model.notes.map(\.id) == all)
    }

    @Test func noteStatsCountLinesWordsAndMatches() {
        let stats = NoteStats("# Заметка\n\nOne two, three-four don't\n- [x] café 42", terms: ["cafe", "two"])
        #expect(stats.lines == 4)
        #expect(stats.words == 9)
        #expect(stats.characters == 50)
        #expect(stats.matches == 2)
        #expect(NoteStats("", terms: []).lines == 0)
        #expect(NoteStats(String(repeating: "word ", count: 1_000), terms: []).readingMinutes == 5)
    }

    @Test func stepperWalksThroughMatches() {
        let stepper = SearchStepper()
        var positions: [SearchPosition] = []
        stepper.onStep = { positions.append($0) }
        let tv = MarkdownTextView(usingTextLayoutManager: false)
        tv.textContainer?.replaceLayoutManager(SearchMarkingLayoutManager())
        tv.string = "alpha beta\ngamma beta\nbeta"
        tv.stepper = stepper
        stepper.editor = tv
        #expect(!stepper.step(forward: true, in: tv))
        let lm = tv.layoutManager as! SearchMarkingLayoutManager
        lm.searchTerms = ["beta"]
        tv.setSelectedRange(NSRange(location: 8, length: 0))
        #expect(stepper.step(forward: true, in: tv))
        #expect(tv.selectedRange() == NSRange(location: 17, length: 4))
        #expect(lm.currentMatch == NSRange(location: 17, length: 4))
        stepper.step(forward: true, in: tv)
        stepper.step(forward: true, in: tv)
        #expect(tv.selectedRange().location == 6)
        stepper.step(forward: false, in: tv)
        #expect(tv.selectedRange().location == 22)
        #expect(positions.map(\.index) == [1, 2, 0, 2] && positions.allSatisfy { $0.count == 3 })
        tv.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        #expect(lm.currentMatch == nil)
        lm.searchTerms = ["zzz"]
        stepper.step(forward: true, in: tv)
        #expect(positions.last == SearchPosition(index: 0, count: 0))
    }

    @Test func modelStepsInTheEditorAndForgetsThePosition() throws {
        let h = try ModelHarness()
        let model = h.model
        let tv = MarkdownTextView(usingTextLayoutManager: false)
        tv.textContainer?.replaceLayoutManager(SearchMarkingLayoutManager())
        tv.string = "one two one"
        (tv.layoutManager as! SearchMarkingLayoutManager).searchTerms = ["one"]
        model.searchStepper.editor = tv
        model.layout = .editor
        model.stepMatch(forward: true)
        #expect(model.currentNote == nil || model.searchPosition == SearchPosition(index: 0, count: 2))
        model.searchText = "one"
        #expect(model.searchPosition == nil)
    }

    @Test func commandFFindsInTheOpenNote() throws {
        _ = NSApplication.shared
        let h = try ModelHarness()
        let model = h.model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let editor = MarkdownTextView(usingTextLayoutManager: false), preview = PreviewTextView(usingTextLayoutManager: false)
        let list = NSTextView()
        for (view, x) in [(editor as NSView, 0.0), (preview, 200.0), (list, 400.0)] {
            let scroll = NSScrollView(frame: NSRect(x: x, y: 0, width: 200, height: 400))
            scroll.documentView = view
            view.frame = scroll.bounds
            window.contentView?.addSubview(scroll)
        }
        editor.usesFindBar = true
        preview.usesFindBar = true
        model.searchStepper.editor = editor
        model.searchStepper.preview = preview
        model.selectedNoteIDs = []
        window.makeFirstResponder(list)
        model.findInNote(in: window)
        #expect(window.firstResponder === list)
        func findsIn(_ tv: NSTextView) -> Bool {
            guard let scroll = tv.enclosingScrollView, scroll.isFindBarVisible,
                  let focus = window.firstResponder as? NSView else { return false }
            return focus === tv || focus.isDescendant(of: scroll)
        }

        let note = try #require(model.notes.first)
        model.selectedNoteIDs = [note.id]
        model.layout = .editor
        model.findInNote(in: window)
        #expect(findsIn(editor))
        model.layout = .preview
        window.makeFirstResponder(list)
        model.findInNote(in: window)
        #expect(findsIn(preview))
        model.layout = .split
        window.makeFirstResponder(preview)
        model.findInNote(in: window)
        #expect(findsIn(preview))
        window.makeFirstResponder(list)
        model.findInNote(in: window)
        #expect(findsIn(editor))
    }

    @Test func layoutManagerMarksMatchesWithoutTouchingTheText() {
        let storage = NSTextStorage(string: String(repeating: "one two three\n", count: 2_000))
        let lm = SearchMarkingLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        lm.addTextContainer(container)
        storage.addLayoutManager(lm)
        lm.searchTerms = ["TWO", "thr"]
        let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: 14, length: 14), actualCharacterRange: nil)
        let matches = lm.searchMatches(forGlyphRange: glyphs)
        #expect(matches == [NSRange(location: 18, length: 3), NSRange(location: 22, length: 3)])
        let pills = lm.pills(forCharacterRange: matches[0], in: container, storage: storage)
        #expect(pills.count == 1 && pills[0].width > 10 && pills[0].height > 10)
        #expect(storage.attribute(.backgroundColor, at: 18, effectiveRange: nil) == nil)
    }
}

@MainActor
@Suite(.serialized) struct ShortcutTests {
    @Test func noteNavigationAndActions() throws {
        let h = try ModelHarness()
        let model = h.model
        let ids = model.notes.map(\.id)
        model.selectedNoteIDs = [ids[0]]
        model.selectAdjacentNote(1)
        #expect(model.selectedNoteIDs == [ids[1]])
        model.selectAdjacentNote(5)
        #expect(model.selectedNoteIDs == [ids.last!])
        model.selectAdjacentNote(-9)
        #expect(model.selectedNoteIDs == [ids[0]])
        model.selectedNoteIDs = []
        model.selectAdjacentNote(-1)
        #expect(model.selectedNoteIDs == [ids.last!])

        let todo = try #require(model.notes.first { $0.isTodo })
        model.selectedNoteIDs = [todo.id]
        model.toggleCurrentTodoCompleted()
        #expect(model.currentNote?.todoCompleted ?? 0 > 0)
        model.toggleCurrentTodoCompleted()
        #expect(model.currentNote?.todoCompleted == 0)

        let before = model.titleFocusRequest
        model.focusTitle()
        #expect(model.titleFocusRequest == before + 1)

        model.showNoteTags = false
        let field = NSTokenField()
        model.tagField = field
        model.focusTags()
        #expect(model.showNoteTags)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        model.trashExpanded = true
        #expect(h.defaults.bool(forKey: "trashExpanded"))
    }

    @Test func focusSearchFindsTheField() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let field = NSSearchField(frame: NSRect(x: 10, y: 10, width: 200, height: 24))
        window.contentView?.addSubview(field)
        let model = try! ModelHarness(welcome: false).model
        model.focusSearch(in: window)
        model.focusSearch(in: nil)
        #expect(window.firstResponder === field.currentEditor() || window.firstResponder === field)
        let toolbar = NSToolbar(identifier: "t")
        window.toolbar = toolbar
        model.focusSearch(in: window)
        window.close()
    }
}
