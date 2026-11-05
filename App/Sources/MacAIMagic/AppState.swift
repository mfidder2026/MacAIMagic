import Foundation
import AppKit
import SwiftUI

/// Ties the parts together: models, memory plan, engine, live metrics, conversations, chat, benchmarks.
@MainActor
final class AppState: ObservableObject {
    let engine = EngineController()
    let models = ModelStore()
    let store = ConversationStore()
    let chat = ChatClient()
    let metrics = LiveMetrics()
    let bench = BenchmarkRunner()
    let cluster = ClusterController()
    let check = SystemCheck()
    let documents = DocumentStudio()
    let images = ImageMaker()
    private(set) lazy var documentEngines = DocumentEngines(app: self)

    @AppStorage("selectedModel") var selectedModelID = "deepseek-v4.1-flash-compact" {
        didSet { loadIndex(); objectWillChange.send() }
    }
    @Published private(set) var system = SystemInfo.current()
    /// For the tests: the app as another Mac sees it.
    var simulatedSystem: SystemInfo? { didSet { refreshSystem() } }
    @Published private(set) var index: GGUFIndex?
    @Published private(set) var indexError: String?

    init() {
        chat.metrics = metrics
        LocalModel.metrics = metrics
        engine.onStateChange = { [weak metrics] state in
            switch state {
            case .running, .starting: metrics?.fast = true
            default: metrics?.fast = false
            }
        }
        images.onRate = { [weak metrics] rate in metrics?.imageRate = rate }
        loadIndex()
        documents.endpoint = { [weak self] role in
            guard let self else { throw CancellationError() }
            return try await self.documentEngines.endpoint(role)
        }
        documents.contextLimit = { [weak self] in self?.chat.contextLimit ?? 32_768 }
    }

    var selectedModel: ModelInfo? { models.catalog.model(selectedModelID) ?? models.catalog.models.first }

    var plan: MemoryPlan? {
        guard let index else { return nil }
        return MemoryPlanner.plan(index: index, system: system, contextSize: contextSize(index),
                                  vision: useVision(index), helpers: cluster.helperBudgets)
    }

    /// The chosen context, at most what the model was made for, and on a Mac with little memory at most what leaves
    /// the model its room in memory (a cluster gives this Mac room, so there the setting decides).
    func contextSize(_ index: GGUFIndex) -> Int {
        let chosen = index.contextLength > 0 ? min(Settings.shared.contextSize, index.contextLength) : Settings.shared.contextSize
        guard cluster.helperBudgets.isEmpty,
              let room = MemoryPlanner.contextRoom(index: index, system: system, vision: useVision(index)) else { return chosen }
        return min(chosen, room)
    }

    /// Vision when it is on and downloaded, unless it would leave the model too little room: then the model goes first.
    func useVision(_ index: GGUFIndex) -> Bool {
        guard Settings.shared.vision, selectedModel.flatMap(models.visionURL) != nil else { return false }
        guard cluster.helperBudgets.isEmpty else { return true }
        guard MemoryPlanner.fitsWhole(index: index, system: system) else { return system.physicalMemory >= MemoryPlanner.roomyMemory }
        return (MemoryPlanner.contextRoom(index: index, system: system, vision: true) ?? 0) >= 16_384
    }

    var canStart: Bool { !images.busy && chatModelReady }

    /// The chosen chat model can start: downloaded, planned, and the engine is there.
    private var chatModelReady: Bool {
        guard let m = selectedModel else { return false }
        return models.status(m.id).isComplete && plan != nil && Paths.engineBinary("llama-server") != nil
    }

    func loadIndex() {
        models.refresh()
        guard let m = selectedModel, models.status(m.id).headersAvailable else { index = nil; return }
        do {
            index = try GGUFIndex.load(shards: models.shardURLs(m), sizes: m.files.map(\.size))
            indexError = nil
        } catch {
            index = nil
            indexError = error.localizedDescription
        }
    }

    func refreshSystem() { system = simulatedSystem ?? SystemInfo.current() }

    /// `forImage`: the image being made needs the chat model first, to improve its description.
    func startEngine(forImage: Bool = false) {
        if index == nil { loadIndex() }
        guard forImage || !images.busy, let m = selectedModel, let index, var plan else { return }
        if !plan.fitsInMemory {
            // the expert cache leaves room for what other apps hold right now
            plan = MemoryPlanner.plan(index: index, system: system, contextSize: contextSize(index),
                                      vision: useVision(index),
                                      helpers: cluster.helperBudgets,
                                      inUse: system.physicalMemory - min(system.physicalMemory, SystemInfo.availableMemory()))
        }
        chat.contextLimit = plan.contextSize
        engine.start(model: m, shards: models.shardURLs(m), plan: plan,
                     vision: useVision(index) ? models.visionURL(m) : nil, draft: models.draftURL(m),
                     rpc: cluster.rpcArgument)
    }

    /// One image. Next to a chat model there is rarely room, so what runs stops first: not an answer being written or a
    /// measurement, those go first, and the chat engine is not started again by itself.
    func makeImage(prompt: String, size: ImageSize) {
        Task { await makeImageNow(prompt: prompt, size: size, improve: Settings.shared.imageImprove) }
    }

    /// The chat model writes a better description: started first when it does not run, and the engine makes room afterwards
    /// as for any image. Fails without a downloaded chat model.
    private func improveDescription(_ text: String, onStep: @escaping (String) -> Void) async throws -> (prompt: String, sources: [Source]) {
        guard let model = selectedModel else { throw ImproveError(L("Er is geen chatmodel gekozen.")) }
        if !engine.state.isRunning {
            guard models.status(model.id).isComplete else { throw ImproveError(L("\(model.name) is nog niet gedownload.")) }
            guard chatModelReady else { throw ImproveError(L("\(model.name) kan nu niet starten.")) }
            onStep(L("\(model.shortName) starten…"))
            startEngine(forImage: true)
            let started = Date()
            while !engine.state.isRunning {
                if case .failed(let why) = engine.state { throw ImproveError(why) }
                if Date().timeIntervalSince(started) > 1800 { throw ImproveError(L("\(model.name) startte niet.")) }
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        onStep(L("Beschrijving verbeteren…"))
        let base = engine.baseURL
        let result = try await ImagePrompt.improve(text, model: engine.model?.name ?? model.name, send: { body in
            var req = URLRequest(url: base.appendingPathComponent("v1/chat/completions"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !Settings.shared.apiKey.isEmpty { req.setValue("Bearer \(Settings.shared.apiKey)", forHTTPHeaderField: "Authorization") }
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.timeoutInterval = 600
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw ImproveError(L("Engine gaf \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")) }
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }, onStep: onStep)
        return (result.prompt, result.sources)
    }

    struct ImproveError: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    /// The model that makes images: chosen under Modellen, else the first.
    var imageModel: ModelInfo? {
        models.catalog.images.first { $0.id == Settings.shared.imageModel } ?? models.catalog.images.first
    }

    @discardableResult
    func makeImageNow(prompt: String, size: ImageSize, seed: Int? = nil, measuring: Bool = false, improve: Bool = false) async -> ImageResult? {
        guard let m = imageModel else { return nil }
        let files = models.shardURLs(m).map(\.path)
        let rewrite: ((@escaping (String) -> Void) async throws -> (prompt: String, sources: [Source]))? =
            improve ? { [weak self] step in
                guard let self else { throw CancellationError() }
                return try await self.improveDescription(prompt, onStep: step)
            } : nil
        return await images.make(prompt: prompt, size: size, system: system, files: files, seed: seed, improve: rewrite) { [weak self] in
                guard let self else { return nil }
                if !self.models.status(m.id).isComplete { return L("De bestanden voor afbeeldingen zijn er nog niet helemaal.") }
                if !measuring && self.bench.running != nil { return L("Er loopt een meting. Wacht tot die klaar is.") }
                if self.documents.busy { return L("De documentmodule is bezig. Wacht tot die klaar is of stop hem.") }
                // the engine says it is done a moment after the description came in
                for _ in 0..<8 where self.metrics.engineBusy && !self.chat.busy { try? await Task.sleep(for: .milliseconds(500)) }
                if self.chat.busy || self.metrics.engineBusy { return L("De engine werkt aan een antwoord. Wacht tot dat klaar is of stop het.") }
                await self.documentEngines.fast.stopAndWait()
                // a small chat model can stay beside the image when this Mac has the room for a whole one; else it makes room
                let need = ImagePlanner.wholeBytes(size) + ImagePlanner.wholeMargin + MemoryPlanner.osHeadroom
                if SystemInfo.availableMemory() < need { await self.engine.stopAndWait() }
                self.refreshSystem()
                return nil
            }
    }

    /// Switch to another model: stops the engine first when it runs a different one.
    func select(_ id: String) async {
        let wasActive: Bool
        switch engine.state {
        case .running, .starting: wasActive = true
        default: wasActive = false
        }
        if wasActive && engine.model?.id != id {
            await engine.stopAndWait()
            await documentEngines.fast.stopAndWait()     // what fits next to the new model is worked out again
        }
        selectedModelID = id
        if wasActive && engine.model?.id != id && canStart { startEngine() }
    }

    /// Raise iogpu.wired_limit_mb so the GPU may keep more experts resident (asks for an admin password; resets on reboot).
    func raiseWiredLimit(mb: Int) {
        let script = "do shell script \"/usr/sbin/sysctl iogpu.wired_limit_mb=\(mb)\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        refreshSystem()
    }
}
