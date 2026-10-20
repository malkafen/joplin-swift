import AppKit
import Foundation
@testable import JoplinCore
import Testing
@testable import JoplinNative

struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

@MainActor
@Suite struct FuzzTests {
    static let seeds: [String] = [
        "# Head\n\ntext *it* **b** ~~s~~ `c` ==m== $x^2$ $$\\frac{a}{b}$$",
        "| a | b |\n|:-|-:|\n| 1 | 2 |\n| x |",
        "- [ ] one\n  - [x] two\n    1. three\n> [!NOTE]\n> quote",
        "```swift\nlet x = 1\n```\n```mermaid\ngraph TD\nA-->B\nB-->A\nA((c))-.->|t|C{d}\n```",
        "```mermaid\nsequenceDiagram\nA->>B: hi\nB-->>A: ok\nNote over A,B: n\nloop x\nA->>A: self\nend\n```",
        "```mermaid\nstateDiagram-v2\n[*] --> S\nS --> [*]\nstate S {\n a --> b\n}\n```",
        "```mermaid\npie title P\n\"a\" : 1\n\"b\" : 0\n```",
        "```drawio\n<mxGraphModel><root><mxCell id=\"0\"/><mxCell id=\"1\" parent=\"0\"/><mxCell id=\"2\" value=\"x\" vertex=\"1\" parent=\"1\"><mxGeometry x=\"0\" y=\"0\" width=\"10\" height=\"10\" as=\"geometry\"/></mxCell><mxCell id=\"3\" edge=\"1\" source=\"2\" target=\"2\" parent=\"1\"><mxGeometry as=\"geometry\"/></mxCell></root></mxGraphModel>\n```",
        "<details><summary>s</summary>\n<table><tr><td>a</td></tr></table>\n</details> <kbd>K</kbd> <img src=\":/0123\" width=\"10\"> &amp;&#x41;&bogus;",
        "[toc]\n## A\n### B\n[l](#a) <https://x.y> https://bare.example/path)",
        "$\\sqrt[3]{x} \\sum_{i=0}^n \\alpha_i \\left( \\mathbb{R} \\right) \\begin{matrix} a & b \\\\ c \\end{matrix}$",
        "1) a\n2) b\n\n* * *\n\n    indented code\n\nSetext\n===\n",
        "\u{1F600}\u{200D}\u{1F469} кириллица \t\r\n\0 \\ ` * _ [ ] ( ) # + - . !",
    ]
    static let noise = ["\n", "|", "`", "```", "$", "$$", "\\", "[", "]", "(", ")", "-->", "->>", "{", "}", "<", ">", "*", "_",
                        "~~", "==", "#", " ", "\t", "> ", "- [ ] ", "1. ", "\"", ":", ";", "%%", "end", "subgraph", "\u{1F600}",
                        "&", "<br>", "</td>", "^", "_{", "\\frac", "graph LR", "participant", "state", "[*]"]

    static func mutate(_ s: String, _ rng: inout SplitMix) -> String {
        var chars = Array(s)
        for _ in 0..<Int.random(in: 0...6, using: &rng) {
            switch Int.random(in: 0..<4, using: &rng) {
            case 0 where !chars.isEmpty:
                let a = Int.random(in: 0..<chars.count, using: &rng)
                chars.removeSubrange(a..<min(chars.count, a + Int.random(in: 1...8, using: &rng)))
            case 1:
                chars.insert(contentsOf: noise.randomElement(using: &rng)!, at: Int.random(in: 0...chars.count, using: &rng))
            case 2:
                chars.append(contentsOf: seeds.randomElement(using: &rng)!)
            default:
                chars = Array(chars.prefix(Int.random(in: 0...chars.count, using: &rng)))
            }
        }
        return String(chars)
    }

    @Test func rendererSurvivesGarbage() throws {
        let store = try Store(directory: temporaryDirectory())
        let renderer = MarkdownRenderer(baseSize: 14) { id in store.resource(id: id).map { ($0, store.url(for: $0)) } }
        var rng = SplitMix(state: UInt64(ProcessInfo.processInfo.environment["JN_FUZZ_SEED"] ?? "") ?? 1)
        let iterations = Int(ProcessInfo.processInfo.environment["JN_FUZZ_N"] ?? "") ?? 300
        for _ in 0..<iterations {
            let md = Self.mutate(Self.seeds.randomElement(using: &rng)!, &rng)
            let out = renderer.render(md, maxImageWidth: CGFloat(Int.random(in: 0...800, using: &rng)))
            out.enumerateAttribute(.attachment, in: NSRange(location: 0, length: out.length)) { value, _, _ in
                if let a = value as? NSTextAttachment, let img = a.image {
                    _ = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
                }
            }
            for body in [md, String(md.drop { $0 != "\n" })] {
                if let img = Mermaid.image(body) { _ = img.cgImage(forProposedRect: nil, context: nil, hints: nil) }
                if let img = Drawio.image(xml: body) { _ = img.cgImage(forProposedRect: nil, context: nil, hints: nil) }
            }
            _ = Snippet.make(from: md)
        }
    }

    /// Refreshing only around an edit must give exactly what highlighting the whole text gives.
    /// The blocks found from one pass over the text are those the patterns find.
    @Test func scannedBlocksMatchThePatterns() {
        var rng = SplitMix(state: UInt64(ProcessInfo.processInfo.environment["JN_FUZZ_SEED"] ?? "") ?? 1)
        let iterations = Int(ProcessInfo.processInfo.environment["JN_FUZZ_N"] ?? "") ?? 300
        let extra = ["~~~", "  ```", "\r", "\u{2028}", "````", "$$\n", "\n```\n", " $", "a$", "$b"]
        for _ in 0..<iterations * 3 {
            var text = (0..<3).map { _ in Self.seeds.randomElement(using: &rng)! }.joined(separator: "\n")
            for _ in 0..<Int.random(in: 0...8, using: &rng) {
                let piece = (Bool.random(using: &rng) ? extra : Self.noise).randomElement(using: &rng)!
                var chars = Array(text)
                chars.insert(contentsOf: piece, at: Int.random(in: 0...chars.count, using: &rng))
                text = String(chars)
            }
            text = Self.mutate(text, &rng)
            let h = MarkdownHighlighter()
            #expect(h.scannedBlocks(in: text) == h.referenceBlocks(in: text), "\(text.debugDescription)")
        }
    }

    @Test func incrementalHighlightMatchesFullHighlight() {
        var rng = SplitMix(state: UInt64(ProcessInfo.processInfo.environment["JN_FUZZ_SEED"] ?? "") ?? 1)
        let iterations = Int(ProcessInfo.processInfo.environment["JN_FUZZ_N"] ?? "") ?? 300
        let keys: [NSAttributedString.Key] = [.font, .foregroundColor, .backgroundColor, .strikethroughStyle]
        func same(_ a: NSAttributedString, _ b: NSAttributedString) -> Bool {
            guard a.string == b.string else { return false }
            var i = 0
            while i < a.length {
                var ra = NSRange(), rb = NSRange()
                let x = a.attributes(at: i, effectiveRange: &ra), y = b.attributes(at: i, effectiveRange: &rb)
                for k in keys {
                    switch (x[k] as AnyObject?, y[k] as AnyObject?) {
                    case (nil, nil): continue
                    case let (u?, v?) where u.isEqual(v): continue
                    default: return false
                    }
                }
                i = min(NSMaxRange(ra), NSMaxRange(rb))
            }
            return true
        }
        for _ in 0..<max(1, iterations / 10) {
            let storage = NSTextStorage(string: (0..<4).map { _ in Self.seeds.randomElement(using: &rng)! }.joined(separator: "\n\n"))
            let h = MarkdownHighlighter()
            h.highlight(storage)
            for _ in 0..<40 {
                let length = (storage.string as NSString).length
                let at = Int.random(in: 0...length, using: &rng)
                let remove = Bool.random(using: &rng) ? min(length - at, Int.random(in: 0...6, using: &rng)) : 0
                let insert = Bool.random(using: &rng) ? Self.noise.randomElement(using: &rng)! : "x"
                let before = storage.string
                storage.replaceCharacters(in: NSRange(location: at, length: remove), with: insert)
                h.highlight(storage, edited: NSRange(location: at, length: (insert as NSString).length))
                let reference = NSTextStorage(string: storage.string)
                MarkdownHighlighter().highlight(reference)
                #expect(same(storage, reference), "replacing \(remove) at \(at) with \(insert.debugDescription) in \(before.debugDescription)")
                if !same(storage, reference) { return }
            }
        }
    }

    /// With a small window: inside it the style is the full highlight's, outside it the base style, while editing
    /// and scrolling at random.
    @Test func windowedHighlightMatchesFullHighlight() {
        var rng = SplitMix(state: UInt64(ProcessInfo.processInfo.environment["JN_FUZZ_SEED"] ?? "") ?? 1)
        let iterations = Int(ProcessInfo.processInfo.environment["JN_FUZZ_N"] ?? "") ?? 300
        let keys: [NSAttributedString.Key] = [.font, .foregroundColor, .backgroundColor, .strikethroughStyle]
        func value(_ s: NSAttributedString, _ k: NSAttributedString.Key, _ i: Int) -> AnyObject? { s.attribute(k, at: i, effectiveRange: nil) as AnyObject? }
        func equal(_ a: AnyObject?, _ b: AnyObject?) -> Bool { a == nil ? b == nil : b.map { a!.isEqual($0) } ?? false }
        for _ in 0..<max(1, iterations / 10) {
            let storage = NSTextStorage(string: (0..<8).map { _ in Self.seeds.randomElement(using: &rng)! }.joined(separator: "\n\n"))
            let h = MarkdownHighlighter()
            h.radius = Int.random(in: 10...200, using: &rng)
            h.highlight(storage)
            for step in 0..<40 {
                let length = storage.length
                if Bool.random(using: &rng) {
                    let at = Int.random(in: 0...length, using: &rng)
                    let remove = Bool.random(using: &rng) ? min(length - at, Int.random(in: 0...6, using: &rng)) : 0
                    let insert = Bool.random(using: &rng) ? Self.noise.randomElement(using: &rng)! : "x"
                    storage.replaceCharacters(in: NSRange(location: at, length: remove), with: insert)
                    h.highlight(storage, edited: NSRange(location: at, length: (insert as NSString).length))
                } else {
                    let at = Int.random(in: 0...length, using: &rng)
                    h.show(NSRange(location: at, length: min(length - at, 40)), in: storage)
                }
                let reference = NSTextStorage(string: storage.string)
                MarkdownHighlighter().highlight(reference)
                // The base style, with the fonts the text storage substitutes (emoji) like in the editor.
                let plain = NSTextStorage(string: storage.string)
                plain.setAttributes(MarkdownHighlighter().baseAttributes, range: NSRange(location: 0, length: plain.length))
                var mismatch: Int?
                for i in 0..<storage.length where mismatch == nil {
                    let inside = NSLocationInRange(i, h.window)
                    for k in keys where mismatch == nil {
                        let expected = value(inside ? reference : plain, k, i)
                        if !equal(value(storage, k, i), expected) { mismatch = i }
                    }
                }
                #expect(mismatch == nil, "step \(step), at \(mismatch ?? -1), window \(h.window): \(storage.string.debugDescription)")
                if mismatch != nil { return }
            }
        }
    }

    @Test func vimSurvivesRandomKeys() {
        _ = NSApplication.shared
        var rng = SplitMix(state: UInt64(ProcessInfo.processInfo.environment["JN_FUZZ_SEED"] ?? "") ?? 1)
        let iterations = Int(ProcessInfo.processInfo.environment["JN_FUZZ_N"] ?? "") ?? 300
        let keys = Array("hjklwbeWBE0^$gGfFtT;,{}+-dcy><~xXDCYsSrJpPoOiaIAuv V123\u{1B}\u{12}\u{04}\u{15}\r\u{7F}x é")
        for _ in 0..<max(1, iterations / 10) {
            let tv = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            tv.allowsUndo = true
            tv.string = Self.mutate(Self.seeds.randomElement(using: &rng)!, &rng)
            let vim = VimEngine(textView: tv)
            tv.vim = vim
            vim.reset()
            for _ in 0..<200 {
                let k = String(keys.randomElement(using: &rng)!)
                if !vim.handle(key: k) {
                    tv.insertText(k, replacementRange: tv.selectedRange())
                }
                let r = tv.selectedRange()
                #expect(NSMaxRange(r) <= (tv.string as NSString).length)
            }
        }
    }
}
