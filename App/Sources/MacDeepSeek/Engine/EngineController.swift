import Foundation

/// Runs llama-server (the patched llama.cpp engine) with the memory plan, and follows its log and health.
@MainActor
final class EngineController: ObservableObject {
    enum State: Equatable {
        case stopped, starting(String), running, failed(String)
        var isRunning: Bool { self == .running }
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var logTail: [String] = []
    @Published private(set) var loadProgress: Double = 0

    private var process: Process?
    private var logHandle: FileHandle?
    private var healthTask: Task<Void, Never>?

    var baseURL: URL { URL(string: "http://\(Settings.shared.host):\(Settings.shared.port)")! }

    func arguments(plan: MemoryPlan, vision: Bool) -> [String] {
        let s = Settings.shared
        var args = [
            "--model", Paths.modelDir.appendingPathComponent(Paths.modelShards[0]).path,
            "--host", s.host, "--port", String(s.port),
            "--ctx-size", String(plan.contextSize),
            "--n-gpu-layers", "999",
            "--n-cpu-moe", String(plan.cpuMoELayers),
            "--flash-attn", "on",
            // measured on an M3 Max with Maya-XS: ubatch 1024 reads prompts ~20% faster than 512;
            // 2048 grows the compute buffers past the wired limit and writing drops from 20 to 3 tok/s
            "--ubatch-size", "1024", "--batch-size", "2048",
            "--fit", "off",               // the plan above already decided where every tensor goes
            "--threads", String(plan.threads),
            "--parallel", "1",            // one conversation at a time keeps the whole KV and compute budget for it
            "--jinja",
            "--reasoning-format", "deepseek",
            "--metrics",
            "--alias", "deepseek-v4.1-flash",
        ]
        if vision {
            args += ["--mmproj", Paths.modelDir.appendingPathComponent(Paths.visionProjector).path]
        }
        if !s.apiKey.isEmpty { args += ["--api-key", s.apiKey] }
        return args
    }

    func start(plan: MemoryPlan, vision: Bool) {
        guard process == nil else { return }
        guard let bin = Paths.engineBinary("llama-server") else {
            state = .failed("Engine niet gevonden. Bouw hem met scripts/build_engine.sh.")
            return
        }
        let p = Process()
        p.executableURL = bin
        p.arguments = arguments(plan: plan, vision: vision)
        var env = ProcessInfo.processInfo.environment
        env["LLAMA_ARG_LAZY_MODE"] = "auto"   // Engram tables are read row by row from the SSD
        p.environment = env

        FileManager.default.createFile(atPath: Paths.engineLog.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: Paths.engineLog)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.consume(text, raw: data) }
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in self?.terminated(code: proc.terminationStatus) }
        }
        do {
            try p.run()
        } catch {
            state = .failed("Kon de engine niet starten: \(error.localizedDescription)")
            return
        }
        process = p
        loadProgress = 0
        logTail = ["$ \(bin.lastPathComponent) " + p.arguments!.joined(separator: " ")]
        state = .starting("Model laden…")
        pollHealth()
    }

    /// Shows a state without a process behind it (README screenshots).
    func previewState(_ s: State) { state = s }

    func stop() {
        healthTask?.cancel()
        process?.interrupt()
        let p = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { if p?.isRunning == true { p?.terminate() } }
    }

    private func consume(_ text: String, raw: Data) {
        logHandle?.write(raw)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            logTail.append(String(line))
            // llama.cpp prints a dot per loaded chunk; the tensor loader also reports "loading tensors"
            if line.contains("load_tensors") { state = .starting("Gewichten laden…") }
            if line.contains("warming up") { state = .starting("Opwarmen…"); loadProgress = 0.95 }
            if line.contains("lazy read enabled") { state = .starting("Engram-tabellen koppelen…") }
        }
        if text.allSatisfy({ $0 == "." || $0 == "\n" }) { loadProgress = min(0.9, loadProgress + 0.002 * Double(text.count)) }
        if logTail.count > 400 { logTail.removeFirst(logTail.count - 400) }
    }

    private func terminated(code: Int32) {
        healthTask?.cancel()
        process = nil
        try? logHandle?.close()
        logHandle = nil
        if case .running = state, code == 0 || code == 2 || code == 15 {
            state = .stopped
        } else if code == 0 || code == 2 || code == 15 {
            state = .stopped
        } else {
            let last = logTail.last(where: { $0.contains("error") || $0.contains("failed") }) ?? logTail.last ?? ""
            state = .failed("Engine gestopt (code \(code)): \(last)")
        }
    }

    private func pollHealth() {
        healthTask?.cancel()
        let url = baseURL.appendingPathComponent("health")
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                var req = URLRequest(url: url)
                req.timeoutInterval = 2
                if let (_, resp) = try? await URLSession.shared.data(for: req),
                   (resp as? HTTPURLResponse)?.statusCode == 200 {
                    self.state = .running
                    self.loadProgress = 1
                    return
                }
            }
        }
    }
}
