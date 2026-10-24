import Foundation

public struct SyncReport: Sendable, Equatable, CustomStringConvertible {
    public var downloaded = 0
    public var uploaded = 0
    public var deletedLocally = 0
    public var deletedRemotely = 0
    public var conflicts = 0
    public var skipped = 0

    public init() {}

    public var description: String {
        var parts = ["downloaded \(downloaded)", "uploaded \(uploaded)"]
        if deletedLocally + deletedRemotely > 0 { parts.append("deleted \(deletedLocally + deletedRemotely)") }
        if conflicts > 0 { parts.append("conflicts \(conflicts)") }
        if skipped > 0 { parts.append("skipped \(skipped)") }
        return parts.joined(separator: ", ")
    }
}

@MainActor
public final class SyncEngine {
    public static let supportedSyncVersion = 3
    static let clientIdKey = "sync.client_id"
    static let lastSyncKey = "sync.last_time"
    nonisolated static let parallelDownloads = URLSessionTransport.defaultConnections
    static let parallelUploads = 4
    static let batchItems = 200
    static let batchBytes = 1_000_000

    let store: Store
    let client: JoplinServerClient
    var lockRefreshInterval: Duration = .seconds(60)

    public init(store: Store, client: JoplinServerClient) {
        self.store = store
        self.client = client
    }

    var clientId: String {
        if let id = store.setting(Self.clientIdKey), !id.isEmpty { return id }
        let id = Store.newId()
        store.setSetting(Self.clientIdKey, id)
        return id
    }

    static func isItemName(_ name: String) -> Bool {
        name.count == 35 && name.hasSuffix(".md") && name.prefix(32).allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    public func sync() async throws -> SyncReport {
        if client.sessionId == nil { try await client.login() }
        try await checkSyncInfo()
        let id = clientId
        try await client.acquireSyncLock(clientId: id)
        let refresher = Task { [client, lockRefreshInterval] in
            while (try? await Task.sleep(for: lockRefreshInterval)) != nil {
                try? await client.acquireSyncLock(clientId: id)
            }
        }
        var report = SyncReport()
        do {
            let ledger = try store.syncLedger(identity: client.targetIdentity)
            try await pull(ledger, &report)
            try await pushDeletions(ledger, &report)
            try await push(ledger, &report)
        } catch {
            refresher.cancel()
            _ = await refresher.result
            await client.releaseSyncLock(clientId: id)
            throw error
        }
        refresher.cancel()
        _ = await refresher.result
        await client.releaseSyncLock(clientId: id)
        store.setSetting(Self.lastSyncKey, String(Store.now()))
        return report
    }

    func checkSyncInfo() async throws {
        guard let data = try await client.get("info.json") else {
            let info: [String: Any] = [
                "version": Self.supportedSyncVersion,
                "e2ee": ["value": false, "updatedTime": 0],
                "activeMasterKeyId": ["value": "", "updatedTime": 0],
                "masterKeys": [],
                "ppk": ["value": NSNull(), "updatedTime": 0],
                "appMinVersion": "3.0.0",
            ]
            try await client.put("info.json", try JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]))
            return
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SyncError.invalidResponse("info.json is not valid JSON")
        }
        let version = (obj["version"] as? NSNumber)?.intValue ?? 0
        if version > Self.supportedSyncVersion { throw SyncError.unsupportedSyncVersion(version) }
        if let e2ee = obj["e2ee"] as? [String: Any], (e2ee["value"] as? Bool) == true {
            throw SyncError.encryptionEnabled
        }
    }

    static func forEachConcurrently<T: Sendable, R: Sendable>(
        _ items: [T], limit: Int, _ work: @escaping @Sendable (T) async throws -> R, result: (T, R) throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: (Int, R).self) { group in
            var next = 0
            func start() {
                let index = next
                let item = items[index]
                next += 1
                group.addTask { (index, try await work(item)) }
            }
            while next < min(items.count, limit) { start() }
            while let (index, value) = try await group.next() {
                try result(items[index], value)
                if next < items.count { start() }
            }
        }
    }

    func fetch(_ names: [String]) async throws -> [String: Data?] {
        try await Self.fetchAll(names, client)
    }
}
