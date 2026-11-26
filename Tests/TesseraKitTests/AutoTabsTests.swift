// SPDX-License-Identifier: MIT
import XCTest
@testable import TesseraHost
@testable import TesseraKit

/// Tabs Tessera keeps for the user: what the user placed stays placed, everything else is filed —
/// spawned work beside where it came from, the rest where the model says.
final class AutoTabsTests: XCTestCase {
    func testFilingNeverMovesWhatTheUserPlaced() {
        var groups = TileGroups()
        let mine = groups.create(named: "Mine")
        let other = groups.create(named: "Other")
        groups.assign("a", to: mine)
        XCTAssertFalse(groups.isMovable("a"))
        XCTAssertFalse(groups.file("a", to: other))
        XCTAssertEqual(groups.group(of: "a")?.id, mine)

        // Dragged back to All, a tile stays on All.
        groups.assign("a", to: nil)
        XCTAssertFalse(groups.isMovable("a"))
        XCTAssertFalse(groups.file("a", to: other))
        XCTAssertNil(groups.group(of: "a"))

        // A tile nobody placed is Tessera's to file, and to file again.
        XCTAssertTrue(groups.isMovable("b"))
        XCTAssertTrue(groups.file("b", to: mine))
        XCTAssertTrue(groups.isMovable("b"))
        XCTAssertTrue(groups.file("b", to: other))
        XCTAssertEqual(groups.group(of: "b")?.id, other)
        XCTAssertFalse(groups.file("b", to: other), "filing where it already is changes nothing")

        // Once the user moves it, it is theirs.
        groups.assign("b", to: mine)
        XCTAssertFalse(groups.isMovable("b"))
    }

    func testTabsSavedBeforeAutoTabsAreTheUsers() throws {
        let old = #"[{"id":"g","name":"Old","tileIds":["a","b"]}]"#
        let list = try JSONDecoder().decode([TileGroup].self, from: Data(old.utf8))
        let groups = TileGroups(list)
        XCTAssertFalse(groups.list[0].isTessera)
        XCTAssertFalse(groups.isMovable("a"))
        XCTAssertFalse(groups.isMovable("b"))
    }

    func testTesseraTabsGoWhenEmptyAndBecomeTheUsersWhenRenamed() {
        var groups = TileGroups()
        let made = groups.create(named: "Made", byTessera: true)
        let kept = groups.create(named: "Kept")
        XCTAssertTrue(groups.file("a", to: made))
        groups.prune(existing: ["a"])
        XCTAssertEqual(groups.list.map(\.id), [made, kept])
        groups.prune(existing: [])
        XCTAssertEqual(groups.list.map(\.id), [kept], "an empty tab Tessera made goes; the user's stays")

        let renamed = groups.create(named: "Made again", byTessera: true)
        groups.rename(renamed, to: "Now mine")
        groups.prune(existing: [])
        XCTAssertEqual(groups.list.map(\.name), ["Kept", "Now mine"])
    }

    func testSpawnedWorkFollowsWhereItCameFrom() {
        var groups = TileGroups()
        let tab = groups.create(named: "Tessera")
        let elsewhere = groups.create(named: "Elsewhere")
        groups.assign("parent", to: tab)
        groups.assign("pinned-child", to: elsewhere)
        let origins = ["child": "parent", "grandchild": "child", "pinned-child": "parent", "orphan": "gone"]
        XCTAssertTrue(groups.follow(origins))
        XCTAssertEqual(groups.group(of: "child")?.id, tab)
        XCTAssertEqual(groups.group(of: "grandchild")?.id, tab, "a chain of spawns ends up together")
        XCTAssertEqual(groups.group(of: "pinned-child")?.id, elsewhere, "the user's placement wins")
        XCTAssertNil(groups.group(of: "orphan"))
        XCTAssertFalse(groups.follow(origins), "nothing left to move")

        // The parent moves; what Tessera filed beside it goes along.
        groups.assign("parent", to: elsewhere)
        XCTAssertTrue(groups.follow(origins))
        XCTAssertEqual(groups.group(of: "child")?.id, elsewhere)
        XCTAssertEqual(groups.group(of: "grandchild")?.id, elsewhere)
    }

    func testClaudeSessionOrigin() {
        XCTAssertEqual(TranscriptScanner.claudeOrigin(["spawnedFrom": ["sessionId": "local_abc-1"]]), "claude:local_abc-1")
        XCTAssertEqual(TranscriptScanner.claudeOrigin(["forkedFromSessionId": "local_def-2"]), "claude:local_def-2")
        XCTAssertNil(TranscriptScanner.claudeOrigin(["spawnedFrom": ["sessionId": "bad id; rm"]]))
        XCTAssertNil(TranscriptScanner.claudeOrigin([:]))
    }

    // MARK: The model's plan

    private let tabs = [Steward.TabDigest(id: "t1", name: "Tessera", byUser: true)]
    private let tiles = [
        Steward.TabTile(id: "a", title: "Fix rename focus", folder: "~/tessera", tab: nil, movable: true, summary: nil),
        Steward.TabTile(id: "b", title: "LLooM image refs", folder: "~/lloom", tab: nil, movable: true, summary: nil),
        Steward.TabTile(id: "c", title: "Pinned", folder: "~", tab: "t1", movable: false, summary: nil),
        Steward.TabTile(id: "d", title: "Already there", folder: "~/tessera", tab: "t1", movable: true, summary: nil)
    ]

    private func completion(_ content: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
    }

    func testPlanKeepsOnlyMovesTheBoardCanMake() throws {
        let answer = """
        {"moves":[{"id":"a","tab":"t1"},{"id":"b","tab":"LLooM"},{"id":"c","tab":"LLooM"},
        {"id":"d","tab":"t1"},{"id":"zz","tab":"t1"},{"id":"a","tab":"Other"},{"id":"b","tab":"  "}]}
        """
        let plan = try Steward.tabPlan(fromCompletion: completion(answer), tabs: tabs, tiles: tiles)
        XCTAssertEqual(plan, [Steward.TabMove(tile: "a", tab: .existing("t1")), Steward.TabMove(tile: "b", tab: .new("LLooM"))])
    }

    func testPlanSpellsANewTabOneWay() throws {
        let answer = #"{"moves":[{"id":"a","tab":"LLooM"},{"id":"b","tab":"lloom"}]}"#
        let plan = try Steward.tabPlan(fromCompletion: completion(answer), tabs: tabs, tiles: tiles)
        XCTAssertEqual(plan, [Steward.TabMove(tile: "a", tab: .new("LLooM")), Steward.TabMove(tile: "b", tab: .new("LLooM"))])
    }

    func testPlanNamesAnExistingTabByNameAsThatTab() throws {
        let plan = try Steward.tabPlan(fromCompletion: completion(#"{"moves":[{"id":"a","tab":"tessera"}]}"#), tabs: tabs, tiles: tiles)
        XCTAssertEqual(plan, [Steward.TabMove(tile: "a", tab: .existing("t1"))])
    }

    func testPlanMessagesSayWhatMayMove() {
        let messages = Steward.tabMessages(tabs: tabs, tiles: tiles)
        XCTAssertEqual(messages.first?["role"], "system")
        let body = messages.last?["content"] ?? ""
        XCTAssertTrue(body.contains("id=t1 | Tessera | made by the developer"), body)
        XCTAssertTrue(body.contains("id=a | Fix rename focus | ~/tessera | no tab | movable"), body)
        XCTAssertTrue(body.contains("id=c | Pinned | ~ | tab t1 | placed by the developer"), body)
    }
}
