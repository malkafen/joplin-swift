import AppKit
import JoplinCore
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    static let shared = ProcessInfo.processInfo.environment["JN_DATA_DIR"]
        .map { AppModel.makeDefault(in: URL(fileURLWithPath: $0, isDirectory: true)) } ?? AppModel.makeDefault()

    let store: Store
    @ObservationIgnored let editor = EditorBridge()
    @ObservationIgnored let searchStepper = SearchStepper()
    @ObservationIgnored let sticky = StickyFolders()
    var searchPosition: SearchPosition?

    var folders: [Folder] = []
    var folderTree: [FolderNode] = []
    var flatFolders: [FlatFolder] = []
    var trashedFolders: [Folder] = []
    var tags: [Tag] = []
    var folderCounts: [String: Int] = [:]
    var allNotesCount = 0
    var trashCount = 0
    var notes: [NoteSummary] = [] {
        didSet { if notes.count != noteCount { noteCount = notes.count } }
    }
    private(set) var noteCount = 0
    var listSearchTerms: [String] = []

    @ObservationIgnored var storedNote: Note?
    var currentNote: Note? {
        get {
            access(keyPath: \.currentNote)
            return storedNote
        }
        set {
            let old = storedNote
            withMutation(keyPath: \.currentNote) { storedNote = newValue }
            let info = newValue.map(NoteInfo.init)
            if info != noteInfo { noteInfo = info }
            if old?.id != newValue?.id || old?.body != newValue?.body {
                withMutation(keyPath: \.currentBody) {}
            }
        }
    }

    var currentBody: String {
        access(keyPath: \.currentBody)
        return storedNote?.body ?? ""
    }

    private(set) var noteInfo: NoteInfo?
    var currentTags: [String] = []
    var titleFocusRequest = 0
    var bodyRevision = 0
    @ObservationIgnored var summaryOutdated = false

    var alert: AlertInfo?
    var textPrompt: TextPrompt? {
        didSet { if let textPrompt { promptText = textPrompt.initial } }
    }
    var promptText = ""
    var confirmation: Confirmation?

    var sidebarSelection: SidebarItem? = .allNotes {
        didSet {
            guard oldValue != sidebarSelection, !restoring else { return }
            clearSearchSilently()
            reloadNotes(selectFirst: true)
        }
    }

    var searchText = "" {
        didSet {
            guard oldValue != searchText else { return }
            let terms = SearchHighlight.terms(searchText)
            if terms != searchTerms { searchTerms = terms }
            searchPosition = nil
            pendingSearch?.cancel()
            pendingSearch = nil
            guard !searchSilently else { return }
            guard searchDelay > 0, !searchText.isEmpty else { return searchNow() }
            let item = DispatchWorkItem { [weak self] in self?.searchNow() }
            pendingSearch = item
            DispatchQueue.main.asyncAfter(deadline: .now() + searchDelay, execute: item)
        }
    }
    private(set) var searchTerms: [String] = []
    @ObservationIgnored var searchDelay: TimeInterval = 0.15
    @ObservationIgnored var pendingSearch: DispatchWorkItem?
    @ObservationIgnored private var searchSilently = false

    var selectedNoteIDs: Set<String> = [] {
        didSet {
            guard oldValue != selectedNoteIDs else { return }
            loadSelection()
        }
    }

    var sort: NoteSort = .updated {
        didSet {
            persist(sort.rawValue, "sort")
            if !restoring { reloadNotes(selectFirst: false) }
        }
    }

    var uncompletedTodosOnTop = true {
        didSet {
            persist(uncompletedTodosOnTop, "todosOnTop")
            if !restoring { reloadNotes(selectFirst: false) }
        }
    }

    var layout: EditorLayout = .editor {
        didSet { persist(layout.rawValue, "layout") }
    }

    var editorFont: FontFamily = .system {
        didSet { persist(editorFont.name, "editorFont") }
    }

    var editorFontSize: Double = 14 {
        didSet { persist(editorFontSize, "editorFontSize") }
    }

    var previewFont: FontFamily = .system {
        didSet {
            persist(previewFont.name, "previewFont")
            rebuildRenderer()
        }
    }

    var previewFontSize: Double = 15 {
        didSet {
            persist(previewFontSize, "previewFontSize")
            rebuildRenderer()
        }
    }

    var codeFont: FontFamily = .monospaced {
        didSet {
            persist(codeFont.name, "codeFont")
            rebuildRenderer()
        }
    }

    var readableWidth = true {
        didSet { persist(readableWidth, "readableWidth") }
    }

    var loadRemoteImages = true {
        didSet {
            persist(loadRemoteImages, "loadRemoteImages")
            rebuildRenderer()
        }
    }

    var showSidebarTags = true {
        didSet { persist(showSidebarTags, "showSidebarTags") }
    }

    var sidebarTagsExpanded = true {
        didSet { persist(sidebarTagsExpanded, "sidebarTagsExpanded") }
    }

    var expandedFolders: Set<String> = []

    var stickyNotebooks = true {
        didSet {
            persist(stickyNotebooks, "stickyNotebooks")
            sticky.enabled = stickyNotebooks
        }
    }

    var vimMode = false {
        didSet {
            persist(vimMode, "vimMode")
            if !vimMode { vimState = .insert }
        }
    }

    var vimState: VimEngine.Mode = .normal

    var trashExpanded = false {
        didSet { persist(trashExpanded, "trashExpanded") }
    }

    var showNoteTags = true {
        didSet { persist(showNoteTags, "showNoteTags") }
    }

    var showNotePreviews = false {
        didSet { persist(showNotePreviews, "showNotePreviews") }
    }

    var shortcuts: [ShortcutAction: Hotkey?] = [:]
    var recordingShortcut: ShortcutAction?
    @ObservationIgnored var shortcutMonitor: Any?

    var syncURL = "" {
        didSet { saveSyncSetting("sync.url", syncURL) }
    }

    var syncEmail = "" {
        didSet { saveSyncSetting("sync.email", syncEmail) }
    }

    var syncPassword = "" {
        didSet { saveSyncSetting("sync.password", syncPassword) }
    }

    var syncInterval = 5 {
        didSet {
            guard !restoring else { return }
            store.setSetting("sync.interval", String(syncInterval))
            restartSyncTimer()
        }
    }

    var isSyncing = false
    var syncStatus = ""
    var syncDetail = ""
    var syncFailed = false
    var lastSyncTime: Int64 = 0

    private(set) var renderer: MarkdownRenderer

    @ObservationIgnored var saveTask: Task<Void, Never>?
    @ObservationIgnored var pendingSave = false
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let pasteboard: NSPasteboard
    @ObservationIgnored var findPasteboard = NSPasteboard(name: .find)
    @ObservationIgnored let openURL: (URL) -> Void
    @ObservationIgnored let syncTransport: HTTPTransport
    @ObservationIgnored var syncTimer: Task<Void, Never>?
    @ObservationIgnored var autoSyncTask: Task<Void, Never>?
    @ObservationIgnored var syncRequestedWhileRunning = false
    @ObservationIgnored var syncClient: (client: JoplinServerClient, credentials: [String])?
    @ObservationIgnored var autoSyncDelay: Duration = .seconds(10)
    @ObservationIgnored var loadedStamp: (id: String, stamp: Store.BodyStamp)?
    @ObservationIgnored let saveQueue = DispatchQueue(label: "io.github.malkafen.JoplinNative.save", qos: .userInitiated)
    @ObservationIgnored lazy var writer: SQLiteDB? = try? store.makeWriter()
    @ObservationIgnored var savingNotes: [String: Int] = [:]
    @ObservationIgnored weak var tagField: NSTokenField?
    @ObservationIgnored var remoteImages: (URL) -> NSImage? = { RemoteImageLoader.shared.image(for: $0) } {
        didSet { rebuildRenderer() }
    }
    @ObservationIgnored private var restoring = true

    init(store: Store, defaults: UserDefaults = .standard, pasteboard: NSPasteboard = .general,
         syncTransport: HTTPTransport = URLSessionTransport(), startsEmpty: Bool = false,
         openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.store = store
        self.defaults = defaults
        self.pasteboard = pasteboard
        self.syncTransport = syncTransport
        self.openURL = openURL
        renderer = MarkdownRenderer(typography: Typography(), resolveResource: { _ in nil })
        searchStepper.onStep = { [weak self] in self?.searchPosition = $0 }
        restoreSettings()
        if store.setting("welcome_created") == nil {
            createWelcomeContent()
            store.setSetting("welcome_created", "1")
        }
        if startsEmpty { sidebarSelection = nil }
        restoring = false
        rebuildRenderer()
        reloadSidebar()
        reloadNotes(selectFirst: !startsEmpty)
        restartSyncTimer()
    }

    private func restoreSettings() {
        sort = NoteSort(rawValue: defaults.string(forKey: "sort") ?? "") ?? .updated
        uncompletedTodosOnTop = defaults.object(forKey: "todosOnTop") as? Bool ?? true
        layout = EditorLayout(rawValue: defaults.string(forKey: "layout") ?? "") ?? .editor
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
        restoreShortcuts()
        syncURL = store.setting("sync.url") ?? ""
        syncEmail = store.setting("sync.email") ?? ""
        syncPassword = store.setting("sync.password") ?? ""
        syncInterval = Int(store.setting("sync.interval") ?? "") ?? 5
        lastSyncTime = Int64(store.setting("sync.last_time") ?? "") ?? 0
    }

    private func persist(_ value: Any, _ key: String) {
        guard !restoring else { return }
        defaults.set(value, forKey: key)
    }

    private func saveSyncSetting(_ key: String, _ value: String) {
        guard !restoring else { return }
        store.setSetting(key, value)
        syncCredentialsChanged()
    }

    private func rebuildRenderer() {
        guard !restoring else { return }
        let store = self.store
        renderer = MarkdownRenderer(typography: previewTypography, resolveResource: { id in
            store.resource(id: id).map { ($0, store.url(for: $0)) }
        }, remoteImage: loadRemoteImages ? remoteImages : nil)
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

    func clearSearchSilently() {
        guard !searchText.isEmpty else { return }
        searchSilently = true
        searchText = ""
        searchSilently = false
    }
}
