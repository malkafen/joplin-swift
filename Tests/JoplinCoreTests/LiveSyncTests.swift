import Foundation
@testable import JoplinCore
import Testing

private let environment = ProcessInfo.processInfo.environment

private func liveURL(_ key: String) -> String? {
    environment[key].flatMap { $0.isEmpty ? nil : $0 }
}

@MainActor
@Suite(.serialized) struct LiveSyncTests {
    static let email = environment["JN_LIVE_EMAIL"] ?? "admin@localhost"
    static let password = environment["JN_LIVE_PASSWORD"] ?? "admin"

    func engine(_ store: Store, _ url: String) throws -> SyncEngine {
        SyncEngine(store: store, client: try JoplinServerClient(baseURL: url, email: Self.email, password: Self.password))
    }

    func timed(_ label: String, _ body: () async throws -> SyncReport) async throws -> SyncReport {
        let start = Date()
        let report = try await body()
        print(String(format: "LIVE %@: %.2f s (%@)", label, Date().timeIntervalSince(start), report.description))
        return report
    }

    @Test(.enabled(if: liveURL("JN_LIVE_BENCH_DOWN") != nil))
    func benchmarkDownload() async throws {
        let url = try #require(liveURL("JN_LIVE_BENCH_DOWN"))
        let store = try makeStore()
        let first = try await timed("first sync down") { try await engine(store, url).sync() }
        #expect(first.downloaded > 0)
        let again = try await timed("no-op sync") { try await engine(store, url).sync() }
        #expect(again == SyncReport())
    }

    @Test(.enabled(if: liveURL("JN_LIVE_BENCH_UP") != nil))
    func benchmarkUpload() async throws {
        let url = try #require(liveURL("JN_LIVE_BENCH_UP"))
        let count = Int(environment["JN_LIVE_BENCH_NOTES"] ?? "") ?? 5000
        let store = try makeStore()
        let body = String(repeating: "Lorem ipsum dolor sit amet, synchronisation benchmark text. ", count: 16)
        let folders = try (0..<30).map { try store.createFolder(title: "Up notebook \($0)").id }
        for i in 0..<count {
            let note = try store.createNote(parentId: folders[i % folders.count], title: "Up note \(i)", body: "# Note \(i)\n\n\(body)")
            if i % 3 == 0 { try store.setTags(noteId: note.id, titles: ["bench\(i % 5)"]) }
        }
        let first = try await timed("first sync up") { try await engine(store, url).sync() }
        #expect(first.uploaded >= count)
        let again = try await timed("no-op sync after upload") { try await engine(store, url).sync() }
        #expect(again == SyncReport())
    }

    func itemIds(_ store: Store) throws -> Set<String> {
        var ids = Set<String>()
        for type in ModelType.syncable { ids.formUnion(try store.rows(type).map { $0.string("id") }) }
        return ids
    }

    func remove(_ ids: Set<String>, using client: JoplinServerClient, resources: Set<String>) async throws {
        let names = ids.map { "\($0).md" } + resources.intersection(ids).map { ".resource/\($0)" }
        _ = try await SyncEngine.mapConcurrently(names, limit: 8) { try await client.delete($0) }
    }

    @Test(.enabled(if: liveURL("JN_LIVE_SYNC_A") != nil && liveURL("JN_LIVE_SYNC_B") != nil))
    func switchingBetweenLiveServers() async throws {
        let a = try JoplinServerClient(baseURL: try #require(liveURL("JN_LIVE_SYNC_A")), email: Self.email, password: Self.password)
        let b = try JoplinServerClient(baseURL: try #require(liveURL("JN_LIVE_SYNC_B")), email: Self.email, password: Self.password)
        func sync(_ store: Store, _ client: JoplinServerClient, _ label: String) async throws -> SyncReport {
            try await timed(label) { try await SyncEngine(store: store, client: client).sync() }
        }
        let store = try makeStore()
        let fromA = try await sync(store, a, "A first sync")
        let idsA = try itemIds(store)
        #expect(fromA.downloaded == idsA.count)

        let folder = try store.createFolder(title: "Switch test \(Store.now())")
        var local: Set<String> = [folder.id]
        for i in 0..<3 { local.insert(try store.createNote(parentId: folder.id, title: "Switch note \(i)", body: "local \(i)").id) }

        let toB = try await sync(store, b, "switch to B")
        let idsB = try itemIds(store).subtracting(idsA).subtracting(local)
        #expect(toB.uploaded == idsA.count + local.count)
        #expect(toB.downloaded == idsB.count)
        #expect(toB.conflicts == 0)
        #expect(idsA.isDisjoint(with: idsB))

        let checkB = try makeStore()
        _ = try await sync(checkB, b, "fresh client on B")
        #expect(try itemIds(checkB) == itemIds(store))

        let back = try await sync(store, a, "switch back to A")
        #expect(back.uploaded == idsB.count + local.count)
        #expect(back.downloaded == 0)
        #expect(back.conflicts == 0)

        let checkA = try makeStore()
        _ = try await sync(checkA, a, "fresh client on A")
        #expect(try itemIds(checkA) == itemIds(store))
        #expect(try checkA.rows(.note).count == checkA.db.scalarInt("SELECT COUNT(DISTINCT id) FROM notes"))

        #expect(try await sync(store, a, "A again") == SyncReport())
        #expect(try await sync(store, b, "B again") == SyncReport())

        let resources = Set(try store.rows(.resource).map { $0.string("id") })
        try await remove(idsB.union(local), using: a, resources: resources)
        try await remove(idsA.union(local), using: b, resources: resources)
        let restoredA = try makeStore()
        _ = try await sync(restoredA, a, "A after cleanup")
        #expect(try itemIds(restoredA) == idsA)
        let restoredB = try makeStore()
        _ = try await sync(restoredB, b, "B after cleanup")
        #expect(try itemIds(restoredB) == idsB)
    }
}
