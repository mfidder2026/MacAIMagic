import XCTest
@testable import MacDeepSeek

/// Runs the app's own chat loop (streaming, tool calls, web search) against a running engine.
/// Set MACDEEPSEEK_ENGINE_TEST=1 with the engine on 127.0.0.1:8080.
@MainActor
final class EngineIntegrationTests: XCTestCase {
    func testWebSearchLoop() async throws {
        guard ProcessInfo.processInfo.environment["MACDEEPSEEK_ENGINE_TEST"] == "1" else { throw XCTSkip("no engine") }
        Settings.shared.webSearch = true
        Settings.shared.thinking = false
        let store = ConversationStore()
        store.conversations = [Conversation()]
        let id = store.conversations[0].id
        let chat = ChatClient()
        chat.send(text: "Zoek op wat de nieuwste versie van llama.cpp is en noem de bron.", attachments: [], in: id,
                  store: store, baseURL: URL(string: "http://127.0.0.1:8080")!)
        let start = Date()
        while chat.busy && Date().timeIntervalSince(start) < 900 { try await Task.sleep(for: .milliseconds(500)) }

        let msgs = store.conversations[0].messages
        for m in msgs {
            print("[\(m.role)] calls=\(m.toolCalls.map(\.name)) text=\(m.text.prefix(300).replacingOccurrences(of: "\n", with: " "))")
        }
        let final = try XCTUnwrap(msgs.last)
        XCTAssertNil(final.error)
        XCTAssertTrue(msgs.contains { $0.role == .tool }, "the model should have searched")
        XCTAssertFalse(final.text.isEmpty)
        XCTAssertFalse(final.sources.isEmpty, "the answer should carry its sources")
        print("tok/s:", final.tokensPerSecond ?? 0, "sources:", final.sources.map(\.url))
    }
}

/// The Compare screen's measurement, end to end: the app starts each model itself and measures it.
/// MACDEEPSEEK_BENCH="id1,id2" with the engine stopped.
@MainActor
final class BenchmarkIntegrationTests: XCTestCase {
    func testBenchmarkModels() async throws {
        guard let ids = ProcessInfo.processInfo.environment["MACDEEPSEEK_BENCH"]?.split(separator: ",").map(String.init) else {
            throw XCTSkip("no models to benchmark")
        }
        let app = AppState()
        await app.bench.run(ids, app: app)
        await app.engine.stopAndWait()
        for r in app.bench.latest where ids.contains(r.modelID) {
            print(String(format: "BENCH %@: decode %.1f tok/s, prompt %.0f tok/s, load %.0f s, SSD %.0f MB/s, wired %.0f GB, cpu layers %d",
                         r.modelName, r.decodeTPS, r.promptTPS, r.loadSeconds, r.ssdMBs, r.wiredGB, r.cpuMoELayers))
        }
        XCTAssertEqual(Set(app.bench.latest.map(\.modelID)).intersection(ids).count, ids.count)
    }
}

/// The model works in a folder: writes a file, runs it, reads the output (MACDEEPSEEK_ENGINE_TEST=1, engine running).
@MainActor
final class WorkspaceIntegrationTests: XCTestCase {
    func testModelCreatesAndRunsFiles() async throws {
        guard ProcessInfo.processInfo.environment["MACDEEPSEEK_ENGINE_TEST"] == "1" else { throw XCTSkip("no engine") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mds-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = Settings.shared
        let saved = (s.workspace, s.workspaceTools, s.autoApprove, s.webSearch, s.thinking)
        defer { (s.workspace, s.workspaceTools, s.autoApprove, s.webSearch, s.thinking) = saved }
        (s.workspace, s.workspaceTools, s.autoApprove, s.webSearch, s.thinking) = (dir.path, true, true, false, false)

        let store = ConversationStore()
        store.conversations = [Conversation(workspace: dir.path)]
        let id = store.conversations[0].id
        let chat = ChatClient()
        chat.send(text: """
            Maak in de werkmap een C64 BASIC-programma hallo.prg dat 10 PRINT "HALLO" en 20 GOTO 10 bevat. \
            Een .prg begint met het laadadres $0801 (bytes 01 08), daarna de getokeniseerde BASIC-regels \
            (PRINT = $99, GOTO = $89), elke regel met een link naar de volgende en het regelnummer, en eindigt met 00 00. \
            Schrijf het als binair bestand. Controleer daarna met een commando (xxd hallo.prg) dat de bytes kloppen.
            """, attachments: [], in: id, store: store, baseURL: URL(string: "http://127.0.0.1:8080")!)
        let start = Date()
        while chat.busy && Date().timeIntervalSince(start) < 900 { try await Task.sleep(for: .milliseconds(500)) }

        for m in store.conversations[0].messages {
            print("[\(m.role)] calls=\(m.toolCalls.map { "\($0.name) \($0.arguments.prefix(160))" }) text=\(m.text.prefix(300).replacingOccurrences(of: "\n", with: " "))")
        }
        let prg = try Data(contentsOf: dir.appendingPathComponent("hallo.prg"))
        print("PRG:", prg.map { String(format: "%02x", $0) }.joined(separator: " "))
        XCTAssertEqual(Array(prg.prefix(2)), [0x01, 0x08], "load address")
        XCTAssertTrue(prg.contains(0x99) && prg.contains(0x89), "PRINT and GOTO tokens")
        XCTAssertTrue(store.conversations[0].messages.contains { $0.toolCalls.contains { $0.name == "run_command" } }, "it checked its work")
    }
}
