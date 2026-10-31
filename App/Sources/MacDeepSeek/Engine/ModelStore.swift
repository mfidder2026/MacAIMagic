import Foundation

/// The model files on disk: what is there, what is verified, and the download that fetches the rest.
@MainActor
final class ModelStore: ObservableObject {
    struct FileStatus: Identifiable {
        let name: String
        let expected: UInt64
        var have: UInt64
        var verified: Bool
        var id: String { name }
        var fraction: Double { expected == 0 ? 0 : min(1, Double(have) / Double(expected)) }
        /// Downloaded by hand into the folder: the exact size is enough to use it (sha256 is checked by our download script)
        var complete: Bool { verified || have == expected }
    }

    @Published private(set) var files: [FileStatus] = []
    @Published private(set) var downloading = false
    @Published private(set) var speed: Double = 0          // bytes per second
    @Published private(set) var lastMessage = ""

    private var process: Process?
    private var timer: Timer?
    private var lastTotal: UInt64 = 0
    private var lastTick = Date()

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var expectedTotal: UInt64 { files.reduce(0) { $0 + $1.expected } }
    var haveTotal: UInt64 { files.reduce(0) { $0 + $1.have } }
    var isComplete: Bool { !files.isEmpty && files.prefix(Paths.modelShards.count).allSatisfy(\.complete) }
    var allVerified: Bool { !files.isEmpty && files.allSatisfy(\.verified) }
    /// The headers sit at the start of every shard, so the plan can be made long before the download ends.
    var headersAvailable: Bool { files.prefix(5).allSatisfy { $0.have > 64 << 20 } }
    var etaSeconds: Double? { speed > 1 ? Double(expectedTotal - haveTotal) / speed : nil }

    func refresh() {
        let names = Paths.modelShards + [Paths.visionProjector]
        let sizes = Paths.modelShardSizes + [Paths.visionProjectorSize]
        let fm = FileManager.default
        files = zip(names, sizes).map { name, size in
            let url = Paths.modelDir.appendingPathComponent(name)
            let have = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? UInt64) ?? 0
            let ok = fm.fileExists(atPath: url.path + ".ok")
            return FileStatus(name: name, expected: size, have: have, verified: ok)
        }
        let now = Date(), total = haveTotal
        let dt = now.timeIntervalSince(lastTick)
        if lastTotal == 0 {
            lastTotal = total   // first look: nothing to compare with yet
            lastTick = now
        } else if dt > 0.5 {
            let inst = total > lastTotal ? Double(total - lastTotal) / dt : 0
            speed = speed == 0 ? inst : 0.8 * speed + 0.2 * inst
            lastTotal = total
            lastTick = now
        }
        // a download started outside the app (or by an earlier run) counts too: never start a second one on the same files
        if process == nil { downloading = Self.externalDownloadRunning() }
    }

    private static func externalDownloadRunning() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "Maya-GGUF/resolve"]
        p.standardOutput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    func shardURLs() -> [URL] { Paths.modelShards.map { Paths.modelDir.appendingPathComponent($0) } }

    func startDownload() {
        guard process == nil, !downloading, let script = Paths.script("download_model.sh") else {
            lastMessage = "download_model.sh niet gevonden"
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path, Paths.modelDir.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let s = String(decoding: h.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { return }
            Task { @MainActor in self?.lastMessage = s.components(separatedBy: "\n").last ?? s }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.process = nil
                self?.downloading = false
                self?.refresh()
            }
        }
        do { try p.run(); process = p; downloading = true } catch { lastMessage = error.localizedDescription }
    }

    func stopDownload() {
        process?.terminate()
        // curl children keep their partial files; the next start resumes them
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", "Maya-GGUF/resolve"]
        try? kill.run()
    }
}
