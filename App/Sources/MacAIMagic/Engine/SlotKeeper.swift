import Foundation

/// Keeps a conversation's place in the engine across a switch and a restart.
///
/// The engine has one slot: what it read of a conversation (its KV cache) is lost when another conversation, a task,
/// the heartbeat or Documents uses it, and when the engine stops. Reading it again costs minutes on a large model
/// (DeepSeek-V4.1-Flash reads ~145 tokens/s: a conversation of 30,000 tokens is 3.5 minutes). llama-server can write a
/// slot to a file and read it back (`--slot-save-path`, `/slots/0?action=save|restore`): measured with Ling-3.0-tiny,
/// a 6,820-token prompt took 23 s to read, 0.05 s to save and 0.02 s to restore, also in an engine started anew.
///
/// So: when another conversation gets the engine, the one that had it is saved; a conversation that comes back is
/// restored first. Before the engine stops, the conversation in it is saved. The engine compares the restored tokens
/// with the new prompt itself, so a conversation that changed meanwhile only reuses what is still the same.
@MainActor
final class SlotKeeper {
    /// The engine's address, and what the saved state belongs to: model, context and vision (a state only fits the
    /// same setup). Nil: the engine does not keep states (stopped, a cluster, or switched off).
    private(set) var baseURL: URL?
    private(set) var key: String?
    /// The conversation whose state is in the engine now, and whether it changed since it was saved or restored.
    private(set) var current: UUID?
    private var unsaved = false
    /// The conversation in the engine changed since it was saved.
    var hasUnsaved: Bool { current != nil && unsaved && Settings.shared.keepEngineMemory }
    /// Saves and restores, in order, for the tests.
    private(set) var log: [String] = []
    let folder: URL

    nonisolated static var defaultFolder: URL { Paths.appSupport.appendingPathComponent("EngineMemory", isDirectory: true) }

    init(folder: URL = SlotKeeper.defaultFolder) {
        self.folder = folder
        Self.all.append(Weak(self))
    }

    /// The engine started with `--slot-save-path folder`: states fit this key from now on.
    func started(baseURL: URL, key: String) {
        self.baseURL = baseURL
        self.key = key
        current = nil
        unsaved = false
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// The engine stopped: nothing is in it any more.
    func stopped() {
        baseURL = nil
        key = nil
        current = nil
        unsaved = false
    }

    nonisolated static func fileName(key: String, conversation: UUID) -> String {
        // llama-server takes a plain file name: no slashes, no spaces
        let safe = key.map { $0.isLetter || $0.isNumber || "-_.".contains($0) ? $0 : "_" }
        return String(safe) + "--" + conversation.uuidString + ".bin"
    }

    /// `owner` gets the engine for an answer: the conversation that had it is saved, and `owner`'s state comes back.
    func enter(_ owner: UUID) async {
        guard let key, baseURL != nil, Settings.shared.keepEngineMemory else { return }
        if current == owner { unsaved = true; return }
        await saveCurrent()
        current = owner
        unsaved = true
        let name = Self.fileName(key: key, conversation: owner)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) else { return }
        if await call("restore", name) {
            log.append("restore " + owner.uuidString)
            touch(name)
        }
    }

    /// Something else uses the engine (Documents, an image description): the conversation in it is saved first.
    func yield() async {
        await saveCurrent()
        current = nil
    }

    /// Writes the state of the conversation in the engine to its file, when it changed.
    func saveCurrent() async {
        guard let key, let owner = current, unsaved, Settings.shared.keepEngineMemory else { return }
        unsaved = false
        let name = Self.fileName(key: key, conversation: owner)
        if await call("save", name) {
            log.append("save " + owner.uuidString)
            prune()
        }
    }

    private func request(_ action: String, _ name: String) -> URLRequest? {
        guard let baseURL, var parts = URLComponents(url: baseURL.appendingPathComponent("slots/0"), resolvingAgainstBaseURL: false)
        else { return nil }
        parts.queryItems = [URLQueryItem(name: "action", value: action)]
        guard let url = parts.url else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !Settings.shared.apiKey.isEmpty { req.setValue("Bearer \(Settings.shared.apiKey)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["filename": name])
        // a DeepSeek state is ~5 GB: a few seconds on the SSD
        req.timeoutInterval = 60
        return req
    }

    private func call(_ action: String, _ name: String) async -> Bool {
        guard let req = request(action, name), let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// For quitting the app, where nothing async runs any more: saves within `timeout` seconds, blocking.
    func saveBlocking(timeout: TimeInterval = 20) {
        guard let key, let owner = current, unsaved, Settings.shared.keepEngineMemory else { return }
        let name = Self.fileName(key: key, conversation: owner)
        guard var req = request("save", name) else { return }
        req.timeoutInterval = timeout
        let done = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            ok = (resp as? HTTPURLResponse)?.statusCode == 200
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + timeout) == .success, ok else { return }
        unsaved = false
        log.append("save " + owner.uuidString)
    }

    // MARK: - files

    private func touch(_ name: String) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: folder.appendingPathComponent(name).path)
    }

    /// The most the saved states may take: 40 GB, and never more than a tenth of the free disk.
    var limit: UInt64 {
        let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) } ?? 0
        return min(40_000_000_000, max(2_000_000_000, (free + used) / 10))
    }

    private var files: [(url: URL, size: UInt64, date: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return urls.filter { $0.pathExtension == "bin" }.map { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return (url, UInt64(v?.fileSize ?? 0), v?.contentModificationDate ?? .distantPast)
        }
    }

    var used: UInt64 { files.reduce(0) { $0 + $1.size } }

    /// Deletes the oldest states until they fit in `limit` (the newest always stays).
    func prune(limit custom: UInt64? = nil) {
        let cap = custom ?? limit
        var all = files.sorted { $0.date > $1.date }
        var total = all.reduce(0) { $0 + $1.size }
        while total > cap, all.count > 1, let oldest = all.popLast() {
            try? FileManager.default.removeItem(at: oldest.url)
            total -= oldest.size
        }
    }

    /// A conversation was deleted: its states go too.
    func forget(_ conversation: UUID) {
        for f in files where f.url.lastPathComponent.hasSuffix("--" + conversation.uuidString + ".bin") {
            try? FileManager.default.removeItem(at: f.url)
        }
        if current == conversation { current = nil; unsaved = false }
    }

    /// Everything saved, for Settings → Engine.
    func clear() {
        for f in files { try? FileManager.default.removeItem(at: f.url) }
        current = nil
        unsaved = false
    }

    /// A conversation was deleted: its states go, in every engine's folder.
    static func forgetAll(_ conversation: UUID) {
        all.removeAll { $0.keeper == nil }
        let keepers = all.compactMap(\.keeper)
        if keepers.isEmpty { SlotKeeper(folder: defaultFolder).forget(conversation) }
        for k in keepers { k.forget(conversation) }
    }

    /// Everything saved, from Settings.
    static func clearAll() {
        all.removeAll { $0.keeper == nil }
        let keepers = all.compactMap(\.keeper)
        if keepers.isEmpty { SlotKeeper(folder: defaultFolder).clear() }
        for k in keepers { k.clear() }
    }

    static var usedText: String {
        let k = all.compactMap(\.keeper).first { $0.folder == defaultFolder } ?? SlotKeeper(folder: defaultFolder)
        return ByteCountFormatter.string(fromByteCount: Int64(k.used), countStyle: .file)
    }

    // MARK: - the engine at an address

    private struct Weak { weak var keeper: SlotKeeper?; init(_ k: SlotKeeper) { keeper = k } }
    private static var all: [Weak] = []

    /// A request outside the chat goes to `url`: the keeper of the engine there saves its conversation first.
    static func yield(to url: URL) async {
        all.removeAll { $0.keeper == nil }
        for k in all.compactMap(\.keeper) where k.baseURL.map({ Self.sameEngine($0, url) }) == true { await k.yield() }
    }

    nonisolated static func sameEngine(_ a: URL, _ b: URL) -> Bool { a.port == b.port && (a.host == b.host || [a.host, b.host].allSatisfy { ["127.0.0.1", "localhost", "0.0.0.0"].contains($0) }) }
}
