import XCTest
@testable import MacAIMagic

/// A small model (Ling-3.0-tiny) repeated one line until its token limit in 4 of 12 sections on the Windows version's
/// test PC. Documents stops such a section and keeps one copy of the line. The same test names as on Windows.
final class LoopGuardTests: XCTestCase {
    static let loop = "- De werknemer die niet in aanmerking komt, kan dit doorgeven aan de HR-afdeling.\n"

    func testALineThatComesThreeTimesIsALoop() throws {
        let text = "Intro van de sectie.\n" + Self.loop + Self.loop + Self.loop + Self.loop
        let at = try XCTUnwrap(LocalModel.loopStart(text))
        XCTAssertEqual(String(text[..<at]), "Intro van de sectie.\n" + Self.loop)
    }

    func testOrdinaryTextIsNoLoop() {
        XCTAssertNil(LocalModel.loopStart("Een.\nTwee regels die verschillen van elkaar.\nDrie regels die ook weer anders zijn.\n"))
        // short lines repeat in ordinary text (table rules, "Ja", empty list items)
        XCTAssertNil(LocalModel.loopStart("| --- | --- |\n| a | b |\n| --- | --- |\n| c | d |\n| --- | --- |\n"))
        // twice is still allowed: a summary may repeat a sentence once
        XCTAssertNil(LocalModel.loopStart(Self.loop + "Iets anders dat lang genoeg is om mee te tellen.\n" + Self.loop))
    }
}
