import XCTest
@testable import MacAIMagic

/// A skill larger than the conversation can hold, and the context a Mac with 32 GB gets for Qwen3.6.
final class SkillSizeTests: XCTestCase {
    private func bigSkill() -> Skill {
        var lines = ["# Start", "Read this first."]
        for i in 1...200 { lines.append("## Section \(i)"); lines.append(String(repeating: "x", count: 300)) }
        var s = Skill(name: "big", description: "a big one", platform: "macos", body: lines.joined(separator: "\n"))
        s.folder = URL(fileURLWithPath: "/tmp/skills/big")
        return s
    }

    func testALongSkillKeepsItsStartAndSaysWhereTheRestIs() {
        let s = bigSkill()
        XCTAssertGreaterThan(s.body.count, 60_000)
        let text = Skills.text(s, limit: 26_000)
        XCTAssertLessThan(text.count, 26_000 + 6_000, "the start plus the note and headings")
        XCTAssertTrue(text.contains("Read this first."))
        XCTAssertTrue(text.contains("/tmp/skills/big/SKILL.md"))
        XCTAssertTrue(text.contains("## Section 150"), "the headings of the part left out are listed")
        XCTAssertTrue(text.contains("more headings"))
        XCTAssertFalse(text.contains(String(repeating: "x", count: 300) + "\n## Section 200\n" + String(repeating: "x", count: 300)))
    }

    func testAShortSkillOrNoLimitIsWhole() {
        let s = bigSkill()
        XCTAssertEqual(Skills.text(s), Skills.text(s, limit: 1_000_000))
        XCTAssertFalse(Skills.text(s).contains("longer than this conversation"))
    }

    /// Qwen3.6's real KV (22.5 KB per token with its MTP layer) gives a Mac with 32 GB 32K of context again.
    func testQwen36On32GBGets32K() throws {
        var idx = GGUFIndex()
        idx.metadata["general.architecture"] = "qwen35moe"
        idx.metadata["qwen35moe.block_count"] = UInt32(41)
        idx.tensors = [GGUFIndex.Tensor(name: "token_embd.weight", bytes: 2_597_331_456)]
            + (0..<40).map { GGUFIndex.Tensor(name: "blk.\($0).ffn_up_exps.weight", bytes: (22_652_396_032 - 2_597_331_456) / 40) }
        let m = SystemInfo(chip: "Apple M1 Max", physicalMemory: 32 << 30, performanceCores: 8,
                           gpuWorkingSet: (32 << 30) * 2 / 3, wiredLimitMB: 0, freeDisk: 500_000_000_000)
        XCTAssertEqual(MemoryPlanner.contextRoom(index: idx, system: m, vision: false), 32_768)
    }
}

/// The portable build's folder and start values (the tests run as a normal app, so portable mode itself is off).
final class PortableTests: XCTestCase {
    func testTheDataFolderSitsNextToTheAppAndStartsOffline() {
        XCTAssertFalse(Portable.isActive)
        XCTAssertNil(Portable.dataRoot)
        let app = URL(fileURLWithPath: "/Volumes/KINGSTON/MacAIMagic Portable/MacAIMagic Portable.app")
        XCTAssertEqual(Portable.folder(nextTo: app).path, "/Volumes/KINGSTON/MacAIMagic Portable/MacAIMagic-data")
        let d = Portable.startDefaults(root: URL(fileURLWithPath: "/Volumes/KINGSTON/x/MacAIMagic-data"))
        for key in ["webSearch", "featureBrowser", "featureTelegram", "featureMail", "featureComputerUse", "heartbeat", "clusterAllowLAN"] {
            XCTAssertEqual(d[key] as? Bool, false, key)
        }
        XCTAssertEqual(d["port"] as? Int, 8090, "beside an installed MacAIMagic on 8080")
        XCTAssertEqual(d["workspace"] as? String, "/Volumes/KINGSTON/x/MacAIMagic-data/Werkmap")
        XCTAssertEqual(Portable.original(app), app, "a path that is not translocated stays as it is")
    }
}
