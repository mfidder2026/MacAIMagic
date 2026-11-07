import Foundation

/// A tool a connector (MCP server) offers.
struct MCPTool: Hashable {
    var name: String
    var title: String?
    var description: String
    /// The JSON schema of the arguments, as JSON text (so the struct stays Hashable).
    var schema: String
    /// What the server says about it (MCP tool annotations); nil when it says nothing.
    var readOnly: Bool?
    var destructive: Bool?

    init(name: String, title: String? = nil, description: String, schema: [String: Any] = ["type": "object", "properties": [:]],
         readOnly: Bool? = nil, destructive: Bool? = nil) {
        self.name = name
        self.title = title
        self.description = description
        let data = (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])) ?? Data("{}".utf8)
        self.schema = String(decoding: data, as: UTF8.self)
        self.readOnly = readOnly
        self.destructive = destructive
    }

    init?(json: [String: Any]) {
        guard let name = json["name"] as? String else { return nil }
        let annotations = json["annotations"] as? [String: Any]
        self.init(name: name, title: (json["title"] as? String) ?? (annotations?["title"] as? String),
                  description: json["description"] as? String ?? "",
                  schema: json["inputSchema"] as? [String: Any] ?? ["type": "object", "properties": [:]],
                  readOnly: annotations?["readOnlyHint"] as? Bool, destructive: annotations?["destructiveHint"] as? Bool)
    }

    var schemaObject: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(schema.utf8))) as? [String: Any] ?? ["type": "object", "properties": [:]]
    }
}

enum MCPError: LocalizedError {
    case notRunning(String), timeout(String), server(Int, String), badResponse, unauthorized(String?)
    var errorDescription: String? {
        switch self {
        case .notRunning(let s): return "The connector is not running: \(s)"
        case .timeout(let m): return "The connector did not answer \(m) in time."
        case .server(let code, let msg): return "The connector answered with an error (\(code)): \(msg)"
        case .badResponse: return "The connector sent something that is not a valid answer."
        case .unauthorized: return "The connector asks to log in."
        }
    }
}

/// How the client reaches a server: a program on this Mac (stdio) or an address on the internet (HTTP).
protocol MCPTransport: AnyObject {
    func start() async throws
    /// Sends a request and returns its `result`.
    func request(_ method: String, params: [String: Any]?, timeout: TimeInterval) async throws -> [String: Any]
    func notify(_ method: String, params: [String: Any]?) async throws
    func close()
    /// Notifications from the server (for example notifications/tools/list_changed).
    var onNotification: ((String) -> Void)? { get set }
}

/// One connection to an MCP server: the handshake, the list of tools and calling one.
final class MCPClient {
    static let protocolVersion = "2025-06-18"
    let transport: MCPTransport
    private(set) var serverName = ""
    private(set) var instructions: String?

    init(transport: MCPTransport) { self.transport = transport }

    func connect() async throws {
        try await transport.start()
        let result = try await transport.request("initialize", params: [
            "protocolVersion": Self.protocolVersion,
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "MacAIMagic", "version": Paths.appVersion ?? "dev"],
        ], timeout: 60)
        serverName = (result["serverInfo"] as? [String: Any])?["name"] as? String ?? ""
        instructions = result["instructions"] as? String
        try await transport.notify("notifications/initialized", params: nil)
    }

    /// Every tool, over as many pages as the server uses.
    func listTools() async throws -> [MCPTool] {
        var tools: [MCPTool] = []
        var cursor: String?
        repeat {
            let result = try await transport.request("tools/list", params: cursor.map { ["cursor": $0] }, timeout: 60)
            tools += (result["tools"] as? [[String: Any]] ?? []).compactMap(MCPTool.init(json:))
            cursor = result["nextCursor"] as? String
        } while cursor != nil && tools.count < 1000
        return tools
    }

    /// The tool's answer as text; `isError` when the tool says it failed.
    func callTool(_ name: String, arguments: [String: Any], timeout: TimeInterval = 300) async throws -> (text: String, isError: Bool) {
        let result = try await transport.request("tools/call", params: ["name": name, "arguments": arguments], timeout: timeout)
        return (Self.text(of: result), result["isError"] as? Bool ?? false)
    }

    /// The content of a tool result in words: text as it is, other kinds named.
    static func text(of result: [String: Any]) -> String {
        var parts: [String] = []
        for item in result["content"] as? [[String: Any]] ?? [] {
            switch item["type"] as? String {
            case "text": parts.append(item["text"] as? String ?? "")
            case "image": parts.append("[image, \(item["mimeType"] as? String ?? "")]")
            case "audio": parts.append("[audio]")
            case "resource":
                let r = item["resource"] as? [String: Any]
                parts.append((r?["text"] as? String) ?? "[resource \(r?["uri"] as? String ?? "")]")
            case "resource_link": parts.append("[link \(item["name"] as? String ?? "") \(item["uri"] as? String ?? "")]")
            default: break
            }
        }
        if parts.isEmpty, let structured = result["structuredContent"],
           let data = try? JSONSerialization.data(withJSONObject: structured, options: [.prettyPrinted, .sortedKeys]) {
            parts.append(String(decoding: data, as: UTF8.self))
        }
        return parts.joined(separator: "\n")
    }

    func close() { transport.close() }
}

/// A program on this Mac that speaks MCP on its standard input and output, one JSON message per line. It starts in the
/// user's login shell, so `npx` and `uvx` are found as in Terminal. Lines that are no JSON-RPC (a shell greeting) and
/// everything on stderr go to the log.
final class StdioTransport: MCPTransport, @unchecked Sendable {
    let command: String
    let arguments: [String]
    let environment: [String: String]
    var onNotification: ((String) -> Void)?
    let log: @Sendable (String) -> Void

    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var ended: String?

    init(command: String, arguments: [String], environment: [String: String], log: @escaping @Sendable (String) -> Void) {
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.log = log
    }

    static func shellQuote(_ s: String) -> String {
        s.isEmpty ? "''" : (s.allSatisfy { $0.isLetter || $0.isNumber || "-_./:@=+,".contains($0) } ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'")
    }

    func start() async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "exec " + ([command] + arguments).map(Self.shellQuote).joined(separator: " ")]
        p.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.received(d)
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.log(String(decoding: d, as: UTF8.self))
        }
        p.terminationHandler = { [weak self] proc in
            self?.finish("the program stopped (exit code \(proc.terminationStatus))")
        }
        try p.run()
        locked { process = p; input = stdin.fileHandleForWriting; ended = nil }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func received(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        lock.unlock()
        for line in lines where !line.isEmpty { handle(line) }
    }

    private func handle(_ line: Data) {
        guard let msg = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], msg["jsonrpc"] as? String == "2.0" else {
            log(String(decoding: line, as: UTF8.self))
            return
        }
        if let method = msg["method"] as? String {
            if let id = msg["id"] {
                // a request from the server (ping, or something this client does not offer)
                let reply: [String: Any] = method == "ping"
                    ? ["jsonrpc": "2.0", "id": id, "result": [:] as [String: Any]]
                    : ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Not supported by MacAIMagic"]]
                write(reply)
            } else {
                onNotification?(method)
            }
            return
        }
        guard let id = (msg["id"] as? Int) ?? (msg["id"] as? NSNumber)?.intValue else { return }
        lock.lock()
        let cont = pending.removeValue(forKey: id)
        lock.unlock()
        if let error = msg["error"] as? [String: Any] {
            cont?.resume(throwing: MCPError.server(error["code"] as? Int ?? 0, error["message"] as? String ?? ""))
        } else {
            cont?.resume(returning: msg["result"] as? [String: Any] ?? [:])
        }
    }

    private func write(_ msg: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        data.append(0x0A)
        let h = locked { input }
        try? h?.write(contentsOf: data)
    }

    func request(_ method: String, params: [String: Any]?, timeout: TimeInterval) async throws -> [String: Any] {
        let (id, why): (Int, String?) = locked {
            defer { nextID += 1 }
            return (nextID, ended)
        }
        if let why { throw MCPError.notRunning(why) }
        var msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { msg["params"] = params }
        return try await withThrowingTaskGroup(of: [String: Any].self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { cont in
                    self.locked { self.pending[id] = cont }
                    self.write(msg)
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw MCPError.timeout(method)
            }
            defer { group.cancelAll() }
            do {
                let first = try await group.next()!
                return first
            } catch {
                // the waiting continuation must not stay behind
                let cont = locked { pending.removeValue(forKey: id) }
                cont?.resume(throwing: error)
                throw error
            }
        }
    }

    func notify(_ method: String, params: [String: Any]?) async throws {
        var msg: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { msg["params"] = params }
        write(msg)
    }

    private func finish(_ why: String) {
        lock.lock()
        ended = why
        let waiting = pending
        pending = [:]
        lock.unlock()
        for (_, c) in waiting { c.resume(throwing: MCPError.notRunning(why)) }
    }

    func close() {
        let p: Process? = locked { defer { process = nil }; return process }
        try? input?.close()
        if let p, p.isRunning { p.terminate() }
        finish("closed")
    }
}
