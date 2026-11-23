// SPDX-License-Identifier: MIT
import XCTest
@testable import TesseraHost
@testable import TesseraKit

/// Life loops: the tile-agent pick, unread-before-typing, schedule coalescing, desk cleanup and
/// the schedule list a tile and the overseer show.
@MainActor
final class LifeLoopTests: XCTestCase {
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

    private func desk(at directory: URL) -> AgentDesk { AgentDesk(directory: directory) }

    /// Agent launches export TESSERA_TILE_AGENT so Accord's nested gating knows the tile's
    /// client family; shell tiles leave it unset, and an inherited marker never leaks in.
    func testTileAgentEnvironment() {
        func value(_ env: [String], _ key: String) -> String? {
            env.first { $0.hasPrefix(key + "=") }?.split(separator: "=", maxSplits: 1).last.map(String.init)
        }
        let agent = TerminalSession.environment(tileId: "t1", shell: "/bin/zsh", nonce: "n", tileAgent: "claude")
        XCTAssertEqual(value(agent, "TESSERA_TILE_AGENT"), "claude")
        XCTAssertEqual(value(agent, "TESSERA_TILE_ID"), "t1")
        let shell = TerminalSession.environment(tileId: "t2", shell: "/bin/zsh", nonce: "n")
        XCTAssertNil(value(shell, "TESSERA_TILE_AGENT"))
    }

    /// Accord's tile-agent rule marks the actor it picked with `current`: that participant wins
    /// for the tile even when a later listing would otherwise take it.
    func testAgentByTilePrefersTheCurrentParticipant() {
        func participant(_ address: String, tile: String, current: Bool = false) -> [String: Any] {
            var tileInfo: [String: Any] = ["id": tile, "role": "agent"]
            if current { tileInfo["current"] = true }
            return ["address": address, "agent": ["tile": tileInfo]]
        }
        let found = AccordBridge.agentByTile([
            participant("mac/first", tile: "tile-1"),
            participant("mac/middle", tile: "tile-1", current: true),
            participant("mac/last", tile: "tile-1"),
        ], authority: "mac")
        XCTAssertEqual(found["tile-1"]?.address, "mac/middle")
    }

    /// Claude's spinner lives in U+25A0–25FF alongside the braille and dingbat ones.
    func testCleanTitleStripsGeometricSpinners() {
        XCTAssertEqual(TerminalSession.cleanTitle("◐ Thinking hard"), "Thinking hard")
        XCTAssertEqual(TerminalSession.cleanTitle("◓◑◒ Claude Code"), "Claude Code")
        XCTAssertEqual(TerminalSession.cleanTitle("● Working"), "Working")
    }

    /// The overseer tile is Tessera's own face: its agent's origin title never shows.
    func testTheOverseerTileKeepsTesserasTitle() {
        XCTAssertEqual(Workspace.tileTitle(overseer: true, flavor: .claude, storeTitle: "Board mind",
                                           programTitle: "claude"), Overseer.title)
        XCTAssertEqual(Workspace.tileTitle(overseer: false, flavor: .claude, storeTitle: "Board mind",
                                           programTitle: "claude"), "Board mind")
        XCTAssertEqual(Workspace.tileTitle(overseer: false, flavor: .claude, storeTitle: nil,
                                           programTitle: "claude"), "claude")
        XCTAssertNil(Workspace.tileTitle(overseer: false, flavor: .shell, storeTitle: "x",
                                         programTitle: "zsh"))
    }

    /// A newer fire of the same schedule replaces the queued one; the queue carries one wake.
    func testQueuedFiresOfOneScheduleCoalesce() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("desk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let desk = desk(at: dir)
        XCTAssertTrue(desk.importMessage(id: "accord:d1", text: "first", from: "sched", address: nil, tile: nil,
                                       to: "tile-1", title: "Agent", route: .queued, scheduleId: "s-1"))
        XCTAssertTrue(desk.importMessage(id: "accord:d2", text: "second", from: "sched", address: nil, tile: nil,
                                       to: "tile-1", title: "Agent", route: .queued, scheduleId: "s-1"))
        // An unscheduled wake for the same tile is unaffected, and a different schedule is too.
        XCTAssertTrue(desk.importMessage(id: "accord:d3", text: "other", from: "sched", address: nil, tile: nil,
                                       to: "tile-1", title: "Agent", route: .queued, scheduleId: "s-2"))
        let states = desk.messages.map { ($0.id, $0.delivery) }
        XCTAssertEqual(states.map(\.0), ["accord:d1", "accord:d2", "accord:d3"])
        XCTAssertEqual(states.map(\.1), ["superseded", "queued", "queued"])
        XCTAssertEqual(desk.nextQueued(for: "tile-1")?.id, "accord:d2")
        // A superseded message makes no card and no wake mark.
        XCTAssertTrue(desk.sessions.isEmpty)
    }

    /// A delivery the agent already read through Accord settles as handled and is never typed.
    func testHandledDropsTheQueueEntryAndItsMark() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("desk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let desk = desk(at: dir)
        XCTAssertTrue(desk.importMessage(id: "accord:d1", text: "hi", from: "sched", address: nil, tile: nil,
                                       to: "tile-1", title: "Agent", route: .queued))
        XCTAssertNotNil(desk.wakeMark(for: "tile-1"))
        desk.markHandled("accord:d1")
        XCTAssertEqual(desk.messages.first?.delivery, "handled")
        XCTAssertNil(desk.wakeMark(for: "tile-1"))
        // The same delivery re-served isn't imported again.
        XCTAssertTrue(desk.importMessage(id: "accord:d1", text: "hi", from: "sched", address: nil, tile: nil,
                                       to: "tile-1", title: "Agent", route: .queued))
        XCTAssertTrue(desk.messages.filter { $0.id == "accord:d1" }.count == 1)
    }

    /// Waiting and open cards for Accord deliveries name their delivery ids; a delivery read
    /// elsewhere leaves the board.
    func testPendingCardsAndHandled() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("desk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let desk = desk(at: dir)
        XCTAssertTrue(desk.importMessage(id: "accord:w1", text: "ok?", from: "peer", address: nil, tile: nil,
                                       to: "tile-1", title: "Agent", route: .ask))
        XCTAssertTrue(desk.importMessage(id: "accord:w2", text: "open", from: "peer", address: nil, tile: nil,
                                       to: "tile-1", title: "Agent", route: .open))
        XCTAssertTrue(desk.importMessage(id: "local:x", text: "no", from: "peer", address: nil, tile: nil,
                                       to: "tile-1", title: "Agent", route: .ask))
        XCTAssertEqual(desk.pendingCardDeliveries.sorted(), ["w1", "w2"])
        desk.markHandled("accord:w1")
        XCTAssertEqual(desk.pendingCardDeliveries, ["w2"])
        XCTAssertFalse(desk.sessions.contains { $0.id == "ask:accord:w1" })
    }

    /// Terminal-state entries older than a week are pruned; a delivery id is forgotten only
    /// once the bridge's inbox no longer lists it.
    func testPruneAgesOutTerminalMessagesButKeepsInboxIds() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("desk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let desk = desk(at: dir)
        let old = Date().addingTimeInterval(-8 * 24 * 3600)
        desk.typeInto = { _, _ in true }
        XCTAssertTrue(desk.importMessage(id: "accord:old1", text: "a", from: "x", address: nil, tile: nil,
                                       to: "t", title: "T", route: .queued, at: old))
        XCTAssertTrue(desk.deliverQueued("t"))
        XCTAssertTrue(desk.importMessage(id: "accord:old2", text: "b", from: "x", address: nil, tile: nil,
                                       to: "t", title: "T", route: .queued, at: old))
        desk.markHandled("accord:old2")
        // Still in the bridge's inbox: the row goes but its id stays, so it can't be re-imported.
        desk.prune(stillInInbox: ["old2"])
        XCTAssertTrue(desk.messages.isEmpty)
        // old2's id survives: a re-import is refused; old1's is forgotten.
        XCTAssertTrue(desk.importMessage(id: "accord:old1", text: "a", from: "x", address: nil, tile: nil,
                                       to: "t", title: "T", route: .queued))
        desk.prune(stillInInbox: [])
        XCTAssertFalse(desk.messages.contains { $0.id == "accord:old2" })
        // A queued (non-terminal) entry is never pruned.
        XCTAssertTrue(desk.importMessage(id: "accord:live", text: "c", from: "x", address: nil, tile: nil,
                                       to: "t", title: "T", route: .queued, at: old))
        desk.prune(stillInInbox: [])
        XCTAssertTrue(desk.messages.contains { $0.id == "accord:live" })
    }

    /// Closing a tile fails what was queued for it, so the user is told to check.
    func testClosingATileFailsItsQueue() throws {
        let (workspace, dir) = try board()
        let tile = workspace.launch(command: "sleep 30", cwd: dir.path)
        defer { workspace.shutDown(tile) }
        XCTAssertTrue(workspace.desk.importMessage(id: "local:one", text: "hi", from: "x", address: nil,
                                                 tile: nil, to: tile, title: "T", route: .queued))
        _ = workspace.close(tile)
        XCTAssertEqual(workspace.desk.messages.first?.delivery, "failed")
    }

    /// The pump asks bridge-unread before typing an accord: message; unread types, read settles
    /// as handled, and a call that can't be made types as it did before the check existed.
    func testPumpChecksUnreadBeforeTyping() async throws {
        let (workspace, dir) = try board()
        workspace.isWakeableTerminalOverride = { _ in true }
        var typed: [String] = []
        workspace.desk.typeInto = { _, text in typed.append(text); return true }
        func idleTile(_ command: String) async throws -> String {
            let tile = workspace.launch(command: command, cwd: dir.path)
            for _ in 0..<400 where workspace.info(tile)?.activity != .idle { try await Task.sleep(nanoseconds: 50_000_000) }
            return tile
        }
        func settle(until condition: @escaping () -> Bool, seconds: TimeInterval = 20) async {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline, !condition() {
                workspace.pumpWakes()
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        // Unread: typed once the check comes back.
        workspace.accord.unreadOverride = { ids in Set(ids) }
        let live = try await idleTile("sleep 30")
        defer { workspace.shutDown(live) }
        XCTAssertTrue(workspace.desk.importMessage(id: "accord:live1", text: "wake", from: "s", address: nil,
                                                 tile: nil, to: live, title: "T", route: .queued))
        await settle { typed.count == 1 }
        XCTAssertEqual(typed.count, 1)
        XCTAssertEqual(workspace.desk.messages.first?.delivery, "typed")
        // Read meanwhile: handled, never typed.
        workspace.accord.unreadOverride = { _ in [] }
        let read = try await idleTile("sleep 30")
        defer { workspace.shutDown(read) }
        XCTAssertTrue(workspace.desk.importMessage(id: "accord:read1", text: "stale", from: "s", address: nil,
                                                 tile: nil, to: read, title: "T", route: .queued))
        await settle { workspace.desk.messages.last?.delivery == "handled" }
        XCTAssertEqual(typed.count, 1)
        XCTAssertEqual(workspace.desk.messages.last?.delivery, "handled")
        XCTAssertNil(workspace.desk.wakeMark(for: read))
        // The check can't be made (old Accord): typed as today.
        workspace.accord.unreadOverride = { _ in nil }
        let old = try await idleTile("sleep 30")
        defer { workspace.shutDown(old) }
        XCTAssertTrue(workspace.desk.importMessage(id: "accord:old1", text: "wake", from: "s", address: nil,
                                                 tile: nil, to: old, title: "T", route: .queued))
        await settle { typed.count == 2 }
        XCTAssertEqual(typed.count, 2)
        XCTAssertEqual(workspace.desk.messages.last?.delivery, "typed")
    }

    /// A tile shows the live schedules its Accord agent owns or is the target of; ended rows
    /// and other agents' schedules stay away.
    func testSchedulesForTileMatchesItsAgent() throws {
        let (workspace, dir) = try board()
        let tile = workspace.launch(command: "sleep 30", cwd: dir.path)
        defer { workspace.shutDown(tile) }
        workspace.accord.tileRecords = [
            tile: .init(address: "mac/obs-1", agentAddress: "mac/agent-1"),
        ]
        func schedule(_ id: String, owner: String, to: String, state: String = "active") -> AccordSchedule {
            AccordSchedule(["id": id, "state": state, "owner": owner, "to": to,
                            "trigger": "every 10m", "text": "Scheduled by dev (s): check Messenger"])!
        }
        workspace.accord.schedules = [
            schedule("s-1", owner: "mac/agent-1", to: "mac/agent-1"),
            schedule("s-2", owner: "mac/other", to: "mac/agent-1"),
            schedule("s-3", owner: "mac/other", to: "mac/other"),
            schedule("s-4", owner: "mac/agent-1", to: "mac/agent-1", state: "ended"),
        ]
        let shown = workspace.schedules(for: tile)
        XCTAssertEqual(shown.map(\.id), ["s-1", "s-2"])
        XCTAssertEqual(shown.first?.line, "every 10m: check Messenger")
        XCTAssertEqual(workspace.info(tile)?.scheduleLines, ["every 10m: check Messenger", "every 10m: check Messenger"])
    }
}
