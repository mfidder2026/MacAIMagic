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
