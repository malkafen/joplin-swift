import Foundation

struct UploadPayload: Sendable {
    let id: String
    let updatedTime: Int64
    let data: Data

    var name: String { "\(id).md" }
}

extension SyncEngine {
    func pushDeletions(_ ledger: SyncLedger, _ report: inout SyncReport) async throws {
        let deletions = try ledger.pendingDeletions()
        let neverSynced = deletions.filter { !$0.onTarget && !$0.elsewhere }
        if !neverSynced.isEmpty {
            try store.db.transaction { for deletion in neverSynced { try ledger.completeDeletion(deletion) } }
        }
        let client = self.client
        let resourceType = Int64(ModelType.resource.rawValue)
        try await Self.forEachConcurrently(deletions.filter(\.onTarget), limit: Self.parallelUploads, { deletion in
            try await client.delete("\(deletion.itemId).md")
            if deletion.type == resourceType { try await client.delete(".resource/\(deletion.itemId)") }
        }) { deletion, _ in
            try ledger.completeDeletion(deletion)
            report.deletedRemotely += 1
        }
    }

    func push(_ ledger: SyncLedger, _ report: inout SyncReport) async throws {
        let pending = try ledger.itemsToUpload()
        let client = self.client
        for type in Store.uploadOrder {
            let items = pending.filter { $0.type == type }
            guard !items.isEmpty else { continue }
            if type == .resource { try await uploadBlobs(items) }
            let payloads = try items.map {
                UploadPayload(id: $0.id, updatedTime: $0.updatedTime,
                              data: Data(try Serializer.serialize(type: type, fields: $0.row.values).utf8))
            }
            try await Self.forEachConcurrently(Self.batches(payloads), limit: Self.parallelUploads, { batch in
                try await client.putBatch(batch.map { ($0.name, $0.data) })
            }) { batch, failures in
                try store.db.transaction {
                    for payload in batch where failures[payload.name] == nil {
                        try ledger.markSynced(type, id: payload.id, time: payload.updatedTime)
                    }
                }
                report.uploaded += batch.count - failures.count
                report.skipped += failures.count
            }
        }
    }

    static func batches(_ payloads: [UploadPayload]) -> [[UploadPayload]] {
        var out: [[UploadPayload]] = []
        var current: [UploadPayload] = []
        var bytes = 0
        for payload in payloads {
            if !current.isEmpty, current.count >= batchItems || bytes + payload.data.count > batchBytes {
                out.append(current)
                current = []
                bytes = 0
            }
            current.append(payload)
            bytes += payload.data.count
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private func uploadBlobs(_ items: [UploadItem]) async throws {
        let blobs = items.compactMap { item -> (id: String, file: URL)? in
            let blobTime = item.row.int("blob_updated_time")
            if let synced = item.syncTime, blobTime != 0, blobTime <= synced { return nil }
            let file = store.url(for: Resource(row: item.row))
            return FileManager.default.fileExists(atPath: file.path) ? (item.id, file) : nil
        }
        let client = self.client
        try await Self.forEachConcurrently(blobs, limit: Self.parallelUploads, { blob in
            try await client.put(".resource/\(blob.id)", try Data(contentsOf: blob.file, options: .alwaysMapped))
        }) { _, _ in }
    }
}
