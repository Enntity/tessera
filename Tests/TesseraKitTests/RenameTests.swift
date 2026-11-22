// SPDX-License-Identifier: MIT
import XCTest
@testable import TesseraHost
@testable import TesseraKit

@MainActor
final class RenameSupportTests: XCTestCase {
    /// Every row of the title-origin table: who owns the name, and who can only answer why not.
    func testEverySourceRow() {
        // Tessera-owned: shells, custom terminals, browsers — immediate, even with nothing running.
        for flavor: AgentFlavor in [.shell, .custom, .web] {
            XCTAssertEqual(RenameSupport.support(kind: .terminal, flavor: flavor, agentRunning: false,
                                                 sessionId: nil), .supported(.tessera))
        }
        XCTAssertEqual(RenameSupport.support(kind: .browser, flavor: .web, agentRunning: false,
                                             sessionId: nil), .supported(.tessera))
        // Typed /rename while the agent runs in the tile.
        for flavor: AgentFlavor in [.claude, .devin, .omp, .antigravity] {
            XCTAssertEqual(RenameSupport.support(kind: .terminal, flavor: flavor, agentRunning: true,
                                                 sessionId: nil), .supported(.typed), "\(flavor)")
            guard case .unsupported(let reason) = RenameSupport.support(kind: .terminal, flavor: flavor,
                                                                        agentRunning: false, sessionId: nil) else {
                return XCTFail("\(flavor) must refuse while its agent isn't running")
            }
            XCTAssertTrue(reason.hasPrefix("This source can't be renamed:"), reason)
        }
        // Codex goes through the app-server once a thread is bound — running or not.
        XCTAssertEqual(RenameSupport.support(kind: .terminal, flavor: .codex, agentRunning: false,
                                             sessionId: "t1"), .supported(.codexAppServer))
        XCTAssertEqual(RenameSupport.support(kind: .agentSession, flavor: .codexDesktop, agentRunning: true,
                                             sessionId: "t1"), .supported(.codexAppServer))
        for kind: TileKind in [.terminal, .agentSession] {
            guard case .unsupported(let reason) = RenameSupport.support(
                    kind: kind, flavor: kind == .terminal ? .codex : .codexDesktop,
                    agentRunning: true, sessionId: nil) else { return XCTFail("unbound Codex must refuse") }
            XCTAssertTrue(reason.contains("no bound conversation"), reason)
        }
        // Sources with no rename mechanism say so.
        for flavor: AgentFlavor in [.grok, .gemini, .opencode, .aider, .dsh] {
            guard case .unsupported(let reason) = RenameSupport.support(kind: .terminal, flavor: flavor,
                                                                        agentRunning: true, sessionId: "x") else {
                return XCTFail("\(flavor) must refuse")
            }
            XCTAssertTrue(reason.hasPrefix("This source can't be renamed:"), reason)
        }
        guard case .unsupported(let claudeApp) = RenameSupport.support(kind: .agentSession, flavor: .claudeDesktop,
                                                                       agentRunning: true, sessionId: "x") else {
            return XCTFail("Claude app must refuse")
        }
        XCTAssertTrue(claudeApp.contains("Claude app"), claudeApp)
        guard case .unsupported(let zcode) = RenameSupport.support(kind: .agentSession, flavor: .zcodeDesktop,
                                                                   agentRunning: true, sessionId: "x") else {
            return XCTFail("ZCode must refuse")
        }
        XCTAssertTrue(zcode.contains("ZCode"), zcode)
        for flavor: AgentFlavor in [.lloom, .agentDesk, .accord] {
            guard case .unsupported = RenameSupport.support(kind: .agentSession, flavor: flavor,
                                                            agentRunning: true, sessionId: nil) else {
                return XCTFail("\(flavor) must refuse")
            }
        }
    }

    /// Anything typed into an agent is one clean line, at most 120 characters, never empty.
    func testSanitizedName() {
        XCTAssertEqual(RenameSupport.sanitizedName("  a\nb  "), "a")
        XCTAssertEqual(RenameSupport.sanitizedName("a\u{7}b"), "ab")
        XCTAssertEqual(RenameSupport.sanitizedName("   "), nil)
        XCTAssertEqual(RenameSupport.sanitizedName(String(repeating: "x", count: 200))?.count, 120)
    }

    /// The app-server handshake and `thread/name/set` carry exactly the settled wire shape.
    func testCodexAppServerWireShape() throws {
        let init_ = CodexAppServer.initializeRequest()
        let hello = try JSONSerialization.jsonObject(with: Data(init_.utf8)) as? [String: Any]
        XCTAssertEqual(hello?["method"] as? String, "initialize")
        let info = (hello?["params"] as? [String: Any])?["clientInfo"] as? [String: Any]
        XCTAssertNotNil(info?["name"])
        let rename = try JSONSerialization.jsonObject(with:
            Data(CodexAppServer.renameRequest(threadId: "thread-1", name: "Harbor").utf8)) as? [String: Any]
        XCTAssertEqual(rename?["method"] as? String, "thread/name/set")
        let params = rename?["params"] as? [String: Any]
        XCTAssertEqual(params?["threadId"] as? String, "thread-1")
        XCTAssertEqual(params?["name"] as? String, "Harbor")
    }
}

@MainActor
final class WorkspaceRenameTests: XCTestCase {
    private func board() throws -> (Workspace, URL) {
        #if !DEBUG
        throw XCTSkip("needs a debug build")
        #endif
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tessera-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        setenv("TESSERA_DATA_DIR", dir.path, 1)
        defer { unsetenv("TESSERA_DATA_DIR") }
        let workspace = Workspace()
        workspace.overseerCommand = "cat"
        return (workspace, dir)
    }

    /// A claude tile adopted into the workspace without launching a real agent.
    private func adopt(_ workspace: Workspace, command: String, sessionId: String? = nil,
                       running: Bool = true, title: String? = nil) -> String {
        let t = TerminalSession(id: "t-\(UUID().uuidString.prefix(6))", command: command,
                                cwd: NSTemporaryDirectory(), title: title, label: command,
                                sessionId: sessionId, startSuspended: true)
        t.isSuspended = false
        t.isRunning = running
        workspace.adopt(t)
        return t.id
    }

    /// Tessera-owned titles apply at once; an empty name goes back to the origin's own.
    func testTesseraOwnedRenameIsImmediate() throws {
        let (workspace, dir) = try board()
        let id = workspace.launch(command: "cat", cwd: dir.path)
        let own = workspace.info(id)?.title
        XCTAssertEqual(try workspace.rename(id, to: "Mine"), "Renamed \(own ?? id) to Mine.")
        XCTAssertEqual(workspace.info(id)?.title, "Mine")
        XCTAssertEqual(try workspace.rename(id, to: "  "), "Reverted to its own title.")
        XCTAssertEqual(workspace.info(id)?.title, own)
    }

    /// An agent terminal's title is its origin's — the program's OSC title, or the bound store's —
    /// never a custom title, and a queued /rename is the only way to change it.
    func testAgentTerminalTitleComesFromOriginAndRenameQueues() throws {
        let (workspace, _) = try board()
        let id = adopt(workspace, command: "claude", sessionId: "s-1")
        // A stale custom title (say, restored by an older build) never shows.
        workspace.terminals[id]?.rename("Stale name")
        XCTAssertEqual(workspace.info(id)?.title, "claude")
        // A queued rename types /rename at the idle prompt through the wake pipeline.
        let answer = try workspace.rename(id, to: "Harbor  Lights")
        XCTAssertEqual(answer, "Will rename claude when Claude Code is idle.")
        let queued = workspace.desk.messages.filter { $0.to == id }
        XCTAssertEqual(queued.last?.text, "/rename Harbor  Lights")
        XCTAssertEqual(queued.last?.delivery, "queued")
        XCTAssertTrue(queued.last?.id.hasPrefix("rename:") == true)
        // While it waits, the tile still shows the origin's current title.
        XCTAssertEqual(workspace.info(id)?.title, "claude")
    }

    /// An agent rename can't be emptied away, and a dead agent refuses with its own reason.
    func testAgentRenameRefusals() throws {
        let (workspace, _) = try board()
        let dead = adopt(workspace, command: "devin", running: false)
        XCTAssertThrowsError(try workspace.rename(dead, to: "x")) { XCTAssertTrue(
            $0.localizedDescription.contains("This source can't be renamed: Devin isn't running")) }
        let live = adopt(workspace, command: "claude", sessionId: "s-2")
        XCTAssertThrowsError(try workspace.rename(live, to: "   ")) { XCTAssertTrue(
            $0.localizedDescription.contains("can't be removed at the source")) }
        let dsh = adopt(workspace, command: "dsh", running: true)
        XCTAssertThrowsError(try workspace.rename(dsh, to: "x")) { XCTAssertTrue(
            $0.localizedDescription.contains("This source can't be renamed: DeepSeek sessions have no supported rename")) }
    }

    /// A bound Codex thread renames through the app-server seam, and the new name shows at once.
    func testCodexRenameGoesThroughAppServer() async throws {
        let (workspace, _) = try board()
        let id = adopt(workspace, command: "codex", sessionId: "thread-9")
        var calls: [(String, String)] = []
        workspace.codexRenameThread = { calls.append(($0, $1)) }
        XCTAssertEqual(try workspace.rename(id, to: "Harbor"), "Renaming codex in Codex.")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(calls.map(\.0), ["thread-9"])
        XCTAssertEqual(calls.map(\.1), ["Harbor"])
    }

    /// An unbound Codex tile refuses until its thread is known.
    func testCodexUnboundRefuses() throws {
        let (workspace, _) = try board()
        let id = adopt(workspace, command: "codex")
        XCTAssertThrowsError(try workspace.rename(id, to: "x")) { XCTAssertTrue(
            $0.localizedDescription.contains("no bound conversation")) }
    }

    /// A kind:"rename" delivery runs the same path — queued for the agent — and is never a prompt.
    /// A refusal reports back instead of typing anything.
    func testRenameDeliveryRoutesAndRefuses() throws {
        let (workspace, _) = try board()
        let id = adopt(workspace, command: "omp", sessionId: nil)
        XCTAssertTrue(workspace.renameDelivery(tile: id, title: "Worker", sender: "mac/agent-1", deliveryId: "d-1"))
        let queued = workspace.desk.messages.filter { $0.to == id }
        XCTAssertEqual(queued.last?.text, "/rename Worker")
        let dsh = adopt(workspace, command: "dsh")
        XCTAssertFalse(workspace.renameDelivery(tile: dsh, title: "x", sender: "mac/agent-1", deliveryId: "d-2"))
        XCTAssertTrue(workspace.desk.messages.filter { $0.to == dsh }.isEmpty)
    }

    /// Each tile's session-report answer is its real rename support.
    func testWorkspaceReportsRenameSupport() throws {
        let (workspace, dir) = try board()
        let shell = workspace.launch(command: "cat", cwd: dir.path)
        XCTAssertEqual(workspace.renameReport(shell).0, "supported")
        let dsh = adopt(workspace, command: "dsh")
        let report = workspace.renameReport(dsh)
        XCTAssertEqual(report.0, "unsupported")
        XCTAssertTrue((report.1 ?? "").contains("can't be renamed"))
    }
}
