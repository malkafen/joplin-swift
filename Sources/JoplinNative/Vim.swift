import AppKit

@MainActor
final class VimEngine {
    enum Mode: Equatable {
        case normal, insert, visual, visualLine

        var label: String {
            switch self {
            case .normal: return "NORMAL"
            case .insert: return "INSERT"
            case .visual: return "VISUAL"
            case .visualLine: return "VISUAL LINE"
            }
        }
    }

    weak var textView: NSTextView?
    var onModeChange: ((Mode) -> Void)?
    private(set) var mode: Mode = .normal {
        didSet {
            guard oldValue != mode else { return }
            onModeChange?(mode)
        }
    }

    private(set) var register = ""
    private(set) var registerLinewise = false
    private var pending = ""
    private var countText = ""
    private var operatorCount = 1
    private var anchor = 0
    private var desiredColumn: Int?
    private var lastFind: (key: Character, char: Character)?
    private var undoCursors: [Int] = []
    private var redoCursors: [Int] = []
    private var changeStart: Int?
    private var insertStart: Int?
    private var edits = 0
    private var insertEdits = 0

    nonisolated(unsafe) private var textObserver: NSObjectProtocol?

    init(textView: NSTextView? = nil) {
        self.textView = textView
        textObserver = NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: textView,
                                                              queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.textDidChange() }
        }
    }

    deinit {
        if let textObserver { NotificationCenter.default.removeObserver(textObserver) }
    }

    private var text: NSString { textView?.textStorage?.mutableString ?? "" }
    private var length: Int { text.length }

    private var cursor: Int {
        get { textView?.selectedRange().location ?? 0 }
        set { place(newValue) }
    }

    private func char(_ i: Int) -> unichar? { i >= 0 && i < length ? text.character(at: i) : nil }
    private func isNewline(_ i: Int) -> Bool { char(i) == 10 }

    private func lineStart(_ i: Int) -> Int {
        let ns = text
        let r = ns.range(of: "\n", options: [.literal, .backwards], range: NSRange(location: 0, length: min(i, ns.length)))
        return r.location == NSNotFound ? 0 : r.location + 1
    }

    private func lineEnd(_ i: Int) -> Int {
        let ns = text
        let from = min(i, ns.length)
        let r = ns.range(of: "\n", options: .literal, range: NSRange(location: from, length: ns.length - from))
        return r.location == NSNotFound ? ns.length : r.location
    }

    private func lastCursorPosition(_ i: Int) -> Int { max(lineStart(i), lineEnd(i) - 1) }

    private func firstNonBlank(_ i: Int) -> Int {
        var p = lineStart(i)
        let e = lineEnd(i)
        while p < e, char(p) == 32 || char(p) == 9 { p += 1 }
        return p
    }

    private func column(_ i: Int) -> Int { i - lineStart(i) }

    private func startOfLine(number: Int) -> Int {
        guard number > 0 else { return 0 }
        let ns = text
        var buffer = [unichar](repeating: 0, count: 65_536)
        var n = 0, p = 0
        while p < ns.length {
            let count = min(buffer.count, ns.length - p)
            ns.getCharacters(&buffer, range: NSRange(location: p, length: count))
            for k in 0..<count where buffer[k] == 10 {
                n += 1
                if n == number { return p + k + 1 }
            }
            p += count
        }
        return lineStart(ns.length)
    }

    private func lineStart(_ i: Int, movingBy count: Int, down: Bool) -> Int? {
        var s = lineStart(i)
        var moved = 0
        while moved < count {
            if down {
                let e = lineEnd(s)
                guard e < length else { break }
                s = e + 1
            } else {
                guard s > 0 else { break }
                s = lineStart(s - 1)
            }
            moved += 1
        }
        return moved > 0 ? s : nil
    }

    private func place(_ i: Int) {
        guard let tv = textView else { return }
        let p = max(0, min(i, length))
        switch mode {
        case .insert:
            tv.setSelectedRange(NSRange(location: p, length: 0))
        case .normal:
            let block = p < length && !isNewline(p) ? 1 : 0
            tv.setSelectedRange(NSRange(location: p, length: block))
        case .visual:
            let lo = min(anchor, p), hi = max(anchor, p)
            tv.setSelectedRange(NSRange(location: lo, length: min(hi + 1, length) - lo))
            visualCursor = p
            return
        case .visualLine:
            let lo = lineStart(min(anchor, p))
            var hi = lineEnd(max(anchor, p))
            if hi < length { hi += 1 }
            tv.setSelectedRange(NSRange(location: lo, length: hi - lo))
            visualCursor = p
            return
        }
        if tv.window != nil { tv.scrollRangeToVisible(NSRange(location: p, length: 0)) }
    }

    private var visualCursor = 0

    private var position: Int { mode == .visual || mode == .visualLine ? visualCursor : cursor }

    private func replace(_ range: NSRange, with string: String) {
        guard let tv = textView, tv.isEditable else { return }
        if changeStart == nil { changeStart = range.location }
        if tv.shouldChangeText(in: range, replacementString: string) {
            tv.textStorage?.replaceCharacters(in: range, with: string)
            tv.didChangeText()
        }
    }

    private func yank(_ range: NSRange, linewise: Bool) {
        register = text.substring(with: range)
        registerLinewise = linewise
    }

    func setMode(_ new: Mode) {
        let p = position
        mode = new
        if new == .visual || new == .visualLine { anchor = p }
        if new == .normal { place(min(p, lastCursorPosition(p))) } else { place(p) }
    }

    func normalizeSelection() {
        guard mode == .normal, let tv = textView, tv.selectedRange().length == 0 else { return }
        place(min(cursor, lastCursorPosition(cursor)))
    }

    func jump(to i: Int) {
        if mode == .visual || mode == .visualLine { mode = .normal }
        desiredColumn = nil
        place(i)
    }

    func reset() {
        pending = ""
        countText = ""
        mode = .normal
        place(min(cursor, lastCursorPosition(cursor)))
    }

    var nonLatinLayoutActive: () -> Bool = { KeyLayout.isNonLatinLayoutActive }

    private func latinKeys(_ event: NSEvent, _ chars: String, shift: Bool) -> String {
        guard !chars.unicodeScalars.allSatisfy(\.isASCII), nonLatinLayoutActive(),
              let latin = KeyLayout.latinTyped(keyCode: event.keyCode, shift: shift) else { return chars }
        return latin
    }

    func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        let bare = latinKeys(event, event.charactersIgnoringModifiers?.lowercased() ?? "", shift: false)
        if flags.contains(.command) { return false }
        if event.keyCode == 53 { return handle(key: "\u{1B}") }
        if flags == .control, bare == "[" { return handle(key: "\u{1B}") }
        if mode == .insert { return false }
        if flags == .control {
            switch bare {
            case "r": return handle(key: "\u{12}")
            case "d", "f": return handle(key: "\u{04}")
            case "u", "b": return handle(key: "\u{15}")
            default: return true
            }
        }
        switch event.specialKey {
        case .delete?: return handle(key: "h")
        case .carriageReturn?, .enter?, .newline?: return handle(key: "+")
        case nil: break
        default: return false
        }
        guard let chars = event.characters, !chars.isEmpty else { return true }
        let argument = pending.last.map { "fFtTr".contains($0) } ?? false
        let keys = argument ? chars : latinKeys(event, chars, shift: event.modifierFlags.contains(.shift))
        for c in keys { handle(key: String(c)) }
        return true
    }

    @discardableResult
    func handle(key: String) -> Bool {
        changeStart = nil
        let wasInsert = mode == .insert
        let undo = textView?.undoManager
        let grouped = !wasInsert && key != "u" && key != "\u{12}" && undo != nil && undo!.groupingLevel == 0
        if grouped { undo!.beginUndoGrouping() }
        let handled = process(key)
        if grouped { undo!.endUndoGrouping() }
        if let start = changeStart, !wasInsert {
            undoCursors.append(insertStart == nil ? start : min(start, insertStart!))
            redoCursors = []
            if mode != .insert { insertStart = nil }
        }
        if mode == .insert, !wasInsert, insertStart == nil {
            insertStart = cursor
            insertEdits = edits
        }
        return handled
    }

    private func process(_ key: String) -> Bool {
        guard let c = key.first else { return false }
        if key == "\u{1B}" {
            pending = ""
            countText = ""
            if mode == .insert {
                let p = cursor
                if let start = insertStart {
                    if edits != insertEdits { undoCursors.append(start) }
                    insertStart = nil
                    redoCursors = []
                }
                mode = .normal
                place(p > lineStart(p) ? p - 1 : p)
            } else {
                setMode(.normal)
            }
            textView?.breakUndoCoalescing()
            return true
        }
        if mode == .insert { return false }

        if let last = pending.last, "fFtTr".contains(last) {
            let op = pending.count > 1 ? pending.first : nil
            pending = ""
            if last == "r" {
                replaceChars(with: c)
            } else {
                lastFind = (last, c)
                findMotion(last, c, count: operatorCount, operator: op)
            }
            return true
        }

        if c.isNumber, c != "0" || !countText.isEmpty {
            countText.append(c)
            return true
        }
        let count = Int(countText) ?? 1
        let hadCount = !countText.isEmpty
        countText = ""
        let visual = mode == .visual || mode == .visualLine

        if pending == "g" {
            pending = ""
            if c == "g" { jump(toLine: hadCount ? count - 1 : 0, operator: nil) }
            return true
        }
        if let op = pending.first, "dcy<>".contains(op) {
            let total = count * operatorCount
            if pending.hasSuffix("g") {
                pending = ""
                if c == "g" { jump(toLine: 0, operator: op) }
                return true
            }
            switch c {
            case "g":
                pending.append("g")
            case "f", "F", "t", "T":
                pending = String(op) + String(c)
                operatorCount = total
            default:
                pending = ""
                if c == op {
                    lineOperation(op, count: total)
                } else if c == "G" {
                    jump(toLine: hadCount ? count - 1 : nil, operator: op)
                } else {
                    motion(c, count: total, operator: op)
                }
            }
            return true
        }

        switch c {
        case "\u{12}":
            guard textView?.undoManager?.canRedo == true else { break }
            textView?.undoManager?.redo()
            let p = redoCursors.popLast() ?? cursor
            undoCursors.append(p)
            place(min(p, lastCursorPosition(p)))
        case "u" where visual:
            caseChange(upper: false)
        case "U" where visual:
            caseChange(upper: true)
        case "~" where visual:
            caseChange(upper: nil)
        case "o" where visual:
            swap(&anchor, &visualCursor)
            place(visualCursor)
        case "u":
            var p = cursor
            for _ in 0..<count where textView?.undoManager?.canUndo == true {
                textView?.undoManager?.undo()
                p = undoCursors.popLast() ?? textView?.selectedRange().location ?? p
                redoCursors.append(p)
            }
            p = min(p, length)
            place(min(p, lastCursorPosition(p)))
        case "d", "c", "y", "<", ">":
            if visual {
                visualOperation(c)
            } else {
                pending = String(c)
                operatorCount = count
            }
        case "x":
            if visual { visualOperation("d") } else { deleteChars(count, before: false) }
        case "X": deleteChars(count, before: true)
        case "D": motion("$", count: count, operator: "d")
        case "C": motion("$", count: count, operator: "c")
        case "Y": lineOperation("y", count: count)
        case "s":
            if visual { visualOperation("c") } else {
                deleteChars(count, before: false)
                setMode(.insert)
            }
        case "S": lineOperation("c", count: count)
        case "r", "f", "F", "t", "T":
            pending = String(c)
            operatorCount = count
        case ";", ",":
            if let last = lastFind {
                let reversed: [Character: Character] = ["f": "F", "F": "f", "t": "T", "T": "t"]
                findMotion(c == ";" ? last.key : reversed[last.key]!, last.char, count: count, operator: nil)
            }
        case "g":
            pending = "g"
        case "G":
            jump(toLine: hadCount ? count - 1 : nil, operator: nil)
        case "i": setMode(.insert)
        case "a":
            let p = cursor
            mode = .insert
            place(p < lineEnd(p) ? p + 1 : p)
        case "I":
            mode = .insert
            place(firstNonBlank(cursor))
        case "A":
            mode = .insert
            place(lineEnd(cursor))
        case "o", "O": openLine(below: c == "o")
        case "v": setMode(mode == .visual ? .normal : .visual)
        case "V": setMode(mode == .visualLine ? .normal : .visualLine)
        case "p", "P": put(after: c == "p", count: count)
        case "J": joinLines(max(count, 2) - 1)
        case "~": toggleCase(count)
        case "\r": motion("+", count: count, operator: nil)
        case "\u{04}", "\u{15}": motion(c == "\u{04}" ? "j" : "k", count: 15 * count, operator: nil)
        default: motion(c, count: count, operator: nil)
        }
        return true
    }

    private enum WordClass { case space, word, punct }

    private func wordClass(_ i: Int, big: Bool) -> WordClass {
        guard let u = char(i), let scalar = Unicode.Scalar(u) else { return .space }
        if CharacterSet.whitespacesAndNewlines.contains(scalar) { return .space }
        if big { return .word }
        return CharacterSet.alphanumerics.contains(scalar) || u == 95 ? .word : .punct
    }

    private func nextWordStart(_ i: Int, big: Bool) -> Int {
        var p = i
        let start = wordClass(p, big: big)
        if start != .space { while p < length, wordClass(p, big: big) == start { p += 1 } }
        while p < length, wordClass(p, big: big) == .space {
            if isNewline(p), p + 1 < length, isNewline(p + 1), p > i { return p + 1 }
            p += 1
        }
        return p
    }

    private func wordEnd(_ i: Int, big: Bool) -> Int {
        var p = i + 1
        while p < length, wordClass(p, big: big) == .space { p += 1 }
        let cls = wordClass(p, big: big)
        while p + 1 < length, wordClass(p + 1, big: big) == cls { p += 1 }
        return min(p, max(length - 1, 0))
    }

    private func previousWordStart(_ i: Int, big: Bool) -> Int {
        var p = i - 1
        while p > 0, wordClass(p, big: big) == .space { p -= 1 }
        let cls = wordClass(p, big: big)
        while p > 0, wordClass(p - 1, big: big) == cls { p -= 1 }
        return max(p, 0)
    }

    private func find(_ key: Character, _ target: Character, from i: Int, count: Int) -> Int? {
        guard let u = target.utf16.first else { return nil }
        var p = i
        var found = 0
        let forward = key == "f" || key == "t"
        let limitLow = lineStart(i), limitHigh = lineEnd(i)
        while found < count {
            p += forward ? 1 : -1
            if forward ? p >= limitHigh : p < limitLow { return nil }
            if char(p) == u { found += 1 }
        }
        if key == "t" { return p - 1 }
        if key == "T" { return p + 1 }
        return p
    }

    private func target(_ key: Character, from start: Int, count: Int, forOperator: Bool)
        -> (end: Int, inclusive: Bool, linewise: Bool)? {
        var p = start
        switch key {
        case "h":
            return (max(lineStart(p), p - count), false, false)
        case "l", " ":
            return (forOperator ? min(p + count, lineEnd(p)) : min(p + count, lastCursorPosition(p)), false, false)
        case "j", "k", "+", "-":
            let down = key == "j" || key == "+"
            let col = desiredColumn ?? column(p)
            guard let s = lineStart(p, movingBy: count, down: down) else { return nil }
            let firstColumn = key == "+" || key == "-"
            desiredColumn = firstColumn ? nil : col
            return (firstColumn ? firstNonBlank(s) : min(s + col, lastCursorPosition(s)), true, true)
        case "w", "W":
            for _ in 0..<count { p = nextWordStart(p, big: key == "W") }
            if forOperator, lineEnd(start) < p { p = max(lineEnd(start), start) }
            return (p, false, false)
        case "b", "B":
            for _ in 0..<count { p = previousWordStart(p, big: key == "B") }
            return (p, false, false)
        case "e", "E":
            for _ in 0..<count { p = wordEnd(p, big: key == "E") }
            return (p, true, false)
        case "0":
            return (lineStart(p), false, false)
        case "^", "_":
            return (firstNonBlank(p), false, false)
        case "$":
            var e = p
            for i in 0..<count { e = lineEnd(i == 0 ? e : e + 1) }
            return (forOperator ? e : max(lineStart(e), e - 1), false, false)
        case "}":
            for _ in 0..<count {
                p = lineEnd(p)
                while p < length, !(isNewline(p) && (p + 1 >= length || isNewline(p + 1))) { p = lineEnd(p + 1) }
                if p < length { p += 1 }
            }
            return (min(p, length), false, false)
        case "{":
            for _ in 0..<count {
                p = lineStart(p)
                if p > 0 { p -= 1 }
                while p > 0, !(isNewline(p) && isNewline(p - 1)) { p -= 1 }
            }
            return (p, false, false)
        default:
            return nil
        }
    }

    private func motion(_ key: Character, count: Int, operator op: Character?) {
        let start = position
        guard let t = target(key, from: start, count: count, forOperator: op != nil) else {
            NSSound.beep()
            return
        }
        if key != "j" && key != "k" { desiredColumn = nil }
        finish(start: start, end: t.end, inclusive: t.inclusive, linewise: t.linewise, operator: op, key: key, count: count)
    }

    private func findMotion(_ key: Character, _ char: Character, count: Int, operator op: Character?) {
        let start = position
        guard let end = find(key, char, from: start, count: max(count, 1)) else {
            NSSound.beep()
            return
        }
        desiredColumn = nil
        finish(start: start, end: end, inclusive: key == "f" || key == "t", linewise: false, operator: op, key: key, count: count)
    }

    private func finish(start: Int, end: Int, inclusive: Bool, linewise: Bool, operator op: Character?, key: Character,
                        count: Int) {
        guard let op else {
            place(mode == .normal ? min(end, lastCursorPosition(end)) : end)
            return
        }
        if linewise {
            let lo = lineStart(min(start, end))
            var hi = lineEnd(max(start, end))
            if hi < length { hi += 1 }
            applyLinewise(op, NSRange(location: lo, length: hi - lo))
            return
        }
        let lo = min(start, end)
        var hi = max(start, end)
        if inclusive { hi = min(hi + 1, length) }
        if op == "c", key == "w" || key == "W", wordClass(start, big: key == "W") != .space {
            var e = start
            for _ in 0..<max(count, 1) { e = wordEnd(e, big: key == "W") }
            hi = min(e + 1, length)
        }
        operate(op, NSRange(location: lo, length: hi - lo), linewise: false)
    }

    private func jump(toLine line: Int?, operator op: Character?) {
        desiredColumn = nil
        let target = firstNonBlank(line.map { startOfLine(number: max(0, $0)) } ?? lineStart(length))
        if let op {
            let lo = lineStart(min(position, target))
            var hi = lineEnd(max(position, target))
            if hi < length { hi += 1 }
            applyLinewise(op, NSRange(location: lo, length: hi - lo))
        } else {
            place(target)
        }
    }

    private func operate(_ op: Character, _ range: NSRange, linewise: Bool) {
        textView?.breakUndoCoalescing()
        switch op {
        case "y":
            yank(range, linewise: linewise)
            mode = .normal
            place(range.location)
        case "d", "c":
            yank(range, linewise: linewise)
            replace(range, with: "")
            if op == "c" {
                mode = .insert
                place(range.location)
            } else {
                mode = .normal
                place(min(range.location, lastCursorPosition(range.location)))
            }
        case ">", "<":
            indent(range, right: op == ">")
        default:
            break
        }
    }

    private func applyLinewise(_ op: Character, _ range: NSRange) {
        let original = range
        var range = range
        if op == "<" || op == ">" {
            indent(range, right: op == ">")
            return
        }
        let content = text.substring(with: range)
        if !content.hasSuffix("\n"), range.location > 0, isNewline(range.location - 1) {
            range = NSRange(location: range.location - 1, length: range.length + 1)
        }
        var yanked = text.substring(with: range)
        if yanked.hasPrefix("\n"), range.location + range.length == length, !content.hasSuffix("\n") { yanked.removeFirst() }
        if !yanked.hasSuffix("\n") { yanked += "\n" }
        register = yanked
        registerLinewise = true
        textView?.breakUndoCoalescing()
        switch op {
        case "c":
            let first = original.location
            let lastEnd = lineEnd(max(first, NSMaxRange(original) - 1))
            let indentEnd = firstNonBlank(first)
            replace(NSRange(location: indentEnd, length: max(0, lastEnd - indentEnd)), with: "")
            mode = .insert
            place(indentEnd)
        case "d":
            replace(range, with: "")
            mode = .normal
            place(firstNonBlank(lineStart(min(range.location, length))))
        default:
            mode = .normal
            place(original.location)
        }
    }

    private func lineOperation(_ op: Character, count: Int) {
        let lo = lineStart(position)
        var hi = lo
        for _ in 0..<count where hi < length { hi = min(lineEnd(hi) + 1, length) }
        if hi == lo { hi = lineEnd(lo) }
        applyLinewise(op, NSRange(location: lo, length: hi - lo))
    }

    private func visualOperation(_ op: Character) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        let linewise = mode == .visualLine
        mode = .normal
        if linewise { applyLinewise(op, range) } else { operate(op, range, linewise: false) }
    }

    private func indent(_ range: NSRange, right: Bool) {
        let lo = lineStart(range.location)
        let hi = lineEnd(max(range.location, NSMaxRange(range) - 1))
        let block = text.substring(with: NSRange(location: lo, length: hi - lo))
        let lines = block.components(separatedBy: "\n").map { line -> String in
            if right { return line.isEmpty ? line : "    " + line }
            var l = Substring(line)
            var removed = 0
            while removed < 4, let f = l.first, f == " " { l = l.dropFirst(); removed += 1 }
            if removed == 0, l.first == "\t" { l = l.dropFirst() }
            return String(l)
        }
        replace(NSRange(location: lo, length: hi - lo), with: lines.joined(separator: "\n"))
        mode = .normal
        place(firstNonBlank(lo))
    }

    private func deleteChars(_ count: Int, before: Bool) {
        let p = cursor
        let range = before
            ? NSRange(location: max(lineStart(p), p - count), length: p - max(lineStart(p), p - count))
            : NSRange(location: p, length: min(count, lineEnd(p) - p))
        guard range.length > 0 else { return }
        yank(range, linewise: false)
        textView?.breakUndoCoalescing()
        replace(range, with: "")
        place(min(range.location, lastCursorPosition(range.location)))
    }

    private func replaceChars(with c: Character) {
        let p = cursor
        let n = min(max(operatorCount, 1), lineEnd(p) - p)
        guard n > 0 else { return }
        replace(NSRange(location: p, length: n), with: String(repeating: String(c), count: n))
        place(p + n - 1)
    }

    private func toggleCase(_ count: Int) {
        let p = cursor
        let n = min(count, lineEnd(p) - p)
        guard n > 0 else { return }
        let s = text.substring(with: NSRange(location: p, length: n))
        let toggled = String(s.map { c -> Character in
            let str = String(c)
            return Character(str == str.uppercased() ? str.lowercased() : str.uppercased())
        })
        replace(NSRange(location: p, length: n), with: toggled)
        place(min(p + n, lastCursorPosition(p)))
    }

    private func caseChange(upper: Bool?) {
        guard let tv = textView else { return }
        let r = tv.selectedRange()
        let s = text.substring(with: r)
        let changed: String
        switch upper {
        case true?: changed = s.uppercased()
        case false?: changed = s.lowercased()
        case nil: changed = String(s.map { c -> Character in
            let str = String(c)
            return Character(str == str.uppercased() ? str.lowercased() : str.uppercased())
        })
        }
        replace(r, with: changed)
        mode = .normal
        place(r.location)
    }

    private func openLine(below: Bool) {
        let p = cursor
        let indent = text.substring(with: NSRange(location: lineStart(p), length: firstNonBlank(p) - lineStart(p)))
        textView?.breakUndoCoalescing()
        if below {
            let e = lineEnd(p)
            replace(NSRange(location: e, length: 0), with: "\n" + indent)
            mode = .insert
            place(e + 1 + (indent as NSString).length)
        } else {
            let s = lineStart(p)
            replace(NSRange(location: s, length: 0), with: indent + "\n")
            mode = .insert
            place(s + (indent as NSString).length)
        }
    }

    private func put(after: Bool, count: Int) {
        guard !register.isEmpty else { return }
        let content = String(repeating: register, count: max(count, 1))
        textView?.breakUndoCoalescing()
        if mode == .visual || mode == .visualLine, let tv = textView {
            let r = tv.selectedRange()
            mode = .normal
            replace(r, with: content)
            place(r.location)
            return
        }
        let p = cursor
        if registerLinewise {
            if after {
                let e = lineEnd(p)
                if e >= length {
                    replace(NSRange(location: e, length: 0), with: "\n" + String(content.dropLast()))
                    place(firstNonBlank(e + 1))
                } else {
                    replace(NSRange(location: e + 1, length: 0), with: content)
                    place(firstNonBlank(e + 1))
                }
            } else {
                let s = lineStart(p)
                replace(NSRange(location: s, length: 0), with: content)
                place(firstNonBlank(s))
            }
        } else {
            let at = after && p < lineEnd(p) ? p + 1 : p
            replace(NSRange(location: at, length: 0), with: content)
            place(at + (content as NSString).length - 1)
        }
    }

    private func joinLines(_ times: Int) {
        var p = cursor
        for _ in 0..<times {
            let e = lineEnd(p)
            guard e < length else { break }
            var next = e + 1
            while next < length, char(next) == 32 || char(next) == 9 { next += 1 }
            let joiner = next < length && !isNewline(next) && e > lineStart(e) ? " " : ""
            replace(NSRange(location: e, length: next - e), with: joiner)
            p = e
        }
        place(p)
    }

    private func textDidChange() {
        edits &+= 1
    }
}
