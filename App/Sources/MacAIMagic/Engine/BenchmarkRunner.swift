import Foundation

struct BenchResult: Codable, Identifiable, Hashable {
    var id = UUID()
    var modelID: String
    var modelName: String
    var date = Date()
    var loadSeconds: Double
    var promptTPS: Double
    var promptTokens: Int
    var decodeTPS: Double
    var decodeTokens: Int
    var ssdMBs: Double          // average SSD reads while writing
    var wiredGB: Double
    var cpuMoELayers: Int
    /// Larger than memory: the GPU expert cache (nil in results from before 1.4)
    var expertCacheGB: Double?
    /// A model that makes images: the seconds for one image of `imageSize`, with loading; the image tokens per second go in
    /// decodeTPS. Nil for a model that chats.
    var imageSeconds: Double?
    var imageSize: String?
    var makesImage: Bool { imageSeconds != nil }
    var imageSecondsOrZero: Double { imageSeconds ?? 0 }
}

/// Runs the same measurement on each model in turn: start it, read a ~2.5K-token prompt, write 300 tokens.
@MainActor
final class BenchmarkRunner: ObservableObject {
    @Published private(set) var results: [BenchResult] = []
    @Published private(set) var running: String?
    @Published private(set) var step = ""

    init() {
        if let data = try? Data(contentsOf: Paths.benchmarksFile),
           let list = try? JSONDecoder().decode([BenchResult].self, from: data) {
            results = list
        }
    }

    /// The latest result per model, in catalog order.
    var latest: [BenchResult] {
        ModelCatalog.shared.all.compactMap { m in results.last { $0.modelID == m.id } }
    }

    func run(_ ids: [String], app: AppState) async {
        for id in ids {
            guard let model = ModelCatalog.shared.model(id), app.models.status(id).isComplete else { continue }
            running = model.name
            if ModelCatalog.shared.images.contains(model) {
                await measureImage(model, app: app)
                continue
            }
            step = "Engine starten…"
            if app.engine.model?.id != id || !app.engine.state.isRunning {
                await app.engine.stopAndWait()
                app.selectedModelID = id
                app.startEngine()
            }
            let started = Date()
            while !app.engine.state.isRunning {
                if case .failed = app.engine.state { break }
                if Date().timeIntervalSince(started) > 1800 { break }
                try? await Task.sleep(for: .seconds(1))
            }
            guard app.engine.state.isRunning, let plan = app.plan else { continue }
            let load = Date().timeIntervalSince(started)
            do {
                step = "Prompt lezen…"
                let p = try await complete(app.engine.baseURL, prompt: Self.longPrompt(), maxTokens: 16)
                step = "Schrijven…"
                let t0 = Date()
                let d = try await complete(app.engine.baseURL, prompt: "Schrijf een verhaal van 300 woorden over een vuurtorenwachter op Terschelling.", maxTokens: 300)
                let during = app.metrics.samples.filter { $0.t >= t0 }
                let ssd = during.isEmpty ? 0 : during.map(\.ssdMBs).reduce(0, +) / Double(during.count)
                let r = BenchResult(modelID: id, modelName: model.name, loadSeconds: load,
                                    promptTPS: p.promptTPS, promptTokens: p.promptTokens,
                                    decodeTPS: d.decodeTPS, decodeTokens: d.decodeTokens,
                                    ssdMBs: ssd, wiredGB: during.map(\.wiredGB).max() ?? 0, cpuMoELayers: plan.cpuMoELayers,
                                    expertCacheGB: Double(plan.expertCache) / 1e9)
                results.append(r)
                save()
            } catch {
                step = "Fout: \(error.localizedDescription)"
            }
        }
        running = nil
        step = ""
    }

    /// The same image every time: a fixed description and seed, at the size measured on every Mac. The chat engine stops first.
    static let imagePrompt = "a lighthouse on a rocky coast at dusk, waves, photo"
    static let imageSize = ImageSize(width: 1024, height: 1024)

    private func measureImage(_ model: ModelInfo, app: AppState) async {
        step = "Afbeelding maken…"
        let saved = Settings.shared.imageModel
        Settings.shared.imageModel = model.id
        defer { Settings.shared.imageModel = saved }
        let root = app.images.root
        app.images.root = FileManager.default.temporaryDirectory.appendingPathComponent("macaimagic-measure")
        defer { app.images.root = root }
        let t0 = Date()
        guard let r = await app.makeImageNow(prompt: Self.imagePrompt, size: Self.imageSize, seed: 7, measuring: true) else {
            step = "Fout: \(app.images.error ?? "")"
            return
        }
        try? FileManager.default.removeItem(atPath: r.path)
        let during = app.metrics.samples.filter { $0.t >= t0 }
        results.append(BenchResult(modelID: model.id, modelName: model.name, loadSeconds: 0, promptTPS: 0, promptTokens: 0,
                                   decodeTPS: r.tokensPerSecond ?? 0, decodeTokens: ImagePlanner.tokensPerStep(Self.imageSize) * 4,
                                   ssdMBs: during.isEmpty ? 0 : during.map(\.ssdMBs).reduce(0, +) / Double(during.count),
                                   wiredGB: during.map(\.wiredGB).max() ?? 0, cpuMoELayers: 0, expertCacheGB: nil,
                                   imageSeconds: r.seconds, imageSize: Self.imageSize.key))
        save()
    }

    private struct Timings { var promptTPS = 0.0, promptTokens = 0, decodeTPS = 0.0, decodeTokens = 0 }

    private func complete(_ base: URL, prompt: String, maxTokens: Int) async throws -> Timings {
        var req = URLRequest(url: base.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !Settings.shared.apiKey.isEmpty { req.setValue("Bearer \(Settings.shared.apiKey)", forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = 1800
        let body: [String: Any] = [
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": maxTokens, "temperature": 0.7,
            "chat_template_kwargs": ["enable_thinking": false],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        let t = ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["timings"] as? [String: Any]) ?? [:]
        return Timings(promptTPS: t["prompt_per_second"] as? Double ?? 0, promptTokens: t["prompt_n"] as? Int ?? 0,
                       decodeTPS: t["predicted_per_second"] as? Double ?? 0, decodeTokens: t["predicted_n"] as? Int ?? 0)
    }

    /// ~2.5K tokens of varied text; a fresh first line each run so the prompt cache never hides the reading cost.
    static func longPrompt() -> String {
        let topics = ["de geschiedenis van de Nederlandse waterbouw", "hoe een mixture-of-experts taalmodel werkt",
                      "de werking van unified memory in Apple Silicon", "het klimaat in de Waddenzee",
                      "de ontwikkeling van open-source software", "de natuurkunde van zonnepanelen"]
        var text = "[\(Date().timeIntervalSince1970)] Lees de volgende notities en vat ze samen in drie zinnen.\n\n"
        for i in 0..<36 {
            let t = topics[i % topics.count]
            text += "Notitie \(i + 1): over \(t). Dit onderwerp raakt aan techniek, economie en maatschappij. "
            text += "Onderzoekers noemen in rapport \(1000 + i * 7) vooral de kosten, de betrouwbaarheid en de gevolgen op lange termijn. "
            text += "In \(1950 + i) werd een belangrijke stap gezet, en sindsdien zijn er \(i * 3 + 2) grote verbeteringen geweest. "
            text += "Critici wijzen op risico's; voorstanders op kansen voor \(["regio's", "bedrijven", "studenten", "gemeenten"][i % 4]).\n"
        }
        return text
    }

    func clear() { results = []; save() }

    /// Exporteer meting: one file with this Mac's hardware and the results, without paths or names. Nothing leaves by itself:
    /// the user drops it in the form on GitHub (Deel op GitHub) and sees it all before sending.
    func exportData(system: SystemInfo) throws -> Data {
        struct Hardware: Encodable {
            let chip: String, model: String, memoryGB: Double, performanceCores: Int, gpuLimitGB: Double, wiredLimitMB: Int, macOS: String
        }
        struct Export: Encodable { let app: String, hardware: Hardware, results: [BenchResult] }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let hardware = Hardware(chip: system.chip, model: Self.macModel(), memoryGB: (Double(system.physicalMemory) / 1e8).rounded() / 10,
                                performanceCores: system.performanceCores, gpuLimitGB: (Double(system.effectiveGPULimit) / 1e8).rounded() / 10,
                                wiredLimitMB: system.wiredLimitMB, macOS: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Export(app: Paths.appVersion ?? "source", hardware: hardware, results: results))
    }

    /// "Mac15,8": which Mac it is, without its name.
    static func macModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "?" }
        return String(cString: bytes)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(results) else { return }
        try? data.write(to: Paths.benchmarksFile, options: .atomic)
    }
}
