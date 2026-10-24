import AppKit
import JoplinCore

extension AppModel {
    func newNote(isTodo: Bool = false) {
        flushSave()
        var parent: String
        switch sidebarSelection {
        case .folder(let id): parent = id
        default: parent = currentNote?.parentId ?? folders.first?.id ?? ""
        }
        if parent.isEmpty || !folders.contains(where: { $0.id == parent }) {
            parent = (try? store.defaultFolderId()) ?? ""
        }
        perform {
            let note = try store.createNote(parentId: parent, isTodo: isTodo)
            if case .tag(let tagId) = sidebarSelection, let tag = tags.first(where: { $0.id == tagId }) {
                try store.setTags(noteId: note.id, titles: [tag.title])
            } else if sidebarSelection == .trash || sidebarSelection == nil {
                sidebarSelection = .folder(parent)
            }
            clearSearchSilently()
            reloadAll(select: [note.id])
            titleFocusRequest += 1
        }
    }

    func setTodoCompleted(_ id: String, _ completed: Bool) {
        if id == currentNote?.id { flushSave() }
        perform { try store.setTodoCompleted(id: id, completed: completed) }
        reloadNotes(selectFirst: false)
    }

    func toggleCurrentTodoCompleted() {
        guard let note = noteInfo, note.isTodo else { return }
        setTodoCompleted(note.id, note.todoCompleted == 0)
    }

    func toggleCurrentIsTodo() {
        guard let note = noteInfo else { return }
        setIsTodo([note.id], !note.isTodo)
    }

    func setIsTodo(_ ids: Set<String>, _ isTodo: Bool) {
        flushSave()
        perform { try store.setIsTodo(ids: Array(ids), isTodo: isTodo) }
        reloadNotes(selectFirst: false)
    }

    func moveNotes(_ ids: Set<String>, to folderId: String) {
        flushSave()
        perform { try store.moveNotes(ids: Array(ids), toFolder: folderId) }
        reloadAll(select: selectedNoteIDs)
    }

    func duplicate(_ ids: Set<String>) {
        flushSave()
        var created: Set<String> = []
        perform {
            for id in ids {
                if let n = try store.duplicateNote(id: id) { created.insert(n.id) }
            }
        }
        reloadAll(select: created)
    }

    func trashNotes(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        flushSave()
        perform { try store.trashNotes(ids: Array(ids)) }
        reloadAll()
    }

    func restoreNotes(_ ids: Set<String>) {
        flushSave()
        perform { try store.restoreNotes(ids: Array(ids)) }
        reloadAll()
    }

    func deleteNotesPermanently(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        confirmation = Confirmation(
            title: ids.count == 1 ? "Delete this note permanently?" : "Delete \(ids.count) notes permanently?",
            message: "This cannot be undone.",
            destructiveLabel: "Delete"
        ) { [weak self] in
            guard let self else { return }
            self.perform { try self.store.deleteNotesPermanently(ids: Array(ids)) }
            self.reloadAll()
        }
    }

    func deleteSelectedNotes() {
        if isTrashSelected {
            deleteNotesPermanently(selectedNoteIDs)
        } else {
            trashNotes(selectedNoteIDs)
        }
    }

    func emptyTrash() {
        confirmation = Confirmation(title: "Empty Trash?", message: "All notes and notebooks in the trash will be deleted permanently.",
                                    destructiveLabel: "Empty Trash") { [weak self] in
            guard let self else { return }
            self.perform { try self.store.emptyTrash() }
            self.reloadAll()
        }
    }

    func copyMarkdownLinks(_ ids: Set<String>) {
        let links = notes.filter { ids.contains($0.id) }.map { "[\($0.title.isEmpty ? "Untitled" : $0.title)](:/\($0.id))" }
        pasteboard.clearContents()
        pasteboard.setString(links.joined(separator: "\n"), forType: .string)
    }

    func dropOnFolder(_ items: [String], folderId: String) -> Bool {
        var noteIds: Set<String> = []
        for item in items {
            if item.hasPrefix("folder:") {
                let id = String(item.dropFirst("folder:".count))
                perform { try store.moveFolder(id: id, toParent: folderId) }
            } else {
                noteIds.insert(item)
            }
        }
        if noteIds.count == 1, let id = noteIds.first, selectedNoteIDs.contains(id) {
            noteIds = selectedNoteIDs
        }
        if !noteIds.isEmpty {
            moveNotes(noteIds, to: folderId)
        } else {
            reloadAll(select: selectedNoteIDs)
        }
        return true
    }

    func newNote(inFolder id: String) {
        sidebarSelection = .folder(id)
        newNote()
    }

    func promptNewFolder(parent: String = "") {
        textPrompt = TextPrompt(title: parent.isEmpty ? "New Notebook" : "New Sub-notebook", placeholder: "Notebook name",
                                initial: "", confirmLabel: "Create") { [weak self] name in
            guard let self, let title = Self.cleanName(name) else { return }
            self.perform {
                let folder = try self.store.createFolder(title: title, parentId: parent)
                self.reloadSidebar()
                if !parent.isEmpty { self.expandedFolders.insert(parent) }
                self.sidebarSelection = .folder(folder.id)
            }
        }
    }

    func promptRenameFolder(_ folder: Folder) {
        textPrompt = TextPrompt(title: "Rename Notebook", placeholder: "Notebook name", initial: folder.title,
                                confirmLabel: "Rename") { [weak self] name in
            guard let self, let title = Self.cleanName(name) else { return }
            self.perform { try self.store.renameFolder(id: folder.id, title: title) }
            self.reloadSidebar()
        }
    }

    func trashFolder(_ folder: Folder) {
        flushSave()
        perform { try store.trashFolder(id: folder.id) }
        reloadAll()
    }

    func restoreFolder(_ folder: Folder) {
        perform { try store.restoreFolder(id: folder.id) }
        reloadAll()
    }

    func deleteFolderPermanently(_ folder: Folder) {
        confirmation = Confirmation(title: "Delete “\(folder.title)” permanently?",
                                    message: "The notebook, its sub-notebooks and all their notes will be deleted. This cannot be undone.",
                                    destructiveLabel: "Delete") { [weak self] in
            guard let self else { return }
            self.perform { try self.store.deleteFolderPermanently(id: folder.id) }
            self.reloadAll()
        }
    }

    func setCurrentTags(_ titles: [String]) {
        guard let note = noteInfo else { return }
        let normalized = titles.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        guard Set(normalized) != Set(currentTags) else { return }
        perform { try store.setTags(noteId: note.id, titles: normalized) }
        reloadCurrentTags(note.id)
        tags = store.tags()
    }

    func promptRenameTag(_ tag: Tag) {
        textPrompt = TextPrompt(title: "Rename Tag", placeholder: "Tag", initial: tag.title, confirmLabel: "Rename") { [weak self] name in
            guard let self, let title = Self.cleanName(name) else { return }
            self.perform { try self.store.renameTag(id: tag.id, title: title) }
            self.reloadAll(select: self.selectedNoteIDs)
        }
    }

    func deleteTag(_ tag: Tag) {
        perform { try store.deleteTag(id: tag.id) }
        reloadAll(select: selectedNoteIDs)
    }

    private static func cleanName(_ name: String) -> String? {
        let title = name.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }
}
