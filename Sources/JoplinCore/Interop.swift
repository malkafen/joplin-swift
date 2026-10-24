import Foundation

public struct ImportReport: Sendable, CustomStringConvertible {
    public var folders = 0
    public var notes = 0
    public var tags = 0
    public var noteTags = 0
    public var resources = 0
    public var skippedEncrypted = 0
    public var errors: [String] = []

    public var description: String {
        var s = "Notebooks: \(folders), notes: \(notes), tags: \(tags), attachments: \(resources)"
        if skippedEncrypted > 0 { s += ", skipped encrypted: \(skippedEncrypted)" }
        if !errors.isEmpty { s += ", errors: \(errors.count)" }
        return s
    }

    mutating func count(_ type: ModelType) {
        switch type {
        case .folder: folders += 1
        case .note: notes += 1
        case .tag: tags += 1
        case .noteTag: noteTags += 1
        case .resource: resources += 1
        default: break
        }
    }
}

public enum InteropError: Error, CustomStringConvertible {
    case tarFailed(String)
    case notFound(String)

    public var description: String {
        switch self {
        case .tarFailed(let m): return "tar failed: \(m)"
        case .notFound(let m): return "Not found: \(m)"
        }
    }
}

public extension Store {
    static var joplinDesktopProfile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/joplin-desktop", isDirectory: true)
    }

    func importDirectory(_ dir: URL) throws -> ImportReport {
        let fm = FileManager.default
        var report = ImportReport()
        let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" && $0.deletingPathExtension().lastPathComponent.count == 32 }
        let blobDirs = [dir.appendingPathComponent("resources"), dir.appendingPathComponent(".resource")]

        try db.transaction {
            for file in files {
                do {
                    let content = try String(contentsOf: file, encoding: .utf8)
                    let (type, fields) = try Serializer.unserialize(content)
                    if (fields["encryption_applied"] as? Int64 ?? 0) != 0 {
                        report.skippedEncrypted += 1
                        continue
                    }
                    if type == .resource, let id = fields["id"] as? String {
                        let ext = fields["file_extension"] as? String ?? ""
                        let storage = ext.isEmpty ? id : "\(id).\(ext)"
                        let candidates = blobDirs.flatMap { [$0.appendingPathComponent(storage), $0.appendingPathComponent(id)] }
                        if let blob = candidates.first(where: { fm.fileExists(atPath: $0.path) }) {
                            let dest = resourceDirectory.appendingPathComponent(storage)
                            try? fm.removeItem(at: dest)
                            try fm.copyItem(at: blob, to: dest)
                        }
                    }
                    try upsert(type, fields)
                    report.count(type)
                } catch {
                    report.errors.append("\(file.lastPathComponent): \(error)")
                }
            }
        }
        return report
    }

    func importJEX(_ archive: URL) throws -> ImportReport {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("jex-\(Store.newId())", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Self.runTar(["-xf", archive.path, "-C", tmp.path])
        return try importDirectory(tmp)
    }

    func importJoplinDesktopProfile(_ profile: URL = Store.joplinDesktopProfile) throws -> ImportReport {
        let dbURL = profile.appendingPathComponent("database.sqlite")
        guard FileManager.default.fileExists(atPath: dbURL.path) else { throw InteropError.notFound(dbURL.path) }
        let source = try SQLiteDB(path: dbURL.path, readOnly: true)
        var report = ImportReport()
        let fm = FileManager.default
        try db.transaction {
            for type in ModelType.syncable {
                guard let table = type.table, let defs = Schema.fields[type] else { continue }
                let available = Set(try source.query("PRAGMA table_info(\(table))").map { $0.string("name") })
                for row in try source.query("SELECT * FROM \(table)") {
                    if row.int("encryption_applied") != 0 {
                        report.skippedEncrypted += 1
                        continue
                    }
                    var fields: [String: Any] = [:]
                    for def in defs where available.contains(def.name) {
                        if let v = row[def.name], !(v is NSNull) { fields[def.name] = v }
                    }
                    if type == .resource {
                        let r = Resource(row: row)
                        let src = profile.appendingPathComponent("resources").appendingPathComponent(r.storageName)
                        let dest = resourceDirectory.appendingPathComponent(r.storageName)
                        if fm.fileExists(atPath: src.path) {
                            try? fm.removeItem(at: dest)
                            try fm.copyItem(at: src, to: dest)
                        }
                    }
                    try upsert(type, fields)
                    report.count(type)
                }
            }
        }
        return report
    }

    func exportJEX(to archive: URL, folderId: String? = nil) throws -> Int {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("jex-\(Store.newId())", isDirectory: true)
        let resDir = tmp.appendingPathComponent("resources", isDirectory: true)
        try fm.createDirectory(at: resDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        var folderIds: [String]? = nil
        if let folderId { folderIds = [folderId] + descendantFolderIds(of: folderId) }

        func inClause(_ ids: [String]) -> String { ids.map { "'\($0)'" }.joined(separator: ",") }

        var items: [(ModelType, Row)] = []
        if let ids = folderIds {
            let list = inClause(ids)
            let folders = try rows(.folder, where: "id IN (\(list)) AND deleted_time = 0")
            let notes = try rows(.note, where: "parent_id IN (\(list)) AND deleted_time = 0")
            let noteList = inClause(notes.map { $0.string("id") })
            let links = try rows(.noteTag, where: "note_id IN (\(noteList))")
            let tags = try rows(.tag, where: "id IN (\(inClause(links.map { $0.string("tag_id") })))")
            let resourceIds = Set(notes.flatMap { MarkdownLinks.resourceIds(in: $0.string("body")) })
            let resources = try rows(.resource, where: "id IN (\(inClause(Array(resourceIds))))")
            items = folders.map { (.folder, $0) } + notes.map { (.note, $0) } + tags.map { (.tag, $0) }
                + links.map { (.noteTag, $0) } + resources.map { (.resource, $0) }
        } else {
            for type in ModelType.syncable {
                let clause = (type == .note || type == .folder) ? "deleted_time = 0" : "1"
                items += try rows(type, where: clause).map { (type, $0) }
            }
        }

        for (type, row) in items {
            let text = try Serializer.serialize(type: type, fields: row.values)
            try text.write(to: tmp.appendingPathComponent("\(row.string("id")).md"), atomically: true, encoding: .utf8)
            if type == .resource {
                let r = Resource(row: row)
                let src = url(for: r)
                if fm.fileExists(atPath: src.path) {
                    try fm.copyItem(at: src, to: resDir.appendingPathComponent(r.storageName))
                }
            }
        }
        try? fm.removeItem(at: archive)
        let names = try fm.contentsOfDirectory(atPath: tmp.path)
        try Self.runTar(["-cf", archive.path, "-C", tmp.path] + names)
        return items.count
    }

    internal static func runTar(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw InteropError.tarFailed(msg)
        }
    }
}

public enum MarkdownLinks {
    private static let resourceRegex = try! NSRegularExpression(pattern: ":/([0-9a-fA-F]{32})")

    public static func resourceIds(in body: String) -> [String] {
        resourceRegex.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap {
            Range($0.range(at: 1), in: body).map { String(body[$0]).lowercased() }
        }
    }
}
