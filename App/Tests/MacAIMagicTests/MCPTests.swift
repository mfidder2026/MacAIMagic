import XCTest
@testable import MacAIMagic

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

/// A Keychain stand-in for the tests.
private final class MemoryStore: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    func get(_ k: String) -> String? { lock.lock(); defer { lock.unlock() }; return items[k] }
    func set(_ v: String, _ k: String) { lock.lock(); items[k] = v; lock.unlock() }
    func delete(_ k: String) { lock.lock(); items[k] = nil; lock.unlock() }
}

final class MCPStdioTests: XCTestCase {
    private func client() -> (MCPClient, StdioTransport) {
        let t = StdioTransport(command: "/usr/bin/python3", arguments: ["-I", fixtures.appendingPathComponent("fake_mcp_stdio.py").path],
                               environment: [:], log: { _ in })
        return (MCPClient(transport: t), t)
    }

    func testHandshakeToolsAndCalls() async throws {
        let (c, _) = client()
        defer { c.close() }
        try await c.connect()
        XCTAssertEqual(c.serverName, "fake")
        XCTAssertEqual(c.instructions, "be nice")
        // two pages, and a line from the shell and a ping from the server in between
        let tools = try await c.listTools()
        XCTAssertEqual(tools.map(\.name), ["echo", "delete_all", "fail"])
        XCTAssertEqual(tools[0].readOnly, true)
        XCTAssertEqual(tools[1].destructive, true)
        XCTAssertNil(tools[2].readOnly)

        let echo = try await c.callTool("echo", arguments: ["text": "hoi"])
        XCTAssertEqual(echo.text, "echo: hoi\n[image, image/png]")
        XCTAssertFalse(echo.isError)
        let fail = try await c.callTool("fail", arguments: [:])
        XCTAssertTrue(fail.isError)
        do {
            _ = try await c.callTool("nope", arguments: [:])
            XCTFail("an unknown tool must throw")
        } catch MCPError.server(let code, _) {
            XCTAssertEqual(code, -32602)
        }
    }

    func testStoppedProgramFailsInsteadOfHanging() async throws {
        let t = StdioTransport(command: "/usr/bin/false", arguments: [], environment: [:], log: { _ in })
        let c = MCPClient(transport: t)
        do {
            try await c.connect()
            XCTFail("a program that stops must not connect")
        } catch {
            XCTAssertTrue(error is MCPError, "\(error)")
        }
    }
}

final class MCPHTTPTests: XCTestCase {
    private var server: Process?
    private var port = 0

    private func startServer(oauth: Bool) throws {
        port = Int.random(in: 41_000...48_000)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", fixtures.appendingPathComponent("fake_mcp_http.py").path, String(port)] + (oauth ? ["oauth"] : [])
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        server = p
        // wait for READY
        let line = out.fileHandleForReading.availableData
        XCTAssertTrue(String(decoding: line, as: UTF8.self).contains("READY"))
    }

    override func tearDown() {
        server?.terminate()
        server = nil
    }

    func testJSONAndServerSentEvents() async throws {
        try startServer(oauth: false)
        let t = HTTPTransport(url: URL(string: "http://127.0.0.1:\(port)/mcp")!, headers: [:], serverName: "http", oauth: false, log: { _ in })
        let c = MCPClient(transport: t)
        try await c.connect()
        XCTAssertEqual(c.serverName, "http-fake")
        let tools = try await c.listTools()          // answered as server-sent events
        XCTAssertEqual(tools.map(\.name), ["hello"])
        let r = try await c.callTool("hello", arguments: [:])
        XCTAssertEqual(r.text, "hello over http")
        c.close()
    }

    func testUnauthorizedWithoutOAuthSaysSo() async throws {
        try startServer(oauth: true)
        let t = HTTPTransport(url: URL(string: "http://127.0.0.1:\(port)/mcp")!, headers: [:], serverName: "http", oauth: false, log: { _ in })
        do {
            try await MCPClient(transport: t).connect()
            XCTFail("401 without OAuth must throw")
        } catch MCPError.unauthorized(let challenge) {
            XCTAssertTrue(challenge?.contains("resource_metadata") == true)
        }
    }

    /// The whole login: 401, metadata, registration, the browser (here: a request that follows the redirect), the
    /// callback on 127.0.0.1, the token with PKCE, and the same message again with the token.
    func testOAuthLoginEndToEnd() async throws {
        try startServer(oauth: true)
        let store = MemoryStore()
        await MCPOAuth.shared.configure(openBrowser: { url in
            URLSession.shared.dataTask(with: url).resume()     // follows the 302 to the app's callback
        }, store: ({ store.get($0) }, { store.set($0, $1) }, { store.delete($0) }))
        let url = URL(string: "http://127.0.0.1:\(port)/mcp")!
        let t = HTTPTransport(url: url, headers: [:], serverName: "http", oauth: true, log: { _ in })
        let c = MCPClient(transport: t)
        try await c.connect()
        XCTAssertEqual(c.serverName, "http-fake")
        let token = await MCPOAuth.shared.accessToken(for: url)
        XCTAssertEqual(token, "token-123")
        let names = try await c.listTools().map(\.name)
        XCTAssertEqual(names, ["hello"])
        await MCPOAuth.shared.configure(store: ({ MCPKeychain.get($0) }, { MCPKeychain.set($0, for: $1) }, { MCPKeychain.delete($0) }))
    }
}

final class MCPPartsTests: XCTestCase {
    func testToolNamesAndDecisions() {
        XCTAssertEqual(MCPManager.toolName(server: "GitHub", tool: "search_issues"), "GitHub__search_issues")
        XCTAssertEqual(MCPManager.toolName(server: "Agenda en Herinneringen", tool: "list.events"), "Agenda_en_Herinneringen__list_events")
        XCTAssertEqual(MCPManager.toolName(server: String(repeating: "a", count: 70), tool: "x").count, 64)

        let read = MCPTool(name: "r", description: "", readOnly: true)
        let write = MCPTool(name: "w", description: "")
        let destroy = MCPTool(name: "d", description: "", readOnly: true, destructive: true)
        XCTAssertEqual(MCPManager.decision(right: "ask", tool: read, autoApprove: false), "allow")
        XCTAssertEqual(MCPManager.decision(right: "deny", tool: read, autoApprove: false), "deny")
        XCTAssertEqual(MCPManager.decision(right: "ask", tool: write, autoApprove: false), "ask")
        XCTAssertEqual(MCPManager.decision(right: "allow", tool: write, autoApprove: false), "allow")
        XCTAssertEqual(MCPManager.decision(right: "ask", tool: destroy, autoApprove: false), "ask", "destructive beats read-only")
    }

    func testConfigFileRoundTripInClaudeDesktopFormat() throws {
        let json = #"{"mcpServers":{"files":{"command":"npx","args":["-y","@modelcontextprotocol/server-filesystem","/tmp"]},"GitHub":{"url":"https://api.githubcopilot.com/mcp/","headers":{"Authorization":"keychain:github"},"right":"allow","enabled":false}}}"#
        let list = MCPConfigFile.parse(Data(json.utf8))
        XCTAssertEqual(list.map(\.name), ["files", "GitHub"])
        XCTAssertTrue(list[0].isEnabled)
        XCTAssertEqual(list[0].rightValue, "ask")
        XCTAssertFalse(list[1].isEnabled)
        XCTAssertTrue(list[1].isRemote)
        let back = MCPConfigFile.parse(MCPConfigFile.encode(list))
        XCTAssertEqual(back, list)
        XCTAssertFalse(String(decoding: MCPConfigFile.encode(list), as: UTF8.self).contains("\"name\""), "the name is the key, as in Claude Desktop")
    }

    func testManagerWithStdioConnector() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let m = await MCPManager(file: file)
        var c = MCPServerConfig()
        c.name = "Fake"
        c.command = "/usr/bin/python3"
        c.args = ["-I", fixtures.appendingPathComponent("fake_mcp_stdio.py").path]
        c.description = "a test connector"
        await m.upsert(c)
        let tools = try await m.start("fake")
        XCTAssertEqual(tools.count, 3)
        let defs = await m.definitions(loaded: ["Fake"])
        XCTAssertEqual(defs.count, 3)
        let none = await m.definitions(loaded: [])
        XCTAssertEqual(none.count, 0, "not loaded in this conversation: no tools in the request")
        let found = await m.route("Fake__echo")
        let route = try XCTUnwrap(found)
        let answer = await m.call(server: route.server, tool: route.tool, arguments: ["text": "x"])
        XCTAssertTrue(answer.hasPrefix("echo: x"))
        let section = await m.promptSection()
        XCTAssertTrue(section.contains("- Fake: a test connector"))
        await m.stopAll()
    }

    func testServerSentEventsParsing() {
        let d = Data("event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\ndata: \"result\":{}}\n\nevent: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"x\"}\n".utf8)
        let msgs = HTTPTransport.events(in: d)
        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(msgs.last?["method"] as? String, "x")
    }

    func testPKCEAndMetadataAddresses() {
        // RFC 7636, appendix B
        XCTAssertEqual(MCPOAuth.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let pair = MCPOAuth.pkcePair()
        XCTAssertGreaterThanOrEqual(pair.verifier.count, 43)
        XCTAssertEqual(MCPOAuth.wellKnown(URL(string: "https://example.com/mcp")!, "oauth-protected-resource").map(\.absoluteString),
                       ["https://example.com/.well-known/oauth-protected-resource/mcp", "https://example.com/.well-known/oauth-protected-resource"])
        XCTAssertEqual(MCPOAuth.resourceMetadataURL(from: #"Bearer realm="x", resource_metadata="https://a.b/.well-known/oauth-protected-resource""#)?.absoluteString,
                       "https://a.b/.well-known/oauth-protected-resource")
    }

    func testCalendarDates() {
        XCTAssertNotNil(CalendarConnector.date("2026-11-07"))
        XCTAssertNotNil(CalendarConnector.date("2026-11-07T09:30"))
        XCTAssertNotNil(CalendarConnector.date("2026-11-07T09:30:00+01:00"))
        XCTAssertNil(CalendarConnector.date("morgen"))
        XCTAssertEqual(CalendarConnector.tools.filter { $0.readOnly == true }.map(\.name), ["list_events", "list_reminders"])
    }
}
