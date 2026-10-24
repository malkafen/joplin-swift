import Foundation
import SQLite3

public enum SQLiteError: Error, CustomStringConvertible {
    case open(String)
    case prepare(sql: String, message: String)
    case step(sql: String, message: String)

    public var description: String {
        switch self {
        case .open(let m): return "SQLite open failed: \(m)"
        case .prepare(let sql, let m): return "SQLite prepare failed: \(m) — \(sql)"
        case .step(let sql, let m): return "SQLite step failed: \(m) — \(sql)"
        }
    }
}

public struct Row {
    public let values: [String: Any]

    public subscript(key: String) -> Any? { values[key] }

    public func string(_ key: String) -> String {
        switch values[key] {
        case let v as String: return v
        case let v as Int64: return String(v)
        case let v as Double: return String(v)
        default: return ""
        }
    }

    public func int(_ key: String) -> Int64 {
        switch values[key] {
        case let v as Int64: return v
        case let v as Double: return Int64(v)
        case let v as String: return Int64(v) ?? 0
        default: return 0
        }
    }

    public func double(_ key: String) -> Double {
        switch values[key] {
        case let v as Double: return v
        case let v as Int64: return Double(v)
        case let v as String: return Double(v) ?? 0
        default: return 0
        }
    }

    public func bool(_ key: String) -> Bool { int(key) != 0 }
}

public final class SQLiteDB {
    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    static let statementCacheLimit = 64
    private let lock = NSLock()
    private var statements: [String: OpaquePointer] = [:]
    private var transactionDepth = 0

    public init(path: String, readOnly: Bool = false) throws {
        let flags = (readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)) | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &handle, flags, nil) != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_close_v2(handle)
            throw SQLiteError.open("\(path): \(message)")
        }
        sqlite3_busy_timeout(handle, 3000)
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close_v2(handle)
    }

    private var errorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    public var changes: Int { Int(sqlite3_changes(handle)) }

    var cachedStatementCount: Int { lock.withLock { statements.count } }

    public func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let message = errorMessage
            sqlite3_free(err)
            throw SQLiteError.step(sql: sql, message: message)
        }
    }

    private func bind(_ s: OpaquePointer, _ args: [Any?]) {
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            guard let value = arg else {
                sqlite3_bind_null(s, idx)
                continue
            }
            switch value {
            case is NSNull: sqlite3_bind_null(s, idx)
            case let v as Bool: sqlite3_bind_int64(s, idx, v ? 1 : 0)
            case let v as Int: sqlite3_bind_int64(s, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(s, idx, v)
            case let v as Int32: sqlite3_bind_int64(s, idx, Int64(v))
            case let v as Double: sqlite3_bind_double(s, idx, v)
            case let v as String: sqlite3_bind_text(s, idx, v, -1, Self.transient)
            case let v as Data:
                _ = v.withUnsafeBytes { buf in
                    sqlite3_bind_blob(s, idx, buf.baseAddress, Int32(v.count), Self.transient)
                }
            default: sqlite3_bind_text(s, idx, "\(value)", -1, Self.transient)
            }
        }
    }

    private func withStatement<T>(_ sql: String, _ args: [Any?], _ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        let s: OpaquePointer
        if let cached = statements.removeValue(forKey: sql) {
            s = cached
        } else {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let prepared = stmt else {
                sqlite3_finalize(stmt)
                throw SQLiteError.prepare(sql: sql, message: errorMessage)
            }
            s = prepared
        }
        defer {
            sqlite3_reset(s)
            sqlite3_clear_bindings(s)
            if statements.count >= Self.statementCacheLimit, let evicted = statements.popFirst() {
                sqlite3_finalize(evicted.value)
            }
            statements[sql] = s
        }
        bind(s, args)
        return try body(s)
    }

    public func run(_ sql: String, _ args: [Any?] = []) throws {
        try withStatement(sql, args) { s in
            let rc = sqlite3_step(s)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
                throw SQLiteError.step(sql: sql, message: errorMessage)
            }
        }
    }

    public func query(_ sql: String, _ args: [Any?] = []) throws -> [Row] {
        try withStatement(sql, args) { s in
            let count = sqlite3_column_count(s)
            let names = (0..<count).map { String(cString: sqlite3_column_name(s, $0)) }
            var rows: [Row] = []
            while true {
                let rc = sqlite3_step(s)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw SQLiteError.step(sql: sql, message: errorMessage) }
                var values: [String: Any] = Dictionary(minimumCapacity: Int(count))
                for c in 0..<count {
                    let name = names[Int(c)]
                    switch sqlite3_column_type(s, c) {
                    case SQLITE_INTEGER: values[name] = sqlite3_column_int64(s, c)
                    case SQLITE_FLOAT: values[name] = sqlite3_column_double(s, c)
                    case SQLITE_TEXT: values[name] = String(cString: sqlite3_column_text(s, c))
                    case SQLITE_BLOB:
                        let bytes = Int(sqlite3_column_bytes(s, c))
                        if let ptr = sqlite3_column_blob(s, c), bytes > 0 {
                            values[name] = Data(bytes: ptr, count: bytes)
                        } else {
                            values[name] = Data()
                        }
                    default: values[name] = NSNull()
                    }
                }
                rows.append(Row(values: values))
            }
            return rows
        }
    }

    public func scalarInt(_ sql: String, _ args: [Any?] = []) throws -> Int64 {
        guard let row = try query(sql, args).first, let key = row.values.keys.first else { return 0 }
        return row.int(key)
    }

    @discardableResult
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        let depth = transactionDepth
        let savepoint = "sp\(depth)"
        try exec(depth == 0 ? "BEGIN" : "SAVEPOINT \(savepoint)")
        transactionDepth += 1
        defer { transactionDepth -= 1 }
        do {
            let result = try body()
            try exec(depth == 0 ? "COMMIT" : "RELEASE \(savepoint)")
            return result
        } catch {
            try? exec(depth == 0 ? "ROLLBACK" : "ROLLBACK TO \(savepoint); RELEASE \(savepoint)")
            throw error
        }
    }
}
