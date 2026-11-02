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

/// A long task with one question goes on to the end, also in a small context (MACAIMAGIC_ENGINE_TEST=1, engine running,
/// MACAIMAGIC_TEST_CONTEXT = the engine's --ctx-size).
@MainActor
final class LongTaskIntegrationTests: XCTestCase {
    func testLongTaskFinishesInSmallContext() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MACAIMAGIC_ENGINE_TEST"] == "1", let context = env["MACAIMAGIC_TEST_CONTEXT"].flatMap(Int.init) else { throw XCTSkip("no engine") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("macaimagic-long-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // long files, so that the task itself fills the context several times
        for i in 1...6 {
            let text = (1...900).map { "kamer \(i) regel \($0): een gang met oude stenen muren en een flakkerende fakkel." }.joined(separator: "\n")
            try text.write(to: folder.appendingPathComponent("bron\(i).txt"), atomically: true, encoding: .utf8)
        }
        let saved = (Settings.shared.webSearch, Settings.shared.workspaceTools, Settings.shared.rightRead, Settings.shared.rightWrite, Settings.shared.rightRun)
        defer { (Settings.shared.webSearch, Settings.shared.workspaceTools, Settings.shared.rightRead, Settings.shared.rightWrite, Settings.shared.rightRun) = saved }
        Settings.shared.webSearch = false
        Settings.shared.workspaceTools = true
        (Settings.shared.rightRead, Settings.shared.rightWrite, Settings.shared.rightRun) = ("allow", "allow", "allow")

        let store = ConversationStore()
        var c = Conversation(title: "Lange taak")
        c.workspace = folder.path
        store.conversations = [c]   // in memory only
        let chat = ChatClient()
        chat.contextLimit = context
        chat.send(text: "Lees de bestanden bron1.txt tot en met bron6.txt een voor een, helemaal, met read_file. Schrijf na elk bestand een bestand samenvatting1.txt (enzovoort) met wat erin staat, in een zin. Schrijf als laatste klaar.txt met de tekst KLAAR.",
                  attachments: [], in: c.id, store: store, baseURL: URL(string: "http://127.0.0.1:8080")!)
        let t0 = Date()
        while chat.busy && Date().timeIntervalSince(t0) < 1500 { try await Task.sleep(for: .seconds(1)) }
        let after = try XCTUnwrap(store.conversations.first)
        let nudges = after.messages.filter { $0.automatic == true }.count
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        print("LONG TASK: \(Int(Date().timeIntervalSince(t0))) s, \(after.messages.count) messages, nudges \(nudges), summary \(after.summary != nil), error \(after.messages.last?.error ?? "none"), files \(files.sorted())")
        print("LONG TASK last: \(after.messages.last?.text.prefix(300) ?? "")")
        chat.stop()
        XCTAssertNotNil(after.summary, "the small context must have been summarized")
        XCTAssertTrue(files.contains("klaar.txt"), "the task ran to its end")
        XCTAssertNil(after.messages.last?.error)
    }
}

/// What a task teaches ends up in MACAIMAGIC.md, and the next conversation in that folder knows it (engine at MACAIMAGIC_TEST_URL).
@MainActor
final class LearningIntegrationTests: XCTestCase {
    func testLessonReachesNextConversation() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let address = env["MACAIMAGIC_TEST_URL"], let base = URL(string: address) else { throw XCTSkip("no engine") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("macaimagic-learn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let saved = (Settings.shared.webSearch, Settings.shared.workspaceTools, Settings.shared.rightRead, Settings.shared.rightWrite, Settings.shared.rightRun, Settings.shared.learnFromChats)
        defer { (Settings.shared.webSearch, Settings.shared.workspaceTools, Settings.shared.rightRead, Settings.shared.rightWrite, Settings.shared.rightRun, Settings.shared.learnFromChats) = saved }
        Settings.shared.webSearch = false
        Settings.shared.workspaceTools = true
        Settings.shared.learnFromChats = true
        (Settings.shared.rightRead, Settings.shared.rightWrite, Settings.shared.rightRun) = ("allow", "allow", "allow")

        let store = ConversationStore()
        var first = Conversation(title: "Leren")
        first.workspace = folder.path
        var second = Conversation(title: "Volgende")
        second.workspace = folder.path
        store.conversations = [first, second]   // in memory only
        let chat = ChatClient()
        func ask(_ text: String, _ id: Conversation.ID) async throws {
            chat.send(text: text, attachments: [], in: id, store: store, baseURL: base)
            let t0 = Date()
            while chat.busy && Date().timeIntervalSince(t0) < 600 { try await Task.sleep(for: .milliseconds(300)) }
        }
        try await ask("Voer run_command uit met: vicex128 --version. Dat programma bestaat hier niet. Voer daarna run_command uit met: which zsh. Schrijf met write_file het resultaat naar uit.txt en controleer het met read_file.", first.id)
        let notes = try String(contentsOf: folder.appendingPathComponent("MACAIMAGIC.md"), encoding: .utf8)
        print("NOTES:\n\(notes)")
        let last = try XCTUnwrap(store.conversations.first { $0.id == first.id }?.messages.last)
        print("STEPS: \(last.activities.map(\.label))")
        XCTAssertTrue(notes.contains("- "), "something was learned")
        XCTAssertTrue(notes.lowercased().contains("vicex128"), "the mistake is in the notes")
        try await ask("Bestaat het programma vicex128 op deze Mac volgens je notities? Antwoord met ja of nee en gebruik geen gereedschap.", second.id)
        let answer = store.conversations.first { $0.id == second.id }?.messages.last?.text ?? ""
        print("NEXT: \(answer)")
        XCTAssertTrue(answer.lowercased().contains("nee"), answer)
    }
}

/// Commands without output and one that fails must not end a task (engine at MACAIMAGIC_TEST_URL); the model stops at
/// such a step at times, so three runs.
@MainActor
final class QuietStepsIntegrationTests: XCTestCase {
    func testQuietStepsDoNotEndTheTask() async throws {
        guard let address = ProcessInfo.processInfo.environment["MACAIMAGIC_TEST_URL"], let base = URL(string: address) else { throw XCTSkip("no engine") }
        let saved = (Settings.shared.webSearch, Settings.shared.workspaceTools, Settings.shared.rightRead, Settings.shared.rightWrite, Settings.shared.rightRun)
        defer { (Settings.shared.webSearch, Settings.shared.workspaceTools, Settings.shared.rightRead, Settings.shared.rightWrite, Settings.shared.rightRun) = saved }
        Settings.shared.webSearch = false
        Settings.shared.workspaceTools = true
        (Settings.shared.rightRead, Settings.shared.rightWrite, Settings.shared.rightRun) = ("allow", "allow", "allow")
        for run in 1...3 {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("macaimagic-quiet-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = ConversationStore()
            var c = Conversation(title: "Stille stappen")
            c.workspace = folder.path
            store.conversations = [c]   // in memory only
            let chat = ChatClient()
            chat.contextLimit = 32_768
            chat.send(text: "Voer met run_command een voor een uit: true, daarna false, daarna true, daarna touch een.txt, daarna true, daarna touch twee.txt, daarna ls. Schrijf daarna met write_file eind.txt met de uitvoer van ls.",
                      attachments: [], in: c.id, store: store, baseURL: base)
            let t0 = Date()
            while chat.busy && Date().timeIntervalSince(t0) < 400 { try await Task.sleep(for: .milliseconds(300)) }
            let after = try XCTUnwrap(store.conversations.first)
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            let nudges = after.messages.filter { $0.automatic == true }.count
            let calls = after.messages.flatMap(\.toolCalls).map(\.name).count
            print("QUIET \(run): \(Int(Date().timeIntervalSince(t0))) s, \(calls) calls, nudges \(nudges), error \(after.messages.last?.error ?? "none"), files \(files.sorted())")
            print("QUIET \(run) last: \(after.messages.last?.text.prefix(200) ?? "")")
            XCTAssertTrue(files.contains("eind.txt"), "run \(run) ran to its end")
        }
    }
}

/// Outside the work folder the model must look with run_command instead of saying it cannot search this Mac.
/// MACAIMAGIC_TEST_URL=<engine>; MACAIMAGIC_TEST_FIND=<path of something outside the folder>, name it in the question.
@MainActor
final class OutsideFolderIntegrationTests: XCTestCase {
    func testModelSearchesOutsideTheFolder() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let address = env["MACAIMAGIC_TEST_URL"], let base = URL(string: address), let find = env["MACAIMAGIC_TEST_FIND"] else { throw XCTSkip("no engine") }
        let saved = (Settings.shared.webSearch, Settings.shared.workspaceTools, Settings.shared.rightRead, Settings.shared.rightWrite, Settings.shared.rightRun)
        defer { (Settings.shared.webSearch, Settings.shared.workspaceTools, Settings.shared.rightRead, Settings.shared.rightWrite, Settings.shared.rightRun) = saved }
        Settings.shared.webSearch = false
        Settings.shared.workspaceTools = true
        (Settings.shared.rightRead, Settings.shared.rightWrite, Settings.shared.rightRun) = ("allow", "allow", "allow")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("macaimagic-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ConversationStore()
        var c = Conversation(title: "Buiten de map")
        c.workspace = folder.path
        store.conversations = [c]   // in memory only
        let chat = ChatClient()
        chat.contextLimit = 32_768
        chat.send(text: "Staat de C64-emulator VICE op deze Mac? Zoek het op en noem het volledige pad.", attachments: [], in: c.id, store: store, baseURL: base)
        let t0 = Date()
        while chat.busy && Date().timeIntervalSince(t0) < 300 { try await Task.sleep(for: .milliseconds(300)) }
        let after = try XCTUnwrap(store.conversations.first)
        let calls = after.messages.flatMap(\.toolCalls).map(\.name)
        print("OUTSIDE: \(Int(Date().timeIntervalSince(t0))) s, calls \(calls), last: \(after.messages.last?.text.prefix(300) ?? "")")
        XCTAssertTrue(calls.contains("run_command"))
        XCTAssertTrue(after.messages.last?.text.contains(find) == true)
    }
}

/// The documents module with real models and the real web, the way the app runs them.
/// MACAIMAGIC_DOC_TEST=<dir> with no engine running. Uses other ports than the app's. MACAIMAGIC_DOC_HEAVY: the heavy model.
@MainActor
final class DocumentsIntegrationTests: XCTestCase {
    func testAttachmentsWebAndHouseStyle() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["MACAIMAGIC_DOC_TEST"] else { throw XCTSkip("no folder") }
        let folder = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let saved = (Settings.shared.port, Settings.shared.host, Settings.shared.vision)
        defer { (Settings.shared.port, Settings.shared.host, Settings.shared.vision) = saved }
        (Settings.shared.port, Settings.shared.host, Settings.shared.vision) = (8092, "127.0.0.1", false)

        let app = AppState()
        app.selectedModelID = env["MACAIMAGIC_DOC_HEAVY"] ?? "qwen3.8-flash-next-q4"
        let studio = DocumentStudio(folder: folder)
        studio.endpoint = { role in try await app.documentEngines.endpoint(role) }
        // MACAIMAGIC_DOC_URL: an engine that runs already, for one model doing everything
        if let running = env["MACAIMAGIC_DOC_URL"].flatMap(URL.init(string:)) { studio.endpoint = { _ in (running, "model") } }
        studio.contextLimit = { env["MACAIMAGIC_DOC_URL"] == nil ? app.chat.contextLimit : 65_536 }
        print("DOC plan: fast \(app.documentEngines.fastChoice?.id ?? "none"), heavy fits \(app.plan?.fitsInMemory ?? false)")
        defer {
            app.engine.stop()
            app.documentEngines.fast.stop()
        }
        func wait(_ what: String) async throws {
            let t0 = Date()
            while studio.busy && Date().timeIntervalSince(t0) < 1800 { try await Task.sleep(for: .milliseconds(300)) }
            for s in studio.steps { print("  [\(s.state)] \(s.text.prefix(240))") }
            print("DOC \(what): \(Int(Date().timeIntervalSince(t0))) s, problem \(studio.problem ?? "none"), notes \(studio.notes)")
        }

        // the attachment says what the document consists of; the house style is only the layout
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/sjabloon.docx")
        studio.useHouseStyle(fixture)
        let requirements = folder.appendingPathComponent("eisen-aqs-bron.txt")
        try "Een AQS (Architecture Quick Scan) bestaat altijd uit precies deze onderdelen: 1. Aanleiding, 2. Huidige situatie, 3. Risico's, 4. Wettelijk kader, 5. Advies. Klant: Gemeente Voorbeeld, versie 0.2, auteur M. Fidder. De gemeente draait een verouderde zaaksysteem-koppeling; er is geen MFA op beheeraccounts en de back-up is niet getest. Advies: eerst MFA, dan back-uptest, dan vervanging van de koppeling.".write(to: requirements, atomically: true, encoding: .utf8)
        studio.addAttachment(requirements)
        try FileManager.default.removeItem(at: requirements)

        studio.make(request: "Maak een AQS", useWeb: true)
        try await wait("aqs")
        XCTAssertNil(studio.problem)
        print(studio.text)
        print("DOC sections:", DraftSections.list(studio.text).map(\.title))
        studio.selection = NSRange(location: (studio.text as NSString).range(of: "# ").location, length: 0)
        let quick = Date()
        studio.apply(.shorter)
        try await wait("quick action")
        print("DOC quick action took", Date().timeIntervalSince(quick))
        studio.deliver()
        print("DOC docx:", studio.report?.url?.path ?? "none", studio.report?.problems ?? [], studio.report?.warnings ?? [])
        XCTAssertEqual(studio.report?.problems, [])

        // a question without anything about it in the attachments goes to the web
        studio.make(request: "Hoeveel geheugen kan de Mac Studio met M3 Ultra maximaal hebben?", useWeb: true)
        try await wait("question")
        XCTAssertNil(studio.problem)
        print(studio.text)
        studio.deliver()
        print("DOC second docx:", studio.report?.url?.path ?? "none", studio.report?.problems ?? [], studio.report?.warnings ?? [])
        XCTAssertEqual(studio.report?.problems, [])
        print("DOC engines: heavy \(app.engine.state) fast \(app.documentEngines.fast.state)")
    }
}
