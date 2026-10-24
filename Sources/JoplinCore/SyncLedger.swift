import Foundation

struct LocalItem: Equatable {
    let type: ModelType
    let updatedTime: Int64
    let syncTime: Int64?

    var isDirty: Bool { syncTime != updatedTime }
}

struct PendingDeletion: Equatable {
    let rowId: Int64
    let type: Int64
    let itemId: String
    let onTarget: Bool
    let elsewhere: Bool
}

struct UploadItem {
    let type: ModelType
    let row: Row

    var id: String { row.string("id") }
    var updatedTime: Int64 { row.int("updated_time") }
    var syncTime: Int64? { row["jn_sync_time"] as? Int64 }
}

public extension Store {
    static let uploadOrder: [ModelType] = [.folder, .tag, .resource, .note, .noteTag]
}

extension Store {
    static let legacyCursorKey = "sync.delta_cursor"

    static func jsonList(_ ids: [String]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: ids), as: UTF8.self)
    }

    func syncLedger(identity: String) throws -> SyncLedger {
        if let row = try db.query("SELECT id, cursor FROM sync_targets WHERE identity = ?", [identity]).first {
            return SyncLedger(store: self, target: row.int("id"), cursor: row.string("cursor"))
        }
        return try db.transaction {
            let cursor = setting(Self.legacyCursorKey) ?? ""
            try db.run("INSERT INTO sync_targets (identity, cursor) VALUES (?, ?)", [identity, cursor])
            let id = try db.scalarInt("SELECT id FROM sync_targets WHERE identity = ?", [identity])
            try db.run("UPDATE sync_items SET target_id = ? WHERE target_id = 0", [id])
            try db.run("DELETE FROM settings WHERE key = ?", [Self.legacyCursorKey])
            return SyncLedger(store: self, target: id, cursor: cursor)
        }
    }

    func missingBlobs() throws -> [String] {
        try db.query("SELECT resource_id FROM missing_blobs ORDER BY resource_id").map { $0.string("resource_id") }
    }

    func setBlobMissing(_ id: String, _ missing: Bool) throws {
        try db.run(missing ? "INSERT OR IGNORE INTO missing_blobs (resource_id) VALUES (?)"
                           : "DELETE FROM missing_blobs WHERE resource_id = ?", [id])
    }
}

final class SyncLedger {
    let store: Store
    let target: Int64
    private(set) var cursor: String

    init(store: Store, target: Int64, cursor: String) {
        self.store = store
        self.target = target
        self.cursor = cursor
    }

    private var db: SQLiteDB { store.db }

    func saveCursor(_ value: String) throws {
        try db.run("UPDATE sync_targets SET cursor = ? WHERE id = ?", [value, target])
        cursor = value
    }

    func syncTime(id: String) -> Int64? {
        (try? db.query("SELECT sync_time FROM sync_items WHERE target_id = ? AND item_id = ?", [target, id]).first)?.int("sync_time")
    }

    func markSynced(_ type: ModelType, id: String, time: Int64) throws {
        try db.run("""
            INSERT INTO sync_items (target_id, item_id, item_type, sync_time) VALUES (?, ?, ?, ?)
            ON CONFLICT(target_id, item_id) DO UPDATE SET item_type = excluded.item_type, sync_time = excluded.sync_time
            """, [target, id, type.rawValue, time])
    }

    func forget(id: String) throws {
        try db.run("DELETE FROM sync_items WHERE target_id = ? AND item_id = ?", [target, id])
    }

    func localItems(ids: [String]) throws -> [String: LocalItem] {
        guard !ids.isEmpty else { return [:] }
        let list = Store.jsonList(ids)
        var times: [String: Int64] = [:]
        for row in try db.query("SELECT item_id, sync_time FROM sync_items WHERE target_id = ? AND item_id IN (SELECT value FROM json_each(?))",
                                [target, list]) {
            times[row.string("item_id")] = row.int("sync_time")
        }
        var out: [String: LocalItem] = [:]
        for type in ModelType.syncable {
            guard let table = type.table else { continue }
            for row in try db.query("SELECT id, updated_time FROM \(table) WHERE id IN (SELECT value FROM json_each(?))", [list]) {
                let id = row.string("id")
                guard out[id] == nil else { continue }
                out[id] = LocalItem(type: type, updatedTime: row.int("updated_time"), syncTime: times[id])
            }
        }
        return out
    }

    func localItem(id: String) -> LocalItem? {
        (try? localItems(ids: [id]))?[id]
    }

    func isDirty(id: String) -> Bool {
        localItem(id: id)?.isDirty ?? false
    }

    func itemsToUpload() throws -> [UploadItem] {
        var out: [UploadItem] = []
        for type in Store.uploadOrder {
            guard let table = type.table else { continue }
            let rows = try db.query("""
                SELECT t.*, s.sync_time AS jn_sync_time FROM \(table) t
                LEFT JOIN sync_items s ON s.target_id = ? AND s.item_id = t.id
                WHERE t.encryption_applied = 0 AND (s.sync_time IS NULL OR t.updated_time != s.sync_time)
                ORDER BY t.updated_time
                """, [target])
            out += rows.map { UploadItem(type: type, row: $0) }
        }
        return out
    }

    func pendingDeletions() throws -> [PendingDeletion] {
        try db.query("""
            SELECT d.id, d.item_type, d.item_id,
                   EXISTS (SELECT 1 FROM sync_items s WHERE s.item_id = d.item_id AND s.target_id = ?) AS here,
                   EXISTS (SELECT 1 FROM sync_items s WHERE s.item_id = d.item_id AND s.target_id != ?) AS elsewhere
            FROM deleted_items d ORDER BY d.id
            """, [target, target]).map {
            PendingDeletion(rowId: $0.int("id"), type: $0.int("item_type"), itemId: $0.string("item_id"),
                            onTarget: $0.bool("here"), elsewhere: $0.bool("elsewhere"))
        }
    }

    func completeDeletion(_ deletion: PendingDeletion) throws {
        try forget(id: deletion.itemId)
        if !deletion.elsewhere {
            try db.run("DELETE FROM deleted_items WHERE id = ?", [deletion.rowId])
        }
    }

    func applyRemoteDeletion(id: String, type: ModelType) throws -> URL? {
        guard let table = type.table else { return nil }
        let file = type == .resource ? store.resource(id: id).map(store.url(for:)) : nil
        if type == .note { try db.run("DELETE FROM note_tags WHERE note_id = ?", [id]) }
        try db.run("DELETE FROM \(table) WHERE id = ?", [id])
        try forget(id: id)
        if type == .resource { try store.setBlobMissing(id, false) }
        if try db.scalarInt("SELECT COUNT(*) FROM sync_items WHERE item_id = ?", [id]) > 0 {
            try store.recordDeletion(type, id)
        }
        return file
    }
}
