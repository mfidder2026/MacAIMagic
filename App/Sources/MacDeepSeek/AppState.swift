import Foundation
import AppKit

/// Ties the parts together: model files, memory plan, engine, conversations, chat.
@MainActor
final class AppState: ObservableObject {
    let engine = EngineController()
    let models = ModelStore()
    let store = ConversationStore()
    let chat = ChatClient()

    @Published private(set) var system = SystemInfo.current()
    @Published private(set) var index: GGUFIndex?
    @Published private(set) var indexError: String?

    init() {
        loadIndex()
    }

    var plan: MemoryPlan? {
        guard let index else { return nil }
        return MemoryPlanner.plan(index: index, system: system, contextSize: Settings.shared.contextSize,
                                  vision: Settings.shared.vision)
    }

    var canStart: Bool { models.isComplete && plan != nil && Paths.engineBinary("llama-server") != nil }

    func loadIndex() {
        models.refresh()
        guard models.headersAvailable else { return }
        do {
            index = try GGUFIndex.load(shards: models.shardURLs(), sizes: Paths.modelShardSizes)
            indexError = nil
        } catch {
            indexError = error.localizedDescription
        }
    }

    func refreshSystem() { system = SystemInfo.current() }

    func startEngine() {
        if index == nil { loadIndex() }
        guard let plan else { return }
        engine.start(plan: plan, vision: Settings.shared.vision && models.files.last?.complete == true)
    }

    /// Raise iogpu.wired_limit_mb so the GPU may keep more experts resident (asks for an admin password; resets on reboot).
    func raiseWiredLimit(mb: Int) {
        let script = "do shell script \"/usr/sbin/sysctl iogpu.wired_limit_mb=\(mb)\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        refreshSystem()
    }
}
