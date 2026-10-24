import AppKit
import JoplinCore
import Markdown

import AppKit
import JoplinCore
import Markdown

extension NSAttributedString.Key {
    static let jnAnchor = NSAttributedString.Key("JNAnchor")
    static let jnCheckbox = NSAttributedString.Key("JNCheckbox")
}

final class CheckboxLine: NSObject {
    var line: Int
    init(_ line: Int) { self.line = line }
}

struct RenderedBlock {
    var source: NSRange
    var line: Int
    var rendered: NSRange
    var headings = 0
}

struct RenderedDocument {
    var text: NSAttributedString
    var sizedToWidth: Bool
    var blocks: [RenderedBlock]
    var headings: [String]
    var hasTOC: Bool
    var headingBases: [String] = []
    var htmlCarries = false
}

struct MarkdownRenderer {
    var typography: Typography
    var resolveResource: (String) -> (Resource, URL)?
    var remoteImage: ((URL) -> NSImage?)?
    var loadsRemoteImages: Bool { remoteImage != nil }

    var baseSize: CGFloat { typography.size }

    init(typography: Typography, resolveResource: @escaping (String) -> (Resource, URL)?,
         remoteImage: ((URL) -> NSImage?)? = nil) {
        self.typography = typography
        self.resolveResource = resolveResource
        self.remoteImage = remoteImage
    }

    init(baseSize: CGFloat, resolveResource: @escaping (String) -> (Resource, URL)?) {
        self.init(typography: Typography(size: baseSize), resolveResource: resolveResource)
    }

    static let imageCache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 256
        return cache
    }()

    static func loadImage(_ url: URL) -> NSImage? {
        if let cached = imageCache.object(forKey: url as NSURL) { return cached }
        guard let image = NSImage(contentsOf: url), image.isValid else { return nil }
        imageCache.setObject(image, forKey: url as NSURL)
        return image
    }

    static let diagramCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 128
        return cache
    }()

    static func mermaid(_ source: String, fontSize: CGFloat) -> NSImage? {
        let key = "\(fontSize)|\(source)" as NSString
        if let cached = diagramCache.object(forKey: key) { return cached }
        guard let image = Mermaid.image(source, fontSize: fontSize) else { return nil }
        diagramCache.setObject(image, forKey: key)
        return image
    }

    static func drawio(_ res: Resource, url: URL) -> NSImage? {
        let ext = res.fileExtension.lowercased()
        let isSVG = res.mime == "image/svg+xml" || ext == "svg"
        let isFile = ext == "drawio" || ext == "dio" || res.mime.contains("drawio") || res.mime.contains("jgraph")
        guard isSVG || isFile else { return nil }
        let key = "drawio|\(url.path)" as NSString
        if let cached = diagramCache.object(forKey: key) { return cached }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let image = isSVG ? Drawio.image(svg: data) : Drawio.image(xml: String(decoding: data, as: UTF8.self))
        if let image { diagramCache.setObject(image, forKey: key) }
        return image
    }

    func render(_ markdown: String, maxImageWidth: CGFloat = 640) -> NSAttributedString {
        renderDocument(markdown, maxImageWidth: maxImageWidth).text
    }

    func renderDocument(_ markdown: String, maxImageWidth: CGFloat = 640, firstLine: Int = 1, headingsBefore: [String: Int] = [:],
                        endsNote: Bool = true) -> RenderedDocument {
        let (source, formulas) = MathExtractor.extract(markdown)
        let document = Document(parsing: source)
        let builder = AttributedBuilder(renderer: self, maxImageWidth: maxImageWidth, formulas: formulas)
        builder.lineOffset = firstLine - 1
        builder.collectHeadings(document, before: headingsBefore)
        var htmlCarries = false
        let lineStarts = Self.lineStarts(markdown)
        let sourceLength = lineStarts.last ?? 0
        func offset(ofLine line: Int) -> Int { line - 1 < lineStarts.count - 1 ? lineStarts[max(0, line - 1)] : sourceLength }
        var blocks: [RenderedBlock] = []
        for child in document.children {
            let start = builder.out.length, headings = builder.headingIndex
            builder.blocks(CollectionOfOne(child), BlockStyle())
            htmlCarries = htmlCarries || builder.htmlIsOpen
            guard let range = child.range else { continue }
            let from = offset(ofLine: range.lowerBound.line)
            let to = max(from, offset(ofLine: range.upperBound.line + 1))
            blocks.append(RenderedBlock(source: NSRange(location: from, length: to - from), line: range.lowerBound.line + firstLine - 1,
                                        rendered: NSRange(location: start, length: builder.out.length - start),
                                        headings: builder.headingIndex - headings))
        }
        while endsNote, builder.out.length > 0, builder.out.mutableString.character(at: builder.out.length - 1) == 10 {
            builder.out.deleteCharacters(in: NSRange(location: builder.out.length - 1, length: 1))
        }
        var position = 0
        for i in blocks.indices {
            let end = i == blocks.count - 1 ? builder.out.length : min(blocks[i].rendered.upperBound, builder.out.length)
            blocks[i].rendered = NSRange(location: position, length: max(0, end - position))
            position = max(position, end)
        }
        return RenderedDocument(text: builder.out, sizedToWidth: builder.sizedToWidth, blocks: blocks,
                                headings: builder.headingSlugs, hasTOC: builder.hasTOC,
                                headingBases: builder.headingBases, htmlCarries: htmlCarries)
    }

    static func lineStarts(_ text: String) -> [Int] {
        var starts = [0]
        var i = 0
        for unit in text.utf16 {
            i += 1
            if unit == 10 { starts.append(i) }
        }
        starts.append(i)
        return starts
    }

    static func slug(_ title: String) -> String {
        let lowered = title.lowercased()
        var s = ""
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                s.unicodeScalars.append(scalar)
            } else if scalar == " " {
                s.append("-")
            }
        }
        return s
    }
}
