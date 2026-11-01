import XCTest
@testable import MacAIMagic

/// Runs the app's own chat loop (streaming, tool calls, web search) against a running engine.
/// Set MACAIMAGIC_ENGINE_TEST=1 with the engine on 127.0.0.1:8080.
@MainActor
final class EngineIntegrationTests: XCTestCase {
    func testWebSearchLoop() async throws {
        guard ProcessInfo.processInfo.environment["MACAIMAGIC_ENGINE_TEST"] == "1" else { throw XCTSkip("no engine") }
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
/// MACAIMAGIC_BENCH="id1,id2" with the engine stopped.
@MainActor
final class BenchmarkIntegrationTests: XCTestCase {
    func testBenchmarkModels() async throws {
        guard let ids = ProcessInfo.processInfo.environment["MACAIMAGIC_BENCH"]?.split(separator: ",").map(String.init) else {
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

/// The model works in a folder: writes a file, runs it, reads the output (MACAIMAGIC_ENGINE_TEST=1, engine running).
@MainActor
final class WorkspaceIntegrationTests: XCTestCase {
    func testModelCreatesAndRunsFiles() async throws {
        guard ProcessInfo.processInfo.environment["MACAIMAGIC_ENGINE_TEST"] == "1" else { throw XCTSkip("no engine") }
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

/// The cluster end to end on one Mac: the app starts a helper on 127.0.0.1, finds it with Bonjour, starts GLM Compact
/// spread over its own GPU and the helper, and checks the answer. MACAIMAGIC_CLUSTER_TEST=1, no engine running.
@MainActor
final class ClusterIntegrationTests: XCTestCase {
    func testHelperFoundAndUsed() async throws {
        guard ProcessInfo.processInfo.environment["MACAIMAGIC_CLUSTER_TEST"] == "1" else { throw XCTSkip("set MACAIMAGIC_CLUSTER_TEST=1") }
        let app = AppState()
        let s = Settings.shared
        let savedRole = s.clusterRole
        defer { s.clusterRole = savedRole }
        s.clusterRole = "helper"
        app.cluster.startHelper(bind: "127.0.0.1")
        XCTAssertTrue(app.cluster.helperRunning, app.cluster.helperLog.joined(separator: "\n"))

        // Bonjour announces it; the main side must find it
        s.clusterRole = "main"
        let t0 = Date()
        while !app.cluster.helpers.contains(where: { $0.host == "127.0.0.1" }) && Date().timeIntervalSince(t0) < 20 {
            try await Task.sleep(for: .milliseconds(300))
        }
        let helper = try XCTUnwrap(app.cluster.helpers.first { $0.host == "127.0.0.1" }, "helper not found via Bonjour")
        print("FOUND:", helper.name, helper.chip, helper.memoryGB, "GB, GPU", helper.gpuGB, "GB")
        app.cluster.selected = [helper.id]
        XCTAssertEqual(app.cluster.rpcArgument, "127.0.0.1:\(ClusterController.defaultPort)")
        // the helper runs on this same Mac: give it about half of GLM Compact
        app.cluster.budgetOverride = [50_000_000_000]

        Settings.shared.mtp = false
        app.selectedModelID = "glm-5.3-flash-compact"
        let plan = try XCTUnwrap(app.plan)
        print("SPLIT:", plan.tensorSplit)
        XCTAssertEqual(plan.tensorSplit.count, 2)
        app.startEngine()
        let args = app.engine.arguments(model: app.selectedModel!, shards: app.models.shardURLs(app.selectedModel!),
                                        plan: plan, vision: nil, rpc: app.cluster.rpcArgument)
        XCTAssertTrue(args.contains("--rpc") && args.contains("--tensor-split"))
        let t1 = Date()
        while !app.engine.state.isRunning && Date().timeIntervalSince(t1) < 1200 {
            if case .failed(let e) = app.engine.state { XCTFail(e); break }
            try await Task.sleep(for: .seconds(1))
        }
        print("ENGINE READY after", Int(Date().timeIntervalSince(t1)), "s")

        var req = URLRequest(url: app.engine.baseURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "messages": [["role": "user", "content": "Wat is de hoofdstad van Frankrijk? Eén zin."]],
            "max_tokens": 120, "temperature": 0, "chat_template_kwargs": ["enable_thinking": false]])
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = ((json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]) ?? [:]
        let text = (message["content"] as? String ?? "") + " " + (message["reasoning_content"] as? String ?? "")
        let tps = (json?["timings"] as? [String: Any])?["predicted_per_second"] as? Double ?? 0
        print("ANSWER:", text, String(format: "(%.1f tok/s)", tps))
        XCTAssertTrue(text.contains("Parijs") || text.contains("Paris"), text)

        await app.engine.stopAndWait()
        app.cluster.stopHelper()
        try await Task.sleep(for: .seconds(6))
    }

    /// DeepSeek Q4 does not fit even in a cluster: the helper takes whole layers, this Mac keeps the rest mapped and
    /// caches the most used experts (MACAIMAGIC_CLUSTER_STREAM_TEST=1; the helper shares this Mac's memory, so both
    /// the helper and the cache are kept small).
    func testStreamingWithHelper() async throws {
        guard ProcessInfo.processInfo.environment["MACAIMAGIC_CLUSTER_STREAM_TEST"] == "1" else { throw XCTSkip("set MACAIMAGIC_CLUSTER_STREAM_TEST=1") }
        let app = AppState()
        let s = Settings.shared
        let savedRole = s.clusterRole
        UserDefaults.standard.set(60.0, forKey: "expertCacheMaxGB")
        defer {
            s.clusterRole = savedRole
            UserDefaults.standard.removeObject(forKey: "expertCacheMaxGB")
        }
        s.clusterRole = "helper"
        app.cluster.startHelper(bind: "127.0.0.1")
        XCTAssertTrue(app.cluster.helperRunning, app.cluster.helperLog.joined(separator: "\n"))
        s.clusterRole = "main"
        let t0 = Date()
        while !app.cluster.helpers.contains(where: { $0.host == "127.0.0.1" }) && Date().timeIntervalSince(t0) < 20 {
            try await Task.sleep(for: .milliseconds(300))
        }
        let helper = try XCTUnwrap(app.cluster.helpers.first { $0.host == "127.0.0.1" }, "helper not found via Bonjour")
        app.cluster.selected = [helper.id]
        app.cluster.budgetOverride = [23_000_000_000]   // three layers of DeepSeek Q4

        app.selectedModelID = "deepseek-v4.1-flash-q4"
        let plan = try XCTUnwrap(app.plan)
        print("SPLIT:", plan.tensorSplit, "host layers:", plan.hostExpertLayers.first ?? -1, "...", plan.hostExpertLayers.last ?? -1,
              "cache:", plan.expertCache.gb)
        XCTAssertEqual(plan.tensorSplit.first, 3)
        XCTAssertGreaterThan(plan.expertCache, 0)
        app.startEngine()
        let t1 = Date()
        while !app.engine.state.isRunning && Date().timeIntervalSince(t1) < 1800 {
            if case .failed(let e) = app.engine.state { XCTFail(e); break }
            try await Task.sleep(for: .seconds(1))
        }
        print("ENGINE READY after", Int(Date().timeIntervalSince(t1)), "s")

        var req = URLRequest(url: app.engine.baseURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "messages": [["role": "user", "content": "Wat is de hoofdstad van Frankrijk? Eén zin."]],
            "max_tokens": 120, "temperature": 0, "chat_template_kwargs": ["enable_thinking": false]])
        req.timeoutInterval = 1800
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = ((json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]) ?? [:]
        let text = (message["content"] as? String ?? "") + " " + (message["reasoning_content"] as? String ?? "")
        let tps = (json?["timings"] as? [String: Any])?["predicted_per_second"] as? Double ?? 0
        print("ANSWER:", text, String(format: "(%.1f tok/s)", tps))
        XCTAssertTrue(text.contains("Parijs") || text.contains("Paris"), text)

        await app.engine.stopAndWait()
        app.cluster.stopHelper()
        try await Task.sleep(for: .seconds(6))
    }
}

/// A full conversation is summarized, and the model still knows what was said before (MACAIMAGIC_ENGINE_TEST=1, engine running).
@MainActor
final class CompactIntegrationTests: XCTestCase {
    func testCompactKeepsWhatMatters() async throws {
        guard ProcessInfo.processInfo.environment["MACAIMAGIC_ENGINE_TEST"] == "1" else { throw XCTSkip("no engine") }
        let store = ConversationStore()
        var c = Conversation(title: "Compact-test")
        let turns = [("Mijn kat heet Pluis en is drie jaar.", "Leuk, Pluis!"), ("Ik werk aan avontuur.bas in de map Werkmap.", "Goed, ik help mee."),
                     ("Het spel heeft vijf kamers.", "Duidelijk."), ("Wat is 2+2?", "4.")]
        for (q, a) in turns { c.messages += [ChatMessage(role: .user, text: q), ChatMessage(role: .assistant, text: a)] }
        store.conversations = [c]   // in memory only
        let chat = ChatClient()
        let base = URL(string: "http://127.0.0.1:8080")!
        await chat.compact(c.id, store: store, baseURL: base)
        let after = try XCTUnwrap(store.conversations.first)
        let summary = try XCTUnwrap(after.summary, "no summary")
        print("SUMMARY:", summary)
        XCTAssertEqual(after.unsummarized.filter { $0.role == .user }.count, 2, "the last two questions stay")

        let saved = (Settings.shared.webSearch, Settings.shared.workspaceTools)
        defer { (Settings.shared.webSearch, Settings.shared.workspaceTools) = saved }
        Settings.shared.webSearch = false
        Settings.shared.workspaceTools = false
        chat.send(text: "Hoe heet mijn kat? Alleen de naam.", attachments: [], in: c.id, store: store, baseURL: base)
        let t0 = Date()
        while chat.busy && Date().timeIntervalSince(t0) < 300 { try await Task.sleep(for: .milliseconds(300)) }
        let answer = store.conversations.first?.messages.last?.text ?? ""
        print("ANSWER:", answer, "context tokens:", store.conversations.first?.contextTokens ?? -1)
        XCTAssertTrue(answer.contains("Pluis"), answer)
        XCTAssertNotNil(store.conversations.first?.contextTokens)
    }
}
