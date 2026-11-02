import Foundation

/// MACAIMAGIC.md in the work folder: the user's notes for the model (like CLAUDE.md for Claude Code) and what the model
/// learned in earlier conversations there, so it does not make the same mistake twice. Read again for every message.
enum WorkspaceNotes {
    /// The line that starts what was learned: the user's own text stays above it, whatever its language.
    private static let marker = "<!-- macaimagic:lessons -->"
    /// The newest lessons stay; the oldest go, so the file keeps fitting in the system prompt.
    static let maxLessons = 60
    private static let maxPromptCharacters = 8_000

    /// The notes file had the app's former name before 1.6; that name still works.
    static func url(in folder: URL) -> URL {
        let current = folder.appendingPathComponent("MACAIMAGIC.md")
        let former = folder.appendingPathComponent("MAC" + "DEEPSEEK.md")
        return !FileManager.default.fileExists(atPath: current.path) && FileManager.default.fileExists(atPath: former.path) ? former : current
    }

    /// Is this file the notes of a folder, not a draft next to them?
    static func isNotes(_ file: URL) -> Bool {
        ["MACAIMAGIC.md", "MAC" + "DEEPSEEK.md"].contains(file.lastPathComponent)
    }

    /// The notes for the system prompt: when they are long, the start (the user's instructions) and the end (the newest lessons).
    static func forPrompt(in folder: URL) -> String? {
        guard let text = try? String(contentsOf: url(in: folder), encoding: .utf8), !text.isEmpty else { return nil }
        guard text.count > maxPromptCharacters else { return text }
        return String(text.prefix(maxPromptCharacters / 2)) + "\n…\n" + String(text.suffix(maxPromptCharacters / 2))
    }

    static func modified(in folder: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url(in: folder).path))?[.modificationDate] as? Date
    }

    /// A new work folder gets the file, with an explanation for the user.
    static func createIfNeeded(in folder: URL) {
        let file = url(in: folder)
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        let text = "# " + L("Notities voor MacAIMagic") + "\n\n"
            + L("Het model leest dit bestand bij elk bericht in deze werkmap. Schrijf hier zelf instructies voor het model, bijvoorbeeld hoe het een emulator start. Onder Geleerd zet de app wat het model tijdens gesprekken leert, zodat het fouten niet twee keer maakt. Je mag daar alles aanpassen of weghalen.")
            + "\n\n" + section
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }

    private static var section: String { "## " + L("Geleerd") + "\n" + marker + "\n" }

    /// Adds what is new under Geleerd and gives back what was added.
    @discardableResult
    static func add(lessons: [String], in folder: URL) -> [String] {
        createIfNeeded(in: folder)
        let file = url(in: folder)
        guard var text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        if !text.contains(marker) {
            // the user's own file: the section goes below their text
            text += (text.hasSuffix("\n") ? "\n" : "\n\n") + section
        }
        guard let range = text.range(of: marker) else { return [] }
        let head = String(text[..<range.upperBound])
        var known = text[range.upperBound...].split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let seen = Set(known.map { $0.lowercased() })
        let added = lessons.filter { !seen.contains($0.lowercased()) }
        guard !added.isEmpty else { return [] }
        known += added
        // the user's own lines below the marker count too: only lessons are dropped, oldest first
        while known.filter({ $0.hasPrefix("- ") }).count > maxLessons, let i = known.firstIndex(where: { $0.hasPrefix("- ") }) {
            known.remove(at: i)
        }
        try? (head + "\n" + known.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return added
    }

    /// The lessons in a model's answer: at most five lines of the form "- …", not too long, and nothing else.
    static func lessons(from answer: String) -> [String] {
        var seen = Set<String>()
        return answer.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") && $0.count > 8 && $0.count <= 300 && seen.insert($0.lowercased()).inserted }
            .prefix(5).map { $0 }
    }
}
