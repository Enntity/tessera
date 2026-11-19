import Foundation
import XCTest
@testable import TesseraAPI
@testable import TesseraHost
@testable import TesseraKit

/// Tile lifecycle into Accord: the hourly re-report selection, the closed-while-away sweep,
/// a tile's holds on shared reservations, and the close warning that names them.
final class TileLifecycleTests: XCTestCase {
    private func digest(_ id: String, text: String = "body") -> Steward.Digest {
        Steward.Digest(id: id, title: id, kind: "terminal", flavor: "shell", subtitle: "", state: "working",
                       waiting: false, unseen: false, idleMinutes: 0, detail: nil, text: text)
    }

    // MARK: Which digests the pass reports

    func testAChangedDigestGoesFirstAndAStaleUnchangedOneIsRechosen() {
        let now = Date(), a = digest("a"), b = digest("b"), c = digest("c")
        let seen = ["a": AccordBridge.fingerprint(a), "b": "an-older-fingerprint"]
        let published = ["a": now.addingTimeInterval(-3660), "b": now.addingTimeInterval(-60)]
        // a is unchanged but last reported 61 minutes ago; b changed a minute ago; c is new.
        let picked = AccordBridge.digestsToReport([a, b, c], seen: seen, published: published, now: now)
        XCTAssertEqual(picked.map(\.id), ["c", "b", "a"])
    }

    func testAnUnchangedDigestUnderAnHourIsNotRechosen() {
        let now = Date(), d = digest("d")
        let picked = AccordBridge.digestsToReport([d], seen: ["d": AccordBridge.fingerprint(d)],
                                                  published: ["d": now.addingTimeInterval(-3540)], now: now)
        XCTAssertTrue(picked.isEmpty)
    }

    func testTheReportBatchIsCappedAtSixteen() {
        let now = Date(), digests = (0..<30).map { digest("t\($0)") }
        var seen: [String: String] = [:], published: [String: Date] = [:]
        for d in digests { seen[d.id] = AccordBridge.fingerprint(d); published[d.id] = now.addingTimeInterval(-3700) }
        XCTAssertEqual(AccordBridge.digestsToReport(digests, seen: seen, published: published, now: now).count, 16)
    }

    // MARK: Observations of tiles closed while away

    private func obs(_ tile: String, state: String = "working", retired: Bool = false) -> [String: Any] {
        var o: [String: Any] = ["source": "tessera", "externalId": tile, "state": state]
        if retired { o["retiredAt"] = 1.0 }
        return o
    }

    func testAHiddenTileIsNeverReportedButAMissingOneIs() {
        let own = [obs("hidden"), obs("gone"), obs("overseer")]
        XCTAssertEqual(AccordBridge.closedObservations(own, presentTileIDs: ["hidden", "overseer"]), ["gone"])
    }

    func testARetiredOrTerminalObservationNeedsNoReport() {
        let own = [obs("away-done", state: "done"), obs("away-exited", state: "exited"), obs("away-retired", retired: true),
                   ["source": "tessera", "externalId": "away-flagged", "state": "working", "terminal": true]]
        XCTAssertTrue(AccordBridge.closedObservations(own, presentTileIDs: []).isEmpty)
    }

    /// An empty board is a broken restore, not twenty closed tiles: the sweep never runs.
    func testAnEmptyBoardRefusesTheSweep() {
        let own = (0..<4).map { obs("t\($0)") }
        let missing = AccordBridge.closedObservations(own, presentTileIDs: [])
        XCTAssertFalse(AccordBridge.closedSweepAllowed(own, presentTileIDs: [], missing: missing))
    }

    /// Most of the live observations missing at once is implausible for tiles genuinely closed
    /// while away; the sweep is refused and retried at the next check.
    func testAMostlyMissingBoardRefusesTheSweep() {
        let own = (0..<20).map { obs("t\($0)") }
        let present: Set<String> = Set((0..<8).map { "t\($0)" })
        let missing = AccordBridge.closedObservations(own, presentTileIDs: present)
        XCTAssertEqual(missing.count, 12)
        XCTAssertFalse(AccordBridge.closedSweepAllowed(own, presentTileIDs: present, missing: missing))
    }

    /// A few tiles gone among a healthy board are swept as usual.
    func testAFewMissingTilesStillSweep() {
        let own = (0..<20).map { obs("t\($0)") }
        let present: Set<String> = Set((0..<17).map { "t\($0)" })
        let missing = AccordBridge.closedObservations(own, presentTileIDs: present)
        XCTAssertEqual(missing.count, 3)
        XCTAssertTrue(AccordBridge.closedSweepAllowed(own, presentTileIDs: present, missing: missing))
    }

    // MARK: Which reservations a tile holds

    private func board() throws -> LLoomSchedule.Board {
        try LLoomSchedule.parse(JSONSerialization.data(withJSONObject: [
            "now": 1_760_000_000_000.0,
            "resources": [["id": "spark04", "label": "Spark 04", "holders": ["res-9"], "queue": ["res-queued"]],
                          ["id": "spark03", "holders": []]],
            "reservations": [["id": "res-9", "resource": "spark04", "owner": "devin", "session": "accord:mac/s-1",
                              "state": "active", "expiresAt": 1_760_003_600_000.0],
                             ["id": "res-queued", "resource": "spark04", "owner": "devin", "session": "accord:mac/s-1",
                              "state": "queued"],
                             ["id": "res-other", "resource": "spark03", "owner": "codex", "session": "accord:mac/s-2",
                              "state": "active"]],
            "jobs": [],
        ]))
    }

    func testAHoldMatchesTheTilesAddressAndAQueuedRequestDoesNot() throws {
        let holds = Workspace.tileHolds(try board(), addresses: ["mac/s-1"])
        XCTAssertEqual(holds, [Workspace.TileHold(resource: "Spark 04", reservation: "res-9",
                                                until: Date(timeIntervalSince1970: 1_760_003_600))])
        XCTAssertTrue(Workspace.tileHolds(try board(), addresses: ["mac/s-3"]).isEmpty)
        XCTAssertTrue(Workspace.tileHolds(nil, addresses: ["mac/s-1"]).isEmpty)
    }

    // MARK: The close check and the developer's warning

    func testAHoldingTileAsksEvenWhenIdle() {
        let hold = Workspace.TileHold(resource: "lloom-spark04", reservation: "res-9", until: nil)
        XCTAssertEqual(Workspace.closeCheck(isOverseer: false, isDeskCard: false, isTerminal: true, activity: .idle,
                                            running: true, suspended: false, isAgent: true, foregroundProgram: false,
                                            lastUserInputAt: nil, holds: [hold]),
                       .busy("holds lloom-spark04 (reservation res-9)"))
        let second = Workspace.TileHold(resource: "lloom-spark03", reservation: "res-8", until: nil)
        XCTAssertEqual(Workspace.closeCheck(isOverseer: false, isDeskCard: false, isTerminal: true, activity: .idle,
                                            running: true, suspended: false, isAgent: true, foregroundProgram: false,
                                            lastUserInputAt: nil, holds: [hold, second]),
                       .busy("holds lloom-spark04 (reservation res-9), lloom-spark03 (reservation res-8)"))
    }

    func testCloseWarningNamesOneHoldUntilItsDeadline() {
        let until = Date(timeIntervalSince1970: 1_760_003_600)
        XCTAssertEqual(Workspace.closeWarning([(title: "Devin", holds: [Workspace.TileHold(resource: "lloom-spark04", reservation: "res-9", until: until)])]),
                       "Devin holds lloom-spark04 until \(Workspace.holdTime(until)). Closing ends this agent. "
                       + "Accord releases lloom-spark04 15 minutes later unless the agent comes back.")
    }

    func testCloseWarningListsEveryHoldAndResource() {
        let tiles: [(title: String, holds: [Workspace.TileHold])] = [
            ("Devin", [Workspace.TileHold(resource: "lloom-spark04", reservation: "res-9", until: nil),
                       Workspace.TileHold(resource: "lloom-spark03", reservation: "res-8", until: nil)]),
            ("Codex", [Workspace.TileHold(resource: "lloom-spark04", reservation: "res-7", until: nil)]),
        ]
        XCTAssertEqual(Workspace.closeWarning(tiles),
                       "Devin holds lloom-spark04 with no deadline and lloom-spark03 with no deadline; "
                       + "Codex holds lloom-spark04 with no deadline. Closing ends these agents. "
                       + "Accord releases lloom-spark04 and lloom-spark03 15 minutes later unless the agent comes back.")
        XCTAssertNil(Workspace.closeWarning([(title: "Plain", holds: [])]))
    }
}
