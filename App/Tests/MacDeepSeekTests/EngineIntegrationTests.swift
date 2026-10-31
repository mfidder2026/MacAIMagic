import XCTest
@testable import MacDeepSeek

/// Runs the app's own chat loop (streaming, tool calls, web search) against a running engine.
/// Set MACDEEPSEEK_ENGINE_TEST=1 with the engine on 127.0.0.1:8080.
@MainActor
final class EngineIntegrationTests: XCTestCase {
    func testWebSearchLoop() async throws {
        guard ProcessInfo.processInfo.environment["MACDEEPSEEK_ENGINE_TEST"] == "1" else { throw XCTSkip("no engine") }
        Settings.shared.webSearch = true
        Settings.shared.thinking = false
        let store = ConversationStore()
        store.conversations = [Conversation()]
        let id = store.conversations[0].id
        let chat = ChatClient()
        chat.send(text: "Zoek op wat de nieuwste versie van llama.cpp is en noem de bron.", attachments: [], in: id,
                  store: store, baseURL: URL(string: "http://127.0.0.1:8080")!)
        let start = Date()
        while chat.busy && Date().timeIntervalSince(start) < 900 { try await Task.sleep(for: .milliseconds(500)) }

        let msgs = store.conversations[0].messages
        for m in msgs {
            print("[\(m.role)] calls=\(m.toolCalls.map(\.name)) text=\(m.text.prefix(300).replacingOccurrences(of: "\n", with: " "))")
        }
        let final = try XCTUnwrap(msgs.last)
        XCTAssertNil(final.error)
        XCTAssertTrue(msgs.contains { $0.role == .tool }, "the model should have searched")
        XCTAssertFalse(final.text.isEmpty)
        XCTAssertFalse(final.sources.isEmpty, "the answer should carry its sources")
        print("tok/s:", final.tokensPerSecond ?? 0, "sources:", final.sources.map(\.url))
    }
}
