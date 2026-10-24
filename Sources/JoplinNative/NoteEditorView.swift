import JoplinCore
import SwiftUI

struct NoteEditorView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var titleFocused: Bool

    var body: some View {
        Group {
            if let note = model.noteInfo {
                NoteDetail(note: note, titleFocus: $titleFocused)
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
            if let note = model.noteInfo {
                ToolbarItemGroup(placement: .primaryAction) {
                    LayoutPicker()

                    Button {
                        model.attachFilesWithPanel()
                    } label: {
                        Label("Attach File", systemImage: "paperclip")
                    }
                    .help("Attach file (⇧⌘A)")
                    .disabled(note.inTrash)
                }
            }
        }
        .onChange(of: model.titleFocusRequest) {
            titleFocused = true
        }
    }
}

private struct LayoutPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Picker("Layout", selection: $model.layout) {
            ForEach(EditorLayout.allCases) { layout in
                Label(layout.label, systemImage: layout.symbol).tag(layout)
            }
        }
        .pickerStyle(.segmented)
        .help(model.hotkey(for: .cycleLayout).map { "Editor layout (\($0.display))" } ?? "Editor layout")
    }
}

private struct NoteDetail: View {
    let note: NoteInfo
    var titleFocus: FocusState<Bool>.Binding
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if note.inTrash {
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
            NoteHeader(note: note, titleFocus: titleFocus)
            Divider()
            NoteContent(noteId: note.id, inTrash: note.inTrash)
            Divider()
            NoteFooter(noteId: note.id, created: note.userCreatedTime)
        }
    }
}

private struct NoteHeader: View {
    let note: NoteInfo
    var titleFocus: FocusState<Bool>.Binding
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if note.isTodo {
                    Toggle("", isOn: Binding(get: { note.todoCompleted > 0 }, set: { model.setTodoCompleted(note.id, $0) }))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .controlSize(.large)
                }
                TitleField(inTrash: note.inTrash, focus: titleFocus)
            }
            HStack(spacing: 10) {
                NoteFolderMenu(note: note)
                NoteTagsField()
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
}

private struct TitleField: View {
    let inTrash: Bool
    var focus: FocusState<Bool>.Binding
    @Environment(AppModel.self) private var model

    var body: some View {
        TextField("Untitled", text: Binding(get: { model.currentNote?.title ?? "" }, set: { model.updateTitle($0) }))
            .textFieldStyle(.plain)
            .font(Font(model.editorFont.font(size: 22, weight: .bold)))
            .focused(focus)
            .disabled(inTrash)
            .onSubmit { model.editor.focus() }
    }
}

private struct NoteFolderMenu: View {
    let note: NoteInfo
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            MoveToFolderItems { model.moveNotes([note.id], to: $0) }
        } label: {
            Label(model.folderTitle(note.parentId), systemImage: "folder")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(note.inTrash)
        .help("Move to notebook")
    }
}

private struct NoteTagsField: View {
    @Environment(AppModel.self) private var model

    var body: some View {
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
    }
}

private struct NoteContent: View {
    let noteId: String
    let inTrash: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        NoteSplitView(layout: model.layout,
                      editor: EditorPane(noteId: noteId, inTrash: inTrash).environment(model),
                      preview: PreviewPane(noteId: noteId).environment(model))
    }
}

private struct EditorPane: View {
    @Environment(AppModel.self) private var model
    var noteId: String
    var inTrash: Bool

    var body: some View {
        MarkdownEditor(
            text: model.currentBody,
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
        .overlay(alignment: .bottomTrailing) { VimModeBadge() }
    }
}

private struct VimModeBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.vimMode {
            let insert = model.vimState == .insert
            Text(model.vimState.label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(insert ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(insert ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.accentColor),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .padding(10)
                .allowsHitTesting(false)
        }
    }
}

private struct PreviewPane: View {
    @Environment(AppModel.self) private var model
    var noteId: String

    var body: some View {
        let shown = model.layout != .editor
        let _ = shown ? model.bodyRevision : 0
        MarkdownPreview(markdown: model.currentBody, noteId: noteId, renderer: model.renderer,
                        isShown: shown, readableWidth: model.readableWidth,
                        highlights: model.searchTerms, stepper: model.searchStepper, onLink: { model.handleLink($0) })
    }
}

struct NoteStats: Equatable, Sendable {
    var lines = 0
    var words = 0
    var characters = 0
    var matches = 0

    init() {}

    init(_ text: String, terms: [String]) {
        var lines = text.isEmpty ? 0 : 1, words = 0, inWord = false
        for b in text.utf8 {
            if b == 10 { lines += 1 }
            let wordByte = b >= 0x80 || (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95
            if wordByte, !inWord { words += 1 }
            inWord = wordByte || (inWord && b == 39)
        }
        self.lines = lines
        self.words = words
        characters = text.count
        matches = terms.isEmpty ? 0 : SearchHighlight.ranges(of: terms, in: text).count
    }

    var readingMinutes: Int { Int((Double(words) / 200).rounded()) }

    func summary(created: Int64) -> String {
        var parts: [String] = []
        if created > 0 {
            parts.append("Created " + Date(timeIntervalSince1970: Double(created) / 1000).formatted(date: .abbreviated, time: .omitted))
        }
        parts.append(Self.count(lines, "line"))
        parts.append(Self.count(words, "word"))
        parts.append(Self.count(characters, "character"))
        if readingMinutes > 0 { parts.append("\(readingMinutes.formatted()) min read") }
        return parts.joined(separator: "  ·  ")
    }

    func matchLabel(position: SearchPosition?) -> String {
        if let position, position.count > 0 {
            return "\((position.index + 1).formatted()) of \(position.count.formatted())"
        }
        if position != nil || matches == 0 { return "No matches" }
        return matches == 1 ? "1 match" : "\(matches.formatted()) matches"
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        "\(n.formatted()) \(noun)\(n == 1 ? "" : "s")"
    }
}

private struct NoteFooter: View {
    @Environment(AppModel.self) private var model
    var noteId: String
    var created: Int64
    @State private var stats = NoteStats()

    var body: some View {
        let terms = model.searchTerms
        HStack(spacing: 12) {
            Text(stats.summary(created: created))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(created > 0 ? "Created \(longDate(created))" : "")
            Spacer(minLength: 8)
            if !terms.isEmpty {
                SearchMatches(stats: stats)
                    .layoutPriority(1)
            }
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 24)
        .frame(height: 24)
        .task(id: StatsKey(noteId: noteId, revision: model.bodyRevision, terms: terms)) {
            let body = model.currentBody
            if body.quickLength > 50_000 {
                try? await Task.sleep(for: .milliseconds(300))
                if Task.isCancelled { return }
            }
            let counted = await Task.detached(priority: .utility) { NoteStats(body, terms: terms) }.value
            if !Task.isCancelled, counted != stats { stats = counted }
        }
    }

    private struct StatsKey: Equatable {
        var noteId: String
        var revision: Int
        var terms: [String]
    }
}

private struct SearchMatches: View {
    let stats: NoteStats
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 2) {
            Text(stats.matchLabel(position: model.searchPosition))
            Button { model.stepMatch(forward: false) } label: { Image(systemName: "chevron.up") }
                .help("Previous match (⇧⌘G, ⇧Return in the search field)")
            Button { model.stepMatch(forward: true) } label: { Image(systemName: "chevron.down") }
                .help("Next match (⌘G, Return in the search field)")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }
}
