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

    /// Each look as the run makes it: a call of view_image, its result, and the picture as a message of the app.
    private func look(_ n: Int, _ a: Attachment) -> [ChatMessage] {
        [ChatMessage(role: .assistant, text: "", toolCalls: [ToolCall(id: "v\(n)", name: WorkspaceTools.imageTool, arguments: #"{"path":"shot.png"}"#)]),
         ChatMessage(role: .tool, text: "shot.png bekeken", toolCallId: "v\(n)"),
         ChatMessage(role: .user, text: "Hier is de afbeelding die je opvroeg: shot.png.", attachments: [a], automatic: true)]
    }

    private func json(_ messages: ArraySlice<[String: Any]>) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: Array(messages), options: [.sortedKeys]), as: UTF8.self)
    }

    /// Only the last 3 looks went as pictures. A new look turned an old one into text far back in the conversation, and
    /// Qwen3.6 read the whole conversation again each time: 82K, 110K and 144K tokens (3, 5 and 11 minutes) in one C64 run.
    func testAPictureTheModelLookedAtStaysAndANewLookChangesNothingBefore() throws {
        try screenshot("shot.png")
        let a = try WorkspaceTools.image(call("shot.png")).get()
        let chat = ChatClient()
        chat.seesImages = true
        var history = [ChatMessage(role: .user, text: "Maak een C64-spel en kijk of het werkt.")]
        for n in 1...5 { history += look(n, a) }
        let before = chat.requestMessages(history)
        XCTAssertEqual(before.filter { $0["content"] is [[String: Any]] }.count, 5)
        XCTAssertEqual(before.count, 1 + 1 + 5 * 3)

        history += look(6, a)
        let after = chat.requestMessages(history)
        XCTAssertEqual(after.filter { $0["content"] is [[String: Any]] }.count, 6)
        // what the engine already read is sent the same, character for character: it reads only the new look
        XCTAssertEqual(try json(after.prefix(before.count)), try json(before[...]))
    }

    /// A conversation saved by 1.14.12 sent its looks but the last 3 as text. After the update it sends exactly that
    /// again, so the engine's saved state still fits; a new look stays a picture and changes nothing before it.
    func testAConversationOfTheOlderVersionSendsWhatItSentBefore() throws {
        try screenshot("shot.png")
        let a = try WorkspaceTools.image(call("shot.png")).get()
        var c = Conversation()
        c.messages = [ChatMessage(role: .user, text: "Maak een C64-spel en kijk of het werkt.")]
        for n in 1...5 { c.messages += look(n, a) }
        // as 1.14.12 saved it: without the field
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode([c])) as? [[String: Any]])
        saved[0].removeValue(forKey: "looksKept")
        let file = dir.appendingPathComponent("conversations.json")
        try JSONSerialization.data(withJSONObject: saved).write(to: file)

        let store = ConversationStore(file: file)
        let loaded = try XCTUnwrap(store.conversations.first { $0.id == c.id })
        XCTAssertEqual(loaded.looksKept, true)
        let chat = ChatClient()
        chat.seesImages = true
        let before = chat.requestMessages(loaded.messages)
        let pictures = before.filter { $0["content"] is [[String: Any]] }
        XCTAssertEqual(pictures.count, 3)
        let texts = before.compactMap { $0["content"] as? String }.filter { $0.contains("shot.png") && $0.hasPrefix("(") }
        XCTAssertEqual(texts.count, 2)

        let after = chat.requestMessages(loaded.messages + look(6, a))
        XCTAssertEqual(after.filter { $0["content"] is [[String: Any]] }.count, 4)
        XCTAssertEqual(try json(after.prefix(before.count)), try json(before[...]))

        // loading it again (saved by this version) changes nothing more
        store.update(c.id) { $0.messages += self.look(6, a) }
        store.save()
        let again = try XCTUnwrap(ConversationStore(file: file).conversations.first { $0.id == c.id })
        XCTAssertEqual(chat.requestMessages(again.messages).filter { $0["content"] is [[String: Any]] }.count, 4)
    }

    /// The engine runs without vision: a picture in the conversation goes as a line of text, or the engine refuses this
    /// and every later request of the conversation (a Telegram photo, a picture dropped on the chat).
    func testWithoutVisionAPictureGoesAsText() throws {
        try screenshot("shot.png")
        let a = try WorkspaceTools.image(call("shot.png")).get()
        let chat = ChatClient()
        chat.seesImages = false
        let out = chat.requestMessages([ChatMessage(role: .user, text: "wat staat hierop?", attachments: [a])])
        XCTAssertTrue(out.allSatisfy { $0["content"] is String })
        let text = out.last?["content"] as? String ?? ""
        XCTAssertTrue(text.contains("shot.png") && text.hasSuffix("wat staat hierop?"), text)
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

    func testAFinishedTaskTicksOffEveryStep() {
        let steps = [WorkStep(title: "a", status: "done"), WorkStep(title: "b", status: "doing"), WorkStep(title: "c", status: "todo")]
        XCTAssertEqual(WorkSteps.finished(steps)?.allSatisfy(\.isDone), true)
        XCTAssertEqual(WorkSteps.finished(steps)?.map(\.title), ["a", "b", "c"])
        XCTAssertNil(WorkSteps.finished(nil))
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
