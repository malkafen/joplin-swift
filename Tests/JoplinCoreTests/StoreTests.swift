import Foundation
import Testing
@testable import JoplinCore

@Suite struct StoreTests {
    @Test func idsAndClock() {
        let id = Store.newId()
        #expect(id.count == 32)
        #expect(id.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(Store.newId() != id)
        #expect(abs(Store.now() - Int64(Date().timeIntervalSince1970 * 1000)) < 5_000)
    }

    @Test func initFailsWhenDirectoryIsAFile() throws {
        let file = temporaryDirectory().appendingPathComponent("file")
        try Data().write(to: file)
        #expect(throws: (any Error).self) { try Store(directory: file) }
    }

    @Test func crudAndSearch() throws {
        let store = try makeStore()
        let folder = try store.createFolder(title: "Work")
        var note = try store.createNote(parentId: folder.id, title: "Привет мир", body: "Встреча с командой в понедельник")
        #expect(note.markupLanguage == 1)
        #expect(store.notes(filter: .folder(folder.id), sort: .updated).count == 1)
        #expect(store.notes(filter: .search("встреч"), sort: .updated).map(\.id) == [note.id])
        #expect(store.notes(filter: .search("nothing"), sort: .updated).isEmpty)

        note.body = "Updated body"
        try store.saveNote(note)
        #expect(store.notes(filter: .search("updated"), sort: .updated).map(\.id) == [note.id])
        #expect(store.notes(filter: .search("встреч"), sort: .updated).isEmpty)
        #expect(store.notes(filter: .search("   "), sort: .updated).count == 1)
        #expect(store.notes(filter: .search("say \"hi"), sort: .updated).isEmpty)
    }

    @Test func ftsQueryQuotesEveryToken() {
        #expect(Store.ftsQuery("a  b") == "\"a\"* \"b\"*")
        #expect(Store.ftsQuery("x\"y") == "\"x\"\"y\"*")
        #expect(Store.ftsQuery(" ") == "")
    }

    @Test func saveNoteFlattensTitleAndBumpsTimes() throws {
        let store = try makeStore()
        var note = try store.createNote(parentId: "", title: "a")
        try store.db.run("UPDATE notes SET user_updated_time = 1 WHERE id = ?", [note.id])
        note.title = "line1\nline2"
        note.sourceUrl = "https://x.y"
        try store.saveNote(note)
        let saved = try #require(store.note(id: note.id))
        #expect(saved.title == "line1 line2")
        #expect(saved.sourceUrl == "https://x.y")
        #expect(saved.userUpdatedTime > 1)
        #expect(store.note(id: fixtureId(99)) == nil)
    }

    @Test func genericAccess() throws {
        let store = try makeStore()
        try store.upsert(.setting, ["id": "x"])
        #expect(!store.exists(.setting, id: "x"))
        #expect(store.row(.setting, id: "x") == nil)
        #expect(try store.rows(.setting).isEmpty)

        let id = fixtureId(1)
        try store.upsert(.note, ["id": id, "title": "first", "author": "me"])
        #expect(store.row(.note, id: id)?.int("markup_language") == 1)
        try store.upsert(.note, ["id": id, "title": "second"])
        let row = try #require(store.row(.note, id: id))
        #expect(row.string("title") == "second")
        #expect(row.string("author") == "me")

        // Only an id: nothing to update, an existing row must stay as is.
        try store.upsert(.noteTag, ["id": fixtureId(2), "note_id": id])
        try store.upsert(.noteTag, ["id": fixtureId(2)])
        #expect(try store.rows(.noteTag, where: "note_id = ?", [id]).count == 1)
    }

    @Test func settings() throws {
        let store = try makeStore()
        #expect(store.setting("k") == nil)
        store.setSetting("k", "1")
        store.setSetting("k", "2")
        #expect(store.setting("k") == "2")
    }

    // MARK: Folders

    @Test func folderTree() throws {
        let store = try makeStore()
        let a = try store.createFolder(title: "b-parent")
        let b = try store.createFolder(title: "A-child", parentId: a.id)
        let c = try store.createFolder(title: "grandchild", parentId: b.id)
        #expect(store.folders().map(\.title) == ["A-child", "b-parent", "grandchild"])
        #expect(Set(store.descendantFolderIds(of: a.id)) == [b.id, c.id])

        try store.renameFolder(id: c.id, title: "renamed")
        #expect(store.folder(id: c.id)?.title == "renamed")

        try store.moveFolder(id: a.id, toParent: c.id) // would create a cycle
        try store.moveFolder(id: a.id, toParent: a.id)
        #expect(store.folder(id: a.id)?.parentId == "")
        try store.moveFolder(id: c.id, toParent: "")
        #expect(store.folder(id: c.id)?.parentId == "")
    }

    @Test func noteCounts() throws {
        let store = try makeStore()
        let f = try store.createFolder(title: "F")
        try store.createNote(parentId: f.id)
        let trashed = try store.createNote(parentId: f.id)
        try store.trashNotes(ids: [trashed.id])
        #expect(store.noteCountsByFolder() == [f.id: 1])
        #expect(store.totalNoteCount == 1)
    }

    @Test func trashAndRestoreFolders() throws {
        let store = try makeStore()
        let root = try store.createFolder(title: "root")
        let child = try store.createFolder(title: "child", parentId: root.id)
        let note = try store.createNote(parentId: child.id, title: "n")

        try store.trashFolder(id: root.id)
        #expect(store.folders().isEmpty)
        #expect(Set(store.folders(deleted: true).map(\.id)) == [root.id, child.id])
        #expect(store.notes(filter: .trash, sort: .updated).map(\.id) == [note.id])

        // Restoring the child brings its trashed parent back too.
        try store.restoreFolder(id: child.id)
        #expect(Set(store.folders().map(\.id)) == [root.id, child.id])
        #expect(store.note(id: note.id)?.deletedTime == 0)
    }

    @Test func restoreSurvivesParentCycles() throws {
        let store = try makeStore()
        let a = fixtureId(1), b = fixtureId(2)
        try store.upsert(.folder, ["id": a, "title": "a", "parent_id": b, "deleted_time": 5])
        try store.upsert(.folder, ["id": b, "title": "b", "parent_id": a, "deleted_time": 5])
        let note = try store.createNote(parentId: a)
        try store.trashNotes(ids: [note.id])
        try store.restoreNotes(ids: [note.id])
        #expect(store.folders().count == 2)
        #expect(store.note(id: note.id)?.deletedTime == 0)
    }

    @Test func deleteFolderPermanently() throws {
        let store = try makeStore()
        let root = try store.createFolder(title: "root")
        let child = try store.createFolder(title: "child", parentId: root.id)
        let note = try store.createNote(parentId: child.id)
        try store.setTags(noteId: note.id, titles: ["t"])
        let link = try #require(try store.rows(.noteTag).first).string("id")

        try store.deleteFolderPermanently(id: root.id)
        #expect(store.folder(id: root.id) == nil)
        #expect(store.note(id: note.id) == nil)
        let deleted = try store.deletedItems()
        #expect(deleted.contains { $0 == (6, link) })
        #expect(deleted.contains { $0 == (1, note.id) })
        #expect(deleted.contains { $0 == (2, root.id) })
        #expect(deleted.contains { $0 == (2, child.id) })
    }

    @Test func defaultFolderIsCreatedOnDemand() throws {
        let store = try makeStore()
        let id = try store.defaultFolderId()
        #expect(store.folder(id: id)?.title == "Notes")
        #expect(try store.defaultFolderId() == id)
    }

    // MARK: Notes

    @Test func filtersAndSorting() throws {
        let store = try makeStore()
        let f = try store.createFolder(title: "F")
        let a = try store.createNote(parentId: f.id, title: "b note")
        let todo = try store.createNote(parentId: f.id, title: "c todo", isTodo: true)
        let done = try store.createNote(parentId: f.id, title: "a done", isTodo: true)
        try store.setTodoCompleted(id: done.id, completed: true)
        try store.db.run("UPDATE notes SET user_updated_time = 3, user_created_time = 1 WHERE id = ?", [a.id])
        try store.db.run("UPDATE notes SET user_updated_time = 2, user_created_time = 3 WHERE id = ?", [todo.id])
        try store.db.run("UPDATE notes SET user_updated_time = 1, user_created_time = 2 WHERE id = ?", [done.id])
        try store.upsert(.note, ["id": fixtureId(1), "parent_id": f.id, "title": "conflict", "is_conflict": 1])
        try store.upsert(.note, ["id": fixtureId(2), "parent_id": f.id, "title": "encrypted", "encryption_applied": 1])

        #expect(store.notes(filter: .all, sort: .updated).map(\.id) == [todo.id, a.id, done.id])
        #expect(store.notes(filter: .all, sort: .updated, uncompletedTodosOnTop: false).map(\.id) == [a.id, todo.id, done.id])
        #expect(store.notes(filter: .all, sort: .created, uncompletedTodosOnTop: false).map(\.id) == [todo.id, done.id, a.id])
        #expect(store.notes(filter: .all, sort: .title, uncompletedTodosOnTop: false).map(\.id) == [done.id, a.id, todo.id])
        #expect(store.notes(filter: .folder(f.id), sort: .title, showCompletedTodos: false).map(\.id) == [todo.id, a.id])
    }

    @Test func moveDuplicateAndTodoFlags() throws {
        let store = try makeStore()
        let f1 = try store.createFolder(title: "1")
        let f2 = try store.createFolder(title: "2")
        let note = try store.createNote(parentId: f1.id, title: "n", body: "b")
        try store.setTags(noteId: note.id, titles: ["x"])

        try store.moveNotes(ids: [], toFolder: f2.id)
        try store.moveNotes(ids: [note.id], toFolder: f2.id)
        #expect(store.note(id: note.id)?.parentId == f2.id)

        try store.setIsTodo(ids: [], isTodo: true)
        try store.setIsTodo(ids: [note.id], isTodo: true)
        try store.setTodoCompleted(id: note.id, completed: true)
        #expect(store.note(id: note.id)?.todoCompleted ?? 0 > 0)
        try store.setTodoCompleted(id: note.id, completed: false)
        #expect(store.note(id: note.id)?.todoCompleted == 0)

        let copy = try #require(try store.duplicateNote(id: note.id))
        #expect(copy.id != note.id)
        #expect(copy.title == "n - Copy")
        #expect(copy.body == "b")
        #expect(copy.isTodo)
        #expect(store.tags(forNote: copy.id).map(\.title) == ["x"])
        #expect(try store.duplicateNote(id: fixtureId(404)) == nil)
    }

    @Test func restoreNotesIntoMissingOrDeletedFolders() throws {
        let store = try makeStore()
        let kept = try store.createFolder(title: "kept")
        let orphan = try store.createNote(parentId: fixtureId(404), title: "orphan")
        let loose = try store.createNote(parentId: "", title: "loose")
        let trashedFolder = try store.createFolder(title: "trashed")
        let inTrashed = try store.createNote(parentId: trashedFolder.id)
        try store.trashFolder(id: trashedFolder.id)
        try store.trashNotes(ids: [orphan.id, loose.id])
        try store.trashNotes(ids: [])

        try store.restoreNotes(ids: [orphan.id, loose.id, inTrashed.id, fixtureId(405)])
        #expect(store.note(id: orphan.id)?.parentId == kept.id)
        #expect(store.note(id: loose.id)?.parentId == "")
        #expect(store.folder(id: trashedFolder.id)?.deletedTime == 0)
        #expect(store.notes(filter: .trash, sort: .updated).isEmpty)
    }

    @Test func permanentDeletionAndEmptyTrash() throws {
        let store = try makeStore()
        let parent = try store.createFolder(title: "parent")
        let child = try store.createFolder(title: "child", parentId: parent.id)
        let empty = try store.createFolder(title: "empty")
        let note = try store.createNote(parentId: child.id)
        try store.setTags(noteId: note.id, titles: ["t"])

        try store.deleteNotesPermanently(ids: [])
        try store.trashFolder(id: empty.id)
        // The trashed parent still has a live child folder, so it must survive emptying the trash.
        try store.db.run("UPDATE folders SET deleted_time = 1 WHERE id = ?", [parent.id])
        try store.trashNotes(ids: [note.id])
        try store.emptyTrash()

        #expect(store.note(id: note.id) == nil)
        #expect(store.folder(id: empty.id) == nil)
        #expect(store.folder(id: parent.id) != nil)
        #expect(try store.deletedItems().map(\.type).sorted() == [1, 2, 6])

        let other = try store.createNote(parentId: child.id)
        try store.deleteNotesPermanently(ids: [other.id])
        #expect(store.note(id: other.id) == nil)
    }

    // MARK: Tags

    @Test func tags() throws {
        let store = try makeStore()
        let note = try store.createNote(parentId: "")
        let trashed = try store.createNote(parentId: "")
        try store.setTags(noteId: note.id, titles: ["Urgent", " home ", "", "URGENT"])
        #expect(store.tags(forNote: note.id).map(\.title) == ["home", "urgent"])
        try store.setTags(noteId: trashed.id, titles: ["Home"])
        try store.trashNotes(ids: [trashed.id])
        #expect(store.tags().map(\.title) == ["home", "urgent"])
        #expect(store.tags().map(\.noteCount) == [1, 1])

        try store.setTags(noteId: note.id, titles: ["home"])
        #expect(store.tags(forNote: note.id).map(\.title) == ["home"])
        #expect(try store.deletedItems().map(\.type) == [6])

        let home = try #require(store.tags().first { $0.title == "home" })
        try store.addTag(tagId: home.id, toNote: note.id)
        #expect(try store.rows(.noteTag, where: "note_id = ?", [note.id]).count == 1)

        try store.renameTag(id: home.id, title: "House")
        #expect(store.tags(forNote: note.id).map(\.title) == ["house"])

        try store.deleteTag(id: home.id)
        #expect(store.tags(forNote: note.id).isEmpty)
        #expect(try store.deletedItems().filter { $0.type == 5 }.map(\.id) == [home.id])

        try store.upsert(.tag, ["id": fixtureId(1), "title": "secret", "encryption_applied": 1])
        #expect(!store.tags().contains { $0.title == "secret" })
        #expect(store.notes(filter: .tag(home.id), sort: .updated).isEmpty)
    }

    // MARK: Resources

    @Test func resources() throws {
        let store = try makeStore()
        let dir = temporaryDirectory()
        let png = dir.appendingPathComponent("Pic.PNG")
        try Data([0x89, 0x50]).write(to: png)
        let unknown = dir.appendingPathComponent("blob.zzzunknown")
        try Data([1]).write(to: unknown)

        let image = try store.addResource(fileAt: png)
        #expect(image.mime == "image/png")
        #expect(image.fileExtension == "png")
        #expect(image.size == 2)
        #expect(image.title == "Pic.PNG")
        #expect(FileManager.default.fileExists(atPath: store.url(for: image).path))

        let other = try store.addResource(fileAt: unknown)
        #expect(other.mime == "application/octet-stream")

        let raw = try store.addResource(data: Data("x".utf8), filename: "raw", mime: "text/plain", fileExtension: "")
        #expect(store.url(for: raw).lastPathComponent == raw.id)
        #expect(store.resource(id: raw.id)?.size == 1)
        #expect(store.resource(id: fixtureId(404)) == nil)
    }
}
