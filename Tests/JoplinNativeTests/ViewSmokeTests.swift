import AppKit
import Foundation
@testable import JoplinCore
import SwiftUI
import Testing
@testable import JoplinNative

@MainActor
@Suite(.serialized) struct ViewSmokeTests {
    private func render<V: View>(_ view: V, size: CGSize = CGSize(width: 1200, height: 760)) -> NSView {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        window.close()
        return host
    }

    private func subviews<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { ($0 as? T).map { [$0] } ?? [] + subviews(of: type, in: $0) }
    }

    @Test(arguments: EditorLayout.allCases)
    func mainWindow(layout: EditorLayout) throws {
        let h = try ModelHarness()
        let model = h.model
        model.layout = layout
        let emoji = try h.store.createFolder(title: "Emoji")
        try h.store.db.run("UPDATE folders SET icon = ? WHERE id = ?", [#"{"emoji":"📒"}"#, emoji.id])
        try h.store.createFolder(title: "", parentId: emoji.id)
        model.reloadSidebar()
        let host = render(ContentView().environment(model))
        #expect(host.fittingSize.width > 0)
        if layout != .preview {
            #expect(model.editor.textView?.string == model.currentNote?.body)
        }
        if layout != .editor {
            #expect(!subviews(of: NSTextView.self, in: host).filter { !$0.isEditable }.isEmpty)
        }
    }

    @Test func todoNoteInTheTrash() throws {
        let h = try ModelHarness()
        let model = h.model
        let todo = try #require(model.notes.first { $0.isTodo })
        model.setTodoCompleted(todo.id, true)
        model.trashNotes([todo.id])
        model.sidebarSelection = .trash
        model.trashFolder(try #require(model.folders.first))
        _ = render(ContentView().environment(model))
        model.trashExpanded = true
        model.searchText = "check"
        _ = render(ContentView().environment(model))
        model.searchText = ""
        #expect(model.currentNote?.deletedTime ?? 0 > 0)
        #expect(model.editor.textView?.isEditable == false)
    }

    @Test func emptyStates() throws {
        let h = try ModelHarness(welcome: false)
        let model = h.model
        _ = render(ContentView().environment(model))
        model.sidebarSelection = .trash
        _ = render(ContentView().environment(model))
        model.sidebarSelection = .allNotes
        model.searchText = "nothing matches"
        _ = render(ContentView().environment(model))
        #expect(model.notes.isEmpty)
    }

    @Test func multipleSelection() throws {
        let h = try ModelHarness()
        let model = h.model
        model.selectedNoteIDs = Set(model.notes.map(\.id))
        _ = render(ContentView().environment(model))
        #expect(model.currentNote == nil)
    }

    @Test func dialogs() throws {
        let h = try ModelHarness()
        let model = h.model
        model.alert = AlertInfo(title: "Alert", message: "message")
        _ = render(ContentView().environment(model))
        model.alert = nil
        model.promptNewFolder()
        _ = render(ContentView().environment(model))
        model.textPrompt = nil
        model.emptyTrash()
        _ = render(ContentView().environment(model))
        #expect(model.confirmation != nil)
    }

    @Test func editorFollowsModelChanges() throws {
        let h = try ModelHarness()
        let model = h.model
        model.layout = .split
        let view = ContentView().environment(model)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1200, height: 760)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        func pump() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        }
        pump()
        let tv = try #require(model.editor.textView)

        tv.insertText("typed ", replacementRange: NSRange(location: 0, length: 0))
        #expect(model.currentNote?.body.hasPrefix("typed ") == true)

        let line = try #require(model.currentNote?.body.components(separatedBy: "\n").firstIndex { $0.contains("[ ]") })
        model.toggleCheckbox(line: line + 1)
        pump()
        #expect(tv.string == model.currentNote?.body)

        model.editorFontSize = 20
        model.editorFont = .monospaced
        pump()
        #expect((tv.typingAttributes[.font] as? NSFont)?.isFixedPitch == true)

        model.selectedNoteIDs = [try #require(model.notes.last).id]
        pump()
        #expect(tv.string == model.currentNote?.body)
        #expect(tv.selectedRange().location == 0)
        window.close()
    }

    @Test func settings() throws {
        let h = try ModelHarness()
        let host = render(SettingsView().environment(h.model), size: CGSize(width: 480, height: 320))
        #expect(host.fittingSize.height > 0)
    }

    @Test func syncStatesAndTextSettings() async throws {
        let h = try ModelHarness()
        let model = h.model
        _ = render(SyncStatusBar().environment(model), size: CGSize(width: 220, height: 40))
        model.syncInterval = 0
        model.syncURL = "http://joplin.test"
        model.syncEmail = "user@example.com"
        model.syncPassword = "wrong"
        await model.syncNow()
        #expect(model.syncFailed)
        _ = render(ContentView().environment(model))
        model.syncPassword = "secret"
        await model.syncNow()
        _ = render(SettingsView().environment(model), size: CGSize(width: 480, height: 640))
        model.showSidebarTags = false
        model.showNoteTags = false
        model.showNotePreviews = true
        model.readableWidth = false
        model.previewFont = .serif
        model.layout = .split
        let host = render(ContentView().environment(model))
        #expect(host.fittingSize.width > 0)
        _ = render(TextSettings().environment(model), size: CGSize(width: 520, height: 600))
        _ = render(GeneralSettings().environment(model), size: CGSize(width: 520, height: 600))
        _ = render(SyncSettings().environment(model), size: CGSize(width: 520, height: 600))
    }

    @Test func snapshotImages() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Text("Snapshot"))
        #expect(Snapshot.cachedImage(window) != nil)
        _ = Snapshot.windowServerImage(window)
        window.close()
    }

    @Test func previewLinkDelegate() throws {
        var clicked: [URL] = []
        let coordinator = MarkdownPreview.Coordinator { clicked.append($0) }
        let tv = NSTextView()
        #expect(coordinator.textView(tv, clickedOnLink: URL(string: "https://a.b")!, at: 0))
        #expect(coordinator.textView(tv, clickedOnLink: "joplinitem://x", at: 0))
        #expect(!coordinator.textView(tv, clickedOnLink: 42, at: 0))
        #expect(coordinator.textView(tv, clickedOnLink: URL(string: "#intro")!, at: 0))
        #expect(clicked.map(\.absoluteString) == ["https://a.b", "joplinitem://x"])
    }

    @Test func tagFieldCompletionAndCommit() async throws {
        var committed: [[String]] = []
        let field = TagField(tags: ["a"], allTags: ["alpha", "beta", "a"]) { committed.append($0) }
        let coordinator = TagField.Coordinator(field)
        let token = NSTokenField()
        token.objectValue = ["a"]
        let completions = coordinator.tokenField(token, completionsForSubstring: "A", indexOfToken: 0, indexOfSelectedItem: nil) as? [String]
        #expect(completions == ["alpha"])

        #expect(coordinator.tokenField(token, shouldAdd: ["b"], at: 1).count == 1)
        try await Task.sleep(for: .milliseconds(50))
        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: token))
        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: nil))
        #expect(committed == [["a"], ["a"]])
    }

    @Test func dates() {
        let now = Store.now()
        #expect(shortDate(0) == "")
        #expect(longDate(0) == "")
        #expect(!shortDate(now).isEmpty)
        #expect(!shortDate(now - 86_400_000).isEmpty)
        #expect(!shortDate(now - 40 * 86_400_000).isEmpty)
        #expect(!shortDate(1_000_000_000_000).isEmpty)
        #expect(!longDate(now).isEmpty)
    }
}
