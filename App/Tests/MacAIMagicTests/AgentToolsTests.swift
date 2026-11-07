import XCTest
import Speech
@testable import MacAIMagic

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

private func call(_ name: String, _ args: [String: Any]) -> ToolCall {
    ToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: try! JSONSerialization.data(withJSONObject: args), as: UTF8.self))
}

@MainActor
final class MailToolsTests: XCTestCase {
    func testAddressesAreChecked() {
        XCTAssertEqual(MailTools.addresses("a@b.nl, Piet <piet@example.com>"), ["a@b.nl", "Piet <piet@example.com>"])
        XCTAssertNil(MailTools.addresses("piet"))
        XCTAssertNil(MailTools.addresses(""))
        XCTAssertNil(MailTools.addresses("a@b.nl, geen adres"))
    }

    func testReadingRunsADraftAsksAndSendingAsksEveryTime() async {
        let mail = MailTools()
        let read = await mail.check(call("mail_list", [:]))
        XCTAssertEqual(read, .run)
        guard case .ask(_, let detail, let warnings, let everyTime) = await mail.check(call("mail_draft", ["to": "a@b.nl", "subject": "Hoi", "body": "Tekst"])) else {
            return XCTFail("a draft asks")
        }
        XCTAssertTrue(detail.contains("a@b.nl") && detail.contains("Hoi") && detail.contains("Tekst"))
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertFalse(everyTime)
        guard case .ask(_, _, let sendWarnings, let sendEvery) = await mail.check(call("mail_send", ["to": "a@b.nl", "subject": "Hoi", "body": "x"])) else {
            return XCTFail("sending asks")
        }
        XCTAssertTrue(sendEvery, "sending asks every time")
        XCTAssertFalse(sendWarnings.isEmpty)
        guard case .refuse = await mail.check(call("mail_send", ["to": "Piet", "subject": "Hoi", "body": "x"])) else { return XCTFail("no address") }
    }

    func testTheValuesGoInAsArgumentsNeverIntoTheScript() async {
        let mail = MailTools()
        var seen: (String, [String])?
        mail.runScript = { script, args in seen = (script, args); return ("ok", nil) }
        let evil = "\" & (do shell script \"rm -rf ~\") & \""
        _ = await mail.run(call("mail_send", ["to": "a@b.nl", "subject": evil, "body": "body"]))
        XCTAssertEqual(seen?.0, MailTools.composeScript, "the script itself is fixed")
        XCTAssertEqual(seen?.1, ["1", "a@b.nl", "", evil, "body"])
        _ = await mail.run(call("mail_search", ["query": "factuur", "days": 7]))
        XCTAssertEqual(seen?.1, ["7", "0", "25", "factuur"])
        mail.runScript = { _, _ in ("", "execution error: Not authorized to send Apple events to Mail. (-1743)") }
        let denied = await mail.run(call("mail_list", [:]))
        XCTAssertTrue(denied.contains("Automation"), denied)
    }

    func testTheScriptsCompile() throws {
        for script in [MailTools.listScript, MailTools.readScript, MailTools.composeScript] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
            let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".scpt")
            p.arguments = ["-o", out.path, "-"]
            let input = Pipe()
            p.standardInput = input
            p.standardError = FileHandle.nullDevice
            try p.run()
            input.fileHandleForWriting.write(Data(script.utf8))
            try input.fileHandleForWriting.close()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, String(script.prefix(80)))
            try? FileManager.default.removeItem(at: out)
        }
    }

    /// A mail that is sent asks again, also after "Altijd in dit gesprek".
    func testSendingAsksAgainAfterAlways() async throws {
        let port = Int.random(in: 52_100...53_900)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", fixtures.appendingPathComponent("fake_engine.py").path, String(port)]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        defer { p.terminate() }
        _ = out.fileHandleForReading.availableData
        let saved = Settings.shared.featureMail
        Settings.shared.featureMail = true
        defer { Settings.shared.featureMail = saved }
        var sent = 0
        MailTools.shared.runScript = { _, _ in sent += 1; return ("ok", nil) }
        defer { MailTools.shared.runScript = { await AgentTools.appleScript($0, $1) } }

        let store = ConversationStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        let c = Conversation()
        store.conversations = [c]
        let chat = ChatClient()
        let url = URL(string: "http://127.0.0.1:\(port)")!
        chat.send(text: "MAILSTUUR naar test", attachments: [], in: c.id, store: store, baseURL: url)
        try await waitUntil { chat.approvals[c.id] != nil }
        XCTAssertTrue(chat.approvals[c.id]!.everyTime)
        chat.answer(chat.approvals[c.id]!, allow: true, always: true)
        try await waitUntil { !chat.isBusy(c.id) }
        XCTAssertEqual(sent, 1)
        chat.send(text: "MAILSTUUR nog een", attachments: [], in: c.id, store: store, baseURL: url)
        try await waitUntil { chat.approvals[c.id] != nil }
        chat.answer(chat.approvals[c.id]!, allow: false)
        try await waitUntil { !chat.isBusy(c.id) }
        XCTAssertEqual(sent, 1, "the second mail asked again and was not sent")
    }
}

@MainActor
final class BrowserToolsTests: XCTestCase {
    func testOpenReadClickAndType() async throws {
        let browser = BrowserTools()
        browser.forTests = true
        let page = fixtures.appendingPathComponent("browser/index.html")
        let opened = await browser.run(call("browser_open", ["url": page.absoluteString]))
        XCTAssertTrue(opened.contains("Title: Testwinkel"), opened)
        XCTAssertTrue(opened.contains("Welkom bij de testwinkel"))
        func number(_ label: String) throws -> Int {
            let line = try XCTUnwrap(opened.split(separator: "\n").first { $0.contains("\"\(label)\"") }, label)
            return Int(line.dropFirst().prefix { $0.isNumber })!
        }
        let password = try number("Wachtwoord"), card = try number("Kaartnummer")
        XCTAssertTrue(opened.contains("password or payment field"))

        // never a password or card field
        for n in [password, card] {
            guard case .refuse = await browser.check(call("browser_type", ["element": n, "text": "geheim"])) else { return XCTFail("typed into a secret field") }
        }
        // a link runs, a button asks, a buying button asks every time
        let link = await browser.check(call("browser_click", ["element": try number("Over ons")]))
        XCTAssertEqual(link, .run)
        guard case .ask(_, _, let w, let every) = await browser.check(call("browser_click", ["element": try number("Meer tonen")])) else { return XCTFail() }
        XCTAssertTrue(w.isEmpty && !every)
        guard case .ask(_, _, let w2, let every2) = await browser.check(call("browser_click", ["element": try number("Nu kopen")])) else { return XCTFail() }
        XCTAssertFalse(w2.isEmpty)
        XCTAssertTrue(every2)

        let shown = await browser.run(call("browser_click", ["element": try number("Meer tonen")]))
        XCTAssertTrue(shown.contains("Getoond!"), shown)

        // typing runs, sending the form asks
        let search = try number("Zoeken")
        let typed = await browser.check(call("browser_type", ["element": search, "text": "fiets"]))
        XCTAssertEqual(typed, .run)
        guard case .ask = await browser.check(call("browser_type", ["element": search, "text": "fiets", "submit": true])) else { return XCTFail("submit asks") }
        _ = await browser.run(call("browser_type", ["element": search, "text": "fiets"]))
        let after = await browser.run(call("browser_read", [:]))
        XCTAssertTrue(after.contains("= \"fiets\""), after)

        let next = await browser.run(call("browser_click", ["element": try number("Over ons")]))
        XCTAssertTrue(next.contains("Title: Over ons"), next)
        let back = await browser.run(call("browser_back", [:]))
        XCTAssertTrue(back.contains("Title: Testwinkel"), back)
        guard case .refuse = await browser.check(call("browser_open", ["url": "javascript:alert(1)"])) else { return XCTFail("only web addresses") }
    }
}

@MainActor
final class ComputerToolsTests: XCTestCase {
    func testKeys() {
        XCTAssertEqual(ComputerTools.keyCode("return")?.0, 36)
        let save = ComputerTools.keyCode("cmd+s")
        XCTAssertEqual(save?.0, 1)
        XCTAssertEqual(save?.1, .maskCommand)
        XCTAssertEqual(ComputerTools.keyCode("cmd+shift+n")?.1, [.maskCommand, .maskShift])
        XCTAssertNil(ComputerTools.keyCode("cmd+q"), "never quit an app")
        XCTAssertNil(ComputerTools.keyCode("hyper+x"))
        XCTAssertNil(ComputerTools.keyCode("f13"))
    }

    func testOnlyAllowedAppsAndNeverThePasswordApps() async {
        let saved = Settings.shared.computerApps
        defer { Settings.shared.computerApps = saved }
        Settings.shared.computerApps = "com.apple.TextEdit\ncom.apple.keychainaccess"
        let tools = ComputerTools()
        XCTAssertEqual(tools.allowed, ["com.apple.TextEdit"], "the keychain never, whatever the list says")
        tools.allow("com.apple.Passwords")
        XCTAssertFalse(tools.allowed.contains("com.apple.Passwords"))
        XCTAssertEqual(tools.resolve("com.apple.textedit"), "com.apple.TextEdit")
        guard case .refuse = await tools.check(call("computer_look", ["app": "com.apple.Notes"])) else { return XCTFail("not allowed") }
        let look = await tools.check(call("computer_look", ["app": "com.apple.TextEdit"]))
        XCTAssertEqual(look, .run)
        guard case .refuse = await tools.check(call("computer_click", ["app": "com.apple.TextEdit", "element": 3])) else { return XCTFail("look first") }
        guard case .ask(_, _, let w, let every) = await tools.check(call("computer_key", ["app": "com.apple.TextEdit", "keys": "return"])) else { return XCTFail() }
        XCTAssertTrue(every && !w.isEmpty, "return can send something")
    }
}

final class VoiceTests: XCTestCase {
    func testWhatIsReadAloud() {
        let text = Voice.speakable("## Kop\nDit is **vet** en [een link](https://x.nl).\n```\ncode\n```\n| a | b |\n|---|---|\nZie https://example.com")
        XCTAssertFalse(text.contains("*") || text.contains("#") || text.contains("code") || text.contains("https") || text.contains("---"))
        XCTAssertTrue(text.contains("Dit is vet en een link."), text)
    }

    /// A spoken sentence as Ogg/Opus (Telegram's format) becomes text: with SpeechAnalyzer on macOS 26 and later,
    /// else only where speech recognition is allowed for the test runner.
    func testAVoiceMessageBecomesText() async throws {
        // speech recognition stops a process without the usage text in its Info.plist: only the app has it
        try XCTSkipUnless(Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil
                          && SFSpeechRecognizer.authorizationStatus() == .authorized, "only in the app: the test runner has no speech permission")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let aiff = dir.appendingPathComponent("s.aiff"), ogg = dir.appendingPathComponent("s.ogg")
        for (tool, args) in [("/usr/bin/say", ["-v", "Samantha", "-o", aiff.path, "What is the weather tomorrow"]),
                             ("/usr/bin/afconvert", ["-f", "Oggf", "-d", "opus@48000", aiff.path, ogg.path])] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, tool)
        }
        let heard = await Voice.transcribe(ogg, locale: Locale(identifier: "en-US"))
        XCTAssertTrue((heard.text ?? "").lowercased().contains("weather"), heard.text ?? heard.error ?? "")
    }
}
