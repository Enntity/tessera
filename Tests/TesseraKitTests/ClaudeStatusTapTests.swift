import XCTest
@testable import TesseraHost

/// The status-line tap edits Claude Code's settings only as far as its own line, keeps what was
/// there running, and gives it back exactly.
final class ClaudeStatusTapTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tessera-tap-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("data"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func settings() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("claude/settings.json"))) as? [String: Any])
    }

    /// Runs the tap as Claude Code would: the status JSON on stdin, what it prints back.
    private func run(_ tap: ClaudeStatusTap, input: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [tap.script.path]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        try p.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        p.waitUntilExit()
        return String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    func testItWrapsTheStatusLineThereWasAndGivesItBack() throws {
        let file = root.appendingPathComponent("claude/settings.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original: [String: Any] = ["model": "opus", "statusLine": ["type": "command", "command": "echo mine", "padding": 2]]
        try JSONSerialization.data(withJSONObject: original).write(to: file)
        let tap = ClaudeStatusTap(directory: root.appendingPathComponent("data"), settings: file)
        XCTAssertFalse(tap.isConnected)

        try tap.connect()
        XCTAssertTrue(tap.isConnected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tap.backup.path))
        var now = try settings()
        XCTAssertEqual(now["model"] as? String, "opus")
        XCTAssertEqual((now["statusLine"] as? [String: Any])?["padding"] as? Int, 2)
        // Connecting again changes nothing (and doesn't take its own line for the user's).
        try tap.connect()
        XCTAssertEqual(try run(tap, input: #"{"model":{}}"#).trimmingCharacters(in: .newlines), "mine")

        // Only a status that carries plan limits is recorded; the user's status line runs either way.
        XCTAssertNil(tap.latest())
        let status = #"{"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":1790003600}}}"#
        XCTAssertEqual(try run(tap, input: status).trimmingCharacters(in: .newlines), "mine")
        XCTAssertEqual(tap.latest().map { String(decoding: $0.data, as: UTF8.self) }, status)

        try tap.disconnect()
        XCTAssertFalse(tap.isConnected)
        now = try settings()
        XCTAssertEqual(now["statusLine"] as? NSDictionary, original["statusLine"] as? NSDictionary)
    }

    func testWithNoStatusLineItPrintsNothingAndDisconnectingRemovesIt() throws {
        let file = root.appendingPathComponent("claude/settings.json")
        let tap = ClaudeStatusTap(directory: root.appendingPathComponent("data"), settings: file)
        try tap.connect()
        XCTAssertEqual(try run(tap, input: #"{"rate_limits":{}}"#), "")
        try tap.disconnect()
        XCTAssertNil(try settings()["statusLine"])
    }
}
