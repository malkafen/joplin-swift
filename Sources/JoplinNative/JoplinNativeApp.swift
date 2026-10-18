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
        .commands { AppCommands(model: model) }

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
        model.theme.apply()
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
            Button("Editor Only") { model.layout = .editor }
                .keyboardShortcut("1", modifiers: [.command, .control])
            Button("Editor and Preview") { model.layout = .split }
                .keyboardShortcut("2", modifiers: [.command, .control])
            Button("Preview Only") { model.layout = .preview }
                .keyboardShortcut("3", modifiers: [.command, .control])
            Button("Toggle Editor Layout") { model.cycleLayout() }
                .keyboardShortcut("l", modifiers: .control)
            Divider()
        }

        CommandMenu("Note") {
            Button("Attach File…") { model.attachFilesWithPanel() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(model.currentNote == nil)
            Button(model.currentNote?.isTodo == true ? "Switch to Note" : "Switch to To-do") { model.toggleCurrentIsTodo() }
                .disabled(model.currentNote == nil)
            Button("Copy Markdown Link") { model.copyMarkdownLinks(model.selectedNoteIDs) }
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
                                    quit: @escaping () -> Void = { NSApp.terminate(nil) }) {
        guard let path = env["JN_SNAPSHOT"] else { return }
        let delay = Double(env["JN_SNAPSHOT_DELAY"] ?? "") ?? 3
        if let profile = env["JN_IMPORT_DESKTOP"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + min(0.5, delay / 4)) {
                MainActor.assumeIsolated {
                    model.importJoplinDesktop(profile: profile == "1" ? Store.joplinDesktopProfile : URL(fileURLWithPath: profile))
                }
            }
        }
        if let index = Int(env["JN_SELECT_INDEX"] ?? "") {
            DispatchQueue.main.asyncAfter(deadline: .now() + min(1, delay / 2)) {
                MainActor.assumeIsolated {
                    if model.notes.indices.contains(index) { model.selectedNoteIDs = [model.notes[index].id] }
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
