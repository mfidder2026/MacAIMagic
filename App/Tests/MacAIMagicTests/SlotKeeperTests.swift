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
