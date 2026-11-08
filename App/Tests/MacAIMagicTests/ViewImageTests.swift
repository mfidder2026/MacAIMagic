import AppKit
import XCTest
@testable import MacAIMagic

/// The model checks a program with a window by looking at a screenshot of it (view_image): the 6-hour C64 run said
/// "I cannot read the screenshot myself" and never saw the ?OUT OF DATA ERROR on the emulator's screen.
@MainActor
final class ViewImageTests: XCTestCase {
    private var dir: URL!
    private var saved = ""
    private var savedTools = true

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mds-img-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        saved = Settings.shared.workspace
        savedTools = Settings.shared.workspaceTools
        Settings.shared.workspace = dir.path
        Settings.shared.workspaceTools = true
    }

    override func tearDown() async throws {
        Settings.shared.workspace = saved
        Settings.shared.workspaceTools = savedTools
        try? FileManager.default.removeItem(at: dir)
    }

    /// A PNG the size of a VICE screenshot (384 × 272).
    private func screenshot(_ name: String) throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 384, pixelsHigh: 272, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
    }

    private func call(_ path: String) -> ToolCall {
        ToolCall(id: "v", name: WorkspaceTools.imageTool, arguments: #"{"path":"\#(path)"}"#)
    }

    func testASmallScreenshotIsEnlargedWithSharpPixels() throws {
        try screenshot("shot.png")
        let a = try WorkspaceTools.image(call("shot.png")).get()
        let img = try XCTUnwrap(NSBitmapImageRep(data: a.jpeg))
        XCTAssertEqual(img.pixelsWide, 768)
        XCTAssertEqual(img.pixelsHigh, 544)
        XCTAssertEqual(a.filename, "shot.png")
    }

    func testOnlyImagesInsideTheWorkspace() throws {
        XCTAssertThrowsError(try WorkspaceTools.image(call("/etc/hosts")).get())
        XCTAssertThrowsError(try WorkspaceTools.image(call("missing.png")).get())
        try "geen plaatje".write(to: dir.appendingPathComponent("tekst.png"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try WorkspaceTools.image(call("tekst.png")).get())
    }

    func testTheToolIsOfferedOnlyWithVision() {
        let chat = ChatClient()
        func names() -> [String] { chat.currentTools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String } }
        chat.seesImages = false
        XCTAssertFalse(names().contains("view_image"))
        chat.seesImages = true
        XCTAssertTrue(names().contains("view_image"))
    }

    func testOnlyTheLastPicturesTheModelLookedAtAreSentAgain() throws {
        try screenshot("shot.png")
        let a = try WorkspaceTools.image(call("shot.png")).get()
        let history = (1...5).map { ChatMessage(role: .user, text: "beeld \($0)", attachments: [a], automatic: true) }
        let out = ChatClient().requestMessages(history)
        let withImage = out.filter { $0["content"] is [[String: Any]] }
        XCTAssertEqual(withImage.count, ChatClient.imagesKept)
        XCTAssertEqual(out.count, 1 + 5)
    }
}

/// The user follows the work in the step list above the composer; a model that forgets to tick steps off is reminded.
final class StepReminderTests: XCTestCase {
    private let open = [WorkStep(title: "Code schrijven", status: "done"), WorkStep(title: "Testen in VICE", status: "todo")]

    func testAFrozenListIsRemindedOf() throws {
        XCTAssertNil(WorkSteps.reminder(open, roundsSince: WorkSteps.remindAfter - 1))
        let text = try XCTUnwrap(WorkSteps.reminder(open, roundsSince: WorkSteps.remindAfter))
        XCTAssertTrue(text.contains("task_list"))
        XCTAssertTrue(text.contains("[todo] Testen in VICE"))
    }

    func testNoReminderWithoutOpenSteps() {
        XCTAssertNil(WorkSteps.reminder(nil, roundsSince: 20))
        XCTAssertNil(WorkSteps.reminder(open.map { WorkStep(title: $0.title, status: "done") }, roundsSince: 20))
    }
}

/// A stopped answer showed a red "cancelled": the stop cancels the request, and URLSession throws URLError.cancelled.
final class StopIsNoFailureTests: XCTestCase {
    func testAStoppedRequestIsAStop() {
        XCTAssertTrue(ChatClient.isStop(CancellationError()))
        XCTAssertTrue(ChatClient.isStop(URLError(.cancelled)))
        XCTAssertTrue(ChatClient.isStop(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
        XCTAssertFalse(ChatClient.isStop(URLError(.timedOut)))
        XCTAssertFalse(ChatClient.isStop(URLError(.cannotConnectToHost)))
    }
}
