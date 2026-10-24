import AppKit

struct CodeHighlighter {
    enum Token: Equatable {
        case comment, string, number, keyword, type, call, tag, attribute, property
    }

    struct Grammar {
        var lineComments: [String] = []
        var blockComment: (open: String, close: String)?
        var quotes: Set<Character> = ["\"", "'"]
        var keywords: Set<String> = []
        var literals: Set<String> = []
        var caseInsensitive = false
        var markup = false
        var properties = false
    }

    static func color(_ token: Token) -> NSColor {
        switch token {
        case .comment: return .secondaryLabelColor
        case .string: return .systemRed
        case .number: return .systemPurple
        case .keyword: return .systemPink
        case .type: return .systemTeal
        case .call: return .systemIndigo
        case .tag: return .systemPink
        case .attribute: return .systemOrange
        case .property: return .systemBlue
        }
    }

    static func grammar(for language: String?) -> Grammar? {
        guard let raw = language?.split(separator: " ").first?.lowercased(), !raw.isEmpty else { return nil }
        let lang = aliases[raw] ?? raw
        return grammars[lang]
    }

    private static let aliases: [String: String] = [
        "js": "javascript", "jsx": "javascript", "mjs": "javascript", "ts": "typescript", "tsx": "typescript",
        "py": "python", "sh": "shell", "bash": "shell", "zsh": "shell", "console": "shell", "rs": "rust",
        "golang": "go", "c++": "cpp", "cc": "cpp", "h": "c", "hpp": "cpp", "cs": "csharp", "c#": "csharp",
        "kt": "kotlin", "rb": "ruby", "yml": "yaml", "htm": "html", "xml": "html", "svg": "html",
        "objc": "c", "objective-c": "c", "scss": "css", "less": "css", "jsonc": "json", "dockerfile": "docker",
        "ps1": "shell", "psql": "sql", "mysql": "sql", "postgres": "sql", "toml": "ini",
    ]

    private static let cFamily = Grammar(lineComments: ["//"], blockComment: ("/*", "*/"))

    private static let grammars: [String: Grammar] = {
        func words(_ s: String) -> Set<String> { Set(s.split(separator: " ").map(String.init)) }
        var g: [String: Grammar] = [:]
        var swift = cFamily
        swift.keywords = words("""
            actor any as associatedtype async await break case catch class continue default defer deinit do else enum \
            extension fallthrough fileprivate final for func guard if import in init inout internal is lazy let mutating \
            nonisolated open operator override private protocol public repeat rethrows return some static struct subscript \
            super switch throw throws try typealias var weak where while self Self
            """)
        swift.literals = words("true false nil")
        g["swift"] = swift
        var js = cFamily
        js.quotes = ["\"", "'", "`"]
        js.keywords = words("""
            async await break case catch class const continue debugger default delete do else export extends finally for \
            from function if import in instanceof let new of return static super switch this throw try typeof var void \
            while with yield interface type enum implements namespace declare readonly as keyof abstract private public protected
            """)
        js.literals = words("true false null undefined NaN Infinity")
        g["javascript"] = js
        g["typescript"] = js
        var json = Grammar()
        json.quotes = ["\""]
        json.literals = words("true false null")
        json.properties = true
        g["json"] = json
        var python = Grammar(lineComments: ["#"])
        python.keywords = words("""
            and as assert async await break class continue def del elif else except finally for from global if import in \
            is lambda nonlocal not or pass raise return try while with yield match case self
            """)
        python.literals = words("True False None")
        g["python"] = python
        var go = cFamily
        go.quotes = ["\"", "'", "`"]
        go.keywords = words("""
            break case chan const continue default defer else fallthrough for func go goto if import interface map package \
            range return select struct switch type var
            """)
        go.literals = words("true false nil iota")
        g["go"] = go
        var rust = cFamily
        rust.keywords = words("""
            as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub \
            ref return self Self static struct super trait type unsafe use where while
            """)
        rust.literals = words("true false None Some Ok Err")
        g["rust"] = rust
        var c = cFamily
        c.keywords = words("""
            auto break case char const continue default do double else enum extern float for goto if inline int long \
            register return short signed sizeof static struct switch typedef union unsigned void volatile while bool \
            class namespace template typename public private protected virtual override new delete this using try catch \
            throw const_cast static_cast dynamic_cast nullptr #include #define #ifdef #ifndef #endif #pragma #import \
            @interface @implementation @end @property
            """)
        c.literals = words("true false NULL nullptr YES NO nil")
        g["c"] = c
        g["cpp"] = c
        var java = cFamily
        java.keywords = words("""
            abstract assert boolean break byte case catch char class const continue default do double else enum extends \
            final finally float for if implements import instanceof int interface long native new package private \
            protected public return short static super switch synchronized this throw throws try void volatile while \
            var val fun object when is in out override data sealed companion internal lateinit suspend async await \
            using namespace readonly get set
            """)
        java.literals = words("true false null")
        g["java"] = java
        g["kotlin"] = java
        g["csharp"] = java
        var php = cFamily
        php.lineComments = ["//", "#"]
        php.keywords = words("""
            abstract and array as break case catch class const continue declare default do echo else elseif extends final \
            for foreach function global if implements include interface namespace new or private protected public require \
            return static switch throw trait try use var while fn match
            """)
        php.literals = words("true false null")
        g["php"] = php
        var ruby = Grammar(lineComments: ["#"])
        ruby.keywords = words("""
            alias and begin break case class def defined? do else elsif end ensure for if in module next not or redo \
            rescue retry return self super then undef unless until when while yield require attr_accessor
            """)
        ruby.literals = words("true false nil")
        g["ruby"] = ruby
        var shell = Grammar(lineComments: ["#"])
        shell.quotes = ["\"", "'", "`"]
        shell.keywords = words("""
            if then else elif fi for while until do done case esac in function return export local readonly set unset \
            echo cd sudo source alias exit
            """)
        shell.literals = words("true false")
        g["shell"] = shell
        g["docker"] = Grammar(lineComments: ["#"], keywords: words("""
            FROM RUN CMD LABEL EXPOSE ENV ADD COPY ENTRYPOINT VOLUME USER WORKDIR ARG ONBUILD STOPSIGNAL HEALTHCHECK SHELL AS
            """))
        var sql = Grammar(lineComments: ["--"], blockComment: ("/*", "*/"))
        sql.caseInsensitive = true
        sql.keywords = words("""
            select from where and or not insert into values update set delete create table index view drop alter add \
            primary key foreign references join left right inner outer full on as group by order having limit offset \
            distinct union all case when then else end is in like between exists with returning default unique check \
            begin commit rollback transaction integer int text varchar boolean real blob
            """)
        sql.literals = words("null true false")
        g["sql"] = sql
        var yaml = Grammar(lineComments: ["#"])
        yaml.literals = words("true false null yes no on off ~")
        yaml.properties = true
        g["yaml"] = yaml
        var ini = Grammar(lineComments: ["#", ";"])
        ini.literals = words("true false")
        ini.properties = true
        g["ini"] = ini
        var css = Grammar(blockComment: ("/*", "*/"))
        css.properties = true
        css.keywords = words("@media @import @keyframes @font-face @supports !important")
        g["css"] = css
        var html = Grammar(blockComment: ("<!--", "-->"))
        html.markup = true
        g["html"] = html
        return g
    }()

    static func tokens(_ code: String, grammar g: Grammar) -> [(NSRange, Token)] {
        let chars = Array(code.utf16)
        var result: [(NSRange, Token)] = []
        var i = 0
        let n = chars.count

        func starts(_ s: String, at index: Int) -> Bool {
            let u = Array(s.utf16)
            guard index + u.count <= n else { return false }
            return Array(chars[index..<index + u.count]) == u
        }
        func isIdentStart(_ c: UInt16) -> Bool {
            (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 || c == 64 || c == 35 || c > 127
        }
        func isIdent(_ c: UInt16) -> Bool { isIdentStart(c) || (c >= 48 && c <= 57) || c == 63 || c == 45 }
        func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
        func lineEnd(_ from: Int) -> Int {
            var j = from
            while j < n, chars[j] != 10 { j += 1 }
            return j
        }

        if g.markup { return markupTokens(chars, grammar: g) }
        let quoteCodes = Set(g.quotes.compactMap { $0.utf16.first })

        var lineStart = true
        while i < n {
            let c = chars[i]
            if c == 10 { lineStart = true; i += 1; continue }
            if c == 32 || c == 9 { i += 1; continue }
            if let block = g.blockComment, starts(block.open, at: i) {
                var j = i + block.open.utf16.count
                while j < n, !starts(block.close, at: j) { j += 1 }
                j = min(n, j + block.close.utf16.count)
                result.append((NSRange(location: i, length: j - i), .comment))
                i = j
                continue
            }
            if let lc = g.lineComments.first(where: { starts($0, at: i) }),
               lc != "#" || lineStart || (i > 0 && (chars[i - 1] == 32 || chars[i - 1] == 9)) {
                let j = lineEnd(i)
                result.append((NSRange(location: i, length: j - i), .comment))
                i = j
                continue
            }
            lineStart = false
            if quoteCodes.contains(c) {
                let q = c
                var j = i + 1
                while j < n {
                    if chars[j] == 92 { j += 2; continue }
                    if chars[j] == q { j += 1; break }
                    if chars[j] == 10 && q != 96 { break }
                    j += 1
                }
                j = min(j, n)
                var k = j
                while k < n, chars[k] == 32 { k += 1 }
                let token: Token = g.properties && k < n && chars[k] == 58 ? .property : .string
                result.append((NSRange(location: i, length: j - i), token))
                i = j
                continue
            }
            if isDigit(c) || (c == 46 && i + 1 < n && isDigit(chars[i + 1])) {
                var j = i + 1
                while j < n, isIdent(chars[j]) || chars[j] == 46 { j += 1 }
                result.append((NSRange(location: i, length: j - i), .number))
                i = j
                continue
            }
            if isIdentStart(c) {
                var j = i + 1
                while j < n, isIdent(chars[j]) && chars[j] != 45 || (chars[j] == 45 && g.properties) { j += 1 }
                let word = String(utf16CodeUnits: Array(chars[i..<j]), count: j - i)
                let key = g.caseInsensitive ? word.lowercased() : word
                var next = j
                while next < n, chars[next] == 32 { next += 1 }
                let token: Token?
                if g.keywords.contains(key) {
                    token = .keyword
                } else if g.literals.contains(key) {
                    token = .number
                } else if g.properties && next < n && (chars[next] == 58 || chars[next] == 61) {
                    token = .property
                } else if next < n && chars[next] == 40 {
                    token = .call
                } else if let first = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first), word.count > 1 {
                    token = .type
                } else {
                    token = nil
                }
                if let token { result.append((NSRange(location: i, length: j - i), token)) }
                i = j
                continue
            }
            i += 1
        }
        return result
    }

    private static func markupTokens(_ chars: [UInt16], grammar g: Grammar) -> [(NSRange, Token)] {
        var result: [(NSRange, Token)] = []
        let n = chars.count
        var i = 0
        while i < n {
            guard chars[i] == 60 else { i += 1; continue }
            if i + 3 < n, chars[i + 1] == 33, chars[i + 2] == 45, chars[i + 3] == 45 {
                var j = i + 4
                while j + 2 < n, !(chars[j] == 45 && chars[j + 1] == 45 && chars[j + 2] == 62) { j += 1 }
                j = min(n, j + 3)
                result.append((NSRange(location: i, length: j - i), .comment))
                i = j
                continue
            }
            var j = i + 1
            if j < n, chars[j] == 47 || chars[j] == 33 || chars[j] == 63 { j += 1 }
            let nameStart = j
            while j < n, chars[j] != 32, chars[j] != 62, chars[j] != 10, chars[j] != 47 { j += 1 }
            if j > nameStart { result.append((NSRange(location: nameStart, length: j - nameStart), .tag)) }
            while j < n, chars[j] != 62 {
                if chars[j] == 34 || chars[j] == 39 {
                    let q = chars[j]
                    var k = j + 1
                    while k < n, chars[k] != q { k += 1 }
                    k = min(n, k + 1)
                    result.append((NSRange(location: j, length: k - j), .string))
                    j = k
                } else if chars[j] != 32, chars[j] != 10, chars[j] != 61, chars[j] != 47 {
                    var k = j
                    while k < n, chars[k] != 61, chars[k] != 32, chars[k] != 62, chars[k] != 10 { k += 1 }
                    result.append((NSRange(location: j, length: k - j), .attribute))
                    j = k
                } else {
                    j += 1
                }
            }
            i = j + 1
        }
        return result
    }

    static func apply(language: String?, to storage: NSMutableAttributedString, range: NSRange) {
        guard let grammar = grammar(for: language), range.length > 0 else { return }
        let code = (storage.string as NSString).substring(with: range)
            .replacingOccurrences(of: "\u{2028}", with: "\n")
        for (r, token) in tokens(code, grammar: grammar) {
            let target = NSRange(location: range.location + r.location, length: r.length)
            storage.addAttribute(.foregroundColor, value: color(token), range: target)
        }
    }
}
