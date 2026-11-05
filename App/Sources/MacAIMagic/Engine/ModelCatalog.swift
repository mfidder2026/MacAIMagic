import Foundation

/// The models MacAIMagic knows, read from models.json (shared with tools/download_model.sh).
struct ModelFile: Codable, Hashable {
    let local: String
    let size: UInt64
    let sha256: String
    let url: String
    /// [no, count]: a shard published on its own, whose header gets its place in the set after download
    let stamp: [Int]?
}

struct ModelInfo: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let family: String
    let summary: String
    let vision: String?
    let files: [ModelFile]
    /// Multi-token prediction head for speculative decoding: in a separate file (Qwen) or inside the model (GLM).
    let draft: ModelFile?
    let mtp: String?
    /// Measured from the GGUF headers: what stays in memory while it runs (dense weights + experts, not DeepSeek's
    /// Engram tables, which come from the SSD), and the dense part of that, which always goes on the GPU.
    let memory: UInt64?
    let dense: UInt64?
    /// Writing speed in tokens/s when it streams on a 32 GB Mac (measured on an M3 Max with 32 GB of memory left).
    let speedOn32GB: String?

    var totalSize: UInt64 { files.reduce(0) { $0 + $1.size } }
    var isDeepSeek: Bool { family == "deepseek" }
    var hasMTP: Bool { mtp == "builtin" || mtp == "file" }
    /// No routed experts: every token reads all the weights, so nothing can stay behind on the SSD for long.
    var isPlain: Bool { dense != nil && dense == memory }
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
    /// The models that make images, on a page of their own: their files in the order the image engine takes them (the image
    /// model, the text model, the decoder). `models` is what can chat.
    var images: [ModelInfo] = []
    var all: [ModelInfo] { models + images }

    init(models: [ModelInfo], vision: [VisionInfo], images: [ModelInfo] = []) {
        self.models = models
        self.vision = vision
        self.images = images
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        models = try c.decode([ModelInfo].self, forKey: .models)
        vision = try c.decode([VisionInfo].self, forKey: .vision)
        images = try c.decodeIfPresent([ModelInfo].self, forKey: .images) ?? []
    }

    static let shared: ModelCatalog = {
        guard let url = Paths.manifest, let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(ModelCatalog.self, from: data) else {
            return ModelCatalog(models: [], vision: [])
        }
        return catalog
    }()

    func model(_ id: String) -> ModelInfo? { all.first { $0.id == id } }
    func vision(for model: ModelInfo) -> VisionInfo? { vision.first { $0.id == model.vision } }
}
