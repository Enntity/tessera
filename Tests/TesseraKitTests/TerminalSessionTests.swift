import XCTest
@testable import TesseraHost
@testable import TesseraKit

/// Spawns real PTYs: output must reach the screen, and closing must kill the whole session.
@MainActor
final class TerminalSessionTests: XCTestCase {
    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    func testOutputReachesScreenAndRestartIsClean() {
        let session = TerminalSession(command: "echo tessera-first-run", cwd: NSTemporaryDirectory())
        defer { session.terminate() }
        XCTAssertTrue(waitUntil { session.terminal.screenTail(40).contains { $0.contains("tessera-first-run") } })
        session.restart()
        XCTAssertTrue(waitUntil { session.terminal.screenTail(40).contains { $0.contains("tessera-first-run") } })
    }

    func testTerminateKillsForegroundProgram() {
        let marker = "tessera-sleep-\(Int.random(in: 100_000...999_999))"
        let session = TerminalSession(command: "exec -a \(marker) sleep 600", cwd: NSTemporaryDirectory())
        func running() -> Bool {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            p.arguments = ["-f", marker]
            p.standardOutput = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        }
        XCTAssertTrue(waitUntil { running() })
        session.terminate()
        XCTAssertTrue(waitUntil { !running() })
    }
}

final class LocalSamplerTests: XCTestCase {
    /// Regression: sensor reads after init must not touch a released HID client.
    func testRepeatedSamplesAreSafe() {
        let sampler = LocalSampler()
        var last: LocalSampler.Sample?
        for _ in 0..<5 { last = sampler.sample() }
        XCTAssertNotNil(last?.memory)
        if let t = last?.temperature { XCTAssert((10...120).contains(t)) }
    }
}
