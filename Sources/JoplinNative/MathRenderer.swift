import AppKit

/// Finds `$…$` and `$$…$$` before Markdown parsing, so that `_`, `*` and `\` inside formulas are not taken as
/// Markdown. Each formula becomes a private-use placeholder; line numbers stay unchanged (checkbox toggling
/// relies on them).
enum MathExtractor {
    static let open: Character = "\u{E000}"
    static let close: Character = "\u{E001}"
    static let placeholder = try! NSRegularExpression(pattern: "\u{E000}(\\d+)\u{E001}")

    struct Formula: Equatable {
        var tex: String
        var display: Bool
    }

    private static let inline = try! NSRegularExpression(
        pattern: #"(?<![\\$\w])\$\$(?=\S)(.+?)(?<=\S)\$\$|(?<![\\$\w])\$(?=[^\s$])([^$\n]*?[^\s\\$])\$(?![\w$])"#)

    static func extract(_ markdown: String) -> (String, [Formula]) {
        guard markdown.quickContains("$") else { return (markdown, []) }
        var formulas: [Formula] = []
        let original = markdown.components(separatedBy: "\n")
        var lines = original
        func token(_ tex: String, display: Bool) -> String {
            formulas.append(Formula(tex: tex, display: display))
            return "\(open)\(formulas.count - 1)\(close)"
        }
        scan(original, display: { i, end in
            // Display block: "$$" lines around the formula. The formula moves to the first line and the
            // others become empty, which also separates it from surrounding paragraphs.
            let tex = original[(i + 1)..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let indent = String(original[i].prefix { $0 == " " || $0 == "\t" })
            lines[i] = indent + token(tex, display: true)
            for j in (i + 1)...end { lines[j] = "" }
        }, inline: { i in
            lines[i] = replaceInline(lines[i], token: token)
        })
        return (lines.joined(separator: "\n"), formulas)
    }

    /// The code fence the extraction is inside of after `text`, which starts inside `fence`. The extraction tracks
    /// fences on its own, a little differently from Markdown.
    static func openFence(after text: String, from fence: String? = nil) -> String? {
        scan(text.utf8.split(separator: 10, omittingEmptySubsequences: false).map { Substring($0) }, from: fence)
    }

    /// Walks the lines as the extraction does: `display` gets the first and last line of each `$$` block, `inline`
    /// each line outside of code fences and blocks. Returns the fence open at the end.
    @discardableResult
    private static func scan<Line: StringProtocol>(_ lines: [Line], from fence: String? = nil, display: (Int, Int) -> Void = { _, _ in },
                                                   inline: (Int) -> Void = { _ in }) -> String? {
        var fence = fence
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if let f = fence {
                if trimmed.hasPrefix(f) { fence = nil }
                i += 1
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
                i += 1
                continue
            }
            if trimmed == "$$", let end = lines[(i + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "$$" }) {
                display(i, end)
                i = end + 1
                continue
            }
            inline(i)
            i += 1
        }
        return fence
    }

    /// Replaces inline formulas outside of code spans.
    private static func replaceInline(_ line: String, token: (String, Bool) -> String) -> String {
        guard line.contains("$") else { return line }
        var out = ""
        var rest = Substring(line)
        while let tick = rest.firstIndex(of: "`") {
            out += replaceOutsideCode(String(rest[..<tick]), token: token)
            let run = rest[tick...].prefix { $0 == "`" }
            let afterRun = rest.index(tick, offsetBy: run.count)
            if let close = rest[afterRun...].range(of: String(run)) {
                out += rest[tick..<close.upperBound]
                rest = rest[close.upperBound...]
            } else {
                out += rest[tick...]
                rest = ""
            }
        }
        return out + replaceOutsideCode(String(rest), token: token)
    }

    private static func replaceOutsideCode(_ s: String, token: (String, Bool) -> String) -> String {
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in inline.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let display = m.range(at: 1).location != NSNotFound
            out += token(ns.substring(with: m.range(at: display ? 1 : 2)), display)
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }
}

/// Typesets a useful subset of LaTeX math with Unicode symbols and the system's STIX Two Math font: Greek
/// letters, operators, arrows, fractions, roots, sub- and superscripts, `\mathbb`, `\text` and friends.
struct MathRenderer {
    var size: CGFloat
    var color: NSColor = .labelColor

    private var mathFont: NSFont { NSFont(name: "STIXTwoMath-Regular", size: size * 1.05) ?? .systemFont(ofSize: size) }
    private var italicFont: NSFont {
        NSFont(name: "STIXTwoText-Italic", size: size * 1.05)
            ?? NSFontManager.shared.convert(mathFont, toHaveTrait: .italicFontMask)
    }
    private var uprightFont: NSFont { NSFont(name: "STIXTwoText", size: size * 1.05) ?? mathFont }

    func render(_ tex: String) -> NSAttributedString {
        var parser = Parser(chars: Array(tex))
        let out = NSMutableAttributedString()
        emit(parser.parseGroup(until: nil), into: out, scale: 1, baseline: 0)
        return out
    }

    // MARK: Model

    indirect enum Node {
        case text(String, italic: Bool)
        case symbol(String)
        case group([Node])
        case sup(Node, Node)
        case sub(Node, Node)
        case subsup(Node, Node, Node)
        case frac(Node, Node)
        case sqrt(Node, Node?)
        case upright([Node])
        case decorated(Node, String)
    }

    struct Parser {
        var chars: [Character]
        var i = 0

        mutating func parseGroup(until end: Character?) -> [Node] {
            var nodes: [Node] = []
            while i < chars.count {
                let c = chars[i]
                if let end, c == end { i += 1; return nodes }
                if c == "^" || c == "_" {
                    i += 1
                    let script = parseAtom(argument: true) ?? .group([])
                    let base = nodes.popLast() ?? .group([])
                    if case .sub(let b, let lower) = base, c == "^" {
                        nodes.append(.subsup(b, lower, script))
                    } else if case .sup(let b, let upper) = base, c == "_" {
                        nodes.append(.subsup(b, script, upper))
                    } else {
                        nodes.append(c == "^" ? .sup(base, script) : .sub(base, script))
                    }
                    continue
                }
                if let atom = parseAtom() { nodes.append(atom) }
            }
            return nodes
        }

        /// One atom; `argument` atoms of commands and scripts take a single digit, as in `\frac12` or `x^23`.
        mutating func parseAtom(argument: Bool = false) -> Node? {
            while i < chars.count, chars[i] == " " || chars[i] == "\n" { i += 1 }
            guard i < chars.count else { return nil }
            let c = chars[i]
            switch c {
            case "{":
                i += 1
                return .group(parseGroup(until: "}"))
            case "}":
                i += 1
                return nil
            case "\\":
                return parseCommand()
            case "'":
                i += 1
                return .symbol("′")
            default:
                i += 1
                if c.isLetter { return .text(String(c), italic: true) }
                if c.isNumber {
                    var s = String(c)
                    if argument { return .text(s, italic: false) }
                    while i < chars.count, chars[i].isNumber || (chars[i] == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                        s.append(chars[i])
                        i += 1
                    }
                    return .text(s, italic: false)
                }
                if let mapped = MathRenderer.operators[String(c)] { return .symbol(mapped) }
                return .symbol(String(c))
            }
        }

        mutating func readName() -> String {
            var name = ""
            if i < chars.count, !chars[i].isLetter {
                name.append(chars[i])
                i += 1
                return name
            }
            while i < chars.count, chars[i].isLetter {
                name.append(chars[i])
                i += 1
            }
            return name
        }

        mutating func rawArgument() -> String {
            while i < chars.count, chars[i] == " " { i += 1 }
            guard i < chars.count else { return "" }
            if chars[i] != "{" {
                defer { i += 1 }
                return String(chars[i])
            }
            var depth = 0
            var s = ""
            while i < chars.count {
                let c = chars[i]
                i += 1
                if c == "{" { depth += 1; if depth == 1 { continue } }
                if c == "}" { depth -= 1; if depth == 0 { break } }
                s.append(c)
            }
            return s
        }

        mutating func parseCommand() -> Node? {
            i += 1
            let name = readName()
            switch name {
            case "frac", "dfrac", "tfrac":
                let num = parseAtom(argument: true) ?? .group([])
                let den = parseAtom(argument: true) ?? .group([])
                return .frac(num, den)
            case "sqrt":
                var index: Node?
                if i < chars.count, chars[i] == "[" {
                    i += 1
                    index = .group(parseGroup(until: "]"))
                }
                return .sqrt(parseAtom(argument: true) ?? .group([]), index)
            case "text", "textrm", "mathrm", "operatorname", "textnormal", "mbox":
                return .upright([.text(rawArgument(), italic: false)])
            case "mathbf", "textbf", "boldsymbol", "bm":
                return .upright([.text(MathRenderer.styled(rawArgument(), .bold), italic: false)])
            case "mathbb":
                return .symbol(MathRenderer.styled(rawArgument(), .doubleStruck))
            case "mathcal", "mathscr":
                return .symbol(MathRenderer.styled(rawArgument(), .script))
            case "mathit", "textit":
                return .text(rawArgument(), italic: true)
            case "hat", "bar", "vec", "dot", "ddot", "tilde", "overline", "widehat", "widetilde":
                let mark = ["hat": "\u{0302}", "widehat": "\u{0302}", "bar": "\u{0304}", "overline": "\u{0305}",
                            "vec": "\u{20D7}", "dot": "\u{0307}", "ddot": "\u{0308}", "tilde": "\u{0303}",
                            "widetilde": "\u{0303}"][name]!
                return .decorated(parseAtom() ?? .group([]), mark)
            case "left", "right", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr", "displaystyle",
                 "textstyle", "limits", "nolimits":
                if name == "left" || name == "right", i < chars.count, chars[i] == "." { i += 1 }
                return nil
            case "begin", "end":
                _ = rawArgument()
                return nil
            case ",", ":", ";", ">":
                return .symbol("\u{2005}")
            case "!":
                return nil
            case "quad":
                return .symbol("\u{2003}")
            case "qquad":
                return .symbol("\u{2003}\u{2003}")
            case " ":
                return .symbol(" ")
            case "\\":
                return .symbol("\n")
            case "{", "}", "$", "%", "&", "#", "_":
                return .symbol(name)
            default:
                if let symbol = MathRenderer.symbols[name] { return .symbol(symbol) }
                if MathRenderer.functions.contains(name) { return .upright([.text(name, italic: false)]) }
                return .upright([.text("\\" + name, italic: false)])
            }
        }
    }

    // MARK: Output

    private func font(_ base: NSFont, scale: CGFloat) -> NSFont {
        NSFont(descriptor: base.fontDescriptor, size: base.pointSize * scale) ?? base
    }

    private func append(_ s: String, _ f: NSFont, scale: CGFloat, baseline: CGFloat, into out: NSMutableAttributedString) {
        out.append(NSAttributedString(string: s, attributes: [
            .font: font(f, scale: scale), .baselineOffset: baseline, .foregroundColor: color,
        ]))
    }

    private func emit(_ nodes: [Node], into out: NSMutableAttributedString, scale: CGFloat, baseline: CGFloat, upright: Bool = false) {
        for node in nodes { emit(node, into: out, scale: scale, baseline: baseline, upright: upright) }
    }

    private func emit(_ node: Node, into out: NSMutableAttributedString, scale: CGFloat, baseline: CGFloat, upright: Bool = false) {
        let scriptScale = max(0.6, scale * 0.72)
        switch node {
        case .text(let s, let italic):
            append(s, italic && !upright ? italicFont : uprightFont, scale: scale, baseline: baseline, into: out)
        case .symbol(let s):
            // Space around relations and binary operators, as TeX does; none for a leading sign.
            let last = out.string.last
            let leading = last == nil || last == "(" || last == "[" || last == "{" || last == "⁄"
                || last.map { Self.relations.contains(String($0)) || Self.binary.contains(String($0)) || $0 == "\u{2004}" || $0 == "\u{2005}" } == true
            if Self.relations.contains(s), scale >= 1 {
                append(leading ? s + "\u{2004}" : "\u{2004}" + s + "\u{2004}", mathFont, scale: scale, baseline: baseline, into: out)
            } else if Self.binary.contains(s), !leading, scale >= 1 {
                append("\u{2005}" + s + "\u{2005}", mathFont, scale: scale, baseline: baseline, into: out)
            } else {
                append(s, mathFont, scale: scale, baseline: baseline, into: out)
            }
        case .group(let nodes):
            emit(nodes, into: out, scale: scale, baseline: baseline, upright: upright)
        case .upright(let nodes):
            emit(nodes, into: out, scale: scale, baseline: baseline, upright: true)
        case .sup(let base, let script):
            emit(base, into: out, scale: scale, baseline: baseline, upright: upright)
            emit(script, into: out, scale: scriptScale, baseline: baseline + size * scale * 0.38, upright: upright)
        case .sub(let base, let script):
            emit(base, into: out, scale: scale, baseline: baseline, upright: upright)
            emit(script, into: out, scale: scriptScale, baseline: baseline - size * scale * 0.2, upright: upright)
        case .subsup(let base, let lower, let upper):
            emit(base, into: out, scale: scale, baseline: baseline, upright: upright)
            emit(lower, into: out, scale: scriptScale, baseline: baseline - size * scale * 0.2, upright: upright)
            emit(upper, into: out, scale: scriptScale, baseline: baseline + size * scale * 0.38, upright: upright)
        case .frac(let num, let den):
            emitWrapped(num, into: out, scale: scale, baseline: baseline, upright: upright)
            append("⁄", mathFont, scale: scale, baseline: baseline, into: out)
            emitWrapped(den, into: out, scale: scale, baseline: baseline, upright: upright)
        case .sqrt(let radicand, let index):
            if let index { emit(index, into: out, scale: scriptScale, baseline: baseline + size * scale * 0.3, upright: upright) }
            append("√", mathFont, scale: scale, baseline: baseline, into: out)
            emitWrapped(radicand, into: out, scale: scale, baseline: baseline, upright: upright)
        case .decorated(let base, let mark):
            let start = out.length
            emit(base, into: out, scale: scale, baseline: baseline, upright: upright)
            if out.length > start {
                out.insert(NSAttributedString(string: mark, attributes: out.attributes(at: out.length - 1, effectiveRange: nil)),
                           at: out.length)
            }
        }
    }

    /// Fraction parts and radicands: single atoms stay bare, anything longer gets parentheses.
    private func emitWrapped(_ node: Node, into out: NSMutableAttributedString, scale: CGFloat, baseline: CGFloat,
                             upright: Bool) {
        var simple = true
        if case .group(let nodes) = node, nodes.count > 1 { simple = false }
        if simple {
            emit(node, into: out, scale: scale, baseline: baseline, upright: upright)
        } else {
            append("(", mathFont, scale: scale, baseline: baseline, into: out)
            emit(node, into: out, scale: scale, baseline: baseline, upright: upright)
            append(")", mathFont, scale: scale, baseline: baseline, into: out)
        }
    }

    // MARK: Tables

    static let functions: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh", "log", "ln",
        "lg", "exp", "lim", "liminf", "limsup", "max", "min", "sup", "inf", "det", "dim", "gcd", "deg", "arg", "ker",
        "Pr", "mod", "bmod",
    ]

    static let relations: Set<String> = [
        "=", "<", ">", "≤", "≥", "≠", "≈", "≡", "∼", "≃", "≅", "∝", "≪", "≫", "≺", "≻", "∈", "∉", "∋", "⊂", "⊃",
        "⊆", "⊇", "→", "←", "↔", "⇒", "⇐", "⇔", "⟹", "⟺", "↦", "⟶", "⟵", "∣", "⊥", "∥",
    ]

    static let binary: Set<String> = ["+", "−", "×", "⋅", "÷", "±", "∓", "∗", "∘", "∪", "∩", "⊕", "⊗", "∖", "∧", "∨"]

    static let operators: [String: String] = ["-": "−", "*": "∗", "<": "<", ">": ">", "=": "=", "+": "+"]

    static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ", "varepsilon": "ε", "zeta": "ζ",
        "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν",
        "xi": "ξ", "pi": "π", "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ", "sigma": "σ", "varsigma": "ς", "tau": "τ",
        "upsilon": "υ", "phi": "ϕ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ",
        "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        "times": "×", "cdot": "⋅", "div": "÷", "pm": "±", "mp": "∓", "ast": "∗", "star": "⋆", "circ": "∘",
        "bullet": "∙", "oplus": "⊕", "otimes": "⊗", "cdots": "⋯", "ldots": "…", "dots": "…", "vdots": "⋮", "ddots": "⋱",
        "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠", "approx": "≈", "equiv": "≡", "sim": "∼",
        "simeq": "≃", "cong": "≅", "propto": "∝", "ll": "≪", "gg": "≫", "prec": "≺", "succ": "≻", "perp": "⊥",
        "parallel": "∥", "mid": "∣",
        "in": "∈", "notin": "∉", "ni": "∋", "subset": "⊂", "supset": "⊃", "subseteq": "⊆", "supseteq": "⊇",
        "cup": "∪", "cap": "∩", "setminus": "∖", "emptyset": "∅", "varnothing": "∅", "forall": "∀", "exists": "∃",
        "nexists": "∄", "neg": "¬", "lnot": "¬", "land": "∧", "wedge": "∧", "lor": "∨", "vee": "∨",
        "to": "→", "rightarrow": "→", "leftarrow": "←", "gets": "←", "leftrightarrow": "↔", "Rightarrow": "⇒",
        "Leftarrow": "⇐", "Leftrightarrow": "⇔", "implies": "⟹", "iff": "⟺", "mapsto": "↦", "uparrow": "↑",
        "downarrow": "↓", "longrightarrow": "⟶", "longleftarrow": "⟵",
        "sum": "∑", "prod": "∏", "coprod": "∐", "int": "∫", "iint": "∬", "iiint": "∭", "oint": "∮",
        "bigcup": "⋃", "bigcap": "⋂", "partial": "∂", "nabla": "∇", "infty": "∞", "aleph": "ℵ", "hbar": "ℏ",
        "ell": "ℓ", "Re": "ℜ", "Im": "ℑ", "wp": "℘", "angle": "∠", "triangle": "△", "degree": "°", "prime": "′",
        "langle": "⟨", "rangle": "⟩", "lceil": "⌈", "rceil": "⌉", "lfloor": "⌊", "rfloor": "⌋", "vert": "|",
        "Vert": "‖", "lbrace": "{", "rbrace": "}", "|": "‖",
    ]

    enum Alphabet {
        case bold, doubleStruck, script

        /// First capital letter of the alphabet in the Mathematical Alphanumeric Symbols block.
        var base: UInt32 {
            switch self {
            case .bold: return 0x1D400
            case .doubleStruck: return 0x1D538
            case .script: return 0x1D49C
            }
        }

        /// Letters that live in the Letterlike Symbols block instead (their slots above are empty).
        var exceptions: [Character: Character] {
            switch self {
            case .bold: return [:]
            case .doubleStruck: return ["C": "ℂ", "H": "ℍ", "N": "ℕ", "P": "ℙ", "Q": "ℚ", "R": "ℝ", "Z": "ℤ"]
            case .script: return ["B": "ℬ", "E": "ℰ", "F": "ℱ", "H": "ℋ", "I": "ℐ", "L": "ℒ", "M": "ℳ", "R": "ℛ",
                                  "e": "ℯ", "g": "ℊ", "o": "ℴ"]
            }
        }
    }

    static func styled(_ s: String, _ alphabet: Alphabet) -> String {
        let exceptions = alphabet.exceptions
        return String(s.map { c -> Character in
            if let mapped = exceptions[c] { return mapped }
            guard let ascii = c.asciiValue else { return c }
            var offset: UInt32?
            if ascii >= 65, ascii <= 90 { offset = UInt32(ascii - 65) }
            if ascii >= 97, ascii <= 122 { offset = 26 + UInt32(ascii - 97) }
            if let offset, let scalar = Unicode.Scalar(alphabet.base + offset) { return Character(scalar) }
            return c
        })
    }
}
