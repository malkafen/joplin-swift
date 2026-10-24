import JoplinCore
import SwiftUI

extension AppModel {
    func reloadSidebar() {
        folders = store.folders()
        trashedFolders = store.folders(deleted: true)
        folderTree = Self.buildTree(folders)
        sticky.parentOf = Dictionary(folders.map { ($0.id, $0.parentId) }, uniquingKeysWith: { a, _ in a })
        flatFolders = Self.flatten(folderTree)
        tags = store.tags()
        folderCounts = store.noteCountsByFolder()
        allNotesCount = store.totalNoteCount
        trashCount = store.trashedNoteCount
    }

    static func buildTree(_ folders: [Folder]) -> [FolderNode] {
        let ids = Set(folders.map(\.id))
        let byParent = Dictionary(grouping: folders) { ids.contains($0.parentId) && $0.parentId != $0.id ? $0.parentId : "" }
        func nodes(_ parent: String, depth: Int) -> [FolderNode] {
            (byParent[parent] ?? []).map { f in
                let kids = depth < 32 ? nodes(f.id, depth: depth + 1) : []
                return FolderNode(folder: f, children: kids.isEmpty ? nil : kids)
            }
        }
        return nodes("", depth: 0)
    }

    static func flatten(_ nodes: [FolderNode], depth: Int = 0) -> [FlatFolder] {
        nodes.flatMap { [FlatFolder(folder: $0.folder, depth: depth)] + flatten($0.children ?? [], depth: depth + 1) }
    }

    func expansion(of id: String) -> Binding<Bool> {
        Binding(get: { self.expandedFolders.contains(id) },
                set: { expanded in
                    if expanded { self.expandedFolders.insert(id) } else { self.expandedFolders.remove(id) }
                })
    }

    func expandAllFolders() {
        let parents = Set(folders.map(\.parentId))
        expandedFolders = Set(folders.map(\.id).filter(parents.contains))
    }

    func collapseAllFolders() {
        expandedFolders = []
    }

    var hasSearch: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var currentFilter: NoteFilter {
        if hasSearch { return .search(searchText) }
        switch sidebarSelection {
        case .folder(let id): return .folder(id)
        case .tag(let id): return .tag(id)
        case .trash: return .trash
        default: return .all
        }
    }

    var isTrashSelected: Bool { sidebarSelection == .trash && searchText.isEmpty }

    var isNothingChosen: Bool { sidebarSelection == nil && !hasSearch }

    var listTitle: String {
        if !searchText.isEmpty { return "Search" }
        switch sidebarSelection {
        case .folder(let id): return folders.first { $0.id == id }?.title ?? "Notebook"
        case .tag(let id): return tags.first { $0.id == id }.map { "#\($0.title)" } ?? "Tag"
        case .trash: return "Trash"
        case .allNotes: return "All Notes"
        case nil: return "Notes"
        }
    }

    var listSubtitle: String {
        if isNothingChosen { return "" }
        return noteCount == 1 ? "1 note" : "\(noteCount) notes"
    }

    func folderPath(_ id: String) -> String {
        (StickyFolders.ancestors(of: id, parentOf: sticky.parentOf) + [id]).map(folderTitle).joined(separator: " › ")
    }

    func folderTitle(_ id: String) -> String {
        folders.first { $0.id == id }?.title ?? "No notebook"
    }

    func searchNow() {
        pendingSearch?.cancel()
        pendingSearch = nil
        reloadNotes(selectFirst: true)
    }

    func reloadNotes(selectFirst: Bool) {
        flushSave()
        notes = isNothingChosen ? [] : store.notes(filter: currentFilter, sort: sort, uncompletedTodosOnTop: uncompletedTodosOnTop)
        if searchTerms != listSearchTerms { listSearchTerms = searchTerms }
        let visible = Set(notes.map(\.id))
        let valid = selectedNoteIDs.intersection(visible)
        if valid.isEmpty, selectFirst, let first = notes.first {
            selectedNoteIDs = [first.id]
        } else if valid != selectedNoteIDs {
            selectedNoteIDs = valid
        } else {
            refreshCurrentNote()
        }
    }

    func loadSelection() {
        searchPosition = nil
        saveInBackground()
        if let term = searchTerms.first, selectedNoteIDs.count == 1 {
            findPasteboard.clearContents()
            findPasteboard.setString(term, forType: .string)
        }
        if selectedNoteIDs.count == 1, let id = selectedNoteIDs.first, let note = loadNote(id) {
            currentNote = note
            reloadCurrentTags(id)
        } else {
            currentNote = nil
            currentTags = []
        }
    }

    func reloadCurrentTags(_ id: String) {
        let titles = store.tags(forNote: id).map(\.title)
        if titles != currentTags { currentTags = titles }
    }

    private func loadNote(_ id: String) -> Note? {
        if savingNotes[id] != nil { waitForSaves() }
        let loaded = store.noteAndStamp(id: id)
        loadedStamp = loaded.map { (id, $0.stamp) }
        return loaded?.note
    }

    private func refreshCurrentNote() {
        guard let current = storedNote else { return }
        let id = current.id
        if let loaded = loadedStamp, loaded.id == id, store.bodyStamp(id: id) == loaded.stamp,
           var note = store.noteWithoutBody(id: id) {
            note.body = current.body
            if note != current { currentNote = note }
            reloadCurrentTags(id)
        } else if let note = loadNote(id) {
            currentNote = note
            reloadCurrentTags(id)
        } else {
            currentNote = nil
            currentTags = []
        }
    }

    func reloadAll(select ids: Set<String>? = nil) {
        reloadSidebar()
        if !isSelectionValid { sidebarSelection = .allNotes }
        reloadNotes(selectFirst: ids == nil)
        guard let ids else { return }
        let visible = ids.intersection(notes.map(\.id))
        if !visible.isEmpty {
            selectedNoteIDs = visible
        } else if selectedNoteIDs.isEmpty, let first = notes.first {
            selectedNoteIDs = [first.id]
        }
    }

    private var isSelectionValid: Bool {
        switch sidebarSelection {
        case .folder(let id): return folders.contains { $0.id == id }
        case .tag(let id): return tags.contains { $0.id == id }
        default: return true
        }
    }

    func selectAdjacentNote(_ step: Int) {
        guard !notes.isEmpty else { return }
        let current = notes.firstIndex { selectedNoteIDs.contains($0.id) }
        let target = current.map { min(max($0 + step, 0), notes.count - 1) } ?? (step > 0 ? 0 : notes.count - 1)
        selectedNoteIDs = [notes[target].id]
    }

    func openItem(id: String) {
        if let note = store.note(id: id) {
            if !notes.contains(where: { $0.id == id }) {
                clearSearchSilently()
                let target: SidebarItem = note.deletedTime > 0 ? .trash : .folder(note.parentId)
                if sidebarSelection != target { sidebarSelection = target } else { reloadNotes(selectFirst: false) }
            }
            selectedNoteIDs = [id]
        } else if let resource = store.resource(id: id) {
            openURL(store.url(for: resource))
        } else {
            alert = AlertInfo(title: "Item not found", message: "No note or attachment with id \(id).")
        }
    }
}
