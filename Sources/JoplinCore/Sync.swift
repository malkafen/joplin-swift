import Foundation

public struct SyncReport: Sendable, Equatable, CustomStringConvertible {
    public var downloaded = 0
    public var uploaded = 0
    public var deletedLocally = 0
    public var deletedRemotely = 0
    public var conflicts = 0
    public var skipped = 0

    public init() {}

    public var description: String {
        var parts = ["downloaded \(downloaded)", "uploaded \(uploaded)"]
        if deletedLocally + deletedRemotely > 0 { parts.append("deleted \(deletedLocally + deletedRemotely)") }
        if conflicts > 0 { parts.append("conflicts \(conflicts)") }
        if skipped > 0 { parts.append("skipped \(skipped)") }
        return parts.joined(separator: ", ")
    }
}

public extension Store {
    static let uploadOrder: [ModelType] = [.folder, .tag, .resource, .note, .noteTag]

    func syncTime(id: String) -> Int64? {
        (try? db.query("SELECT sync_time FROM sync_items WHERE item_id = ?", [id]).first)?.int("sync_time")
    }

    func markSynced(_ type: ModelType, id: String, time: Int64) throws {
        try db.run("""
            INSERT INTO sync_items (item_id, item_type, sync_time) VALUES (?, ?, ?)
            ON CONFLICT(item_id) DO UPDATE SET item_type = excluded.item_type, sync_time = excluded.sync_time
            """, [id, type.rawValue, time])
    }

    func itemsToUpload() throws -> [(type: ModelType, row: Row)] {
        var out: [(ModelType, Row)] = []
        for type in Store.uploadOrder {
            guard let table = type.table else { continue }
            let rows = try db.query("""
                SELECT t.* FROM \(table) t LEFT JOIN sync_items s ON s.item_id = t.id
                WHERE t.encryption_applied = 0 AND (s.item_id IS NULL OR t.updated_time > s.sync_time)
                ORDER BY t.updated_time
                """)
            out += rows.map { (type, $0) }
        }
        return out
    }

    func pendingDeletions() throws -> [(rowId: Int64, type: Int64, itemId: String)] {
        try db.query("SELECT id, item_type, item_id FROM deleted_items ORDER BY id").map {
            ($0.int("id"), $0.int("item_type"), $0.string("item_id"))
        }
    }

    func clearDeletion(rowId: Int64) throws {
        try db.run("DELETE FROM deleted_items WHERE id = ?", [rowId])
    }

    func localType(of id: String) -> ModelType? {
        ModelType.syncable.first { exists($0, id: id) }
    }

    func applyRemoteDeletion(id: String) throws {
        guard let type = localType(of: id), let table = type.table else { return }
        if type == .resource, let r = resource(id: id) {
            try? FileManager.default.removeItem(at: url(for: r))
        }
        try db.transaction {
            if type == .note { try db.run("DELETE FROM note_tags WHERE note_id = ?", [id]) }
            try db.run("DELETE FROM \(table) WHERE id = ?", [id])
            try db.run("DELETE FROM sync_items WHERE item_id = ?", [id])
        }
    }

    func isDirty(id: String) -> Bool {
        guard let type = localType(of: id), let row = row(type, id: id) else { return false }
        guard let synced = syncTime(id: id) else { return true }
        return row.int("updated_time") > synced
    }
}

@MainActor
public final class SyncEngine {
    public static let supportedSyncVersion = 3
    static let cursorKey = "sync.delta_cursor"
    static let clientIdKey = "sync.client_id"

    let store: Store
    let client: JoplinServerClient

    public init(store: Store, client: JoplinServerClient) {
        self.store = store
        self.client = client
    }

    var clientId: String {
        if let id = store.setting(Self.clientIdKey), !id.isEmpty { return id }
        let id = Store.newId()
        store.setSetting(Self.clientIdKey, id)
        return id
    }

    static func isItemName(_ name: String) -> Bool {
        name.count == 35 && name.hasSuffix(".md") && name.prefix(32).allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    public func sync() async throws -> SyncReport {
        try await client.login()
        try await checkSyncInfo()
        let id = clientId
        try await client.acquireSyncLock(clientId: id)
        var report = SyncReport()
        do {
            try await pull(&report)
            try await pushDeletions(&report)
            try await push(&report)
        } catch {
            await client.releaseSyncLock(clientId: id)
            throw error
        }
        await client.releaseSyncLock(clientId: id)
        store.setSetting("sync.last_time", String(Store.now()))
        return report
    }

    func checkSyncInfo() async throws {
        guard let data = try await client.get("info.json") else {
            let info: [String: Any] = [
                "version": Self.supportedSyncVersion,
                "e2ee": ["value": false, "updatedTime": 0],
                "activeMasterKeyId": ["value": "", "updatedTime": 0],
                "masterKeys": [],
                "ppk": ["value": NSNull(), "updatedTime": 0],
                "appMinVersion": "3.0.0",
            ]
            try await client.put("info.json", try JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]))
            return
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SyncError.invalidResponse("info.json is not valid JSON")
        }
        let version = (obj["version"] as? NSNumber)?.intValue ?? 0
        if version > Self.supportedSyncVersion { throw SyncError.unsupportedSyncVersion(version) }
        if let e2ee = obj["e2ee"] as? [String: Any], (e2ee["value"] as? Bool) == true {
            throw SyncError.encryptionEnabled
        }
    }

    func pull(_ report: inout SyncReport) async throws {
        var cursor = store.setting(Self.cursorKey) ?? ""
        let pendingDeletes = Set(try store.pendingDeletions().map(\.itemId))
        while true {
            let page: DeltaPage
            do {
                page = try await client.delta(cursor: cursor)
            } catch SyncError.http(_, "resyncRequired", _) where !cursor.isEmpty {
                cursor = ""
                continue
            }
            var wanted: [String] = []
            for item in page.items where Self.isItemName(item.name) && item.change != .delete {
                let id = String(item.name.prefix(32))
                if !pendingDeletes.contains(id), !hasVersion(id: id, itemUpdatedTime: item.itemUpdatedTime), !wanted.contains(item.name) {
                    wanted.append(item.name)
                }
            }
            let contents = try await fetch(wanted)
            for item in page.items where Self.isItemName(item.name) {
                let id = String(item.name.prefix(32))
                if pendingDeletes.contains(id) { continue }
                if item.change == .delete {
                    guard store.localType(of: id) != nil else { continue }
                    if store.isDirty(id: id) { continue }
                    try store.applyRemoteDeletion(id: id)
                    report.deletedLocally += 1
                } else {
                    try await download(id: id, name: item.name, itemUpdatedTime: item.itemUpdatedTime,
                                       prefetched: contents[item.name], &report)
                }
            }
            cursor = page.cursor
            store.setSetting(Self.cursorKey, cursor)
            if !page.hasMore { break }
        }
    }

    static let parallelDownloads = 8

    func fetch(_ names: [String]) async throws -> [String: Data?] {
        let client = self.client
        var out: [String: Data?] = [:]
        try await withThrowingTaskGroup(of: (String, Data?).self) { group in
            var next = 0
            func start() {
                let name = names[next]
                next += 1
                group.addTask { (name, try await client.get(name)) }
            }
            while next < min(names.count, Self.parallelDownloads) { start() }
            while let (name, data) = try await group.next() {
                out[name] = .some(data)
                if next < names.count { start() }
            }
        }
        return out
    }

    private func hasVersion(id: String, itemUpdatedTime: Int64) -> Bool {
        guard itemUpdatedTime > 0, let type = store.localType(of: id) else { return false }
        return store.syncTime(id: id) == itemUpdatedTime || store.row(type, id: id)?.int("updated_time") == itemUpdatedTime
    }

    private func download(id: String, name: String, itemUpdatedTime: Int64, prefetched: Data?? = nil,
                          _ report: inout SyncReport) async throws {
        if itemUpdatedTime > 0, let type = store.localType(of: id) {
            if store.syncTime(id: id) == itemUpdatedTime { return }
            if store.row(type, id: id)?.int("updated_time") == itemUpdatedTime {
                try store.markSynced(type, id: id, time: itemUpdatedTime)
                return
            }
        }
        let content: Data?
        if let prefetched { content = prefetched } else { content = try await client.get(name) }
        guard let data = content, let text = String(data: data, encoding: .utf8) else { return }
        let type: ModelType
        var fields: [String: Any]
        do {
            (type, fields) = try Serializer.unserialize(text)
        } catch {
            report.skipped += 1
            return
        }
        guard (fields["id"] as? String) == id else {
            report.skipped += 1
            return
        }
        if (fields["encryption_applied"] as? Int64 ?? 0) != 0 {
            report.skipped += 1
            return
        }
        let remoteTime = fields["updated_time"] as? Int64 ?? 0
        if store.row(type, id: id) != nil, store.syncTime(id: id) == remoteTime { return }

        if let local = store.row(type, id: id), store.isDirty(id: id) {
            let localTime = local.int("updated_time")
            if localTime == remoteTime {
                try store.markSynced(type, id: id, time: remoteTime)
                return
            }
            if type == .note {
                if local.string("title") != (fields["title"] as? String ?? "") || local.string("body") != (fields["body"] as? String ?? "") {
                    try saveConflictCopy(of: local)
                    report.conflicts += 1
                }
            } else if localTime > remoteTime {
                return
            }
        }

        if type == .resource {
            let ext = fields["file_extension"] as? String ?? ""
            let storage = ext.isEmpty ? id : "\(id).\(ext)"
            if let blob = try await client.get(".resource/\(id)") {
                try blob.write(to: store.resourceDirectory.appendingPathComponent(storage), options: .atomic)
            }
        }
        try store.db.transaction {
            try store.upsert(type, fields)
            try store.markSynced(type, id: id, time: remoteTime)
        }
        report.downloaded += 1
    }

    private func saveConflictCopy(of local: Row) throws {
        var fields = local.values
        let now = Store.now()
        let newId = Store.newId()
        fields["id"] = newId
        fields["title"] = "\(local.string("title")) (conflict)"
        fields["conflict_original_id"] = local.string("id")
        fields["created_time"] = now
        fields["updated_time"] = now
        try store.upsert(.note, fields)
        for tag in store.tags(forNote: local.string("id")) { try store.addTag(tagId: tag.id, toNote: newId) }
    }

    func pushDeletions(_ report: inout SyncReport) async throws {
        for deletion in try store.pendingDeletions() {
            try await client.delete("\(deletion.itemId).md")
            if deletion.type == Int64(ModelType.resource.rawValue) {
                try await client.delete(".resource/\(deletion.itemId)")
            }
            try store.clearDeletion(rowId: deletion.rowId)
            try store.db.run("DELETE FROM sync_items WHERE item_id = ?", [deletion.itemId])
            report.deletedRemotely += 1
        }
    }

    func push(_ report: inout SyncReport) async throws {
        for (type, row) in try store.itemsToUpload() {
            let id = row.string("id")
            if type == .resource {
                let file = store.url(for: Resource(row: row))
                if let blob = try? Data(contentsOf: file) {
                    try await client.put(".resource/\(id)", blob)
                }
            }
            let text = try Serializer.serialize(type: type, fields: row.values)
            try await client.put("\(id).md", Data(text.utf8))
            try store.markSynced(type, id: id, time: row.int("updated_time"))
            report.uploaded += 1
        }
    }
}
