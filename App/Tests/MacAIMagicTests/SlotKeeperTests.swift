import XCTest
@testable import MacAIMagic

/// A conversation's place in the engine is saved when another one takes the model, and read back when it returns
/// (SlotKeeper), against a stand-in for llama-server's /slots endpoints.
@MainActor
final class SlotKeeperTests: XCTestCase {
    private var server: Process?
    private var port = 0
    private var dir: URL!
    private var savedSetting = true

    override func setUp() async throws {
        port = Int.random(in: 46_100...47_900)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("slots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/fake_engine.py").path, String(port), dir.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        server = p
        XCTAssertTrue(String(decoding: out.fileHandleForReading.availableData, as: UTF8.self).contains("READY"))
        savedSetting = Settings.shared.keepEngineMemory
        Settings.shared.keepEngineMemory = true
    }

    override func tearDown() async throws {
        server?.terminate()
        Settings.shared.keepEngineMemory = savedSetting
        try? FileManager.default.removeItem(at: dir)
    }

    private var url: URL { URL(string: "http://127.0.0.1:\(port)")! }

    private func slotCalls() async throws -> [String] {
        let (data, _) = try await URLSession.shared.data(from: url.appendingPathComponent("stats"))
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["slots"] as? [String] ?? []
    }

    func testAConversationThatComesBackIsRestored() async throws {
        let store = ConversationStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        let a = Conversation(), b = Conversation()
        store.conversations = [a, b]
        let keeper = SlotKeeper(folder: dir)
        keeper.started(baseURL: url, key: "model-c65536-v1-s0")
        let chat = ChatClient()
        chat.slots = keeper

        chat.send(text: "hallo", attachments: [], in: a.id, store: store, baseURL: url)
        try await waitUntil { !chat.isBusy(a.id) }
        do { let calls = try await slotCalls(); XCTAssertEqual(calls, ["save " + a.id.uuidString], "an answer is saved when it is done") }

        chat.send(text: "hoi", attachments: [], in: b.id, store: store, baseURL: url)
        try await waitUntil { !chat.isBusy(b.id) }
        do { let calls = try await slotCalls(); XCTAssertEqual(calls, ["save " + a.id.uuidString, "save " + b.id.uuidString], "A was saved already: B's turn does not save it again") }

        chat.send(text: "verder", attachments: [], in: a.id, store: store, baseURL: url)
        try await waitUntil { !chat.isBusy(a.id) }
        do { let calls = try await slotCalls(); XCTAssertEqual(calls, ["save " + a.id.uuidString, "save " + b.id.uuidString, "restore " + a.id.uuidString, "save " + a.id.uuidString]) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(SlotKeeper.fileName(key: "model-c65536-v1-s0", conversation: b.id)).path))

        // the same conversation again: nothing to save or restore
        chat.send(text: "en nog iets", attachments: [], in: a.id, store: store, baseURL: url)
        try await waitUntil { !chat.isBusy(a.id) }
        do { let calls = try await slotCalls(); XCTAssertEqual(calls.count, 5, "the same conversation: no restore, only its save") }
        XCTAssertFalse(keeper.hasUnsaved, "saved after its answer: a quit has nothing left to do")
    }

    /// The notes in MACAIMAGIC.md change while a conversation goes on (the model writes lessons there): its system prompt
    /// stays as it began, so the engine reuses what it read and a restored state still fits. A new conversation sees them.
    func testAConversationKeepsTheNotesItBeganWith() async throws {
        let saved = (Settings.shared.workspaceTools, Settings.shared.learnFromChats)
        Settings.shared.workspaceTools = true
        Settings.shared.learnFromChats = false
        defer { Settings.shared.workspaceTools = saved.0; Settings.shared.learnFromChats = saved.1 }
        let ws = dir.appendingPathComponent("werkmap")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let notes = ws.appendingPathComponent("MACAIMAGIC.md")
        try "Gebruik VICE.".write(to: notes, atomically: true, encoding: .utf8)
        let store = ConversationStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        var a = Conversation(), b = Conversation()
        a.workspace = ws.path
        b.workspace = ws.path
        store.conversations = [a, b]
        let chat = ChatClient()

        chat.send(text: "hallo", attachments: [], in: a.id, store: store, baseURL: url)
        try await waitUntil { !chat.isBusy(a.id) }
        try "Gebruik VICE.\n\n## Geleerd\n- iets nieuws".write(to: notes, atomically: true, encoding: .utf8)
        chat.send(text: "verder", attachments: [], in: a.id, store: store, baseURL: url)
        try await waitUntil { !chat.isBusy(a.id) }
        chat.send(text: "nieuw", attachments: [], in: b.id, store: store, baseURL: url)
        try await waitUntil { !chat.isBusy(b.id) }

        let (data, _) = try await URLSession.shared.data(from: url.appendingPathComponent("systems"))
        let systems = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String])
        XCTAssertEqual(systems.count, 3)
        XCTAssertEqual(systems[0], systems[1], "the same conversation keeps its start")
        XCTAssertFalse(systems[1].contains("iets nieuws"))
        XCTAssertTrue(systems[2].contains("iets nieuws"), "a new conversation reads the notes as they are now")
    }

    /// The lessons asked after a task go with the same template settings as the answers: with thinking off DeepSeek's
    /// template changes the start of the prompt, and the engine read the whole conversation again after every task.
    func testTheLessonsAskedAfterATaskKeepThePromptsStart() async throws {
        let saved = (Settings.shared.workspaceTools, Settings.shared.learnFromChats, Settings.shared.rightWrite, Settings.shared.thinking)
        Settings.shared.workspaceTools = true
        Settings.shared.learnFromChats = true
        Settings.shared.rightWrite = "allow"
        Settings.shared.thinking = true
        defer { (Settings.shared.workspaceTools, Settings.shared.learnFromChats, Settings.shared.rightWrite, Settings.shared.thinking) = saved }
        let ws = dir.appendingPathComponent("taak")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let store = ConversationStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        var a = Conversation()
        a.workspace = ws.path
        store.conversations = [a]
        let chat = ChatClient()
        chat.send(text: "DRIE bestanden", attachments: [], in: a.id, store: store, baseURL: url)
        try await waitUntil { !chat.isBusy(a.id) }
        let (data, _) = try await URLSession.shared.data(from: url.appendingPathComponent("kwargs"))
        let all = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let lesson = try XCTUnwrap(all.last { ($0["stream"] as? Bool) == false }, "the lessons were asked")
        let answer = try XCTUnwrap(all.first { ($0["stream"] as? Bool) == true })
        XCTAssertEqual(lesson["kwargs"] as? NSDictionary, answer["kwargs"] as? NSDictionary)
        XCTAssertEqual((lesson["kwargs"] as? [String: Any])?["enable_thinking"] as? Bool, true)
    }

    func testAnotherEngineSetupDoesNotRestoreAndOffSavesNothing() async throws {
        let keeper = SlotKeeper(folder: dir)
        let a = UUID(), b = UUID()
        keeper.started(baseURL: url, key: "model-c65536-v1-s0")
        await keeper.enter(a)
        await keeper.enter(b)        // saves a
        // the engine restarts with another context: a's state does not fit it
        keeper.started(baseURL: url, key: "model-c32768-v1-s0")
        await keeper.enter(a)
        do { let calls = try await slotCalls(); XCTAssertEqual(calls, ["save " + a.uuidString]) }
        // switched off: no saving or restoring at all
        Settings.shared.keepEngineMemory = false
        await keeper.enter(b)
        XCTAssertFalse(keeper.hasUnsaved)
        do { let calls = try await slotCalls(); XCTAssertEqual(calls.count, 1) }
    }

    func testQuittingSavesTheConversationInTheEngine() async throws {
        let keeper = SlotKeeper(folder: dir)
        let a = UUID()
        keeper.started(baseURL: url, key: "k")
        await keeper.enter(a)
        var lines: [String] = []
        keeper.note = { lines.append($0) }
        keeper.saveBlocking()
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines.first?.contains("save (afsluiten)") == true, "\(lines)")
        do { let calls = try await slotCalls(); XCTAssertEqual(calls, ["save " + a.uuidString]) }
        XCTAssertFalse(keeper.hasUnsaved)
    }

    /// A stop while the engine writes an answer does not wait for it: llama-server holds a save back until the slot is
    /// free, so the model went on writing for up to a minute under "Model ontladen…".
    func testAStopDoesNotWaitForAnAnswerBeingWritten() async throws {
        let keeper = SlotKeeper(folder: dir)
        let a = UUID()
        keeper.started(baseURL: url, key: "k")
        await keeper.enter(a)
        var lines: [String] = []
        keeper.note = { lines.append($0) }
        // an answer is being written (the stand-in sleeps 0.4 s per request)
        var req = URLRequest(url: url.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: ["messages": [["role": "user", "content": "hallo"]], "stream": false])
        let answer = Task { _ = try? await URLSession.shared.data(for: req) }
        try await Task.sleep(for: .milliseconds(150))
        let busy = await keeper.engineBusy()
        XCTAssertEqual(busy, true)
        await keeper.saveCurrent(onlyWhenIdle: true)
        do { let calls = try await slotCalls(); XCTAssertEqual(calls, [], "nothing is saved while it writes") }
        XCTAssertTrue(lines.first?.contains("nog bezig") == true, "\(lines)")
        _ = await answer.value
        await keeper.saveCurrent(onlyWhenIdle: true)
        do { let calls = try await slotCalls(); XCTAssertEqual(calls, ["save " + a.uuidString], "idle again: saved") }
    }

    func testDocumentsSaveTheChatsConversationFirst() async throws {
        let keeper = SlotKeeper(folder: dir)
        let a = UUID()
        keeper.started(baseURL: url, key: "k")
        await keeper.enter(a)
        await SlotKeeper.yield(to: URL(string: "http://localhost:\(port)")!)
        do { let calls = try await slotCalls(); XCTAssertEqual(calls, ["save " + a.uuidString]) }
        XCTAssertNil(keeper.current)
        await SlotKeeper.yield(to: URL(string: "http://127.0.0.1:1")!)
        do { let calls = try await slotCalls(); XCTAssertEqual(calls.count, 1, "another engine leaves it alone") }
    }

    func testOldStatesGoFirstAndADeletedConversationTakesItsOwn() throws {
        let keeper = SlotKeeper(folder: dir)
        let ids = (0..<3).map { _ in UUID() }
        for (n, id) in ids.enumerated() {
            let f = dir.appendingPathComponent(SlotKeeper.fileName(key: "m", conversation: id))
            try Data(count: 1000).write(to: f)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(n - 10))], ofItemAtPath: f.path)
        }
        keeper.prune(limit: 2500)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(SlotKeeper.fileName(key: "m", conversation: ids[0])).path), "the oldest went")
        XCTAssertEqual(keeper.used, 2000)
        keeper.forget(ids[2])
        XCTAssertEqual(keeper.used, 1000)
    }

    /// Measured on the M3 Max with Qwen3.8-Flash-Next: ngram-mod beside MTP doubled the speed of changing code and cost
    /// nothing elsewhere. A model larger than memory gets neither: checking more tokens needs more experts from the SSD.
    func testMTPComesWithNgramModOnlyForAModelInMemory() throws {
        let saved = Settings.shared.mtp
        defer { Settings.shared.mtp = saved }
        Settings.shared.mtp = true
        let engine = EngineController(port: 1, slots: SlotKeeper(folder: dir))
        let model = try XCTUnwrap(ModelCatalog.shared.model("qwen3.8-flash-next-q4"))
        XCTAssertEqual(model.mtp, "file")
        func plan(cache: UInt64) -> MemoryPlan {
            MemoryPlan(physical: 128 << 30, gpuLimit: 110 << 30, suggestedWiredLimitMB: 0, dense: 6 << 30, experts: 76 << 30, engram: 0,
                       overhead: 4 << 30, layers: 48, hostExpertLayers: [], gpuExperts: 0, cpuExperts: 0, expertCache: cache,
                       tensorSplit: [], threads: 12, contextSize: 65536, warnings: [])
        }
        let draft = URL(fileURLWithPath: "/mtp.gguf")
        let args = engine.arguments(model: model, shards: [URL(fileURLWithPath: "/x.gguf")], plan: plan(cache: 0), vision: nil, draft: draft)
        XCTAssertEqual(args.firstIndex(of: "--spec-type").map { args[$0 + 1] }, "draft-mtp,ngram-mod")
        XCTAssertEqual(args.firstIndex(of: "--model-draft").map { args[$0 + 1] }, draft.path)
        XCTAssertEqual(args.firstIndex(of: "--spec-draft-n-max").map { args[$0 + 1] }, "2")
        let streamed = engine.arguments(model: model, shards: [URL(fileURLWithPath: "/x.gguf")], plan: plan(cache: 90 << 30), vision: nil, draft: draft)
        XCTAssertFalse(streamed.contains("--spec-type"))
        // without MTP, no ngram-mod either: it was measured only beside MTP
        Settings.shared.mtp = false
        XCTAssertFalse(engine.arguments(model: model, shards: [URL(fileURLWithPath: "/x.gguf")], plan: plan(cache: 0), vision: nil, draft: draft).contains("--spec-type"))
    }

    func testTheEngineGetsTheFolderUnlessItIsACluster() throws {
        let engine = EngineController(port: 1, slots: SlotKeeper(folder: dir))
        let model = try XCTUnwrap(ModelCatalog.shared.model("ministral-3-8b-q4"))
        let plan = MemoryPlan(physical: 16 << 30, gpuLimit: 12 << 30, suggestedWiredLimitMB: 0, dense: 5 << 30, experts: 0, engram: 0,
                              overhead: 1 << 30, layers: 34, hostExpertLayers: [], gpuExperts: 0, cpuExperts: 0, expertCache: 0,
                              tensorSplit: [], threads: 8, contextSize: 8192, warnings: [])
        let args = engine.arguments(model: model, shards: [URL(fileURLWithPath: "/x.gguf")], plan: plan, vision: nil)
        XCTAssertEqual(args.firstIndex(of: "--slot-save-path").map { args[$0 + 1] }, dir.path)
        XCTAssertFalse(engine.arguments(model: model, shards: [URL(fileURLWithPath: "/x.gguf")], plan: plan, vision: nil, rpc: "1.2.3.4:50052").contains("--slot-save-path"))
        XCTAssertNotEqual(EngineController.slotKey(model: model, plan: plan, vision: nil, speculative: false),
                          EngineController.slotKey(model: model, plan: plan, vision: URL(fileURLWithPath: "/v"), speculative: false))
    }
}
