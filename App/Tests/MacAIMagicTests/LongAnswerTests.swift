import XCTest
import SwiftUI
import AppKit
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

/// While a C64 task ran, the chat scrolled into empty space (2026-11-10): the live answer card showed its last 14 parts
/// in full, three rounds of assembler code made it 8,876 points high (more than macOS draws in one view), and it shrank
/// by thousands of points when a text left those 14 or the answer finished.
@MainActor final class LiveCardHeightTests: XCTestCase {
    private func code(lines: Int) -> String {
        "Hier is de code:\n\n```asm\n" + (1...lines).map { String(format: "        lda #$%02x          ; regel %d van de intro", $0 % 256, $0) }.joined(separator: "\n") + "\n```"
    }

    private func height(_ rounds: [ChatMessage], streaming: Bool) -> CGFloat {
        let v = NSHostingView(rootView: AnswerView(rounds: rounds, streaming: streaming).frame(width: 860))
        v.frame = NSRect(x: 0, y: 0, width: 860, height: 100)
        v.layoutSubtreeIfNeeded()
        return v.fittingSize.height
    }

    private func rounds(_ n: Int, lines: Int) -> [ChatMessage] {
        (0..<n).map { _ in
            var m = ChatMessage(role: .assistant, text: code(lines: lines))
            m.reasoning = "Ik denk na over de volgende stap."
            m.activities = [ToolActivity(label: "Schrijven: intro.asm", done: true), ToolActivity(label: "Uitvoeren: build.sh", done: true)]
            return m
        }
    }

    func testOnlyTheNewestTextIsShownWholeWhileTheModelWorks() {
        for lines in [200, 330] {      // ~10,000 characters (not folded) and ~16,700 (folded)
            let one = height(rounds(1, lines: lines), streaming: true)
            let six = height(rounds(6, lines: lines), streaming: true)
            let done = height(rounds(6, lines: lines), streaming: false)
            print("LIVE \(lines) lines: one round \(one), six rounds \(six), finished \(done)")
            XCTAssertGreaterThan(one, 2000, "the newest text is there in full")
            XCTAssertLessThan(six, one + 1200, "earlier texts are a few lines each")
            XCTAssertLessThan(abs(six - done), 1200, "finishing does not shrink the card by thousands of points")
        }
    }

    func testAPreviewIsTheFirstLinesWithoutTheCodeFence() throws {
        let p = try XCTUnwrap(PartView.preview(code(lines: 50)))
        XCTAssertEqual(p.shown.components(separatedBy: "\n").count, PartView.previewLines)
        XCTAssertTrue(p.shown.hasPrefix("Hier is de code:"))
        XCTAssertFalse(p.shown.contains("```"))
        XCTAssertNil(PartView.preview("Kort."))
    }
}

/// The chat went blank while the model worked: the visible area had ended below the messages.
final class PastTheEndTests: XCTestCase {
    func testABlankViewIsPastTheEnd() {
        // 800 points of view, 5,000 of messages
        XCTAssertFalse(ChatView.isPastTheEnd(visibleTop: 4200, visibleHeight: 800, contentHeight: 5000), "at the end")
        XCTAssertFalse(ChatView.isPastTheEnd(visibleTop: 1000, visibleHeight: 800, contentHeight: 5000), "scrolled up")
        XCTAssertFalse(ChatView.isPastTheEnd(visibleTop: 4300, visibleHeight: 800, contentHeight: 5000), "a bounce at the end")
        XCTAssertFalse(ChatView.isPastTheEnd(visibleTop: -60, visibleHeight: 800, contentHeight: 300), "a short chat")
        XCTAssertTrue(ChatView.isPastTheEnd(visibleTop: 5000, visibleHeight: 800, contentHeight: 5000), "nothing in view")
        XCTAssertTrue(ChatView.isPastTheEnd(visibleTop: 7200, visibleHeight: 800, contentHeight: 5000), "far below")
        XCTAssertTrue(ChatView.isPastTheEnd(visibleTop: 4920, visibleHeight: 800, contentHeight: 5000), "one line left")
    }
}
