import AppKit
import Foundation
@testable import JoplinCore
import SwiftUI
import Testing
@testable import JoplinNative

@MainActor
final class HostedView<V: View> {
    let host: NSHostingView<V>
    let window: NSWindow

    init(_ view: V, size: CGSize = CGSize(width: 1200, height: 760)) {
        _ = NSApplication.shared
        host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        pump()
    }

    func pump(_ seconds: Double = 0.15) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
        }
    }

    func views<T: NSView>(_ type: T.Type, in view: NSView? = nil) -> [T] {
        (view ?? host).subviews.flatMap { ($0 as? T).map { [$0] } ?? [] + views(type, in: $0) }
    }

    func close() {
        window.close()
    }
}

private final class FlippedDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
@Suite(.serialized) struct ShellViewTests {
    @Test func stickyHeaderShowsPinnedNotebooks() throws {
        let h = try ModelHarness(welcome: false)
        let model = h.model
        let a = try h.store.createFolder(title: "Alpha")
        let b = try h.store.createFolder(title: "Beta", parentId: a.id)
        let c = try h.store.createFolder(title: "Gamma", parentId: b.id)
        model.reloadSidebar()

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        let document = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 200, height: 28 * 8))
        scroll.documentView = document
        window.contentView?.addSubview(scroll)
        for (i, id) in [a.id, b.id, c.id].enumerated() {
            let marker = FolderMarkerView(frame: NSRect(x: CGFloat(i) * 16, y: CGFloat(i) * 28, width: 100, height: 28))
            marker.folderId = id
            marker.tracker = model.sticky
            document.addSubview(marker)
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 60))
        model.sticky.update()
        #expect(model.sticky.ids.first == a.id)

        let header = HostedView(StickyFolderHeader().environment(model), size: CGSize(width: 240, height: 120))
        #expect(header.host.fittingSize.height > 0)
        #expect(model.folderPath(b.id) == "Alpha › Beta")
        header.close()
        window.close()
    }

    @Test func folderMarkerFollowsItsRow() throws {
        let tracker = StickyFolders()
        let hosted = HostedView(FolderMarker(id: "a", tracker: tracker), size: CGSize(width: 100, height: 30))
        let marker = try #require(hosted.views(FolderMarkerView.self).first)
        #expect(marker.folderId == "a")
        hosted.host.rootView = FolderMarker(id: "b", tracker: tracker)
        hosted.pump()
        #expect(marker.folderId == "b")
        hosted.close()
    }

    @Test func sidebarSyncStatesAndFolderRows() throws {
        let h = try ModelHarness()
        let model = h.model
        model.syncInterval = 0
        model.syncURL = "http://joplin.test"
        model.syncEmail = "user@example.com"
        model.syncPassword = "secret"
        model.isSyncing = true
        let bar = HostedView(SyncStatusBar().environment(model), size: CGSize(width: 260, height: 40))
        #expect(model.syncStatusLine == "Syncing…")
        model.isSyncing = false
        model.syncFailed = true
        model.syncDetail = "boom"
        bar.pump()
        #expect(model.syncHelp == "boom")
        bar.close()

        let folder = try #require(model.folders.first)
        let row = HostedView(VStack { FolderRow(folder: folder, accentIcon: true); FolderRow(folder: folder) },
                             size: CGSize(width: 200, height: 60))
        row.close()

        model.showSidebarTags = true
        model.trashFolder(folder)
        model.trashExpanded = true
        let sidebar = HostedView(SidebarView().environment(model), size: CGSize(width: 260, height: 600))
        model.sidebarTagsExpanded = false
        sidebar.pump()
        sidebar.close()
    }

    @Test func noteListStates() throws {
        let h = try ModelHarness(welcome: true)
        let model = AppModel(store: h.store, defaults: h.defaults, pasteboard: h.pasteboard, syncTransport: h.server,
                             startsEmpty: true)
        model.searchDelay = 0
        #expect(model.isNothingChosen)
        #expect(model.listTitle == "Notes")
        #expect(model.listSubtitle.isEmpty)
        let list = HostedView(NavigationStack { NoteListView() }.environment(model), size: CGSize(width: 320, height: 500))
        model.sidebarSelection = .allNotes
        model.searchText = "checklists"
        model.showNotePreviews = true
        list.pump()
        #expect(model.listTitle == "Search")
        #expect(model.listSearchTerms == ["checklists"])
        list.close()

        let highlighted = NoteRow.highlighted("Try checklists and Checklists", terms: ["checklists"])
        let marked = highlighted.runs.filter { $0.backgroundColor != nil }
        #expect(marked.count == 2)
        #expect(NoteRow.highlighted("plain", terms: []).runs.count == 1)
    }

    @Test func editorDetailStates() async throws {
        let h = try ModelHarness()
        let model = h.model
        model.vimMode = true
        model.layout = .split
        let hosted = HostedView(ContentView().environment(model))
        model.vimState = .normal
        hosted.pump()
        model.vimState = .insert
        model.focusTitle()
        model.searchText = "checkbox"
        hosted.pump(0.3)
        model.searchPosition = SearchPosition(index: 0, count: 2)
        hosted.pump()
        model.updateBody(String(repeating: "word ", count: 12_000))
        hosted.pump(0.5)
        model.vimMode = false
        hosted.pump()
        hosted.close()

        var stats = NoteStats("one two\nthree", terms: ["two"])
        #expect(stats.matchLabel(position: nil) == "1 match")
        #expect(stats.matchLabel(position: SearchPosition(index: 1, count: 3)) == "2 of 3")
        #expect(stats.matchLabel(position: SearchPosition(index: 0, count: 0)) == "No matches")
        stats.matches = 4
        #expect(stats.matchLabel(position: nil) == "4 matches")
        #expect(stats.summary(created: 0) == "2 lines  ·  3 words  ·  13 characters")
        #expect(stats.summary(created: Store.now()).hasPrefix("Created "))
        #expect(NoteStats(String(repeating: "w ", count: 400), terms: []).summary(created: 0).hasSuffix("2 min read"))
    }

    @Test func shortcutRecorderStates() throws {
        let h = try ModelHarness()
        let model = h.model
        model.setHotkey(model.hotkey(for: .split), for: .editorOnly)
        #expect(model.shortcutConflict(for: .editorOnly) == ShortcutAction.split.title)
        model.startRecordingShortcut(.previewOnly)
        let settings = HostedView(ShortcutSettings().environment(model), size: CGSize(width: 520, height: 400))
        model.stopRecordingShortcut()
        model.resetShortcut(.editorOnly)
        settings.pump()
        #expect(model.shortcutConflict(for: .editorOnly) == nil)
        settings.close()
    }

    @Test func settingsFontPickerKeepsUnknownFonts() throws {
        let h = try ModelHarness()
        let model = h.model
        model.editorFont = FontFamily(name: "No Such Font Family")
        let text = HostedView(TextSettings().environment(model), size: CGSize(width: 520, height: 600))
        #expect(model.editorFont.name == "No Such Font Family")
        text.close()
    }

    @Test func snapshotHooksDriveTheWindow() async throws {
        let h = try ModelHarness()
        let model = h.model
        let a = try h.store.createFolder(title: "Deep")
        try h.store.createFolder(title: "Deeper", parentId: a.id)
        model.reloadSidebar()
        let hosted = HostedView(ContentView().environment(model), size: CGSize(width: 1100, height: 400))
        hosted.window.orderFrontRegardless()
        defer { hosted.close() }
        #expect(Snapshot.visibleWindow != nil)
        var quit = false
        Snapshot.scheduleIfRequested(model: model, env: [
            "JN_SNAPSHOT": temporaryDirectory().appendingPathComponent("s.png").path, "JN_SNAPSHOT_DELAY": "0.4",
            "JN_SNAPSHOT_QUIT": "1", "JN_VIM": "1", "JN_VIM_KEYS": "G\n", "JN_EXPAND_ALL": "1", "JN_SIDEBAR_SCROLL": "20",
            "JN_SEARCH": "welcome",
        ]) { quit = true }
        for _ in 0..<40 where !quit {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(quit)
        #expect(model.vimMode)
        #expect(model.searchText == "welcome")
        #expect(model.expandedFolders.contains(a.id))
        #expect(Snapshot.editor(in: hosted.host) != nil)
        Snapshot.scrollSidebar(in: NSView(), to: 10)
        model.vimMode = false
    }
}
