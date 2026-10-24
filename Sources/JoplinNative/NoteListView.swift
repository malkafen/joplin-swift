import JoplinCore
import SwiftUI

struct NoteListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.noteCount == 0 {
                NoteListPlaceholder()
            } else {
                NoteList()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(model.listTitle)
        .navigationSubtitle(model.listSubtitle)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search all notes")
        .onSubmit(of: .search) { model.stepMatch(forward: !NSEvent.modifierFlags.contains(.shift)) }
        .toolbar {
            ToolbarItemGroup {
                NoteListOptionsMenu()

                Button {
                    model.newNote(isTodo: true)
                } label: {
                    Label("New To-do", systemImage: "checklist")
                }
                .help("New To-do (⇧⌘N)")

                Button {
                    model.newNote()
                } label: {
                    Label("New Note", systemImage: "square.and.pencil")
                }
                .help("New Note (⌘N)")
            }
        }
    }
}

private struct NoteListPlaceholder: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.searchText.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else if model.isNothingChosen {
            ContentUnavailableView {
                Label("No Notebook Selected", systemImage: "sidebar.left")
            } description: {
                Text("Choose a notebook, a tag or All Notes in the sidebar, or press ⌘L to search.")
            }
        } else if model.isTrashSelected {
            ContentUnavailableView("Trash Is Empty", systemImage: "trash")
        } else {
            ContentUnavailableView {
                Label("No Notes", systemImage: "note.text")
            } description: {
                Text("Press ⌘N to create a note.")
            }
        }
    }
}

private struct NoteList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let terms = model.listSearchTerms
        let previews = model.showNotePreviews || !terms.isEmpty
        List(selection: $model.selectedNoteIDs) {
            ForEach(model.notes) { note in
                NoteRow(note: note, terms: terms, showsPreview: previews)
                    .tag(note.id)
                    .draggable(note.id)
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: String.self) { ids in
            NoteMenu(ids: ids)
        }
        .onDeleteCommand { model.deleteSelectedNotes() }
    }
}

private struct NoteListOptionsMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Menu {
            Picker("Sort By", selection: $model.sort) {
                NoteSortOptions()
            }
            .pickerStyle(.inline)
            Toggle("Uncompleted To-dos on Top", isOn: $model.uncompletedTodosOnTop)
            Divider()
            Toggle("Show Note Previews", isOn: $model.showNotePreviews)
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .help("Sort notes")
    }
}

struct NoteSortOptions: View {
    var body: some View {
        Text("Date Edited").tag(NoteSort.updated)
        Text("Date Created").tag(NoteSort.created)
        Text("Title").tag(NoteSort.title)
    }
}

struct MoveToFolderItems: View {
    let action: (String) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        ForEach(model.flatFolders, id: \.folder.id) { item in
            Button(String(repeating: "    ", count: item.depth) + item.folder.title) {
                action(item.folder.id)
            }
        }
    }
}

struct NoteMenu: View {
    let ids: Set<String>
    @Environment(AppModel.self) private var model

    var body: some View {
        if ids.isEmpty {
            Button("New Note") { model.newNote() }
            Button("New To-do") { model.newNote(isTodo: true) }
        } else if model.isTrashSelected {
            Button("Restore") { model.restoreNotes(ids) }
            Button("Delete Permanently…", role: .destructive) { model.deleteNotesPermanently(ids) }
        } else {
            Menu("Move To") {
                MoveToFolderItems { model.moveNotes(ids, to: $0) }
            }
            Button("Duplicate") { model.duplicate(ids) }
            Button("Copy Markdown Link") { model.copyMarkdownLinks(ids) }
            if model.notes.filter({ ids.contains($0.id) }).allSatisfy(\.isTodo) {
                Button("Switch to Note") { model.setIsTodo(ids, false) }
            } else {
                Button("Switch to To-do") { model.setIsTodo(ids, true) }
            }
            Divider()
            Button("Move to Trash", role: .destructive) { model.trashNotes(ids) }
        }
    }
}

struct NoteRow: View {
    let note: NoteSummary
    var terms: [String] = []
    var showsPreview = false
    @Environment(AppModel.self) private var model

    private var done: Bool { note.isTodo && note.todoCompleted > 0 }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if note.isTodo {
                Toggle("", isOn: Binding(get: { done }, set: { model.setTodoCompleted(note.id, $0) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.highlighted(note.title.isEmpty ? "Untitled" : note.title, terms: terms))
                    .font(.system(size: 13, weight: .semibold))
                    .strikethrough(done)
                    .foregroundStyle(done ? .secondary : .primary)
                    .lineLimit(1)
                if showsPreview {
                    HStack(spacing: 6) {
                        Text(shortDate(note.userUpdatedTime))
                            .foregroundStyle(.primary.opacity(0.75))
                        Text(Self.highlighted(note.snippet.isEmpty ? "No additional text" : note.snippet, terms: terms))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .font(.system(size: 12))
                }
            }
        }
        .padding(.vertical, showsPreview ? 4 : 2)
    }

    static func highlighted(_ text: String, terms: [String]) -> AttributedString {
        var result = AttributedString(text)
        for r in SearchHighlight.ranges(of: terms, in: text) {
            guard let range = Range(r, in: text), let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].backgroundColor = Color(nsColor: SearchHighlight.color)
            result[lower..<upper].foregroundColor = Color(nsColor: .labelColor)
        }
        return result
    }
}
