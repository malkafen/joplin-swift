import Foundation
import Testing
@testable import JoplinCore

@Suite struct SQLiteTests {
    private func memory() throws -> SQLiteDB { try SQLiteDB(path: ":memory:") }

    @Test func bindsAndReadsEveryType() throws {
        let db = try memory()
        try db.exec("CREATE TABLE t (a, b, c, d, e, f, g, h, i, j, k)")
        try db.run("INSERT INTO t VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", [
            nil, NSNull(), true, 7, Int64(8), Int32(9), 1.5, "text", Data([1, 2, 3]), URL(string: "https://x.y")!, false,
        ])
        let row = try #require(try db.query("SELECT * FROM t").first)
        #expect(row["a"] is NSNull)
        #expect(row["b"] is NSNull)
        #expect(row.int("c") == 1)
        #expect(row.int("d") == 7)
        #expect(row.int("e") == 8)
        #expect(row.int("f") == 9)
        #expect(row.double("g") == 1.5)
        #expect(row.string("h") == "text")
        #expect(row["i"] as? Data == Data([1, 2, 3]))
        #expect(row.string("j") == "https://x.y")
        #expect(row.int("k") == 0)
    }

    @Test func emptyBlob() throws {
        let row = try #require(try memory().query("SELECT x'' AS b").first)
        #expect(row["b"] as? Data == Data())
        try memory().run("SELECT ?", [Data()])
    }

    @Test func rowAccessorsConvert() {
        let row = Row(values: ["i": Int64(3), "d": 2.5, "s": "4", "sd": "1.25", "bad": "x", "n": NSNull()])
        #expect(row.string("i") == "3")
        #expect(row.string("d") == "2.5")
        #expect(row.string("n") == "")
        #expect(row.string("missing") == "")
        #expect(row.int("d") == 2)
        #expect(row.int("s") == 4)
        #expect(row.int("bad") == 0)
        #expect(row.int("n") == 0)
        #expect(row.double("i") == 3)
        #expect(row.double("sd") == 1.25)
        #expect(row.double("bad") == 0)
        #expect(row.double("n") == 0)
        #expect(row.bool("i"))
        #expect(!row.bool("missing"))
    }

    @Test func scalarInt() throws {
        let db = try memory()
        #expect(try db.scalarInt("SELECT 41 + ?", [1]) == 42)
        #expect(try db.scalarInt("SELECT 1 WHERE 0") == 0)
    }

    @Test func changesCount() throws {
        let db = try memory()
        try db.exec("CREATE TABLE t (x); INSERT INTO t VALUES (1), (2), (3);")
        try db.run("UPDATE t SET x = 0 WHERE x > 1")
        #expect(db.changes == 2)
    }

    @Test func transactionCommitsAndRollsBack() throws {
        let db = try memory()
        try db.exec("CREATE TABLE t (x)")
        let value = try db.transaction { () -> Int in
            try db.run("INSERT INTO t VALUES (1)")
            return 5
        }
        #expect(value == 5)
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try db.transaction {
                try db.run("INSERT INTO t VALUES (2)")
                throw Boom()
            }
        }
        #expect(try db.scalarInt("SELECT COUNT(*) FROM t") == 1)
    }

    @Test func nestedTransactionsUseSavepoints() throws {
        let db = try memory()
        try db.exec("CREATE TABLE t (x)")
        struct Boom: Error {}
        try db.transaction {
            try db.run("INSERT INTO t VALUES (1)")
            #expect(throws: Boom.self) {
                try db.transaction {
                    try db.run("INSERT INTO t VALUES (2)")
                    throw Boom()
                }
            }
            try db.transaction { try db.run("INSERT INTO t VALUES (3)") }
        }
        #expect(try db.query("SELECT x FROM t ORDER BY x").map { $0.int("x") } == [1, 3])
        #expect(throws: Boom.self) {
            try db.transaction {
                try db.transaction { try db.run("INSERT INTO t VALUES (4)") }
                throw Boom()
            }
        }
        #expect(try db.scalarInt("SELECT COUNT(*) FROM t") == 2)
    }

    @Test func statementsAreCachedAndEvicted() throws {
        let db = try memory()
        try db.exec("CREATE TABLE t (x)")
        for i in 0..<3 { try db.run("INSERT INTO t VALUES (?)", [i]) }
        #expect(db.cachedStatementCount == 1)
        #expect(try db.query("SELECT x FROM t WHERE x > ?", [0]).count == 2)
        #expect(try db.query("SELECT x FROM t WHERE x > ?", [1]).count == 1)
        #expect(db.cachedStatementCount == 2)
        for i in 0..<(SQLiteDB.statementCacheLimit * 2) { _ = try db.scalarInt("SELECT \(i)") }
        #expect(db.cachedStatementCount == SQLiteDB.statementCacheLimit)
        #expect(try db.query("SELECT x FROM t WHERE x > ?", [-1]).count == 3)
        #expect(throws: SQLiteError.self) { try db.query("SELEC broken") }
        #expect(db.cachedStatementCount == SQLiteDB.statementCacheLimit)
        try db.exec("DROP TABLE t; CREATE TABLE t (x, y); INSERT INTO t VALUES (9, 9)")
        #expect(try db.query("SELECT x FROM t WHERE x > ?", [-1]).map { $0.int("x") } == [9])
    }

    @Test func errors() throws {
        let db = try memory()
        let exec = #expect(throws: SQLiteError.self) { try db.exec("NOT SQL") }
        #expect(exec?.description.hasPrefix("SQLite step failed: ") == true)
        #expect(exec?.description.hasSuffix("— NOT SQL") == true)

        let prepare = #expect(throws: SQLiteError.self) { try db.query("SELEC 1") }
        #expect(prepare?.description.hasPrefix("SQLite prepare failed: ") == true)

        try db.exec("CREATE TABLE t (id PRIMARY KEY)")
        try db.run("INSERT INTO t VALUES (1)")
        let step = #expect(throws: SQLiteError.self) { try db.run("INSERT INTO t VALUES (1)") }
        #expect(step?.description.contains("UNIQUE") == true)

        #expect(throws: SQLiteError.self) { try db.query("SELECT abs(-9223372036854775807 - 1)") }
    }

    @Test func openErrors() throws {
        let missing = temporaryDirectory().appendingPathComponent("nope/db.sqlite").path
        let error = #expect(throws: SQLiteError.self) { try SQLiteDB(path: missing, readOnly: true) }
        #expect(error?.description.hasPrefix("SQLite open failed: \(missing)") == true)
    }

    @Test func readOnlyDatabase() throws {
        let path = temporaryDirectory().appendingPathComponent("db.sqlite").path
        try SQLiteDB(path: path).exec("CREATE TABLE t (x); INSERT INTO t VALUES (1);")
        let ro = try SQLiteDB(path: path, readOnly: true)
        #expect(try ro.scalarInt("SELECT x FROM t") == 1)
        #expect(throws: SQLiteError.self) { try ro.exec("INSERT INTO t VALUES (2)") }
    }
}

@Suite struct SchemaTests {
    @Test func tables() {
        #expect(ModelType.syncable.map(\.table) == ["folders", "notes", "tags", "note_tags", "resources"])
        #expect(ModelType.setting.table == nil)
        #expect(ModelType.masterKey.table == nil)
        #expect(ModelType.revision.table == nil)
        #expect(Set(Schema.fields.keys) == Set(ModelType.syncable))
    }

    @Test func fieldDefaults() {
        #expect(Schema.field(.note, "markup_language")?.defaultSQLValue as? Int64 == 1)
        #expect(Schema.field(.note, "latitude")?.defaultSQLValue as? Double == 0)
        #expect(Schema.field(.note, "title")?.defaultSQLValue as? String == "")
        #expect(Schema.field(.resource, "size")?.defaultSQLValue as? Int64 == -1)
        #expect(Schema.field(.note, "nope") == nil)
        #expect(Schema.field(.setting, "id") == nil)
        #expect(FieldDef(name: "x", type: .int, defaultValue: "bad").defaultSQLValue as? Int64 == 0)
        #expect(FieldDef(name: "x", type: .numeric, defaultValue: "bad").defaultSQLValue as? Double == 0)
    }

    @Test func migrationIsIdempotent() throws {
        let dir = temporaryDirectory()
        let first = try Store(directory: dir)
        try first.createFolder(title: "Keep")
        let second = try Store(directory: dir)
        #expect(try second.db.scalarInt("PRAGMA user_version") == Int64(Schema.version))
        #expect(second.folders().map(\.title) == ["Keep"])
    }

    private func legacyDatabase(version: Int) throws -> URL {
        let dir = temporaryDirectory()
        let db = try SQLiteDB(path: dir.appendingPathComponent("database.sqlite").path)
        for sql in Schema.migrations.prefix(version) { try db.exec(sql) }
        try db.exec("PRAGMA user_version = \(version)")
        try db.run("INSERT INTO folders (id, title, updated_time) VALUES (?, 'Old', 5)", [fixtureId(1)])
        try db.run("INSERT INTO folders (id, title, updated_time) VALUES (?, 'New', 6)", [fixtureId(2)])
        if version >= 2 {
            try db.run("INSERT INTO sync_items (item_id, item_type, sync_time) VALUES (?, 2, 5)", [fixtureId(1)])
            try db.run("INSERT INTO settings (key, value) VALUES ('sync.delta_cursor', 'c42')")
        }
        return dir
    }

    @Test func upgradesVersionOneDatabases() throws {
        let upgraded = try Store(directory: try legacyDatabase(version: 1))
        #expect(try upgraded.db.scalarInt("PRAGMA user_version") == Int64(Schema.version))
        let ledger = try upgraded.syncLedger(identity: "t")
        #expect(ledger.cursor == "")
        #expect(try ledger.itemsToUpload().map(\.id) == [fixtureId(1), fixtureId(2)])
    }

    @Test func upgradesVersionTwoDatabasesAndAdoptsTheirSyncState() throws {
        let upgraded = try Store(directory: try legacyDatabase(version: 2))
        #expect(try upgraded.db.scalarInt("PRAGMA user_version") == Int64(Schema.version))
        let ledger = try upgraded.syncLedger(identity: "first")
        #expect(ledger.cursor == "c42")
        #expect(ledger.syncTime(id: fixtureId(1)) == 5)
        #expect(try ledger.itemsToUpload().map(\.id) == [fixtureId(2)])
        #expect(upgraded.setting(Store.legacyCursorKey) == nil)

        let other = try upgraded.syncLedger(identity: "second")
        #expect(other.target != ledger.target)
        #expect(other.cursor == "")
        #expect(other.syncTime(id: fixtureId(1)) == nil)
        #expect(try upgraded.syncLedger(identity: "first").cursor == "c42")
    }

    @Test func tablesMatchSchema() throws {
        let store = try makeStore()
        for type in ModelType.syncable {
            let columns = try store.db.query("PRAGMA table_info(\(type.table!))").map { $0.string("name") }
            #expect(columns == Schema.fields[type]!.map(\.name), "\(type)")
        }
    }
}
