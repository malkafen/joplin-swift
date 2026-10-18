import Foundation
@testable import JoplinCore

func temporaryDirectory(_ prefix: String = "jn-test") -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func makeStore() throws -> Store {
    try Store(directory: temporaryDirectory())
}

/// Lowercase 32-char hex id, deterministic from a small number (readable fixtures).
func fixtureId(_ n: Int) -> String {
    String(format: "%032x", n)
}

extension Store {
    func deletedItems() throws -> [(type: Int64, id: String)] {
        try db.query("SELECT item_type, item_id FROM deleted_items ORDER BY id").map { ($0.int("item_type"), $0.string("item_id")) }
    }
}
