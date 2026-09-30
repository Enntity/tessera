import XCTest
@testable import TesseraKit

private func tile(_ id: String, _ activity: TileActivity = .idle, attention: Bool = false, age: TimeInterval = 0,
                  kind: TileKind = .terminal, flavor: AgentFlavor = .shell, title: String? = nil, folder: String = "",
                  detail: String? = nil) -> TileInfo {
    TileInfo(id: id, kind: kind, flavor: flavor, title: title ?? id, subtitle: folder, activity: activity, attention: attention,
             lastActivityAt: Date(timeIntervalSince1970: age), detail: detail)
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

/// ⌘K finds tiles by title, folder, tab and state; the best match leads, so ⏎ jumps to it.
final class TileSearchTests: XCTestCase {
    private func found(_ query: String, _ candidates: [TileSearch.Candidate]) -> [String] {
        TileSearch.rank(query, candidates).map(\.tile.id)
    }

    func testTitleBeatsFolderBeatsTabBeatsState() {
        let candidates = [
            TileSearch.Candidate(tile: tile("state", .failed, title: "build")),
            TileSearch.Candidate(tile: tile("tab", title: "notes"), tab: "Failed experiments"),
            TileSearch.Candidate(tile: tile("folder", title: "shell", folder: "~/src/failed-run")),
            TileSearch.Candidate(tile: tile("inside", title: "an unfailed run")),
            TileSearch.Candidate(tile: tile("word", title: "the failed deploy")),
            TileSearch.Candidate(tile: tile("prefix", title: "Failed deploy")),
            TileSearch.Candidate(tile: tile("other", title: "tessera", folder: "~/src/tessera"))
        ]
        XCTAssertEqual(found("failed", candidates), ["prefix", "word", "inside", "folder", "tab", "state"])
        XCTAssertEqual(found("FAIL", candidates).first, "prefix")
        XCTAssertEqual(TileSearch.match("dep", in: "Failed deploy"), 1)
        XCTAssertEqual(TileSearch.match("ploy", in: "Failed deploy"), 2)
        XCTAssertNil(TileSearch.match("x", in: "Failed deploy"))
    }

    func testEveryWordMustMatchSomewhere() {
        let candidates = [
            TileSearch.Candidate(tile: tile("a", .needsInput, title: "api server", folder: "~/src/shop"), tab: "Work"),
            TileSearch.Candidate(tile: tile("b", title: "api client", folder: "~/src/blog"))
        ]
        XCTAssertEqual(found("api shop", candidates), ["a"])
        XCTAssertEqual(found("api work needs", candidates), ["a"])
        XCTAssertEqual(found("api server", candidates), ["a"])
        XCTAssertEqual(found("api nothing", candidates), [])
        XCTAssertEqual(found("  ", candidates), [])
    }

    func testATileIsFoundByWhatItAsksAndWhatItShows() {
        let candidates = [
            TileSearch.Candidate(tile: tile("screen", title: "shell"), text: "$ npm test\n PASS tests/auth.test.ts"),
            TileSearch.Candidate(tile: tile("asks", .needsInput, title: "deploy", detail: "Allow command: rm -rf build/ ?")),
            TileSearch.Candidate(tile: tile("title", title: "auth flow")),
            TileSearch.Candidate(tile: tile("other", title: "notes"))
        ]
        // The title leads, then the folder, what it asks, its tab, its state, and last what is on it.
        XCTAssertEqual(found("auth", candidates), ["title", "screen"])
        XCTAssertEqual(found("allow", candidates), ["asks"])
        XCTAssertEqual(found("deploy build", candidates), ["asks"])
        XCTAssertEqual(found("shell pass", candidates), ["screen"])
        XCTAssertNil(TileSearch.score(" ", candidates[0]))
        XCTAssertEqual(TileSearch.score("needs", candidates[1]), 6)
    }

    func testWhereTheWordsAreInATitle() {
        func lit(_ query: String, _ title: String) -> [String] { TileSearch.ranges(of: query, in: title).map { String(title[$0]) } }
        XCTAssertEqual(lit("auth", "Refactor auth flow"), ["auth"])
        XCTAssertEqual(lit("AUTH", "Auth: reauthorise"), ["Auth", "auth"])
        XCTAssertEqual(lit("flow auth", "Refactor auth flow"), ["auth", "flow"])
        // Words that run into each other light up as one.
        XCTAssertEqual(lit("refac actor", "Refactor auth flow"), ["Refactor"])
        XCTAssertEqual(lit("api", "Refactor auth flow"), [])
        XCTAssertEqual(lit("", "Refactor auth flow"), [])
    }

    func testEqualMatchesPutTheBoardBeforeHiddenAndTheLatestFirst() {
        let candidates = [
            TileSearch.Candidate(tile: tile("hidden", age: 90, title: "deploy notes"), hidden: true),
            TileSearch.Candidate(tile: tile("old", age: 10, title: "deploy staging")),
            TileSearch.Candidate(tile: tile("new", age: 50, title: "deploy prod"))
        ]
        XCTAssertEqual(found("deploy", candidates), ["new", "old", "hidden"])
    }
}

/// The filter field and its chips narrow the board in place, within the tab being viewed.
final class BoardQueryTests: XCTestCase {
    private let tiles = [
        tile("shell"),
        tile("claude-asks", .needsInput, flavor: .claude, title: "auth flow"),
        tile("claude-app", .working, kind: .agentSession, flavor: .claudeDesktop, title: "auth docs"),
        tile("codex", .working, flavor: .codex),
        tile("codex-done", .done, attention: true, kind: .agentSession, flavor: .codexDesktop),
        tile("dsh", kind: .agentSession, flavor: .dsh),
        tile("page", kind: .browser, flavor: .web, title: "auth provider docs")
    ]
    private var ids: [String] { tiles.map(\.id) }
    private var holdings: BoardQuery.Holdings { BoardQuery.holdings(of: tiles) }

    private func shown(_ query: BoardQuery) -> [String] {
        query.narrow(ids, found: query.find(in: tiles.map { TileSearch.Candidate(tile: $0) }), holdings: holdings)
    }

    func testEachChipHoldsItsOwnTiles() {
        XCTAssertEqual(holdings[.needsYou], ["claude-asks", "codex-done"])
        XCTAssertEqual(holdings[.working], ["claude-app", "codex"])
        XCTAssertEqual(holdings[.terminals], ["shell", "claude-asks", "codex"])
        XCTAssertEqual(holdings[.claude], ["claude-asks", "claude-app"])
        XCTAssertEqual(holdings[.codex], ["codex", "codex-done"])
        XCTAssertEqual(holdings[.dsh], ["dsh"])
        XCTAssertEqual(holdings[.web], ["page"])
        XCTAssertEqual(BoardQuery.Chip.allCases.map(\.label), ["Needs you", "Working", "Terminals", "Claude", "Codex", "dsh", "Web"])
    }

    func testAnEmptyQueryShowsEverythingInOrder() {
        XCTAssertTrue(BoardQuery().isEmpty)
        XCTAssertTrue(BoardQuery(text: "  ").isEmpty)
        XCTAssertNil(BoardQuery(text: "  ").find(in: []))
        XCTAssertEqual(shown(BoardQuery()), ids)
    }

    func testChipsOfOneSortWidenAndTheTwoSortsNarrow() {
        XCTAssertEqual(shown(BoardQuery(chips: [.claude, .codex])), ["claude-asks", "claude-app", "codex", "codex-done"])
        XCTAssertEqual(shown(BoardQuery(chips: [.needsYou, .working])), ["claude-asks", "claude-app", "codex", "codex-done"])
        XCTAssertEqual(shown(BoardQuery(chips: [.claude, .working])), ["claude-app"])
        XCTAssertEqual(shown(BoardQuery(chips: [.terminals, .web, .needsYou])), ["claude-asks"])
        // A chip that holds nothing shows nothing, but for the tile that is open.
        XCTAssertEqual(BoardQuery(chips: [.dsh]).narrow(ids, found: nil, holdings: [:]), [])
        XCTAssertEqual(BoardQuery(chips: [.dsh]).narrow(ids, found: nil, holdings: [:], keeping: "page"), ["page"])
    }

    func testTextNarrowsWithTheChipsAndKeepsTheBoardsOrder() {
        XCTAssertEqual(shown(BoardQuery(text: "auth")), ["claude-asks", "claude-app", "page"])
        XCTAssertEqual(shown(BoardQuery(text: "auth docs", chips: [.claude])), ["claude-app"])
        XCTAssertEqual(shown(BoardQuery(text: "nothing like it")), [])
        // The tab being viewed narrows first: only its tiles are there to find.
        let query = BoardQuery(text: "auth")
        XCTAssertEqual(query.narrow(["page", "shell"], found: query.find(in: tiles.map { TileSearch.Candidate(tile: $0) }), holdings: holdings), ["page"])
    }

    func testAChipCountsWhatItWouldShowAmongTheOtherSortAndTheText() {
        func count(_ chip: BoardQuery.Chip, _ query: BoardQuery) -> Int {
            query.count(chip, in: ids, found: query.find(in: tiles.map { TileSearch.Candidate(tile: $0) }), holdings: holdings)
        }
        XCTAssertEqual(count(.claude, BoardQuery()), 2)
        XCTAssertEqual(count(.working, BoardQuery()), 2)
        // Its own sort doesn't change a chip's number; the other sort and the text do.
        XCTAssertEqual(count(.claude, BoardQuery(chips: [.codex])), 2)
        XCTAssertEqual(count(.claude, BoardQuery(chips: [.working])), 1)
        XCTAssertEqual(count(.working, BoardQuery(chips: [.claude, .codex])), 2)
        XCTAssertEqual(count(.web, BoardQuery(text: "auth")), 1)
        XCTAssertEqual(count(.codex, BoardQuery(text: "auth")), 0)
    }
}

final class TileHistoryTests: XCTestCase {
    private struct Closed: Identifiable, Equatable {
        var id: String
        var note = ""
    }

    func testRecentlyClosedKeepsTheLatestNewestFirst() {
        var closed = RecentlyClosed<Closed>(limit: 3)
        for id in ["a", "b", "c", "d"] { closed.push(Closed(id: id)) }
        XCTAssertEqual(closed.tiles.map(\.id), ["d", "c", "b"])
        // Closed again, a tile has one record: the new one.
        closed.push(Closed(id: "b", note: "again"))
        XCTAssertEqual(closed.tiles, [Closed(id: "b", note: "again"), Closed(id: "d"), Closed(id: "c")])
        XCTAssertEqual(closed.take("d"), Closed(id: "d"))
        XCTAssertNil(closed.take("d"))
        XCTAssertEqual(closed.tiles.map(\.id), ["b", "c"])
        XCTAssertEqual(RecentlyClosed([Closed(id: "x"), Closed(id: "y")], limit: 1).tiles.map(\.id), ["x"])
    }

    func testControlTabGoesBackToTheTileOpenedBefore() {
        var opened = OpenHistory()
        XCTAssertNil(opened.previous(from: "a") { _ in true })
        for id in ["a", "b", "c", "b"] { opened.note(id) }
        XCTAssertEqual(opened.ids, ["b", "c", "a"])
        // A toggle: from the open tile to the one before, and back.
        XCTAssertEqual(opened.previous(from: "b") { _ in true }, "c")
        XCTAssertEqual(opened.previous(from: "c") { _ in true }, "b")
        // On the board with none of them open, it is the last one opened; closed tiles are passed over.
        XCTAssertEqual(opened.previous(from: nil) { _ in true }, "b")
        XCTAssertEqual(opened.previous(from: "b") { $0 != "c" }, "a")
    }
}

final class BoardCommandTests: XCTestCase {
    private func targets(_ command: BoardCommand, suspended: Set<String> = []) -> [String] {
        let tiles = [tile("unseen", .done, attention: true), tile("asking", .needsInput), tile("exited", .exited), tile("down", .exited),
                     tile("failed", .failed, attention: true), tile("shell"), tile("page", kind: .browser),
                     tile("chat", kind: .agentSession), tile("chat-busy", .working, kind: .agentSession)]
        return tiles.filter { command.applies(to: $0, suspended: suspended.contains($0.id)) }.map(\.id)
    }

    func testEachCommandPicksItsOwnTiles() {
        XCTAssertEqual(targets(.markAllSeen), ["unseen", "failed"])
        // A terminal the user shut down is kept for Resume, not swept away.
        XCTAssertEqual(targets(.closeExited, suspended: ["down"]), ["exited"])
        XCTAssertEqual(targets(.restartFailed), ["failed"])
        XCTAssertEqual(targets(.hideIdle), ["chat"])
        XCTAssertEqual(targets(.resumeAll, suspended: ["down"]), ["down"])
        XCTAssertEqual(targets(.shutDownAll, suspended: ["down"]), ["unseen", "asking", "exited", "failed", "shell"])
        // Hidden conversations aren't among the board's tiles.
        XCTAssertEqual(targets(.showHidden), [])
        XCTAssertEqual(BoardCommand.allCases.filter(\.everyTab), [.shutDownAll, .resumeAll])
    }
}
