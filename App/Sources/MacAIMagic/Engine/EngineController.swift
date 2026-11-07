import Foundation
import IOKit.pwr_mgt

/// Runs llama-server (the patched llama.cpp engine) with the memory plan, and follows its log and health.
@MainActor
final class EngineController: ObservableObject {
    enum State: Equatable {
        case stopped, starting(String), running, failed(String)
        var isRunning: Bool { self == .running }
    }

    @Published private(set) var state: State = .stopped {
        didSet { onStateChange?(state) }
    }
    var onStateChange: ((State) -> Void)?
    @Published private(set) var logTail: [String] = []
    @Published private(set) var loadProgress: Double = 0

    private var process: Process?
    /// Keeps the Mac awake while the engine runs: during idle sleep a running answer or benchmark freezes for minutes.
    private var sleepAssertion: IOPMAssertionID = 0
    private var logHandle: FileHandle?
    private var logPending = ""
    private var healthTask: Task<Void, Never>?

    /// A second engine next to the app's own: its own port, only reachable from this Mac, and its own log.
    private let fixedPort: Int?
    private let logFile: URL

    init(port: Int? = nil, logFile: URL = Paths.engineLog) {
        fixedPort = port
        self.logFile = logFile
    }

    private var host: String { fixedPort == nil ? Settings.shared.host : "127.0.0.1" }
    private var port: Int { fixedPort ?? Settings.shared.port }
    var baseURL: URL { URL(string: "http://\(host):\(port)")! }

    /// The model the engine runs (or last ran).
    @Published private(set) var model: ModelInfo?

    func arguments(model: ModelInfo, shards: [URL], plan: MemoryPlan, vision: URL?, draft: URL? = nil, rpc: String? = nil) -> [String] {
        let s = Settings.shared
        var args = [
            "--model", shards[0].path,
            "--host", host, "--port", String(port),
            "--ctx-size", String(plan.contextSize),
            "--n-gpu-layers", plan.gpuLayers.map(String.init) ?? "999",
            "--flash-attn", "on",
            // measured on an M3 Max: ubatch 1024 reads prompts ~20% faster than 512; for a model that fits, 2048 grows the
            // compute buffers past the wired limit and writing drops from 20 to 3 tok/s. A model larger than memory reads
            // its uncached experts from the SSD once per ubatch, so there 4096 reads a 2,500-token prompt in one pass:
            // 81 instead of 60 tok/s (DeepSeek Q4), 92 instead of 56 (GLM Q4); the plan makes room for the buffers
            "--ubatch-size", plan.expertCache > 0 ? "4096" : "1024", "--batch-size", plan.expertCache > 0 ? "4096" : "2048",
            "--fit", "off",               // the plan above already decided where every tensor goes
            "--threads", String(plan.threads),
            "--parallel", "1",            // one conversation at a time keeps the whole KV and compute budget for it
            "--jinja",
            "--reasoning-format", "deepseek",   // thinking goes to reasoning_content, for both DeepSeek and GLM
            "--metrics",
            "--alias", model.id,
        ]
        if plan.tensorSplit.isEmpty {
            args += ["--n-cpu-moe", String(plan.cpuMoELayers)]
        } else {
            // cluster: llama.cpp puts the helpers first, so the layers kept in this Mac's memory are the last ones
            args += ["--tensor-split", plan.tensorSplit.map(String.init).joined(separator: ",")]
            if !plan.hostExpertLayers.isEmpty {
                let layers = plan.hostExpertLayers.map(String.init).joined(separator: "|")
                args += ["--override-tensor", "blk\\.(\(layers))\\.ffn_(up|down|gate|gate_up)_(ch|)exps=CPU"]
            }
        }
        // larger than memory: the experts stay mapped from the file, never repacked into RAM, and the GPU caches the
        // ones the conversation uses most
        // a model without experts neither: the same speed with less private memory (measured on the Windows version)
        if !plan.fitsInMemory || plan.experts == 0 { args += ["--no-repack"] }
        if plan.expertCache > 0 { args += ["--moe-cache-mib", String(plan.expertCache >> 20)] }
        if let vision { args += ["--mmproj", vision.path] }
        // cluster: the helpers' GPUs join as RPC devices
        if let rpc { args += ["--rpc", rpc] }
        // multi-token prediction: a small head guesses the next tokens, the model checks them in one pass
        // (measured on GLM-5.3 Compact: 2 tokens ahead gives +44% on code, +20% on explanations and the same
        // speed on creative text; 3+ ahead loses on creative text because too many guesses are rejected).
        // Not for a model larger than memory: checking 3 tokens needs more experts from the SSD, and the head runs without
        // the expert cache (GLM-5.3-Flash Q4: 5.2-5.5 tok/s with MTP, 5.2-5.9 without)
        if s.mtp && model.hasMTP && plan.expertCache == 0 {
            if model.mtp == "file", let draft { args += ["--spec-type", "draft-mtp", "--model-draft", draft.path, "--spec-draft-n-max", "2"] }
            else if model.mtp == "builtin" { args += ["--spec-type", "draft-mtp", "--spec-draft-n-max", "2"] }
        }
        return args
    }

    func start(model: ModelInfo, shards: [URL], plan: MemoryPlan, vision: URL?, draft: URL? = nil, rpc: String? = nil) {
        guard process == nil else { return }
        guard let bin = Paths.engineBinary("llama-server") else {
            state = .failed(L("Engine niet gevonden. Bouw hem met scripts/build_engine.sh."))
            return
        }
        let p = Process()
        p.executableURL = bin
        p.arguments = arguments(model: model, shards: shards, plan: plan, vision: vision, draft: draft, rpc: rpc)
        self.model = model
        var env = ProcessInfo.processInfo.environment
        // not on the command line: the process list and the log would show it
        if !Settings.shared.apiKey.isEmpty { env["LLAMA_API_KEY"] = Settings.shared.apiKey }
        env["LLAMA_ARG_LAZY_MODE"] = "auto"   // tables over 4 GB (DeepSeek's Engram) are read row by row from the SSD
        // larger than memory: reading the whole file ahead at load would take minutes and evict itself
        if !plan.fitsInMemory { env["LLAMA_MMAP_PREFETCH"] = "0" }
        if plan.expertCache > 0 {
            // the experts in the GPU cache are saved when the engine stops and read back at the next start, so the first
            // answer is as fast as the later ones
            env["LLAMA_MOE_CACHE_FILE"] = Paths.modelDir(model.id).appendingPathComponent("expert-cache.bin").path
            // writing (up to 8 tokens at once) reads its experts from the cache; prompts copy the experts they use to the
            // GPU without pushing the conversation's experts out of the cache
            env["LLAMA_MOE_CACHE_MAX_BATCH"] = "8"
            env["GGML_OP_OFFLOAD_MIN_BATCH"] = "9"
        }
        p.environment = env

        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: logFile)
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
            state = .failed(L("Kon de engine niet starten: \(error.localizedDescription)"))
            return
        }
        process = p
        preventSleep(true)
        loadProgress = 0
        logTail = ["$ \(bin.lastPathComponent) " + p.arguments!.joined(separator: " ")]
        state = .starting(L("Model laden…"))
        pollHealth()
    }

    /// Shows a state without a process behind it (README screenshots).
    func previewState(_ s: State, model: ModelInfo? = nil) { state = s; self.model = model }

    /// Stop and wait until the process is gone (switching models needs the memory back first).
    func stopAndWait() async {
        guard process != nil else { state = .stopped; return }
        stop()
        for _ in 0..<60 where process != nil { try? await Task.sleep(for: .milliseconds(500)) }
    }

    /// Set while a stop that was asked for is under way: how the process then ends is no failure.
    private var stopping = false

    func stop() {
        stopping = process != nil
        healthTask?.cancel()
        process?.interrupt()
        let p = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { if p?.isRunning == true { p?.terminate() } }
    }

    /// The GGUF metadata dump is noise (hundreds of lines), and carries the file's original names: not in the log either.
    nonisolated static func keepsInLog(_ line: some StringProtocol) -> Bool {
        !(line.contains("llama_model_loader:") || line.contains("print_info: general.") || line.contains("quantize.")
            || line.range(of: "maya", options: .caseInsensitive) != nil)
    }

    private func consume(_ text: String, raw: Data) {
        // whole lines only: a chunk can end halfway a line
        logPending += text
        if let end = logPending.lastIndex(of: "\n") {
            let lines = logPending[...end].split(separator: "\n", omittingEmptySubsequences: false).dropLast()
            let kept = lines.filter { Self.keepsInLog($0) }.joined(separator: "\n")
            if !kept.isEmpty { logHandle?.write(Data((kept + "\n").utf8)) }
            logPending = String(logPending[logPending.index(after: end)...])
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard Self.keepsInLog(line) else { continue }
            logTail.append(String(line))
            // llama.cpp prints a dot per loaded chunk; the tensor loader also reports "loading tensors"
            if line.contains("load_tensors") { state = .starting(L("Gewichten laden…")) }
            if line.contains("warming up") { state = .starting(L("Opwarmen…")); loadProgress = 0.95 }
            if line.contains("lazy read enabled") { state = .starting(L("Engram-tabellen koppelen…")) }
        }
        if text.allSatisfy({ $0 == "." || $0 == "\n" }) { loadProgress = min(0.9, loadProgress + 0.002 * Double(text.count)) }
        if logTail.count > 400 { logTail.removeFirst(logTail.count - 400) }
    }

    private func terminated(code: Int32) {
        healthTask?.cancel()
        process = nil
        preventSleep(false)
        try? logHandle?.close()
        logHandle = nil
        // 0: clean exit, 2 / 15: our interrupt or terminate. A stop that was asked for is a stop whatever the exit
        // code: llama.cpp's Metal backend can assert while it shuts down after a cancelled request (code 6,
        // "rsets->data count == 0"), and that is no failure of the model.
        let asked = stopping
        stopping = false
        if [0, 2, 15].contains(code) || asked {
            state = .stopped
        } else {
            let last = logTail.last(where: { $0.contains("error") || $0.contains("failed") }) ?? logTail.last ?? ""
            state = .failed(L("Engine gestopt (code \(code)): \(last)"))
        }
    }

    /// The display may still sleep; the system does not, until the engine stops.
    private func preventSleep(_ on: Bool) {
        if on, sleepAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "MacAIMagic: het model draait" as CFString, &sleepAssertion)
        } else if !on, sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
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

/// Engines left behind by an app that was forced to quit: they hold their port and over 100 GB of memory, and a new
/// engine would fail on that. Engines of an app that still runs have that app as parent, and are left alone.
enum EngineOrphans {
    static func pids(inProcessList list: String) -> [Int32] {
        list.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, parts[1] == "1",
                  parts[2].contains("/Contents/Resources/engine/llama-server") || parts[2].contains("/Contents/Resources/engine/ggml-rpc-server")
            else { return nil }
            return Int32(parts[0])
        }
    }

    static func stop() {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        guard (try? ps.run()) != nil else { return }
        let list = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        let orphans = pids(inProcessList: list)
        for pid in orphans { kill(pid, SIGINT) }    // as the app stops them: the expert cache gets saved
        for _ in 0..<40 where orphans.contains(where: { kill($0, 0) == 0 }) { usleep(250_000) }
        for pid in orphans where kill(pid, 0) == 0 { kill(pid, SIGTERM) }
    }
}

