import Foundation

/// The models MacDeepSeek knows, read from models.json (shared with tools/download_model.sh).
struct ModelFile: Codable, Hashable {
    let local: String
    let size: UInt64
    let sha256: String
    let url: String
}

struct ModelInfo: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let family: String
    let summary: String
    let vision: String?
    let files: [ModelFile]

    var totalSize: UInt64 { files.reduce(0) { $0 + $1.size } }
    var isDeepSeek: Bool { family == "deepseek" }
    var shortName: String { name.components(separatedBy: " ").first ?? name }
}

struct VisionInfo: Codable, Hashable {
    let id: String
    let local: String
    let size: UInt64
    let sha256: String
    let url: String
}

struct ModelCatalog: Codable {
    let models: [ModelInfo]
    let vision: [VisionInfo]

    static let shared: ModelCatalog = {
        guard let url = Paths.manifest, let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(ModelCatalog.self, from: data) else {
            return ModelCatalog(models: [], vision: [])
        }
        return catalog
    }()

    func model(_ id: String) -> ModelInfo? { models.first { $0.id == id } }
    func vision(for model: ModelInfo) -> VisionInfo? { vision.first { $0.id == model.vision } }
}
