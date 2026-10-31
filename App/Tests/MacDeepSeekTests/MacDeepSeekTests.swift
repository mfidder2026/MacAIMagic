import XCTest
@testable import MacDeepSeek

final class MemoryPlannerTests: XCTestCase {
    /// Maya-XS as measured from its headers: ~9.3 GB dense, 40 layers of ~2.65 GB experts.
    private func mayaXS() -> GGUFIndex {
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
        let p = MemoryPlanner.plan(index: mayaXS(), system: mac(limitMB: 0), contextSize: 65_536, vision: true)
        XCTAssertGreaterThan(p.cpuMoELayers, 0)
        XCTAssertLessThan(p.cpuMoELayers, 40)
        XCTAssertLessThanOrEqual(p.dense + p.overhead + p.gpuExperts, p.gpuLimit)
        XCTAssertEqual(p.gpuExperts + p.cpuExperts, p.experts)
        XCTAssertFalse(p.warnings.isEmpty, "should suggest raising the wired limit")
    }

    func testRaisedLimitMovesMoreToGPU() {
        let low = MemoryPlanner.plan(index: mayaXS(), system: mac(limitMB: 0), contextSize: 65_536, vision: true)
        let high = MemoryPlanner.plan(index: mayaXS(), system: mac(limitMB: 123_000), contextSize: 65_536, vision: true)
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
    /// Indexes the real Maya-XS headers when they are on disk (the download writes them first).
    func testRealHeadersIfPresent() throws {
        let urls = Paths.modelShards.map { Paths.modelDir.appendingPathComponent($0) }
        guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { throw XCTSkip("model not downloaded") }
        let idx = try GGUFIndex.load(shards: urls, sizes: Paths.modelShardSizes)
        XCTAssertEqual(idx.expertBytesPerLayer.count, 40)
        XCTAssertGreaterThan(idx.engramBytes, 150_000_000_000)
        let total = idx.denseBytes + idx.expertBytesPerLayer.values.reduce(0, +)
        XCTAssertEqual(Double(total) / 1e9, 115.3, accuracy: 2.0)
        print("dense \(idx.denseBytes.gb), experts \(idx.expertBytesPerLayer.values.reduce(0, +).gb), engram \(idx.engramBytes.gb)")
    }
}
