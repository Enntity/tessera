import XCTest
@testable import TesseraKit

private func tile(_ id: String, _ activity: TileActivity = .idle, attention: Bool = false, age: TimeInterval = 0,
                  kind: TileKind = .terminal, title: String? = nil, folder: String = "") -> TileInfo {
    TileInfo(id: id, kind: kind, flavor: .shell, title: title ?? id, subtitle: folder, activity: activity, attention: attention,
             lastActivityAt: Date(timeIntervalSince1970: age))
}

/// ⌘J, the HUD counters, the palette and the phone all visit waiting tiles in one order.
final class AttentionQueueTests: XCTestCase {
    func testQuestionsThenFailuresThenResultsOldestFirst() {
        let tiles = [tile("done-old", .done, attention: true, age: 1), tile("failed", .failed, attention: true, age: 40),
                     tile("ask-new", .needsInput, attention: true, age: 30), tile("ask-old", .needsInput, age: 20),
                     tile("working", .working, attention: true, age: 2), tile("failed-seen", .failed, age: 3), tile("idle", age: 4)]
        XCTAssertEqual(tiles.attentionQueue().map(\.id), ["ask-old", "ask-new", "failed", "done-old"])
        XCTAssertEqual([TileInfo]().attentionQueue(), [])
    }

    func testNextMovesOnFromATileTheUserHasSeen() {
        let ask = tile("ask", .needsInput, age: 50), ask2 = tile("ask2", .needsInput, attention: true, age: 60)
        let failed = tile("failed", .failed, attention: true, age: 20), done = tile("done", .done, attention: true, age: 30)
        let tiles = [done, ask2, failed, ask]
        XCTAssertEqual(tiles.next(after: nil), "ask")
        // On a question already seen (put off, or opened in its app) it moves on, and round again after the last.
        XCTAssertEqual(tiles.next(after: ask), "ask2")
        XCTAssertEqual([ask].next(after: ask), "ask")
        // A tile that is only selected, not yet seen, isn't passed over: the most pressing comes first.
        XCTAssertEqual(tiles.next(after: failed), "ask")
        XCTAssertEqual(tiles.next(after: tile("elsewhere")), "ask")
        XCTAssertNil([TileInfo]().next(after: ask))
        // Tiles that aren't waiting (the working counter's) go oldest first.
        XCTAssertEqual([tile("w2", .working, age: 9), tile("w1", .working, age: 5)].next(after: nil), "w1")
    }

    func testNextGoesOnFromATileThatStoppedWaitingWhenItWasOpened() {
        let ask = tile("ask", .needsInput, age: 50), failed = tile("failed", .failed, attention: true, age: 20)
        let done = tile("done", .done, attention: true, age: 30)
        // Opening the failure marked it seen, so it left the queue: its old place still says what is next.
        XCTAssertEqual([ask, done].next(after: failed), "done")
        XCTAssertEqual([ask].next(after: done), "ask")
    }

    func testBoardStateCountsEachTileUnderItsOwnState() {
        let state = BoardState([tile("w", .working, attention: true), tile("q", .needsInput, attention: true, age: 9),
                                tile("seen", .needsInput, age: 5), tile("d", .done, attention: true), tile("f", .failed, attention: true),
                                tile("f-seen", .failed), tile("i")])
        XCTAssertEqual(state.working, ["w"])
        XCTAssertEqual(state.needsInput, ["q", "seen"])
        XCTAssertEqual(state.failed, ["f"])
        XCTAssertEqual(state.done, ["d"])
        XCTAssertEqual(state.queue, ["seen", "q", "f", "d"])
        XCTAssertEqual(state.needsUser, ["q", "seen", "f", "d"])
        // A tab's dot shows the most pressing state among its tiles.
        XCTAssertEqual(state.waiting(in: ["d", "f", "i"]), .failed)
        XCTAssertEqual(state.waiting(in: ["d", "q"]), .needsInput)
        XCTAssertNil(state.waiting(in: ["w", "i", "f-seen"]))
    }
}
