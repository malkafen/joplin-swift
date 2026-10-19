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
                    model.promptNewFolder()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("New Notebook")
            }

            OutlineGroup(model.folderTree, children: \.children) { node in
                FolderRow(folder: node.folder)
                    .badge(model.folderCounts[node.id] ?? 0)
                    .tag(SidebarItem.folder(node.id))
                    .draggable("folder:\(node.id)")
                    .dropDestination(for: String.self) { items, _ in
                        model.dropOnFolder(items, folderId: node.id)
                    }
                    .contextMenu { folderMenu(node.folder) }
            }

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
                Label("Trash", systemImage: "trash")
                    .badge(model.trashCount)
                    .tag(SidebarItem.trash)
                    .contextMenu {
                        Button("Empty Trash", role: .destructive) { model.emptyTrash() }
                    }
                ForEach(model.trashedFolders) { folder in
                    Label(folder.title, systemImage: "folder")
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                        .contextMenu {
                            Button("Restore Notebook") { model.restoreFolder(folder) }
                            Button("Delete Permanently…", role: .destructive) { model.deleteFolderPermanently(folder) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { SyncStatusBar() }
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
    }
}

struct FolderRow: View {
    let folder: Folder

    var body: some View {
        Label {
            Text(folder.title.isEmpty ? "Untitled" : folder.title)
        } icon: {
            if let emoji = folder.emoji {
                Text(emoji)
            } else {
                Image(systemName: "folder")
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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if note.isTodo {
                Toggle("", isOn: Binding(get: { done }, set: { model.setTodoCompleted(note.id, $0) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(note.title.isEmpty ? "Untitled" : note.title)
                    .font(.system(size: 13, weight: .semibold))
                    .strikethrough(done)
                    .foregroundStyle(done ? .secondary : .primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(shortDate(note.userUpdatedTime))
                        .foregroundStyle(.primary.opacity(0.75))
                    Text(note.snippet.isEmpty ? "No additional text" : note.snippet)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .font(.system(size: 12))
            }
        }
        .padding(.vertical, 4)
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

struct NoteEditorView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var titleFocused: Bool

    var body: some View {
        @Bindable var model = model
        Group {
            if let note = model.currentNote {
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
                    .help("Editor layout (⌃L)")

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
    private func editor(_ note: Note) -> some View {
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
        }
    }

    private func header(_ note: Note, inTrash: Bool) -> some View {
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
                        TagField(tags: model.currentTags, allTags: model.tags.map(\.title)) { model.setCurrentTags($0) }
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

    @ViewBuilder
    private func content(_ note: Note, inTrash: Bool) -> some View {
        switch model.layout {
        case .editor:
            editorPane(note, inTrash: inTrash)
        case .preview:
            previewPane(note)
        case .split:
            HSplitView {
                editorPane(note, inTrash: inTrash).frame(minWidth: 220)
                previewPane(note).frame(minWidth: 220)
            }
        }
    }

    private func editorPane(_ note: Note, inTrash: Bool) -> some View {
        MarkdownEditor(
            text: note.body,
            noteId: note.id,
            typography: model.editorTypography,
            readableWidth: model.readableWidth,
            isEditable: !inTrash,
            bridge: model.editor,
            onChange: { model.updateBody($0) },
            onDropFiles: { model.attachmentMarkdown(for: $0) },
            onPasteImage: { model.pastedImageMarkdown($0) }
        )
    }

    private func previewPane(_ note: Note) -> some View {
        MarkdownPreview(markdown: note.body, noteId: note.id, renderer: model.renderer,
                        readableWidth: model.readableWidth, onLink: { model.handleLink($0) })
    }
}

// MARK: - Settings

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            TextSettings()
                .tabItem { Label("Text", systemImage: "textformat") }
            SyncSettings()
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
        }
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
