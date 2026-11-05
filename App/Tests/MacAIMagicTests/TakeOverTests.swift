import AppKit
import XCTest
@testable import MacAIMagic

/// What was taken over from the Windows version. The names follow its tests where they apply.
final class CatalogTakeOverTests: XCTestCase {
    /// A sha256 belongs to one version of a file: an address that follows the newest version breaks when the maker replaces it.
    func testEveryDownloadAddressNamesOneVersion() {
        let c = ModelCatalog.shared
        let urls = c.all.flatMap { $0.files + ($0.draft.map { [$0] } ?? []) }.map(\.url) + c.vision.map(\.url)
        XCTAssertFalse(urls.isEmpty)
        for url in urls { XCTAssertNotNil(url.range(of: "/resolve/[0-9a-f]{40}/", options: .regularExpression), url) }
    }

    func testImageModelIsNotAChatModel() {
        let c = ModelCatalog.shared
        XCTAssertEqual(c.images.first?.files.count, 3)
        XCTAssertFalse(c.models.contains { $0.id == c.images.first?.id })
        XCTAssertNotNil(c.model(c.images[0].id))
    }

    func testDownloadErrorsSayWhatHappened() {
        XCTAssertNil(ModelStore.errorText(exitCode: 0, failure: nil))
        XCTAssertTrue(ModelStore.errorText(exitCode: 3, failure: nil)?.contains("MacAIMagic") == true)
        XCTAssertNotNil(ModelStore.errorText(exitCode: 1, failure: nil))
        XCTAssertTrue(ModelStore.errorText(exitCode: 1, failure: "a.gguf: size 1 != 2")?.contains("a.gguf") == true)
    }
}

final class PlainModelTests: XCTestCase {
    private func ministral() -> GGUFIndex {
        var idx = GGUFIndex()
        idx.metadata["general.architecture"] = "mistral3"
        idx.metadata["mistral3.block_count"] = UInt64(34)
        idx.tensors.append(.init(name: "blk.0.attn.weight", bytes: 5_190_500_352))
        return idx
    }

    private func mac(_ gb: UInt64) -> SystemInfo {
        SystemInfo(chip: "Apple M1", physicalMemory: gb << 30, performanceCores: 4,
                   gpuWorkingSet: (gb << 30) / 3 * 2, wiredLimitMB: 0, freeDisk: 1 << 40)
    }

    /// A model without experts never gets an expert cache, on any Mac, and is never called too big.
    func testPlainModelHasNoExpertCache() {
        for gb: UInt64 in [8, 16, 32, 128] {
            let p = MemoryPlanner.plan(index: ministral(), system: mac(gb), contextSize: 8192, vision: false)
            XCTAssertEqual(p.expertCache, 0, "\(gb) GB")
            XCTAssertEqual(p.cpuMoELayers, 0, "\(gb) GB")
        }
        let model = ModelCatalog.shared.model("ministral-3-8b-q4")!
        XCTAssertEqual(MemoryPlanner.fit(model, physical: 8 << 30), .streams)
        XCTAssertEqual(MemoryPlanner.fit(model, physical: 16 << 30), .fits)
    }

    func testLayersThatDoNotFitGoToTheProcessor() {
        let small = MemoryPlanner.plan(index: ministral(), system: mac(8), contextSize: 8192, vision: false)
        XCTAssertNotNil(small.gpuLayers)
        XCTAssertLessThan(small.gpuLayers!, 34)
        XCTAssertNil(MemoryPlanner.plan(index: ministral(), system: mac(32), contextSize: 8192, vision: false).gpuLayers)
    }

    /// From the real file, when it is downloaded: no experts, and the architecture the KV cost is known for.
    @MainActor func testTheRealFileIsPlain() throws {
        let m = try XCTUnwrap(ModelCatalog.shared.model("ministral-3-8b-q4"))
        let store = ModelStore()
        guard store.status(m.id).isComplete else { throw XCTSkip("Ministral not downloaded") }
        let index = try GGUFIndex.load(shards: store.shardURLs(m), sizes: m.files.map(\.size))
        XCTAssertTrue(index.isPlain)
        XCTAssertEqual(index.kvBytesPerToken, 142_000)
        XCTAssertEqual(MemoryPlanner.plan(index: index, system: mac(16), contextSize: 8192, vision: false).expertCache, 0)
    }

    func testContextIsAtLeast8KWhereMemoryIsShort() {
        XCTAssertEqual(MemoryPlanner.contextRoom(index: ministral(), system: mac(8), vision: false), 8192)
        XCTAssertEqual(MemoryPlanner.contextRoom(index: ministral(), system: mac(16), vision: false), 8192)
    }

    @MainActor func testEngineArgumentsForAPlainModel() {
        let model = ModelCatalog.shared.model("ministral-3-8b-q4")!
        let plan = MemoryPlanner.plan(index: ministral(), system: mac(8), contextSize: 8192, vision: false)
        let args = EngineController().arguments(model: model, shards: [URL(fileURLWithPath: "/m.gguf")], plan: plan, vision: nil)
        XCTAssertEqual(args[args.firstIndex(of: "--n-gpu-layers")! + 1], String(plan.gpuLayers!))
        XCTAssertTrue(args.contains("--no-repack"))
        XCTAssertFalse(args.contains("--moe-cache-mib"))
    }
}

final class MeterScaleTests: XCTestCase {
    @MainActor func testTheScaleGrowsWithImageTokens() {
        let m = LiveMetrics()
        XCTAssertEqual(m.scale(base: 30), 30)
        XCTAssertFalse(m.makingImage)
        m.imageRate = 0
        XCTAssertTrue(m.makingImage)
        m.imageRate = nil
    }
}

final class GapTests: XCTestCase {
    /// The transcript's own labels at the start of a line: no summary but more of the conversation.
    func testAContinuationOfTheConversationIsNoSummary() {
        XCTAssertTrue(ChatClient.looksLikeTranscript(L("Gebruiker:") + " en verder?"))
        XCTAssertTrue(ChatClient.looksLikeTranscript("Code gevonden.\n" + L("Resultaat:") + " Wrote 243 bytes"))
        XCTAssertFalse(ChatClient.looksLikeTranscript("# Samenvatting\n## Doel\n- De resultaten staan in codes.txt."))
    }

    func testSearchRegionFollowsTheLanguage() {
        XCTAssertEqual(WebTools.duckDuckGoRegion("nl"), "nl-nl")
        XCTAssertEqual(WebTools.duckDuckGoRegion("en"), "us-en")
        XCTAssertEqual(WebTools.bingRegion("de").country, "DE")
        XCTAssertEqual(WebTools.bingRegion("fr").language, "fr")
    }

    func testTheLogKeepsOutWhatTheTailKeepsOut() {
        XCTAssertFalse(EngineController.keepsInLog("llama_model_loader: - kv 1: general.name"))
        XCTAssertFalse(EngineController.keepsInLog("print_info: general.name = x"))
        XCTAssertTrue(EngineController.keepsInLog("srv  update_slots: all slots are idle"))
    }

    @MainActor func testTheApiKeyStaysOffTheCommandLine() {
        let saved = Settings.shared.apiKey
        defer { Settings.shared.apiKey = saved }
        Settings.shared.apiKey = "geheim"
        var idx = GGUFIndex()
        idx.tensors.append(.init(name: "x", bytes: 1))
        let plan = MemoryPlanner.plan(index: idx, system: SystemInfo.current(), contextSize: 4096, vision: false)
        let args = EngineController().arguments(model: ModelCatalog.shared.models[0], shards: [URL(fileURLWithPath: "/m.gguf")], plan: plan, vision: nil)
        XCTAssertFalse(args.contains("geheim"))
    }

    func testAHelperSaysWhatItHolds() {
        XCTAssertEqual(ClusterController.helperMemory("Available devices:\n  RPC0: 10.0.0.2:50052 (16310 MiB, 15172 MiB free)\n"), 16310)
        XCTAssertNil(ClusterController.helperMemory("error: failed to connect"))
    }

    @MainActor func testAHelperThatDoesNotAnswerStaysOut() async throws {
        let c = ClusterController()
        c.probeOverride = { _ in nil }
        c.addManual("10.9.9.9:50052", save: false)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(c.active.contains { $0.host == "10.9.9.9" })
        c.probeOverride = { _ in 16310 }
        c.recheckManual()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(c.helperBudgets.count, c.active.count)
        c.remove(c.helpers.first { $0.host == "10.9.9.9" }!)
    }

    /// A program started with & keeps the output open: the command is over all the same, and the program lives on.
    @MainActor func testAProgramInTheBackgroundDoesNotHoldUpTheCommand() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        WorkspaceTools.current = folder.path
        defer { WorkspaceTools.current = nil }
        let start = Date()
        let out = try await WorkspaceTools.runCommand("sleep 5 & echo hallo", timeout: 30)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertTrue(out.contains("hallo"), out)
        XCTAssertTrue(out.contains("exit code 0"), out)
    }

    @MainActor func testTheTimeoutEndsTheWholeCommand() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        WorkspaceTools.current = folder.path
        defer { WorkspaceTools.current = nil }
        let start = Date()
        let out = try await WorkspaceTools.runCommand("sleep 30; echo te laat", timeout: 1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        XCTAssertTrue(out.contains("timeout"), out)
    }

    @MainActor func testStopEndsARunningCommand() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        WorkspaceTools.current = folder.path
        defer { WorkspaceTools.current = nil }
        let start = Date()
        let task = Task { @MainActor in try await WorkspaceTools.runCommand("sleep 30", timeout: 60) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let out = try await task.value
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        XCTAssertTrue(out.contains("stopped by the user"), out)
    }
}

final class ImagePlannerTests: XCTestCase {
    private func mac(_ gb: UInt64) -> SystemInfo {
        SystemInfo(chip: "Apple M1", physicalMemory: gb << 30, performanceCores: 4,
                   gpuWorkingSet: (gb << 30) / 3 * 2, wiredLimitMB: 0, freeDisk: 1 << 40)
    }

    func testSizePerMac() {
        XCTAssertEqual(ImagePlanner.defaultSize(mac(128)).width, 1024)
        XCTAssertEqual(ImagePlanner.defaultSize(mac(16)).width, 1024)
        XCTAssertEqual(ImagePlanner.defaultSize(mac(8)).width, 768)
    }

    func testAMacWithLittleMemoryKeepsTheLargeSizesOnTheProcessor() {
        XCTAssertTrue(ImagePlanner.plan(ImageSize(width: 768, height: 768), mac(8)).onGPU)
        let large = ImagePlanner.plan(ImageSize(width: 1024, height: 1024), mac(8))
        XCTAssertFalse(large.onGPU)
        XCTAssertTrue(large.tiling, "the last stage would take more than half the memory")
    }

    func testBudgetLeavesMacOSItsRoom() throws {
        let p = ImagePlanner.plan(ImageSize(width: 1024, height: 1024), mac(16))
        XCTAssertTrue(p.onGPU)
        XCTAssertLessThan(try XCTUnwrap(p.gpuBudgetGiB) * Double(1 << 30), Double(16 << 30))
    }

    func testArguments() {
        let gpu = ImagePlanner.plan(ImageSize(width: 768, height: 768), mac(8))
        let args = ImagePlanner.arguments(gpu, files: ["a", "b", "c"], prompt: "vos", seed: 7, output: "/o.png")
        XCTAssertEqual(Array(args[0..<6]), ["--diffusion-model", "a", "--llm", "b", "--vae", "c"])
        XCTAssertEqual(args[args.firstIndex(of: "--max-vram")! + 1], "1.2")
        XCTAssertTrue(args.contains("--disable-image-metadata"))
        XCTAssertFalse(args.contains("cpu"))
        XCTAssertTrue(ImagePlanner.arguments(ImagePlanner.planForProcessor(gpu.size, mac(8)), files: ["a", "b", "c"], prompt: "", seed: 1, output: "o").contains("cpu"))
    }

    /// In parts only where a whole image does not fit beside macOS: measured on the M3 Max, 42 s whole against 61 s in parts.
    func testWorkingInPartsOnlyWhereMemoryIsShort() {
        XCTAssertFalse(ImagePlanner.plan(ImageSize(width: 1024, height: 1024), mac(128)).tiling)
        XCTAssertFalse(ImagePlanner.plan(ImageSize(width: 512, height: 512), mac(32)).tiling)
        XCTAssertTrue(ImagePlanner.plan(ImageSize(width: 1024, height: 1024), mac(16)).tiling)
        XCTAssertTrue(ImagePlanner.plan(ImageSize(width: 768, height: 768), mac(8)).tiling)
    }

    func testImageTokens() {
        XCTAssertEqual(ImagePlanner.tokensPerStep(ImageSize(width: 1024, height: 1024)), 4096)
        XCTAssertEqual(ImageProgress.stepSeconds("|====|  2/4 -   8.62s/it - ETA 00:17"), 8.62)
        XCTAssertEqual(ImageProgress.stepSeconds("|=| 1/4 - 2.00it/s"), 0.5)
        var p = ImageProgress()
        _ = p.read("[INFO] sampling using Euler method")
        _ = p.read("|============>   | 1/4 -   8.49s/it - ETA 00:25")
        XCTAssertEqual(p.secondsPerStep, 8.49)
    }

    func testProgressFollowsTheStages() {
        var p = ImageProgress()
        XCTAssertEqual(p.fraction, 0.03)
        XCTAssertFalse(p.read("|====| 200/500 - 10 it/s"), "a bar of reading weights")
        XCTAssertTrue(p.read("\u{1b}[32m[INFO]\u{1b}[0m sampling using Euler method"))
        XCTAssertTrue(p.read("|==  | 2/4 - 1.2 s/it"))
        XCTAssertEqual(p.fraction, 0.05 + 0.75 * 2 / 4, accuracy: 0.001)
        XCTAssertTrue(p.read("[INFO] sampling completed"))
        XCTAssertEqual(p.fraction, 0.85)
        _ = p.read("[E] generate failed --- main.cpp:926")
        XCTAssertEqual(p.lastError, "generate failed")
    }
}

/// With a stand-in for the engine: a small script that behaves as the real one does.
@MainActor final class ImageMakerTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: folder) }

    private func maker(_ script: String) throws -> ImageMaker {
        let exe = folder.appendingPathComponent("engine.sh")
        try ("#!/bin/bash\nwhile [ $# -gt 0 ]; do case \"$1\" in -o) OUT=\"$2\"; shift;; --backend) CPU=1;; esac; shift; done\n" + script).write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        let m = ImageMaker()
        m.root = folder.appendingPathComponent("out")
        m.executableOverride = exe
        return m
    }

    private func mac() -> SystemInfo {
        SystemInfo(chip: "Apple M1", physicalMemory: 32 << 30, performanceCores: 4, gpuWorkingSet: 21 << 30, wiredLimitMB: 0, freeDisk: 1 << 40)
    }

    private let size = ImageSize(width: 512, height: 512)

    func testAnImageIsSavedWithItsDescriptionBesideIt() async throws {
        let m = try maker("echo 'sampling using Euler'\necho png > \"$OUT\"\n")
        let made = await m.make(prompt: "een vos", size: size, system: mac(), files: ["a", "b", "c"], seed: 5)
        let r = try XCTUnwrap(made)
        XCTAssertTrue(r.onGPU)
        XCTAssertFalse(m.busy)
        let list = m.history()
        XCTAssertEqual(list.first?.prompt, "een vos")
        XCTAssertEqual(list.first?.seed, 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: (r.path as NSString).deletingPathExtension + ".json"))
    }

    func testAGPUThatRefusesLeavesTheImageToTheProcessor() async throws {
        let m = try maker("[ -z \"$CPU\" ] && { echo '[E] out of memory --- x.cpp:1'; exit 1; }\necho png > \"$OUT\"\n")
        let made = await m.make(prompt: "x", size: size, system: mac(), files: ["a", "b", "c"])
        let r = try XCTUnwrap(made)
        XCTAssertFalse(r.onGPU)
        XCTAssertNotNil(m.note)
    }

    func testAFailureSaysWhy() async throws {
        let m = try maker("echo '[E] kapot --- x.cpp:1'\nexit 1\n")
        let r = await m.make(prompt: "x", size: size, system: mac(), files: ["a", "b", "c"])
        XCTAssertNil(r)
        XCTAssertTrue(m.error?.contains("kapot") == true, m.error ?? "")
    }

    func testTheMetersFollowTheImageTokens() async throws {
        let m = try maker("echo '[INFO] sampling using Euler'\nprintf '|==| 1/4 - 2.00s/it\\n'\nsleep 0.3\necho png > \"$OUT\"\n")
        var rates: [Double?] = []
        m.onRate = { rates.append($0) }
        let made = await m.make(prompt: "x", size: ImageSize(width: 512, height: 512), system: mac(), files: ["a", "b", "c"])
        XCTAssertEqual(rates.first ?? nil, 0)
        XCTAssertTrue(rates.contains { $0 == 512 }, "\(rates)")   // 1024 tokens a step, 2 s a step
        XCTAssertNil(rates.last ?? 0)
        XCTAssertEqual(made?.tokensPerSecond, 512)
    }

    func testPrepareCanSayNo() async throws {
        let m = try maker("exit 0\n")
        let r = await m.make(prompt: "x", size: size, system: mac(), files: ["a", "b", "c"]) { "bezig" }
        XCTAssertNil(r)
        XCTAssertEqual(m.error, "bezig")
    }

    func testStopLeavesNoError() async throws {
        let m = try maker("sleep 20\n")
        let task = Task { await m.make(prompt: "x", size: size, system: mac(), files: ["a", "b", "c"]) }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(m.busy)
        m.stop()
        let r = await task.value
        XCTAssertNil(r)
        XCTAssertNil(m.error)
    }
}

/// MACAIMAGIC_IMAGE_TEST=1: one real image with the real engine and the downloaded model, through the app's own path.
@MainActor final class ImageEngineIntegrationTests: XCTestCase {
    func testARealImage() async throws {
        guard ProcessInfo.processInfo.environment["MACAIMAGIC_IMAGE_TEST"] == "1" else { throw XCTSkip("no image test") }
        let app = AppState()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        app.images.root = folder
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = try XCTUnwrap(app.models.catalog.images.first)
        XCTAssertTrue(app.models.status(model.id).isComplete, "download the image model first")
        let made = await app.images.make(prompt: "a red fox reading a newspaper on a bench in Amsterdam, autumn light, photo",
                                         size: ImageSize(width: 512, height: 512), system: app.system,
                                         files: app.models.shardURLs(model).map(\.path), seed: 7)
        let r = try XCTUnwrap(made, app.images.error ?? "")
        XCTAssertTrue(r.onGPU)
        XCTAssertNotNil(NSImage(contentsOfFile: r.path))
        print(String(format: "IMAGE 512 on the GPU: %.1f s", r.seconds))
    }
}


/// The chat model's better description, with a stand-in for the engine.
final class ImagePromptTests: XCTestCase {
    private func reply(_ content: String, calls: [[String: Any]] = []) -> [String: Any] {
        var message: [String: Any] = ["role": "assistant", "content": content]
        if !calls.isEmpty { message["tool_calls"] = calls }
        return ["choices": [["message": message]]]
    }

    func testTheAnswerIsTheDescriptionAlone() {
        XCTAssertEqual(ImagePrompt.cleaned("Prompt: \"a red fox on a bench\""), "a red fox on a bench")
        XCTAssertEqual(ImagePrompt.cleaned("<think>hmm</think>\n a fox "), "a fox")
    }

    func testWithoutSearchingOneRequestIsEnough() async throws {
        var bodies: [[String: Any]] = []
        let r = try await ImagePrompt.improve("een rode vos", model: "m", send: { bodies.append($0); return self.reply("a red fox, photo") }, onStep: { _ in })
        XCTAssertEqual(r.prompt, "a red fox, photo")
        XCTAssertEqual(bodies.count, 1)
        XCTAssertNotNil(bodies[0]["tools"])
        XCTAssertEqual((bodies[0]["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool, false)
    }

    func testEnglishIsRecognised() {
        XCTAssertTrue(ImagePrompt.isEnglish("A photograph of the Eiffel Tower in Paris on a clear afternoon"))
        XCTAssertFalse(ImagePrompt.isEnglish("De Eiffeltoren, een smeedijzeren monument in Parijs met vier poten"))
        XCTAssertFalse(ImagePrompt.isEnglish("Der Eiffelturm in Paris mit blauem Himmel und einer Wiese"))
    }

    /// A Dutch answer is asked for once more, in English, without tools.
    func testADutchAnswerIsAskedAgainInEnglish() async throws {
        var bodies: [[String: Any]] = []
        let r = try await ImagePrompt.improve("maak een foto van de eifeltoren", model: "m", send: { body in
            bodies.append(body)
            return bodies.count == 1 ? self.reply("De Eiffeltoren in Parijs met een blauwe lucht") : self.reply("A photograph of the Eiffel Tower in Paris")
        }, onStep: { _ in })
        XCTAssertEqual(r.prompt, "A photograph of the Eiffel Tower in Paris")
        XCTAssertEqual(bodies.count, 2)
        XCTAssertNil(bodies[1]["tools"])
        XCTAssertTrue((bodies[0]["messages"] as? [[String: Any]])?.last?["content"] as? String == "The user's request:\nmaak een foto van de eifeltoren\n\nWrite the English description now.")
    }

    func testPagesWithTextAreReadNotStockPhotoSites() {
        let hits = [Source(title: "a", url: "https://www.alamy.com/x"), Source(title: "b", url: "https://www.rijksmuseum.nl/gebouw"),
                    Source(title: "c", url: "https://nl.wikipedia.org/wiki/Rijksmuseum")]
        XCTAssertEqual(ImagePrompt.pagesToRead(hits).map(\.url), ["https://www.rijksmuseum.nl/gebouw", "https://nl.wikipedia.org/wiki/Rijksmuseum"])
        XCTAssertTrue(ImagePrompt.pagesToRead([hits[0]]).isEmpty)
    }

    /// The model searched but read nothing: its description came from memory, so the app reads the pages and asks again.
    func testASearchWithoutReadingGetsPagesRead() async throws {
        let search: [[String: Any]] = [["id": "1", "type": "function", "function": ["name": "web_search", "arguments": "{\"query\": \"x\"}"]]]
        var bodies: [[String: Any]] = []
        var fetched: [String] = []
        let r = try await ImagePrompt.improve("het Rijksmuseum", model: "m", send: { body in
            bodies.append(body)
            switch bodies.count {
            case 1: return self.reply("", calls: search)
            case 2: return self.reply("A photograph of the Rijksmuseum with a dome")
            default: return self.reply("A photograph of the Rijksmuseum, a red-brick building with two towers")
            }
        }, fetch: { url in fetched.append(url); return "A red-brick building with two towers." }, onStep: { _ in })
        XCTAssertEqual(r.prompt, "A photograph of the Rijksmuseum, a red-brick building with two towers")
        XCTAssertNil(bodies.last?["tools"], "the last round may only answer")
        _ = fetched
    }

    func testAnEmptyAnswerKeepsTheUsersDescription() async throws {
        let r = try await ImagePrompt.improve("een rode vos", model: "m", send: { _ in self.reply("  ") }, onStep: { _ in })
        XCTAssertEqual(r.prompt, "een rode vos")
    }

    /// A model that keeps calling tools gets a last round in which it may only answer.
    func testTheLastRoundMayOnlyAnswer() async throws {
        var bodies: [[String: Any]] = []
        let call: [[String: Any]] = [["id": "1", "type": "function", "function": ["name": "nope", "arguments": "{}"]]]
        _ = try await ImagePrompt.improve("x", model: "m", send: { body in
            bodies.append(body)
            return body["tool_choice"] as? String == "none" ? self.reply("a fox") : self.reply("", calls: call)
        }, onStep: { _ in })
        XCTAssertEqual(bodies.count, ImagePrompt.maxRounds + 1)
        XCTAssertNil(bodies.last?["tools"])
    }
}

@MainActor final class ImageImproveMakerTests: XCTestCase {
    func testTheImprovedDescriptionGoesToTheEngineAndIsKept() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let exe = folder.appendingPathComponent("engine.sh")
        try "#!/bin/bash\nwhile [ $# -gt 0 ]; do case \"$1\" in -o) OUT=\"$2\"; shift;; -p) echo \"$2\" > \"$OUT.prompt\"; P=\"$2\"; shift;; esac; shift; done\necho \"$P\" > \"$OUT.txt\"; echo png > \"$OUT\"\n"
            .write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        let m = ImageMaker()
        m.root = folder.appendingPathComponent("out")
        m.executableOverride = exe
        let system = SystemInfo(chip: "M1", physicalMemory: 32 << 30, performanceCores: 4, gpuWorkingSet: 21 << 30, wiredLimitMB: 0, freeDisk: 1 << 40)
        let made = await m.make(prompt: "een rode vos", size: ImageSize(width: 512, height: 512), system: system, files: ["a", "b", "c"],
                                improve: { step in step("x"); return ("a red fox", [Source(title: "t", url: "https://example.org")]) })
        let r = try XCTUnwrap(made)
        XCTAssertEqual(r.prompt, "een rode vos")
        XCTAssertEqual(r.usedPrompt, "a red fox")
        XCTAssertEqual(try String(contentsOfFile: r.path + ".txt", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "a red fox")
        XCTAssertEqual(m.sources.count, 1)
        XCTAssertEqual(m.history().first?.usedPrompt, "a red fox")
    }

    func testAFailedImprovementStillMakesTheImage() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let exe = folder.appendingPathComponent("engine.sh")
        try "#!/bin/bash\nwhile [ $# -gt 0 ]; do case \"$1\" in -o) OUT=\"$2\"; shift;; esac; shift; done\necho png > \"$OUT\"\n".write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        let m = ImageMaker()
        m.root = folder.appendingPathComponent("out")
        m.executableOverride = exe
        let system = SystemInfo(chip: "M1", physicalMemory: 32 << 30, performanceCores: 4, gpuWorkingSet: 21 << 30, wiredLimitMB: 0, freeDisk: 1 << 40)
        let made = await m.make(prompt: "vos", size: ImageSize(width: 512, height: 512), system: system, files: ["a", "b", "c"],
                                improve: { _ in throw AppState.ImproveError("geen model") })
        XCTAssertNotNil(made)
        XCTAssertNil(made?.usedPrompt)
        XCTAssertTrue(m.note?.contains("geen model") == true)
    }

    /// MACAIMAGIC_IMPROVE_TEST=1: with the owner's own choice of models, the fast model writes the description with the web, the
    /// heavy one does not start, and FLUX draws it.
    func testARealImprovement() async throws {
        guard ProcessInfo.processInfo.environment["MACAIMAGIC_IMPROVE_TEST"] == "1" else { throw XCTSkip("no improve test") }
        let app = AppState()
        let writer = try XCTUnwrap(app.describer)
        print("WRITER: \(writer.model.name) (\(writer.role)), heavy: \(app.selectedModel?.name ?? "-")")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("macaimagic-improve")
        app.images.root = folder
        let start = Date()
        let env = ProcessInfo.processInfo.environment
        let side = Int(env["MACAIMAGIC_IMPROVE_SIZE"] ?? "") ?? 512
        let made = await app.makeImageNow(prompt: env["MACAIMAGIC_IMPROVE_PROMPT"] ?? "het Rijksmuseum in Amsterdam bij avondlicht, foto",
                                          size: ImageSize(width: side, height: side), seed: 11, improve: true)
        print("STEPS:\n" + app.images.steps.map { "  \($0.state) \($0.title)" }.joined(separator: "\n"))
        print("HEAVY after: \(app.engine.state), FAST after: \(app.documentEngines.fast.state) \(app.documentEngines.fast.model?.name ?? "")")
        await app.documentEngines.fast.stopAndWait()
        await app.engine.stopAndWait()
        let r = try XCTUnwrap(made, app.images.error ?? "")
        print("IMPROVED in \(Int(Date().timeIntervalSince(start))) s, image \(Int(r.seconds)) s: \(r.usedPrompt ?? "(not improved: \(app.images.note ?? ""))")")
        print("IMAGE: \(r.path)")
        XCTAssertNotNil(r.usedPrompt)
    }
}


/// The fast model the user chose under Modellen goes first, as long as it fits beside the heavy one.
final class ChosenFastModelTests: XCTestCase {
    private func model(_ id: String) -> ModelInfo { ModelCatalog.shared.model(id)! }

    func testTheChosenFastModelGoesFirst() {
        var idx = GGUFIndex()
        idx.tensors.append(.init(name: "x", bytes: 20_000_000_000))
        let system = SystemInfo(chip: "M3 Max", physicalMemory: 128 << 30, performanceCores: 12, gpuWorkingSet: 100_000_000_000, wiredLimitMB: 0, freeDisk: 1 << 40)
        let plan = MemoryPlanner.plan(index: idx, system: system, contextSize: 8192, vision: false)
        let heavy = model("glm-5.3-flash-compact")
        let downloaded = [heavy, model("qwen3.6-35b-a3b-q4"), model("ministral-3-8b-q4")]
        XCTAssertEqual(DocumentModels.fastModel(heavy: heavy, heavyPlan: plan, downloaded: downloaded, physical: system.physicalMemory)?.id,
                       "ministral-3-8b-q4", "by itself: the smallest")
        XCTAssertEqual(DocumentModels.fastModel(heavy: heavy, heavyPlan: plan, downloaded: downloaded, physical: system.physicalMemory,
                                                chosen: "qwen3.6-35b-a3b-q4")?.id, "qwen3.6-35b-a3b-q4")
        XCTAssertEqual(DocumentModels.fastModel(heavy: heavy, heavyPlan: plan, downloaded: downloaded, physical: system.physicalMemory,
                                                chosen: heavy.id)?.id, "ministral-3-8b-q4", "the heavy one is never also the fast one")
    }
}


/// Who writes the description for an image: the fast model, the heavy one only when there is no other.
final class DescriberTests: XCTestCase {
    private func model(_ id: String) -> ModelInfo { ModelCatalog.shared.model(id)! }
    private let plenty: UInt64 = 100_000_000_000

    func testTheFastModelWritesIt() {
        let heavy = model("deepseek-v4.1-flash-compact"), small = model("ministral-3-8b-q4")
        let d = AppState.describer(heavy: heavy, downloaded: [heavy, small, model("qwen3.6-35b-a3b-q4")], chosenFast: "",
                                   heavyRunning: false, fastRunning: nil, available: plenty)
        XCTAssertEqual(d?.model.id, small.id)
        XCTAssertEqual(d?.onFast, true)
    }

    func testTheChosenFastModelWritesIt() {
        let heavy = model("deepseek-v4.1-flash-compact")
        let d = AppState.describer(heavy: heavy, downloaded: [heavy, model("ministral-3-8b-q4"), model("qwen3.6-35b-a3b-q4")],
                                   chosenFast: "qwen3.6-35b-a3b-q4", heavyRunning: false, fastRunning: nil, available: plenty)
        XCTAssertEqual(d?.model.id, "qwen3.6-35b-a3b-q4")
    }

    func testOnlyOneModelMeansTheHeavyOne() {
        let heavy = model("deepseek-v4.1-flash-compact")
        let d = AppState.describer(heavy: heavy, downloaded: [heavy], chosenFast: "", heavyRunning: false, fastRunning: nil, available: plenty)
        XCTAssertEqual(d?.model.id, heavy.id)
        XCTAssertEqual(d?.onFast, false)
    }

    /// A heavy model that runs and leaves no room for the fast one: it writes the description itself.
    func testARunningHeavyModelWithoutRoomWritesIt() {
        let heavy = model("deepseek-v4.1-flash-compact")
        let d = AppState.describer(heavy: heavy, downloaded: [heavy, model("ministral-3-8b-q4")], chosenFast: "",
                                   heavyRunning: true, fastRunning: nil, available: 3_000_000_000)
        XCTAssertEqual(d?.model.id, heavy.id)
    }

    func testAFastModelThatRunsWritesIt() {
        let heavy = model("deepseek-v4.1-flash-compact"), qwen = model("qwen3.6-35b-a3b-q4")
        let d = AppState.describer(heavy: heavy, downloaded: [heavy, model("ministral-3-8b-q4"), qwen], chosenFast: "",
                                   heavyRunning: true, fastRunning: qwen, available: 0)
        XCTAssertEqual(d?.model.id, qwen.id)
    }

    /// The steps name the model that does them, and end done.
    @MainActor func testTheStepsNameTheModels() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let exe = folder.appendingPathComponent("engine.sh")
        try "#!/bin/bash\nwhile [ $# -gt 0 ]; do case \"$1\" in -o) OUT=\"$2\"; shift;; esac; shift; done\necho 'sampling using Euler'\necho 'sampling completed'\necho png > \"$OUT\"\n"
            .write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        let m = ImageMaker()
        m.root = folder.appendingPathComponent("out")
        m.executableOverride = exe
        let system = SystemInfo(chip: "M1", physicalMemory: 32 << 30, performanceCores: 4, gpuWorkingSet: 21 << 30, wiredLimitMB: 0, freeDisk: 1 << 40)
        _ = await m.make(prompt: "vos", size: ImageSize(width: 512, height: 512), system: system, files: ["a", "b", "c"], drawer: "FLUX.2",
                         improve: { step in step("Ministral-3-8B (Snel) schrijft de beschrijving…"); return ("a fox", []) })
        XCTAssertEqual(m.steps.first?.title, "Ministral-3-8B (Snel) schrijft de beschrijving…")
        XCTAssertTrue(m.steps.contains { $0.title.hasPrefix("FLUX.2: ") }, "\(m.steps.map(\.title))")
        XCTAssertTrue(m.steps.allSatisfy { $0.state == .done })
    }
}
