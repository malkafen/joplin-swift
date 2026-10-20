import AppKit
import JoplinCore
import SwiftUI

@main
struct JoplinNativeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model = AppModel.shared

    var body: some Scene {
        Window("Joplin Native", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 480)
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            SidebarCommands()
            AppCommands(model: model)
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Replaced in tests so they never touch the real database.
    lazy var model: AppModel = .shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        Snapshot.scheduleIfRequested(model: model)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.flushSave()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension.lowercased() == "jex" { model.importJEX(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") { model.newNote() }
                .keyboardShortcut("n")
            Button("New To-do") { model.newNote(isTodo: true) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Notebook…") { model.promptNewFolder() }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }

        CommandGroup(after: .textEditing) {
            Button("Search All Notes") { model.focusSearch() }
                .keyboardShortcut("l")
        }

        CommandGroup(replacing: .saveItem) {
            Button("Synchronise") { model.requestSync() }
                .keyboardShortcut("s")
                .disabled(!model.isSyncConfigured || model.isSyncing)
        }

        CommandGroup(replacing: .importExport) {
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

        CommandGroup(after: .sidebar) {
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
            Toggle("Vim Mode", isOn: Binding(get: { model.vimMode }, set: { model.vimMode = $0 }))
                .keyboardShortcut("v", modifiers: [.command, .control, .option])
            Divider()
            Toggle("Show Tags in Sidebar", isOn: Binding(get: { model.showSidebarTags }, set: { model.showSidebarTags = $0 }))
                .keyboardShortcut("t", modifiers: [.command, .control])
            Toggle("Show Tags Above Notes", isOn: Binding(get: { model.showNoteTags }, set: { model.showNoteTags = $0 }))
            Divider()
        }

        CommandGroup(after: .toolbar) {
            Button("Actual Size") { model.resetTextSize() }
                .keyboardShortcut("0")
            Button("Zoom In") { model.adjustTextSize(by: 1) }
                .keyboardShortcut("+")
            Button("Zoom Out") { model.adjustTextSize(by: -1) }
                .keyboardShortcut("-")
            Divider()
        }

        CommandMenu("Note") {
            Button("Next Note") { model.selectAdjacentNote(1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Previous Note") { model.selectAdjacentNote(-1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Divider()
            Button("Edit Title") { model.focusTitle() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(model.currentNote == nil)
            Button("Edit Tags") { model.focusTags() }
                .keyboardShortcut("k", modifiers: [.command, .option])
                .disabled(model.currentNote == nil)
            Button("Attach File…") { model.attachFilesWithPanel() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(model.currentNote == nil)
            Divider()
            Button(model.currentNote?.todoCompleted ?? 0 > 0 ? "Mark as Not Done" : "Mark as Done") {
                model.toggleCurrentTodoCompleted()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.currentNote?.isTodo != true)
            Button(model.currentNote?.isTodo == true ? "Switch to Note" : "Switch to To-do") { model.toggleCurrentIsTodo() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(model.currentNote == nil)
            Button("Duplicate") { model.duplicate(model.selectedNoteIDs) }
                .keyboardShortcut("d")
                .disabled(model.selectedNoteIDs.isEmpty || model.isTrashSelected)
            Button("Copy Markdown Link") { model.copyMarkdownLinks(model.selectedNoteIDs) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(model.selectedNoteIDs.isEmpty)
            Divider()
            Button(model.isTrashSelected ? "Delete Permanently…" : "Move to Trash") { model.deleteSelectedNotes() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.selectedNoteIDs.isEmpty)
            Button("Empty Trash…") { model.emptyTrash() }
        }

        CommandMenu("Format") {
            Button("Bold") { model.editor.wrap("**", placeholder: "bold text") }
                .keyboardShortcut("b")
            Button("Italic") { model.editor.wrap("*", placeholder: "italic text") }
                .keyboardShortcut("i")
            Button("Strikethrough") { model.editor.wrap("~~", placeholder: "text") }
                .keyboardShortcut("x", modifiers: [.command, .shift])
            Button("Highlight") { model.editor.wrap("==", placeholder: "text") }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Inline Code") { model.editor.wrap("`", placeholder: "code") }
                .keyboardShortcut("e")
            Button("Link") { model.editor.wrap("[", "](https://)", placeholder: "link text") }
                .keyboardShortcut("k")
            Divider()
            Button("Heading 1") { model.editor.toggleLinePrefix("# ") }
                .keyboardShortcut("1", modifiers: [.command, .option])
            Button("Heading 2") { model.editor.toggleLinePrefix("## ") }
                .keyboardShortcut("2", modifiers: [.command, .option])
            Button("Heading 3") { model.editor.toggleLinePrefix("### ") }
                .keyboardShortcut("3", modifiers: [.command, .option])
            Divider()
            Button("Bulleted List") { model.editor.toggleLinePrefix("- ") }
                .keyboardShortcut("8", modifiers: [.command, .shift])
            Button("Numbered List") { model.editor.toggleLinePrefix("1. ") }
                .keyboardShortcut("7", modifiers: [.command, .shift])
            Button("Checklist") { model.editor.toggleLinePrefix("- [ ] ") }
                .keyboardShortcut("9", modifiers: [.command, .shift])
            Button("Quote") { model.editor.toggleLinePrefix("> ") }
                .keyboardShortcut("'", modifiers: [.command, .shift])
            Divider()
            Button("Code Block") { model.editor.wrap("```\n", "\n```", placeholder: "code") }
            Button("Math Formula") { model.editor.wrap("$", placeholder: "E = mc^2") }
                .keyboardShortcut("m", modifiers: [.command, .control])
            Button("Table") { model.editor.insertBlock("| Column | Column |\n|--------|--------|\n|        |        |\n") }
            Button("Horizontal Rule") { model.editor.insertBlock("\n---\n") }
            Button("Insert Date and Time") {
                model.editor.insert(Date().formatted(date: .numeric, time: .shortened))
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
        }
    }
}

/// Debug aid: JN_SNAPSHOT=/path.png renders the main window to a PNG (no screen-recording permission needed).
@MainActor
enum Snapshot {
    /// `JN_IMPORT_DESKTOP` is "1" for the default Joplin Desktop profile, or a profile directory.
    static func scheduleIfRequested(model: AppModel, env: [String: String] = ProcessInfo.processInfo.environment,
                                    quit: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }) {
        guard let path = env["JN_SNAPSHOT"] else { return }
        let delay = Double(env["JN_SNAPSHOT_DELAY"] ?? "") ?? 3
        if let profile = env["JN_IMPORT_DESKTOP"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + min(0.5, delay / 4)) {
                MainActor.assumeIsolated {
                    model.importJoplinDesktop(profile: profile == "1" ? Store.joplinDesktopProfile : URL(fileURLWithPath: profile))
                }
            }
        }
        if let query = env["JN_SEARCH"] { model.searchText = query }
        if env["JN_VIM"] == "1" { model.vimMode = true }
        if env["JN_EXPAND_ALL"] == "1" { model.expandAllFolders() }
        if let offset = Double(env["JN_SIDEBAR_SCROLL"] ?? "") {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay * 0.7) {
                MainActor.assumeIsolated {
                    if let content = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView {
                        scrollSidebar(in: content, to: offset)
                    }
                }
            }
        }
        if let layout = env["JN_LAYOUT"].flatMap(EditorLayout.init(rawValue:)) { model.layout = layout }
        if let appearance = env["JN_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        if let index = Int(env["JN_SELECT_INDEX"] ?? "") {
            DispatchQueue.main.asyncAfter(deadline: .now() + min(1, delay / 2)) {
                MainActor.assumeIsolated {
                    if model.notes.indices.contains(index) { model.selectedNoteIDs = [model.notes[index].id] }
                }
            }
        }
        if let keys = env["JN_VIM_KEYS"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay * 0.8) {
                MainActor.assumeIsolated {
                    guard let content = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView,
                          let vim = editor(in: content)?.vim else { return }
                    for c in keys { vim.handle(key: c == "\n" ? "\r" : String(c)) }
                }
            }
        }
                if let fraction = Double(env["JN_SCROLL"] ?? "") {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay * 0.75) {
                MainActor.assumeIsolated {
                    if let content = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView {
                        scrollAll(in: content, to: fraction)
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
               let rep = windowServerImage(window) ?? cachedImage(window) {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            if env["JN_SNAPSHOT_QUIT"] == "1" { quit() }
        }
    }

    static func editor(in view: NSView) -> MarkdownTextView? {
        if let tv = view as? MarkdownTextView { return tv }
        for sub in view.subviews { if let tv = editor(in: sub) { return tv } }
        return nil
    }

    /// Scrolls the sidebar's list (the scroll view holding the notebook rows) by `offset` points from its top.
    static func scrollSidebar(in view: NSView, to offset: Double) {
        func find(_ v: NSView) -> FolderMarkerView? {
            if let marker = v as? FolderMarkerView { return marker }
            for sub in v.subviews { if let m = find(sub) { return m } }
            return nil
        }
        guard let scroll = find(view)?.enclosingScrollView else { return }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(offset) - scroll.contentInsets.top))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Scrolls every text scroll view to `fraction` of its height (0 top, 1 bottom).
    static func scrollAll(in view: NSView, to fraction: Double) {
        if let scroll = view as? NSScrollView, let doc = scroll.documentView, doc is NSTextView {
            let maxY = max(0, doc.frame.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: maxY * fraction))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        view.subviews.forEach { scrollAll(in: $0, to: fraction) }
    }

    /// The composited window (materials, toolbar), as the user sees it. Capturing the app's own windows needs no
    /// screen-recording permission. The API is unavailable to Swift on macOS 15+, hence the dynamic lookup.
    static func windowServerImage(_ window: NSWindow) -> NSBitmapImageRep? {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        let includingWindow: UInt32 = 1 << 3, boundsIgnoreFraming: UInt32 = 1 << 0, bestResolution: UInt32 = 1 << 3
        guard let image = create(.null, includingWindow, UInt32(window.windowNumber), boundsIgnoreFraming | bestResolution)?
            .takeRetainedValue() else { return nil }
        return NSBitmapImageRep(cgImage: image)
    }

    static func cachedImage(_ window: NSWindow) -> NSBitmapImageRep? {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
}
