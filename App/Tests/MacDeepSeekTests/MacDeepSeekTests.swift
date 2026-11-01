import XCTest
@testable import MacDeepSeek

final class MemoryPlannerTests: XCTestCase {
    /// DeepSeek Compact as measured from its headers: ~9.3 GB dense, 40 layers of ~2.65 GB experts.
    private func compactDeepSeek() -> GGUFIndex {
        var idx = GGUFIndex()
        idx.metadata["deepseek41.block_count"] = UInt64(40)
        idx.tensors.append(.init(name: "token_embd.weight", bytes: 9_300_000_000))
        for il in 0..<40 {
            idx.tensors.append(.init(name: "blk.\(il).ffn_gate_exps.weight", bytes: 884_000_000))
            idx.tensors.append(.init(name: "blk.\(il).ffn_up_exps.weight", bytes: 884_000_000))
            idx.tensors.append(.init(name: "blk.\(il).ffn_down_exps.weight", bytes: 884_000_000))
        }
        idx.tensors.append(.init(name: "blk.1.engram_embd.weight", bytes: 80_600_000_000))
        return idx
    }

    private func mac(limitMB: Int) -> SystemInfo {
        SystemInfo(chip: "Apple M3 Max", physicalMemory: 137_438_953_472, performanceCores: 12,
                   gpuWorkingSet: 103_000_000_000, wiredLimitMB: limitMB, freeDisk: 1_000_000_000_000)
    }

    func testDefaultLimitPutsSomeExpertsOnCPU() {
        let p = MemoryPlanner.plan(index: compactDeepSeek(), system: mac(limitMB: 0), contextSize: 65_536, vision: true)
        XCTAssertGreaterThan(p.cpuMoELayers, 0)
        XCTAssertLessThan(p.cpuMoELayers, 40)
        XCTAssertLessThanOrEqual(p.dense + p.overhead + p.gpuExperts, p.gpuLimit)
        XCTAssertEqual(p.gpuExperts + p.cpuExperts, p.experts)
        XCTAssertFalse(p.warnings.isEmpty, "should suggest raising the wired limit")
    }

    func testRaisedLimitMovesMoreToGPU() {
        let low = MemoryPlanner.plan(index: compactDeepSeek(), system: mac(limitMB: 0), contextSize: 65_536, vision: true)
        let high = MemoryPlanner.plan(index: compactDeepSeek(), system: mac(limitMB: 123_000), contextSize: 65_536, vision: true)
        XCTAssertLessThan(high.cpuMoELayers, low.cpuMoELayers)
        XCTAssertEqual(high.engram, 80_600_000_000)
    }
}

final class MarkdownTests: XCTestCase {
    func testBlocks() {
        let blocks = MarkdownText.blocks("# Titel\nHallo **wereld**\n\n```swift\nlet x = 1\n```\n- punt")
        XCTAssertEqual(blocks.count, 4)
        if case .heading(1, "Titel") = blocks[0] {} else { XCTFail("heading") }
        if case .code("swift", "let x = 1") = blocks[2] {} else { XCTFail("code") }
        if case .text(let t) = blocks[3] { XCTAssertEqual(t, "• punt") } else { XCTFail("bullet") }
    }
}

final class WebToolTests: XCTestCase {
    func testDuckDuckGoParsing() {
        let html = """
        <div class="result"><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa&amp;rut=x">Example &amp; Co</a>
        <a class="result__snippet" href="x">Een <b>voorbeeld</b> snippet</a></div>
        """
        let hits = WebTools.parseDuckDuckGo(html)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.url, "https://example.com/a")
        XCTAssertEqual(hits.first?.title, "Example & Co")
        XCTAssertEqual(hits.first?.snippet, "Een voorbeeld snippet")
    }

    func testHTMLText() {
        let t = HTML.text(from: "<p>Hallo</p><script>x()</script><p>wereld&nbsp;!</p>")
        XCTAssertEqual(t, "Hallo\nwereld !")
    }
}

final class GGUFIndexTests: XCTestCase {
    /// Indexes the real DeepSeek Compact headers when they are on disk (the download writes them first).
    func testRealHeadersIfPresent() throws {
        let model = try XCTUnwrap(ModelCatalog.shared.model("deepseek-v4.1-flash-compact"))
        let urls = model.files.map { Paths.modelDir(model.id).appendingPathComponent($0.local) }
        guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { throw XCTSkip("model not downloaded") }
        let idx = try GGUFIndex.load(shards: urls, sizes: model.files.map(\.size))
        XCTAssertEqual(idx.layerCount, 40)
        XCTAssertEqual(idx.expertBytesPerLayer.count, 40)
        XCTAssertGreaterThan(idx.engramBytes, 150_000_000_000)
        let total = idx.denseBytes + idx.expertBytesPerLayer.values.reduce(0, +)
        XCTAssertEqual(Double(total) / 1e9, 115.3, accuracy: 2.0)
    }
}

final class CatalogTests: XCTestCase {
    func testCatalogLoads() throws {
        let c = ModelCatalog.shared
        XCTAssertEqual(c.models.count, 5)
        for m in c.models {
            XCTAssertFalse(m.files.isEmpty)
            XCTAssertNotNil(c.vision(for: m), m.id)
            // llama.cpp finds the other shards from the first one's name: <prefix>-0000N-of-0000M.gguf
            for (i, f) in m.files.enumerated() {
                XCTAssertTrue(f.local.hasPrefix(m.id), f.local)
                XCTAssertTrue(f.local.hasSuffix(String(format: "-%05d-of-%05d.gguf", i + 1, m.files.count)), f.local)
            }
        }
    }

    /// The names the user sees are our own: the model name starts with the base model, files are named after the id.
    func testNamesAreOurOwn() {
        for m in ModelCatalog.shared.models {
            XCTAssertTrue(["DeepSeek-V4.1-Flash", "GLM-5.3-Flash", "Qwen3.8-Flash-Next"].contains { m.name.hasPrefix($0) }, m.name)
            XCTAssertTrue(m.files.allSatisfy { $0.local.hasPrefix(m.id) })
        }
    }
}

final class StreamingPlanTests: XCTestCase {
    /// A Q4-sized model (~290 GB of experts) on a 128 GB Mac: every expert stays mapped, the GPU caches the most used.
    func testLargerThanMemory() {
        var idx = GGUFIndex()
        idx.metadata["deepseek41.block_count"] = UInt32(40)
        idx.tensors.append(.init(name: "token_embd.weight", bytes: 9_000_000_000))
        for il in 0..<40 { idx.tensors.append(.init(name: "blk.\(il).ffn_up_exps.weight", bytes: 7_250_000_000)) }
        let mac = SystemInfo(chip: "Apple M3 Max", physicalMemory: 137_438_953_472, performanceCores: 12,
                             gpuWorkingSet: 103_000_000_000, wiredLimitMB: 122_880, freeDisk: 1_000_000_000_000)
        let p = MemoryPlanner.plan(index: idx, system: mac, contextSize: 32_768, vision: false)
        XCTAssertFalse(p.fitsInMemory)
        XCTAssertEqual(p.cpuMoELayers, 40, "all experts stay mapped from the file")
        XCTAssertTrue(p.tensorSplit.isEmpty)
        XCTAssertGreaterThan(p.expertCache, 90_000_000_000)
        XCTAssertGreaterThan(p.streamedExperts, 150_000_000_000)
        // the GPU holds the dense weights, buffers and the cache, and macOS keeps its headroom and staging page cache
        XCTAssertLessThanOrEqual(p.dense + p.overhead + p.expertCache, p.gpuLimit)
        XCTAssertLessThanOrEqual(p.dense + p.overhead + p.expertCache + MemoryPlanner.osHeadroom + MemoryPlanner.stagingReserve, p.physical)
    }

    /// With the macOS default GPU limit the cache is smaller, and the plan suggests raising the limit.
    func testDefaultLimitShrinksCache() {
        var idx = GGUFIndex()
        idx.metadata["deepseek41.block_count"] = UInt32(40)
        idx.tensors.append(.init(name: "token_embd.weight", bytes: 9_000_000_000))
        for il in 0..<40 { idx.tensors.append(.init(name: "blk.\(il).ffn_up_exps.weight", bytes: 7_250_000_000)) }
        let mac = SystemInfo(chip: "Apple M3 Max", physicalMemory: 137_438_953_472, performanceCores: 12,
                             gpuWorkingSet: 103_000_000_000, wiredLimitMB: 0, freeDisk: 1_000_000_000_000)
        let p = MemoryPlanner.plan(index: idx, system: mac, contextSize: 32_768, vision: false)
        XCTAssertLessThan(p.dense + p.overhead + p.expertCache, 103_000_000_000)
        XCTAssertGreaterThan(p.expertCache, 75_000_000_000)
        XCTAssertTrue(p.warnings.contains { $0.contains("Verhoog de GPU-limiet") })
    }
}

/// Prints the memory plan of every model whose headers are on disk (MACDEEPSEEK_PLANS=1).
@MainActor
final class PlanReportTests: XCTestCase {
    func testPrintPlans() throws {
        guard ProcessInfo.processInfo.environment["MACDEEPSEEK_PLANS"] == "1" else { throw XCTSkip("set MACDEEPSEEK_PLANS=1") }
        let store = ModelStore()
        for m in ModelCatalog.shared.models where store.status(m.id).headersAvailable {
            let idx = try GGUFIndex.load(shards: store.shardURLs(m), sizes: m.files.map(\.size))
            let p = MemoryPlanner.plan(index: idx, system: .current(), contextSize: 65_536, vision: true)
            print(String(format: "PLAN %@: layers %d, dense %.1f GB, experts %.1f GB, engram %.1f GB, cpu layers %d, gpu experts %.1f GB, cpu experts %.1f GB, expert cache %.1f GB, streamed %.1f GB, fits %@",
                         m.id, p.layers, Double(p.dense) / 1e9, Double(p.experts) / 1e9, Double(p.engram) / 1e9, p.cpuMoELayers,
                         Double(p.gpuExperts) / 1e9, Double(p.cpuExperts) / 1e9, Double(p.expertCache) / 1e9, Double(p.streamedExperts) / 1e9, p.fitsInMemory ? "yes" : "no"))
        }
    }
}

final class ClusterPlanTests: XCTestCase {
    private let mac = SystemInfo(chip: "Apple M3 Max", physicalMemory: 137_438_953_472, performanceCores: 12,
                                 gpuWorkingSet: 115_400_000_000, wiredLimitMB: 0, freeDisk: 1_000_000_000_000)
    /// M5 96 GB (GPU ~72 GB) and M1 32 GB (GPU ~21 GB), minus their own headroom as ClusterController counts it
    private let helpers: [UInt64] = [69_000_000_000, 18_000_000_000]

    /// GLM-5.3-Flash Q4 (~190 GB of experts) on the MacBook alone streams from the SSD; with the helpers it fits in memory.
    func testHelpersMakeQ4Fit() {
        var idx = GGUFIndex()
        idx.metadata["glm5-next.block_count"] = UInt32(46)
        idx.tensors.append(.init(name: "token_embd.weight", bytes: 9_800_000_000))
        for il in 3..<46 { idx.tensors.append(.init(name: "blk.\(il).ffn_up_exps.weight", bytes: 4_416_000_000)) }
        let alone = MemoryPlanner.plan(index: idx, system: mac, contextSize: 65_536, vision: false)
        XCTAssertFalse(alone.fitsInMemory)
        let cluster = MemoryPlanner.plan(index: idx, system: mac, contextSize: 65_536, vision: false, helpers: helpers)
        XCTAssertTrue(cluster.fitsInMemory)
        XCTAssertEqual(cluster.streamedExperts, 0, "nothing comes from the SSD")
        // one entry per helper and one for this Mac, together every layer plus the output layer
        XCTAssertEqual(cluster.tensorSplit.count, 3)
        XCTAssertEqual(cluster.tensorSplit.reduce(0, +), 47)
        // the helpers take the first layers, so the layers this Mac keeps in memory are among its own, the last ones
        let mine = (46 - (cluster.tensorSplit.last! - 1))..<46
        XCTAssertTrue(cluster.hostExpertLayers.allSatisfy { mine.contains($0) })
        XCTAssertLessThanOrEqual(cluster.cpuMoELayers, 6)
    }

    /// DeepSeek-V4.1-Flash Q4 (~290 GB of experts) does not fit even in the cluster: this Mac keeps its layers mapped
    /// and caches the most used experts, with a much larger share of its experts in the cache than alone.
    func testDeepSeekQ4StreamsLessInCluster() {
        var idx = GGUFIndex()
        idx.metadata["deepseek41.block_count"] = UInt32(40)
        idx.tensors.append(.init(name: "token_embd.weight", bytes: 9_000_000_000))
        for il in 0..<40 { idx.tensors.append(.init(name: "blk.\(il).ffn_up_exps.weight", bytes: 7_250_000_000)) }
        let alone = MemoryPlanner.plan(index: idx, system: mac, contextSize: 32_768, vision: false)
        let cluster = MemoryPlanner.plan(index: idx, system: mac, contextSize: 32_768, vision: false, helpers: helpers)
        XCTAssertGreaterThan(cluster.expertCache, 0)
        XCTAssertLessThan(cluster.streamedExperts, alone.streamedExperts - 70_000_000_000)
        XCTAssertEqual(cluster.hostExpertLayers.count, cluster.tensorSplit.last! - 1, "all of this Mac's layers")
        XCTAssertEqual(cluster.hostExpertLayers.first, 40 - cluster.hostExpertLayers.count)
    }
}
