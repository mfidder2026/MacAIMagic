import XCTest
@testable import MacAIMagic

final class SkillsTests: XCTestCase {
    func testParseFrontMatter() throws {
        let s = try XCTUnwrap(Skills.parse("---\nname: dock\ndescription: \"Dock settings\"\nplatform: macos\n---\n\nUse defaults.\n", fallbackName: "x"))
        XCTAssertEqual(s, Skill(name: "dock", description: "Dock settings", platform: "macos", body: "Use defaults."))
        // no front matter: the folder's name, for every platform
        let plain = try XCTUnwrap(Skills.parse("Just text", fallbackName: "folder"))
        XCTAssertEqual(plain.name, "folder")
        XCTAssertEqual(plain.platform, "all")
        XCTAssertNil(Skills.parse("---\nname: empty\n---\n", fallbackName: "x"))
    }

    func testUserSkillReplacesBuiltInAndPlatformFilters() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        func write(_ folder: String, _ name: String, _ text: String) throws {
            let d = tmp.appendingPathComponent(folder).appendingPathComponent(name)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try text.write(to: d.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        try write("builtin", "dock", "---\nname: dock\ndescription: built in\nplatform: macos\n---\nA")
        try write("builtin", "win", "---\nname: win\nplatform: windows\n---\nB")
        try write("user", "mydock", "---\nname: Dock\ndescription: mine\n---\nC")
        let skills = Skills.load(from: [tmp.appendingPathComponent("builtin"), tmp.appendingPathComponent("user")])
        XCTAssertEqual(skills.map(\.description), ["mine"])
        XCTAssertTrue(Skills.run(ToolCall(id: "1", name: "use_skill", arguments: #"{"name":"dock"}"#), skills: skills).contains("C"))
        XCTAssertTrue(Skills.run(ToolCall(id: "1", name: "use_skill", arguments: #"{"name":"nope"}"#), skills: skills).contains("no skill"))
    }

    func testBuiltInSkillsLoad() {
        let skills = Skills.load(from: [Paths.bundledSkills].compactMap { $0 })
        XCTAssertGreaterThanOrEqual(skills.count, 8)
        XCTAssertTrue(skills.allSatisfy { !$0.description.isEmpty })
        // the commands the skills give for reading pass system_read
        for c in ["defaults read com.apple.dock orientation", "pmset -g", "networksetup -getdnsservers \"Wi-Fi\"",
                  "/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate", "top -l 1 -o cpu -n 15",
                  "mdfind -onlyin ~ \"kMDItemFSSize > 2000000000\"", "launchctl print gui/501/com.example",
                  "log show --last 10m --predicate 'messageType == error' --style compact", "brew search vlc"] {
            XCTAssertTrue(SystemTools.isReadOnly(c), c)
        }
    }
}

final class SystemToolsTests: XCTestCase {
    func testReadOnlyAllowlist() {
        for c in ["sw_vers", "df -h /", "defaults read -g AppleInterfaceStyle", "scutil --dns", "csrutil status",
                  "softwareupdate --list", "tmutil listlocalsnapshots /", "sysctl vm.swapusage", "ifconfig en0", "ping -c 3 1.1.1.1"] {
            XCTAssertTrue(SystemTools.isReadOnly(c), c)
        }
        for c in ["defaults write com.apple.dock orientation left", "pmset -a sleep 0", "sw_vers; rm -rf ~", "ls | sh",
                  "cat $(echo /etc/passwd)", "ls `whoami`", "df > out.txt", "networksetup -setdnsservers Wi-Fi 1.1.1.1",
                  "find . -delete", "sysctl -w kern.x=1", "ifconfig en0 down", "softwareupdate -i -a", "rm file",
                  "launchctl bootout gui/501 x", "ls && rm x", "echo 'unclosed", "brew install vlc", "log erase"] {
            XCTAssertFalse(SystemTools.isReadOnly(c), c)
        }
    }

    func testChecksAsModelsWriteThem() {
        XCTAssertEqual(SystemTools.readableCheck(#"defaults read d k 2>/dev/null || echo "(sleutel bestaat nog niet)""#), "defaults read d k")
        XCTAssertEqual(SystemTools.readableCheck("pmset -g 2>&1"), "pmset -g")
        XCTAssertEqual(SystemTools.readableCheck("defaults read d k || true"), "defaults read d k")
        XCTAssertNil(SystemTools.readableCheck("defaults read d k || rm -rf ~"))
        XCTAssertNil(SystemTools.readableCheck(#"defaults read d k || echo "$(whoami)""#))
        XCTAssertNil(SystemTools.readableCheck("defaults write d k v 2>/dev/null"))
    }

    func testWarnings() {
        func step(_ apply: String, undo: String = "x") -> SystemTools.Step {
            SystemTools.Step(title: "t", check: "", apply: apply, undo: undo, admin: true)
        }
        XCTAssertTrue(SystemTools.warnings(for: [step("defaults write com.apple.dock orientation left")], afterWeb: false).isEmpty)
        XCTAssertEqual(SystemTools.warnings(for: [step("/usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate off")], afterWeb: false).count, 1)
        XCTAssertEqual(SystemTools.warnings(for: [step("spctl --global-disable")], afterWeb: false).count, 1)
        XCTAssertEqual(SystemTools.warnings(for: [step("sudo pmset -a hibernatemode 0")], afterWeb: false).count, 2)
        // a plan after reading the web, and a step without undo, are said too
        XCTAssertEqual(SystemTools.warnings(for: [step("killall Dock", undo: "")], afterWeb: true).count, 2)
    }

    func testPlanParsing() throws {
        let call = ToolCall(id: "1", name: "system_change", arguments: #"""
        {"summary":"Dock left","steps":[{"title":"Dock","check":"defaults read com.apple.dock orientation","apply":"defaults write com.apple.dock orientation -string left; killall Dock","undo":"defaults delete com.apple.dock orientation; killall Dock","admin":"false"},{"apply":"pmset -a displaysleep 30","undo":"pmset -a displaysleep 5","admin":true}]}
        """#)
        let plan = try SystemTools.plan(from: call)
        XCTAssertEqual(plan.summary, "Dock left")
        XCTAssertEqual(plan.steps.count, 2)
        XCTAssertFalse(plan.steps[0].admin)
        XCTAssertTrue(plan.steps[1].admin)
        XCTAssertEqual(plan.steps[1].title, "pmset -a displaysleep 30")
        XCTAssertThrowsError(try SystemTools.plan(from: ToolCall(id: "2", name: "system_change", arguments: #"{"summary":"x","steps":[]}"#)))
        // the steps as a JSON string
        let asString = ToolCall(id: "3", name: "system_change", arguments: #"{"summary":"s","steps":"[{\"apply\":\"true\",\"undo\":\"true\"}]"}"#)
        XCTAssertEqual(try SystemTools.plan(from: asString).steps.count, 1)
    }

    func testDomainsAndKillalls() {
        XCTAssertEqual(SystemTools.domains(in: "defaults write com.apple.dock orientation left; defaults write -g AppleShowAllExtensions -bool true"),
                       ["com.apple.dock", "NSGlobalDomain"])
        XCTAssertEqual(SystemTools.domains(in: "defaults -currentHost write x y z"), [])
        XCTAssertEqual(SystemTools.killalls(in: "defaults write a b c; killall Dock\nkillall SystemUIServer"), ["Dock", "SystemUIServer"])
        XCTAssertEqual(SystemTools.appleScriptString(#"echo "a\b""#), #""echo \"a\\b\"""#)
    }

    /// A real change on a test domain: the value before, the change, the record, and undo back to the value before.
    func testApplyAndUndoRoundTrip() async throws {
        let domain = "app.fremen.macaimagic.test"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: folder)
            _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/defaults"), arguments: ["delete", domain])
        }
        _ = await SystemTools.runUser("defaults write \(domain) color -string blue")
        let step = SystemTools.Step(title: "Colour", check: "defaults read \(domain) color",
                                    apply: "defaults write \(domain) color -string red",
                                    undo: "defaults write \(domain) color -string wrong", admin: false)   // a wrong undo
        let change = await SystemTools.apply(summary: "Make it red", steps: [step], snapshot: false, folder: folder)
        XCTAssertTrue(change.succeeded)
        XCTAssertEqual(change.results[0].before, "blue")
        XCTAssertEqual(change.results[0].after, "red")
        XCTAssertNotNil(change.exports[domain])
        XCTAssertEqual(SystemTools.load(folder: folder).map(\.id), [change.id])

        // the model's undo was wrong; the export made before the change puts the exact value back
        let undone = await SystemTools.undo(change, folder: folder)
        XCTAssertNotNil(undone.undone)
        let now = await SystemTools.runUser("defaults read \(domain) color")
        XCTAssertEqual(now.output, "blue")
        XCTAssertTrue(undone.undoReport?.contains("back to") == true, undone.undoReport ?? "")
        XCTAssertNotNil(SystemTools.load(folder: folder).first?.undone)
    }

    func testFailedStepStopsThePlan() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let steps = [SystemTools.Step(title: "fails", check: "", apply: "false", undo: "true", admin: false),
                     SystemTools.Step(title: "never", check: "", apply: "true", undo: "true", admin: false)]
        let change = await SystemTools.apply(summary: "x", steps: steps, snapshot: false, folder: folder)
        XCTAssertFalse(change.succeeded)
        XCTAssertTrue(change.results[0].ran)
        XCTAssertFalse(change.results[1].ran)
        XCTAssertTrue(SystemTools.report(change).contains("not run"))
    }
}

final class HelpTests: XCTestCase {
    func testBothLanguagesHaveTheSameTopics() {
        let nl = HelpCenter.topics("nl"), en = HelpCenter.topics("en")
        XCTAssertGreaterThanOrEqual(nl.count, 18)
        XCTAssertEqual(nl.map(\.id), en.map(\.id))
        XCTAssertTrue((nl + en).allSatisfy { !$0.title.isEmpty && $0.body.count > 200 }, "every topic has a title and real text")
    }

    @MainActor func testEveryPageHasItsTopic() {
        let ids = Set(HelpCenter.topics("en").map(\.id))
        for pane: Pane? in [.live, .models, .documents, .images, .compare, .cluster, .system, .help, .chat(UUID()), nil] {
            XCTAssertTrue(ids.contains(HelpCenter.topic(for: pane)), "\(String(describing: pane))")
        }
        // the Help menu and the Experimental tab open these
        for id in ["start", "troubleshooting", "shortcuts", "sysadmin", "skills"] { XCTAssertTrue(ids.contains(id), id) }
    }

    func testSearch() {
        let nl = HelpCenter.topics("nl")
        XCTAssertEqual(HelpCenter.search("wachtwoord beheerder", in: nl).first?.id, "sysadmin")
        XCTAssertEqual(HelpCenter.search("Thunderbolt", in: HelpCenter.topics("en")).first?.id, "cluster")
        XCTAssertEqual(HelpCenter.search("", in: nl).count, nl.count)
        XCTAssertTrue(HelpCenter.search("xyzzy", in: nl).isEmpty)
    }

    func testBlocks() {
        let b = HelpBody.blocks("Intro\n## Kop\n| a | b |\n|---|---|\n| 1 | 2 |\n> Tip\n```\n## not a heading\n```")
        XCTAssertEqual(b, [.text("Intro"), .heading("Kop"), .text("• a — b\n• 1 — 2"), .tip("Tip"), .text("```\n## not a heading\n```")])
    }
}
