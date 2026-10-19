import Foundation
import JoplinCore

/// In-memory stand-in for Joplin Server's REST API (sessions, items, delta, locks), as observed on server 3.7.
final class FakeJoplinServer: HTTPTransport, @unchecked Sendable {
    struct Change {
        var name: String
        var type: Int
        var jopUpdatedTime: Int64
    }

    private let lock = NSLock()
    var email = "user@example.com"
    var password = "secret"
    private(set) var files: [String: Data] = [:]
    private(set) var changes: [Change] = []
    private(set) var sessions: Set<String> = []
    private(set) var locks: [String: (type: Int, clientId: String)] = [:]
    private(set) var requests: [String] = []
    /// Items per delta page.
    var pageSize = 1000
    /// Status code returned for the next request whose "METHOD path" contains the key.
    var failures: [String: Int] = [:]

    init(email: String = "user@example.com", password: String = "secret") {
        self.email = email
        self.password = password
    }

    func expireSessions() { lock.withLock { sessions.removeAll() } }

    func file(_ name: String) -> Data? { lock.withLock { files[name] } }

    func text(_ name: String) -> String? { file(name).flatMap { String(data: $0, encoding: .utf8) } }

    var itemNames: [String] { lock.withLock { files.keys.filter { $0.hasSuffix(".md") }.sorted() } }

    /// Stores a file as another client would, recording a change.
    func seed(_ name: String, _ content: String) {
        lock.withLock { store(name, Data(content.utf8)) }
    }

    func remove(_ name: String) {
        lock.withLock { erase(name) }
    }

    func setLock(type: Int, clientId: String) {
        lock.withLock { locks["\(type)_1_\(clientId)"] = (type, clientId) }
    }

    private func store(_ name: String, _ data: Data) {
        let created = files[name] == nil
        files[name] = data
        var time: Int64 = 0
        if name.hasSuffix(".md"), let text = String(data: data, encoding: .utf8),
           let line = text.components(separatedBy: "\n").last(where: { $0.hasPrefix("updated_time: ") }) {
            time = Serializer.parseTime(String(line.dropFirst("updated_time: ".count)))
        }
        changes.append(Change(name: name, type: created ? 1 : 2, jopUpdatedTime: time))
    }

    private func erase(_ name: String) {
        guard files.removeValue(forKey: name) != nil else { return }
        changes.append(Change(name: name, type: 3, jopUpdatedTime: 0))
    }

    private func json(_ status: Int, _ obj: Any) -> (Data, Int) {
        ((try? JSONSerialization.data(withJSONObject: obj)) ?? Data(), status)
    }

    private func error(_ status: Int, _ message: String, code: String? = nil) -> (Data, Int) {
        var obj: [String: Any] = ["error": message]
        if let code { obj["code"] = code }
        return json(status, obj)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // URLSession fails requests of a cancelled task with NSURLErrorCancelled (-999).
        if Task.isCancelled { throw URLError(.cancelled) }
        let url = request.url!
        let (data, status) = lock.withLock { handle(request, url) }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (data, response)
    }

    private func handle(_ request: URLRequest, _ url: URL) -> (Data, Int) {
        let method = request.httpMethod ?? "GET"
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let path = components.percentEncodedPath.removingPercentEncoding ?? components.percentEncodedPath
        let signature = "\(method) \(path)"
        requests.append(signature)
        if let key = failures.keys.sorted().first(where: { signature.contains($0) }), let status = failures.removeValue(forKey: key) {
            return error(status, "Injected failure")
        }

        if method == "POST", path.hasSuffix("/api/sessions") {
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: String]
            guard body?["email"] == email, body?["password"] == password else { return error(403, "Invalid email or password") }
            let id = UUID().uuidString
            sessions.insert(id)
            return json(200, ["id": id, "user_id": "u1"])
        }
        guard let token = request.value(forHTTPHeaderField: "X-API-AUTH"), sessions.contains(token) else {
            return error(403, "Your session has expired. Please login again.")
        }

        if path.hasSuffix("/api/locks") && method == "POST" {
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
            let type = body["type"] as? Int ?? 0
            let clientId = body["clientId"] as? String ?? ""
            if let other = locks.values.first(where: { $0.clientId != clientId && ($0.type == 2 || type == 2) }) {
                return error(400, "Cannot acquire lock because there is an active lock for client: 1 #\(other.clientId)",
                             code: other.type == 2 ? "hasExclusiveLock" : "hasSyncLock")
            }
            locks["\(type)_1_\(clientId)"] = (type, clientId)
            return json(200, ["id": "lock", "type": type, "clientId": clientId, "clientType": 1])
        }
        if path.contains("/api/locks/"), method == "DELETE" {
            locks.removeValue(forKey: String(path.split(separator: "/").last ?? ""))
            return (Data(), 200)
        }

        guard let start = path.range(of: "/api/items/root:/") else { return error(404, "Not found: \(path)") }
        var rest = String(path[start.upperBound...])
        if rest.hasSuffix(":/delta") {
            let cursorText = components.queryItems?.first { $0.name == "cursor" }?.value ?? ""
            let cursor = cursorText.isEmpty ? 0 : Int(cursorText) ?? -1
            guard cursor >= 0, cursor <= changes.count else {
                return error(400, "Delta cursor is invalid and the complete data should be resynced", code: "resyncRequired")
            }
            let end = min(changes.count, cursor + pageSize)
            let items: [[String: Any]] = changes[cursor..<end].map { c in
                var item: [String: Any] = ["item_name": c.name, "type": c.type, "updated_time": 0]
                if c.type != 3 { item["jop_updated_time"] = c.jopUpdatedTime }
                return item
            }
            return json(200, ["items": items, "cursor": String(end), "has_more": end < changes.count])
        }
        let isContent = rest.hasSuffix(":/content")
        rest = String(rest.dropLast(isContent ? ":/content".count : 1))
        switch method {
        case "GET":
            guard let data = files[rest] else { return error(404, "Not found: root:/\(rest):") }
            return isContent ? (data, 200) : json(200, ["name": rest])
        case "PUT":
            let body = request.httpBody ?? Data()
            if rest.hasSuffix(".md"), !(String(data: body, encoding: .utf8) ?? "").contains("type_: ") {
                return error(500, "Missing required property: type_: ")
            }
            store(rest, body)
            return json(200, ["name": rest])
        case "DELETE":
            erase(rest)
            return (Data(), 200)
        default:
            return error(405, "Method not allowed")
        }
    }
}
