import Foundation

/// The model files on disk for every model in the catalog: what is there, what is verified, and the downloads.
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

    struct ModelStatus {
        var files: [FileStatus] = []
        var vision: FileStatus?
        var draft: FileStatus?
        var have: UInt64 { files.reduce(0) { $0 + $1.have } }
        var expected: UInt64 { files.reduce(0) { $0 + $1.expected } }
        var fraction: Double { expected == 0 ? 0 : Double(have) / Double(expected) }
        var isComplete: Bool { !files.isEmpty && files.allSatisfy(\.complete) }
        var allVerified: Bool { !files.isEmpty && files.allSatisfy(\.verified) }
        /// The headers sit at the start of every shard, so the plan can be made long before a download ends.
        var headersAvailable: Bool { !files.isEmpty && files.allSatisfy { $0.have >= min($0.expected, 32 << 20) } }
    }

    @Published private(set) var status: [String: ModelStatus] = [:]
    @Published private(set) var downloading: Set<String> = []
    @Published private(set) var speed: Double = 0          // bytes per second, all downloads together
    @Published private(set) var lastMessage: [String: String] = [:]
    /// Why a download stopped, for the model card.
    @Published private(set) var lastError: [String: String] = [:]

    let catalog = ModelCatalog.shared
    private var processes: [String: Process] = [:]
    private var timer: Timer?
    private var lastTotal: UInt64 = 0
    private var lastTick = Date()
    private var lastExternalCheck = Date.distantPast
    private var external: Set<String> = []
    private var failures: [String: String] = [:]

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func status(_ id: String) -> ModelStatus { status[id] ?? ModelStatus() }

    func etaSeconds(_ id: String) -> Double? {
        let s = status(id)
        return speed > 1 && downloading.contains(id) ? Double(s.expected - s.have) / speed : nil
    }

    func refresh() {
        let fm = FileManager.default
        func file(_ dir: URL, _ name: String, _ size: UInt64) -> FileStatus {
            let url = dir.appendingPathComponent(name)
            let have = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? UInt64) ?? 0
            return FileStatus(name: name, expected: size, have: have, verified: fm.fileExists(atPath: url.path + ".ok"))
        }
        var next: [String: ModelStatus] = [:]
        for m in catalog.all {
            var s = ModelStatus()
            s.files = m.files.map { file(Paths.modelDir(m.id), $0.local, $0.size) }
            if let v = catalog.vision(for: m) { s.vision = file(Paths.visionDir, v.local, v.size) }
            if let d = m.draft { s.draft = file(Paths.modelDir(m.id), d.local, d.size) }
            next[m.id] = s
        }
        status = next

        let now = Date(), total = next.values.reduce(0) { $0 + $1.have + ($1.vision?.have ?? 0) }
        if lastTotal == 0 {
            lastTotal = total   // first look: nothing to compare with yet
            lastTick = now
        } else if now.timeIntervalSince(lastTick) > 0.5 {
            let inst = total > lastTotal ? Double(total - lastTotal) / now.timeIntervalSince(lastTick) : 0
            speed = speed == 0 ? inst : 0.8 * speed + 0.2 * inst
            lastTotal = total
            lastTick = now
        }
        // downloads started outside the app (or by an earlier run) count too: never start a second one on the same files.
        // Looking for them starts a process, so only every 15 s (every 2 s it kept launchd busy)
        if now.timeIntervalSince(lastExternalCheck) > 15 {
            lastExternalCheck = now
            external = Self.externalDownloads()
        }
        downloading = Set(processes.keys).union(catalog.all.map(\.id).filter { external.contains($0) })
    }

    func shardURLs(_ model: ModelInfo) -> [URL] { model.files.map { Paths.modelDir(model.id).appendingPathComponent($0.local) } }

    func draftURL(_ model: ModelInfo) -> URL? {
        guard let d = model.draft, status(model.id).draft?.complete == true else { return nil }
        return Paths.modelDir(model.id).appendingPathComponent(d.local)
    }

    func visionURL(_ model: ModelInfo) -> URL? {
        guard let v = catalog.vision(for: model), status(model.id).vision?.complete == true else { return nil }
        return Paths.visionDir.appendingPathComponent(v.local)
    }

    func startDownload(_ id: String) {
        guard processes[id] == nil, !downloading.contains(id), let script = Paths.script("download_model.sh") else {
            lastError[id] = L("download_model.sh niet gevonden")
            return
        }
        lastError[id] = nil
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path, id, Paths.modelsRoot.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let s = String(decoding: h.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { return }
            Task { @MainActor in
                let lines = s.components(separatedBy: "\n")
                self?.lastMessage[id] = lines.last ?? s
                if let failed = lines.last(where: { $0.hasPrefix("FAILED ") }) { self?.failures[id] = String(failed.dropFirst(7)) }
            }
        }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationReason == .exit ? proc.terminationStatus : 0     // a pause ends it with a signal
            Task { @MainActor in
                self?.processes[id] = nil
                self?.lastError[id] = Self.errorText(exitCode: code, failure: self?.failures[id])
                self?.failures[id] = nil
                self?.refresh()
            }
        }
        do { try p.run(); processes[id] = p; downloading.insert(id) } catch { lastError[id] = error.localizedDescription }
    }

    /// What the card says when the download script ends. Exit 3: the server offers another file than the catalog names.
    nonisolated static func errorText(exitCode: Int32, failure: String?) -> String? {
        switch exitCode {
        case 0: return nil
        case 3: return L("De maker heeft dit model op de server vervangen of verwijderd, dus deze versie van MacAIMagic kan het niet meer downloaden. Kijk of er een nieuwere MacAIMagic is.")
        default:
            guard let failure else { return L("De download is niet gelukt. Probeer het opnieuw.") }
            return L("De download is niet gelukt: \(failure). Verwijder het bestand en download het opnieuw.")
        }
    }

    func stopDownload(_ id: String) {
        processes[id]?.terminate()
        // curl keeps its partial files; the next start resumes them
        for pattern in ["download_model.sh \(id)", "curl .*/\(id)/"] {
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            kill.arguments = ["-f", pattern]
            try? kill.run()
            kill.waitUntilExit()
        }
    }

    /// Model ids with a running download_model.sh or curl writing into their folder.
    private static func externalDownloads() -> Set<String> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "command="]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return [] }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        var ids = Set<String>()
        for line in out.split(separator: "\n") where line.contains("download_model.sh") || line.hasPrefix("curl") {
            for m in ModelCatalog.shared.all where line.contains("/\(m.id)/") || line.hasSuffix(" \(m.id)") || line.contains(" \(m.id) ") {
                ids.insert(m.id)
            }
        }
        return ids
    }
}
