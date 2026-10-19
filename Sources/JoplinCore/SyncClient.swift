import Foundation

public enum SyncError: Error, Equatable, CustomStringConvertible {
    case notConfigured
    case invalidURL(String)
    case authentication(String)
    case http(status: Int, code: String, message: String)
    case encryptionEnabled
    case unsupportedSyncVersion(Int)
    case locked(String)
    case invalidResponse(String)

    public var description: String {
        switch self {
        case .notConfigured: return "Synchronisation is not configured. Enter the server URL, email and password in Settings."
        case .invalidURL(let u): return "Invalid server URL: \(u)"
        case .authentication(let m): return "Login failed: \(m)"
        case .http(let status, _, let message): return "Server error \(status): \(message)"
        case .encryptionEnabled:
            return "End-to-end encryption is enabled on this sync target. Joplin Native does not support encrypted sync yet."
        case .unsupportedSyncVersion(let v): return "The sync target uses format version \(v), which this app does not support."
        case .locked(let m): return "The sync target is locked by another client: \(m)"
        case .invalidResponse(let m): return "Unexpected server response: \(m)"
        }
    }
}

/// Sends HTTP requests. Injected so that tests can run against an in-memory server.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncError.invalidResponse("not an HTTP response") }
        return (data, http)
    }
}

public struct DeltaItem: Sendable, Equatable {
    public enum Change: Int, Sendable { case create = 1, update = 2, delete = 3 }
    public var name: String
    public var change: Change
    /// `updated_time` of the Joplin item inside the file (0 when unknown, e.g. for deletions).
    public var itemUpdatedTime: Int64
}

public struct DeltaPage: Sendable {
    public var items: [DeltaItem]
    public var cursor: String
    public var hasMore: Bool
}

/// REST client for Joplin Server (`packages/server`), the API used by Joplin's "Joplin Server" sync target.
/// Requests may run concurrently; only the session id is shared between them.
public final class JoplinServerClient: @unchecked Sendable {
    public let baseURL: URL
    let email: String
    let password: String
    let transport: HTTPTransport
    private let sessionLock = NSLock()
    private var currentSession: String?
    private(set) var sessionId: String? {
        get { sessionLock.withLock { currentSession } }
        set { sessionLock.withLock { currentSession = newValue } }
    }

    public init(baseURL: String, email: String, password: String, transport: HTTPTransport = URLSessionTransport()) throws {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else {
            throw SyncError.invalidURL(baseURL)
        }
        self.baseURL = url
        self.email = email
        self.password = password
        self.transport = transport
    }

    static func itemPath(_ name: String) -> String { "api/items/root:/\(name):" }

    private func url(_ path: String, query: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(string: baseURL.absoluteString + "/" + path) else {
            throw SyncError.invalidURL(path)
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw SyncError.invalidURL(path) }
        return url
    }

    private static func errorInfo(_ data: Data) -> (code: String, message: String) {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = obj?["error"] as? String ?? String(data: data, encoding: .utf8) ?? ""
        return (obj?["code"] as? String ?? "", message)
    }

    public func login() async throws {
        var request = URLRequest(url: try url("api/sessions", query: []))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw SyncError.authentication(Self.errorInfo(data).message)
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let id = obj["id"] as? String else {
            throw SyncError.invalidResponse("no session id")
        }
        sessionId = id
    }

    /// Performs an authenticated request. A rejected session is renewed once (sessions expire on the server).
    @discardableResult
    func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
                 allowNotFound: Bool = false) async throws -> (data: Data, status: Int) {
        if sessionId == nil { try await login() }
        for attempt in 0..<2 {
            var request = URLRequest(url: try url(path, query: query))
            request.httpMethod = method
            request.setValue(sessionId, forHTTPHeaderField: "X-API-AUTH")
            request.setValue("2.6.0", forHTTPHeaderField: "X-API-MIN-VERSION")
            if let body {
                request.httpBody = body
                request.setValue(path.hasPrefix("api/locks") ? "application/json" : "application/octet-stream",
                                 forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await transport.send(request)
            let status = response.statusCode
            if (200..<300).contains(status) || (allowNotFound && status == 404) { return (data, status) }
            if status == 403, attempt == 0 {
                try await login()
                continue
            }
            let info = Self.errorInfo(data)
            throw SyncError.http(status: status, code: info.code, message: info.message)
        }
        throw SyncError.invalidResponse("request retry failed")
    }

    /// File content, or nil when it does not exist.
    public func get(_ name: String) async throws -> Data? {
        let (data, status) = try await request("GET", Self.itemPath(name) + "/content", allowNotFound: true)
        return status == 404 ? nil : data
    }

    public func put(_ name: String, _ data: Data) async throws {
        try await request("PUT", Self.itemPath(name) + "/content", body: data)
    }

    public func delete(_ name: String) async throws {
        try await request("DELETE", Self.itemPath(name), allowNotFound: true)
    }

    public func delta(cursor: String) async throws -> DeltaPage {
        let query = cursor.isEmpty ? [] : [URLQueryItem(name: "cursor", value: cursor)]
        let (data, _) = try await request("GET", Self.itemPath("") + "/delta", query: query)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SyncError.invalidResponse("delta is not JSON")
        }
        let items = (obj["items"] as? [[String: Any]] ?? []).compactMap { item -> DeltaItem? in
            guard let name = item["item_name"] as? String, let raw = item["type"] as? Int,
                  let change = DeltaItem.Change(rawValue: raw) else { return nil }
            let time = (item["jop_updated_time"] as? NSNumber)?.int64Value ?? 0
            return DeltaItem(name: name, change: change, itemUpdatedTime: time)
        }
        return DeltaPage(items: items, cursor: obj["cursor"] as? String ?? cursor, hasMore: obj["has_more"] as? Bool ?? false)
    }

    /// Joplin lock types: 1 = sync, 2 = exclusive. Client type 1 = desktop.
    public func acquireSyncLock(clientId: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["type": 1, "clientType": 1, "clientId": clientId])
        do {
            try await request("POST", "api/locks", body: body)
        } catch SyncError.http(_, let code, let message) where !code.isEmpty {
            throw SyncError.locked(message)
        }
    }

    public func releaseSyncLock(clientId: String) async {
        _ = try? await request("DELETE", "api/locks/1_1_\(clientId)", allowNotFound: true)
    }
}
