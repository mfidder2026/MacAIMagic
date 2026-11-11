import XCTest
@testable import MacAIMagic

/// The same error three times: the app tells the model its idea of the cause is probably wrong. In the Terminator intro
/// (Qwen3.6, 11 Nov 2026) Kick Assembler said "Syntax error" on `beq !t1-done` in 10 of 13 builds while the model
/// changed other lines and rewrote the whole file 14 times.
final class RepeatedErrorsTests: XCTestCase {
    /// Kick Assembler's output as build.sh up to 11 Nov 2026 showed it, the error on line `line`.
    private func kickAss(line: Int, source: String = "        beq !t1-done") -> String {
        """
        [build] syntax-check terminator.asm

        Summary: 0 error(s), 0 warning(s)
        [build] assembling...
        parsing
        Got 19 errors while executing:
          (/Users/fremen/Development/Kick Assembler/QwenFlashKick/terminator/terminator.asm \(line):17) Syntax error
          (/Users/fremen/Development/Kick Assembler/QwenFlashKick/terminator/terminator.asm \(line + 4):1) Invalid token
          ...

                lda #>termData
                sta $fe
        !t1:    lda ($fd),y
        \(source)
                        ^

        Error: Syntax error
        at line \(line), column 17 in terminator.asm


        [build] ERROR: assembleren mislukt

        [exit code 1]
        """
    }

    func testTheTerminatorErrorIsRecognizedWhereverItMoves() throws {
        var repeated = RepeatedErrors()
        XCTAssertNil(repeated.note(kickAss(line: 67)))
        XCTAssertNil(repeated.note(kickAss(line: 49)))
        let warning = try XCTUnwrap(repeated.note(kickAss(line: 54)), "the third time")
        XCTAssertTrue(warning.contains("beq !t#-done"), warning)
        XCTAssertTrue(warning.contains("3 times"), warning)
        XCTAssertNil(repeated.note(kickAss(line: 57)))
        XCTAssertNil(repeated.note(kickAss(line: 60)))
        XCTAssertNotNil(repeated.note(kickAss(line: 63)), "and again every third time")
    }

    func testOtherErrorsAndGoodBuildsDoNotCount() {
        var repeated = RepeatedErrors()
        XCTAssertNil(repeated.note(kickAss(line: 10, source: "        beq !t1-done")))
        XCTAssertNil(repeated.note(kickAss(line: 20, source: "        lda #$100")))
        XCTAssertNil(repeated.note(kickAss(line: 30, source: "        sta $0400+40*10+x")))
        let good = "[build] assembling...\nparsing\nflex pass 1\nOutput pass\nWriting prg file: build/t.prg\n[build] OK: build/t.prg\n\n[exit code 0]"
        XCTAssertNil(RepeatedErrors.signature(good), "a good build reports no error")
        for _ in 0..<5 { XCTAssertNil(repeated.note(good)) }
        XCTAssertNil(RepeatedErrors.signature("Wrote 4647 bytes to terminator/terminator.asm"))
    }

    /// The new build.sh names the line itself, the checker names it before Kick Assembler, and a Python script ends
    /// with its exception: each is the same error when only its numbers change.
    func testTheNewBuildOutputTheCheckerAndPython() {
        func build(_ n: Int) -> String {
            "[build] FOUT in m1.asm regel \(n), kolom 17: Syntax error\n[build]   \(n) |         beq !t1-done\n                              ^\n[build]   hint: een !-label mag geen - of + in de naam hebben\n[build] ERROR: assembleren mislukt\n\n[exit code 1]"
        }
        XCTAssertEqual(RepeatedErrors.signature(build(6)), RepeatedErrors.signature(build(49)))
        func checker(_ n: Int) -> String {
            "[build] syntax-check t.asm\nERROR: Line \(n): '!t1-done' - een !-label mag geen - of + in de naam hebben\n\nSummary: 1 error(s), 0 warning(s)\n[build] ERROR: syntax checker vond ERRORs — eerst repareren\n\n[exit code 1]"
        }
        XCTAssertEqual(RepeatedErrors.signature(checker(54)), RepeatedErrors.signature(checker(98)))
        XCTAssertTrue(RepeatedErrors.signature(checker(54))?.contains("!t#-done") == true)
        let python = "Traceback (most recent call last):\n  File \"<stdin>\", line 18, in <module>\nTypeError: '>=' not supported between instances of 'str' and 'int'\n\n[exit code 1]"
        let key = RepeatedErrors.signature(python) ?? ""
        XCTAssertTrue(key.contains("typeerror"), key)
        XCTAssertFalse(key.contains("traceback"), "the generic first line says nothing about the error")
    }
}

/// The warning rides on the tool result itself, through the real chat loop, against the stand-in engine.
@MainActor
final class RepeatedErrorsChatTests: XCTestCase {
    private var server: Process?
    private var port = 0
    private var dir: URL!

    override func setUp() async throws {
        port = Int.random(in: 48_100...49_900)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("herhaald-\(UUID().uuidString)")
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

    func testTheThirdSameErrorTellsTheModel() async throws {
        let saved = (Settings.shared.workspaceTools, Settings.shared.learnFromChats, Settings.shared.rightRun)
        Settings.shared.workspaceTools = true
        Settings.shared.learnFromChats = false
        Settings.shared.rightRun = "allow"
        defer { (Settings.shared.workspaceTools, Settings.shared.learnFromChats, Settings.shared.rightRun) = saved }
        let store = ConversationStore(file: dir.appendingPathComponent("gesprekken.json"))
        var a = Conversation()
        a.workspace = dir.path
        store.conversations = [a]
        let chat = ChatClient()
        chat.send(text: "BOUWFOUT", attachments: [], in: a.id, store: store, baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        try await waitUntil(30) { !chat.isBusy(a.id) }

        let messages = try XCTUnwrap(store.conversations.first?.messages)
        let results = messages.filter { $0.role == .tool }.map(\.text)
        XCTAssertEqual(results.count, 4, "\(results)")
        let warned = results.map { $0.contains("Note from the app") }
        XCTAssertEqual(warned, [false, false, true, false], "\(results)")
        XCTAssertTrue(results[2].contains("Syntax error"), "the warning comes with the error itself")
        let steps = messages.flatMap(\.activities)
        XCTAssertTrue(steps.contains { $0.output?.contains("Note from the app") == true }, "the user sees it in the step")
        // the last step of a round was never stored as done, without its output (33 of 37 in the Terminator run)
        XCTAssertEqual(steps.count, 4)
        XCTAssertTrue(steps.allSatisfy { $0.done && $0.output != nil }, "\(steps.map { ($0.done, $0.output != nil) })")
    }
}
