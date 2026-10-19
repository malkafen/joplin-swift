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

    static let welcomeBody = #"""
    A native macOS notes app that speaks **Joplin**'s data format: SwiftUI + AppKit, no Electron, no web view.

    [toc]

    ## Features

    - Nested notebooks, tags, to-dos and a trash
    - Markdown editor with syntax highlighting, preview and *split* mode (⌃L)
    - Full-text search across all notes (SQLite FTS5)
    - Attachments: drop a file or paste an image from the clipboard
    - **JEX** import and export, Joplin Desktop profile import

    > [!TIP]
    > Choose the fonts of the editor and the preview in **Settings → Text**. ⌘+ and ⌘− change the size.

    ## Formatting

    | Action | Shortcut |
    |:--|:--:|
    | Bold | ⌘B |
    | Italic | ⌘I |
    | ==Highlight== | ⇧⌘H |
    | Link | ⌘K |
    | Checklist | ⇧⌘9 |

    Press <kbd>⌘</kbd><kbd>N</kbd> for a new note. Inline `code`, ~~strikethrough~~, H<sub>2</sub>O and x<sup>2</sup> work too.

    > Notes are stored in SQLite using Joplin's schema: same fields, ids and serialization.

    ```swift
    let note = try store.createNote(parentId: folder.id, title: "Hello")
    print(note.title) // "Hello"
    ```

    ## Math

    Euler's identity $e^{i\pi} + 1 = 0$, and a sum:

    $$
    \sum_{k=1}^{n} k = \frac{n(n+1)}{2}
    $$

    ---

    - [ ] Click a checkbox in the preview and it toggles in the source
    - [x] Done
    """#
}
