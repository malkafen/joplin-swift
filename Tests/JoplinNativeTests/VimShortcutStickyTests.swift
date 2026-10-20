import AppKit
import Carbon.HIToolbox
import Foundation
@testable import JoplinCore
import SwiftUI
import Testing
@testable import JoplinNative

@MainActor
func keyEvent(_ chars: String, keyCode: UInt16 = 0, flags: NSEvent.ModifierFlags = [], ignoring: String? = nil) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                     characters: chars, charactersIgnoringModifiers: ignoring ?? chars, isARepeat: false, keyCode: keyCode)!
}

@MainActor
@Suite struct HotkeyTests {
    @Test func storageAndDisplay() throws {
        let h = Hotkey(key: "L", command: true, control: true, option: true, shift: true)
        #expect(h.storage == "ctrl+opt+shift+cmd+l")
        #expect(Hotkey(storage: h.storage) == h)
        #expect(h.display == "⌃⌥⇧⌘L")
        #expect(Hotkey(key: "left", option: true).display == "⌥←")
        #expect(Hotkey(storage: "") == nil)
        #expect(Hotkey(storage: "hyper+x") == nil)
        #expect(Hotkey(key: "1", command: true).keyboardShortcut != nil)
        #expect(Hotkey(key: "up", command: true).keyboardShortcut?.key == .upArrow)
        #expect(Hotkey(key: "", command: true).keyboardShortcut == nil)
        #expect(Hotkey(key: "f13").keyboardShortcut == nil)
    }

    @Test func functionKeysBecomeMenuShortcuts() throws {
        let f5 = try #require(Hotkey(key: "f5", control: true).keyboardShortcut)
        #expect(f5.key.character == Character(UnicodeScalar(NSF5FunctionKey)!))
        #expect(f5.modifiers == .control)
        #expect(Hotkey(key: "f1").keyboardShortcut?.key.character == Character(UnicodeScalar(NSF1FunctionKey)!))
        #expect(Hotkey(key: "f12").keyboardShortcut?.key.character == Character(UnicodeScalar(NSF12FunctionKey)!))
        #expect(Hotkey(key: "f5").display == "F5")
    }

    @Test func plusKeySurvivesStorage() {
        let plus = Hotkey(key: "+", command: true, control: true)
        #expect(plus.storage == "ctrl+cmd++")
        #expect(Hotkey(storage: plus.storage) == plus)
        #expect(Hotkey(storage: "+") == Hotkey(key: "+"))
        #expect(Hotkey(storage: "cmd+") == nil)
        #expect(Hotkey(storage: "ctrl+opt+l") == Hotkey(key: "l", control: true, option: true))
    }

    @Test func fromEvents() {
        #expect(Hotkey(event: keyEvent("1", keyCode: 18, flags: [.command, .control])) == Hotkey(key: "1", command: true, control: true))
        #expect(Hotkey(event: keyEvent("a", keyCode: 0)) == nil) // plain letter
        #expect(Hotkey(event: keyEvent("", keyCode: 123, flags: [.option]))?.key == "left")
        #expect(Hotkey(event: keyEvent("", keyCode: 96))?.key == "f5") // function key alone
    }

    /// With a Cyrillic layout active the L key types "д"; the shortcut is still recorded on L.
    @Test func eventsAreReadOnTheLatinKey() {
        let event = keyEvent("\u{0C}", keyCode: 37, flags: [.control, .option], ignoring: "д")
        #expect(Hotkey(event: event) == Hotkey(key: "l", control: true, option: true))
        #expect(KeyLayout.latinCharacter(keyCode: 37) == "l")
        #expect(KeyLayout.latinCharacter(keyCode: 18) == "1")
    }

    @Test func storedCyrillicKeysAreMigrated() throws {
        let russian = KeyLayout.nonLatinLayouts.filter { source in
            let id = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
                .map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } ?? ""
            return id.hasSuffix(".Russian")
        }
        #expect(Hotkey(key: "l", control: true).latinized() == nil) // already Latin
        #expect(Hotkey(key: "left", control: true).latinized() == nil)
        guard !russian.isEmpty else { return } // the Russian layout is not enabled on this Mac
        #expect(Hotkey(key: "д", control: true, option: true).latinized(layouts: russian) == Hotkey(key: "l", control: true, option: true))
        #expect(Hotkey(key: "й", command: true).latinized(layouts: russian) == Hotkey(key: "q", command: true))

        let h = try ModelHarness(welcome: false) { $0.set("ctrl+opt+д", forKey: "shortcut.cycleLayout") }
        #expect(h.model.hotkey(for: .cycleLayout) == Hotkey(key: "l", control: true, option: true))
        #expect(h.defaults.string(forKey: "shortcut.cycleLayout") == "ctrl+opt+l")
    }

    @Test func modelShortcuts() throws {
        let h = try ModelHarness(welcome: false)
        let model = h.model
        #expect(model.hotkey(for: .split) == ShortcutAction.split.defaultHotkey)
        #expect(model.shortcutConflict(for: .split) == nil)
        model.setHotkey(Hotkey(key: "b", command: true), for: .split)
        #expect(model.shortcutConflict(for: .split) == "Bold")
        model.setHotkey(ShortcutAction.editorOnly.defaultHotkey, for: .split)
        #expect(model.shortcutConflict(for: .split) == "Editor Only")
        model.setHotkey(nil, for: .previewOnly)
        #expect(model.hotkey(for: .previewOnly) == nil)
        #expect(model.shortcutConflict(for: .previewOnly) == nil)
        #expect(h.defaults.string(forKey: "shortcut.previewOnly") == "")

        let reloaded = try ModelHarness(welcome: false) { d in
            d.set(h.defaults.string(forKey: "shortcut.split"), forKey: "shortcut.split")
            d.set("", forKey: "shortcut.previewOnly")
        }
        #expect(reloaded.model.hotkey(for: .split) == ShortcutAction.editorOnly.defaultHotkey)
        #expect(reloaded.model.hotkey(for: .previewOnly) == nil)
        model.resetShortcut(.split)
        #expect(model.hotkey(for: .split) == ShortcutAction.split.defaultHotkey)
        #expect(h.defaults.object(forKey: "shortcut.split") == nil)
        #expect(ShortcutAction.allCases.map(\.title).count == 4)
    }

    @Test func recording() throws {
        let model = try ModelHarness(welcome: false).model
        #expect(!model.recordShortcut(keyEvent("x")))
        model.startRecordingShortcut(.cycleLayout)
        #expect(model.recordingShortcut == .cycleLayout)
        #expect(model.recordShortcut(keyEvent("q"))) // not a valid shortcut: swallowed, still recording
        #expect(model.recordingShortcut == .cycleLayout)
        #expect(model.recordShortcut(keyEvent("k", keyCode: 40, flags: [.control, .option])))
        #expect(model.hotkey(for: .cycleLayout) == Hotkey(key: "k", control: true, option: true))
        #expect(model.recordingShortcut == nil)
        model.startRecordingShortcut(.cycleLayout)
        #expect(model.recordShortcut(keyEvent("\u{1B}", keyCode: 53)))
        #expect(model.hotkey(for: .cycleLayout) == Hotkey(key: "k", control: true, option: true))
        model.startRecordingShortcut(.cycleLayout)
        #expect(model.recordShortcut(keyEvent("\u{7F}", keyCode: 51)))
        #expect(model.hotkey(for: .cycleLayout) == nil)
        model.stopRecordingShortcut()
    }
}

@MainActor
@Suite(.serialized) struct VimTests {
    private func setup(_ text: String, at cursor: Int = 0) -> (NSTextView, VimEngine, NSWindow) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let tv = MarkdownTextView(frame: window.contentView!.bounds)
        tv.allowsUndo = true
        tv.isRichText = false
        tv.string = text
        window.contentView?.addSubview(tv)
        let vim = VimEngine(textView: tv)
        tv.vim = vim
        tv.setSelectedRange(NSRange(location: cursor, length: 0))
        vim.reset()
        return (tv, vim, window)
    }

    /// Keys as typed: what the engine does not take (insert mode) goes into the text, as in the app.
    private func keys(_ vim: VimEngine, _ sequence: String) {
        for c in sequence {
            if !vim.handle(key: String(c)) {
                vim.textView?.insertText(String(c), replacementRange: vim.textView!.selectedRange())
            }
            // Each key press is its own event: let the undo manager close the event's undo group.
            RunLoop.main.run(mode: .default, before: Date())
        }
    }

    private func cursor(_ tv: NSTextView) -> Int { tv.selectedRange().location }

    /// "/" opens the system find bar, n and N step through its matches.
    @Test func searchUsesTheFindBar() {
        let (tv, vim, window) = setup("foo bar\nFoo food\nbar foo")
        defer { window.close() }
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        tv.removeFromSuperview()
        scroll.documentView = tv
        window.contentView?.addSubview(scroll)
        tv.usesFindBar = true
        window.makeFirstResponder(tv)
        keys(vim, "/")
        #expect(scroll.isFindBarVisible)
        let pasteboard = NSPasteboard(name: .find)
        pasteboard.clearContents()
        pasteboard.setString("bar", forType: .string)
        window.makeFirstResponder(tv)
        keys(vim, "n"); #expect(tv.selectedRange() == NSRange(location: 4, length: 1))
        keys(vim, "n"); #expect(cursor(tv) == 17)
        keys(vim, "N"); #expect(cursor(tv) == 4)
        #expect(vim.mode == .normal)
    }

    @Test func verticalMotionsStopAtTheEnds() {
        let (tv, vim, window) = setup("abc\nde\n\nfghi\nj")
        defer { window.close() }
        keys(vim, "ll2j"); #expect(cursor(tv) == 7) // empty line
        keys(vim, "j"); #expect(cursor(tv) == 10) // column 2 again
        keys(vim, "9j"); #expect(cursor(tv) == 13) // stops at the last line
        keys(vim, "j"); #expect(cursor(tv) == 13)
        keys(vim, "k"); #expect(cursor(tv) == 10)
        keys(vim, "9k"); #expect(cursor(tv) == 2)
        keys(vim, "k"); #expect(cursor(tv) == 2)
        keys(vim, "3G"); #expect(cursor(tv) == 7)
        keys(vim, "9G"); #expect(cursor(tv) == 13)
        keys(vim, "gg"); #expect(cursor(tv) == 0)
    }

    @Test func motions() {
        let (tv, vim, window) = setup("one two-three  four\n  second line\n\nlast")
        defer { window.close() }
        #expect(tv.selectedRange() == NSRange(location: 0, length: 1)) // block cursor
        keys(vim, "w"); #expect(cursor(tv) == 4)
        keys(vim, "w"); #expect(cursor(tv) == 7) // "-" is a word of its own
        keys(vim, "W"); #expect(cursor(tv) == 15)
        keys(vim, "b"); #expect(cursor(tv) == 8)
        keys(vim, "B"); #expect(cursor(tv) == 4)
        keys(vim, "e"); #expect(cursor(tv) == 6)
        keys(vim, "E"); #expect(cursor(tv) == 12)
        keys(vim, "$"); #expect(cursor(tv) == 18)
        keys(vim, "0"); #expect(cursor(tv) == 0)
        keys(vim, "j^"); #expect(cursor(tv) == 22)
        keys(vim, "l"); #expect(cursor(tv) == 23)
        keys(vim, "h"); #expect(cursor(tv) == 22)
        keys(vim, "G"); #expect(cursor(tv) == 35)
        keys(vim, "gg"); #expect(cursor(tv) == 0)
        keys(vim, "2G"); #expect(cursor(tv) == 22)
        keys(vim, "k"); #expect(cursor(tv) == 2) // column kept
        keys(vim, "fo"); #expect(cursor(tv) == 6)
        keys(vim, ";"); #expect(cursor(tv) == 16)
        keys(vim, ","); #expect(cursor(tv) == 6)
        keys(vim, "Ft"); #expect(cursor(tv) == 4)
        keys(vim, "tr"); #expect(cursor(tv) == 9)
        keys(vim, "Tw"); #expect(cursor(tv) == 6)
        keys(vim, "}"); #expect(cursor(tv) == 34)
        keys(vim, "{"); #expect(cursor(tv) == 0)
        keys(vim, "zq") // unknown keys do nothing
        #expect(tv.string.hasPrefix("one"))
        vim.handle(key: "\u{04}") // ⌃D
        #expect(cursor(tv) == 35)
        vim.handle(key: "\u{15}")
        #expect(cursor(tv) == 0)
        keys(vim, "+"); #expect(cursor(tv) == 22)
        keys(vim, "-"); #expect(cursor(tv) == 0)
    }

    @Test func startingToType() {
        let (tv, vim, window) = setup("  ab\ncd")
        defer { window.close() }
        keys(vim, "A"); #expect(vim.mode == .insert); #expect(cursor(tv) == 4)
        keys(vim, "\u{1B}"); #expect(cursor(tv) == 3)
        keys(vim, "o"); #expect(tv.string == "  ab\n  \ncd"); #expect(cursor(tv) == 7)
        keys(vim, "x\u{1B}O"); #expect(tv.string == "  ab\n  \n  x\ncd"); #expect(cursor(tv) == 7)
        keys(vim, "\u{1B}ggI"); #expect(cursor(tv) == 2)
        keys(vim, "\u{1B}0a"); #expect(cursor(tv) == 1)
        keys(vim, "\u{1B}"); #expect(vim.mode == .normal)
        tv.isEditable = false
        keys(vim, "o"); #expect(tv.string == "  ab\n  \n  x\ncd") // read-only: nothing to type into
    }

    @Test func commandsWithANonLatinLayout() {
        let (tv, vim, window) = setup("один\nдва\nтри")
        defer { window.close() }
        vim.nonLatinLayoutActive = { true }
        #expect(vim.handle(keyEvent("о", keyCode: 38))) // j
        #expect(cursor(tv) == 5)
        #expect(vim.handle(keyEvent("Р", keyCode: 4, flags: .shift))) // H is not a motion here: ignored
        #expect(vim.handle(keyEvent("а", keyCode: 3))) // f…
        #expect(vim.handle(keyEvent("а", keyCode: 3))) // …а: the argument stays Cyrillic
        #expect(cursor(tv) == 7)
        #expect(vim.handle(keyEvent("в", keyCode: 2))) // d is not a command: nothing changes
        #expect(tv.string == "один\nдва\nтри")
        #expect(vim.handle(keyEvent("\u{04}", keyCode: 2, flags: .control, ignoring: "в"))) // ⌃D
        #expect(vim.handle(keyEvent("\u{1B}", keyCode: 33, flags: .control, ignoring: "х"))) // ⌃[ is Esc
        #expect(vim.mode == .normal)
        #expect(vim.handle(keyEvent("ш", keyCode: 34))) // i
        #expect(vim.mode == .insert)
        #expect(!vim.handle(keyEvent("ш", keyCode: 34))) // typing in insert mode is untouched
        vim.nonLatinLayoutActive = { false }
        #expect(vim.handle(keyEvent("\u{1B}", keyCode: 53)))
        #expect(vim.handle(keyEvent("о", keyCode: 38))) // a Latin layout: "о" is not a command
        #expect(vim.mode == .normal)
    }

    @Test func eventsAndModes() {
        let (tv, vim, window) = setup("abc\ndef")
        defer { window.close() }
        var modes: [VimEngine.Mode] = []
        vim.onModeChange = { modes.append($0) }
        #expect(vim.handle(keyEvent("l", keyCode: 37)))
        #expect(cursor(tv) == 1)
        #expect(!vim.handle(keyEvent("c", keyCode: 8, flags: .command))) // menu shortcuts pass through
        #expect(!vim.handle(keyEvent(String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)), keyCode: 123)))
        #expect(vim.handle(keyEvent("i", keyCode: 34)))
        #expect(vim.mode == .insert)
        #expect(!vim.handle(keyEvent("z", keyCode: 6))) // typing goes to the text view
        #expect(vim.handle(keyEvent("\u{1B}", keyCode: 53)))
        #expect(vim.mode == .normal)
        #expect(vim.handle(keyEvent("i", keyCode: 34)))
        #expect(vim.handle(keyEvent("\u{1B}", keyCode: 33, flags: .control, ignoring: "[")))
        #expect(vim.mode == .normal)
        #expect(vim.handle(keyEvent("\u{12}", keyCode: 15, flags: .control, ignoring: "r")))
        #expect(vim.handle(keyEvent("\u{04}", keyCode: 2, flags: .control, ignoring: "d")))
        #expect(vim.handle(keyEvent("\u{15}", keyCode: 32, flags: .control, ignoring: "u")))
        #expect(vim.handle(keyEvent("\u{01}", keyCode: 0, flags: .control, ignoring: "a")))
        #expect(vim.handle(keyEvent("\u{7F}", keyCode: 51)))
        #expect(vim.handle(keyEvent("\r", keyCode: 36)))
        #expect(cursor(tv) == 4)
        #expect(modes.contains(.insert) && modes.contains(.normal))
        #expect(VimEngine.Mode.insert.label == "INSERT")
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        vim.normalizeSelection()
        #expect(tv.selectedRange().length == 1)
        // The text view routes keys through the engine.
        (tv as? MarkdownTextView)?.keyDown(with: keyEvent("x", keyCode: 7))
        #expect(tv.string == "abc\ndef") // not a command, not typed either
        (tv as? MarkdownTextView)?.keyDown(with: keyEvent("h", keyCode: 4))
        #expect(cursor(tv) == 1)
    }
}

@MainActor
@Suite(.serialized) struct StickyFolderTests {
    @Test func pinnedAncestors() {
        let parents = ["b": "a", "c": "b", "d": "c", "e": "a", "x": ""]
        #expect(StickyFolders.ancestors(of: "d", parentOf: parents) == ["a", "b", "c"])
        #expect(StickyFolders.ancestors(of: "x", parentOf: parents).isEmpty)
        #expect(StickyFolders.ancestors(of: "loop", parentOf: ["loop": "loop2", "loop2": "loop"]).count <= 2)
        typealias Row = StickyFolders.Row
        let ids = ["a", "b", "c", "d", "e", "f", "g", "h"]
        let rows = ids.enumerated().map { Row(id: $1, minY: CGFloat($0) * 28, maxY: CGFloat($0 + 1) * 28) }
        let chain = Dictionary(uniqueKeysWithValues: zip(ids.dropFirst(), ids))
        #expect(StickyFolders.sticky(rows: rows, top: 0, rowHeight: 28, parentOf: chain, maxRows: 6).isEmpty)
        // "d" at the top of a single deep chain: every ancestor hidden under the pinned rows is pinned too.
        #expect(StickyFolders.sticky(rows: rows, top: 84, rowHeight: 28, parentOf: chain, maxRows: 6) == ["a", "b", "c", "d", "e"])
        #expect(StickyFolders.sticky(rows: rows, top: 84, rowHeight: 28, parentOf: chain, maxRows: 2) == ["d", "e"])
        #expect(StickyFolders.sticky(rows: rows, top: 1000, rowHeight: 28, parentOf: chain, maxRows: 6).isEmpty)
        // "e" is a sibling of "b": the b-subtree ends with "d", so only "a" stays pinned.
        let siblings = ["b": "a", "c": "b", "d": "c", "e": "a"]
        #expect(StickyFolders.sticky(rows: Array(rows.prefix(5)), top: 84, rowHeight: 28, parentOf: siblings, maxRows: 6) == ["a"])
        // A new root right below the pinned row: the old context is pushed out.
        let roots = ["a1": "a", "a2": "a1", "x": ""]
        let mixed = [Row(id: "a2", minY: 0, maxY: 28), Row(id: "x", minY: 28, maxY: 56), Row(id: "y", minY: 56, maxY: 84)]
        #expect(StickyFolders.sticky(rows: mixed, top: 10, rowHeight: 28, parentOf: roots, maxRows: 6).isEmpty)
    }

    @Test func trackerFollowsScrolling() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 200, height: 28 * 6))
        scroll.documentView = document
        window.contentView?.addSubview(scroll)
        let tracker = StickyFolders()
        tracker.parentOf = ["b": "a", "c": "b", "d": "c", "e": "d", "f": "e"]
        for (i, id) in ["a", "b", "c", "d", "e", "f"].enumerated() {
            let marker = FolderMarkerView(frame: NSRect(x: CGFloat(i) * 10, y: CGFloat(i) * 28, width: 100, height: 28))
            marker.folderId = id
            marker.tracker = tracker
            document.addSubview(marker)
        }
        #expect(tracker.scrollView === scroll)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(tracker.ids.isEmpty)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 84))
        tracker.update()
        #expect(tracker.ids == ["a", "b", "c"])
        #expect(tracker.depth("c") == 2)
        #expect(tracker.indents[2] == 20)
        tracker.reveal("e")
        tracker.reveal("missing")
        tracker.enabled = false
        #expect(tracker.ids.isEmpty)
        tracker.enabled = true
        let marker = try #require(document.subviews.first as? FolderMarkerView)
        #expect(marker.hitTest(.zero) == nil)
        #expect(marker.enclosingRowView == nil)
        marker.removeFromSuperview()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.close()
    }

    @Test func modelExpansionAndPaths() throws {
        let h = try ModelHarness(welcome: false)
        let model = h.model
        let a = try h.store.createFolder(title: "A")
        let b = try h.store.createFolder(title: "B", parentId: a.id)
        try h.store.createFolder(title: "C", parentId: b.id)
        model.reloadSidebar()
        #expect(model.folderPath(b.id) == "A › B")
        model.expandAllFolders()
        #expect(model.expandedFolders == [a.id, b.id])
        model.expansion(of: a.id).wrappedValue = false
        #expect(!model.expansion(of: a.id).wrappedValue)
        model.expansion(of: a.id).wrappedValue = true
        #expect(h.defaults.stringArray(forKey: "expandedFolders")?.count == 2)
        model.collapseAllFolders()
        #expect(model.expandedFolders.isEmpty)
        model.stickyNotebooks = false
        #expect(!model.sticky.enabled)
        model.vimMode = true
        model.vimMode = false
        #expect(model.vimState == .insert)
        // Sidebar and settings render with the tree, the sticky header and the shortcut recorders.
        model.expandAllFolders()
        let host = NSHostingView(rootView: ContentView().environment(model))
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        host.layoutSubtreeIfNeeded()
        let settings = NSHostingView(rootView: ShortcutSettings().environment(model))
        settings.frame = NSRect(x: 0, y: 0, width: 520, height: 400)
        settings.layoutSubtreeIfNeeded()
        model.startRecordingShortcut(.split)
        settings.layoutSubtreeIfNeeded()
        model.stopRecordingShortcut()
        let header = NSHostingView(rootView: StickyFolderHeader().environment(model))
        header.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        header.layoutSubtreeIfNeeded()
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
