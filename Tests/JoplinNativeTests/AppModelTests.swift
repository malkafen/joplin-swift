import AppKit
import Foundation
@testable import JoplinCore
import Testing
@testable import JoplinNative

@MainActor
@Suite struct AppModelTests {
    // MARK: Startup and loading

    @Test func firstLaunchCreatesWelcomeContent() throws {
        let h = try ModelHarness()
        let model = h.model
        #expect(model.folders.map(\.title) == ["Welcome"])
        #expect(model.notes.count == 2)
        #expect(model.tags.map(\.title) == ["start"])
        #expect(model.allNotesCount == 2)
        #expect(model.selectedNoteIDs.count == 1)
        #expect(model.currentNote != nil)
        #expect(h.store.setting("welcome_created") == "1")

        // A second launch on the same data must not add another copy.
        let again = AppModel(store: h.store, defaults: h.defaults, pasteboard: h.pasteboard)
        #expect(again.notes.count == 2)
    }

    @Test func welcomeContentIsSkippedForExistingData() throws {
        let store = try Store(directory: temporaryDirectory())
        try store.createFolder(title: "Mine")
        let model = AppModel(store: store, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        #expect(model.folders.map(\.title) == ["Mine"])
        #expect(model.notes.isEmpty)
        #expect(model.currentNote == nil)
    }

    @Test func preferencesComeFromDefaults() throws {
        let h = try ModelHarness(welcome: false) { d in
            d.set("title", forKey: "sort")
            d.set(false, forKey: "todosOnTop")
            d.set("preview", forKey: "layout")
            d.set(18.0, forKey: "editorFontSize")
            d.set(true, forKey: "editorMonospaced")
            d.set(false, forKey: "showSidebarTags")
        }
        let model = h.model
        #expect(model.sort == .title)
        #expect(!model.uncompletedTodosOnTop)
        #expect(model.layout == .preview)
        #expect(model.editorFontSize == 18)
        #expect(model.editorFont == .monospaced)
        #expect(!model.showSidebarTags)

        model.sort = .created
        model.uncompletedTodosOnTop = true
        model.editorFontSize = 12
        model.editorFont = .serif
        model.previewFont = FontFamily(name: "Helvetica")
        model.previewFontSize = 17
        model.codeFont = FontFamily(name: "Menlo")
        model.readableWidth = false
        model.loadRemoteImages = false
        model.showSidebarTags = true
        model.sidebarTagsExpanded = false
        model.showNoteTags = false
        model.cycleLayout()
        #expect(model.layout == .editor)
        model.cycleLayout()
        #expect(model.layout == .split)
        #expect(h.defaults.string(forKey: "sort") == "created")
        #expect(h.defaults.bool(forKey: "todosOnTop"))
        #expect(h.defaults.string(forKey: "layout") == "split")
        #expect(h.defaults.double(forKey: "editorFontSize") == 12)

        let againHarness = try ModelHarness(welcome: false) { d in
            for key in ["editorFont", "previewFont", "previewFontSize", "codeFont", "readableWidth", "loadRemoteImages",
                        "showSidebarTags", "sidebarTagsExpanded", "showNoteTags", "editorMonospaced"] {
                d.set(h.defaults.object(forKey: key), forKey: key)
            }
        }
        let again = againHarness.model
        #expect(again.editorFont == .serif)
        #expect(again.previewFont.name == "Helvetica")
        #expect(again.previewFontSize == 17)
        #expect(again.codeFont.name == "Menlo")
        #expect(!again.readableWidth)
        #expect(!again.loadRemoteImages)
        #expect(again.showSidebarTags)
        #expect(!again.sidebarTagsExpanded)
        #expect(!again.showNoteTags)
        #expect(!again.renderer.loadsRemoteImages)
        #expect(again.previewTypography == Typography(family: FontFamily(name: "Helvetica"), size: 17, codeFamily: FontFamily(name: "Menlo")))
    }

    @Test func defaultPreferences() throws {
        let model = try ModelHarness(welcome: false).model
        #expect(model.sort == .updated)
        #expect(model.uncompletedTodosOnTop)
        #expect(model.layout == .editor)
        #expect(model.editorFontSize == 14)
        #expect(model.editorFont == .system)
        #expect(model.previewFontSize == 15)
        #expect(model.codeFont == .monospaced)
        #expect(model.readableWidth)
        #expect(model.loadRemoteImages)
        #expect(model.renderer.loadsRemoteImages)
        #expect(model.showSidebarTags)
        #expect(model.showNoteTags)
    }

    @Test func textSizeShortcuts() throws {
        let model = try ModelHarness(welcome: false).model
        model.adjustTextSize(by: 2)
        #expect(model.editorFontSize == 16)
        #expect(model.previewFontSize == 17)
        for _ in 0..<40 { model.adjustTextSize(by: -1) }
        #expect(model.editorFontSize == AppModel.fontSizes.lowerBound)
        model.resetTextSize()
        #expect(model.editorFontSize == 14)
        #expect(model.previewFontSize == 15)
    }

    @Test func folderTree() {
        func folder(_ id: Int, parent: Int?) -> Folder {
            Folder(row: Row(values: ["id": fixtureId(id), "title": "f\(id)", "parent_id": parent.map(fixtureId) ?? ""]))
        }
        let folders = [folder(1, parent: nil), folder(2, parent: 1), folder(3, parent: 2), folder(4, parent: 404), folder(5, parent: 5)]
        let tree = AppModel.buildTree(folders)
        #expect(tree.map(\.id) == [fixtureId(1), fixtureId(4), fixtureId(5)])
        #expect(tree[0].children?.first?.children?.first?.id == fixtureId(3))
        #expect(tree[1].children == nil)
        let flat = AppModel.flatten(tree)
        #expect(flat.map(\.depth) == [0, 1, 2, 0, 0])
        #expect(flat.map(\.folder.id) == [1, 2, 3, 4, 5].map(fixtureId))
    }

    @Test func sidebarSelectionDrivesTheList() throws {
        let h = try ModelHarness(welcome: false)
        let store = h.store
        let work = try store.createFolder(title: "Work")
        let home = try store.createFolder(title: "Home")
        let a = try store.createNote(parentId: work.id, title: "alpha")
        let b = try store.createNote(parentId: home.id, title: "beta")
        try store.setTags(noteId: b.id, titles: ["tagged"])
        let model = h.model

        #expect(model.listTitle == "All Notes")
        #expect(model.currentFilter == .all)
        model.sidebarSelection = .folder(work.id)
        #expect(model.notes.map(\.id) == [a.id])
        #expect(model.listTitle == "Work")
        #expect(model.currentFilter == .folder(work.id))
        #expect(model.selectedNoteIDs == [a.id])

        let tag = try #require(model.tags.first)
        model.sidebarSelection = .tag(tag.id)
        #expect(model.notes.map(\.id) == [b.id])
        #expect(model.listTitle == "#tagged")
        #expect(model.currentFilter == .tag(tag.id))

        model.searchText = "alp"
        #expect(model.listTitle == "Search")
        #expect(model.currentFilter == .search("alp"))
        #expect(model.notes.map(\.id) == [a.id])
        #expect(!model.isTrashSelected)

        model.sidebarSelection = .trash
        #expect(model.searchText.isEmpty)
        #expect(model.isTrashSelected)
        #expect(model.listTitle == "Trash")
        #expect(model.notes.isEmpty)
        #expect(model.currentNote == nil)

        model.sidebarSelection = .folder(fixtureId(404))
        #expect(model.listTitle == "Notebook")
        model.sidebarSelection = .tag(fixtureId(404))
        #expect(model.listTitle == "Tag")
        #expect(model.folderTitle(work.id) == "Work")
        #expect(model.folderTitle("") == "No notebook")
    }

    @Test func multipleSelectionClearsTheEditor() throws {
        let h = try ModelHarness()
        let model = h.model
        model.selectedNoteIDs = Set(model.notes.map(\.id))
        #expect(model.currentNote == nil)
        #expect(model.currentTags.isEmpty)
        model.selectedNoteIDs = [model.notes[1].id]
        #expect(model.currentNote?.id == model.notes[1].id)
    }

    @Test func reloadingReadsTheBodyOnlyWhenItChanged() throws {
        let h = try ModelHarness()
        let model = h.model
        let id = try #require(model.currentNote?.id)
        model.updateBody("mine")
        model.flushSave()
        // Same time and size: the body in memory is taken to be current (a real change moves `updated_time`).
        try h.store.db.run("UPDATE notes SET body = 'MINE', title = 'retitled' WHERE id = ?", [id])
        model.reloadNotes(selectFirst: false)
        #expect(model.currentNote?.body == "mine")
        #expect(model.currentNote?.title == "retitled")
        try h.store.db.run("UPDATE notes SET body = 'theirs', updated_time = updated_time + 1 WHERE id = ?", [id])
        model.reloadNotes(selectFirst: false)
        #expect(model.currentNote?.body == "theirs")
    }

    @Test func externallyDeletedNoteDisappears() throws {
        let h = try ModelHarness()
        let model = h.model
        let id = try #require(model.currentNote?.id)
        try h.store.db.run("UPDATE notes SET title = 'changed' WHERE id = ?", [id])
        model.reloadNotes(selectFirst: false)
        #expect(model.currentNote?.title == "changed")
        try h.store.deleteNotesPermanently(ids: [id])
        model.sidebarSelection = .trash
        model.sidebarSelection = .allNotes
        #expect(!model.notes.contains { $0.id == id })
    }

    // MARK: Editing

    @Test func editsAreDebouncedAndFlushed() async throws {
        let h = try ModelHarness()
        let model = h.model
        let id = try #require(model.currentNote?.id)

        model.updateTitle("New title")
        model.updateBody("# Heading\nbody text")
        model.updateTitle("New title") // unchanged: no-op
        #expect(model.notes.first { $0.id == id }?.title == "New title")
        #expect(model.notes.first { $0.id == id }?.snippet == "Heading body text")
        #expect(h.store.note(id: id)?.title != "New title")

        // The debounced save fires ~600 ms later; allow for a busy main actor on CI.
        for _ in 0..<100 where h.store.note(id: id)?.title != "New title" {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(h.store.note(id: id)?.title == "New title")

        model.updateBody("flushed now")
        model.flushSave()
        #expect(h.store.note(id: id)?.body == "flushed now")
        model.flushSave()
    }

    @Test func editsWithoutANoteAreIgnored() throws {
        let model = try ModelHarness(welcome: false).model
        model.updateTitle("x")
        model.updateBody("x")
        model.toggleCurrentIsTodo()
        model.setCurrentTags(["x"])
        model.toggleCheckbox(line: 1)
        #expect(model.currentNote == nil)
    }

    // MARK: Notes

    @Test func newNoteGoesToTheSelectedContext() throws {
        let h = try ModelHarness(welcome: false)
        let model = h.model

        model.newNote() // empty database: creates the default notebook
        #expect(model.folders.map(\.title) == ["Notes"])
        let first = try #require(model.currentNote)
        #expect(model.titleFocusRequest == 1)

        let other = try h.store.createFolder(title: "Other")
        model.reloadSidebar()
        model.sidebarSelection = .folder(other.id)
        model.newNote(isTodo: true)
        #expect(model.currentNote?.parentId == other.id)
        #expect(model.currentNote?.isTodo == true)

        model.setCurrentTags(["Work"])
        let tag = try #require(model.tags.first { $0.title == "work" })
        model.sidebarSelection = .tag(tag.id)
        model.newNote()
        #expect(model.currentTags == ["work"])
        #expect(model.notes.count == 2)

        model.sidebarSelection = .trash
        model.newNote()
        #expect(model.sidebarSelection == .folder(model.currentNote!.parentId))

        model.sidebarSelection = nil
        model.searchText = "zzz"
        model.newNote()
        #expect(model.searchText.isEmpty)
        #expect(model.sidebarSelection != nil)
        #expect(h.store.note(id: first.id) != nil)
    }

    @Test func todoAndMoveActions() throws {
        let h = try ModelHarness(welcome: false)
        let a = try h.store.createFolder(title: "A")
        let b = try h.store.createFolder(title: "B")
        let note = try h.store.createNote(parentId: a.id, title: "n")
        let model = h.model
        model.selectedNoteIDs = [note.id]

        model.toggleCurrentIsTodo()
        #expect(model.currentNote?.isTodo == true)
        model.setTodoCompleted(note.id, true)
        #expect(model.currentNote?.todoCompleted ?? 0 > 0)
        model.setIsTodo([note.id], false)
        #expect(model.currentNote?.isTodo == false)

        model.moveNotes([note.id], to: b.id)
        #expect(h.store.note(id: note.id)?.parentId == b.id)
        #expect(model.folderCounts[b.id] == 1)

        model.duplicate([note.id])
        #expect(model.currentNote?.title == "n - Copy")
        #expect(model.allNotesCount == 2)
    }

    @Test func trashRestoreAndDelete() throws {
        let h = try ModelHarness()
        let model = h.model
        let id = try #require(model.currentNote?.id)

        model.trashNotes([])
        model.deleteSelectedNotes() // not in trash: moves to trash
        #expect(model.trashCount == 1)
        #expect(!model.notes.contains { $0.id == id })

        model.sidebarSelection = .trash
        #expect(model.selectedNoteIDs == [id])
        model.restoreNotes([id])
        #expect(model.trashCount == 0)

        model.trashNotes([id])
        model.selectedNoteIDs = [id]
        model.deleteSelectedNotes() // in trash: asks first
        let confirmation = try #require(model.confirmation)
        #expect(confirmation.title == "Delete this note permanently?")
        #expect(h.store.note(id: id) != nil)
        confirmation.action()
        #expect(h.store.note(id: id) == nil)

        model.deleteNotesPermanently([])
        model.deleteNotesPermanently([fixtureId(1), fixtureId(2)])
        #expect(model.confirmation?.title == "Delete 2 notes permanently?")

        model.sidebarSelection = .allNotes
        model.trashNotes(Set(model.notes.map(\.id)))
        model.emptyTrash()
        #expect(model.confirmation?.destructiveLabel == "Empty Trash")
        model.confirmation?.action()
        #expect(model.trashCount == 0)
        #expect(model.allNotesCount == 0)
    }

    @Test func copyMarkdownLinks() throws {
        let h = try ModelHarness(welcome: false)
        let untitled = try h.store.createNote(parentId: "", title: "")
        let titled = try h.store.createNote(parentId: "", title: "Named")
        let model = h.model
        model.copyMarkdownLinks([untitled.id, titled.id])
        let text = try #require(h.pasteboard.string(forType: .string))
        #expect(Set(text.components(separatedBy: "\n")) == ["[Untitled](:/\(untitled.id))", "[Named](:/\(titled.id))"])
    }

    @Test func dragAndDropOntoFolders() throws {
        let h = try ModelHarness(welcome: false)
        let target = try h.store.createFolder(title: "Target")
        let source = try h.store.createFolder(title: "Source")
        let n1 = try h.store.createNote(parentId: source.id, title: "1")
        let n2 = try h.store.createNote(parentId: source.id, title: "2")
        let n3 = try h.store.createNote(parentId: source.id, title: "3")
        let model = h.model
        model.sidebarSelection = .folder(source.id)
        model.selectedNoteIDs = [n1.id, n2.id]

        // Dragging one row of a multi-selection moves the whole selection.
        #expect(model.dropOnFolder([n1.id], folderId: target.id))
        #expect(h.store.note(id: n2.id)?.parentId == target.id)
        #expect(h.store.note(id: n3.id)?.parentId == source.id)

        #expect(model.dropOnFolder([n3.id], folderId: target.id))
        #expect(h.store.note(id: n3.id)?.parentId == target.id)

        #expect(model.dropOnFolder(["folder:\(source.id)"], folderId: target.id))
        #expect(h.store.folder(id: source.id)?.parentId == target.id)
        #expect(model.folderTree.first?.children?.map(\.id) == [source.id])
    }

    // MARK: Folders

    @Test func folderPrompts() throws {
        let h = try ModelHarness(welcome: false)
        let model = h.model

        model.promptNewFolder()
        var prompt = try #require(model.textPrompt)
        #expect(prompt.title == "New Notebook")
        #expect(model.promptText == "")
        prompt.action("   ")
        #expect(model.folders.isEmpty)
        prompt.action(" Projects ")
        let projects = try #require(model.folders.first)
        #expect(projects.title == "Projects")
        #expect(model.sidebarSelection == .folder(projects.id))

        model.promptNewFolder(parent: projects.id)
        prompt = try #require(model.textPrompt)
        #expect(prompt.title == "New Sub-notebook")
        prompt.action("Child")
        #expect(model.folderTree.first?.children?.first?.folder.title == "Child")

        model.promptRenameFolder(projects)
        prompt = try #require(model.textPrompt)
        #expect(model.promptText == "Projects")
        prompt.action("")
        prompt.action("Renamed")
        #expect(model.folderTitle(projects.id) == "Renamed")
    }

    @Test func folderTrashLifecycle() throws {
        let h = try ModelHarness(welcome: false)
        let folder = try h.store.createFolder(title: "Doomed")
        try h.store.createNote(parentId: folder.id, title: "inside")
        let model = h.model
        model.sidebarSelection = .folder(folder.id)

        model.trashFolder(folder)
        #expect(model.sidebarSelection == .allNotes)
        #expect(model.trashedFolders.map(\.id) == [folder.id])
        #expect(model.trashCount == 1)

        model.restoreFolder(folder)
        #expect(model.folders.map(\.id) == [folder.id])
        #expect(model.allNotesCount == 1)

        model.trashFolder(folder)
        model.deleteFolderPermanently(folder)
        #expect(model.confirmation?.title == "Delete “Doomed” permanently?")
        model.confirmation?.action()
        #expect(model.trashedFolders.isEmpty)
        #expect(h.store.folder(id: folder.id) == nil)
    }

    // MARK: Tags

    @Test func tagEditing() throws {
        let h = try ModelHarness()
        let model = h.model
        model.selectedNoteIDs = [try #require(model.notes.first { $0.title == "Try checklists" }).id]
        #expect(model.currentTags == ["start"])

        model.setCurrentTags(["START"]) // same set: nothing to do
        model.setCurrentTags(["start", " Next ", ""])
        #expect(model.currentTags == ["next", "start"])
        #expect(model.tags.map(\.title) == ["next", "start"])

        let next = try #require(model.tags.first)
        model.promptRenameTag(next)
        let prompt = try #require(model.textPrompt)
        #expect(model.promptText == "next")
        prompt.action(" ")
        prompt.action("Later")
        #expect(model.currentTags == ["later", "start"])

        let later = try #require(model.tags.first { $0.title == "later" })
        model.sidebarSelection = .tag(later.id)
        model.deleteTag(later)
        #expect(model.sidebarSelection == .allNotes)
        #expect(model.tags.map(\.title) == ["start"])
        model.deleteTag(try #require(model.tags.first))
        #expect(model.tags.isEmpty)
    }

    // MARK: Attachments and links

    @Test func attachments() throws {
        let h = try ModelHarness(welcome: false)
        let model = h.model
        let dir = temporaryDirectory()
        let png = dir.appendingPathComponent("photo.png")
        try tinyPNG.write(to: png)
        let pdf = dir.appendingPathComponent("doc.pdf")
        try Data("%PDF".utf8).write(to: pdf)

        let md = try #require(model.attachmentMarkdown(for: [png, pdf]))
        let lines = md.components(separatedBy: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("![photo.png](:/"))
        #expect(lines[1].hasPrefix("[doc.pdf](:/"))

        #expect(model.attachmentMarkdown(for: []) == nil)
        #expect(model.attachmentMarkdown(for: [dir.appendingPathComponent("missing.txt")]) == nil)
        #expect(model.alert?.title == "Error")

        let pasted = try #require(model.pastedImageMarkdown(tinyPNG))
        #expect(pasted.hasPrefix("![Pasted image.png](:/"))
    }

    @Test func links() throws {
        let h = try ModelHarness(welcome: false)
        let work = try h.store.createFolder(title: "Work")
        let other = try h.store.createFolder(title: "Other")
        let target = try h.store.createNote(parentId: other.id, title: "target")
        let trashed = try h.store.createNote(parentId: other.id, title: "trashed")
        try h.store.trashNotes(ids: [trashed.id])
        let res = try h.store.addResource(data: Data("x".utf8), filename: "x.txt", mime: "text/plain", fileExtension: "txt")
        let model = h.model
        model.sidebarSelection = .folder(work.id)

        model.handleLink(URL(string: "joplinitem://\(target.id)")!)
        #expect(model.sidebarSelection == .folder(other.id))
        #expect(model.currentNote?.id == target.id)

        model.openItem(id: target.id) // already visible: just selects it
        #expect(model.sidebarSelection == .folder(other.id))

        model.openItem(id: trashed.id)
        #expect(model.sidebarSelection == .trash)
        #expect(model.currentNote?.id == trashed.id)

        model.openItem(id: res.id)
        #expect(h.opened == [h.store.url(for: res)])

        model.openItem(id: fixtureId(404))
        #expect(model.alert?.title == "Item not found")

        model.handleLink(URL(string: "https://joplinapp.org")!)
        #expect(h.opened.last == URL(string: "https://joplinapp.org"))
        model.handleLink(URL(string: "joplincheckbox://notanumber")!)
    }

    @Test func checkboxesToggleInTheSource() throws {
        let h = try ModelHarness(welcome: false)
        let note = try h.store.createNote(parentId: "", title: "c", body: "- [ ] one\n- [x] two\n* [X] three\nplain")
        let model = h.model
        model.selectedNoteIDs = [note.id]

        model.handleLink(URL(string: "joplincheckbox://1")!)
        model.toggleCheckbox(line: 2)
        model.toggleCheckbox(line: 3)
        model.toggleCheckbox(line: 4)
        model.toggleCheckbox(line: 0)
        model.toggleCheckbox(line: 99)
        #expect(model.currentNote?.body == "- [x] one\n- [ ] two\n* [ ] three\nplain")

        model.trashNotes([note.id])
        model.sidebarSelection = .trash
        model.selectedNoteIDs = [note.id]
        model.toggleCheckbox(line: 1)
        #expect(model.currentNote?.body.hasPrefix("- [x] one") == true)
    }

    @Test func rendererResolvesResources() throws {
        let h = try ModelHarness(welcome: false)
        let res = try h.store.addResource(data: Data("x".utf8), filename: "file.txt", mime: "text/plain", fileExtension: "txt")
        let model = h.model
        model.previewFontSize = 20
        let renderer = model.renderer
        #expect(renderer.baseSize == 20)
        #expect(renderer.render("[](:/\(res.id))").string == "\u{FFFC}\u{2009}file.txt")
        #expect(renderer.resolveResource(fixtureId(404)) == nil)
    }

    // MARK: Import

    @Test func importReportsAreShown() throws {
        let source = try Store(directory: temporaryDirectory())
        let folder = try source.createFolder(title: "Exported")
        try source.createNote(parentId: folder.id, title: "n")
        let jex = temporaryDirectory().appendingPathComponent("export.jex")
        _ = try source.exportJEX(to: jex)

        let h = try ModelHarness(welcome: false)
        let model = h.model
        model.importJEX(jex)
        #expect(model.alert?.title == "export.jex imported")
        #expect(model.alert?.message == "Notebooks: 1, notes: 1, tags: 0, attachments: 0")
        #expect(model.folders.map(\.title) == ["Exported"])

        let broken = temporaryDirectory().appendingPathComponent("broken.jex")
        try Data("nope".utf8).write(to: broken)
        model.importJEX(broken)
        #expect(model.alert?.title == "Import failed")

        model.importJoplinDesktop(profile: temporaryDirectory())
        #expect(model.alert?.title == "Import failed")
    }

    @Test func importErrorsAreSummarised() throws {
        let profile = temporaryDirectory()
        let source = try Store(directory: profile)
        try source.createNote(parentId: "", title: "desktop note")
        let h = try ModelHarness(welcome: false)
        h.model.importJoplinDesktop(profile: profile)
        #expect(h.model.alert?.title == "Joplin Desktop profile imported")
        #expect(h.model.allNotesCount == 1)

        let dir = temporaryDirectory()
        try "broken".write(to: dir.appendingPathComponent("\(fixtureId(1)).md"), atomically: true, encoding: .utf8)
        let jex = temporaryDirectory().appendingPathComponent("broken-items.jex")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-cf", jex.path, "-C", dir.path, "\(fixtureId(1)).md"]
        try tar.run()
        tar.waitUntilExit()
        h.model.importJEX(jex)
        #expect(h.model.alert?.message.contains("errors: 1\n\nFirst error: \(fixtureId(1)).md") == true)
    }

    @Test func layoutMetadata() {
        #expect(EditorLayout.allCases.map(\.label) == ["Editor", "Split", "Preview"])
        #expect(EditorLayout.allCases.map(\.symbol) == ["pencil.line", "rectangle.split.2x1", "eye"])
        #expect(EditorLayout.split.id == "split")
    }
}
