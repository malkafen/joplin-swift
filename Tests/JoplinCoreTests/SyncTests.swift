import Foundation
@testable import JoplinCore
import Testing

@MainActor
@Suite struct SyncTests {
    let server = FakeJoplinServer()

    func client(password: String = "secret") throws -> JoplinServerClient {
        try JoplinServerClient(baseURL: "http://joplin.test:22300/", email: "user@example.com", password: password, transport: server)
    }

    func engine(_ store: Store) throws -> SyncEngine {
        SyncEngine(store: store, client: try client())
    }

    @discardableResult
    func sync(_ store: Store) async throws -> SyncReport {
        try await engine(store).sync()
    }

    func edit(_ store: Store, _ type: ModelType, _ id: String, _ column: String, _ value: Any, at time: Int64? = nil) throws {
        let t = time ?? (store.row(type, id: id)!.int("updated_time") + 1000)
        try store.db.run("UPDATE \(type.table!) SET \"\(column)\" = ?, updated_time = ? WHERE id = ?", [value, t, id])
    }

    @Test func firstSyncUploadsEverythingAndCreatesSyncInfo() async throws {
        let store = try makeStore()
        let folder = try store.createFolder(title: "Work")
        let note = try store.createNote(parentId: folder.id, title: "Plan", body: "- [ ] one\n- [x] two")
        try store.setTags(noteId: note.id, titles: ["urgent"])
        let res = try store.addResource(data: Data("hello".utf8), filename: "a.txt", mime: "text/plain", fileExtension: "txt")

        let report = try await sync(store)
        #expect(report.uploaded == 5)
        #expect(report.downloaded == 0)
        #expect(server.itemNames.count == 5)
        #expect(server.file(".resource/\(res.id)") == Data("hello".utf8))
        let info = try #require(server.file("info.json"))
        let obj = try #require(try JSONSerialization.jsonObject(with: info) as? [String: Any])
        #expect(obj["version"] as? Int == 3)
        #expect(server.text("\(note.id).md")?.hasPrefix("Plan\n\n- [ ] one\n- [x] two\n\nid: \(note.id)") == true)
        #expect(server.locks.isEmpty)
        #expect(store.setting("sync.last_time") != nil)

        let second = try await sync(store)
        #expect(second == SyncReport())
    }

    @Test func manyItemsAreFetchedConcurrently() async throws {
        let a = try makeStore()
        let folder = try a.createFolder(title: "Bulk")
        var ids: [String] = []
        for i in 0..<(SyncEngine.parallelDownloads * 3 + 1) {
            ids.append(try a.createNote(parentId: folder.id, title: "n\(i)", body: "body \(i)").id)
        }
        try await sync(a)
        server.pageSize = 10

        let b = try makeStore()
        let report = try await sync(b)
        #expect(report.downloaded == ids.count + 1)
        for (i, id) in ids.enumerated() { #expect(b.note(id: id)?.body == "body \(i)") }
        #expect(try await sync(b) == SyncReport())

        let names = [ids[0], ids[1], String(repeating: "f", count: 32)].map { "\($0).md" }
        let contents = try await engine(b).fetch(names)
        #expect(contents.count == 3)
        #expect(contents[names[2]] == .some(nil))
        #expect(try await engine(b).fetch([]).isEmpty)
    }

    @Test func twoClientsExchangeNotesTagsAndAttachments() async throws {
        let a = try makeStore()
        let b = try makeStore()
        let folder = try a.createFolder(title: "Shared")
        let sub = try a.createFolder(title: "Child", parentId: folder.id)
        let res = try a.addResource(data: Data([1, 2, 3]), filename: "img.png", mime: "image/png", fileExtension: "png")
        let note = try a.createNote(parentId: sub.id, title: "Hello", body: "Body ![](:/\(res.id))")
        try a.setTags(noteId: note.id, titles: ["x", "y"])
        try await sync(a)

        let report = try await sync(b)
        #expect(report.downloaded == 8)
        #expect(b.folder(id: sub.id)?.parentId == folder.id)
        #expect(b.note(id: note.id)?.body == "Body ![](:/\(res.id))")
        #expect(Set(b.tags(forNote: note.id).map(\.title)) == ["x", "y"])
        let local = try #require(b.resource(id: res.id))
        #expect(try Data(contentsOf: b.url(for: local)) == Data([1, 2, 3]))
        #expect(!b.isDirty(id: note.id))

        var edited = try #require(b.note(id: note.id))
        edited.body = "Changed on B"
        try b.saveNote(edited)
        try b.trashFolder(id: folder.id)
        #expect(try await sync(b).uploaded == 3)
        let back = try await sync(a)
        #expect(back.downloaded == 3)
        #expect(a.note(id: note.id)?.body == "Changed on B")
        #expect(a.note(id: note.id)?.deletedTime ?? 0 > 0)
        #expect(a.folders().isEmpty)
    }

    @Test func permanentDeletionsPropagate() async throws {
        let a = try makeStore()
        let b = try makeStore()
        let folder = try a.createFolder(title: "F")
        let note = try a.createNote(parentId: folder.id, title: "Doomed")
        try a.setTags(noteId: note.id, titles: ["t"])
        let res = try a.addResource(data: Data("r".utf8), filename: "r.txt", mime: "text/plain", fileExtension: "txt")
        try await sync(a)
        try await sync(b)
        #expect(b.note(id: note.id) != nil)

        try a.deleteNotesPermanently(ids: [note.id])
        try a.db.run("DELETE FROM resources WHERE id = ?", [res.id])
        try a.db.run("INSERT INTO deleted_items (item_type, item_id, deleted_time) VALUES (4, ?, 0)", [res.id])
        let report = try await sync(a)
        #expect(report.deletedRemotely == 3)
        #expect(server.file("\(note.id).md") == nil)
        #expect(server.file(".resource/\(res.id)") == nil)
        #expect(try a.pendingDeletions().isEmpty)

        let localFile = b.url(for: try #require(b.resource(id: res.id)))
        let pulled = try await sync(b)
        #expect(pulled.deletedLocally == 3)
        #expect(b.note(id: note.id) == nil)
        #expect(b.resource(id: res.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: localFile.path))
        #expect(try b.pendingDeletions().isEmpty, "remote deletions are not echoed back")
    }

    @Test func conflictingNoteEditsKeepBothVersions() async throws {
        let a = try makeStore()
        let b = try makeStore()
        let folder = try a.createFolder(title: "F")
        let note = try a.createNote(parentId: folder.id, title: "Shared", body: "base")
        try a.setTags(noteId: note.id, titles: ["keep"])
        try await sync(a)
        try await sync(b)

        try edit(a, .note, note.id, "body", "from A")
        try edit(b, .note, note.id, "body", "from B", at: b.row(.note, id: note.id)!.int("updated_time") + 2000)
        try await sync(a)
        let report = try await sync(b)
        #expect(report.conflicts == 1)
        #expect(b.note(id: note.id)?.body == "from A")
        let copy = try #require(try b.rows(.note, where: "conflict_original_id = ?", [note.id]).first)
        #expect(copy.string("body") == "from B")
        #expect(copy.string("title") == "Shared (conflict)")
        #expect(b.tags(forNote: copy.string("id")).map(\.title) == ["keep"])

        try await sync(b)
        try await sync(a)
        #expect(a.note(id: copy.string("id"))?.body == "from B")
    }

    @Test func ownUploadsComingBackAreNotConflicts() async throws {
        let store = try makeStore()
        let note = try store.createNote(parentId: try store.createFolder(title: "F").id, title: "Mine", body: "v1")
        try await sync(store)
        try edit(store, .note, note.id, "body", "v2")
        let report = try await sync(store)
        #expect(report.conflicts == 0)
        #expect(report.downloaded == 0)
        #expect(report.uploaded == 1)
        #expect(store.note(id: note.id)?.body == "v2")
        #expect(server.text("\(note.id).md")?.contains("v2") == true)
    }

    @Test func identicalEditsAreNotConflicts() async throws {
        let a = try makeStore()
        let b = try makeStore()
        let note = try a.createNote(parentId: try a.createFolder(title: "F").id, title: "Same", body: "x")
        try await sync(a)
        try await sync(b)
        try edit(a, .note, note.id, "is_todo", 1)
        try edit(b, .note, note.id, "is_todo", 1, at: b.row(.note, id: note.id)!.int("updated_time") + 5000)
        try await sync(a)
        #expect(try await sync(b).conflicts == 0)

        let t = Store.now() + 10_000
        try edit(a, .note, note.id, "title", "T", at: t)
        try edit(b, .note, note.id, "title", "T", at: t)
        try await sync(a)
        let report = try await sync(b)
        #expect(report.downloaded == 0)
        #expect(!b.isDirty(id: note.id))
    }

    @Test func newerLocalChangeWinsForNonNotes() async throws {
        let a = try makeStore()
        let b = try makeStore()
        let folder = try a.createFolder(title: "Original")
        try await sync(a)
        try await sync(b)
        try edit(a, .folder, folder.id, "title", "From A")
        try edit(b, .folder, folder.id, "title", "From B newer", at: a.row(.folder, id: folder.id)!.int("updated_time") + 5000)
        try await sync(a)
        let report = try await sync(b)
        #expect(report.downloaded == 0)
        #expect(report.uploaded == 1)
        try await sync(a)
        #expect(a.folder(id: folder.id)?.title == "From B newer")

        try edit(a, .folder, folder.id, "title", "A again", at: a.row(.folder, id: folder.id)!.int("updated_time") + 10_000)
        try edit(b, .folder, folder.id, "title", "B older", at: b.row(.folder, id: folder.id)!.int("updated_time") + 1)
        try await sync(a)
        try await sync(b)
        #expect(b.folder(id: folder.id)?.title == "A again")
    }

    @Test func locallyEditedItemSurvivesRemoteDeletion() async throws {
        let a = try makeStore()
        let b = try makeStore()
        let note = try a.createNote(parentId: try a.createFolder(title: "F").id, title: "Keep me")
        try await sync(a)
        try await sync(b)
        try a.deleteNotesPermanently(ids: [note.id])
        try await sync(a)
        try edit(b, .note, note.id, "body", "still editing")
        let report = try await sync(b)
        #expect(report.deletedLocally == 0)
        #expect(b.note(id: note.id)?.body == "still editing")
        #expect(server.file("\(note.id).md") != nil, "re-uploaded")
    }

    @Test func pendingLocalDeletionIsNotResurrected() async throws {
        let a = try makeStore()
        let b = try makeStore()
        let note = try a.createNote(parentId: try a.createFolder(title: "F").id, title: "N")
        try await sync(a)
        try await sync(b)
        try edit(a, .note, note.id, "body", "edited remotely")
        try await sync(a)
        try b.deleteNotesPermanently(ids: [note.id])
        try await sync(b)
        #expect(b.note(id: note.id) == nil)
        #expect(server.file("\(note.id).md") == nil)
    }

    @Test func skipsEncryptedUnknownAndMalformedItems() async throws {
        let store = try makeStore()
        let id1 = fixtureId(1), id2 = fixtureId(2), id3 = fixtureId(3), id4 = fixtureId(4)
        server.seed("\(id1).md", "\n\nid: \(id1)\nencryption_cipher_text: xyz\nencryption_applied: 1\nupdated_time: 2024-01-01T00:00:00.000Z\ntype_: 1")
        server.seed("\(id2).md", "key\n\nid: \(id2)\nupdated_time: 2024-01-01T00:00:00.000Z\ntype_: 9")
        server.seed("\(id3).md", "not a joplin item")
        server.seed("\(id4).md", "Wrong id\n\nid: \(fixtureId(5))\nupdated_time: 2024-01-01T00:00:00.000Z\ntype_: 2")
        server.seed("README.md", "ignored")
        server.seed(".resource/\(id1)", "blob")
        server.seed("locks/x.json", "{}")
        let report = try await sync(store)
        #expect(report.skipped == 4)
        #expect(report.downloaded == 0)
        #expect(store.note(id: id1) == nil)
        #expect(store.folder(id: fixtureId(5)) == nil)
    }

    @Test func importsItemsCreatedByJoplin() async throws {
        let store = try makeStore()
        let folderId = fixtureId(10), noteId = fixtureId(11), resId = fixtureId(12)
        server.seed("\(folderId).md", try Serializer.serialize(type: .folder, fields: [
            "id": folderId, "title": "From Joplin", "updated_time": Int64(1_700_000_000_000),
        ]))
        server.seed("\(noteId).md", try Serializer.serialize(type: .note, fields: [
            "id": noteId, "parent_id": folderId, "title": "Note", "body": "Text", "updated_time": Int64(1_700_000_000_000),
        ]))
        server.seed("\(resId).md", try Serializer.serialize(type: .resource, fields: [
            "id": resId, "title": "no blob", "mime": "text/plain", "updated_time": Int64(1_700_000_000_000),
        ]))
        let report = try await sync(store)
        #expect(report.downloaded == 3)
        #expect(store.note(id: noteId)?.parentId == folderId)
        #expect(store.resource(id: resId)?.title == "no blob")
        #expect(store.syncTime(id: noteId) == 1_700_000_000_000)
        #expect(try store.itemsToUpload().isEmpty)
    }

    @Test func pagedDeltaAndInvalidCursor() async throws {
        let a = try makeStore()
        let b = try makeStore()
        let folder = try a.createFolder(title: "F")
        for i in 0..<5 { try a.createNote(parentId: folder.id, title: "N\(i)") }
        try await sync(a)
        server.pageSize = 2
        #expect(try await sync(b).downloaded == 6)
        #expect(b.setting(SyncEngine.cursorKey) == String(server.changes.count))

        b.setSetting(SyncEngine.cursorKey, "999999")
        try edit(a, .note, try #require(a.notes(filter: .all, sort: .title).first).id, "body", "new")
        try await sync(a)
        let report = try await sync(b)
        #expect(report.downloaded == 1)
    }

    @Test func renewsExpiredSessions() async throws {
        let store = try makeStore()
        try store.createFolder(title: "F")
        let e = try engine(store)
        try await e.client.login()
        server.expireSessions()
        try await e.checkSyncInfo()
        #expect(server.requests.filter { $0.hasSuffix("/api/sessions") }.count == 2)
        #expect(try await e.sync().uploaded == 1)
    }

    @Test func refusesEncryptedOrNewerTargets() async throws {
        let store = try makeStore()
        server.seed("info.json", #"{"version":3,"e2ee":{"value":true,"updatedTime":1}}"#)
        await #expect(throws: SyncError.encryptionEnabled) { try await sync(store) }
        server.seed("info.json", #"{"version":4}"#)
        await #expect(throws: SyncError.unsupportedSyncVersion(4)) { try await sync(store) }
        server.seed("info.json", "garbage")
        await #expect(throws: SyncError.invalidResponse("info.json is not valid JSON")) { try await sync(store) }
        server.seed("info.json", #"{"version":3,"e2ee":{"value":false}}"#)
        try await sync(store)
    }

    @Test func authenticationAndServerErrors() async throws {
        let store = try makeStore()
        await #expect(throws: SyncError.authentication("Invalid email or password")) {
            try await SyncEngine(store: store, client: try client(password: "wrong")).sync()
        }
        server.failures["PUT /api/items/root:/info.json"] = 500
        await #expect(throws: SyncError.http(status: 500, code: "", message: "Injected failure")) { try await sync(store) }

        server.seed("info.json", #"{"version":3}"#)
        try store.createFolder(title: "F")
        server.failures["PUT /api/items/root:/"] = 502
        await #expect(throws: SyncError.http(status: 502, code: "", message: "Injected failure")) { try await sync(store) }
        #expect(server.locks.isEmpty)
        #expect(try await sync(store).uploaded == 1)
    }

    @Test func respectsLocksOfOtherClients() async throws {
        let store = try makeStore()
        server.setLock(type: 2, clientId: "other")
        await #expect(throws: SyncError.locked("Cannot acquire lock because there is an active lock for client: 1 #other")) {
            try await sync(store)
        }
        #expect(server.itemNames.isEmpty)
    }

    @Test func malformedServerResponses() async throws {
        let broken = BrokenTransport()
        let client = try JoplinServerClient(baseURL: "https://joplin.test", email: "e", password: "p", transport: broken)
        await #expect(throws: SyncError.invalidResponse("no session id")) { try await client.login() }
        broken.sessionBody = #"{"id":"s"}"#
        await #expect(throws: SyncError.invalidResponse("delta is not JSON")) { _ = try await client.delta(cursor: "") }
    }

    @Test func clientValidation() throws {
        #expect(throws: SyncError.invalidURL("ftp://x")) { try JoplinServerClient(baseURL: "ftp://x", email: "", password: "") }
        #expect(throws: SyncError.invalidURL("not a url")) { try JoplinServerClient(baseURL: "not a url", email: "", password: "") }
        let c = try JoplinServerClient(baseURL: " https://h.example/joplin// ", email: "", password: "")
        #expect(c.baseURL.absoluteString == "https://h.example/joplin")
        #expect(SyncEngine.isItemName("\(fixtureId(1)).md"))
        #expect(!SyncEngine.isItemName("\(String(repeating: "A", count: 32)).md"))
        #expect(!SyncEngine.isItemName("info.json"))
    }

    @Test func descriptions() {
        let errors: [SyncError] = [
            .notConfigured, .invalidURL("u"), .authentication("a"), .http(status: 500, code: "", message: "m"),
            .encryptionEnabled, .unsupportedSyncVersion(9), .locked("l"), .invalidResponse("r"),
        ]
        #expect(Set(errors.map(\.description)).count == errors.count)
        var report = SyncReport()
        #expect(report.description == "downloaded 0, uploaded 0")
        report.deletedLocally = 1
        report.conflicts = 2
        report.skipped = 3
        #expect(report.description == "downloaded 0, uploaded 0, deleted 1, conflicts 2, skipped 3")
    }

    @Test func clientIdIsStable() throws {
        let store = try makeStore()
        let e = try engine(store)
        let id = e.clientId
        #expect(id.count == 32)
        #expect(e.clientId == id)
    }

    @Test func urlSessionTransport() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let transport = URLSessionTransport(session: URLSession(configuration: config))
        let (data, response) = try await transport.send(URLRequest(url: URL(string: "https://stub.test/ping")!))
        #expect(response.statusCode == 200)
        #expect(String(data: data, encoding: .utf8) == "pong")
    }
}

final class BrokenTransport: HTTPTransport, @unchecked Sendable {
    var sessionBody = "{}"

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = request.url!.path.hasSuffix("/api/sessions") ? sessionBody : "<html>"
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("pong".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
