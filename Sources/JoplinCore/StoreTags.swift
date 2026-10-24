import Foundation

public extension Store {
    func tags() -> [Tag] {
        let sql = """
        SELECT tags.id, tags.title, COUNT(notes.id) AS c FROM tags
        LEFT JOIN note_tags ON note_tags.tag_id = tags.id
        LEFT JOIN notes ON notes.id = note_tags.note_id AND notes.deleted_time = 0
        WHERE tags.encryption_applied = 0
        GROUP BY tags.id ORDER BY tags.title COLLATE NOCASE
        """
        return rowsOrEmpty(sql).map { Tag(id: $0.string("id"), title: $0.string("title"), noteCount: Int($0.int("c"))) }
    }

    func tags(forNote noteId: String) -> [Tag] {
        let sql = """
        SELECT tags.id, tags.title FROM tags JOIN note_tags ON note_tags.tag_id = tags.id
        WHERE note_tags.note_id = ? ORDER BY tags.title COLLATE NOCASE
        """
        return rowsOrEmpty(sql, [noteId]).map { Tag(id: $0.string("id"), title: $0.string("title"), noteCount: 0) }
    }

    func addTag(tagId: String, toNote noteId: String) throws {
        let exists = try db.scalarInt("SELECT COUNT(*) FROM note_tags WHERE note_id = ? AND tag_id = ?", [noteId, tagId])
        guard exists == 0 else { return }
        let now = Store.now()
        try upsert(.noteTag, [
            "id": Store.newId(), "note_id": noteId, "tag_id": tagId,
            "created_time": now, "updated_time": now, "user_created_time": now, "user_updated_time": now,
        ])
    }

    func setTags(noteId: String, titles: [String]) throws {
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

    func renameTag(id: String, title: String) throws {
        let now = Store.now()
        try db.run("UPDATE tags SET title = ?, updated_time = ?, user_updated_time = ? WHERE id = ?", [title.lowercased(), now, now, id])
    }

    func deleteTag(id: String) throws {
        try db.transaction {
            for link in try db.query("SELECT id FROM note_tags WHERE tag_id = ?", [id]) {
                try recordDeletion(.noteTag, link.string("id"))
            }
            try db.run("DELETE FROM note_tags WHERE tag_id = ?", [id])
            try db.run("DELETE FROM tags WHERE id = ?", [id])
            try recordDeletion(.tag, id)
        }
    }
}
