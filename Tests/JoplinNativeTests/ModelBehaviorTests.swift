import AppKit
import Foundation
@testable import JoplinCore
import Observation
import Testing
import UniformTypeIdentifiers
@testable import JoplinNative

@MainActor
final class ChangeFlag {
    private(set) var raised = false

    init(_ read: @escaping @MainActor () -> Void) {
        withObservationTracking { read() } onChange: { [weak self] in
            MainActor.assumeIsolated { self?.raised = true }
        }
    }
}

@MainActor
@Suite struct ObservationScopeTests {
    @Test func titleEditsDoNotTouchTheBodyOrTheNoteInfo() throws {
        let model = try ModelHarness().model
        let id = try #require(model.noteInfo?.id)
        let note = ChangeFlag { _ = model.currentNote }
        let info = ChangeFlag { _ = model.noteInfo }
        let body = ChangeFlag { _ = model.currentBody }
        let count = ChangeFlag { _ = model.noteCount }
        let list = ChangeFlag { _ = model.notes }
        model.updateTitle("Renamed")
        #expect(note.raised)
        #expect(list.raised)
        #expect(!info.raised)
        #expect(!body.raised)
        #expect(!count.raised)
        #expect(model.notes.first { $0.id == id }?.title == "Renamed")
    }

    @Test func bodyChangesNotifyTheBodyOnly() throws {
        let model = try ModelHarness().model
        let info = ChangeFlag { _ = model.noteInfo }
        let body = ChangeFlag { _ = model.currentBody }
        model.updateBody("new body")
        #expect(body.raised)
        #expect(!info.raised)
        #expect(model.currentBody == "new body")

        let typed = ChangeFlag { _ = model.currentBody }
        let revision = ChangeFlag { _ = model.bodyRevision }
        model.editBody("typed")
        #expect(!typed.raised)
        #expect(revision.raised)
        #expect(model.currentBody == "typed")
    }

    @Test func switchingNotesNotifiesBodyAndInfo() throws {
        let model = try ModelHarness().model
        let info = ChangeFlag { _ = model.noteInfo }
        let body = ChangeFlag { _ = model.currentBody }
        model.selectAdjacentNote(1)
        #expect(info.raised)
        #expect(body.raised)
        #expect(model.noteInfo?.id == model.currentNote?.id)

        model.selectedNoteIDs = []
        #expect(model.noteInfo == nil)
        #expect(model.currentBody == "")
    }

    @Test func searchTermsChangeOnlyWithTheWords() throws {
        let model = try ModelHarness().model
        model.searchText = "check"
        let terms = ChangeFlag { _ = model.searchTerms }
        model.searchText = "check "
        #expect(!terms.raised)
        model.searchText = "check list"
        #expect(terms.raised)
        #expect(model.searchTerms == ["check", "list"])
    }

    @Test func listHighlightsFollowTheListNotTheTyping() async throws {
        let model = try ModelHarness().model
        model.searchDelay = 10
        model.searchText = "welcome"
        #expect(model.searchTerms == ["welcome"])
        #expect(model.listSearchTerms.isEmpty)
        model.searchNow()
        #expect(model.listSearchTerms == ["welcome"])
        model.searchText = ""
        #expect(model.listSearchTerms.isEmpty)
    }

    @Test func rendererIsRebuiltOnlyForPreviewSettings() throws {
        let model = try ModelHarness().model
        let editorOnly = ChangeFlag { _ = model.renderer }
        model.editorFontSize = 20
        model.editorFont = .serif
        #expect(!editorOnly.raised)
        let preview = ChangeFlag { _ = model.renderer }
        model.previewFontSize = 21
        #expect(preview.raised)
        #expect(model.renderer.baseSize == 21)
        model.codeFont = .serif
        #expect(model.renderer.typography.codeFamily == .serif)
        model.loadRemoteImages = false
        #expect(!model.renderer.loadsRemoteImages)
        model.loadRemoteImages = true
        model.remoteImages = { _ in nil }
        #expect(model.renderer.loadsRemoteImages)
    }

    @Test func launchDoesNotRewriteTheSettings() throws {
        let h = try ModelHarness(welcome: false) { d in
            d.set("split", forKey: "layout")
        }
        let model = h.model
        #expect(model.layout == .split)
        for key in ["sort", "todosOnTop", "editorFont", "editorFontSize", "previewFont", "vimMode", "stickyNotebooks"] {
            #expect(h.defaults.object(forKey: key) == nil, "\(key)")
        }
        #expect(h.store.setting("sync.url") == nil)
        #expect(h.store.setting("sync.interval") == nil)
        #expect(model.vimState == .insert)
        #expect(model.sticky.enabled)
    }

    @Test func noteInfoFlags() throws {
        let model = try ModelHarness().model
        let todo = try #require(model.notes.first { $0.isTodo })
        model.selectedNoteIDs = [todo.id]
        #expect(model.noteInfo?.isTodo == true)
        #expect(model.noteInfo?.isDone == false)
        model.toggleCurrentTodoCompleted()
        #expect(model.noteInfo?.isDone == true)
        model.trashNotes([todo.id])
        model.sidebarSelection = .trash
        model.selectedNoteIDs = [todo.id]
        #expect(model.noteInfo?.inTrash == true)
    }
}

@MainActor
@Suite struct ModelFixTests {
    @Test func trashingTheParentOfTheChosenNotebookFallsBackToAllNotes() throws {
        let h = try ModelHarness(welcome: false)
        let model = h.model
        let parent = try h.store.createFolder(title: "Parent")
        let child = try h.store.createFolder(title: "Child", parentId: parent.id)
        try h.store.createNote(parentId: child.id, title: "inside")
        model.reloadSidebar()
        model.sidebarSelection = .folder(child.id)
        #expect(model.notes.count == 1)
        model.trashFolder(parent)
        #expect(model.sidebarSelection == .allNotes)
        #expect(model.listTitle == "All Notes")
    }

    @Test func notebookDeletedElsewhereIsUnselected() throws {
        let h = try ModelHarness()
        let model = h.model
        let folder = try #require(model.folders.first)
        model.sidebarSelection = .folder(folder.id)
        try h.store.trashFolder(id: folder.id)
        model.reloadAll(select: model.selectedNoteIDs)
        #expect(model.sidebarSelection == .allNotes)

        let tag = try #require(model.tags.first)
        model.sidebarSelection = .tag(tag.id)
        try h.store.deleteTag(id: tag.id)
        model.reloadAll()
        #expect(model.sidebarSelection == .allNotes)
    }

    @Test func newSubNotebookIsShownAndChosen() throws {
        let h = try ModelHarness(welcome: false)
        let model = h.model
        let parent = try h.store.createFolder(title: "Parent")
        model.reloadSidebar()
        model.promptNewFolder(parent: parent.id)
        model.textPrompt?.action("  Child  ")
        let child = try #require(model.folders.first { $0.title == "Child" })
        #expect(child.parentId == parent.id)
        #expect(model.expandedFolders.contains(parent.id))
        #expect(model.sidebarSelection == .folder(child.id))
        model.promptNewFolder()
        model.textPrompt?.action("   ")
        #expect(model.folders.count == 2)
    }

    @Test func choosingANotebookWhileSearchingClearsTheSearch() throws {
        let h = try ModelHarness()
        let model = h.model
        model.searchText = "checklists"
        #expect(model.notes.count == 1)
        let folder = try #require(model.folders.first)
        model.sidebarSelection = .folder(folder.id)
        #expect(model.searchText.isEmpty)
        #expect(model.searchTerms.isEmpty)
        #expect(model.notes.count == 2)
        #expect(model.listSubtitle == "2 notes")
    }

    @Test func linksOpenNotesHiddenBySearch() throws {
        let h = try ModelHarness()
        let model = h.model
        let folder = try #require(model.folders.first)
        model.sidebarSelection = .folder(folder.id)
        let other = try #require(model.notes.last)
        model.searchText = "zzzz"
        #expect(model.notes.isEmpty)
        model.openItem(id: other.id)
        #expect(model.searchText.isEmpty)
        #expect(model.sidebarSelection == .folder(folder.id))
        #expect(model.currentNote?.id == other.id)
    }

    @Test func exportAndImportRoundTrip() throws {
        let h = try ModelHarness()
        let model = h.model
        let folder = try #require(model.folders.first)
        #expect(model.exportFileName(folderId: nil) == "Joplin Export.jex")
        #expect(model.exportFileName(folderId: folder.id) == "Welcome.jex")
        let file = temporaryDirectory().appendingPathComponent("round.jex")
        model.exportJEX(to: file, folderId: folder.id)
        #expect(model.alert?.title == "Export complete")

        let other = try ModelHarness(welcome: false)
        other.model.importJEX(file)
        #expect(other.model.alert?.title == "round.jex imported")
        #expect(other.model.allNotesCount == 2)
        other.model.importJEX(temporaryDirectory().appendingPathComponent("missing.jex"))
        #expect(other.model.alert?.title == "Import failed")
        #expect(AppModel.jexType.preferredFilenameExtension == "jex")
    }

    @Test func credentialsStartAndStopTheSyncTimer() async throws {
        let h = try ModelHarness()
        let model = h.model
        await model.syncNow()
        #expect(model.syncStatus == AppModel.notSetUpStatus)
        #expect(!model.isSyncTimerRunning)
        model.syncURL = "http://joplin.test"
        #expect(model.syncStatus.isEmpty)
        #expect(!model.syncFailed)
        model.syncEmail = "user@example.com"
        model.syncPassword = "secret"
        #expect(model.isSyncTimerRunning)
        #expect(h.server.requests.isEmpty, "the first automatic sync waits for the interval")
        model.syncPassword = ""
        #expect(!model.isSyncTimerRunning)
        model.syncInterval = 0
        model.syncPassword = "secret"
        #expect(!model.isSyncTimerRunning)
    }

    @Test func syncNowFromSettingsSyncsOnce() async throws {
        func configured() throws -> ModelHarness {
            let h = try ModelHarness()
            h.model.syncInterval = 60
            h.model.syncURL = "http://joplin.test"
            h.model.syncEmail = "user@example.com"
            h.model.syncPassword = "secret"
            return h
        }
        let reference = try configured()
        await reference.model.syncNow()
        reference.model.syncInterval = 0

        let h = try configured()
        let model = h.model
        model.syncNowAndRestartTimer()
        for _ in 0..<200 where model.isSyncing || model.lastSyncTime == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!model.syncFailed, "\(model.syncDetail)")
        #expect(model.isSyncTimerRunning)
        #expect(h.server.requests.count == reference.server.requests.count)
        model.syncInterval = 0
    }
}
