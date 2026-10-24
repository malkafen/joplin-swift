import Foundation
import JoplinCore

struct FolderNode: Identifiable, Hashable {
    let folder: Folder
    var children: [FolderNode]?
    var id: String { folder.id }
}

struct FlatFolder: Hashable {
    let folder: Folder
    let depth: Int
}

enum SidebarItem: Hashable {
    case allNotes
    case folder(String)
    case tag(String)
    case trash
}

enum EditorLayout: String, CaseIterable, Identifiable {
    case editor, split, preview

    var id: String { rawValue }

    var label: String {
        switch self {
        case .editor: return "Editor"
        case .split: return "Split"
        case .preview: return "Preview"
        }
    }

    var symbol: String {
        switch self {
        case .editor: return "pencil.line"
        case .split: return "rectangle.split.2x1"
        case .preview: return "eye"
        }
    }
}

struct NoteInfo: Equatable {
    var id: String
    var parentId: String
    var isTodo: Bool
    var todoCompleted: Int64
    var deletedTime: Int64
    var userCreatedTime: Int64
    var userUpdatedTime: Int64

    init(_ note: Note) {
        id = note.id
        parentId = note.parentId
        isTodo = note.isTodo
        todoCompleted = note.todoCompleted
        deletedTime = note.deletedTime
        userCreatedTime = note.userCreatedTime
        userUpdatedTime = note.userUpdatedTime
    }

    var inTrash: Bool { deletedTime > 0 }
    var isDone: Bool { isTodo && todoCompleted > 0 }
}

struct AlertInfo: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

struct TextPrompt: Identifiable {
    let id = UUID()
    var title: String
    var placeholder: String
    var initial: String
    var confirmLabel: String
    var action: (String) -> Void
}

struct Confirmation: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var destructiveLabel: String
    var action: () -> Void
}
