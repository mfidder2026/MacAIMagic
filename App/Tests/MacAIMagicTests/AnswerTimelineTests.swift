import XCTest
@testable import MacAIMagic

/// An answer of many rounds is one card with its parts in the order they came (the owner saw text jump away).
final class AnswerTimelineTests: XCTestCase {
    private func round(_ text: String, reasoning: String = "", steps: [String] = []) -> ChatMessage {
        var m = ChatMessage(role: .assistant, text: text)
        m.reasoning = reasoning
        m.activities = steps.map { ToolActivity(label: $0, done: true) }
        return m
    }

    func testQuestionsSplitAnswersAndAutomaticMessagesStayInside() {
        let q1 = ChatMessage(role: .user, text: "maak een spel")
        let go = ChatMessage(role: .user, text: "ga door", automatic: true)
        let q2 = ChatMessage(role: .user, text: "nog een")
        let items = ChatItem.group([q1, round("", reasoning: "plan", steps: ["Uitvoeren: cd"]), go, round("klaar"), q2, round("ja")])
        XCTAssertEqual(items.count, 4)
        guard case .answer(let rounds) = items[1] else { return XCTFail("geen antwoord") }
        XCTAssertEqual(rounds.count, 3, "the automatic go-on belongs to the answer")
        XCTAssertTrue(items[3].contains(items[3].id))
    }

    func testPartsAreChronological() {
        let rounds = [round("", reasoning: "eerst denken", steps: ["Uitvoeren: cd /Users"]),
                      round("Het werkt, nu de sprite.", reasoning: "tweede gedachte", steps: ["Schrijven: spook.txt"]),
                      round("KLAAR")]
        let parts = AnswerPart.of(rounds, streaming: false)
        let kinds = parts.map { p -> String in
            switch p {
            case .thought(_, let t, _): return "denk:" + t
            case .step(let a): return "stap:" + a.label
            case .text(_, let t): return "tekst:" + t
            default: return "?"
            }
        }
        XCTAssertEqual(kinds, ["denk:eerst denken", "stap:Uitvoeren: cd /Users", "denk:tweede gedachte",
                               "tekst:Het werkt, nu de sprite.", "stap:Schrijven: spook.txt", "tekst:KLAAR"])
        XCTAssertEqual(Set(parts.map(\.id)).count, parts.count, "ids are unique")
    }

    func testOnlyTheLastRoundThinksLive() {
        let parts = AnswerPart.of([round("", reasoning: "a", steps: ["x"]), round("", reasoning: "b")], streaming: true)
        let live = parts.compactMap { p -> Bool? in if case .thought(_, _, let l) = p { return l }; return nil }
        XCTAssertEqual(live, [false, true])
    }

    func testARoundWithOnlyThinkingAndStepsStaysVisible() {
        var m = round("", reasoning: "denk", steps: ["Uitvoeren: ls"])
        m.toolCalls = [ToolCall(id: "1", name: "run_command", arguments: "{}")]
        XCTAssertFalse(m.isHidden, "its thinking must not vanish once the tools ran")
    }

    func testGist() {
        XCTAssertEqual(PartView.gist("regel een\nregel twee", live: false), "regel een regel twee")
        XCTAssertEqual(PartView.gist(String(repeating: "a", count: 500) + "einde", live: true).suffix(5), "einde")
    }
}
