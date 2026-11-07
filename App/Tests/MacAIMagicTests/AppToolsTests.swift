import XCTest
@testable import MacAIMagic

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

/// A stand-in for the app: it says what it did.
@MainActor
private final class FakeApp: AppControlling {
    var ran: [String] = []
    var done: [String] = []
    private var waiting: [UUID: [String]] = [:]
    func status() -> String { "MacAIMagic test, engine running" }
    var settingNames: [String] { ["thinking (true/false)"] }
    func plan(_ action: String, _ args: [String: Any]) -> AppActionPlan {
        action == "stop_engine" ? AppActionPlan(title: "Engine stoppen", afterAnswer: true) : AppActionPlan(error: "Unknown action.")
    }
    func run(_ action: String, _ args: [String: Any], conversation: UUID) async -> String {
        ran.append(action)
        waiting[conversation, default: []].append(action)
        return "Approved. This happens as soon as your answer is done."
    }
    func answerDone(_ conversation: UUID) { done += waiting.removeValue(forKey: conversation) ?? [] }
}

@MainActor
final class AppToolsTests: XCTestCase {
    func testHelpListsAndFinds() {
        let list = AppTools.help(ToolCall(id: "1", name: "app_help", arguments: "{}"))
        XCTAssertTrue(list.contains("- skills:") || list.contains("skills"), list.prefix(300).description)
        let found = AppTools.help(ToolCall(id: "1", name: "app_help", arguments: #"{"query":"heartbeat checklist"}"#))
        XCTAssertTrue(found.hasPrefix("# "), found.prefix(80).description)
        XCTAssertTrue(found.contains("(topic tasks)"), found.prefix(120).description)
    }

    func testSkillsGoToTheUsersFolder() throws {
        XCTAssertEqual(AppTools.skillName(" C64 Assembler! "), "c64-assembler")
        XCTAssertNil(AppTools.skillName("!!!"))
        let call = ToolCall(id: "1", name: "create_skill", arguments: #"{"name":"C64 Assembler","description":"Assembler voor de C64\nmet ACME","instructions":"Gebruik acme -f cbm."}"#)
        let skill = try XCTUnwrap(AppTools.skill(call))
        XCTAssertEqual(skill.name, "c64-assembler")
        XCTAssertTrue(skill.text.hasPrefix("---\nname: c64-assembler\ndescription: Assembler voor de C64 met ACME\nplatform: macos\n---\n"), skill.text)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("skills-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertNil(AppTools.replaces("c64-assembler", userFolder: folder))
        let file = try AppTools.writeSkill(skill.name, skill.text, userFolder: folder)
        XCTAssertEqual(AppTools.replaces("c64-assembler", userFolder: folder), "own")
        let loaded = Skills.load(from: [folder])
        XCTAssertEqual(loaded.map(\.name), ["c64-assembler"], "the skill list reads it: \(file.path)")
        XCTAssertNil(AppTools.skill(ToolCall(id: "1", name: "create_skill", arguments: #"{"name":"x","description":"y","instructions":""}"#)))
        XCTAssertEqual(AppTools.replaces("energie", userFolder: folder), Paths.bundledSkills == nil ? nil : "builtin")
    }

    func testOnlyTheseSettingsAndTheirValues() {
        XCTAssertNotNil(AppControl.setting("Thinking"))
        XCTAssertNil(AppControl.setting("rightWrite"), "its own rights stay the user's")
        XCTAssertNil(AppControl.setting("apiKey"))
        XCTAssertNil(AppControl.setting("port"))
        XCTAssertNil(AppControl.setting("modelFolder"))
        XCTAssertEqual(AppControl.setting("contextSize")?.setting.options?.first, "32768")
        let saved = Settings.shared.thinking
        defer { Settings.shared.thinking = saved }
        XCTAssertTrue(AppControl.setting("thinking")!.setting.set("uit"))
        XCTAssertFalse(Settings.shared.thinking)
        XCTAssertFalse(AppControl.setting("thinking")!.setting.set("misschien"))
    }

    /// The chat client asks first and runs an action that stops the engine only once the answer is done.
    func testAnActionThatStopsTheEngineWaitsForTheAnswer() async throws {
        let port = Int.random(in: 48_100...49_900)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", fixtures.appendingPathComponent("fake_engine.py").path, String(port)]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        defer { p.terminate() }
        XCTAssertTrue(String(decoding: out.fileHandleForReading.availableData, as: UTF8.self).contains("READY"))
        let s = Settings.shared
        let saved = (s.appTools, s.rightSystemChange)
        defer { (s.appTools, s.rightSystemChange) = saved }
        (s.appTools, s.rightSystemChange) = (true, "ask")

        let store = ConversationStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        let c = Conversation()
        store.conversations = [c]
        let app = FakeApp()
        let chat = ChatClient()
        chat.appControl = app
        chat.send(text: "APPACTIE stop de engine", attachments: [], in: c.id, store: store, baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        try await waitUntil { chat.approvals[c.id] != nil }
        XCTAssertEqual(chat.approvals[c.id]?.title, "Engine stoppen")
        XCTAssertEqual(app.ran, [], "nothing before the card")
        chat.answer(try XCTUnwrap(chat.approvals[c.id]), allow: true)
        try await waitUntil { !chat.isBusy(c.id) }
        XCTAssertEqual(app.ran, ["stop_engine"])
        XCTAssertEqual(app.done, ["stop_engine"], "it ran once the answer was done")
    }
}
