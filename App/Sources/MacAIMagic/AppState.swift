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

    @AppStorage("selectedModel") var selectedModelID = "deepseek-v4.1-flash-compact" {
        didSet { loadIndex(); objectWillChange.send() }
    }
    @Published private(set) var system = SystemInfo.current()
    @Published private(set) var index: GGUFIndex?
    @Published private(set) var indexError: String?

    init() {
        chat.metrics = metrics
        engine.onStateChange = { [weak metrics] state in
            switch state {
            case .running, .starting: metrics?.fast = true
            default: metrics?.fast = false
            }
        }
        loadIndex()
    }

    var selectedModel: ModelInfo? { models.catalog.model(selectedModelID) ?? models.catalog.models.first }

    var plan: MemoryPlan? {
        guard let index else { return nil }
        return MemoryPlanner.plan(index: index, system: system, contextSize: contextSize(index),
                                  vision: useVision(index), helpers: cluster.helperBudgets)
    }

    /// The chosen context, at most what the model was made for, and on a Mac with little memory at most what still
    /// lets the whole model stay in memory (a cluster gives this Mac room, so there the setting decides).
    func contextSize(_ index: GGUFIndex) -> Int {
        let chosen = index.contextLength > 0 ? min(Settings.shared.contextSize, index.contextLength) : Settings.shared.contextSize
        guard cluster.helperBudgets.isEmpty,
              let room = MemoryPlanner.contextRoom(index: index, system: system, vision: useVision(index)) else { return chosen }
        return min(chosen, room)
    }

    /// Vision when it is on and downloaded, unless it would leave the model too little room: then the model goes first.
    func useVision(_ index: GGUFIndex) -> Bool {
        guard Settings.shared.vision, selectedModel.flatMap(models.visionURL) != nil else { return false }
        guard cluster.helperBudgets.isEmpty, MemoryPlanner.contextRoom(index: index, system: system, vision: false) != nil else { return true }
        return (MemoryPlanner.contextRoom(index: index, system: system, vision: true) ?? 0) >= 16_384
    }

    var canStart: Bool {
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

    func refreshSystem() { system = SystemInfo.current() }

    func startEngine() {
        if index == nil { loadIndex() }
        guard let m = selectedModel, let index, var plan else { return }
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

    /// Switch to another model: stops the engine first when it runs a different one.
    func select(_ id: String) async {
        let wasActive: Bool
        switch engine.state {
        case .running, .starting: wasActive = true
        default: wasActive = false
        }
        if wasActive && engine.model?.id != id { await engine.stopAndWait() }
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
