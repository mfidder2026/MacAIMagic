import Foundation

/// An MCP server on the internet (Streamable HTTP): every message is a POST; the answer is JSON or a short stream of
/// server-sent events. The server may give a session id, which goes with every next message. With `oauth` the app logs
/// in when the server answers 401 (MCPOAuth); otherwise the headers carry the token (for example GitHub).
final class HTTPTransport: MCPTransport, @unchecked Sendable {
    let url: URL
    let serverName: String
    let oauth: Bool
    var headers: [String: String]
    var onNotification: ((String) -> Void)?
    let log: @Sendable (String) -> Void
    let session: URLSession

    private let lock = NSLock()
    private var sessionID: String?
    private var nextID = 1

    init(url: URL, headers: [String: String], serverName: String, oauth: Bool, session: URLSession = .shared,
         log: @escaping @Sendable (String) -> Void) {
        self.url = url
        self.headers = headers
        self.serverName = serverName
        self.oauth = oauth
        self.session = session
        self.log = log
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func start() async throws {}

    func request(_ method: String, params: [String: Any]?, timeout: TimeInterval) async throws -> [String: Any] {
        let id = locked { defer { nextID += 1 }; return nextID }
        var msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { msg["params"] = params }
        let messages = try await post(msg, timeout: timeout)
        guard let answer = messages.first(where: { ($0["id"] as? Int) == id || ($0["id"] as? NSNumber)?.intValue == id }) else {
            throw MCPError.badResponse
        }
        if let error = answer["error"] as? [String: Any] {
            throw MCPError.server(error["code"] as? Int ?? 0, error["message"] as? String ?? "")
        }
        return answer["result"] as? [String: Any] ?? [:]
    }

    func notify(_ method: String, params: [String: Any]?) async throws {
        var msg: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { msg["params"] = params }
        _ = try await post(msg, timeout: 30)
    }

    /// Sends one message; returns the JSON-RPC messages that came back (none for a notification).
    private func post(_ msg: [String: Any], timeout: TimeInterval, retried: Bool = false) async throws -> [[String: Any]] {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(MCPClient.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sid = locked({ sessionID }) { req.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if oauth, headers["Authorization"] == nil, let token = await MCPOAuth.shared.accessToken(for: url) {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: msg)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw MCPError.badResponse }
        if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id") { locked { sessionID = sid } }
        if http.statusCode == 401 {
            let challenge = http.value(forHTTPHeaderField: "WWW-Authenticate")
            guard oauth, !retried, headers["Authorization"] == nil else { throw MCPError.unauthorized(challenge) }
            // log in (the browser opens) and send the same message again
            try await MCPOAuth.shared.authorize(server: url, challenge: challenge, name: serverName)
            return try await post(msg, timeout: timeout, retried: true)
        }
        if http.statusCode == 202 || data.isEmpty { return [] }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(decoding: data.prefix(500), as: UTF8.self)
            log("HTTP \(http.statusCode): \(text)")
            throw MCPError.server(http.statusCode, text)
        }
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        let messages = type.contains("text/event-stream") ? Self.events(in: data) : Self.json(data)
        for m in messages where m["id"] == nil {
            if let method = m["method"] as? String { onNotification?(method) }
        }
        return messages
    }

    /// A JSON answer: one message or a batch.
    static func json(_ data: Data) -> [[String: Any]] {
        let obj = try? JSONSerialization.jsonObject(with: data)
        if let one = obj as? [String: Any] { return [one] }
        return obj as? [[String: Any]] ?? []
    }

    /// The `data:` lines of server-sent events; each event's lines together are one JSON message.
    static func events(in data: Data) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var current: [String] = []
        func flush() {
            if !current.isEmpty, let d = current.joined(separator: "\n").data(using: .utf8) { out += json(d) }
            current = []
        }
        for raw in String(decoding: data, as: UTF8.self).components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.isEmpty { flush() }
            else if line.hasPrefix("data:") { current.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
        }
        flush()
        return out
    }

    func close() {
        guard let sid = locked({ sessionID }) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        session.dataTask(with: req).resume()
        locked { sessionID = nil }
    }
}
