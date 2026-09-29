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

    func testShutDownKeepsTileAndResumeRunsAgain() {
        let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath
        let session = TerminalSession(command: "echo tessera-resume-check", cwd: dir)
        defer { session.terminate() }
        XCTAssertTrue(waitUntil { session.terminal.screenTail(40).contains { $0.contains("tessera-resume-check") } })
        XCTAssertEqual(session.liveDirectory().map { ($0 as NSString).resolvingSymlinksInPath }, dir)
        session.shutDown()
        XCTAssertTrue(session.isSuspended)
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.info.activity, .exited)
        XCTAssertTrue(session.info.detail?.contains("echo tessera-resume-check") == true)
        session.resume()
        XCTAssertFalse(session.isSuspended)
        XCTAssertTrue(waitUntil { session.terminal.screenTail(40).contains { $0.contains("tessera-resume-check") } })
    }

    func testRestoredAgentTileResumesItsSession() {
        let session = TerminalSession(command: "claude --model opus", cwd: NSTemporaryDirectory(),
                                      sessionId: "11111111-2222-3333-4444-555555555555", resuming: true, startSuspended: true)
        XCTAssertTrue(session.isSuspended)
        // No transcript was ever saved for this id, so it starts fresh under the same id.
        XCTAssertEqual(session.resumeHint, "Resume runs: claude --model opus --session-id 11111111-2222-3333-4444-555555555555")
        let duplicate = TerminalSession(command: "claude", cwd: NSTemporaryDirectory(), resuming: true,
                                        mayContinueLatest: false, startSuspended: true)
        XCTAssertEqual(duplicate.resumeHint, "Resume runs: claude")
    }

    /// Through the user's real zsh startup: a typed launcher is adopted as the tile's resumable
    /// agent command, and returning to the prompt drops it.
    func testTypedLauncherIsAdoptedThenDroppedAtPrompt() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tessera-launcher-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let launcher = dir.appendingPathComponent("claude-tessera-probe")
        try "#!/bin/sh\necho probe-running\nexec sleep 30\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let session = TerminalSession(command: nil, cwd: dir.path)
        defer { session.terminate() }
        // Wait for the shell to finish starting (the prompt report arrives with the first prompt).
        XCTAssertTrue(waitUntil(20) { session.terminal.screenTail(40).contains { !$0.isEmpty } })
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        session.send(Array("\(launcher.path) --model opus\r".utf8))
        XCTAssertTrue(waitUntil(10) { session.command == "\(launcher.path) --model opus" })
        XCTAssertEqual(session.flavor, .claude)
        XCTAssertTrue(session.resumeHint.contains("claude-tessera-probe --model opus"))
        session.send([0x03])  // Ctrl-C back to the prompt
        XCTAssertTrue(waitUntil(10) { session.command == nil })
        XCTAssertEqual(session.flavor, .shell)
    }

    private func fakeTool(_ name: String, body: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tessera-fake-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// A resume that fails fast falls back to a fresh start, says so, and forgets the dead id.
    func testFailedResumeFallsBackToFreshStart() throws {
        let tool = try fakeTool("codex-tessera-fake", body: """
        case "$*" in *resume*) echo "no such session" >&2; exit 2;; esac
        echo FRESH-START; exec sleep 30
        """)
        defer { try? FileManager.default.removeItem(at: tool.deletingLastPathComponent()) }
        let session = TerminalSession(command: tool.path, cwd: tool.deletingLastPathComponent().path,
                                      sessionId: "dead-session", resuming: true)
        defer { session.terminate() }
        XCTAssertTrue(waitUntil(20) { session.terminal.screenTail(40).contains { $0.contains("FRESH-START") } })
        XCTAssertTrue(session.terminal.screenTail(40).contains { $0.contains("Could not resume that session") })
        XCTAssertTrue(waitUntil(5) { session.sessionId == nil })
    }

    /// fish users get the same typed-command tracking via Tessera's fish hooks.
    func testFishTracksTypedLaunchers() throws {
        let fish = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let fish else { throw XCTSkip("fish not installed") }
        let tool = try fakeTool("claude-tessera-fish", body: "echo probe; exec sleep 30")
        defer { try? FileManager.default.removeItem(at: tool.deletingLastPathComponent()) }
        let session = TerminalSession(command: nil, cwd: tool.deletingLastPathComponent().path, shell: fish)
        defer { session.terminate() }
        XCTAssertTrue(waitUntil(20) { session.terminal.screenTail(40).contains { !$0.isEmpty } })
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        session.send(Array("\(tool.path)\r".utf8))
        XCTAssertTrue(waitUntil(10) { session.command == tool.path })
        session.send([0x03])
        XCTAssertTrue(waitUntil(10) { session.command == nil })
    }

    /// The tile's report secret must not leak to programs run from the shell.
    func testNonceIsNotExportedToChildren() {
        let session = TerminalSession(command: nil, cwd: NSTemporaryDirectory(), shell: "/bin/zsh")
        defer { session.terminate() }
        XCTAssertTrue(waitUntil(20) { session.terminal.screenTail(40).contains { !$0.isEmpty } })
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        session.send(Array("echo LEAKS=$(env | grep -c TESSERA_NONCE)\r".utf8))
        XCTAssertTrue(waitUntil(10) { session.terminal.screenTail(40).contains { $0.hasPrefix("LEAKS=") } })
        XCTAssertTrue(session.terminal.screenTail(40).contains("LEAKS=0"))
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
