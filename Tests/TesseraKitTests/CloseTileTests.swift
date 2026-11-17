import Foundation
import XCTest
@testable import TesseraAPI
@testable import TesseraHost
@testable import TesseraKit

/// The pure close rules: who closes at once, who asks, who is refused.
final class CloseCheckTests: XCTestCase {
    private func check(isOverseer: Bool = false, desk: Bool = false, terminal: Bool = true,
                       activity: TileActivity = .idle, running: Bool = true, suspended: Bool = false,
                       agent: Bool = false, foreground: Bool = false,
                       typed: Date? = nil, now: Date = Date()) -> Workspace.CloseCheck {
        Workspace.closeCheck(isOverseer: isOverseer, isDeskCard: desk, isTerminal: terminal,
                             activity: activity, running: running, suspended: suspended,
                             isAgent: agent, foregroundProgram: foreground, lastUserInputAt: typed, now: now)
    }

    func testTheOverseerIsNeverClosed() {
        XCTAssertEqual(check(isOverseer: true), .never("the overseer's own tile"))
        XCTAssertEqual(check(isOverseer: true, running: false, suspended: true), .never("the overseer's own tile"))
    }

    func testADeskCardDismissesEvenThoughItAsks() {
        XCTAssertEqual(check(desk: true, terminal: false, activity: .needsInput), .ok)
    }

    func testANotRunningOrSuspendedTerminalCloses() {
        XCTAssertEqual(check(running: false), .ok)
        XCTAssertEqual(check(activity: .working, suspended: true), .ok)
    }

    func testAWorkingAskingOrStartingTileIsBusyWhateverItsKind() {
        for kind in [true, false] {
            XCTAssertEqual(check(terminal: kind, activity: .working), .busy("working"))
            XCTAssertEqual(check(terminal: kind, activity: .needsInput), .busy("asking"))
            XCTAssertEqual(check(terminal: kind, activity: .starting), .busy("starting"))
        }
    }

    func testATerminalTypedIntoLatelyIsBusy() {
        let now = Date()
        XCTAssertEqual(check(typed: now.addingTimeInterval(-10), now: now), .busy("being typed into"))
        XCTAssertEqual(check(typed: now.addingTimeInterval(-30), now: now), .ok)
    }

    func testABareShellsForegroundProgramIsBusyButAnAgentsIsNot() {
        XCTAssertEqual(check(agent: false, foreground: true), .busy("running a program other than its shell"))
        XCTAssertEqual(check(agent: false, foreground: false), .ok)
        XCTAssertEqual(check(agent: true, foreground: true), .ok)
        XCTAssertEqual(check(activity: .done, agent: true, foreground: true), .ok)
    }
}

/// close_tile end to end: the tool, the approval card, and the close log.
final class CloseTileTests: XCTestCase {
    private var dir: URL!

    @MainActor
    private func board() throws -> Workspace {
        #if !DEBUG
        throw XCTSkip("needs a debug build")
        #endif
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tessera-close-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { [dir] in try? FileManager.default.removeItem(at: dir!) }
        setenv("TESSERA_DATA_DIR", dir.path, 1)
        defer { unsetenv("TESSERA_DATA_DIR") }
        let workspace = Workspace()
        XCTAssertFalse(workspace.accord.isConfigured)
        workspace.agentTools.attach(workspace)
        return workspace
    }

    @MainActor
    private func tool(_ workspace: Workspace, _ args: [String: Any], tile: String) async throws -> (String, Bool) {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 7, "method": "tools/call",
                                                               "params": ["name": "close_tile", "arguments": args,
                                                                          "_meta": ["tessera/caller": ["tile": tile]]]])
        let (status, data) = await workspace.agentTools.handle(body)
        XCTAssertEqual(status, 200)
        let result = try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [String: Any])?["result"] as? [String: Any])
        return (((result["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(),
                result["isError"] as? Bool ?? false)
    }

    /// A busy bare shell refuses without force; force asks the developer on a card whose
    /// answer closes or keeps the tile.
    @MainActor
    func testABusyShellNeedsForceAndTheCardDecides() async throws {
        let workspace = try board()
        workspace.overseerCommand = "cat"
        let over = try XCTUnwrap(workspace.overseer())
        let cat = workspace.launch(command: "cat", cwd: dir.path)
        defer { workspace.shutDown(cat) }
        for _ in 0..<200 where workspace.terminals[cat]?.runsForegroundProgram != true { try await Task.sleep(nanoseconds: 50_000_000) }
        var (text, failed) = try await tool(workspace, ["tile": cat], tile: over)
        XCTAssertTrue(failed); XCTAssertTrue(workspace.exists(cat))
        (text, failed) = try await tool(workspace, ["tile": cat, "force": true], tile: over)
        XCTAssertFalse(failed)
        XCTAssertTrue(text.contains("Waiting for the developer's OK"), text)
        var cards = workspace.desk.sessions.filter { $0.id.hasPrefix("ask:close:") }
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(workspace.desk.choices(for: cards[0].id), ["Close", "Don't"])
        _ = try await tool(workspace, ["tile": cat, "force": true], tile: over)
        cards = workspace.desk.sessions.filter { $0.id.hasPrefix("ask:close:") }
        XCTAssertEqual(cards.count, 1, "a second request reuses the pending card")
        workspace.desk.respond(cards[0].id, with: "Close")
        XCTAssertFalse(workspace.exists(cat))
        XCTAssertEqual(workspace.recentlyClosed.tiles.first?.id, cat)
    }

    @MainActor
    func testADeclinedCardKeepsTheTile() async throws {
        let workspace = try board()
        workspace.overseerCommand = "cat"
        let over = try XCTUnwrap(workspace.overseer())
        let cat = workspace.launch(command: "cat", cwd: dir.path)
        defer { workspace.shutDown(cat) }
        for _ in 0..<200 where workspace.terminals[cat]?.runsForegroundProgram != true { try await Task.sleep(nanoseconds: 50_000_000) }
        _ = try await tool(workspace, ["tile": cat, "force": true], tile: over)
        let card = workspace.desk.sessions.first { $0.id.hasPrefix("ask:close:") }!
        workspace.desk.respond(card.id, with: "Don't")
        XCTAssertTrue(workspace.exists(cat))
        XCTAssertFalse(workspace.desk.sessions.contains { $0.id == card.id })
    }

    @MainActor
    func testAnIdleAgentClosesAtOnce() async throws {
        let workspace = try board()
        workspace.overseerCommand = "cat"
        workspace.isWakeableTerminalOverride = { _ in true }
        let over = try XCTUnwrap(workspace.overseer())
        let tile = workspace.launch(command: "sleep 30", cwd: dir.path)
        defer { workspace.shutDown(tile) }
        for _ in 0..<400 where workspace.info(tile)?.activity != .idle { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(workspace.info(tile)?.activity, .idle)
        let (text, failed) = try await tool(workspace, ["tile": tile], tile: over)
        XCTAssertFalse(failed); XCTAssertTrue(text.contains("Closed"), text)
        XCTAssertFalse(workspace.exists(tile))
    }

    @MainActor
    func testTheOverseersTileIsNeverClosed() async throws {
        let workspace = try board()
        workspace.overseerCommand = "cat"
        let over = try XCTUnwrap(workspace.overseer())
        let (_, failed) = try await tool(workspace, ["tile": over, "force": true], tile: over)
        XCTAssertTrue(failed)
        XCTAssertTrue(workspace.exists(over))
    }

    /// Dismissing an ask: desk card declines the delivery it carries.
    @MainActor
    func testADeskCardIsDismissedNotClosed() async throws {
        let workspace = try board()
        workspace.overseerCommand = "cat"
        let over = try XCTUnwrap(workspace.overseer())
        let cat = workspace.launch(command: "cat", cwd: dir.path)
        defer { workspace.shutDown(cat) }
        XCTAssertTrue(workspace.desk.importMessage(id: "wake-test", text: "look at this", from: over,
                                                 address: nil, tile: over, to: cat, title: "cat", route: .ask))
        let card = AgentDesk.idPrefix + "wake-test"
        XCTAssertTrue(workspace.desk.sessions.contains { $0.id == card })
        let (text, failed) = try await tool(workspace, ["tile": card], tile: over)
        XCTAssertFalse(failed); XCTAssertTrue(text.hasPrefix("Dismissed"), text)
        XCTAssertFalse(workspace.desk.sessions.contains { $0.id == card })
        XCTAssertEqual(workspace.desk.messages.first { $0.id == "wake-test" }?.delivery, "declined")
    }

    @MainActor
    func testAnUnknownTileIsRefused() async throws {
        let workspace = try board()
        workspace.overseerCommand = "cat"
        let over = try XCTUnwrap(workspace.overseer())
        let (_, failed) = try await tool(workspace, ["tile": "nope"], tile: over)
        XCTAssertTrue(failed)
    }

    /// Every path writes the asker and the outcome to closes.log.
    @MainActor
    func testTheCloseLogKeepsWhoAskedAndWhatHappened() async throws {
        let workspace = try board()
        workspace.overseerCommand = "cat"
        let over = try XCTUnwrap(workspace.overseer())
        let cat = workspace.launch(command: "cat", cwd: dir.path)
        defer { workspace.shutDown(cat) }
        for _ in 0..<200 where workspace.terminals[cat]?.runsForegroundProgram != true { try await Task.sleep(nanoseconds: 50_000_000) }
        _ = try await tool(workspace, ["tile": cat], tile: over)                       // refused
        _ = try await tool(workspace, ["tile": cat, "force": true], tile: over)        // asked
        workspace.desk.respond(workspace.desk.sessions.first { $0.id.hasPrefix("ask:close:") }!.id, with: "Close") // approved + closed
        let cat2 = workspace.launch(command: "cat", cwd: dir.path)
        defer { workspace.shutDown(cat2) }
        for _ in 0..<200 where workspace.terminals[cat2]?.runsForegroundProgram != true { try await Task.sleep(nanoseconds: 50_000_000) }
        _ = try await tool(workspace, ["tile": cat2, "force": true], tile: over)
        workspace.desk.respond(workspace.desk.sessions.first { $0.id.hasPrefix("ask:close:") }!.id, with: "Don't") // declined

        let lines = try String(contentsOf: dir.appendingPathComponent("closes.log"), encoding: .utf8)
            .split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let outcomes = lines.compactMap { $0["outcome"] as? String }
        for want in ["refused", "asked", "approved", "declined", "closed"] {
            XCTAssertTrue(outcomes.contains(want), "missing \(want) in \(outcomes)")
        }
        XCTAssertTrue(lines.contains { ($0["by"] as? String)?.contains("Tessera") == true }, "\(lines)")
    }

    /// A pending close request is kept on disk and loaded again; a day-old one is dropped.
    @MainActor
    func testCloseRequestsPersistAndExpire() throws {
        let workspace = try board()
        workspace.desk.requestClose(from: "tester", fromTile: nil, tile: "t", title: "T", reason: "working")
        let again = AgentDesk(directory: dir)
        XCTAssertEqual(again.closeRequests.count, 1)
        again.requestClose(from: "tester", fromTile: nil, tile: "t2", title: "T2", reason: "working",
                           at: Date().addingTimeInterval(-25 * 3600))
        XCTAssertFalse(again.closeRequests.contains { $0.tile == "t2" })
        XCTAssertTrue(again.closeRequests.contains { $0.tile == "t" })
    }
}

/// A desk card stands as its own lane row; it never makes its target tile look asking, and
/// dismiss on a parent still reaches a real asking child.
final class LaneAskingTests: XCTestCase {
    private var dir: URL!

    @MainActor
    private func board() throws -> Workspace {
        #if !DEBUG
        throw XCTSkip("needs a debug build")
        #endif
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tessera-lane-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { [dir] in try? FileManager.default.removeItem(at: dir!) }
        setenv("TESSERA_DATA_DIR", dir.path, 1)
        defer { unsetenv("TESSERA_DATA_DIR") }
        return Workspace()
    }

    @MainActor
    func testAWakeCardDoesNotMakeItsTargetAsk() async throws {
        let workspace = try board()
        let cat = workspace.launch(command: "cat", cwd: dir.path)
        defer { workspace.shutDown(cat) }
        workspace.agents.hasScanned = true
        XCTAssertTrue(workspace.desk.importMessage(id: "lane-test", text: "take a look", from: "someone",
                                                 address: nil, tile: nil, to: cat, title: "cat", route: .ask))
        workspace.deskChanged()
        workspace.agentsChanged()
        let card = AgentDesk.idPrefix + "lane-test"
        XCTAssertNotEqual(workspace.info(cat)?.activity, .needsInput)
        XCTAssertTrue(workspace.taskIDs.contains(card), "the card is its own lane row, not a child of the tile")
        XCTAssertTrue(workspace.taskTiles.contains { $0.id == card && $0.activity == .needsInput })
        XCTAssertFalse(workspace.terminalAsking(cat))
        XCTAssertEqual(workspace.desk.choices(for: card), ["Deliver", "Don't"])
    }

    /// A non-desk linked session still propagates needsInput, and dismissing the parent clears it.
    @MainActor
    func testALinkedAgentStillAsksThroughItsParent() async throws {
        let workspace = try board()
        let cat = workspace.launch(command: "cat", cwd: dir.path)
        defer { workspace.shutDown(cat) }
        let child = AgentAppSession(id: "accord:linked-child", flavor: .lloom, title: "Linked child",
                                    cwd: "test", openURL: nil, resumeCommand: nil,
                                    snapshot: ConversationSnapshot(items: [], activity: .needsInput,
                                                                   detail: "Pick one", lastEventAt: Date()),
                                    summary: nil, lastActivityAt: Date(), link: cat)
        workspace.agents.hasScanned = true
        workspace.agents.setExternal([child], source: "test")
        workspace.agentsChanged()
        XCTAssertEqual(workspace.info(cat)?.activity, .needsInput)
        workspace.dismiss(cat)
        XCTAssertNotNil(workspace.agents.session("accord:linked-child"), "dismiss sets the child aside; it stays a session")
        XCTAssertNotEqual(workspace.info(cat)?.activity, .needsInput)
    }
}

/// Agents found in a shell's foreground: argv parsing and the pure command guess.
final class ForegroundAgentTests: XCTestCase {
    func testAgentCommand() {
        XCTAssertEqual(TerminalSession.agentCommand(argv: ["/Users/jmac/.bun/bin/omp"]), "omp")
        XCTAssertEqual(TerminalSession.agentCommand(argv: ["/Applications/ChatGPT.app/Contents/codex", "-p", "aj_prod", "resume", "X"]),
                       "codex -p aj_prod resume X")
        XCTAssertEqual(TerminalSession.agentCommand(argv: ["omp", "-r", "X"]), "omp -r X")
        XCTAssertNil(TerminalSession.agentCommand(argv: ["vim", "x"]))
        XCTAssertNil(TerminalSession.agentCommand(argv: ["/usr/local/bin/node", "/x/cli.js"]))
        XCTAssertNil(TerminalSession.agentCommand(argv: ["claude", "auth", "login"]))
    }

    func testProcessArgsReadsThisProcess() {
        XCTAssertFalse(ProcessArgs.argv(of: getpid())?.isEmpty ?? true)
        let started = ProcessArgs.startTime(of: getpid())
        XCTAssertNotNil(started)
        XCTAssertLessThan(Date().timeIntervalSince(started!), 3600)
    }
}
