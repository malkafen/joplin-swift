import Foundation
@testable import JoplinCore
import Testing

@MainActor
@Suite struct SyncEngineTests {
    let server = FakeJoplinServer()

    func client() throws -> JoplinServerClient {
        try JoplinServerClient(baseURL: "http://joplin.test:22300", email: "user@example.com", password: "secret", transport: server)
    }

    @discardableResult
    func sync(_ store: Store) async throws -> SyncReport {
        try await SyncEngine(store: store, client: try client()).sync()
    }

    func ledger(_ store: Store) throws -> SyncLedger {
        try store.syncLedger(identity: try client().targetIdentity)
    }

    func count(_ prefix: String) -> Int {
        server.requests.filter { $0.hasPrefix(prefix) }.count
    }

    func payload(_ size: Int, _ n: Int = 0) -> UploadPayload {
        UploadPayload(id: fixtureId(n), updatedTime: 1, data: Data(count: size))
    }

    @Test func uploadsInBatches() async throws {
        let store = try makeStore()
        let folder = try store.createFolder(title: "Many")
        for i in 0..<450 { try store.createNote(parentId: folder.id, title: "n\(i)") }
        let report = try await sync(store)
        #expect(report.uploaded == 451)
        #expect(count("PUT /api/batch_items") == 3)
        #expect(server.itemNames.count == 451)
        #expect(try ledger(store).itemsToUpload().isEmpty)
        #expect(try await sync(store) == SyncReport())
    }

    @Test func fallsBackToSingleUploadsOnOlderServers() async throws {
        server.supportsBatch = false
        let store = try makeStore()
        let folder = try store.createFolder(title: "F")
        for i in 0..<3 { try store.createNote(parentId: folder.id, title: "n\(i)") }
        let c = try client()
        #expect(try await SyncEngine(store: store, client: c).sync().uploaded == 4)
        #expect(!c.supportsBatchUpload)
        #expect(count("PUT /api/batch_items") == 1)
        #expect(server.itemNames.count == 4)
    }

    @Test func rejectedItemsAreRetried() async throws {
        let store = try makeStore()
        let folder = try store.createFolder(title: "F")
        let bad = try store.createNote(parentId: folder.id, title: "bad")
        try store.createNote(parentId: folder.id, title: "good")
        server.rejectedNames = ["\(bad.id).md"]
        let report = try await sync(store)
        #expect(report.uploaded == 2)
        #expect(report.skipped == 1)
        #expect(try ledger(store).isDirty(id: bad.id))
        server.rejectedNames = []
        #expect(try await sync(store).uploaded == 1)
        #expect(server.file("\(bad.id).md") != nil)
    }

    @Test func batchResponses() throws {
        #expect(throws: SyncError.invalidResponse("batch upload response is not JSON")) {
            try JoplinServerClient.batchFailures(Data("<html>".utf8), names: ["a"])
        }
        let body = #"{"items":{"ok":{"item":{},"error":null},"text":{"error":"nope"},"plain":{"error":{"code":"x"}},"msg":{"error":{"message":"m"}},"bare":{}}}"#
        let failures = try JoplinServerClient.batchFailures(Data(body.utf8), names: ["ok", "text", "plain", "msg", "bare", "gone"])
        #expect(failures["ok"] == nil)
        #expect(failures["bare"] == nil)
        #expect(failures["text"] == "nope")
        #expect(failures["msg"] == "m")
        #expect(failures["plain"]?.contains("x") == true)
        #expect(failures["gone"] == "missing from the batch response")
    }

    @Test func invalidBatchResponseFailsTheSync() async throws {
        let store = try makeStore()
        let folder = try store.createFolder(title: "F")
        try store.createNote(parentId: folder.id, title: "n")
        try store.createNote(parentId: folder.id, title: "m")
        server.batchResponse = Data("<html>".utf8)
        await #expect(throws: SyncError.invalidResponse("batch upload response is not JSON")) { try await sync(store) }
        #expect(server.locks.isEmpty)
    }

    @Test func batchesSplitByCountAndSize() {
        #expect(SyncEngine.batches([]).isEmpty)
        let small = (0..<450).map { payload(10, $0) }
        #expect(SyncEngine.batches(small).map(\.count) == [200, 200, 50])
        let big = [payload(600_000, 1), payload(600_000, 2), payload(2_000_000, 3), payload(10, 4)]
        #expect(SyncEngine.batches(big).map(\.count) == [1, 1, 1, 1])
        let mixed = [payload(400_000, 1), payload(400_000, 2), payload(400_000, 3)]
        #expect(SyncEngine.batches(mixed).map(\.count) == [2, 1])
        #expect(payload(1, 7).name == "\(fixtureId(7)).md")
    }

    @Test func refreshesTheLockDuringLongSyncs() async throws {
        let store = try makeStore()
        let folder = try store.createFolder(title: "F")
        for i in 0..<20 { try store.createNote(parentId: folder.id, title: "n\(i)") }
        server.delay = .milliseconds(20)
        let engine = SyncEngine(store: store, client: try client())
        engine.lockRefreshInterval = .milliseconds(5)
        try await engine.sync()
        #expect(count("POST /api/locks") >= 2)
        #expect(server.locks.isEmpty)
    }

    @Test func concurrentWorkStopsAtTheFirstError() async throws {
        struct Boom: Error {}
        var seen: [Int] = []
        await #expect(throws: Boom.self) {
            try await SyncEngine.forEachConcurrently(Array(0..<10), limit: 2, { n -> Int in
                if n == 3 { throw Boom() }
                return n
            }) { n, _ in seen.append(n) }
        }
        #expect(!seen.contains(3))
        #expect(seen.count < 10)
    }

    @Test func missingBlobIsFetchedOnALaterSync() async throws {
        let a = try makeStore()
        let res = try a.addResource(data: Data("blob".utf8), filename: "f.txt", mime: "text/plain", fileExtension: "txt")
        try await sync(a)
        server.remove(".resource/\(res.id)")

        let b = try makeStore()
        #expect(try await sync(b).downloaded == 1)
        let local = try #require(b.resource(id: res.id))
        #expect(!FileManager.default.fileExists(atPath: b.url(for: local).path))
        #expect(try b.missingBlobs() == [res.id])
        try await sync(b)
        #expect(try b.missingBlobs() == [res.id])

        server.seed(".resource/\(res.id)", "blob")
        try await sync(b)
        #expect(try Data(contentsOf: b.url(for: local)) == Data("blob".utf8))
        #expect(try b.missingBlobs().isEmpty)

        let c = try makeStore()
        server.remove(".resource/\(res.id)")
        try await sync(c)
        try c.db.run("DELETE FROM resources")
        try await sync(c)
        #expect(try c.missingBlobs().isEmpty)
    }

    @Test func blobsMoveOnlyWhenTheyChange() async throws {
        let a = try makeStore()
        let b = try makeStore()
        let res = try a.addResource(data: Data("one".utf8), filename: "f.txt", mime: "text/plain", fileExtension: "txt")
        try await sync(a)
        try await sync(b)
        #expect(count("GET /api/items/root:/.resource/") == 1)
        #expect(count("PUT /api/items/root:/.resource/") == 1)

        let t = Store.now() + 1000
        try a.db.run("UPDATE resources SET title = 'renamed', updated_time = ? WHERE id = ?", [t, res.id])
        try await sync(a)
        try await sync(b)
        #expect(b.resource(id: res.id)?.title == "renamed")
        #expect(count("GET /api/items/root:/.resource/") == 1)
        #expect(count("PUT /api/items/root:/.resource/") == 1)

        try Data("two".utf8).write(to: a.url(for: res))
        try a.db.run("UPDATE resources SET blob_updated_time = ?, updated_time = ? WHERE id = ?", [t + 1000, t + 1000, res.id])
        try await sync(a)
        try await sync(b)
        #expect(count("PUT /api/items/root:/.resource/") == 2)
        #expect(try Data(contentsOf: b.url(for: try #require(b.resource(id: res.id)))) == Data("two".utf8))

        let oldFile = b.url(for: try #require(b.resource(id: res.id)))
        try FileManager.default.moveItem(at: a.url(for: res), to: a.resourceDirectory.appendingPathComponent("\(res.id).md"))
        try a.db.run("UPDATE resources SET file_extension = 'md', updated_time = ? WHERE id = ?", [t + 2000, res.id])
        try await sync(a)
        try await sync(b)
        let moved = try #require(b.resource(id: res.id))
        #expect(moved.fileExtension == "md")
        #expect(try Data(contentsOf: b.url(for: moved)) == Data("two".utf8))
        #expect(!FileManager.default.fileExists(atPath: oldFile.path))
        #expect(count("GET /api/items/root:/.resource/") == 2)

        try a.db.run("UPDATE resources SET file_extension = 'bin', blob_updated_time = ?, updated_time = ? WHERE id = ?",
                     [t + 3000, t + 3000, res.id])
        try FileManager.default.moveItem(at: a.resourceDirectory.appendingPathComponent("\(res.id).md"),
                                         to: a.resourceDirectory.appendingPathComponent("\(res.id).bin"))
        try await sync(a)
        try await sync(b)
        let rebinned = try #require(b.resource(id: res.id))
        #expect(FileManager.default.fileExists(atPath: b.url(for: rebinned).path))
        #expect(!FileManager.default.fileExists(atPath: b.url(for: moved).path))
    }

    @Test func resourcesWithoutBlobTimesAreAlwaysRefreshed() async throws {
        let store = try makeStore()
        let id = fixtureId(40)
        func seed(_ time: Int64) throws {
            server.seed("\(id).md", try Serializer.serialize(type: .resource, fields: [
                "id": id, "title": "old style", "mime": "text/plain", "updated_time": time,
            ]))
        }
        try seed(1_700_000_000_000)
        server.seed(".resource/\(id)", "x")
        try await sync(store)
        try seed(1_700_000_001_000)
        try await sync(store)
        #expect(count("GET /api/items/root:/.resource/") == 2)
    }

    @Test func remoteItemsOfAnotherTypeOrEncodingAreSkipped() async throws {
        let store = try makeStore()
        let folder = try store.createFolder(title: "Mine")
        try await sync(store)
        server.seed("\(folder.id).md", try Serializer.serialize(type: .note, fields: [
            "id": folder.id, "title": "imposter", "updated_time": Int64(1_700_000_000_000),
        ]))
        server.seed("\(fixtureId(50)).md", data: Data([0xff, 0xfe, 0xfd]))
        let report = try await sync(store)
        #expect(report.skipped == 2)
        #expect(store.note(id: folder.id) == nil)
        #expect(store.folder(id: folder.id)?.title == "Mine")
    }

    @Test func remoteDeletionsInBulk() async throws {
        let a = try makeStore()
        let b = try makeStore()
        let folder = try a.createFolder(title: "F")
        let ids = try (0..<30).map { try a.createNote(parentId: folder.id, title: "n\($0)").id }
        try await sync(a)
        try await sync(b)
        try a.deleteNotesPermanently(ids: ids)
        #expect(try await sync(a).deletedRemotely == 30)
        #expect(try await sync(b).deletedLocally == 30)
        #expect(b.notes(filter: .all, sort: .title).isEmpty)
    }

    @Test func minimalRemoteItemsAreAccepted() async throws {
        let store = try makeStore()
        let local = try store.createNote(parentId: "", title: "Local", body: "mine")
        let folderId = fixtureId(60), resourceId = fixtureId(61)
        server.seed("\(folderId).md", "Plain\n\nid: \(folderId)\nupdated_time: 2024-01-01T00:00:00.000Z\ntype_: 2")
        server.seed("\(resourceId).md", "R\n\nid: \(resourceId)\nupdated_time: 2024-01-01T00:00:00.000Z\ntype_: 4")
        server.seed(".resource/\(resourceId)", "raw")
        server.seed("\(local.id).md", "id: \(local.id)\nupdated_time: 2024-01-01T00:00:00.000Z\ntype_: 1")
        let untitled = try store.createNote(parentId: "", title: "", body: "draft")
        server.seed("\(untitled.id).md", "id: \(untitled.id)\nupdated_time: 2024-01-01T00:00:00.000Z\ntype_: 1")
        server.seed("\(fixtureId(62)).md", "Timeless\n\nid: \(fixtureId(62))\ntype_: 2")
        let report = try await sync(store)
        #expect(report.downloaded == 5)
        #expect(report.conflicts == 2)
        #expect(store.folder(id: fixtureId(62))?.title == "Timeless")
        #expect(store.folder(id: folderId)?.title == "Plain")
        let resource = try #require(store.resource(id: resourceId))
        #expect(resource.storageName == resourceId)
        #expect(try Data(contentsOf: store.url(for: resource)) == Data("raw".utf8))
        #expect(try store.rows(.note, where: "conflict_original_id = ?", [local.id]).first?.string("body") == "mine")
    }

    @Test func serversWithoutItemTimesStillRecogniseKnownVersions() async throws {
        let a = try makeStore()
        let b = try makeStore()
        let note = try a.createNote(parentId: try a.createFolder(title: "F").id, title: "N")
        try await sync(a)
        server.omitItemTimes = true
        #expect(try await sync(b).downloaded == 2)
        let t = Store.now() + 10_000
        try a.db.run("UPDATE notes SET title = 'same', updated_time = ? WHERE id = ?", [t, note.id])
        try b.db.run("UPDATE notes SET title = 'same', updated_time = ? WHERE id = ?", [t, note.id])
        try await sync(a)
        let report = try await sync(b)
        #expect(report.downloaded == 0)
        #expect(report.uploaded == 0)
        #expect(try !ledger(b).isDirty(id: note.id))
        try ledger(b).saveCursor("")
        #expect(try await sync(b) == SyncReport())
    }

    @Test func itemThatVanishedBeforeItsDownloadIsIgnored() async throws {
        let store = try makeStore()
        server.seed("\(fixtureId(70)).md", "Gone\n\nid: \(fixtureId(70))\nupdated_time: 2024-01-01T00:00:00.000Z\ntype_: 2")
        server.removeSilently("\(fixtureId(70)).md")
        #expect(try await sync(store) == SyncReport())
        #expect(try !ledger(store).isDirty(id: fixtureId(70)))
    }

    @Test func resourceWithoutLocalFileUploadsItsMetadata() async throws {
        let store = try makeStore()
        let res = try store.addResource(data: Data("x".utf8), filename: "x.txt", mime: "text/plain", fileExtension: "txt")
        try FileManager.default.removeItem(at: store.url(for: res))
        #expect(try await sync(store).uploaded == 1)
        #expect(server.file("\(res.id).md") != nil)
        #expect(server.file(".resource/\(res.id)") == nil)
    }

    @Test func remoteDeletionOfUnknownTypeIsIgnored() throws {
        let store = try makeStore()
        #expect(try ledger(store).applyRemoteDeletion(id: fixtureId(1), type: .setting) == nil)
    }
}
