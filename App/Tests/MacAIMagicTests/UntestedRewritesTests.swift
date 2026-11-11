import XCTest
@testable import MacAIMagic

/// The same file written in full again and again, never run: the app tells the model the third time. In the Terminator
/// intro (Qwen3.8, 11 Nov 2026) terminator.asm was written in full 9 times in 40 minutes and never built.
final class UntestedRewritesTests: XCTestCase {
    /// The pattern of that run, made up: analysis scripts and greps in a folder named like the file, a data script
    /// that is run, and the program itself that is written again and again.
    func testThePatternOfTheTerminatorRun() {
        var r = UntestedRewrites()
        var notes: [String] = []
        func write(_ path: String) { if let n = r.wrote(path) { notes.append("\(path) \(n.contains("3 times") ? 3 : n.contains("6 times") ? 6 : 0)") } }
        r.ran("cd /Users/x/Development/Terminator && python3 - <<'EOF'\nraw = open(\"s1.kla\",\"rb\").read()\nEOF")
        write("gen.py")
        r.ran("cd /Users/x/Development/Terminator && python3 gen.py && ls -la *.bin")
        write("gen.py")
        write("gen.py")
        r.ran("cd /Users/x/Development/Terminator && python3 gen.py")
        write("gen.py")
        for k in 1...6 {
            write("terminator.asm")
            if k == 4 { r.ran("grep -n \"SID\" \"$HOME/Skills/c64/C64_KICKASS_SKILL.md\" | head") }
            if k == 5 { r.ran("cd /Users/x/Development/Terminator && ls -la && cat MACAIMAGIC.md") }
        }
        XCTAssertEqual(notes, ["terminator.asm 3", "terminator.asm 6"], "the folder named Terminator is not the file")
    }

    func testAFileCountsAsRunWhenACommandNamesIt() {
        for command in ["./build.sh terminator.asm", "python3 c64run.py build/terminator.prg --shot t.png",
                        "cd /x/Terminator && java -jar KickAss.jar Terminator.asm"] {
            var r = UntestedRewrites()
            XCTAssertNil(r.wrote("terminator.asm"))
            XCTAssertNil(r.wrote("terminator.asm"))
            r.ran(command)
            XCTAssertNil(r.wrote("terminator.asm"), command)
            XCTAssertNil(r.wrote("terminator.asm"), command)
            XCTAssertNotNil(r.wrote("terminator.asm"), "three writes after the run: \(command)")
        }
        var r = UntestedRewrites()
        _ = r.wrote("src/a.asm")
        _ = r.wrote("src/a.asm")
        r.ran("./build.sh b.asm && cd area && ls")
        XCTAssertNotNil(r.wrote("src/a.asm"), "another file, and a word that only starts like it, do not count")
        XCTAssertNil(r.wrote("other.asm"), "each file counts on its own")
    }
}

/// The note rides on the third write's own result, through the real chat loop, against the stand-in engine.
@MainActor
final class UntestedRewritesChatTests: XCTestCase {
    private var server: Process?
    private var port = 0
    private var dir: URL!

    override func setUp() async throws {
        port = Int.random(in: 48_100...49_900)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("herschrijf-\(UUID().uuidString)")
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

    func testTheThirdWholeWriteTellsTheModel() async throws {
        let saved = (Settings.shared.workspaceTools, Settings.shared.learnFromChats, Settings.shared.rightWrite)
        Settings.shared.workspaceTools = true
        Settings.shared.learnFromChats = false
        Settings.shared.rightWrite = "allow"
        defer { (Settings.shared.workspaceTools, Settings.shared.learnFromChats, Settings.shared.rightWrite) = saved }
        let store = ConversationStore(file: dir.appendingPathComponent("gesprekken.json"))
        var a = Conversation()
        a.workspace = dir.path
        store.conversations = [a]
        let chat = ChatClient()
        chat.send(text: "HERSCHRIJF", attachments: [], in: a.id, store: store, baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        try await waitUntil(30) { !chat.isBusy(a.id) }

        let results = try XCTUnwrap(store.conversations.first?.messages).filter { $0.role == .tool }.map(\.text)
        XCTAssertEqual(results.count, 3, "\(results)")
        XCTAssertEqual(results.map { $0.contains("Note from the app") }, [false, false, true], "\(results)")
        XCTAssertTrue(results[2].contains("intro.asm in full 3 times"), results[2])
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("intro.asm")), "versie 2", "the write itself went through")
    }
}
