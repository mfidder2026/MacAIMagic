import Foundation

/// What the file panel beside the chat shows of the working folder: the entries of one folder, and the text of one file.
/// Only reads (WinAIMagic's owner asked for a developer view of what the model writes; taken over from there).
enum WorkspaceFiles {
    struct Entry: Hashable, Identifiable {
        let url: URL
        let name: String
        let isFolder: Bool
        let size: Int64
        var id: URL { url }
    }

    /// At most this many entries of one folder; the rest is counted.
    static let maxEntries = 500
    /// A longer file shows its first part.
    static let maxBytes = 1_000_000

    /// Folders first, then files, each in the Finder's order (file2 before file10). Hidden entries stay out, as in the
    /// Finder, and so does .git. `more` is how many did not fit.
    static func list(_ folder: URL) -> (entries: [Entry], more: Int) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .isHiddenKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return ([], 0) }
        var found: [Entry] = []
        for url in urls where url.lastPathComponent != ".git" {
            let v = try? url.resourceValues(forKeys: Set(keys))
            if v?.isHidden == true { continue }
            let dir = v?.isDirectory ?? false
            found.append(Entry(url: url, name: url.lastPathComponent, isFolder: dir, size: dir ? 0 : Int64(v?.fileSize ?? 0)))
        }
        found.sort { $0.isFolder != $1.isFolder ? $0.isFolder : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return found.count > maxEntries ? (Array(found.prefix(maxEntries)), found.count - maxEntries) : (found, 0)
    }

    struct Content: Equatable {
        let text: String?
        let note: String?
    }

    /// The text of a file, or why there is none. A file that holds a 0 byte in its first 8 kB is not text.
    static func read(_ url: URL) -> Content {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return Content(text: nil, note: L("Kan \(url.lastPathComponent) niet lezen."))
        }
        defer { try? handle.close() }
        let length = (try? handle.seekToEnd()).map { Int64($0) } ?? 0
        try? handle.seek(toOffset: 0)
        let head = (try? handle.read(upToCount: maxBytes)) ?? Data()
        if head.prefix(8192).contains(0) { return Content(text: nil, note: L("Geen tekstbestand (\(size(length))).")) }
        var text = decode(head)
        if length > Int64(head.count) {
            // never end in the middle of a line
            if let cut = text.lastIndex(of: "\n") { text = String(text[..<cut]) }
            return Content(text: text, note: L("De eerste \(size(Int64(head.count))) van \(size(length))."))
        }
        return Content(text: text, note: nil)
    }

    /// UTF-8 (with or without its mark) or UTF-16 with its mark; a file that is not valid UTF-8 is read as Windows-1252
    /// (older text files, also from a PC).
    static func decode(_ b: Data) -> String {
        if b.starts(with: [0xFF, 0xFE]) { return String(data: b.dropFirst(2), encoding: .utf16LittleEndian) ?? "" }
        if b.starts(with: [0xFE, 0xFF]) { return String(data: b.dropFirst(2), encoding: .utf16BigEndian) ?? "" }
        let body = b.starts(with: [0xEF, 0xBB, 0xBF]) ? b.dropFirst(3) : b[...]
        if let s = String(data: body, encoding: .utf8) { return s }
        // a cut through a character at the end is no reason to call the file something else
        if b.count >= maxBytes { return String(decoding: body, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FFFD}")) }
        return String(data: body, encoding: .windowsCP1252) ?? String(decoding: body, as: UTF8.self)
    }

    static func size(_ bytes: Int64) -> String {
        switch bytes {
        case ..<1024: return "\(bytes) B"
        case ..<(1024 * 1024): return String(format: "%.1f kB", Double(bytes) / 1024).replacingOccurrences(of: ".0 ", with: " ")
        default: return String(format: "%.1f MB", Double(bytes) / 1_048_576).replacingOccurrences(of: ".0 ", with: " ")
        }
    }

    /// What changes when the model writes: names, sizes and dates of the open folders, and the open file's date. Compared
    /// once a second; the panel redraws only when it changed.
    static func signature(folders: [URL], file: URL?) -> Int {
        var h = Hasher()
        for f in folders {
            for e in list(f).entries {
                h.combine(e.url); h.combine(e.size)
                h.combine((try? e.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
            }
        }
        if let file { h.combine((try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]))?.contentModificationDate) }
        return h.finalize()
    }
}
