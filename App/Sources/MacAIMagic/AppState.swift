import Foundation
import Combine
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
    /// The app as the model sees it (app_status, app_action).
    private(set) lazy var appControl = AppControl(app: self)
    // Taken: the scheduled tasks and their runs (TaskRunner.swift)
    let tasks = TaskStore()
    /// The conversations of task runs that are going on, with their task.
    @Published var taskRuns: [Conversation.ID: UUID] = [:]
    var modelStartedByTasks = false
    /// Tasks waiting for the model to load before their run starts.
    @Published var tasksStarting: Set<UUID> = []
    var taskTimer: Timer?
    var taskActivity: NSObjectProtocol?
    /// What the last heartbeat found, for Instellingen → Taken.
    @Published var heartbeatStatus: String?
    private var tasksChanged: AnyCancellable?

    /// There is something that may run with the window closed.
    var hasBackgroundWork: Bool { tasks.tasks.contains(where: \.enabled) || Settings.shared.heartbeat || !taskRuns.isEmpty }

    /// The window closed and the app stays in the menu bar: no Dock icon, and the model stops unless something runs.
    func windowClosed() {
        NSApp.setActivationPolicy(.accessory)
        if Settings.shared.stopModelOnClose && !chat.busy && taskRuns.isEmpty {
            engine.stop()
            documentEngines.fast.stop()
        }
    }

    @AppStorage("selectedModel") var selectedModelID = "deepseek-v4.1-flash-compact" {
        didSet {
            // the heavy model is never the fast one too, however it was chosen (a card, the system check, Compare)
            if Settings.shared.fastModel == selectedModelID { Settings.shared.fastModel = "" }
            loadIndex()
            objectWillChange.send()
        }
    }
    @Published private(set) var system = SystemInfo.current()
    /// For the tests: the app as another Mac sees it.
    var simulatedSystem: SystemInfo? { didSet { refreshSystem() } }
    @Published private(set) var index: GGUFIndex?
    @Published private(set) var indexError: String?

    init() {
        chat.metrics = metrics
        chat.taskStore = tasks
        chat.appControl = appControl
        // the menu bar item depends on the tasks
        tasksChanged = tasks.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        LocalModel.metrics = metrics
        engine.onStateChange = { [weak metrics] state in
            switch state {
            case .running, .starting: metrics?.fast = true
            default: metrics?.fast = false
            }
        }
        // the second engine writes too (documents, a description for an image): the gauge counts it
        let fastPort = documentEngines.fast.baseURL.port
        documentEngines.fast.onStateChange = { [weak metrics] state in
            switch state {
            case .running, .starting: metrics?.fastPort = fastPort
            default: metrics?.fastPort = nil
            }
        }
        images.onRate = { [weak metrics] rate in metrics?.imageRate = rate }
        if Settings.shared.fastModel == selectedModelID { Settings.shared.fastModel = "" }   // a choice from before that rule
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

    /// The chat's model, when it runs only as the fast model on the second engine: the chat does not talk to that one.
    var chatModelOnFast: ModelInfo? {
        let fast = documentEngines.fast
        guard engine.state == .stopped || { if case .failed = engine.state { return true }; return false }() else { return nil }
        guard fast.state.isRunning || { if case .starting = fast.state { return true }; return false }() else { return nil }
        return fast.model?.id == selectedModel?.id ? fast.model : nil
    }

    /// `forImage`: the image being made needs the chat model first, to improve its description.
    func startEngine(forImage: Bool = false, helpersChecked: Bool = false) {
        // the same model twice in memory helps nothing: the copy on the second engine makes room for the real one
        if chatModelOnFast != nil {
            Task { await documentEngines.fast.stopAndWait(); startEngine(forImage: forImage) }
            return
        }
        // a helper that does not answer would make the start wait for minutes: it stays out, and Cluster says why
        if !helpersChecked && cluster.role == .main && !cluster.selected.isEmpty {
            Task { await cluster.checkBeforeStart(); startEngine(forImage: forImage, helpersChecked: true) }
            return
        }
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
        let rpc = cluster.rpcArgument
        engine.start(model: m, shards: models.shardURLs(m), plan: plan,
                     vision: useVision(index) ? models.visionURL(m) : nil, draft: models.draftURL(m),
                     rpc: rpc)
        if rpc != nil {
            // the model parts go to the helpers while it loads: Cluster shows how far
            let expected = ClusterController.expectedTransfer(modelBytes: m.memory ?? m.totalSize, helperBudgets: cluster.helperBudgets,
                                                              localBudget: system.gpuWorkingSet)
            Task { [engine, cluster] in
                await cluster.watchTransfer(loading: { if case .starting = engine.state { return true }; return false }, expected: expected)
            }
        }
    }

    /// One image. Next to a chat model there is rarely room, so what runs stops first: not an answer being written or a
    /// measurement, those go first, and the chat engine is not started again by itself.
    func makeImage(prompt: String, size: ImageSize) {
        Task { await makeImageNow(prompt: prompt, size: size, improve: Settings.shared.imageImprove) }
    }

    /// The model that writes the better description, and on which engine.
    struct Describer: Equatable {
        let model: ModelInfo
        /// On the second engine, the fast model's (Snel); else the app's own, the heavy model's (Zwaar).
        let onFast: Bool
        var role: String { onFast ? L("Snel") : L("Zwaar") }
    }

    /// The fast model (Snel) writes it: it is small, starts in seconds and can stay beside the image. The heavy model only
    /// when there is no other, or when it runs already and the fast one would not fit beside it.
    nonisolated static func describer(heavy: ModelInfo?, downloaded: [ModelInfo], chosenFast: String, heavyRunning: Bool,
                                      fastRunning: ModelInfo?, available: UInt64) -> Describer? {
        if let running = fastRunning { return Describer(model: running, onFast: true) }
        func size(_ m: ModelInfo) -> UInt64 { m.memory ?? m.totalSize }
        let others = downloaded.filter { $0.id != heavy?.id }
        let chosen = others.first { $0.id == chosenFast }
        let smallest = others.min { size($0) < size($1) }.flatMap { m in heavy.map { size(m) < size($0) } ?? true ? m : nil }
        if let fast = chosen ?? smallest {
            let fits = size(fast) + MemoryPlanner.minimumOverhead + MemoryPlanner.osHeadroom <= available
            if !(heavyRunning && !fits) || heavy == nil { return Describer(model: fast, onFast: true) }
        }
        return heavy.map { Describer(model: $0, onFast: false) }
    }

    var describer: Describer? {
        let downloaded = models.catalog.models.filter { models.status($0.id).isComplete }
        let fast = documentEngines.fast
        return Self.describer(heavy: selectedModel.flatMap { downloaded.contains($0) ? $0 : nil }, downloaded: downloaded,
                              chosenFast: Settings.shared.fastModel, heavyRunning: engine.state.isRunning,
                              fastRunning: fast.state.isRunning ? fast.model : nil, available: SystemInfo.availableMemory())
    }

    /// The chat model writes a better description: started first when it does not run, and afterwards the engines make room
    /// as for any image. Fails without a downloaded chat model.
    private func improveDescription(_ text: String, onStep: @escaping (String) -> Void) async throws -> (prompt: String, sources: [Source]) {
        guard let writer = describer else { throw ImproveError(L("Er is geen chatmodel gedownload.")) }
        let model = writer.model
        let target = writer.onFast ? documentEngines.fast : engine
        if !(target.state.isRunning && target.model?.id == model.id) {
            onStep(L("\(model.shortName) (\(writer.role)) laden…"))
            if writer.onFast {
                try await documentEngines.startForImage(model)
            } else {
                guard chatModelReady else { throw ImproveError(L("\(model.name) kan nu niet starten.")) }
                startEngine(forImage: true)
                let started = Date()
                while !engine.state.isRunning {
                    if case .failed(let why) = engine.state { throw ImproveError(why) }
                    if Date().timeIntervalSince(started) > 1800 { throw ImproveError(L("\(model.name) startte niet.")) }
                    try await Task.sleep(for: .milliseconds(500))
                }
            }
        }
        onStep(L("\(model.shortName) (\(writer.role)) schrijft de beschrijving…"))
        let base = target.baseURL
        let result = try await ImagePrompt.improve(text, model: model.name, send: { body in
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
        }, onStep: { onStep(model.shortName + " " + $0) })
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
        return await images.make(prompt: prompt, size: size, system: system, files: files, seed: seed, drawer: m.shortName,
                                 improve: rewrite) { [weak self] in
                guard let self else { return nil }
                if !self.models.status(m.id).isComplete { return L("De bestanden voor afbeeldingen zijn er nog niet helemaal.") }
                if !measuring && self.bench.running != nil { return L("Er loopt een meting. Wacht tot die klaar is.") }
                if self.documents.busy { return L("De documentmodule is bezig. Wacht tot die klaar is of stop hem.") }
                // the engine says it is done a moment after the description came in
                for _ in 0..<8 where self.metrics.engineBusy && !self.chat.busy { try? await Task.sleep(for: .milliseconds(500)) }
                if self.chat.busy || self.metrics.engineBusy { return L("De engine werkt aan een antwoord. Wacht tot dat klaar is of stop het.") }
                // a model stays beside the image when this Mac has the room for a whole one; else it makes room, the largest first
                let need = ImagePlanner.wholeBytes(size) + ImagePlanner.wholeMargin + MemoryPlanner.osHeadroom
                for engine in [self.engine, self.documentEngines.fast] where SystemInfo.availableMemory() < need {
                    guard engine.state != .stopped, let name = engine.model?.shortName else { continue }
                    self.images.step(L("\(name) stopt om ruimte te maken voor de afbeelding"))
                    await engine.stopAndWait()
                }
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
