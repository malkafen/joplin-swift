import Foundation
@testable import JoplinCore
import Testing

@MainActor
@Suite struct MultiTargetSyncTests {
    let serverA = FakeJoplinServer()
    let serverB = FakeJoplinServer()

    func client(_ server: FakeJoplinServer) throws -> JoplinServerClient {
        let url = server === serverA ? "http://a.test:22300" : "http://b.test:22300"
        return try JoplinServerClient(baseURL: url, email: "user@example.com", password: "secret", transport: server)
    }

    @discardableResult
    func sync(_ store: Store, _ server: FakeJoplinServer) async throws -> SyncReport {
        try await SyncEngine(store: store, client: try client(server)).sync()
    }

    func ledger(_ store: Store, _ server: FakeJoplinServer) throws -> SyncLedger {
        try store.syncLedger(identity: try client(server).targetIdentity)
    }

    func noteIds(_ store: Store) -> Set<String> {
        Set(((try? store.rows(.note)) ?? []).map { $0.string("id") })
    }

    func deletes(_ server: FakeJoplinServer, _ id: String) -> Int {
        server.requests.filter { $0 == "DELETE /api/items/root:/\(id).md:" }.count
    }

    @Test func switchingTargetsMergesBothLibrariesWithoutDuplicates() async throws {
        let mine = try makeStore()
        let folder = try mine.createFolder(title: "Alpha")
        let alpha = try (0..<3).map { try mine.createNote(parentId: folder.id, title: "a\($0)").id }
        try mine.setTags(noteId: alpha[0], titles: ["shared"])
        let res = try mine.addResource(data: Data("blob".utf8), filename: "f.txt", mime: "text/plain", fileExtension: "txt")
        #expect(try await sync(mine, serverA).uploaded == 7)

        let other = try makeStore()
        let betaFolder = try other.createFolder(title: "Beta")
        let beta = try (0..<2).map { try other.createNote(parentId: betaFolder.id, title: "b\($0)").id }
        try await sync(other, serverB)

        let first = try await sync(mine, serverB)
        #expect(first.uploaded == 7)
        #expect(first.downloaded == 3)
        #expect(first.conflicts == 0)
        #expect(serverB.file(".resource/\(res.id)") == Data("blob".utf8))
        #expect(noteIds(mine) == Set(alpha + beta))
        #expect(try await sync(mine, serverB) == SyncReport())

        try await sync(other, serverB)
        #expect(noteIds(other) == Set(alpha + beta))

        let back = try await sync(mine, serverA)
        #expect(back.uploaded == 3)
        #expect(back.downloaded == 0)
        #expect(back.conflicts == 0)
        #expect(serverA.itemNames.count == 10)
        #expect(serverB.itemNames.count == 10)
        #expect(noteIds(mine).count == 5)
        #expect(try await sync(mine, serverA) == SyncReport())
        #expect(try await sync(mine, serverB) == SyncReport())
    }

    @Test func editsMadeWhileOnAnotherTargetReachTheFirstOne() async throws {
        let mine = try makeStore()
        let note = try mine.createNote(parentId: try mine.createFolder(title: "F").id, title: "N", body: "v1")
        try await sync(mine, serverA)
        try await sync(mine, serverB)
        var edited = try #require(mine.note(id: note.id))
        edited.body = "v2"
        try mine.saveNote(edited, at: Store.now() + 1000)
        #expect(try await sync(mine, serverB).uploaded == 1)
        #expect(try await sync(mine, serverA).uploaded == 1)
        #expect(serverA.text("\(note.id).md")?.contains("v2") == true)
    }

    @Test func olderVersionPulledFromAnotherTargetIsSentBack() async throws {
        let mine = try makeStore()
        let other = try makeStore()
        let note = try mine.createNote(parentId: try mine.createFolder(title: "F").id, title: "Same", body: "new")
        try await sync(mine, serverA)
        try await sync(other, serverA)
        try other.db.run("UPDATE notes SET body = 'old', updated_time = updated_time - 5000 WHERE id = ?", [note.id])
        try await sync(other, serverB)

        let report = try await sync(mine, serverB)
        #expect(report.conflicts == 1)
        #expect(mine.note(id: note.id)?.body == "old")
        try await sync(mine, serverA)
        #expect(serverA.text("\(note.id).md")?.contains("old") == true)
        #expect(try mine.rows(.note, where: "conflict_original_id = ?", [note.id]).first?.string("body") == "new")
    }

    @Test func deletionsGoOnlyToTargetsThatHadTheItem() async throws {
        let mine = try makeStore()
        let folder = try mine.createFolder(title: "F")
        let onBoth = try mine.createNote(parentId: folder.id, title: "both")
        try await sync(mine, serverA)
        let onlyA = try mine.createNote(parentId: folder.id, title: "only A")
        try await sync(mine, serverA)
        try mine.deleteNotesPermanently(ids: [onlyA.id])

        let toB = try await sync(mine, serverB)
        #expect(toB.deletedRemotely == 0)
        #expect(deletes(serverB, onlyA.id) == 0)
        #expect(serverB.file("\(onBoth.id).md") != nil)
        #expect(try ledger(mine, serverB).pendingDeletions().map(\.itemId) == [onlyA.id])

        try mine.deleteNotesPermanently(ids: [onBoth.id])
        let deletedOnB = try await sync(mine, serverB)
        #expect(deletedOnB.deletedRemotely == 1)
        #expect(serverB.file("\(onBoth.id).md") == nil)
        #expect(Set(try ledger(mine, serverA).pendingDeletions().map(\.itemId)) == [onlyA.id, onBoth.id])

        let deletedOnA = try await sync(mine, serverA)
        #expect(deletedOnA.deletedRemotely == 2)
        #expect(serverA.file("\(onlyA.id).md") == nil)
        #expect(serverA.file("\(onBoth.id).md") == nil)
        #expect(try mine.deletedItems().isEmpty)
        #expect(try await sync(mine, serverB) == SyncReport())
        #expect(deletes(serverB, onlyA.id) == 0)
    }

    @Test func itemsNeverSyncedAreForgottenWithoutRequests() async throws {
        let mine = try makeStore()
        let folder = try mine.createFolder(title: "F")
        try await sync(mine, serverA)
        let note = try mine.createNote(parentId: folder.id, title: "short lived")
        try mine.deleteNotesPermanently(ids: [note.id])
        #expect(try await sync(mine, serverA).deletedRemotely == 0)
        #expect(deletes(serverA, note.id) == 0)
        #expect(try mine.deletedItems().isEmpty)
    }

    @Test func pendingDeletionIsNotDownloadedFromAnotherTarget() async throws {
        let mine = try makeStore()
        let note = try mine.createNote(parentId: try mine.createFolder(title: "F").id, title: "gone")
        try await sync(mine, serverA)
        serverB.seed("\(note.id).md", try #require(serverA.text("\(note.id).md")))
        try mine.deleteNotesPermanently(ids: [note.id])

        let report = try await sync(mine, serverB)
        #expect(report.downloaded == 0)
        #expect(mine.note(id: note.id) == nil)
        #expect(serverB.file("\(note.id).md") != nil)
        try await sync(mine, serverA)
        #expect(serverA.file("\(note.id).md") == nil)
    }

    @Test func remoteDeletionOnOneTargetReachesTheOther() async throws {
        let mine = try makeStore()
        let other = try makeStore()
        let note = try mine.createNote(parentId: try mine.createFolder(title: "F").id, title: "shared")
        try await sync(mine, serverA)
        try await sync(mine, serverB)
        try await sync(other, serverB)
        try other.deleteNotesPermanently(ids: [note.id])
        try await sync(other, serverB)

        #expect(try await sync(mine, serverB).deletedLocally == 1)
        #expect(mine.note(id: note.id) == nil)
        #expect(try await sync(mine, serverA).deletedRemotely == 1)
        #expect(serverA.file("\(note.id).md") == nil)
        #expect(try mine.deletedItems().isEmpty)
    }

    @Test func targetIdentityIsNormalised() throws {
        func identity(_ url: String, _ email: String) throws -> String {
            try JoplinServerClient(baseURL: url, email: email, password: "").targetIdentity
        }
        let base = try identity("http://joplin.test", "user@example.com")
        #expect(base == "http://joplin.test user@example.com")
        #expect(try identity("HTTP://Joplin.TEST:80/", " User@Example.com ") == base)
        #expect(try identity("https://joplin.test:443", "a@b") == "https://joplin.test a@b")
        #expect(try identity("https://joplin.test:8443/x/", "a@b") == "https://joplin.test:8443/x a@b")
        #expect(try identity("http://joplin.test:22300", "user@example.com") != base)
        #expect(try identity("http://joplin.test", "other@example.com") != base)
        #expect(try identity("http://joplin.test/?q=1#f", "user@example.com") == base)
    }
}
