import AppKit
import Foundation
@testable import JoplinCore
import Testing
@testable import JoplinNative

@MainActor
@Suite(.serialized) struct SyncModelTests {
    private func configure(_ model: AppModel, password: String = "secret", interval: Int = 0) {
        model.syncInterval = interval
        model.syncURL = "http://joplin.test:22300"
        model.syncEmail = "user@example.com"
        model.syncPassword = password
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func notConfigured() async throws {
        let h = try ModelHarness()
        let model = h.model
        #expect(!model.isSyncConfigured)
        #expect(model.syncStatusLine == "Sync is off")
        await model.syncNow()
        #expect(model.syncFailed)
        #expect(model.syncDetail == SyncError.notConfigured.description)
        #expect(h.server.requests.isEmpty)
    }

    @Test func syncUploadsAndReceivesNotes() async throws {
        let server = FakeJoplinServer()
        let a = try ModelHarness(server: server)
        let b = try ModelHarness(welcome: false, server: server)
        configure(a.model)
        configure(b.model)
        #expect(a.model.syncStatusLine == "Not synced yet")

        await a.model.syncNow()
        #expect(!a.model.syncFailed)
        #expect(a.model.syncStatus.hasPrefix("Synced"))
        #expect(a.model.syncDetail.hasPrefix("Downloaded 0, uploaded"))
        #expect(a.model.syncStatusLine == a.model.syncStatus)

        await b.model.syncNow()
        #expect(b.model.allNotesCount == a.model.allNotesCount)
        #expect(Set(b.model.notes.map(\.id)) == Set(a.model.notes.map(\.id)))
        #expect(b.model.folders.map(\.title) == a.model.folders.map(\.title))

        let reopened = try ModelHarness(server: server, directory: b.store.directory)
        #expect(reopened.model.isSyncConfigured)
        #expect(reopened.model.syncStatusLine.hasPrefix("Synced"))
        #expect(reopened.model.syncInterval == 0)
    }

    @Test func noteTrashedElsewhereLeavesTheEditor() async throws {
        let server = FakeJoplinServer()
        let a = try ModelHarness(server: server)
        let b = try ModelHarness(welcome: false, server: server)
        configure(a.model)
        configure(b.model)
        await a.model.syncNow()
        await b.model.syncNow()
        let id = try #require(b.model.notes.first?.id)
        b.model.selectedNoteIDs = [id]
        #expect(b.model.currentNote?.id == id)

        a.model.trashNotes([id])
        await a.model.syncNow()
        await b.model.syncNow()
        #expect(!b.model.notes.contains { $0.id == id })
        #expect(b.model.currentNote?.id != id)
        #expect(b.model.selectedNoteIDs.isSubset(of: Set(b.model.notes.map(\.id))))
        #expect(b.model.currentNote != nil)
    }

    @Test func pendingEditIsSavedBeforeSync() async throws {
        let h = try ModelHarness()
        configure(h.model)
        let id = try #require(h.model.currentNote?.id)
        h.model.updateBody("typed just now")
        await h.model.syncNow()
        #expect(h.server.text("\(id).md")?.contains("typed just now") == true)
    }

    @Test func failureIsReported() async throws {
        let h = try ModelHarness()
        configure(h.model, password: "wrong")
        await h.model.syncNow()
        #expect(h.model.syncFailed)
        #expect(h.model.syncStatusLine == "Sync failed")
        #expect(h.model.syncDetail.contains("Invalid email or password"))
    }

    @Test func localChangesTriggerAutomaticSync() async throws {
        let h = try ModelHarness()
        h.model.autoSyncDelay = .milliseconds(30)
        configure(h.model, interval: 0)
        h.model.newNote()
        try await Task.sleep(for: .milliseconds(150))
        #expect(h.server.itemNames.isEmpty, "manual mode does not sync on its own")

        configure(h.model, interval: 60)
        try await waitUntil { !h.server.itemNames.isEmpty && !h.model.isSyncing }
        let before = h.server.itemNames.count
        h.model.newNote()
        try await waitUntil { h.server.itemNames.count > before && !h.model.isSyncing }
        #expect(h.server.itemNames.count == before + 1)
        h.model.syncInterval = 0
    }

    @Test func cancellingTheCallerDoesNotAbortSync() async throws {
        let h = try ModelHarness()
        configure(h.model)
        let caller = Task { await h.model.syncNow() }
        caller.cancel()
        await caller.value
        #expect(!h.model.syncFailed, "\(h.model.syncDetail)")
        #expect(!h.server.itemNames.isEmpty)
    }

        @Test func requestDuringSyncRunsAgain() async throws {
        let h = try ModelHarness()
        configure(h.model)
        h.model.requestSync()
        h.model.requestSync()
        await h.model.syncNow()
        try await waitUntil { !h.model.isSyncing }
        #expect(!h.model.syncFailed)
        let logins = h.server.requests.filter { $0.hasSuffix("/api/sessions") }.count
        #expect(logins >= 2)
    }

    @Test func syncSettingsPersist() throws {
        let h = try ModelHarness()
        h.model.syncURL = "https://x"
        #expect(h.store.setting("sync.url") == "https://x")
        let again = try ModelHarness(directory: h.store.directory)
        #expect(again.model.syncURL == "https://x")
    }
}
