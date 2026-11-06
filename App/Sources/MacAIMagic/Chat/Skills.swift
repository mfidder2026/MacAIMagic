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
    static func load(from folders: [URL], platform: String = "macos") -> [Skill] {
        var byName: [String: Skill] = [:]
        let fm = FileManager.default
        for folder in folders {
            guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for dir in items {
                let file = dir.appendingPathComponent("SKILL.md")
                guard let text = try? String(contentsOf: file, encoding: .utf8),
                      let skill = parse(text, fallbackName: dir.lastPathComponent),
                      skill.platform == "all" || skill.platform == platform else { continue }
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
        if let s = skills.first(where: { $0.name.lowercased() == name }) { return "# Skill: \(s.name)\n\n\(s.body)" }
        return "There is no skill named \"\(name)\". Available: " + skills.map(\.name).joined(separator: ", ")
    }

    static func label(for call: ToolCall) -> String {
        L("Skill laden: \(WorkspaceTools.args(call)["name"] as? String ?? "")")
    }
}
