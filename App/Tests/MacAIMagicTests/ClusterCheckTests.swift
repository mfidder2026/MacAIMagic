import XCTest
@testable import MacAIMagic

/// Before a start with helpers each one is asked on its port, and while the model loads the transfer is shown.
/// Taken over from WinAIMagic 246584d (ClusterCheckTests there).
@MainActor
final class ClusterCheckTests: XCTestCase {
    func testARealPortOpenAndClosed() async throws {
        let port = Int.random(in: 46_000...47_900)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-I", "-m", "http.server", String(port), "--bind", "127.0.0.1"]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { if server.isRunning { server.terminate() } }
        var open = false
        for _ in 0..<30 where !open {
            try await Task.sleep(for: .milliseconds(100))
            open = await ClusterController.reachable(host: "127.0.0.1", port: port, timeout: 1)
        }
        XCTAssertTrue(open, "something listens there")
        server.terminate()
        server.waitUntilExit()
        let start = Date()
        let closed = await ClusterController.reachable(host: "127.0.0.1", port: port, timeout: 2)
        XCTAssertFalse(closed)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.5, "it gives up within its time")
    }

    func testAHelperThatDoesNotAnswerStaysOutWithTheReason() async throws {
        let c = ClusterController()
        let saved = c.selected
        defer { c.selected = saved; for h in c.helpers where h.host.hasPrefix("10.9.9.") { c.remove(h) } }
        c.probeOverride = { _ in 16310 }
        c.addManual("10.9.9.1:50052", save: false)
        c.addManual("10.9.9.2:50052", save: false)
        try await Task.sleep(for: .milliseconds(100))
        c.selected = ["10.9.9.1:50052", "10.9.9.2:50052"]
        c.reachOverride = { host, _ in host == "10.9.9.1" }
        await c.checkBeforeStart()
        XCTAssertEqual(c.active.map(\.host), ["10.9.9.1"], "the one that does not answer stays out of this start")
        XCTAssertTrue(c.problem?.contains("10.9.9.2") == true, c.problem ?? "")
        // it answers again: it takes part again, and the problem is gone
        c.reachOverride = { _, _ in true }
        await c.checkBeforeStart()
        XCTAssertEqual(Set(c.active.map(\.host)), ["10.9.9.1", "10.9.9.2"])
        XCTAssertNil(c.problem)
    }

    func testTheTransferAndAStall() async {
        let c = ClusterController()
        var sent: UInt64 = 0
        c.sentOverride = { sent }
        var ticks = 0
        // two ticks with 1 MB each, then nothing; it loads for 6 ticks
        let watch = Task { @MainActor in
            await c.watchTransfer(loading: { ticks < 6 }, expected: 10_000_000, tick: 0.05, stallAfter: 0.12)
        }
        for _ in 0..<6 {
            try? await Task.sleep(for: .milliseconds(55))
            if ticks < 2 { sent += 1_000_000 }
            ticks += 1
            if ticks == 2 { try? await Task.sleep(for: .milliseconds(10)) }
        }
        await watch.value
        XCTAssertNil(c.transfer, "gone once it loaded")
        XCTAssertTrue(c.problem?.contains("niets meer") == true || c.problem?.contains("nothing") == true, c.problem ?? "no stall said")
    }

    func testWhatGoesToTheHelpers() {
        XCTAssertEqual(ClusterController.expectedTransfer(modelBytes: 100, helperBudgets: [], localBudget: 50), 0)
        XCTAssertEqual(ClusterController.expectedTransfer(modelBytes: 100, helperBudgets: [50], localBudget: 50), 50)
        XCTAssertEqual(ClusterController.expectedTransfer(modelBytes: 1000, helperBudgets: [30], localBudget: 70), 30, "at most what they hold")
        XCTAssertGreaterThan(ClusterController.bytesSent(), 0, "this Mac has sent something since it started")
    }
}
