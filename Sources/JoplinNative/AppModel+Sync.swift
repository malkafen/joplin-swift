import Foundation
import JoplinCore

extension AppModel {
    static let notSetUpStatus = "Sync is not set up"

    var isSyncConfigured: Bool {
        !syncURL.trimmingCharacters(in: .whitespaces).isEmpty && !syncEmail.isEmpty && !syncPassword.isEmpty
    }

    var syncStatusLine: String {
        if isSyncing { return "Syncing…" }
        if !isSyncConfigured { return "Sync is off" }
        if !syncStatus.isEmpty { return syncStatus }
        return lastSyncTime > 0 ? "Synced \(shortDate(lastSyncTime))" : "Not synced yet"
    }

    var syncHelp: String { syncDetail.isEmpty ? syncStatusLine : syncDetail }

    func syncNow() async {
        guard isSyncConfigured else {
            syncFailed = true
            syncStatus = Self.notSetUpStatus
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
                let report = try await SyncEngine(store: store, client: try currentSyncClient()).sync()
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

    func currentSyncClient() throws -> JoplinServerClient {
        let credentials = [syncURL, syncEmail, syncPassword]
        if let cached = syncClient, cached.credentials == credentials { return cached.client }
        let client = try JoplinServerClient(baseURL: syncURL, email: syncEmail, password: syncPassword, transport: syncTransport)
        syncClient = (client, credentials)
        return client
    }

    func requestSync() {
        Task { await syncNow() }
    }

    func syncNowAndRestartTimer() {
        restartSyncTimer(syncFirst: false)
        requestSync()
    }

    func scheduleAutoSync() {
        guard isSyncConfigured, syncInterval > 0 else { return }
        autoSyncTask?.cancel()
        let delay = autoSyncDelay
        autoSyncTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    func restartSyncTimer(syncFirst: Bool = true) {
        syncTimer?.cancel()
        syncTimer = nil
        guard isSyncConfigured, syncInterval > 0 else { return }
        let interval = Duration.seconds(syncInterval * 60)
        syncTimer = Task { [weak self] in
            if !syncFirst { try? await Task.sleep(for: interval) }
            while !Task.isCancelled {
                await self?.syncNow()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func syncCredentialsChanged() {
        if syncStatus == Self.notSetUpStatus {
            syncStatus = ""
            syncDetail = ""
            syncFailed = false
        }
        if !isSyncConfigured {
            syncTimer?.cancel()
            syncTimer = nil
        } else if syncTimer == nil {
            restartSyncTimer(syncFirst: false)
        }
    }

    var isSyncTimerRunning: Bool { syncTimer != nil }
}
