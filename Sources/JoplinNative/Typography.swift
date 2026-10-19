import AppKit

/// A font family chosen in Settings. The system designs are stored as reserved names starting with a dot, any
/// other value is the family name of an installed font.
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

    /// Installed families, for the font pickers. The system designs come first and are not repeated.
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

/// Fonts used to draw a note, resolved from the Settings.
struct Typography: Equatable {
    var family: FontFamily = .system
    var size: CGFloat = 14
    var codeFamily: FontFamily = .monospaced

    func body(weight: NSFont.Weight = .regular, italic: Bool = false, scale: CGFloat = 1) -> NSFont {
        family.font(size: size * scale, weight: weight, italic: italic)
    }

    func code(weight: NSFont.Weight = .regular, italic: Bool = false, scale: CGFloat = 1) -> NSFont {
        // Monospaced fonts look larger than proportional ones at the same point size.
        let factor: CGFloat = family.isMonospaced ? 1 : 0.9
        return codeFamily.font(size: size * scale * factor, weight: weight, italic: italic)
    }

    /// Comfortable reading measure (about 75 characters of body text).
    var readableWidth: CGFloat { (size * 46).rounded() }
}

/// Finding and marking the words of a search in text.
enum SearchHighlight {
    static var color: NSColor { NSColor.systemYellow.withAlphaComponent(0.45) }

    /// Search words without quotes; FTS matches prefixes, so these are matched as substrings.
    static func terms(_ text: String) -> [String] {
        let words = text.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'*")) }
            .filter { !$0.isEmpty }
        var seen: Set<String> = []
        return words.filter { seen.insert($0.lowercased()).inserted }
    }

    /// Ranges of all terms in `string`, ignoring case and diacritics, in text order.
    static func ranges(of terms: [String], in string: String) -> [NSRange] {
        guard !terms.isEmpty, !string.isEmpty else { return [] }
        let ns = string as NSString
        var result: [NSRange] = []
        for term in terms {
            var search = NSRange(location: 0, length: ns.length)
            while search.length > 0 {
                let r = ns.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: search)
                guard r.location != NSNotFound, r.length > 0 else { break }
                result.append(r)
                let next = r.location + r.length
                search = NSRange(location: next, length: ns.length - next)
            }
        }
        return result.sorted { $0.location < $1.location }
    }

    /// Adds the highlight background to every match; returns the first match.
    @discardableResult
    static func apply(_ terms: [String], to text: NSMutableAttributedString) -> NSRange? {
        let found = ranges(of: terms, in: text.string)
        for r in found { text.addAttribute(.backgroundColor, value: color, range: r) }
        return found.first
    }
}
