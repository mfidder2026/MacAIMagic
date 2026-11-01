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
    /// The user's notes for the model in every conversation (a work folder can add its own MACAIMAGIC.md).
    static var generalNotes: URL {
        let current = appSupport.appendingPathComponent("MACAIMAGIC.md")
        let former = appSupport.appendingPathComponent("MAC" + "DEEPSEEK.md")   // the name before 1.6
        return !FileManager.default.fileExists(atPath: current.path) && FileManager.default.fileExists(atPath: former.path) ? former : current
    }

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

    /// The project root when running from source (swift run / swift test in App/, or this file's location).
    private static var sourceRoots: [URL] {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let thisFile = URL(fileURLWithPath: #filePath)   // …/App/Sources/MacAIMagic/Support/Paths.swift
        return [cwd.deletingLastPathComponent(), cwd,
                thisFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent().deletingLastPathComponent()]
    }
}
