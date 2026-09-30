import XCTest
@testable import TesseraHost
@testable import TesseraKit

/// Spawns real PTYs: output must reach the screen, and closing must kill the whole session.
@MainActor
final class TerminalSessionTests: XCTestCase {
    /// Interactive test shells get a throwaway home: the user's startup files and history are never
    /// read or written.
    private func isolatedHome() throws -> (url: URL, env: [String: String]) {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tessera-home-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return (home, ["HOME": home.path, "TESSERA_USER_ZDOTDIR": home.path, "ZDOTDIR": ShellIntegration.directory.path,
                       "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
                       "XDG_DATA_HOME": home.appendingPathComponent(".local/share").path])
    }

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

    func testATileOnAnotherMachineIsNamedAfterItAndSaysSo() {
        let remote = TerminalSession(command: "ssh -p 2222 me@gpu-box-1", cwd: NSTemporaryDirectory(), startSuspended: true)
        XCTAssertEqual(remote.info.title, "gpu-box-1")
        XCTAssertEqual(remote.info.subtitle, "gpu-box-1")
        // As it is when restored, and a name of the user's own still wins.
        let restored = TerminalSession(command: "ssh gpu-box-1", cwd: NSTemporaryDirectory(), title: "Training", label: "ssh gpu-box-1",
                                       resuming: true, startSuspended: true)
        XCTAssertEqual(restored.info.title, "Training")
        XCTAssertEqual(restored.info.subtitle, "gpu-box-1")
        let local = TerminalSession(command: "make", cwd: "/", startSuspended: true)
        XCTAssertEqual(local.info.title, "make")
        XCTAssertEqual(local.info.subtitle, "/")
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

    /// Two tiles saved in the same conversation: only the first resumes it, the other starts fresh.
    func testRestoredDuplicateConversationStartsFresh() {
        let plan = RestorePlan.plan([.init(id: "a", command: "codex resume S1", cwd: "/w", sessionId: nil),
                                     .init(id: "b", command: "codex resume S1", cwd: "/w", sessionId: nil)])
        let tiles = ["a", "b"].map { id in
            TerminalSession(id: id, command: "codex resume S1", cwd: NSTemporaryDirectory(), sessionId: plan[id]?.sessionId,
                            resuming: true, mayContinueLatest: plan[id]?.mayContinueLatest ?? false, startSuspended: true)
        }
        XCTAssertEqual(tiles.map(\.resumeHint), ["Resume runs: codex resume S1", "Resume runs: codex"])
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

        let home = try isolatedHome()
        let session = TerminalSession(command: nil, cwd: dir.path, shell: "/bin/zsh", environmentOverrides: home.env)
        defer { session.terminate() }
        // Wait for the shell to finish starting (the prompt report arrives with the first prompt).
        XCTAssertTrue(waitUntil(20) { session.terminal.screenTail(40).contains { !$0.isEmpty } })
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        session.send(Array("\(launcher.path) --model opus\r".utf8))
        XCTAssertTrue(waitUntil(10) { session.command == "\(launcher.path) --model opus" })
        XCTAssertEqual(session.flavor, .claude)
        XCTAssertEqual(session.info.flavor, .claude)
        XCTAssertTrue(session.resumeHint.contains("claude-tessera-probe --model opus"))
        session.send([0x03])  // Ctrl-C back to the prompt
        XCTAssertTrue(waitUntil(10) { session.command == nil })
        XCTAssertEqual(session.info.flavor, .shell)
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

    /// A program that isn't on PATH says nothing about its conversation: the tile shuts down with
    /// the id intact instead of starting fresh or dropping to a plain shell.
    func testMissingProgramKeepsTheConversation() throws {
        let home = try isolatedHome()
        let command = "/nonexistent-tessera/codex-tessera-missing"
        let session = TerminalSession(command: command, cwd: NSTemporaryDirectory(), sessionId: "S1", resuming: true,
                                      shell: "/bin/zsh", environmentOverrides: home.env)
        defer { session.terminate() }
        XCTAssertTrue(waitUntil(20) { session.isSuspended })
        XCTAssertEqual(session.command, command)
        XCTAssertEqual(session.sessionId, "S1")
        XCTAssertEqual(session.info.detail, "Not found · Resume runs: \(command) resume S1")
        XCTAssertFalse(session.terminal.screenTail(40).contains { $0.contains("Could not resume") })
    }

    /// Anything else that isn't found (a typo, a missing script) has no conversation to keep: the
    /// tile stays a live shell, as in any terminal.
    func testMissingPlainCommandLeavesAShell() throws {
        let home = try isolatedHome()
        let session = TerminalSession(command: "/nonexistent-tessera/tessera-missing-tool", cwd: NSTemporaryDirectory(),
                                      shell: "/bin/zsh", environmentOverrides: home.env)
        defer { session.terminate() }
        XCTAssertTrue(waitUntil(20) { session.command == nil })
        XCTAssertFalse(session.isSuspended)
        XCTAssertTrue(session.isRunning)
    }

    /// tcsh rejects `-l -i` and can't run the launch script: plain tiles get `-l`, agent tiles run
    /// their script under zsh and then come back to tcsh.
    func testTcshTilesStart() throws {
        let home = try isolatedHome()
        let plain = TerminalSession(command: nil, cwd: NSTemporaryDirectory(), shell: "/bin/tcsh", environmentOverrides: home.env)
        defer { plain.terminate() }
        let agent = TerminalSession(command: "echo tessera-tcsh-agent", cwd: NSTemporaryDirectory(), shell: "/bin/tcsh",
                                    environmentOverrides: home.env)
        defer { agent.terminate() }
        XCTAssertTrue(waitUntil(20) { agent.terminal.screenTail(40).contains { $0.contains("tessera-tcsh-agent") } })
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        for session in [plain, agent] {
            XCTAssertTrue(session.isRunning)
            session.send(Array("echo tessera-$shell-ok\r".utf8))
        }
        XCTAssertTrue(waitUntil(10) { plain.terminal.screenTail(40).contains("tessera-/bin/tcsh-ok") })
        XCTAssertTrue(waitUntil(10) { agent.terminal.screenTail(40).contains("tessera-/bin/tcsh-ok") })
    }

    /// fish users get the same typed-command tracking via Tessera's fish hooks.
    func testFishTracksTypedLaunchers() throws {
        let fish = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let fish else { throw XCTSkip("fish not installed") }
        let tool = try fakeTool("claude-tessera-fish", body: "echo probe; exec sleep 30")
        defer { try? FileManager.default.removeItem(at: tool.deletingLastPathComponent()) }
        let home = try isolatedHome()
        let session = TerminalSession(command: nil, cwd: tool.deletingLastPathComponent().path, shell: fish, environmentOverrides: home.env)
        defer { session.terminate() }
        XCTAssertTrue(waitUntil(20) { session.terminal.screenTail(40).contains { !$0.isEmpty } })
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        session.send(Array("\(tool.path)\r".utf8))
        XCTAssertTrue(waitUntil(10) { session.command == tool.path })
        session.send([0x03])
        XCTAssertTrue(waitUntil(10) { session.command == nil })
    }

    /// The tile's report secret must not leak to programs run from the shell.
    func testNonceIsNotExportedToChildren() throws {
        let home = try isolatedHome()
        let session = TerminalSession(command: nil, cwd: NSTemporaryDirectory(), shell: "/bin/zsh", environmentOverrides: home.env)
        defer { session.terminate() }
        XCTAssertTrue(waitUntil(20) { session.terminal.screenTail(40).contains { !$0.isEmpty } })
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        session.send(Array("echo LEAKS=$(env | grep -c TESSERA_NONCE)\r".utf8))
        XCTAssertTrue(waitUntil(10) { session.terminal.screenTail(40).contains { $0.hasPrefix("LEAKS=") } })
        XCTAssertTrue(session.terminal.screenTail(40).contains("LEAKS=0"))
    }

    /// History must stay in the user's own file, not the shim directory.
    func testZshHistoryStaysInUsersFile() throws {
        let home = try isolatedHome()
        let session = TerminalSession(command: nil, cwd: NSTemporaryDirectory(), shell: "/bin/zsh", environmentOverrides: home.env)
        defer { session.terminate() }
        XCTAssertTrue(waitUntil(20) { session.terminal.screenTail(40).contains { !$0.isEmpty } })
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        session.send(Array("echo HIST=$HISTFILE\r".utf8))
        XCTAssertTrue(waitUntil(10) { session.terminal.screenTail(40).contains { $0.hasPrefix("HIST=") } })
        let line = session.terminal.screenTail(40).first { $0.hasPrefix("HIST=") } ?? ""
        XCTAssertFalse(line.contains("shell-integration"), line)
        XCTAssertEqual(line, "HIST=\(home.url.path)/.zsh_history")
    }

    /// A terminal with nothing happening costs nothing: its clock stops once the screen settles,
    /// and output starts it again.
    func testClockRunsOnlyWhileTheScreenChanges() throws {
        let home = try isolatedHome()
        let session = TerminalSession(command: nil, cwd: NSTemporaryDirectory(), shell: "/bin/zsh", environmentOverrides: home.env)
        defer { session.terminate() }
        XCTAssertTrue(waitUntil(20) { session.terminal.screenTail(40).contains { !$0.isEmpty } })
        XCTAssertTrue(waitUntil(10) { session.clock == nil })
        session.send(Array("echo tessera-tick\r".utf8))
        XCTAssertTrue(waitUntil(5) { session.clock != nil })
        XCTAssertTrue(waitUntil(10) { session.clock == nil })
        XCTAssertTrue(session.terminal.screenTail(40).contains("tessera-tick"))
    }

    /// A terminal that keeps working keeps its age current, a few seconds at a time, even when
    /// nothing else about the tile changes.
    func testWorkingTerminalKeepsItsAgeCurrent() throws {
        let home = try isolatedHome()
        let session = TerminalSession(command: "while :; do echo tick; sleep 0.3; done", cwd: NSTemporaryDirectory(),
                                      shell: "/bin/zsh", environmentOverrides: home.env)
        defer { session.terminate() }
        XCTAssertTrue(waitUntil(20) { session.info.activity == .working })
        let since = session.info.lastActivityAt
        XCTAssertTrue(waitUntil(8) { session.info.lastActivityAt.timeIntervalSince(since) > 3 })
        XCTAssertEqual(session.info.activity, .working)
    }

    /// An answered question stops asking at once, even if what follows is too brief to count as work.
    func testAnsweringAQuestionSettlesTheTile() throws {
        let home = try isolatedHome()
        let session = TerminalSession(command: "printf 'Do you want to proceed? (y/n) '; read -r answer", cwd: NSTemporaryDirectory(),
                                      shell: "/bin/zsh", environmentOverrides: home.env)
        defer { session.terminate() }
        XCTAssertTrue(waitUntil(20) { session.info.activity == .needsInput })
        session.send(Array("y".utf8))
        XCTAssertEqual(session.info.activity, .idle)
        XCTAssertFalse(session.info.attention)
    }

    /// An unbound `resume --last` that may not continue the latest starts clean, not with `--last`.
    func testUnboundContinueStartsFresh() {
        let session = TerminalSession(command: "codex-work resume --last", cwd: NSTemporaryDirectory(), resuming: true,
                                      mayContinueLatest: false, startSuspended: true)
        XCTAssertEqual(session.resumeHint, "Resume runs: codex-work")
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

final class ClaudeLocalUsageTests: XCTestCase {
    func testCountsEachMessageOnceWithinTheWindow() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tessera-usage-\(UUID().uuidString.prefix(6))")
        let project = root.appendingPathComponent("-tmp-proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date()
        func entry(_ id: String, _ at: Date) -> String {
            #"{"type":"assistant","timestamp":"\#(f.string(from: at))","message":{"id":"\#(id)","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":10,"cache_read_input_tokens":99999}}}"#
        }
        let lines = [
            entry("m1", now.addingTimeInterval(-600)),
            entry("m1", now.addingTimeInterval(-600)),          // same message, second content block
            entry("m2", now.addingTimeInterval(-3 * 86_400)),   // this week, not last 5h
            entry("m3", now.addingTimeInterval(-9 * 86_400)),   // older than a week
            #"{"type":"user","message":{"content":"hi"}}"#
        ]
        let path = project.appendingPathComponent("s.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: path, atomically: true, encoding: .utf8)

        let usage = ClaudeLocalUsage(root: root)
        var totals = usage.refresh(now: now)
        XCTAssertEqual(totals.fiveHours.tokens, 160)
        XCTAssertEqual(totals.fiveHours.replies, 1)
        XCTAssertEqual(totals.week.tokens, 320)
        XCTAssertEqual(totals.week.replies, 2)

        // Appends are picked up incrementally.
        let handle = try FileHandle(forWritingTo: path)
        handle.seekToEndOfFile()
        handle.write(Data((entry("m4", now.addingTimeInterval(-60)) + "\n").utf8))
        try handle.close()
        totals = usage.refresh(now: now)
        XCTAssertEqual(totals.fiveHours.replies, 2)

        // Read in chunks far smaller than a line, the counts come out the same.
        let chunked = ClaudeLocalUsage(root: root, chunkSize: 37).refresh(now: now)
        XCTAssertEqual(chunked.fiveHours, totals.fiveHours)
        XCTAssertEqual(chunked.week, totals.week)
    }
}

/// A web tile's load bar belongs to the load: once the page is in, it is gone.
@MainActor
final class BrowserSessionTests: XCTestCase {
    func testProgressClearsWhenTheLoadEnds() throws {
        let page = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tessera-page-\(UUID().uuidString.prefix(6)).html")
        try "<title>Loaded</title><p>hello</p>".write(to: page, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: page) }
        let session = BrowserSession(url: page)
        let deadline = Date().addingTimeInterval(10)
        while session.info.title != "Loaded" || session.webView.isLoading, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(session.info.title, "Loaded")
        XCTAssertNil(session.info.progress)
        XCTAssertEqual(session.info.activity, .idle)
    }

    /// Privacy mode's mosaic hides a page as well in a narrow view, where it fills more of its picture.
    func testMosaicCellsAreSizedToThePage() throws {
        /// How much of the page, in its points, a cell of the mosaic covers.
        func cell(picture: CGSize, pageWidth: CGFloat) throws -> CGSize {
            let image = NSImage(size: picture, flipped: false) { rect in
                NSColor.white.setFill()
                rect.fill()
                return true
            }
            let mosaic = try XCTUnwrap(BrowserSession.mosaic(image, pageWidth: pageWidth)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let pageHeight = picture.height * pageWidth / picture.width
            return CGSize(width: pageWidth / CGFloat(mosaic.width), height: pageHeight / CGFloat(mosaic.height))
        }
        // The same picture of a page 1280 pt wide and of one 456 pt wide: a cell covers as much page in both.
        for pageWidth in [1280.0, 456.0] {
            let cell = try cell(picture: CGSize(width: 640, height: 400), pageWidth: pageWidth)
            XCTAssertEqual(cell.width, BrowserSession.mosaicCell.width, accuracy: 4)
            XCTAssertEqual(cell.height, BrowserSession.mosaicCell.height, accuracy: 2)
        }
        XCTAssertNil(BrowserSession.mosaic(NSImage(size: CGSize(width: 10, height: 10)), pageWidth: 0))
    }
}
