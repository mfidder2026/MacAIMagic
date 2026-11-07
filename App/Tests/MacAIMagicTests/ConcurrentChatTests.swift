import XCTest
@testable import MacAIMagic

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

struct TimedOut: Error {}

/// Waits for a condition; a time-out fails the test.
@MainActor
func waitUntil(_ seconds: Double = 20, _ condition: () -> Bool) async throws {
    let start = Date()
    while !condition() {
        if Date().timeIntervalSince(start) > seconds { throw TimedOut() }
        try await Task.sleep(for: .milliseconds(50))
    }
}

@MainActor
final class ModelGateTests: XCTestCase {
    func testTurnsInOrder() async {
        let gate = ModelGate()
        let a = UUID(), b = UUID(), c = UUID()
        var order: [UUID] = []
        let first = await gate.acquire(a)
        XCTAssertTrue(first)
        let tb = Task { if await gate.acquire(b) { order.append(b); gate.release() } }
        try? await Task.sleep(for: .milliseconds(50))
        let tc = Task { if await gate.acquire(c) { order.append(c); gate.release() } }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(gate.waiting, [b, c])
        gate.release()
        await tb.value
        await tc.value
        XCTAssertEqual(order, [b, c])
        XCTAssertNil(gate.holder)
    }

    func testAStopWhileWaitingLeavesTheQueue() async {
        let gate = ModelGate()
        let a = UUID(), b = UUID()
        _ = await gate.acquire(a)
        let tb = Task { await gate.acquire(b) }
        try? await Task.sleep(for: .milliseconds(50))
        tb.cancel()
        let got = await tb.value
        XCTAssertFalse(got)
        XCTAssertEqual(gate.waiting, [])
        gate.release()
        XCTAssertNil(gate.holder, "nobody left to hand the model to")
    }
}

/// Two conversations at once against a stand-in for the engine.
@MainActor
final class ConcurrentChatTests: XCTestCase {
    private var server: Process?
    private var port = 0
    private var saved: (tools: Bool, write: String)!
    private var dirs: [URL] = []

    override func setUp() async throws {
        port = Int.random(in: 48_100...49_900)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", fixtures.appendingPathComponent("fake_engine.py").path, String(port)]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        server = p
        XCTAssertTrue(String(decoding: out.fileHandleForReading.availableData, as: UTF8.self).contains("READY"))
        saved = (Settings.shared.workspaceTools, Settings.shared.rightWrite)
        Settings.shared.workspaceTools = true
        Settings.shared.rightWrite = "ask"
    }

    override func tearDown() async throws {
        server?.terminate()
        Settings.shared.workspaceTools = saved.tools
        Settings.shared.rightWrite = saved.write
        for d in dirs { try? FileManager.default.removeItem(at: d) }
    }

    private func folder() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("mds-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        dirs.append(d)
        return d.resolvingSymlinksInPath()
    }

    private func lastAnswer(_ store: ConversationStore, _ id: UUID) -> String? {
        store.conversations.first { $0.id == id }?.messages.last { $0.role == .assistant && !$0.text.isEmpty }?.text
    }

    func testATaskWaitingForApprovalDoesNotHoldUpAnotherChat() async throws {
        let store = ConversationStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        let dirA = try folder(), dirB = try folder()
        var a = Conversation(), b = Conversation()
        a.workspace = dirA.path
        b.workspace = dirB.path
        store.conversations = [a, b]
        let chat = ChatClient()
        let url = URL(string: "http://127.0.0.1:\(port)")!

        chat.send(text: "SCHRIJF een bestand", attachments: [], in: a.id, store: store, baseURL: url)
        try await waitUntil { chat.approvals[a.id] != nil }
        // A waits for the user; B gets the model and its answer
        chat.send(text: "hallo", attachments: [], in: b.id, store: store, baseURL: url)
        XCTAssertTrue(chat.isBusy(a.id) && chat.isBusy(b.id))
        try await waitUntil { !chat.isBusy(b.id) }
        XCTAssertEqual(lastAnswer(store, b.id), "Antwoord op: hallo")
        XCTAssertTrue(chat.isBusy(a.id), "A still waits for its approval")

        chat.answer(try XCTUnwrap(chat.approvals[a.id]), allow: true)
        try await waitUntil { !chat.isBusy(a.id) }
        XCTAssertEqual(lastAnswer(store, a.id), "Geschreven.", "the done-word is not shown")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirA.appendingPathComponent("x.txt").path), "A writes in its own folder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dirB.appendingPathComponent("x.txt").path))

        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/stats")!)
        let stats = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(stats["most"] as? Int, 1, "the model wrote for one conversation at a time")
    }

    func testStoppingOneConversationLeavesTheOther() async throws {
        let store = ConversationStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        var a = Conversation(), b = Conversation()
        a.workspace = try folder().path
        store.conversations = [a, b]
        let chat = ChatClient()
        let url = URL(string: "http://127.0.0.1:\(port)")!
        chat.send(text: "SCHRIJF", attachments: [], in: a.id, store: store, baseURL: url)
        try await waitUntil { chat.approvals[a.id] != nil }
        chat.send(text: "nog een vraag", attachments: [], in: b.id, store: store, baseURL: url)
        chat.stop(a.id)
        try await waitUntil { !chat.isBusy(a.id) }
        try await waitUntil { !chat.isBusy(b.id) }
        XCTAssertNil(chat.approvals[a.id])
        XCTAssertEqual(lastAnswer(store, b.id), "Antwoord op: nog een vraag")
    }
}
