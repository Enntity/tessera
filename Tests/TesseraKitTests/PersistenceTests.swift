import XCTest
@testable import TesseraHost
@testable import TesseraKit

/// Saved state is never silently lost: unreadable files are kept aside before being replaced.
@MainActor
final class StateFileTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tessera-state-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func copies(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".unreadable-") }
    }

    func testMissingFileIsNotAProblem() throws {
        let dir = try tempDir()
        XCTAssertNil(StateFile.load([MachineConfig].self, from: dir.appendingPathComponent("machines.json")))
        XCTAssertEqual(try copies(in: dir), [])
    }

    func testUnreadableFileIsKeptAside() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("workspace.json")
        try Data("{\"tiles\": [".utf8).write(to: url)
        XCTAssertNil(StateFile.load(Workspace.Saved.self, from: url))
        let kept = try copies(in: dir)
        XCTAssertEqual(kept.count, 1)
        XCTAssertTrue(kept[0].hasPrefix("workspace.json.unreadable-"))
        XCTAssertTrue(StateFile.keptAside.contains { $0.lastPathComponent == kept[0] })
    }

    func testUnknownEntriesDropOutAloneAndTheFileIsKept() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("providers.json")
        try Data(#"[{"id":"a","kind":"openrouter","name":"OR"},{"id":"b","kind":"fromTheFuture","name":"?"}]"#.utf8).write(to: url)
        XCTAssertEqual(StateFile.loadList(UsageProviderConfig.self, from: url)?.map(\.id), ["a"])
        XCTAssertEqual(try copies(in: dir).count, 1)

        let board = dir.appendingPathComponent("workspace.json")
        try Data(#"{"tiles":[{"id":"t","kind":"terminal"},{"id":"x","kind":"hologram"}],"resumeOnLaunch":false}"#.utf8).write(to: board)
        let saved = try XCTUnwrap(StateFile.load(Workspace.Saved.self, from: board))
        XCTAssertEqual(saved.tiles.compactMap(\.value).map(\.id), ["t"])
        XCTAssertEqual(saved.resumeOnLaunch, false)
    }

    func testSaveRoundTrips() throws {
        let url = try tempDir().appendingPathComponent("sub/machines.json")
        StateFile.save([MachineConfig(id: "m", name: "Box", sshHost: "box")], to: url)
        XCTAssertEqual(StateFile.loadList(MachineConfig.self, from: url)?.map(\.sshHost), ["box"])

        let board = url.deletingLastPathComponent().appendingPathComponent("workspace.json")
        let tile = Workspace.Saved.Tile(id: "t", kind: .terminal, command: "claude", cwd: "/w", sessionId: "S")
        let page = Workspace.Saved.Tile(id: "w", kind: .browser, title: "Docs", url: "https://example.com")
        StateFile.save(Workspace.Saved(tiles: [Lossy(tile), Lossy(page)], order: ["t", "claude:x"], hidden: ["claude:y": Date(timeIntervalSince1970: 5)],
                                       agentLookbackHours: 12, titles: ["claude:x": "Release notes"]), to: board)
        let saved = try XCTUnwrap(StateFile.load(Workspace.Saved.self, from: board))
        XCTAssertEqual(saved.tiles.compactMap(\.value).map(\.sessionId), ["S", nil])
        // A name the user gave a tile is kept, whatever its kind.
        XCTAssertEqual(saved.tiles.compactMap(\.value).map(\.title), [nil, "Docs"])
        XCTAssertEqual(saved.titles, ["claude:x": "Release notes"])
        XCTAssertEqual(saved.order, ["t", "claude:x"])
        XCTAssertEqual(saved.hidden, ["claude:y": Date(timeIntervalSince1970: 5)])
        XCTAssertEqual(saved.agentLookbackHours, 12)
    }

    /// A closed tile is kept with what brings it back, across launches: an agent's command, folder
    /// and conversation; a page's address.
    func testRecentlyClosedTilesAreSaved() throws {
        let board = try tempDir().appendingPathComponent("workspace.json")
        let agent = ClosedTile(title: "Fix login", subtitle: "~/app",
                               tile: .init(id: "t", kind: .terminal, command: "claude", cwd: "/app", sessionId: "S"), tab: "tab-1")
        let page = ClosedTile(title: "Docs", subtitle: "example.com", tile: .init(id: "w", kind: .browser, url: "https://example.com"))
        StateFile.save(Workspace.Saved(tiles: [], closed: [Lossy(page), Lossy(agent)]), to: board)
        let closed = try XCTUnwrap(StateFile.load(Workspace.Saved.self, from: board)?.closed?.compactMap(\.value))
        XCTAssertEqual(closed.map(\.id), ["w", "t"])
        XCTAssertEqual(closed.map(\.kind), [.browser, .terminal])
        XCTAssertEqual(closed[0].tile.url, "https://example.com")
        XCTAssertEqual([closed[1].title, closed[1].tile.command, closed[1].tile.cwd, closed[1].tile.sessionId, closed[1].tab],
                       ["Fix login", "claude", "/app", "S", "tab-1"])

        // One this build can't read drops out alone, and boards saved before there was a list still load.
        try Data(#"{"tiles":[],"closed":[{"title":"?","subtitle":"","tile":{"id":"x","kind":"hologram"}},{"title":"Docs","subtitle":"","tile":{"id":"w","kind":"browser"}}]}"#.utf8).write(to: board)
        XCTAssertEqual(StateFile.load(Workspace.Saved.self, from: board)?.closed?.compactMap(\.value).map(\.id), ["w"])
        try Data(#"{"tiles":[]}"#.utf8).write(to: board)
        XCTAssertNil(try XCTUnwrap(StateFile.load(Workspace.Saved.self, from: board)).closed)
    }
}

/// App sessions aren't saved as tiles, but their places on the board are.
final class BoardOrderTests: XCTestCase {
    func testReappearingSessionReturnsAfterItsSavedNeighbour() {
        let saved = ["t1", "claude:a", "t2", "codex:b"]
        XCTAssertEqual(Workspace.restoredIndex(of: "claude:a", saved: saved, in: ["t1", "t2"]), 1)
        XCTAssertEqual(Workspace.restoredIndex(of: "codex:b", saved: saved, in: ["t1", "claude:a", "t2"]), 3)
        // Its neighbours are gone: nothing before it survives, so it leads.
        XCTAssertEqual(Workspace.restoredIndex(of: "claude:a", saved: saved, in: ["t2"]), 0)
        // Never saved: a new session goes last.
        XCTAssertEqual(Workspace.restoredIndex(of: "dsh:new", saved: saved, in: ["t1", "t2"]), 2)
    }

    func testClosingATileSelectsItsNeighbourOnShow() {
        // The tile that takes its place, else the one before it; never one the tab hides.
        XCTAssertEqual(Workspace.neighbor(of: "b", in: ["a", "b", "c"]), "c")
        XCTAssertEqual(Workspace.neighbor(of: "c", in: ["a", "b", "c"]), "b")
        XCTAssertNil(Workspace.neighbor(of: "a", in: ["a"]))
        XCTAssertEqual(Workspace.neighbor(of: "elsewhere", in: ["a", "b"]), "a")
    }

    func testSavedOrderKeepsOnlyWhatShouldComeBack() {
        let saved = ["t1", "claude:hidden", "t2", "gone", "codex:closed-for-good"]
        let order = Workspace.persistedOrder(["t2", "t1"], saved: saved) { $0 == "claude:hidden" }
        XCTAssertEqual(order, ["t2", "t1", "claude:hidden"])
        XCTAssertEqual(Workspace.persistedOrder([], saved: saved) { _ in false }, [])
    }
}

final class BoardLockTests: XCTestCase {
    func testSecondTakerSeesTheHolder() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tessera-lock-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(BoardLock.take(in: dir))
        XCTAssertEqual(BoardLock.take(in: dir), getpid())
        // A folder that can't hold a lock doesn't stop a launch.
        XCTAssertNil(BoardLock.take(in: dir.appendingPathComponent("missing")))
    }
}
