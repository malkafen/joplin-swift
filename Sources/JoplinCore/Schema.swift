import Foundation

public enum ModelType: Int, CaseIterable, Sendable {
    case note = 1
    case folder = 2
    case setting = 3
    case resource = 4
    case tag = 5
    case noteTag = 6
    case masterKey = 9
    case revision = 13

    public static let syncable: [ModelType] = [.folder, .note, .tag, .noteTag, .resource]

    public var table: String? {
        switch self {
        case .note: return "notes"
        case .folder: return "folders"
        case .tag: return "tags"
        case .noteTag: return "note_tags"
        case .resource: return "resources"
        default: return nil
        }
    }
}

public enum FieldType: Sendable {
    case int, text, numeric
}

public struct FieldDef: Sendable {
    public let name: String
    public let type: FieldType
    public let defaultValue: String

    public var defaultSQLValue: Any {
        switch type {
        case .int: return Int64(defaultValue) ?? 0
        case .numeric: return Double(defaultValue) ?? 0
        case .text: return defaultValue
        }
    }
}

private func t(_ name: String, _ def: String = "") -> FieldDef { FieldDef(name: name, type: .text, defaultValue: def) }
private func i(_ name: String, _ def: Int = 0) -> FieldDef { FieldDef(name: name, type: .int, defaultValue: String(def)) }
private func n(_ name: String) -> FieldDef { FieldDef(name: name, type: .numeric, defaultValue: "0") }

public enum Schema {
    public static let fields: [ModelType: [FieldDef]] = [
        .folder: [
            t("id"), t("title"), i("created_time"), i("updated_time"), i("user_created_time"), i("user_updated_time"),
            t("encryption_cipher_text"), i("encryption_applied"), t("parent_id"), i("is_shared"), t("share_id"),
            t("master_key_id"), t("icon"), t("user_data"), i("deleted_time"),
        ],
        .note: [
            t("id"), t("parent_id"), t("title"), t("body"), i("created_time"), i("updated_time"), i("is_conflict"),
            n("latitude"), n("longitude"), n("altitude"), t("author"), t("source_url"), i("is_todo"), i("todo_due"),
            i("todo_completed"), t("source"), t("source_application"), t("application_data"), i("order"),
            i("user_created_time"), i("user_updated_time"), t("encryption_cipher_text"), i("encryption_applied"),
            i("markup_language", 1), i("is_shared"), t("share_id"), t("conflict_original_id"), t("master_key_id"),
            t("user_data"), i("deleted_time"), i("is_locked"), t("extracted_resource_ids"),
        ],
        .tag: [
            t("id"), t("title"), i("created_time"), i("updated_time"), i("user_created_time"), i("user_updated_time"),
            t("encryption_cipher_text"), i("encryption_applied"), i("is_shared"), t("parent_id"), t("user_data"),
        ],
        .noteTag: [
            t("id"), t("note_id"), t("tag_id"), i("created_time"), i("updated_time"), i("user_created_time"),
            i("user_updated_time"), t("encryption_cipher_text"), i("encryption_applied"), i("is_shared"),
        ],
        .resource: [
            t("id"), t("title"), t("mime"), t("filename"), i("created_time"), i("updated_time"), i("user_created_time"),
            i("user_updated_time"), t("file_extension"), t("encryption_cipher_text"), i("encryption_applied"),
            i("encryption_blob_encrypted"), i("size", -1), i("is_shared"), t("share_id"), t("master_key_id"),
            t("user_data"), i("blob_updated_time"), t("ocr_text"), t("ocr_details"), i("ocr_status"), t("ocr_error"),
            i("ocr_driver_id"), i("is_locked"),
        ],
    ]

    public static func field(_ type: ModelType, _ name: String) -> FieldDef? {
        fields[type]?.first { $0.name == name }
    }

    static var createSQL: String {
        var sql = ""
        for type in ModelType.syncable {
            guard let table = type.table, let defs = fields[type] else { continue }
            let columns = defs.map { def -> String in
                switch def.type {
                case .text where def.name == "id": return "\"id\" TEXT PRIMARY KEY"
                case .text: return "\"\(def.name)\" TEXT NOT NULL DEFAULT '\(def.defaultValue)'"
                case .int: return "\"\(def.name)\" INT NOT NULL DEFAULT \(def.defaultValue)"
                case .numeric: return "\"\(def.name)\" NUMERIC NOT NULL DEFAULT 0"
                }
            }
            sql += "CREATE TABLE IF NOT EXISTS \(table) (\(columns.joined(separator: ", ")));\n"
        }
        sql += """
        CREATE INDEX IF NOT EXISTS notes_parent_id ON notes (parent_id);
        CREATE INDEX IF NOT EXISTS notes_user_updated_time ON notes (user_updated_time);
        CREATE INDEX IF NOT EXISTS notes_deleted_time ON notes (deleted_time);
        CREATE INDEX IF NOT EXISTS folders_parent_id ON folders (parent_id);
        CREATE INDEX IF NOT EXISTS note_tags_note_id ON note_tags (note_id);
        CREATE INDEX IF NOT EXISTS note_tags_tag_id ON note_tags (tag_id);

        CREATE TABLE IF NOT EXISTS deleted_items (
            id INTEGER PRIMARY KEY,
            item_type INT NOT NULL,
            item_id TEXT NOT NULL,
            deleted_time INT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS settings (
            "key" TEXT PRIMARY KEY,
            "value" TEXT NOT NULL DEFAULT ''
        );

        CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(
            title, body, content='notes', content_rowid='rowid', tokenize='unicode61 remove_diacritics 2'
        );
        CREATE TRIGGER IF NOT EXISTS notes_fts_ai AFTER INSERT ON notes BEGIN
            INSERT INTO notes_fts(rowid, title, body) VALUES (new.rowid, new.title, new.body);
        END;
        CREATE TRIGGER IF NOT EXISTS notes_fts_ad AFTER DELETE ON notes BEGIN
            INSERT INTO notes_fts(notes_fts, rowid, title, body) VALUES ('delete', old.rowid, old.title, old.body);
        END;
        CREATE TRIGGER IF NOT EXISTS notes_fts_au AFTER UPDATE OF title, body ON notes BEGIN
            INSERT INTO notes_fts(notes_fts, rowid, title, body) VALUES ('delete', old.rowid, old.title, old.body);
            INSERT INTO notes_fts(rowid, title, body) VALUES (new.rowid, new.title, new.body);
        END;
        """
        return sql
    }

    static let migrations: [String] = [
        createSQL,
        """
        CREATE TABLE IF NOT EXISTS sync_items (
            item_id TEXT PRIMARY KEY,
            item_type INT NOT NULL,
            sync_time INT NOT NULL DEFAULT 0
        );
        """,
        """
        CREATE TABLE sync_targets (
            id INTEGER PRIMARY KEY,
            identity TEXT NOT NULL UNIQUE,
            cursor TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE sync_items_by_target (
            target_id INT NOT NULL,
            item_id TEXT NOT NULL,
            item_type INT NOT NULL,
            sync_time INT NOT NULL DEFAULT 0,
            PRIMARY KEY (target_id, item_id)
        ) WITHOUT ROWID;
        INSERT INTO sync_items_by_target (target_id, item_id, item_type, sync_time)
            SELECT 0, item_id, item_type, sync_time FROM sync_items;
        DROP TABLE sync_items;
        ALTER TABLE sync_items_by_target RENAME TO sync_items;
        CREATE INDEX sync_items_item_id ON sync_items (item_id);
        CREATE TABLE missing_blobs (resource_id TEXT PRIMARY KEY);
        """,
    ]

    public static var version: Int { migrations.count }

    static func migrate(_ db: SQLiteDB) throws {
        let current = Int(try db.scalarInt("PRAGMA user_version"))
        for (index, sql) in migrations.enumerated() where index >= current {
            try db.transaction {
                try db.exec(sql)
                try db.exec("PRAGMA user_version = \(index + 1)")
            }
        }
    }
}
