import Foundation
import CryptoKit
import Network
#if canImport(AppKit)
import AppKit
#endif

/// Logging in to a connector on the internet, the way the MCP authorization spec describes it: the server's 401 points
/// to its protected-resource metadata, that names the authorization server, the app registers itself there when the
/// server allows it (dynamic client registration), and the user logs in in their own browser with the authorization
/// code and PKCE. The answer comes back to a small listener on 127.0.0.1. Tokens go to the Keychain and are refreshed
/// when they expire. The app never sees the user's password.
actor MCPOAuth {
    static let shared = MCPOAuth()

    struct Tokens: Codable {
        var access: String
        var refresh: String?
        var expires: Date?
        var tokenEndpoint: String
        var clientID: String
        var clientSecret: String?
        var resource: String
    }

    struct Client: Codable {
        var clientID: String
        var clientSecret: String?
        var port: UInt16
    }

    enum OAuthError: LocalizedError {
        case noMetadata, noAuthorizationServer, noRegistration, stateMismatch, denied(String), token(String), timeout
        var errorDescription: String? {
            switch self {
            case .noMetadata: return "The server asks to log in but does not say where."
            case .noAuthorizationServer: return "The login server could not be found."
            case .noRegistration: return "The login server does not let MacAIMagic register itself; add a token by hand instead."
            case .stateMismatch: return "The answer from the browser did not belong to this login."
            case .denied(let why): return "Logging in was refused: \(why)"
            case .token(let why): return "No token: \(why)"
            case .timeout: return "Logging in took longer than 5 minutes."
            }
        }
    }

    var session: URLSession = .shared
    /// Opens the login page; tests replace it.
    var openBrowser: @Sendable (URL) -> Void = { url in
        #if canImport(AppKit)
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        #endif
    }
    var store: (get: @Sendable (String) -> String?, set: @Sendable (String, String) -> Void, delete: @Sendable (String) -> Void) =
        ({ MCPKeychain.get($0) }, { MCPKeychain.set($0, for: $1) }, { MCPKeychain.delete($0) })

    func configure(session: URLSession? = nil, openBrowser: (@Sendable (URL) -> Void)? = nil,
                   store: (get: @Sendable (String) -> String?, set: @Sendable (String, String) -> Void, delete: @Sendable (String) -> Void)? = nil) {
        if let session { self.session = session }
        if let openBrowser { self.openBrowser = openBrowser }
        if let store { self.store = store }
    }

    static func key(_ server: URL) -> String {
        var c = URLComponents(url: server, resolvingAgainstBaseURL: false)
        c?.query = nil
        c?.fragment = nil
        return "oauth:" + (c?.string ?? server.absoluteString)
    }

    func tokens(for server: URL) -> Tokens? {
        store.get(Self.key(server)).flatMap { try? JSONDecoder().decode(Tokens.self, from: Data($0.utf8)) }
    }

    private func save(_ t: Tokens, for server: URL) {
        if let d = try? JSONEncoder().encode(t) { store.set(String(decoding: d, as: UTF8.self), Self.key(server)) }
    }

    func logOut(_ server: URL) { store.delete(Self.key(server)) }

    /// A valid access token, refreshed when it expired; nil when there is none (the server's 401 then starts a login).
    func accessToken(for server: URL) async -> String? {
        guard var t = tokens(for: server) else { return nil }
        if let exp = t.expires, exp < Date().addingTimeInterval(60) {
            guard let refresh = t.refresh, let fresh = try? await tokenRequest(t.tokenEndpoint, [
                "grant_type": "refresh_token", "refresh_token": refresh, "client_id": t.clientID, "resource": t.resource,
            ], secret: t.clientSecret) else { return nil }
            t.access = fresh.access
            t.refresh = fresh.refresh ?? refresh
            t.expires = fresh.expires
            save(t, for: server)
        }
        return t.access
    }

    // MARK: - discovery

    /// The `resource_metadata` address in a WWW-Authenticate header.
    static func resourceMetadataURL(from challenge: String?) -> URL? {
        guard let c = challenge, let r = c.range(of: #"resource_metadata="([^"]+)""#, options: .regularExpression) else { return nil }
        let quoted = c[r].drop { $0 != "\"" }.dropFirst().dropLast()
        return URL(string: String(quoted))
    }

    /// Where well-known metadata stands: https://host/.well-known/<name>[/path].
    static func wellKnown(_ base: URL, _ name: String) -> [URL] {
        var c = URLComponents()
        c.scheme = base.scheme
        c.host = base.host
        c.port = base.port
        let path = base.path == "/" ? "" : base.path
        var out: [URL] = []
        if !path.isEmpty { c.path = "/.well-known/\(name)\(path)"; if let u = c.url { out.append(u) } }
        c.path = "/.well-known/\(name)"
        if let u = c.url { out.append(u) }
        return out
    }

    private func getJSON(_ url: URL) async -> [String: Any]? {
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - logging in

    func authorize(server: URL, challenge: String?, name: String) async throws {
        // 1. the protected resource: which authorization server, which scopes
        var resourceMeta: [String: Any]?
        for u in [Self.resourceMetadataURL(from: challenge)].compactMap({ $0 }) + Self.wellKnown(server, "oauth-protected-resource") {
            if let m = await getJSON(u) { resourceMeta = m; break }
        }
        let resource = resourceMeta?["resource"] as? String ?? server.absoluteString
        guard let asString = (resourceMeta?["authorization_servers"] as? [String])?.first ?? (resourceMeta == nil ? server.absoluteString : nil),
              let asURL = URL(string: asString) else { throw OAuthError.noMetadata }
        // 2. the authorization server
        var asMeta: [String: Any]?
        for u in Self.wellKnown(asURL, "oauth-authorization-server") + Self.wellKnown(asURL, "openid-configuration") {
            if let m = await getJSON(u) { asMeta = m; break }
        }
        guard let meta = asMeta, let authEndpoint = meta["authorization_endpoint"] as? String,
              let tokenEndpoint = meta["token_endpoint"] as? String else { throw OAuthError.noAuthorizationServer }
        // 3. this app as a client of that server: registered once, kept with its loopback port
        let clientKey = "oauth-client:" + asString
        var client = store.get(clientKey).flatMap { try? JSONDecoder().decode(Client.self, from: Data($0.utf8)) }
        let listener = try CallbackListener(port: client?.port ?? 0)
        if client == nil || client?.port != listener.port {
            guard let reg = meta["registration_endpoint"] as? String, let regURL = URL(string: reg) else { throw OAuthError.noRegistration }
            client = try await register(regURL, port: listener.port, name: name)
            if let d = try? JSONEncoder().encode(client) { store.set(String(decoding: d, as: UTF8.self), clientKey) }
        }
        guard let client else { throw OAuthError.noRegistration }
        // 4. the login in the browser, with PKCE and a state that must come back
        let pkce = Self.pkcePair()
        let state = Self.randomString(24)
        let redirect = "http://127.0.0.1:\(listener.port)/callback"
        var c = URLComponents(string: authEndpoint)
        var items = c?.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "resource", value: resource),
        ]
        if let scopes = resourceMeta?["scopes_supported"] as? [String], !scopes.isEmpty {
            items.append(URLQueryItem(name: "scope", value: scopes.joined(separator: " ")))
        }
        c?.queryItems = items
        guard let loginURL = c?.url else { throw OAuthError.noAuthorizationServer }
        openBrowser(loginURL)
        let answer = try await listener.wait(seconds: 300)
        guard answer["state"] == state else { throw OAuthError.stateMismatch }
        if let err = answer["error"] { throw OAuthError.denied(answer["error_description"] ?? err) }
        guard let code = answer["code"] else { throw OAuthError.denied("no code") }
        // 5. the code for tokens
        let t = try await tokenRequest(tokenEndpoint, [
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirect,
            "client_id": client.clientID, "code_verifier": pkce.verifier, "resource": resource,
        ], secret: client.clientSecret)
        save(Tokens(access: t.access, refresh: t.refresh, expires: t.expires, tokenEndpoint: tokenEndpoint,
                    clientID: client.clientID, clientSecret: client.clientSecret, resource: resource), for: server)
    }

    private func register(_ url: URL, port: UInt16, name: String) async throws -> Client {
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": "MacAIMagic",
            "redirect_uris": ["http://127.0.0.1:\(port)/callback"],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ])
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = json["client_id"] as? String else { throw OAuthError.noRegistration }
        return Client(clientID: id, clientSecret: json["client_secret"] as? String, port: port)
    }

    private func tokenRequest(_ endpoint: String, _ form: [String: String], secret: String?) async throws -> (access: String, refresh: String?, expires: Date?) {
        guard let url = URL(string: endpoint) else { throw OAuthError.token("bad endpoint") }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        var all = form
        if let secret { all["client_secret"] = secret }
        req.httpBody = Data(all.sorted { $0.key < $1.key }.map { "\(Self.formEscape($0.key))=\(Self.formEscape($0.value))" }.joined(separator: "&").utf8)
        let (data, resp) = try await session.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true, let access = json["access_token"] as? String else {
            throw OAuthError.token(json["error_description"] as? String ?? json["error"] as? String ?? "HTTP error")
        }
        let expires = (json["expires_in"] as? Double).map { Date().addingTimeInterval($0) }
            ?? (json["expires_in"] as? Int).map { Date().addingTimeInterval(Double($0)) }
        return (access, json["refresh_token"] as? String, expires)
    }

    // MARK: - helpers

    static func formEscape(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func randomString(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return base64url(data)
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func pkcePair() -> (verifier: String, challenge: String) {
        let verifier = randomString(32)
        return (verifier, challenge(for: verifier))
    }

    static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}

/// Waits for the browser to come back to http://127.0.0.1:<port>/callback?code=…&state=…, answers with a short page,
/// and gives the query parameters.
final class CallbackListener: @unchecked Sendable {
    private(set) var port: UInt16 = 0
    private let listener: NWListener
    private let lock = NSLock()
    private var result: [String: String]?
    private var waiter: CheckedContinuation<[String: String], Error>?

    init(port wanted: UInt16) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: wanted) ?? .any)
        let l: NWListener
        do { l = try NWListener(using: params) } catch {
            // the port of an earlier registration is taken: another one (the client registers again)
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            l = try NWListener(using: params)
        }
        listener = l
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        l.start(queue: .global())
        _ = ready.wait(timeout: .now() + 5)
        port = l.port?.rawValue ?? wanted
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global())
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            let text = String(decoding: data ?? Data(), as: UTF8.self)
            let firstLine = text.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.split(separator: " ")
            var query: [String: String] = [:]
            if parts.count >= 2, let c = URLComponents(string: "http://127.0.0.1" + parts[1]), c.path == "/callback" {
                for item in c.queryItems ?? [] { query[item.name] = item.value ?? "" }
            }
            let ok = !query.isEmpty
            let body = ok ? "<html><body style=\"font-family:-apple-system;padding:40px\"><h2>MacAIMagic</h2><p>Ingelogd. Je kunt dit venster sluiten. · Logged in. You can close this window.</p></body></html>"
                          : "<html><body>Not found</body></html>"
            let response = "HTTP/1.1 \(ok ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
            if ok { self?.deliver(query) }
        }
    }

    private func deliver(_ query: [String: String]) {
        lock.lock()
        if result == nil { result = query }
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(returning: query)
    }

    private func takeWaiter() -> CheckedContinuation<[String: String], Error>? {
        lock.lock()
        defer { lock.unlock() }
        let w = waiter
        waiter = nil
        return w
    }

    func wait(seconds: Double) async throws -> [String: String] {
        defer { listener.cancel() }
        return try await withThrowingTaskGroup(of: [String: String].self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { cont in
                    self.lock.lock()
                    if let r = self.result { self.lock.unlock(); cont.resume(returning: r); return }
                    self.waiter = cont
                    self.lock.unlock()
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw MCPOAuth.OAuthError.timeout
            }
            defer { group.cancelAll() }
            do { return try await group.next()! } catch {
                let w = takeWaiter()
                w?.resume(throwing: error)
                throw error
            }
        }
    }
}
