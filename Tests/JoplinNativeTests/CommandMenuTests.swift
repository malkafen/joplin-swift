import AppKit
import Foundation
@testable import JoplinCore
import SwiftUI
import Testing
@testable import JoplinNative

@available(macOS 14.4, *)
@MainActor
struct MenuHarness {
    let menu: NSMenu

    init<V: View>(_ view: V) {
        _ = NSApplication.shared
        menu = NSHostingMenu(rootView: view)
        refresh()
    }

    func refresh() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
    }

    func item(_ title: String, in menu: NSMenu? = nil) -> NSMenuItem? {
        if menu == nil { refresh() }
        let menu = menu ?? self.menu
        for item in menu.items {
            if item.title == title { return item }
            if let sub = item.submenu {
                sub.delegate?.menuNeedsUpdate?(sub)
                if let found = self.item(title, in: sub) { return found }
            }
        }
        return nil
    }

    var titles: [String] { menu.items.map(\.title).filter { !$0.isEmpty } }

    func isEnabled(_ title: String) -> Bool {
        refresh()
        guard let item = item(title) else { return false }
        if let target = item.target as? NSObject, let action = item.action,
           let validator = target as? NSMenuItemValidation, target.responds(to: action) {
            return validator.validateMenuItem(item) && item.isEnabled
        }
        return item.isEnabled
    }

    @discardableResult
    func click(_ title: String) -> Bool {
        refresh()
        guard let item = item(title), let owner = item.menu else { return false }
        owner.performActionForItem(at: owner.index(of: item))
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        return true
    }
}

@MainActor
@Suite(.serialized) struct CommandMenuTests {
    @available(macOS 14.4, *)
    @Test func noteMenuFollowsTheOpenNote() throws {
        let h = try ModelHarness()
        let model = h.model
        let menu = MenuHarness(NoteCommands(model: model))
        let todo = try #require(model.notes.first { $0.isTodo })
        model.selectedNoteIDs = [todo.id]
        #expect(menu.isEnabled("Mark as Done"))
        #expect(menu.isEnabled("Switch to Note"))

        #expect(menu.click("Mark as Done"))
        #expect(model.noteInfo?.isDone == true)
        #expect(menu.item("Mark as Not Done") != nil)
        menu.click("Mark as Not Done")
        #expect(model.noteInfo?.isDone == false)

        menu.click("Switch to Note")
        #expect(model.noteInfo?.isTodo == false)
        #expect(!menu.isEnabled("Mark as Done"))
        menu.click("Switch to To-do")
        #expect(model.noteInfo?.isTodo == true)

        let requests = model.titleFocusRequest
        menu.click("Edit Title")
        #expect(model.titleFocusRequest == requests + 1)
        model.showNoteTags = false
        menu.click("Edit Tags")
        #expect(model.showNoteTags)

        model.selectedNoteIDs = [model.notes[0].id]
        menu.click("Next Note")
        #expect(model.selectedNoteIDs == [model.notes[1].id])
        menu.click("Previous Note")
        #expect(model.selectedNoteIDs == [model.notes[0].id])

        menu.click("Copy Markdown Link")
        #expect(h.pasteboard.string(forType: .string)?.hasPrefix("[") == true)

        let count = model.notes.count
        menu.click("Duplicate")
        #expect(model.notes.count == count + 1)

        menu.click("Move to Trash")
        #expect(model.notes.count == count)
        menu.click("Empty Trash…")
        #expect(model.confirmation?.title == "Empty Trash?")
        model.confirmation = nil

        model.sidebarSelection = .trash
        model.selectedNoteIDs = [try #require(model.notes.first).id]
        #expect(menu.item("Delete Permanently…") != nil)
        #expect(!menu.isEnabled("Duplicate"))
        menu.click("Delete Permanently…")
        #expect(model.confirmation?.destructiveLabel == "Delete")
        model.confirmation = nil

        model.selectedNoteIDs = []
        for title in ["Edit Title", "Edit Tags", "Attach File…", "Mark as Done", "Switch to To-do", "Duplicate",
                      "Copy Markdown Link", "Delete Permanently…"] {
            #expect(!menu.isEnabled(title), "\(title)")
        }
        #expect(menu.isEnabled("Empty Trash…"))
    }

    @available(macOS 14.4, *)
    @Test func fileAndViewMenus() throws {
        let h = try ModelHarness()
        let model = h.model
        let items = MenuHarness(NewItemCommands(model: model))
        let count = model.allNotesCount
        items.click("New Note")
        items.click("New To-do")
        #expect(model.allNotesCount == count + 2)
        #expect(model.noteInfo?.isTodo == true)
        items.click("New Notebook…")
        #expect(model.textPrompt?.title == "New Notebook")
        model.textPrompt = nil

        let view = MenuHarness(ViewCommands(model: model))
        #expect(view.item(ShortcutAction.editorOnly.title)?.keyEquivalent == "1")
        #expect(view.item(ShortcutAction.cycleLayout.title)?.keyEquivalentModifierMask == .control)
        view.click(ShortcutAction.split.title)
        #expect(model.layout == .split)
        view.click(ShortcutAction.previewOnly.title)
        #expect(model.layout == .preview)
        view.click(ShortcutAction.editorOnly.title)
        #expect(model.layout == .editor)
        view.click(ShortcutAction.cycleLayout.title)
        #expect(model.layout == .split)
        model.setHotkey(nil, for: .split)
        view.refresh()
        #expect(view.item(ShortcutAction.split.title)?.keyEquivalent == "")

        try h.store.createFolder(title: "Child", parentId: try #require(model.folders.first).id)
        model.reloadSidebar()
        view.click("Expand All Notebooks")
        #expect(!model.expandedFolders.isEmpty)
        view.click("Collapse All Notebooks")
        #expect(model.expandedFolders.isEmpty)

        let vim = model.vimMode
        view.click("Vim Mode")
        #expect(model.vimMode == !vim)
        view.click("Show Tags in Sidebar")
        #expect(!model.showSidebarTags)
        view.click("Show Tags Above Notes")
        #expect(!model.showNoteTags)
        view.click("Show Note Previews")
        #expect(model.showNotePreviews)

        let zoom = MenuHarness(ZoomCommands(model: model))
        zoom.click("Zoom In")
        #expect(model.editorFontSize == 15)
        zoom.click("Zoom Out")
        zoom.click("Zoom Out")
        #expect(model.editorFontSize == 13)
        zoom.click("Actual Size")
        #expect(model.editorFontSize == 14)
    }

    @available(macOS 14.4, *)
    @Test func findSyncAndExportMenus() throws {
        let h = try ModelHarness()
        let model = h.model
        let find = MenuHarness(FindCommands(model: model))
        #expect(find.isEnabled("Find in Note"))
        find.click("Search All Notes")
        model.selectedNoteIDs = []
        #expect(!find.isEnabled("Find in Note"))

        let sync = MenuHarness(SyncCommand(model: model))
        #expect(!sync.isEnabled("Synchronise"))
        model.syncInterval = 0
        model.syncURL = "http://joplin.test"
        model.syncEmail = "a@b.c"
        model.syncPassword = "x"
        #expect(sync.isEnabled("Synchronise"))

        let files = MenuHarness(ImportExportCommands(model: model))
        #expect(files.item("All Notes as JEX…") != nil)
        #expect(files.item("JEX – Joplin Export File…") != nil)
        let folder = try #require(model.folders.first)
        model.sidebarSelection = .folder(folder.id)
        files.refresh()
        #expect(files.item("Notebook “\(folder.title)” as JEX…") != nil)
        model.sidebarSelection = .allNotes
        files.refresh()
        #expect(files.item("Notebook “\(folder.title)” as JEX…") == nil)
    }

    @available(macOS 14.4, *)
    @Test func formatMenuEditsTheEditor() throws {
        let bridge = EditorBridge()
        let tv = NSTextView()
        tv.string = "word"
        tv.setSelectedRange(NSRange(location: 0, length: 4))
        bridge.textView = tv
        let menu = MenuHarness(FormatCommands(editor: bridge))
        menu.click("Bold")
        #expect(tv.string == "**word**")
        tv.setSelectedRange(NSRange(location: 0, length: 8))
        menu.click("Bold")
        #expect(tv.string == "word")
        for title in ["Italic", "Strikethrough", "Highlight", "Inline Code", "Link", "Code Block", "Math Formula"] {
            tv.string = "x"
            tv.setSelectedRange(NSRange(location: 0, length: 1))
            menu.click(title)
            #expect(tv.string.count > 1, "\(title)")
        }
        for (title, prefix) in [("Heading 1", "# "), ("Heading 2", "## "), ("Heading 3", "### "), ("Bulleted List", "- "),
                                ("Numbered List", "1. "), ("Checklist", "- [ ] "), ("Quote", "> ")] {
            tv.string = "line"
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            menu.click(title)
            #expect(tv.string == prefix + "line", "\(title)")
        }
        for title in ["Table", "Horizontal Rule", "Insert Date and Time"] {
            tv.string = ""
            menu.click(title)
            #expect(!tv.string.isEmpty, "\(title)")
        }
    }

    @available(macOS 14.4, *)
    @Test func noteContextMenu() throws {
        let h = try ModelHarness()
        let model = h.model
        let target = try h.store.createFolder(title: "Target")
        model.reloadSidebar()
        let empty = MenuHarness(NoteMenu(ids: []).environment(model))
        #expect(empty.titles == ["New Note", "New To-do"])
        let count = model.allNotesCount
        empty.click("New Note")
        empty.click("New To-do")
        #expect(model.allNotesCount == count + 2)

        let note = try #require(model.notes.first { !$0.isTodo && !$0.title.isEmpty })
        let menu = MenuHarness(NoteMenu(ids: [note.id]).environment(model))
        menu.click("Copy Markdown Link")
        #expect(h.pasteboard.string(forType: .string)?.contains(note.id) == true)
        menu.click("Switch to To-do")
        #expect(model.notes.first { $0.id == note.id }?.isTodo == true)
        menu.click("Switch to Note")
        #expect(model.notes.first { $0.id == note.id }?.isTodo == false)
        menu.click("Duplicate")
        #expect(model.allNotesCount == count + 3)
        #expect(menu.click("Target"))
        #expect(h.store.note(id: note.id)?.parentId == target.id)
        menu.click("Move to Trash")
        #expect(h.store.note(id: note.id)?.deletedTime ?? 0 > 0)

        model.sidebarSelection = .trash
        let trash = MenuHarness(NoteMenu(ids: [note.id]).environment(model))
        #expect(trash.titles == ["Restore", "Delete Permanently…"])
        trash.click("Delete Permanently…")
        #expect(model.confirmation != nil)
        model.confirmation = nil
        trash.click("Restore")
        #expect(h.store.note(id: note.id)?.deletedTime == 0)
    }

    @available(macOS 14.4, *)
    @Test func folderContextMenu() throws {
        let h = try ModelHarness(welcome: false)
        let model = h.model
        let parent = try h.store.createFolder(title: "Parent")
        let child = try h.store.createFolder(title: "Child", parentId: parent.id)
        model.reloadSidebar()

        let top = MenuHarness(FolderMenu(folder: parent).environment(model))
        #expect(top.item("Move to Top Level") == nil)
        top.click("New Note")
        #expect(model.sidebarSelection == .folder(parent.id))
        #expect(model.currentNote?.parentId == parent.id)
        top.click("New Sub-notebook…")
        #expect(model.textPrompt?.title == "New Sub-notebook")
        top.click("Rename…")
        #expect(model.textPrompt?.initial == "Parent")
        model.textPrompt = nil

        let sub = MenuHarness(FolderMenu(folder: child).environment(model))
        sub.click("Move to Top Level")
        #expect(h.store.folders().first { $0.id == child.id }?.parentId == "")
        sub.click("Move to Trash")
        #expect(model.trashedFolders.map(\.id) == [child.id])
    }

    @Test func appSceneAndCommandsBuild() throws {
        let h = try ModelHarness()
        _ = JoplinNativeApp(model: h.model).body
        _ = AppCommands(model: h.model).body
    }
}
