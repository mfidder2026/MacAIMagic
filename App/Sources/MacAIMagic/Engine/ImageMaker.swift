import AppKit
import Foundation
import IOKit.pwr_mgt

struct ImageSize: Hashable, Identifiable {
    var width: Int
    var height: Int
    var id: String { key }
    var megapixels: Double { Double(width * height) / 1e6 }
    var key: String { "\(width)x\(height)" }

    init(width: Int, height: Int) { self.width = width; self.height = height }

    init?(key: String) {
        let parts = key.split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        self.init(width: parts[0], height: parts[1])
    }
}

/// How one image is made on this Mac.
struct ImagePlan: Equatable {
    var size: ImageSize
    var onGPU: Bool
    /// What the engine may keep on the GPU, in GiB; nil on the processor.
    var gpuBudgetGiB: Double?
    /// The last stage works in parts: slower, and much less memory.
    var tiling: Bool
    var threads: Int
}

/// A pure function of the Mac, as MemoryPlanner is. The engine runs once per image, so all its memory is free again afterwards.
///
/// On a Mac the GPU and everything else share one pool, so what the GPU may use leaves macOS its room as well.
///
/// Measured on an M3 Max (128 GB), FLUX.2 Klein 4B at 4 steps, the whole run with loading: on the GPU 512 in 17-20 s, 768 in 34 s,
/// 1024 in 60 s; extra wired memory 6.8 GB at 1024 without a limit, 4.1 GB with a budget of 5.2 GiB, 3.8 GB at 768 with 1.2 GiB
/// (as small a budget at 1024 fails cleanly, as on Windows). The processor, 12 threads: 512 in 78 s. Smaller Macs: not measured.
enum ImagePlanner {
    static let sizes = [ImageSize(width: 512, height: 512), ImageSize(width: 768, height: 768), ImageSize(width: 1024, height: 1024),
                        ImageSize(width: 1024, height: 768), ImageSize(width: 768, height: 1024)]

    /// From where every size runs on the GPU.
    static let largeBudget: UInt64 = 5_400_000_000
    /// From where the smaller sizes run on the GPU, with `smallBudgetGiB`.
    static let smallBudget: UInt64 = 3_400_000_000
    static let smallBudgetGiB = 1.2
    static let smallMegapixels = 0.6
    /// Below this much memory without room on the GPU the smallest size is the default: the next one has to work in parts there.
    static let littleMemory: UInt64 = 12 << 30

    /// The chat engine stopped first, so this is what macOS leaves over.
    private static func gpuRoom(_ s: SystemInfo) -> UInt64 {
        let headroom = MemoryPlanner.streamingHeadroom(s.physicalMemory)
        return min(s.effectiveGPULimit, s.physicalMemory > headroom ? s.physicalMemory - headroom : 0)
    }

    private static func fitsOnGPU(_ size: ImageSize, _ s: SystemInfo) -> Bool {
        let room = gpuRoom(s)
        return room >= largeBudget || (room >= smallBudget && size.megapixels <= smallMegapixels)
    }

    /// The image model works on the picture as tokens of 16 × 16 pixels, all of them in every step.
    static func tokensPerStep(_ size: ImageSize) -> Int { (size.width / 16) * (size.height / 16) }

    /// What a whole image takes on the GPU when the last stage works in one piece, a line through two measurements on the
    /// M3 Max: 7.3 GB at 512 × 512, 12.6 GB at 1024 × 1024. In parts it is ~6-7 GB and 1024 takes 61 s instead of 42 s.
    static func wholeBytes(_ size: ImageSize) -> UInt64 { 5_300_000_000 + UInt64(size.megapixels * 7_000_000_000) }
    /// Room the GPU keeps beside a whole image.
    static let wholeMargin: UInt64 = 2_000_000_000

    /// Own memory of the last stage on the processor, a line through three measurements on the Windows PC.
    static func decoderBytes(_ size: ImageSize) -> UInt64 { 400_000_000 + UInt64(size.megapixels * 6_840_000_000) }

    static func defaultSize(_ s: SystemInfo) -> ImageSize {
        let large = ImageSize(width: 1024, height: 1024), middle = ImageSize(width: 768, height: 768)
        if fitsOnGPU(large, s) { return large }
        if fitsOnGPU(middle, s) { return middle }
        return s.physicalMemory < littleMemory ? ImageSize(width: 512, height: 512) : middle
    }

    static func plan(_ size: ImageSize, _ s: SystemInfo) -> ImagePlan {
        guard fitsOnGPU(size, s) else { return planForProcessor(size, s) }
        let room = gpuRoom(s)
        let budget = room >= largeBudget ? (Double(room) / Double(1 << 30) * 10).rounded(.down) / 10 : smallBudgetGiB
        // in parts only where a whole image would not leave the GPU its margin: on a roomy Mac that saves a third of the time
        return ImagePlan(size: size, onGPU: true, gpuBudgetGiB: budget, tiling: wholeBytes(size) + wholeMargin > room,
                         threads: max(4, s.performanceCores))
    }

    /// The last stage may take half the memory; beyond that it works in parts.
    static func planForProcessor(_ size: ImageSize, _ s: SystemInfo) -> ImagePlan {
        ImagePlan(size: size, onGPU: false, gpuBudgetGiB: nil, tiling: decoderBytes(size) > s.physicalMemory / 2, threads: max(4, s.performanceCores))
    }

    /// `files`: the image model, the text model and the decoder, in the catalog's order.
    static func arguments(_ plan: ImagePlan, files: [String], prompt: String, seed: Int, output: String) -> [String] {
        var args = [
            "--diffusion-model", files[0], "--llm", files[1], "--vae", files[2],
            "-p", prompt,
            // what this model was made for: 4 steps, and no second pass for what the image should not show
            "--steps", "4", "--cfg-scale", "1.0", "--sampling-method", "euler",
            "-s", String(seed), "-W", String(plan.size.width), "-H", String(plan.size.height), "-t", String(plan.threads),
            "-o", output,
            // the weights stay mapped from the files, so what is not in use can leave memory
            "--mmap",
            // the prompt stays out of an image that is passed on
            "--disable-image-metadata",
        ]
        if plan.tiling { args.append("--vae-tiling") }
        if let budget = plan.gpuBudgetGiB { args += ["--max-vram", String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), budget)] }
        if !plan.onGPU { args += ["--backend", "cpu"] }
        return args
    }
}

/// The stages of one image, read from the engine's output.
struct ImageProgress {
    private enum Stage { case reading, drawing, finishing }
    private static let steps = 4
    private var stage = Stage.reading
    private var step = 0
    private(set) var lastError: String?
    /// Seconds per step, as the engine's progress bar says; nil before the first step.
    private(set) var secondsPerStep: Double?

    static func clean(_ line: String) -> String {
        line.replacingOccurrences(of: #"\x1b\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// One line of output; true when what the page shows changed.
    mutating func read(_ raw: String) -> Bool {
        let line = Self.clean(raw)
        if line.hasPrefix("[E]") {
            // "[E] generate failed --- main.cpp:926": the words, not the place in the source
            let words = line.dropFirst(3)
            lastError = String(words.range(of: " --- ").map { words[..<$0.lowerBound] } ?? words).trimmingCharacters(in: .whitespaces)
            return false
        }
        if stage == .reading && line.contains("sampling using") { stage = .drawing; return true }
        guard stage == .drawing else { return false }
        if line.contains("sampling completed") { stage = .finishing; return true }
        // the same kind of bar goes with reading weights, with hundreds of parts
        if let bar = line.range(of: #"\|[^|]*\|\s*\d+/\d+\s*-"#, options: .regularExpression) {
            let numbers = line[bar].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.suffix(2)
            if numbers.count == 2, numbers.last == Self.steps, let n = numbers.first, n != step {
                step = n
                secondsPerStep = Self.stepSeconds(line) ?? secondsPerStep
                return true
            }
        }
        return false
    }

    /// "8.49s/it" or "1.08it/s" in a progress bar.
    static func stepSeconds(_ line: String) -> Double? {
        if let r = line.range(of: #"[0-9.]+s/it"#, options: .regularExpression) { return Double(line[r].dropLast(4)) }
        if let r = line.range(of: #"[0-9.]+it/s"#, options: .regularExpression), let n = Double(line[r].dropLast(4)), n > 0 { return 1 / n }
        return nil
    }

    var isDrawing: Bool { stage == .drawing }

    var fraction: Double {
        switch stage {
        case .reading: return 0.03
        case .drawing: return 0.05 + 0.75 * Double(step) / Double(Self.steps)
        case .finishing: return 0.85
        }
    }

    var status: String {
        switch stage {
        case .reading: return L("Tekst lezen…")
        case .drawing: return L("Tekenen: stap \(min(step + 1, Self.steps)) van \(Self.steps)")
        case .finishing: return L("Afbeelding afmaken…")
        }
    }
}

/// An image that was made; beside the PNG in a file of the same name.
struct ImageResult: Codable, Identifiable, Equatable {
    var prompt = ""
    var width = 0
    var height = 0
    var seed = 0
    var seconds = 0.0
    var onGPU = false
    var created = Date()
    /// Image tokens the model drew per second, over the steps.
    var tokensPerSecond: Double?
    /// The description the image model got, when the chat model improved the user's.
    var usedPrompt: String?
    var path = ""
    var id: String { path }

    private enum CodingKeys: String, CodingKey { case prompt, width, height, seed, seconds, onGPU, created, tokensPerSecond, usedPrompt }
}

/// Makes one image at a time with the image engine.
@MainActor
final class ImageMaker: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published private(set) var fraction = 0.0
    @Published private(set) var error: String?
    /// Something the user should know about the image that came out.
    @Published private(set) var note: String?
    @Published private(set) var last: ImageResult?
    @Published private(set) var started = Date()
    /// Where the improved description came from.
    @Published private(set) var sources: [Source] = []

    /// The image tokens per second while the model draws, for the live meters; nil when no image is being made.
    var onRate: ((Double?) -> Void)?

    /// Tests: a folder of their own, and a stand-in for the engine.
    var root: URL?
    var executableOverride: URL?

    private var running: Process?
    private var stopped = false
    private var folder: URL { root ?? Paths.picturesFolder }

    /// Makes the image. `prepare` runs first with this maker already busy, so nothing starts beside it; what it returns is why not to
    /// go on. On return: the image, or nil with the reason in `error` (a stop leaves that empty).
    @discardableResult
    /// `improve` runs first: it gives the description for the image model and where it came from, and names its steps.
    func make(prompt: String, size: ImageSize, system: SystemInfo, files: [String], seed: Int? = nil,
              improve: ((@escaping (String) -> Void) async throws -> (prompt: String, sources: [Source]))? = nil,
              prepare: (() async -> String?)? = nil) async -> ImageResult? {
        guard !busy else { return nil }
        busy = true
        stopped = false
        error = nil
        note = nil
        fraction = 0
        status = L("Voorbereiden…")
        started = Date()
        onRate?(0)
        defer { busy = false; status = ""; onRate?(nil) }
        var awake: IOPMAssertionID = 0
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "MacAIMagic: een afbeelding maken" as CFString, &awake)
        defer { IOPMAssertionRelease(awake) }

        sources = []
        var drawn = prompt
        if let improve {
            status = L("Beschrijving verbeteren…")
            do {
                let better = try await improve { [weak self] step in self?.status = step }
                drawn = better.prompt
                sources = better.sources
            } catch is CancellationError {
                return nil
            } catch {
                note = L("De beschrijving kon niet worden verbeterd (\(error.localizedDescription)); de afbeelding is met je eigen beschrijving gemaakt.")
            }
            if stopped { return nil }
        }
        if let why = await prepare?() { error = why; return nil }
        guard let exe = executableOverride ?? Paths.engineBinary("image-engine") else {
            error = L("De beeldengine ontbreekt in de app. Installeer MacAIMagic opnieuw.")
            return nil
        }
        let chosen = seed ?? Int.random(in: 1..<Int(Int32.max))
        let begin = Date()
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
            self.error = L("De afbeelding is niet gelukt.") + " " + error.localizedDescription
            return nil
        }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let output = folder.appendingPathComponent("\(stamp.string(from: begin))-\(chosen).png")

        var plan = ImagePlanner.plan(size, system)
        var outcome = await run(exe, plan, files, drawn, chosen, output, appendLog: false)
        // the GPU can refuse in ways no plan foresees. The processor always works
        if outcome.failed && plan.onGPU && !stopped {
            note = L("De GPU lukte niet, dus deze afbeelding is op de processor gemaakt. Dat duurt langer.")
            fraction = 0
            plan = ImagePlanner.planForProcessor(size, system)
            outcome = await run(exe, plan, files, drawn, chosen, output, appendLog: true)
        }
        if stopped { return nil }
        if outcome.failed {
            error = L("De afbeelding is niet gelukt.") + (outcome.reason.map { " " + $0 } ?? "")
            return nil
        }
        var result = ImageResult(prompt: prompt, width: size.width, height: size.height, seed: chosen,
                                 seconds: Date().timeIntervalSince(begin), onGPU: plan.onGPU, created: Date(),
                                 tokensPerSecond: outcome.secondsPerStep.map { Double(ImagePlanner.tokensPerStep(size)) / $0 },
                                 usedPrompt: drawn == prompt ? nil : drawn)
        result.path = output.path
        // the image itself is there, also when this fails
        if let data = try? JSONEncoder().encode(result) { try? data.write(to: output.deletingPathExtension().appendingPathExtension("json")) }
        last = result
        return result
    }

    private func run(_ exe: URL, _ plan: ImagePlan, _ files: [String], _ prompt: String, _ seed: Int, _ output: URL, appendLog: Bool) async -> (failed: Bool, reason: String?, secondsPerStep: Double?) {
        let tokens = Double(ImagePlanner.tokensPerStep(plan.size))
        let args = ImagePlanner.arguments(plan, files: files, prompt: prompt, seed: seed, output: output.path)
        if !appendLog { FileManager.default.createFile(atPath: Paths.imageLog.path, contents: nil) }
        let log = try? FileHandle(forWritingTo: Paths.imageLog)
        _ = try? log?.seekToEnd()
        log?.write(Data(("$ image-engine " + args.joined(separator: " ") + "\n").utf8))

        var progress = ImageProgress()
        status = progress.status
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.currentDirectoryURL = exe.deletingLastPathComponent()
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        var pending = ""
        let done: Int32? = await withCheckedContinuation { (cont: CheckedContinuation<Int32?, Never>) in
            pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
                let text = String(decoding: h.availableData, as: UTF8.self)
                guard !text.isEmpty else { return }
                Task { @MainActor in
                    pending += text
                    // a progress bar rewrites its line with \r
                    while let at = pending.firstIndex(where: { $0 == "\r" || $0 == "\n" || $0 == "\r\n" }) {
                        let line = String(pending[..<at])
                        pending = String(pending[pending.index(after: at)...])
                        guard !ImageProgress.clean(line).isEmpty else { continue }
                        if !line.contains("it/s") && !line.contains("/it") && !line.contains("B/s") && EngineController.keepsInLog(line) {
                            log?.write(Data((ImageProgress.clean(line) + "\n").utf8))
                        }
                        if progress.read(line) {
                            self?.fraction = progress.fraction
                            self?.status = progress.status
                            // the steps draw image tokens; reading the text and finishing the image do not
                            self?.onRate?(progress.isDrawing ? progress.secondsPerStep.map { tokens / $0 } ?? 0 : 0)
                        }
                    }
                }
            }
            p.terminationHandler = { proc in cont.resume(returning: proc.terminationStatus) }
            do { try p.run() } catch {
                p.terminationHandler = nil
                cont.resume(returning: nil)
                return
            }
            running = p
            if stopped { p.terminate() }
        }
        running = nil
        // the last lines of output, among them the reason for a failure
        try? await Task.sleep(for: .milliseconds(100))
        pipe.fileHandleForReading.readabilityHandler = nil
        try? log?.close()
        let made = done == 0 && FileManager.default.fileExists(atPath: output.path)
        return (!made, progress.lastError, progress.secondsPerStep)
    }

    /// Stops the image being made; what the engine had done is gone.
    func stop() {
        guard busy else { return }
        stopped = true
        running?.terminate()
        status = L("Stoppen…")
    }

    /// The images in the folder, newest first; nothing is created for this.
    func history(most: Int = 30) -> [ImageResult] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return [] }
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast }
        return files.filter { $0.pathExtension.lowercased() == "png" }
            .sorted { date($0) > date($1) }.prefix(most).map { file in
                let side = file.deletingPathExtension().appendingPathExtension("json")
                var r = (try? Data(contentsOf: side)).flatMap { try? JSONDecoder().decode(ImageResult.self, from: $0) } ?? ImageResult(created: date(file))
                r.path = file.path
                return r
            }
    }

    /// To the Trash: what the user removes stays recoverable.
    func remove(_ image: ImageResult) {
        let file = URL(fileURLWithPath: image.path)
        try? FileManager.default.trashItem(at: file, resultingItemURL: nil)
        try? FileManager.default.trashItem(at: file.deletingPathExtension().appendingPathExtension("json"), resultingItemURL: nil)
        if last?.path == image.path { last = nil }
        objectWillChange.send()
    }
}
