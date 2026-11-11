import Foundation

/// The same error, again and again: then the model's idea of its cause is wrong, and it should stop and look.
///
/// In a C64 run (Terminator intro, Qwen3.6, 11 Nov 2026) Kick Assembler said "Syntax error" on `beq !t1-done` in 10
/// of 13 builds. The model blamed the line above the `^`, rewrote the whole file 14 times and never looked at the line
/// itself. After the third time the app now says so in that tool result.
struct RepeatedErrors {
    /// The third time the same error comes back the model hears it, and again every third time after.
    static let warnEvery = 3
    private var counts: [String: Int] = [:]

    /// A line that reports an error, in the output of a build, a script or a command.
    private static let errorLine = try! NSRegularExpression(
        pattern: #"error|fout|exception|fatal|failed|mislukt|unknown symbol|invalid|not found|no such file|undefined"#,
        options: [.caseInsensitive])
    /// Lines that every failure has, whatever its cause: they say nothing about which error it is.
    private static let generic = try! NSRegularExpression(
        pattern: #"^(\[build\] error: (assembleren mislukt|syntax checker)|traceback|\[exit code|summary: |got \d+ errors|\[build\] verander alleen)"#,
        options: [.caseInsensitive])

    /// What identifies the error a result reports: the source line the `^` points at (Kick Assembler, Python, cc) and
    /// the first specific error line, with numbers and folders left out, so a line that moved is the same error.
    /// Nil when the result reports no error.
    static func signature(_ result: String) -> String? {
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var parts: [String] = []
        // the line right above a line that is only a ^
        if let caret = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "^" }), caret > 0 {
            parts.append(lines[caret - 1])
        }
        if let first = lines.first(where: { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            let range = NSRange(t.startIndex..., in: t)
            return !t.isEmpty && errorLine.firstMatch(in: t, range: range) != nil && generic.firstMatch(in: t, range: range) == nil
        }) {
            parts.append(first)
        }
        guard !parts.isEmpty else { return nil }
        return parts.map(normalized).joined(separator: " | ")
    }

    /// Lower case, digits as #, a path as its last part, spaces collapsed.
    static func normalized(_ line: String) -> String {
        var s = line.lowercased()
        s = s.replacingOccurrences(of: #"(/[^\s/:()'"]+)+/"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Counts the error in a tool result; returns the note for the model when it came back for the 3rd (6th, …) time.
    mutating func note(_ result: String) -> String? {
        guard let key = Self.signature(result) else { return nil }
        let n = (counts[key] ?? 0) + 1
        counts[key] = n
        guard n % Self.warnEvery == 0 else { return nil }
        let shown = key.count > 200 ? String(key.prefix(200)) + "…" : key
        return "(Note from the app: the same error has now come back \(n) times in this answer: \(shown)\nWhat you changed so far did not fix it, so your idea of its cause is probably wrong. Stop changing other things. Read the line the error names, word for word, and the hint if there is one; change only that line. If you are not sure why it fails, try that one construct alone in a small test file, or look it up in the documentation. Do not rewrite the whole file.)"
    }
}
