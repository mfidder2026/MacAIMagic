import XCTest
@testable import MacAIMagic

/// Qwen's template keeps the model's earlier thinking (Qwen3.8 for the whole conversation, Qwen3.6 since the last question)
/// and knows low, medium and high/xhigh only.
@MainActor
final class QwenRequestTests: XCTestCase {
    func history() -> [ChatMessage] {
        var step = ChatMessage(role: .assistant, text: "", toolCalls: [.init(id: "a", name: "list_dir", arguments: "{}")])
        step.reasoning = "Eerst kijken wat er in de map staat."
        var cut = ChatMessage(role: .assistant, text: String(repeating: "x", count: 10))
        cut.reasoning = "Lang nagedacht"
        cut.cutOff = true
        var answer = ChatMessage(role: .assistant, text: "Klaar.")
        answer.reasoning = "De map is leeg."
        return [ChatMessage(role: .user, text: "Wat staat er?"), step,
                ChatMessage(role: .tool, text: "(leeg)", toolCallId: "a"), answer, cut]
    }

    func testEarlierThinkingGoesBackWhenKept() {
        let chat = ChatClient()
        let sent = chat.requestMessages(history(), keepThinking: true).filter { $0["role"] as? String == "assistant" }
        XCTAssertEqual(sent.map { $0["reasoning_content"] as? String },
                       ["Eerst kijken wat er in de map staat.", "De map is leeg.", nil], "a cut-off answer goes back shortened, without its thinking")
        let plain = chat.requestMessages(history()).filter { $0["role"] as? String == "assistant" }
        XCTAssertTrue(plain.allSatisfy { $0["reasoning_content"] == nil })
    }

    func testAnOlderConversationKeepsSendingEmptyThinking() throws {
        // a conversation saved by 1.14.13 has no thinkingKept: it stays as the engine read it
        let old = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(Conversation()))
        XCTAssertEqual(old.thinkingKept, true)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(Conversation())) as? [String: Any])
        json["thinkingKept"] = nil
        let before = try JSONDecoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(before.thinkingKept)
    }

    func testMaximaalBecomesHighForQwen() {
        let saved = (Settings.shared.reasoningEffort, Settings.shared.thinking)
        defer { (Settings.shared.reasoningEffort, Settings.shared.thinking) = saved }
        (Settings.shared.reasoningEffort, Settings.shared.thinking) = ("max", true)
        XCTAssertEqual(ChatClient.templateKwargs(qwen: true)["reasoning_effort"] as? String, "high")
        XCTAssertEqual(ChatClient.templateKwargs()["reasoning_effort"] as? String, "max")
        // the thinking of earlier questions stays out (Qwen3.8 keeps it all by default)
        XCTAssertEqual(ChatClient.templateKwargs(qwen: true)["preserve_thinking"] as? Bool, false)
        XCTAssertNil(ChatClient.templateKwargs()["preserve_thinking"])
    }
}
