import Foundation

public struct Folder: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var parentId: String
    public var icon: String
    public var deletedTime: Int64
    public var userUpdatedTime: Int64

    init(row: Row) {
        id = row.string("id")
        title = row.string("title")
        parentId = row.string("parent_id")
        icon = row.string("icon")
        deletedTime = row.int("deleted_time")
        userUpdatedTime = row.int("user_updated_time")
    }

    /// Joplin stores the notebook icon as JSON: {"emoji":"📒","name":"","type":1}
    public var emoji: String? {
        guard !icon.isEmpty, let data = icon.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let emoji = obj["emoji"] as? String, !emoji.isEmpty else { return nil }
        return emoji
    }
}

public struct Tag: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var noteCount: Int
}

public struct NoteSummary: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var parentId: String
    public var isTodo: Bool
    public var todoCompleted: Int64
    public var todoDue: Int64
    public var userUpdatedTime: Int64
    public var userCreatedTime: Int64
    public var deletedTime: Int64
    public var snippet: String

    init(row: Row) {
        id = row.string("id")
        title = row.string("title")
        parentId = row.string("parent_id")
        isTodo = row.bool("is_todo")
        todoCompleted = row.int("todo_completed")
        todoDue = row.int("todo_due")
        userUpdatedTime = row.int("user_updated_time")
        userCreatedTime = row.int("user_created_time")
        deletedTime = row.int("deleted_time")
        snippet = Snippet.make(from: row.string("snippet"))
    }
}

public struct Note: Identifiable, Hashable, Sendable {
    public var id: String
    public var parentId: String
    public var title: String
    public var body: String
    public var isTodo: Bool
    public var todoCompleted: Int64
    public var todoDue: Int64
    public var sourceUrl: String
    public var author: String
    public var markupLanguage: Int64
    public var isConflict: Bool
    public var createdTime: Int64
    public var userCreatedTime: Int64
    public var userUpdatedTime: Int64
    public var deletedTime: Int64
    public var encrypted: Bool

    init(row: Row) {
        id = row.string("id")
        parentId = row.string("parent_id")
        title = row.string("title")
        body = row.string("body")
        isTodo = row.bool("is_todo")
        todoCompleted = row.int("todo_completed")
        todoDue = row.int("todo_due")
        sourceUrl = row.string("source_url")
        author = row.string("author")
        markupLanguage = row.int("markup_language")
        isConflict = row.bool("is_conflict")
        createdTime = row.int("created_time")
        userCreatedTime = row.int("user_created_time")
        userUpdatedTime = row.int("user_updated_time")
        deletedTime = row.int("deleted_time")
        encrypted = row.bool("encryption_applied")
    }
}

public struct Resource: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var mime: String
    public var filename: String
    public var fileExtension: String
    public var size: Int64

    init(row: Row) {
        id = row.string("id")
        title = row.string("title")
        mime = row.string("mime")
        filename = row.string("filename")
        fileExtension = row.string("file_extension")
        size = row.int("size")
    }

    /// Same naming as Joplin's resourceFilename(): "<id>.<ext>" or "<id>".
    public var storageName: String { fileExtension.isEmpty ? id : "\(id).\(fileExtension)" }

    public var isImage: Bool { mime.hasPrefix("image/") }

    public var displayName: String {
        if !title.isEmpty { return title }
        if !filename.isEmpty { return filename }
        return storageName
    }
}

public enum NoteSort: String, CaseIterable, Sendable {
    case updated, created, title
}

public enum NoteFilter: Hashable, Sendable {
    case all
    case folder(String)
    case tag(String)
    case trash
    case search(String)
}

public enum Snippet {
    private static let patterns: [(NSRegularExpression, String)] = [
        ("!\\[[^\\]]*\\]\\([^)]*\\)", ""),
        ("\\[([^\\]]*)\\]\\([^)]*\\)", "$1"),
        ("<[^>]+>", ""),
        ("(?m)^\\s{0,3}(#{1,6}|>|[-*+]\\s+\\[[ xX]\\]|[-*+]|\\d+\\.)\\s+", ""),
        ("[*_`~]+", ""),
        ("\\s+", " "),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    public static func make(from markdown: String) -> String {
        var s = markdown
        for (re, template) in patterns {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
