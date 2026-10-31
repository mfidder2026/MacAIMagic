import Foundation

/// Where MacDeepSeek keeps its model, its engine and its conversations.
enum Paths {
    static let appSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MacDeepSeek", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var defaultModelDir: URL { appSupport.appendingPathComponent("models/Maya-XS", isDirectory: true) }
    /// The folder with the GGUF files: chosen by the user (Engine & model → Kies map), else the default.
    static var modelDir: URL {
        if let custom = UserDefaults.standard.string(forKey: "modelFolder"), !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return defaultModelDir
    }
    static var conversationsFile: URL { appSupport.appendingPathComponent("conversations.json") }
    static var engineLog: URL { appSupport.appendingPathComponent("engine.log") }

    static let modelShards = (1...5).map {
        String(format: "DeepSeek-V4.1-Flash-1017-Maya-XS-IQ1_S-%05d-of-00005.gguf", $0)
    }
    static let modelShardSizes: [UInt64] = [47_781_530_400, 47_775_748_128, 19_784_230_848, 80_641_295_472, 80_643_503_412]
    static let visionProjector = "mmproj-F16.gguf"
    static let visionProjectorSize: UInt64 = 971_004_064

    /// The engine binary: inside the app bundle, or next to the project when run from source.
    static func engineBinary(_ name: String) -> URL? {
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("engine/\(name)"))
        }
        candidates.append(appSupport.appendingPathComponent("engine/\(name)"))
        // swift run from App/: the project root is two levels up from the package
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("../engine/bin/\(name)").standardized)
        candidates.append(cwd.appendingPathComponent("engine/bin/\(name)"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func script(_ name: String) -> URL? {
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL { candidates.append(res.appendingPathComponent(name)) }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("../tools/\(name)").standardized)
        candidates.append(cwd.appendingPathComponent("tools/\(name)"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
