import Foundation

/// Where MacAIMagic keeps its models, its engine and its conversations.
enum Paths {
    static let appSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MacAIMagic", isDirectory: true)
        // before 1.6 the app had another name: its folder (models, conversations, measurements) moves along once
        let former = base.appendingPathComponent("Mac" + "DeepSeek", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path), FileManager.default.fileExists(atPath: former.path) {
            try? FileManager.default.moveItem(at: former, to: dir)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// The version of the running app; nil when it runs from source, without a bundle.
    static var appVersion: String? {
        // (under the tests the bundle is the test runner's, with a version of its own)
        guard Bundle.main.bundleIdentifier == "app.fremen.macaimagic" else { return nil }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    static var defaultModelsRoot: URL { appSupport.appendingPathComponent("models", isDirectory: true) }
    /// The folder that holds one subfolder per model: chosen by the user (Engine → Kies map), else the default.
    static var modelsRoot: URL {
        if let custom = UserDefaults.standard.string(forKey: "modelFolder"), !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return defaultModelsRoot
    }
    static func modelDir(_ id: String) -> URL { modelsRoot.appendingPathComponent(id, isDirectory: true) }
    static var visionDir: URL { modelsRoot.appendingPathComponent("vision", isDirectory: true) }

    static var conversationsFile: URL { appSupport.appendingPathComponent("conversations.json") }
    static var benchmarksFile: URL { appSupport.appendingPathComponent("benchmarks.json") }
    static var engineLog: URL { appSupport.appendingPathComponent("engine.log") }
    static var imageLog: URL { appSupport.appendingPathComponent("image.log") }
    /// ~/Pictures/MacAIMagic, where the images go; made when the first image is.
    static var picturesFolder: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("MacAIMagic", isDirectory: true)
    }
    /// The user's notes for the model in every conversation (a work folder can add its own MACAIMAGIC.md).
    static var generalNotes: URL {
        let current = appSupport.appendingPathComponent("MACAIMAGIC.md")
        let former = appSupport.appendingPathComponent("MAC" + "DEEPSEEK.md")   // the name before 1.6
        return !FileManager.default.fileExists(atPath: current.path) && FileManager.default.fileExists(atPath: former.path) ? former : current
    }

    /// The user's own skills (a folder per skill with SKILL.md); one with the name of a built-in skill replaces it.
    static var userSkills: URL { appSupport.appendingPathComponent("Skills", isDirectory: true) }
    /// The skills that come with the app: inside the bundle, or skills/ when run from source.
    static var bundledSkills: URL? {
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL { candidates.append(res.appendingPathComponent("Skills")) }
        for root in sourceRoots { candidates.append(root.appendingPathComponent("skills")) }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
    /// The connectors (MCP servers), in the format of Claude Desktop.
    static var mcpConfig: URL { appSupport.appendingPathComponent("mcp.json") }
    /// Scheduled tasks (Taken).
    static var tasks: URL { appSupport.appendingPathComponent("tasks.json") }
    /// The heartbeat's checklist.
    static var heartbeat: URL { appSupport.appendingPathComponent("HEARTBEAT.md") }
    /// One folder per system change the model made: the plan, the values before and after, and exports for undo.
    static var changes: URL { appSupport.appendingPathComponent("Changes", isDirectory: true) }

    /// models.json: inside the app bundle, or in tools/ when run from source.
    static var manifest: URL? { resource("models.json") }

    /// The engine binary: inside the app bundle, or next to the project when run from source.
    static func engineBinary(_ name: String) -> URL? {
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL { candidates.append(res.appendingPathComponent("engine/\(name)")) }
        candidates.append(appSupport.appendingPathComponent("engine/\(name)"))
        for root in sourceRoots { candidates.append(root.appendingPathComponent("engine/bin/\(name)")) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func script(_ name: String) -> URL? { resource(name) }

    private static func resource(_ name: String) -> URL? {
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL { candidates.append(res.appendingPathComponent(name)) }
        for root in sourceRoots { candidates.append(root.appendingPathComponent("tools/\(name)")) }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// A folder of the project when running from source (help/nl, skills).
    static func sourceFolders(_ path: String) -> [URL] { sourceRoots.map { $0.appendingPathComponent(path) } }

    /// The project root when running from source (swift run / swift test in App/, or this file's location).
    private static var sourceRoots: [URL] {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let thisFile = URL(fileURLWithPath: #filePath)   // …/App/Sources/MacAIMagic/Support/Paths.swift
        return [cwd.deletingLastPathComponent(), cwd,
                thisFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent().deletingLastPathComponent()]
    }
}
