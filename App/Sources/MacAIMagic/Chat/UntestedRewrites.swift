import Foundation

/// The same file written in full again and again without running it: the model is then guessing on paper, and every
/// rewrite brings new mistakes that nothing shows.
///
/// In the Terminator intro (Qwen3.8, 11 Nov 2026) the model wrote terminator.asm in full 9 times and gen.py 5 times in
/// two hours, built nothing, and 54% of the time went to those rewrites. The third time a file is written in full
/// while no command named it since, the app says so with that write's result, and again every third time after.
struct UntestedRewrites {
    static let warnEvery = 3
    private var counts: [String: Int] = [:]

    /// A write_file to `path` that went through: the note for the model at the 3rd (6th, …) full write since a command
    /// last named the file.
    mutating func wrote(_ path: String) -> String? {
        let key = Self.key(path)
        guard !key.isEmpty else { return nil }
        let n = (counts[key] ?? 0) + 1
        counts[key] = n
        guard n % Self.warnEvery == 0 else { return nil }
        return "(Note from the app: you have now written \(path) in full \(n) times in this answer, and no command ran it since. Rewriting does not show what is wrong. Build or run it now, then fix only what fails, with edit_file. Make it work first; make it nicer after.)"
    }

    /// A command: the files it names count as run. A file is named by its own name (intro.asm) or by its name with
    /// another extension (build/intro.prg); a folder of the same name (cd …/Intro) does not count.
    mutating func ran(_ command: String) {
        let c = command.lowercased()
        for key in counts.keys where Self.names(key, in: c) { counts[key] = 0 }
    }

    private static func key(_ path: String) -> String { (path as NSString).lastPathComponent.lowercased() }

    private static func names(_ key: String, in command: String) -> Bool {
        if command.contains(key) { return true }
        let stem = (key as NSString).deletingPathExtension
        guard !stem.isEmpty, stem != key else { return false }
        let pattern = #"(^|[^a-z0-9_])"# + NSRegularExpression.escapedPattern(for: stem) + #"\.[a-z0-9]+"#
        return command.range(of: pattern, options: .regularExpression) != nil
    }
}
