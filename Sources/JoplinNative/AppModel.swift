import AppKit
import JoplinCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct FolderNode: Identifiable, Hashable {
    let folder: Folder
    var children: [FolderNode]?
    var id: String { folder.id }
}

enum SidebarItem: Hashable {
    case allNotes
    case folder(String)
    case tag(String)
    case trash
}

enum EditorLayout: String, CaseIterable, Identifiable {
    case editor, split, preview

    var id: String { rawValue }

    var label: String {
        switch self {
        case .editor: return "Editor"
        case .split: return "Split"
        case .preview: return "Preview"
        }
    }

    var symbol: String {
        switch self {
        case .editor: return "pencil.line"
        case .split: return "rectangle.split.2x1"
        case .preview: return "eye"
        }
    }
}

struct AlertInfo: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

struct TextPrompt: Identifiable {
    let id = UUID()
    var title: String
    var placeholder: String
    var initial: String
    var confirmLabel: String
    var action: (String) -> Void
}

struct Confirmation: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var destructiveLabel: String
    var action: () -> Void
}

@MainActor
@Observable
final class AppModel {
    static let shared = ProcessInfo.processInfo.environment["JN_DATA_DIR"]
        .map { AppModel.makeDefault(in: URL(fileURLWithPath: $0, isDirectory: true)) } ?? AppModel.makeDefault()

    let store: Store
    @ObservationIgnored let editor = EditorBridge()
    @ObservationIgnored let searchStepper = SearchStepper()
    var searchPosition: SearchPosition?
    @ObservationIgnored let sticky = StickyFolders()

    private(set) var folders: [Folder] = []
    private(set) var folderTree: [FolderNode] = []
    private(set) var flatFolders: [(folder: Folder, depth: Int)] = []
    private(set) var trashedFolders: [Folder] = []
    private(set) var tags: [Tag] = []
    private(set) var folderCounts: [String: Int] = [:]
    private(set) var allNotesCount = 0
    private(set) var trashCount = 0
    private(set) var notes: [NoteSummary] = []
    @ObservationIgnored private var storedNote: Note?
    private(set) var currentNote: Note? {
        get {
            access(keyPath: \.currentNote)
            return storedNote
        }
        set {
            withMutation(keyPath: \.currentNote) { storedNote = newValue }
        }
    }
    private(set) var currentTags: [String] = []
    private(set) var titleFocusRequest = 0

    var alert: AlertInfo?
    var textPrompt: TextPrompt? {
        didSet { if let textPrompt { promptText = textPrompt.initial } }
    }
    var promptText = ""
    var confirmation: Confirmation?

    var sidebarSelection: SidebarItem? = .allNotes {
        didSet {
            guard oldValue != sidebarSelection else { return }
            if !searchText.isEmpty { searchText = "" }
            reloadNotes(selectFirst: true)
        }
    }

    var searchText = "" {
        didSet {
            guard oldValue != searchText else { return }
            searchPosition = nil
            pendingSearch?.cancel()
            guard searchDelay > 0, !searchText.isEmpty else { return searchNow() }
            let item = DispatchWorkItem { [weak self] in self?.searchNow() }
            pendingSearch = item
            DispatchQueue.main.asyncAfter(deadline: .now() + searchDelay, execute: item)
        }
    }
    @ObservationIgnored var searchDelay: TimeInterval = 0.15
    @ObservationIgnored private var pendingSearch: DispatchWorkItem?

    func stepMatch(forward: Bool) {
        guard currentNote != nil, let tv = layout == .preview ? searchStepper.preview : searchStepper.editor else { return }
        searchStepper.step(forward: forward, in: tv)
    }

    func findInNote(in window: NSWindow? = nil) {
        let window = window ?? NSApp.keyWindow
        let preview = searchStepper.preview
        let inPreview = layout == .preview || (preview != nil && window?.firstResponder === preview)
        guard currentNote != nil, let tv = inPreview ? preview : searchStepper.editor, let window = tv.window else {
            NSSound.beep()
            return
        }
        window.makeFirstResponder(tv)
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        tv.performTextFinderAction(item)
    }

    func searchNow() {
        pendingSearch?.cancel()
        pendingSearch = nil
        reloadNotes(selectFirst: true)
    }

    var selectedNoteIDs: Set<String> = [] {
        didSet {
            guard oldValue != selectedNoteIDs else { return }
            loadSelection()
        }
    }

    var sort: NoteSort = .updated {
        didSet {
            defaults.set(sort.rawValue, forKey: "sort")
            reloadNotes(selectFirst: false)
        }
    }

    var uncompletedTodosOnTop = true {
        didSet {
            defaults.set(uncompletedTodosOnTop, forKey: "todosOnTop")
            reloadNotes(selectFirst: false)
        }
    }

    var layout: EditorLayout = .editor {
        didSet { defaults.set(layout.rawValue, forKey: "layout") }
    }

    var editorFont: FontFamily = .system {
        didSet { defaults.set(editorFont.name, forKey: "editorFont") }
    }

    var editorFontSize: Double = 14 {
        didSet { defaults.set(editorFontSize, forKey: "editorFontSize") }
    }

    var previewFont: FontFamily = .system {
        didSet { defaults.set(previewFont.name, forKey: "previewFont") }
    }

    var previewFontSize: Double = 15 {
        didSet { defaults.set(previewFontSize, forKey: "previewFontSize") }
    }

    var codeFont: FontFamily = .monospaced {
        didSet { defaults.set(codeFont.name, forKey: "codeFont") }
    }

    var readableWidth = true {
        didSet { defaults.set(readableWidth, forKey: "readableWidth") }
    }

    var loadRemoteImages = true {
        didSet { defaults.set(loadRemoteImages, forKey: "loadRemoteImages") }
    }

    var showSidebarTags = true {
        didSet { defaults.set(showSidebarTags, forKey: "showSidebarTags") }
    }

    var sidebarTagsExpanded = true {
        didSet { defaults.set(sidebarTagsExpanded, forKey: "sidebarTagsExpanded") }
    }

    var expandedFolders: Set<String> = []

    func expansion(of id: String) -> Binding<Bool> {
        Binding(get: { self.expandedFolders.contains(id) },
                set: { expanded in
                    if expanded { self.expandedFolders.insert(id) } else { self.expandedFolders.remove(id) }
                })
    }

    func expandAllFolders() {
        expandedFolders = Set(folders.filter { f in folders.contains { $0.parentId == f.id } }.map(\.id))
    }

    func collapseAllFolders() {
        expandedFolders = []
    }

    var stickyNotebooks = true {
        didSet {
            defaults.set(stickyNotebooks, forKey: "stickyNotebooks")
            sticky.enabled = stickyNotebooks
        }
    }

    var vimMode = false {
        didSet {
            defaults.set(vimMode, forKey: "vimMode")
            if !vimMode { vimState = .insert }
        }
    }

    var vimState: VimEngine.Mode = .normal

    var trashExpanded = false {
        didSet { defaults.set(trashExpanded, forKey: "trashExpanded") }
    }

    var showNoteTags = true {
        didSet { defaults.set(showNoteTags, forKey: "showNoteTags") }
    }

    var showNotePreviews = false {
        didSet { defaults.set(showNotePreviews, forKey: "showNotePreviews") }
    }

    private(set) var shortcuts: [ShortcutAction: Hotkey?] = [:]
    private(set) var recordingShortcut: ShortcutAction?
    @ObservationIgnored private var shortcutMonitor: Any?

    func hotkey(for action: ShortcutAction) -> Hotkey? {
        if let custom = shortcuts[action] { return custom }
        return action.defaultHotkey
    }

    func setHotkey(_ hotkey: Hotkey?, for action: ShortcutAction) {
        shortcuts[action] = .some(hotkey)
        defaults.set(hotkey?.storage ?? "", forKey: action.defaultsKey)
    }

    func resetShortcut(_ action: ShortcutAction) {
        shortcuts[action] = nil
        defaults.removeObject(forKey: action.defaultsKey)
    }

    func shortcutConflict(for action: ShortcutAction) -> String? {
        guard let key = hotkey(for: action) else { return nil }
        if let other = ShortcutAction.allCases.first(where: { $0 != action && hotkey(for: $0) == key }) { return other.title }
        return ShortcutAction.reserved[key]
    }

    func startRecordingShortcut(_ action: ShortcutAction) {
        stopRecordingShortcut()
        recordingShortcut = action
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.recordShortcut(event) ? nil : event
        }
    }

    func stopRecordingShortcut() {
        if let monitor = shortcutMonitor { NSEvent.removeMonitor(monitor) }
        shortcutMonitor = nil
        recordingShortcut = nil
    }

    @discardableResult
    func recordShortcut(_ event: NSEvent) -> Bool {
        guard let action = recordingShortcut else { return false }
        let plain = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        if event.keyCode == 53 && plain {
            stopRecordingShortcut()
            return true
        }
        if (event.keyCode == 51 || event.keyCode == 117) && plain {
            setHotkey(nil, for: action)
            stopRecordingShortcut()
            return true
        }
        guard let hotkey = Hotkey(event: event) else {
            NSSound.beep()
            return true
        }
        setHotkey(hotkey, for: action)
        stopRecordingShortcut()
        return true
    }

    static let fontSizes: ClosedRange<Double> = 9...36

    var editorTypography: Typography {
        Typography(family: editorFont, size: CGFloat(editorFontSize), codeFamily: codeFont)
    }

    var previewTypography: Typography {
        Typography(family: previewFont, size: CGFloat(previewFontSize), codeFamily: codeFont)
    }

    func adjustTextSize(by step: Double) {
        let range = Self.fontSizes
        editorFontSize = min(range.upperBound, max(range.lowerBound, editorFontSize + step))
        previewFontSize = min(range.upperBound, max(range.lowerBound, previewFontSize + step))
    }

    func resetTextSize() {
        editorFontSize = 14
        previewFontSize = 15
    }

    var syncURL = "" {
        didSet { store.setSetting("sync.url", syncURL) }
    }

    var syncEmail = "" {
        didSet { store.setSetting("sync.email", syncEmail) }
    }

    var syncPassword = "" {
        didSet { store.setSetting("sync.password", syncPassword) }
    }

    var syncInterval = 5 {
        didSet {
            store.setSetting("sync.interval", String(syncInterval))
            restartSyncTimer()
        }
    }

    private(set) var isSyncing = false
    private(set) var syncStatus = ""
    private(set) var syncDetail = ""
    private(set) var syncFailed = false
    private(set) var lastSyncTime: Int64 = 0

    var isSyncConfigured: Bool {
        !syncURL.trimmingCharacters(in: .whitespaces).isEmpty && !syncEmail.isEmpty && !syncPassword.isEmpty
    }

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSave = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let pasteboard: NSPasteboard
    @ObservationIgnored var findPasteboard = NSPasteboard(name: .find)
    @ObservationIgnored let openURL: (URL) -> Void
    @ObservationIgnored let syncTransport: HTTPTransport
    @ObservationIgnored private var syncTimer: Task<Void, Never>?
    @ObservationIgnored private var autoSyncTask: Task<Void, Never>?
    @ObservationIgnored private var syncRequestedWhileRunning = false
    @ObservationIgnored var autoSyncDelay: Duration = .seconds(10)

    init(store: Store, defaults: UserDefaults = .standard, pasteboard: NSPasteboard = .general,
         syncTransport: HTTPTransport = URLSessionTransport(), startsEmpty: Bool = false,
         openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.store = store
        self.defaults = defaults
        self.pasteboard = pasteboard
        self.syncTransport = syncTransport
        self.openURL = openURL
        sort = NoteSort(rawValue: defaults.string(forKey: "sort") ?? "") ?? .updated
        uncompletedTodosOnTop = defaults.object(forKey: "todosOnTop") as? Bool ?? true
        layout = EditorLayout(rawValue: defaults.string(forKey: "layout") ?? "") ?? .editor
        searchStepper.onStep = { [weak self] in self?.searchPosition = $0 }
        editorFontSize = defaults.object(forKey: "editorFontSize") as? Double ?? 14
        editorFont = defaults.string(forKey: "editorFont").map(FontFamily.init(name:))
            ?? (defaults.bool(forKey: "editorMonospaced") ? .monospaced : .system)
        previewFont = defaults.string(forKey: "previewFont").map(FontFamily.init(name:)) ?? .system
        previewFontSize = defaults.object(forKey: "previewFontSize") as? Double ?? 15
        codeFont = defaults.string(forKey: "codeFont").map(FontFamily.init(name:)) ?? .monospaced
        readableWidth = defaults.object(forKey: "readableWidth") as? Bool ?? true
        loadRemoteImages = defaults.object(forKey: "loadRemoteImages") as? Bool ?? true
        showSidebarTags = defaults.object(forKey: "showSidebarTags") as? Bool ?? true
        sidebarTagsExpanded = defaults.object(forKey: "sidebarTagsExpanded") as? Bool ?? true
        showNoteTags = defaults.object(forKey: "showNoteTags") as? Bool ?? true
        showNotePreviews = defaults.bool(forKey: "showNotePreviews")
        trashExpanded = defaults.bool(forKey: "trashExpanded")
        vimMode = defaults.bool(forKey: "vimMode")
        stickyNotebooks = defaults.object(forKey: "stickyNotebooks") as? Bool ?? true
        for action in ShortcutAction.allCases {
            guard let stored = defaults.string(forKey: action.defaultsKey) else { continue }
            let hotkey = Hotkey(storage: stored)
            if let latin = hotkey?.latinized() {
                setHotkey(latin, for: action)
            } else {
                shortcuts[action] = .some(hotkey)
            }
        }
        syncURL = store.setting("sync.url") ?? ""
        syncEmail = store.setting("sync.email") ?? ""
        syncPassword = store.setting("sync.password") ?? ""
        syncInterval = Int(store.setting("sync.interval") ?? "") ?? 5
        lastSyncTime = Int64(store.setting("sync.last_time") ?? "") ?? 0
        if store.setting("welcome_created") == nil {
            createWelcomeContent()
            store.setSetting("welcome_created", "1")
        }
        if startsEmpty { sidebarSelection = nil }
        reloadSidebar()
        reloadNotes(selectFirst: !startsEmpty)
    }

    static func makeDefault(
        in base: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    ) -> AppModel {
        let dir = base.appendingPathComponent("JoplinNative", isDirectory: true)
        do {
            return AppModel(store: try Store(directory: dir), startsEmpty: true)
        } catch {
            fatalError("Cannot open database at \(dir.path): \(error)")
        }
    }

    @ObservationIgnored var remoteImages: (URL) -> NSImage? = { RemoteImageLoader.shared.image(for: $0) }

    var renderer: MarkdownRenderer {
        let store = self.store
        return MarkdownRenderer(typography: previewTypography, resolveResource: { id in
            store.resource(id: id).map { ($0, store.url(for: $0)) }
        }, remoteImage: loadRemoteImages ? remoteImages : nil)
    }

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

    static func flatten(_ nodes: [FolderNode], depth: Int = 0) -> [(folder: Folder, depth: Int)] {
        nodes.flatMap { [($0.folder, depth)] + flatten($0.children ?? [], depth: depth + 1) }
    }

    var currentFilter: NoteFilter {
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty { return .search(searchText) }
        switch sidebarSelection {
        case .folder(let id): return .folder(id)
        case .tag(let id): return .tag(id)
        case .trash: return .trash
        default: return .all
        }
    }

    var searchTerms: [String] {
        SearchHighlight.terms(searchText)
    }

    var isTrashSelected: Bool { sidebarSelection == .trash && searchText.isEmpty }

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

    func folderPath(_ id: String) -> String {
        (StickyFolders.ancestors(of: id, parentOf: sticky.parentOf) + [id]).map(folderTitle).joined(separator: " › ")
    }

    func folderTitle(_ id: String) -> String {
        folders.first { $0.id == id }?.title ?? "No notebook"
    }

    var isNothingChosen: Bool { sidebarSelection == nil && searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    func reloadNotes(selectFirst: Bool) {
        flushSave()
        notes = isNothingChosen ? [] : store.notes(filter: currentFilter, sort: sort, uncompletedTodosOnTop: uncompletedTodosOnTop)
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

    private func loadSelection() {
        searchPosition = nil
        saveInBackground()
        if let term = searchTerms.first, selectedNoteIDs.count == 1 {
            findPasteboard.clearContents()
            findPasteboard.setString(term, forType: .string)
        }
        if selectedNoteIDs.count == 1, let id = selectedNoteIDs.first, let note = loadNote(id) {
            currentNote = note
            currentTags = store.tags(forNote: id).map(\.title)
        } else {
            currentNote = nil
            currentTags = []
        }
    }

    @ObservationIgnored private var loadedStamp: (id: String, stamp: Store.BodyStamp)?

    private func loadNote(_ id: String) -> Note? {
        if savingNotes[id] != nil { waitForSaves() }
        let loaded = store.noteAndStamp(id: id)
        loadedStamp = loaded.map { (id, $0.stamp) }
        return loaded?.note
    }

    private func refreshCurrentNote() {
        guard let current = currentNote else { return }
        let id = current.id
        if let loaded = loadedStamp, loaded.id == id, store.bodyStamp(id: id) == loaded.stamp,
           var note = store.noteWithoutBody(id: id) {
            note.body = current.body
            if note != current { currentNote = note }
            currentTags = store.tags(forNote: id).map(\.title)
        } else if let note = loadNote(id) {
            currentNote = note
            currentTags = store.tags(forNote: id).map(\.title)
        } else {
            currentNote = nil
        }
    }

    private func reloadAll(select ids: Set<String>? = nil) {
        reloadSidebar()
        reloadNotes(selectFirst: ids == nil)
        guard let ids else { return }
        let visible = ids.intersection(notes.map(\.id))
        if !visible.isEmpty {
            selectedNoteIDs = visible
        } else if selectedNoteIDs.isEmpty, let first = notes.first {
            selectedNoteIDs = [first.id]
        }
    }

    func updateTitle(_ title: String) {
        guard var note = currentNote, note.title != title else { return }
        note.title = title
        currentNote = note
        patchSummary(note)
        scheduleSave()
    }

    func updateBody(_ body: String) {
        guard var note = currentNote else { return }
        note.body = body
        currentNote = note
        patchSummary(note)
        scheduleSave()
    }

    private(set) var bodyRevision = 0
    @ObservationIgnored private var summaryOutdated = false

    func editBody(_ body: String) {
        guard storedNote != nil else { return }
        storedNote!.body = body
        bodyRevision += 1
        summaryOutdated = true
        scheduleSave()
    }

    private func patchOutdatedSummary(_ note: Note) {
        guard summaryOutdated else { return }
        summaryOutdated = false
        patchSummary(note)
    }

    private func patchSummary(_ note: Note) {
        guard let i = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[i].title = note.title
        notes[i].snippet = Snippet.make(from: String(note.body.prefix(400)))
        notes[i].userUpdatedTime = Store.now()
    }

    private func scheduleSave() {
        pendingSave = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveInBackground()
        }
    }

    @ObservationIgnored private let saveQueue = DispatchQueue(label: "io.github.malkafen.JoplinNative.save", qos: .userInitiated)
    @ObservationIgnored private lazy var writer: SQLiteDB? = try? store.makeWriter()

    @ObservationIgnored private var savingNotes: [String: Int] = [:]

    private func saveInBackground() {
        saveTask?.cancel()
        saveTask = nil
        guard pendingSave, let note = currentNote else { return }
        guard let writer else { return flushSave() }
        pendingSave = false
        patchOutdatedSummary(note)
        savingNotes[note.id, default: 0] += 1
        nonisolated(unsafe) let db = writer
        saveQueue.async { [weak self] in
            var failure: String?
            let time = Store.now()
            do { try Store.saveNote(note, in: db, at: time) } catch { failure = "\(error)" }
            let stamp = Store.BodyStamp(updatedTime: time, body: note.body)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let count = self.savingNotes[note.id] { self.savingNotes[note.id] = count > 1 ? count - 1 : nil }
                    if let failure {
                        self.alert = AlertInfo(title: "Error", message: failure)
                    } else {
                        if self.currentNote?.id == note.id { self.loadedStamp = (note.id, stamp) }
                        self.scheduleAutoSync()
                    }
                }
            }
        }
    }

    private func waitForSaves() {
        saveQueue.sync {}
    }

    func flushSave() {
        saveTask?.cancel()
        saveTask = nil
        waitForSaves()
        guard pendingSave, let note = currentNote else { return }
        pendingSave = false
        patchOutdatedSummary(note)
        let time = Store.now()
        perform {
            try store.saveNote(note, at: time)
            loadedStamp = (note.id, Store.BodyStamp(updatedTime: time, body: note.body))
        }
    }

    private func perform(_ body: () throws -> Void) {
        waitForSaves()
        do {
            try body()
            scheduleAutoSync()
        } catch {
            alert = AlertInfo(title: "Error", message: "\(error)")
        }
    }

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
            searchText = ""
            reloadAll(select: [note.id])
            titleFocusRequest += 1
        }
    }

    func setTodoCompleted(_ id: String, _ completed: Bool) {
        if id == currentNote?.id { flushSave() }
        perform { try store.setTodoCompleted(id: id, completed: completed) }
        reloadNotes(selectFirst: false)
    }

    func toggleCurrentIsTodo() {
        guard let note = currentNote else { return }
        flushSave()
        perform { try store.setIsTodo(ids: [note.id], isTodo: !note.isTodo) }
        reloadNotes(selectFirst: false)
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

    func promptNewFolder(parent: String = "") {
        textPrompt = TextPrompt(title: parent.isEmpty ? "New Notebook" : "New Sub-notebook", placeholder: "Notebook name",
                                initial: "", confirmLabel: "Create") { [weak self] name in
            guard let self else { return }
            let title = name.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return }
            self.perform {
                let folder = try self.store.createFolder(title: title, parentId: parent)
                self.reloadSidebar()
                self.sidebarSelection = .folder(folder.id)
            }
        }
    }

    func promptRenameFolder(_ folder: Folder) {
        textPrompt = TextPrompt(title: "Rename Notebook", placeholder: "Notebook name", initial: folder.title,
                                confirmLabel: "Rename") { [weak self] name in
            guard let self else { return }
            let title = name.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return }
            self.perform { try self.store.renameFolder(id: folder.id, title: title) }
            self.reloadSidebar()
        }
    }

    func trashFolder(_ folder: Folder) {
        flushSave()
        perform { try store.trashFolder(id: folder.id) }
        if sidebarSelection == .folder(folder.id) { sidebarSelection = .allNotes }
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
        guard let note = currentNote else { return }
        let normalized = titles.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        guard Set(normalized) != Set(currentTags) else { return }
        perform { try store.setTags(noteId: note.id, titles: normalized) }
        currentTags = store.tags(forNote: note.id).map(\.title)
        tags = store.tags()
    }

    func promptRenameTag(_ tag: Tag) {
        textPrompt = TextPrompt(title: "Rename Tag", placeholder: "Tag", initial: tag.title, confirmLabel: "Rename") { [weak self] name in
            guard let self else { return }
            let title = name.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return }
            self.perform { try self.store.renameTag(id: tag.id, title: title) }
            self.reloadAll(select: self.selectedNoteIDs)
        }
    }

    func deleteTag(_ tag: Tag) {
        perform { try store.deleteTag(id: tag.id) }
        if sidebarSelection == .tag(tag.id) { sidebarSelection = .allNotes }
        reloadAll(select: selectedNoteIDs)
    }

    func attachmentMarkdown(for urls: [URL]) -> String? {
        var parts: [String] = []
        perform {
            for url in urls {
                let r = try store.addResource(fileAt: url)
                parts.append(r.isImage ? "![\(r.displayName)](:/\(r.id))" : "[\(r.displayName)](:/\(r.id))")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    func pastedImageMarkdown(_ png: Data) -> String? {
        var md: String?
        perform {
            let r = try store.addResource(data: png, filename: "Pasted image.png", mime: "image/png", fileExtension: "png")
            md = "![\(r.displayName)](:/\(r.id))"
        }
        return md
    }

    func attachFilesWithPanel() {
        guard currentNote != nil else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        attach(panel.urls)
    }

    func attach(_ urls: [URL]) {
        guard currentNote != nil, let md = attachmentMarkdown(for: urls) else { return }
        if editor.textView != nil, layout != .preview {
            editor.insert(md)
        } else if let note = currentNote {
            updateBody(note.body + (note.body.isEmpty || note.body.hasSuffix("\n") ? "" : "\n") + md)
        }
    }

    func handleLink(_ url: URL) {
        switch url.scheme {
        case "joplincheckbox":
            if let line = Int(url.host ?? "") { toggleCheckbox(line: line) }
        case "joplinitem":
            openItem(id: url.host ?? "")
        default:
            openURL(url)
        }
    }

    func openItem(id: String) {
        if let note = store.note(id: id) {
            if !notes.contains(where: { $0.id == id }) {
                searchText = ""
                sidebarSelection = note.deletedTime > 0 ? .trash : .folder(note.parentId)
            }
            selectedNoteIDs = [id]
        } else if let resource = store.resource(id: id) {
            openURL(store.url(for: resource))
        } else {
            alert = AlertInfo(title: "Item not found", message: "No note or attachment with id \(id).")
        }
    }

    func toggleCheckbox(line: Int) {
        guard let note = currentNote, note.deletedTime == 0 else { return }
        var lines = note.body.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count else { return }
        let s = lines[line - 1]
        if let r = s.range(of: "[ ]") {
            lines[line - 1] = s.replacingCharacters(in: r, with: "[x]")
        } else if let r = s.range(of: "[x]") ?? s.range(of: "[X]") {
            lines[line - 1] = s.replacingCharacters(in: r, with: "[ ]")
        } else {
            return
        }
        updateBody(lines.joined(separator: "\n"))
    }

    func selectAdjacentNote(_ step: Int) {
        guard !notes.isEmpty else { return }
        let current = notes.firstIndex { selectedNoteIDs.contains($0.id) }
        let target = current.map { min(max($0 + step, 0), notes.count - 1) } ?? (step > 0 ? 0 : notes.count - 1)
        selectedNoteIDs = [notes[target].id]
    }

    func toggleCurrentTodoCompleted() {
        guard let note = currentNote, note.isTodo else { return }
        setTodoCompleted(note.id, note.todoCompleted == 0)
    }

    func focusTitle() {
        titleFocusRequest += 1
    }

    @ObservationIgnored weak var tagField: NSTokenField?

    func focusTags() {
        if !showNoteTags { showNoteTags = true }
        DispatchQueue.main.async { [weak self] in
            guard let field = self?.tagField else { return }
            field.window?.makeFirstResponder(field)
        }
    }

    func focusSearch(in window: NSWindow? = nil) {
        guard let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
        if let item = window.toolbar?.items.compactMap({ $0 as? NSSearchToolbarItem }).first {
            item.beginSearchInteraction()
            return
        }
        func find(_ view: NSView) -> NSSearchField? {
            if let field = view as? NSSearchField { return field }
            for sub in view.subviews { if let f = find(sub) { return f } }
            return nil
        }
        if let root = window.contentView?.superview, let field = find(root) {
            window.makeFirstResponder(field)
        }
    }

    func cycleLayout() {
        let all = EditorLayout.allCases
        layout = all[(all.firstIndex(of: layout)! + 1) % all.count]
    }

    private func runImport(_ name: String, _ body: () throws -> ImportReport) {
        flushSave()
        do {
            let report = try body()
            reloadAll()
            var message = report.description
            if let first = report.errors.first { message += "\n\nFirst error: \(first)" }
            alert = AlertInfo(title: "\(name) imported", message: message)
        } catch {
            alert = AlertInfo(title: "Import failed", message: "\(error)")
        }
    }

    func importJoplinDesktop(profile: URL = Store.joplinDesktopProfile) {
        runImport("Joplin Desktop profile") { try store.importJoplinDesktopProfile(profile) }
    }

    func importJEXWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "jex") ?? .data]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importJEX(url)
    }

    func importJEX(_ url: URL) {
        runImport(url.lastPathComponent) { try store.importJEX(url) }
    }

    func importRawWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a Joplin RAW export directory or a Joplin file-system sync folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importRaw(url)
    }

    func importRaw(_ url: URL) {
        runImport(url.lastPathComponent) { try store.importDirectory(url) }
    }

    func exportJEXWithPanel(folderId: String?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "jex") ?? .data]
        let name = folderId.map { folderTitle($0) } ?? "Joplin Export"
        panel.nameFieldStringValue = "\(name).jex"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportJEX(to: url, folderId: folderId)
    }

    func exportJEX(to url: URL, folderId: String?) {
        flushSave()
        do {
            let count = try store.exportJEX(to: url, folderId: folderId)
            alert = AlertInfo(title: "Export complete", message: "\(count) items written to \(url.lastPathComponent).")
        } catch {
            alert = AlertInfo(title: "Export failed", message: "\(error)")
        }
    }

    var syncStatusLine: String {
        if isSyncing { return "Syncing…" }
        if !isSyncConfigured { return "Sync is off" }
        if !syncStatus.isEmpty { return syncStatus }
        return lastSyncTime > 0 ? "Synced \(shortDate(lastSyncTime))" : "Not synced yet"
    }

    func syncNow() async {
        guard isSyncConfigured else {
            syncFailed = true
            syncStatus = "Sync is not set up"
            syncDetail = SyncError.notConfigured.description
            return
        }
        guard !isSyncing else {
            syncRequestedWhileRunning = true
            return
        }
        autoSyncTask?.cancel()
        flushSave()
        isSyncing = true
        defer { isSyncing = false }
        await Task { await runSyncs() }.value
    }

    private func runSyncs() async {
        var again = true
        while again {
            do {
                let client = try JoplinServerClient(baseURL: syncURL, email: syncEmail, password: syncPassword, transport: syncTransport)
                let report = try await SyncEngine(store: store, client: client).sync()
                lastSyncTime = Store.now()
                syncFailed = false
                syncStatus = "Synced \(shortDate(lastSyncTime))"
                syncDetail = report.description.prefix(1).uppercased() + report.description.dropFirst()
                if report.downloaded + report.deletedLocally + report.conflicts > 0 {
                    reloadAll(select: selectedNoteIDs)
                }
            } catch {
                syncFailed = true
                syncStatus = "Sync failed"
                syncDetail = "\(error)"
                syncRequestedWhileRunning = false
            }
            again = syncRequestedWhileRunning
            syncRequestedWhileRunning = false
        }
    }

    func requestSync() {
        Task { await syncNow() }
    }

    private func scheduleAutoSync() {
        guard isSyncConfigured, syncInterval > 0 else { return }
        autoSyncTask?.cancel()
        let delay = autoSyncDelay
        autoSyncTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    func restartSyncTimer() {
        syncTimer?.cancel()
        syncTimer = nil
        guard isSyncConfigured, syncInterval > 0 else { return }
        let interval = Duration.seconds(syncInterval * 60)
        syncTimer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncNow()
                try? await Task.sleep(for: interval)
            }
        }
    }
}
