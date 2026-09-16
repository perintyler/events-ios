import Foundation

enum EventsError: LocalizedError, Equatable {
    case badURL
    case http(Int, String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "The server URL is not valid."
        case .http(let code, let detail):
            // 403, not 401: `requireWebAuth` in packages/auth returns forbidden
            // for an unauthenticated caller. Saying "check the secret" for a
            // 401 the server never sends would send someone hunting the wrong
            // setting.
            if code == 403 {
                return "Not authorized (403) — check the secret in Settings, or that this device is on the tailnet."
            }
            return detail.isEmpty ? "Server error \(code)." : "Server error \(code): \(detail)"
        case .decoding(let detail):
            return "Could not read the server's response: \(detail)"
        }
    }
}

/// Talks to `/api/v1/events` on the Barry API.
///
/// No custom backend was written for this app — it is a client of the routes in
/// `servers/api/src/routes/events.ts`, reached through the barry.works proxy.
struct EventsClient {
    let config: ServerConfig
    var urlSession: URLSession = .shared

    // MARK: - Reads

    /// One page of the feed.
    ///
    /// `cursor` is the opaque keyset cursor from a previous response. Note the
    /// server SILENTLY IGNORES a cursor it cannot decode and returns page one
    /// again with HTTP 200 (verified live) — so the caller must detect a page
    /// that contributes nothing new rather than trusting the cursor round-trip.
    /// `AppStore.loadMore` is where that guard lives.
    func events(
        limit: Int = 50,
        cursor: String? = nil,
        type: EventType? = nil,
        severity: Severity? = nil,
        unreadOnly: Bool = false
    ) async throws -> EventListResponse {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        if let type { query.append(URLQueryItem(name: "type", value: type.wireValue)) }
        if let severity { query.append(URLQueryItem(name: "severity", value: severity.rawValue)) }
        if unreadOnly { query.append(URLQueryItem(name: "unread", value: "true")) }
        return try await get(EventListResponse.self, path: "/api/v1/events", query: query)
    }

    /// The GLOBAL unread count, which is not the same as the unread events on
    /// screen — the backlog runs to four figures while a page holds 50.
    func unreadCount() async throws -> Int {
        try await get(UnreadCountResponse.self, path: "/api/v1/events/unread-count").count
    }

    /// A cheap authenticated round trip for the Settings "Test connection"
    /// button. There is no unauthenticated health route on this API, so this
    /// deliberately exercises the same path the feed uses.
    func probe() async throws {
        _ = try await events(limit: 1)
    }

    // MARK: - Writes

    func markRead(_ eventId: String) async throws {
        _ = try await postIgnoringBody(path: "/api/v1/events/\(eventId)/read", body: nil)
    }

    /// Mark everything read, optionally narrowed to one type.
    ///
    /// `type` is the ONLY filter the server honours here — `packages/db`'s
    /// `markAllRead` ignores severity, session and unread entirely. Callers must
    /// not imply a narrower scope than this actually has.
    func markAllRead(type: EventType? = nil) async throws -> Int {
        let body = type.map { ["type": $0.wireValue] }
        let data = try await postIgnoringBody(
            path: "/api/v1/events/read-all",
            body: body.map { try? JSONSerialization.data(withJSONObject: $0) } ?? nil
        )
        return (try? JSONDecoder.barry.decode(MarkAllReadResponse.self, from: data).count) ?? 0
    }

    // MARK: - Transport

    private func get<T: Decodable>(
        _ type: T.Type, path: String, query: [URLQueryItem] = []
    ) async throws -> T {
        guard let req = config.request(path: path, query: query) else { throw EventsError.badURL }
        return try await run(type, req)
    }

    @discardableResult
    private func postIgnoringBody(path: String, body: Data?) async throws -> Data {
        guard var req = config.request(path: path) else { throw EventsError.badURL }
        req.httpMethod = "POST"
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await runRaw(req)
    }

    private func run<T: Decodable>(_ type: T.Type, _ req: URLRequest) async throws -> T {
        let data = try await runRaw(req)
        do {
            return try JSONDecoder.barry.decode(T.self, from: data)
        } catch {
            throw EventsError.decoding(String(describing: error))
        }
    }

    private func runRaw(_ req: URLRequest) async throws -> Data {
        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw EventsError.decoding("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw EventsError.http(http.statusCode, Self.readableDetail(from: data))
        }
        return data
    }

    /// Unwrap the several error shapes this API emits before falling back to
    /// the raw body. Note the error path DOES still carry `ok` — only success
    /// responses have it stripped.
    static func readableDetail(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8) ?? ""
        }
        if let detail = object["detail"] as? String { return detail }
        if let error = object["error"] as? String { return error }
        if let title = object["title"] as? String { return title }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
