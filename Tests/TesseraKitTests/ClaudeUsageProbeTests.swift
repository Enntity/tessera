import XCTest
@testable import TesseraHost

/// Runs the probe against scripts standing in for Claude Code: however the stand-in ends, Tessera
/// must collect it, or it stays in the process table as a zombie until Tessera quits.
@MainActor
final class ClaudeUsageProbeTests: XCTestCase {
    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    /// Runs the probe on `script`, which gets as far as the line that makes the probe give up, and
    /// returns the stand-in's pid once the probe has reported.
    private func probed(_ script: String) throws -> pid_t {
        let pidFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tessera-probe-\(UUID().uuidString.prefix(6))")
        addTeardownBlock { try? FileManager.default.removeItem(at: pidFile) }
        var probe: ClaudeUsageProbe? = ClaudeUsageProbe(
            executable: "/bin/sh", args: ["-c", "echo $$ > '\(pidFile.path)'; \(script)"], quitGrace: 0.2)
        var result: ClaudeUsageProbe.Result?
        // As the usage service does: the probe is let go as soon as it reports.
        probe?.run { result = $0; probe = nil }
        XCTAssertTrue(waitUntil { result != nil }, "the probe never reported")
        let pid = try XCTUnwrap(pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        // A failed assertion must not leave the stand-in behind; one already collected is not ours to signal.
        addTeardownBlock {
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == 0 { kill(pid, SIGKILL); waitpid(pid, &status, 0) }
        }
        return pid
    }

    /// Gone from the process table: a zombie still answers a signal, a collected child doesn't.
    private func collected(_ pid: pid_t) -> Bool { kill(pid, 0) == -1 && errno == ESRCH }

    func testAChildThatQuitsWhenAskedIsCollected() throws {
        let pid = try probed("echo 'Please run /login'; exec sleep 60")
        XCTAssertTrue(waitUntil { collected(pid) }, "left as a zombie")
    }

    func testAChildThatOutlivesTheQuitGraceIsCollected() throws {
        // Ignores Ctrl-C, as Claude Code slow to quit does for a while; ends when told to.
        let pid = try probed("trap '' INT; echo 'Please run /login'; exec sleep 60")
        XCTAssertTrue(waitUntil { collected(pid) }, "left as a zombie")
    }

    func testAChildThatWontEndIsKilledAndCollected() throws {
        let pid = try probed("trap '' INT TERM HUP; echo 'Please run /login'; exec sleep 60")
        XCTAssertTrue(waitUntil { collected(pid) }, "still there")
    }
}
