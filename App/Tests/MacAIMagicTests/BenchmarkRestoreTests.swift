import XCTest
@testable import MacAIMagic

/// After a comparison the user's own model is the chosen one again (it stayed on the last model measured).
final class BenchmarkRestoreTests: XCTestCase {
    func testTheLastMeasuredModelStopsAndTheOwnOneComesBack() {
        // Flash-Next ran before, the comparison ended on Ling: Ling stops, Flash-Next starts again
        let a = BenchmarkRunner.afterRun(chosen: "qwen3.8-flash-next-q4", wasRunning: "qwen3.8-flash-next-q4", nowRunning: "ling-3.0-tiny-q4")
        XCTAssertTrue(a.stop); XCTAssertTrue(a.start)
        // nothing ran before: Ling stops, nothing starts
        let b = BenchmarkRunner.afterRun(chosen: "qwen3.8-flash-next-q4", wasRunning: nil, nowRunning: "ling-3.0-tiny-q4")
        XCTAssertTrue(b.stop); XCTAssertFalse(b.start)
        // the comparison ended on the user's own model: it keeps running
        let c = BenchmarkRunner.afterRun(chosen: "ling-3.0-tiny-q4", wasRunning: "ling-3.0-tiny-q4", nowRunning: "ling-3.0-tiny-q4")
        XCTAssertFalse(c.stop); XCTAssertFalse(c.start)
        // the last model was an image model: no chat engine runs, the own one starts again
        let d = BenchmarkRunner.afterRun(chosen: "qwen3.8-flash-next-q4", wasRunning: "qwen3.8-flash-next-q4", nowRunning: nil)
        XCTAssertFalse(d.stop); XCTAssertTrue(d.start)
    }

    /// A result names a GPU that another program kept busy; older results (no field) do not.
    func testASharedGPUIsNamedAndOldResultsStillLoad() throws {
        var r = BenchResult(modelID: "glm", modelName: "GLM", loadSeconds: 1, promptTPS: 1, promptTokens: 1, decodeTPS: 2.5,
                            decodeTokens: 300, ssdMBs: 0, wiredGB: 123, cpuMoELayers: 0, otherGPU: 80)
        XCTAssertTrue(r.sharedGPU)
        r.otherGPU = 5
        XCTAssertFalse(r.sharedGPU)
        r.otherGPU = nil
        XCTAssertFalse(r.sharedGPU)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as! [String: Any]
        json.removeValue(forKey: "otherGPU")
        let old = try JSONDecoder().decode(BenchResult.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.otherGPU)
        XCTAssertFalse(old.sharedGPU)
    }
}
