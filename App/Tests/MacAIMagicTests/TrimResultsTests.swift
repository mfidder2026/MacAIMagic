import XCTest
@testable import MacAIMagic

/// A full conversation whose old tool results take most of the room: those are trimmed to their start and end
/// instead of summarizing the conversation.
@MainActor
final class TrimResultsTests: XCTestCase {
    func conversation(results: Int, size: Int) -> Conversation {
        var c = Conversation()
        c.messages.append(ChatMessage(role: .user, text: "Bouw het spel"))
        for n in 0..<results {
            c.messages.append(ChatMessage(role: .assistant, text: "", toolCalls: [.init(id: "r\(n)", name: "read_file", arguments: "{}")]))
            c.messages.append(ChatMessage(role: .tool, text: "begin \(n) " + String(repeating: "x", count: size) + " einde \(n)", toolCallId: "r\(n)"))
        }
        return c
    }

    func testOldLongResultsAreTrimmedInsteadOfSummarized() throws {
        let store = ConversationStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        let chat = ChatClient()
        chat.contextLimit = 65_536
        // 12 results of 15,000 characters: about 60K tokens, the context is full
        var c = conversation(results: 12, size: 15_000)
        c.contextTokens = 60_000
        store.conversations = [c]
        XCTAssertTrue(chat.trimOldResults(c.id, store: store, used: 60_000))
        let after = store.conversations[0]
        let tools = after.messages.filter { $0.role == .tool }
        // the last 8 messages (4 results) stay whole; the 8 before them are trimmed
        XCTAssertEqual(tools.map { $0.trimmed == true }, Array(repeating: true, count: 8) + Array(repeating: false, count: 4))
        XCTAssertNil(after.contextTokens)
        // the text in the chat stays whole; the model gets the start and the end
        XCTAssertEqual(tools[0].text.count, 15_000 + "begin 0 ".count + " einde 0".count)
        let sent = chat.requestMessages(after.messages).filter { $0["role"] as? String == "tool" }.map { $0["content"] as? String ?? "" }
        XCTAssertTrue(sent[0].hasPrefix("begin 0 ") && sent[0].hasSuffix(" einde 0"))
        XCTAssertLessThan(sent[0].count, 1_200)
        XCTAssertEqual(sent[11].count, tools[11].text.count)
        // a second time there is nothing left to trim
        XCTAssertFalse(chat.trimOldResults(c.id, store: store, used: 60_000))
    }

    func testAConversationOfTalkIsSummarizedAsBefore() {
        let store = ConversationStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        let chat = ChatClient()
        chat.contextLimit = 65_536
        // short results: trimming would not bring it to half the context
        let c = conversation(results: 12, size: 300)
        store.conversations = [c]
        XCTAssertFalse(chat.trimOldResults(c.id, store: store, used: 60_000))
        XCTAssertTrue(store.conversations[0].messages.allSatisfy { $0.trimmed == nil })
    }
}
