import Foundation

public extension Store {
    func folders(deleted: Bool = false) -> [Folder] {
        let clause = deleted ? "deleted_time > 0" : "deleted_time = 0 AND encryption_applied = 0"
        let rows = rowsOrEmpty("SELECT * FROM folders WHERE \(clause)")
        return rows.map(Folder.init(row:)).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func folder(id: String) -> Folder? {
        row(.folder, id: id).map(Folder.init(row:))
    }

    func noteCountsByFolder() -> [String: Int] {
        let rows = rowsOrEmpty("SELECT parent_id, COUNT(*) AS c FROM notes WHERE deleted_time = 0 AND is_conflict = 0 GROUP BY parent_id")
        var out: [String: Int] = [:]
        for r in rows { out[r.string("parent_id")] = Int(r.int("c")) }
        return out
    }

    @discardableResult
    func createFolder(title: String, parentId: String = "") throws -> Folder {
        let now = Store.now()
        let id = Store.newId()
        try upsert(.folder, [
            "id": id, "title": title, "parent_id": parentId,
            "created_time": now, "updated_time": now, "user_created_time": now, "user_updated_time": now,
        ])
        return folder(id: id)!
    }

    func renameFolder(id: String, title: String) throws {
        let now = Store.now()
        try db.run("UPDATE folders SET title = ?, updated_time = ?, user_updated_time = ? WHERE id = ?", [title, now, now, id])
    }

    func moveFolder(id: String, toParent parentId: String) throws {
        guard id != parentId, !descendantFolderIds(of: id).contains(parentId) else { return }
        let now = Store.now()
        try db.run("UPDATE folders SET parent_id = ?, updated_time = ?, user_updated_time = ? WHERE id = ?", [parentId, now, now, id])
    }

    func descendantFolderIds(of id: String) -> [String] {
        var result: [String] = []
        var queue = [id]
        while let current = queue.popLast() {
            let children = rowsOrEmpty("SELECT id FROM folders WHERE parent_id = ?", [current]).map { $0.string("id") }
            result.append(contentsOf: children)
            queue.append(contentsOf: children)
        }
        return result
    }

    func trashFolder(id: String) throws {
        let now = Store.now()
        let ids = [id] + descendantFolderIds(of: id)
        let ph = Store.placeholders(ids.count)
        try db.transaction {
            try db.run("UPDATE folders SET deleted_time = ?, updated_time = ? WHERE id IN (\(ph)) AND deleted_time = 0", [now, now] + ids)
            try db.run("UPDATE notes SET deleted_time = ?, updated_time = ? WHERE parent_id IN (\(ph)) AND deleted_time = 0", [now, now] + ids)
        }
    }

    func restoreFolder(id: String) throws {
        let now = Store.now()
        let ids = [id] + descendantFolderIds(of: id)
        let ph = Store.placeholders(ids.count)
        try db.transaction {
            try restoreFolderChain(startingAt: folder(id: id)?.parentId ?? "", now: now)
            try db.run("UPDATE folders SET deleted_time = 0, updated_time = ? WHERE id IN (\(ph))", [now] + ids)
            try db.run("UPDATE notes SET deleted_time = 0, updated_time = ? WHERE parent_id IN (\(ph))", [now] + ids)
        }
    }

    internal func restoreFolderChain(startingAt id: String, now: Int64) throws {
        var current = id
        var seen = Set<String>()
        while !current.isEmpty, !seen.contains(current), let f = folder(id: current) {
            seen.insert(current)
            if f.deletedTime > 0 {
                try db.run("UPDATE folders SET deleted_time = 0, updated_time = ? WHERE id = ?", [now, current])
            }
            current = f.parentId
        }
    }

    func deleteFolderPermanently(id: String) throws {
        let ids = [id] + descendantFolderIds(of: id)
        let ph = Store.placeholders(ids.count)
        let noteIds = rowsOrEmpty("SELECT id FROM notes WHERE parent_id IN (\(ph))", ids).map { $0.string("id") }
        try db.transaction {
            try deleteNotesPermanentlyInTransaction(noteIds)
            try db.run("DELETE FROM folders WHERE id IN (\(ph))", ids)
            for fid in ids { try recordDeletion(.folder, fid) }
        }
    }

    func defaultFolderId() throws -> String {
        if let f = folders().first { return f.id }
        return try createFolder(title: "Notes").id
    }
}
