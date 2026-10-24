import Foundation

public extension Store {
    func note(id: String) -> Note? {
        row(.note, id: id).map(Note.init(row:))
    }

    var totalNoteCount: Int {
        intOrZero("SELECT COUNT(*) FROM notes WHERE deleted_time = 0 AND is_conflict = 0")
    }

    var trashedNoteCount: Int {
        intOrZero("SELECT COUNT(*) FROM notes WHERE deleted_time > 0 AND encryption_applied = 0")
    }

    @discardableResult
    func createNote(parentId: String, title: String = "", body: String = "", isTodo: Bool = false) throws -> Note {
        let now = Store.now()
        let id = Store.newId()
        try upsert(.note, [
            "id": id, "parent_id": parentId, "title": title, "body": body, "is_todo": isTodo ? 1 : 0,
            "created_time": now, "updated_time": now, "user_created_time": now, "user_updated_time": now,
            "source_application": "io.github.malkafen.JoplinNative", "markup_language": 1,
        ])
        return note(id: id)!
    }

    func saveNote(_ note: Note, at time: Int64 = Store.now()) throws {
        try Store.saveNote(note, in: db, at: time)
    }

    struct BodyStamp: Equatable, Sendable {
        public var updatedTime: Int64
        public var size: Int64

        public init(updatedTime: Int64, body: String) {
            self.updatedTime = updatedTime
            size = Int64(body.utf8.count)
        }

        init(updatedTime: Int64, size: Int64) {
            self.updatedTime = updatedTime
            self.size = size
        }
    }

    func noteAndStamp(id: String) -> (note: Note, stamp: BodyStamp)? {
        guard let row = row(.note, id: id) else { return nil }
        let note = Note(row: row)
        return (note, BodyStamp(updatedTime: row.int("updated_time"), body: note.body))
    }

    func bodyStamp(id: String) -> BodyStamp? {
        guard let row = try? db.query("SELECT updated_time, octet_length(body) AS size FROM notes WHERE id = ?", [id]).first
        else { return nil }
        return BodyStamp(updatedTime: row.int("updated_time"), size: row.int("size"))
    }

    func noteWithoutBody(id: String) -> Note? {
        let sql = """
            SELECT id, parent_id, title, '' AS body, is_todo, todo_completed, todo_due, source_url, author, markup_language,
                   is_conflict, created_time, user_created_time, user_updated_time, deleted_time, encryption_applied
            FROM notes WHERE id = ?
            """
        return (try? db.query(sql, [id]).first).map(Note.init(row:))
    }

    static func saveNote(_ note: Note, in db: SQLiteDB, at now: Int64 = Store.now()) throws {
        let title = note.title.replacingOccurrences(of: "\n", with: " ")
        try db.run("""
            UPDATE notes SET title = ?, body = ?, is_todo = ?, todo_completed = ?, todo_due = ?, parent_id = ?, source_url = ?,
                   updated_time = ?, user_updated_time = ?
            WHERE id = ?
            """, [title, note.body, note.isTodo ? 1 : 0, note.todoCompleted, note.todoDue, note.parentId, note.sourceUrl, now, now, note.id])
    }

    func moveNotes(ids: [String], toFolder folderId: String) throws {
        guard !ids.isEmpty else { return }
        let now = Store.now()
        try db.run("UPDATE notes SET parent_id = ?, updated_time = ?, user_updated_time = ? WHERE id IN (\(Store.placeholders(ids.count)))",
                   [folderId, now, now] + ids)
    }

    func setTodoCompleted(id: String, completed: Bool) throws {
        let now = Store.now()
        try db.run("UPDATE notes SET todo_completed = ?, updated_time = ?, user_updated_time = ? WHERE id = ?",
                   [completed ? now : 0, now, now, id])
    }

    func setIsTodo(ids: [String], isTodo: Bool) throws {
        guard !ids.isEmpty else { return }
        let now = Store.now()
        try db.run("UPDATE notes SET is_todo = ?, todo_completed = 0, updated_time = ?, user_updated_time = ? WHERE id IN (\(Store.placeholders(ids.count)))",
                   [isTodo ? 1 : 0, now, now] + ids)
    }

    @discardableResult
    func duplicateNote(id: String) throws -> Note? {
        guard let original = row(.note, id: id) else { return nil }
        var fields = original.values
        let now = Store.now()
        let newId = Store.newId()
        fields["id"] = newId
        fields["title"] = "\(original.string("title")) - Copy"
        for key in ["created_time", "updated_time", "user_created_time", "user_updated_time"] { fields[key] = now }
        try upsert(.note, fields)
        for tag in tags(forNote: id) { try addTag(tagId: tag.id, toNote: newId) }
        return note(id: newId)
    }

    func trashNotes(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let now = Store.now()
        try db.run("UPDATE notes SET deleted_time = ?, updated_time = ? WHERE id IN (\(Store.placeholders(ids.count)))", [now, now] + ids)
    }

    func restoreNotes(ids: [String]) throws {
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

    func deleteNotesPermanently(ids: [String]) throws {
        try db.transaction { try deleteNotesPermanentlyInTransaction(ids) }
    }

    internal func deleteNotesPermanentlyInTransaction(_ ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let ph = Store.placeholders(ids.count)
        let links = rowsOrEmpty("SELECT id FROM note_tags WHERE note_id IN (\(ph))", ids).map { $0.string("id") }
        try db.run("DELETE FROM note_tags WHERE note_id IN (\(ph))", ids)
        try db.run("DELETE FROM notes WHERE id IN (\(ph))", ids)
        for id in links { try recordDeletion(.noteTag, id) }
        for id in ids { try recordDeletion(.note, id) }
    }

    func emptyTrash() throws {
        let noteIds = rowsOrEmpty("SELECT id FROM notes WHERE deleted_time > 0").map { $0.string("id") }
        let folderIds = rowsOrEmpty("SELECT id FROM folders WHERE deleted_time > 0").map { $0.string("id") }
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
}
