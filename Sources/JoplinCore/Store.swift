import Foundation
import UniformTypeIdentifiers

/// Local note database. All access is synchronous and expected on the main thread.
public final class Store {
    public let db: SQLiteDB
    public let directory: URL
    public let resourceDirectory: URL

    public init(directory: URL) throws {
        self.directory = directory
        resourceDirectory = directory.appendingPathComponent("resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resourceDirectory, withIntermediateDirectories: true)
        db = try SQLiteDB(path: directory.appendingPathComponent("database.sqlite").path)
        try db.exec("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = OFF;")
        try Schema.migrate(db)
    }

    public static func now() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

    /// Joplin ids: 32 lowercase hex chars (uuid without dashes).
    public static func newId() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    // MARK: - Generic item access

    /// Inserts or updates an item. Missing columns get schema defaults on insert and are left untouched on update.
    public func upsert(_ type: ModelType, _ fields: [String: Any]) throws {
        guard let table = type.table, let defs = Schema.fields[type] else { return }
        var values = fields
        if !exists(type, id: fields["id"] as? String ?? "") {
            for def in defs where values[def.name] == nil && def.name != "id" {
                values[def.name] = def.defaultSQLValue
            }
        }
        let names = defs.map(\.name).filter { values[$0] != nil }
        let columns = names.map { "\"\($0)\"" }.joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: names.count).joined(separator: ", ")
        let updates = names.filter { $0 != "id" }.map { "\"\($0)\" = excluded.\"\($0)\"" }.joined(separator: ", ")
        let sql = updates.isEmpty
            ? "INSERT OR IGNORE INTO \(table) (\(columns)) VALUES (\(placeholders))"
            : "INSERT INTO \(table) (\(columns)) VALUES (\(placeholders)) ON CONFLICT(id) DO UPDATE SET \(updates)"
        try db.run(sql, names.map { values[$0] })
    }

    public func exists(_ type: ModelType, id: String) -> Bool {
        guard let table = type.table else { return false }
        return ((try? db.scalarInt("SELECT COUNT(*) FROM \(table) WHERE id = ?", [id])) ?? 0) > 0
    }

    public func row(_ type: ModelType, id: String) -> Row? {
        guard let table = type.table else { return nil }
        return try? db.query("SELECT * FROM \(table) WHERE id = ?", [id]).first
    }

    public func rows(_ type: ModelType, where clause: String = "1", _ args: [Any?] = []) throws -> [Row] {
        guard let table = type.table else { return [] }
        return try db.query("SELECT * FROM \(table) WHERE \(clause)", args)
    }

    private func recordDeletion(_ type: ModelType, _ id: String) throws {
        try db.run("INSERT INTO deleted_items (item_type, item_id, deleted_time) VALUES (?, ?, ?)", [type.rawValue, id, Store.now()])
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    // MARK: - Settings

    public func setting(_ key: String) -> String? {
        try? db.query("SELECT value FROM settings WHERE key = ?", [key]).first?.string("value")
    }

    public func setSetting(_ key: String, _ value: String) {
        try? db.run("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [key, value])
    }

    // MARK: - Folders

    /// Sorted like Finder: case-insensitive, numbers by value ("Folder 2" before "Folder 10").
    public func folders(deleted: Bool = false) -> [Folder] {
        let clause = deleted ? "deleted_time > 0" : "deleted_time = 0 AND encryption_applied = 0"
        let rows = (try? db.query("SELECT * FROM folders WHERE \(clause)")) ?? []
        return rows.map(Folder.init(row:)).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    public func folder(id: String) -> Folder? {
        row(.folder, id: id).map(Folder.init(row:))
    }

    /// Number of non-deleted notes directly inside each folder.
    public func noteCountsByFolder() -> [String: Int] {
        let rows = (try? db.query("SELECT parent_id, COUNT(*) AS c FROM notes WHERE deleted_time = 0 AND is_conflict = 0 GROUP BY parent_id")) ?? []
        var out: [String: Int] = [:]
        for r in rows { out[r.string("parent_id")] = Int(r.int("c")) }
        return out
    }

    @discardableResult
    public func createFolder(title: String, parentId: String = "") throws -> Folder {
        let now = Store.now()
        let id = Store.newId()
        try upsert(.folder, [
            "id": id, "title": title, "parent_id": parentId,
            "created_time": now, "updated_time": now, "user_created_time": now, "user_updated_time": now,
        ])
        return folder(id: id)!
    }

    public func renameFolder(id: String, title: String) throws {
        let now = Store.now()
        try db.run("UPDATE folders SET title = ?, updated_time = ?, user_updated_time = ? WHERE id = ?", [title, now, now, id])
    }

    public func moveFolder(id: String, toParent parentId: String) throws {
        guard id != parentId, !descendantFolderIds(of: id).contains(parentId) else { return }
        let now = Store.now()
        try db.run("UPDATE folders SET parent_id = ?, updated_time = ?, user_updated_time = ? WHERE id = ?", [parentId, now, now, id])
    }

    public func descendantFolderIds(of id: String) -> [String] {
        var result: [String] = []
        var queue = [id]
        while let current = queue.popLast() {
            let children = ((try? db.query("SELECT id FROM folders WHERE parent_id = ?", [current])) ?? []).map { $0.string("id") }
            result.append(contentsOf: children)
            queue.append(contentsOf: children)
        }
        return result
    }

    /// Moves a folder, its sub-folders and their notes to the trash (Joplin's deleted_time).
    public func trashFolder(id: String) throws {
        let now = Store.now()
        let ids = [id] + descendantFolderIds(of: id)
        let ph = Store.placeholders(ids.count)
        try db.transaction {
            try db.run("UPDATE folders SET deleted_time = ?, updated_time = ? WHERE id IN (\(ph)) AND deleted_time = 0", [now, now] + ids)
            try db.run("UPDATE notes SET deleted_time = ?, updated_time = ? WHERE parent_id IN (\(ph)) AND deleted_time = 0", [now, now] + ids)
        }
    }

    public func restoreFolder(id: String) throws {
        let now = Store.now()
        let ids = [id] + descendantFolderIds(of: id)
        let ph = Store.placeholders(ids.count)
        try db.transaction {
            try restoreFolderChain(startingAt: folder(id: id)?.parentId ?? "", now: now)
            try db.run("UPDATE folders SET deleted_time = 0, updated_time = ? WHERE id IN (\(ph))", [now] + ids)
            try db.run("UPDATE notes SET deleted_time = 0, updated_time = ? WHERE parent_id IN (\(ph))", [now] + ids)
        }
    }

    private func restoreFolderChain(startingAt id: String, now: Int64) throws {
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

    public func deleteFolderPermanently(id: String) throws {
        let ids = [id] + descendantFolderIds(of: id)
        let ph = Store.placeholders(ids.count)
        let noteIds = ((try? db.query("SELECT id FROM notes WHERE parent_id IN (\(ph))", ids)) ?? []).map { $0.string("id") }
        try db.transaction {
            try deleteNotesPermanentlyInTransaction(noteIds)
            try db.run("DELETE FROM folders WHERE id IN (\(ph))", ids)
            for fid in ids { try recordDeletion(.folder, fid) }
        }
    }

    // MARK: - Notes

    public func notes(filter: NoteFilter, sort: NoteSort, uncompletedTodosOnTop: Bool = true, showCompletedTodos: Bool = true) -> [NoteSummary] {
        var clauses: [String] = []
        var args: [Any?] = []
        switch filter {
        case .all:
            clauses.append("deleted_time = 0 AND is_conflict = 0")
        case .folder(let id):
            clauses.append("parent_id = ? AND deleted_time = 0 AND is_conflict = 0")
            args.append(id)
        case .tag(let id):
            clauses.append("id IN (SELECT note_id FROM note_tags WHERE tag_id = ?) AND deleted_time = 0")
            args.append(id)
        case .trash:
            clauses.append("deleted_time > 0")
        case .search(let text):
            let q = Store.ftsQuery(text)
            if q.isEmpty {
                clauses.append("deleted_time = 0 AND is_conflict = 0")
            } else {
                clauses.append("rowid IN (SELECT rowid FROM notes_fts WHERE notes_fts MATCH ?) AND deleted_time = 0")
                args.append(q)
            }
        }
        if !showCompletedTodos { clauses.append("NOT (is_todo = 1 AND todo_completed > 0)") }
        clauses.append("encryption_applied = 0")

        // Search results show the text around the first match instead of the start of the note.
        var snippet = "substr(body, 1, 400)"
        if case .search(let text) = filter, !Store.ftsQuery(text).isEmpty {
            snippet = """
            COALESCE(NULLIF((SELECT snippet(notes_fts, 1, '', '', '…', 24) FROM notes_fts
                             WHERE notes_fts MATCH ? AND notes_fts.rowid = notes.rowid), ''), substr(body, 1, 400))
            """
            args.insert(Store.ftsQuery(text), at: 0)
        }

        var order: [String] = []
        if uncompletedTodosOnTop { order.append("(is_todo = 1 AND todo_completed = 0) DESC") }
        switch sort {
        case .updated: order.append("user_updated_time DESC")
        case .created: order.append("user_created_time DESC")
        case .title: order.append("title COLLATE NOCASE ASC")
        }
        let sql = """
        SELECT id, title, parent_id, is_todo, todo_completed, todo_due, user_updated_time, user_created_time, deleted_time,
               \(snippet) AS snippet
        FROM notes WHERE \(clauses.joined(separator: " AND ")) ORDER BY \(order.joined(separator: ", "))
        """
        return ((try? db.query(sql, args)) ?? []).map(NoteSummary.init(row:))
    }

    static func ftsQuery(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
            .joined(separator: " ")
    }

    public func note(id: String) -> Note? {
        row(.note, id: id).map(Note.init(row:))
    }

    public var totalNoteCount: Int {
        Int((try? db.scalarInt("SELECT COUNT(*) FROM notes WHERE deleted_time = 0 AND is_conflict = 0")) ?? 0)
    }

    /// Notes listed in the trash.
    public var trashedNoteCount: Int {
        Int((try? db.scalarInt("SELECT COUNT(*) FROM notes WHERE deleted_time > 0 AND encryption_applied = 0")) ?? 0)
    }

    @discardableResult
    public func createNote(parentId: String, title: String = "", body: String = "", isTodo: Bool = false) throws -> Note {
        let now = Store.now()
        let id = Store.newId()
        try upsert(.note, [
            "id": id, "parent_id": parentId, "title": title, "body": body, "is_todo": isTodo ? 1 : 0,
            "created_time": now, "updated_time": now, "user_created_time": now, "user_updated_time": now,
            "source_application": "io.github.malkafen.JoplinNative", "markup_language": 1,
        ])
        return note(id: id)!
    }

    /// Saves user-editable fields and bumps the modification times.
    public func saveNote(_ note: Note) throws {
        let now = Store.now()
        let title = note.title.replacingOccurrences(of: "\n", with: " ")
        try db.run("""
            UPDATE notes SET title = ?, body = ?, is_todo = ?, todo_completed = ?, todo_due = ?, parent_id = ?, source_url = ?,
                   updated_time = ?, user_updated_time = ?
            WHERE id = ?
            """, [title, note.body, note.isTodo ? 1 : 0, note.todoCompleted, note.todoDue, note.parentId, note.sourceUrl, now, now, note.id])
    }

    public func moveNotes(ids: [String], toFolder folderId: String) throws {
        guard !ids.isEmpty else { return }
        let now = Store.now()
        try db.run("UPDATE notes SET parent_id = ?, updated_time = ?, user_updated_time = ? WHERE id IN (\(Store.placeholders(ids.count)))",
                   [folderId, now, now] + ids)
    }

    public func setTodoCompleted(id: String, completed: Bool) throws {
        let now = Store.now()
        try db.run("UPDATE notes SET todo_completed = ?, updated_time = ?, user_updated_time = ? WHERE id = ?",
                   [completed ? now : 0, now, now, id])
    }

    public func setIsTodo(ids: [String], isTodo: Bool) throws {
        guard !ids.isEmpty else { return }
        let now = Store.now()
        try db.run("UPDATE notes SET is_todo = ?, todo_completed = 0, updated_time = ?, user_updated_time = ? WHERE id IN (\(Store.placeholders(ids.count)))",
                   [isTodo ? 1 : 0, now, now] + ids)
    }

    @discardableResult
    public func duplicateNote(id: String) throws -> Note? {
        guard var fields = row(.note, id: id)?.values else { return nil }
        let now = Store.now()
        let newId = Store.newId()
        fields["id"] = newId
        fields["title"] = "\(fields["title"] as? String ?? "") - Copy"
        for key in ["created_time", "updated_time", "user_created_time", "user_updated_time"] { fields[key] = now }
        try upsert(.note, fields)
        for tag in tags(forNote: id) { try addTag(tagId: tag.id, toNote: newId) }
        return note(id: newId)
    }

    public func trashNotes(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let now = Store.now()
        try db.run("UPDATE notes SET deleted_time = ?, updated_time = ? WHERE id IN (\(Store.placeholders(ids.count)))", [now, now] + ids)
    }

    public func restoreNotes(ids: [String]) throws {
        let now = Store.now()
        try db.transaction {
            for id in ids {
                guard let n = note(id: id) else { continue }
                if !n.parentId.isEmpty, folder(id: n.parentId) != nil {
                    try restoreFolderChain(startingAt: n.parentId, now: now)
                } else if !n.parentId.isEmpty {
                    try db.run("UPDATE notes SET parent_id = ? WHERE id = ?", [try defaultFolderId(), id])
                }
                try db.run("UPDATE notes SET deleted_time = 0, updated_time = ? WHERE id = ?", [now, id])
            }
        }
    }

    public func deleteNotesPermanently(ids: [String]) throws {
        try db.transaction { try deleteNotesPermanentlyInTransaction(ids) }
    }

    private func deleteNotesPermanentlyInTransaction(_ ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let ph = Store.placeholders(ids.count)
        let links = ((try? db.query("SELECT id FROM note_tags WHERE note_id IN (\(ph))", ids)) ?? []).map { $0.string("id") }
        try db.run("DELETE FROM note_tags WHERE note_id IN (\(ph))", ids)
        try db.run("DELETE FROM notes WHERE id IN (\(ph))", ids)
        for id in links { try recordDeletion(.noteTag, id) }
        for id in ids { try recordDeletion(.note, id) }
    }

    public func emptyTrash() throws {
        let noteIds = ((try? db.query("SELECT id FROM notes WHERE deleted_time > 0")) ?? []).map { $0.string("id") }
        let folderIds = ((try? db.query("SELECT id FROM folders WHERE deleted_time > 0")) ?? []).map { $0.string("id") }
        try db.transaction {
            try deleteNotesPermanentlyInTransaction(noteIds)
            for id in folderIds {
                let remaining = try db.scalarInt("SELECT COUNT(*) FROM notes WHERE parent_id = ?", [id])
                    + db.scalarInt("SELECT COUNT(*) FROM folders WHERE parent_id = ? AND deleted_time = 0", [id])
                guard remaining == 0 else { continue }
                try db.run("DELETE FROM folders WHERE id = ?", [id])
                try recordDeletion(.folder, id)
            }
        }
    }

    /// First non-deleted folder, creating one when the database is empty.
    public func defaultFolderId() throws -> String {
        if let f = folders().first { return f.id }
        return try createFolder(title: "Notes").id
    }

    // MARK: - Tags

    public func tags() -> [Tag] {
        let sql = """
        SELECT tags.id, tags.title, COUNT(notes.id) AS c FROM tags
        LEFT JOIN note_tags ON note_tags.tag_id = tags.id
        LEFT JOIN notes ON notes.id = note_tags.note_id AND notes.deleted_time = 0
        WHERE tags.encryption_applied = 0
        GROUP BY tags.id ORDER BY tags.title COLLATE NOCASE
        """
        return ((try? db.query(sql)) ?? []).map { Tag(id: $0.string("id"), title: $0.string("title"), noteCount: Int($0.int("c"))) }
    }

    public func tags(forNote noteId: String) -> [Tag] {
        let sql = """
        SELECT tags.id, tags.title FROM tags JOIN note_tags ON note_tags.tag_id = tags.id
        WHERE note_tags.note_id = ? ORDER BY tags.title COLLATE NOCASE
        """
        return ((try? db.query(sql, [noteId])) ?? []).map { Tag(id: $0.string("id"), title: $0.string("title"), noteCount: 0) }
    }

    public func addTag(tagId: String, toNote noteId: String) throws {
        let exists = try db.scalarInt("SELECT COUNT(*) FROM note_tags WHERE note_id = ? AND tag_id = ?", [noteId, tagId])
        guard exists == 0 else { return }
        let now = Store.now()
        try upsert(.noteTag, [
            "id": Store.newId(), "note_id": noteId, "tag_id": tagId,
            "created_time": now, "updated_time": now, "user_created_time": now, "user_updated_time": now,
        ])
    }

    /// Replaces the note's tags with the given titles (case-insensitive, Joplin stores tag titles lowercased).
    public func setTags(noteId: String, titles: [String]) throws {
        let wanted = Array(Set(titles.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }))
        try db.transaction {
            var wantedIds: [String] = []
            for title in wanted {
                if let existing = try db.query("SELECT id FROM tags WHERE title = ? COLLATE NOCASE", [title]).first {
                    wantedIds.append(existing.string("id"))
                } else {
                    let now = Store.now()
                    let id = Store.newId()
                    try upsert(.tag, ["id": id, "title": title, "created_time": now, "updated_time": now,
                                      "user_created_time": now, "user_updated_time": now])
                    wantedIds.append(id)
                }
            }
            for link in try db.query("SELECT id, tag_id FROM note_tags WHERE note_id = ?", [noteId]) where !wantedIds.contains(link.string("tag_id")) {
                try db.run("DELETE FROM note_tags WHERE id = ?", [link.string("id")])
                try recordDeletion(.noteTag, link.string("id"))
            }
            for tagId in wantedIds { try addTag(tagId: tagId, toNote: noteId) }
        }
    }

    public func renameTag(id: String, title: String) throws {
        let now = Store.now()
        try db.run("UPDATE tags SET title = ?, updated_time = ?, user_updated_time = ? WHERE id = ?", [title.lowercased(), now, now, id])
    }

    public func deleteTag(id: String) throws {
        try db.transaction {
            for link in try db.query("SELECT id FROM note_tags WHERE tag_id = ?", [id]) {
                try recordDeletion(.noteTag, link.string("id"))
            }
            try db.run("DELETE FROM note_tags WHERE tag_id = ?", [id])
            try db.run("DELETE FROM tags WHERE id = ?", [id])
            try recordDeletion(.tag, id)
        }
    }

    // MARK: - Resources

    public func resource(id: String) -> Resource? {
        row(.resource, id: id).map(Resource.init(row:))
    }

    public func url(for resource: Resource) -> URL {
        resourceDirectory.appendingPathComponent(resource.storageName)
    }

    @discardableResult
    public func addResource(fileAt source: URL) throws -> Resource {
        let ext = source.pathExtension.lowercased()
        let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        return try addResource(filename: source.lastPathComponent, mime: mime, fileExtension: ext) { dest in
            try FileManager.default.copyItem(at: source, to: dest)
        }
    }

    @discardableResult
    public func addResource(data: Data, filename: String, mime: String, fileExtension: String) throws -> Resource {
        try addResource(filename: filename, mime: mime, fileExtension: fileExtension) { dest in
            try data.write(to: dest)
        }
    }

    private func addResource(filename: String, mime: String, fileExtension: String, write: (URL) throws -> Void) throws -> Resource {
        let id = Store.newId()
        let now = Store.now()
        let storage = fileExtension.isEmpty ? id : "\(id).\(fileExtension)"
        let dest = resourceDirectory.appendingPathComponent(storage)
        try write(dest)
        let size = ((try? FileManager.default.attributesOfItem(atPath: dest.path))?[.size] as? NSNumber)?.int64Value ?? -1
        try upsert(.resource, [
            "id": id, "title": filename, "filename": filename, "mime": mime, "file_extension": fileExtension, "size": size,
            "created_time": now, "updated_time": now, "user_created_time": now, "user_updated_time": now, "blob_updated_time": now,
        ])
        return resource(id: id)!
    }
}
