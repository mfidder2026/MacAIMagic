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
        // while thinking: the last lines one below the other, not one block that runs together
        XCTAssertEqual(PartView.gist("een\ntwee\n\n  drie\nvier\nvijf", live: true), "twee\ndrie\nvier\nvijf")
        // the line being written keeps its end, an earlier long one its start
        let live = PartView.gist(String(repeating: "b", count: 300) + "\n" + String(repeating: "a", count: 500) + "einde", live: true)
            .components(separatedBy: "\n")
        XCTAssertEqual(live[0].count, PartView.gistWidth)
        XCTAssertTrue(live[0].hasSuffix("…"))
        XCTAssertTrue(live[1].hasSuffix("einde"))
        XCTAssertEqual(live[1].count, PartView.gistWidth)
    }
}

/// DeepSeek thought 16,000 tokens before every step; only the first round of an answer gets the full budget.
final class FollowUpThinkingTests: XCTestCase {
    func testLaterRoundsThinkLess() {
        XCTAssertEqual(ChatClient.thinkingBudget(setting: 16_000, turn: 0), 16_000)
        XCTAssertEqual(ChatClient.thinkingBudget(setting: 16_000, turn: 1), ChatClient.followUpThinking)
        XCTAssertEqual(ChatClient.thinkingBudget(setting: 2_000, turn: 5), 2_000, "a smaller setting stays")
        XCTAssertEqual(ChatClient.thinkingBudget(setting: 0, turn: 0), 0, "no limit in the first round")
        XCTAssertEqual(ChatClient.thinkingBudget(setting: 0, turn: 3), ChatClient.followUpThinking)
    }
}

/// One thinking choice (off, low, normal, high) sets the switch, the effort and the budget, so it works for every model.
final class ThinkingLevelTests: XCTestCase {
    func testLevels() {
        let s = Settings.shared
        let saved = (s.thinking, s.reasoningEffort, s.thinkingBudget)
        defer { (s.thinking, s.reasoningEffort, s.thinkingBudget) = saved }
        s.thinkingBudget = 16_000
        s.thinkingLevel = .off
        XCTAssertFalse(s.thinking); XCTAssertEqual(s.thinkingLevel, .off); XCTAssertEqual(s.thinkingBudgetNow, 0)
        s.thinkingLevel = .low
        XCTAssertTrue(s.thinking); XCTAssertEqual(s.reasoningEffort, "low"); XCTAssertEqual(s.thinkingBudgetNow, 2_000)
        s.thinkingLevel = .normal
        XCTAssertEqual(s.reasoningEffort, "medium"); XCTAssertEqual(s.thinkingBudgetNow, 8_000)
        s.thinkingLevel = .high
        XCTAssertEqual(s.reasoningEffort, "high"); XCTAssertEqual(s.thinkingBudgetNow, 16_000)
        s.reasoningEffort = "max"
        XCTAssertEqual(s.thinkingLevel, .high, "max from Settings counts as high")
        s.thinkingLevel = .high
        XCTAssertEqual(s.reasoningEffort, "max", "choosing high again keeps max")
        XCTAssertEqual(ChatClient.thinkingBudget(setting: Settings.ThinkingLevel.low.budget!, turn: 3), 2_000)
    }
}

/// "ga door" on work under way thinks like a later round; a real new question keeps the full budget.
final class GoOnThinkingTests: XCTestCase {
    func testGoOnText() {
        for t in ["ga door", "Ga door!", "verder", "continue", "Go on.", "ga door graag", "mach weiter"] {
            XCTAssertTrue(ChatClient.isGoOnText(t), t)
        }
        for t in ["ga door met het spel maar maak de spookjes groter en sneller", "door welke deur?", "maak een spel", ""] {
            XCTAssertFalse(ChatClient.isGoOnText(t), t)
        }
    }

    func testOnlyAfterAnswerWithSteps() {
        var worked = ChatMessage(role: .assistant, text: "")
        worked.toolCalls = [ToolCall(id: "1", name: "run_command", arguments: "{}")]
        var c = Conversation()
        c.messages = [ChatMessage(role: .user, text: "maak een spel"), worked, ChatMessage(role: .assistant, text: "pauze"),
                      ChatMessage(role: .user, text: "ga door")]
        XCTAssertTrue(ChatClient.isGoOn(c))
        c.messages = [ChatMessage(role: .user, text: "hoi"), ChatMessage(role: .assistant, text: "hallo"),
                      ChatMessage(role: .user, text: "ga door")]
        XCTAssertFalse(ChatClient.isGoOn(c), "no work under way: a full first round")
    }
}
