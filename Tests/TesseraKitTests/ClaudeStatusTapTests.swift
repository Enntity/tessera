import XCTest
@testable import TesseraHost

/// Retiring the old status-line tap puts back exactly the status line it replaced, and touches
/// nothing else in Claude Code's settings.
final class ClaudeStatusTapTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tessera-tap-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("data"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func write(_ object: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    private func settings(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testItPutsBackTheStatusLineItReplaced() throws {
        let data = root.appendingPathComponent("data"), file = root.appendingPathComponent("settings.json")
        let tap = "/bin/sh " + ClaudeStatusTap.quoted(data.appendingPathComponent("claude-statusline.sh").path)
        try write(["model": "opus", "statusLine": ["type": "command", "command": tap, "padding": 2]], to: file)
        let original: [String: Any] = ["type": "command", "command": "echo mine", "padding": 2]
        try write(original, to: data.appendingPathComponent("claude-statusline.previous.json"))
        try Data("x".utf8).write(to: data.appendingPathComponent("claude-status.json"))

        ClaudeStatusTap.retire(in: data, settings: file)
        let now = try settings(file)
        XCTAssertEqual(now["statusLine"] as? NSDictionary, original as NSDictionary)
        XCTAssertEqual(now["model"] as? String, "opus")
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.appendingPathComponent("claude-status.json").path))
    }

    func testWithNoStatusLineBeforeItRemovesItsOwn_AndLeavesOthersAlone() throws {
        let data = root.appendingPathComponent("data"), file = root.appendingPathComponent("settings.json")
        let tap = "/bin/sh " + ClaudeStatusTap.quoted(data.appendingPathComponent("claude-statusline.sh").path)
        try write(["statusLine": ["type": "command", "command": tap]], to: file)
        try write([String: Any](), to: data.appendingPathComponent("claude-statusline.previous.json"))
        ClaudeStatusTap.retire(in: data, settings: file)
        XCTAssertNil(try settings(file)["statusLine"])

        // Someone else's status line is not Tessera's to touch.
        try write(["statusLine": ["type": "command", "command": "echo theirs"]], to: file)
        ClaudeStatusTap.retire(in: data, settings: file)
        XCTAssertEqual((try settings(file)["statusLine"] as? [String: Any])?["command"] as? String, "echo theirs")
    }
}
