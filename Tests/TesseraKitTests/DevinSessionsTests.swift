import XCTest
@testable import TesseraHost
@testable import TesseraKit

/// Devin's `session_locks/<id>.lock` files name the session whose `devin acp` pid is in a tile's
/// foreground process group. These write fake locks into a temporary folder.
final class DevinSessionsTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tessera-devin-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func lock(_ name: String, in dir: URL, pid: pid_t, modified: Date = Date()) throws {
        let url = dir.appendingPathComponent(name + ".lock")
        try Data("\(pid)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    /// A pid nobody is: run a short-lived process to the end and take its number.
    private func deadPid() throws -> pid_t {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try p.run()
        p.waitUntilExit()
        return p.processIdentifier
    }

    func testLockWhosePidIsInTheGroupMatches() throws {
        let dir = try tempDir()
        let pgid = getpgid(getpid())
        try lock("hammerhead-cookie", in: dir, pid: getpid())
        XCTAssertEqual(DevinSessions.session(forProcessGroup: pgid, locks: dir), "hammerhead-cookie")
        // A lock left behind by a dead session matches nothing.
        let other = try tempDir()
        try lock("stale-one", in: other, pid: deadPid())
        XCTAssertNil(DevinSessions.session(forProcessGroup: pgid, locks: other))
    }

    func testNewestMatchingLockWins() throws {
        let dir = try tempDir()
        let pgid = getpgid(getpid())
        // A REPL that moved between sessions leaves one lock per session it ran.
        try lock("older-session", in: dir, pid: getpid(), modified: Date().addingTimeInterval(-600))
        try lock("newer-session", in: dir, pid: getpid(), modified: Date())
        XCTAssertEqual(DevinSessions.session(forProcessGroup: pgid, locks: dir), "newer-session")
    }

    func testLocksOutsideTheGroupAndUnsafeNamesAreSkipped() throws {
        let dir = try tempDir()
        let pgid = getpgid(getpid())
        try lock("init", in: dir, pid: 1)
        try lock("not an id", in: dir, pid: getpid())
        try lock("malformed", in: dir, pid: getpid())
        // A lock whose contents aren't a pid never matches.
        try Data("hello\n".utf8).write(to: dir.appendingPathComponent("malformed.lock"))
        XCTAssertNil(DevinSessions.session(forProcessGroup: pgid, locks: dir))
        XCTAssertNil(DevinSessions.session(forProcessGroup: pgid, locks: dir.appendingPathComponent("missing")))
    }
}
