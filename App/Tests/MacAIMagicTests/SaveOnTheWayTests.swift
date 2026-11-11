import XCTest
@testable import MacAIMagic

/// A long answer is written to disk while it runs, not only at its end. The Terminator intro (Qwen3.8, 11 Nov 2026)
/// ran for two hours in one answer, and all its steps were in memory only.
@MainActor
final class SaveOnTheWayTests: XCTestCase {
    private var server: Process?
    private var port = 0
    private var dir: URL!

    override func setUp() async throws {
        port = Int.random(in: 48_100...49_900)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("onderweg-\(UUID().uuidString)")
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
    }

    override func tearDown() async throws {
        server?.terminate()
        try? FileManager.default.removeItem(at: dir)
    }

    func testALongAnswerIsOnDiskWhileItRuns() async throws {
        let saved = (Settings.shared.workspaceTools, Settings.shared.learnFromChats, Settings.shared.rightRun, ConversationStore.saveEvery)
        Settings.shared.workspaceTools = true
        Settings.shared.learnFromChats = false
        Settings.shared.rightRun = "allow"
        ConversationStore.saveEvery = 0
        defer { (Settings.shared.workspaceTools, Settings.shared.learnFromChats, Settings.shared.rightRun, ConversationStore.saveEvery) = saved }
        let file = dir.appendingPathComponent("gesprekken.json")
        let store = ConversationStore(file: file)
        var a = Conversation()
        a.workspace = dir.path
        store.conversations = [a]
        let chat = ChatClient()
        // four rounds of a failing build, then the answer ends
        chat.send(text: "BOUWFOUT", attachments: [], in: a.id, store: store, baseURL: URL(string: "http://127.0.0.1:\(port)")!)

        var resultsOnDisk: [Int] = []
        let until = Date().addingTimeInterval(30)
        while chat.isBusy(a.id) && Date() < until {
            if let data = try? Data(contentsOf: file),
               let messages = try? JSONDecoder().decode([Conversation].self, from: data).first?.messages {
                let results = messages.filter { $0.role == .tool }.count
                if resultsOnDisk.last != results {
                    resultsOnDisk.append(results)
                    // saved where a round is complete: each call has its result, and no step is still busy
                    XCTAssertEqual(messages.last?.role, results == 0 ? .user : .tool, "\(results)")
                    XCTAssertTrue(messages.flatMap(\.activities).allSatisfy(\.done), "\(results)")
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(chat.isBusy(a.id))
        XCTAssertTrue(resultsOnDisk.contains { $0 >= 2 }, "rounds were on disk before the answer ended: \(resultsOnDisk)")
    }

    func testOnTheWayItSavesAtMostOnceInAWhile() throws {
        let saved = ConversationStore.saveEvery
        ConversationStore.saveEvery = 3600
        defer { ConversationStore.saveEvery = saved }
        let file = dir.appendingPathComponent("gesprekken.json")
        let store = ConversationStore(file: file)
        store.saveOnTheWay()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "the first time it saves")
        try FileManager.default.removeItem(at: file)
        store.saveOnTheWay()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "not again within the interval")
        store.save()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "a save at the end of an answer always writes")
    }
}
