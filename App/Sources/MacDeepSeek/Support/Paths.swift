import Foundation

/// Where MacDeepSeek keeps its models, its engine and its conversations.
enum Paths {
    static let appSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MacDeepSeek", isDirectory: true)
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
        let thisFile = URL(fileURLWithPath: #filePath)   // …/App/Sources/MacDeepSeek/Support/Paths.swift
        return [cwd.deletingLastPathComponent(), cwd,
                thisFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent().deletingLastPathComponent()]
    }
}
