import Foundation
import XCTest
@testable import TesseraAPI
@testable import TesseraHost
@testable import TesseraKit

/// open_tile end to end: the tool, the guardrails, and the open log.
final class OpenTileTests: XCTestCase {
    private var dir: URL!

    @MainActor
    private func board() throws -> Workspace {
        #if !DEBUG
        throw XCTSkip("needs a debug build")
        #endif
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tessera-open-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { [dir] in try? FileManager.default.removeItem(at: dir!) }
        setenv("TESSERA_DATA_DIR", dir.path, 1)
        defer { unsetenv("TESSERA_DATA_DIR") }
        let workspace = Workspace()
        XCTAssertFalse(workspace.accord.isConfigured)
        workspace.agentTools.attach(workspace)
        workspace.accordAddressWait = 0
        return workspace
    }

    @MainActor
    private func tool(_ workspace: Workspace, _ args: [String: Any], tile: String) async throws -> (String, Bool) {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 7, "method": "tools/call",
                                                               "params": ["name": "open_tile", "arguments": args,
                                                                          "_meta": ["tessera/caller": ["tile": tile]]]])
        let (status, data) = await workspace.agentTools.handle(body)
        XCTAssertEqual(status, 200)
        let result = try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [String: Any])?["result"] as? [String: Any])
        return (((result["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(),
                result["isError"] as? Bool ?? false)
    }

    /// A shell opens in its directory without touching the developer's view: the board query,
    /// filter and selection stay, and the tile lands after the caller (or at the end).
    @MainActor
    func testAShellOpensQuietlyInItsDirectory() async throws {
        let workspace = try board()
        workspace.overseerCommand = "cat"
        let over = try XCTUnwrap(workspace.overseer())
        let selected = workspace.selectedId
        let (text, failed) = try await tool(workspace, ["agent": "shell", "cwd": dir.path], tile: over)
        XCTAssertFalse(failed, text)
        let id = try XCTUnwrap(text.split(separator: " ").first(where: { $0.count == 36 }).map(String.init), text)
        let t = try XCTUnwrap(workspace.terminals[id])
        XCTAssertNil(t.command)
        XCTAssertEqual(t.cwd, dir.path)
        XCTAssertEqual(workspace.selectedId, selected)
        // The caller has no tab of its own here, so the tile sits right behind it.
        XCTAssertEqual(workspace.order.firstIndex(of: id), workspace.order.firstIndex(of: over).map { $0 + 1 })
        XCTAssertTrue(text.contains("Opened"), text)
    }

    /// An installed agent opens with its preset command, its title, and a first message queued
    /// the way send_to_tile queues it.
    @MainActor
    func testAnAgentOpensTitledWithAPromptQueued() async throws {
        let workspace = try board()
        workspace.overseerCommand = "cat"
        workspace.openTileAgentsOverride = ["claude", "codex", "devin", "omp"]
        let over = try XCTUnwrap(workspace.overseer())
        let (text, failed) = try await tool(workspace, ["agent": "claude", "cwd": dir.path,
                                                        "title": "Reviewer", "prompt": "check the build"], tile: over)
        XCTAssertFalse(failed, text)
        let id = try XCTUnwrap(text.split(separator: " ").first(where: { $0.count == 36 }).map(String.init), text)
        let t = try XCTUnwrap(workspace.terminals[id])
        XCTAssertEqual(t.command, "claude")
        XCTAssertEqual(t.customTitle, "Reviewer")
        let queued = workspace.desk.messages.first { $0.to == id }
        XCTAssertEqual(queued?.delivery, "queued")
        XCTAssertEqual(queued?.fromTile, over)
        XCTAssertTrue(text.contains("Will be typed"), text)
        workspace.shutDown(id)
    }

    /// A resume builds the tool's resume command and binds the session id; a second tile for the
    /// same conversation is refused.
    @MainActor
    func testAResumeOpensOncePerConversation() async throws {
        let workspace = try board()
        workspace.overseerCommand = "cat"
        workspace.openTileAgentsOverride = ["devin"]
        let over = try XCTUnwrap(workspace.overseer())
        let (text, failed) = try await tool(workspace, ["agent": "devin", "cwd": dir.path, "resume": "ring-cougar"], tile: over)
        XCTAssertFalse(failed, text)
        let id = try XCTUnwrap(text.split(separator: " ").first(where: { $0.count == 36 }).map(String.init), text)
        let t = try XCTUnwrap(workspace.terminals[id])
        XCTAssertEqual(t.command, "devin -r ring-cougar")
        XCTAssertEqual(t.sessionId, "ring-cougar")
        let (_, again) = try await tool(workspace, ["agent": "devin", "cwd": dir.path, "resume": "ring-cougar"], tile: over)
        XCTAssertTrue(again)
        workspace.shutDown(id)
    }

    @MainActor
    func testRefusals() async throws {
        let workspace = try board()
        workspace.overseerCommand = "cat"
        workspace.openTileAgentsOverride = ["claude", "devin", "omp"]
        let over = try XCTUnwrap(workspace.overseer())
        try "x".write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        for (args, why) in [
            (["agent": "bash -c rm", "cwd": dir.path], "arbitrary command"),
            (["agent": "aider", "cwd": dir.path], "not an openable agent"),
            (["agent": "shell", "cwd": "/no/such/dir/xyz"], "missing cwd"),
            (["agent": "shell", "cwd": dir.appendingPathComponent("f.txt").path], "cwd is a file"),
            (["agent": "claude", "cwd": dir.path, "resume": "x; rm"], "unsafe id"),
            (["agent": "shell", "cwd": dir.path, "prompt": "hi"], "prompt with shell"),
            (["agent": "shell", "cwd": dir.path, "resume": "abc123"], "resume with shell"),
            (["reopen": "ghost", "agent": "shell"], "reopen with agent"),
            (["reopen": "ghost"], "unknown id"),
            (["agent": "codex", "cwd": dir.path], "not installed"),
        ] as [([String: Any], String)] {
            let (text, failed) = try await tool(workspace, args, tile: over)
            XCTAssertTrue(failed, "\(why) should refuse: \(text)")
        }
    }

    /// A closed tile comes back by id through the same reopen the developer gets.
    @MainActor
    func testReopenBringsAClosedTileBack() async throws {
        let workspace = try board()
        workspace.overseerCommand = "cat"
        let over = try XCTUnwrap(workspace.overseer())
        let cat = workspace.launch(command: "cat", cwd: dir.path)
        defer { workspace.shutDown(cat) }
        workspace.close(cat)
        XCTAssertFalse(workspace.exists(cat))
        let (text, failed) = try await tool(workspace, ["reopen": cat], tile: over)
        XCTAssertFalse(failed, text)
        XCTAssertTrue(workspace.exists(cat))
        XCTAssertTrue(text.contains(cat), text)
    }

    /// The hourly cap is per caller: the limit+1th open is refused, another caller still opens.
    @MainActor
    func testTheHourlyCapIsPerCaller() async throws {
        let workspace = try board()
        workspace.overseerCommand = "cat"
        let over = try XCTUnwrap(workspace.overseer())
        let other = workspace.launch(command: "cat", cwd: dir.path)
        defer { workspace.shutDown(other) }
        Preferences.store.set(2, forKey: "tessera.agentOpensPerHour")
        defer { Preferences.store.removeObject(forKey: "tessera.agentOpensPerHour") }
        var opened: [String] = []
        for _ in 0..<2 {
            let (text, failed) = try await tool(workspace, ["agent": "shell", "cwd": dir.path], tile: over)
            XCTAssertFalse(failed, text)
            if let id = text.split(separator: " ").first(where: { $0.count == 36 }).map(String.init) { opened.append(id) }
        }
        defer { opened.forEach { workspace.shutDown($0) } }
        let (text, failed) = try await tool(workspace, ["agent": "shell", "cwd": dir.path], tile: over)
        XCTAssertTrue(failed)
        XCTAssertTrue(text.contains("limit 2"), text)
        let (otherText, otherFailed) = try await tool(workspace, ["agent": "shell", "cwd": dir.path], tile: other)
        XCTAssertFalse(otherFailed, otherText)
        if let id = otherText.split(separator: " ").first(where: { $0.count == 36 }).map(String.init) { workspace.shutDown(id) }
    }

    /// Every attempt writes the asker and the outcome to opens.log.
    @MainActor
    func testTheOpenLogKeepsWhoAskedAndWhatHappened() async throws {
        let workspace = try board()
        workspace.overseerCommand = "cat"
        workspace.openTileAgentsOverride = ["claude"]
        let over = try XCTUnwrap(workspace.overseer())
        let (text, _) = try await tool(workspace, ["agent": "shell", "cwd": dir.path], tile: over) // opened
        let id = text.split(separator: " ").first(where: { $0.count == 36 }).map(String.init)!
        _ = try await tool(workspace, ["agent": "wat", "cwd": dir.path], tile: over)               // refused
        workspace.close(id)
        _ = try await tool(workspace, ["reopen": id], tile: over)                                 // reopened
        defer { workspace.shutDown(id) }

        let lines = try String(contentsOf: dir.appendingPathComponent("opens.log"), encoding: .utf8)
            .split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let outcomes = lines.compactMap { $0["outcome"] as? String }
        for want in ["opened", "reopened", "refused"] {
            XCTAssertTrue(outcomes.contains(want), "missing \(want) in \(outcomes)")
        }
        XCTAssertTrue(lines.contains { ($0["by"] as? String)?.contains("Tessera") == true }, "\(lines)")
        XCTAssertTrue(lines.contains { $0["agent"] as? String == "shell" })
    }

    /// board lists closed tiles under "Recently closed" so agents can reopen them.
    @MainActor
    func testBoardListsRecentlyClosed() async throws {
        let workspace = try board()
        workspace.overseerCommand = "cat"
        let over = try XCTUnwrap(workspace.overseer())
        let cat = workspace.launch(command: "cat", cwd: dir.path, title: "The Closed One")
        defer { workspace.shutDown(cat) }
        workspace.close(cat)
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 7, "method": "tools/call",
                                                               "params": ["name": "board", "arguments": [:],
                                                                          "_meta": ["tessera/caller": ["tile": over]]]])
        let (_, data) = await workspace.agentTools.handle(body)
        let result = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["result"] as? [String: Any]
        let text = ((result?["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
        XCTAssertTrue(text.contains("Recently closed ("), text)
        XCTAssertTrue(text.contains(cat), text)
        XCTAssertTrue(text.contains("The Closed One"), text)
    }
}
