import XCTest
@testable import MacAIMagic

/// The gauge while a model loads or unloads (WinAIMagic's test names).
final class LoadClockTests: XCTestCase {
    func testTheGaugeRunsOnTheClockAndNeverFillsBeforeTheEngineAnswers() throws {
        let expected: TimeInterval = 30
        XCTAssertEqual(LoadClock.fraction(reported: 0, elapsed: 15, expected: expected), 0.5, accuracy: 0.001)
        XCTAssertEqual(LoadClock.fraction(reported: 0.8, elapsed: 3, expected: expected), 0.8, accuracy: 0.001, "the engine's own report when further")
        let late = LoadClock.fraction(reported: 0, elapsed: 300, expected: expected)
        XCTAssertTrue(late >= 0.95 && late <= 0.99, "late: creeps, never full (\(late))")
        XCTAssertGreaterThan(LoadClock.fraction(reported: 0, elapsed: 40, expected: expected), LoadClock.fraction(reported: 0, elapsed: 30, expected: expected))
        XCTAssertEqual(LoadClock.remaining(elapsed: 15, expected: expected), 15)
        XCTAssertNil(LoadClock.remaining(elapsed: 31, expected: expected))
        // the first guess from the size: DeepSeek Compact (115 GB) loaded in 57 s from the page cache on the M3 Max
        XCTAssertTrue((50...120).contains(LoadClock.firstLoad(115_000_000_000)), "\(LoadClock.firstLoad(115_000_000_000))")
        // remembered, the newest weighing most
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("load-times-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        LoadClock.record("load:test", took: 10, file: file)
        XCTAssertEqual(LoadClock.expected("load:test", guess: expected, file: file), 10, accuracy: 0.001)
        LoadClock.record("load:test", took: 20, file: file)
        XCTAssertEqual(LoadClock.expected("load:test", guess: expected, file: file), 16, accuracy: 0.001)
        XCTAssertEqual(LoadClock.expected("load:other", guess: expected, file: file), expected)
    }

    @MainActor func testUnloadingIsAStateOfItsOwn() {
        XCTAssertFalse(EngineController.State.stopping.isRunning, "nothing is sent to an engine that unloads")
        XCTAssertEqual(Theme.statusText(.stopping), L("Model ontladen…"))
        XCTAssertEqual(Theme.statusText(.running), L("Model geladen"))
        // a stop without a process stays stopped, with no gauge
        let engine = EngineController(port: 1)
        engine.stop()
        XCTAssertEqual(engine.state, .stopped)
        XCTAssertNil(engine.phaseStart)
    }
}
