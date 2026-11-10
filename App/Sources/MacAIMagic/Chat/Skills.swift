import Foundation

/// A skill: instructions for one subject (Dock and appearance, energy, network…) with commands that were tested on
/// this platform. Only the name and description go in the system prompt; the model loads the rest with `use_skill`,
/// so a local model does not read every skill on every message.
struct Skill: Equatable {
    var name: String
    var description: String
    /// "macos", "windows" or "all".
    var platform: String
    var body: String
    /// The folder of a skill the user put in the skills folder (nil for a built-in one): its scripts sit there.
    var folder: URL? = nil
}

enum Skills {
    static let toolName = "use_skill"

    /// SKILL.md: front matter between --- lines (name, description, platform), then the instructions.
    static func parse(_ text: String, fallbackName: String) -> Skill? {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var fields: [String: String] = [:]
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            for line in lines[1..<end] {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if value.count >= 2, value.first == "\"", value.last == "\"" { value = String(value.dropFirst().dropLast()) }
                fields[key] = value
            }
            lines = Array(lines[(end + 1)...])
        }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (fields["name"] ?? fallbackName).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !body.isEmpty else { return nil }
        return Skill(name: name, description: fields["description"] ?? "", platform: (fields["platform"] ?? "all").lowercased(), body: body)
    }

    /// Every SKILL.md one level down in these folders; a later folder replaces a skill of the same name.
    /// `own`: the user's skills folder; a skill there loads whatever platform it names.
    static func load(from folders: [URL], platform: String = "macos", own ownFolder: URL? = Paths.userSkills) -> [Skill] {
        var byName: [String: Skill] = [:]
        let fm = FileManager.default
        for folder in folders {
            guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for dir in items {
                let file = dir.appendingPathComponent("SKILL.md")
                guard let text = try? String(contentsOf: file, encoding: .utf8),
                      var skill = parse(text, fallbackName: dir.lastPathComponent) else { continue }
                // a built-in skill of another platform stays out; one the user put in the skills folder always loads
                // (WinAIMagic's owner copied a Mac skill to the PC, and it was dropped without a word)
                let own = ownFolder.map { folder.standardizedFileURL == $0.standardizedFileURL } ?? false
                if own { skill.folder = dir }
                guard skill.platform == "all" || skill.platform == platform || own else { continue }
                byName[skill.name.lowercased()] = skill
            }
        }
        return byName.values.sorted { $0.name < $1.name }
    }

    /// The built-in skills, then the user's own.
    static var all: [Skill] {
        load(from: [Paths.bundledSkills, Paths.userSkills].compactMap { $0 })
    }

    static let definition: [String: Any] = [
        "type": "function",
        "function": [
            "name": toolName,
            "description": "Load the full instructions of a skill from the list in the system prompt. Do this before you work on that subject: the skill has commands that were tested on this computer.",
            "parameters": ["type": "object",
                           "properties": ["name": ["type": "string", "description": "The skill's name, exactly as listed"]],
                           "required": ["name"]],
        ] as [String: Any],
    ]

    /// For the system prompt: one line per skill. Sorted, so the prompt stays the same and the engine can reuse it.
    static func promptSection(_ skills: [Skill]) -> String {
        guard !skills.isEmpty else { return "" }
        return L("Je hebt skills: instructies per onderwerp, met geteste commando's. Laad een skill met use_skill voordat je aan dat onderwerp werkt, en volg hem op:")
            + "\n" + skills.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
    }

    static func run(_ call: ToolCall, skills: [Skill] = all) -> String {
        let name = (WorkspaceTools.args(call)["name"] as? String ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if let s = skills.first(where: { $0.name.lowercased() == name }) { return text(s) }
        return "There is no skill named \"\(name)\". Available: " + skills.map(\.name).joined(separator: ", ")
    }

    /// What the model reads of a skill. A user's skill says where its files are, so its scripts can be found; one written
    /// for Windows gets its WinAIMagic folder replaced by the real one here and a note on what differs on a Mac.
    static func text(_ s: Skill) -> String {
        var body = s.body
        var head = "# Skill: \(s.name)\n\n"
        if let folder = s.folder {
            // %LOCALAPPDATA%\WinAIMagic\Skills\c64_basic, $env:LOCALAPPDATA\... and C:\Users\x\AppData\Local\...: this folder
            body = body.replacingOccurrences(of: #"(%LOCALAPPDATA%|\$env:LOCALAPPDATA|[A-Za-z]:\\Users\\[^\\\s"'`]+\\AppData\\Local)\\WinAIMagic\\Skills\\[^\\\s"'`]+"#,
                                              with: NSRegularExpression.escapedTemplate(for: folder.path), options: .regularExpression)
            head += "This skill's own files (scripts beside SKILL.md) are in: \(folder.path)\n"
            if s.platform != "all" && s.platform != "macos" {
                head += "This skill was written for \(s.platform), and this computer is a Mac. Adapt its commands: run_command runs zsh, "
                    + "so use `python3` instead of `python`, `$HOME` instead of `$env:USERPROFILE`, ls/mdfind instead of Get-ChildItem, "
                    + "pgrep/pkill instead of Get-Process/Stop-Process, `open` instead of Start-Process, and / instead of \\ in paths. "
                    + "Programs named in it (such as an emulator) may be installed elsewhere here or not at all: look for them before you use them.\n"
            }
            head += "\n"
        }
        return head + body
    }

    /// Words that say nothing about a subject.
    nonisolated static let common: Set<String> = [
        "voor", "met", "een", "het", "van", "naar", "zodra", "worden", "wordt", "moet", "laden", "plus", "geteste", "vaste",
        "code", "harde", "regels", "this", "that", "with", "when", "from", "load", "loaded", "into", "your", "what", "alle",
        "deze", "maken", "schrijven", "programmeren", "gebruik", "door", "over", "wilt", "skill", "instructies", "macos",
    ]

    nonisolated static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    /// The words of a question, and what two words next to each other also mean: "kick assembler" is "kickassembler",
    /// and "commodore 64" is "c64" (a name's first letter with its number, also "amiga 500" for "a500").
    nonisolated static func questionWords(_ text: String) -> Set<String> {
        let list = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var out = Set(list)
        for (a, b) in zip(list, list.dropFirst()) {
            out.insert(a + b)
            if let first = a.first, first.isLetter, a.allSatisfy(\.isLetter), b.allSatisfy(\.isNumber) { out.insert(String(first) + b) }
        }
        return out
    }

    /// The skills a question is clearly about: a word of the skill's name that no other skill has, and at least three
    /// words of its name and description together in the question. A small model often skips use_skill; then the app
    /// loads these itself. Two skills on one subject (C64 BASIC and C64 assembler) share "c64" and "commodore", so the
    /// question must name what sets one apart ("basic", "assembler"): "commodore 64 assembler programmeur" loaded the
    /// BASIC skill and never the assembler one (2026-11-10).
    static func matching(_ question: String, in skills: [Skill] = all) -> [Skill] {
        let asked = questionWords(question)
        func terms(_ s: Skill) -> (name: Set<String>, all: Set<String>) {
            let name = words(s.name.replacingOccurrences(of: "-", with: " ")).subtracting(common)
            return (name, name.union(words(s.description).filter { ($0.count >= 4 || $0.contains { $0.isNumber }) }).subtracting(common))
        }
        let sets = skills.map(terms)
        // "sprite" counts for "sprites" (a shared start of four letters), "assembler" for "kickassembler" (six inside)
        func found(_ term: String) -> Bool {
            asked.contains { w in
                w == term || (min(w.count, term.count) >= 4 && (w.hasPrefix(term) || term.hasPrefix(w)))
                    || (min(w.count, term.count) >= 6 && (term.contains(w) || w.contains(term)))
            }
        }
        let scored: [(Skill, own: Int, hits: Int)] = skills.indices.compactMap { i in
            let (name, all) = sets[i]
            let others = sets.indices.filter { $0 != i }.reduce(into: Set<String>()) { $0.formUnion(sets[$1].all) }
            let hits = all.filter(found)
            // a word of the name that no other skill has: "basic" or "v2", "kickassembler"; "c64" does not tell them apart
            let ownName = sets.indices.filter { $0 != i }.reduce(name) { $0.subtracting(sets[$1].name) }
            guard (ownName.isEmpty ? name : ownName).contains(where: found), hits.count >= 3 else { return nil }
            return (skills[i], hits.subtracting(others).count, hits.count)
        }
        return scored.sorted { ($0.own, $0.hits) > ($1.own, $1.hits) }.prefix(2).map(\.0)
    }

    static func label(for call: ToolCall) -> String {
        L("Skill laden: \(WorkspaceTools.args(call)["name"] as? String ?? "")")
    }
}
