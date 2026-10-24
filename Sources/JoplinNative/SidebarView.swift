import JoplinCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebarSelection) {
            AllNotesRow()
            NotebooksHeader()
            FolderTreeRows(nodes: model.folderTree)
            SidebarTags()
            SidebarTrash()
        }
        .listStyle(.sidebar)
        .overlay(alignment: .top) { StickyFolderHeader() }
        .safeAreaInset(edge: .bottom, spacing: 0) { SyncStatusBar() }
    }
}

private struct AllNotesRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Label("All Notes", systemImage: "note.text")
            .badge(model.allNotesCount)
            .tag(SidebarItem.allNotes)
    }
}

private struct NotebooksHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
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
    }
}

private struct SidebarTags: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
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
    }
}

private struct SidebarTrash: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            if model.trashedFolders.isEmpty {
                trashRow
            } else {
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

    private var trashRow: some View {
        Label("Trash", systemImage: "trash")
            .badge(model.trashCount)
            .tag(SidebarItem.trash)
            .contextMenu {
                Button("Empty Trash", role: .destructive) { model.emptyTrash() }
            }
    }
}

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
            .contextMenu { FolderMenu(folder: node.folder) }
    }
}

struct FolderMenu: View {
    let folder: Folder
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("New Note") { model.newNote(inFolder: folder.id) }
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
        let tint = model.syncFailed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary)
        HStack(spacing: 8) {
            if model.isSyncConfigured {
                Button {
                    model.requestSync()
                } label: {
                    Image(systemName: model.syncFailed ? "exclamationmark.arrow.triangle.2.circlepath" : "arrow.triangle.2.circlepath")
                        .foregroundStyle(tint)
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
                .foregroundStyle(tint)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(model.syncHelp)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

struct FolderRow: View {
    let folder: Folder
    var accentIcon = false

    var body: some View {
        Label {
            Text(folder.title.isEmpty ? "Untitled" : folder.title)
        } icon: {
            if let emoji = folder.emoji {
                Text(emoji)
            } else if accentIcon {
                Image(systemName: "folder").foregroundStyle(Color.accentColor)
            } else {
                Image(systemName: "folder")
            }
        }
    }
}
