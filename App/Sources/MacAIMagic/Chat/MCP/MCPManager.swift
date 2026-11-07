import Foundation
import Security

/// One connector as it stands in mcp.json: the format of Claude Desktop (`command`/`args`/`env` for a program on this Mac,
/// `url`/`headers` for an address on the internet), plus what MacAIMagic adds. A value "keychain:<name>" in env or
/// headers is read from the Keychain when the connector starts, so tokens do not stand in the file.
struct MCPServerConfig: Codable, Equatable, Identifiable {
    var name: String = ""
    var command: String?
    var args: [String]?
    var env: [String: String]?
    var url: String?
    var headers: [String: String]?
    /// MacAIMagic: off connectors are not offered to the model.
    var enabled: Bool?
    /// "allow", "ask" or "deny" for tools that change something; read-only tools are allowed unless "deny".
    var right: String?
    /// Its tools are always in the request, without use_connector.
    var alwaysLoaded: Bool?
    /// One line for the model: what this connector is for.
    var description: String?
    /// A connector built into the app ("calendar") instead of a program or address.
    var builtin: String?
    /// Log in with OAuth when the server asks for it.
    var oauth: Bool?

    var id: String { name }
    var isEnabled: Bool { enabled ?? true }
    var isRemote: Bool { url != nil }
    var rightValue: String { right ?? "ask" }

    enum CodingKeys: String, CodingKey { case command, args, env, url, headers, enabled, right, alwaysLoaded, description, builtin, oauth }
}

/// mcp.json: `{"mcpServers": {name: config}}`.
struct MCPConfigFile: Codable {
    var mcpServers: [String: MCPServerConfig] = [:]

    static func parse(_ data: Data) -> [MCPServerConfig] {
        guard let file = try? JSONDecoder().decode(MCPConfigFile.self, from: data) else { return [] }
        return file.mcpServers.map { name, c in var c = c; c.name = name; return c }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    static func encode(_ servers: [MCPServerConfig]) -> Data {
        let file = MCPConfigFile(mcpServers: Dictionary(servers.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a }))
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(file)) ?? Data("{}".utf8)
    }
}

/// Tokens for connectors, in the login Keychain under the service "MacAIMagic connectors".
enum MCPKeychain {
    static let service = "MacAIMagic connectors"

    static func set(_ value: String, for account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }

    /// "keychain:<name>" becomes the stored value; anything else stays as it is.
    static func resolve(_ value: String) -> String {
        value.hasPrefix("keychain:") ? (get(String(value.dropFirst(9))) ?? "") : value
    }
}

/// The connectors: which there are, which run, their tools, and calling one. Programs start the first time a
/// conversation needs them and keep running until the app stops.
@MainActor
final class MCPManager: ObservableObject {
    /// A var so tests can use a manager with their own mcp.json.
    static var shared = MCPManager()
    static let loadTool = "use_connector"

    enum State: Equatable {
        case stopped, starting, ready(Int), failed(String)
        var isReady: Bool { if case .ready = self { return true }; return false }
    }

    @Published private(set) var servers: [MCPServerConfig] = []
    @Published private(set) var states: [String: State] = [:]
    @Published private(set) var logs: [String: String] = [:]
    private var clients: [String: MCPClient] = [:]
    private(set) var tools: [String: [MCPTool]] = [:]
    /// Connectors built into the app, by their `builtin` value.
    var builtins: [String: BuiltinConnector] = [:]
    private var starting: [String: Task<Void, Error>] = [:]
    let file: URL

    init(file: URL = Paths.mcpConfig) {
        self.file = file
        builtins["calendar"] = CalendarConnector()
        reload()
    }

    func reload() {
        servers = (try? Data(contentsOf: file)).map(MCPConfigFile.parse) ?? []
    }

    func save(_ list: [MCPServerConfig]) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? MCPConfigFile.encode(list).write(to: file, options: .atomic)
        // a changed connector starts again with its new settings
        for old in servers where list.first(where: { $0.name == old.name }) != old { stop(old.name) }
        servers = list
    }

    func upsert(_ config: MCPServerConfig, replacing old: String? = nil) {
        var list = servers.filter { $0.name != (old ?? config.name) && $0.name != config.name }
        list.append(config)
        save(list.sorted { $0.name.lowercased() < $1.name.lowercased() })
    }

    func remove(_ name: String) {
        stop(name)
        save(servers.filter { $0.name != name })
    }

    var enabled: [MCPServerConfig] { servers.filter(\.isEnabled) }
    func config(_ name: String) -> MCPServerConfig? { servers.first { $0.name.lowercased() == name.lowercased() } }

    // MARK: - running

    private func appendLog(_ name: String, _ text: String) {
        var l = (logs[name] ?? "") + text
        if !l.hasSuffix("\n") { l += "\n" }
        logs[name] = String(l.suffix(20_000))
    }

    /// Starts the connector when it does not run yet and returns its tools.
    @discardableResult
    func start(_ name: String) async throws -> [MCPTool] {
        guard let config = config(name) else { throw MCPError.notRunning("no connector named \(name)") }
        if states[config.name]?.isReady == true, let t = tools[config.name] { return t }
        if let running = starting[config.name] { try await running.value; return tools[config.name] ?? [] }
        let task = Task { try await self.connect(config) }
        starting[config.name] = task
        defer { starting[config.name] = nil }
        try await task.value
        return tools[config.name] ?? []
    }

    private func connect(_ config: MCPServerConfig) async throws {
        let name = config.name
        states[name] = .starting
        do {
            if let b = config.builtin {
                guard let builtin = builtins[b] else { throw MCPError.notRunning("unknown built-in connector \(b)") }
                tools[name] = try await builtin.start()
            } else {
                let transport = try makeTransport(config)
                let client = MCPClient(transport: transport)
                transport.onNotification = { [weak self] method in
                    guard method == "notifications/tools/list_changed" else { return }
                    Task { @MainActor in
                        if let t = try? await client.listTools() { self?.tools[name] = t; self?.states[name] = .ready(t.count) }
                    }
                }
                try await client.connect()
                clients[name] = client
                tools[name] = try await client.listTools()
            }
            states[name] = .ready(tools[name]?.count ?? 0)
            appendLog(name, "ready: \(tools[name]?.count ?? 0) tools")
        } catch {
            clients[name]?.close()
            clients[name] = nil
            states[name] = .failed(error.localizedDescription)
            appendLog(name, "failed: \(error.localizedDescription)")
            throw error
        }
    }

    func makeTransport(_ config: MCPServerConfig) throws -> MCPTransport {
        let name = config.name
        let log: @Sendable (String) -> Void = { text in Task { @MainActor in MCPManager.shared.appendLog(name, text) } }
        if let url = config.url, let u = URL(string: url) {
            let headers = (config.headers ?? [:]).mapValues(MCPKeychain.resolve)
            return HTTPTransport(url: u, headers: headers, serverName: name, oauth: config.oauth ?? true, log: log)
        }
        guard let command = config.command, !command.isEmpty else { throw MCPError.notRunning("no command or address") }
        return StdioTransport(command: command, arguments: config.args ?? [], environment: (config.env ?? [:]).mapValues(MCPKeychain.resolve), log: log)
    }

    func stop(_ name: String) {
        clients[name]?.close()
        clients[name] = nil
        tools[name] = nil
        if states[name] != nil { states[name] = .stopped }
    }

    func stopAll() { for name in Array(clients.keys) { stop(name) } }

    /// Starts it, lists its tools and stops it again (Instellingen → Connectors → Test).
    func test(_ config: MCPServerConfig) async -> Result<[MCPTool], Error> {
        let wasRunning = states[config.name]?.isReady == true
        do {
            if config.builtin == nil {
                let client = MCPClient(transport: try makeTransport(config))
                defer { if !wasRunning { client.close() } }
                try await client.connect()
                return .success(try await client.listTools())
            }
            return .success(try await builtins[config.builtin!]?.start() ?? [])
        } catch {
            return .failure(error)
        }
    }

    // MARK: - the model's side

    /// The tool name the model sees: "<connector>__<tool>", only letters, digits, _ and -, at most 64 characters.
    nonisolated static func toolName(server: String, tool: String) -> String {
        func clean(_ s: String) -> String {
            String(s.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? $0 : "_" })
        }
        let full = clean(server) + "__" + clean(tool)
        return full.count <= 64 ? full : String(full.prefix(64))
    }

    /// The connector and tool behind a name the model used, for connectors that are loaded.
    func route(_ name: String) -> (server: MCPServerConfig, tool: MCPTool)? {
        for s in enabled {
            for t in tools[s.name] ?? [] where Self.toolName(server: s.name, tool: t.name) == name { return (s, t) }
        }
        return nil
    }

    /// The connectors whose tools go in the request: those loaded in this conversation and those always loaded,
    /// when they run.
    func definitions(loaded: [String]) -> [[String: Any]] {
        let names = Set(loaded.map { $0.lowercased() } + enabled.filter { $0.alwaysLoaded == true }.map { $0.name.lowercased() })
        var out: [[String: Any]] = []
        for s in enabled where names.contains(s.name.lowercased()) {
            for t in tools[s.name] ?? [] {
                var desc = (t.title.map { $0 + ". " } ?? "") + t.description
                if desc.count > 600 { desc = String(desc.prefix(600)) + "…" }
                out.append(["type": "function", "function": [
                    "name": Self.toolName(server: s.name, tool: t.name),
                    "description": "[\(s.name)] " + desc,
                    "parameters": t.schemaObject,
                ] as [String: Any]])
            }
        }
        return out
    }

    /// Before a request: the connectors a conversation loaded earlier run again (after a restart of the app).
    func ensureRunning(_ names: [String]) async {
        let wanted = names + enabled.filter { $0.alwaysLoaded == true }.map(\.name)
        for n in Set(wanted) where config(n)?.isEnabled == true && states[config(n)!.name]?.isReady != true {
            _ = try? await start(n)
        }
    }

    var loadDefinition: [String: Any] {
        ["type": "function", "function": [
            "name": Self.loadTool,
            "description": "Load the tools of a connector from the list in the system prompt, so you can use them in this conversation. Do this once per connector, before you need it.",
            "parameters": ["type": "object", "properties": ["name": ["type": "string", "description": "The connector's name, exactly as listed"]], "required": ["name"]],
        ] as [String: Any]]
    }

    func promptSection() -> String {
        let list = enabled
        guard !list.isEmpty else { return "" }
        return L("Je hebt connectors: gereedschap van andere programma's en diensten. Laad de tools van een connector met use_connector voordat je hem gebruikt; daarna staan ze voor de rest van het gesprek klaar. Een connector op internet stuurt wat je meegeeft naar die dienst.")
            + "\n" + list.map { "- \($0.name)" + (($0.description ?? "").isEmpty ? "" : ": \($0.description!)") + ($0.alwaysLoaded == true ? " " + L("(al geladen)") : "") }.joined(separator: "\n")
    }

    /// use_connector: starts it and says which tools there are now.
    func load(_ call: ToolCall) async -> (text: String, name: String?) {
        let wanted = (WorkspaceTools.args(call)["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard let c = config(wanted), c.isEnabled else {
            return ("There is no connector named \"\(wanted)\". Available: " + enabled.map(\.name).joined(separator: ", "), nil)
        }
        do {
            let t = try await start(c.name)
            let list = t.prefix(60).map { "- \(Self.toolName(server: c.name, tool: $0.name)): \(($0.title ?? $0.description).prefix(120))" }
            return ("Connector \(c.name) is loaded with \(t.count) tools; they are available from your next step:\n" + list.joined(separator: "\n"), c.name)
        } catch {
            return ("Connector \(c.name) did not start: \(error.localizedDescription). Tell the user; it can be checked under Instellingen → Connectors.", nil)
        }
    }

    /// Calls a tool and returns its answer as text.
    func call(server: MCPServerConfig, tool: MCPTool, arguments: [String: Any]) async -> String {
        do {
            if let b = server.builtin, let builtin = builtins[b] {
                return try await builtin.call(tool.name, arguments: arguments)
            }
            if states[server.name]?.isReady != true { try await start(server.name) }
            guard let client = clients[server.name] else { throw MCPError.notRunning(server.name) }
            let r = try await client.callTool(tool.name, arguments: arguments)
            return (r.isError ? "The tool reported an error:\n" : "") + (r.text.isEmpty ? "(no output)" : r.text)
        } catch {
            appendLog(server.name, "call \(tool.name) failed: \(error.localizedDescription)")
            return "Error: \(error.localizedDescription)"
        }
    }

    /// Whether this call may run without a card, needs one, or is refused.
    nonisolated static func decision(right: String, tool: MCPTool, autoApprove: Bool) -> String {
        if right == "deny" { return "deny" }
        if tool.readOnly == true && tool.destructive != true { return "allow" }
        if right == "ask" && autoApprove { return "allow" }
        return right == "allow" ? "allow" : "ask"
    }

    func label(for call: ToolCall) -> String {
        guard let r = route(call.name) else { return call.name }
        return "\(r.server.name): \(r.tool.title ?? r.tool.name)"
    }

    // MARK: - import

    /// Connectors from Claude Desktop's and Claude Code's settings that are not here yet; they come in switched off.
    func importable() -> [MCPServerConfig] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var found: [MCPServerConfig] = []
        let desktop = home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        if let d = try? Data(contentsOf: desktop) { found += MCPConfigFile.parse(d) }
        let code = home.appendingPathComponent(".claude.json")
        if let d = try? Data(contentsOf: code),
           let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let servers = json["mcpServers"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": servers]) {
            found += MCPConfigFile.parse(data)
        }
        let have = Set(servers.map { $0.name.lowercased() })
        var seen = Set<String>()
        return found.filter { have.contains($0.name.lowercased()) == false && seen.insert($0.name.lowercased()).inserted }
            .map { var c = $0; c.enabled = false; return c }
    }
}

/// A connector that is part of the app itself, with the same shape as an MCP server.
protocol BuiltinConnector {
    func start() async throws -> [MCPTool]
    func call(_ tool: String, arguments: [String: Any]) async throws -> String
}
