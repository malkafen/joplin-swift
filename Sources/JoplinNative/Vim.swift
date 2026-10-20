import AppKit

/// Vim navigation for an `NSTextView`: normal and insert modes, counts, the motions h j k l w b e W B E 0 ^ $ gg G
/// f F t T ; , { } + - ⌃D ⌃U, and i a I A o O to start typing. "/" and "?" open the system find bar, n and N go to
/// the next and previous match. Editing is left to the text view. Normal mode shows the character under the cursor
/// selected, which reads as a block cursor.
///
/// The text is read in place, around the cursor: copying a note of hundreds of thousands of lines per key is slow.
@MainActor
final class VimEngine {
    enum Mode: Equatable {
        case normal, insert

        var label: String {
            switch self {
            case .normal: return "NORMAL"
            case .insert: return "INSERT"
            }
        }
    }

    weak var textView: NSTextView?
    var onModeChange: ((Mode) -> Void)?

    private(set) var mode: Mode = .normal {
        didSet { if oldValue != mode { onModeChange?(mode) } }
    }

    private var pending = ""
    private var countText = ""
    private var desiredColumn: Int?
    private var lastFind: (key: Character, char: Character)?
    /// The last search was typed after "?": n goes backwards.
    private var searchBackwards = false

    init(textView: NSTextView? = nil) {
        self.textView = textView
    }

    // MARK: Text helpers

    private var text: NSString { textView?.textStorage?.mutableString ?? "" }
    private var length: Int { text.length }

    private var cursor: Int { textView?.selectedRange().location ?? 0 }

    private func char(_ i: Int) -> unichar? { i >= 0 && i < length ? text.character(at: i) : nil }
    private func isNewline(_ i: Int) -> Bool { char(i) == 10 }

    private func lineStart(_ i: Int) -> Int {
        let ns = text
        let r = ns.range(of: "\n", options: [.literal, .backwards], range: NSRange(location: 0, length: min(i, ns.length)))
        return r.location == NSNotFound ? 0 : r.location + 1
    }

    /// Index of the line's newline (or the end of the text).
    private func lineEnd(_ i: Int) -> Int {
        let ns = text
        let from = min(i, ns.length)
        let r = ns.range(of: "\n", options: .literal, range: NSRange(location: from, length: ns.length - from))
        return r.location == NSNotFound ? ns.length : r.location
    }

    /// Last character a normal-mode cursor may sit on.
    private func lastCursorPosition(_ i: Int) -> Int { max(lineStart(i), lineEnd(i) - 1) }

    private func firstNonBlank(_ i: Int) -> Int {
        var p = lineStart(i)
        let e = lineEnd(i)
        while p < e, char(p) == 32 || char(p) == 9 { p += 1 }
        return p
    }

    private func column(_ i: Int) -> Int { i - lineStart(i) }

    /// Start of line `number` (0-based), or of the last line. Reads the text in chunks: per-character access is far
    /// too slow for notes of hundreds of thousands of lines.
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

    /// Start of the line `count` lines below (or above) the one at `i`, stopping at the last (first) line;
    /// nil when already there.
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

    /// Shows the cursor: in normal mode the character under it is selected as a block.
    private func place(_ i: Int) {
        guard let tv = textView else { return }
        let p = max(0, min(i, length))
        let block = mode == .normal && p < length && !isNewline(p) ? 1 : 0
        tv.setSelectedRange(NSRange(location: p, length: block))
        // Off-window, AppKit defers the scroll to a block that leaks if the view goes away before layout.
        if tv.window != nil { tv.scrollRangeToVisible(NSRange(location: p, length: 0)) }
    }

    // MARK: Mode changes

    func setMode(_ new: Mode) {
        let p = cursor
        mode = new
        place(new == .normal ? min(p, lastCursorPosition(p)) : p)
    }

    /// After a mouse click in normal mode the caret becomes a block again.
    func normalizeSelection() {
        guard mode == .normal, let tv = textView, tv.selectedRange().length == 0 else { return }
        place(min(cursor, lastCursorPosition(cursor)))
    }

    /// Back to normal mode after loading another note.
    func reset() {
        pending = ""
        countText = ""
        desiredColumn = nil
        mode = .normal
        place(min(cursor, lastCursorPosition(cursor)))
    }

    // MARK: Key handling

    /// Whether a layout without Latin letters is active; replaced in tests.
    var nonLatinLayoutActive: () -> Bool = { KeyLayout.isNonLatinLayoutActive }

    /// With a Cyrillic (or other non-Latin) layout active, letters typed as commands mean the key at the same place in
    /// the Latin layout, as Vim's 'langmap' does: "о" is j, "в" with ⌃ is ⌃D.
    private func latinKeys(_ event: NSEvent, _ chars: String, shift: Bool) -> String {
        guard !chars.unicodeScalars.allSatisfy(\.isASCII), nonLatinLayoutActive(),
              let latin = KeyLayout.latinTyped(keyCode: event.keyCode, shift: shift) else { return chars }
        return latin
    }

    /// Handles a key press; returns false to let the text view process it.
    func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        let bare = latinKeys(event, event.charactersIgnoringModifiers?.lowercased() ?? "", shift: false)
        if flags.contains(.command) { return false }
        if event.keyCode == 53 { return handle(key: "\u{1B}") } // Esc
        if flags == .control, bare == "[" { return handle(key: "\u{1B}") }
        if mode == .insert { return false }
        if flags == .control {
            switch bare {
            case "d", "f": return handle(key: "\u{04}")
            case "u", "b": return handle(key: "\u{15}")
            default: return true
            }
        }
        switch event.specialKey {
        case .delete?: return handle(key: "h")
        case .carriageReturn?, .enter?, .newline?: return handle(key: "+")
        case nil: break
        default: return false // arrows, Tab, Home… keep their usual meaning
        }
        guard let chars = event.characters, !chars.isEmpty else { return true }
        // The character after f or t is text to find, not a command.
        let argument = pending.last.map { "fFtT".contains($0) } ?? false
        let keys = argument ? chars : latinKeys(event, chars, shift: event.modifierFlags.contains(.shift))
        for c in keys { handle(key: String(c)) }
        return true
    }

    /// Handles one typed character (Esc is "\u{1B}", ⌃D "\u{04}", ⌃U "\u{15}", Return "\r").
    @discardableResult
    func handle(key: String) -> Bool {
        guard let c = key.first else { return false }
        if key == "\u{1B}" {
            pending = ""
            countText = ""
            if mode == .insert {
                let p = cursor
                mode = .normal
                place(p > lineStart(p) ? p - 1 : p)
                textView?.breakUndoCoalescing()
            } else {
                setMode(.normal)
            }
            return true
        }
        if mode == .insert { return false }

        if let last = pending.last, "fFtT".contains(last) {
            pending = ""
            lastFind = (last, c)
            findMotion(last, c, count: Int(countText) ?? 1)
            countText = ""
            return true
        }
        if c.isNumber, c != "0" || !countText.isEmpty {
            countText.append(c)
            return true
        }
        let count = Int(countText) ?? 1
        let hadCount = !countText.isEmpty
        countText = ""

        if pending == "g" {
            pending = ""
            if c == "g" { jump(toLine: hadCount ? count - 1 : 0) }
            return true
        }
        switch c {
        case "f", "F", "t", "T":
            pending = String(c)
            if hadCount { countText = String(count) }
        case ";", ",":
            if let last = lastFind {
                let reversed: [Character: Character] = ["f": "F", "F": "f", "t": "T", "T": "t"]
                findMotion(c == ";" ? last.key : reversed[last.key]!, last.char, count: count)
            }
        case "g":
            pending = "g"
        case "G":
            if hadCount { jump(toLine: count - 1) } else { place(firstNonBlank(length)) }
            desiredColumn = nil
        case "i":
            setMode(.insert)
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
        case "o", "O":
            openLine(below: c == "o")
        case "/", "?":
            searchBackwards = c == "?"
            finder(.showFindInterface)
        case "n", "N":
            for _ in 0..<count { finder((c == "N") != searchBackwards ? .previousMatch : .nextMatch) }
            normalizeMatch()
        case "\r":
            motion("+", count: count)
        case "\u{04}", "\u{15}":
            motion(c == "\u{04}" ? "j" : "k", count: 15 * count)
        default:
            motion(c, count: count)
        }
        return true
    }

    // MARK: Search

    /// Runs a find bar action of the text view, as the Find menu does.
    private func finder(_ action: NSTextFinder.Action) {
        guard let tv = textView else { return }
        let item = NSMenuItem()
        item.tag = action.rawValue
        tv.performTextFinderAction(item)
    }

    /// The cursor goes to the start of the match found.
    private func normalizeMatch() {
        guard let tv = textView else { return }
        let p = tv.selectedRange().location
        place(min(p, lastCursorPosition(p)))
    }

    // MARK: Motions

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
            // An empty line is a word of its own.
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

    /// Where a motion key moves the cursor; nil for an unknown key or when it cannot move.
    private func target(_ key: Character, from start: Int, count: Int) -> Int? {
        var p = start
        switch key {
        case "h":
            return max(lineStart(p), p - count)
        case "l", " ":
            return min(p + count, lastCursorPosition(p))
        case "j", "k", "+", "-":
            let down = key == "j" || key == "+"
            let col = desiredColumn ?? column(p)
            // Moving past the first or last line stops there; already there, it is an error.
            guard let s = lineStart(p, movingBy: count, down: down) else { return nil }
            let firstColumn = key == "+" || key == "-"
            desiredColumn = firstColumn ? nil : col
            return firstColumn ? firstNonBlank(s) : min(s + col, lastCursorPosition(s))
        case "w", "W":
            for _ in 0..<count { p = nextWordStart(p, big: key == "W") }
            return p
        case "b", "B":
            for _ in 0..<count { p = previousWordStart(p, big: key == "B") }
            return p
        case "e", "E":
            for _ in 0..<count { p = wordEnd(p, big: key == "E") }
            return p
        case "0":
            return lineStart(p)
        case "^", "_":
            return firstNonBlank(p)
        case "$":
            var e = p
            for i in 0..<count { e = lineEnd(i == 0 ? e : e + 1) }
            return max(lineStart(e), e - 1)
        case "}":
            for _ in 0..<count {
                p = lineEnd(p)
                while p < length, !(isNewline(p) && (p + 1 >= length || isNewline(p + 1))) { p = lineEnd(p + 1) }
                if p < length { p += 1 }
            }
            return min(p, length)
        case "{":
            for _ in 0..<count {
                p = lineStart(p)
                if p > 0 { p -= 1 }
                while p > 0, !(isNewline(p) && isNewline(p - 1)) { p -= 1 }
            }
            return p
        default:
            return nil
        }
    }

    private func motion(_ key: Character, count: Int) {
        guard let end = target(key, from: cursor, count: count) else {
            NSSound.beep()
            return
        }
        if !"jk+-".contains(key) { desiredColumn = nil }
        place(min(end, lastCursorPosition(end)))
    }

    private func findMotion(_ key: Character, _ char: Character, count: Int) {
        guard let end = find(key, char, from: cursor, count: max(count, 1)) else {
            NSSound.beep()
            return
        }
        desiredColumn = nil
        place(end)
    }

    private func jump(toLine line: Int) {
        desiredColumn = nil
        place(firstNonBlank(startOfLine(number: max(0, line))))
    }

    // MARK: Insert

    private func openLine(below: Bool) {
        guard let tv = textView, tv.isEditable else { return }
        let p = cursor
        let indent = text.substring(with: NSRange(location: lineStart(p), length: firstNonBlank(p) - lineStart(p)))
        let at = below ? lineEnd(p) : lineStart(p)
        let inserted = below ? "\n" + indent : indent + "\n"
        tv.breakUndoCoalescing()
        if tv.shouldChangeText(in: NSRange(location: at, length: 0), replacementString: inserted) {
            tv.textStorage?.replaceCharacters(in: NSRange(location: at, length: 0), with: inserted)
            tv.didChangeText()
        }
        mode = .insert
        place(at + (indent as NSString).length + (below ? 1 : 0))
    }
}
