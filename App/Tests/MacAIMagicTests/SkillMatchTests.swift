import XCTest
@testable import MacAIMagic

/// A small model (Ministral-3-8B) did not load the owner's C64 skill for a C64 question: the app loads a skill itself
/// when the question is clearly about it.
final class SkillMatchTests: XCTestCase {
    private let c64 = Skill(name: "c64-basic-v2",
                            description: "Commodore 64 BASIC V2 programmeren: harde regels, tokentabel, verboden statements, vaste patronen voor scherm/sprites/SID/invoer, plus de geteste toolchain (syntax checker en .bas→.prg compiler) en het VICE-pad. Laden zodra er C64 BASIC-code geschreven, gecontroleerd of gecompileerd moet worden.",
                            platform: "macos", body: "# C64")
    private let dock = Skill(name: "appearance-dock", description: "Dark mode, accent colour, the Dock: position, size, hiding, apps in it.",
                             platform: "macos", body: "# Dock")

    func testTheOwnersQuestionLoadsTheC64Skill() {
        let q = "Je bent een commodore 64 basic programmeur en je gaat een gave tekstadventure maken voor de commodore 64 in basic v2. Als intro vliegt er een spookje door het scherm met enge muziek. Zoek op internet naar gave teksten, sprites en gameplay."
        XCTAssertEqual(Skills.matching(q, in: [dock, c64]).map(\.name), ["c64-basic-v2"])
        XCTAssertEqual(Skills.matching("Schrijf een C64 BASIC programma met een sprite", in: [c64]).map(\.name), ["c64-basic-v2"])
    }

    func testOtherQuestionsDoNot() {
        XCTAssertTrue(Skills.matching("Wat is het weer morgen in Amsterdam?", in: [c64, dock]).isEmpty)
        XCTAssertTrue(Skills.matching("Leg uit hoe BASIC werkt", in: [c64]).isEmpty, "one word is not enough")
        XCTAssertTrue(Skills.matching("Zet het scherm op donker", in: [c64, dock]).isEmpty)
    }
}
