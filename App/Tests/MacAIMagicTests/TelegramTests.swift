import XCTest
@testable import MacAIMagic

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

final class TelegramFormatTests: XCTestCase {
    func testLongTextIsSplitUnderTheLimit() {
        let paragraph = String(repeating: "woord ", count: 120)          // 720 characters
        let text = Array(repeating: paragraph, count: 12).joined(separator: "\n\n")
        let parts = TelegramFormat.chunks(text, limit: 2000)
        XCTAssertGreaterThan(parts.count, 3)
        XCTAssertTrue(parts.allSatisfy { $0.count <= 2000 + 4 })
        XCTAssertEqual(parts.joined(separator: " ").split(separator: " ").count, text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count)
        XCTAssertEqual(TelegramFormat.chunks("kort"), ["kort"])
    }

    func testACodeBlockThatIsSplitStaysACodeBlock() {
        let code = "```\n" + (1...400).map { "regel \($0)" }.joined(separator: "\n") + "\n```"
        let parts = TelegramFormat.chunks(code, limit: 1000)
        XCTAssertGreaterThan(parts.count, 1)
        for p in parts { XCTAssertEqual(p.components(separatedBy: "```").count % 2, 1, "every part has whole code blocks: \(p.prefix(40))") }
    }

    func testHTMLIsSafeAndKeepsTheMarkdown() {
        XCTAssertEqual(TelegramFormat.html("a < b & c > d"), "a &lt; b &amp; c &gt; d")
        XCTAssertEqual(TelegramFormat.html("<script>alert(1)</script>"), "&lt;script&gt;alert(1)&lt;/script&gt;")
        XCTAssertEqual(TelegramFormat.html("**vet** en *schuin*"), "<b>vet</b> en <i>schuin</i>")
        XCTAssertEqual(TelegramFormat.html("doe `ls -la <map>`"), "doe <code>ls -la &lt;map&gt;</code>")
        XCTAssertEqual(TelegramFormat.html("```swift\nlet a = 1 < 2\n```"), "<pre>let a = 1 &lt; 2</pre>")
        XCTAssertEqual(TelegramFormat.html("[site](https://example.com/a?b=1&c=2)"), "<a href=\"https://example.com/a?b=1&amp;c=2\">site</a>")
        XCTAssertEqual(TelegramFormat.html("[x](javascript:alert(1))"), "[x](javascript:alert(1))", "only http(s) links")
        XCTAssertEqual(TelegramFormat.html("## Titel\n- punt"), "<b>Titel</b>\n• punt")
        XCTAssertEqual(TelegramFormat.html("2 * 3 * 4"), "2 * 3 * 4")
        XCTAssertEqual(TelegramFormat.html("Vrij:\n| | |\n|---|---|\n| Totaal | 1,8 TB |\n| **Vrij** | 150 GB |\nKlaar"),
                       "Vrij:\n<pre>Totaal  1,8 TB\nVrij    150 GB</pre>\nKlaar")
    }
}

final class TelegramAccessTests: XCTestCase {
    private func message(_ text: String, from id: Int64 = 42, chat: Int64? = nil, type: String = "private") -> TelegramBot.Message {
        TelegramBot.Message(messageId: 1, from: .init(id: id, isBot: false, firstName: "Mila", lastName: nil, username: nil),
                            chat: .init(id: chat ?? id, type: type), text: text, caption: nil, photo: nil, document: nil, voice: nil)
    }

    func testOnlyThePairingCodeLetsSomeoneIn() {
        var access = TelegramAccess()
        XCTAssertEqual(access.decide(message("hallo")), .ignored, "nobody without a code")
        let now = Date()
        let code = access.newCode(now: now)
        XCTAssertEqual(code.count, 6)
        XCTAssertEqual(access.decide(message("000000" == code ? "111111" : "000000"), now: now), .ignored, "a wrong code")
        XCTAssertEqual(access.decide(message(code, chat: -5, type: "group"), now: now), .ignored, "not in a group")
        XCTAssertEqual(access.decide(message("ik weet het: " + code), now: now), .ignored, "the code alone")
        guard case .paired(let a) = access.decide(message("/start " + code), now: now) else { return XCTFail("not paired") }
        XCTAssertEqual(a.id, 42)
        XCTAssertEqual(a.name, "Mila")
        XCTAssertEqual(access.decide(message("hallo")), .allowed(a))
        XCTAssertNil(access.code, "a code works once")
        XCTAssertEqual(access.decide(message(code, from: 7), now: now), .ignored, "not for a second account")
    }

    func testTheCodeExpires() {
        var access = TelegramAccess()
        let now = Date()
        let code = access.newCode(now: now)
        XCTAssertEqual(access.decide(message(code), now: now.addingTimeInterval(11 * 60)), .ignored)
        XCTAssertTrue(access.accounts.isEmpty)
    }
}

/// The bot, the service and the bridge against a stand-in for Telegram and one for the engine.
@MainActor
final class TelegramBridgeTests: XCTestCase {
    private var servers: [Process] = []
    private var telegramPort = 0
    private var enginePort = 0
    private var dirs: [URL] = []
    private var saved: (tools: Bool, write: String, notify: Bool)!
    private var defaults: UserDefaults!

    private func start(_ script: String) throws -> Int {
        let port = Int.random(in: 50_100...51_900)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", fixtures.appendingPathComponent(script).path, String(port)]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        servers.append(p)
        XCTAssertTrue(String(decoding: out.fileHandleForReading.availableData, as: UTF8.self).contains("READY"))
        return port
    }

    override func setUp() async throws {
        telegramPort = try start("fake_telegram.py")
        enginePort = try start("fake_engine.py")
        saved = (Settings.shared.workspaceTools, Settings.shared.rightWrite, Settings.shared.telegramNotify)
        Settings.shared.workspaceTools = true
        Settings.shared.rightWrite = "ask"
        defaults = UserDefaults(suiteName: "telegram-test-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        for s in servers { s.terminate() }
        Settings.shared.workspaceTools = saved.tools
        Settings.shared.rightWrite = saved.write
        Settings.shared.telegramNotify = saved.notify
        for d in dirs { try? FileManager.default.removeItem(at: d) }
    }

    private var telegram: URL { URL(string: "http://127.0.0.1:\(telegramPort)")! }

    private func push(_ update: [String: Any]) async throws {
        var req = URLRequest(url: telegram.appendingPathComponent("control/push"))
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: update)
        _ = try await URLSession.shared.data(for: req)
    }

    private func pushText(_ text: String, from id: Int64 = 42) async throws {
        try await push(["message": ["message_id": Int.random(in: 1...9999), "from": ["id": id, "is_bot": false, "first_name": "Mila"],
                                    "chat": ["id": id, "type": "private"], "date": 0, "text": text]])
    }

    private func sent() async throws -> [[String: Any]] {
        let (data, _) = try await URLSession.shared.data(from: telegram.appendingPathComponent("control/sent"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    /// Waits for a call to Telegram that matches.
    @discardableResult
    private func waitForSent(_ seconds: Double = 20, _ match: @escaping ([String: Any]) -> Bool) async throws -> [String: Any] {
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            if let hit = try await sent().last(where: match) { return hit }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("never sent: " + ((try? await sent()) ?? []).map { "\($0["method"] ?? "") \($0["parse_mode"] ?? "-") \(self.text($0).prefix(60))" }.joined(separator: " | "))
        throw CancellationError()
    }

    private func text(_ call: [String: Any]) -> String { call["text"] as? String ?? "" }

    private func make() -> (TelegramService, TelegramBridge, ChatClient, ConversationStore) {
        let service = TelegramService(defaults: defaults)
        service.useForTests(base: telegram, token: "TEST:OK")
        let chat = ChatClient()
        let store = ConversationStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        let engine = URL(string: "http://127.0.0.1:\(enginePort)")!
        let bridge = TelegramBridge(service: service, chat: chat, store: store, baseURL: { engine }, modelRunning: { true },
                                    ensureModel: { true }, statusText: { "Model: test" })
        bridge.editInterval = .milliseconds(200)
        chat.onApproval = { [weak bridge] a in bridge?.approval(a, isTask: false) }
        return (service, bridge, chat, store)
    }

    private func pair(_ service: TelegramService) async throws {
        try await waitUntil { service.isOnline }
        let code = service.newCode()
        try await pushText("/start " + code)
        try await waitUntil { !service.accounts.isEmpty }
        try await waitForSent { self.text($0).hasPrefix("Gekoppeld") || self.text($0).hasPrefix("Paired") }
    }

    func testTheBotRefusesAWrongTokenAndFallsBackToPlainText() async throws {
        let wrong = TelegramBot(token: "WRONG", base: telegram)
        do { _ = try await wrong.me(); XCTFail("a wrong token works") } catch let e as TelegramBot.BotError { XCTAssertEqual(e, .unauthorized) }
        let bot = TelegramBot(token: "TEST:OK", base: telegram)
        let me = try await bot.me()
        XCTAssertEqual(me.username, "testbot")
        _ = try await bot.send(42, "platte tekst", html: "<bad>")
        let calls = try await sent().filter { $0["method"] as? String == "sendMessage" }
        XCTAssertEqual(calls.count, 2, "HTML refused, then sent as plain text")
        XCTAssertEqual(text(calls[1]), "platte tekst")
        XCTAssertNil(calls[1]["parse_mode"])
    }

    func testAStrangerIsIgnoredAndAPairedAccountGetsItsAnswer() async throws {
        let (service, bridge, _, store) = make()
        defer { withExtendedLifetime(bridge) {} }
        service.start()
        defer { service.stop() }
        try await waitUntil { service.isOnline }
        try await pushText("hallo, wie ben jij?", from: 666)
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertFalse(store.conversations.contains { $0.telegram != nil }, "no conversation for a stranger")
        let early = try await sent()
        XCTAssertTrue(early.isEmpty, "and no answer: the bot gives nothing away")
        XCTAssertTrue(service.log.contains { $0.contains("666") && !$0.contains("wie ben jij") }, "the log has the id, not the text")

        try await pair(service)
        try await pushText("hallo")
        let answer = try await waitForSent { self.text($0).contains("Antwoord op: hallo") && $0["parse_mode"] as? String == "HTML" }
        XCTAssertEqual(answer["chat_id"] as? Int, 42)
        let c = try XCTUnwrap(store.conversations.first { $0.telegram != nil })
        XCTAssertEqual(c.telegram, 42)
        XCTAssertTrue(c.title.contains("Telegram"))
        XCTAssertEqual(c.messages.first?.text, "hallo")

        // the next message goes on in the same conversation; /nieuw starts another
        try await pushText("en nu?")
        try await waitForSent { self.text($0).contains("Antwoord op: en nu?") }
        XCTAssertEqual(store.conversations.filter { $0.telegram != nil }.count, 1)
        try await pushText("/nieuw")
        try await waitForSent { self.text($0).hasPrefix("Nieuw gesprek") || self.text($0).hasPrefix("New conversation") }
        XCTAssertEqual(store.conversations.filter { $0.telegram != nil }.count, 2)
        XCTAssertGreaterThan(defaults.integer(forKey: "telegramOffset"), 4, "the offset is kept, so a restart does nothing twice")
    }

    func testAButtonInTelegramAnswersTheApproval() async throws {
        let (service, bridge, chat, store) = make()
        service.start()
        defer { service.stop() }
        try await pair(service)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        let id = bridge.conversation(for: service.accounts[0])
        store.update(id) { $0.workspace = dir.resolvingSymlinksInPath().path }

        try await pushText("SCHRIJF een bestand")
        let card = try await waitForSent { $0["reply_markup"] != nil && $0["method"] as? String == "sendMessage" }
        let rows = try XCTUnwrap((card["reply_markup"] as? [String: Any])?["inline_keyboard"] as? [[[String: Any]]])
        let allow = try XCTUnwrap(rows.flatMap { $0 }.first { ($0["callback_data"] as? String ?? "").hasPrefix("a:") })
        XCTAssertTrue(chat.isBusy(id), "waits for the answer")

        // a stranger's press does nothing
        try await push(["callback_query": ["id": "q0", "from": ["id": 666, "is_bot": false, "first_name": "X"], "data": allow["callback_data"]!]])
        try await Task.sleep(for: .seconds(1))
        XCTAssertNotNil(chat.approvals[id])

        try await push(["callback_query": ["id": "q1", "from": ["id": 42, "is_bot": false, "first_name": "Mila"], "data": allow["callback_data"]!,
                                           "message": ["message_id": card["message_id"] ?? 100, "chat": ["id": 42, "type": "private"], "date": 0, "text": "kaart"]]])
        try await waitUntil { !chat.isBusy(id) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("x.txt").path), "the yes in Telegram let it write")
        try await waitForSent { self.text($0).contains("✅") }
        try await waitForSent { self.text($0).contains("Geschreven") }

        // the same button again: already answered
        try await push(["callback_query": ["id": "q2", "from": ["id": 42, "is_bot": false, "first_name": "Mila"], "data": allow["callback_data"]!]])
        let late = try await waitForSent { $0["method"] as? String == "answerCallbackQuery" && $0["callback_query_id"] as? String == "q2" }
        XCTAssertNotNil(late["text"])
    }

    func testAdministratorRightsHaveNoButtons() async throws {
        let (service, bridge, _, store) = make()
        service.start()
        defer { service.stop() }
        try await pair(service)
        let id = bridge.conversation(for: service.accounts[0])
        var a = ChatClient.Approval(conversation: id, call: ToolCall(id: "c", name: "system_change", arguments: "{}"),
                                    title: "Firewall aan", detail: "")
        a.admin = true
        bridge.approval(a, isTask: false)
        let card = try await waitForSent { self.text($0).contains("Firewall aan") }
        XCTAssertNil(card["reply_markup"], "no buttons for administrator rights")
        XCTAssertTrue(text(card).contains("Mac"))
        _ = store
    }

    func testTasksReportToTheFirstAccount() async throws {
        let (service, bridge, _, _) = make()
        Settings.shared.telegramNotify = true
        service.start()
        defer { service.stop() }
        try await pair(service)
        bridge.notify("Taak klaar: Agenda", "Om 10:00 tandarts.")
        let m = try await waitForSent { self.text($0).contains("Taak klaar: Agenda") }
        XCTAssertEqual(m["chat_id"] as? Int, 42)
        Settings.shared.telegramNotify = false
        bridge.notify("Taak klaar: Stil", "")
        try await Task.sleep(for: .seconds(0.5))
        let after = try await sent()
        XCTAssertFalse(after.contains { self.text($0).contains("Stil") })
    }
}
