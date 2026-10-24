import Foundation
import UniformTypeIdentifiers

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

    public static func newId() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    public func upsert(_ type: ModelType, _ fields: [String: Any]) throws {
        guard let id = fields["id"] as? String else { return }
        try upsert(type, fields, isNew: !exists(type, id: id))
    }

    func upsert(_ type: ModelType, _ fields: [String: Any], isNew: Bool) throws {
        guard let table = type.table, let defs = Schema.fields[type] else { return }
        var values = fields
        if isNew {
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
        return intOrZero("SELECT COUNT(*) FROM \(table) WHERE id = ?", [id]) > 0
    }

    public func row(_ type: ModelType, id: String) -> Row? {
        guard let table = type.table else { return nil }
        return try? db.query("SELECT * FROM \(table) WHERE id = ?", [id]).first
    }

    public func rows(_ type: ModelType, where clause: String = "1", _ args: [Any?] = []) throws -> [Row] {
        guard let table = type.table else { return [] }
        return try db.query("SELECT * FROM \(table) WHERE \(clause)", args)
    }

    func recordDeletion(_ type: ModelType, _ id: String) throws {
        try db.run("INSERT INTO deleted_items (item_type, item_id, deleted_time) VALUES (?, ?, ?)", [type.rawValue, id, Store.now()])
    }

    static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    func rowsOrEmpty(_ sql: String, _ args: [Any?] = []) -> [Row] {
        (try? db.query(sql, args)) ?? []
    }

    func intOrZero(_ sql: String, _ args: [Any?] = []) -> Int {
        Int((try? db.scalarInt(sql, args)) ?? 0)
    }

    public func setting(_ key: String) -> String? {
        try? db.query("SELECT value FROM settings WHERE key = ?", [key]).first?.string("value")
    }

    public func setSetting(_ key: String, _ value: String) {
        try? db.run("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [key, value])
    }

    public func makeWriter() throws -> SQLiteDB {
        try SQLiteDB(path: directory.appendingPathComponent("database.sqlite").path)
    }
}
