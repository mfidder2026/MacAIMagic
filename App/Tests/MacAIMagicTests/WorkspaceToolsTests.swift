import XCTest
@testable import MacAIMagic

@MainActor
final class WorkspaceToolsTests: XCTestCase {
    private var dir: URL!
    private var saved = ""

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mds-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        saved = Settings.shared.workspace
        Settings.shared.workspace = dir.path
    }

    override func tearDown() async throws {
        WorkspaceTools.current = nil
        Settings.shared.workspace = saved
        try? FileManager.default.removeItem(at: dir)
    }

    private func call(_ name: String, _ args: [String: Any]) async -> String {
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: args), as: UTF8.self)
        return await WorkspaceTools.run(ToolCall(id: "t", name: name, arguments: json))
    }

    func testStaysInsideTheWorkspace() async throws {
        XCTAssertThrowsError(try WorkspaceTools.resolve("../escape.txt"))
        XCTAssertThrowsError(try WorkspaceTools.resolve("/etc/passwd"))
        XCTAssertThrowsError(try WorkspaceTools.resolve("sub/../../escape.txt"))
        // a symlink inside the workspace that points outside must not work either
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: URL(fileURLWithPath: "/etc"))
        XCTAssertThrowsError(try WorkspaceTools.resolve("link/passwd"))
        let out = await call("read_file", ["path": "link/passwd"])
        XCTAssertTrue(out.hasPrefix("Error:"), out)
        XCTAssertNoThrow(try WorkspaceTools.resolve("new/deeper/file.txt"))
    }

    func testWriteReadEditList() async throws {
        let w = await call("write_file", ["path": "src/hello.py", "content": "print('hallo')\nprint('wereld')\n"])
        XCTAssertTrue(w.contains("Wrote"), w)
        let r = await call("read_file", ["path": "src/hello.py"])
        XCTAssertTrue(r.contains("1\tprint('hallo')"), r)
        let e = await call("edit_file", ["path": "src/hello.py", "old_text": "wereld", "new_text": "Mac"])
        XCTAssertTrue(e.contains("Edited"), e)
        let l = await call("list_dir", ["path": "src"])
        XCTAssertTrue(l.contains("hello.py"), l)
        let bad = await call("edit_file", ["path": "src/hello.py", "old_text": "print", "new_text": "x"])
        XCTAssertTrue(bad.contains("2 times"), bad)
    }

    func testBinaryWriteForAPrg() async throws {
        // a C64 BASIC program: load address $0801, then 10 PRINT"HI"
        let bytes: [UInt8] = [0x01, 0x08, 0x0B, 0x08, 0x0A, 0x00, 0x99, 0x22, 0x48, 0x49, 0x22, 0x00, 0x00, 0x00]
        let w = await call("write_file", ["path": "hi.prg", "content": Data(bytes).base64EncodedString(), "encoding": "base64"])
        XCTAssertTrue(w.contains("14 bytes"), w)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("hi.prg")), Data(bytes))
        let r = await call("read_file", ["path": "hi.prg"])
        XCTAssertTrue(r.contains("binary"), r)
    }

    func testRunCommandAndTailALog() async throws {
        _ = await call("write_file", ["path": "run.sh", "content": "for i in $(seq 1 50); do echo \"regel $i\"; done > app.log\necho klaar\nexit 3\n"])
        let out = await call("run_command", ["command": "bash run.sh"])
        XCTAssertTrue(out.contains("klaar"), out)
        XCTAssertTrue(out.contains("exit code 3"), out)
        let tail = await call("read_file", ["path": "app.log", "tail": 2])
        XCTAssertTrue(tail.contains("regel 50") && !tail.contains("regel 48"), tail)
        let pwd = await call("run_command", ["command": "pwd"])
        XCTAssertTrue(pwd.contains(dir.resolvingSymlinksInPath().path), pwd)
        let slow = await call("run_command", ["command": "sleep 5", "timeout": 1])
        XCTAssertTrue(slow.contains("timeout"), slow)
    }

    /// Each conversation has its own folder: what one chat writes, the other does not see.
    func testEachChatHasItsOwnFolder() async throws {
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("mds-ws2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        WorkspaceTools.current = dir.path
        _ = await call("write_file", ["path": "a.txt", "content": "chat A"])
        WorkspaceTools.current = other.path
        let list = await call("list_dir", ["path": "."])
        XCTAssertFalse(list.contains("a.txt"), list)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.txt").path))
        // a chat without a folder has no file tools
        WorkspaceTools.current = ""
        let none = await call("list_dir", ["path": "."])
        XCTAssertTrue(none.contains("No workspace"), none)
    }
}

final class RightsTests: XCTestCase {
    /// Each workspace tool falls under one right: read, write or run.
    func testToolsMapToRights() {
        XCTAssertEqual(WorkspaceTools.right(for: "list_dir"), .read)
        XCTAssertEqual(WorkspaceTools.right(for: "read_file"), .read)
        XCTAssertEqual(WorkspaceTools.right(for: "write_file"), .write)
        XCTAssertEqual(WorkspaceTools.right(for: "edit_file"), .write)
        XCTAssertEqual(WorkspaceTools.right(for: "run_command"), .run)
        XCTAssertEqual(Set(WorkspaceTools.Right.allCases.map(\.letter)).count, 3, "three different letters in every language")
    }
}
