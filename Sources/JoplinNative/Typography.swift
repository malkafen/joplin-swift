import AppKit

struct FontFamily: Hashable, Identifiable {
    let name: String

    static let system = FontFamily(name: "")
    static let serif = FontFamily(name: ".serif")
    static let rounded = FontFamily(name: ".rounded")
    static let monospaced = FontFamily(name: ".mono")

    static let systemDesigns: [FontFamily] = [.system, .serif, .rounded, .monospaced]

    init(name: String) {
        self.name = name
    }

    var id: String { name }

    var label: String {
        switch self {
        case .system: return "System (SF Pro)"
        case .serif: return "System Serif (New York)"
        case .rounded: return "System Rounded"
        case .monospaced: return "System Monospaced (SF Mono)"
        default: return name
        }
    }

    var isMonospaced: Bool {
        if self == .monospaced { return true }
        return font(size: 12).isFixedPitch
    }

    static var installed: [FontFamily] {
        NSFontManager.shared.availableFontFamilies
            .filter { !$0.hasPrefix(".") }
            .map(FontFamily.init(name:))
    }

    func font(size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false) -> NSFont {
        var font: NSFont
        switch self {
        case .system:
            font = .systemFont(ofSize: size, weight: weight)
        case .monospaced:
            font = .monospacedSystemFont(ofSize: size, weight: weight)
        case .serif, .rounded:
            let base = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor
            let design = base.withDesign(self == .serif ? .serif : .rounded) ?? base
            font = NSFont(descriptor: design, size: size) ?? .systemFont(ofSize: size, weight: weight)
        default:
            font = NSFont(name: name, size: size).map { Self.withWeight($0, weight) }
                ?? NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size).map { Self.withWeight($0, weight) }
                ?? .systemFont(ofSize: size, weight: weight)
        }
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    private static func withWeight(_ font: NSFont, _ weight: NSFont.Weight) -> NSFont {
        guard weight >= .semibold else { return font }
        return NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }
}

struct Typography: Equatable {
    var family: FontFamily = .system
    var size: CGFloat = 14
    var codeFamily: FontFamily = .monospaced

    func body(weight: NSFont.Weight = .regular, italic: Bool = false, scale: CGFloat = 1) -> NSFont {
        family.font(size: size * scale, weight: weight, italic: italic)
    }

    func code(weight: NSFont.Weight = .regular, italic: Bool = false, scale: CGFloat = 1) -> NSFont {
        let factor: CGFloat = family.isMonospaced ? 1 : 0.9
        return codeFamily.font(size: size * scale * factor, weight: weight, italic: italic)
    }

    var readableWidth: CGFloat { (size * 46).rounded() }
}

enum SearchHighlight {
    static var color: NSColor { NSColor.systemYellow.withAlphaComponent(0.45) }
    static var currentColor: NSColor { NSColor.systemOrange.withAlphaComponent(0.75) }

    static func terms(_ text: String) -> [String] {
        let words = text.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'*")) }
            .filter { !$0.isEmpty }
        var seen: Set<String> = []
        return words.filter { seen.insert($0.lowercased()).inserted }
    }

    static func ranges(of terms: [String], in string: String, range: NSRange? = nil, limit: Int = .max) -> [NSRange] {
        ranges(of: terms, in: string as NSString, range: range, limit: limit)
    }

    static func ranges(of terms: [String], in ns: NSString, range: NSRange? = nil, limit: Int = .max) -> [NSRange] {
        guard !terms.isEmpty, ns.length > 0 else { return [] }
        let scope = range ?? NSRange(location: 0, length: ns.length)
        var result: [NSRange] = []
        for term in terms {
            var search = scope
            var found = 0
            while search.length > 0, found < limit {
                let r = ns.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: search)
                guard r.location != NSNotFound, r.length > 0 else { break }
                result.append(r)
                found += 1
                let next = r.location + r.length
                search = NSRange(location: next, length: NSMaxRange(scope) - next)
            }
        }
        return result.sorted { $0.location < $1.location }
    }
}
