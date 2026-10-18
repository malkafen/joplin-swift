import Foundation
import Testing
@testable import JoplinCore

@Suite struct InteropTests {
    @Test func jexExportImportRoundTrip() throws {
        let a = try makeStore()
        let folder = try a.createFolder(title: "Notebook")
        let res = try a.addResource(data: Data("hello".utf8), filename: "hello.txt", mime: "text/plain", fileExtension: "txt")
        let note = try a.createNote(parentId: folder.id, title: "With attachment", body: "See [file](:/\(res.id))")
        try a.setTags(noteId: note.id, titles: ["t1"])
        let trashed = try a.createNote(parentId: folder.id, title: "trashed")
        try a.trashNotes(ids: [trashed.id])

        let jex = temporaryDirectory().appendingPathComponent("all.jex")
        try Data("stale".utf8).write(to: jex)
        let count = try a.exportJEX(to: jex)
        #expect(count == 5)

        let b = try makeStore()
        let report = try b.importJEX(jex)
        #expect(report.notes == 1 && report.folders == 1 && report.tags == 1 && report.noteTags == 1 && report.resources == 1)
        #expect(report.errors.isEmpty)
        #expect(b.note(id: note.id)?.body == note.body)
        #expect(b.note(id: trashed.id) == nil)
        let imported = try #require(b.resource(id: res.id))
        #expect(try String(contentsOf: b.url(for: imported), encoding: .utf8) == "hello")
        #expect(b.tags(forNote: note.id).map(\.title) == ["t1"])
    }

    @Test func exportSingleNotebookWithSubNotebooks() throws {
        let a = try makeStore()
        let root = try a.createFolder(title: "root")
        let child = try a.createFolder(title: "child", parentId: root.id)
        let other = try a.createFolder(title: "other")
        let img = try a.addResource(data: Data([1, 2]), filename: "i.png", mime: "image/png", fileExtension: "png")
        let lost = try a.addResource(data: Data([3]), filename: "lost.bin", mime: "application/octet-stream", fileExtension: "bin")
        try FileManager.default.removeItem(at: a.url(for: lost))
        let inChild = try a.createNote(parentId: child.id, title: "in child", body: "![](:/\(img.id)) [x](:/\(lost.id))")
        try a.setTags(noteId: inChild.id, titles: ["kept"])
        let outside = try a.createNote(parentId: other.id, title: "outside")
        try a.setTags(noteId: outside.id, titles: ["dropped"])

        let jex = temporaryDirectory().appendingPathComponent("root.jex")
        // 2 folders + 1 note + 1 tag + 1 link + 2 resources
        #expect(try a.exportJEX(to: jex, folderId: root.id) == 7)

        let b = try makeStore()
        let report = try b.importJEX(jex)
        #expect(report.folders == 2 && report.notes == 1 && report.resources == 2)
        #expect(b.folder(id: other.id) == nil)
        #expect(b.tags().map(\.title) == ["kept"])
        #expect(FileManager.default.fileExists(atPath: b.url(for: try #require(b.resource(id: img.id))).path))
        #expect(!FileManager.default.fileExists(atPath: b.url(for: try #require(b.resource(id: lost.id))).path))
    }

    @Test func exportEmptyNotebook() throws {
        let a = try makeStore()
        let empty = try a.createFolder(title: "empty")
        #expect(try a.exportJEX(to: temporaryDirectory().appendingPathComponent("e.jex"), folderId: empty.id) == 1)
    }

    @Test func importDirectoryLikeFileSystemSyncTarget() throws {
        let dir = temporaryDirectory()
        let blobs = dir.appendingPathComponent(".resource")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        func write(_ id: String, _ text: String) throws {
            try text.write(to: dir.appendingPathComponent("\(id).md"), atomically: true, encoding: .utf8)
        }
        let folder = fixtureId(1), note = fixtureId(2), withBlob = fixtureId(3), noBlob = fixtureId(4)
        try write(folder, "Synced\n\nid: \(folder)\nparent_id: \ntype_: 2")
        try write(note, "Note\n\nBody\n\nid: \(note)\nparent_id: \(folder)\ntype_: 1")
        try write(fixtureId(5), "\n\nid: \(fixtureId(5))\nencryption_applied: 1\ntype_: 1")
        try write(fixtureId(6), "MK\n\nid: \(fixtureId(6))\ntype_: 9")
        try write(fixtureId(7), "garbage without properties")
        try write(withBlob, "pic.jpg\n\nid: \(withBlob)\nmime: image/jpeg\nfile_extension: jpg\ntype_: 4")
        try write(noBlob, "missing\n\nid: \(noBlob)\nfile_extension: \ntype_: 4")
        try Data([9]).write(to: blobs.appendingPathComponent(withBlob))
        try "ignored".write(to: dir.appendingPathComponent("info.json"), atomically: true, encoding: .utf8)
        try "ignored".write(to: dir.appendingPathComponent("short.md"), atomically: true, encoding: .utf8)

        let store = try makeStore()
        let report = try store.importDirectory(dir)
        #expect(report.folders == 1 && report.notes == 1 && report.resources == 2)
        #expect(report.skippedEncrypted == 1)
        #expect(report.errors.count == 2)
        #expect(store.note(id: note)?.body == "Body")
        let resource = try #require(store.resource(id: withBlob))
        #expect(try Data(contentsOf: store.url(for: resource)) == Data([9]))

        // Re-importing overwrites existing blobs instead of failing.
        #expect(try store.importDirectory(dir).resources == 2)
    }

    @Test func importDirectoryMissing() throws {
        #expect(throws: (any Error).self) { try makeStore().importDirectory(temporaryDirectory().appendingPathComponent("none")) }
    }

    @Test func importCorruptJEX() throws {
        let file = temporaryDirectory().appendingPathComponent("bad.jex")
        try Data("not a tar".utf8).write(to: file)
        let error = #expect(throws: InteropError.self) { try makeStore().importJEX(file) }
        #expect(error?.description.hasPrefix("tar failed: ") == true)
    }

    @Test func importJoplinDesktopProfile() throws {
        // A Joplin Desktop profile has the same tables, plus columns this app does not know about.
        let profile = temporaryDirectory()
        let source = try Store(directory: profile)
        try source.db.exec("ALTER TABLE notes ADD COLUMN future_column TEXT")
        let folder = try source.createFolder(title: "Desktop")
        let note = try source.createNote(parentId: folder.id, title: "From desktop", body: "body")
        try source.setTags(noteId: note.id, titles: ["imported"])
        let res = try source.addResource(data: Data("blob".utf8), filename: "f.txt", mime: "text/plain", fileExtension: "txt")
        let gone = try source.addResource(data: Data(), filename: "g.txt", mime: "text/plain", fileExtension: "txt")
        try FileManager.default.removeItem(at: source.url(for: gone))
        try source.upsert(.note, ["id": fixtureId(1), "parent_id": folder.id, "encryption_applied": 1])
        // Older profiles: fewer columns and NULLs.
        let tag = try #require(source.tags().first)
        try source.db.exec("""
            DROP TABLE tags;
            CREATE TABLE tags (id TEXT PRIMARY KEY, title TEXT, user_data TEXT, encryption_applied INT NOT NULL DEFAULT 0);
            """)
        try source.db.run("INSERT INTO tags (id, title, user_data) VALUES (?, ?, NULL)", [tag.id, tag.title])

        let store = try makeStore()
        try store.addResource(data: Data(), filename: "x", mime: "text/plain", fileExtension: "txt")
        try FileManager.default.copyItem(at: source.url(for: res), to: store.url(for: res))

        let report = try store.importJoplinDesktopProfile(profile)
        #expect(report.folders == 1 && report.notes == 1 && report.tags == 1 && report.noteTags == 1 && report.resources == 2)
        #expect(report.skippedEncrypted == 1)
        #expect(store.note(id: note.id)?.body == "body")
        #expect(try String(contentsOf: store.url(for: try #require(store.resource(id: res.id))), encoding: .utf8) == "blob")
    }

    @Test func importJoplinDesktopProfileMissing() throws {
        let error = #expect(throws: InteropError.self) { try makeStore().importJoplinDesktopProfile(temporaryDirectory()) }
        #expect(error?.description.hasPrefix("Not found: ") == true)
        #expect(Store.joplinDesktopProfile.path.hasSuffix("/.config/joplin-desktop"))
    }

    @Test func reportDescription() {
        var report = ImportReport()
        report.count(.folder)
        report.count(.note)
        report.count(.tag)
        report.count(.noteTag)
        report.count(.resource)
        report.count(.setting)
        #expect(report.description == "Notebooks: 1, notes: 1, tags: 1, attachments: 1")
        report.skippedEncrypted = 2
        report.errors = ["e"]
        #expect(report.description == "Notebooks: 1, notes: 1, tags: 1, attachments: 1, skipped encrypted: 2, errors: 1")
    }

    @Test func markdownLinks() {
        let upper = String(repeating: "AB", count: 16)
        let body = "[a](:/\(fixtureId(1))) ![b](:/\(upper)) [c](https://x.y) :/short"
        #expect(MarkdownLinks.resourceIds(in: body) == [fixtureId(1), upper.lowercased()])
        #expect(MarkdownLinks.resourceIds(in: "").isEmpty)
    }
}
