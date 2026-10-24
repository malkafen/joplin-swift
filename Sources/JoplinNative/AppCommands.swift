import SwiftUI

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) { NewItemCommands(model: model) }
        CommandGroup(after: .textEditing) { FindCommands(model: model) }
        CommandGroup(replacing: .saveItem) { SyncCommand(model: model) }
        CommandGroup(replacing: .importExport) { ImportExportCommands(model: model) }
        CommandGroup(after: .sidebar) { ViewCommands(model: model) }
        CommandGroup(after: .toolbar) { ZoomCommands(model: model) }
        CommandMenu("Note") { NoteCommands(model: model) }
        CommandMenu("Format") { FormatCommands(editor: model.editor) }
    }
}

struct NewItemCommands: View {
    let model: AppModel

    var body: some View {
        Button("New Note") { model.newNote() }
            .keyboardShortcut("n")
        Button("New To-do") { model.newNote(isTodo: true) }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        Button("New Notebook…") { model.promptNewFolder() }
            .keyboardShortcut("n", modifiers: [.command, .option])
    }
}

struct FindCommands: View {
    let model: AppModel

    var body: some View {
        Button("Find in Note") { model.findInNote() }
            .keyboardShortcut("f")
            .disabled(model.noteInfo == nil)
        Button("Search All Notes") { model.focusSearch() }
            .keyboardShortcut("l")
    }
}

struct SyncCommand: View {
    let model: AppModel

    var body: some View {
        Button("Synchronise") { model.requestSync() }
            .keyboardShortcut("s")
            .disabled(!model.isSyncConfigured || model.isSyncing)
    }
}

struct ImportExportCommands: View {
    let model: AppModel

    var body: some View {
        Menu("Import") {
            Button("From Joplin Desktop Profile") { model.importJoplinDesktop() }
            Button("JEX – Joplin Export File…") { model.importJEXWithPanel() }
            Button("RAW – Joplin Export Directory…") { model.importRawWithPanel() }
        }
        Menu("Export") {
            Button("All Notes as JEX…") { model.exportJEXWithPanel(folderId: nil) }
            if case .folder(let id) = model.sidebarSelection {
                Button("Notebook “\(model.folderTitle(id))” as JEX…") { model.exportJEXWithPanel(folderId: id) }
            }
        }
    }
}

struct ViewCommands: View {
    let model: AppModel

    var body: some View {
        @Bindable var model = model
        Button(ShortcutAction.editorOnly.title) { model.layout = .editor }
            .keyboardShortcut(model.hotkey(for: .editorOnly))
        Button(ShortcutAction.split.title) { model.layout = .split }
            .keyboardShortcut(model.hotkey(for: .split))
        Button(ShortcutAction.previewOnly.title) { model.layout = .preview }
            .keyboardShortcut(model.hotkey(for: .previewOnly))
        Button(ShortcutAction.cycleLayout.title) { model.cycleLayout() }
            .keyboardShortcut(model.hotkey(for: .cycleLayout))
        Divider()
        Button("Expand All Notebooks") { model.expandAllFolders() }
        Button("Collapse All Notebooks") { model.collapseAllFolders() }
        Divider()
        Toggle("Vim Mode", isOn: $model.vimMode)
            .keyboardShortcut("v", modifiers: [.command, .control, .option])
        Divider()
        Toggle("Show Tags in Sidebar", isOn: $model.showSidebarTags)
            .keyboardShortcut("t", modifiers: [.command, .control])
        Toggle("Show Tags Above Notes", isOn: $model.showNoteTags)
        Toggle("Show Note Previews", isOn: $model.showNotePreviews)
        Divider()
    }
}

struct ZoomCommands: View {
    let model: AppModel

    var body: some View {
        Button("Actual Size") { model.resetTextSize() }
            .keyboardShortcut("0")
        Button("Zoom In") { model.adjustTextSize(by: 1) }
            .keyboardShortcut("+")
        Button("Zoom Out") { model.adjustTextSize(by: -1) }
            .keyboardShortcut("-")
        Divider()
    }
}

struct NoteCommands: View {
    let model: AppModel

    var body: some View {
        let note = model.noteInfo
        let noSelection = model.selectedNoteIDs.isEmpty
        let inTrash = model.isTrashSelected
        Button("Next Note") { model.selectAdjacentNote(1) }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
        Button("Previous Note") { model.selectAdjacentNote(-1) }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
        Divider()
        Button("Edit Title") { model.focusTitle() }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(note == nil)
        Button("Edit Tags") { model.focusTags() }
            .keyboardShortcut("k", modifiers: [.command, .option])
            .disabled(note == nil)
        Button("Attach File…") { model.attachFilesWithPanel() }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(note == nil)
        Divider()
        Button(note?.todoCompleted ?? 0 > 0 ? "Mark as Not Done" : "Mark as Done") {
            model.toggleCurrentTodoCompleted()
        }
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(note?.isTodo != true)
        Button(note?.isTodo == true ? "Switch to Note" : "Switch to To-do") { model.toggleCurrentIsTodo() }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(note == nil)
        Button("Duplicate") { model.duplicate(model.selectedNoteIDs) }
            .keyboardShortcut("d")
            .disabled(noSelection || inTrash)
        Button("Copy Markdown Link") { model.copyMarkdownLinks(model.selectedNoteIDs) }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(noSelection)
        Divider()
        Button(inTrash ? "Delete Permanently…" : "Move to Trash") { model.deleteSelectedNotes() }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(noSelection)
        Button("Empty Trash…") { model.emptyTrash() }
    }
}

struct FormatCommands: View {
    let editor: EditorBridge

    var body: some View {
        Button("Bold") { editor.wrap("**", placeholder: "bold text") }
            .keyboardShortcut("b")
        Button("Italic") { editor.wrap("*", placeholder: "italic text") }
            .keyboardShortcut("i")
        Button("Strikethrough") { editor.wrap("~~", placeholder: "text") }
            .keyboardShortcut("x", modifiers: [.command, .shift])
        Button("Highlight") { editor.wrap("==", placeholder: "text") }
            .keyboardShortcut("h", modifiers: [.command, .shift])
        Button("Inline Code") { editor.wrap("`", placeholder: "code") }
            .keyboardShortcut("e")
        Button("Link") { editor.wrap("[", "](https://)", placeholder: "link text") }
            .keyboardShortcut("k")
        Divider()
        Button("Heading 1") { editor.toggleLinePrefix("# ") }
            .keyboardShortcut("1", modifiers: [.command, .option])
        Button("Heading 2") { editor.toggleLinePrefix("## ") }
            .keyboardShortcut("2", modifiers: [.command, .option])
        Button("Heading 3") { editor.toggleLinePrefix("### ") }
            .keyboardShortcut("3", modifiers: [.command, .option])
        Divider()
        Button("Bulleted List") { editor.toggleLinePrefix("- ") }
            .keyboardShortcut("8", modifiers: [.command, .shift])
        Button("Numbered List") { editor.toggleLinePrefix("1. ") }
            .keyboardShortcut("7", modifiers: [.command, .shift])
        Button("Checklist") { editor.toggleLinePrefix("- [ ] ") }
            .keyboardShortcut("9", modifiers: [.command, .shift])
        Button("Quote") { editor.toggleLinePrefix("> ") }
            .keyboardShortcut("'", modifiers: [.command, .shift])
        Divider()
        Button("Code Block") { editor.wrap("```\n", "\n```", placeholder: "code") }
        Button("Math Formula") { editor.wrap("$", placeholder: "E = mc^2") }
            .keyboardShortcut("m", modifiers: [.command, .control])
        Button("Table") { editor.insertBlock("| Column | Column |\n|--------|--------|\n|        |        |\n") }
        Button("Horizontal Rule") { editor.insertBlock("\n---\n") }
        Button("Insert Date and Time") {
            editor.insert(Date().formatted(date: .numeric, time: .shortened))
        }
        .keyboardShortcut("t", modifiers: [.command, .shift])
    }
}
