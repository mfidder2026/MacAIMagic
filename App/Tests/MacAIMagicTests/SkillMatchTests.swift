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

    /// The owner's two C64 skills as they are in the skills folder (2026-11-10).
    private let basic = Skill(name: "c64-basic-v2",
                              description: "Commodore 64 BASIC V2 programmeren: harde regels, tokentabel, verboden statements, patronen voor scherm/sprites/SID/invoer, geteste toolchain (syntax checker, bas2prg.py -i, c64sprite.py) en c64run.py-testrooster, plus alle lessen uit de spellen spookkasteel (nov 2026).",
                              platform: "macos", body: "# BASIC")
    private let kick = Skill(name: "c64-kickassembler",
                             description: "Commodore 64 Assembler-programmeren met Kick Assembler 5.x op macOS: 12+1 harde regels, geteste toolchain (KickAss.jar, syntax checker, build.sh, VICE-c64run.py), 21 recepten en 28 praktijklessen uit C64_KICKASS_SKILL.md.",
                             platform: "macos", body: "# Kick")

    /// "commodore 64 assembler programmeur" never found the assembler skill: its name says "c64" and "kickassembler".
    func testAnAssemblerQuestionLoadsTheAssemblerSkill() {
        let skills = [dock, basic, kick]
        let assembler = "Je bent een commodore 64 assembler programmeur en je gaat een gave tekstadventure maken voor de commodore 64. Het spel speelt zich af in een spookkasteel met vampieren."
        XCTAssertEqual(Skills.matching(assembler, in: skills).map(\.name), ["c64-kickassembler"])
        XCTAssertEqual(Skills.matching("Schrijf in Kick Assembler een raster-effect voor de C64", in: skills).map(\.name), ["c64-kickassembler"])
        XCTAssertEqual(Skills.matching("Je bent een commodore 64 kickassembler programmeur, maak een intro met muziek", in: skills).map(\.name), ["c64-kickassembler"])
        // a BASIC question still gets only the BASIC skill, although both share c64 and commodore
        let old = "Je bent een commodore 64 basic programmeur en je gaat een gave tekstadventure maken voor de commodore 64 in basic v2. Als intro vliegt er een spookje door het scherm met enge muziek."
        XCTAssertEqual(Skills.matching(old, in: skills).map(\.name), ["c64-basic-v2"])
        // the owner's question of 15:02 asks for both (assembler and "in basic v2"): both load, the model gets to choose
        let both = "Je bent een commodore 64 assembler programmeur en je gaat een gave tekstadventure maken voor de commodore 64 in basic v2. Het spel speelt zich af in een spookkasteel met vampieren."
        XCTAssertEqual(Set(Skills.matching(both, in: skills).map(\.name)), ["c64-basic-v2", "c64-kickassembler"])
        XCTAssertTrue(Skills.matching("Leg uit hoe assembler werkt", in: skills).isEmpty, "one word is not enough")
    }

    /// The same with every skill the app has (the built-in ones and the skills folder): none of them takes "basic" or
    /// "assembler" away.
    func testWithAllSkillsTheRightC64SkillLoads() {
        let skills = Skills.all.filter { !$0.name.hasPrefix("c64") } + [basic, kick]
        XCTAssertEqual(Skills.matching("Je bent een commodore 64 assembler programmeur en je gaat een gave tekstadventure maken voor de commodore 64.", in: skills).map(\.name), ["c64-kickassembler"])
        XCTAssertEqual(Skills.matching("Schrijf een C64 BASIC programma met een sprite", in: skills).map(\.name), ["c64-basic-v2"])
    }

    func testTwoWordsTogetherCountAsTheirName() {
        let w = Skills.questionWords("Een Commodore 64 met Kick Assembler, of een Amiga 500")
        XCTAssertTrue(w.isSuperset(of: ["c64", "kickassembler", "a500", "commodore", "64"]))
    }

    func testOtherQuestionsDoNot() {
        XCTAssertTrue(Skills.matching("Wat is het weer morgen in Amsterdam?", in: [c64, dock]).isEmpty)
        XCTAssertTrue(Skills.matching("Leg uit hoe BASIC werkt", in: [c64]).isEmpty, "one word is not enough")
        XCTAssertTrue(Skills.matching("Zet het scherm op donker", in: [c64, dock]).isEmpty)
    }
}
