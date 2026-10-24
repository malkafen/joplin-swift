import Foundation

public extension Store {
    func notes(filter: NoteFilter, sort: NoteSort, uncompletedTodosOnTop: Bool = true, showCompletedTodos: Bool = true) -> [NoteSummary] {
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

        var searchText: String?
        if case .search(let text) = filter, !Store.ftsQuery(text).isEmpty { searchText = text }

        var order: [String] = []
        if uncompletedTodosOnTop { order.append("(is_todo = 1 AND todo_completed = 0) DESC") }
        switch sort {
        case .updated: order.append("user_updated_time DESC")
        case .created: order.append("user_created_time DESC")
        case .title: order.append("title COLLATE NOCASE ASC")
        }
        let sql = """
        SELECT rowid, id, title, parent_id, is_todo, todo_completed, todo_due, user_updated_time, user_created_time, deleted_time,
               substr(body, 1, 400) AS snippet, octet_length(body) > \(Store.longNote) AS long
        FROM notes WHERE \(clauses.joined(separator: " AND ")) ORDER BY \(order.joined(separator: ", "))
        """
        let rows = rowsOrEmpty(sql, args)
        var summaries = rows.map(NoteSummary.init(row:))
        if let searchText { snippetSearchResults(&summaries, rows: rows, search: searchText) }
        return summaries
    }

    internal static let snippetRows = 200

    internal func snippetSearchResults(_ summaries: inout [NoteSummary], rows: [Row], search: String) {
        let words = search.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'*")) }
        guard words.allSatisfy({ $0.count >= 3 }) else { return }
        let first = rows.indices.prefix(Store.snippetRows)
        let short = first.filter { rows[$0].int("long") == 0 }
        if !short.isEmpty {
            let index = Dictionary(uniqueKeysWithValues: short.map { (rows[$0].int("rowid"), $0) })
            let sql = """
            SELECT rowid, snippet(notes_fts, 1, '', '', '…', 24) AS snippet FROM notes_fts
            WHERE notes_fts MATCH ? AND rowid IN (\(index.keys.map(String.init).joined(separator: ",")))
            """
            for row in rowsOrEmpty(sql, [Store.ftsQuery(search)]) {
                guard let i = index[row.int("rowid")], !row.string("snippet").isEmpty else { continue }
                summaries[i].snippet = Snippet.make(from: row.string("snippet"))
            }
        }
        for i in first where rows[i].int("long") != 0 {
            summaries[i].snippet = Snippet.make(from: excerpt(noteId: summaries[i].id, around: search))
        }
    }

    internal static let longNote = 50_000

    internal func excerpt(noteId: String, around search: String) -> String {
        let words = search.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'*")) }
            .filter { !$0.isEmpty }
        var spellings: [String] = []
        for w in words {
            for s in [w, w.lowercased(), w.capitalized, w.uppercased()] where !spellings.contains(s) { spellings.append(s) }
        }
        for s in spellings {
            guard let found = try? db.query("SELECT instr(body, ?) AS p FROM notes WHERE id = ?", [s, noteId]).first?.int("p"),
                  found > 0 else { continue }
            let start = max(1, found - 80)
            guard let text = try? db.query("SELECT substr(body, ?, 401) AS t FROM notes WHERE id = ?", [start, noteId])
                .first?.string("t") else { break }
            let more = text.count > 400
            return (start > 1 ? "…" : "") + (more ? String(text.prefix(400)) : text) + (more ? "…" : "")
        }
        guard let body = try? db.query("SELECT substr(body, 1, 200000) AS body FROM notes WHERE id = ?", [noteId])
            .first?.string("body") else { return "" }
        let ns = body as NSString
        let first = words.map { ns.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }
            .filter { $0.location != NSNotFound }
            .min { $0.location < $1.location }
        guard let first else { return ns.substring(to: min(400, ns.length)) }
        let start = ns.rangeOfComposedCharacterSequence(at: max(0, first.location - 80)).location
        let end = min(ns.length, start + 400)
        let text = ns.substring(with: ns.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start)))
        return (start > 0 ? "…" : "") + text + (end < ns.length ? "…" : "")
    }

    internal static func ftsQuery(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
            .joined(separator: " ")
    }
}
