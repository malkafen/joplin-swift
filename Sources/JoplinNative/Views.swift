import JoplinCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 340)
        } content: {
            NoteListView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 290, max: 460)
        } detail: {
            NoteEditorView()
        }
        .alert(model.alert?.title ?? "", isPresented: isPresented(\.alert), presenting: model.alert) { _ in
            Button("OK") {}
        } message: { info in
            Text(info.message)
        }
        .alert(model.textPrompt?.title ?? "", isPresented: isPresented(\.textPrompt), presenting: model.textPrompt) { prompt in
            TextField(prompt.placeholder, text: $model.promptText)
            Button(prompt.confirmLabel) { prompt.action(model.promptText) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(model.confirmation?.title ?? "", isPresented: isPresented(\.confirmation),
                            presenting: model.confirmation) { c in
            Button(c.destructiveLabel, role: .destructive) { c.action() }
            Button("Cancel", role: .cancel) {}
        } message: { c in
            Text(c.message)
        }
    }

    private func isPresented<T>(_ keyPath: ReferenceWritableKeyPath<AppModel, T?>) -> Binding<Bool> {
        Binding(
            get: { model[keyPath: keyPath] != nil },
            set: { if !$0 { model[keyPath: keyPath] = nil } }
        )
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebarSelection) {
            Label("All Notes", systemImage: "note.text")
                .badge(model.allNotesCount)
                .tag(SidebarItem.allNotes)

            SidebarHeader(title: "Notebooks") {
                Button {
                    model.collapseAllFolders()
                } label: {
                    Image(systemName: "rectangle.compress.vertical")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .disabled(model.expandedFolders.isEmpty)
                .help("Collapse All Notebooks")

                Button {
                    model.promptNewFolder()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("New Notebook")
            }

            FolderTreeRows(nodes: model.folderTree)

            if model.showSidebarTags, !model.tags.isEmpty {
                Section(isExpanded: $model.sidebarTagsExpanded) {
                    ForEach(model.tags) { tag in
                        Label(tag.title, systemImage: "number")
                            .badge(tag.noteCount)
                            .tag(SidebarItem.tag(tag.id))
                            .contextMenu {
                                Button("Rename…") { model.promptRenameTag(tag) }
                                Button("Delete Tag", role: .destructive) { model.deleteTag(tag) }
                                Divider()
                                Button("Hide Tags in Sidebar") { model.showSidebarTags = false }
                            }
                    }
                } header: {
                    Text("Tags")
                        .contextMenu {
                            Button("Hide Tags in Sidebar") { model.showSidebarTags = false }
                        }
                }
            }

            Section {
                if model.trashedFolders.isEmpty {
                    trashRow
                } else {
                    // Notebooks in the trash fold under it like sub-notebooks; collapsed by default.
                    DisclosureGroup(isExpanded: $model.trashExpanded) {
                        ForEach(model.trashedFolders) { folder in
                            Label(folder.title, systemImage: "folder")
                                .foregroundStyle(.secondary)
                                .contextMenu {
                                    Button("Restore Notebook") { model.restoreFolder(folder) }
                                    Button("Delete Permanently…", role: .destructive) { model.deleteFolderPermanently(folder) }
                                }
                        }
                    } label: {
                        trashRow
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay(alignment: .top) { StickyFolderHeader() }
        .safeAreaInset(edge: .bottom, spacing: 0) { SyncStatusBar() }
    }

    private var trashRow: some View {
        Label("Trash", systemImage: "trash")
            .badge(model.trashCount)
            .tag(SidebarItem.trash)
            .contextMenu {
                Button("Empty Trash", role: .destructive) { model.emptyTrash() }
            }
    }
}

/// Notebook rows with disclosure triangles; which notebooks are expanded is kept in the model (and remembered).
struct FolderTreeRows: View {
    let nodes: [FolderNode]
    @Environment(AppModel.self) private var model

    var body: some View {
        ForEach(nodes) { node in
            if let children = node.children {
                DisclosureGroup(isExpanded: model.expansion(of: node.id)) {
                    AnyView(FolderTreeRows(nodes: children))
                } label: {
                    row(node)
                }
            } else {
                row(node)
            }
        }
    }

    private func row(_ node: FolderNode) -> some View {
        FolderRow(folder: node.folder)
            .background(FolderMarker(id: node.id, tracker: model.sticky))
            .badge(model.folderCounts[node.id] ?? 0)
            .tag(SidebarItem.folder(node.id))
            .draggable("folder:\(node.id)")
            .dropDestination(for: String.self) { items, _ in
                model.dropOnFolder(items, folderId: node.id)
            }
            .contextMenu { folderMenu(node.folder) }
    }

    @ViewBuilder
    private func folderMenu(_ folder: Folder) -> some View {
        Button("New Note") {
            model.sidebarSelection = .folder(folder.id)
            model.newNote()
        }
        Button("New Sub-notebook…") { model.promptNewFolder(parent: folder.id) }
        Divider()
        Button("Rename…") { model.promptRenameFolder(folder) }
        Button("Export as JEX…") { model.exportJEXWithPanel(folderId: folder.id) }
        if !folder.parentId.isEmpty {
            Button("Move to Top Level") { _ = model.dropOnFolder(["folder:\(folder.id)"], folderId: "") }
        }
        Divider()
        Button("Move to Trash", role: .destructive) { model.trashFolder(folder) }
    }
}

/// Group title as a plain row: sidebar Section headers get a system collapse button on hover that collides with
/// header buttons.
struct SidebarHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            accessory
        }
        .padding(.top, 10)
    }
}

struct SyncStatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            if model.isSyncConfigured {
                Button {
                    model.requestSync()
                } label: {
                    Image(systemName: model.syncFailed ? "exclamationmark.arrow.triangle.2.circlepath" : "arrow.triangle.2.circlepath")
                        .foregroundStyle(model.syncFailed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.borderless)
                .disabled(model.isSyncing)
                .help("Synchronise (⌘S)")
            } else {
                SettingsLink {
                    Image(systemName: "icloud.slash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Set up synchronisation")
            }
            if model.isSyncing {
                ProgressView().controlSize(.mini)
            }
            Text(model.syncStatusLine)
                .font(.system(size: 11))
                .foregroundStyle(model.syncFailed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(model.syncDetail.isEmpty ? model.syncStatusLine : model.syncDetail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        // The list scrolls under this bar; without a background the last rows show through the text.
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

struct FolderRow: View {
    let folder: Folder
    /// Outside a sidebar list the icon is not tinted automatically.
    var accentIcon = false

    var body: some View {
        Label {
            Text(folder.title.isEmpty ? "Untitled" : folder.title)
        } icon: {
            if let emoji = folder.emoji {
                Text(emoji)
            } else {
                if accentIcon {
                    Image(systemName: "folder").foregroundStyle(Color.accentColor)
                } else {
                    Image(systemName: "folder")
                }
            }
        }
    }
}

// MARK: - Note list

struct NoteListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.notes.isEmpty {
                if !model.searchText.isEmpty {
                    ContentUnavailableView.search(text: model.searchText)
                } else if model.isTrashSelected {
                    ContentUnavailableView("Trash Is Empty", systemImage: "trash")
                } else {
                    ContentUnavailableView {
                        Label("No Notes", systemImage: "note.text")
                    } description: {
                        Text("Press ⌘N to create a note.")
                    }
                }
            } else {
                List(selection: $model.selectedNoteIDs) {
                    ForEach(model.notes) { note in
                        NoteRow(note: note)
                            .tag(note.id)
                            .draggable(note.id)
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: String.self) { ids in
                    noteMenu(ids)
                }
                .onDeleteCommand { model.deleteSelectedNotes() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(model.listTitle)
        .navigationSubtitle(model.notes.count == 1 ? "1 note" : "\(model.notes.count) notes")
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search all notes")
        // Return / ⇧Return step through the matches in the note.
        .onSubmit(of: .search) { model.stepMatch(forward: !NSEvent.modifierFlags.contains(.shift)) }
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Picker("Sort By", selection: $model.sort) {
                        Text("Date Edited").tag(NoteSort.updated)
                        Text("Date Created").tag(NoteSort.created)
                        Text("Title").tag(NoteSort.title)
                    }
                    .pickerStyle(.inline)
                    Toggle("Uncompleted To-dos on Top", isOn: $model.uncompletedTodosOnTop)
                    Divider()
                    Toggle("Show Note Previews", isOn: $model.showNotePreviews)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort notes")

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

    @ViewBuilder
    private func noteMenu(_ ids: Set<String>) -> some View {
        if ids.isEmpty {
            Button("New Note") { model.newNote() }
            Button("New To-do") { model.newNote(isTodo: true) }
        } else if model.isTrashSelected {
            Button("Restore") { model.restoreNotes(ids) }
            Button("Delete Permanently…", role: .destructive) { model.deleteNotesPermanently(ids) }
        } else {
            Menu("Move To") {
                ForEach(model.flatFolders, id: \.folder.id) { item in
                    Button(String(repeating: "    ", count: item.depth) + item.folder.title) {
                        model.moveNotes(ids, to: item.folder.id)
                    }
                }
            }
            Button("Duplicate") { model.duplicate(ids) }
            Button("Copy Markdown Link") { model.copyMarkdownLinks(ids) }
            let todos = model.notes.filter { ids.contains($0.id) }
            if todos.allSatisfy(\.isTodo) {
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
    @Environment(AppModel.self) private var model

    private var done: Bool { note.isTodo && note.todoCompleted > 0 }
    /// Search results keep the text around the match even when the list shows only titles.
    private var showsPreview: Bool { model.showNotePreviews || !model.searchTerms.isEmpty }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if note.isTodo {
                Toggle("", isOn: Binding(get: { done }, set: { model.setTodoCompleted(note.id, $0) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(highlighted(note.title.isEmpty ? "Untitled" : note.title))
                    .font(.system(size: 13, weight: .semibold))
                    .strikethrough(done)
                    .foregroundStyle(done ? .secondary : .primary)
                    .lineLimit(1)
                if showsPreview {
                    HStack(spacing: 6) {
                        Text(shortDate(note.userUpdatedTime))
                            .foregroundStyle(.primary.opacity(0.75))
                        Text(highlighted(note.snippet.isEmpty ? "No additional text" : note.snippet))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .font(.system(size: 12))
                }
            }
        }
        .padding(.vertical, showsPreview ? 4 : 2)
    }

    /// Marks the words of the active search.
    private func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        let ranges = SearchHighlight.ranges(of: model.searchTerms, in: text)
        for r in ranges {
            guard let range = Range(r, in: text), let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].backgroundColor = Color(nsColor: SearchHighlight.color)
            result[lower..<upper].foregroundColor = Color(nsColor: .labelColor)
        }
        return result
    }
}

func shortDate(_ ms: Int64) -> String {
    guard ms > 0 else { return "" }
    let date = Date(timeIntervalSince1970: Double(ms) / 1000)
    let cal = Calendar.current
    if cal.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
    if cal.isDateInYesterday(date) { return "Yesterday" }
    if cal.isDate(date, equalTo: Date(), toGranularity: .year) {
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
    return date.formatted(date: .numeric, time: .omitted)
}

func longDate(_ ms: Int64) -> String {
    guard ms > 0 else { return "" }
    return Date(timeIntervalSince1970: Double(ms) / 1000).formatted(date: .abbreviated, time: .shortened)
}

// MARK: - Editor

/// The current note without its body.
private struct NoteInfo: Equatable {
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
}

struct NoteEditorView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var titleFocused: Bool

    var body: some View {
        @Bindable var model = model
        Group {
            // Not `if let note`: SwiftUI compares the values views hold or capture, and comparing huge bodies on every
            // keystroke is slow. The chrome gets the note without its body, the editor its body in a `TextBox`.
            if let note = model.currentNote.map(NoteInfo.init) {
                editor(note)
            } else if model.selectedNoteIDs.count > 1 {
                ContentUnavailableView("\(model.selectedNoteIDs.count) Notes Selected", systemImage: "doc.on.doc")
            } else {
                ContentUnavailableView {
                    Label("No Note Selected", systemImage: "note.text")
                } description: {
                    Text("Select a note or press ⌘N to create one.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .toolbar {
            if model.currentNote != nil {
                ToolbarItemGroup(placement: .primaryAction) {
                    Picker("Layout", selection: $model.layout) {
                        ForEach(EditorLayout.allCases) { layout in
                            Label(layout.label, systemImage: layout.symbol).tag(layout)
                        }
                    }
                    .pickerStyle(.segmented)
                    .help(model.hotkey(for: .cycleLayout).map { "Editor layout (\($0.display))" } ?? "Editor layout")

                    Button {
                        model.attachFilesWithPanel()
                    } label: {
                        Label("Attach File", systemImage: "paperclip")
                    }
                    .help("Attach file (⇧⌘A)")
                    .disabled(model.currentNote?.deletedTime ?? 0 > 0)
                }
            }
        }
        .onChange(of: model.titleFocusRequest) {
            titleFocused = true
        }
    }

    @ViewBuilder
    private func editor(_ note: NoteInfo) -> some View {
        let inTrash = note.deletedTime > 0
        VStack(spacing: 0) {
            if inTrash {
                HStack {
                    Image(systemName: "trash")
                    Text("This note is in the trash.")
                    Spacer()
                    Button("Restore") { model.restoreNotes([note.id]) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.yellow.opacity(0.15))
            }
            header(note, inTrash: inTrash)
            Divider()
            content(note, inTrash: inTrash)
            Divider()
            NoteFooter(noteId: note.id, created: note.userCreatedTime)
        }
    }

    private func header(_ note: NoteInfo, inTrash: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if note.isTodo {
                    Toggle("", isOn: Binding(get: { note.todoCompleted > 0 }, set: { model.setTodoCompleted(note.id, $0) }))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .controlSize(.large)
                }
                TextField("Untitled", text: Binding(get: { model.currentNote?.title ?? "" }, set: { model.updateTitle($0) }))
                    .textFieldStyle(.plain)
                    .font(Font(model.editorFont.font(size: 22, weight: .bold)))
                    .focused($titleFocused)
                    .disabled(inTrash)
                    .onSubmit { model.editor.focus() }
            }
            HStack(spacing: 10) {
                Menu {
                    ForEach(model.flatFolders, id: \.folder.id) { item in
                        Button(String(repeating: "    ", count: item.depth) + item.folder.title) {
                            model.moveNotes([note.id], to: item.folder.id)
                        }
                    }
                } label: {
                    Label(model.folderTitle(note.parentId), systemImage: "folder")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(inTrash)
                .help("Move to notebook")

                if model.showNoteTags {
                    HStack(spacing: 4) {
                        Image(systemName: "number")
                            .foregroundStyle(.tertiary)
                        TagField(tags: model.currentTags, allTags: model.tags.map(\.title), onCreate: { model.tagField = $0 }) {
                            model.setCurrentTags($0)
                        }
                            .frame(minWidth: 140, maxWidth: 360)
                    }
                }

                Spacer(minLength: 8)

                Text(longDate(note.userUpdatedTime))
                    .foregroundStyle(.tertiary)
                    .help("Created \(longDate(note.userCreatedTime))")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private func content(_ note: NoteInfo, inTrash: Bool) -> some View {
        NoteSplitView(layout: model.layout,
                      editor: EditorPane(noteId: note.id, inTrash: inTrash).environment(model),
                      preview: PreviewPane(noteId: note.id).environment(model))
    }
}

/// The source editor of the current note. Its own view: it reads the body, which the editor changes on every keystroke.
private struct EditorPane: View {
    @Environment(AppModel.self) private var model
    var noteId: String
    var inTrash: Bool

    var body: some View {
        MarkdownEditor(
            text: model.currentNote?.body ?? "",
            noteId: noteId,
            typography: model.editorTypography,
            readableWidth: model.readableWidth,
            highlights: model.searchTerms,
            vimMode: model.vimMode,
            onVimMode: { model.vimState = $0 },
            isEditable: !inTrash,
            bridge: model.editor,
            stepper: model.searchStepper,
            onChange: { model.editBody($0) },
            onDropFiles: { model.attachmentMarkdown(for: $0) },
            onPasteImage: { model.pastedImageMarkdown($0) }
        )
        .overlay(alignment: .bottomTrailing) {
            if model.vimMode {
                Text(model.vimState.label)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(model.vimState == .insert ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(model.vimState == .insert ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.accentColor),
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// The rendered current note; follows the editor through `bodyRevision`.
private struct PreviewPane: View {
    @Environment(AppModel.self) private var model
    var noteId: String

    var body: some View {
        // Collapsed, it renders once shown: typing need not update it.
        let shown = model.layout != .editor
        let _ = shown ? model.bodyRevision : 0
        MarkdownPreview(markdown: model.currentNote?.body ?? "", noteId: noteId, renderer: model.renderer,
                        isShown: shown, readableWidth: model.readableWidth,
                        highlights: model.searchTerms, stepper: model.searchStepper, onLink: { model.handleLink($0) })
    }
}

/// Counts shown under the note.
struct NoteStats: Equatable, Sendable {
    var lines = 0
    var words = 0
    var characters = 0
    var matches = 0

    init() {}

    /// Reads the text once, byte by byte: a huge note is counted in a few milliseconds.
    init(_ text: String, terms: [String]) {
        var lines = text.isEmpty ? 0 : 1, words = 0, inWord = false
        for b in text.utf8 {
            if b == 10 { lines += 1 }
            // Letters and digits of any script (non-ASCII bytes) make words; spaces and punctuation separate them.
            let wordByte = b >= 0x80 || (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95
            if wordByte, !inWord { words += 1 }
            inWord = wordByte || (inWord && b == 39)
        }
        self.lines = lines
        self.words = words
        characters = text.count
        matches = terms.isEmpty ? 0 : SearchHighlight.ranges(of: terms, in: text).count
    }

    /// Minutes to read at 200 words a minute.
    var readingMinutes: Int { Int((Double(words) / 200).rounded()) }
}

/// Quiet line under the note: when it was created, its size, and the matches of the search.
private struct NoteFooter: View {
    @Environment(AppModel.self) private var model
    var noteId: String
    var created: Int64
    @State private var stats = NoteStats()

    var body: some View {
        let terms = model.searchTerms
        HStack(spacing: 12) {
            Text(summary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(created > 0 ? "Created \(longDate(created))" : "")
            Spacer(minLength: 8)
            if !terms.isEmpty {
                matches
                    .layoutPriority(1)
            }
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 24)
        .frame(height: 24)
        // Counted off the main thread once typing pauses; small notes at once.
        .task(id: "\(noteId)|\(model.bodyRevision)|\(terms)") {
            let body = model.currentNote?.body ?? ""
            if body.quickLength > 50_000 {
                try? await Task.sleep(for: .milliseconds(300))
                if Task.isCancelled { return }
            }
            let counted = await Task.detached(priority: .utility) { NoteStats(body, terms: terms) }.value
            if !Task.isCancelled { stats = counted }
        }
    }

    private var summary: String {
        var parts: [String] = []
        if created > 0 {
            parts.append("Created " + Date(timeIntervalSince1970: Double(created) / 1000).formatted(date: .abbreviated, time: .omitted))
        }
        parts.append(count(stats.lines, "line"))
        parts.append(count(stats.words, "word"))
        parts.append(count(stats.characters, "character"))
        if stats.readingMinutes > 0 { parts.append("\(stats.readingMinutes) min read") }
        return parts.joined(separator: "  ·  ")
    }

    private func count(_ n: Int, _ noun: String) -> String {
        "\(n.formatted()) \(noun)\(n == 1 ? "" : "s")"
    }

    private var matches: some View {
        HStack(spacing: 2) {
            if let position = model.searchPosition, position.count > 0 {
                Text("\((position.index + 1).formatted()) of \(position.count.formatted())")
            } else if model.searchPosition != nil || stats.matches == 0 {
                Text("No matches")
            } else {
                Text(stats.matches == 1 ? "1 match" : "\(stats.matches.formatted()) matches")
            }
            Button { model.stepMatch(forward: false) } label: { Image(systemName: "chevron.up") }
                .help("Previous match (⇧⌘G, ⇧Return in the search field)")
            Button { model.stepMatch(forward: true) } label: { Image(systemName: "chevron.down") }
                .help("Next match (⌘G, Return in the search field)")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            TextSettings()
                .tabItem { Label("Text", systemImage: "textformat") }
            ShortcutSettings()
                .tabItem { Label("Shortcuts", systemImage: "command") }
            SyncSettings()
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
        }
        .onDisappear { model.stopRecordingShortcut() }
        .frame(width: 520)
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Default layout", selection: $model.layout) {
                    ForEach(EditorLayout.allCases) { Text($0.label).tag($0) }
                }
                Picker("Sort notes by", selection: $model.sort) {
                    Text("Date Edited").tag(NoteSort.updated)
                    Text("Date Created").tag(NoteSort.created)
                    Text("Title").tag(NoteSort.title)
                }
                Toggle("Uncompleted to-dos on top", isOn: $model.uncompletedTodosOnTop)
                Toggle("Show the date and start of each note in the list", isOn: $model.showNotePreviews)
            }
            Section("Sidebar") {
                Toggle("Keep parent notebooks visible while scrolling", isOn: $model.stickyNotebooks)
            }
            Section("Tags") {
                Toggle("Show tags in the sidebar", isOn: $model.showSidebarTags)
                Toggle("Show tags above notes", isOn: $model.showNoteTags)
            }
            Section("Data") {
                LabeledContent("Location") {
                    Text(model.store.directory.path)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.store.directory])
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct TextSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Editor") {
                FontPicker(title: "Font", selection: $model.editorFont)
                SizeStepper(value: $model.editorFontSize)
                Toggle("Vim key bindings", isOn: $model.vimMode)
            }
            Section("Preview") {
                FontPicker(title: "Font", selection: $model.previewFont)
                SizeStepper(value: $model.previewFontSize)
                Toggle("Load images from the web", isOn: $model.loadRemoteImages)
            }
            Section {
                FontPicker(title: "Code font", selection: $model.codeFont)
                Toggle("Limit line length for easier reading", isOn: $model.readableWidth)
            } footer: {
                Text("⌘+ and ⌘− change the text size of the editor and the preview together, ⌘0 restores it.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct ShortcutSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                ForEach(ShortcutAction.allCases) { ShortcutRecorder(action: $0) }
            } header: {
                Text("Editor layout")
            } footer: {
                Text("Click a shortcut and press the new keys. Esc cancels, ⌫ removes the shortcut.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct FontPicker: View {
    let title: String
    @Binding var selection: FontFamily

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(FontFamily.systemDesigns) { Text($0.label).tag($0) }
            Divider()
            ForEach(FontFamily.installed) { Text($0.label).tag($0) }
        }
    }
}

struct SizeStepper: View {
    @Binding var value: Double

    var body: some View {
        LabeledContent("Size") {
            Stepper(value: $value, in: AppModel.fontSizes, step: 1) {
                Text("\(Int(value)) pt").monospacedDigit()
            }
        }
    }
}

struct SyncSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                TextField("Server URL", text: $model.syncURL, prompt: Text("https://joplin.example.com"))
                    .textContentType(.URL)
                TextField("Email", text: $model.syncEmail, prompt: Text("you@example.com"))
                    .textContentType(.username)
                SecureField("Password", text: $model.syncPassword)
                    .textContentType(.password)
                Picker("Sync automatically", selection: $model.syncInterval) {
                    Text("Manually").tag(0)
                    Text("Every minute").tag(1)
                    Text("Every 5 minutes").tag(5)
                    Text("Every 15 minutes").tag(15)
                    Text("Every hour").tag(60)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.syncStatusLine)
                        if !model.syncDetail.isEmpty {
                            Text(model.syncDetail).font(.caption).lineLimit(4)
                        }
                    }
                    .foregroundStyle(model.syncFailed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .textSelection(.enabled)
                    Spacer()
                    if model.isSyncing { ProgressView().controlSize(.small) }
                    Button("Sync Now") {
                        model.restartSyncTimer()
                        model.requestSync()
                    }
                    .disabled(!model.isSyncConfigured || model.isSyncing)
                }
            } header: {
                Text("Joplin Server")
            } footer: {
                Text("Uses the same sync target as the Joplin apps. End-to-end encrypted targets are not supported yet.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}
