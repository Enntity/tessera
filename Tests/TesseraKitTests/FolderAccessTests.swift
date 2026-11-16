import XCTest
@testable import TesseraHost
@testable import TesseraKit

/// Folder-access probing and how a tile behaves while macOS decides whether Tessera may open its
/// working folder.
@MainActor
final class FolderAccessTests: XCTestCase {
    override func setUp() {
        FolderAccess.reset()
    }

    override func tearDown() {
        FolderAccess.reset()
    }

    private func path() -> String {
        NSTemporaryDirectory() + "folder-access-\(UUID().uuidString.prefix(6))"
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    func testAFastAnswerComesBackSynchronously() {
        FolderAccess.opener = { _ in 0 }
        var called = false
        let outcome = FolderAccess.probe(path()) { _ in called = true }
        XCTAssertEqual(outcome, .reachable)
        XCTAssertFalse(called)
    }

    func testASlowAnswerFinishesOnMainAndProbesJoinIt() {
        let folder = path()
        FolderAccess.opener = { _ in Thread.sleep(forTimeInterval: 1); return 0 }
        let done = expectation(description: "probe finishes")
        var outcome: FolderAccess.Outcome?
        XCTAssertNil(FolderAccess.probe(folder) { result in outcome = result; done.fulfill() })
        // A second probe for the same folder doesn't wait out the patience again.
        let started = Date()
        XCTAssertNil(FolderAccess.probe(folder) { _ in })
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1)
        wait(for: [done], timeout: 5)
        XCTAssertEqual(outcome, .reachable)
        XCTAssertEqual(FolderAccess.probe(folder), .reachable)
    }

    func testARefusedFolderIsDenied() {
        FolderAccess.opener = { _ in EPERM }
        XCTAssertEqual(FolderAccess.probe(path()), .denied(EPERM))
        FolderAccess.reset()
        FolderAccess.opener = { _ in EACCES }
        XCTAssertEqual(FolderAccess.probe(path()), .denied(EACCES))
    }

    /// Any other failure (a folder that isn't there, say) stays forkpty's business.
    func testOtherErrnosStillSpawn() {
        FolderAccess.opener = { _ in ENOENT }
        XCTAssertEqual(FolderAccess.probe(path()), .reachable)
    }

    func testARefusedFolderFailsTheTileInsteadOfSpawning() throws {
        FolderAccess.opener = { _ in EPERM }
        let session = TerminalSession(command: "echo should-not-run", cwd: path())
        defer { session.terminate() }
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.info.activity, .failed)
        XCTAssertTrue(session.info.detail?.contains("Privacy & Security") == true)
        XCTAssertTrue(session.info.attention)
    }

    func testAWaitingFolderSaysSoThenLaunches() throws {
        let folder = try isolatedHome()
        FolderAccess.opener = { _ in Thread.sleep(forTimeInterval: 1); return 0 }
        let session = TerminalSession(command: "echo folder-probe-done", cwd: folder.url.path, environmentOverrides: folder.env)
        defer { session.terminate() }
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.info.activity, .needsInput)
        XCTAssertTrue(session.info.detail?.contains("Waiting for macOS") == true)
        XCTAssertTrue(session.info.attention)
        XCTAssertTrue(waitUntil { session.terminal.screenTail(40).contains { $0.contains("folder-probe-done") } })
        XCTAssertTrue(session.isRunning)
    }

    /// The same throwaway home TerminalSessionTests uses, so real shells don't read the user's files.
    private func isolatedHome() throws -> (url: URL, env: [String: String]) {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tessera-home-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return (home, ["HOME": home.path, "TESSERA_USER_ZDOTDIR": home.path, "ZDOTDIR": ShellIntegration.directory.path,
                       "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
                       "XDG_DATA_HOME": home.appendingPathComponent(".local/share").path])
    }
}
