import AppKit
import Foundation
@testable import JoplinCore
import SwiftUI
import Testing
@testable import JoplinNative

/// App-level glue: delegate callbacks, menu commands, debug snapshot hook, file-based model actions.
@MainActor
@Suite(.serialized) struct AppShellTests {
    @Test func delegateFlushesAndOpensJEXFiles() throws {
        let source = try Store(directory: temporaryDirectory())
        try source.createFolder(title: "From file")
        let jex = temporaryDirectory().appendingPathComponent("drop.JEX")
        _ = try source.exportJEX(to: jex)

        let h = try ModelHarness()
        let delegate = AppDelegate()
        delegate.model = h.model
        let id = try #require(h.model.currentNote?.id)
        h.model.updateBody("unsaved")
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        #expect(h.store.note(id: id)?.body == "unsaved")

        delegate.application(NSApplication.shared, open: [jex, URL(fileURLWithPath: "/tmp/other.txt")])
        #expect(h.model.folders.contains { $0.title == "From file" })
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    }

    @Test func snapshotHook() async throws {
        let profile = temporaryDirectory()
        try Store(directory: profile).createNote(parentId: "", title: "profile note")
        let h = try ModelHarness()
        let model = h.model
        let png = temporaryDirectory().appendingPathComponent("shot.png")

        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 900, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView().environment(model))
        window.orderFrontRegardless()
        defer { window.close() }

        var quitCalled = false
        Snapshot.scheduleIfRequested(model: model, env: [:]) { quitCalled = true }
        Snapshot.scheduleIfRequested(model: model, env: [
            "JN_SNAPSHOT": png.path, "JN_SNAPSHOT_DELAY": "0.4", "JN_SNAPSHOT_QUIT": "1",
            "JN_SELECT_INDEX": "1", "JN_IMPORT_DESKTOP": profile.path,
        ]) { quitCalled = true }
        for _ in 0..<40 where !quitCalled {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(quitCalled)
        #expect(model.alert?.title == "Joplin Desktop profile imported")
        #expect(model.allNotesCount == 3)
        #expect(NSImage(contentsOf: png) != nil)
    }

    @Test func menuCommandsBuild() throws {
        let h = try ModelHarness()
        let model = h.model
        _ = AppCommands(model: model).body
        model.sidebarSelection = .folder(try #require(model.folders.first).id)
        model.trashNotes([try #require(model.currentNote).id])
        model.sidebarSelection = .trash
        _ = AppCommands(model: model).body
    }

    @Test func defaultModelLivesInApplicationSupport() throws {
        let base = temporaryDirectory()
        let model = AppModel.makeDefault(in: base)
        #expect(model.store.directory == base.appendingPathComponent("JoplinNative", isDirectory: true))
        #expect(FileManager.default.fileExists(atPath: model.store.directory.appendingPathComponent("database.sqlite").path))
    }

    @Test func attachInsertsAtTheCaretOrAppends() throws {
        let h = try ModelHarness(welcome: false)
        let note = try h.store.createNote(parentId: "", title: "n", body: "text")
        let model = h.model
        let file = temporaryDirectory().appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: file)

        model.selectedNoteIDs = []
        model.attach([file]) // no note selected
        #expect(try h.store.rows(.resource).isEmpty)

        model.selectedNoteIDs = [note.id]
        model.layout = .preview
        model.attach([file])
        #expect(model.currentNote?.body.hasPrefix("text\n[a.txt](:/") == true)

        model.updateBody("")
        model.attach([file])
        #expect(model.currentNote?.body.hasPrefix("[a.txt](:/") == true)

        let tv = NSTextView()
        tv.string = "caret"
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        model.editor.textView = tv
        model.layout = .editor
        model.attach([file])
        #expect(tv.string.hasPrefix("[a.txt](:/"))
        #expect(tv.string.hasSuffix(")caret"))
    }

    @Test func rawImportAndJEXExport() throws {
        let h = try ModelHarness()
        let model = h.model
        let folder = try #require(model.folders.first)
        let dir = temporaryDirectory()

        model.exportJEX(to: dir.appendingPathComponent("all.jex"), folderId: nil)
        #expect(model.alert?.title == "Export complete")
        #expect(model.alert?.message == "5 items written to all.jex.")
        model.exportJEX(to: dir.appendingPathComponent("folder.jex"), folderId: folder.id)
        #expect(model.alert?.message == "5 items written to folder.jex.")
        model.exportJEX(to: dir.appendingPathComponent("missing/dir/x.jex"), folderId: nil)
        #expect(model.alert?.title == "Export failed")

        let raw = temporaryDirectory()
        try "Raw\n\nid: \(fixtureId(9))\ntype_: 2".write(to: raw.appendingPathComponent("\(fixtureId(9)).md"), atomically: true, encoding: .utf8)
        model.importRaw(raw)
        #expect(model.alert?.title == "\(raw.lastPathComponent) imported")
        #expect(model.folders.contains { $0.title == "Raw" })
    }
}

/// Minimal NSDraggingInfo so the editor's drop handling can be exercised without a real drag session.
private final class FakeDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    init(_ pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { NSPoint(x: 5, y: 5) }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

@MainActor
@Suite struct EditorDropTests {
    @Test func droppedFilesAreInsertedAtTheDropPoint() throws {
        let tv = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        tv.string = "body"
        let pb = NSPasteboard(name: NSPasteboard.Name("jn-drag-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let file = temporaryDirectory().appendingPathComponent("drop.txt")
        try Data("d".utf8).write(to: file)

        tv.onDropFiles = { _ in "[drop.txt](:/x)" }
        pb.clearContents()
        pb.writeObjects([file as NSURL])
        #expect(tv.performDragOperation(FakeDrag(pb)))
        #expect(tv.string.contains("[drop.txt](:/x)"))

        // Plain text drags fall through to NSTextView.
        pb.clearContents()
        pb.setString("x", forType: .string)
        _ = tv.performDragOperation(FakeDrag(pb))
        #expect(tv.string.contains("body"))
    }
}
