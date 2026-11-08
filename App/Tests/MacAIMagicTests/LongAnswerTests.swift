import XCTest
@testable import MacAIMagic

/// A model that plans aloud must not fill its context and start over, and the engine must be able to reuse the
/// conversation it already read.
final class LongAnswerTests: XCTestCase {
    func testACutOffAnswerComesBackAsItsStartAndEnd() {
        let text = String(repeating: "a", count: 3000) + String(repeating: "b", count: 100_000) + String(repeating: "c", count: 3000)
        let short = ChatClient.shortened(text)
        XCTAssertLessThan(short.count, 6500)
        XCTAssertTrue(short.hasPrefix(String(repeating: "a", count: 3000)))
        XCTAssertTrue(short.hasSuffix(String(repeating: "c", count: 3000)))
        XCTAssertFalse(short.contains("b"))
    }

    func testAShortAnswerStaysWhole() {
        XCTAssertEqual(ChatClient.shortened("kort antwoord"), "kort antwoord")
    }

    @MainActor func testOneAnswerTakesAQuarterOfTheContextAtMost() {
        let chat = ChatClient()
        chat.contextLimit = 65_536
        XCTAssertEqual(chat.maxAnswerTokens, 16_384)
        chat.contextLimit = 8192
        XCTAssertEqual(chat.maxAnswerTokens, 4096)
    }

    /// The engine reads the whole conversation again when the tool definitions come in another key order; Swift's
    /// dictionaries give a different order from one request to the next (measured: 3 orders in 50 requests).
    func testToolDefinitionsAlwaysSerializeTheSame() throws {
        var seen = Set<Data>()
        for _ in 0..<50 {
            let body: [String: Any] = ["tools": WorkspaceTools.definitions, "messages": [["role": "user", "content": "hoi"]]]
            seen.insert(try JSONSerialization.data(withJSONObject: body, options: .sortedKeys))
        }
        XCTAssertEqual(seen.count, 1)
    }
}

final class LongMessageViewTests: XCTestCase {
    func testAVeryLongMessageShowsItsStartAndEnd() throws {
        let lines = (1...5000).map { "regel \($0) van het plan" }
        let f = try XCTUnwrap(MessageRow.folded(lines.joined(separator: "\n")))
        XCTAssertTrue(f.head.hasPrefix("regel 1 van"))
        XCTAssertTrue(f.tail.hasSuffix("regel 5000 van het plan"))
        XCTAssertFalse(f.head.hasSuffix("\n"))
        XCTAssertGreaterThan(f.hidden, 100_000)
        XCTAssertLessThanOrEqual(f.head.count + f.tail.count, 8000)
    }

    func testAnOrdinaryAnswerIsNotFolded() {
        XCTAssertNil(MessageRow.folded(String(repeating: "x", count: 5000)))
    }
}
