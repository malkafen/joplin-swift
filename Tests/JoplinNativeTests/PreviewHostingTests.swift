import AppKit
import SwiftUI
import Testing
@testable import JoplinNative

@MainActor
@Suite(.serialized) struct PreviewHostingTests {
    @MainActor
    final class Host {
        let window: NSWindow
        let host: NSHostingView<MarkdownPreview>
        let stepper = SearchStepper()
        var links: [URL] = []
        var renderer = MarkdownRenderer(baseSize: 14) { _ in nil }

        init(_ markdown: String, width: CGFloat = 700) {
            _ = NSApplication.shared
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 400), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            host = NSHostingView(rootView: MarkdownPreview(markdown: "", noteId: "", renderer: renderer, readableWidth: true) { _ in })
            host.frame = window.contentLayoutRect
            window.contentView = host
            update(markdown)
        }

        func update(_ markdown: String, noteId: String = "n", highlights: [String] = [], shown: Bool = true, readable: Bool = true) {
            host.rootView = MarkdownPreview(markdown: markdown, noteId: noteId, renderer: renderer, isShown: shown, readableWidth: readable,
                                            highlights: highlights, stepper: stepper) { [unowned self] in links.append($0) }
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        var textView: PreviewTextView { stepper.preview as! PreviewTextView }
        var coordinator: MarkdownPreview.Coordinator { textView.delegate as! MarkdownPreview.Coordinator }

        func wait(_ seconds: TimeInterval = 30, _ done: () -> Bool) async {
            let deadline = Date().addingTimeInterval(seconds)
            while !done(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        }
    }

    static let renderer = MarkdownRenderer(baseSize: 14) { _ in nil }

    @Test func typingFollowsAtTheTypingInterval() async {
        let h = Host("# Title\n\nfirst")
        let tv = h.textView
        #expect(tv.string == "Title\nfirst")
        let storage = tv.textStorage
        await h.wait(0.3) { false }
        h.update("# Title\n\nfirst!")
        #expect(tv.string == "Title\nfirst!")
        h.update("# Title\n\nfirst!!")
        #expect(tv.string == "Title\nfirst!")
        #expect(h.coordinator.markdown == "# Title\n\nfirst!!")
        await h.wait { tv.string == "Title\nfirst!!" }
        #expect(tv.string == "Title\nfirst!!")
        #expect(tv.textStorage === storage)
        h.update("# Hidden", shown: false)
        #expect(tv.string == "Title\nfirst!!")
        h.update("# Other", noteId: "m")
        #expect(tv.string == "Other")
        h.window.close()
    }

    @Test func checkboxesAndLinksReachTheModel() throws {
        let h = Host("- [ ] task\n\n[site](https://a.b)")
        let tv = h.textView
        tv.onCheckbox?(1)
        #expect(h.links.map(\.absoluteString) == ["joplincheckbox://1"])
        let storage = try #require(tv.textStorage)
        let box = (storage.string as NSString).range(of: "\u{FFFC}").location
        let glyph = tv.layoutManager!.glyphIndexForCharacter(at: box)
        let rect = tv.layoutManager!.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tv.textContainer!)
        let point = tv.convert(NSPoint(x: rect.midX + tv.textContainerOrigin.x, y: rect.midY + tv.textContainerOrigin.y), to: nil)
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                    windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        tv.mouseDown(with: click)
        #expect(h.links.last?.absoluteString == "joplincheckbox://1")
        h.window.close()
    }

    @Test func searchRevealsAndStepsThroughThePreview() throws {
        let body = (1...120).map { "Line \($0) of text" }.joined(separator: "\n\n") + "\n\nThe needle here and a needle there."
        let h = Host(body)
        h.window.orderFront(nil)
        let tv = h.textView
        h.update(body, highlights: ["needle"])
        #expect(tv.visibleRect.minY > 0)
        let lm = try #require(tv.layoutManager as? SearchMarkingLayoutManager)
        #expect(lm.searchTerms == ["needle"])
        tv.scroll(.zero)
        #expect(h.stepper.step(forward: true, in: tv))
        #expect(lm.currentMatch != nil)
        let rep = try #require(tv.bitmapImageRepForCachingDisplay(in: tv.visibleRect))
        tv.cacheDisplay(in: tv.visibleRect, to: rep)
        let pills = lm.pills(forCharacterRange: lm.currentMatch!, in: tv.textContainer!, storage: tv.textStorage!)
        #expect(pills.count == 1 && pills[0].width > 10)
        let next = NSMenuItem(title: "Next", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "")
        next.tag = NSTextFinder.Action.nextMatch.rawValue
        #expect(tv.validateUserInterfaceItem(next))
        let before = lm.currentMatch
        tv.performFindPanelAction(next)
        #expect(lm.currentMatch != before)
        let show = NSMenuItem(title: "Find", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "")
        show.tag = NSTextFinder.Action.showFindInterface.rawValue
        tv.performFindPanelAction(show)
        #expect(!h.stepper.isActive(in: tv))
        h.update(body, highlights: [])
        h.window.orderOut(nil)
        h.window.close()
    }

    @Test func imagesFollowTheWidth() async throws {
        let file = temporaryDirectory().appendingPathComponent("wide.png")
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2000, pixelsHigh: 100, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(rep.representation(using: .png, properties: [:])).write(to: file)
        let h = Host("![wide](\(file.absoluteString))", width: 900)
        h.update("![wide](\(file.absoluteString))", readable: false)
        let tv = h.textView
        func width() -> CGFloat {
            (tv.textStorage?.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)?.bounds.width ?? 0
        }
        await h.wait { width() > 500 }
        let wide = width()
        #expect(wide > 500)
        tv.setFrameSize(NSSize(width: 400, height: tv.frame.height))
        await h.wait { width() < wide - 24 }
        #expect(width() < 400)
        h.window.close()
    }

    @Test func scrollingToTheEndOfTheSource() throws {
        let body = (1...200).map { "Paragraph \($0)" }.joined(separator: "\n\n")
        let h = Host(body)
        let tv = h.textView
        let scroll = try #require(tv.enclosingScrollView)
        tv.scroll(toSource: Int.max, offset: -.greatestFiniteMagnitude)
        #expect(scroll.contentView.bounds.maxY >= tv.frame.height - 1)
        tv.scroll(toSource: 0, offset: tv.textContainerOrigin.y)
        #expect(scroll.contentView.bounds.minY == 0)
        h.window.close()
    }

    @Test func hugeNotesWithRemoteImagesRenderInTheBackground() async {
        let h = Host("start")
        h.renderer = MarkdownRenderer(typography: Typography(), resolveResource: { _ in nil }, remoteImage: { _ in nil })
        let body = "![r](https://img.test/r.png)\n\n" + (1...25_000).map { "Paragraph \($0) text.\n\n" }.joined()
        h.update(body, noteId: "huge")
        let tv = h.textView
        await h.wait { tv.string.hasSuffix("Paragraph 25000 text.") }
        #expect(tv.string.hasPrefix("🖼 r"))
        h.update(body + "more", noteId: "huge")
        h.update(body + "more and more", noteId: "huge")
        await h.wait { tv.string.hasSuffix("more and more") }
        #expect(tv.string.hasSuffix("more and more"))
        h.window.close()
    }

    @Test func remoteImagesAreServedOffTheMainThreadFromTheCache() async {
        let loader = RemoteImageLoader()
        let url = URL(string: "https://img.test/cached.png")!
        let image = NSImage(data: tinyPNG)!
        loader.finish(url, image)
        let cached = await Task.detached { loader.imageOffMain(for: url) != nil }.value
        #expect(cached)
        let missing = await Task.detached { loader.imageOffMain(for: URL(string: "ftp://img.test/none.png")!) == nil }.value
        #expect(missing)
        loader.finish(URL(string: "https://img.test/broken.png")!, nil)
        #expect(loader.image(for: URL(string: "https://img.test/broken.png")!) == nil)
    }

    @Test(arguments: 1...4) func splicesMatchFullRenders(seed: UInt64) throws {
        let renderer = Self.renderer
        var markdown = "[toc]\n\n" + (1...8).map { i in
            "## Part \(i)\n\nText \(i) with **bold** and `code`.\n\n- [ ] task \(i)\n- [x] done \(i)\n\n| a | b |\n|---|---|\n| \(i) | y |\n"
        }.joined(separator: "\n")
        let snippets = ["x", "\n", "\n\n", "- [ ] ", "|", "# ", "**", "😀", "[r]: https://x.test\n"]
        var rng = SplitMix(state: seed)
        var shown = MarkdownPreview.Coordinator.rendered(markdown, renderer, width: 640)
        let storage = NSTextStorage(attributedString: shown.text)
        var spliced = 0
        func lines(_ s: NSAttributedString) -> [Int] {
            var out: [Int] = []
            s.enumerateAttribute(.jnCheckbox, in: NSRange(location: 0, length: s.length)) { value, _, _ in
                if let box = value as? CheckboxLine { out.append(box.line) }
            }
            return out
        }
        for _ in 0..<80 {
            let ns = markdown as NSString
            let at = Int.random(in: 0...ns.length, using: &rng)
            let place = at == ns.length ? at : ns.rangeOfComposedCharacterSequence(at: at).location
            if Bool.random(using: &rng), place < ns.length {
                let r = ns.rangeOfComposedCharacterSequences(for: NSRange(location: place, length: min(4, ns.length - place)))
                markdown = ns.replacingCharacters(in: r, with: "")
            } else {
                markdown = ns.replacingCharacters(in: NSRange(location: place, length: 0), with: snippets.randomElement(using: &rng)!)
            }
            let full = MarkdownPreview.Coordinator.rendered(markdown, renderer, width: 640)
            if MarkdownPreview.Coordinator.splice(storage, showing: shown, into: full) {
                spliced += 1
                #expect(storage.string == full.text.string)
                #expect(lines(storage) == lines(full.text))
            } else {
                storage.setAttributedString(full.text)
            }
            shown = full
        }
        #expect(spliced > 20, "\(spliced)")
        let other = MarkdownPreview.Coordinator.rendered("a", renderer, width: 300)
        #expect(!MarkdownPreview.Coordinator.splice(NSTextStorage(string: "x"), showing: shown, into: other))
    }

    @Test func splitViewFollowsTheEditor() async throws {
        _ = NSApplication.shared
        let body = (1...300).map { "Line \($0)" }.joined(separator: "\n\n")
        let bridge = EditorBridge()
        func split(_ layout: EditorLayout) -> NoteSplitView<MarkdownEditor, MarkdownPreview> {
            NoteSplitView(layout: layout,
                          editor: MarkdownEditor(text: body, noteId: "n", typography: Typography(), readableWidth: false, isEditable: true,
                                                 bridge: bridge, onChange: { _ in }, onDropFiles: { _ in nil }, onPasteImage: { _ in nil }),
                          preview: MarkdownPreview(markdown: body, noteId: "n", renderer: Self.renderer, readableWidth: false) { _ in })
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: split(.editor))
        host.frame = window.contentLayoutRect
        window.contentView = host
        window.orderFront(nil)
        func settle() async {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(100))
        }
        await settle()
        let editor = try #require(bridge.textView)
        window.makeFirstResponder(editor)
        host.rootView = split(.split)
        await settle()
        let splitView = try #require(host.subviews(of: NoteSplitNSView.self).first)
        #expect(splitView.showsDivider && splitView.dividerThickness > 0)
        let preview = try #require(host.subviews(of: PreviewTextView.self).first)
        let previewClip = try #require(preview.enclosingScrollView?.contentView)
        let editorClip = try #require(editor.enclosingScrollView?.contentView)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editorClip.scroll(to: NSPoint(x: 0, y: editor.frame.height / 2))
        await settle()
        #expect(previewClip.bounds.minY > 0)
        editorClip.scroll(to: NSPoint(x: 0, y: editor.frame.height))
        await settle()
        editorClip.scroll(to: .zero)
        await settle()
        #expect(previewClip.bounds.minY < preview.textContainerOrigin.y)
        let caret = (body as NSString).range(of: "Line 150").location
        editor.setSelectedRange(NSRange(location: caret, length: 0))
        editor.scrollRangeToVisible(NSRange(location: caret, length: 0))
        await settle()
        #expect(previewClip.bounds.minY > 0)
        let delegate = try #require(splitView.delegate)
        #expect(delegate.splitView?(splitView, constrainMinCoordinate: 0, ofSubviewAt: 0) ?? 0 >= 220)
        #expect(delegate.splitView?(splitView, constrainMaxCoordinate: 900, ofSubviewAt: 0) ?? 900 <= 900 - 220)
        #expect(delegate.splitView?(splitView, canCollapseSubview: preview) == false)
        #expect(delegate.splitView?(splitView, shouldHideDividerAt: 0) == false)
        window.makeFirstResponder(editor)
        host.rootView = split(.preview)
        await settle()
        #expect(!splitView.showsDivider && splitView.dividerThickness == 0)
        #expect(window.firstResponder === preview)
        let rep = try #require(splitView.bitmapImageRepForCachingDisplay(in: splitView.bounds))
        splitView.cacheDisplay(in: splitView.bounds, to: rep)
        window.orderOut(nil)
        window.close()
    }
}

private extension NSView {
    func subviews<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { ($0 as? T).map { [$0] } ?? [] + $0.subviews(of: type) }
    }
}
