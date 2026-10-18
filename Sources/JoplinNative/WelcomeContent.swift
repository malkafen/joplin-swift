import JoplinCore

extension AppModel {
    func createWelcomeContent() {
        guard store.totalNoteCount == 0, store.folders().isEmpty else { return }
        do {
            let folder = try store.createFolder(title: "Welcome")
            try store.createNote(parentId: folder.id, title: "Welcome to Joplin Native", body: Self.welcomeBody)
            let todo = try store.createNote(parentId: folder.id, title: "Try checklists", body: """
                - [x] Create a note (⌘N)
                - [ ] Create a to-do (⇧⌘N)
                - [ ] Drop an image into the editor
                - [ ] Import your notes from Joplin (File → Import)
                """, isTodo: true)
            try store.setTags(noteId: todo.id, titles: ["start"])
        } catch {
            alert = AlertInfo(title: "Error", message: "\(error)")
        }
    }

    static let welcomeBody = """
    A native macOS notes app that speaks **Joplin**'s data format: SwiftUI + AppKit, no Electron, no web view.

    ## Features

    - Nested notebooks, tags, to-dos and a trash
    - Markdown editor with syntax highlighting, preview and *split* mode (⌃L)
    - Full-text search across all notes (SQLite FTS5)
    - Attachments: drop a file or paste an image from the clipboard
    - **JEX** import and export, Joplin Desktop profile import

    ## Formatting

    | Action | Shortcut |
    |:--|:--:|
    | Bold | ⌘B |
    | Italic | ⌘I |
    | Link | ⌘K |
    | Checklist | ⇧⌘9 |

    > Notes are stored in SQLite using Joplin's schema: same fields, ids and serialization.

    ```swift
    let note = try store.createNote(parentId: folder.id, title: "Hello")
    ```

    ---

    - [ ] Click a checkbox in the preview and it toggles in the source
    - [x] Done
    """
}
