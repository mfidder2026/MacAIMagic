import Foundation

/// Tools that let the model work in one folder the user chose: list, read, write and edit files, and run commands.
/// Every path is resolved inside the workspace; anything that points outside it is refused.
enum WorkspaceTools {
    static let names: Set<String> = ["list_dir", "read_file", "write_file", "edit_file", "run_command"]
    /// Tools that change something: these ask the user first.
    /// The kinds of action the user gives rights for (allow, ask, deny).
    enum Right: String, CaseIterable {
        case read, write, run
        var letter: String { self == .read ? L("L") : self == .write ? L("S") : L("U") }
        var title: String { self == .read ? L("Lezen") : self == .write ? L("Schrijven") : L("Uitvoeren") }
        var detail: String {
            switch self {
            case .read: return L("Mappen bekijken en bestanden lezen")
            case .write: return L("Bestanden maken en aanpassen")
            case .run: return L("Commando's, scripts en apps starten")
            }
        }
    }

    static func right(for name: String) -> Right {
        switch name {
        case "write_file", "edit_file": return .write
        case "run_command": return .run
        default: return .read
        }
    }

    static let definitions: [[String: Any]] = [
        function("list_dir", "List the files and folders in a folder of the workspace, with sizes. Use \".\" for the workspace itself.",
                 ["path": ["type": "string", "description": "Folder, relative to the workspace"]], required: ["path"]),
        function("read_file", "Read a text file from the workspace. For long files or logs, use tail to read only the last lines, or offset/limit for a range of lines.",
                 ["path": ["type": "string", "description": "File, relative to the workspace"],
                  "offset": ["type": "integer", "description": "First line to read (1-based), optional"],
                  "limit": ["type": "integer", "description": "Number of lines, optional"],
                  "tail": ["type": "integer", "description": "Read only the last N lines (for log files), optional"]],
                 required: ["path"]),
        function("write_file", "Create or overwrite a file in the workspace. Folders are created as needed. For binary files (for example a C64 .prg, an image or a zip), pass the bytes as base64 and set encoding to \"base64\".",
                 ["path": ["type": "string", "description": "File, relative to the workspace"],
                  "content": ["type": "string", "description": "The full file content (text, or base64 when encoding is base64)"],
                  "encoding": ["type": "string", "enum": ["text", "base64"], "description": "text (default) or base64"]],
                 required: ["path", "content"]),
        function("edit_file", "Replace one exact piece of text in a file of the workspace. old_text must occur exactly once.",
                 ["path": ["type": "string"], "old_text": ["type": "string"], "new_text": ["type": "string"]],
                 required: ["path", "old_text", "new_text"]),
        function("run_command", "Run a shell command (zsh) in the workspace folder and return its output and exit code. Use it to run scripts, build or test code, start programs (open file.ext), or inspect the system. Commands that never end (servers) are stopped after the timeout.",
                 ["command": ["type": "string", "description": "The command line"],
                  "timeout": ["type": "integer", "description": "Seconds before the command is stopped (default 120, max 1800)"]],
                 required: ["command"]),
    ]

    private static func function(_ name: String, _ description: String, _ properties: [String: Any], required: [String]) -> [String: Any] {
        ["type": "function", "function": ["name": name, "description": description,
                                          "parameters": ["type": "object", "properties": properties, "required": required]]]
    }

    // MARK: - paths

    enum ToolError: LocalizedError {
        case noWorkspace, outside(String), notFound(String), notUnique(Int), tooBig(String), badBase64
        var errorDescription: String? {
            switch self {
            case .noWorkspace: return "No workspace folder is set. Ask the user to choose one (Werkmap in the chat)."
            case .outside(let p): return "\(p) is outside the workspace; this tool only works inside it. Elsewhere on this Mac, use run_command (ls, mdfind, cat)."
            case .notFound(let p): return "\(p) does not exist."
            case .notUnique(let n): return "old_text occurs \(n) times; it must occur exactly once. Include more surrounding text."
            case .tooBig(let p): return "\(p) is larger than 2 MB; read it with offset/limit or tail."
            case .badBase64: return "content is not valid base64."
            }
        }
    }

    /// The conversation's own folder while the chat client runs its tools; falls back to the last chosen folder.
    @MainActor static var current: String?

    @MainActor static var workspace: URL? {
        let p = current ?? Settings.shared.workspace
        guard !p.isEmpty else { return nil }
        return URL(fileURLWithPath: p, isDirectory: true).resolvingSymlinksInPath()
    }

    /// A path inside the workspace, or an error. Symlinks are resolved first, so a link cannot lead outside.
    @MainActor static func resolve(_ path: String) throws -> URL {
        guard let root = workspace else { throw ToolError.noWorkspace }
        let expanded = (path as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : root.appendingPathComponent(expanded)
        // resolve what exists; a new file's parent decides
        var resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        if !FileManager.default.fileExists(atPath: resolved.path) {
            resolved = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
                .appendingPathComponent(url.lastPathComponent)
        }
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard resolved.path == root.path || resolved.path.hasPrefix(rootPath) else { throw ToolError.outside(path) }
        return resolved
    }

    @MainActor static func relative(_ url: URL) -> String {
        guard let root = workspace?.path else { return url.path }
        let p = url.path
        return p == root ? "." : (p.hasPrefix(root + "/") ? String(p.dropFirst(root.count + 1)) : p)
    }

    // MARK: - run

    static func args(_ call: ToolCall) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
    }

    static func label(for call: ToolCall) -> String {
        let a = args(call)
        let path = a["path"] as? String ?? ""
        switch call.name {
        case "list_dir": return L("Map bekijken: \(path)")
        case "read_file": return L("Lezen: \(path)")
        case "write_file": return L("Schrijven: \(path)")
        case "edit_file": return L("Aanpassen: \(path)")
        case "run_command": return L("Uitvoeren: \(a["command"] as? String ?? "")")
        default: return call.name
        }
    }

    /// What the user is asked to approve, in plain words.
    static func approvalText(for call: ToolCall) -> (title: String, detail: String) {
        let a = args(call)
        switch call.name {
        case "write_file":
            let content = a["content"] as? String ?? ""
            let binary = (a["encoding"] as? String) == "base64"
            return (L("Bestand schrijven: \(a["path"] as? String ?? "")"),
                    binary ? L("Binair bestand, \(Data(base64Encoded: content)?.count ?? 0) bytes") : String(content.prefix(1500)))
        case "edit_file":
            return (L("Bestand aanpassen: \(a["path"] as? String ?? "")"),
                    "− \((a["old_text"] as? String ?? "").prefix(600))\n+ \((a["new_text"] as? String ?? "").prefix(600))")
        case "run_command":
            return (L("Commando uitvoeren in de werkmap"), a["command"] as? String ?? "")
        default:
            return (call.name, call.arguments)
        }
    }

    @MainActor static func run(_ call: ToolCall) async -> String {
        let a = args(call)
        do {
            switch call.name {
            case "list_dir": return try listDir(a["path"] as? String ?? ".")
            case "read_file": return try readFile(a["path"] as? String ?? "", offset: a["offset"] as? Int, limit: a["limit"] as? Int, tail: a["tail"] as? Int)
            case "write_file": return try writeFile(a["path"] as? String ?? "", content: a["content"] as? String ?? "", base64: (a["encoding"] as? String) == "base64")
            case "edit_file": return try editFile(a["path"] as? String ?? "", old: a["old_text"] as? String ?? "", new: a["new_text"] as? String ?? "")
            case "run_command": return try await runCommand(a["command"] as? String ?? "", timeout: min(max(a["timeout"] as? Int ?? 120, 1), 1800))
            default: return "Unknown tool \(call.name)"
            }
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    @MainActor static func listDir(_ path: String) throws -> String {
        let url = try resolve(path)
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else {
            throw ToolError.notFound(path)
        }
        let df = ISO8601DateFormatter()
        let lines = items.sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(500).map { item -> String in
            let v = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let date = v?.contentModificationDate.map { df.string(from: $0) } ?? ""
            return v?.isDirectory == true ? "\(item.lastPathComponent)/  \(date)" : "\(item.lastPathComponent)  \(v?.fileSize ?? 0) bytes  \(date)"
        }
        return lines.isEmpty ? "(empty folder) \(relative(url))" : "\(relative(url)):\n" + lines.joined(separator: "\n")
    }

    @MainActor static func readFile(_ path: String, offset: Int?, limit: Int?, tail: Int?) throws -> String {
        let url = try resolve(path)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { throw ToolError.notFound(path) }
        let size = attrs[.size] as? Int ?? 0
        let data: Data
        if size > 2_000_000 {
            guard tail != nil || offset != nil else { throw ToolError.tooBig(path) }
            // big file: read the end for tail, else the start
            let fh = try FileHandle(forReadingFrom: url)
            defer { try? fh.close() }
            if tail != nil { try fh.seek(toOffset: UInt64(max(0, size - 2_000_000))) }
            data = try fh.read(upToCount: 2_000_000) ?? Data()
        } else {
            data = try Data(contentsOf: url)
        }
        let text = String(decoding: data, as: UTF8.self)
        if data.prefix(8000).contains(0) {
            return "\(path) is a binary file (\(size) bytes). Its first bytes as hex: " + data.prefix(64).map { String(format: "%02x", $0) }.joined(separator: " ")
        }
        var lines = text.components(separatedBy: "\n")
        var first = 1
        if let tail { first = max(1, lines.count - tail + 1); lines = Array(lines.suffix(tail)) }
        else if offset != nil || limit != nil {
            first = max(1, offset ?? 1)
            lines = Array(lines.dropFirst(first - 1).prefix(limit ?? 400))
        }
        var out = lines.enumerated().map { "\(first + $0.offset)\t\($0.element)" }.joined(separator: "\n")
        if out.count > 40_000 { out = String(out.prefix(40_000)) + "\n… (truncated; use offset/limit)" }
        return out
    }

    @MainActor static func writeFile(_ path: String, content: String, base64: Bool) throws -> String {
        let url = try resolve(path)
        let data: Data
        if base64 {
            guard let d = Data(base64Encoded: content, options: .ignoreUnknownCharacters) else { throw ToolError.badBase64 }
            data = d
        } else {
            data = Data(content.utf8)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return "Wrote \(data.count) bytes to \(relative(url))"
    }

    @MainActor static func editFile(_ path: String, old: String, new: String) throws -> String {
        let url = try resolve(path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw ToolError.notFound(path) }
        let count = text.components(separatedBy: old).count - 1
        guard count == 1 else { throw ToolError.notUnique(count) }
        try text.replacingOccurrences(of: old, with: new).write(to: url, atomically: true, encoding: .utf8)
        return "Edited \(relative(url))"
    }

    /// Runs in the workspace with the user's login shell environment; output is capped so it fits the context.
    @MainActor static func runCommand(_ command: String, timeout: Int) async throws -> String {
        guard let root = workspace else { throw ToolError.noWorkspace }
        return await runShell(command, in: root, timeout: timeout)
    }

    /// A zsh command line in a folder, stopped after the timeout or when the user presses stop. Also used by the
    /// system tools, which work in the home folder.
    static func runShell(_ command: String, in root: URL, timeout: Int, executable: String = "/bin/zsh", arguments: [String]? = nil) async -> String {
        let stopped = StopFlag()
        return await withTaskCancellationHandler(operation: { await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = arguments ?? ["-lc", command]
                p.currentDirectoryURL = root
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                p.standardInput = FileHandle.nullDevice
                var output = Data()
                let lock = NSLock()
                pipe.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    lock.lock(); if output.count < 400_000 { output.append(d) }; lock.unlock()
                }
                do { try p.run() } catch {
                    cont.resume(returning: "Error: could not start the command: \(error.localizedDescription)")
                    return
                }
                let deadline = Date().addingTimeInterval(TimeInterval(timeout))
                var timedOut = false
                while p.isRunning {
                    if Date() > deadline { timedOut = true; stopTree(p.processIdentifier); break }
                    if stopped.isSet { stopTree(p.processIdentifier); break }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                p.waitUntilExit()
                // a program started with & keeps this pipe open: what it writes later is read and dropped, so it keeps
                // running and the command is over now
                Thread.sleep(forTimeInterval: 0.1)
                pipe.fileHandleForReading.readabilityHandler = { h in
                    if h.availableData.isEmpty { h.readabilityHandler = nil }
                }
                lock.lock()
                var text = String(decoding: output, as: UTF8.self)
                lock.unlock()
                if text.count > 30_000 { text = String(text.prefix(12_000)) + "\n… (\(text.count - 24_000) characters cut) …\n" + String(text.suffix(12_000)) }
                let status = timedOut ? "stopped after \(timeout) s (timeout)" : stopped.isSet ? "stopped by the user" : "exit code \(p.terminationStatus)"
                cont.resume(returning: (text.isEmpty ? "(no output)" : text) + "\n[\(status)]")
            }
        } }, onCancel: { stopped.set() })
    }

    /// Stop pressed while a command runs.
    private final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    /// The command and everything it started, children first. Programs detached with `open` are not among them.
    private static func stopTree(_ pid: pid_t) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            for child in out.split(separator: "\n").compactMap({ pid_t($0) }) { stopTree(child) }
        }
        kill(pid, SIGTERM)
    }
}
