import XCTest
@testable import MacAIMagic

/// The file panel beside the chat: what it lists of the working folder and what it shows of a file (WinAIMagic's names).
final class WorkspaceFilesTests: XCTestCase {
    private var dirs: [URL] = []
    override func tearDown() { for d in dirs { try? FileManager.default.removeItem(at: d) } }

    private func newFolder() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("panel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        dirs.append(d)
        return d
    }

    func testFoldersComeFirstInTheFindersOrderAndHiddenOnesStayOut() throws {
        let dir = try newFolder()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        for n in ["file10.txt", "file2.txt", "Alpha.swift", ".geheim"] { try "x".write(to: dir.appendingPathComponent(n), atomically: true, encoding: .utf8) }
        let (entries, more) = WorkspaceFiles.list(dir)
        XCTAssertEqual(entries.map(\.name), ["src", "Alpha.swift", "file2.txt", "file10.txt"])
        XCTAssertTrue(entries[0].isFolder)
        XCTAssertEqual(more, 0)
        XCTAssertTrue(WorkspaceFiles.list(dir.appendingPathComponent("bestaat-niet")).entries.isEmpty)
    }

    func testAVeryFullFolderShowsItsFirstPartAndCountsTheRest() throws {
        let dir = try newFolder()
        for i in 0..<(WorkspaceFiles.maxEntries + 7) { FileManager.default.createFile(atPath: dir.appendingPathComponent("f\(i).txt").path, contents: nil) }
        let (entries, more) = WorkspaceFiles.list(dir)
        XCTAssertEqual(entries.count, WorkspaceFiles.maxEntries)
        XCTAssertEqual(more, 7)
    }

    func testTextIsShownAndABinaryFileIsNamedAsSuch() throws {
        let dir = try newFolder()
        let code = dir.appendingPathComponent("spel.bas")
        try (Data([0xEF, 0xBB, 0xBF]) + Data("10 print \"héllo\"\n20 goto 10\n".utf8)).write(to: code)
        XCTAssertEqual(WorkspaceFiles.read(code), .init(text: "10 print \"héllo\"\n20 goto 10\n", note: nil))
        let old = dir.appendingPathComponent("oud.txt")
        try Data([UInt8(ascii: "c"), 0xE9, UInt8(ascii: "!")]).write(to: old)     // Windows-1252, not UTF-8
        XCTAssertEqual(WorkspaceFiles.read(old).text, "cé!")
        let prg = dir.appendingPathComponent("spel.prg")
        try Data([0x01, 0x08, 0x0E, 0x08, 0x0A, 0x00, 0x99, 0x00, 0x00, 0x00]).write(to: prg)
        let shown = WorkspaceFiles.read(prg)
        XCTAssertNil(shown.text)
        XCTAssertTrue(shown.note?.contains("10 B") == true, "\(String(describing: shown.note))")
        XCTAssertNil(WorkspaceFiles.read(dir.appendingPathComponent("weg.txt")).text)
    }

    func testALongFileShowsItsFirstPartUpToAWholeLine() throws {
        let dir = try newFolder()
        let log = dir.appendingPathComponent("lang.log")
        let line = String(repeating: "é", count: 99) + "\n"          // 199 bytes in UTF-8: the cut falls inside a character
        try String(repeating: line, count: 6000).write(to: log, atomically: true, encoding: .utf8)
        let shown = WorkspaceFiles.read(log)
        let text = try XCTUnwrap(shown.text)
        XCTAssertTrue(text.hasSuffix("é"))
        XCTAssertFalse(text.contains("\u{FFFD}"))
        XCTAssertLessThan(text.count, 6000 * line.count)
        XCTAssertNotNil(shown.note)
    }

    func testWhatTheModelWritesChangesTheSignature() throws {
        let dir = try newFolder()
        let before = WorkspaceFiles.signature(folders: [dir], file: nil)
        try "x".write(to: dir.appendingPathComponent("nieuw.txt"), atomically: true, encoding: .utf8)
        XCTAssertNotEqual(WorkspaceFiles.signature(folders: [dir], file: nil), before)
    }
}
