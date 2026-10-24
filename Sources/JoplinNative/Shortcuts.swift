import AppKit
import Carbon.HIToolbox
import SwiftUI

enum KeyLayout {
    static func character(keyCode: UInt16, in source: TISInputSource, shift: Bool = false) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let modifiers = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), modifiers, UInt32(LMGetKbdType()),
                                  OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: length)
        return s.unicodeScalars.allSatisfy({ $0.properties.isWhitespace || $0.value < 0x20 }) ? nil : s
    }

    private static let ansi: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b", 12: "q", 13: "w",
        14: "e", 15: "r", 16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 37: "l", 38: "j",
        39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "n", 46: "m", 47: ".", 50: "`",
        65: ".", 67: "*", 69: "+", 75: "/", 78: "-", 81: "=", 82: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5",
        88: "6", 89: "7", 91: "8", 92: "9",
    ]

    static func latinCharacter(keyCode: UInt16) -> String? {
        if let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
           let c = character(keyCode: keyCode, in: source)?.lowercased(), c.count == 1 {
            return c
        }
        return ansi[keyCode]
    }

    static var isNonLatinLayoutActive: Bool {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let p = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else { return false }
        return !CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(p).takeUnretainedValue())
    }

    static func latinTyped(keyCode: UInt16, shift: Bool) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let c = character(keyCode: keyCode, in: source, shift: shift), c.unicodeScalars.allSatisfy(\.isASCII) else {
            return ansi[keyCode].map { shift ? $0.uppercased() : $0 }
        }
        return c
    }

    static var nonLatinLayouts: [TISInputSource] {
        let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String] as CFDictionary
        let all = (TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource]) ?? []
        return all.filter { source in
            guard let p = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else { return false }
            return !CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(p).takeUnretainedValue())
        }
    }

    static func latinCharacter(for character: String, layouts: [TISInputSource] = nonLatinLayouts) -> String? {
        for source in layouts {
            for code in UInt16(0)..<128 where Self.character(keyCode: code, in: source)?.lowercased() == character {
                if let latin = latinCharacter(keyCode: code), latin != character { return latin }
            }
        }
        return nil
    }
}

struct Hotkey: Equatable, Hashable {
    var key: String
    var command = false
    var control = false
    var option = false
    var shift = false

    init(key: String, command: Bool = false, control: Bool = false, option: Bool = false, shift: Bool = false) {
        self.key = key.lowercased()
        self.command = command
        self.control = control
        self.option = option
        self.shift = shift
    }

    init?(storage: String) {
        var parts = storage.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if parts.count >= 2, parts.suffix(2) == ["", ""] {
            parts.removeLast(2)
            parts.append("+")
        }
        guard let key = parts.last, !key.isEmpty else { return nil }
        self.init(key: key)
        for p in parts.dropLast() {
            switch p {
            case "cmd": command = true
            case "ctrl": control = true
            case "opt": option = true
            case "shift": shift = true
            default: return nil
            }
        }
    }

    var storage: String {
        var parts: [String] = []
        if control { parts.append("ctrl") }
        if option { parts.append("opt") }
        if shift { parts.append("shift") }
        if command { parts.append("cmd") }
        return (parts + [key]).joined(separator: "+")
    }

    private static let named: [String: (symbol: String, equivalent: KeyEquivalent)] = [
        "left": ("←", .leftArrow), "right": ("→", .rightArrow), "up": ("↑", .upArrow), "down": ("↓", .downArrow),
        "return": ("↩", .return), "tab": ("⇥", .tab), "space": ("Space", .space), "delete": ("⌫", .delete),
        "escape": ("⎋", .escape), "home": ("↖", .home), "end": ("↘", .end), "pageup": ("⇞", .pageUp),
        "pagedown": ("⇟", .pageDown),
    ]

    var display: String {
        var s = ""
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if command { s += "⌘" }
        return s + (Self.named[key]?.symbol ?? key.uppercased())
    }

    var functionKeyNumber: Int? {
        guard key.count > 1, key.hasPrefix("f"), let n = Int(key.dropFirst()), (1...12).contains(n) else { return nil }
        return n
    }

    var keyboardShortcut: KeyboardShortcut? {
        let equivalent: KeyEquivalent
        if let named = Self.named[key] {
            equivalent = named.equivalent
        } else if let n = functionKeyNumber, let scalar = UnicodeScalar(NSF1FunctionKey + n - 1) {
            equivalent = KeyEquivalent(Character(scalar))
        } else if key.count == 1, let c = key.first {
            equivalent = KeyEquivalent(c)
        } else {
            return nil
        }
        var modifiers: SwiftUI.EventModifiers = []
        if command { modifiers.insert(.command) }
        if control { modifiers.insert(.control) }
        if option { modifiers.insert(.option) }
        if shift { modifiers.insert(.shift) }
        return KeyboardShortcut(equivalent, modifiers: modifiers)
    }

    private static let keyCodes: [UInt16: String] = [
        123: "left", 124: "right", 126: "up", 125: "down", 36: "return", 76: "return", 48: "tab", 49: "space",
        51: "delete", 53: "escape", 115: "home", 119: "end", 116: "pageup", 121: "pagedown",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9",
        109: "f10", 103: "f11", 111: "f12",
    ]

    init?(event: NSEvent) {
        let flags = event.modifierFlags
        let key: String
        if let named = Self.keyCodes[event.keyCode] {
            key = named
        } else if let latin = KeyLayout.latinCharacter(keyCode: event.keyCode) {
            key = latin
        } else if let base = event.characters(byApplyingModifiers: []), base.count == 1 {
            key = base.lowercased()
        } else {
            return nil
        }
        self.init(key: key, command: flags.contains(.command), control: flags.contains(.control),
                  option: flags.contains(.option), shift: flags.contains(.shift))
        if !command && !control && !option && functionKeyNumber == nil { return nil }
    }

    func latinized(layouts: [TISInputSource] = KeyLayout.nonLatinLayouts) -> Hotkey? {
        guard key.count == 1, !key.unicodeScalars.allSatisfy(\.isASCII),
              let latin = KeyLayout.latinCharacter(for: key, layouts: layouts) else { return nil }
        var copy = self
        copy.key = latin
        return copy
    }
}

enum ShortcutAction: String, CaseIterable, Identifiable {
    case editorOnly, split, previewOnly, cycleLayout

    var id: String { rawValue }

    var title: String {
        switch self {
        case .editorOnly: return "Editor Only"
        case .split: return "Editor and Preview"
        case .previewOnly: return "Preview Only"
        case .cycleLayout: return "Toggle Editor Layout"
        }
    }

    var defaultHotkey: Hotkey {
        switch self {
        case .editorOnly: return Hotkey(key: "1", command: true, control: true)
        case .split: return Hotkey(key: "2", command: true, control: true)
        case .previewOnly: return Hotkey(key: "3", command: true, control: true)
        case .cycleLayout: return Hotkey(key: "l", control: true)
        }
    }

    var defaultsKey: String { "shortcut.\(rawValue)" }

    static let reserved: [Hotkey: String] = {
        var r: [Hotkey: String] = [:]
        func add(_ key: String, _ title: String, cmd: Bool = true, ctrl: Bool = false, opt: Bool = false, shift: Bool = false) {
            r[Hotkey(key: key, command: cmd, control: ctrl, option: opt, shift: shift)] = title
        }
        add("n", "New Note"); add("n", "New To-do", shift: true); add("n", "New Notebook", opt: true)
        add("s", "Synchronise"); add("b", "Bold"); add("i", "Italic"); add("e", "Inline Code"); add("k", "Link")
        add("x", "Strikethrough", shift: true); add("h", "Highlight", shift: true); add("t", "Insert Date", shift: true)
        add("1", "Heading 1", opt: true); add("2", "Heading 2", opt: true); add("3", "Heading 3", opt: true)
        add("8", "Bulleted List", shift: true); add("7", "Numbered List", shift: true); add("9", "Checklist", shift: true)
        add("m", "Math Formula", ctrl: true); add("a", "Attach File", shift: true); add("d", "Duplicate")
        add("d", "Switch to To-do", shift: true); add("l", "Copy Markdown Link", shift: true); add("r", "Edit Title", opt: true)
        add("k", "Edit Tags", opt: true); add("l", "Search All Notes"); add("f", "Find in Note"); add("g", "Find Next")
        add("g", "Find Previous", shift: true); add("t", "Show Tags in Sidebar", ctrl: true); add("s", "Toggle Sidebar", ctrl: true)
        add("0", "Actual Size"); add("+", "Zoom In"); add("-", "Zoom Out"); add("z", "Undo"); add("z", "Redo", shift: true)
        add("c", "Copy"); add("v", "Paste"); add("x", "Cut"); add("a", "Select All"); add("q", "Quit"); add("w", "Close")
        add(",", "Settings"); add("h", "Hide"); add("m", "Minimize"); add("down", "Next Note", opt: true)
        add("up", "Previous Note", opt: true); add("return", "Mark as Done"); add("delete", "Move to Trash")
        add("v", "Vim Mode", ctrl: true, opt: true)
        return r
    }()
}

struct ShortcutRecorder: View {
    let action: ShortcutAction
    @Environment(AppModel.self) private var model

    var body: some View {
        let recording = model.recordingShortcut == action
        let current = model.hotkey(for: action)
        LabeledContent(action.title) {
            HStack(spacing: 6) {
                if let clash = model.shortcutConflict(for: action) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("Also used by “\(clash)”")
                }
                Button {
                    recording ? model.stopRecordingShortcut() : model.startRecordingShortcut(action)
                } label: {
                    Text(recording ? "Type shortcut…" : (current?.display ?? "None"))
                        .monospacedDigit()
                        .frame(minWidth: 110)
                }
                .buttonStyle(.bordered)
                .tint(recording ? .accentColor : nil)
                Button {
                    model.resetShortcut(action)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Restore \(action.defaultHotkey.display)")
                .disabled(current == action.defaultHotkey)
            }
        }
    }
}

extension View {
    func keyboardShortcut(_ hotkey: Hotkey?) -> some View {
        keyboardShortcut(hotkey?.keyboardShortcut)
    }
}
