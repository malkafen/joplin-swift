import AppKit
import Foundation
@testable import JoplinCore
import SwiftUI
import Testing
@testable import JoplinNative

@MainActor
@Suite struct CodeHighlighterTests {
    private func tokens(_ code: String, _ language: String) -> [(String, CodeHighlighter.Token)] {
        guard let g = CodeHighlighter.grammar(for: language) else { return [] }
        return CodeHighlighter.tokens(code, grammar: g).map { ((code as NSString).substring(with: $0.0), $0.1) }
    }

    private func token(_ text: String, in list: [(String, CodeHighlighter.Token)]) -> CodeHighlighter.Token? {
        list.first { $0.0 == text }?.1
    }

    @Test func languagesAndAliases() {
        #expect(CodeHighlighter.grammar(for: nil) == nil)
        #expect(CodeHighlighter.grammar(for: "") == nil)
        #expect(CodeHighlighter.grammar(for: "brainfuck") == nil)
        for lang in ["swift", "js", "tsx", "json", "py", "go", "rs", "c", "c++", "java", "kt", "cs", "php", "rb", "bash",
                     "dockerfile", "sql", "yml", "toml", "css", "html", "xml", "Swift {.numberLines}"] {
            #expect(CodeHighlighter.grammar(for: lang) != nil, "\(lang)")
        }
    }

    @Test func cLikeLanguages() {
        let t = tokens("/* block */ let x = 42 // done\nfunc go() { return Foo(\"a\\\"b\", 'c', 0x1F, .5) }", "swift")
        #expect(token("/* block */", in: t) == .comment)
        #expect(token("let", in: t) == .keyword)
        #expect(token("42", in: t) == .number)
        #expect(token("// done", in: t) == .comment)
        #expect(token("go", in: t) == .call)
        #expect(token("Foo", in: t) == .call)
        #expect(token("\"a\\\"b\"", in: t) == .string)
        #expect(token("0x1F", in: t) == .number)
        #expect(token(".5", in: t) == .number)
        let js = tokens("const s = `multi\nline`; if (x === null) Type", "javascript")
        #expect(token("`multi\nline`", in: js) == .string)
        #expect(token("null", in: js) == .number)
        #expect(token("Type", in: js) == .type)
        #expect(token("const", in: js) == .keyword)
    }

    @Test func scriptingLanguages() {
        let py = tokens("# comment\ndef f(x):\n    return None  # trailing\nprint('#not')", "python")
        #expect(token("# comment", in: py) == .comment)
        #expect(token("# trailing", in: py) == .comment)
        #expect(token("def", in: py) == .keyword)
        #expect(token("None", in: py) == .number)
        #expect(token("'#not'", in: py) == .string)
        let sh = tokens("echo $HOME a#b # c", "sh")
        #expect(token("echo", in: sh) == .keyword)
        #expect(token("# c", in: sh) == .comment)
        #expect(!sh.contains { $0.0.hasPrefix("#b") })
        let sql = tokens("SELECT id FROM notes -- all\nWHERE x IS NULL", "sql")
        #expect(token("SELECT", in: sql) == .keyword)
        #expect(token("-- all", in: sql) == .comment)
        #expect(token("NULL", in: sql) == .number)
    }

    @Test func dataAndMarkup() {
        let json = tokens(#"{"key": "value", "n": 1, "ok": true}"#, "json")
        #expect(token(#""key""#, in: json) == .property)
        #expect(token(#""value""#, in: json) == .string)
        #expect(token("true", in: json) == .number)
        let yaml = tokens("name: app\nenabled: yes # on", "yaml")
        #expect(token("name", in: yaml) == .property)
        #expect(token("yes", in: yaml) == .number)
        let css = tokens(".a { font-size: 12px; } /* c */", "css")
        #expect(token("font-size", in: css) == .property)
        #expect(token("/* c */", in: css) == .comment)
        let html = tokens(#"<!-- c --><a href="x" disabled>t</a><br/>"#, "html")
        #expect(token("<!-- c -->", in: html) == .comment)
        #expect(token("a", in: html) == .tag)
        #expect(token("href", in: html) == .attribute)
        #expect(token(#""x""#, in: html) == .string)
        #expect(token("disabled", in: html) == .attribute)
        #expect(token("br", in: html) == .tag)
        // Unterminated constructs end at the end of the text.
        #expect(!tokens("<a href=\"x", "html").isEmpty)
        #expect(token("/* open", in: tokens("/* open", "c")) == .comment)
        #expect(token("<!-- open", in: tokens("<!-- open", "html")) == .comment)
    }

    @Test func colours() {
        let all: [CodeHighlighter.Token] = [.comment, .string, .number, .keyword, .type, .call, .tag, .attribute, .property]
        #expect(Set(all.map { CodeHighlighter.color($0) }).count >= 8)
        let storage = NSMutableAttributedString(string: "x let a")
        CodeHighlighter.apply(language: "swift", to: storage, range: NSRange(location: 2, length: 5))
        #expect(storage.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor == .systemPink)
        CodeHighlighter.apply(language: "unknown", to: storage, range: NSRange(location: 0, length: 1))
        #expect(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) == nil)
    }
}

@MainActor
@Suite struct MathTests {
    private func math(_ tex: String) -> String { MathRenderer(size: 14).render(tex).string }

    @Test func extraction() {
        let (text, formulas) = MathExtractor.extract("a $x$ b\n```\n$y$\n```\n`$z$` $$w$$\n  $$\n  q\n  $$\nend $unclosed")
        #expect(formulas.map(\.tex) == ["x", "w", "q"])
        #expect(formulas.map(\.display) == [false, true, true])
        #expect(text.components(separatedBy: "\n").count == 9)
        #expect(text.contains("$y$"))
        #expect(text.contains("`$z$`"))
        #expect(text.hasSuffix("end $unclosed"))
        #expect(MathExtractor.extract("no math").1.isEmpty)
        #expect(MathExtractor.extract("$5 and $10, \\$x\\$").1.isEmpty)
        #expect(MathExtractor.extract("$$\nnever closed").1.isEmpty)
        #expect(MathExtractor.extract("`unclosed $x$").1.isEmpty)
    }

    @Test func symbolsAndStructures() {
        #expect(math("\\alpha + \\beta \\to \\infty") == "α\u{2005}+\u{2005}β\u{2004}→\u{2004}∞")
        #expect(math("-x") == "−x")
        #expect(math("\\frac12") == "1⁄2")
        #expect(math("\\sqrt[3]{x+1}") == "3√(x\u{2005}+\u{2005}1)")
        #expect(math("\\mathbb{R} \\mathcal{L} \\mathbf{v} \\mathbb{x}") == "ℝℒ𝐯𝕩")
        #expect(math("\\text{if } x") == "if x")
        #expect(math("\\sin x \\unknown") == "sinx\\unknown")
        #expect(math("\\hat{a}\\vec v") == "a\u{0302}v\u{20D7}")
        #expect(math("\\left( x \\right.") == "(x")
        #expect(math("a \\quad b \\, c \\\\ d") == "a\u{2003}b\u{2005}c\nd")
        #expect(math("\\begin{matrix} a \\end{matrix}") == "a")
        #expect(math("f'(x) \\{ \\} \\% \\!") == "f′(x){}%")
        #expect(math("x_i^2 y^2_j z_{} 2^10") == "xi2yj2z210")
        #expect(math("3.14 \\mathit{v} \\cdot") == "3.14v\u{2005}⋅\u{2005}")
        #expect(math("{a}}^") == "a")
        let s = MathRenderer(size: 20).render("x^2_1")
        #expect((s.attribute(.baselineOffset, at: 1, effectiveRange: nil) as? CGFloat ?? 0) < 0)
        #expect((s.attribute(.baselineOffset, at: 2, effectiveRange: nil) as? CGFloat ?? 0) > 0)
    }
}

@MainActor
@Suite struct TypographyTests {
    @Test func families() {
        #expect(FontFamily.system.label.contains("System"))
        #expect(FontFamily.serif.label.contains("New York"))
        #expect(FontFamily.rounded.label.contains("Rounded"))
        #expect(FontFamily.monospaced.isMonospaced)
        #expect(!FontFamily.system.isMonospaced)
        #expect(FontFamily(name: "Menlo").isMonospaced)
        #expect(FontFamily(name: "Menlo").label == "Menlo")
        #expect(!FontFamily.installed.isEmpty)
        #expect(!FontFamily.installed.contains { $0.name.hasPrefix(".") })
        for family in FontFamily.systemDesigns + [FontFamily(name: "Helvetica"), FontFamily(name: "No Such Font")] {
            let regular = family.font(size: 13)
            let bold = family.font(size: 13, weight: .bold, italic: true)
            #expect(regular.pointSize == 13)
            #expect(bold.pointSize == 13)
        }
        #expect(NSFontManager.shared.traits(of: FontFamily(name: "Helvetica").font(size: 12, weight: .bold)).contains(.boldFontMask))
    }

    @Test func typography() {
        let t = Typography(family: .monospaced, size: 10)
        #expect(t.code().pointSize == 10)
        #expect(Typography(size: 10).code().pointSize == 9)
        #expect(t.body(weight: .bold, italic: true, scale: 2).pointSize == 20)
        #expect(t.readableWidth == 460)
    }
}

@MainActor
@Suite(.serialized) struct PreviewInteractionTests {
    private func preview(_ markdown: String, width: CGFloat = 700) -> (PreviewTextView, NSScrollView, MarkdownPreview.Coordinator, [URL]) {
        _ = NSApplication.shared
        var clicked: [URL] = []
        let view = MarkdownPreview(markdown: markdown, noteId: "n", renderer: MarkdownRenderer(baseSize: 14) { _ in nil },
                                   readableWidth: true) { clicked.append($0) }
        let coordinator = view.makeCoordinator()
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let scroll = host.subviews(of: NSScrollView.self).first!
        let tv = scroll.documentView as! PreviewTextView
        let delegate = tv.delegate as! MarkdownPreview.Coordinator
        delegate.onLink = { clicked.append($0) }
        _ = coordinator
        window.close()
        return (tv, scroll, delegate, clicked)
    }

    @Test func checkboxHitTesting() throws {
        let (tv, _, coordinator, _) = preview("- [ ] first\n- [x] second\n\ntext")
        var toggled: [Int] = []
        tv.onCheckbox = { toggled.append($0) }
        let storage = try #require(tv.textStorage)
        let index = (storage.string as NSString).range(of: "\u{FFFC}").location
        let glyph = tv.layoutManager!.glyphIndexForCharacter(at: index)
        let rect = tv.layoutManager!.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tv.textContainer!)
        let point = NSPoint(x: rect.midX + tv.textContainerOrigin.x, y: rect.midY + tv.textContainerOrigin.y)
        #expect(tv.checkboxLine(at: point) == 1)
        #expect(tv.checkboxLine(at: NSPoint(x: 5000, y: 5000)) == nil)
        let textPoint = NSPoint(x: rect.maxX + 200, y: rect.midY + tv.textContainerOrigin.y)
        #expect(tv.checkboxLine(at: textPoint) == nil)
        tv.onCheckbox?(1)
        #expect(toggled == [1])
        _ = coordinator
    }

    @Test func readableWidthAndResize() {
        let (tv, _, coordinator, _) = preview("text", width: 1600)
        #expect(tv.textContainerInset.width > 100)
        tv.maxLineWidth = nil
        #expect(tv.textContainerInset.width == tv.minimumInset.width)
        tv.setFrameSize(NSSize(width: 400, height: tv.frame.height))
        coordinator.widthChanged()
        #expect(tv.textWidth < 400)
    }

    @Test func anchorsScroll() {
        let body = (1...80).map { "line \($0)\n" }.joined() + "\n## Target\n\nend"
        let (tv, scroll, coordinator, _) = preview(body)
        #expect(tv.scrollToAnchor("target"))
        #expect(!tv.scrollToAnchor("missing"))
        #expect(coordinator.textView(tv, clickedOnLink: URL(string: "#target")!, at: 0))
        _ = scroll
    }

    @Test func remoteImagesTriggerRerender() {
        let (tv, _, coordinator, _) = preview("![x](https://img.test/a.png)")
        coordinator.markdown = "![x](https://img.test/a.png)"
        let before = tv.string
        NotificationCenter.default.post(name: RemoteImageLoader.didLoad, object: URL(string: "https://img.test/a.png"))
        NotificationCenter.default.post(name: RemoteImageLoader.didLoad, object: URL(string: "https://other.test/b.png"))
        #expect(tv.string == before)
        MarkdownPreview.dismantleNSView(NSScrollView(), coordinator: coordinator)
    }

    @Test func pillBackgroundsDraw() throws {
        let (tv, _, _, _) = preview("Inline `code` and ==mark== and <kbd>K</kbd>")
        let rep = try #require(tv.bitmapImageRepForCachingDisplay(in: tv.bounds))
        tv.cacheDisplay(in: tv.bounds, to: rep)
        #expect(tv.layoutManager is PillBackgroundLayoutManager)
    }
}

@MainActor
@Suite(.serialized) struct RemoteImageLoaderTests {
    final class Stub: URLProtocol {
        nonisolated(unsafe) static var responses: [String: (Int, Data)] = [:]
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let (status, data) = Self.responses[request.url!.absoluteString] ?? (404, Data())
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    @Test func downloadsOnceAndAnnounces() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        let loader = RemoteImageLoader()
        loader.session = URLSession(configuration: config)
        let good = URL(string: "https://img.test/good.png")!
        let bad = URL(string: "https://img.test/bad.png")!
        Stub.responses = [good.absoluteString: (200, tinyPNG), bad.absoluteString: (500, Data())]
        var announced: [URL] = []
        let token = NotificationCenter.default.addObserver(forName: RemoteImageLoader.didLoad, object: nil, queue: nil) { note in
            if let url = note.object as? URL { announced.append(url) }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        #expect(loader.image(for: good) == nil)
        #expect(loader.image(for: good) == nil) // already in flight
        #expect(loader.image(for: bad) == nil)
        #expect(loader.image(for: URL(string: "ftp://x/y.png")!) == nil)
        for _ in 0..<50 where loader.image(for: good) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(loader.image(for: good) != nil)
        #expect(announced == [good])
        try await Task.sleep(for: .milliseconds(100))
        #expect(loader.image(for: bad) == nil) // failures are not retried
        #expect(Stub.responses.count == 2)
    }
}

@MainActor
@Suite struct RendererStressTests {
    /// Odd and broken input must never crash the renderer.
    @Test func survivesOddInput() {
        let renderer = MarkdownRenderer(baseSize: 14) { _ in nil }
        let samples = [
            "", "\n\n\n", "#", "######", "> ", "> [!", "> [!NOTE", "> [!NOTE]", "- [ ]", "1.", "|a|\n|-|", "| a |\n|---|\n|",
            "```", "```\n", "~~~js\nx", "$", "$$", "$$\n$$", "$x", "\\(", "<", "<div", "<img>", "<img src=>", "</b></i>",
            "<b><i>x</b>", "<a href=x>y", "==", "====", "== a ==", "[toc]\n[toc]", "[](#)", "[x](<>)", "![](", "![]()",
            String(repeating: "> ", count: 40) + "deep", String(repeating: "- ", count: 40) + "deep",
            String(repeating: "*", count: 200), "😀 ==🎉== $\\alpha$ <kbd>⌘</kbd>",
            "| a | b |\n|---|---|\n| 1 |\n| 1 | 2 | 3 |", "<table><tr><td>a<td>b</table>", "&#0; &#xFFFFFFFF; &amp",
            "- a\n\n  b\n\n  > c\n\n  ```\n  d\n  ```\n- e", "Setext\n===\n\nSub\n---", "[ref]\n\n[ref]: https://x.y",
            "<details><summary>S</summary>\n\nbody\n\n</details>", "line  \nbreak\\\nagain",
        ]
        for sample in samples {
            _ = renderer.render(sample)
            _ = renderer.render(sample, maxImageWidth: 1)
        }
        let highlighter = MarkdownHighlighter()
        for sample in samples {
            let storage = NSTextStorage(string: sample)
            highlighter.highlight(storage)
        }
    }
}

private extension NSView {
    func subviews<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { ($0 as? T).map { [$0] } ?? [] + $0.subviews(of: type) }
    }
}
