import XCTest
@testable import TesseraHost
@testable import TesseraKit

/// The agent record Tessera merges into its tile records, the title layers it shows, the
/// overseer designation it sends once, and whose scheduled wake a message answers to.
@MainActor
final class AgentRecordTests: XCTestCase {
    private func participant(_ address: String, tile: String? = nil, role: String? = nil,
                             native: [String: Any]? = nil, title: String? = nil,
                             titleSource: String? = nil, task: String? = nil, client: String? = nil) -> [String: Any] {
        var agent: [String: Any] = [:]
        if let tile { agent["tile"] = ["id": tile, "role": role ?? "agent"] }
        if let native { agent["native"] = native }
        if let title { agent["title"] = title }
        if let titleSource { agent["titleSource"] = titleSource }
        if let task { agent["task"] = task }
        if let client { agent["client"] = client }
        return ["address": address, "agent": agent]
    }

    func testAgentByTilePrefersTheAgentRoleAndFallsBackToTheMailboxBinding() {
        let participants = [
            participant("mac/cli", tile: "tile-1", role: "nested"),
            participant("mac/mcp", tile: "tile-1", role: "agent", task: "watching"),
            // An older link: the tile is the participant's mailbox binding, no tile link.
            participant("mac/bound", native: ["source": "tessera", "id": "tile-2"]),
            // Another authority's agent never stands for this host's tile.
            participant("elsewhere/agent", tile: "tile-3", role: "agent"),
            // A participant with no agent record is skipped.
            ["address": "mac/plain"],
        ]
        let found = AccordBridge.agentByTile(participants, authority: "mac")
        XCTAssertEqual(found["tile-1"]?.address, "mac/mcp")
        XCTAssertEqual(found["tile-1"]?.agent["task"] as? String, "watching")
        XCTAssertEqual(found["tile-2"]?.address, "mac/bound")
        XCTAssertNil(found["tile-3"])
    }

    func testScheduledSenderTrustsOnlyTheLocalScheduler() {
        // The overseer's own scheduled wake is judged as the overseer, so its policy types it.
        XCTAssertEqual(AccordBridge.scheduledSender(from: "mac/accord-scheduler", scheduledBy: "mac/overseer", authority: "mac"),
                       "mac/overseer")
        // A remote host's scheduler can carry a scheduledBy for its own owner; here it is only
        // a sender, never a trusted identity.
        XCTAssertEqual(AccordBridge.scheduledSender(from: "spark03/accord-scheduler", scheduledBy: "spark03/overseer", authority: "mac"),
                       "spark03/accord-scheduler")
        // A scheduledBy on any other sender is decoration, not an identity.
        XCTAssertEqual(AccordBridge.scheduledSender(from: "mac/agent", scheduledBy: "mac/overseer", authority: "mac"), "mac/agent")
        XCTAssertEqual(AccordBridge.scheduledSender(from: "mac/accord-scheduler", scheduledBy: "not-an-address", authority: "mac"),
                       "mac/accord-scheduler")
        XCTAssertEqual(AccordBridge.scheduledSender(from: "mac/accord-scheduler", scheduledBy: nil, authority: "mac"),
                       "mac/accord-scheduler")
    }

    func testTheOverseerIsDesignatedOnceItsAgentAddressIsKnown() async throws {
        let bridge = AccordBridge(profile: URL(fileURLWithPath: "/nonexistent/connection.json"))
        var calls: [String] = []
        bridge.designateOperation = { calls.append($0) }
        let c = (URL(string: "http://127.0.0.1")!, "", "mac")
        // Nothing is designated until the overseer tile exists and its agent record has role agent.
        try await bridge.designateOverseer(c, agents: ["tile-1": ("mac/mcp", ["tile": ["id": "tile-1", "role": "agent"]])])
        XCTAssertTrue(calls.isEmpty)
        bridge.overseerTile = { "tile-1" }
        try await bridge.designateOverseer(c, agents: ["tile-1": ("mac/cli", ["tile": ["id": "tile-1", "role": "nested"]])])
        XCTAssertTrue(calls.isEmpty)
        try await bridge.designateOverseer(c, agents: ["tile-1": ("mac/mcp", ["tile": ["id": "tile-1", "role": "agent"]])])
        XCTAssertEqual(calls, ["mac/mcp"])
        // Once designated it is not sent again, even as the record refreshes.
        try await bridge.designateOverseer(c, agents: ["tile-1": ("mac/mcp", ["tile": ["id": "tile-1", "role": "agent"]])])
        XCTAssertEqual(calls, ["mac/mcp"])
    }

    func testARejectedDesignationIsLoggedOnceAndNotRetried() async throws {
        let bridge = AccordBridge(profile: URL(fileURLWithPath: "/nonexistent/connection.json"))
        var calls = 0, logged: [String] = []
        bridge.designateOperation = { _ in calls += 1; throw URLError(.badServerResponse) }
        bridge.logFailure = { logged.append($0) }
        bridge.overseerTile = { "tile-1" }
        let c = (URL(string: "http://127.0.0.1")!, "", "mac")
        let agents: [String: (address: String, agent: [String: Any])] = ["tile-1": ("mac/mcp", ["tile": ["id": "tile-1", "role": "agent"]])]
        try await bridge.designateOverseer(c, agents: agents)
        try await bridge.designateOverseer(c, agents: agents)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(logged.count, 1)
    }

    func testRenameTargetsTheAgentAddressOrTheObservationOnAnOlderAccord() async throws {
        let bridge = AccordBridge(profile: URL(fileURLWithPath: "/nonexistent/connection.json"))
        var sent: [[String: Any]] = []
        bridge.titleOperation = { sent.append($0) }
        // With an agent record the operator title goes to the participant by id.
        bridge.tileRecords = ["tile-1": .init(address: "mac/observed-1", agentAddress: "mac/mcp-1")]
        await bridge.setTileTitle("tile-1", "Harbor")
        XCTAssertEqual(sent.last?["id"] as? String, "mcp-1")
        XCTAssertNil(sent.last?["source"])
        // Without one it lands on the tile's observation, which every Accord accepts.
        await bridge.setTileTitle("tile-9", "")
        XCTAssertEqual(sent.last?["source"] as? String, "tessera")
        XCTAssertEqual(sent.last?["externalId"] as? String, "tile-9")
        XCTAssertEqual(sent.last?["title"] as? String, "")
    }

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

    func testLayeredTitlesOutrankGivenTitleButNotTheUsersOwnName() throws {
        let (workspace, dir) = try board()
        let id = workspace.launch(command: "cat", cwd: dir.path)
        // The agent record's title wins when the overseer, the agent or a peer set it.
        workspace.accord.tileRecords = [id: .init(address: "mac/observed-1", givenTitle: "Old name",
                                                  title: "Overseer name", titleSource: "overseer")]
        XCTAssertEqual(workspace.info(id)?.title, "Overseer name")
        workspace.accord.tileRecords = [id: .init(address: "mac/observed-1", givenTitle: "Old name",
                                                  title: "Agent name", titleSource: "agent")]
        XCTAssertEqual(workspace.info(id)?.title, "Agent name")
        // An operator source is this user's own rename; without one the given title shows.
        workspace.accord.tileRecords = [id: .init(address: "mac/observed-1", givenTitle: "Old name",
                                                  title: "Operator name", titleSource: "operator")]
        XCTAssertEqual(workspace.info(id)?.title, "Old name")
        // The user's own rename still comes first.
        workspace.rename(id, to: "Mine")
        XCTAssertEqual(workspace.info(id)?.title, "Mine")
        workspace.rename(id, to: "")
        XCTAssertEqual(workspace.info(id)?.title, "Old name")
    }

    func testAnOlderAccordsGivenTitleStillShows() throws {
        let (workspace, dir) = try board()
        let id = workspace.launch(command: "cat", cwd: dir.path)
        // No title/titleSource fields at all: the old givenTitle path is unchanged.
        workspace.accord.tileRecords = [id: .init(address: "mac/observed-1", givenTitle: "Given name")]
        XCTAssertEqual(workspace.info(id)?.title, "Given name")
    }

    func testTheListingCarriesTheAgentAddressAndItsTask() {
        let tile = TileInfo(id: "tile-1", kind: .terminal, flavor: .shell, title: "Worker", subtitle: "~/src",
                            activity: .working, lastActivityAt: Date(timeIntervalSince1970: 9_940))
        let record = AccordBridge.TileRecord(address: "mac/observed-1", agentAddress: "mac/mcp-1",
                                             task: "Porting the tokenizer")
        XCTAssertEqual(AgentTools.boardLine(tile, isCaller: false, summary: "", fromAccord: false, record: record,
                                            now: Date(timeIntervalSince1970: 10_000)),
                       "- tile-1 | Worker | Shell | working | ~/src | accord mac/observed-1 | agent mac/mcp-1 | task Porting the tokenizer")
        // No agent record keeps the old shape.
        let plain = AccordBridge.TileRecord(address: "mac/observed-1")
        XCTAssertEqual(AgentTools.boardLine(tile, isCaller: false, summary: "", fromAccord: false, record: plain,
                                            now: Date(timeIntervalSince1970: 10_000)),
                       "- tile-1 | Worker | Shell | working | ~/src | accord mac/observed-1")
    }
}
