import AppKit
import SwiftUI

/// A key combination as stored in the defaults ("ctrl+cmd+1", "opt+cmd+left") and shown in menus ("⌃⌘1").
struct Hotkey: Equatable, Hashable {
    /// Lowercased character, or a named key: left, right, up, down, return, tab, space, delete, escape, f1…f12.
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
        let parts = storage.lowercased().split(separator: "+").map(String.init)
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

    var keyboardShortcut: KeyboardShortcut? {
        let equivalent: KeyEquivalent
        if let named = Self.named[key] {
            equivalent = named.equivalent
        } else if key.count == 1, let c = key.first {
            equivalent = KeyEquivalent(c)
        } else {
            return nil
        }
        var modifiers: EventModifiers = []
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

    /// The combination of a key press, or nil for keys that cannot be shortcuts (bare letters, modifiers only).
    init?(event: NSEvent) {
        let flags = event.modifierFlags
        let key: String
        if let named = Self.keyCodes[event.keyCode] {
            key = named
        } else if let base = event.characters(byApplyingModifiers: []), base.count == 1 {
            key = base.lowercased()
        } else {
            return nil
        }
        self.init(key: key, command: flags.contains(.command), control: flags.contains(.control),
                  option: flags.contains(.option), shift: flags.contains(.shift))
        // Plain characters would stop typing; function keys work alone.
        let functionKey = key.count > 1 && key.hasPrefix("f") && Int(key.dropFirst()) != nil
        if !command && !control && !option && !functionKey { return nil }
    }
}

/// Menu commands whose shortcuts can be changed in Settings → Shortcuts.
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

    /// Fixed shortcuts of other menu commands, to warn about clashes.
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
        add("k", "Edit Tags", opt: true); add("f", "Search All Notes", opt: true); add("f", "Find"); add("g", "Find Next")
        add("g", "Find Previous", shift: true); add("t", "Show Tags in Sidebar", ctrl: true); add("s", "Toggle Sidebar", ctrl: true)
        add("0", "Actual Size"); add("+", "Zoom In"); add("-", "Zoom Out"); add("z", "Undo"); add("z", "Redo", shift: true)
        add("c", "Copy"); add("v", "Paste"); add("x", "Cut"); add("a", "Select All"); add("q", "Quit"); add("w", "Close")
        add(",", "Settings"); add("h", "Hide"); add("m", "Minimize"); add("down", "Next Note", opt: true)
        add("up", "Previous Note", opt: true); add("return", "Mark as Done"); add("delete", "Move to Trash")
        add("v", "Vim Mode", ctrl: true, opt: true)
        return r
    }()
}

/// Settings row that records a new shortcut: click, press the keys; Esc cancels, ⌫ clears.
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
    /// Applies a user-configurable shortcut, or none when it was cleared.
    func keyboardShortcut(_ hotkey: Hotkey?) -> some View {
        keyboardShortcut(hotkey?.keyboardShortcut)
    }
}
