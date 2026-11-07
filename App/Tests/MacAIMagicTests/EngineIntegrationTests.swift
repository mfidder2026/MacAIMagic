import XCTest
import AppKit
import SwiftUI
@testable import MacAIMagic

/// Runs the app's own chat loop (streaming, tool calls, web search) against a running engine.
/// Set MACAIMAGIC_ENGINE_TEST=1 with the engine on 127.0.0.1:8080.
@MainActor
final class EngineIntegrationTests: XCTestCase {
    func testWebSearchLoop() async throws {
        guard ProcessInfo.processInfo.environment["MACAIMAGIC_ENGINE_TEST"] == "1" else { throw XCTSkip("no engine") }
        Settings.shared.webSearch = true
        Settings.shared.thinking = false
        let store = ConversationStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
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

        let store = ConversationStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
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
        let store = ConversationStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
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

        let store = ConversationStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
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
        chat.stopAll()
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

        let store = ConversationStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
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
            let store = ConversationStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
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
        let store = ConversationStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
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
            while studio.busy && Date().timeIntervalSince(t0) < 1800 {
                window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
            }
            print("DOC gauge counted \(app.metrics.samples.map(\.tokensPerSec).max() ?? 0) tok/s at most")
            for s in studio.steps { print("  [\(s.state)] \(s.text.prefix(240))") }
            print("DOC \(what): \(Int(Date().timeIntervalSince(t0))) s, problem \(studio.problem ?? "none"), notes \(studio.notes)")
        }

        // the real screen follows along: that is where a model's text locked up the app in 1.9.3
        let root = DocumentsView()
            .environmentObject(app).environmentObject(app.engine).environmentObject(app.models).environmentObject(app.store)
            .environmentObject(app.chat).environmentObject(Settings.shared).environmentObject(app.metrics).environmentObject(app.bench)
            .environmentObject(app.cluster).environmentObject(app.check).environmentObject(studio)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: root)
        defer { window.contentView = nil }

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

/// System management with a real model (MACAIMAGIC_ENGINE_TEST=1, engine running): diagnosis only reads, a change goes
/// through the approval card and is recorded, and the model undoes it with system_undo. Changes only a test domain.
@MainActor
final class SystemIntegrationTests: XCTestCase {
    private var saved: (Bool, Bool, Bool, Bool, Bool, String, String, Bool)!

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["MACAIMAGIC_ENGINE_TEST"] == "1" else { throw XCTSkip("no engine") }
        let s = Settings.shared
        saved = (s.systemManagement, s.skills, s.autoApprove, s.webSearch, s.thinking, s.rightSystemRead, s.rightSystemChange, s.workspaceTools)
        (s.systemManagement, s.skills, s.autoApprove, s.webSearch, s.thinking, s.rightSystemRead, s.rightSystemChange, s.workspaceTools)
            = (true, true, false, false, false, "allow", "ask", false)
    }

    override func tearDown() async throws {
        guard let saved else { return }
        let s = Settings.shared
        (s.systemManagement, s.skills, s.autoApprove, s.webSearch, s.thinking, s.rightSystemRead, s.rightSystemChange, s.workspaceTools) = saved
    }

    /// Runs one message to the end; every approval card is recorded and answered with yes.
    private func run(_ text: String, chat: ChatClient, store: ConversationStore, id: Conversation.ID, cards: inout [ChatClient.Approval]) async throws {
        chat.send(text: text, attachments: [], in: id, store: store, baseURL: URL(string: "http://127.0.0.1:8080")!)
        let start = Date()
        while chat.busy && Date().timeIntervalSince(start) < 900 {
            if let a = chat.approvals.values.first { cards.append(a); chat.answer(a, allow: true) }
            try await Task.sleep(for: .milliseconds(200))
        }
        for m in store.conversations[0].messages.suffix(14) {
            print("[\(m.role)] calls=\(m.toolCalls.map { "\($0.name) \($0.arguments.prefix(300))" }) text=\(m.text.prefix(400).replacingOccurrences(of: "\n", with: " "))")
        }
    }

    func testDiagnosisOnlyReads() async throws {
        let store = ConversationStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        store.conversations = [Conversation()]
        let chat = ChatClient()
        chat.modelName = "Qwen3.8-Flash-Next"
        var cards: [ChatClient.Approval] = []
        try await run("Welke macOS-versie draait deze Mac, en hoeveel vrije ruimte is er op de opstartschijf? Alleen bekijken, niets veranderen.",
                      chat: chat, store: store, id: store.conversations[0].id, cards: &cards)
        let calls = store.conversations[0].messages.flatMap(\.toolCalls)
        XCTAssertTrue(calls.contains { $0.name == "system_read" }, "it read the system")
        XCTAssertFalse(calls.contains { $0.name == "system_change" }, "it changed nothing")
        XCTAssertTrue(cards.isEmpty, "reading asks nothing")
        let answer = store.conversations[0].messages.last { $0.role == .assistant && !$0.text.isEmpty }?.text ?? ""
        XCTAssertTrue(answer.contains("27"), "the macOS version is in the answer: \(answer.prefix(300))")
    }

    func testChangeThroughCardAndUndoByModel() async throws {
        let domain = "app.fremen.macaimagic.agenttest"
        _ = await SystemTools.runUser("defaults write \(domain) kleur -string blauw")
        let before = Set(SystemTools.load().map(\.id))
        defer {
            _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/defaults"), arguments: ["delete", domain])
            // the test's own records do not stay in the user's list
            for c in SystemTools.load() where !before.contains(c.id) {
                try? FileManager.default.removeItem(at: Paths.changes.appendingPathComponent(c.id))
            }
        }
        let store = ConversationStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        store.conversations = [Conversation()]
        let id = store.conversations[0].id
        let chat = ChatClient()
        chat.modelName = "Qwen3.8-Flash-Next"
        var cards: [ChatClient.Approval] = []
        try await run("Zet in het voorkeurendomein \(domain) de sleutel kleur op de tekst rood. Gebruik system_change met een check, een wijziging en een ongedaanmaking.",
                      chat: chat, store: store, id: id, cards: &cards)
        let now = await SystemTools.runUser("defaults read \(domain) kleur")
        XCTAssertEqual(now.output, "rood")
        let card = try XCTUnwrap(cards.first { $0.call.name == "system_change" }, "the plan was shown on a card")
        XCTAssertFalse(card.steps.isEmpty)
        print("PLAN:", card.call.arguments)
        XCTAssertTrue(card.steps.contains { $0.current == "blauw" }, "the card showed the current value: \(card.steps.map { $0.current ?? "-" })")
        XCTAssertFalse(card.admin)
        let change = try XCTUnwrap(SystemTools.load().first { !before.contains($0.id) }, "the change was recorded")
        XCTAssertTrue(change.succeeded)

        try await run("Maak die wijziging weer ongedaan.", chat: chat, store: store, id: id, cards: &cards)
        XCTAssertTrue(cards.contains { $0.call.name == "system_undo" } || cards.filter { $0.call.name == "system_change" }.count > 1, "undo went through a card")
        let back = await SystemTools.runUser("defaults read \(domain) kleur")
        XCTAssertEqual(back.output, "blauw")
    }

    func testSkillIsUsedForASubject() async throws {
        let store = ConversationStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        store.conversations = [Conversation()]
        let chat = ChatClient()
        chat.modelName = "Qwen3.8-Flash-Next"
        var cards: [ChatClient.Approval] = []
        try await run("Welke DNS-servers gebruikt de Wi-Fi van deze Mac nu? Alleen bekijken.",
                      chat: chat, store: store, id: store.conversations[0].id, cards: &cards)
        let calls = store.conversations[0].messages.flatMap(\.toolCalls)
        print("CALLS:", calls.map(\.name))
        XCTAssertTrue(calls.contains { $0.name == "system_read" && $0.arguments.contains("networksetup") || $0.arguments.contains("scutil") })
        XCTAssertFalse(calls.contains { $0.name == "system_change" })
    }
}

/// A connector with a real model (MACAIMAGIC_ENGINE_TEST=1, engine running, npx on the Mac): the model loads the
/// Bestanden connector (the official filesystem MCP server) with use_connector and lists a folder through it.
/// Uses its own mcp.json, so the user's connectors are not touched.
@MainActor
final class ConnectorIntegrationTests: XCTestCase {
    func testModelUsesFilesystemConnector() async throws {
        guard ProcessInfo.processInfo.environment["MACAIMAGIC_ENGINE_TEST"] == "1" else { throw XCTSkip("no engine") }
        guard ConnectorPresets.hasTool("npx") else { throw XCTSkip("no npx") }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-files-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try "boodschappen: melk, brood".write(to: tmp.appendingPathComponent("lijstje.txt"), atomically: true, encoding: .utf8)
        try "x".write(to: tmp.appendingPathComponent("rapport-2026.md"), atomically: true, encoding: .utf8)
        let saved = MCPManager.shared
        let s = Settings.shared
        let savedSettings = (s.systemManagement, s.skills, s.autoApprove, s.webSearch, s.thinking, s.workspaceTools)
        defer {
            MCPManager.shared.stopAll()
            MCPManager.shared = saved
            (s.systemManagement, s.skills, s.autoApprove, s.webSearch, s.thinking, s.workspaceTools) = savedSettings
            try? FileManager.default.removeItem(at: tmp)
        }
        (s.systemManagement, s.skills, s.autoApprove, s.webSearch, s.thinking, s.workspaceTools) = (false, false, false, false, false, false)
        MCPManager.shared = MCPManager(file: tmp.appendingPathComponent("mcp.json"))
        var files = MCPServerConfig(name: "Bestanden", command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem", tmp.path],
                                    right: "ask", description: "Bestanden lezen en schrijven in de testmap")
        files.enabled = true
        MCPManager.shared.upsert(files)

        let store = ConversationStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        store.conversations = [Conversation()]
        let id = store.conversations[0].id
        let chat = ChatClient()
        chat.modelName = "Qwen3.8-Flash-Next"
        chat.send(text: "Welke bestanden staan er in de map \(tmp.path)? Gebruik de connector Bestanden.", attachments: [], in: id, store: store,
                  baseURL: URL(string: "http://127.0.0.1:8080")!)
        var cards: [ChatClient.Approval] = []
        let start = Date()
        while chat.busy && Date().timeIntervalSince(start) < 600 {
            if let a = chat.approvals.values.first { cards.append(a); chat.answer(a, allow: true) }
            try await Task.sleep(for: .milliseconds(200))
        }
        let c = store.conversations[0]
        for m in c.messages {
            print("[\(m.role)] calls=\(m.toolCalls.map { "\($0.name) \($0.arguments.prefix(200))" }) text=\(m.text.prefix(300).replacingOccurrences(of: "\n", with: " "))")
        }
        print("CARDS:", cards.map(\.title))
        let calls = c.messages.flatMap(\.toolCalls).map(\.name)
        XCTAssertTrue(calls.contains(MCPManager.loadTool), "it loaded the connector")
        XCTAssertTrue(calls.contains { $0.hasPrefix("Bestanden__") }, "it used a tool of the connector")
        XCTAssertEqual(c.connectors, ["Bestanden"], "the conversation keeps the loaded connector")
        let answer = c.messages.last { $0.role == .assistant && !$0.text.isEmpty }?.text ?? ""
        XCTAssertTrue(answer.contains("lijstje.txt") && answer.contains("rapport-2026.md"), answer)
        XCTAssertTrue(cards.isEmpty, "listing a folder only reads: no card")

        // writing is not read-only: the card comes, and after yes the file is there
        chat.send(text: "Maak in die map met de connector een bestand notitie.txt met de tekst hallo.", attachments: [], in: id, store: store,
                  baseURL: URL(string: "http://127.0.0.1:8080")!)
        let again = Date()
        while chat.busy && Date().timeIntervalSince(again) < 600 {
            if let a = chat.approvals.values.first { cards.append(a); chat.answer(a, allow: true) }
            try await Task.sleep(for: .milliseconds(200))
        }
        print("CARDS:", cards.map { "\($0.title) \($0.detail.prefix(120))" })
        XCTAssertTrue(cards.contains { $0.title.hasPrefix("Bestanden:") }, "writing asked first")
        let written = try? String(contentsOf: tmp.appendingPathComponent("notitie.txt"), encoding: .utf8)
        XCTAssertEqual(written?.trimmingCharacters(in: .whitespacesAndNewlines), "hallo")
    }
}

/// Phase 3 with a real model: the model plans a task, a heartbeat with nothing to report, and two conversations at
/// once. Starts the engine itself. MACAIMAGIC_TASKS_TEST=1 (optionally MACAIMAGIC_TASKS_MODEL=<id>), engine stopped.
@MainActor
final class TasksIntegrationTests: XCTestCase {
    func testTasksHeartbeatAndTwoConversations() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MACAIMAGIC_TASKS_TEST"] == "1" else { throw XCTSkip("set MACAIMAGIC_TASKS_TEST=1") }
        let app = AppState()
        let s = Settings.shared
        let saved = (app.selectedModelID, s.systemManagement, s.skills, s.webSearch, s.thinking, s.workspaceTools, s.rightWrite, s.autoApprove)
        defer {
            app.engine.stop()
            (app.selectedModelID, s.systemManagement, s.skills, s.webSearch, s.thinking, s.workspaceTools, s.rightWrite, s.autoApprove) = saved
        }
        (s.systemManagement, s.skills, s.webSearch, s.thinking, s.workspaceTools, s.rightWrite, s.autoApprove) = (true, false, false, false, true, "ask", false)
        app.selectedModelID = env["MACAIMAGIC_TASKS_MODEL"] ?? "qwen3.8-flash-next-q4"
        app.startEngine()
        let t0 = Date()
        while !app.engine.state.isRunning && Date().timeIntervalSince(t0) < 1200 {
            if case .failed(let e) = app.engine.state { XCTFail(e); return }
            try await Task.sleep(for: .seconds(1))
        }
        print("ENGINE READY after", Int(Date().timeIntervalSince(t0)), "s:", app.selectedModelID)
        let base = app.engine.baseURL
        let chat = ChatClient()
        chat.modelName = app.selectedModel?.name ?? "model"
        let tasks = TaskStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        chat.taskStore = tasks
        let store = ConversationStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        func dump(_ id: UUID) {
            for m in store.conversations.first(where: { $0.id == id })?.messages ?? [] {
                print("  [\(m.role)] calls=\(m.toolCalls.map { "\($0.name) \($0.arguments.prefix(160))" }) text=\(m.text.prefix(240).replacingOccurrences(of: "\n", with: " "))")
            }
        }
        func answer(_ id: UUID) -> String { store.conversations.first { $0.id == id }?.messages.last { $0.role == .assistant && !$0.text.isEmpty }?.text ?? "" }

        // 1. the model plans a task, through the card
        let plan = Conversation()
        store.conversations = [plan]
        var cards: [ChatClient.Approval] = []
        chat.send(text: "Geef me elke werkdag om 8 uur 's ochtends een overzicht van mijn agenda. Plan dat als taak.", attachments: [], in: plan.id, store: store, baseURL: base)
        var start = Date()
        while chat.isBusy(plan.id) && Date().timeIntervalSince(start) < 600 {
            if let a = chat.approvals[plan.id] { cards.append(a); chat.answer(a, allow: true) }
            try await Task.sleep(for: .milliseconds(200))
        }
        print("PLAN:"); dump(plan.id)
        print("CARDS:", cards.map { "\($0.title) | \($0.detail.prefix(160))" })
        XCTAssertTrue(cards.contains { $0.title.hasPrefix(L("Taak plannen: \("")")) }, "it showed the card")
        let planned = try XCTUnwrap(tasks.tasks.first, "a task was planned")
        XCTAssertEqual(planned.schedule, .daily(hour: 8, minute: 0, weekdaysOnly: true))
        print("TASK:", planned.title, "|", planned.prompt, "| next", planned.nextRun as Any)

        // 2. a heartbeat with nothing to report answers NIETS
        let beat = Conversation()
        store.conversations.insert(beat, at: 0)
        let missing = "zzz-bestaat-niet-\(UUID().uuidString.prefix(6)).txt"
        chat.send(text: Heartbeat.prompt("- Staat er een bestand \(missing) in de map /tmp? Meld het alleen als het er is."), attachments: [], in: beat.id, store: store, baseURL: base)
        start = Date()
        while chat.isBusy(beat.id) && Date().timeIntervalSince(start) < 600 {
            if let a = chat.approvals[beat.id] { chat.answer(a, allow: true) }
            try await Task.sleep(for: .milliseconds(200))
        }
        print("HEARTBEAT:"); dump(beat.id)
        XCTAssertTrue(Heartbeat.isNothing(answer(beat.id)), "nothing to report: \(answer(beat.id))")

        // 3. one conversation waits for approval, the other answers meanwhile
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mds-two-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var a = Conversation(), b = Conversation()
        a.workspace = folder.path
        store.conversations.insert(contentsOf: [a, b], at: 0)
        chat.send(text: "Maak in de werkmap een bestand notitie.txt met de tekst hallo.", attachments: [], in: a.id, store: store, baseURL: base)
        start = Date()
        while chat.approvals[a.id] == nil && chat.isBusy(a.id) && Date().timeIntervalSince(start) < 600 { try await Task.sleep(for: .milliseconds(200)) }
        XCTAssertNotNil(chat.approvals[a.id], "A asks before it writes")
        chat.send(text: "Wat is de hoofdstad van Frankrijk? Alleen het woord.", attachments: [], in: b.id, store: store, baseURL: base)
        start = Date()
        while chat.isBusy(b.id) && Date().timeIntervalSince(start) < 300 { try await Task.sleep(for: .milliseconds(200)) }
        print("B:"); dump(b.id)
        XCTAssertTrue(answer(b.id).localizedCaseInsensitiveContains("Parijs") || answer(b.id).localizedCaseInsensitiveContains("Paris"), answer(b.id))
        XCTAssertTrue(chat.isBusy(a.id), "A still waits for its card")
        start = Date()
        while chat.isBusy(a.id) && Date().timeIntervalSince(start) < 600 {
            if let card = chat.approvals[a.id] { chat.answer(card, allow: true) }
            try await Task.sleep(for: .milliseconds(200))
        }
        print("A:"); dump(a.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("notitie.txt").path))
    }
}

/// The app knows itself, with a real model: which model it recommends (reads, downloads nothing), a setting through the
/// card, and a skill in the skills folder. Starts the engine itself. MACAIMAGIC_TASKS_TEST=1.
@MainActor
final class AppToolsIntegrationTests: XCTestCase {
    func testTheModelUsesTheApp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MACAIMAGIC_TASKS_TEST"] == "1" else { throw XCTSkip("set MACAIMAGIC_TASKS_TEST=1") }
        let app = AppState()
        let s = Settings.shared
        let saved = (app.selectedModelID, s.systemManagement, s.skills, s.webSearch, s.thinking, s.appTools, s.rightSystemChange, s.workspaceTools)
        let skillDir = Paths.userSkills.appendingPathComponent("proef-c64-assembler")
        defer {
            app.engine.stop()
            (app.selectedModelID, s.systemManagement, s.skills, s.webSearch, s.thinking, s.appTools, s.rightSystemChange, s.workspaceTools) = saved
            try? FileManager.default.removeItem(at: skillDir)
        }
        (s.systemManagement, s.skills, s.webSearch, s.thinking, s.appTools, s.rightSystemChange, s.workspaceTools) = (false, true, false, true, true, "ask", false)
        app.selectedModelID = env["MACAIMAGIC_TASKS_MODEL"] ?? "qwen3.8-flash-next-q4"
        app.startEngine()
        let t0 = Date()
        while !app.engine.state.isRunning && Date().timeIntervalSince(t0) < 1200 {
            if case .failed(let e) = app.engine.state { XCTFail(e); return }
            try await Task.sleep(for: .seconds(1))
        }
        let chat = ChatClient()
        chat.modelName = app.selectedModel?.name ?? "model"
        chat.appControl = app.appControl
        let store = ConversationStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        var cards: [ChatClient.Approval] = []
        func ask(_ text: String) async throws -> Conversation {
            let c = Conversation()
            store.conversations.insert(c, at: 0)
            chat.send(text: text, attachments: [], in: c.id, store: store, baseURL: app.engine.baseURL)
            let start = Date()
            while chat.isBusy(c.id) && Date().timeIntervalSince(start) < 600 {
                if let a = chat.approvals[c.id] { cards.append(a); chat.answer(a, allow: true) }
                try await Task.sleep(for: .milliseconds(200))
            }
            let done = store.conversations.first { $0.id == c.id }!
            for m in done.messages {
                print("  [\(m.role)] calls=\(m.toolCalls.map { "\($0.name) \($0.arguments.prefix(160))" }) text=\(m.text.prefix(240).replacingOccurrences(of: "\n", with: " "))")
            }
            return done
        }

        print("RECOMMEND:")
        let rec = try await ask("Welk model raad je aan voor deze Mac? Download niets.")
        let recCalls = rec.messages.flatMap(\.toolCalls)
        XCTAssertTrue(recCalls.contains { $0.name == "app_status" }, "it looked at the app")
        XCTAssertFalse(recCalls.contains { $0.arguments.contains("download_model") }, "it downloaded nothing")

        print("SETTING:")
        cards = []
        _ = try await ask("Zet het denken uit.")
        print("CARDS:", cards.map(\.title))
        XCTAssertFalse(s.thinking, "thinking is off after the card")
        XCTAssertTrue(cards.contains { $0.title.contains("thinking") })

        print("SKILL:")
        cards = []
        _ = try await ask("Maak een skill met de naam proef-c64-assembler voor programmeren in C64-assembler met ACME.")
        print("CARDS:", cards.map(\.title))
        XCTAssertTrue(FileManager.default.fileExists(atPath: skillDir.appendingPathComponent("SKILL.md").path), "the skill is in the skills folder")
    }
}
