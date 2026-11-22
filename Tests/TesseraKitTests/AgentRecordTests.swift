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

    /// A tile's report to Accord carries its rename support, so a session-title request can be
    /// answered or refused with a reason instead of guessing.
    func testSessionReportCarriesRenameSupportAndReason() {
        let digest = Steward.Digest(id: "tile-1", title: "Build", kind: "terminal", flavor: "shell",
                                    subtitle: "/tmp", state: "idle", waiting: false, unseen: false,
                                    idleMinutes: 0, detail: nil, text: "")
        var args = AccordBridge.reportArgs(digest, key: "k", nowMs: 0, rename: ("supported", nil))
        XCTAssertEqual(args["rename"] as? String, "supported")
        XCTAssertNil(args["renameReason"])
        args = AccordBridge.reportArgs(digest, key: "k", nowMs: 0,
                                       rename: ("unsupported", "This source can't be renamed: x."))
        XCTAssertEqual(args["rename"] as? String, "unsupported")
        XCTAssertEqual(args["renameReason"] as? String, "This source can't be renamed: x.")
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

    /// A tile's title is its origin's own: Accord records never overlay it — the coordinator's
    /// agent record reads this same tile title back as the agent's name.
    func testAccordRecordsNeverOverlayATilesTitle() throws {
        let (workspace, dir) = try board()
        let id = workspace.launch(command: "cat", cwd: dir.path)
        let own = try XCTUnwrap(workspace.info(id)?.title)
        for source in ["overseer", "agent", "peer", "operator"] {
            workspace.accord.tileRecords = [id: .init(address: "mac/observed-1", givenTitle: "Old name",
                                                      title: "\(source) name", titleSource: source)]
            XCTAssertEqual(workspace.info(id)?.title, own)
        }
        // The user's own rename is the tile's origin (a custom shell title), and clearing it
        // goes back to the tile's own.
        try workspace.rename(id, to: "Mine")
        XCTAssertEqual(workspace.info(id)?.title, "Mine")
        try workspace.rename(id, to: "")
        XCTAssertEqual(workspace.info(id)?.title, own)
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

extension AgentRecordTests {
    /// A one-off check against a real new Accord: run it with
    /// `ACCORD_FIXTURE_CLI=/path/to/accord/src/cli.mjs swift test --filter testRealAccord…`.
    /// Until the vendored Accord carries the agent record, the default run skips it.
    func testRealAccordServesFindLocalDesignationAndOperatorTitles() async throws {
        guard let cli = ProcessInfo.processInfo.environment["ACCORD_FIXTURE_CLI"],
              FileManager.default.fileExists(atPath: cli) else {
            throw XCTSkip("set ACCORD_FIXTURE_CLI to an agent-record Accord cli.mjs to run")
        }
        let dir = URL(fileURLWithPath: "/tmp/accord-record-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/accord-fixture.mjs")
        let profile = dir.appendingPathComponent("accord-connection.json")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", script.path, dir.appendingPathComponent("accord-data").path, profile.path]
        process.environment = ProcessInfo.processInfo.environment.merging(["ACCORD_TEST_CLI": cli]) { _, new in new }
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        addTeardownBlock { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: profile.path) && process.isRunning {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let bridge = AccordBridge(profile: profile)

        // find {local:true, detail:true}: the only host is this fixture's authority, and each
        // participant carries an agent object.
        let found = try await bridge.request("find", args: ["detail": true, "local": true])
        let hosts = try XCTUnwrap(found["hosts"] as? [[String: Any]])
        XCTAssertEqual(hosts.count, 1)
        let authority = try XCTUnwrap(hosts[0]["authority"] as? String)
        let participants = try XCTUnwrap(hosts[0]["participants"] as? [[String: Any]])
        let me = try XCTUnwrap(participants.first)
        XCTAssertTrue(String(describing: me["address"] ?? "").hasPrefix(authority + "/"))
        XCTAssertNotNil(me["agent"] as? [String: Any])
        let address = try XCTUnwrap(me["address"] as? String)

        // overseer-designate takes an idempotency key and a local address.
        let designated = try await bridge.request("overseer-designate", args: ["key": "designate:" + address, "address": address])
        XCTAssertEqual(designated["overseer"] as? String, address)

        // session-title renames at the source: a tile that reports rename support gets a
        // kind "rename" bridge delivery; the same key replays instead of duplicating.
        _ = try await bridge.request("session-report", args: ["key": "fixture-report-1", "source": "tessera",
            "externalId": "tile-1", "title": "The Overseer", "state": "idle", "rename": "supported"])
        let id = try XCTUnwrap(address.split(separator: "/").last.map(String.init))
        let titled = try await bridge.request("session-title", args: ["key": "fixture-title-1", "source": "tessera",
                                                                     "externalId": "tile-1", "title": "The Overseer"])
        XCTAssertEqual(titled["rename"] as? String, "requested")
        let replayed = try await bridge.request("session-title", args: ["key": "fixture-title-1", "source": "tessera",
                                                                       "externalId": "tile-1", "title": "The Overseer"])
        XCTAssertEqual(replayed["rename"] as? String, "requested")
        // bridge-inbox surfaces the rename delivery to the tile's host adapter, kind intact
        // (the outbox flushes asynchronously — poll until it lands).
        var rename: [String: Any]?
        for _ in 0..<100 where rename == nil {
            let inbox = try await bridge.request("bridge-inbox", args: ["source": "tessera"])
            rename = ((inbox["deliveries"] as? [[String: Any]]) ?? []).first { $0["externalId"] as? String == "tile-1" }
            if rename == nil { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        XCTAssertEqual(rename?["kind"] as? String, "rename")
        XCTAssertEqual(rename?["title"] as? String, "The Overseer")
        // An agent session with no tile refuses instead of layering on a name.
        do {
            _ = try await bridge.request("session-title", args: ["key": "fixture-title-2", "id": id, "title": "x"])
            XCTFail("a tileless session must refuse session-title")
        } catch { }
    }

    private func heldRecord(_ tile: String, title: String? = nil) -> AccordBridge.TileRecord {
        AccordBridge.TileRecord(address: "mac/" + tile + "-obs", givenTitle: title, changedAt: Date())
    }

    func testMergingAgentsAppliesTheAgentRecordAndLeavesTheObservationIntact() {
        let held = ["tile-1": heldRecord("tile-1", title: "Given name")]
        let agents = AccordBridge.agentByTile([participant("mac/mcp", tile: "tile-1", role: "agent",
                                                         title: "The Overseer", titleSource: "overseer",
                                                         task: "watching the board", client: "devin")], authority: "mac")
        let merged = AccordBridge.mergingAgents(agents, into: held, previous: [:])
        let record = merged["tile-1"]
        XCTAssertEqual(record?.agentAddress, "mac/mcp")
        XCTAssertEqual(record?.title, "The Overseer")
        XCTAssertEqual(record?.titleSource, "overseer")
        XCTAssertEqual(record?.task, "watching the board")
        XCTAssertEqual(record?.client, "devin")
        XCTAssertEqual(record?.givenTitle, "Given name")
        XCTAssertEqual(record?.address, "mac/tile-1-obs")
    }

    func testAMissedFindKeepsTheAgentFieldsTheTileAlreadyHad() {
        let held = ["tile-1": heldRecord("tile-1")]
        let agents = AccordBridge.agentByTile([participant("mac/mcp", tile: "tile-1", title: "The Overseer",
                                                         titleSource: "overseer", task: "watching", client: "devin")], authority: "mac")
        let merged = AccordBridge.mergingAgents(agents, into: held, previous: [:])
        // find failed this pass: nothing about the tile's agent record may change.
        XCTAssertEqual(AccordBridge.mergingAgents(nil, into: held, previous: merged), merged)
    }

    func testATileAbsentFromASuccessfulFindLosesItsAgentFields() {
        let held = ["tile-1": heldRecord("tile-1"), "tile-2": heldRecord("tile-2")]
        var previous = held
        previous["tile-2"]!.agentAddress = "mac/gone"
        previous["tile-2"]!.title = "Old name"
        previous["tile-2"]!.titleSource = "peer"
        previous["tile-2"]!.task = "old task"
        previous["tile-2"]!.client = "cli"
        let agents = AccordBridge.agentByTile([participant("mac/mcp", tile: "tile-1", title: "Kept",
                                                         titleSource: "agent")], authority: "mac")
        let merged = AccordBridge.mergingAgents(agents, into: held, previous: previous)
        XCTAssertEqual(merged["tile-1"]?.title, "Kept")
        XCTAssertNil(merged["tile-2"]?.agentAddress)
        XCTAssertNil(merged["tile-2"]?.title)
        XCTAssertNil(merged["tile-2"]?.titleSource)
        XCTAssertNil(merged["tile-2"]?.task)
        XCTAssertNil(merged["tile-2"]?.client)
    }

    func testMergingTheSamePassTwiceChangesNothing() {
        let held = ["tile-1": heldRecord("tile-1", title: "Given name")]
        let agents = AccordBridge.agentByTile([participant("mac/mcp", tile: "tile-1", title: "The Overseer",
                                                         titleSource: "overseer", task: "watching", client: "devin")],
                                              authority: "mac")
        let first = AccordBridge.mergingAgents(agents, into: held, previous: [:])
        // The refresh loop only assigns when the merge differs, so a repeat pass must be equal.
        XCTAssertEqual(AccordBridge.mergingAgents(agents, into: held, previous: first), first)
    }
}
