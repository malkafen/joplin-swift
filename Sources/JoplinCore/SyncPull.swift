import Foundation

struct RemoteItem: @unchecked Sendable {
    let type: ModelType
    let id: String
    let fields: [String: Any]

    var updatedTime: Int64 { fields["updated_time"] as? Int64 ?? 0 }
    var blobUpdatedTime: Int64 { fields["blob_updated_time"] as? Int64 ?? 0 }

    var storageName: String {
        let ext = fields["file_extension"] as? String ?? ""
        return ext.isEmpty ? id : "\(id).\(ext)"
    }
}

enum FetchedItem: Sendable {
    case item(RemoteItem)
    case invalid
}

struct PagePlan {
    let cursor: String
    var marks: [(type: ModelType, id: String, time: Int64)] = []
    var wanted: [String] = []
    var deleted: [String] = []
}

extension SyncEngine {
    func pull(_ ledger: SyncLedger, _ report: inout SyncReport) async throws {
        let pendingDeletes = Set(try ledger.pendingDeletions().map(\.itemId))
        let client = self.client
        var page = try await firstPage(ledger.cursor)
        var plan = try self.plan(page, ledger, skipping: pendingDeletes)
        var download = Self.download(plan.wanted, client)
        var nextPage = page.hasMore ? Self.delta(page.cursor, client) : nil
        defer {
            download.cancel()
            nextPage?.cancel()
        }
        while true {
            let fetched = try await download.value
            let current = plan
            guard let pending = nextPage else {
                try await commit(current, fetched, ledger, &report)
                break
            }
            page = try await pending.value
            plan = try self.plan(page, ledger, skipping: pendingDeletes)
            download = Self.download(plan.wanted, client)
            nextPage = page.hasMore ? Self.delta(page.cursor, client) : nil
            try await commit(current, fetched, ledger, &report)
        }
        try await fetchMissingBlobs()
    }

    private func firstPage(_ cursor: String) async throws -> DeltaPage {
        do {
            return try await client.delta(cursor: cursor)
        } catch SyncError.http(_, "resyncRequired", _) where !cursor.isEmpty {
            return try await client.delta(cursor: "")
        }
    }

    nonisolated static func delta(_ cursor: String, _ client: JoplinServerClient) -> Task<DeltaPage, Error> {
        Task.detached { try await client.delta(cursor: cursor) }
    }

    nonisolated static func download(_ ids: [String], _ client: JoplinServerClient) -> Task<[String: FetchedItem], Error> {
        Task.detached {
            let contents = try await fetchAll(ids.map { "\($0).md" }, client)
            var out: [String: FetchedItem] = [:]
            for id in ids {
                guard case let data?? = contents["\(id).md"] else { continue }
                out[id] = parse(data, id: id)
            }
            return out
        }
    }

    nonisolated static func parse(_ data: Data, id: String) -> FetchedItem {
        guard let text = String(data: data, encoding: .utf8), let (type, fields) = try? Serializer.unserialize(text),
              fields["id"] as? String == id, (fields["encryption_applied"] as? Int64 ?? 0) == 0 else { return .invalid }
        return .item(RemoteItem(type: type, id: id, fields: fields))
    }

    nonisolated static func mapConcurrently<T: Sendable, R: Sendable>(
        _ items: [T], limit: Int, _ work: @escaping @Sendable (T) async throws -> R
    ) async throws -> [R] {
        var out = [R?](repeating: nil, count: items.count)
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
                out[index] = value
                if next < items.count { start() }
            }
        }
        return out.compactMap { $0 }
    }

    nonisolated static func fetchAll(_ names: [String], _ client: JoplinServerClient) async throws -> [String: Data?] {
        let contents = try await mapConcurrently(names, limit: parallelDownloads) { try await client.get($0) }
        var out: [String: Data?] = [:]
        for (name, data) in zip(names, contents) { out[name] = .some(data) }
        return out
    }

    func plan(_ page: DeltaPage, _ ledger: SyncLedger, skipping pendingDeletes: Set<String>) throws -> PagePlan {
        var latest: [String: DeltaItem] = [:]
        var order: [String] = []
        for item in page.items where Self.isItemName(item.name) {
            let id = String(item.name.prefix(32))
            if pendingDeletes.contains(id) { continue }
            if latest.updateValue(item, forKey: id) == nil { order.append(id) }
        }
        let snapshot = try ledger.localItems(ids: order)
        var plan = PagePlan(cursor: page.cursor)
        for id in order {
            guard let item = latest[id] else { continue }
            if item.change == .delete {
                plan.deleted.append(id)
                continue
            }
            if let local = snapshot[id], item.itemUpdatedTime > 0 {
                if local.syncTime == item.itemUpdatedTime { continue }
                if local.updatedTime == item.itemUpdatedTime {
                    plan.marks.append((local.type, id, item.itemUpdatedTime))
                    continue
                }
            }
            plan.wanted.append(id)
        }
        return plan
    }

    func commit(_ plan: PagePlan, _ fetched: [String: FetchedItem], _ ledger: SyncLedger, _ report: inout SyncReport) async throws {
        var remote: [RemoteItem] = []
        for id in plan.wanted {
            switch fetched[id] {
            case .item(let item): remote.append(item)
            case .invalid: report.skipped += 1
            case nil: continue
            }
        }
        let staged = try await stageBlobs(remote.filter(needsBlob).map(\.id))
        defer { for case let url? in staged.values { try? FileManager.default.removeItem(at: url) } }
        var removedFiles: [URL] = []
        try store.db.transaction {
            let fresh = try ledger.localItems(ids: remote.map(\.id) + plan.deleted + plan.marks.map(\.id))
            for mark in plan.marks where fresh[mark.id]?.type == mark.type && fresh[mark.id]?.updatedTime == mark.time {
                try ledger.markSynced(mark.type, id: mark.id, time: mark.time)
            }
            for item in remote {
                try applyDownload(item, local: fresh[item.id], blob: staged[item.id], ledger, &report)
            }
            for id in plan.deleted {
                guard let local = fresh[id], !local.isDirty else { continue }
                if let file = try ledger.applyRemoteDeletion(id: id, type: local.type) { removedFiles.append(file) }
                report.deletedLocally += 1
            }
            try ledger.saveCursor(plan.cursor)
        }
        for file in removedFiles { try? FileManager.default.removeItem(at: file) }
    }

    func needsBlob(_ item: RemoteItem) -> Bool {
        guard item.type == .resource else { return false }
        guard item.blobUpdatedTime != 0, let row = store.row(.resource, id: item.id) else { return true }
        if row.int("blob_updated_time") != item.blobUpdatedTime { return true }
        return !FileManager.default.fileExists(atPath: store.url(for: Resource(row: row)).path)
    }

    var stagingDirectory: URL { store.directory.appendingPathComponent("sync-incoming", isDirectory: true) }

    func stageBlobs(_ ids: [String]) async throws -> [String: URL?] {
        guard !ids.isEmpty else { return [:] }
        let client = self.client
        let directory = stagingDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let urls = try await Self.mapConcurrently(ids, limit: Self.parallelDownloads) { id -> URL? in
            guard let data = try await client.get(".resource/\(id)") else { return nil }
            let url = directory.appendingPathComponent("\(id)-\(UUID().uuidString)")
            try data.write(to: url)
            return url
        }
        var out: [String: URL?] = [:]
        for (id, url) in zip(ids, urls) { out[id] = .some(url) }
        return out
    }

    private func applyDownload(_ item: RemoteItem, local: LocalItem?, blob: URL??, _ ledger: SyncLedger,
                               _ report: inout SyncReport) throws {
        if let local {
            guard local.type == item.type else {
                report.skipped += 1
                return
            }
            if local.syncTime == item.updatedTime { return }
            if local.isDirty {
                if local.updatedTime == item.updatedTime {
                    try ledger.markSynced(item.type, id: item.id, time: item.updatedTime)
                    return
                }
                if item.type == .note {
                    if let row = store.row(.note, id: item.id),
                       row.string("title") != (item.fields["title"] as? String ?? "")
                        || row.string("body") != (item.fields["body"] as? String ?? "") {
                        try saveConflictCopy(of: row)
                        report.conflicts += 1
                    }
                } else if local.updatedTime > item.updatedTime {
                    return
                }
            }
        }
        if item.type == .resource { try placeBlob(item, blob: blob) }
        try store.upsert(item.type, item.fields, isNew: local == nil)
        try ledger.markSynced(item.type, id: item.id, time: item.updatedTime)
        report.downloaded += 1
    }

    private func placeBlob(_ item: RemoteItem, blob: URL??) throws {
        let fm = FileManager.default
        let destination = store.resourceDirectory.appendingPathComponent(item.storageName)
        let previous = store.resource(id: item.id).map(store.url(for:))
        switch blob {
        case .some(.some(let staged)):
            if let previous, previous != destination { try? fm.removeItem(at: previous) }
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: staged, to: destination)
            try store.setBlobMissing(item.id, false)
        case .some(.none):
            try store.setBlobMissing(item.id, true)
        case .none:
            if let previous, previous != destination, fm.fileExists(atPath: previous.path), !fm.fileExists(atPath: destination.path) {
                try fm.moveItem(at: previous, to: destination)
            }
        }
    }

    func fetchMissingBlobs() async throws {
        let ids = try store.missingBlobs()
        guard !ids.isEmpty else { return }
        let client = self.client
        try await Self.forEachConcurrently(ids, limit: Self.parallelDownloads, { try await client.get(".resource/\($0)") }) { id, data in
            guard let resource = store.resource(id: id) else {
                try store.setBlobMissing(id, false)
                return
            }
            guard let data else { return }
            try data.write(to: store.url(for: resource), options: .atomic)
            try store.setBlobMissing(id, false)
        }
    }

    private func saveConflictCopy(of local: Row) throws {
        var fields = local.values
        let now = Store.now()
        let newId = Store.newId()
        fields["id"] = newId
        fields["title"] = "\(local.string("title")) (conflict)"
        fields["conflict_original_id"] = local.string("id")
        fields["created_time"] = now
        fields["updated_time"] = now
        try store.upsert(.note, fields, isNew: true)
        for tag in store.tags(forNote: local.string("id")) { try store.addTag(tagId: tag.id, toNote: newId) }
    }
}
